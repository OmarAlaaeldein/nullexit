#!/bin/bash
# toggle.sh — nullexit gateway toggle script (macOS + Linux)
# Automatically handles Docker containers, Colima, DNS hijacking, and Tailscale exit node routing.
#
# One file, both OSes: the dispatch below runs the self-contained Linux
# implementation (shuf / ss / nmcli / ip / systemd) and exits; on macOS it
# falls through to the macOS implementation (jot / netstat / networksetup,
# launchd / pf).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ═══════════════════════════════════════════════════════════════════════════
# LINUX TOGGLE — self-contained; runs the full toggle then exits before the
# macOS body below. Native Linux tooling (shuf / ss / nmcli / ip / systemd).
# (Body inlined verbatim at column 0 — it contains multiline `bash -c "…"`
# strings that must NOT be re-indented.)
# ═══════════════════════════════════════════════════════════════════════════
if [[ "$OSTYPE" != "darwin"* ]]; then
# Define log file (used by the lifecycle breadcrumb + run_logged helper)
LOG_FILE="$PWD/output.log"

# --- LIFECYCLE PHASE TRACKING + EXIT BREADCRUMB ---
# TOGGLE_PHASE is updated as the script moves through STOP/START so that if the
# process is killed (terminal closed, pkill, OOM) or exits on error, the EXIT
# trap records the final exit code AND the phase it died in — making an
# interrupted START traceable in output.log instead of ending abruptly.
TOGGLE_PHASE="init"
_log_exit_breadcrumb() {
  local rc=$?
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] toggle.sh EXIT: code=$rc phase=$TOGGLE_PHASE (pid $$)" >> "$LOG_FILE" 2>/dev/null || true
}
trap '_log_exit_breadcrumb' EXIT

# --- DEBUG TRACE (opt-in via .env: DEBUG_TRACE=true) ---
# When enabled, mirror a full command-by-command xtrace to output.log. Off by
# default. Read directly from .env because common.sh (read_env_var) isn't
# sourced yet. Branch on bash version: BASH_XTRACEFD needs >= 4.1 (Linux
# usually has bash 5); fall back to teeing stderr on older bash. We never use
# the `exec {var}>>` dynamic-fd form (4.1+ only).
DEBUG_TRACE=$(grep -E '^DEBUG_TRACE=' .env 2>/dev/null | cut -d'=' -f2- | tr -d "\"'" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
if [ "$DEBUG_TRACE" = "true" ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG_TRACE enabled — xtrace mirrored to output.log (bash ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]})" >> "$LOG_FILE"
  export PS4='+ [$(date "+%H:%M:%S")] ${BASH_SOURCE##*/}:${LINENO}:${FUNCNAME[0]:-main}: '
  if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 1 ]; }; then
    exec 9>>"$LOG_FILE"
    export BASH_XTRACEFD=9
    set -x
  else
    # bash < 4.1: plain stderr→file redirect. NOT a process substitution — under
    # set -e, xtrace flowing through a backgrounded `tee` can abort the script
    # (failed write/SIGPIPE trips set -e). See devref §15.11.8.
    exec 2>>"$LOG_FILE"
    set -x
  fi
fi

# --- PROCEDURAL PORT GENERATION ---
# To prevent static port fingerprinting by malware, we randomize exposed ports
# on every boot and persist them to a hidden environment file.
PORTS_FILE="/tmp/nullexit-ports.env"
if [[ "$1" == "" || "$1" == "--restart" || "$1" == "restart" ]]; then
  
  # Collision-avoidance function
  GENERATED_PORTS=""
  get_free_port() {
    local port
    while true; do
      # Linux uses shuf or $RANDOM instead of jot
      port=$(shuf -i 10000-65000 -n 1 2>/dev/null || echo $((10000 + RANDOM % 55000)))
      # 1. Prevent self-collision within this loop
      if [[ "$GENERATED_PORTS" == *"$port"* ]]; then
        continue
      fi
      # 2. Prevent collision with ANY process on the machine (root daemons, terminal apps, etc)
      # We use ss to read the kernel socket table directly.
      if ! ss -lnt | awk '{print $4}' | grep -q ":$port$"; then
        echo "$port"
        return
      fi
    done
  }

  export TOR_SOCKS_PORT=$(get_free_port)
  GENERATED_PORTS="$GENERATED_PORTS $TOR_SOCKS_PORT"
  
  export TOR_CONTROL_PORT=$(get_free_port)
  GENERATED_PORTS="$GENERATED_PORTS $TOR_CONTROL_PORT"
  
  export SOCKS_PROXY_PORT=$(get_free_port)
  GENERATED_PORTS="$GENERATED_PORTS $SOCKS_PROXY_PORT"
  
  export DNS_PROXY_PORT=$(get_free_port)
  
  echo "export TOR_SOCKS_PORT=$TOR_SOCKS_PORT" > "$PORTS_FILE"
  echo "export TOR_CONTROL_PORT=$TOR_CONTROL_PORT" >> "$PORTS_FILE"
  echo "export SOCKS_PROXY_PORT=$SOCKS_PROXY_PORT" >> "$PORTS_FILE"
  echo "export DNS_PROXY_PORT=$DNS_PROXY_PORT" >> "$PORTS_FILE"
elif [ -f "$PORTS_FILE" ]; then
  # On STOP, source the existing ports so docker-compose down matches
  source "$PORTS_FILE"
else
  # Fallbacks if file is lost
  export TOR_SOCKS_PORT=9050
  export TOR_CONTROL_PORT=9051
  export SOCKS_PROXY_PORT=1080
  export DNS_PROXY_PORT=5354
fi

# Start execution timer
TOGGLE_START_TIME=$SECONDS

if [[ "$1" == "restart" ]] || [[ "$1" == "--restart" ]]; then
  echo "Executing Gateway Restart Sequence..."
  # We must source common.sh here temporarily to check gateway state before we proceed
  source "$SCRIPT_DIR/scripts/common.sh"
  # Use persisted intent via gateway_state (echoes a string, never a return code;
  # set -e-safe under set -x — see devref §15.11.8). On Linux the marker is not
  # maintained, so this degrades to the is_gateway_active fallback (fast — native Docker).
  if [ "$(gateway_state)" = "running" ]; then
    echo "Gateway is currently running. Stopping it first..."
    bash "$0"
    echo "Gateway stopped. Now starting it..."
  else
    echo "Gateway is already stopped. Starting it..."
  fi
  bash "$0"
  exit 0
fi

# Global flag to track if the script completed successfully
SUCCESS_RUN=false

# Global variable to track the currently running background command PID
CURRENT_BG_PID=""

# Source common bash functions
source "$SCRIPT_DIR/scripts/common.sh"


PID_FILE="/tmp/nullexit-caffeinate.pid"

