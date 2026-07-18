#!/bin/bash
# scripts/sweep.sh — nullexit gateway health sweep
#
# Automates the 7-check post-restart health sweep (sweep.md §1 + tailnet ping
# + throughput). It answers one question: "after a toggle/restart/wake, is
# the gateway actually healthy end-to-end — no leak, direct P2P, DNS
# filtering live, kill-switch armed, and fast enough to actually use?" It is
# READ-ONLY with respect to gateway state: it never mutates routing, PF, DNS,
# or containers (the throughput check only pulls a test file over curl — the
# same kind of traffic any app already sends, nothing is exec'd into or
# installed in the container), so it is safe to run against a live gateway at
# any time (including from a remote session — see the caveat in agent.md L16).
#
# The 7 checks (1-5 mirror sweep.md §1):
#   1. Containers          — warp, adguardhome, tailscale, tor, routing-fix up/healthy
#   2. Double-tunnel/leak  — container WARP exit IP == host exit IP, both warp=on
#   3. Host↔container path  — Tailscale exit-node is a DIRECT P2P conn, not DERP relay
#   4. AdGuard filtering    — compiled rule counts present + live DNS interception
#   5. PF kill-switch       — pfctl Enabled + anchor com.apple/nullexit carries rules
#   6. Tailnet reachability — every ONLINE Tailscale peer answers a tailscale ping
#      (DERP-relayed peers are flagged as throughput-degraded, not a failure)
#   7. Throughput           — host path vs. WARP-only baseline (via the container's
#      SOCKS5 proxy, no exec/install inside the container). Catches "slow AND
#      dropping mid-transfer" that a one-shot ping/latency check can't see.
#      Real per-device (phone) throughput can't be measured without an agent
#      running on the device, so mesh peers get a path/latency flag instead
#      (see check 6).
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
  --help|-h)  sed -n '2,27p' "$0"; exit 0 ;;
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
section "1/7  Containers"
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
section "2/7  Double-tunnel / IP-leak"
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
section "3/7  Host ↔ container path (direct P2P, not DERP relay)"
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
section "4/7  AdGuard filtering"
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
section "5/7  PF kill-switch"
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
section "6/7  Tailnet reachability (ping all online devices)"
# ═══════════════════════════════════════════════════════════════════════════
# Every peer the coordination server reports as ONLINE should answer a
# `tailscale ping` (TSMP probes the WireGuard data path; ICMP is avoided since
# phones/laptops often drop it). Offline peers and this host are skipped.
# An online-but-unreachable peer means control plane and data path disagree.
if ! command -v tailscale >/dev/null 2>&1; then
  fail "tailscale CLI not on PATH"
  record FAIL "tailnet"
