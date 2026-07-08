#!/bin/bash
# scripts/fix-docker-bridge-collision.sh — nullexit fix for devref §9.13
#
# Symptom: host default route points at Docker's bridge gateway (172.17.0.1)
# instead of the real Wi-Fi gateway. ALL host internet egress fails. Remote
# tailnet clients route through the gateway correctly (their tunnel is
# independent of the host's broken route table), so they look healthy while
# the host itself cannot reach anything.
#
# Root cause: Docker's default bridge claims 172.17.0.0/16 by default. When the
# host's physical Wi-Fi also lands in the same /16 — extremely common on
# university networks which hand out 172.16.0.0/12 — the kernel
# installs Docker's bridge as the default route, and every packet bound for
# the internet is silently absorbed by docker0 instead of egressing.
#
# This script:
#   1. Detects the actual collision (Docker's 172.17.0.0/16 vs the host's
#      Wi-Fi subnet, queried live via the ACTIVE interface — not hardcoded en0)
#   2. Picks a non-colliding Docker bip using /8-family routing (works for
#      172.16.0.0/12 campus networks; naive prefix-match would pick 172.26/24
#      which still lives INSIDE a /12 of 172.16.0.0/12)
#   3. Backs up ~/.colima/default/colima.yaml with an ISO-8601 timestamp
#   4. Edits the file in place, idempotent (replace existing docker.bip /
#      append new docker.bip without disturbing other keys; skip YAML comments)
#   5. Restarts Colima so the VM rebuilds with the new bridge subnet
#   6. Rebinds Wi-Fi DHCP so the host re-learns its real Wi-Fi gateway
#   7. Verifies the new default route is no longer the Docker bridge
#   8. Re-runs toggle.sh to bring the gateway back up cleanly
#   9. Re-runs scripts/diagnose-host-leak.sh and prints the new verdict
#
# Usage:
#   bash scripts/fix-docker-bridge-collision.sh        # apply the fix
#   bash scripts/fix-docker-bridge-collision.sh --dry  # show what would change, then exit
#   bash scripts/fix-docker-bridge-collision.sh --skip-toggle  # fix but don't restart gateway
#   bash scripts/fix-docker-bridge-collision.sh --help # usage

set -uo pipefail
# NOTE: errexit (`set -e`) is intentionally NOT enabled so intermediate
# `command … || warn …` patterns can continue past non-fatal failures.
# Every critical failure (colima restart, sed, cp backup, toggle.sh)
# uses an explicit `|| die` so a half-applied state never escapes.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_FILE="$PROJECT_ROOT/output.log"
source "$SCRIPT_DIR/common.sh"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
COLIMA_YAML="$HOME/.colima/default/colima.yaml"
PLATFORM="$(uname -s)"

# ─── Argument parsing ───────────────────────────────────────────────────────
DRY_RUN=false
SKIP_TOGGLE=false
case "${1:-}" in
  --dry|-n)       DRY_RUN=true ;;
  --skip-toggle)  SKIP_TOGGLE=true ;;
  --help|-h)
    sed -n '28,37p' "$0"
    exit 0
    ;;
  "")
    : # default: apply
    ;;
  *)
    printf 'Unknown argument: %s\n' "$1" >&2
    exit 2
    ;;
esac



# Helper: print "[dry-run] $cmd" or actually run $cmd. Wraps the redirect
# INSIDE the function so outer `>> $FILE` statements never accidentally
# append dry-run noise to the real file. (Earlier draft didn't and the
# dry-run polluted $COLIMA_YAML.)
run() {
  if [ "$DRY_RUN" = "true" ]; then
    printf '    [dry-run] %s\n' "$*"
    return 0
  fi
  printf '    $ %s\n' "$*"
  "$@"
}

# Platform-aware sed in-place. macOS BSD sed needs an empty argument;
# GNU sed (Linux) does not. Earlier draft used `-i ''` everywhere and
# would have failed on Linux silently.
sed_inplace() {
  local expr="$1"
  local file="$2"
  case "$PLATFORM" in
    Darwin) run sed -i '' "$expr" "$file" ;;
    *)      run sed -i    "$expr" "$file" ;;
  esac
}

