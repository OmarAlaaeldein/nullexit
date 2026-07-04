#!/bin/bash
# recover.sh — nullexit KILL-SWITCH recovery script for macOS
# Fixes internet when toggle.sh leaves you stranded.
#
# This is a NUCLEAR option: it undoes EVERYTHING toggle.sh does by:
#   1. Disconnecting host Tailscale from the mesh (exit-node off)
#   2. Resetting DNS to default on ALL network services
#   3. Disabling rogue proxy settings (SOCKS, web, secure web)
#   4. Flushing macOS DNS cache
#   5. Flushing stale routing table entries
#   6. Stopping gateway Docker containers
#   7. Power-cycling Wi-Fi
#   8. Verifying internet is working
#
# Usage:  double-click Recover-Gateway.applescript
#         OR  ./recover.sh
#         OR  ./recover.sh --post-wake    (lighter-touch refresh, keeps gateway live)

set -e

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
if [ "${1:-}" = "--post-wake" ]; then
  POST_WAKE=true
  shift
fi

# ─── Resolve script directory (used for path-relative refs) ─────────────────
# recover.sh lives at the repo root; SCRIPT_DIR lets us launch toggle.sh
# (and reference any other repo-root file) from the same directory no
# matter where the user invoked recover.sh from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rm -f "$SCRIPT_DIR/TUNNEL_FAILED_CLOSED.marker"

# Source common formatting and helper functions
source "$SCRIPT_DIR/scripts/common.sh"

# Always add Homebrew path
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

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
if [ "$POST_WAKE" = "false" ]; then
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

# ─── 1. Disconnect host Tailscale (default) / Refresh exit-node (post-wake) ─
restart_tailscaled_daemon() {
  warn "tailscaled daemon appears to be wedged/unresponsive. Attempting restart..."

  if run_with_timeout 15 brew services restart tailscale >> output.log 2>&1; then
    ok "Successfully restarted tailscaled (user service)"
  elif run_with_timeout 15 sudo -n brew services restart tailscale >> output.log 2>&1; then
    ok "Successfully restarted tailscaled (system service)"
  else
    warn "Failed to restart tailscaled daemon"
  fi
  sleep 3
}

if [ "$POST_WAKE" = "true" ]; then
  step "Refreshing host Tailscale exit-node routing (post-wake)"
  if command -v tailscale >> output.log 2>&1; then
    # Re-issue the SAME exit-node up command toggle.sh START uses. This refreshes
    # the DERP relay mapping and re-asserts the exit-node preference without
    # dropping the host's mesh connection (which `tailscale down` would).
    TS_IP=""
    for src in ADGUARD_IP.txt; do
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
        ok "Exit-node $TS_IP re-asserted via `tailscale set`"
      else
        warn "tailscale set --exit-node=$TS_IP didn't respond; falling back to mesh-only"
        run_with_timeout 10 tailscale set --exit-node= \
                          >> output.log 2>&1 || true
      fi
    else
      warn "ADGUARD_IP.txt missing — cannot re-assert exit node"
      run_with_timeout 10 tailscale up --reset --ssh=true --accept-dns=false --exit-node= \
                        >> output.log 2>&1 || true
    fi
  else
    warn "tailscale CLI not found"
  fi
else
  step "Disconnecting host Tailscale from mesh"
  if command -v tailscale >> output.log 2>&1; then
    # Check if actually connected first (with timeout — tailscaled could be wedged)
    status_ok=false
    if run_with_timeout 5 tailscale status >> output.log 2>&1; then
      status_ok=true
    else
      status_exit=$?
      # If it was a quick exit code 1 (disconnected), it is still reachable
      if [ "$status_exit" -ne 143 ] && [ -S /var/run/tailscaled.socket ]; then
        status_ok=true
      fi
    fi

    if [ "$status_ok" = "false" ]; then
      restart_tailscaled_daemon
    fi

    # Also explicitly reset any exit-node so it doesn't linger.
    if run_with_timeout 10 tailscale up --reset --ssh=true --accept-dns=false --exit-node= >> output.log 2>&1; then
      ok "Exit-node preference cleared"
    else
      warn "tailscale up --reset didn't respond (tailscaled may be wedged)"
    fi
    ts_args=""
    if grep -iq "^KILL_SWITCH=true" .env 2>/dev/null; then ts_args="--accept-risk=lose-ssh"; fi
    if run_with_timeout 10 tailscale down $ts_args >> output.log 2>&1; then
      ok "Tailscale disconnected"
    else
      warn "tailscale down didn't respond"
    fi
  else
    warn "tailscale CLI not found — skipping"
  fi
