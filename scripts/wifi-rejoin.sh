#!/usr/bin/env bash
# nullexit — Wi-Fi keepalive. Re-associates ONLY to networks you've remembered,
# never any other (no public-AP hopping). No Location permission, no root plist
# reads, no reading the current SSID.
#
# Why "remembered" and not "current": macOS hides the live SSID from every
# script unless the process holds Location Services access, so nothing can
# auto-detect which network you're on. Joining a network *by name* is not
# gated, so you remember your network(s) once and we rejoin the first
# remembered one that's in range.
#
#   set <SSID>      remember a network (safe to run repeatedly)
#   forget <SSID>   stop remembering it
#   list            show remembered networks
#   reset           (internal) clear the drop-timer once the link is back
#   rejoin          (internal, called by the WARP watcher) re-associate a
#                   remembered network after a grace period, with backoff
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
STATE="$ROOT/.last_wifi_ssid"          # remembered SSIDs, one per line (gitignored)
LOG="$ROOT/output.log"
DOWN_MARK="/tmp/nullexit-wifi-downsince"
JOIN_MARK="/tmp/nullexit-wifi-lastjoin"
TRY_MARK="/tmp/nullexit-wifi-tries"
GAVEUP_MARK="/tmp/nullexit-wifi-gaveup"

GRACE=15        # let DHCP self-heal before the first rejoin attempt
BACKOFF=30      # base seconds between rejoin attempts (grows per attempt)
MAX_TRIES=6     # stop re-associating after this many tries per down-episode

ts()  { date -u +%FT%TZ; }
log() { echo "[$(ts)] wifi-rejoin: $*" >> "$LOG"; }

wifi_iface() {
  local i
  i=$(networksetup -listallhardwareports 2>/dev/null \
      | awk '/Hardware Port: Wi-Fi/{getline; print $2; exit}')
  [ -z "$i" ] && i=en0
  printf '%s' "$i"
}

case "${1:-}" in
  set)
    ssid="${2:-}"; [ -z "$ssid" ] && { echo "usage: ${0##*/} set <SSID>" >&2; exit 2; }
    touch "$STATE"
    if grep -qxF "$ssid" "$STATE" 2>/dev/null; then
      echo "already remembered: $ssid"
    else
      printf '%s\n' "$ssid" >> "$STATE"
      echo "remembered: $ssid"
    fi
    ;;

  forget)
    ssid="${2:-}"; [ -z "$ssid" ] && { echo "usage: ${0##*/} forget <SSID>" >&2; exit 2; }
    if [ -f "$STATE" ] && grep -qxF "$ssid" "$STATE"; then
      grep -vxF "$ssid" "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
      echo "forgotten: $ssid"
    else
      echo "not remembered: $ssid"
    fi
    ;;

  list)
    if [ -s "$STATE" ]; then cat "$STATE"; else echo "(none — run: ${0##*/} set <SSID>)"; fi
    ;;

  reset)
    rm -f "$DOWN_MARK" "$JOIN_MARK" "$TRY_MARK" "$GAVEUP_MARK" 2>/dev/null || true
    ;;

  rejoin)
    [ -s "$STATE" ] || exit 0                    # nothing remembered → do nothing
    now=$(date +%s)

    # Grace: remember when the uplink first dropped and hold off, so a DHCP-only
    # blip on the same AP recovers on its own before we force anything.
    if [ ! -f "$DOWN_MARK" ]; then echo "$now" > "$DOWN_MARK"; echo 0 > "$TRY_MARK"; exit 0; fi
    downsince=$(cat "$DOWN_MARK" 2>/dev/null || echo "$now")
    [ $(( now - downsince )) -lt "$GRACE" ] && exit 0

    # Attempt cap: if re-associating hasn't restored the uplink after MAX_TRIES,
    # STOP. Churning a network that won't come up (captive portal, DHCP blocked,
    # out of range) only makes things worse — which is exactly what happened
    # once recovery was aborting. Resets when the link returns (see 'reset').
    tries=$(cat "$TRY_MARK" 2>/dev/null || echo 0)
    if [ "$tries" -ge "$MAX_TRIES" ]; then
      [ -f "$GAVEUP_MARK" ] || { log "gave up after $tries attempts — reconnect Wi-Fi manually"; : > "$GAVEUP_MARK"; }
      exit 0
    fi

    # Progressive backoff between attempts: 30s, 60s, 120s, 240s, then cap 300s —
    # give DHCP time to actually settle instead of hammering every 30s.
    backoff=$(( BACKOFF * (2 ** (tries < 4 ? tries : 4)) )); [ "$backoff" -gt 300 ] && backoff=300
    if [ -f "$JOIN_MARK" ]; then
      last=$(cat "$JOIN_MARK" 2>/dev/null || echo 0)
      [ $(( now - last )) -lt "$backoff" ] && exit 0
    fi
    echo "$now" > "$JOIN_MARK"
    echo $(( tries + 1 )) > "$TRY_MARK"

    iface=$(wifi_iface)
    if ! networksetup -getairportpower "$iface" 2>/dev/null | grep -q ': On'; then
      sudo -n /usr/sbin/networksetup -setairportpower "$iface" on >/dev/null 2>&1 || true
      sleep 2
    fi

    log "uplink down — rejoin attempt $((tries + 1))/$MAX_TRIES, remembered network(s) only (iface $iface)"
    while IFS= read -r ssid; do
      [ -z "$ssid" ] && continue
      # -setairportnetwork joins by name using macOS's saved credentials; it
      # only ever targets a network you explicitly remembered. Exit 0 just means
      # the request was accepted — DHCP/uplink recovery is confirmed separately
      # when the watcher sees the interface get an IP and logs RESUMED.
      if sudo -n /usr/sbin/networksetup -setairportnetwork "$iface" "$ssid" >/dev/null 2>&1; then
        log "sent re-associate request for a remembered network (waiting for DHCP)"
        exit 0
      fi
    done < "$STATE"
    log "no remembered network in range (or credentials needed)"
    ;;

  *)
    echo "usage: ${0##*/} {set <SSID>|forget <SSID>|list|rejoin}" >&2
    exit 2
    ;;
esac
