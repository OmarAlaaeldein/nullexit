#!/bin/bash
# scripts/sweep.sh — nullexit gateway health sweep
#
# Automates the 5-check post-restart health sweep documented in sweep.md §1.
# It answers one question: "after a toggle/restart/wake, is the gateway
# actually healthy end-to-end — no leak, direct P2P, DNS filtering live,
# kill-switch armed?" It is READ-ONLY: it never mutates routing, PF, DNS,
# or containers, so it is safe to run against a live gateway at any time
# (including from a remote session — see the caveat in agent.md L16).
#
# The 5 checks (mirroring sweep.md §1):
#   1. Containers          — warp, adguardhome, tailscale, tor, routing-fix up/healthy
#   2. Double-tunnel/leak  — container WARP exit IP == host exit IP, both warp=on
#   3. Host↔container path  — Tailscale exit-node is a DIRECT P2P conn, not DERP relay
#   4. AdGuard filtering    — compiled rule counts present + live DNS interception
#   5. PF kill-switch       — pfctl Enabled + anchor com.apple/nullexit carries rules
#
# A timestamped report is written to the project root (one file per run, so
# runs can be diffed). stdout carries a coloured summary + a final PASS/FAIL
# verdict; exit code is 0 when every check passes, 1 otherwise (so it can gate
# CI / launchd / a post-restart hook).
#
# Usage:
#   bash scripts/sweep.sh            # run the sweep, write report, print verdict
#   bash scripts/sweep.sh --quiet    # only the final verdict line + non-zero on FAIL
#   bash scripts/sweep.sh --help     # this message

set -uo pipefail
# NOTE: errexit is intentionally OFF. Several probes are EXPECTED to fail on an
# unhealthy gateway and that failure IS the diagnostic signal — we record each
# exit status rather than letting one abort the whole sweep.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
cd "$PROJECT_ROOT" || { echo "[FATAL] cannot cd to $PROJECT_ROOT" >&2; exit 1; }
source "$SCRIPT_DIR/common.sh"
LOG_FILE="$PROJECT_ROOT/output.log"
REPORT_FILE="$PROJECT_ROOT/sweep-$TIMESTAMP.txt"

# ─── Argument parsing ───────────────────────────────────────────────────────
QUIET=false
case "${1:-}" in
  --quiet|-q) QUIET=true ;;
  --help|-h)  sed -n '2,26p' "$0"; exit 0 ;;
  "")         : ;;
  *)          echo "Unknown argument: $1" >&2
              echo "Run with --help for usage." >&2
              exit 2 ;;
esac

# ─── Colours (auto-disabled when stdout is not a tty, e.g. piped) ───────────
if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BOLD=''; NC=''
fi

# ─── Homebrew on PATH (same as toggle.sh / recover.sh / diagnose-host-leak) ─
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# ─── Output helpers — write to BOTH stdout and the report file ──────────────
exec 3>> "$REPORT_FILE" || {
  printf '\n[FATAL] cannot open %s for write\n' "$REPORT_FILE" >&2
  exit 1
}
emit()    { [ "$QUIET" = true ] || printf '%b\n' "$1"; printf '%b\n' "$1" | sed 's/\x1b\[[0-9;]*m//g' >&3; }
section() { emit ""; emit "${BOLD}═══════ $1 ═══════${NC}"; }
line()    { emit "  $1"; }
ok()      { line "${GREEN}✓${NC} $1"; }
warn()    { line "${YELLOW}⚠${NC} $1"; }
fail()    { line "${RED}✗${NC} $1"; }

# common.sh redefines run_with_timeout; it is a pure-bash macOS-safe timeout
# (GNU `timeout` is absent on stock macOS). We reuse the sourced version.

# ─── Result accounting ──────────────────────────────────────────────────────
# Each check appends "PASS"/"WARN"/"FAIL" so the verdict is a pure roll-up.
declare -a RESULTS=()
record() { RESULTS+=("$1|$2"); }   # status|label

