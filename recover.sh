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

set -e

# ─── Colours ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; NC='\033[0m'

step()  { echo -e "\n${BOLD}▶ $*${NC}"; }
ok()    { echo -e "  ${GREEN}✓ $*${NC}"; }
warn()  { echo -e "  ${YELLOW}⚠ $*${NC}"; }
fail()  { echo -e "  ${RED}✗ $*${NC}"; }
die()   { echo -e "\n  ${RED}✗ $*${NC}\n"; exit 1; }

# ─── Pure-bash timeout (no dependency on GNU coreutils' `timeout`) ────────────
# macOS lacks the `timeout` command by default. This bash-native replacement
# runs a command with a safety cutoff so a wedged daemon can't hang the script.
run_with_timeout() {
  local timeout_sec="$1"
  shift
  if [ $# -eq 0 ]; then return 1; fi
  (
    "$@" &
    cmd_pid=$!
    (
      sleep "$timeout_sec"
      kill -9 "$cmd_pid" 2>> output.log || true
    ) &
    watcher_pid=$!
    wait "$cmd_pid" 2>> output.log
    exit_code=$?
    kill "$watcher_pid" 2>> output.log || true
    exit $exit_code
  ) 2>> output.log
  return $?
}

# Always add Homebrew path
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

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
  ts_args=\"\"
  if grep -iq \"^KILL_SWITCH=true\" .env 2>/dev/null; then ts_args=\"--accept-risk=lose-ssh\"; fi
  if run_with_timeout 10 tailscale down $ts_args >> output.log 2>&1; then
    ok "Tailscale disconnected"
  else
    warn "tailscale down didn't respond"
  fi
else
  warn "tailscale CLI not found — skipping"
fi

# ─── 2. Reset DNS to default on ALL network services ─────────────────────────
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

# ─── 3. Disable rogue proxy settings ─────────────────────────────────────────
step "Disabling proxy settings (SOCKS, web, secure web)"
for svc in $(networksetup -listallnetworkservices 2>> output.log | grep -v "^An asterisk" | grep -v "^$" || echo "Wi-Fi"); do
  svc_clean=$(echo "$svc" | sed 's/^\*//')
  [ -z "$svc_clean" ] && continue
  sudo networksetup -setsocksfirewallproxystate "$svc_clean" off 2>> output.log || true
  sudo networksetup -setwebproxystate "$svc_clean" off 2>> output.log || true
  sudo networksetup -setsecurewebproxystate "$svc_clean" off 2>> output.log || true
done
ok "Proxy settings cleared"

# ─── 4. Flush macOS DNS cache ────────────────────────────────────────────────
step "Flushing DNS cache"
if command -v dscacheutil >> output.log 2>&1; then
  sudo dscacheutil -flushcache 2>> output.log || true
  sudo killall -HUP mDNSResponder 2>> output.log || true
  ok "DNS cache flushed"
else
  warn "dscacheutil not found"
fi

# ─── 5. Clear stale routing table ────────────────────────────────────────────
step "Flushing stale routing table entries"
sudo route -n flush >> output.log 2>&1 || true
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

# ─── 6b. Stopping sleep prevention (caffeinate) ──────────────────────────────
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

# ─── 6c. Stopping DNS Watcher ────────────────────────────────────────────────
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

# ─── 7. Power-cycle Wi-Fi ────────────────────────────────────────────────────
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

# ─── 8. Verify internet connectivity ──────────────────────────────────────────
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

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}──────────────────────────────────────────────${NC}"
echo -e "${BOLD}RECOVERY SUMMARY${NC}"
echo -e "${BOLD}──────────────────────────────────────────────${NC}"

# Show final DNS state
FINAL_DNS="(checking...)"
FINAL_DNS=$(networksetup -getdnsservers "Wi-Fi" 2>> output.log || echo "N/A")
echo "  DNS (Wi-Fi):  $FINAL_DNS"

FINAL_DNS2=$(networksetup -getdnsservers "Ethernet" 2>> output.log || echo "N/A")
echo "  DNS (Ethernet): $FINAL_DNS2"

echo ""

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

# Reset sharing services to prevent AirDrop freezes after interface changes
echo -e "  Resetting macOS sharing services (AirDrop/AirPlay)..."
sudo -n killall sharingd rapportd 2>> output.log || true

echo ""
echo -e "${GREEN}${BOLD}Recovery complete.${NC}"
echo ""