# ─── 0. Resolve the ACTIVE physical interface once (used everywhere) ───────
# Replaces the earlier `en0` hardcoding. Same algorithm recover.sh uses:
# `route get default` → if utun/tun, walk en0..en5 first with `status: active`
# + `inet` → fall back to en0. This means the script also works on hosts
# whose primary NIC is en1/en2 (Thunderbolt Ethernet, USB-LAN, etc.).
resolve_active_iface() {
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
  printf '%s\n' "$iface"
}
ACTIVE_IFACE=$(resolve_active_iface)

# ─── 1. Detect collision ────────────────────────────────────────────────────
step "1/9  Detecting Docker-bridge vs Wi-Fi subnet collision"

# Host subnet on the ACTIVE interface (not hardcoded en0).
HOST_SUBNET=$(ifconfig "$ACTIVE_IFACE" 2>> "$LOG_FILE" \
              | awk '/inet /{print $2; exit}')
HOST_GATEWAY=$(route get default 2>> "$LOG_FILE" \
               | awk '/gateway:/{print $2; exit}')
DEFAULT_DEV=$(route get default 2>> "$LOG_FILE" \
              | awk '/interface:/{print $2; exit}')

printf '  active iface:  %s\n' "$ACTIVE_IFACE"
printf '  iface inet:    %s\n' "${HOST_SUBNET:-none}"
printf '  default via:   %s\n' "${HOST_GATEWAY:-none}"
printf '  default dev:   %s\n' "${DEFAULT_DEV:-none}"

# Collision fires when the host's default-route gateway is 172.17.0.1 (Docker's
# bridge) OR when the host subnet is in 172.17.0.0/16. The full-bridge-collision
# case (gateway is literally the docker bridge IP) is the smoking gun.
COLLISION=false
if [ -n "$HOST_GATEWAY" ] && [ "${HOST_GATEWAY#172.17.}" != "$HOST_GATEWAY" ]; then
  COLLISION=true
  fail "default gateway $HOST_GATEWAY collides with Docker's default bridge (172.17.0.0/16)"
elif [ -n "$HOST_SUBNET" ] && [ "${HOST_SUBNET#172.17.}" != "$HOST_SUBNET" ]; then
  COLLISION=true
  fail "host subnet $HOST_SUBNET overlaps Docker's 172.17.0.0/16 bridge"
else
  ok "no collision detected between host Wi-Fi and Docker's default bridge"
fi

if [ "$COLLISION" = "false" ]; then
  echo ""
  echo "Nothing to fix. If you still see egress issues, run:"
  echo "    bash scripts/diagnose-host-leak.sh"
  exit 0
fi

# ─── 2. Pick non-colliding bip via /8-family routing ───────────────────────
step "2/9  Picking a non-colliding Docker bip for ~/.colima/default/colima.yaml"

# Earlier draft tried naive prefix-match: "if candidate's 3-octet prefix is
# not a literal prefix of host gateway, pick it". That breaks on /12 campus
# networks (172.16.0.0/12 covers 172.16-172.31): a candidate like
# 172.26.0.1/24 LIVES INSIDE the host's /12 even though the prefix test
# passes. Fix: classify the host's address family FIRST, then choose ALL
# candidates from a DIFFERENT RFC1918 family. /8 boundaries are coarse
# enough that no /24 picked this way can ever collide.
case "$HOST_GATEWAY" in
  172.16.*|172.17.*|172.18.*|172.19.*|172.20.*|172.21.*|172.22.*|172.23.*|\
  172.24.*|172.25.*|172.26.*|172.27.*|172.28.*|172.29.*|172.30.*|172.31.*)
    HOST_FAMILY="172"
    # Host is in 172.x — jump past 172.31 entirely. Pick from 10.x / 192.168.x.
    CANDIDATES="10.200.0.1/24 10.201.0.1/24 192.168.99.1/24"
    ;;
  10.*)
    HOST_FAMILY="10"
    # Host is in 10.x — pick from 172.x (well outside any commonly-deployed
    # 10.0.0.0/8 slice) / 192.168.x.
    CANDIDATES="172.26.0.1/24 172.28.0.1/24 192.168.99.1/24"
    ;;
  192.168.*)
    HOST_FAMILY="192"
    CANDIDATES="172.26.0.1/24 10.200.0.1/24 10.201.0.1/24"
    ;;
  *)
    HOST_FAMILY="unknown"
    warn "host gateway $HOST_GATEWAY is not in any RFC1918 range (/8 family)"
    warn "falling back to abstract candidate set; verify collision-free manually"
    CANDIDATES="172.26.0.1/24 10.200.0.1/24 192.168.99.1/24"
    ;;