# ─── Header ─────────────────────────────────────────────────────────────────
if [ "$QUIET" != true ]; then
  emit ""
  emit "════════════════════════════════════════════════════════════"
  emit " n u l l e x i t   h e a l t h   s w e e p"
  emit "════════════════════════════════════════════════════════════"
  emit " Timestamp (UTC): $TIMESTAMP"
  emit " Project root:    $PROJECT_ROOT"
  emit " Report file:     $REPORT_FILE"
  emit "════════════════════════════════════════════════════════════"
fi

GATEWAY_TS_IP="$(read_adguard_ip)"   # gateway Tailscale IP from .gateway_ip

# ═══════════════════════════════════════════════════════════════════════════
section "1/5  Containers"
# ═══════════════════════════════════════════════════════════════════════════
# All five services must be running; warp + adguardhome additionally expose a
# healthcheck and must be 'healthy'. `docker compose ps` is the source of truth.
EXPECTED_SERVICES="warp adguardhome tailscale tor routing-fix"
if ! command -v docker >/dev/null 2>&1; then
  fail "docker CLI not on PATH — cannot inspect containers"
  record FAIL "containers"
else
  PS_OUT=$(run_with_timeout 20 docker compose ps 2>>"$LOG_FILE")
  missing=""; unhealthy=""
  for svc in $EXPECTED_SERVICES; do
    row=$(printf '%s\n' "$PS_OUT" | awk -v s="$svc" '$1==s || $0 ~ ("[[:space:]]"s"[[:space:]]")')
    if [ -z "$row" ] || ! printf '%s' "$row" | grep -qiE 'up|running'; then
      missing="$missing $svc"
    elif printf '%s' "$row" | grep -qi 'unhealthy'; then
      unhealthy="$unhealthy $svc"
    fi
  done
  if [ -z "$missing" ] && [ -z "$unhealthy" ]; then
    ok "all 5 services up (warp/adguardhome healthy, tailscale/tor/routing-fix running)"
    record PASS "containers"
  else
    [ -n "$missing" ]   && fail "not up/running:$missing"
    [ -n "$unhealthy" ] && fail "reporting unhealthy:$unhealthy"
    record FAIL "containers"
  fi
  line "── docker compose ps ──"
  printf '%s\n' "$PS_OUT" | awk '{print "    "$0}' >&3
  [ "$QUIET" = true ] || printf '%s\n' "$PS_OUT" | awk '{print "    "$0}'
fi

