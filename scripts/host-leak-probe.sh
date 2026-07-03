#!/bin/bash
# scripts/host-leak-probe.sh — nullexit sub-second host-egress leak prober
#
# WHY THIS EXISTS: toggle.sh's WARP Watcher polls warp=on/off every 5s via
# `docker compose exec -T warp wget ...` — that asks the WARP CONTAINER
# about its own tunnel state, not what actually leaves the HOST's physical
# interface. A host-side flash-leak (Cloudflare edge reroute, the up-to-5s
# routing-fix re-assertion gap after a Gluetun healthcheck restart — see
# devref.md §10.18 — or a browser reusing a stale pooled connection across
# a state change) is invisible to it. This script probes from the HOST
# directly, at sub-second resolution, and logs ONLY on state change so
# it's safe to leave running for a long diagnostic window.
#
# This is a DETECTION tool, not prevention. Even at 300ms polling it can
# miss a leak that resolves within the gap between two polls — it exists
# to tell you whether the flash is real before you invest in a kill-switch
# (which is prevention, not detection, and the only way to close a
# sub-second gap for certain).
#
# Usage:
#   bash scripts/host-leak-probe.sh              # poll every 300ms (default)
#   bash scripts/host-leak-probe.sh 0.5          # custom interval, in seconds
#
# Ctrl+C to stop. Run it for a bounded window (an hour or two of normal
# browsing/roaming), then grep the log — don't leave it running forever;
# back off the interval if you see probe failures pile up (rate limiting).
#
# Log: output.log (repo root), UTC timestamps, ms precision.
# Grep for real leaks afterward with:  grep LEAK output.log

set -uo pipefail

INTERVAL="${1:-0.3}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd 2>/dev/null || echo "$SCRIPT_DIR")"
LOG_FILE="$PROJECT_ROOT/output.log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

echo "════════════════════════════════════════════════════════════"
echo " host-leak-probe — polling every ${INTERVAL}s from the HOST"
echo " (not through docker exec — this is the actual browser egress path)"
echo " logging state changes only → output.log"
echo " Ctrl+C to stop"
echo "════════════════════════════════════════════════════════════"
echo ""

last_warp=""
last_ip=""
leak_count=0
rotate_count=0
fail_count=0
start_ts=$(date +%s)

trap '
  elapsed=$(( $(date +%s) - start_ts ))
  echo ""
  echo "────────────────────────────────────────────────────────────"
  echo " Stopped after ${elapsed}s."
  echo "   leak events (warp != on):     $leak_count"
  echo "   Cloudflare edge rotations:    $rotate_count  (expected/harmless)"
  echo "   probe failures/timeouts:      $fail_count"
  echo " Full log: '"$LOG_FILE"'"
  if [ "$leak_count" -gt 0 ]; then
    echo -e " '"${RED}${BOLD}"'→ Real leak events were logged. Grep LEAK '"'"'$LOG_FILE'"'"' before deciding on a fix.'"${NC}"'"
  else
    echo -e " '"${GREEN}"'→ No warp-off events this run. The flash you saw is more likely a browser/CDN caching artifact than a routing leak — but a short run is not proof; longer/more sessions (especially around roams or Gluetun restarts) give better confidence.'"${NC}"'"
  fi
  echo "────────────────────────────────────────────────────────────"
  exit 0
' INT TERM

while true; do
  # -m 2: hard 2s timeout so one hung request never stalls the loop.
  # Cache-busting query param + no-cache headers so nothing between us
  # and Cloudflare's edge can mask a real transition with a stale response.
  out=$(curl -s -m 2 -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
        "https://www.cloudflare.com/cdn-cgi/trace?_=$(date +%s%N)" 2>>"$LOG_FILE")
  warp=$(printf '%s' "$out" | awk -F'=' '/^warp=/{print $2; exit}')
  ip=$(printf '%s' "$out" | awk -F'=' '/^ip=/{print $2; exit}')
  ts=$(date -u +%H:%M:%S.%3N)

  if [ -z "$warp" ]; then
    # Request itself failed/timed out. Noted, but NOT treated as a leak —
    # a failed probe tells you nothing about what actually left the NIC.
    fail_count=$((fail_count + 1))
    printf '[%s] HOST-PROBE failed/timeout (count=%d)\n' "$ts" "$fail_count" >> "$LOG_FILE"
    printf '\r%s  probe failed/timeout (%d so far)          ' "$ts" "$fail_count"
  elif [ "$warp" != "on" ]; then
    leak_count=$((leak_count + 1))
    echo ""
    echo -e "${RED}${BOLD}[$ts] LEAK: warp=${warp}  ip=${ip}  (was warp=${last_warp:-?} ip=${last_ip:-?})${NC}"
    printf '[%s] LEAK warp=%s ip=%s prev_warp=%s prev_ip=%s\n' \
      "$ts" "$warp" "$ip" "${last_warp:-?}" "${last_ip:-?}" >> "$LOG_FILE"
  elif [ -n "$last_ip" ] && [ "$ip" != "$last_ip" ]; then
    # IP changed but warp is still "on" — almost certainly Cloudflare
    # anycast/edge rotation, not a leak. Logged for visibility only.
    rotate_count=$((rotate_count + 1))
    echo ""
    echo -e "${YELLOW}[$ts] Cloudflare IP rotated (still warp=on): ${last_ip} → ${ip}${NC}"
    printf '[%s] ROTATE warp=on ip=%s prev_ip=%s\n' "$ts" "$ip" "$last_ip" >> "$LOG_FILE"
  else
    printf '\r%s  warp=on  ip=%s   ' "$ts" "$ip"
  fi

  last_warp="$warp"
  [ -n "$ip" ] && last_ip="$ip"
  sleep "$INTERVAL"
done