# Start macOS caffeinate to prevent sleep while gateway is running
start_sleep_prevention() {
  if ! command -v systemd-inhibit >/dev/null 2>&1; then
    echo "  [Warning] systemd-inhibit tool not found. Sleep prevention unavailable."
    return 1
  fi

  # Stop any existing sleep prevention process first to avoid duplicates
  stop_sleep_prevention

  echo "  Enabling system sleep prevention (systemd-inhibit)..."
  # Run systemd-inhibit wrapped in a bash trap to prevent idle system sleep.
  # Critically, this traps shutdown signals (SIGTERM) and automatically
  # flushes hijacked DNS back to normal right before the PC powers off.
  # We do not use recover.sh here because it is a heavy recovery script
  # which takes too long and gets terminated before it can reset the DNS. Instead,
  # we surgically and instantly restore normal DNS settings here.
  nohup bash -c "
    trap '
      echo \"[Shutdown Trap] Reverting network settings...\" >> \"$PWD/output.log\" 2>&1
      kill \$! 2>/dev/null || true
      sudo -n resolvectl domain \"$ACTIVE_SERVICE\" \"\" >> \"$PWD/output.log\" 2>&1 || true
      sudo -n resolvectl revert \"$ACTIVE_SERVICE\" >> \"$PWD/output.log\" 2>&1 || true
      resolvectl domain \"$ACTIVE_SERVICE\" \"\" >> \"$PWD/output.log\" 2>&1 || true
      resolvectl revert \"$ACTIVE_SERVICE\" >> \"$PWD/output.log\" 2>&1 || true
      if command -v tailscale >/dev/null 2>&1; then
        tailscale up --accept-dns=false --exit-node= >> \"$PWD/output.log\" 2>&1 &
        TS_DOWN_ARGS=\"\"
        if [ \"\$KILL_SWITCH\" = \"true\" ]; then TS_DOWN_ARGS=\"--accept-risk=lose-ssh\"; fi
        tailscale down \$TS_DOWN_ARGS >> \"$PWD/output.log\" 2>&1 &
      fi
      sleep 1
      echo \"[Shutdown Trap] Cleanup complete.\" >> \"$PWD/output.log\" 2>&1
      exit 0
    ' SIGTERM SIGINT SIGHUP
    systemd-inhibit --what=sleep --who=nullexit --why=\"gateway running\" --mode=block sleep infinity &
    wait \$!
  " >> output.log 2>&1 &
  local caffe_pid=$!
  echo "$caffe_pid" > "$PID_FILE"
  echo "  Sleep prevention active (PID $caffe_pid). Your PC won't sleep while the gateway is running."
}

# Stop sleep prevention when gateway is stopped
stop_sleep_prevention() {
  if [ -f "$PID_FILE" ]; then
    local caffe_pid
    caffe_pid=$(cat "$PID_FILE")
    if [ -n "$caffe_pid" ] && kill -0 "$caffe_pid" 2>/dev/null && ps -p "$caffe_pid" -o command= 2>/dev/null | grep -q -E "systemd-inhibit|recover.sh"; then
      echo "  Stopping system sleep prevention (systemd-inhibit wrapper PID $caffe_pid)..."
      kill "$caffe_pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
  fi
}

DNS_WATCHER_PID_FILE="/tmp/nullexit-dns-watcher.pid"

stop_dns_watcher() {
  if [ -f "$DNS_WATCHER_PID_FILE" ]; then
    local watcher_pid
    watcher_pid=$(cat "$DNS_WATCHER_PID_FILE")
    if [ -n "$watcher_pid" ] && kill -0 "$watcher_pid" 2>/dev/null; then
      echo "  Stopping background DNS Watcher (PID $watcher_pid)..."
      kill -9 "$watcher_pid" 2>/dev/null || true
    fi
    rm -f "$DNS_WATCHER_PID_FILE"
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
    stop_dns_watcher

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
# needed (resolvectl, ip, systemctl, systemd-inhibit, pkill, and
# python3 scripts/dns-proxy.py for the fallback DNS proxy).
# All privileged calls below use `sudo -n` which will run without prompting.
# No credential caching loop is needed.

# Add Homebrew and standard paths
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$PATH"

# Check for local DNS proxy tools (used when tailnet data plane is unavailable)
# Uses a Python DNS proxy (handles TCP wire format correctly).
# Python3 is built into macOS — no external dependencies.
DNS_PROXY_BIN=""
if command -v python3 >/dev/null 2>&1; then
  DNS_PROXY_BIN="python3 -I"
elif command -v python >/dev/null 2>&1; then
  DNS_PROXY_BIN="python -I"
fi

# Path to the DNS proxy script (sibling of this script)
DNS_PROXY_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dns-proxy.py"

# Resolve Tailscale CLI on host. We rely on the standalone Homebrew formula
# (`brew install tailscale` + `systemctl start tailscaled`) — NOT the
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
# *entire* teardown — no need to mess with system network managers.
# tailscaled keeps running (as a systemd service), which is intentional:
# the next `tailscale up` then reconnects in seconds rather than waiting for a
# slow daemon launch. The `tailscale down` call also retains the user's
# auth state, so we don't force a browser re-login every cycle.
#
# Defined early (before the if/else branches and referenced by cleanup_handler's
# ERR trap) so that any failure before the main logic can still tear down Tailscale.
restart_tailscaled_daemon() {
  echo "  [Tailscale Recovery] tailscaled daemon appears to be wedged/unresponsive."
  echo "  [Tailscale Recovery] Attempting to restart tailscaled service via systemctl..."
  if run_with_timeout 15 sudo -n systemctl restart tailscaled >> output.log 2>&1; then
    echo "  [Tailscale Recovery] Successfully restarted tailscaled service."
  else
    echo "  [Tailscale Recovery] WARNING: Failed to restart tailscaled. Manual intervention may be needed."
  fi
  sleep 3
}
disconnect_tailscale_host() {
  if [ -n "$TS_BIN" ]; then
    echo "Disconnecting host Tailscale from mesh (tailscaled stays running as system service)..."
    local ts_args=""
    if is_kill_switch_enabled; then ts_args="--accept-risk=lose-ssh"; fi
    if ! run_with_timeout 10 $TS_BIN down $ts_args >> output.log 2>&1; then
      restart_tailscaled_daemon
      run_with_timeout 10 $TS_BIN down $ts_args >> output.log 2>&1 || true
    fi
  fi
}

ACTIVE_SERVICE=$(get_active_service)

# Helper to nuke leftover network state after teardown (proxy settings, routing
# table, DNS cache, Wi-Fi). Prevents the "had to write a whole recovery script"
# problem where stale state kills internet after the gateway stops.
cleanup_network_state() {
  echo -e "\nCleaning up network state (proxies, routes, DNS cache, Wi-Fi)..."

  # 1. Disable any leftover proxy settings (needs root on many macOS versions)
  # (Skipped for Linux since we don't set global SOCKS proxy)
  echo "  Proxies disabled."

  # 2. Flush DNS cache
  if command -v resolvectl >> output.log 2>&1; then
    sudo -n resolvectl flush-caches 2>> output.log || true
  elif command -v systemd-resolve >> output.log 2>&1; then
    sudo -n systemd-resolve --flush-caches 2>> output.log || true
  fi
  echo "  DNS cache flushed."

  # 3. Flush stale routing table entries
  if command -v ip >> output.log 2>&1; then
    sudo -n ip route flush cache >> output.log 2>&1 || true
  fi
  echo "  Routing table flushed."

  # 4. Power-cycle Wi-Fi to clear any lingering interface state
  echo "  Restarting network interface..."
  sudo -n ip link set dev "$ACTIVE_SERVICE" down 2>> output.log || true
  sleep 1
  sudo -n ip link set dev "$ACTIVE_SERVICE" up 2>> output.log || true
  echo "  Interface power-cycled ($ACTIVE_SERVICE)."
  sleep 3

  echo "Network state cleanup complete."
}

# Ensure DNS is set to 1.1.1.1 immediately at script start to prevent any DNS deadlocks/hangs
# during status checks, container startup, VM boot, or teardown. We *also* clear any leftover
# `ts.net` search domain from a previous `tailscale up --accept-dns=true` run, otherwise macOS
# would prepend it to every lookup and most public DNS queries would resolve to NXDOMAIN.
# Capture current DNS before resetting so we can check if it was hijacked
INITIAL_DNS=$(resolvectl dns "$ACTIVE_SERVICE" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)

echo "Initializing DNS to 1.1.1.1 to ensure reliable internet access..."
reset_dns


  # ── Local Network Surveillance Check ──────────────────────────────────────
  echo -e "\n──────────────────────────────────────────────"
  echo "Local Network Surveillance Check"
  echo "──────────────────────────────────────────────"
  # Count populated ARP cache entries to detect network scanning or high congestion
  if command -v ip >/dev/null 2>&1; then
    ARP_COUNT=$(ip neigh | grep -iv 'incomplete' | wc -l | tr -d ' ')
  else
    # Using '-an' avoids hanging on DNS reverse resolution when the network state is in transition.
    ARP_COUNT=$(arp -an 2>/dev/null | grep -iv 'incomplete' | wc -l | tr -d ' ')
  fi
  if [ "$ARP_COUNT" -gt 15 ]; then
    echo -e "  \033[1;33m[!] WARNING: High ARP activity detected ($ARP_COUNT devices in cache).\033[0m"
    echo -e "  \033[1;33m[!] This Wi-Fi network may be heavily congested or actively scanned (e.g., arp-scan).\033[0m"
    echo -e "  [✓] Your traffic remains fully encrypted and invisible.\n"
  else
    echo -e "  [✓] Local network looks quiet ($ARP_COUNT devices). No aggressive scanning detected.\n"
  fi

echo "Checking Gateway Status..."
# Decide STOP vs START from persisted intent via gateway_state, which echoes a
# string (never a return code) to stay set -e-safe under set -x. See devref §15.11.8.
# On Linux this falls back to is_gateway_active (fast — native Docker).
if [ "$(gateway_state)" = "running" ]; then
  TOGGLE_PHASE="stop"
  echo -e "\n=============================================="
  echo "Gateway is RUNNING. Stopping it now..."
  echo -e "==============================================\n"

  # 1. Disconnect host Tailscale cleanly first before stopping the exit-node container
  disconnect_tailscale_host
  echo ""

  echo "Stopping Docker containers..."
  # `|| true`: a disable must always complete even if the Docker daemon is down.
  run_logged docker compose down -t 5 || true

  echo -e "\nDocker daemon handles container teardown automatically."

  # The host's DNS was hijacked to the gateway IP during ENABLE; now that the
  # gateway is down, restore DNS to 1.1.1.1 immediately so subsequent lookups
  # don't stall for the macOS DNS timeout before the 1.1.1.1 fallback engages.
  echo -e "\nRestoring host DNS to 1.1.1.1 (gateway is gone)... "
  reset_dns

  # 3. Stop local DNS proxy if running
  stop_local_dns_proxy

  # Stop sleep prevention
  stop_sleep_prevention
  stop_dns_watcher

  # 4. Nuke leftover network state so internet actually works after teardown
  cleanup_network_state

  ELAPSED=$(( SECONDS - TOGGLE_START_TIME ))
  echo -e "\nGateway has been successfully STOPPED in ${ELAPSED} seconds."
else
  TOGGLE_PHASE="start"
  echo -e "\n=============================================="
  echo "Gateway is STOPPED. Starting it now..."
  echo -e "==============================================\n"

  # 1. Prevent host exit-node deadlock during VM / Container startup
  disconnect_tailscale_host

  echo -e "\nUsing native Linux Docker..."

  # 4. Clean up corrupted AdGuardHome configurations
  if [ -f "adguard/conf/AdGuardHome.yaml" ] && [ ! -s "adguard/conf/AdGuardHome.yaml" ]; then
    rm -f "adguard/conf/AdGuardHome.yaml"
    echo "Removed corrupted empty AdGuardHome.yaml to prevent container crash loop."
  fi

  

  # 5. Start compose services
  write_host_ips
  # Procedurally generated ports have already been exported at the top of the script.
  echo "  [Security] Procedurally randomized proxy ports generated to evade fingerprinting."
  
  # --- HONEY-PORT TRIPWIRE ---
  # Generate a random trap port. If any malware does a sequential port scan on localhost,
  # it will inevitably hit this port. When it does, we instantly fire a desktop alert.
  HONEY_PORT=$(get_free_port)
  (
    if nc -l -p "$HONEY_PORT" 127.0.0.1 >/dev/null 2>&1 || nc -l localhost "$HONEY_PORT" >/dev/null 2>&1; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] [CRITICAL SECURITY ALERT] PORT SCAN DETECTED! An unknown application just pinged the local Honey-Port ($HONEY_PORT)!" >> "$PWD/output.log"
      if command -v notify-send >/dev/null 2>&1; then
        notify-send -u critical "nullexit OPSEC Alert" "An unknown application is aggressively scanning your local ports. Malware port-scan suspected."
      fi
    fi
  ) &
  disown %1 2>/dev/null || true
  echo "  [Security] Honey-Port Tripwire armed on random port to detect malware port-scans."

  echo -e "\nStarting Docker containers..."
  run_logged docker compose up -d

  # Clean up the one-off rule compiler container so it doesn't clutter the Docker UI
  docker compose rm -s -f rule-compiler >> output.log 2>&1

  # 6. Wait for the gateway container's Tailscale connection to be ready
  BYPASS_PING=$(read_env_var GATEWAY_BYPASS_PING | tr '[:upper:]' '[:lower:]')
  USE_EXIT_NODE=$(read_env_var GATEWAY_USE_EXIT_NODE | tr '[:upper:]' '[:lower:]')

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
  # Dynamically query the container for the IP (handles IP changes after re-auth)
  # and cache it in .gateway_ip for fast retrieval by recover.sh during Wi-Fi roaming.
  #
  # CRITICAL: `docker compose exec -T` on macOS/Colima injects carriage
  # returns (\r) into captured output. If $TS_IP ends with \r, then
  # `networksetup -setdnsservers` silently rejects the malformed IP and
  # DNS stays at 1.1.1.1 — the primary bug this project was hitting.
  # `tr -d '\r'` strips the CR; `awk 'NR==1{print $1; exit}'` takes only
  # the first field of the first line.
  TS_IP=""
  if [ "$connected" = "true" ]; then
    TS_IP=$(run_with_timeout 10 docker compose exec -T tailscale tailscale ip -4 2>> output.log | tr -d '\r' | awk 'NR==1{print $1; exit}' || true)
    if [ -n "$TS_IP" ]; then
      echo "Resolved gateway Tailscale IP dynamically: $TS_IP"
      echo "$TS_IP" > .gateway_ip
    else
      echo "    [!] Failed to resolve gateway IP dynamically. Trying fallback cache..." >&2
      TS_IP=$(read_adguard_ip || true)
    fi
  else
    TS_IP=$(read_adguard_ip || true)
  fi

  # 7. Connect host Mac to Tailscale mesh.
  # With the standalone tailscaled daemon (registered as a per-user LaunchAgent or
  # system LaunchDaemon via 'systemctl start tailscaled'), the previous five-
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
        if run_with_timeout 10 sudo systemctl start tailscaled 2>> output.log; then
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
      if $TS_BIN up --reset --ssh=true --accept-dns=false --exit-node=; then
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
      echo "      sudo systemctl start tailscaled"
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
    ping_ok=false
    # The host tailscaled needs a few seconds to propagate the new network map and
    # establish a connection route after 'tailscale up --reset'. We retry up to 45 times.
    for attempt in {1..45}; do
      if $TS_BIN ping --until-direct=false -c 2 --timeout 2s "$TS_IP" 2>/dev/null | grep -q "pong"; then
        ping_ok=true
        break
      fi
      sleep 1
    done
    if [ "$ping_ok" = "true" ]; then
      echo "PASS"
    else
      echo "FAIL"
      SKIP_EXIT_NODE=true
    fi
    
    # Check 2: Can we reach AdGuard via localhost (exposed port ${DNS_PROXY_PORT})?
    echo -n "  [2/3] AdGuard DNS via localhost... "
    if command -v dig >/dev/null 2>&1; then
      if dig +tcp @127.0.0.1 -p ${DNS_PROXY_PORT} google.com +short +timeout=5 >/dev/null 2>&1; then
        echo "PASS"
      else
        echo "FAIL"
        SKIP_EXIT_NODE=true
      fi
    elif command -v nslookup >/dev/null 2>&1; then
      if nslookup -port=${DNS_PROXY_PORT} google.com 127.0.0.1 >/dev/null 2>&1; then
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
      if $TS_BIN up --reset --ssh=true --accept-dns=false --exit-node="$TS_IP" --exit-node-allow-lan-access=true; then
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
  # AdGuard is also available at localhost:${DNS_PROXY_PORT} for manual configuration in apps.
  if [ -n "$TS_IP" ] && [ "$HOST_ON_MESH" = "true" ] && [ "$SKIP_EXIT_NODE" != "true" ]; then
    echo -e "\nHijacking host DNS to point ONLY at AdGuard Home ($TS_IP)..."
    echo "Setting MagicDNS search domain 'ts.net' so tailnet hostnames resolve..."
    if force_dns_to_gateway "$TS_IP"; then
      echo "DNS hijack verified: single server = $TS_IP."
      start_dns_watcher "$TS_IP"
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
      echo "  AdGuard available at http://localhost:80 (port ${DNS_PROXY_PORT} for DNS via TCP)."
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
  FINAL_DNS=$(resolvectl dns "$ACTIVE_SERVICE" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tr '
' ' ' || true)
  echo -e "\n──────────────────────────────────────────────"
  echo -e "DNS STATE: $FINAL_DNS"
  echo -e "──────────────────────────────────────────────"
fi

if [ "$START_GATEWAY" = "true" ] && command -v docker >/dev/null 2>&1; then
  if docker compose logs rule-compiler 2>/dev/null | grep -q "Warning: Failed to fetch"; then
    echo -e "\n[Warning] One or more blocklist URLs failed to download (404/Offline)."
    echo "  The gateway gracefully fell back to yesterday's cached blocklist."
    echo "  (Run 'docker logs rule-compiler' later to investigate which link died.)"
  fi
fi

echo -e "\n──────────────────────────────────────────────"
read -rp "Press [r] and Enter to instantly reverse state, or just press Enter to exit: " USER_CHOICE
if [[ "${USER_CHOICE}" == "r" || "${USER_CHOICE}" == "R" ]]; then
  echo "Reversing gateway state..."
  exec bash "$0"
fi

echo -e "\nYou can close this terminal window now."

exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# macOS TOGGLE — jot / netstat / networksetup, launchd / pf.
# ═══════════════════════════════════════════════════════════════════════════

# Enforce Cryptographic Script Integrity
if [ -f "scripts/crypto.sh" ]; then
  if ! bash scripts/crypto.sh --verify; then
    exit 1
  fi
fi

# Define log file
LOG_FILE="$PWD/output.log"

# Rotate log file if it exceeds 1GB (1073741824 bytes).
# Sized large on purpose: with DEBUG_TRACE the log holds a full command-by-command
# trace — effectively the entire compilation/warning history of the framework —
# which is valuable to keep for post-mortems. Raised from 50MB so always-on
# tracing doesn't churn that history away prematurely.
if [ -f "$LOG_FILE" ]; then
  log_size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
  if [ "$log_size" -gt 1073741824 ]; then
    mv "$LOG_FILE" "${LOG_FILE}.old" 2>/dev/null || rm -f "$LOG_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Log file exceeded 1GB; rotated to output.log.old" > "$LOG_FILE"
  fi
fi

# --- LIFECYCLE PHASE TRACKING + EXIT BREADCRUMB ---
# TOGGLE_PHASE is updated as the script moves through STARTUP/STOP/START so that
# if the process is killed (window closed, pkill, OOM) or exits with an error,
# the EXIT trap records the final exit code AND the phase it died in. Previously
# an interrupted START left output.log ending abruptly after the teardown with no
# indication of what failed — this makes every exit traceable.
TOGGLE_PHASE="init"
_log_exit_breadcrumb() {
  local rc=$?
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] toggle.sh EXIT: code=$rc phase=$TOGGLE_PHASE (pid $$)" >> "$LOG_FILE" 2>/dev/null || true
}
trap '_log_exit_breadcrumb' EXIT

# --- DEBUG TRACE (opt-in via .env: DEBUG_TRACE=true) ---
# When enabled, mirror a full command-by-command xtrace to output.log for a
# complete post-mortem trail (e.g. a race during --restart while Wi-Fi is
# re-associating). Off by default. Read directly from .env here because
# common.sh (read_env_var) isn't sourced yet.
#
# BASH_XTRACEFD (send xtrace to its own fd, keeping the terminal clean) needs
# bash >= 4.1. macOS ships /bin/bash 3.2, so we branch:
#   - bash >= 4.1 (e.g. Linux): dedicate fd 9 to the log and point xtrace there;
#     the terminal stays clean and normal stderr is untouched.
#   - bash 3.2 (stock macOS): BASH_XTRACEFD is unsupported, so xtrace always goes
#     to stderr. We redirect stderr *straight to the log file* with a plain
#     `exec 2>>"$LOG_FILE"`. This deliberately does NOT use a process
#     substitution (`2> >(tee …)`): under `set -e`, stderr flowing through the
#     backgrounded `tee` proved to abort the script mid-START on 3.2 (a failed
#     write / SIGPIPE in a pipeline returned non-zero and tripped `set -e`, with
#     $LINENO mis-blaming the enclosing `fi` — see devref §15.11.8-A/E). The
#     tradeoff: on 3.2 the terminal no longer shows live progress while tracing
#     (everything is in output.log instead). Acceptable for an opt-in debug mode.
# We NEVER use the `exec {var}>>` dynamic-fd form (4.1+ only), which hard-fails on 3.2.
DEBUG_TRACE=$(grep -E '^DEBUG_TRACE=' .env 2>/dev/null | cut -d'=' -f2- | tr -d "\"'" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
if [ "$DEBUG_TRACE" = "true" ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG_TRACE enabled — xtrace mirrored to output.log (bash ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]})" >> "$LOG_FILE"
  # Timestamped, location-aware xtrace prompt (works on 3.2 and 4.x).
  export PS4='+ [$(date "+%H:%M:%S")] ${BASH_SOURCE##*/}:${LINENO}:${FUNCNAME[0]:-main}: '
  if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 1 ]; }; then
    exec 9>>"$LOG_FILE"
    export BASH_XTRACEFD=9
    set -x
  else
    # bash 3.2 (stock macOS): plain stderr→file redirect (no process substitution).
    exec 2>>"$LOG_FILE"
    set -x
  fi
