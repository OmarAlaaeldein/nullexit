#!/bin/bash
# recover.sh — nullexit KILL-SWITCH recovery script (macOS + Linux)
# Fixes internet when toggle.sh leaves you stranded.
#
# This is a NUCLEAR option: it undoes EVERYTHING toggle.sh does by:
#   1. Disconnecting host Tailscale from the mesh (exit-node off)
#   2. Resetting DNS to default on ALL network services
#   3. Disabling rogue proxy settings (SOCKS, web, secure web)
#   4. Flushing the DNS cache
#   5. Flushing stale routing table entries
#   6. Stopping gateway Docker containers
#   7. Power-cycling Wi-Fi
#   8. Verifying internet is working
#
# One file, both OSes: the dispatch below runs the self-contained Linux
# recovery and exits; on macOS it falls through to the richer dual-mode
# implementation (default teardown / --post-wake refresh).
#
# Usage:  double-click Recover-Gateway.applescript
#         OR  ./recover.sh
#         OR  ./recover.sh --post-wake    (macOS only — lighter refresh, keeps gateway live)

set -e

# ─── Resolve script directory (used for path-relative refs) ─────────────────
# recover.sh lives at the repo root; SCRIPT_DIR lets us launch toggle.sh
# (and reference any other repo-root file) from the same directory no
# matter where the user invoked recover.sh from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

