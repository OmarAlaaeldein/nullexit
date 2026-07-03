#!/bin/bash
# scripts/diagnose-host-leak.sh — nullexit host-routing diagnostic
#
# Symptom this addresses: tests like https://www.whatismyip.com on the
# *HOST MAC* return the underlying physical ISP/ASN (e.g. "Université de
# Montréal / UdeM") even though the nullexit gateway is active and remote
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
#   bash scripts/diagnose-host-leak.sh          # diagnose + write report
#   bash scripts/diagnose-host-leak.sh --fix    # diagnose + fix + re-verify
#   bash scripts/diagnose-host-leak.sh --help   # this message
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
LOG_FILE="$PROJECT_ROOT/output.log"
REPORT_FILE="$PROJECT_ROOT/host-leak-diagnostic-$TIMESTAMP.txt"

# ─── Argument parsing ───────────────────────────────────────────────────────
DO_FIX=false
case "${1:-}" in
  --fix) DO_FIX=true ;;
  --help|-h)
    sed -n '2,28p' "$0"
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
# tee-to-file approach: every diagnostic line is printed live (so the user
# sees progress when running interactively) and captured to REPORT_FILE
# (so they have a saved artefact they don't have to scroll-and-copy from).
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

# ─── Always add Homebrew to PATH (same as toggle.sh / recover.sh) ──────────
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# ─── Pure-bash timeout (macOS lacks GNU `timeout`) ──────────────────────────
# Borrowed verbatim from recover.sh — same semantics with one caveat: we
# use `kill -9` (SIGKILL) for the timeout victim, so the child exits with
# code 137 (128+9), NOT 143 (SIGTERM = 128+15). Same "kill the watchdog
# on completion" trick to avoid the watchdog subprocess racing ahead.
run_with_timeout() {
  local timeout_sec="$1"
  shift
  if [ "$#" -eq 0 ]; then return 1; fi
  "$@" &  # ? "$@" & or "$@" >> "$LOG_FILE" 2>&1 &
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
  local iface
  iface=$(route get default 2>> "$LOG_FILE" | awk '/interface:/{print $2; exit}')
  if [ -z "$iface" ] || [ "${iface#utun}" != "$iface" ] || [ "${iface#tun}" != "$iface" ]; then
    for i in en0 en1 en2 en3 en4 en5; do
      if ifconfig "$i" 2>> "$LOG_FILE" | grep -q "status: active" \
         && ifconfig "$i" 2>> "$LOG_FILE" | grep -q "inet "; then
        iface="$i"; break
      fi
    done
  fi
  [ -z "$iface" ] && iface="en0"
  local svc
  svc=$(networksetup -listnetworkserviceorder 2>> "$LOG_FILE" \
        | grep -B 1 "Device: $iface" | head -n 1 \
        | sed -E 's/^\([0-9\*]+\) //' || true)
  [ -z "$svc" ] && svc="Wi-Fi"
  printf '%s\n' "$svc"
}

ACTIVE_SERVICE=$(resolve_active_service)
EN0_SERVICE=$(networksetup -listnetworkserviceorder 2>> "$LOG_FILE" \
              | grep -B 1 "Device: en0" | head -1 \
              | sed -E 's/^\([0-9\*]+\) //' || true)
[ -z "$EN0_SERVICE" ] && EN0_SERVICE="Wi-Fi"

# Resolve the gateway's Tailscale IP. Primary: ADGUARD_IP.txt (fast). Fallback:
# docker compose exec on the running tailscale container (handles re-auths).
GATEWAY_TS_IP=""
if [ -f "$PROJECT_ROOT/ADGUARD_IP.txt" ]; then
  GATEWAY_TS_IP=$(cat "$PROJECT_ROOT/ADGUARD_IP.txt" 2>> "$LOG_FILE" \
                  | tr -d '\r' | awk 'NR==1{print $1; exit}')
fi
if [ -z "$GATEWAY_TS_IP" ] && command -v docker >> "$LOG_FILE" 2>&1 \
   && docker compose ps --status running 2>/dev/null | grep -q 'tailscale'; then
  GATEWAY_TS_IP=$(run_with_timeout 10 docker compose exec -T tailscale \
                  tailscale ip -4 2>> "$LOG_FILE" \
                  | tr -d '\r' | awk 'NR==1{print $1; exit}')
fi

# ─── Scenario classification state ──────────────────────────────────────────
SCENARIO=""          # A | B | C | ""
WARP_STATUS=""       # "on" | "off" | "unknown"
SOCKS5_ENABLED=false
TS_ON_MESH=false     # is the host on the tailnet with the gateway reachable?
DEFAULT_VIA_UTUN=false
IPV6_LEAK=false

# ═══════════════════════════════════════════════════════════════════════════
section "1/8  Host Tailscale mesh status"
# ═══════════════════════════════════════════════════════════════════════════
if ! command -v tailscale >> "$LOG_FILE" 2>&1; then
  fail "tailscale CLI not on PATH — install via 'brew install tailscale' then re-run"
  echo "  (a Tailscale daemon is required for the exit-node path to work)"
