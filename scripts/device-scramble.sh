#!/bin/bash
# scripts/device-scramble.sh — present a random, anonymous DEVICE identity on Wi-Fi.
#
# Randomizes the identifiers a network/observer uses to fingerprint your device:
#   • hostname   — ComputerName / LocalHostName / HostName (the DHCP hostname +
#                  the mDNS/Bonjour ".local" name broadcast on the LAN)
#   • MAC (opt)  — the layer-2 device address
#
# WHERE IT HELPS: open / no-auth Wi-Fi (café, hotel, airport) where these IDs are
# the ONLY handle on you, and against co-located sniffers on any network. It does
# NOT hide you from a network you 802.1X-authenticate to — that login ties every
# session to your account regardless of MAC (see the FaceTime/threat-model notes).
#
# SAFETY: `scramble` saves your real identity first; `restore` puts it back.
# `test-mac` is FAIL-SAFE — it always restores your original MAC at the end, and
# detects Apple-Silicon spoof-blocking and MAC-gated networks without stranding you.
#
# Usage (privileged actions need sudo):
#   bash scripts/device-scramble.sh status            # show current + saved identity (no sudo)
#   sudo bash scripts/device-scramble.sh scramble     # random hostname now (add --mac to also rotate MAC)
#   sudo bash scripts/device-scramble.sh restore       # put your real identity back
#   sudo bash scripts/device-scramble.sh test-mac      # can this network take a random MAC? (auto-reverts)
#   bash scripts/device-scramble.sh --dry-run          # print the random values it would use (no sudo, no change)

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT" || exit 1
IFACE=en0
SAVE="$PROJECT_ROOT/.device-identity.orig"   # gitignored

rand_mac() {  # locally-administered (0x02) + unicast (clear 0x01) first octet
  printf '%02x:%02x:%02x:%02x:%02x:%02x' \
    $(( (RANDOM & 0xFC) | 0x02 )) $((RANDOM&255)) $((RANDOM&255)) $((RANDOM&255)) $((RANDOM&255)) $((RANDOM&255))
}
rand_host() { printf 'MacBook-%04X' $((RANDOM & 0xFFFF)); }   # Apple-ish, blends in

cur_mac()  { ifconfig "$IFACE" ether 2>/dev/null | awk '/ether/{print $2}'; }
cur_ip()   { ipconfig getifaddr "$IFACE" 2>/dev/null; }
need_root(){ [ "$(id -u)" = 0 ] || { echo "device-scramble: this needs root — run with: sudo bash $0 $*" >&2; exit 1; }; }

cmd_status() {
  echo "current:"
  echo "  ComputerName  : $(scutil --get ComputerName 2>/dev/null)"
  echo "  LocalHostName : $(scutil --get LocalHostName 2>/dev/null)"
  echo "  HostName      : $(scutil --get HostName 2>/dev/null || echo '(unset)')"
  echo "  MAC ($IFACE)    : $(cur_mac)   IP: $(cur_ip)"
  if [ -f "$SAVE" ]; then echo; echo "saved original (restore target):"; sed 's/^/  /' "$SAVE"; fi
}

cmd_dry_run() {
  echo "dry-run — would set (no changes made, no sudo needed):"
  echo "  hostname → $(rand_host)"
  echo "  MAC      → $(rand_mac)   (locally-administered, unicast)"
}

save_original() {
  [ -f "$SAVE" ] && return 0   # don't overwrite a real original with an already-scrambled one
  {
    echo "ComputerName=$(scutil --get ComputerName 2>/dev/null)"
    echo "LocalHostName=$(scutil --get LocalHostName 2>/dev/null)"
    echo "HostName=$(scutil --get HostName 2>/dev/null)"
    echo "MAC=$(cur_mac)"
  } > "$SAVE"
}

cmd_scramble() {
  need_root scramble
  save_original
  local h; h=$(rand_host)
  echo "device-scramble: hostname → $h"
  scutil --set ComputerName  "$h"
  scutil --set LocalHostName  "$h"
  scutil --set HostName       "$h"
  dscacheutil -flushcache 2>/dev/null || true
  if [ "${1:-}" = "--mac" ]; then
    local m; m=$(rand_mac)
    echo "device-scramble: MAC → $m (disassociate → set → reconnect)"
    networksetup -setairportpower "$IFACE" off; sleep 3   # can't set MAC while associated
    ifconfig "$IFACE" ether "$m" 2>/dev/null
    [ "$(cur_mac)" = "$m" ] || echo "  [!] MAC did not change — this driver refuses ifconfig spoofing on this hardware"
    networksetup -setairportpower "$IFACE" on
  fi
  echo "done. Restore your real identity with: sudo bash $0 restore"
}

