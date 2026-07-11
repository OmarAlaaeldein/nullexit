#!/bin/bash
# scripts/diagnose-host-leak.sh — nullexit host-routing diagnostic
#
# Symptom this addresses: tests like https://www.whatismyip.com on the
# *HOST MAC* return the underlying physical ISP/ASN
# local ISP / campus network") even though the nullexit gateway is active and remote
# tailnet clients correctly egress via Cloudflare WARP. The container and
# the gateway itself are healthy — only the host's own routing is leaking.
#
# This script runs 7 checks in sequence, classifies the result into ONE
# of the three known leak scenarios, writes the full report to a
# timestamped file in the project root, and prints a verdict + a
# ready-to-run fix command on stdout. Pass --fix to apply the matching
# remediation in the same invocation and re-verify egress afterwards.
# See devref.md §10.30 for the deep-dive rationale.
#
# Usage:
#   bash scripts/diagnose-host-leak.sh              # diagnose + write report
#   bash scripts/diagnose-host-leak.sh --fix        # diagnose + fix + re-verify
#   bash scripts/diagnose-host-leak.sh --watch      # full baseline then loop checks every 60s
#   bash scripts/diagnose-host-leak.sh --watch 30   # same, with custom interval (seconds)
#   bash scripts/diagnose-host-leak.sh --help       # this message
#
# Multiple runs produce timestamped files (one per run) so historical
# reports can be diffed. The newest file is the most recent.

set -uo pipefail
# NOTE: errexit (`set -e`) is intentionally NOT enabled. Several checks
# below are EXPECTED to fail and that's diagnostic data (e.g. `tailscale
# status` returns non-zero when the daemon is wedged). Every command
# pipes to a helper that records the exit code without killing the script.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
source "$SCRIPT_DIR/common.sh"
LOG_FILE="$PROJECT_ROOT/output.log"
REPORT_FILE="$PROJECT_ROOT/host-leak-diagnostic-$TIMESTAMP.txt"

# ─── Argument parsing ───────────────────────────────────────────────────────
DO_FIX=false
DO_WATCH=false
WATCH_INTERVAL=60
WATCH_LOG="$PROJECT_ROOT/host-leak-watch.log"
case "${1:-}" in
  --fix) DO_FIX=true ;;
  --watch)
    DO_WATCH=true
    # Optional second argument: custom interval in seconds
    if [ -n "${2:-}" ] && [[ "$2" =~ ^[0-9]+$ ]]; then
      WATCH_INTERVAL="$2"
    fi
    ;;
  --help|-h)
    sed -n '2,31p' "$0"
    exit 0
    ;;
  "")
    : # default: diagnose only
    ;;
  *)
    echo "Unknown argument: $1" >&2
    echo "Run with --help for usage." >&2
    exit 2
    ;;
esac

# ─── Colours (auto-disabled when stdout is not a tty, e.g. piped) ───────────
if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BOLD=''; NC=''
fi

# ─── Output helpers — write to BOTH stdout and the report file ──────────────
exec 3>> "$REPORT_FILE" || {
  printf '\n[FATAL] cannot open %s for write\n' "$REPORT_FILE" >&2
  exit 1
}
section() {
  local title="$1"
  printf '\n%b═══════ %s ═══════%b\n' "$BOLD" "$title" "$NC" >&3
  printf '\n%b═══════ %s ═══════%b\n' "$BOLD" "$title" "$NC"
}
line()   { printf '  %b\n' "$1" >&3; printf '  %b\n' "$1"; }
ok()     { line "${GREEN}✓${NC} $1"; }
warn()   { line "${YELLOW}⚠${NC} $1"; }
fail()   { line "${RED}✗${NC} $1"; }
note()   { line "(no ${1})"; }

# ─── Watch-mode header (only shown when entering watch loop) ────────────────
if [ "$DO_WATCH" = "true" ]; then
  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo " n u l l e x i t   w a t c h   m o d e"
  echo "════════════════════════════════════════════════════════════"
  echo " Interval:        ${WATCH_INTERVAL}s"
  echo " Watch log:       $WATCH_LOG"
  echo "════════════════════════════════════════════════════════════"
else
  echo "════════════════════════════════════════════════════════════"
  echo " n u l l e x i t   h o s t - r o u t i n g   d i a g n o s t i c"
  echo "════════════════════════════════════════════════════════════"
  echo " Timestamp (UTC): $TIMESTAMP"
  echo " Project root:    $PROJECT_ROOT"
  echo " Report file:     $REPORT_FILE"
  echo " Mode:            $([ "$DO_FIX" = true ] && echo "diagnose + apply fix" || echo "diagnose only (pass --fix to remediate)")"
  echo "════════════════════════════════════════════════════════════"
  echo "" >&3
  echo "════════════════════════════════════════════════════════════" >&3
  echo " n u l l e x i t   h o s t - r o u t i n g   d i a g n o s t i c" >&3
  echo "════════════════════════════════════════════════════════════" >&3
  echo " Timestamp (UTC): $TIMESTAMP" >&3
  echo " Mode:            $([ "$DO_FIX" = true ] && echo "diagnose + apply fix" || echo "diagnose only")" >&3
