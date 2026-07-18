#!/bin/bash
# scripts/pihole-mode.sh — LAN Pi-hole mode (opt-in)
#
# nullexit is already a Pi-hole for MESH devices: AdGuard Home sinkholes DNS for
# everything that routes through the gateway over Tailscale. This mode extends
# that to NON-Tailscale devices on the same LAN — a smart TV, a guest laptop, an
# IoT gadget — the classic "point your DNS at this box" Pi-hole. It binds a DNS
# forwarder on the LAN interface that relays to AdGuard, so any device that sets
# its DNS server to this Mac's LAN IP gets the same ad/tracker/threat filtering.
#
# Mechanism: reuse the tested dns-proxy.py, but LISTEN_ADDR = the LAN IP instead
# of loopback, forwarding to AdGuard at 127.0.0.1:${DNS_PROXY_PORT} (the Docker
# port mapping). No kill-switch changes are needed — pf.conf has no inbound-53
# block, and DNS responses to RFC1918 LAN clients are already permitted.
#
# ⚠️ NETWORK REALITY: on an AP-isolated network (WPA2-Enterprise / hotel), other
# devices CANNOT reach this Mac at all — the same isolation that forces phones
# onto DERP. This mode only does anything useful on a TRUSTED, non-isolated
# network (home / your own AP). It is report-clear here but won't serve remote
# clients until you're on such a network. It also filters DNS only — it does NOT
# route those devices' traffic through WARP.
#
# Usage:
#   bash scripts/pihole-mode.sh enable    # start the LAN DNS forwarder (needs PIHOLE_LAN_MODE=true)
#   bash scripts/pihole-mode.sh disable   # stop it
#   bash scripts/pihole-mode.sh status    # running? listen addr, AdGuard reachability
#   bash scripts/pihole-mode.sh test      # prove it resolves AND sinkholes, locally
#
# .env:
#   PIHOLE_LAN_MODE     master on/off (default false)
#   PIHOLE_LAN_LISTEN   LAN address to bind (blank = this Mac's en0 IP)
#   DNS_PROXY_PORT      AdGuard's host-published DNS port (default 5354)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT" || { echo "[FATAL] cannot cd to $PROJECT_ROOT" >&2; exit 1; }
source "$SCRIPT_DIR/common.sh"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

DNS_PROXY="$SCRIPT_DIR/dns-proxy.py"
PID_FILE="/tmp/nullexit-pihole.pid"
LOG_FILE="$PROJECT_ROOT/output.log"

PIHOLE_ON=$(read_env_var "PIHOLE_LAN_MODE" | tr '[:upper:]' '[:lower:]'); [ -z "$PIHOLE_ON" ] && PIHOLE_ON="false"

# AdGuard's DNS host port is PROCEDURAL (randomized per boot — see Procedural
# Ports), so discover it; never assume 5354. Docker is the source of truth, then
# the ports file toggle.sh writes, then the compose default.
resolve_adguard_port() {
  local p
  p=$(docker compose port warp 5335 2>/dev/null | grep -oE '[0-9]+$' | head -1)
  [ -n "$p" ] && { echo "$p"; return; }
  p=$(grep -oE 'DNS_PROXY_PORT=[0-9]+' /tmp/nullexit-ports.env 2>/dev/null | grep -oE '[0-9]+$' | head -1)
  [ -n "$p" ] && { echo "$p"; return; }
  echo 5354
}
ADGUARD_PORT=$(resolve_adguard_port)