else
  SELF_TS_IP=$(run_with_timeout 6 tailscale ip -4 2>>"$LOG_FILE")
  [ -n "${TS_OUT:-}" ] || TS_OUT=$(run_with_timeout 6 tailscale status 2>>"$LOG_FILE")
  # Online peers = rows starting with a Tailscale IP, minus self and 'offline'.
  # (A '-' status column means online-but-idle, so it is kept.)
  PEERS=$(printf '%s\n' "$TS_OUT" | awk -v self="$SELF_TS_IP" \
          '$1 ~ /^100\./ && $1 != self && $0 !~ /(^|[[:space:]])offline(,|;|[[:space:]]|$)/ {print $1, $2}')
  if [ -z "$PEERS" ]; then
    warn "no online peers to ping (everything else in the tailnet is offline)"
    record WARN "tailnet"
  else
    unreached=0
    while read -r peer_ip peer_name; do
      PONG=$(run_with_timeout 10 tailscale ping --timeout=3s --c 1 --until-direct=false "$peer_ip" 2>>"$LOG_FILE")
      if printf '%s' "$PONG" | grep -q '^pong'; then
        detail=$(printf '%s\n' "$PONG" | head -1 | sed -E 's/^pong from [^ ]+ \([^)]+\) //')
        if printf '%s' "$detail" | grep -q 'DERP'; then
          ok "$peer_name ($peer_ip) — pong $detail — relayed, expect degraded throughput (see check 7)"
        else
          ok "$peer_name ($peer_ip) — pong $detail"
        fi
      else
        fail "$peer_name ($peer_ip) — no pong (online per control plane, data path dead)"
        unreached=$((unreached+1))
      fi
    done <<< "$PEERS"
    n_peers=$(printf '%s\n' "$PEERS" | wc -l | tr -d '[:space:]')
    if [ "$unreached" -eq 0 ]; then
      record PASS "tailnet"
    elif [ "$unreached" -lt "$n_peers" ]; then
      record WARN "tailnet"
    else
      record FAIL "tailnet"
    fi
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
section "7/7  Throughput (host path vs. WARP-only baseline)"
# ═══════════════════════════════════════════════════════════════════════════
# A single ping only proves the path is UP, not that it stays up under real
# load — devref.md §15.3.1 documents sustained-transfer bufferbloat/reset
# behavior a quick latency check can't see. Pulls a real test file twice:
# once over the host's normal route (full double-tunnel: Tailscale exit-node
# wrap + WARP) and once straight through the warp container's own SOCKS5
# proxy (WARP only, no Tailscale wrap) — port read from the live
# /tmp/nullexit-ports.env, so this never execs into or installs anything in
# the container (sweep stays read-only w.r.t. gateway state). Comparing the
# two shows whether slowness/resets come from WARP itself or from the extra
# Tailscale-wrap hop. Skip with SWEEP_SKIP_THROUGHPUT=true in .env.
#
# Target: a fast, high-bandwidth CDN, not a slow/distant one. speedtest.net-style
# test hosts (e.g. speedtest.tele2.net) were tried first and turned out to be the
# bottleneck themselves — even RAW, gateway-off ISP speed to tele2.net was ~3.2
# Mbps, vs ~32 Mbps raw to a fast CDN — so a slow test target would have silently
# blamed nullexit for a benchmark artifact. Cloudflare's own speed-test endpoint
# 403s WARP egress IPs specifically (abuse-prevention on shared/CGNAT IPs), so
# Hetzner (also fast, does not flag WARP IPs) is used instead.
THROUGHPUT_SKIP=$(read_env_var "SWEEP_SKIP_THROUGHPUT" | tr '[:upper:]' '[:lower:]')
if [ "$THROUGHPUT_SKIP" = "true" ]; then
  warn "skipped (SWEEP_SKIP_THROUGHPUT=true)"
  record WARN "throughput"