fi

# ─── Always add Homebrew to PATH (same as toggle.sh / recover.sh) ──────────
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# ─── Pure-bash timeout (macOS lacks GNU `timeout`) ──────────────────────────
run_with_timeout() {
  local timeout_sec="$1"
  shift
  if [ "$#" -eq 0 ]; then return 1; fi
  "$@" &
  local cmd_pid=$!
  (
    sleep "$timeout_sec"
    if kill -0 "$cmd_pid" 2>> "$LOG_FILE"; then
      kill -9 "$cmd_pid" 2>> "$LOG_FILE" || true
    fi
  ) >> "$LOG_FILE" 2>&1 &
  local watcher_pid=$!
  set +e
  wait "$cmd_pid"
  local exit_status=$?
  set -uo pipefail
  kill "$watcher_pid" 2>> "$LOG_FILE" || true
  return "$exit_status"
}

# ─── Resolve the active network service (same heuristic as toggle.sh) ──────
resolve_active_service() {
  get_active_service
}

# ═══════════════════════════════════════════════════════════════════════════
# Quick-check functions (used by --watch loop; return simple status strings)
# Each echoes its result so the caller can capture and compare.
# ═══════════════════════════════════════════════════════════════════════════

quick_warp() {
  # Returns: "on", "off", "unknown"
  local out
  out=$(run_with_timeout 8 curl -s --max-time 6 \
        https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || echo "")
  local warp
  warp=$(printf '%s' "$out" | awk -F'=' '/^warp=/{print $2; exit}')
  printf '%s' "${warp:-unknown}"
}

quick_ipv6() {
  # Returns: the IPv6 address if leaking, or empty string if clean
  local out
  out=$(run_with_timeout 7 curl -6 -s --max-time 5 ifconfig.co 2>/dev/null || echo "")
  if [ -n "$out" ] && printf '%s' "$out" | grep -qE '^[0-9a-fA-F:]+$'; then
    printf '%s' "$out"
  fi
}

quick_default_route() {
  # Returns: "utun" if default route is via Tailscale utun*,
  #          "wifi" if via physical Wi-Fi (192.168.x.x),
  #          "other" otherwise
  local route
  route=$(netstat -rn 2>/dev/null | awk '/^default/ {print $0; exit}')
  if [ -z "$route" ]; then
    printf '%s' "none"
  elif printf '%s' "$route" | grep -qE 'utun[0-9]+'; then
    printf '%s' "utun"
  elif printf '%s' "$route" | grep -qE '^(default|0\.0\.0\.0).*\b192\.168\.'; then
    printf '%s' "wifi"
  else
    printf '%s' "other"
  fi
}