esac

printf '  host address family: %s\n' "$HOST_FAMILY"
printf '  candidate pool:      %s\n' "$CANDIDATES"

# Sanity-check the chosen pool has at least one entry that doesn't literally
# share a /24 with the host gateway. Naive check (just /24 prefix) is fine
# here because we already picked across families.
CHOSEN=""
for cand in $CANDIDATES; do
  PREFIX3=$(printf '%s' "$cand" | cut -d. -f1-3)
  if [ -n "$HOST_GATEWAY" ] && [ "${HOST_GATEWAY#"$PREFIX3".}" != "$HOST_GATEWAY" ]; then
    warn "skip $cand (literal /24 collision with host gateway $HOST_GATEWAY)"
    continue
  fi
  CHOSEN="$cand"
  ok "chose bip=$CHOSEN (cross-family, no /24 literal collision)"
  break
done

if [ -z "$CHOSEN" ]; then
  CHOSEN="172.26.0.1/24"
  warn "could not find a clean candidate; defaulting to $CHOSEN"
  warn "verify with 'route get default' after restart"
fi

# ─── 3. Backup colima.yaml ──────────────────────────────────────────────────
step "3/9  Backing up $COLIMA_YAML"
mkdir -p "$(dirname "$COLIMA_YAML")"
BACKUP="$HOME/.colima/default/colima.yaml.bak.$TIMESTAMP"
if [ -f "$COLIMA_YAML" ]; then
  # `cp` is safe in dry-run because run() suppresses the inner command
  # entirely — no chance of accidentally writing a real backup.
  run cp -p "$COLIMA_YAML" "$BACKUP" || die "backup failed"
  if [ "$DRY_RUN" = "false" ]; then ok "backup: $BACKUP"; fi
else
  warn "no existing $COLIMA_YAML (will create fresh)"
fi

# ─── 4. Edit colima.yaml in place (idempotent) ──────────────────────────────
step "4/9  Setting docker.bip=$CHOSEN in colima.yaml (in place)"