# ═══════════════════════════════════════════════════════════════════════════
# LINUX RECOVERY — self-contained; runs the full teardown then exits before the
# macOS body below. Native Linux tooling (resolvectl / nmcli / ip) throughout.
# ═══════════════════════════════════════════════════════════════════════════
if [[ "$OSTYPE" != "darwin"* ]]; then
  # Source common formatting and helper functions
  source "$SCRIPT_DIR/scripts/common.sh"

  # Always add Homebrew path
  export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

  echo ""
  echo -e "${RED}${BOLD}╔══════════════════════════════════════════╗${NC}"
  echo -e "${RED}${BOLD}║     Nullexit Gateway — RECOVERY MODE     ║${NC}"
  echo -e "${RED}${BOLD}╚══════════════════════════════════════════╝${NC}"
  echo ""
  echo "This script will tear down the gateway and restore normal internet."
  echo ""

  # ─── Cache sudo credentials upfront ─────────────────────────────────────────
  # Prevents the script from hanging halfway through when it needs to run
  # privileged commands (route flush, Wi-Fi power cycle, etc.).
  echo -e "${YELLOW}${BOLD}Authentication required for network recovery...${NC}"
  sudo -v
  (
    while true; do
      sudo -n true 2>/dev/null
      sleep 60
    done
  ) &
  SUDO_KEEPER_PID=$!
  trap 'kill $SUDO_KEEPER_PID 2>/dev/null' EXIT

  # ─── 1. Disconnect host Tailscale ───────────────────────────────────────────
  step "Disconnecting host Tailscale from mesh"
  if command -v tailscale >> output.log 2>&1; then
    # Check if actually connected first (with timeout — tailscaled could be wedged)
    if run_with_timeout 5 tailscale status >> output.log 2>&1; then
      # Also explicitly reset any exit-node so it doesn't linger.
      if run_with_timeout 10 tailscale up --reset --ssh=true --accept-dns=false --exit-node= >> output.log 2>&1; then
        ok "Exit-node preference cleared"
      else
        warn "tailscale up --reset didn't respond (tailscaled may be wedged)"
      fi
      ts_args=""
      if is_kill_switch_enabled; then ts_args="--accept-risk=lose-ssh"; fi
      if run_with_timeout 10 tailscale down $ts_args >> output.log 2>&1; then
        ok "Tailscale disconnected"
      else
        warn "tailscale down didn't respond"
      fi
    else
      warn "tailscaled not reachable — skipping (timeout after 5s)"
    fi
  else
    warn "tailscale CLI not found — skipping"
  fi

  # ─── 2. Reset DNS to default on ALL network services ─────────────────────────
  step "Resetting DNS to default on active interface"

  ACTIVE_SERVICE=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')
  if [ -n "$ACTIVE_SERVICE" ]; then
    sudo resolvectl revert "$ACTIVE_SERVICE" 2>> output.log || true
    ok "DNS reset on $ACTIVE_SERVICE"
  else
    warn "Could not determine active network interface"
  fi

  # ─── 3. Disable rogue proxy settings ─────────────────────────────────────────
  step "Disabling proxy settings (SOCKS, web, secure web)"
  echo "  (Linux global SOCKS proxy configuration skipped.)"
  ok "Proxy settings cleared"


  # ─── 4. Flush DNS cache ──────────────────────────────────────────────────────
  step "Flushing DNS cache"
  if command -v resolvectl >> output.log 2>&1; then
    sudo resolvectl flush-caches 2>> output.log || true
    ok "DNS cache flushed"
  else
    warn "resolvectl not found"
  fi

  # ─── 5. Clear stale routing table ────────────────────────────────────────────
  step "Flushing stale routing table entries"
  sudo ip route flush cache >> output.log 2>&1 || true
  ok "Routing table flushed"

  # ─── 6. Stop gateway Docker containers ────────────────────────────────────────
  step "Stopping gateway Docker containers"
  if command -v docker >> output.log 2>&1 && docker info >> output.log 2>&1; then
    if [ -f "docker-compose.yml" ]; then
      docker compose down -t 5 2>> output.log && ok "Containers stopped" || warn "No containers were running"
    else
      warn "docker-compose.yml not found in current directory"
    fi
  else
    warn "Docker not available — skipping"
  fi

  # ─── 6b. Stopping sleep prevention (systemd-inhibit) ──────────────────────────────
  step "Stopping sleep prevention"
  PID_FILE="/tmp/nullexit-caffeinate.pid"
  if [ -f "$PID_FILE" ]; then
    INHIBIT_PID=$(cat "$PID_FILE")
    if [ -n "$INHIBIT_PID" ] && kill -0 "$INHIBIT_PID" 2>/dev/null; then
      kill "$INHIBIT_PID" 2>/dev/null || true
      ok "Sleep prevention stopped (PID $INHIBIT_PID)"
    else
      warn "Sleep prevention process not running, cleaning up stale PID file"
    fi
    rm -f "$PID_FILE"
  else
    ok "Sleep prevention was not active"
  fi

  # ─── 7. Power-cycle Wi-Fi ────────────────────────────────────────────────────
  step "Power-cycling Wi-Fi"
  if command -v nmcli &>/dev/null; then
    sudo nmcli radio wifi off 2>> output.log || true
    sleep 2
    sudo nmcli radio wifi on 2>> output.log || true
    ok "Wi-Fi bounced via nmcli"
    sleep 3
  else
    warn "nmcli not found. Falling back to ip link..."
    WIFI_IFACE=$(ip link | grep -E '^[0-9]+: (wl[a-zA-Z0-9]+|wlan[0-9]+):' | awk -F': ' '{print $2}')
    if [ -n "$WIFI_IFACE" ]; then
      sudo ip link set "$WIFI_IFACE" down 2>> output.log || true
      sleep 2
      sudo ip link set "$WIFI_IFACE" up 2>> output.log || true
      ok "Wi-Fi bounced via ip link (interface $WIFI_IFACE)"
      sleep 3
    else
      warn "No Wi-Fi interface detected."
    fi
  fi

  # ─── 8. Verify internet connectivity ──────────────────────────────────────────
  verify_internet_connectivity

  # ─── Summary ──────────────────────────────────────────────────────────────────
  echo ""
  echo -e "${BOLD}──────────────────────────────────────────────${NC}"
  echo -e "${BOLD}RECOVERY SUMMARY${NC}"
  echo -e "${BOLD}──────────────────────────────────────────────${NC}"

  # Show final DNS state
  FINAL_DNS=$(resolvectl dns "$ACTIVE_SERVICE" 2>> output.log | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tr '\n' ' ' || echo "N/A")
  echo "  DNS ($ACTIVE_SERVICE):  $FINAL_DNS"

  echo ""

  if [ "$INTERNET_OK" = "true" ]; then
    echo -e "  ${GREEN}${BOLD}✓ Internet is working.${NC}"
  else
    echo -e "  ${YELLOW}${BOLD}⚠ Could not verify internet connectivity.${NC}"
    echo "    This might mean:"
    echo "    - Your Wi-Fi is disconnected from the router"
    echo "    - Tailscale is still interfering (try restarting tailscaled:"
    echo "        systemctl restart tailscaled)"
    echo "    - You need to re-connect to Wi-Fi in the menu bar"
    echo "    - Try toggling Wi-Fi off/on in the menu bar"
    echo ""
    echo "    Or try manually:"
    echo "      resolvectl revert $ACTIVE_SERVICE"
    extra_args=""
    if is_kill_switch_enabled; then extra_args="--accept-risk=lose-ssh"; fi
    echo "      tailscale down $extra_args"
    echo "      sudo ip route flush cache"
    echo "      systemctl restart tailscaled"
  fi

  echo ""
  echo -e "${GREEN}${BOLD}Recovery complete.${NC}"
  echo ""

  exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# macOS RECOVERY (dual-mode: default teardown / --post-wake refresh)
