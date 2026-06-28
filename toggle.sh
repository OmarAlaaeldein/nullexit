#!/bin/bash
# toggle.sh — nullexit gateway toggle script for macOS
# Automatically handles Docker containers, Colima, DNS hijacking, and Tailscale exit node routing.

set -e

# Start execution timer
TOGGLE_START_TIME=$SECONDS

# Global flag to track if the script completed successfully
SUCCESS_RUN=false

# Global variable to track the currently running background command PID
CURRENT_BG_PID=""

# Helper function to run a command with a timeout (in seconds)
# Returns the command's exit code, or 143 if timed out.
run_with_timeout() {
  local timeout_sec="$1"
  shift
  
  # Run the command in the background
  "$@" &
  local cmd_pid=$!
  CURRENT_BG_PID="$cmd_pid"
  
  # Run a watchdog sleep in the background
  (
    sleep "$timeout_sec"
    if kill -0 "$cmd_pid" 2>> output.log; then
      echo -e "\n[Timeout] Command '$*' exceeded $timeout_sec seconds. Terminating..." >&2
      kill -15 "$cmd_pid" 2>> output.log || true
      sleep 2
      if kill -0 "$cmd_pid" 2>> output.log; then
        kill -9 "$cmd_pid" 2>> output.log || true
      fi
    fi
  ) &
  local watcher_pid=$!
  
  # Disable set -e temporarily to capture exit status of wait
  set +e
  wait "$cmd_pid"
  local exit_status=$?
  set -e
  
  # Kill the watcher since the command finished
  kill "$watcher_pid" 2>> output.log && wait "$watcher_pid" 2>> output.log || true
  
  CURRENT_BG_PID=""
  return "$exit_status"
}

# Helper function to run a GUI command as the logged-in console user
# (Prevents permission failures if the script is run with sudo)
run_gui_cmd() {
  local console_user
  console_user=$(stat -f '%Su' /dev/console 2>> output.log || echo "$SUDO_USER")
  if [ -z "$console_user" ] || [ "$console_user" = "root" ]; then
    console_user=$(logname 2>> output.log || echo "$USER")
  fi

  if [ -n "$console_user" ] && [ "$console_user" != "root" ] && [ "$EUID" -eq 0 ]; then
    sudo -u "$console_user" "$@"
  else
    "$@"
  fi
}

PID_FILE="/tmp/nullexit-caffeinate.pid"

# Start macOS caffeinate to prevent sleep while gateway is running
start_sleep_prevention() {
  if ! command -v caffeinate >/dev/null 2>&1; then
    echo "  [Warning] caffeinate tool not found. Sleep prevention unavailable."
    return 1
  fi

  # Stop any existing sleep prevention process first to avoid duplicates
  stop_sleep_prevention

  echo "  Enabling system sleep prevention (caffeinate)..."
  # Run caffeinate to prevent idle system sleep, redirecting all output.
  # This prevents the system from sleeping while leaving the screen free to turn off.
  nohup caffeinate -i >> output.log 2>&1 &
  local caffe_pid=$!
  echo "$caffe_pid" > "$PID_FILE"
  echo "  Sleep prevention active (PID $caffe_pid). Your Mac won't sleep while the gateway is running."
}

# Stop macOS caffeinate when gateway is stopped
stop_sleep_prevention() {
  if [ -f "$PID_FILE" ]; then
    local caffe_pid
    caffe_pid=$(cat "$PID_FILE")
    if [ -n "$caffe_pid" ] && kill -0 "$caffe_pid" 2>/dev/null && ps -p "$caffe_pid" -o comm= 2>/dev/null | grep -q caffeinate; then
      echo "  Stopping system sleep prevention (caffeinate PID $caffe_pid)..."
      kill "$caffe_pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
  fi
}

# Cleanup handler to restore DNS to 1.1.1.1 on error or user interrupt (Ctrl+C / SIGTERM / SIGHUP)
cleanup_handler() {
  local exit_code=$?
  local trigger_type="$1"
  local line_no="$2"
  
  if [ "$SUCCESS_RUN" = "false" ]; then
    echo -e "\n[Self-Correction] Script interrupted or failed ($trigger_type). Restoring host DNS to 1.1.1.1..."
    if [ -n "$ACTIVE_SERVICE" ]; then
      reset_dns
    fi
    
    if [ -n "$CURRENT_BG_PID" ]; then
      echo "Terminating active command (PID $CURRENT_BG_PID)..."
      kill -15 "$CURRENT_BG_PID" 2>> output.log || true
    fi

    # Disconnect host Tailscale and close the GUI application on failure
    disconnect_tailscale_host

    # Stop local DNS proxy if running
    stop_local_dns_proxy

    # Stop sleep prevention
    stop_sleep_prevention

    # Nuke leftover network state (proxies, routes, DNS cache, Wi-Fi)
    if [ -n "$ACTIVE_SERVICE" ]; then
      cleanup_network_state
    fi
    
    if [ "$trigger_type" = "ERR" ]; then
      echo -e "\n=============================================="
      echo "ERROR: Script failed at line $line_no with exit code $exit_code."
      echo "=============================================="
      echo "Troubleshooting steps:"
      echo "1. Run 'colima status' to verify the VM is active."
      echo "2. Run 'docker compose ps' to check container health."
      echo "3. Run 'docker compose logs' to view application logs."
      echo "4. Run 'tailscale status' to check host Tailscale status."
      echo "=============================================="
    fi
  fi
}