fi

# ─── 2. Reset DNS to default on ALL network services (default) / Re-hijack gateway DNS (post-wake) ─
if [ "$POST_WAKE" = "true" ]; then
  step "Re-hijacking host DNS to gateway IP (post-wake / post-roam)"
  TS_IP=""
  for src in ADGUARD_IP.txt; do
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
    warn "ADGUARD_IP.txt missing — cannot re-hijack DNS (user must run toggle.sh START)"
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
    sudo networksetup -setsocksfirewallproxystate "$svc_clean" off 2>> output.log || true
    sudo networksetup -setwebproxystate "$svc_clean" off 2>> output.log || true
    sudo networksetup -setsecurewebproxystate "$svc_clean" off 2>> output.log || true
  done
  ok "Proxy settings cleared"
else
  step "Proxy settings: leaving untouched (post-wake keeps gateway SOCKS wiring alive)"
fi

# ─── 4. Flush macOS DNS cache (always — safe and useful in both modes) ─────
step "Flushing DNS cache"
if command -v dscacheutil >> output.log 2>&1; then
  sudo -n dscacheutil -flushcache 2>> output.log || true
  sudo -n killall -HUP mDNSResponder 2>> output.log || true
  ok "DNS cache flushed (mDNSResponder HUP)"
else
  warn "dscacheutil not found"
fi

# ─── 5. Clear stale routing table (always — safe in both modes) ──────────
step "Flushing stale routing table entries"
# Resolve physical default gateway IP before flushing
PHYSICAL_GW=$(route get default 2>> output.log | awk '/gateway:/{print $2; exit}')
sudo -n route -n flush >> output.log 2>&1 || true
ok "Routing table flushed"

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
  sudo -n route delete -host 162.159.192.1 2>/dev/null || true
  sudo -n route delete -host 162.159.193.1 2>/dev/null || true
  if [ -n "${PHYSICAL_GW:-}" ]; then
    sudo -n route add -host 162.159.192.1 "$PHYSICAL_GW" >> output.log 2>&1 || true
    sudo -n route add -host 162.159.193.1 "$PHYSICAL_GW" >> output.log 2>&1 || true
  else
    sudo -n route add -host 162.159.192.1 -interface "$ACTIVE_IF" >> output.log 2>&1 || true
    sudo -n route add -host 162.159.193.1 -interface "$ACTIVE_IF" >> output.log 2>&1 || true
  fi

  # Also re-apply the default route pointing to the Tailscale interface
  ts_iface=$(ifconfig 2>> output.log | grep -B4 "inet 100." | grep -E '^[a-z0-9]+' | cut -d: -f1 | head -n 1)
  if [ -n "$ts_iface" ]; then
    echo "Re-routing default gateway to $ts_iface..."
    sudo -n route delete default 2>> output.log || true
    sudo -n route add default -interface "$ts_iface" >> output.log 2>&1 || true
  fi
fi