# ═══════════════════════════════════════════════════════════════════════════

# Enforce Cryptographic Script Integrity
if [ -f "scripts/crypto.sh" ]; then
  if ! bash scripts/crypto.sh --verify; then
    exit 1
  fi
fi

# ─── Argument parsing ───────────────────────────────────────────────────────
# --post-wake: lightweight refresh after sleep/wake or Wi-Fi roam.
#              Keeps the gateway live while HUPing DNS caches, refreshing the
#              Tailscale exit-node leak, re-hijacking host DNS, and force-
#              recreating the warp container if its gluetun healthcheck failed.
#              Does NOT tear down Docker, Tailscale, sleep prevention, or Wi-Fi.
#              Called from scripts/watcher.sh on every wake / network-change event
#              while /tmp/nullexit-gateway-active.marker is present (i.e. the
#              gateway is currently up). See devref.md §10.29 for the why.
POST_WAKE=false
AUTO_MODE=false
for arg in "$@"; do
  if [ "$arg" = "--post-wake" ]; then
    POST_WAKE=true
  elif [ "$arg" = "--auto" ] || [ "$arg" = "--non-interactive" ]; then
    AUTO_MODE=true
  fi
done

rm -f "$SCRIPT_DIR/TUNNEL_FAILED_CLOSED.marker"