else
  TP_URL="${SWEEP_THROUGHPUT_URL:-https://ash-speed.hetzner.com/100MB.bin}"
  TP_TIMEOUT="${SWEEP_THROUGHPUT_TIMEOUT:-30}"

  measure() {   # $1 = extra curl args (word-split; may be empty)
    # curl's own --max-time must win the race against run_with_timeout's outer
    # SIGTERM watcher — a process killed by signal never reaches its own -w
    # output, so if both timers were equal, the watcher could kill curl right
    # before it prints stats, and every leg would misreport as "no response".
    # The outer timeout is a dead-man's-switch (+5s), not the real budget.
    run_with_timeout $((TP_TIMEOUT + 5)) curl -sS --max-time "$TP_TIMEOUT" $1 -o /dev/null \
      -w 'code=%{http_code} size=%{size_download} time=%{time_total} bps=%{speed_download}' \
      "$TP_URL" 2>>"$LOG_FILE"
  }
  leg_verdict() {   # $1=curl_rc $2=http_code -> ok|stall|blocked|unknown
    [ -z "$2" ] && { echo unknown; return; }
    [ "$2" != "200" ] && { echo blocked; return; }
    case "$1" in
      0|28) echo ok ;;     # 0=completed; 28=hit our own --max-time while still healthy
      56)   echo stall ;;  # curl's actual "Recv failure: Connection reset by peer"
      *)    echo unknown ;;
    esac
  }
  to_mbps() { awk -v b="${1:-}" 'BEGIN{ if (b=="") print "?"; else printf "%.1f", (b*8)/1000000 }'; }

  HOST_TP=$(measure ""); HOST_RC=$?
  HOST_CODE=$(printf '%s' "$HOST_TP" | grep -oE 'code=[0-9]+' | cut -d= -f2)
  HOST_SIZE=$(printf '%s' "$HOST_TP" | grep -oE 'size=[0-9]+' | cut -d= -f2)
  HOST_TIME=$(printf '%s' "$HOST_TP" | grep -oE 'time=[0-9.]+' | cut -d= -f2)
  HOST_BPS=$(printf '%s' "$HOST_TP"  | grep -oE 'bps=[0-9.]+'  | cut -d= -f2)
  HOST_VERDICT=$(leg_verdict "$HOST_RC" "$HOST_CODE")
  HOST_MBPS=$(to_mbps "$HOST_BPS")
  case "$HOST_VERDICT" in
    ok)      ok   "host path: ${HOST_MBPS} Mbps (${HOST_SIZE:-0} bytes in ${HOST_TIME:-?}s)" ;;
    stall)   warn "host path: connection reset mid-transfer after ${HOST_SIZE:-0} bytes — sustained-load drop, see devref.md §15.3.1" ;;
    blocked) warn "host path: test endpoint returned HTTP ${HOST_CODE:-?} (egress IP likely flagged) — inconclusive, not a gateway fault" ;;
    unknown) warn "host path: no response (timeout after ${TP_TIMEOUT}s)" ;;
  esac

  SOCKS_PROXY_PORT=""
  [ -f /tmp/nullexit-ports.env ] && SOCKS_PROXY_PORT=$(grep -oE 'SOCKS_PROXY_PORT=[0-9]+' /tmp/nullexit-ports.env | cut -d= -f2)
  if [ -z "$SOCKS_PROXY_PORT" ]; then
    warn "WARP-only baseline: SOCKS_PROXY_PORT unknown (no /tmp/nullexit-ports.env — gateway not started via toggle.sh?)"
    CTR_VERDICT=unknown
  else
    CTR_TP=$(measure "--socks5-hostname 127.0.0.1:$SOCKS_PROXY_PORT"); CTR_RC=$?
    CTR_CODE=$(printf '%s' "$CTR_TP" | grep -oE 'code=[0-9]+' | cut -d= -f2)
    CTR_SIZE=$(printf '%s' "$CTR_TP" | grep -oE 'size=[0-9]+' | cut -d= -f2)
    CTR_TIME=$(printf '%s' "$CTR_TP" | grep -oE 'time=[0-9.]+' | cut -d= -f2)
    CTR_BPS=$(printf '%s' "$CTR_TP"  | grep -oE 'bps=[0-9.]+'  | cut -d= -f2)
    CTR_VERDICT=$(leg_verdict "$CTR_RC" "$CTR_CODE")
    CTR_MBPS=$(to_mbps "$CTR_BPS")
    case "$CTR_VERDICT" in
      ok)      ok   "WARP-only baseline: ${CTR_MBPS} Mbps (${CTR_SIZE:-0} bytes in ${CTR_TIME:-?}s)" ;;
      stall)   warn "WARP-only baseline: connection reset mid-transfer after ${CTR_SIZE:-0} bytes — bug is in WARP itself, not the Tailscale wrap" ;;
      blocked) warn "WARP-only baseline: test endpoint returned HTTP ${CTR_CODE:-?} — inconclusive" ;;
      unknown) warn "WARP-only baseline: no response (timeout after ${TP_TIMEOUT}s)" ;;
    esac
  fi

  if [ "$HOST_VERDICT" = "ok" ] && [ "$CTR_VERDICT" = "ok" ]; then
    if [ "$HOST_MBPS" != "?" ] && [ "$CTR_MBPS" != "?" ]; then
      DELTA=$(awk -v h="$HOST_MBPS" -v c="$CTR_MBPS" 'BEGIN{ if (c<=0) print 0; else printf "%.0f", 100*(c-h)/c }')
      [ "$DELTA" -ge 30 ] 2>/dev/null && warn "host is ${DELTA}% slower than the WARP-only baseline — the Tailscale exit-node wrap is the added cost here, not WARP"
    fi
    record PASS "throughput"
  elif [ "$HOST_VERDICT" = "stall" ] || [ "$CTR_VERDICT" = "stall" ]; then
    record WARN "throughput"
  elif [ "$HOST_VERDICT" = "unknown" ] && [ "$CTR_VERDICT" = "unknown" ]; then
    record FAIL "throughput"
  else
    record WARN "throughput"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# Cover traffic (opt-in) — informational only, NOT a scored check.
