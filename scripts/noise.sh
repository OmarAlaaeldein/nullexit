#!/bin/bash
# scripts/noise.sh — nullexit verifiable-random noise + cover-traffic padding
#
# OPT-IN and ACTIVE. Unlike sweep.sh (read-only), this module PUTS TRAFFIC ON
# THE WIRE. It stays completely inert unless NOISE_ENABLED=true in .env, so the
# default posture is unchanged and the sweep's read-only guarantee is intact.
#
# Two jobs, one primitive (CSPRNG bytes from the OS, /dev/urandom via os.urandom):
#
#   1. verify — prove a freshly generated buffer is statistically random using
#      three standard tests (Shannon entropy, NIST monobit, chi-square over the
#      256 byte values). This is the "we can verify it's truly random
#      mathematically" requirement — it is harmless and always allowed.
#
#   2. pad — a cover-traffic daemon. It emits verified-random UDP datagrams
#      toward the exit at a configured rate + jitter so a passive on-path
#      observer (residence / campus / hostile network) sees a continuously
#      varying encrypted flow instead of your real traffic envelope. This is
#      the "dummy padding" defence the Threat Model flags as the countermeasure
#      to metadata / traffic-flow correlation. It ONLY runs with NOISE_ENABLED=true.
#
# HONEST LIMITS: this is constant/random one-way padding, not a full
# traffic-analysis-resistant shaper. It blurs volume + timing on the uplink; it
# does not mimic a specific protocol, pad bidirectionally, or defeat a global
# active adversary. It costs bandwidth and (on battery devices) power — hence
# opt-in, modest default rate. The DNS/IP anomaly detector is deliberately NOT
# here (left for later).
#
# Usage:
#   bash scripts/noise.sh verify [BYTES]   # randomness self-test (default 1 MiB)
#   bash scripts/noise.sh start            # launch the padding daemon (background)
#   bash scripts/noise.sh pad              # run the padding loop in the foreground
#   bash scripts/noise.sh status           # is the daemon running? target + rate
#   bash scripts/noise.sh stop             # stop the daemon
#   bash scripts/noise.sh --help           # this message
#
# Persistence: install launchd/com.nullexit.noise.plist (see README) so padding
# auto-starts at boot/login. It is governed by the SAME NOISE_ENABLED switch — no
# extra knob: the launchd job is a clean no-op whenever NOISE_ENABLED=false.
#
# .env knobs (all optional; sane defaults):
#   NOISE_ENABLED          master on/off switch (default false)
#   NOISE_PAD_TARGET       where to aim padding (default: the gateway Tailscale IP)
#   NOISE_PAD_PORT         UDP port on the target (default 9999; no listener needed)
#   NOISE_PAD_RATE_KBPS    average padding bitrate (default 64)
#   NOISE_PAD_PACKET_BYTES datagram payload size (default 1024)
#   NOISE_PAD_JITTER_MS    +/- timing jitter per packet (default 40)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT" || { echo "[FATAL] cannot cd to $PROJECT_ROOT" >&2; exit 1; }
source "$SCRIPT_DIR/common.sh"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

SELF="$SCRIPT_DIR/noise.sh"
NOISE_PID="/tmp/nullexit-noise.pid"
NOISE_LOG="$PROJECT_ROOT/output.log"

# ─── .env-driven config ─────────────────────────────────────────────────────
NOISE_ENABLED=$(read_env_var "NOISE_ENABLED" | tr '[:upper:]' '[:lower:]')
[ -z "$NOISE_ENABLED" ] && NOISE_ENABLED="false"