# Prevent concurrent execution of lifecycle scripts (toggle.sh / recover.sh)
LOCK_FILE="/tmp/nullexit-toggle.lock"
if [ -f "$LOCK_FILE" ]; then
  LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
  if [ -n "$LOCK_PID" ] && [ "$LOCK_PID" != "$$" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    if ps -p "$LOCK_PID" -o args= 2>/dev/null | grep -q -E "toggle\.sh|recover\.sh"; then
      if [ "$POST_WAKE" = "true" ]; then
        echo "[$(date -u +%FT%TZ)] POST-WAKE skipped: another lifecycle script (PID $LOCK_PID) is running." >> output.log
        exit 0
      else
        echo "Error: Another instance of toggle.sh or recover.sh (PID $LOCK_PID) is already running." >&2
        exit 1
      fi
    fi
  fi
fi
echo "$$" > "$LOCK_FILE"

# Clear the active-state marker in nuclear recovery mode since the gateway is being
# completely torn down. This prevents scripts/watcher.sh from triggering post-wake
# recoveries in response to network changes caused by the teardown itself.
if [ "$POST_WAKE" = "false" ]; then
  rm -f "/tmp/nullexit-gateway-active.marker"
fi

# WARP Watcher inhibit marker: written immediately in --post-wake mode so the
# background WARP Watcher (in toggle.sh) skips failure counting while we are
# intentionally tearing down / recreating the warp container. Without this, the
# watcher accumulates 6 consecutive warp=off readings during force-recreate (~35s)
# and fires nuclear recover.sh, killing a gateway that would have been healthy.
WARP_INHIBIT_FILE="/tmp/nullexit-warp-inhibit.marker"
if [ "$POST_WAKE" = "true" ]; then
  touch "$WARP_INHIBIT_FILE"
  echo "[$(date -u +%FT%TZ)] POST-WAKE started — WARP Watcher inhibited to prevent spurious shutdown during warp recreate." >> output.log
fi

# Ensure the inhibit marker and lock file are always removed when the script exits (success or error)
cleanup_recover() {
  rm -f "$WARP_INHIBIT_FILE"
  if [ -f "$LOCK_FILE" ] && [ "$(cat "$LOCK_FILE" 2>/dev/null)" = "$$" ]; then
    rm -f "$LOCK_FILE"
  fi
}
trap cleanup_recover EXIT

# Source common formatting and helper functions
source "$SCRIPT_DIR/scripts/common.sh"

# Always add Homebrew path
setup_standard_path

echo ""
if [ "$POST_WAKE" = "true" ]; then
  echo -e "${YELLOW}${BOLD}╔══════════════════════════════════════════╗${NC}"
  echo -e "${YELLOW}${BOLD}║  Nullexit — POST-WAKE / POST-ROAM LIGHT ${NC}"
  echo -e "${YELLOW}${BOLD}║  (keeps the gateway live, refreshes)    ${NC}"
  echo -e "${YELLOW}${BOLD}╚══════════════════════════════════════════╝${NC}"
  echo ""
  echo "Re-hijacking DNS, refreshing Tailscale exit-node, force-recreating"
  echo "warp if unhealthy, and resetting sharing services. The gateway stays"
  echo "up. docker compose / Wi-Fi / caffeinate are NOT touched."
  echo ""
else
  echo -e "${RED}${BOLD}╔══════════════════════════════════════════╗${NC}"
  echo -e "${RED}${BOLD}║     Nullexit Gateway — RECOVERY MODE     ║${NC}"
  echo -e "${RED}${BOLD}╚══════════════════════════════════════════╝${NC}"
  echo ""
  echo "This script will tear down the gateway and restore normal internet."
  echo ""
fi

# ─── Cache sudo credentials upfront (default mode ONLY) ────────────────────
# Skip in --post-wake: the LaunchAgent-launched watcher has no TTY, so `sudo -v`
# would block forever waiting for a password. All post-wake commands use `sudo -n`
# which is non-blocking and relies on /etc/sudoers.d/nullexit NOPASSWD entries.
SUDO_KEEPER_PID=""
if [ "$POST_WAKE" = "false" ] && [ "$AUTO_MODE" = "false" ] && [ -t 0 ]; then
  echo -e "${YELLOW}${BOLD}Authentication required for network recovery...${NC}"
  sudo -v
  (
    while true; do
      sudo -n true 2>/dev/null
      sleep 60
    done
  ) &
  SUDO_KEEPER_PID=$!
  trap 'kill $SUDO_KEEPER_PID 2>/dev/null' EXIT
fi

# ─── Resolve physical default interface and gateway upfront ─────────────────
PHYSICAL_IFACE=$(networksetup -listallhardwareports 2>> output.log | awk '/Hardware Port: (Wi-Fi|Ethernet)/{getline; print $2; exit}')
[ -z "$PHYSICAL_IFACE" ] && PHYSICAL_IFACE="en0"

if [ "$POST_WAKE" = "true" ]; then
  wait_for_dhcp_settle
else
  # Quick resolution in non-post-wake mode (non-blocking)
  PHYSICAL_GW=$(ipconfig getpacket "$PHYSICAL_IFACE" 2>> output.log | awk -F'[{}]' '/router /{print $2}')
fi

# ─── 1. Disconnect host Tailscale (default) / Refresh exit-node (post-wake) ─

if [ "$POST_WAKE" = "true" ]; then
  step "Refreshing host Tailscale exit-node routing (post-wake)"
  if command -v tailscale >> output.log 2>&1; then
    # Re-issue the SAME exit-node up command toggle.sh START uses. This refreshes
    # the DERP relay mapping and re-asserts the exit-node preference without
    # dropping the host's mesh connection (which `tailscale down` would).
    TS_IP=""
    for src in .gateway_ip; do
      [ -f "$src" ] || continue
      TS_IP=$(cat "$src" 2>> output.log | tr -d '\r' | awk 'NR==1{print $1; exit}' || true)
      [ -n "$TS_IP" ] && break
    done

    if [ -n "$TS_IP" ]; then
      step "Re-establishing exit node $TS_IP via 'tailscale set --exit-node'"
      # `tailscale set` only mutates the named preference (exit-node here).
      # Crucially it does NOT call --reset, which would re-apply ALL flags and
      # trigger a sub-second route-table re-evaluation cycle each post-wake.
      # On already-connected nodes, the lighter `set` keeps the existing tunnel
      # alive while only changing the exit-node preference.
      if run_with_timeout 15 tailscale set --exit-node="$TS_IP" \
                            --exit-node-allow-lan-access=true \
                            >> output.log 2>&1; then
        ok "Exit-node $TS_IP re-asserted via 'tailscale set'"
      else
        warn "tailscale set --exit-node=$TS_IP didn't respond; falling back to mesh-only"
        run_with_timeout 10 tailscale set --exit-node= \
                          >> output.log 2>&1 || true
      fi
    else
      warn ".gateway_ip missing — cannot re-assert exit node"
      run_with_timeout 10 tailscale up --reset --ssh=true --accept-dns=false --exit-node= \
                        >> output.log 2>&1 || true
    fi
  else
    warn "tailscale CLI not found"
  fi
else
  step "Disconnecting host Tailscale from mesh"
  disconnect_tailscale_host "tailscale"
fi

# ─── 2. Reset DNS to default on ALL network services (default) / Re-hijack gateway DNS (post-wake) ─
if [ "$POST_WAKE" = "true" ]; then
  step "Re-hijacking host DNS to gateway IP (post-wake / post-roam)"
  TS_IP=""
  for src in .gateway_ip; do
    [ -f "$src" ] || continue
    TS_IP=$(cat "$src" 2>> output.log | tr -d '\r' | awk 'NR==1{print $1; exit}' || true)
    [ -n "$TS_IP" ] && break
  done

  if [ -n "$TS_IP" ]; then
    # Detect the active network service (using helper in common.sh)
    ACTIVE_SVC=$(get_active_service)
    EN0_SVC=$(get_en0_service)

    networksetup -setsearchdomains "$ACTIVE_SVC" "ts.net" 2>> output.log || true
    networksetup -setdnsservers "$ACTIVE_SVC" "$TS_IP" 2>> output.log || true
    networksetup -setsearchdomains "$EN0_SVC" "ts.net" 2>> output.log || true
    networksetup -setdnsservers "$EN0_SVC" "$TS_IP" 2>> output.log || true

    HITS=$(networksetup -getdnsservers "$ACTIVE_SVC" 2>> output.log | grep -Fx "$TS_IP" || true)
    if [ -n "$HITS" ]; then
      ok "DNS re-hijacked to $TS_IP on services: $ACTIVE_SVC, $EN0_SVC"
    else
      warn "networksetup accepted but DNS read-back didn't include $TS_IP"
    fi
  else
    warn ".gateway_ip missing — cannot re-hijack DNS (user must run toggle.sh START)"
  fi
else
  step "Resetting DNS to default on all network services (empty = DHCP)"

  # Get ALL network services (handles spaces in names, skips disabled ones)
  SERVICES=$(networksetup -listallnetworkservices 2>> output.log | grep -v "^An asterisk" | grep -v "^$" || true)

  if [ -z "$SERVICES" ]; then
    # Fallback to common names
    SERVICES="Wi-Fi Ethernet Thunderbolt Ethernet USB 10/100 LAN"
  fi

  RESET_COUNT=0
  while IFS= read -r service; do
    # Strip leading asterisk (disabled services)
    service_clean=$(echo "$service" | sed 's/^\*//')
    [ -z "$service_clean" ] && continue

    # Check if this service has a hardware port (skip VPN/service-only entries)
    if networksetup -listallhardwareports 2>> output.log | grep -A1 "Port: $service_clean$" | grep -q "Device:" || [ "$service_clean" = "Wi-Fi" ]; then
      (
        networksetup -setsearchdomains "$service_clean" "Empty" 2>> output.log
        # Set to "empty" so macOS uses DHCP-assigned DNS (not hardcoded 1.1.1.1)
        sudo networksetup -setdnsservers "$service_clean" "empty" 2>> output.log
      ) && RESET_COUNT=$((RESET_COUNT + 1)) || true
    fi
  done <<< "$SERVICES"

  ok "DNS reset on $RESET_COUNT service(s)"
fi

# ─── 3. Disable rogue proxy settings (default only — gateway uses proxy in non-exit-node path) ─
if [ "$POST_WAKE" = "false" ]; then
  step "Disabling proxy settings (SOCKS, web, secure web)"
  for svc in $(networksetup -listallnetworkservices 2>> output.log | grep -v "^An asterisk" | grep -v "^$" || echo "Wi-Fi"); do
    svc_clean=$(echo "$svc" | sed 's/^\*//')
    [ -z "$svc_clean" ] && continue
    disable_all_proxies "$svc_clean"
  done
  ok "Proxy settings cleared"
else
  step "Proxy settings: leaving untouched (post-wake keeps gateway SOCKS wiring alive)"
fi

# ─── 4. Flush macOS DNS cache (always — safe and useful in both modes) ─────
step "Flushing DNS cache"
if command -v dscacheutil >> output.log 2>&1; then
  flush_dns_cache
  ok "DNS cache flushed (mDNSResponder HUP)"
else
  warn "dscacheutil not found"
fi

# ─── 5. Clear stale routing table (always — safe in both modes) ──────────
step "Flushing stale routing table entries"
# Resolve physical default gateway IP before flushing
# We cannot trust `route get default` here because Tailscale may have already hijacked
# the default route to utunX. We must read the actual DHCP router assignment from the hardware.
# PHYSICAL_IFACE and PHYSICAL_GW resolved upfront

# Instead of full route -n flush (which destroys macOS loopback/multicast and wedges the OS until reboot),
# we cleanly delete the Tailscale overrides and Cloudflare WARP bypass routes in ALL modes.
# This ensures tailscaled isn't blocked from reaching its control plane when waking from sleep.
sudo -n route delete -net 0.0.0.0/1 >> output.log 2>&1 || true
sudo -n route delete -net 128.0.0.0/1 >> output.log 2>&1 || true
remove_warp_bypass_routes
ok "Routing overrides cleared"

if [ "$POST_WAKE" = "false" ]; then
  disable_killswitch
  ok "Routing table flush completed via targeted deletes and firewall disabled"
else
  ok "Routing overrides cleared (post-wake mode to preserve Colima bridge100)"
fi

# In post-wake mode we don't bounce Wi-Fi, so we MUST manually restore the physical default route
if [ "$POST_WAKE" = "true" ] && [ -n "$PHYSICAL_GW" ]; then
  # Ensure physical gateway is set just in case it was dropped
  sudo -n route add default "$PHYSICAL_GW" >> output.log 2>&1 || true
fi

# CONDITIONAL BYPASS ROUTE RESTORATION:
# If this was a post-wake recovery and the exit node is active, the route flush
# just wiped the static bypass routes for the WARP endpoints. We must re-add
# them immediately to prevent a routing loop when Tailscale starts sending traffic.
if [ "$POST_WAKE" = "true" ]; then
  if [ -z "${ACTIVE_IF:-}" ]; then
    ACTIVE_IF=$(route get default 2>> output.log | awk '/interface:/{print $2; exit}')
    if [ -z "$ACTIVE_IF" ] || [[ "$ACTIVE_IF" =~ ^utun ]] || [[ "$ACTIVE_IF" =~ ^tun ]]; then
      for i in en0 en1 en2 en3; do
        if ifconfig "$i" 2>> output.log | grep -q 'status: active'; then
          ACTIVE_IF="$i"; break
        fi
      done
    fi
    [ -z "$ACTIVE_IF" ] && ACTIVE_IF="en0"
  fi
  
  echo "Re-adding host bypass routes for Cloudflare WARP endpoints..."
  remove_warp_bypass_routes
  if [ -n "${PHYSICAL_GW:-}" ]; then
    add_warp_bypass_routes "$PHYSICAL_GW"
  else
    add_warp_bypass_routes "$ACTIVE_IF"
  fi

  # Also re-apply the default route pointing to the Tailscale interface
  ts_iface=$(ifconfig 2>> output.log | grep -B4 "inet 100." | grep -E '^[a-z0-9]+' | cut -d: -f1 | head -n 1)
  if [ -n "$ts_iface" ]; then
    echo "Re-routing default gateway to $ts_iface using 0.0.0.0/1 split..."
    # DO NOT delete the physical default route! It crashes Colima.
    # Use the /1 trick to mathematically override the default route.
    sudo -n route delete -net 0.0.0.0/1 >> output.log 2>&1 || true
    sudo -n route delete -net 128.0.0.0/1 >> output.log 2>&1 || true
    sudo -n route add -net 0.0.0.0/1 -interface "$ts_iface" >> output.log 2>&1 || true
    sudo -n route add -net 128.0.0.0/1 -interface "$ts_iface" >> output.log 2>&1 || true
    enable_killswitch
  fi
fi

# ─── 6. Stop gateway Docker containers (default) / Force-recreate warp if unhealthy (post-wake) ─
if [ "$POST_WAKE" = "true" ]; then
  # ─── 6a. Check for Roaming Network Mismatch (Bridged vs Enterprise Wi-Fi) ─
  if [ -f "/tmp/nullexit_colima_mode.txt" ] && [ -f "$SCRIPT_DIR/../.lan_p2p_detected" ]; then
    current_colima_mode=$(cat /tmp/nullexit_colima_mode.txt)
    p2p_allowed=$(cat "$SCRIPT_DIR/../.lan_p2p_detected")
    required_colima_mode="bridged"
    [ "$p2p_allowed" == "false" ] && required_colima_mode="shared"
    
    if [ "$current_colima_mode" != "$required_colima_mode" ]; then
      warn "Network roaming mismatch detected!"
      warn "Colima is running in '$current_colima_mode' mode but new network requires '$required_colima_mode'."
      warn "Executing full gateway restart to protect against MAC-spoofing deauthentication..."
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] [Roam] Mismatch ($current_colima_mode vs $required_colima_mode). Triggering toggle.sh --restart." >> output.log
      nohup bash "$SCRIPT_DIR/../toggle.sh" --restart >/dev/null 2>&1 &
      exit 0
    fi
  fi

  step "Checking Colima VM state"
  colima_status=$(colima status 2>&1)
  if echo "$colima_status" | grep -qi "running"; then
    ok "Colima VM is running"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [Docker/Colima] Colima status check passed." >> output.log
  else
    warn "Colima VM is NOT running or unresponsive"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [Docker/Colima] Colima is unhealthy or dead! Output: $colima_status" >> output.log
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [Docker/Colima] Attempting to restart Colima..." >> output.log
    colima restart >> output.log 2>&1 || warn "Failed to restart Colima"
  fi

  step "Checking warp container health (gluetun UDP tunnel)"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [Docker/Colima] Inspecting warp container state..." >> output.log
  # The warp container is the most failure-prone link in the chain at wake/roam:
  # its UDP NAT binding to Cloudflare's edge (162.159.192.1:2408) silently dies
  # during a Wi-Fi roam. We verify the tunnel is actually passing traffic via curl.
  WARP_STATE=$(docker inspect --format '{{.State.Health.Status}}' warp 2>> output.log || echo "missing")
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [Docker/Colima] warp container status: $WARP_STATE" >> output.log
  
  if [ "$WARP_STATE" = "missing" ]; then
    warn "warp container is missing — leaving gateway containers alone (full relaunch requires \"$SCRIPT_DIR/toggle.sh\")"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [Docker/Colima] warp container missing from Docker engine. Requires full toggle.sh launch." >> output.log
  else
    tmp_err=$(mktemp)
    if docker compose exec -T warp wget -qO- --timeout=3 https://www.cloudflare.com/cdn-cgi/trace 2>"$tmp_err" | grep -q "warp=on"; then
      ok "warp container is healthy and actively tunneling traffic (no recreate needed)"
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] [Docker/Colima] warp container passed live traffic healthcheck (Cloudflare trace successful)." >> output.log
    else
      warn "warp container tunnel is dead (Docker status: $WARP_STATE) — force-recreating all gateway containers to restore network namespace"
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] [Docker/Colima] warp container is DEAD or STUCK. Forcing recreation of gateway stack..." >> output.log
      if [ -s "$tmp_err" ]; then
        err_msg=$(cat "$tmp_err" | tr -d '\r')
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [Docker/Colima] Healthcheck failure details: $err_msg" >> output.log
      fi
      docker compose up -d --force-recreate >> output.log 2>&1 || warn "force-recreate failed"
      
      NEW_STATE=$(docker inspect --format '{{.State.Health.Status}}' warp 2>> output.log || echo "missing")
      ok "warp container health after recreate: $NEW_STATE"
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] [Docker/Colima] warp container health after recreation: $NEW_STATE" >> output.log
    fi
    rm -f "$tmp_err"
  fi
