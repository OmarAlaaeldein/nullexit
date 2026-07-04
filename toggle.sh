#!/bin/bash
# toggle.sh — nullexit gateway toggle script for macOS
# Automatically handles Docker containers, Colima, DNS hijacking, and Tailscale exit node routing.

set -e

# Enforce Cryptographic Script Integrity
if [ -x "scripts/crypto.sh" ]; then
  if ! ./scripts/crypto.sh --verify; then
    exit 1
  fi
fi

# Define log file
LOG_FILE="$PWD/output.log"

# Rotate log file if it exceeds 50MB (52428800 bytes)
if [ -f "$LOG_FILE" ]; then
  log_size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
  if [ "$log_size" -gt 52428800 ]; then
    mv "$LOG_FILE" "${LOG_FILE}.old" 2>/dev/null || rm -f "$LOG_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Log file exceeded 50MB; rotated to output.log.old" > "$LOG_FILE"
  fi
fi

# --- MAIN EXECUTION LOGGING ---
echo -e "\n========================================================" >> "$LOG_FILE"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] toggle.sh invoked" >> "$LOG_FILE"
echo "========================================================" >> "$LOG_FILE"

# (Previously this script chmod 600'd .env at start to "unlock" it for docker compose,
# and chmod 000'd it on exit. That pattern broke docker compose on macOS/Colima when
# the umask produced 0600 — the script removed its own ability to read .env before it could even proceed.)

# Start execution timer
TOGGLE_START_TIME=$SECONDS

if [[ "$1" == "restart" ]] || [[ "$1" == "--restart" ]]; then
  echo "Executing Gateway Restart Sequence..."
  # We must source common.sh here temporarily to check is_gateway_active before we proceed
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/common.sh"
  if is_gateway_active; then
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
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/common.sh"

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
}

clear_gateway_active_marker() {
  rm -f /tmp/nullexit-gateway-active.marker
  rm -f "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/TUNNEL_FAILED_CLOSED.marker"
}

# Defensive: clear any stale marker from a prior crashed/aborted run. If a
# previous toggle.sh wrote the marker but was OOM-killed in the middle of the
# START block (before the END-of-START write) — or if the user rebooted mid
# session — this prevents the watcher from firing post-wake against a
# non-running gateway on every wake event. Placed AFTER the function
# definitions so bash resolves the call at parse time.
clear_gateway_active_marker

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
        tailscale up --reset --accept-dns=false --exit-node= >> \"$PWD/output.log\" 2>&1 &
        TS_DOWN_ARGS=\"\"
        if grep -iq \"^KILL_SWITCH=true\" .env 2>/dev/null; then TS_DOWN_ARGS=\"--accept-risk=lose-ssh\"; fi
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

# Stop macOS caffeinate when gateway is stopped
stop_sleep_prevention() {
  if [ -f "$PID_FILE" ]; then
    local caffe_pid
    caffe_pid=$(cat "$PID_FILE")
    if [ -n "$caffe_pid" ] && kill -0 "$caffe_pid" 2>/dev/null && ps -p "$caffe_pid" -o command= 2>/dev/null | grep -q -E "caffeinate|recover.sh"; then
      echo "  Stopping system sleep prevention (caffeinate wrapper PID $caffe_pid)..."
      kill "$caffe_pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
  fi
}

DNS_WATCHER_PID_FILE="/tmp/nullexit-dns-watcher.pid"
WARP_WATCHER_PID_FILE="/tmp/nullexit-warp-watcher.pid"
HOST_LEAK_PROBE_PID_FILE="/tmp/nullexit-host-leak-probe.pid"