# ─── Watch loop (runs after baseline diagnostic when --watch is passed) ─────
run_watch_loop() {
  local baseline_warp="$1"
  local baseline_default="$2"
  local baseline_ipv6_leak="$3"
  local interval="$4"

  echo ""
  echo "────────────────────────────────────────────────────────────"
  echo " Baseline established. Monitoring every ${interval}s..."
  echo "  warp:     $baseline_warp"
  echo "  default:  $baseline_default"
  echo "────────────────────────────────────────────────────────────"

  # ── Safety: warn if interval is very short (avoids hammering APIs) ──
  if [ "$interval" -lt 30 ]; then
    printf '%b⚠  Short interval (%ss) — rate-limiting risk on external APIs%b\n' "$YELLOW" "$interval" "$NC"
    printf '  Consider 30s or longer for production use.\n'
  fi
  printf '[%s] WATCH START  warp=%s  default=%s  interval=%ss\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$baseline_warp" "$baseline_default" "$interval" \
    >> "$WATCH_LOG"

  local iteration=0
  local last_warp="$baseline_warp"
  local last_default="$baseline_default"
  local last_ipv6_ok=$([ "$baseline_ipv6_leak" = "false" ] && echo true || echo false)

  trap 'printf "\n%bWatch stopped by user. Log at: %s%b\n" "$YELLOW" "$WATCH_LOG" "$NC"; exit 0' INT TERM

  while true; do
    iteration=$((iteration + 1))

    local warp_now ipv6_now default_now
    warp_now=$(quick_warp)
    ipv6_now=$(quick_ipv6)
    default_now=$(quick_default_route)

    local ts
    ts=$(date -u +%H:%M:%S)

    # ─── WARP check ──────────────────────────────────────────────────────
    if [ "$warp_now" != "$last_warp" ]; then
      if [ "$warp_now" = "off" ] || [ "$warp_now" = "unknown" ]; then
        printf '\n%b━━━━━━━━ ALERT ━━━━━━━━%b\n' "$RED$BOLD" "$NC"
        printf '%b[%s] %bWARP FLIPPED: %s → %s%b — YOUR IP IS LEAKING!\n' \
          "$RED" "$ts" "$BOLD" "$last_warp" "$warp_now" "$NC"
        printf '[%s] ALERT  warp flipped  %s→%s\n' "$ts" "$last_warp" "$warp_now" >> "$WATCH_LOG"
      else
        printf '\n%b[%s] ✓ warp recovered: %s → %s%b\n' \
          "$GREEN" "$ts" "$last_warp" "$warp_now" "$NC"
        printf '[%s] OK     warp recovered  %s→%s\n' "$ts" "$last_warp" "$warp_now" >> "$WATCH_LOG"
      fi
      last_warp="$warp_now"
    fi

    # ─── IPv6 check ──────────────────────────────────────────────────────
    if [ -n "$ipv6_now" ]; then
      if [ "$last_ipv6_ok" = true ]; then
        printf '\n%b━━━━━━━━ ALERT ━━━━━━━━%b\n' "$RED$BOLD" "$NC"
        printf '%b[%s] %bIPv6 LEAK DETECTED → %s%b\n' \
          "$RED" "$ts" "$BOLD" "$ipv6_now" "$NC"
        printf '[%s] ALERT  IPv6 leak  %s\n' "$ts" "$ipv6_now" >> "$WATCH_LOG"
        last_ipv6_ok=false
      fi
    else
      if [ "$last_ipv6_ok" = false ]; then
        printf '%b[%s] ✓ IPv6 leak resolved%b\n' "$GREEN" "$ts" "$NC"
        printf '[%s] OK     IPv6 resolved\n' "$ts" >> "$WATCH_LOG"
      fi
      last_ipv6_ok=true
    fi

    # ─── Default route check ─────────────────────────────────────────────
    if [ "$default_now" != "$last_default" ]; then
      if [ "$default_now" != "utun" ]; then
        printf '\n%b━━━━━━━━ ALERT ━━━━━━━━%b\n' "$RED$BOLD" "$NC"
        printf '%b[%s] %bDEFAULT ROUTE CHANGED: %s → %s%b — traffic may bypass WARP!\n' \
          "$RED" "$ts" "$BOLD" "$last_default" "$default_now" "$NC"
        printf '[%s] ALERT  route changed  %s→%s\n' "$ts" "$last_default" "$default_now" >> "$WATCH_LOG"
      else
        printf '%b[%s] ✓ default route recovered: %s → %s%b\n' \
          "$GREEN" "$ts" "$last_default" "$default_now" "$NC"
        printf '[%s] OK     route recovered  %s→%s\n' "$ts" "$last_default" "$default_now" >> "$WATCH_LOG"
      fi
      last_default="$default_now"
    fi

    # ─── Heartbeat (every 10th iteration or if all OK) ───────────────────
    if [ $((iteration % 10)) -eq 0 ]; then
      printf '[%s] #%d  warp=%s  ipv6=%s  route=%s\n' \
        "$ts" "$iteration" "$warp_now" "${ipv6_now:-none}" "$default_now" >> "$WATCH_LOG"
      printf '\r%b[%s] #%d  warp=%s  route=%s  (Ctrl+C to stop)%b' \
        "$GREEN" "$ts" "$iteration" "$warp_now" "$default_now" "$NC"
    fi

    sleep "$interval"
  done
}

# ═══════════════════════════════════════════════════════════════════════════
# Begin main diagnostic (skipped in non-watch modes if we're just watching)
# ═══════════════════════════════════════════════════════════════════════════

ACTIVE_SERVICE=$(resolve_active_service)
EN0_SERVICE=$(networksetup -listnetworkserviceorder 2>> "$LOG_FILE" \
              | grep -B 1 "Device: en0" | head -1 \
              | sed -E 's/^\([0-9\*]+\) //' || true)
[ -z "$EN0_SERVICE" ] && EN0_SERVICE="Wi-Fi"

# Resolve the gateway's Tailscale IP.
GATEWAY_TS_IP=""
if [ -f "$PROJECT_ROOT/.gateway_ip" ]; then
  GATEWAY_TS_IP=$(cat "$PROJECT_ROOT/.gateway_ip" 2>> "$LOG_FILE" \
                  | tr -d '\r' | awk 'NR==1{print $1; exit}')