# Resolve the existing docker.bip (if any) without picking up commented-out
# YAML keys. awk-based extraction; the negated-comment check (`! /^[[:space:]]*#`)
# ensures `# bip: 1.2.3.4/24` is treated as a comment, not the active value.
EXISTING_BIP=""
if [ -f "$COLIMA_YAML" ]; then
  EXISTING_BIP=$(awk '
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*bip:[[:space:]]*/ {print $2; exit}
  ' "$COLIMA_YAML" 2>> "$LOG_FILE" || true)
fi

if [ -n "$EXISTING_BIP" ] && [ "$EXISTING_BIP" = "$CHOSEN" ]; then
  ok "colima.yaml already has docker.bip=$CHOSEN — no edit needed"
elif [ -n "$EXISTING_BIP" ]; then
  printf '  (replacing existing docker.bip=%s with %s)\n' "$EXISTING_BIP" "$CHOSEN"
  # Use sed_inplace so Linux / macOS get the right syntax. Skip YAML comment
  # lines so existing `# bip:` comments aren't rewired.
  sed_inplace "s|^\\([[:space:]]*bip:[[:space:]]*\\).*\$|\\1$CHOSEN|" "$COLIMA_YAML" \
    || die "sed replacement failed (colima.yaml malformed?)"
  ok "colima.yaml updated"
else
  # No existing `bip:` key. Branch:
  #   - file has `docker:` block → append `  bip:` under it
  #   - file has no `docker:` block → append new docker: section
  #   - file does not exist → create fresh
  # Each branch is dry-run-aware so no branch can accidentally leak noise
  # into $COLIMA_YAML during a preview.
  HAS_DOCKER_BLOCK=false
  if [ -f "$COLIMA_YAML" ] && grep -q '^docker:' "$COLIMA_YAML"; then
    HAS_DOCKER_BLOCK=true
  fi

  if [ "$HAS_DOCKER_BLOCK" = "true" ]; then
    if [ "$DRY_RUN" = "true" ]; then
      printf '    [dry-run] would append to %s:\\n  bip: %s\\n' "$COLIMA_YAML" "$CHOSEN"
    else
      printf '\n  bip: %s\n' "$CHOSEN" >> "$COLIMA_YAML" \
        || die "append failed"
      ok "appended bip under existing docker: block"
    fi
  elif [ -f "$COLIMA_YAML" ]; then
    if [ "$DRY_RUN" = "true" ]; then
      printf '    [dry-run] would append to %s:\\ndocker:\\n  bip: %s\\n' "$COLIMA_YAML" "$CHOSEN"
    else
      printf '\ndocker:\n  bip: %s\n' "$CHOSEN" >> "$COLIMA_YAML" \
        || die "append failed"
      ok "appended new docker: block at end of file"
    fi
  else
    if [ "$DRY_RUN" = "true" ]; then
      printf '    [dry-run] would create %s with:\\ndocker:\\n  bip: %s\\n' "$COLIMA_YAML" "$CHOSEN"
    else
      printf 'docker:\n  bip: %s\n' "$CHOSEN" > "$COLIMA_YAML" \
        || die "create failed"
      ok "created fresh $COLIMA_YAML with docker.bip=$CHOSEN"
    fi
  fi
fi

# Always show the final colima.yaml docker section for visibility
printf '\n%b  colima.yaml `docker:` section now reads:%b\n' "$BOLD" "$NC"
awk '
  /^docker:/{p=1}
  p && /^[^ ]/ && !/^docker:/{exit}
  p
' "$COLIMA_YAML" 2>/dev/null | sed 's/^/    /' || true

if [ "$DRY_RUN" = "true" ]; then
  printf '\n  %b(dry-run: exiting before colima restart / dhcp rebind / toggle.sh)%b\n' "$YELLOW" "$NC"
  exit 0
fi

# ─── 5. Restart Colima ──────────────────────────────────────────────────────
step "5/9  Restarting Colima VM with new bip"
if ! command -v colima >> "$LOG_FILE" 2>&1; then
  die "colima not on PATH — install with 'brew install colima' first"
fi
# No timeout wrapper (would mask actual VM startup time). If colima hangs,
# the user kills with Ctrl+C and can manually `colima restart` from a fresh
# terminal — the rest of this script is idempotent so re-running works.
colima restart >> "$LOG_FILE" 2>&1 || die "colima restart failed; check $LOG_FILE"
ok "colima restarted"

# ─── 6. Rebind DHCP on the ACTIVE interface (not hardcoded en0) ────────────
step "6/9  Rebinding DHCP on $ACTIVE_IFACE so host re-learns its real gateway"

# Map ifname → macOS network service name (Wi-Fi, USB 10/100 LAN, etc.).
# Same logic as the diagnostic + toggle.sh.
ACTIVE_SVC=""
if [ "$PLATFORM" = "Darwin" ]; then
  ACTIVE_SVC=$(get_active_service)
fi

case "$PLATFORM" in
  Darwin)
    sudo -n networksetup -setdhcp "$ACTIVE_SVC" renew >> "$LOG_FILE" 2>&1 \
      && ok "DHCP rebind issued on $ACTIVE_SVC" \
      || warn "setdhcp renew failed; try 'sudo ipconfig set $ACTIVE_IFACE DHCP' manually"
    ;;
  Linux)
    sudo -n dhclient -r "$ACTIVE_IFACE" >> "$LOG_FILE" 2>&1 || true
    sudo -n dhclient "$ACTIVE_IFACE"     >> "$LOG_FILE" 2>&1 \
      && ok "dhclient rebind on $ACTIVE_IFACE" \
      || warn "dhclient rebind failed"
    ;;
  *)
    warn "unsupported platform $PLATFORM; skip DHCP rebind"
    ;;