trap 'cleanup_handler ERR $LINENO' ERR
trap 'cleanup_handler INT' INT
trap 'cleanup_handler TERM' TERM
trap 'cleanup_handler HUP' HUP

# ─── NOPASSWD sudo ──────────────────────────────────────────────────────────
# The user has NOPASSWD in /etc/sudoers.d/nullexit for the specific commands
# needed (networksetup, dnsmasq, dscacheutil, killall, pkill, socat).
# All privileged calls below use `sudo -n` which will run without prompting.
# No credential caching loop is needed.

# Add Homebrew and standard paths
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$PATH"

# Check for local DNS proxy tools (used when tailnet data plane is unavailable)
# Uses a Python DNS proxy (handles TCP wire format correctly).
# Python3 is built into macOS — no external dependencies.
DNS_PROXY_BIN=""
if command -v python3 >> output.log 2>&1; then
  DNS_PROXY_BIN="python3"
elif command -v python >> output.log 2>&1; then
  DNS_PROXY_BIN="python"
fi

# Path to the DNS proxy script (sibling of this script)
DNS_PROXY_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dns-proxy.py"

# Resolve Tailscale CLI on host. We rely on the standalone Homebrew formula
# (`brew install tailscale` + `brew services start tailscale`) — NOT the
# Tailscale.app GUI — so there is no .app bundle or Network Extension sandbox
# to launch, no menu-bar click to perform, and no scutil Network Service to
# start manually. tailscaled runs as a per-user LaunchAgent (or LaunchDaemon
# if you ran the install with sudo) and the control socket is always available.
TS_BIN=""
if command -v tailscale >> output.log 2>&1; then
  TS_BIN="tailscale"
fi

# Baseline: disable Tailscale DNS management at the daemon level.
# `tailscale set` writes a persistent preference. However, `tailscale up --reset`
# (used in steps 7 and 9) RESETS all unspecified flags to defaults, which would
# re-enable `--accept-dns=true` and nullify this `set`.
# Therefore, EVERY `tailscale up --reset` call in this file MUST also pass
# `--accept-dns=false` explicitly. See steps 7 and 9 for the fix.
#
# This initial `set` is still useful as a baseline for non-reset operations
# (e.g. if the user runs `tailscale up` manually without --reset) and covers
# the brief window between this line and the first `--reset` call.
#
# Runs once at script start while tailscaled is still connected (if it was
# left running from a previous toggle), so the pref takes effect before any
# disconnection or reconnection logic.
if [ -n "$TS_BIN" ]; then
  $TS_BIN set --accept-dns=false >> output.log 2>&1 || true
fi

# Disconnect host Tailscale from the mesh. With the standalone daemon, this is the
# *entire* teardown — no scutil tunnel stop, no Tailscale.app GUI quit, no pkill.
# tailscaled keeps running (as a LaunchAgent / LaunchDaemon), which is intentional:
# the next `tailscale up` then reconnects in seconds rather than waiting for a
# slow .app launch + Network Extension activation. The `tailscale down` call also
# retains the user's auth state, so we don't force a browser re-login every cycle.
#
# Defined early (before the if/else branches and referenced by cleanup_handler's
# ERR trap) so that any failure before the main logic can still tear down Tailscale.
disconnect_tailscale_host() {
  if [ -n "$TS_BIN" ]; then
    echo "Disconnecting host Tailscale from mesh (tailscaled stays running as system service)..."
    run_with_timeout 10 $TS_BIN down >> output.log 2>&1 || true
  fi
}

# Function to get the active network service name (e.g., "Wi-Fi" or "USB 10/100 LAN")
get_active_service() {
  local iface
  iface=$(route get default 2>> output.log | awk '/interface:/ {print $2}')
  
  # If the default interface is empty or a VPN tunnel (like utunX), fallback to the active physical interface
  if [[ -z "$iface" || ! "$iface" =~ ^en[0-9]+$ ]]; then
    for i in en0 en1 en2 en3; do
      if ifconfig "$i" 2>> output.log | grep -q "status: active" && ifconfig "$i" 2>> output.log | grep -q "inet "; then
        iface="$i"
        break
      fi
    done
  fi

  # Default fallback if still empty or not enX
  if [[ -z "$iface" || ! "$iface" =~ ^en[0-9]+$ ]]; then
    iface="en0"
  fi

  # Map interface (e.g., en0) to service name (e.g., Wi-Fi)
  local service
  service=$(networksetup -listnetworkserviceorder | grep -B 1 "Device: $iface" | head -n 1 | sed -E 's/^\([0-9\*]+\) //')
  
  if [ -n "$service" ]; then
    echo "$service"
  else
    echo "Wi-Fi"
  fi
}

ACTIVE_SERVICE=$(get_active_service)