fi
if [ -z "$GATEWAY_TS_IP" ] && command -v docker >> "$LOG_FILE" 2>&1 \
   && docker compose ps --status running 2>/dev/null | grep -q 'tailscale'; then
  GATEWAY_TS_IP=$(run_with_timeout 10 docker compose exec -T tailscale \
                  tailscale ip -4 2>> "$LOG_FILE" \
                  | tr -d '\r' | awk 'NR==1{print $1; exit}')
fi

# ─── Scenario classification state ──────────────────────────────────────────
SCENARIO=""
WARP_STATUS=""
SOCKS5_ENABLED=false
TS_ON_MESH=false
DEFAULT_VIA_UTUN=false
IPV6_LEAK=false

# ═══════════════════════════════════════════════════════════════════════════
section "1/8  Host Tailscale mesh status"
# ═══════════════════════════════════════════════════════════════════════════
if ! command -v tailscale >> "$LOG_FILE" 2>&1; then
  fail "tailscale CLI not on PATH — install via 'brew install tailscale' then re-run"
  echo "  (a Tailscale daemon is required for the exit-node path to work)"
else
  set +e
  TS_OUT=$(run_with_timeout 5 tailscale status 2>&1)
  TS_EXIT=$?
  set -uo pipefail
  TS_HEAD=$(printf '%s\n' "$TS_OUT" | head -5 | tr -d '\r')
  if [ "$TS_EXIT" -eq 137 ]; then
    fail "tailscaled daemon is wedged/unresponsive (5s timeout)"
    echo "  Fix path: 'sudo brew services restart tailscale'"
  elif printf '%s' "$TS_OUT" | grep -qE 'Logged out|not logged in|expired'; then
    fail "tailscale is logged out / auth expired on this host"
    echo "  Fix path: 'sudo tailscale up' (browser auth once)"
  elif printf '%s' "$TS_OUT" | grep -q '100\.'; then
    ok "Host is on tailnet (100.x.x.x visible in status)"
    TS_ON_MESH=true
    if printf '%s' "$TS_OUT" | grep -q "$GATEWAY_TS_IP"; then
      ok "Gateway $GATEWAY_TS_IP visible in host's peer list"
    elif [ -n "$GATEWAY_TS_IP" ]; then
      warn "Gateway $GATEWAY_TS_IP NOT in host's peer list — possible auth/key mismatch"
    fi
    line "── first 5 lines of 'tailscale status' ──"
    line "$(printf '%s' "$TS_HEAD" | awk '{print "    "$0}')"
  else
    fail "tailscale output unrecognized:"
    line "$(printf '%s' "$TS_OUT" | head -3 | awk '{print "    "$0}')"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
section "2/8  Active SOCKS5 proxy on Wi-Fi"
# ═══════════════════════════════════════════════════════════════════════════
SOCKS_OUT=$(networksetup -getsocksfirewallproxy "$ACTIVE_SERVICE" 2>> "$LOG_FILE" \
             || networksetup -getsocksfirewallproxy Wi-Fi 2>> "$LOG_FILE" \
             || echo "Could not query SOCKS5 proxy state")
if printf '%s' "$SOCKS_OUT" | grep -q "Enabled: Yes"; then
  fail "SOCKS5 proxy IS enabled on $ACTIVE_SERVICE — toggle.sh fell back to SOCKS5 mode last run"
  SOCKS5_ENABLED=true
  line "  Full state:"
  line "$(printf '%s' "$SOCKS_OUT" | awk '{print "    "$0}')"
  line "  Browse on macOS ignores system SOCKS5 by default → traffic bypasses WARP."
else
  ok "SOCKS5 proxy is OFF on $ACTIVE_SERVICE — exit-node path should be active"
fi