start_dns_watcher() {
  local target_ip=$1
  stop_dns_watcher
  echo "  Starting background DNS Watcher for seamless Wi-Fi roaming..."
  nohup bash -c "
    trap 'exit 0' SIGTERM SIGINT SIGHUP
    while true; do
      ACTIVE_IF=\$(networksetup -listallnetworkservices | awk 'NR>1' | grep -v '*' | grep -i 'Wi-Fi' | head -1)
      if [ -n \"\$ACTIVE_IF\" ]; then
        CURRENT_DNS=\$(networksetup -getdnsservers \"\$ACTIVE_IF\" 2>/dev/null)
        if [ \"\$CURRENT_DNS\" != \"$target_ip\" ]; then
          networksetup -setdnsservers \"\$ACTIVE_IF\" \"$target_ip\" >/dev/null 2>&1
        fi
      fi
      sleep 30
    done
  " >> output.log 2>&1 &
  echo $! > "$DNS_WATCHER_PID_FILE"
}

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

# Background WARP tunnel liveness monitor. Polls cdn-cgi/trace every 30s
# while healthy, but accelerates to polling every 5s if a failure is detected.
# Always logs state transitions to output.log. When warp=off persists for
# WARP_FAIL_THRESHOLD consecutive polls (default 6 = 30s of downtime), the watcher
# triggers a nuclear recovery: runs recover.sh to tear down the entire
# gateway — disconnecting Tailscale, stopping containers, resetting DNS,
# and power-cycling Wi-Fi. This guarantees no traffic ever leaks through
# a dead WARP tunnel while the user thinks they're protected.
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
    while true; do
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
          bash \"\$recover_bin\" >> \"\$out_log\" 2>&1 || true
          echo \"[\$(date -u +%FT%TZ)] WARP SHUTDOWN — recover.sh completed, watcher exiting. Your IP is now your real ISP IP.\" >> \"\$out_log\"
          exit 0
        fi
      else
        if [ \"\$consec_off\" -gt 0 ]; then
          echo \"[\$(date -u +%FT%TZ)] WARP RECOVERED — warp=on after \$consec_off consecutive off readings (threshold was \$threshold)\" >> \"\$out_log\"
        fi
        consec_off=0
      fi

      if [ "\$state" = "off" ]; then
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

# Background host-egress leak prober. Polls cdn-cgi/trace directly from the
# HOST (not via docker exec) at 300ms resolution. Logs LEAK / ROTATE / probe
# failures to output.log on every state change. Enabled via HOST_LEAK_PROBE=true
# in .env (default true). Safe to leave running for hours; ~1.4 MB RSS.
start_host_leak_probe() {
  stop_host_leak_probe
  local enabled
  enabled=$(read_env_var HOST_LEAK_PROBE)
  if [ -z "$enabled" ]; then
    enabled="${HOST_LEAK_PROBE:-true}"
  fi
  if [ "$enabled" != "true" ]; then
    return 0
  fi
  echo "  Starting background Host Leak Probe (polling every 300ms from HOST, logging to output.log)..."
  nohup bash "$PWD/scripts/host-leak-probe.sh" >> "$PWD/output.log" 2>&1 &
  echo $! > "$HOST_LEAK_PROBE_PID_FILE"
}

stop_host_leak_probe() {
  if [ -f "$HOST_LEAK_PROBE_PID_FILE" ]; then
    local hp
    hp=$(cat "$HOST_LEAK_PROBE_PID_FILE")
    if [ -n "$hp" ] && kill -0 "$hp" 2>/dev/null; then
      echo "  Stopping background Host Leak Probe (PID $hp)..."
      kill "$hp" 2>/dev/null || true
    fi
    rm -f "$HOST_LEAK_PROBE_PID_FILE"
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
    stop_warp_watcher
    stop_host_leak_probe
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
restart_tailscaled_daemon() {
  echo "  [Tailscale Recovery] tailscaled daemon appears to be wedged/unresponsive."
  echo "  [Tailscale Recovery] Attempting to restart tailscaled service..."
  
  # Try user-level restart first
  if run_with_timeout 15 brew services restart tailscale >> output.log 2>&1; then
    echo "  [Tailscale Recovery] Successfully restarted tailscaled (user service)."
  # Fallback to system-level restart (using sudo -n so it doesn't block if NOPASSWD isn't set)
  elif run_with_timeout 15 sudo -n brew services restart tailscale >> output.log 2>&1; then
    echo "  [Tailscale Recovery] Successfully restarted tailscaled (system service)."
  else
    echo "  [Tailscale Recovery] WARNING: Failed to restart tailscaled. Manual intervention may be needed."
  fi
  sleep 3
}

disconnect_tailscale_host() {
  if [ -n "$TS_BIN" ]; then
    echo "Disconnecting host Tailscale from mesh (tailscaled stays running as system service)..."
    local ts_args=""
    if grep -iq "^KILL_SWITCH=true" .env 2>/dev/null; then ts_args="--accept-risk=lose-ssh"; fi
    if ! run_with_timeout 10 $TS_BIN down $ts_args >> output.log 2>&1; then
      restart_tailscaled_daemon
      # Retry once
      echo "Retrying Tailscale disconnection..."
      run_with_timeout 10 $TS_BIN down $ts_args >> output.log 2>&1 || true
    fi
  fi
}


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
add_warp_bypass_routes() {
  local gateway_ip
  gateway_ip=$(route get default 2>> output.log | awk '/gateway:/ {print $2}')
  
  if [ -z "$gateway_ip" ]; then
    local iface
    iface=$(route get default 2>> output.log | awk '/interface:/ {print $2}')
    if [[ -z "$iface" || ! "$iface" =~ ^en[0-9]+$ ]]; then
      iface="en0"
    fi
    echo -e "\nAdding host bypass routes for Cloudflare WARP endpoints via interface $iface..."
    sudo -n route delete -host 162.159.192.1 2>/dev/null || true
    sudo -n route delete -host 162.159.193.1 2>/dev/null || true
    sudo -n route add -host 162.159.192.1 -interface "$iface" >> output.log 2>&1 || true
    sudo -n route add -host 162.159.193.1 -interface "$iface" >> output.log 2>&1 || true
  else
    echo -e "\nAdding host bypass routes for Cloudflare WARP endpoints via gateway $gateway_ip..."
    sudo -n route delete -host 162.159.192.1 2>/dev/null || true
    sudo -n route delete -host 162.159.193.1 2>/dev/null || true
    sudo -n route add -host 162.159.192.1 "$gateway_ip" >> output.log 2>&1 || true
    sudo -n route add -host 162.159.193.1 "$gateway_ip" >> output.log 2>&1 || true
  fi
}

remove_warp_bypass_routes() {
  echo -e "\nRemoving host bypass routes for Cloudflare WARP endpoints..."
  sudo -n route delete -host 162.159.192.1 2>/dev/null || true
  sudo -n route delete -host 162.159.193.1 2>/dev/null || true
}

# Helper to manually override the host's default route to point through the
# Tailscale utun* interface. Standalone tailscaled on macOS (Homebrew version)
# lacks the platform-specific integration to override the default gateway
# automatically when --exit-node is used.
setup_exit_node_routing() {
  local ts_iface
  ts_iface=$(ifconfig 2>> output.log | grep -B4 "inet 100." | grep -E '^[a-z0-9]+' | cut -d: -f1 | head -n 1)
  if [ -z "$ts_iface" ]; then
    for i in $(ifconfig 2>> output.log | grep -E '^utun[0-9]+' | cut -d: -f1); do
      if ifconfig "$i" 2>> output.log | grep -q "inet 100."; then
        ts_iface="$i"
        break
      fi
    done
  fi
  
  if [ -n "$ts_iface" ]; then
    echo "Manually configuring host routing table for exit node via $ts_iface..."
    sudo -n route delete default 2>> output.log || true
    sudo -n route add default -interface "$ts_iface" >> output.log 2>&1 || true
  else
    echo "[Warning] Could not detect Tailscale utun interface for host routing."
  fi
}

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
  remove_warp_bypass_routes
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

  # Force restart sharing services to prevent AirDrop / AirPlay discovery freezes
  # after network interface/DNS changes.
  echo "  Resetting macOS sharing services (AirDrop/AirPlay)..."
  sudo -n killall sharingd rapportd 2>> output.log || true

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



  # ── Local Network Surveillance Check ──────────────────────────────────────
  echo -e "\n──────────────────────────────────────────────"
  echo "Local Network Surveillance Check"
  echo "──────────────────────────────────────────────"
  # Count populated ARP cache entries to detect network scanning or high congestion
  # Using '-an' avoids hanging on DNS reverse resolution when the network state is in transition.
  ARP_COUNT=$(arp -an 2>/dev/null | grep -iv 'incomplete' | wc -l | tr -d ' ')
  if [ "$ARP_COUNT" -gt 15 ]; then
    echo -e "  \033[1;33m[!] WARNING: High ARP activity detected ($ARP_COUNT devices in cache).\033[0m"
    echo -e "  \033[1;33m[!] This Wi-Fi network may be heavily congested or actively scanned (e.g., arp-scan).\033[0m"
    echo -e "  [✓] Your traffic remains fully encrypted and invisible.\n"
  else
    echo -e "  [✓] Local network looks quiet ($ARP_COUNT devices). No aggressive scanning detected.\n"
  fi

echo "Checking Gateway Status..."
HIJACK_HOST=$(read_env_var GATEWAY_HIJACK_HOST | tr '[:upper:]' '[:lower:]')

if is_gateway_active; then
  echo -e "\n=============================================="
  echo "Gateway is RUNNING. Stopping it now..."
  echo -e "==============================================\n"

  # 1. Disconnect host Tailscale cleanly first before stopping the exit-node container
  if [[ "$HIJACK_HOST" != "false" ]]; then
    disconnect_tailscale_host
    echo ""
  fi

  echo "Stopping Docker containers..."
  docker compose down --remove-orphans -t 30
  
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
    stop_sleep_prevention
    stop_dns_watcher
    stop_warp_watcher
    stop_host_leak_probe
    clear_gateway_active_marker

    # 4. Nuke leftover network state so internet actually works after teardown
    cleanup_network_state
  fi

  ELAPSED=$(( SECONDS - TOGGLE_START_TIME ))
  echo -e "\nGateway has been successfully STOPPED in ${ELAPSED} seconds."
else
  START_GATEWAY=true
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Action: STARTUP GATEWAY" >> "$LOG_FILE"
  echo -e "\n=============================================="
  echo "Gateway is STOPPED. Starting it now..."
  echo -e "==============================================\n"

  # 1. Prevent host exit-node deadlock during VM / Container startup
  if [[ "$HIJACK_HOST" != "false" ]]; then
    disconnect_tailscale_host
  fi

  # 3. Boot Colima VM if it is not already running
  echo -e "\nChecking Colima VM status..."
  if ! run_with_timeout 15 colima status >> output.log 2>&1; then
    echo "Colima is not running. Starting Colima (600MB RAM allocation, vz VM, network address, bridged)..."
    run_with_timeout 120 colima start --memory 0.6 --vm-type vz --network-address --network-mode bridged
  else
    echo "Colima is already running."
  fi
  # 3b. Configure swap file inside the VM to prevent OOM on low-memory limits
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
  echo -e "\nStarting Docker containers..."
  docker compose up -d --build
  
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
        echo -e "\033[0;33m[!] tailscaled daemon is wedged/unresponsive. Restarting it...\033[0m"
      else
        echo -e "\033[0;33m[!] tailscaled daemon is not running. Attempting to start it...\033[0m"
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
      if $TS_BIN up --reset --ssh=true --accept-dns=false --accept-routes=true --exit-node=; then
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
      if $TS_BIN up --reset --ssh=true --accept-dns=false --accept-routes=true --exit-node="$TS_IP" --exit-node-allow-lan-access=true; then
        echo "Exit node enabled."
        add_warp_bypass_routes
        setup_exit_node_routing
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
  elif [ -n "$TS_IP" ] && [ "$HIJACK_HOST" != "false" ]; then
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
  
  if [[ "$HIJACK_HOST" != "false" ]]; then
    if [ -n "$TS_IP" ] && [ "$TS_IP" != "1.1.1.1" ]; then
      start_dns_watcher "$TS_IP"
    fi

    # Start WARP liveness monitor (logs to output.log on warp flip)
    start_warp_watcher

    # Start host-side egress leak prober (polls from HOST, not docker exec)
    start_host_leak_probe
  fi

  # Reset sharing services after network configuration to prevent AirDrop freezes
  echo "Resetting macOS sharing services (AirDrop/AirPlay)..."
  sudo -n killall sharingd rapportd 2>> output.log || true

  # Tell external watchers (post-wake / network-change) the gateway is up.
  write_gateway_active_marker
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

echo -e "\n──────────────────────────────────────────────"
read -rp "Press [r] and Enter to instantly reverse state, or just press Enter to exit: " USER_CHOICE
if [[ "${USER_CHOICE}" == "r" || "${USER_CHOICE}" == "R" ]]; then
  echo "Reversing gateway state..."
  exec bash "$0"
fi

echo -e "\nYou can close this terminal window now."