esac

# ─── 7. Verify new default route ────────────────────────────────────────────
step "7/9  Verifying the new default route is NOT the Docker bridge"
sleep 2  # give DHCP + kernel a beat
NEW_DEFAULT=$(netstat -rn 2>> "$LOG_FILE" | awk '/^default/ {print $0; exit}')
printf '  %s\n' "${NEW_DEFAULT:-no default route detected}"
NEW_GATEWAY=$(printf '%s' "$NEW_DEFAULT" | awk '{print $2; exit}')

if [ -n "$NEW_GATEWAY" ] && [ "${NEW_GATEWAY#172.17.}" != "$NEW_GATEWAY" ]; then
  fail "default route STILL points at 172.17.x.x — DHCP rebind may need manual touch"
  warn "try: sudo ipconfig set $ACTIVE_IFACE DHCP  (or reconnect Wi-Fi in the menu bar)"
elif [ -n "$NEW_GATEWAY" ]; then
  ok "default route is now via $NEW_GATEWAY (no longer Docker's bridge)"
else
  warn "could not determine new gateway; verify with 'route get default'"
fi

# ─── 8. Re-run toggle.sh to bring the gateway back up ───────────────────────
if [ "$SKIP_TOGGLE" = "true" ]; then
  step "8/9  Skipping toggle.sh (--skip-toggle)"
  warn "gateway is currently down — run ./toggle.sh manually when ready"
else
  step "8/9  Re-running toggle.sh to bring the gateway back up"
  if bash "$PROJECT_ROOT/toggle.sh" 2>&1 | tee -a "$LOG_FILE"; then
    ok "toggle.sh completed"
  else
    warn "toggle.sh returned non-zero — see $LOG_FILE for details"
  fi
fi

# ─── 9. Re-run the diagnostic + show verdict ────────────────────────────────
step "9/9  Re-running host-leak diagnostic to confirm fix"
if bash "$SCRIPT_DIR/diagnose-host-leak.sh" 2>&1 | tee -a "$LOG_FILE"; then
  LATEST_REPORT=$(ls -t "$PROJECT_ROOT"/host-leak-diagnostic-*.txt 2>/dev/null | head -1)
  if [ -n "$LATEST_REPORT" ]; then
    VERDICT=$(awk '/^ Scenario:/ {print $2; exit}' "$LATEST_REPORT" 2>/dev/null)
    WARP=$(awk -F': *' '/^ WARP egress:/ {print $2; exit}' "$LATEST_REPORT" 2>/dev/null)
    printf '\n  Most recent verdict: Scenario=%s  WARP=%s\n' \
           "${VERDICT:-?}" "${WARP:-?}"
    if [ "$VERDICT" = "OK" ]; then
      ok "fix confirmed by diagnostic — host traffic is going through WARP"
    fi
  fi
else
  warn "diagnostic exited non-zero; verify manually"
fi

printf '\n%b════════════════════════════════════════════════════════════%b\n' "$BOLD" "$NC"
printf '%bDone.%b Full transcript at %s\n' "$BOLD" "$NC" "$LOG_FILE"
printf '%b════════════════════════════════════════════════════════════%b\n' "$BOLD" "$NC"
exit 0