PAD_TARGET=$(read_env_var "NOISE_PAD_TARGET")
[ -z "$PAD_TARGET" ] && PAD_TARGET="$(read_adguard_ip)"        # gateway Tailscale IP
PAD_PORT=$(read_env_var "NOISE_PAD_PORT");         [ -z "$PAD_PORT" ]  && PAD_PORT=9999
PAD_RATE=$(read_env_var "NOISE_PAD_RATE_KBPS");    [ -z "$PAD_RATE" ]  && PAD_RATE=64
PAD_BYTES=$(read_env_var "NOISE_PAD_PACKET_BYTES");[ -z "$PAD_BYTES" ] && PAD_BYTES=1024
PAD_JITTER=$(read_env_var "NOISE_PAD_JITTER_MS");  [ -z "$PAD_JITTER" ] && PAD_JITTER=40

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [noise] $*" >> "$NOISE_LOG" 2>/dev/null || true; }

require_enabled() {
  if [ "$NOISE_ENABLED" != "true" ]; then
    echo "noise: disabled (NOISE_ENABLED != true in .env) — refusing to emit traffic." >&2
    echo "       Set NOISE_ENABLED=true to arm cover-traffic padding." >&2
    exit 3
  fi
}

# ─── Randomness self-test (stdlib python3; no third-party deps) ──────────────
# Exits 0 (PASS) / 1 (FAIL). Prints a human summary unless $2 == "quiet".
verify_random() {
  local nbytes="${1:-1048576}" mode="${2:-loud}"
  python3 - "$nbytes" "$mode" <<'PY'
import os, sys, math
from collections import Counter

n    = int(sys.argv[1])
mode = sys.argv[2] if len(sys.argv) > 2 else "loud"
buf  = os.urandom(n)
bits = n * 8

# 1) Shannon entropy over byte values (bits/byte, ideal = 8.0)
c = Counter(buf)
H = -sum((v / n) * math.log2(v / n) for v in c.values())

# 2) NIST monobit: 1-bit count should be ~half. z = (ones - bits/2)/sqrt(bits/4)
ones = sum(bin(b).count("1") for b in buf)
z    = (ones - bits / 2) / math.sqrt(bits / 4)

# 3) Chi-square over the 256 byte values (df = 255, mean 255, sd ~22.6)
exp  = n / 256.0
chi2 = sum((c.get(i, 0) - exp) ** 2 / exp for i in range(256))

# PASS windows chosen wide enough that true CSPRNG output passes ~always,
# yet a broken/patterned source (constant, low-entropy, biased) fails hard.
H_OK    = H >= 7.99 if n >= 1 << 16 else H >= 7.5
Z_OK    = abs(z) < 5.0
CHI_OK  = 185.0 < chi2 < 345.0
ok = H_OK and Z_OK and CHI_OK

if mode != "quiet":
    print(f"    sample        : {n} bytes ({bits} bits) from os.urandom (/dev/urandom CSPRNG)")
    print(f"    shannon H     : {H:.5f} bits/byte  (ideal 8.0)            [{'ok' if H_OK else 'FAIL'}]")
    print(f"    monobit z     : {z:+.3f}  (|z|<5, bias {ones/bits*100:.3f}% ones) [{'ok' if Z_OK else 'FAIL'}]")
    print(f"    chi-square    : {chi2:.1f}  (df=255, expect ~255, window 185-345) [{'ok' if CHI_OK else 'FAIL'}]")
    print(f"    verdict       : {'PASS — statistically random' if ok else 'FAIL — not random enough'}")
sys.exit(0 if ok else 1)
PY
}

