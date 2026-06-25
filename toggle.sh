#!/bin/bash
# toggle.sh — nullexit gateway toggle script for macOS
# Automatically handles Docker containers, Colima, DNS hijacking, and Tailscale exit node routing.

set -e

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
    if kill -0 "$cmd_pid" 2>/dev/null; then
      echo -e "\n[Timeout] Command '$*' exceeded $timeout_sec seconds. Terminating..." >&2
      kill -15 "$cmd_pid" 2>/dev/null || true
      sleep 2
      if kill -0 "$cmd_pid" 2>/dev/null; then
        kill -9 "$cmd_pid" 2>/dev/null || true
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
  kill "$watcher_pid" 2>/dev/null && wait "$watcher_pid" 2>/dev/null
  
  CURRENT_BG_PID=""
  return "$exit_status"
}

# Helper function to run a GUI command as the logged-in console user
# (Prevents permission failures if the script is run with sudo)
run_gui_cmd() {
  local console_user
  console_user=$(stat -f '%Su' /dev/console 2>/dev/null || echo "$SUDO_USER")
  if [ -z "$console_user" ] || [ "$console_user" = "root" ]; then
    console_user=$(logname 2>/dev/null || echo "$USER")
  fi

  if [ -n "$console_user" ] && [ "$console_user" != "root" ] && [ "$EUID" -eq 0 ]; then
    sudo -u "$console_user" "$@"
  else
    "$@"
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
      sudo networksetup -setdnsservers "$ACTIVE_SERVICE" 1.1.1.1 2>/dev/null || true
    fi
    
    if [ -n "$CURRENT_BG_PID" ]; then
      echo "Terminating active command (PID $CURRENT_BG_PID)..."
      kill -15 "$CURRENT_BG_PID" 2>/dev/null || true
    fi

    # Disconnect host Tailscale and close the GUI application on failure
    disconnect_tailscale_host
    
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

# Add Homebrew and standard paths
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Resolve Tailscale binary on host
TS_BIN=""
if command -v tailscale >/dev/null 2>&1; then
  TS_BIN="tailscale"
elif [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
  TS_BIN="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
fi

# Function to get the active network service name (e.g., "Wi-Fi" or "USB 10/100 LAN")
get_active_service() {
  local iface
  iface=$(route get default 2>/dev/null | awk '/interface:/ {print $2}')
  
  # If the default interface is empty or a VPN tunnel (like utunX), fallback to the active physical interface
  if [[ -z "$iface" || ! "$iface" =~ ^en[0-9]+$ ]]; then
    for i in en0 en1 en2 en3; do
      if ifconfig "$i" 2>/dev/null | grep -q "status: active" && ifconfig "$i" 2>/dev/null | grep -q "inet "; then
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

# Ensure DNS is set to 1.1.1.1 immediately at script start to prevent any DNS deadlocks/hangs
# during status checks, container startup, VM boot, or teardown.
echo "Initializing DNS to 1.1.1.1 to ensure reliable internet access..."
echo "You may be prompted for your macOS admin password:"
sudo networksetup -setdnsservers "$ACTIVE_SERVICE" 1.1.1.1 2>/dev/null || true

# Disconnect host Tailscale cleanly and stop VPN extension synchronously to prevent race conditions
disconnect_tailscale_host() {
  # 1. Clear exit-node preference
  if [ -n "$TS_BIN" ]; then
    echo "Clearing Tailscale exit-node routing on host..."
    run_with_timeout 10 $TS_BIN up --exit-node= >/dev/null 2>&1 || true
  fi
  
  # 2. Stop macOS VPN tunnel first while daemon/GUI are fully responsive
  if command -v scutil >/dev/null 2>&1; then
    echo "Disconnecting macOS Tailscale VPN tunnel interface..."
    run_with_timeout 10 scutil --nc stop "Tailscale" >/dev/null 2>&1 || true
    sleep 1.5
  fi

  # 3. Disconnect host Tailscale CLI
  if [ -n "$TS_BIN" ]; then
    echo "Disconnecting host Tailscale..."
    run_with_timeout 10 $TS_BIN down >/dev/null 2>&1 || true
  fi

  # 4. Gracefully quit the Tailscale GUI application
  if pgrep -x "Tailscale" >/dev/null; then
    echo "Closing Tailscale GUI application..."
    run_gui_cmd osascript -e 'tell application "Tailscale" to quit' 2>/dev/null || true
    sleep 1.5
    if pgrep -x "Tailscale" >/dev/null; then
      echo "AppleScript quit failed, falling back to pkill..."
      pkill -x "Tailscale" 2>/dev/null || true
      sleep 0.5
      if pgrep -x "Tailscale" >/dev/null; then
        killall "Tailscale" 2>/dev/null || true
      fi
    fi
  fi
}


# Check if the gateway is active (either containers are running, or host DNS is hijacked)
is_gateway_active() {
  # 1. Check if containers are running
  if run_with_timeout 15 docker compose ps --status running | grep -q 'warp'; then
    return 0
  fi
  # 2. Check if host DNS is hijacked (not 1.1.1.1 and not default/empty)
  local current_dns
  current_dns=$(networksetup -getdnsservers "$ACTIVE_SERVICE" 2>/dev/null || true)
  if [[ -n "$current_dns" && "$current_dns" != "1.1.1.1" && ! "$current_dns" =~ "There aren't any DNS Servers" ]]; then
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
  run_with_timeout 30 docker compose down -t 5

  echo -e "\nGateway has been successfully STOPPED."
else
  echo -e "\n=============================================="
  echo "Gateway is STOPPED. Starting it now..."
  echo -e "==============================================\n"

  # 1. Prevent host exit-node deadlock during VM / Container startup
  disconnect_tailscale_host

  # 2. Compile DNS filter rules
  echo -e "\nCompiling DNS filter rules..."
  if command -v python3 >/dev/null 2>&1; then
    python3 sync-rules.py || echo "Warning: Failed to compile DNS filter rules, proceeding with existing compilation..."
  elif command -v python >/dev/null 2>&1; then
    python sync-rules.py || echo "Warning: Failed to compile DNS filter rules, proceeding with existing compilation..."
  else
    echo "Warning: Python not found. Skipping DNS rule compilation."
  fi

  # 3. Boot Colima VM if it is not already running
  echo -e "\nChecking Colima VM status..."
  if ! run_with_timeout 15 colima status >/dev/null 2>&1; then
    echo "Colima is not running. Starting Colima (0.6GB RAM allocation)..."
    run_with_timeout 120 colima start --memory 0.6
  else
    echo "Colima is already running."
  fi

  # 4. Clean up corrupted AdGuardHome configurations
  if [ -f "adguard/conf/AdGuardHome.yaml" ] && [ ! -s "adguard/conf/AdGuardHome.yaml" ]; then
    rm -f "adguard/conf/AdGuardHome.yaml"
    echo "Removed corrupted empty AdGuardHome.yaml to prevent container crash loop."
  fi

  # 5. Start compose services
  echo -e "\nStarting Docker containers..."
  run_with_timeout 60 docker compose up -d

  # 6. Wait for the gateway container's Tailscale connection to be ready
  BYPASS_PING=$(grep -E "^GATEWAY_BYPASS_PING=" .env 2>/dev/null | cut -d'=' -f2- | tr -d '"'\' | tr '[:upper:]' '[:lower:]')
  USE_EXIT_NODE=$(grep -E "^GATEWAY_USE_EXIT_NODE=" .env 2>/dev/null | cut -d'=' -f2- | tr -d '"'\' | tr '[:upper:]' '[:lower:]')

  echo -n "Waiting for gateway container's Tailscale connection to be ready"
  connected=false
  for i in {1..30}; do
    # Query the container directly via Docker socket (works while host Tailscale is fully closed)
    if run_with_timeout 5 docker compose exec -T tailscale tailscale status 2>/dev/null | grep -q "offers exit node"; then
      connected=true
      break
    fi
    echo -n "."
    sleep 1
  done
  echo ""

  if [ "$connected" = "true" ]; then
    echo "Gateway container is online on the Tailscale mesh."
  elif [ "$BYPASS_PING" = "true" ]; then
    echo "[Warning] Gateway container check timed out. Proceeding anyway (GATEWAY_BYPASS_PING is true)..."
  else
    echo "ERROR: Gateway container failed to initialize Tailscale (timed out)." >&2
    cleanup_handler ERR $LINENO
    exit 1
  fi

  # 6b. Derive the gateway's Tailscale IP dynamically from the container.
  # This replaces the old static ADGUARD_IP.txt file, which was fragile
  # because Tailscale IPs are stable but not guaranteed across re-auths.
  TS_IP=""
  if [ "$connected" = "true" ]; then
    TS_IP=$(run_with_timeout 10 docker compose exec -T tailscale tailscale ip -4 2>/dev/null | head -1 || true)
  fi
  # Fall back to ADGUARD_IP.txt if the dynamic query fails (e.g. container exec is broken)
  if [ -z "$TS_IP" ]; then
    TS_IP=$(cat ADGUARD_IP.txt 2>/dev/null || true)
    if [ -n "$TS_IP" ]; then
      echo "[Fallback] Using static IP from ADGUARD_IP.txt: $TS_IP"
    fi
  else
    echo "Resolved gateway Tailscale IP dynamically: $TS_IP"
  fi

  # 7. Connect host Mac to Tailscale mesh
  # Ensure the Tailscale GUI application is open and running
  if [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ] || [ -d /Applications/Tailscale.app ]; then
    echo "Ensuring Tailscale GUI app is open..."
    run_gui_cmd osascript -e 'tell application "Tailscale" to activate' 2>/dev/null || \
    run_gui_cmd open "/Applications/Tailscale.app" 2>/dev/null || \
    run_gui_cmd open -a "Tailscale" 2>/dev/null
    sleep 2
  fi

  # Clear exit-node preference to prevent immediate deadlock upon tunnel connection
  if [ -n "$TS_BIN" ]; then
    echo "Clearing exit-node preference on startup..."
    for i in {1..15}; do
      if run_with_timeout 5 $TS_BIN up --exit-node= >/dev/null 2>&1; then
        echo "Exit-node preference cleared."
        break
      fi
      sleep 0.2
    done
  else
    echo -e "\n[Warning] Tailscale CLI not found on host. Skipping CLI-based exit-node initialization..."
  fi

  # Force the macOS Network Extension VPN tunnel to start and connect
  if command -v scutil >/dev/null 2>&1; then
    echo "Forcing macOS Tailscale VPN tunnel interface to start..."
    run_with_timeout 10 scutil --nc start "Tailscale" 2>/dev/null || true
    sleep 1.5
  fi

  # 8. Apply DNS Hijacking
  if [ -n "$TS_IP" ]; then
    echo -e "\nHijacking DNS to route through AdGuard Home ($TS_IP)..."
    echo "You may be prompted for your macOS admin password:"
    sudo networksetup -setdnsservers "$ACTIVE_SERVICE" "$TS_IP" 2>/dev/null || true
  else
    echo -e "\n[Warning] Could not resolve gateway Tailscale IP. DNS hijacking skipped."
  fi

  # 9. Apply Tailscale Exit Node routing (in the background so it activates after script exit)
  if [ "$USE_EXIT_NODE" != "false" ]; then
    if [ -n "$TS_BIN" ] && [ -n "$TS_IP" ]; then
      echo -e "\nRouting host internet through Tailscale exit node '$TS_IP' (activating in background)..."
      $TS_BIN up --exit-node="$TS_IP" --exit-node-allow-lan-access=true >/dev/null 2>&1 &
    fi
  else
    echo -e "\nSkipping exit-node routing (GATEWAY_USE_EXIT_NODE is set to false)."
  fi

  echo -e "\nGateway has been successfully STARTED."
fi

SUCCESS_RUN=true

echo -e "\nYou can close this terminal window now."