# ═══════════════════════════════════════════════════════════════════════════
section "3/8  Egress IP + WARP tunnel verification (definitive test)"
# ═══════════════════════════════════════════════════════════════════════════
CDN_OUT=$(run_with_timeout 8 curl -s --max-time 6 \
          https://www.cloudflare.com/cdn-cgi/trace 2>&1 || echo "(curl failed)")
CDN_WARP=$(printf '%s' "$CDN_OUT" | awk -F'=' '/^warp=/{print $2; exit}')
CDN_IP=$(printf '%s' "$CDN_OUT" | awk -F'=' '/^ip=/{print $2; exit}')
CDN_COLO=$(printf '%s' "$CDN_OUT" | awk -F'=' '/^colo=/{print $2; exit}')
WARP_STATUS="$CDN_WARP"
if [ "$CDN_WARP" = "on" ]; then
  ok "warp=on — tunnel is hot, host traffic IS going through Cloudflare WARP"
  line "  Public IP:   $CDN_IP"
  line "  Cloudflare:   ${CDN_COLO:-unknown colo}"
  line "  → whatismyip.com's 'local ISP' result is its ISP-database error, not yours."
elif [ "$CDN_WARP" = "off" ]; then
  fail "warp=off — host traffic is NOT going through WARP"
  line "  Public IP:   $CDN_IP  (NOT Cloudflare)"
  warn "This is the actual leak."
else
  warn "could not determine warp status (curl failed or returned unexpected shape)"
  line "  Raw output: $(printf '%s' "$CDN_OUT" | head -3 | tr '\n' '|')"
fi

# ═══════════════════════════════════════════════════════════════════════════
section "4/8  IPv6 leak probe (bypasses IPv4 exit-node on campus networks)"
# ═══════════════════════════════════════════════════════════════════════════
IPV6_OUT=$(run_with_timeout 7 curl -6 -s --max-time 5 ifconfig.co 2>&1 || echo "")
if [ -n "$IPV6_OUT" ] && printf '%s' "$IPV6_OUT" | grep -qE '^[0-9a-fA-F:]+$'; then
  fail "host has live IPv6 egress → $IPV6_OUT (A6 record bypasses WARP)"
  IPV6_LEAK=true
  line "  Tailscale exit-node advertisement is IPv4-only, so IPv6 traffic skips it."
  line "  Quick-fix: 'sudo networksetup -setv6off $ACTIVE_SERVICE'"
else
  ok "no IPv6 egress detected (good — IPv6 won't bypass the tunnel)"
fi

# ═══════════════════════════════════════════════════════════════════════════
section "5/8  Host egress route for real traffic (route -n get 1.1.1.1)"
# ═══════════════════════════════════════════════════════════════════════════
# WHY NOT 'netstat -rn | grep default':
# On macOS, Tailscale does NOT replace the physical default route installed by
# DHCP. Instead it adds a second interface-scoped route bound to the utun
# interface that the kernel prefers for real traffic forwarding. The literal
# "default" entry (192.168.x.x via en0) is left untouched in the table as a
# BSD routing quirk — it's not lying, it's just answering a different question.
# The correct question is: "where does a real destination actually resolve?"
# `route -n get 1.1.1.1` asks the kernel's forwarding logic directly.
ROUTE_GET=$(route -n get 1.1.1.1 2>/dev/null)
ROUTE_IFACE=$(echo "$ROUTE_GET" | awk '/interface:/{print $2}')
ROUTE_GATEWAY=$(echo "$ROUTE_GET" | awk '/gateway:/{print $2}')
if [ -z "$ROUTE_IFACE" ]; then
  warn "route -n get 1.1.1.1 returned no interface — routing table may be empty"
else
  line "  interface: $ROUTE_IFACE  gateway: ${ROUTE_GATEWAY:-n/a}"
  if echo "$ROUTE_IFACE" | grep -qE '^utun[0-9]+'; then
    ok "1.1.1.1 resolves via $ROUTE_IFACE → Tailscale interface-scoped route is winning"
    DEFAULT_VIA_UTUN=true
  elif echo "$ROUTE_IFACE" | grep -qE '^en[0-9]+'; then
    fail "1.1.1.1 resolves via $ROUTE_IFACE (physical Wi-Fi) — exit-node interface route not active"
  else
    warn "1.1.1.1 resolves via unexpected interface: $ROUTE_IFACE"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
section "6/8  Last toggle.sh START-relevant lines in output.log (if any)"
# ═══════════════════════════════════════════════════════════════════════════
if [ ! -f "$LOG_FILE" ]; then
  note "output.log"
  line "  toggle.sh was never run from this directory. Run './toggle.sh' first,"
  line "  then re-run this diagnostic."
else
  HITS=$(grep -E 'Exit node enabled|SKIP_EXIT_NODE|Pre-flight|Falling back to SOCKS|Starting|Successfully' \
         "$LOG_FILE" 2>/dev/null | tail -8 || true)
  if [ -z "$HITS" ]; then
    note "matching lines in output.log"
  else
    line "$(printf '%s\n' "$HITS" | awk '{print "    "$0}')"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
section "7/8  Gateway IP we should be pointing at"
# ═══════════════════════════════════════════════════════════════════════════
if [ -n "$GATEWAY_TS_IP" ]; then
  ok "gateway Tailscale IP: $GATEWAY_TS_IP"
else
  warn "could not resolve gateway Tailscale IP"
  line "  (looked in .gateway_ip and tried docker compose exec tailscale ip -4)"
fi

# ═══════════════════════════════════════════════════════════════════════════
section "8/8  Tailscale System Extension (App Store conflict check)"
# ═══════════════════════════════════════════════════════════════════════════
SE_PENDING_UNINSTALL=false
SE_ACTIVE=false
if command -v systemextensionsctl >/dev/null 2>&1; then
  SE_OUT=$(systemextensionsctl list 2>/dev/null | grep -iE '(io|com)\.tailscale')
  if [ -n "$SE_OUT" ]; then
    line "  Tailscale System Extension(s) detected:"
    line "$(printf '%s' "$SE_OUT" | awk '{print "    "$0}')"
    if printf '%s' "$SE_OUT" | grep -q 'waiting to uninstall'; then
      SE_PENDING_UNINSTALL=true
      warn "System Extension is pending uninstall on next reboot."
    else
      SE_ACTIVE=true
      warn "Active Tailscale System Extension detected. This will conflict with Homebrew Tailscale."
    fi
  else
    ok "no Tailscale System Extension detected"
  fi
else
  note "systemextensionsctl not available (not on macOS or permission restricted)"
fi

# ═══════════════════════════════════════════════════════════════════════════
section "CLASSIFICATION  →  applies ONE of the four known scenarios"
# ═══════════════════════════════════════════════════════════════════════════

if [ "$WARP_STATUS" = "on" ] && [ "$IPV6_LEAK" = "false" ]; then
  SCENARIO="OK"
elif [ "$SE_PENDING_UNINSTALL" = "true" ]; then
  SCENARIO="SE_PENDING"
elif [ "$SOCKS5_ENABLED" = "true" ]; then
  SCENARIO="A"
elif [ "$IPV6_LEAK" = "true" ]; then
  SCENARIO="B"
elif [ "$DEFAULT_VIA_UTUN" = "false" ] && [ "$TS_ON_MESH" = "true" ]; then
  SCENARIO="C"
else
  SCENARIO="UNKNOWN"
fi

case "$SCENARIO" in
  SE_PENDING)
    echo ""
    echo -e "  ${RED}${BOLD}VERDICT:  Scenario SE_PENDING — Tailscale System Extension Pending Uninstall${NC}"
    echo "  A prior App Store Tailscale System Extension is pending uninstall."
    echo "  Since System Integrity Protection (SIP) is enabled, macOS blocks manual"
    echo "  uninstallation of terminated system extensions until the next reboot."
    echo "  Brew-managed tailscaled cannot engage the Network Extension slot until this is resolved."
    echo ""
    echo "  ${BOLD}Recommended fix:${NC}"
    echo "    sudo shutdown -r now"
    echo "    # After reboot, run:  ./toggle.sh"
    ;;
  A)
    echo ""
    echo -e "  ${RED}${BOLD}VERDICT:  Scenario A — SOCKS5 fallback lane${NC}"
    echo "  toggle.sh's pre-flight checks failed last run. The script activated"
    echo "  SOCKS5 + local DNS proxy as a fallback. DNS gets hijacked but"
    echo "  browsers on macOS ignore the system SOCKS5 → traffic egresses"
    echo "  direct through the local network."
    echo ""
    echo "  ${BOLD}Recommended fix:${NC}"
    echo "    echo 'GATEWAY_BYPASS_PING=true' >> $PROJECT_ROOT/.env"
    echo "    sudo tailscale up --reset --ssh=true --accept-dns=false --accept-routes=true \\"
    if [ -n "$GATEWAY_TS_IP" ]; then
    echo "        --exit-node=$GATEWAY_TS_IP --exit-node-allow-lan-access=true"
    else
    echo "        --exit-node=\$GATEWAY_TS_IP --exit-node-allow-lan-access=true  # fill in $GATEWAY_TS_IP"
    fi
    echo "    sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder"
    echo "    ./toggle.sh"
    ;;
  B)
    echo ""
    echo -e "  ${RED}${BOLD}VERDICT:  Scenario B — IPv6 leak over dual-stack campus/local IPv6${NC}"
    echo "  Tailscale exit-node advertises only IPv4. macOS sends AAAA queries"
    echo "  straight out en0, which is dual-stack on most campus APs — IPv6"
    echo "  traffic bypasses the WARP tunnel entirely."
    echo ""
    echo "  ${BOLD}Recommended fix:${NC}"
    echo "    sudo networksetup -setv6off $ACTIVE_SERVICE"
    echo "    sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder"
    echo "    # Re-enable IPv6 later with:  sudo networksetup -setv6automatic $ACTIVE_SERVICE"
    ;;
  C)
    echo ""
    echo -e "  ${RED}${BOLD}VERDICT:  Scenario C — Tailscale route-freeze${NC}"
    echo "  Host's default route points at the Wi-Fi gateway instead of the"
    echo "  Tailscale utun* interface. The exit-node preference is set but the"
    echo "  routing-table assertion did not take effect (devref §10.26)."
    echo ""
    echo "  ${BOLD}Recommended fix:${NC}"
    echo "    sudo brew services restart tailscale"
    echo "    sudo route delete -net 0.0.0.0/1"
    echo "    sudo route delete -net 128.0.0.0/1"
    echo "    sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder"
    if [ -n "$GATEWAY_TS_IP" ]; then
    echo "    sudo tailscale up --reset --ssh=true --accept-dns=false --accept-routes=true \\"
    echo "        --exit-node=$GATEWAY_TS_IP --exit-node-allow-lan-access=true"
    else
    echo "    sudo tailscale up --reset --ssh=true --accept-dns=false --accept-routes=true --exit-node=\$TS_IP --exit-node-allow-lan-access=true"
    fi
    echo "    ./toggle.sh"
    ;;
  OK)
    echo ""
    echo -e "  ${GREEN}${BOLD}VERDICT:  No host leak detected — tunnel is working${NC}"
    echo "  The local ISP string from whatismyip.com is its IP-database"
    echo "  misclassifying the Cloudflare egress IP.  CDN-CGI's trace endpoint"
    echo "  (which is what we use here) reports warp=on because that endpoint"
    echo "  is hosted by Cloudflare itself and can see its own edge."
    echo "  If you want a third-party confirmation:"
    echo "    curl -s https://api.ipify.org; echo"
    ;;
  *)
    echo ""
    echo -e "  ${YELLOW}${BOLD}VERDICT:  Could not classify automatically${NC}"
    echo "  The diagnostic data did not match any known scenario cleanly."
    echo "  Likely causes:"
    echo "    - tailscaled is logged out / expired (see Section 1)"
    echo "    - Docker is not running (gateway containers down)"
    echo "    - .gateway_ip missing AND docker compose exec failed"
    echo "  Inspect the report at: $REPORT_FILE"
    ;;