# ─── The cover-traffic loop (foreground; `start` backgrounds this) ──────────
pad_loop() {
  require_enabled
  # Own the PID file for BOTH run modes (manual `start` and launchd `__boot`), so
  # `status`/`stop` behave identically however padding was launched. Cleared on exit.
  echo $$ > "$NOISE_PID"
  trap 'rm -f "$NOISE_PID"' EXIT INT TERM
  # Gate: only ever emit noise we have just proven is statistically random.
  if ! verify_random 1048576 quiet; then
    echo "noise: randomness self-test FAILED — refusing to emit non-random padding." >&2
    log "pad aborted: randomness self-test failed"
    exit 1
  fi
  log "pad start → ${PAD_TARGET}:${PAD_PORT} rate=${PAD_RATE}kbps pkt=${PAD_BYTES}B jitter=${PAD_JITTER}ms"
  python3 - "$PAD_TARGET" "$PAD_PORT" "$PAD_RATE" "$PAD_BYTES" "$PAD_JITTER" <<'PY'
import os, sys, socket, time, random

target = sys.argv[1]
port   = int(sys.argv[2])
rate   = float(sys.argv[3]) * 1000.0 / 8.0   # kbps → bytes/sec
pkt    = int(sys.argv[4])
jitter = float(sys.argv[5]) / 1000.0         # ms → sec

pps      = max(0.1, rate / pkt)              # packets per second for the target rate
interval = 1.0 / pps
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    while True:
        try:
            s.sendto(os.urandom(pkt), (target, port))   # fresh CSPRNG bytes per packet
        except OSError:
            pass  # target unreachable / dropped is fine — the bytes still left the NIC
        time.sleep(max(0.0, interval + random.uniform(-jitter, jitter)))
except KeyboardInterrupt:
    pass
PY
}

daemon_running() {
  [ -f "$NOISE_PID" ] || return 1
  local pid; pid="$(cat "$NOISE_PID" 2>/dev/null)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

cmd_start() {
  require_enabled
  if daemon_running; then
    echo "noise: padding daemon already running (pid $(cat "$NOISE_PID"))."
    exit 0
  fi
  echo "noise: verifying randomness before arming padding…"
  verify_random 1048576 loud || { echo "noise: aborting — self-test failed." >&2; exit 1; }
  nohup "$SELF" pad >>"$NOISE_LOG" 2>&1 &
  local npid=$!
  sleep 0.3   # let pad_loop write its PID file so `status` is immediately accurate
  echo "noise: padding daemon armed (pid $npid) → ${PAD_TARGET}:${PAD_PORT}, ${PAD_RATE} kbps."
}

cmd_stop() {
  if daemon_running; then
    local pid; pid="$(cat "$NOISE_PID")"
    kill "$pid" 2>/dev/null && echo "noise: stopped padding daemon (pid $pid)."
    log "pad stop (pid $pid)"
  else
    echo "noise: no padding daemon running."
  fi
  rm -f "$NOISE_PID"
}

cmd_status() {
  echo "NOISE_ENABLED = $NOISE_ENABLED"
  if daemon_running; then
    echo "padding       : RUNNING (pid $(cat "$NOISE_PID"))"
    echo "target        : ${PAD_TARGET}:${PAD_PORT}"
    echo "rate / packet : ${PAD_RATE} kbps / ${PAD_BYTES} B, +/-${PAD_JITTER} ms jitter"
  else
    echo "padding       : stopped"
  fi
}

# launchd entry point (see launchd/com.nullexit.noise.plist). Governed by the
# SAME NOISE_ENABLED switch — NOT a new option. When disabled it exits 0 cleanly
# so KeepAlive never tight-loops; when enabled it runs the padding loop in the
# foreground so launchd supervises it directly. This is why persistence adds no
# extra knob: loading the plist once means "auto-start whenever NOISE_ENABLED=true".
cmd_boot() {
  if [ "$NOISE_ENABLED" != "true" ]; then
    log "boot: NOISE_ENABLED != true — idle (padding not started)"
    exit 0
  fi
  log "boot: NOISE_ENABLED=true — starting padding loop under launchd"
  pad_loop
}

case "${1:-}" in
  verify)      verify_random "${2:-1048576}" loud ;;
  start)       cmd_start ;;
  pad)         pad_loop ;;
  __boot)      cmd_boot ;;
  stop)        cmd_stop ;;
  status)      cmd_status ;;
  --help|-h|"") sed -n '2,50p' "$0" ;;
  *) echo "Unknown argument: $1 (try --help)" >&2; exit 2 ;;
esac