else
  # 5s timeout: a wedged tailscaled manifests as a hang, not an immediate
  # error (devref §10.26 documents this exact failure mode).
  # Two bugs avoided here:
  #   (a) `|| true` after run_with_timeout makes the pipeline exit 0 regardless,
  #       so $TS_EXIT always reads 0 and the wedged-daemon check below is dead.
  #   (b) run_with_timeout uses `kill -9` for the timeout victim, so the exit
  #       code propagated is 137 (SIGKILL = 128+9), NOT 143 (SIGTERM = 128+15).
  # The deliberate set +e / set -uo pipefail window captures the real exit code
  # without disabling errexit for the rest of the script.
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
# SOCKS5 "Enabled: Yes" means toggle.sh's pre-flight checks failed last run
# and the script fell back to SOCKS5 + local DNS proxy (toggle.sh:849,894).
# Modern browsers on macOS do NOT honor the system SOCKS5 proxy, so traffic
# exits directly through UdeM even though DNS is hijacked.
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
# CDN-CGI's `trace` endpoint reports warp=on|off and the resolved colo —
# it is far more reliable than whatismyip.com's ISP-detection database,
# which frequently mislabels campus IPv6 ranges.
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
  line "  → whatismyip.com's 'udem' result is its ISP-database error, not yours."
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
# The exit node AND WARP are IPv4-only. If the host has IPv6 enabled (true on
# virtually every UdeM campus AP), any IPv6 AAAA query resolves and egresses
# straight out en0, even when Tailscale is set as the exit node (devref §10.6).
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
section "5/8  Host default route (should be utun*, NOT 192.168.x.x)"
# ═══════════════════════════════════════════════════════════════════════════
# When Tailscale exit-node is active, macOS installs utunX as default route.
# If the host default route points at the Wi-Fi gateway (192.168.x.x), the
# routing-table assertion failed (devref §10.26 — route freeze).
DEFAULT_ROUTE=$(netstat -rn 2>> "$LOG_FILE" | awk '/^default/ {print $0; exit}')
if [ -z "$DEFAULT_ROUTE" ]; then
  warn "no default route detected"
else
  line "  $DEFAULT_ROUTE"
  if printf '%s' "$DEFAULT_ROUTE" | grep -qE 'utun[0-9]+'; then
    ok "default route goes via utun* → Tailscale is owning the egress route"
    DEFAULT_VIA_UTUN=true
  elif printf '%s' "$DEFAULT_ROUTE" | grep -qE '^(default|0\.0\.0\.0).*\b192\.168\.'; then
    fail "default route goes via physical Wi-Fi (192.168.x.x) — Tailscale route assertion failed"
  else
    warn "default route has unexpected shape: $DEFAULT_ROUTE"
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
  line "  (looked in ADGUARD_IP.txt and tried docker compose exec tailscale ip -4)"
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
# Priority order (most-specific first):
#   SE_PENDING. System Extension Pending Uninstall — brew tailscaled blocked by a pending SE delete
#   A. SOCKS5 fallback lane active                — host traffic bypasses because browsers ignore macOS SOCKS5
#   B. Tailscale routing OK, but IPv6 leak         — campus IPv6 AAAA egress skips the IPv4-only tunnel
#   C. Route-freeze                               — Tailscale default route assertion failed on host
#   OK. Everything checks out                     — host IS going through WARP; whatismyip.com's ISP DB is lying
# We only pick the first scenario whose preconditions fully hold, to keep
# the fix deterministic (one scenario → one fix command).

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
    echo "  direct through UdeM."
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
    echo -e "  ${RED}${BOLD}VERDICT:  Scenario B — IPv6 leak over UdeM campus IPv6${NC}"
    echo "  Tailscale exit-node advertises only IPv4. macOS sends AAAA queries"
    echo "  straight out en0, which is dual-stack on UdeM campus APs — IPv6"
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
    echo "    sudo route -n flush"
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
    echo "  The 'udem' ISP string from whatismyip.com is its IP-database"
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
    echo "    - ADGUARD_IP.txt missing AND docker compose exec failed"
    echo "  Inspect the report at: $REPORT_FILE"
    ;;
esac
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# Write the verdict block to the report file too (mirrors stdout so a user
# inspecting the file without running the script gets the same conclusion).
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
# --fix mode: apply the scenario-matched remediation, then re-verify only the
# two checks that could change (warp + ipv6). We deliberately do NOT loop —
# if the first fix doesn't take, the user gets a clearer second report to
# paste back than a confused mid-fix-loop mess.
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
        # In-place update of .env WITHOUT a temp-file round-trip. The naive
        # `grep -v > tmp && mv tmp back` pattern destroys the file when the
        # variable was not already present (grep matches nothing → tmp is
        # empty → mv overwrites .env with empty content, wiping the user's
        # WARP private key + TS auth key). Replace-or-append is safe.
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
      sudo -n route -n flush >> "$LOG_FILE" 2>&1 || true
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

  # Re-verify the two checks that could change after a fix.
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

# Only classify completed, not auto-exit (--fix returns success even if fix
# failed; the verdict and report carry the relevant signals).
exit 0