# ─── 6. Stop gateway Docker containers (default) / Force-recreate warp if unhealthy (post-wake) ─
if [ "$POST_WAKE" = "true" ]; then
  step "Checking warp container health (gluetun UDP tunnel)"
  # The warp container is the most failure-prone link in the chain at wake/roam:
  # its UDP NAT binding to Cloudflare's edge (162.159.192.1:2408) silently dies
  # during a Wi-Fi roam. gluetun's healthcheck may catch it within ~30s, but if
  # not, a force-recreate forces the tun device to re-bind instantly.
  WARP_STATE=$(docker inspect --format '{{.State.Health.Status}}' warp 2>> output.log || echo "missing")
  case "$WARP_STATE" in
    healthy)
      ok "warp container is healthy (no recreate needed)"
      ;;
    missing)
      warn "warp container is missing — leaving gateway containers alone (full relaunch requires \"$SCRIPT_DIR/toggle.sh\")"
      ;;
    *)
      warn "warp container health = '$WARP_STATE' — force-recreating to nudge UDP rebind"
      docker compose up -d --force-recreate warp 2>> output.log || warn "force-recreate failed"
      sleep 5
      NEW_STATE=$(docker inspect --format '{{.State.Health.Status}}' warp 2>> output.log || echo "missing")
      ok "warp container health after recreate: $NEW_STATE"
      ;;
  esac
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
  PID_FILE="/tmp/nullexit-caffeinate.pid"
  if [ -f "$PID_FILE" ]; then
    CAFFE_PID=$(cat "$PID_FILE")
    if [ -n "$CAFFE_PID" ] && kill -0 "$CAFFE_PID" 2>/dev/null && ps -p "$CAFFE_PID" -o comm= 2>/dev/null | grep -q caffeinate; then
      kill "$CAFFE_PID" 2>/dev/null || true
      ok "Sleep prevention stopped (PID $CAFFE_PID)"
    else
      warn "Sleep prevention process not running, cleaning up stale PID file"
    fi
    rm -f "$PID_FILE"
  else
    ok "Sleep prevention was not active"
  fi
else
  step "Sleep prevention: leaving untouched (caffeinate already re-acquired by parent shell)"
fi

# ─── 6c. Stopping DNS Watcher — default only ────────────────────────────────
if [ "$POST_WAKE" = "false" ]; then
  step "Stopping DNS Watcher"
  DNS_WATCHER_PID_FILE="/tmp/nullexit-dns-watcher.pid"
  if [ -f "$DNS_WATCHER_PID_FILE" ]; then
    WATCHER_PID=$(cat "$DNS_WATCHER_PID_FILE")
    if [ -n "$WATCHER_PID" ] && kill -0 "$WATCHER_PID" 2>/dev/null; then
      kill -9 "$WATCHER_PID" 2>/dev/null || true
      ok "DNS Watcher stopped (PID $WATCHER_PID)"
    else
      warn "DNS Watcher process not running, cleaning up stale PID file"
    fi
    rm -f "$DNS_WATCHER_PID_FILE"
  else
    ok "DNS Watcher was not active"
  fi

  # ─── 6d. Stopping Host Leak Probe — default only ─────────────────────────
  step "Stopping Host Leak Probe"
  HOST_LEAK_PROBE_PID_FILE="/tmp/nullexit-host-leak-probe.pid"
  if [ -f "$HOST_LEAK_PROBE_PID_FILE" ]; then
    HP=$(cat "$HOST_LEAK_PROBE_PID_FILE")
    if [ -n "$HP" ] && kill -0 "$HP" 2>/dev/null; then
      kill "$HP" 2>/dev/null || true
      ok "Host Leak Probe stopped (PID $HP)"
    else
      warn "Host Leak Probe process not running, cleaning up stale PID file"
    fi
    rm -f "$HOST_LEAK_PROBE_PID_FILE"
  else
    ok "Host Leak Probe was not active"
  fi
else
  step "DNS Watcher / Host Leak Probe: leaving untouched (it keeps re-hijacking DNS on every roam)"
fi