# Resolve the service name for en0 (usually "Wi-Fi") — macOS scutil DNS resolver
# is commonly scoped to en0, so per-service DNS changes on other interfaces are
# ignored unless en0's service is also updated.
EN0_SERVICE=$(networksetup -listnetworkserviceorder 2>> output.log | grep -B1 "Device: en0" | head -1 | sed -E 's/^\([0-9\*]+\) //' || true)
[ -z "$EN0_SERVICE" ] && EN0_SERVICE="Wi-Fi"

  # Helper to restore host DNS to a clean state (used on script start, on failure,
  # and after a successful STOP). Without this, a successful toggle-off leaves the
  # host's resolver pinned to a now-dead gateway IP — every lookup stalls for macOS's
  # DNS timeout (~5s) before falling through to whatever next server is configured.
  # With it, we always leave the host in `1.1.1.1 / no search domain`.
  #
  # We set DNS on BOTH the active service AND the en0 service because macOS's scutil DNS
  # resolver is commonly scoped to en0 (Wi-Fi). A per-service change on e.g.
  # "USB 10/100 LAN" is ignored by the system resolver unless the en0 service is also updated.
  reset_dns() {
    if [ -n "$ACTIVE_SERVICE" ]; then
      for dns_svc in "$ACTIVE_SERVICE" "$EN0_SERVICE"; do
        networksetup -setsearchdomains "$dns_svc" "Empty" 2>> output.log || true
        networksetup -setdnsservers "$dns_svc" 1.1.1.1 2>> output.log || true
      done
    fi
  }

# Helper to nuke leftover network state after teardown (proxy settings, routing
# table, DNS cache, Wi-Fi). Prevents the "had to write a whole recovery script"
# problem where stale state kills internet after the gateway stops.
cleanup_network_state() {
  echo -e "\nCleaning up network state (proxies, routes, DNS cache, Wi-Fi)..."

  # 1. Disable any leftover proxy settings (needs root on many macOS versions)
  for svc in "$ACTIVE_SERVICE" "$EN0_SERVICE"; do
    sudo -n networksetup -setsocksfirewallproxystate "$svc" off 2>> output.log || true
    sudo -n networksetup -setwebproxystate "$svc" off 2>> output.log || true
    sudo -n networksetup -setsecurewebproxystate "$svc" off 2>> output.log || true
  done
  echo "  Proxies disabled."

  # 2. Flush DNS cache
  if command -v dscacheutil >> output.log 2>&1; then
    sudo -n dscacheutil -flushcache 2>> output.log || true
  fi
  sudo -n killall -HUP mDNSResponder 2>> output.log || true
  echo "  DNS cache flushed."

  # 3. Flush stale routing table entries
  if command -v route >> output.log 2>&1; then
    sudo -n route -n flush >> output.log 2>&1 || true
  fi
  echo "  Routing table flushed."

  # 4. Power-cycle Wi-Fi to clear any lingering interface state
  WIFI_PORT=$(networksetup -listallhardwareports 2>> output.log | awk '/Hardware Port: Wi-Fi/{getline; print $2}')
  if [ -n "$WIFI_PORT" ]; then
    sudo -n networksetup -setairportpower "$WIFI_PORT" off 2>> output.log || true
    sleep 2
    sudo -n networksetup -setairportpower "$WIFI_PORT" on 2>> output.log || true
    echo "  Wi-Fi power-cycled (interface $WIFI_PORT)."
    sleep 3
  else
    echo "  Wi-Fi interface not detected; bouncing en0..."
    sudo -n ifconfig en0 down 2>> output.log || true
    sudo -n ifconfig en0 up 2>> output.log || true
  fi

  echo "Network state cleanup complete."
}

# ─── SOCKS5 Proxy (WARP Tunnel) ────────────────────────────────────────────
# When Tailscale's exit node can't route through WARP (due to userspace
# forwarding), we use a SOCKS5 proxy running inside the warp container's
# network namespace. Connections created by this proxy go through the
# kernel routing table (table 200 -> tun0 -> WARP), unlike Tailscale's
# userspace exit node which bypasses it.
#
# The SOCKS5 proxy is exposed on localhost:1080 via Docker port mapping.
# `networksetup -setsocksfirewallproxy` on macOS routes system TCP traffic
# through the proxy, which then goes through WARP.
#
# IMPORTANT: CLI tools like curl do NOT respect macOS system proxy settings.
# They must use --socks5-hostname or the ALL_PROXY env variable explicitly.

SOCKS_PROXY_PORT=1080

enable_socks_proxy() {
  local svc="$1"
  if [ -z "$svc" ]; then
    svc="$ACTIVE_SERVICE"
  fi
  
  echo -n "  Enabling system-wide SOCKS5 proxy on $svc (localhost:$SOCKS_PROXY_PORT)... "
  sudo -n networksetup -setsocksfirewallproxy "$svc" 127.0.0.1 $SOCKS_PROXY_PORT 2>> output.log || true
  sudo -n networksetup -setsocksfirewallproxystate "$svc" on 2>> output.log || true
  
  # Also set on en0 service for macOS resolver consistency
  if [ "$svc" != "$EN0_SERVICE" ]; then
    sudo -n networksetup -setsocksfirewallproxy "$EN0_SERVICE" 127.0.0.1 $SOCKS_PROXY_PORT 2>> output.log || true
    sudo -n networksetup -setsocksfirewallproxystate "$EN0_SERVICE" on 2>> output.log || true
  fi
  
  echo "done."
  echo "  All TCP traffic now routed through gateway -> WARP tunnel -> internet."
  echo "  (CLI tools: export ALL_PROXY=socks5://127.0.0.1:$SOCKS_PROXY_PORT)"
}

disable_socks_proxy() {
  for svc in "$ACTIVE_SERVICE" "$EN0_SERVICE"; do
    sudo -n networksetup -setsocksfirewallproxystate "$svc" off 2>> output.log || true
  done
  echo "  SOCKS5 proxy disabled."
}