lan_ip() {
  local a; a=$(read_env_var "PIHOLE_LAN_LISTEN")
  [ -n "$a" ] && { echo "$a"; return; }
  ipconfig getifaddr en0 2>/dev/null || echo ""
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [pihole-lan] $*" >> "$LOG_FILE" 2>/dev/null || true; }

running() {
  [ -f "$PID_FILE" ] || return 1
  local p; p=$(cat "$PID_FILE" 2>/dev/null)
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

adguard_reachable() {
  # Probe over TCP: Colima user-mode net forwards UDP-to-container unreliably (the
  # very reason dns-proxy.py relays over TCP), so a UDP probe false-negatives even
  # when AdGuard is healthy. TCP is exactly the path the forwarder uses.
  dig +tcp +short +tries=1 +time=2 -p "$ADGUARD_PORT" @127.0.0.1 example.com >/dev/null 2>&1
}

cmd_enable() {
  if [ "$PIHOLE_ON" != "true" ]; then
    echo "pihole-lan: disabled (PIHOLE_LAN_MODE != true in .env) — refusing to serve LAN DNS." >&2
    exit 3
  fi
  if running; then echo "pihole-lan: already running (pid $(cat "$PID_FILE"))."; exit 0; fi
  local addr; addr=$(lan_ip)
  if [ -z "$addr" ]; then echo "pihole-lan: could not determine a LAN IP (en0 down?)." >&2; exit 1; fi
  if ! adguard_reachable; then
    echo "pihole-lan: AdGuard not reachable at 127.0.0.1:$ADGUARD_PORT — is the gateway up?" >&2
    exit 1
  fi
  echo "pihole-lan: starting LAN DNS forwarder on ${addr}:53 → AdGuard 127.0.0.1:${ADGUARD_PORT}…"
  # :53 needs root. Capture the child PID from inside the privileged shell.
  sudo -n bash -c "LISTEN_ADDR='$addr' LISTEN_PORT=53 TARGET_HOST=127.0.0.1 TARGET_PORT='$ADGUARD_PORT' \
      nohup '$(command -v python3)' '$DNS_PROXY' >>'$LOG_FILE' 2>&1 & echo \$! > '$PID_FILE'" || {
    echo "pihole-lan: failed to start (need passwordless sudo to bind :53)." >&2; exit 1; }
  sleep 0.4
  if running; then
    log "enabled on ${addr}:53 → 127.0.0.1:${ADGUARD_PORT}"
    echo "pihole-lan: running (pid $(cat "$PID_FILE")). Point a LAN device's DNS at ${addr} to filter it."
  else
    echo "pihole-lan: listener did not stay up — check $LOG_FILE (port 53 already bound?)." >&2; exit 1
  fi
}

cmd_disable() {
  if running; then
    local p; p=$(cat "$PID_FILE")
    sudo -n kill "$p" 2>/dev/null || kill "$p" 2>/dev/null
    log "disabled (pid $p)"; echo "pihole-lan: stopped (pid $p)."
  else
    echo "pihole-lan: not running."
  fi
  sudo -n rm -f "$PID_FILE" 2>/dev/null || rm -f "$PID_FILE" 2>/dev/null || true
}

cmd_status() {
  echo "PIHOLE_LAN_MODE = $PIHOLE_ON"
  echo "AdGuard (127.0.0.1:$ADGUARD_PORT): $(adguard_reachable && echo reachable || echo UNREACHABLE)"
  if running; then
    echo "forwarder      : RUNNING (pid $(cat "$PID_FILE")) on $(lan_ip):53"
  else
    echo "forwarder      : stopped"
  fi
}

cmd_test() {
  local addr; addr=$(lan_ip)
  if ! running; then echo "pihole-lan: not running — 'enable' first." >&2; exit 1; fi
  echo "Testing LAN Pi-hole at ${addr}:53 (querying locally)…"
  local good bad
  good=$(dig +short +tries=1 +time=3 @"$addr" example.com 2>/dev/null | head -1)
  bad=$(dig +short +tries=1 +time=3 @"$addr" doubleclick.net 2>/dev/null | head -1)
  echo "  resolve example.com     → ${good:-<none>}"
  echo "  filter  doubleclick.net → ${bad:-<blocked/empty>}"
  if [ -n "$good" ] && { [ -z "$bad" ] || [ "$bad" = "0.0.0.0" ]; }; then
    echo "  RESULT: PASS — resolves clean domains and sinkholes blocked ones."
  else
    echo "  RESULT: check — clean resolve=${good:+yes}, sinkhole=${bad:-empty}. (If both empty, AdGuard/gateway may be down.)"
  fi
}

case "${1:-}" in
  enable)  cmd_enable ;;
  disable) cmd_disable ;;
  status)  cmd_status ;;
  test)    cmd_test ;;
  --help|-h|"") sed -n '2,40p' "$0" ;;
  *) echo "Unknown argument: $1 (try --help)" >&2; exit 2 ;;
esac