# ─── 7. Power-cycle Wi-Fi — default only ────────────────────────────────────
if [ "$POST_WAKE" = "false" ]; then
  step "Power-cycling Wi-Fi"
  WIFI_PORT=$(networksetup -listallhardwareports 2>> output.log | awk '/Hardware Port: Wi-Fi/{getline; print $2}')
  if [ -n "$WIFI_PORT" ]; then
    sudo networksetup -setairportpower "$WIFI_PORT" off 2>> output.log
    sleep 2
    sudo networksetup -setairportpower "$WIFI_PORT" on 2>> output.log
    ok "Wi-Fi bounced (interface $WIFI_PORT)"
    sleep 3
  else
    warn "Could not detect Wi-Fi interface. Bouncing fallback interfaces..."
    set +e
    for iface in en0 en1 en2 en3 en4 en5; do
      if ifconfig "$iface" >> output.log 2>&1; then
        sudo ifconfig "$iface" down 2>> output.log
        sudo ifconfig "$iface" up 2>> output.log
      fi
    done
    set -e
    ok "Fallback interfaces bounced"
  fi
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
    # AdGuard is exposed at localhost:5354. If this resolves, the warp tunnel
    # is alive AND DNSCache has picked up the post-wake reset.
    if dig +tcp @127.0.0.1 -p 5354 google.com +short +timeout=5 >> output.log 2>&1; then
      ok "Gateway DNS (AdGuard via localhost:5354) works"
      GATEWAY_OK=true
    else
      warn "Gateway DNS not responding yet"
    fi
  fi

  # Direct host → gateway check via Tailscale ping (relayed pong counts as success)
  if command -v tailscale >> output.log 2>&1; then
    TS_IP=""
    [ -f ADGUARD_IP.txt ] && TS_IP=$(cat ADGUARD_IP.txt 2>> output.log | tr -d '\r' | awk 'NR==1{print $1; exit}' || true)
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
  step "Verifying internet connectivity"

  # Wait a moment for the network to settle
  sleep 2

  INTERNET_OK=false

  # Try DNS resolution first
  if host -W 3 google.com 1.1.1.1 >> output.log 2>&1; then
    ok "DNS resolution works (google.com via 1.1.1.1)"
    INTERNET_OK=true
  elif nslookup google.com 1.1.1.1 >> output.log 2>&1; then
    ok "DNS resolution works (nslookup google.com via 1.1.1.1)"
    INTERNET_OK=true
  else
    warn "DNS resolution check failed — will still try ping/curl"
  fi

  # Try actual HTTP connectivity
  if command -v curl >> output.log 2>&1; then
    if curl -sf --max-time 5 https://1.1.1.1 >> output.log 2>&1; then
      ok "Internet reachable via HTTP"
      INTERNET_OK=true
    elif curl -sf --max-time 5 http://1.1.1.1 >> output.log 2>&1; then
      ok "Internet reachable via HTTP (plain)"
      INTERNET_OK=true
    else
      warn "HTTP check failed"
    fi
  elif command -v ping >> output.log 2>&1; then
    if ping -c 1 -W 3 1.1.1.1 >> output.log 2>&1; then
      ok "Internet reachable via ping"
      INTERNET_OK=true
    else
      warn "Ping check failed"
    fi
  fi
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
FINAL_DNS=$(networksetup -getdnsservers "Wi-Fi" 2>> output.log || echo "N/A")
echo "  DNS (Wi-Fi):  $FINAL_DNS"

FINAL_DNS2=$(networksetup -getdnsservers "Ethernet" 2>> output.log || echo "N/A")
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
    echo "      tailscale down "
    echo "      sudo route -n flush"
    echo "      brew services restart tailscale"
  fi
fi

# Reset sharing services to prevent AirDrop freezes after interface changes
# This is the SAME step in BOTH modes (post-wake inherits the previous fix from §10.27).
echo -e "  Resetting macOS sharing services (AirDrop/AirPlay)..."
sudo -n killall sharingd rapportd 2>> output.log || true

echo ""
if [ "$POST_WAKE" = "true" ]; then
  echo -e "${YELLOW}${BOLD}Post-wake refresh complete.${NC}"
else
  echo -e "${GREEN}${BOLD}Recovery complete.${NC}"
fi
echo ""