# ─── Local DNS Proxy (Python) ───────────────────────────────────────────────
# When the tailnet data plane cannot establish, we use a Python DNS proxy.
# It listens on UDP:53, receives DNS queries, forwards them over TCP to
# AdGuard at 127.0.0.1:5354 (Docker port mapping), and returns the response.
# The Python script handles the DNS-over-TCP wire format (2-byte length prefix)
# correctly — unlike socat which just forwards raw bytes.
#
# Python3 is built into macOS — no external dependencies.
DNS_PROXY_PID=""

# Kill any leftover DNS proxy process
stop_local_dns_proxy() {
  if [ -n "$DNS_PROXY_PID" ]; then
    kill "$DNS_PROXY_PID" 2>/dev/null || true
    wait "$DNS_PROXY_PID" 2>/dev/null || true
    DNS_PROXY_PID=""
  fi
  # Clean up any stale Python DNS proxy processes
  sudo -n pkill -f "dns-proxy.py" 2>/dev/null || true
}

# Start local DNS proxy (Python)
start_local_dns_proxy() {
  if [ -z "$DNS_PROXY_BIN" ]; then
    echo "  Python not found. Python3 is built into macOS — this shouldn't happen."
    return 1
  fi

  if [ ! -f "$DNS_PROXY_SCRIPT" ]; then
    echo "  DNS proxy script not found at $DNS_PROXY_SCRIPT"
    return 1
  fi

  # Kill any leftover process first
  stop_local_dns_proxy

  echo -n "  Starting local DNS proxy via Python (UDP:53 → TCP:5354)... "
  sudo -n "$DNS_PROXY_BIN" "$DNS_PROXY_SCRIPT" &
  DNS_PROXY_PID=$!
  disown "$DNS_PROXY_PID" 2>/dev/null || true

  # Give it a moment to bind
  sleep 0.5

  if kill -0 "$DNS_PROXY_PID" 2>/dev/null; then
    echo "started (PID $DNS_PROXY_PID)."

    # Hijack host DNS to localhost
    echo -n "  Hijacking host DNS to 127.0.0.1 for ad-blocking... "
    networksetup -setsearchdomains "$ACTIVE_SERVICE" "Empty" 2>/dev/null || true
    networksetup -setsearchdomains "$EN0_SERVICE" "Empty" 2>/dev/null || true
    if ! networksetup -setdnsservers "$ACTIVE_SERVICE" 127.0.0.1; then
      echo "FAILED (networksetup error — check permissions)."
      stop_local_dns_proxy
      return 1
    fi
    networksetup -setdnsservers "$EN0_SERVICE" 127.0.0.1 2>/dev/null || true
    sudo -n dscacheutil -flushcache 2>/dev/null || true
    sudo -n killall -HUP mDNSResponder 2>/dev/null || true

    # Verify DNS actually works through the proxy
    echo -n "  Verifying DNS resolution... "
    if dig @127.0.0.1 google.com +short +timeout=5 &>/dev/null; then
      echo "ok."
      return 0
    else
      echo "FAILED (DNS queries not reaching AdGuard)."
      echo "  Restoring DNS to 1.1.1.1..."
      reset_dns
      stop_local_dns_proxy
      return 1
    fi
  else
    echo "FAILED (could not bind port 53 — is it in use?)."
    DNS_PROXY_PID=""
    return 1
  fi
}

# Helper to FORCIBLY hijack host DNS to a single server (the gateway's AdGuard IP)
# and VERIFY via `networksetup -getdnsservers` that the only name server is exactly
# $1. Returns 0 iff the live state matches; non-zero if it can't be confirmed.
#
# This deliberately does NOT append a 1.1.1.1 fallback: macOS's resolver queries
# the list in order and falls back to the next entry on timeout, so on a
# misbehaving AdGuard (filter compile crash, OOM kill, etc.) the resolver still
# leaks to 1.1.1.1 and silently bypasses ad-blocking. With no fallback, a broken
# gateway manifests as a *visible* DNS outage that prompts the user to
# investigate — which is the correct failure mode.
force_dns_to_gateway() {
  local target_ip="$1"
  if [ -z "$target_ip" ] || [ -z "$ACTIVE_SERVICE" ]; then
    echo "  [force_dns] ERROR: target_ip or ACTIVE_SERVICE is empty" >&2
    return 1
  fi

  local attempt
  for attempt in 1 2 3; do
    echo -n "  [force_dns] Attempt $attempt/3: setting DNS to $target_ip on \"$ACTIVE_SERVICE\" + \"$EN0_SERVICE\"... "

    # Apply to BOTH the active service AND the en0 service — the scutil DNS resolver
    # is scoped to en0 (Wi-Fi) and ignores per-service changes that don't include it.
    # Fail fast on ACTIVE_SERVICE; best-effort on EN0_SERVICE (it may not exist).
    networksetup -setsearchdomains "$ACTIVE_SERVICE" "ts.net" || true
    if ! networksetup -setdnsservers "$ACTIVE_SERVICE" "$target_ip"; then
      echo "FAILED (networksetup error — check permissions)"
      sleep 1
      continue
    fi
    networksetup -setsearchdomains "$EN0_SERVICE" "ts.net" || true
    networksetup -setdnsservers "$EN0_SERVICE" "$target_ip" || true

    local entries
    entries=$(networksetup -getdnsservers "$ACTIVE_SERVICE" 2>> output.log \
              | awk '/^(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$/ {print}')
    if echo "$entries" | grep -qFx "$target_ip"; then
      echo "VERIFIED"
      return 0
    fi

    local current
    current=$(echo "$entries" | tr '\n' ' ' | sed 's/ $//')
    echo "NOT YET (current DNS: [${current:-none}])"

    if [ "$attempt" = "3" ]; then sleep 2; else sleep 1; fi
  done

  echo "  [force_dns] FAILED after 3 attempts"
  return 1
}