cmd_restore() {
  need_root restore
  [ -f "$SAVE" ] || { echo "device-scramble: no saved identity at $SAVE — nothing to restore."; exit 1; }
  local cn lh hn mac
  cn=$(sed -n 's/^ComputerName=//p'  "$SAVE"); lh=$(sed -n 's/^LocalHostName=//p' "$SAVE")
  hn=$(sed -n 's/^HostName=//p' "$SAVE");      mac=$(sed -n 's/^MAC=//p' "$SAVE")
  [ -n "$cn" ] && scutil --set ComputerName  "$cn"
  [ -n "$lh" ] && scutil --set LocalHostName  "$lh"
  [ -n "$hn" ] && scutil --set HostName       "$hn"
  if [ -n "$mac" ] && [ "$(cur_mac)" != "$mac" ]; then
    networksetup -setairportpower "$IFACE" off; sleep 3   # disassociate before setting MAC
    ifconfig "$IFACE" ether "$mac" 2>/dev/null
    networksetup -setairportpower "$IFACE" on
  fi
  rm -f "$SAVE"
  echo "restored: ComputerName=$cn  MAC=$(cur_mac)"
}

# The safe experiment: does THIS network accept a random MAC? Always reverts.
# CRITICAL: macOS refuses to change the MAC while the interface is ASSOCIATED to
# an SSID, so we disassociate (Wi-Fi radio off) BEFORE setting it, then reconnect.
# (This is the fix for the naive first attempt that set it while connected.)
cmd_test_mac() {
  need_root test-mac
  local orig; orig=$(cur_mac)
  [ -n "$orig" ] || { echo "no $IFACE MAC found"; exit 1; }
  echo "$orig" > /tmp/nullexit-mac.orig
  local rnd; rnd=$(rand_mac)
  echo "original MAC: $orig  →  trying random: $rnd"
  echo "step 1: disassociate (Wi-Fi off) — you can't set the MAC while connected…"
  networksetup -setairportpower "$IFACE" off; sleep 3
  echo "step 2: set MAC while disassociated…"
  ifconfig "$IFACE" ether "$rnd" 2>/dev/null
  local after; after=$(cur_mac)
  if [ "$after" != "$rnd" ]; then
    echo "RESULT: MAC still $after even when disassociated — this driver refuses ifconfig spoofing on neo."
    echo "        (Only Apple's native 'Private Wi-Fi Address' or a USB Wi-Fi adapter would work.)"
    networksetup -setairportpower "$IFACE" on; exit 0
  fi
  echo "  → MAC CHANGED to $after with disassociate-first. Reconnecting to test the network…"
  networksetup -setairportpower "$IFACE" on
  local ip=""; for _ in $(seq 1 15); do sleep 2; ip=$(cur_ip); [ -n "$ip" ] && break; done
  if [ -n "$ip" ]; then
    echo "RESULT: ✅ SUCCESS — random MAC works AND got IP $ip. neo can spoof + this network accepts it."
  else
    echo "RESULT: ⚠️  MAC spoof works, but no IP in ~30s — this network gates on your registered MAC (or 802.1X re-auth needed)."
  fi
  echo "restoring original MAC $orig …"
  networksetup -setairportpower "$IFACE" off; sleep 3
  ifconfig "$IFACE" ether "$orig" 2>/dev/null
  networksetup -setairportpower "$IFACE" on
  ip=""; for _ in $(seq 1 15); do sleep 2; ip=$(cur_ip); [ -n "$ip" ] && break; done
  echo "restored: MAC=$(cur_mac)  IP=${ip:-<reconnecting>}"
}

case "${1:-status}" in
  status)    cmd_status ;;
  --dry-run) cmd_dry_run ;;
  scramble)  cmd_scramble "${2:-}" ;;
  restore)   cmd_restore ;;
  test-mac)  cmd_test_mac ;;
  --help|-h) sed -n '2,26p' "$0" ;;
  *) echo "Unknown: $1 (status|scramble [--mac]|restore|test-mac|--dry-run)" >&2; exit 2 ;;
esac
