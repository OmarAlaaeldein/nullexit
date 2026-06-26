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
      reset_dns
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

# Resolve Tailscale CLI on host. We rely on the standalone Homebrew formula
# (`brew install tailscale` + `brew services start tailscale`) — NOT the
# Tailscale.app GUI — so there is no .app bundle or Network Extension sandbox
# to launch, no menu-bar click to perform, and no scutil Network Service to
# start manually. tailscaled runs as a per-user LaunchAgent (or LaunchDaemon
# if you ran the install with sudo) and the control socket is always available.
TS_BIN=""
if command -v tailscale >/dev/null 2>&1; then
  TS_BIN="tailscale"
fi

# Persistently disable Tailscale DNS management at the daemon level.
# Unlike `--accept-dns=false` on individual `tailscale up` calls (which is
# per-session and often ignored during exit-node transitions), `tailscale set`
# writes a preference that survives across `tailscale up` / `tailscale down`
# cycles. The daemon will NEVER touch macOS DNS after this — all DNS control
# belongs to `networksetup` / `force_dns_to_gateway`.
#
# Runs once at script start while tailscaled is still connected (if it was
# left running from a previous toggle), so the persistent pref takes effect
# before any disconnection or reconnection logic.
if [ -n "$TS_BIN" ]; then
  $TS_BIN set --accept-dns=false >/dev/null 2>&1 || true
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
    run_with_timeout 10 $TS_BIN down >/dev/null 2>&1 || true
  fi
}

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