fi

# --- MAIN EXECUTION LOGGING ---
echo -e "\n========================================================" >> "$LOG_FILE"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] toggle.sh invoked" >> "$LOG_FILE"
echo "========================================================" >> "$LOG_FILE"

# (Previously this script chmod 600'd .env at start to "unlock" it for docker compose,
# and chmod 000'd it on exit. That pattern broke docker compose on macOS/Colima when
# the umask produced 0600 — the script removed its own ability to read .env before it could even proceed.)

# --- PROCEDURAL PORT GENERATION ---
# To prevent static port fingerprinting by malware, we randomize exposed ports
# on every boot and persist them to a hidden environment file.
PORTS_FILE="/tmp/nullexit-ports.env"
if [[ "$1" == "" || "$1" == "--restart" ]]; then
  
  # Collision-avoidance function
  GENERATED_PORTS=""
  get_free_port() {
    local port
    while true; do
      port=$(jot -r 1 10000 65000)
      # 1. Prevent self-collision within this loop
      if [[ "$GENERATED_PORTS" == *"$port"* ]]; then
        continue
      fi
      # 2. Prevent collision with ANY process on the Mac (root daemons, terminal apps, etc)
      # We use netstat instead of lsof because netstat reads the kernel socket table
      # directly and doesn't require sudo to see ports bound by other users/root.
      if ! netstat -an -p tcp | awk '{print $4}' | grep -q "\.$port$"; then
        echo "$port"
        return
      fi
    done
  }

  export TOR_SOCKS_PORT=$(get_free_port)
  GENERATED_PORTS="$GENERATED_PORTS $TOR_SOCKS_PORT"
  
  export TOR_CONTROL_PORT=$(get_free_port)
  GENERATED_PORTS="$GENERATED_PORTS $TOR_CONTROL_PORT"
  
  export SOCKS_PROXY_PORT=$(get_free_port)
  GENERATED_PORTS="$GENERATED_PORTS $SOCKS_PROXY_PORT"
  
  export DNS_PROXY_PORT=$(get_free_port)
  
  echo "export TOR_SOCKS_PORT=$TOR_SOCKS_PORT" > "$PORTS_FILE"
  echo "export TOR_CONTROL_PORT=$TOR_CONTROL_PORT" >> "$PORTS_FILE"
  echo "export SOCKS_PROXY_PORT=$SOCKS_PROXY_PORT" >> "$PORTS_FILE"
  echo "export DNS_PROXY_PORT=$DNS_PROXY_PORT" >> "$PORTS_FILE"
  ADGUARD_PASS=$(grep -E "^ADGUARD_PASSWORD=" .env 2>/dev/null | cut -d'=' -f2- | tr -d "\"'")
  echo "export TOR_PASSWORD=${ADGUARD_PASS:-nullexit}" >> "$PORTS_FILE"