else
  step "Stopping gateway Docker containers"
  if command -v docker >> output.log 2>&1 && docker info >> output.log 2>&1; then
    if [ -f "docker-compose.yml" ]; then
      docker compose down -t 5 2>> output.log && ok "Containers stopped" || warn "No containers were running"
    else
      warn "docker-compose.yml not found in current directory"
    fi
  else
    warn "Docker not available — skipping"
  fi
fi

# ─── 6b. Stopping sleep prevention (caffeinate) — default only ──────────────
if [ "$POST_WAKE" = "false" ]; then
  step "Stopping sleep prevention"
  stop_pidfile_daemon "$PID_CAFFEINATE" "system sleep prevention"
else
  step "Sleep prevention: leaving untouched (caffeinate already re-acquired by parent shell)"
fi

# ─── 6c. Stopping DNS Watcher — default only ────────────────────────────────
if [ "$POST_WAKE" = "false" ]; then
  step "Stopping DNS Watcher"
  stop_pidfile_daemon "$PID_DNS_WATCHER" "background DNS Watcher"
else
  step "DNS Watcher: leaving untouched (it keeps re-hijacking DNS on every roam)"
fi

# ─── 7. Power-cycle Wi-Fi — default only ────────────────────────────────────
if [ "$POST_WAKE" = "false" ]; then
  step "Power-cycling Wi-Fi"
  bounce_wifi_interfaces