# Resolve the service name for en0 (usually "Wi-Fi") — macOS scutil DNS resolver
# is commonly scoped to en0, so per-service DNS changes on other interfaces are
# ignored unless en0's service is also updated.
EN0_SERVICE=$(networksetup -listnetworkserviceorder 2>/dev/null | grep -B1 "Device: en0" | head -1 | sed -E 's/^\([0-9\*]+\) //' || true)
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
        networksetup -setsearchdomains "$dns_svc" "Empty" 2>/dev/null || true
        networksetup -setdnsservers "$dns_svc" 1.1.1.1 2>/dev/null || true
      done
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
    entries=$(networksetup -getdnsservers "$ACTIVE_SERVICE" 2>/dev/null \
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
echo "Initializing DNS to 1.1.1.1 to ensure reliable internet access..."
reset_dns

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

  # The host's DNS was hijacked to the gateway IP during ENABLE; now that the
  # gateway is down, restore DNS to 1.1.1.1 immediately so subsequent lookups
  # don't stall for the macOS DNS timeout before the 1.1.1.1 fallback engages.
  echo -e "\nRestoring host DNS to 1.1.1.1 (gateway is gone)... "
  reset_dns

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
  TS_IP=$(cat ADGUARD_IP.txt 2>/dev/null | tr -d '\r' | awk 'NR==1{print $1; exit}' || true)
  if [ -n "$TS_IP" ]; then
    echo "Using static IP from ADGUARD_IP.txt: $TS_IP"
  elif [ "$connected" = "true" ]; then
    TS_IP=$(run_with_timeout 10 docker compose exec -T tailscale tailscale ip -4 2>/dev/null | tr -d '\r' | awk 'NR==1{print $1; exit}' || true)
    if [ -n "$TS_IP" ]; then
      echo "[Fallback] Resolved gateway Tailscale IP dynamically: $TS_IP"
    fi
  fi

  # 7. Connect host Mac to Tailscale mesh.
  # With the standalone tailscaled daemon (registered as a per-user LaunchAgent or
  # system LaunchDaemon via 'brew services start tailscale'), the previous five-
  # phase flow (launch .app GUI → click menu bar System-Events → poll daemon →
  # `tailscale up --exit-node=` → `scutil --nc start "Tailscale"` Network Extension)
  # collapses into two trivial CLI calls. There is no .app GUI to launch, no menu
  # bar item to click, no Network Extension sandbox to unstick, and no Accessibility
  # permission required. We just verify the daemon socket is responsive, then join
  # the mesh without an exit-node so the host can safely reach the gateway's
  # 100.x.x.x IP (AdGuard) before the DNS hijack below takes effect.
  if [ -n "$TS_BIN" ]; then
    echo -n "Verifying tailscaled is reachable"
    daemon_ready=false
    for i in {1..15}; do
      if run_with_timeout 3 $TS_BIN status >/dev/null 2>&1; then
        daemon_ready=true
        break
      fi
      echo -n "."
      sleep 1
    done
    echo ""

    if [ "$daemon_ready" = "true" ]; then
      echo "tailscaled is responsive (running as a system service)."
    else
      echo "[Warning] tailscaled did not respond. Run 'brew services start tailscale'"
      echo "         (or 'sudo brew services start tailscale' for system-wide) and re-run this script."
    fi

    # `tailscale up --exit-node=` is idempotent: if we're already on the mesh it just
    # clears any stale exit-node preference; if we're not yet on the mesh it joins
    # without one. Either way, the host can now safely reach the gateway's IP via
    # the Tailscale mesh. DNS is left alone because of the persistent `set` above.
    echo "Joining Tailscale mesh without exit-node (so host can safely reach $TS_IP)..."
    joined=false
    for i in {1..5}; do
      if run_with_timeout 5 $TS_BIN up --reset --exit-node= >/dev/null 2>&1; then
        joined=true
        break
      fi
      sleep 1
    done
    if [ "$joined" = "true" ]; then
      echo "Host is on Tailscale mesh (no exit-node)."
    else
      echo "[Warning] tailscale up failed; will continue anyway."
    fi
  else
    echo -e "\n[Warning] tailscale CLI not found on PATH. Skipping host Tailscale configuration..."
  fi

  # 8. Apply DNS Hijacking.
  # With the standalone daemon (no .app GUI / Network Extension), Tailscale's
  # `tailscale up --accept-dns=true` *no longer* keeps DNS settings sticky for
  # us. So we manually replicate what the .app would have done:
  #   - Search domain `ts.net` → MagicDNS names like `omars-macbook` resolve via
  #                              our gateway (AdGuard forwards to Tailscale).
  #   - DNS server: $TS_IP     → AdGuard Home runs blocklists + MagicDNS.
  # We deliberately set NO fallback (no 1.1.1.1 alongside). Anything in the
  # resolver list other than $TS_IP creates a route for queries to silently
  # leak past the gateway's ad-blocking on the first failure. `force_dns_to_gateway`
  # sets AND verifies the live state via `networksetup -getdnsservers`.
  if [ -n "$TS_IP" ]; then
    echo -e "\nHijacking host DNS to point ONLY at AdGuard Home ($TS_IP)..."
    echo "Setting MagicDNS search domain 'ts.net' so tailnet hostnames resolve..."
    if force_dns_to_gateway "$TS_IP"; then
      echo "DNS hijack verified: single server = $TS_IP."
    else
      echo "[Warning] DNS hijack could not be verified."
      echo "          Run: networksetup -setdnsservers \"$ACTIVE_SERVICE\" $TS_IP"
    fi
  else
    echo -e "\n[Warning] Could not resolve gateway Tailscale IP. DNS hijacking skipped."
  fi

  # 9. Apply Tailscale Exit Node routing and verify the host actually came back online.
  if [ "$USE_EXIT_NODE" != "false" ]; then
    if [ -n "$TS_BIN" ] && [ -n "$TS_IP" ]; then
      echo -e "\nRouting host internet through Tailscale exit node '$TS_IP'..."
      # The persistent `tailscale set --accept-dns=false` above means this
      # exit-node transition won't clobber DNS — no `--accept-dns` flag needed.
      exit_node_enabled=false
      for i in {1..5}; do
        if run_with_timeout 10 $TS_BIN up --reset --exit-node="$TS_IP" --exit-node-allow-lan-access=true >/dev/null 2>&1; then
          exit_node_enabled=true
          break
        fi
        sleep 1
      done

      if [ "$exit_node_enabled" = "true" ]; then
        if run_with_timeout 5 $TS_BIN status >/dev/null 2>&1; then
          echo "Host exit-node routing is active."
        else
          echo "[Warning] Exit-node command succeeded, but Tailscale still does not appear online."
        fi
      else
        echo "[Warning] Failed to enable exit-node routing before exit."
      fi
    fi
  else
    echo -e "\nSkipping exit-node routing (GATEWAY_USE_EXIT_NODE is set to false)."
  fi

  # 10. Final DNS re-force + verify.
  # Step 9's `tailscale up --exit-node=...` may still trigger a brief DNS
  # reset on macOS during the exit-node routing-table transition even though
  # `tailscale set --accept-dns=false` is configured. Without a re-force
  # at the tail, the script exits with the gateway ON yet the host's resolver
  # sitting back on 1.1.1.1 (or whatever stale value step 8 lost to the race).
  if [ -n "$TS_IP" ]; then
    echo -e "\nFinal DNS re-force (kills any 1.1.1.1 that snuck back in)..."
    if force_dns_to_gateway "$TS_IP"; then
      echo "Final DNS state verified: $TS_IP (single server, no 1.1.1.1)."
    else
      echo "[Warning] Final DNS could not be locked at $TS_IP."
      echo "          Run: networksetup -setdnsservers \"$ACTIVE_SERVICE\" $TS_IP"
      echo "          (Note: re-running ./toggle.sh would STOP the gateway — it detects the active state and tears down — so don't use it as a recovery command.)"
    fi
  fi

  echo -e "\nGateway has been successfully STARTED."
fi

SUCCESS_RUN=true

# Final DNS state summary
if [ -n "$ACTIVE_SERVICE" ]; then
  FINAL_DNS=$(networksetup -getdnsservers "$ACTIVE_SERVICE" 2>/dev/null || true)
  echo -e "\n──────────────────────────────────────────────"
  echo -e "DNS STATE: $FINAL_DNS"
  echo -e "──────────────────────────────────────────────"
fi

echo -e "\nYou can close this terminal window now."