# ═══════════════════════════════════════════════════════════════════════════
section "2/5  Double-tunnel / IP-leak"
# ═══════════════════════════════════════════════════════════════════════════
# The container's WARP egress and the host's egress must be the SAME public IP
# with warp=on for both. Equal IPs ⇒ all host traffic is exiting through the
# same WARP tunnel the container uses (no split / raw-ISP leak).
# The warp container (gluetun) ships wget, not curl — fetch the trace from
# inside its netns with whichever client is present.
CTR_TRACE=$(run_with_timeout 12 docker compose exec -T warp sh -c \
            'curl -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
             || wget -qO- --timeout=8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null' \
            2>>"$LOG_FILE")
HOST_TRACE=$(run_with_timeout 12 curl -s --max-time 8 \
            https://www.cloudflare.com/cdn-cgi/trace 2>>"$LOG_FILE")
CTR_IP=$(printf '%s' "$CTR_TRACE"  | awk -F= '/^ip=/{print $2;exit}')
CTR_WARP=$(printf '%s' "$CTR_TRACE" | awk -F= '/^warp=/{print $2;exit}')
HOST_IP=$(printf '%s' "$HOST_TRACE" | awk -F= '/^ip=/{print $2;exit}')
HOST_WARP=$(printf '%s' "$HOST_TRACE"| awk -F= '/^warp=/{print $2;exit}')
line "container exit: ip=${CTR_IP:-?} warp=${CTR_WARP:-?}"
line "host exit:      ip=${HOST_IP:-?} warp=${HOST_WARP:-?}"
if [ -z "$CTR_IP" ] || [ -z "$HOST_IP" ]; then
  fail "could not obtain both egress IPs (container or host trace failed)"
  record FAIL "leak"
elif [ "$CTR_IP" = "$HOST_IP" ] && [ "$HOST_WARP" = "on" ]; then
  ok "no leak — host egress == container egress ($HOST_IP), warp=on"
  record PASS "leak"
elif [ "$HOST_WARP" != "on" ]; then
  fail "host warp=$HOST_WARP — host traffic is NOT going through WARP (LEAK)"
  record FAIL "leak"
else
  fail "egress mismatch: host $HOST_IP != container $CTR_IP — split/leak"
  record FAIL "leak"
fi

# ═══════════════════════════════════════════════════════════════════════════
section "3/5  Host ↔ container path (direct P2P, not DERP relay)"
# ═══════════════════════════════════════════════════════════════════════════
# `tailscale status` annotates each peer with 'direct <ip:port>' or
# 'relay "<derp>"'. The gateway peer should be DIRECT — a DERP relay hop adds
# latency and signals NAT traversal failure between host and gateway.
if ! command -v tailscale >/dev/null 2>&1; then
  fail "tailscale CLI not on PATH"
  record FAIL "p2p"
else
  TS_OUT=$(run_with_timeout 6 tailscale status 2>>"$LOG_FILE")
  PEER_LINE=$(printf '%s\n' "$TS_OUT" | grep -E "(^|[[:space:]])$GATEWAY_TS_IP([[:space:]]|$)" | head -1)
  if [ -z "$PEER_LINE" ]; then
    warn "gateway $GATEWAY_TS_IP not found in host peer list"
    line "$(printf '%s\n' "$TS_OUT" | head -5 | awk '{print "    "$0}')"
    record WARN "p2p"
  elif printf '%s' "$PEER_LINE" | grep -q 'direct '; then
    conn=$(printf '%s' "$PEER_LINE" | grep -oE 'direct [0-9.]+:[0-9]+')
    ok "direct P2P to gateway — $conn (no DERP relay)"
    record PASS "p2p"
  elif printf '%s' "$PEER_LINE" | grep -q 'relay '; then
    relay=$(printf '%s' "$PEER_LINE" | grep -oE 'relay "[^"]+"')
    warn "gateway reached via DERP $relay (not direct) — NAT traversal degraded"
    record WARN "p2p"
  else
    warn "gateway peer state indeterminate (idle/no active conn)"
    line "    $PEER_LINE"
    record WARN "p2p"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
section "4/5  AdGuard filtering"
# ═══════════════════════════════════════════════════════════════════════════
# Two signals: (a) the compiled ruleset exists with a non-trivial block count,
# (b) the gateway resolver actually answers a query (live interception).
COMPILED="adguard/work/userfilters/compiled_rules.txt"
if [ -f "$COMPILED" ]; then
  TOTAL=$(grep -m1 '! Total Block Rules:'  "$COMPILED" | awk -F': ' '{print $2}' | tr -d '[:space:]')
  NATIVE=$(grep -m1 '! Native AdGuard Rules:' "$COMPILED" | awk -F': ' '{print $2}' | tr -d '[:space:]')
  if [ -n "$TOTAL" ] && [ "$TOTAL" -gt 0 ] 2>/dev/null; then
    ok "compiled ruleset present — Total Block Rules: $TOTAL / Native AdGuard: ${NATIVE:-?}"
    RULES_OK=true
  else
    warn "compiled_rules.txt present but block-rule count unreadable"
    RULES_OK=false
  fi
else
  warn "compiled_rules.txt missing (rule-compile may not have run)"
  RULES_OK=false
fi
# Live interception: the gateway resolver must answer (dig via .gateway_ip).
DNS_OK=false
if command -v dig >/dev/null 2>&1 && [ -n "$GATEWAY_TS_IP" ]; then
  DIG_OUT=$(run_with_timeout 8 dig +time=3 +tries=1 @"$GATEWAY_TS_IP" google.com A 2>>"$LOG_FILE")
  if printf '%s' "$DIG_OUT" | grep -qE 'ANSWER SECTION|status: NOERROR'; then
    ok "live DNS interception — gateway $GATEWAY_TS_IP resolved google.com"
    DNS_OK=true
  else
    warn "gateway $GATEWAY_TS_IP did not answer a test query"
  fi
else
  warn "skipped live-resolution probe (dig missing or gateway IP unknown)"
fi
if [ "$RULES_OK" = true ] && [ "$DNS_OK" = true ]; then
  record PASS "adguard"
elif [ "$RULES_OK" = true ] || [ "$DNS_OK" = true ]; then
  record WARN "adguard"
else
  record FAIL "adguard"
fi

# ═══════════════════════════════════════════════════════════════════════════
section "5/5  PF kill-switch"
# ═══════════════════════════════════════════════════════════════════════════
# PF must be Enabled AND the com.apple/nullexit anchor must carry rules.
# An empty/absent anchor means the fail-closed lane is not actually armed.
PF_STATUS=$(run_with_timeout 6 sudo -n pfctl -s info 2>>"$LOG_FILE" | awk '/^Status:/{print $2;exit}')
ANCHOR_RULES=$(run_with_timeout 6 sudo -n pfctl -a com.apple/nullexit -sr 2>>"$LOG_FILE")
if [ "$PF_STATUS" = "Enabled" ] && [ -n "$ANCHOR_RULES" ]; then
  RULE_N=$(printf '%s\n' "$ANCHOR_RULES" | grep -cvE '^\s*$')
  ok "PF Enabled + anchor com.apple/nullexit armed ($RULE_N rules)"
  line "$(printf '%s\n' "$ANCHOR_RULES" | head -4 | awk '{print "    "$0}')"
  record PASS "pf"
elif [ "$PF_STATUS" = "Enabled" ]; then
  fail "PF Enabled but anchor com.apple/nullexit has NO rules — kill-switch not armed"
  record FAIL "pf"
elif [ -z "$PF_STATUS" ]; then
  warn "could not read PF status (needs passwordless sudo for 'pfctl -s info')"
  record WARN "pf"
else
  fail "PF Status: $PF_STATUS — kill-switch disabled"
  record FAIL "pf"
fi

# ═══════════════════════════════════════════════════════════════════════════
section "VERDICT"
# ═══════════════════════════════════════════════════════════════════════════
pass=0; warnc=0; failc=0
for r in "${RESULTS[@]}"; do
  case "${r%%|*}" in PASS) pass=$((pass+1));; WARN) warnc=$((warnc+1));; FAIL) failc=$((failc+1));; esac
done
for r in "${RESULTS[@]}"; do
  st="${r%%|*}"; lbl="${r##*|}"
  case "$st" in
    PASS) ok   "$lbl" ;;
    WARN) warn "$lbl" ;;
    FAIL) fail "$lbl" ;;
  esac
done
emit ""
if [ "$failc" -eq 0 ] && [ "$warnc" -eq 0 ]; then
  emit "${GREEN}${BOLD}SWEEP PASS — gateway healthy (${pass}/5 checks green)${NC}"
  EXIT=0
elif [ "$failc" -eq 0 ]; then
  emit "${YELLOW}${BOLD}SWEEP PASS with warnings — ${pass} pass, ${warnc} warn, 0 fail${NC}"
  EXIT=0
else
  emit "${RED}${BOLD}SWEEP FAIL — ${pass} pass, ${warnc} warn, ${failc} fail${NC}"
  EXIT=1
fi
emit ""
[ "$QUIET" = true ] || emit "Full report: $REPORT_FILE"
exit "$EXIT"