else
  step "Wi-Fi: leaving untouched (post-wake keeps the current Wi-Fi association)"
fi

# ─── 8. Verify (default checks direct internet; post-wake verifies the gateway) ─
if [ "$POST_WAKE" = "true" ]; then
  step "Verifying gateway is healthy after post-wake refresh"

  # Wait a moment for tailscale + warp healthcheck to settle
  sleep 3

  GATEWAY_OK=false
  if command -v dig >> output.log 2>&1; then
    # Source procedural ports if available
    if [ -f "/tmp/nullexit-ports.env" ]; then
      source "/tmp/nullexit-ports.env"
    fi
    DNS_PORT=${DNS_PROXY_PORT:-5354}
    
    # AdGuard is exposed at localhost:${DNS_PORT}. If this resolves, the warp tunnel
    # is functioning properly because AdGuard routes upstream to warp.
    if dig +tcp @127.0.0.1 -p "$DNS_PORT" google.com +short +timeout=5 >> output.log 2>&1; then
      ok "Gateway DNS (AdGuard via localhost:${DNS_PORT}) works"
      GATEWAY_OK=true
    else
      warn "Gateway DNS not responding yet"
    fi
  fi

  # Direct host → gateway check via Tailscale ping (relayed pong counts as success)
  if command -v tailscale >> output.log 2>&1; then
    TS_IP=""
    [ -f .gateway_ip ] && TS_IP=$(read_adguard_ip || true)
    if [ -n "$TS_IP" ] && tailscale ping --until-direct=false -c 1 --timeout 4s "$TS_IP" 2>> output.log | grep -q pong; then
      ok "Gateway $TS_IP reachable via Tailscale"
      GATEWAY_OK=true
    else
      warn "Tailscale ping to gateway did not pong — exit-node may still be re-establishing"
    fi
  fi

  if [ "$GATEWAY_OK" = "true" ]; then
    echo -e "  ${GREEN}${BOLD}✓ Gateway is healthy after post-wake refresh.${NC}"
  else
    echo -e "  ${YELLOW}${BOLD}⚠ Gateway recovery is in-progress.${NC}"
    echo "    The route may need another 30s before queries succeed."
    echo "    If it stays broken for >60s, run: bash \"$SCRIPT_DIR/toggle.sh\""
  fi