# Ensure DNS is set to 1.1.1.1 immediately at script start to prevent any DNS deadlocks/hangs
# during status checks, container startup, VM boot, or teardown. We *also* clear any leftover
# `ts.net` search domain from a previous `tailscale up --accept-dns=true` run, otherwise macOS
# would prepend it to every lookup and most public DNS queries would resolve to NXDOMAIN.
# Capture current DNS before resetting so we can check if it was hijacked
INITIAL_DNS=$(networksetup -getdnsservers "$ACTIVE_SERVICE" 2>> output.log || true)

echo "Initializing DNS to 1.1.1.1 to ensure reliable internet access..."
reset_dns

# Check if the gateway is active (either containers are running, or host DNS is hijacked)
is_gateway_active() {
  # 1. Check if containers are running (suppress stderr to avoid errors if docker is down)
  if run_with_timeout 15 docker compose ps --status running 2>/dev/null | grep -q 'warp'; then
    return 0
  fi
  # 2. Check if host DNS was hijacked (not 1.1.1.1 and not default/empty)
  if [[ -n "$INITIAL_DNS" && "$INITIAL_DNS" != "1.1.1.1" && ! "$INITIAL_DNS" =~ "There aren't any DNS Servers" ]]; then
    return 0
  fi
  # 3. Check if SOCKS proxy is enabled
  local socks_proxy
  socks_proxy=$(networksetup -getsocksfirewallproxy "$ACTIVE_SERVICE" 2>> output.log || true)
  if echo "$socks_proxy" | grep -q "Enabled: Yes"; then
    return 0
  fi
  return 1
}