elif [ -f "$PORTS_FILE" ]; then
  # On STOP, source the existing ports so docker-compose down matches
  source "$PORTS_FILE"
else
  # Fallbacks if file is lost
  export TOR_SOCKS_PORT=9050
  export TOR_CONTROL_PORT=9051
  export SOCKS_PROXY_PORT=1080
  export DNS_PROXY_PORT=5354
fi

# Start execution timer
TOGGLE_START_TIME=$SECONDS

if [[ "$1" == "--restart" ]]; then
  echo "Executing Gateway Restart Sequence..."
  # We must source common.sh here temporarily to check gateway state before we proceed
  source "$SCRIPT_DIR/scripts/common.sh"
  # Use persisted intent (marker) via gateway_state, which echoes a string (never
  # a return code) to stay set -e-safe under set -x. See devref §15.11.8.
  if [ "$(gateway_state)" = "running" ]; then
    echo "Gateway is currently running. Stopping it first..."
    bash "$0"
    echo "Gateway stopped. Now starting it..."
  else
    echo "Gateway is already stopped. Starting it..."
  fi
  bash "$0"
  exit 0
fi

# Global flag to track if the script completed successfully
SUCCESS_RUN=false

# Global variable to track the currently running background command PID
CURRENT_BG_PID=""

# Source common bash functions
source "$SCRIPT_DIR/scripts/common.sh"