else
  verify_internet_connectivity
fi

# ─── Summary ────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}──────────────────────────────────────────────${NC}"
if [ "$POST_WAKE" = "true" ]; then
  echo -e "${BOLD}POST-WAKE SUMMARY${NC}"
else
  echo -e "${BOLD}RECOVERY SUMMARY${NC}"
fi
echo -e "${BOLD}──────────────────────────────────────────────${NC}"

# Show final DNS state
FINAL_DNS=$(networksetup -getdnsservers "Wi-Fi" 2>/dev/null || echo "N/A")
echo "  DNS (Wi-Fi):  $FINAL_DNS"

FINAL_DNS2=$(networksetup -getdnsservers "Ethernet" 2>/dev/null || true)
if [[ -z "$FINAL_DNS2" || "$FINAL_DNS2" == *"not a recognized"* || "$FINAL_DNS2" == *"Error"* ]]; then
  FINAL_DNS2="N/A (Not configured)"
fi
echo "  DNS (Ethernet): $FINAL_DNS2"

echo ""

if [ "$POST_WAKE" = "false" ]; then
  if [ "$INTERNET_OK" = "true" ]; then
    echo -e "  ${GREEN}${BOLD}✓ Internet is working.${NC}"
  else
    echo -e "  ${YELLOW}${BOLD}⚠ Could not verify internet connectivity.${NC}"
    echo "    This might mean:"
    echo "    - Your Wi-Fi is disconnected from the router"
    echo "    - Tailscale is still interfering (try restarting tailscaled:"
    echo "        brew services restart tailscale)"
    echo "    - You need to re-connect to Wi-Fi in the menu bar"
    echo "    - Try toggling Wi-Fi off/on in the menu bar"
    echo ""
    echo "    Or try manually:"
    echo "      networksetup -setdnsservers Wi-Fi empty"
    echo "      tailscale down"
    echo "      sudo route delete -net 0.0.0.0/1"
    echo "      sudo route delete -net 128.0.0.0/1"
    echo "      brew services restart tailscale"
  fi
fi

# Reset sharing services to prevent AirDrop freezes after interface changes
# This is the SAME step in BOTH modes (post-wake inherits the previous fix from §10.27).
echo -e "  Resetting macOS sharing services (AirDrop/AirPlay)..."
reset_sharing_services

echo ""
if [ "$POST_WAKE" = "true" ]; then
  echo -e "${YELLOW}${BOLD}Post-wake refresh complete.${NC}"
  # Remove the WARP Watcher inhibit marker now that the gateway is fully healthy.
  # The watcher will resume normal liveness monitoring on its next 5s poll.
  rm -f "$WARP_INHIBIT_FILE"
  echo "[$(date -u +%FT%TZ)] POST-WAKE complete — WARP Watcher inhibit released." >> output.log
else
  echo -e "${GREEN}${BOLD}Recovery complete.${NC}"
fi
echo ""
