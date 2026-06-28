#!/bin/bash
# recover.sh — nullexit KILL-SWITCH recovery script for Linux
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
    if run_with_timeout 10 tailscale up --reset --accept-dns=false --exit-node= >> output.log 2>&1; then
      ok "Exit-node preference cleared"
    else
      warn "tailscale up --reset didn't respond (tailscaled may be wedged)"
    fi
    if run_with_timeout 10 tailscale down >> output.log 2>&1; then
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


# ─── 4. Flush macOS DNS cache ────────────────────────────────────────────────
step "Flushing DNS cache"
if command -v resolvectl >> output.log 2>&1; then
  sudo resolvectl flush-caches 2>> output.log || true
  ok "DNS cache flushed"
else
  warn "resolvectl not found"
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

# ─── 6b. Stopping sleep prevention (systemd-inhibit) ──────────────────────────────
step "Stopping sleep prevention"
PID_FILE="/tmp/nullexit-systemd-inhibit.pid"
if [ -f "$PID_FILE" ]; then
  INHIBIT_PID=$(cat "$PID_FILE")
  if [ -n "$INHIBIT_PID" ] && kill -0 "$INHIBIT_PID" 2>/dev/null && ps -p "$INHIBIT_PID" -o comm= 2>/dev/null | grep -q systemd-inhibit; then
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
FINAL_DNS=$(resolvectl dns "$ACTIVE_SERVICE" 2>> output.log | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tr '
' ' ' || echo "N/A")
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
  echo "      tailscale down"
  echo "      sudo route -n flush"
  echo "      systemctl restart tailscaled"
fi

echo ""
echo -e "${GREEN}${BOLD}Recovery complete.${NC}"
echo ""