# Shown solely when NOISE_ENABLED=true so the sweep stays read-only and the
# 6-check verdict is unchanged. Reports whether the padding daemon is alive.
NOISE_ON=$(read_env_var "NOISE_ENABLED" | tr '[:upper:]' '[:lower:]')
if [ "$NOISE_ON" = "true" ]; then
  section "Cover traffic (opt-in, informational)"
  NOISE_PID_FILE="/tmp/nullexit-noise.pid"
  npid="$(cat "$NOISE_PID_FILE" 2>/dev/null)"
  if [ -n "$npid" ] && kill -0 "$npid" 2>/dev/null; then
    ok "dummy-padding daemon running (pid $npid) — see 'bash scripts/noise.sh status'"
  else
    warn "NOISE_ENABLED=true but no padding daemon running — start it: bash scripts/noise.sh start"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# DNS anomaly scan (informational, read-only, NOT a scored check — the 6-check
# verdict is unchanged). It only READS the AdGuard querylog; never blocks DNS.
# It FAILS LOUD: a broken detector (crash, corrupt model, empty log, failing
# self-test) shows a red ✗ with the reason — it is NEVER silently reported as
# clean, and an untrained detector is announced rather than skipped in silence.
QUERYLOG="$PROJECT_ROOT/adguard/work/data/querylog.json"
DNS_TOOL="$SCRIPT_DIR/dns_anomaly_detector.py"
if command -v python3 >/dev/null 2>&1 && [ -f "$DNS_TOOL" ]; then
  section "DNS anomaly scan (informational)"
  # 1) Prove the detection logic itself works before trusting any "clean".
  ST_ERR=$(python3 "$DNS_TOOL" selftest 2>&1 >/dev/null); ST_RC=$?
  if [ "$ST_RC" -ne 0 ]; then
    fail "DNS detector SELF-TEST FAILED (rc=$ST_RC) — detector is broken, do NOT trust results: ${ST_ERR:-see stderr}"
  elif [ ! -f "$PROJECT_ROOT/.dns_baseline.json" ]; then
    warn "DNS detector NOT trained (no .dns_baseline.json) — not protecting; run: python3 scripts/dns_anomaly_detector.py learn"
  elif [ ! -f "$QUERYLOG" ]; then
    warn "DNS detector trained but querylog absent ($QUERYLOG) — nothing to scan"
  else
    # 2) Real scan. Capture stderr + exit code; do NOT swallow failures.
    DNS_ERR=$(python3 "$DNS_TOOL" scan --quiet 2>&1 >/tmp/nullexit-dns-scan.out); DNS_RC=$?
    DNS_OUT=$(cat /tmp/nullexit-dns-scan.out 2>/dev/null); rm -f /tmp/nullexit-dns-scan.out
    case "$DNS_RC" in
      0) ok   "no DNS-tunneling / DGA signatures — $DNS_OUT" ;;
      1) warn "$DNS_OUT — review: python3 scripts/dns_anomaly_detector.py scan" ;;
      *) fail "DNS scan FAILED to run (rc=$DNS_RC) — NOT a clean result: ${DNS_ERR:-unknown error}" ;;
    esac
  fi
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
  emit "${GREEN}${BOLD}SWEEP PASS — gateway healthy (${pass}/${#RESULTS[@]} checks green)${NC}"
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