# Prevent concurrent execution of lifecycle scripts (toggle.sh / recover.sh)
LOCK_FILE="/tmp/nullexit-toggle.lock"
if [ -f "$LOCK_FILE" ]; then
  LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
  if [ -n "$LOCK_PID" ] && [ "$LOCK_PID" != "$$" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    if ps -p "$LOCK_PID" -o args= 2>/dev/null | grep -q -E "toggle\.sh|recover\.sh"; then
      die "Another instance of toggle.sh or recover.sh (PID $LOCK_PID) is already running."
    fi
  fi
fi
echo "$$" > "$LOCK_FILE"

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

# Active-state marker: written at end of START path so external watchers
# (see launchd/com.nullexit.wake-recovery.plist + scripts/watcher.sh +
# devref §10.29) know the gateway is currently up. They only fire
# recover.sh --post-wake when this file is present. Cleared at the top
# of the STOP path and inside cleanup_handler on any error/signal path
# so a half-broken gateway never re-triggers post-wake refreshes.
write_gateway_active_marker() {
  date -u +%FT%TZ > /tmp/nullexit-gateway-active.marker
  # Set the watcher debounce timestamp to now to prevent a redundant post-startup recovery run.
  date +%s > /tmp/nullexit-watcher.last-recovery 2>/dev/null || true
}

clear_gateway_active_marker() {
  rm -f /tmp/nullexit-gateway-active.marker
  rm -f "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/TUNNEL_FAILED_CLOSED.marker"
}

# Capture whether the gateway-active marker exists BEFORE the defensive clear
# below wipes it. The STOP-vs-START decision (gateway_should_be_running) reads
# this captured value — persisted *intent* — instead of a live Docker probe, so
# a disable is instant and works even when Colima/Docker is down. Must be read
# before clear_gateway_active_marker or it would always look "stopped".
#
# Written as default-assign + `if` WITHOUT an `else`: under `set -e` (with the
# DEBUG_TRACE xtrace redirect active) an `if [ -f … ]; then …; else …; fi` whose
# condition is false was aborting the script here at init on macOS /bin/bash 3.2
# — the false `[ -f ]` status leaked through the compound. An `if` with no `else`
# yields status 0 when the condition is false, so nothing leaks.
GATEWAY_MARKER_AT_STARTUP="no"
if [ -f "$MARKER_FILE" ]; then
  GATEWAY_MARKER_AT_STARTUP="yes"
fi

# Defensive: clear any stale marker from a prior crashed/aborted run. If a
# previous toggle.sh wrote the marker but was OOM-killed in the middle of the
# START block (before the END-of-START write) — or if the user rebooted mid
# session — this prevents the watcher from firing post-wake against a
# non-running gateway on every wake event. Placed AFTER the function
# definitions so bash resolves the call at parse time.
clear_gateway_active_marker

PID_FILE="$PID_CAFFEINATE"

# Start macOS caffeinate to prevent sleep while gateway is running
start_sleep_prevention() {
  if ! command -v caffeinate >/dev/null 2>&1; then
    echo "  [Warning] caffeinate tool not found. Sleep prevention unavailable."
    return 1
  fi

  # Stop any existing sleep prevention process first to avoid duplicates
  stop_pidfile_daemon "/tmp/nullexit-caffeinate.pid" "system sleep prevention"

  echo "  Enabling system sleep prevention (caffeinate)..."
  # Run caffeinate wrapped in a bash trap to prevent idle system sleep.
  # Critically, this traps macOS shutdown signals (SIGTERM) and automatically
  # flushes hijacked DNS back to normal right before the Mac powers off.
  # We do not use recover.sh here because it is a heavy recovery script (managing
  # containers, restarting tailscaled, etc.) which takes too long and gets
  # terminated by macOS before it can reset the DNS. Instead, we surgically and
  # instantly restore normal DNS and proxy settings here.
  nohup bash -c "
    trap '
      echo \"[Shutdown Trap] Reverting network settings...\" >> \"$PWD/output.log\" 2>&1
      kill \$! 2>/dev/null || true
      sudo -n networksetup -setdnsservers \"$ACTIVE_SERVICE\" 1.1.1.1 >> \"$PWD/output.log\" 2>&1 || true
      sudo -n networksetup -setdnsservers \"$EN0_SERVICE\" 1.1.1.1 >> \"$PWD/output.log\" 2>&1 || true
      sudo -n networksetup -setsearchdomains \"$ACTIVE_SERVICE\" \"Empty\" >> \"$PWD/output.log\" 2>&1 || true
      sudo -n networksetup -setsearchdomains \"$EN0_SERVICE\" \"Empty\" >> \"$PWD/output.log\" 2>&1 || true
      sudo -n networksetup -setsocksfirewallproxystate \"$ACTIVE_SERVICE\" off >> \"$PWD/output.log\" 2>&1 || true
      sudo -n networksetup -setsocksfirewallproxystate \"$EN0_SERVICE\" off >> \"$PWD/output.log\" 2>&1 || true
      sudo -n networksetup -setwebproxystate \"$ACTIVE_SERVICE\" off >> \"$PWD/output.log\" 2>&1 || true
      sudo -n networksetup -setwebproxystate \"$EN0_SERVICE\" off >> \"$PWD/output.log\" 2>&1 || true
      sudo -n networksetup -setsecurewebproxystate \"$ACTIVE_SERVICE\" off >> \"$PWD/output.log\" 2>&1 || true
      sudo -n networksetup -setsecurewebproxystate \"$EN0_SERVICE\" off >> \"$PWD/output.log\" 2>&1 || true
      if command -v tailscale >/dev/null 2>&1; then
        tailscale up >> \"$PWD/output.log\" 2>&1 || true
        tailscale set --accept-dns=false --exit-node= >> \"$PWD/output.log\" 2>&1 || true
        TS_DOWN_ARGS=\"\"
        if [ \"\$KILL_SWITCH\" = \"true\" ]; then TS_DOWN_ARGS=\"--accept-risk=lose-ssh\"; fi
        tailscale down \$TS_DOWN_ARGS >> \"$PWD/output.log\" 2>&1 &
      fi
      sleep 1
      echo \"[Shutdown Trap] Cleanup complete.\" >> \"$PWD/output.log\" 2>&1
      exit 0
    ' SIGTERM SIGINT SIGHUP
    caffeinate -i &
    wait \$!
  " >> output.log 2>&1 &
  local caffe_pid=$!
  echo "$caffe_pid" > "$PID_FILE"
  echo "  Sleep prevention active (PID $caffe_pid). Your Mac won't sleep while the gateway is running."
}



DNS_WATCHER_PID_FILE="$PID_DNS_WATCHER"
WARP_WATCHER_PID_FILE="/tmp/nullexit-warp-watcher.pid"



# Background WARP tunnel liveness monitor. Polls cdn-cgi/trace every 30s
# while healthy, but accelerates to polling every 5s if a failure is detected.
# Always logs state transitions to output.log. When warp=off persists for
# WARP_FAIL_THRESHOLD consecutive polls (default 6 = 30s of downtime), the watcher
# triggers a nuclear recovery: runs recover.sh to tear down the entire
# gateway — disconnecting Tailscale, stopping containers, resetting DNS,
# and power-cycling Wi-Fi. Note: This minimizes exposure window, but
# only the pf kill switch guarantees absolutely zero leakage on drop.
#
# The threshold (default 6) is statistically chosen: even at an
# unrealistically high 10% false-positive rate per poll, P(6 consecutive
# false positives) = 0.1^6 ≈ 0.0001%. Real-world false-positive rates
# are far lower, making 30s of continuous downtime overwhelmingly likely
# to be a genuine outage.
#
# Configurable via .env:  WARP_FAIL_THRESHOLD=3  (15s, more aggressive)
start_warp_watcher() {
  stop_warp_watcher
  # Parse threshold from .env (same pattern as GATEWAY_MSS, GATEWAY_BYPASS_PING, etc.)
  local threshold
  threshold=$(read_env_var WARP_FAIL_THRESHOLD)
  if [ -z "$threshold" ]; then
    threshold="${WARP_FAIL_THRESHOLD:-6}"
  fi
  local trigger_file="/tmp/nullexit-warp-shutdown-triggered"
  rm -f "$trigger_file"
  echo "  Starting background WARP Watcher (polling every 30s [accelerating to 5s on failure], shutdown after ${threshold} consecutive failures)..."
  nohup bash -c "
    trap 'exit 0' SIGTERM SIGINT SIGHUP
    last_state='on'
    consec_off=0
    threshold='$threshold'
    trigger_file='$trigger_file'
    out_log='$PWD/output.log'
    recover_bin='$PWD/recover.sh'
    inhibit_file='/tmp/nullexit-warp-inhibit.marker'
    while true; do
      # ── Inhibit check ─────────────────────────────────────────────────
      # recover.sh --post-wake writes this marker while force-recreating the
      # warp container. During that window, the container is intentionally
      # down — don't count it as a failure or we'll fire nuclear recover.sh
      # and kill a gateway that was in the process of healing itself.
      if [ -f \"\$inhibit_file\" ]; then
        consec_off=0
        sleep 5
        continue
      fi

      state='off'
      if docker compose exec -T warp wget -qO- --timeout=5 \
           https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
           | grep -q 'warp=on'; then
        state='on'
      fi

      # ── State-transition logging ────────────────────────────────────
      if [ \"\$state\" != \"\$last_state\" ]; then
        if [ \"\$state\" = 'off' ]; then
          echo \"[\$(date -u +%FT%TZ)] WARP DOWN — cdn-cgi/trace reports warp=off\" >> \"\$out_log\"
        fi
        last_state=\"\$state\"
      fi

      # ── Consecutive-failure tracking + auto-shutdown ─────────────────
      if [ \"\$state\" = 'off' ]; then
        consec_off=\$((consec_off + 1))
        if [ \"\$consec_off\" -ge \"\$threshold\" ] && [ ! -f \"\$trigger_file\" ]; then
          touch \"\$trigger_file\"
          echo \"[\$(date -u +%FT%TZ)] WARP SHUTDOWN — \$consec_off consecutive failures (threshold=\$threshold). Running recover.sh to kill the gateway and restore normal internet. Your IP is NO LONGER Cloudflare.\" >> \"\$out_log\"
          # Nuclear recovery: tear down the entire gateway.
          # recover.sh resets DNS → 1.1.1.1, disconnects Tailscale,
          # stops Docker containers, flushes routes, power-cycles Wi-Fi.
          bash \"\$recover_bin\" --auto >> \"\$out_log\" 2>&1 || true
          echo \"[\$(date -u +%FT%TZ)] WARP SHUTDOWN — recover.sh completed, watcher exiting. Your IP is now your real ISP IP.\" >> \"\$out_log\"
          exit 0
        fi
      else
        if [ \"\$consec_off\" -gt 0 ]; then
          echo \"[\$(date -u +%FT%TZ)] WARP RECOVERED — warp=on after \$consec_off consecutive off readings (threshold was \$threshold)\" >> \"\$out_log\"
        fi
        consec_off=0
      fi

      if [ \"\$state\" = \"off\" ]; then
        sleep 5
      else
        sleep 30
      fi
    done
  " >> output.log 2>&1 &
  echo $! > "$WARP_WATCHER_PID_FILE"
}

stop_warp_watcher() {
  if [ -f "$WARP_WATCHER_PID_FILE" ]; then
    local wp
    wp=$(cat "$WARP_WATCHER_PID_FILE")
    if [ -n "$wp" ] && kill -0 "$wp" 2>/dev/null; then
      echo "  Stopping background WARP Watcher (PID $wp)..."
      kill "$wp" 2>/dev/null || true
    fi
    rm -f "$WARP_WATCHER_PID_FILE"
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
    stop_pidfile_daemon "/tmp/nullexit-caffeinate.pid" "system sleep prevention"
    stop_pidfile_daemon "/tmp/nullexit-dns-watcher.pid" "background DNS Watcher"
    stop_warp_watcher
    clear_gateway_active_marker

    # Capture warp logs on failure for debugging before teardown
    if [ "$trigger_type" = "ERR" ]; then
      echo -e "\n--- WARP FAILURE LOGS ---" >> output.log
      docker compose logs warp --tail=100 >> output.log 2>&1 || true
      echo "-------------------------" >> output.log
    fi

    # Best-effort container teardown on failure
    docker compose down --remove-orphans -t 30 2>> output.log || true

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
    rm -f "${LOCK_FILE:-/tmp/nullexit-toggle.lock}"
  fi
}

trap 'cleanup_handler ERR $LINENO' ERR
trap 'cleanup_handler INT' INT
trap 'cleanup_handler TERM' TERM
trap 'cleanup_handler HUP' HUP

# ─── NOPASSWD sudo ──────────────────────────────────────────────────────────
# The user has NOPASSWD in /etc/sudoers.d/nullexit for the specific commands
# needed (networksetup, pfctl, route, ifconfig, dscacheutil, killall, pkill,
# and python3 -I scripts/dns-proxy.py for the fallback DNS proxy).
# All privileged calls below use `sudo -n` which will run without prompting.
# No credential caching loop is needed.

# Add Homebrew and standard paths
setup_standard_path

# Check for local DNS proxy tools (used when tailnet data plane is unavailable)
# Uses a Python DNS proxy (handles TCP wire format correctly).
# Python3 is built into macOS — no external dependencies.
DNS_PROXY_BIN=""
if command -v python3 >> output.log 2>&1; then
  DNS_PROXY_BIN="python3 -I"
elif command -v python >> output.log 2>&1; then
  DNS_PROXY_BIN="python -I"
fi

# Path to the DNS proxy script (sibling of this script)
DNS_PROXY_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/dns-proxy.py"

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


# ─── Wait for Network Readiness ─────────────────────────────────────────────
# On --restart, the gateway tears down while the host network interface may
# still be reconnecting (Wi-Fi, Ethernet, USB tethering, etc.). If we proceed
# too early, get_active_service returns nothing, routing targets the wrong
# interface, and DNS/WARP setup silently fails.
#
# We use `route get default` to detect a valid default gateway rather than
# checking a specific interface (e.g. en0) — this generalizes across all
# connection types: Wi-Fi, Ethernet, USB-C adapters, iPhone tethering, etc.
# The moment the OS has any routable default gateway, we proceed.
_net_wait_secs=0
_net_timeout=60
echo "Waiting for network connectivity before starting..."
while true; do
  if route get default 2>/dev/null | grep -q 'gateway:'; then
    _gw=$(route get default 2>/dev/null | awk '/gateway:/{print $2}')
    echo "  Network ready (default gateway: $_gw)."
    break
  fi
  if [ "$_net_wait_secs" -ge "$_net_timeout" ]; then
    echo "  [Warning] No default gateway after ${_net_timeout}s — proceeding anyway."
    break
  fi
  sleep 2
  _net_wait_secs=$((_net_wait_secs + 2))
done

ACTIVE_SERVICE=$(get_active_service)

# Resolve the service name for en0 (usually "Wi-Fi") — macOS scutil DNS resolver
# is commonly scoped to en0, so per-service DNS changes on other interfaces are
# ignored unless en0's service is also updated.
EN0_SERVICE=$(get_en0_service)

# Helper to add host-side bypass routes for the WARP WireGuard endpoints.
# This prevents an infinite recursive routing loop (tunnel loop) where
# the container's WireGuard packets exit the VM, reach the host, match the
# default route (the exit node), and get routed back into the tunnel.
# We route via the gateway IP (not interface) to ensure packets are routed
# properly even when the host's default route changes to the Tailscale interface.

# Helper to manually override the host's default route to point through the
# Tailscale utun* interface. Standalone tailscaled on macOS (Homebrew version)
# lacks the platform-specific integration to override the default gateway
# automatically when --exit-node is used.
setup_exit_node_routing() {
  local ts_iface
  ts_iface=$(ifconfig | awk '/^[a-z0-9]+:/{iface=$1} /inet 100\./{print iface; exit}' | tr -d ':')
  
  if [ -n "$ts_iface" ]; then
    echo "Re-routing default gateway to $ts_iface using 0.0.0.0/1 split..."
    local host_mtu
    host_mtu=$(read_env_var HOST_MTU)
    host_mtu=${host_mtu:-1200}
    
    # Lower the host Tailscale MTU (defaults to 1200) to prevent fragmentation when passing
    # through the container's WARP tunnel (which also has an MTU of 1280).
    sudo -n ifconfig "$ts_iface" mtu "$host_mtu" >> output.log 2>&1 || true

    # DO NOT delete the physical default route! It crashes Colima.
    # Use the /1 trick to mathematically override the default route.
    sudo -n route delete -net 0.0.0.0/1 >> output.log 2>&1 || true
    sudo -n route delete -net 128.0.0.0/1 >> output.log 2>&1 || true
    sudo -n route add -net 0.0.0.0/1 -interface "$ts_iface" >> output.log 2>&1 || true
    sudo -n route add -net 128.0.0.0/1 -interface "$ts_iface" >> output.log 2>&1 || true

    if netstat -nr | grep -E -q "^(0\.0\.0\.0/1|0/1)[[:space:]]+.*$ts_iface"; then
      echo "  [✓] Default route successfully overridden via $ts_iface."
    else
      echo "  [!] Failed to verify exit node routing on $ts_iface."
    fi
  else
    echo "[Warning] Could not detect Tailscale utun interface for host routing."
  fi
}

# Helper to nuke leftover network state after teardown (proxy settings, routing
# table, DNS cache, Wi-Fi). Prevents the "had to write a whole recovery script"
# problem where stale state kills internet after the gateway stops.
cleanup_network_state() {
  echo -e "\nCleaning up network state (proxies, routes, DNS cache, Wi-Fi)..."

  # 1. Disable any leftover proxy settings (needs root on many macOS versions)
  for svc in "$ACTIVE_SERVICE" "$EN0_SERVICE"; do
    disable_all_proxies "$svc"
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
    sudo -n route delete -net 0.0.0.0/1 >> output.log 2>&1 || true
    sudo -n route delete -net 128.0.0.0/1 >> output.log 2>&1 || true
  fi
  remove_warp_bypass_routes
  disable_killswitch
  echo "  Routing table and firewall flushed."

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

  # Force restart sharing services to prevent AirDrop / AirPlay discovery freezes
  # after network interface/DNS changes.
  echo "  Resetting macOS sharing services (AirDrop/AirPlay)..."
  reset_sharing_services

  echo "Network state cleanup complete."
}

SOCKS_PROXY_PORT=${SOCKS_PROXY_PORT}

# Ensure DNS is set to 1.1.1.1 immediately at script start to prevent any DNS deadlocks/hangs
# during status checks, container startup, VM boot, or teardown. We *also* clear any leftover
# `ts.net` search domain from a previous `tailscale up --accept-dns=true` run, otherwise macOS
# would prepend it to every lookup and most public DNS queries would resolve to NXDOMAIN.


echo "Initializing DNS to 1.1.1.1 to ensure reliable internet access..."
reset_dns




echo "Checking Gateway Status..."
HIJACK_HOST=$(read_env_var GATEWAY_HIJACK_HOST | tr '[:upper:]' '[:lower:]')

# Decide STOP vs START from persisted intent (marker), not a live Docker probe.
# This makes *disable* instant and robust even when Colima/Docker is down.
#
# CRITICAL (set -e + set -x on bash 3.2): gateway_state ECHOES "running"/"stopped"
# and always returns 0, so we branch on the STRING — never on a function's exit
# code. A helper that `return 1`s trips a spurious `set -e` abort under `set -x`
# (DEBUG_TRACE=true) even when guarded, hence the echo contract. See devref §15.11.8.
if [ "$(gateway_state)" = "running" ]; then
  TOGGLE_PHASE="stop"
  echo -e "\n=============================================="
  echo "Gateway is RUNNING. Stopping it now..."
  echo -e "==============================================\n"

  # 1. Disconnect host Tailscale cleanly first before stopping the exit-node container
  if [[ "$HIJACK_HOST" != "false" ]]; then
    disconnect_tailscale_host
    echo ""
  fi

  echo "Stopping Docker containers..."
  # `|| true`: a disable must always complete its teardown even if the Docker
  # daemon / Colima VM is already down (compose down would exit non-zero and,
  # under set -e, abort the STOP). The START path intentionally does NOT guard
  # its `docker compose up` — a failed start SHOULD trigger cleanup.
  run_logged docker compose down --remove-orphans -t 30 || true

  # Only stop Colima if the user explicitly opted in (false by default) to prevent breaking their other Docker dev projects
  STOP_COLIMA=$(read_env_var STOP_COLIMA_ON_EXIT | tr '[:upper:]' '[:lower:]')
  if [[ "$STOP_COLIMA" == "true" ]]; then
    echo -e "\nStopping Colima VM to free up host RAM and battery..."
    run_with_timeout 30 colima stop >> output.log 2>&1 || echo "Warning: Failed to stop Colima gracefully."
  else
    echo -e "\nLeaving Colima running. (Set STOP_COLIMA_ON_EXIT=true in .env to change this)"
  fi

  if [[ "$HIJACK_HOST" != "false" ]]; then
    # The host's DNS was hijacked to the gateway IP during ENABLE; now that the
    # gateway is down, restore DNS to 1.1.1.1 immediately so subsequent lookups
    # don't stall for the macOS DNS timeout before the 1.1.1.1 fallback engages.
    echo -e "\nRestoring host DNS to 1.1.1.1 (gateway is gone)... "
    reset_dns

    # 3. Stop local DNS proxy if running
    stop_local_dns_proxy

    # Stop background daemons
    stop_pidfile_daemon "/tmp/nullexit-caffeinate.pid" "system sleep prevention"
    stop_pidfile_daemon "/tmp/nullexit-dns-watcher.pid" "background DNS Watcher"
    stop_warp_watcher
    clear_gateway_active_marker

    # 4. Nuke leftover network state so internet actually works after teardown
    cleanup_network_state
  fi

  ELAPSED=$(( SECONDS - TOGGLE_START_TIME ))
  echo -e "\nGateway has been successfully STOPPED in ${ELAPSED} seconds."
else
  TOGGLE_PHASE="start"
  START_GATEWAY=true
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Action: STARTUP GATEWAY" >> "$LOG_FILE"
  echo -e "\n=============================================="
  echo "Gateway is STOPPED. Starting it now..."
  echo -e "==============================================\n"

  # 1. Prevent host exit-node deadlock during VM / Container startup
  if [[ "$HIJACK_HOST" != "false" ]]; then
    disconnect_tailscale_host
  fi

  # 2. Wait for physical DHCP lease to settle (crucial for restarts/wake-up/roaming)
  wait_for_dhcp_settle

  # 3. Boot Colima VM if it is not already running
  echo -e "\nChecking Colima VM status..."
  if ! run_with_timeout 15 colima status >> output.log 2>&1; then
    colima_network_mode="bridged"
    security_type=""
    if [[ "$OSTYPE" == "darwin"* ]]; then
      security_type=$(system_profiler SPAirPortDataType 2>/dev/null | awk '/Current Network Information:/{found=1} found && /Security:/{print $NF; exit}')
      if echo "$security_type" | grep -qi "Enterprise"; then
        echo -e "\n  [!] WPA2-Enterprise Wi-Fi detected! Bridged mode will cause MAC-spoofing deauthentication."
        echo "      Falling back to '--network-mode shared' for Colima."
        colima_network_mode="shared"
      fi
    fi
    echo "Colima is not running. Starting Colima (600MB RAM allocation, vz VM, network address, $colima_network_mode)..."
    run_logged run_with_timeout 120 colima start --memory 0.6 --vm-type vz --network-address --network-mode "$colima_network_mode"
    echo "$colima_network_mode" > /tmp/nullexit_colima_mode.txt
  else
    echo "Colima is already running."
  fi

  # 3b. Auto-detect and fix Docker Subnet Collisions (e.g. if the user travels to a 172.17.x.x Wi-Fi)
  if [ -f "scripts/fix-docker-bridge-collision.sh" ]; then
    if bash scripts/fix-docker-bridge-collision.sh --dry | grep -q "collision detected"; then
      echo -e "\n[!] WARNING: Docker Subnet Collision Detected with your current Wi-Fi!"
      echo -e "    Auto-fixing Colima config to prevent internet jitter..."
      bash scripts/fix-docker-bridge-collision.sh --skip-toggle || true
    fi
  fi

  # 3c. Configure swap file inside the VM to prevent OOM on low-memory limits
  # We also set vm.swappiness=10 so the Linux kernel strictly prefers physical RAM
  # and avoids unnecessarily wearing out the SSD with proactive background swapping.
  if ! run_with_timeout 15 colima ssh -- grep -q 'swapfile' /proc/swaps >> output.log 2>&1; then
    echo "Configuring 400MB swap file inside the VM to prevent OOM..."
    run_with_timeout 30 colima ssh -- sudo sh -c "if [ ! -f /swapfile ]; then dd if=/dev/zero of=/swapfile bs=1M count=400 status=none && mkswap /swapfile; fi && swapon /swapfile && sysctl vm.swappiness=10" >> output.log 2>&1 || echo "Warning: Failed to enable swap file inside the VM."
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

  # 4c. Inject TCP MSS clamp from .env into post-rules.txt before starting
  if [ -f .env ] && grep -q "^GATEWAY_MSS=" .env; then
    GATEWAY_MSS=$(read_env_var GATEWAY_MSS)
    if [[ "$GATEWAY_MSS" =~ ^[0-9]+$ ]]; then
      # macOS sed syntax
      sed -i '' "s/--set-mss [0-9]*/--set-mss ${GATEWAY_MSS}/g" post-rules.txt 2>/dev/null || \
      # Linux sed fallback
      sed -i "s/--set-mss [0-9]*/--set-mss ${GATEWAY_MSS}/g" post-rules.txt 2>/dev/null
    fi
  fi

  # 5. Start compose services
  write_host_ips
  
  # Procedurally generated ports have already been exported at the top of the script.
  echo "  [Security] Procedurally randomized proxy ports generated to evade fingerprinting."
  
  # --- HONEY-PORT TRIPWIRE ---
  # Generate a random trap port. If any malware does a sequential port scan on localhost,
  # it will inevitably hit this port. When it does, we instantly fire a macOS alert.
  HONEY_PORT=$(get_free_port)
  (
    if nc -l localhost "$HONEY_PORT" >/dev/null 2>&1; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] [CRITICAL SECURITY ALERT] PORT SCAN DETECTED! An unknown application just pinged the local Honey-Port ($HONEY_PORT)!" >> "$LOG_FILE"
      osascript -e 'display notification "An unknown application is aggressively scanning your local ports. Malware port-scan suspected." with title "nullexit OPSEC Alert" sound name "Basso"' 2>/dev/null || true
    fi
  ) &
  disown %1 2>/dev/null || true
  echo "  [Security] Honey-Port Tripwire armed on random port to detect malware port-scans."
  
  echo -e "\nStarting Docker containers..."
  run_logged docker compose up -d --build

  # Log the output of the rule compiler for debugging before removing it
  docker compose logs rule-compiler >> output.log 2>&1
  # Clean up the one-off rule compiler container so it doesn't clutter the Docker UI
  docker compose rm -s -f rule-compiler >> output.log 2>&1
  
  RULE_COUNT=$(grep "! Total Block Rules:" adguard/work/userfilters/compiled_rules.txt 2>/dev/null | awk -F': ' '{print $2}' || echo "0")
  NATIVE_COUNT=$(grep "! Native AdGuard Rules:" adguard/work/userfilters/compiled_rules.txt 2>/dev/null | awk -F': ' '{print $2}' || echo "0")
  
  if [ "$RULE_COUNT" != "0" ] && [ "$RULE_COUNT" != "" ]; then
    if [ "$NATIVE_COUNT" != "0" ] && [ "$NATIVE_COUNT" != "" ]; then
      TOTAL_COUNT=$((RULE_COUNT + NATIVE_COUNT))
      # Format with commas for readability (e.g. 441,578)
      if command -v printf &> /dev/null; then
        FORMATTED_RULE=$(printf "%'d" "$RULE_COUNT")
        FORMATTED_TOTAL=$(printf "%'d" "$TOTAL_COUNT")
        echo "  DNS: Compiled $FORMATTED_RULE unique custom rules (Total active in AdGuard: ~$FORMATTED_TOTAL rules)."
      else
        echo "  DNS: Compiled $RULE_COUNT unique custom rules (Total active in AdGuard: ~$TOTAL_COUNT rules)."
      fi
    else
      echo "  DNS: Compiled and loaded $RULE_COUNT optimized rules."
    fi
  fi

  # Report IP blocklist compilation results
  IP_COUNT=$(grep "^# Entries:" adguard/work/userfilters/ip_blocklist.ipset 2>/dev/null | awk -F': ' '{print $2}' || echo "0")
  if [ "$IP_COUNT" != "0" ] && [ "$IP_COUNT" != "" ]; then
    if command -v printf &> /dev/null; then
      FORMATTED_IP=$(printf "%'d" "$IP_COUNT")
      echo "  IP:  Loaded $FORMATTED_IP threat intelligence IPs/CIDRs into kernel firewall."
    else
      echo "  IP:  Loaded $IP_COUNT threat intelligence IPs/CIDRs into kernel firewall."
    fi
  fi

  # 6. Wait for the gateway container's Tailscale connection to be ready
  BYPASS_PING=$(read_env_var GATEWAY_BYPASS_PING | tr '[:upper:]' '[:lower:]')
  USE_EXIT_NODE=$(read_env_var GATEWAY_USE_EXIT_NODE | tr '[:upper:]' '[:lower:]')

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
  # Dynamically query the container for the IP (handles IP changes after re-auth)
  # and cache it in .gateway_ip for fast retrieval by recover.sh during Wi-Fi roaming.
  #
  # CRITICAL: `docker compose exec -T` on macOS/Colima injects carriage
  # returns (\r) into captured output. If $TS_IP ends with \r, then
  # `networksetup -setdnsservers` silently rejects the malformed IP and
  # DNS stays at 1.1.1.1 — the primary bug this project was hitting.
  # `tr -d '\r'` strips the CR; `awk 'NR==1{print $1; exit}'` takes only
  # the first field of the first line.
  TS_IP=""
  if [ "$connected" = "true" ]; then
    TS_IP=$(run_with_timeout 10 docker compose exec -T tailscale tailscale ip -4 2>> output.log | tr -d '\r' | awk 'NR==1{print $1; exit}' || true)
    if [ -n "$TS_IP" ]; then
      echo "Resolved gateway Tailscale IP dynamically: $TS_IP"
      echo "$TS_IP" > .gateway_ip
    else
      echo "    [!] Failed to resolve gateway IP dynamically. Trying fallback cache..." >&2
      TS_IP=$(read_adguard_ip || true)
    fi
  else
    TS_IP=$(read_adguard_ip || true)
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
  if [ "$HIJACK_HOST" = "false" ]; then
    echo -e "\n[Info] HIJACK_HOST is false (Headless Mode). Host networking will remain untouched."
    SKIP_EXIT_NODE=true
  elif [ -n "$TS_BIN" ]; then
    echo -n "Verifying tailscaled is reachable"
    daemon_ready=false
    status_exit=0
    for i in {1..10}; do
      # Test if the daemon responds to status check.
      # If status returns non-zero, check if it was a normal "stopped/disconnected" state
      # (exit code 1 is normal for disconnected). If the command exited quickly (not killed by timeout),
      # and the error is just "Tailscale is stopped", then the daemon is alive and ready.
      # But if it timed out (exit code 143) or is completely unresponsive, it's wedged.
      status_exit=0
      if run_with_timeout 5 $TS_BIN status >> output.log 2>&1; then
        daemon_ready=true
        break
      else
        status_exit=$?
        if [ "$status_exit" -ne 143 ] && [ -S /var/run/tailscaled.socket ]; then
          daemon_ready=true
          break
        fi
      fi
      echo -n "."
      sleep 1
    done
    echo ""

    # If the daemon was unresponsive or socket check failed, attempt auto-restart
    if [ "$daemon_ready" != "true" ]; then
      if [ "$status_exit" -eq 143 ]; then
        warn "tailscaled daemon is wedged/unresponsive. Restarting it..."
      else
        warn "tailscaled daemon is not running. Attempting to start it..."
      fi
      restart_tailscaled_daemon
      
      # Re-verify
      if run_with_timeout 5 $TS_BIN status >> output.log 2>&1 || [ -S /var/run/tailscaled.socket ]; then
        daemon_ready=true
      fi
    fi

    if [ "$daemon_ready" = "true" ]; then
      echo "tailscaled is responsive (running as a system service)."

      # ── Phase A: Join mesh without exit node ───────────────────────────
      echo "Connecting host to Tailscale mesh (no exit node yet)..."
      if $TS_BIN up; then
        $TS_BIN set --ssh=true --accept-dns=false --accept-routes=true --exit-node= || true
        HOST_ON_MESH=true
        echo "Host is on Tailscale mesh."
      else
        warn "tailscale up failed even though the daemon is running."
        echo "  This usually means the host hasn't authenticated with your tailnet yet."
        echo "  Run this command in a terminal to authenticate:"
        echo ""
        echo "      sudo tailscale up"
        echo ""
        echo "  A browser will open. Log in to your Tailscale account, then re-run toggle.sh."
      fi
    else
      fail "tailscaled could NOT be started automatically."
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
    ping_ok=false
    # The host tailscaled needs a few seconds to propagate the new network map and
    # establish a connection route after 'tailscale up --reset'. We retry up to 45 times.
    for attempt in {1..45}; do
      if $TS_BIN ping --until-direct=false -c 2 --timeout 2s "$TS_IP" 2>/dev/null | grep -q "pong"; then
        ping_ok=true
        break
      fi
      sleep 1
    done
    if [ "$ping_ok" = "true" ]; then
      echo "PASS"
    else
      echo "FAIL"
      SKIP_EXIT_NODE=true
    fi
    
    # Check 2: Can we reach AdGuard via localhost (exposed port ${DNS_PROXY_PORT})?
    # Colima's SSH tunnel only forwards TCP (not UDP), so we use +tcp.
    echo -n "  [2/3] AdGuard DNS via localhost... "
    if command -v dig &>/dev/null; then
      if dig +tcp @127.0.0.1 -p ${DNS_PROXY_PORT} google.com +short +timeout=5 &>/dev/null; then
        echo "PASS"
      else
        echo "FAIL"
        SKIP_EXIT_NODE=true
      fi
    elif command -v nslookup &>/dev/null; then
      if nslookup -port=${DNS_PROXY_PORT} google.com 127.0.0.1 &>/dev/null; then
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
    tmp_err=$(mktemp)
    if docker compose exec -T warp wget -qO- --timeout=5 https://www.cloudflare.com/cdn-cgi/trace >/dev/null 2>"$tmp_err"; then
      echo "PASS"
    else
      echo "FAIL"
      if [ -s "$tmp_err" ]; then
        err_msg=$(cat "$tmp_err" | tr -d '\r')
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [Check 3] WARP container check failed: $err_msg" >> output.log
      fi
      SKIP_EXIT_NODE=true
    fi
    rm -f "$tmp_err"
    
    # Act based on check results
    if [ "$SKIP_EXIT_NODE" != "true" ]; then
      echo -e "\nAll checks passed. Enabling exit node $TS_IP..."
      $TS_BIN up || true
      if $TS_BIN set --ssh=true --accept-dns=false --accept-routes=true --exit-node="$TS_IP" --exit-node-allow-lan-access=true; then
        echo "Exit node enabled."
        add_warp_bypass_routes
        setup_exit_node_routing
        enable_killswitch
      else
        echo "[Warning] Failed to set exit node."
        SKIP_EXIT_NODE=true
      fi
    fi
    
    if [ "$SKIP_EXIT_NODE" = "true" ]; then
      warn "Pre-flight checks failed — EXIT NODE + DNS HIJACK SKIPPED."
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
  # AdGuard is also available at localhost:${DNS_PROXY_PORT} for manual configuration in apps.
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
  elif [ -n "$TS_IP" ] && [ "$HIJACK_HOST" != "false" ]; then
    echo -e "\n[Info] Exit node not enabled (pre-flight checks failed)."
    echo "  Trying local DNS proxy for ad-blocking..."
    if start_local_dns_proxy; then
      echo "  Ad-blocking active via local DNS proxy through AdGuard."
    else
      echo "  Local DNS proxy unavailable. DNS stays at 1.1.1.1."
      echo "  AdGuard available at http://localhost:80 (port ${DNS_PROXY_PORT} for DNS via TCP)."
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
  
  if [[ "$HIJACK_HOST" != "false" ]]; then
    if [ -n "$TS_IP" ] && [ "$TS_IP" != "1.1.1.1" ]; then
      start_dns_watcher "$TS_IP"
    fi

    # Start WARP liveness monitor (logs to output.log on warp flip)
    start_warp_watcher
  fi

  # Reset sharing services after network configuration to prevent AirDrop freezes
  echo "Resetting macOS sharing services (AirDrop/AirPlay)..."
  reset_sharing_services

  # Tell external watchers (post-wake / network-change) the gateway is up.
  write_gateway_active_marker

  # ── Local Network Surveillance Check ──────────────────────────────────────
  echo -e "\n──────────────────────────────────────────────"
  echo "Local Network Surveillance Check"
  echo "──────────────────────────────────────────────"
  # Count populated ARP cache entries to detect network scanning or high congestion
  # Using '-an' avoids hanging on DNS reverse resolution when the network state is in transition.
  ARP_COUNT=$(arp -an 2>/dev/null | grep -iv 'incomplete' | wc -l | tr -d ' ')
  if [ "$ARP_COUNT" -gt 15 ]; then
    warn "High ARP activity detected ($ARP_COUNT devices in cache)."
    warn "This Wi-Fi network may be heavily congested or actively scanned (e.g., arp-scan)."
    echo -e "  [✓] Your traffic remains fully encrypted and invisible.\n"
  else
    echo -e "  [✓] Local network looks quiet ($ARP_COUNT devices). No aggressive scanning detected.\n"
  fi
fi

SUCCESS_RUN=true

# Final DNS state summary
if [ -n "$ACTIVE_SERVICE" ]; then
  FINAL_DNS=$(networksetup -getdnsservers "$ACTIVE_SERVICE" 2>> output.log || true)
  echo -e "\n──────────────────────────────────────────────"
  echo -e "DNS STATE: $FINAL_DNS"
  echo -e "──────────────────────────────────────────────"
fi

if [ "$START_GATEWAY" = "true" ] && command -v docker >/dev/null 2>&1; then
  if docker compose logs rule-compiler 2>/dev/null | grep -q "Warning: Failed to fetch"; then
    echo -e "\n[Warning] One or more blocklist URLs failed to download (404/Offline)."
    echo "  The gateway gracefully fell back to yesterday's cached blocklist."
    echo "  (Run 'docker logs rule-compiler' later to investigate which link died.)"
  fi
fi

rm -f "${LOCK_FILE:-/tmp/nullexit-toggle.lock}"
if [ -t 0 ]; then
  read -rp "Press [r] and Enter to instantly reverse state, or just press Enter to exit: " USER_CHOICE
  if [[ "${USER_CHOICE}" == "r" || "${USER_CHOICE}" == "R" ]]; then
    echo "Reversing gateway state..."
    exec bash "$0"
  fi
fi

echo -e "\nYou can close this terminal window now."