echo "Checking Gateway Status..."
if is_gateway_active; then
  echo -e "\n=============================================="
  echo "Gateway is RUNNING. Stopping it now..."
  echo -e "==============================================\n"

  # 1. Disconnect host Tailscale cleanly first before stopping the exit-node container
  disconnect_tailscale_host
  echo ""

  echo "Stopping Docker containers..."
  docker compose down -t 5
  
  # Only stop Colima if the user explicitly opted in (false by default) to prevent breaking their other Docker dev projects
  STOP_COLIMA=$(grep -E "^STOP_COLIMA_ON_EXIT=" .env 2>> output.log | cut -d'=' -f2- | tr -d '"'\' | tr '[:upper:]' '[:lower:]')
  if [[ "$STOP_COLIMA" == "true" ]]; then
    echo -e "\nStopping Colima VM to free up host RAM and battery..."
    run_with_timeout 30 colima stop >> output.log 2>&1 || echo "Warning: Failed to stop Colima gracefully."
  else
    echo -e "\nLeaving Colima running. (Set STOP_COLIMA_ON_EXIT=true in .env to change this)"
  fi

  # The host's DNS was hijacked to the gateway IP during ENABLE; now that the
  # gateway is down, restore DNS to 1.1.1.1 immediately so subsequent lookups
  # don't stall for the macOS DNS timeout before the 1.1.1.1 fallback engages.
  echo -e "\nRestoring host DNS to 1.1.1.1 (gateway is gone)... "
  reset_dns

  # 3. Stop local DNS proxy if running
  stop_local_dns_proxy

  # Stop sleep prevention
  stop_sleep_prevention

  # 4. Nuke leftover network state so internet actually works after teardown
  cleanup_network_state

  ELAPSED=$(( SECONDS - TOGGLE_START_TIME ))
  echo -e "\nGateway has been successfully STOPPED in ${ELAPSED} seconds."
else
  echo -e "\n=============================================="
  echo "Gateway is STOPPED. Starting it now..."
  echo -e "==============================================\n"

  # 1. Prevent host exit-node deadlock during VM / Container startup
  disconnect_tailscale_host

  # 3. Boot Colima VM if it is not already running
  echo -e "\nChecking Colima VM status..."
  if ! run_with_timeout 15 colima status >> output.log 2>&1; then
    echo "Colima is not running. Starting Colima (512MB RAM allocation, vz VM, network address)..."
    run_with_timeout 120 colima start --memory 0.5 --vm-type vz --network-address
  else
    echo "Colima is already running."
  fi
  # 3b. Configure swap file inside the VM to prevent OOM on low-memory limits
  # We also set vm.swappiness=10 so the Linux kernel strictly prefers physical RAM
  # and avoids unnecessarily wearing out the SSD with proactive background swapping.
  if ! run_with_timeout 15 colima ssh -- grep -q 'swapfile' /proc/swaps >> output.log 2>&1; then
    echo "Configuring 512MB swap file inside the VM to prevent OOM..."
    run_with_timeout 30 colima ssh -- sudo sh -c "if [ ! -f /swapfile ]; then dd if=/dev/zero of=/swapfile bs=1M count=512 status=none && chmod 600 /swapfile && mkswap /swapfile; fi && swapon /swapfile && sysctl vm.swappiness=10" >> output.log 2>&1 || echo "Warning: Failed to enable swap file inside the VM."
  fi

  # 4. Clean up corrupted AdGuardHome configurations
  if [ -f "adguard/conf/AdGuardHome.yaml" ] && [ ! -s "adguard/conf/AdGuardHome.yaml" ]; then
    rm -f "adguard/conf/AdGuardHome.yaml"
    echo "Removed corrupted empty AdGuardHome.yaml to prevent container crash loop."
  fi

  # 4b. Auto-heal stale Docker socket from hard reboots
  if ! run_with_timeout 15 docker ps >/dev/null 2>&1; then
    echo "Docker daemon is unresponsive (likely a stale socket from a crash). Auto-healing Colima..."
    run_with_timeout 120 colima restart >> output.log 2>&1
  fi

  # 5. Start compose services
  echo -e "\nStarting Docker containers..."
  docker compose up -d
  
  # Clean up the one-off rule compiler container so it doesn't clutter the Docker UI
  docker compose rm -s -f rule-compiler >> output.log 2>&1

  # 6. Wait for the gateway container's Tailscale connection to be ready
  BYPASS_PING=$(grep -E "^GATEWAY_BYPASS_PING=" .env 2>> output.log | cut -d'=' -f2- | tr -d '"'\' | tr '[:upper:]' '[:lower:]')
  USE_EXIT_NODE=$(grep -E "^GATEWAY_USE_EXIT_NODE=" .env 2>> output.log | cut -d'=' -f2- | tr -d '"'\' | tr '[:upper:]' '[:lower:]')

  echo "Waiting for gateway container's Tailscale to connect to the tailnet..."
  echo "  (This can take 30-60s — Tailscale goes through: NoState → Starting → Running → Online)"
  connected=false
  consecutive_failures=0
  for i in {1..60}; do
    # Run tailscale status and capture its output so the user can see what's happening.
    # Previously this was hidden behind 2>> output.log, making it impossible to debug hangs.
    ts_output=$(run_with_timeout 5 docker compose exec -T tailscale tailscale status 2>&1 || true)
    
    if echo "$ts_output" | grep -q "offers exit node"; then
      connected=true
      break
    fi
    
    # Track consecutive failures to detect a stuck state.
    # If we see 40+ consecutive 'NoState' responses, give up early —
    # the daemon is alive but can't connect to the coordination server.
    if echo "$ts_output" | grep -q "NoState"; then
      consecutive_failures=$((consecutive_failures + 1))
      if [ "$consecutive_failures" -ge 40 ]; then
        echo ""
        echo "  [attempt $i/60] Stuck in 'NoState' for $consecutive_failures checks."
        echo "    Tailscale daemon is running but can't reach the coordination server."
        break
      fi
    else
      consecutive_failures=0
    fi
    
    # Print a condensed status every 10 seconds so the user can see progress
    if [ $((i % 10)) -eq 0 ]; then
      ts_short=$(echo "$ts_output" | head -1 | tr -d '\r\n')
      echo "  [attempt $i/60] $ts_short"
    elif [ $((i % 5)) -eq 0 ]; then
      echo -n "[$i]"
    else
      echo -n "."
    fi
    sleep 1
  done
  echo ""

  if [ "$connected" = "true" ]; then
    echo "Gateway container is online on the Tailscale mesh."
  elif [ "$BYPASS_PING" = "true" ]; then
    echo "[Warning] Gateway container check timed out. Proceeding anyway (GATEWAY_BYPASS_PING is true)..."
  else
    echo "ERROR: Gateway container failed to initialize Tailscale (timed out after 60s)." >&2
    echo "  The container was seen in the following states during the wait:" >&2
    echo "$ts_output" | sed 's/^/    /' >&2
    echo "" >&2
    echo "  This could mean:" >&2
    echo "    1. Tailscale auth key has expired — check TS_AUTHKEY in .env" >&2
    echo "    2. Network issue inside the container — check: docker compose logs tailscale" >&2
    echo "    3. gluetun VPN tunnel not connecting — check: docker compose logs warp | tail -20" >&2
    echo "" >&2
    echo "  Diagnose manually:" >&2
    echo "    docker compose exec -T tailscale tailscale status" >&2
    echo "    docker compose exec -T tailscale tailscale netcheck" >&2
    cleanup_handler ERR $LINENO
    exit 1
  fi

  # 6b. Resolve the gateway's Tailscale IP.
  # Primary: static ADGUARD_IP.txt (fast, no docker-exec dependency).
  # Fallback: dynamic query from the container (handles IP changes after re-auth).
  #
  # CRITICAL: `docker compose exec -T` on macOS/Colima injects carriage
  # returns (\r) into captured output. If $TS_IP ends with \r, then
  # `networksetup -setdnsservers` silently rejects the malformed IP and
  # DNS stays at 1.1.1.1 — the primary bug this project was hitting.
  # `tr -d '\r'` strips the CR; `awk 'NR==1{print $1; exit}'` takes only
  # the first field of the first line (preserving the old `head -1` guard).
  TS_IP=""
  TS_IP=$(cat ADGUARD_IP.txt 2>> output.log | tr -d '\r' | awk 'NR==1{print $1; exit}' || true)
  if [ -n "$TS_IP" ]; then
    echo "Using static IP from ADGUARD_IP.txt: $TS_IP"
  elif [ "$connected" = "true" ]; then
    TS_IP=$(run_with_timeout 10 docker compose exec -T tailscale tailscale ip -4 2>> output.log | tr -d '\r' | awk 'NR==1{print $1; exit}' || true)
    if [ -n "$TS_IP" ]; then
      echo "[Fallback] Resolved gateway Tailscale IP dynamically: $TS_IP"
    fi
  fi

  # 7. Connect host Mac to Tailscale mesh.
  # With the standalone tailscaled daemon (registered as a per-user LaunchAgent or
  # system LaunchDaemon via 'brew services start tailscale'), the previous five-
  # phase flow collapses into two trivial CLI calls. There is no .app GUI to launch,
  # no menu bar item to click, and no Accessibility permission required.
  #
  # CRITICAL: If tailscaled is not running, `tailscale up` will silently fail.
  # We auto-start it before proceeding, and SKIP the rest of the Tailscale setup
  # if it can't be started (DNS hijack to a 100.x.x.x IP and exit-node routing
  # are impossible without the host on the mesh).
  #
  # We connect in two phases:
  #   Phase A — Join mesh WITHOUT exit node (so pre-flight checks can run)
  #   Phase B — Set exit node only after pre-flight checks confirm the gateway works
  HOST_ON_MESH=false
  SKIP_EXIT_NODE=false
  if [ -n "$TS_BIN" ]; then
    echo -n "Verifying tailscaled is reachable"
    daemon_ready=false
    for i in {1..10}; do
      # `tailscale status` returns exit code 1 when the daemon is alive but
      # disconnected ("Tailscale is stopped."). We check the daemon socket
      # directly as a fallback — if the socket exists, tailscaled is running
      # even if the host isn't connected to the mesh yet.
      if run_with_timeout 5 $TS_BIN status >> output.log 2>&1 || [ -S /var/run/tailscaled.socket ]; then
        daemon_ready=true
        break
      fi
      echo -n "."
      sleep 1
    done
    echo ""

    if [ "$daemon_ready" != "true" ]; then
      echo -e "\033[0;33m[!] tailscaled daemon is not running. Attempting to start it...\033[0m"
      
      # Try system-wide daemon (with timeout — sudo may prompt for password)
      if [ "$daemon_ready" != "true" ]; then
        if run_with_timeout 10 sudo brew services start tailscale 2>> output.log; then
          echo "  Started tailscaled as system LaunchDaemon."
          for i in {1..15}; do
            if run_with_timeout 5 $TS_BIN status >> output.log 2>&1; then
              daemon_ready=true
              break
            fi
            sleep 1
          done
        fi
      fi
    fi

    if [ "$daemon_ready" = "true" ]; then
      echo "tailscaled is responsive (running as a system service)."

      # ── Phase A: Join mesh without exit node ───────────────────────────
      echo "Connecting host to Tailscale mesh (no exit node yet)..."
      if $TS_BIN up --reset --accept-dns=false --exit-node=; then
        HOST_ON_MESH=true
        echo "Host is on Tailscale mesh."
      else
        echo -e "\033[0;33m[!] tailscale up failed even though the daemon is running.\033[0m"
        echo "  This usually means the host hasn't authenticated with your tailnet yet."
        echo "  Run this command in a terminal to authenticate:"
        echo ""
        echo "      sudo tailscale up"
        echo ""
        echo "  A browser will open. Log in to your Tailscale account, then re-run toggle.sh."
      fi
    else
      echo -e "\033[0;31m[!] tailscaled could NOT be started automatically.\033[0m"
      echo "  Run this in a terminal to start and authenticate Tailscale:"
      echo ""
      echo "      sudo brew services start tailscale"
      echo "      sudo tailscale up"
      echo ""
      echo "  Then re-run toggle.sh."
    fi
  else
    echo -e "\n[Warning] tailscale CLI not found on PATH. Skipping host Tailscale configuration..."
  fi

  # ── Phase B: Pre-flight checks + enable exit node only if safe ───────
  if [ "$HOST_ON_MESH" = "true" ] && [ "$USE_EXIT_NODE" != "false" ] && [ -n "$TS_IP" ]; then
    echo -e "\n──────────────────────────────────────────────"
    echo "Pre-flight connectivity check"
    echo "──────────────────────────────────────────────"
    
    # Check 1: Can we reach the gateway via Tailscale (uses tailscale ping, not ICMP)?
    # NOTE: tailscale ping exits 1 when the connection goes through a DERP relay
    # ("direct connection not established") even though the pong was received.
    # We check for 'pong' in the output (stderr discarded) to accept relayed connections.
    echo -n "  [1/3] Gateway reachable via Tailscale... "
    if $TS_BIN ping --until-direct=false -c 3 --timeout 5s "$TS_IP" 2>/dev/null | grep -q "pong"; then
      echo "PASS"
    else
      echo "FAIL"
      SKIP_EXIT_NODE=true
    fi
    
    # Check 2: Can we reach AdGuard via localhost (exposed port 5354)?
    # Colima's SSH tunnel only forwards TCP (not UDP), so we use +tcp.
    echo -n "  [2/3] AdGuard DNS via localhost... "
    if command -v dig &>/dev/null; then
      if dig +tcp @127.0.0.1 -p 5354 google.com +short +timeout=5 &>/dev/null; then
        echo "PASS"
      else
        echo "FAIL"
        SKIP_EXIT_NODE=true
      fi
    elif command -v nslookup &>/dev/null; then
      if nslookup -port=5354 google.com 127.0.0.1 &>/dev/null; then
        echo "PASS"
      else
        echo "FAIL"
        SKIP_EXIT_NODE=true
      fi
    else
      echo "SKIP (dig/nslookup not available)"
    fi
    
    # Check 3: Does the WARP container have external internet?
    echo -n "  [3/3] WARP container internet... "
    if docker compose exec -T warp wget -qO- --timeout=5 https://www.cloudflare.com/cdn-cgi/trace &>/dev/null; then
      echo "PASS"
    else
      echo "FAIL"
      SKIP_EXIT_NODE=true
    fi
    
    # Act based on check results
    if [ "$SKIP_EXIT_NODE" != "true" ]; then
      echo -e "\nAll checks passed. Enabling exit node $TS_IP..."
      if $TS_BIN up --reset --accept-dns=false --exit-node="$TS_IP" --exit-node-allow-lan-access=true; then
        echo "Exit node enabled."
      else
        echo "[Warning] Failed to set exit node."
        SKIP_EXIT_NODE=true
      fi
    fi
    
    if [ "$SKIP_EXIT_NODE" = "true" ]; then
      echo -e "\n\033[0;33m[!] Pre-flight checks failed — EXIT NODE + DNS HIJACK SKIPPED.\033[0m"
      echo "  Host stays on Tailscale mesh but your internet routes through your normal connection."
      echo "  Troubleshoot with:"
      echo "    docker compose logs warp | tail -20"
      echo "    docker compose exec -T warp wget -qO- --timeout=5 https://www.cloudflare.com/cdn-cgi/trace"
      echo ""
      echo "  Falling back to SOCKS5 proxy for traffic routing..."
    fi
  elif [ "$HOST_ON_MESH" = "true" ] && [ "$USE_EXIT_NODE" = "false" ]; then
    echo "USE_EXIT_NODE is false. Skipping exit node and DNS hijack."
    SKIP_EXIT_NODE=true
  fi

  # 8. Apply DNS Hijacking.
  # If exit node is enabled: hijack DNS to gateway's Tailscale IP (routes through tailnet).
  # Otherwise, leave DNS at 1.1.1.1 (already set by reset at the top).
  # AdGuard is also available at localhost:5354 for manual configuration in apps.
  if [ -n "$TS_IP" ] && [ "$HOST_ON_MESH" = "true" ] && [ "$SKIP_EXIT_NODE" != "true" ]; then
    echo -e "\nHijacking host DNS to point ONLY at AdGuard Home ($TS_IP)..."
    echo "Setting MagicDNS search domain 'ts.net' so tailnet hostnames resolve..."
    if force_dns_to_gateway "$TS_IP"; then
      echo "DNS hijack verified: single server = $TS_IP."
    else
      echo "[Warning] DNS hijack could not be verified."
      echo "  If DNS is broken, run manually:"
      echo "    networksetup -setdnsservers \"$ACTIVE_SERVICE\" $TS_IP"
      echo "    networksetup -setsearchdomains \"$ACTIVE_SERVICE\" ts.net"
    fi
  elif [ -n "$TS_IP" ]; then
    echo -e "\n[Info] Exit node not enabled (pre-flight checks failed)."
    echo "  Trying local DNS proxy for ad-blocking..."
    if start_local_dns_proxy; then
      echo "  Ad-blocking active via local DNS proxy through AdGuard."
    else
      echo "  Local DNS proxy unavailable. DNS stays at 1.1.1.1."
      echo "  AdGuard available at http://localhost:80 (port 5354 for DNS via TCP)."
    fi
    
    # Enable SOCKS5 proxy for traffic routing through WARP
    # (enabled whenever exit node is skipped, regardless of HOST_ON_MESH)
    echo -e "\n  Enabling SOCKS5 proxy for TCP traffic routing through gateway WARP tunnel..."
    echo "  (SOCKS5 proxy runs inside gateway container, routes through tun0 -> WARP)"
    enable_socks_proxy "$ACTIVE_SERVICE"

    # Verify the SOCKS5 proxy works through WARP
    echo -n "  Verifying SOCKS5 proxy routes through WARP... "
    if curl --socks5-hostname 127.0.0.1:$SOCKS_PROXY_PORT --max-time 10 -s https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q "warp=on"; then
      echo "ok (warp=on)."
      echo "  All TCP traffic now encrypted through Cloudflare WARP tunnel."
    else
      echo "FAILED (proxy not routing through WARP)."
      echo "  Disabling SOCKS5 proxy — internet stays on direct connection."
      disable_socks_proxy
      echo "  SOCKS proxy available at localhost:$SOCKS_PROXY_PORT for manual configuration."
    fi
  else
    echo -e "\n[Warning] Could not resolve gateway Tailscale IP."
  fi

  # 9. Verify host connectivity
  if [ "$HOST_ON_MESH" = "true" ] && [ -n "$TS_BIN" ]; then
    if run_with_timeout 5 $TS_BIN status >> output.log 2>&1; then
      echo "Host is online on the Tailscale mesh."
    else
      echo "[Warning] Host is not responding on Tailscale."
    fi
  fi

  ELAPSED=$(( SECONDS - TOGGLE_START_TIME ))
  echo -e "\nGateway has been successfully STARTED in ${ELAPSED} seconds."

  # Prevent system from going to sleep while gateway is running
  start_sleep_prevention
fi

SUCCESS_RUN=true

# Final DNS state summary
if [ -n "$ACTIVE_SERVICE" ]; then
  FINAL_DNS=$(networksetup -getdnsservers "$ACTIVE_SERVICE" 2>> output.log || true)
  echo -e "\n──────────────────────────────────────────────"
  echo -e "DNS STATE: $FINAL_DNS"
  echo -e "──────────────────────────────────────────────"
fi

echo -e "\nYou can close this terminal window now."