esac
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# Write the verdict block to the report file
# ═══════════════════════════════════════════════════════════════════════════
SECOND_BLOCK=$(cat <<EOF

════════════════════════════════════════════════════════════
 C L A S S I F I C A T I O N   R E S U L T
════════════════════════════════════════════════════════════
 Scenario: $SCENARIO
 WARP egress:  $WARP_STATUS  (cdn-cgi/trace)
 SOCKS5 lane:  $([ "$SOCKS5_ENABLED" = true ] && echo "ENABLED (browsers bypass)" || echo "off")
 IPv6 leak:    $([ "$IPV6_LEAK" = true ] && echo "YES (campus IPv6 egress)" || echo "no")
 Default via:  $([ "$DEFAULT_VIA_UTUN" = true ] && echo "utun* (Tailscale)" || echo "Wi-Fi gateway")
 Host on mesh: $([ "$TS_ON_MESH" = true ] && echo "yes" || echo "no")
 SE pending:   $([ "$SE_PENDING_UNINSTALL" = true ] && echo "yes" || echo "no")
 Gateway IP:   ${GATEWAY_TS_IP:-unresolved}
EOF
)
printf '%s\n' "$SECOND_BLOCK" >&3

# ═══════════════════════════════════════════════════════════════════════════
# --fix mode
# ═══════════════════════════════════════════════════════════════════════════
if [ "$DO_FIX" = "true" ] && [ "$SCENARIO" != "OK" ] && [ "$SCENARIO" != "UNKNOWN" ]; then
  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo " A P P L Y I N G   F I X  (scenario $SCENARIO)"
  echo "════════════════════════════════════════════════════════════"
  echo ""

  case "$SCENARIO" in
    SE_PENDING)
      warn "System Extension uninstall is pending on next reboot."
      line "Please run 'sudo shutdown -r now' to reboot the system."
      ;;
    A)
      if [ -n "$GATEWAY_TS_IP" ]; then
        line "→ writing GATEWAY_BYPASS_PING=true to .env"
        ENV="$PROJECT_ROOT/.env"
        [ -f "$ENV" ] || touch "$ENV"
        if grep -q '^GATEWAY_BYPASS_PING=' "$ENV" 2>/dev/null; then
          sed -i '' 's/^GATEWAY_BYPASS_PING=.*/GATEWAY_BYPASS_PING=true/' "$ENV"
        else
          printf '\nGATEWAY_BYPASS_PING=true\n' >> "$ENV"
        fi
        line "→ re-asserting tailscale exit-node (with --reset)"
        sudo -n tailscale up --reset --ssh=true --accept-dns=false --accept-routes=true \
             --exit-node="$GATEWAY_TS_IP" --exit-node-allow-lan-access=true \
             >> "$LOG_FILE" 2>&1 \
          && ok "tailscale exit-node re-asserted for $GATEWAY_TS_IP" \
          || warn "tailscale up did not return success (check $LOG_FILE)"
      else
        warn "no gateway Tailscale IP resolved — skipping tailscale up"
        warn "fix manually: 'sudo tailscale up --reset ... --exit-node=<TS_IP>'"
      fi
      ;;
    B)
      line "→ disabling IPv6 on $ACTIVE_SERVICE while gateway is up"
      sudo -n networksetup -setv6off "$ACTIVE_SERVICE" >> "$LOG_FILE" 2>&1 \
        && ok "IPv6 disabled on $ACTIVE_SERVICE (re-enable with 'setv6automatic')" \
        || warn "networksetup -setv6off failed (check $LOG_FILE)"
      ;;
    C)
      line "→ restarting tailscaled (route-table fix)"
      run_with_timeout 15 brew services restart tailscale >> "$LOG_FILE" 2>&1 \
        || run_with_timeout 15 sudo -n brew services restart tailscale >> "$LOG_FILE" 2>&1
      sleep 3
      line "→ flushing stale host routes + DNS cache"
      sudo -n route delete -net 0.0.0.0/1 >> "$LOG_FILE" 2>&1 || true
      sudo -n route delete -net 128.0.0.0/1 >> "$LOG_FILE" 2>&1 || true
      sudo -n dscacheutil -flushcache >> "$LOG_FILE" 2>&1 || true
      sudo -n killall -HUP mDNSResponder >> "$LOG_FILE" 2>&1 || true
      if [ -n "$GATEWAY_TS_IP" ]; then
        line "→ re-asserting exit-node after restart"
        sudo -n tailscale up --reset --ssh=true --accept-dns=false --accept-routes=true \
             --exit-node="$GATEWAY_TS_IP" --exit-node-allow-lan-access=true \
             >> "$LOG_FILE" 2>&1 \
          && ok "tailscale exit-node re-asserted for $GATEWAY_TS_IP" \
          || warn "tailscale up did not return success (check $LOG_FILE)"
      fi
      ;;
  esac

  echo ""
  echo "Re-verifying after fix..."
  sleep 3
  CDN_WARP_AFTER=$(run_with_timeout 8 curl -s --max-time 6 \
      https://www.cloudflare.com/cdn-cgi/trace 2>&1 \
      | awk -F'=' '/^warp=/{print $2; exit}')
  IPV6_AFTER=$(run_with_timeout 7 curl -6 -s --max-time 5 ifconfig.co 2>&1 || echo "")
  printf '\n[AFTER FIX]\n' >&3
  printf '  warp status:    %s\n' "$CDN_WARP_AFTER" >&3
  printf '  IPv6 egress:     %s\n' "${IPV6_AFTER:-none}" >&3
  line "  warp status:    ${CDN_WARP_AFTER:-unknown}"
  line "  IPv6 egress:    ${IPV6_AFTER:-none}"
  if [ "$CDN_WARP_AFTER" = "on" ] && [ -z "$IPV6_AFTER" ]; then
    echo ""
    ok "Fix verified — host is now routing through WARP. Remote clients unaffected."
  else
    echo ""
    warn "Fix did not fully take effect on first try. Likely causes:"
    line "  • tailscaled needed a longer settling window (re-run diagnostic in 30s)"
    line "  • The classified scenario was wrong; paste this report for triage."
    line "  • Tailscale needs a full auth refresh: 'sudo tailscale up'"
  fi
fi

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  Full report written to:"
echo "    $REPORT_FILE"
echo "════════════════════════════════════════════════════════════"
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# --watch mode: enter the continuous monitoring loop after baseline diagnostic
# ═══════════════════════════════════════════════════════════════════════════
if [ "$DO_WATCH" = "true" ]; then
  # Build baseline from the full diagnostic just completed
  BASELINE_WARP="$WARP_STATUS"
  BASELINE_DEFAULT=$([ "$DEFAULT_VIA_UTUN" = "true" ] && echo "utun" || echo "wifi/other")

  if [ "$SCENARIO" != "OK" ]; then
    warn "Baseline diagnostic found issues (scenario: $SCENARIO)."
    line "  Watch loop will still run — alerts fire on any STATE CHANGE from current baseline."
    line "  Fix the issue first? Re-run with:  bash scripts/diagnose-host-leak.sh --fix"
    echo ""
  fi

  run_watch_loop "$BASELINE_WARP" "$BASELINE_DEFAULT" "$IPV6_LEAK" "$WATCH_INTERVAL"
fi

exit 0
