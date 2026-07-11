#!/usr/bin/env bash
#
# scripts/reinstall-host-tailscale.sh
#
# Complete uninstall + reinstall of the host-side Homebrew Tailscale.
#
# Use this when the brew LaunchAgent is wedged, Login Items entries are
# duplicated, "Tailscale is stopped" persists despite
# `brew services restart tailscale`, or you simply want a clean baseline
# before re-engaging the gateway as exit node.
#
# Idempotent. Safe to re-run. Use --dry to preview every step with zero
# changes. Use --yes to skip the per-step confirmation prompts.
#
# This script ONLY touches the HOST-side Tailscale (the one installed by
# Homebrew `brew install tailscale` and managed by launchd as
# homebrew.mxcl.tailscale). The nullexit gateway container's tailscaled
# (which lives inside the Colima VM at 100.100.21.8 and offers the exit
# node to this host) is unaffected.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY=0
YES=0

for arg in "$@"; do
  case "$arg" in
    --dry)  DRY=1 ;;
    --yes)  YES=1 ;;
    --help|-h)      # NOTE: heredoc is UNQUOTED so $SCRIPT_DIR expands in the body.  If you
      # add new $-style placeholders here, they'll expand the same way.
      cat <<USAGE
Usage: bash "$SCRIPT_DIR/reinstall-host-tailscale.sh" [--dry] [--yes] 

  --dry  Print every step, make zero changes. Use to audit before
         committing.
  --yes  Auto-confirm the prompts at every destructive step. Useful in
         CI / fully-scripted recovery; do not use until you've read
         the script.

After this script completes cleanly, you still must (MANUALLY):

  1. Open System Settings → Privacy & Security → Local Network and
     enable Tailscale. macOS will prompt automatically the first time
     the fresh install of `tailscale` is invoked.

  2. Re-engage the tailnet + exit node:
         sudo tailscale up --ssh=true --accept-dns=false \
           --exit-node="$(cat .gateway_ip | tr -d '\r' | awk 'NR==1{print $1; exit}')" \
           --exit-node-allow-lan-access=true

  3. Re-run ./toggle.sh from the project root.

  4. Final verification:
         curl -s https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(warp|ip|colo)='
     expected: warp=on, ip=<Cloudflare>, colo=YYZ/YUL
USAGE
      exit 0
      ;;
    *)
      echo "Unknown flag: $arg" >&2
      exit 2
      ;;
  esac
done

# ---------- helpers ----------

confirm() {
  if [ "$YES" = 1 ] || [ "$DRY" = 1 ]; then
    return 0
  fi
  printf "    ⚠  %s  [y/N] " "$1"
  read -r ans
  case "$ans" in
    y|Y|yes|YES) return 0 ;;
    *)
      echo "    → aborted by user"
      exit 1
      ;;
  esac
}

header() {
  printf '\n▸ %s\n' "$1"
}

# with_timeout <seconds> <cmd...>
# Run a command in the background and kill it if it exceeds <seconds>.
# Returns the command's exit code if it finished in time, 124 (matching
# GNU `timeout` convention) if it timed out. macOS doesn't ship GNU
# coreutils `timeout`, so this is the bash-3.2-friendly replacement.
# stdout + stderr are discarded (we only care about exit code); redirect
# or pipe externally if you need the output.
with_timeout() {
  local timeout_s="${1:-30}"
  shift
  "$@" >/dev/null 2>&1 &
  local cmdpid=$!
  local elapsed=0
  while kill -0 "$cmdpid" 2>/dev/null; do
    if [ "$elapsed" -ge "$timeout_s" ]; then
      kill -9 "$cmdpid" 2>/dev/null
      wait "$cmdpid" 2>/dev/null
      return 124
    fi
    sleep 1
    elapsed=$((elapsed+1))
  done
  wait "$cmdpid" 2>/dev/null
  return $?
}

# ---------- 0. Pre-flight ----------
header "Pre-flight — current host tailscale state"
echo "    brew:                   $(command -v brew >/dev/null 2>&1 && brew --version | head -1 || echo 'not on PATH')"
echo "    tailscaled running:     $(pgrep -lf tailscaled 2>/dev/null | wc -l | tr -d ' ') process(es)"
echo "    brew service tailscale: $(brew services list 2>/dev/null | awk '$1=="tailscale"{print $2, $3}' | tr '\n' ' ' | sed 's/ $//')"
echo "    LaunchAgent plists (under ~/Library/LaunchAgents/):"
ls -1 ~/Library/LaunchAgents/ 2>/dev/null | grep -i 'tail' | sed 's/^/      /' || echo "      (none)"

# Detect Tailscale's macOS Network Extension (residual from prior App Store
# Tailscale.app installs). Lives under /Library/Apple/SystemExtensions/ and
# is managed by `systemextensionsctl` — NOT launchd. If loaded, brew
# tailscaled will NOT engage the Network Extension framework slot because
# the SE still has it claimed. Symptom: 'sudo tailscale status' returns
# "Tailscale is stopped" even when the daemon is alive and listening.
se_found=0
if command -v systemextensionsctl >/dev/null 2>&1; then
  # Grab any line matching tailscale and network-extension
  se_line=$(systemextensionsctl list 2>/dev/null | grep -iE '(io|com)\.tailscale\..*network-extension' | head -n 1)
  if [ -n "$se_line" ]; then
    se_found=1
    # Extract the teamID (10-char uppercase/numeric word)
    se_teamID=$(echo "$se_line" | tr -s ' \t' '\n' | grep -E '^[A-Z0-9]{10}$' | head -n 1)
    # Extract the bundleID (starts with io.tailscale or com.tailscale)
    se_bundleID=$(echo "$se_line" | tr -s ' \t' '\n' | grep -E '^(io|com)\.tailscale\.' | head -n 1 | sed 's/(.*//')
    
    # If teamID is not found, fallback to '-'
    if [ -z "$se_teamID" ]; then
      se_teamID="-"
    fi
  fi
fi

if [ "$se_found" = 1 ] && [ -n "$se_bundleID" ]; then
  echo "    ⚠ Tailscale Network Extension System Extension is loaded (residual from App Store Tailscale.app install)"
  echo "      Team ID: $se_teamID, Bundle ID: $se_bundleID"
  echo "      brew tailscaled cannot engage the NE slot while this SE has it claimed."
  if [ "$DRY" = 1 ]; then
    echo "    [dry] (would prompt) sudo systemextensionsctl uninstall $se_teamID $se_bundleID"
  else
    confirm "Run 'sudo systemextensionsctl uninstall $se_teamID $se_bundleID'? (frees the NE slot for brew tailscale; non-fatal if it errors)"
    sudo systemextensionsctl uninstall "$se_teamID" "$se_bundleID" 2>&1 \
      || echo "    ! uninstall returned non-zero (may require reboot, non-fatal)"
  fi
else
  echo "    ✓ no Tailscale System Extension loaded"
fi

# Pattern used by the Step-1 bootout loops, in both dry + real branches.
# Widened from a bare /tailscale/ so the same loops also pick up any
# nullexit-labeled LaunchAgents (e.g., com.nullexit.wake-recovery, the
# caffeinate + post-wake recovery hook). The wake-recovery LaunchAgent
# is re-installed by ./toggle.sh / setup.sh on re-engage, so wiping it
# here is non-fatal and is part of restoring a clean baseline.
TAILSCALE_LABEL_RE='tailscale'
NULLEXIT_LABEL_RE='nullexit'

# ---------- 1. brew services stop ----------
header "Step 1 — Stop the brew-managed service + unload LaunchAgents"
# Detect whether the brew-managed service is registered as $USER (gui/$UID
# domain) or as root (system domain). NOPASSWD sudoers can leave a stale
# root-owned registration after a prior 'sudo brew services ...' round;
# 'brew services stop' without sudo refuses to touch a root-owned plist
# (Error: Service 'tailscale' is started as `root`).
brew_status_line="$(brew services list 2>/dev/null | awk '$1=="tailscale"')"
brew_status_user="$(echo "$brew_status_line" | awk '{print $3}')"
if [ -n "$brew_status_line" ]; then
  if [ "$DRY" = 1 ]; then
    echo "    [dry] brew services stop tailscale (user=$brew_status_user)"
  else
    if [ "$brew_status_user" = "root" ]; then
      confirm "Run 'sudo brew services stop tailscale' (service is registered as root)?"
      sudo brew services stop tailscale 2>&1 || echo "    (sudo brew services stop returned non-zero — non-fatal)"
    else
      echo "    → brew services stop tailscale (user=$brew_status_user, no sudo needed)"
      brew services stop tailscale 2>&1 || echo "    (brew reported it wasn't actually running)"
    fi
  fi
  echo "    → unload any tailscale-related LaunchAgents (prevents launchd from respawning after kill)"
  if [ "$DRY" = 1 ]; then
    echo "      [dry] for each 'tailscale|nullexit'-matched label in gui/$UID domain:"
    while IFS= read -r label; do
      [ -z "$label" ] && continue
      echo "             [dry] launchctl bootout gui/$UID/$label"
    done < <(launchctl list 2>/dev/null | awk -v ts="$TAILSCALE_LABEL_RE" -v nx="$NULLEXIT_LABEL_RE" 'NR > 1 && ($3 ~ ts || $3 ~ nx) {print $3}')
    echo "      [dry] for each 'tailscale|nullexit'-matched label in system domain (root-owned brew plist):"
    while IFS= read -r label; do
      [ -z "$label" ] && continue
      echo "             [dry] (would prompt) sudo launchctl bootout system/$label"
    done < <(sudo -n launchctl list 2>/dev/null | awk -v ts="$TAILSCALE_LABEL_RE" -v nx="$NULLEXIT_LABEL_RE" 'NR > 1 && ($3 ~ ts || $3 ~ nx) {print $3}')
    if launchctl print system/com.tailscale.ipn.macos >/dev/null 2>&1; then
      echo "      [dry] (would prompt) sudo launchctl bootout system/com.tailscale.ipn.macos"
    fi
    if launchctl print system/com.tailscale.ipn.macsys >/dev/null 2>&1; then
      echo "      [dry] (would prompt) sudo launchctl bootout system/com.tailscale.ipn.macsys"
    fi
  else
    # Bootout every gui-domain LaunchAgent whose label matches 'tailscale'
    # OR 'nullexit'. The nullexit arm catches com.nullexit.wake-recovery,
    # which holds caffeinate/watcher.sh alive across a daemon reset — not
    # desired while the script is establishing a fresh baseline. Awake-
    # recovery is re-installed by ./toggle.sh / setup.sh on re-engage, so
    # wiping here is non-fatal. The pattern stays narrower than a bare
    # /tail/ or /null/ so unrelated Apple services are not unloaded.
    while IFS= read -r label; do
      [ -z "$label" ] && continue
      echo "      → launchctl bootout gui/$UID/$label"
      launchctl bootout "gui/$UID/$label" 2>/dev/null || true
    done < <(launchctl list 2>/dev/null | awk -v ts="$TAILSCALE_LABEL_RE" -v nx="$NULLEXIT_LABEL_RE" 'NR > 1 && ($3 ~ ts || $3 ~ nx) {print $3}')
    # Bootout every system-domain LaunchDaemon/Agent whose label matches
    # 'tailscale' OR 'nullexit'. This catches the root-owned brew plist left
    # behind by prior 'sudo brew services ...' invocations — that was the
    # case that left tailscaled PID 47447 → 57734 respawning between sudo
    # pkill runs. Defensive nullexit catch in case the user previously
    # `sudo ln -s`'d the wake-recovery plist into /Library/LaunchDaemons.
    while IFS= read -r label; do
      [ -z "$label" ] && continue
      confirm "Run 'sudo launchctl bootout system/$label'?"
      sudo launchctl bootout "system/$label" 2>/dev/null || true
    done < <(sudo -n launchctl list 2>/dev/null | awk -v ts="$TAILSCALE_LABEL_RE" -v nx="$NULLEXIT_LABEL_RE" 'NR > 1 && ($3 ~ ts || $3 ~ nx) {print $3}')
    # Legacy Tailscale.app system-domain entries. Each one is checked and
    # confirmed separately so we don't sudo-promp or sudo-bootout for nothing.
    if launchctl print system/com.tailscale.ipn.macos >/dev/null 2>&1; then
      confirm "Run 'sudo launchctl bootout system/com.tailscale.ipn.macos'?"
      sudo launchctl bootout system/com.tailscale.ipn.macos 2>/dev/null || true
    fi
    if launchctl print system/com.tailscale.ipn.macsys >/dev/null 2>&1; then
      confirm "Run 'sudo launchctl bootout system/com.tailscale.ipn.macsys'?"
      sudo launchctl bootout system/com.tailscale.ipn.macsys 2>/dev/null || true
    fi
  fi
  echo "    → waiting up to 10s for tailscaled to exit"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if [ "$DRY" = 1 ]; then
      echo "    [dry] sleep 1; loop check would terminate here"
      break
    fi
    sleep 1
    if ! pgrep -lf tailscaled >/dev/null 2>&1; then
      echo "    ✓ tailscaled exited in ${i}s"
      break
    fi
    [ "$i" = 10 ] && echo "    ✗ tailscaled still alive after 10s — Step 2 will deal with it"
  done
else
  echo "    ✓ brew reports no tailscale service loaded"
fi

# ---------- 2. Kill any orphan tailscaled ----------
header "Step 2 — Kill any orphan tailscaled process(es) (may escalate to sudo)"
if ! pgrep -lf tailscaled >/dev/null 2>&1; then
  echo "    ✓ no orphans"
else
  echo "    Stray process(es):"
  pgrep -lf tailscaled | sed 's/^/      /'
  echo "    → no-sudo: pkill tailscaled"
  if [ "$DRY" = 1 ]; then
    echo "    [dry] pkill tailscaled → on failure: sudo pkill -9 tailscaled"
  else
    if pkill tailscaled 2>/dev/null; then
      echo "    ✓ no-sudo pkill succeeded"
    else
      echo "    ! no-sudo pkill insufficient; cannot escalate yet"
    fi
    sleep 1
  fi

  # Recheck; if still alive, offer sudo escalation
  if { [ "$DRY" = 0 ] && pgrep -lf tailscaled >/dev/null 2>&1; } || [ "$DRY" = 1 ]; then
    if [ "$DRY" = 1 ]; then
      echo "    [dry] sudo pkill -9 tailscaled  (escalation would fire here)"
    else
      confirm "Run 'sudo pkill -9 tailscaled' to escalate?"
      sudo pkill -9 tailscaled 2>&1
      sleep 1
    fi
  fi

  if [ "$DRY" = 0 ]; then
    if pgrep -lf tailscaled >/dev/null 2>&1; then
      echo "    ✗ Failed to kill stragglers — bailing out"
      pgrep -lf tailscaled | sed 's/^/      /'
      exit 3
    fi
    echo "    ✓ all tailscaled processes gone"
  fi
fi

# ---------- 3. brew uninstall ----------
header "Step 3 — brew uninstall tailscale"
if ! brew list tailscale >/dev/null 2>&1; then
  echo "    ✓ not currently installed via brew — skip"
else
  # Detect whether the keg directory is owner=$USER or owner=root. If the
  # keg is root-owned (typically a residual of some prior 'sudo brew ...'
  # cycle that did perms fixups), 'brew uninstall' without sudo refuses
  # to remove the files and prints: 'Error: Could not remove tailscale
  # keg! Do so manually: sudo rm -rf /opt/homebrew/Cellar/tailscale/<v>'.
  # Detect that and escalate to a sudoed uninstall, with a manual rm -rf
  # fallback if `sudo brew uninstall` itself errors out (e.g., partial
  # state where the keg dir is gone but brew still thinks it's installed).
  # Detect keg state. Treat `(dir absent)` AND `(dir present + empty)` as the
  # same `<unknown>` bucket so both escalate to sudo. The empty-parent case
  # is what you get after a manual `sudo rm -rf /opt/homebrew/Cellar/tailscale/<v>`
  # from inside: brew's parent dir is left present-but-empty and brew still
  # thinks the package is installed.
  keg_dir="/opt/homebrew/Cellar/tailscale"
  if [ -d "$keg_dir" ] && [ -n "$(ls -A "$keg_dir" 2>/dev/null)" ]; then
    keg_owner="$(stat -f '%Su' "$keg_dir" 2>/dev/null || echo '<unknown>')"
  else
    keg_owner="<unknown>"
  fi
  if [ "$DRY" = 1 ]; then
    echo "    [dry] brew uninstall tailscale (keg_owner=$keg_owner)"
  else
    # 'root' AND '<unknown>' both require sudo escalation. The '<unknown>'
    # case is the partial-state path: keg dir was already removed (manually
    # or by a prior failed uninstall) but brew's internal state still says
    # installed. Without this branch the script would fall through to a
    # non-sudo brew uninstall that fails again with the same 'Could not
    # remove tailscale keg!' error.
    if [ "$keg_owner" = "root" ] || [ "$keg_owner" = "<unknown>" ]; then
      confirm "Run 'sudo brew uninstall tailscale' (keg=$keg_owner)?"
      sudo brew uninstall tailscale 2>&1 || {
        echo "    ! sudo brew uninstall failed; offering manual rm -rf fallback"
        # Guard the glob so an empty/absent dir doesn't literal-expand the
        # '*' and confuse the user with a sudo error about a non-existent path.
        if [ -d /opt/homebrew/Cellar/tailscale ] && [ -n "$(ls -A /opt/homebrew/Cellar/tailscale 2>/dev/null)" ]; then
          confirm "Run 'sudo rm -rf /opt/homebrew/Cellar/tailscale/*'?"
          sudo rm -rf /opt/homebrew/Cellar/tailscale/* 2>&1
        else
          echo "    ✓ keg dir already empty or absent — nothing more to rm"
        fi
      }
    else
      confirm "Run 'brew uninstall tailscale' (removes LaunchAgent plist + linked symlinks)?"
      brew uninstall tailscale 2>&1
    fi
  fi
fi

# ---------- 4. Wipe state directories ----------
header "Step 4 — Wipe stale state"
# User-owned
declare -a USER_PATHS
USER_PATHS=(
  "$HOME/.local/share/tailscale"
  "$HOME/.local/run/tailscaled.socket"
  "$HOME/.local/run/tailscaled.state"
  "$HOME/.local/state/tailscale"
  "$HOME/Library/Application Support/Tailscale"
  "$HOME/Library/Caches/com.tailscale.ipn.macos"
  "$HOME/Library/Caches/Tailscale"
  "$HOME/Library/Logs/Tailscale"
)
echo "    User-owned paths (no sudo):"
for p in "${USER_PATHS[@]}"; do
  if [ -e "$p" ]; then
    if [ "$DRY" = 1 ]; then
      echo "      [dry] rm -rf '$p'"
    else
      rm -rf "$p"
      echo "      ✓ rm -rf '$p'"
    fi
  fi
done

# System
declare -a SUDO_PATHS
SUDO_PATHS=(
  "/var/lib/tailscale"
  "/var/cache/tailscale"
)
echo "    System paths under /var (will prompt for sudo if any are present):"
eligible_sudo=0
for p in "${SUDO_PATHS[@]}"; do
  if [ -e "$p" ]; then
    eligible_sudo=1
    if [ "$DRY" = 1 ]; then
      echo "      [dry] sudo rm -rf '$p'"
    else
      if confirm "Run 'sudo rm -rf $p'?"; then
        sudo rm -rf "$p" && echo "      ✓ rm -rf '$p'"
      fi
    fi
  fi
done
[ "$eligible_sudo" = 0 ] && echo "      (none of /var/lib/tailscale, /var/cache/tailscale are present)"

# ---------- 5. Wipe stale LaunchAgent plists ----------
header "Step 5 — Wipe stale LaunchAgent plist files"
declare -a PLIST_FILES
PLIST_FILES=(
  "$HOME/Library/LaunchAgents/homebrew.mxcl.tailscale.plist"
  "$HOME/Library/LaunchAgents/com.tailscale.ipn.macos.plist"
  "$HOME/Library/LaunchAgents/homebrew.mxcl.tailscale.plist.bak"
  "$HOME/Library/LaunchAgents/com.nullexit.wake-recovery.plist"
)
for f in "${PLIST_FILES[@]}"; do
  if [ -e "$f" ]; then
    if [ "$DRY" = 1 ]; then
      echo "    [dry] rm -f '$f'"
    else
      rm -f "$f"
      echo "    ✓ rm -f '$f'"
    fi
  fi
done
echo "    Remaining tailscale|nullexit plists (should be empty):"
ls -1 ~/Library/LaunchAgents/ 2>/dev/null | grep -i 'tail' | sed 's/^/      /' || echo "      (none)"

# ---------- 5.5. Drain Background-Items (Login Items) ----------
header "Step 5.5 — Drain Background-Items (Login Items)"
# macOS 13+ keeps a parallel "Background Items" database alongside
# classic LaunchAgents. Even when we wipe ~/Library/LaunchAgents/homebrew.mxcl.tailscale.plist
# in Step 5, the .btm file at
# ~/Library/Application Support/com.apple.backgroundtaskmanagementagent.backgrounditems.btm
# can still hold a Background-Items entry pointing at the (now-dead) plist
# path. Next login: macOS sees the entry, tries to bootstrap, finds the
# plist missing, and either silently regenerates it via brew's post-install
# hook (causing tailscaled respawn at next login) or refuses outright.
# `sfltool reset-login-items` is Apple's canonical API for wiping the
# entire .btm file. It DOES wipe all Login Items — the user re-adds what
# they want via System Settings → General → Login Items. Acceptable here
# because the goal of this script is "fresh baseline for Tailscale".
BTM="$HOME/Library/Application Support/com.apple.backgroundtaskmanagementagent/backgrounditems.btm"
if [ -f "$BTM" ]; then
  if [ "$DRY" = 1 ]; then
    echo "    [dry] found $BTM; would prompt sfltool reset-login-items"
  else
    confirm "Run 'sfltool reset-login-items' (wipes ALL Login Items; rebuild via System Settings → General → Login Items)?"
    if sfltool reset-login-items 2>&1; then
      echo "    ✓ Login Items drained"
    else
      echo "    ! sfltool reset-login-items failed (non-fatal; do manually: System Settings → General → Login Items)"
    fi
  fi
else
  echo "    ✓ no backgrounditems.btm present"
fi

# ---------- 6. brew install ----------
header "Step 6 — brew install tailscale (fresh)"
if brew list tailscale >/dev/null 2>&1; then
  echo "    ✓ already installed — skip"
else
  confirm "Run 'brew install tailscale'?"
  if [ "$DRY" = 1 ]; then
    echo "    [dry] brew install tailscale"
  else
    brew install tailscale 2>&1
  fi
fi

# ---------- 6.5. Strip quarantine xattr from keg ----------
header "Step 6.5 — Strip quarantine xattr from tailscale install"
# brew's freshly poured bottles don't carry com.apple.quarantine (the
# bottles are content-addressed and Homebrew-verified), but the upstream
# installer (Tailscale.app from App Store) and any manual download do.
# Strip the xattr from the entire keg as a defensive safety net so the
# freshly-installed tailscaled binary and any helper binaries are not
# Gatekeeper-blocked on first launch. Idempotent — no-op if no quarantine
# xattr is present.
quarantine_count="$(xattr -lr /opt/homebrew/Cellar/tailscale 2>/dev/null | grep -c '^[^ ]* com.apple.quarantine' || echo 0)"
if [ "${quarantine_count:-0}" -gt 0 ]; then
  if [ "$DRY" = 1 ]; then
    echo "    [dry] found $quarantine_count file(s) with com.apple.quarantine; would prompt xattr -dr"
  else
    confirm "Run 'xattr -dr com.apple.quarantine /opt/homebrew/Cellar/tailscale'? (strips quarantine xattr from $quarantine_count file(s); non-fatal if it errors)"
    if xattr -dr com.apple.quarantine /opt/homebrew/Cellar/tailscale 2>&1; then
      echo "    ✓ quarantine xattr stripped"
    else
      echo "    ! xattr -dr failed (non-fatal; open /opt/homebrew/Cellar/tailscale in Finder, right-click tailscaled → Open Anyway)"
    fi
  fi
else
  echo "    ✓ no com.apple.quarantine xattr on tailscale install"
fi

# ---------- 7. brew services start (NO sudo!) ----------
header "Step 7 — Start the service as $USER (NO sudo, with multi-tier self-healing)"
if ! command -v tailscale >/dev/null 2>&1; then
  echo "    ⚠ tailscale not on PATH after install — brew install errored; aborting"
  exit 4
fi

# Aliveness fan-out: ANY one of these is taken as proof of life. None of
# them alone is reliable — pgrep misses tailscaled if it does setproctitle
# or fork-detach; launchctl's reported PID can be a shim that exited
# within 1s; tailscale-cli hangs while macOS Local-Network permission is
# unresolved. Combined, they cover each other's blind spots.

tailscaled_api_up() {
  # Strategy A: tailscale CLI can talk to the local API. Canonical proof.
  # Bound at 8s — tailscale status itself returns quickly on success OR
  # failure, but if the post-install state is wedged it can hang.
  with_timeout 8 /opt/homebrew/bin/tailscale status >/dev/null 2>&1
}

tailscaled_proc_up() {
  # Strategy B: any process has 'tailscaled' substring in argv.
  pgrep -lf tailscaled >/dev/null 2>&1
}

tailscaled_lc_up() {
  # Strategy C: launchctl-managed service has a non-dash, non-zero PID.
  local lc_pid
  lc_pid="$(launchctl list 2>/dev/null | awk '$3 == "homebrew.mxcl.tailscale" {print $1; exit}')"
  if [ -n "$lc_pid" ] && [ "$lc_pid" != "-" ] && [ "$lc_pid" -gt 0 ] 2>/dev/null; then
    return 0
  fi
  return 1
}

tailscaled_is_alive() {
  tailscaled_api_up  && return 0
  tailscaled_proc_up && return 0
  tailscaled_lc_up   && return 0
  return 1
}

confirm "Run 'brew services start tailscale'?"
if [ "$DRY" = 1 ]; then
  echo "    [dry] brew services start tailscale"
  echo "    [dry] (then poll up to 30s for tailscaled_is_alive)"
  echo "    [dry] (recovery tier 1: launchctl kickstart)"
  echo "    [dry] (recovery tier 2: launchctl bootout + bootstrap of explicit plist)"
  echo "    [dry] (recovery tier 3: brew services restart (stop+start cycle))"
  echo "    [dry] (recovery tier 4: direct /opt/homebrew/bin/tailscaled spawn (bypasses launchd))"
else
  brew services start tailscale 2>&1
  # Primary poll — tailscaled_is_alive covers all 3 detection strategies.
  echo "    → polling for tailscaled to come up (up to ~30s)"
  tailscaled_up=0
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if tailscaled_is_alive; then
      tailscaled_up=1
      echo "      ✓ tailscaled alive after ${i}*2s"
      break
    fi
    sleep 2
  done

  # Recovery tier 1: kickstart the launchd-managed service. This is the
  # cheapest and most-aligned-with-launchd fix when brew has loaded the
  # LaunchAgent but tailscaled didn't fork. Kickstart tells launchd
  # "re-spawn if not running" without forcing a teardown.
  if [ "$tailscaled_up" = 0 ]; then
    echo "    ! Recovery tier 1: launchctl kickstart"
    if launchctl kickstart -kp "gui/$UID/homebrew.mxcl.tailscale" 2>&1; then
      for i in 1 2 3 4 5 6 7 8 9 10; do
        if tailscaled_is_alive; then
          tailscaled_up=1
          echo "      ✓ tailscaled alive after kickstart (${i}*2s)"
          break
        fi
        sleep 2
      done
    else
      echo "      ! kickstart returned non-zero (LaunchAgent may not be loaded)"
    fi
  fi

  # Recovery tier 2: explicit plist bootout + bootstrap. Forces a fresh
  # launchd registration cycle for the brew-managed service, which fixes
  # the wider class of "brew says started but daemon never spawned"
  # wedge states that kickstart alone can't dig out of.
  if [ "$tailscaled_up" = 0 ]; then
    echo "    ! Recovery tier 2: launchctl bootout + bootstrap of explicit plist"
    launchctl bootout "gui/$UID/homebrew.mxcl.tailscale" 2>/dev/null || true
    sleep 1
    # Brew installs the canonical plist template at $HOMEBREW_PREFIX/Library/.
    # On Apple Silicon that's /opt/homebrew/Library/LaunchAgents/. On Intel
    # it's /usr/local/Library/LaunchAgents/. Detect which and pick the
    # right one so this script works across both architectures.
    if [ -f /opt/homebrew/Library/LaunchAgents/homebrew.mxcl.tailscale.plist ]; then
      plist_path="/opt/homebrew/Library/LaunchAgents/homebrew.mxcl.tailscale.plist"
    elif [ -f /usr/local/Library/LaunchAgents/homebrew.mxcl.tailscale.plist ]; then
      plist_path="/usr/local/Library/LaunchAgents/homebrew.mxcl.tailscale.plist"
    else
      plist_path=""
    fi
    if [ -n "$plist_path" ]; then
      if launchctl bootstrap "gui/$UID" "$plist_path" 2>&1; then
        for i in 1 2 3 4 5 6 7 8 9 10; do
          if tailscaled_is_alive; then
            tailscaled_up=1
            echo "      ✓ tailscaled alive after bootstrap (${i}*2s)"
            break
          fi
          sleep 2
        done
      else
        echo "      ! explicit bootstrap returned non-zero"
      fi
    else
      echo "      ! could not locate brew plist template; skipping bootstrap tier"
    fi
  fi

  # Recovery tier 3: brew services restart (forces a stop + start cycle,
  # which unsticks LaunchAgents with stale 'started' state from prior
  # half-cycles). This is the canonical brew-doc fix for 'services don't
  # actually start even though brew says started'.
  if [ "$tailscaled_up" = 0 ]; then
    echo "    ! Recovery tier 3: brew services restart (forces stop+start cycle)"
    if brew services restart tailscale 2>&1; then
      for i in 1 2 3 4 5 6 7 8 9 10; do
        if tailscaled_is_alive; then
          tailscaled_up=1
          echo "      ✓ tailscaled alive after brew restart (${i}*2s)"
          break
        fi
        sleep 2
      done
    else
      echo "      ! brew services restart returned non-zero"
    fi
  fi

  # Recovery tier 4: last-resort direct spawn of the daemon binary,
  # bypassing launchd entirely. If tailscaled crashes here too, we'll
  # capture its actual stderr in /tmp for the user to read (NOPASSWD
  # sudoers often have local-network permission denied — the captured
  # stderr makes it obvious what to fix in System Settings).
  if [ "$tailscaled_up" = 0 ]; then
    echo "    ! Recovery tier 4: direct spawn (bypasses launchd; tail stderr to /tmp)"
    /opt/homebrew/bin/tailscaled >/tmp/nullexit-tailscaled-spawn.log 2>&1 &
    spawned_pid=$!
    disown "$spawned_pid" 2>/dev/null || true
    sleep 3
    if tailscaled_is_alive; then
      tailscaled_up=1
      echo "      ✓ tailscaled alive via direct spawn (pid=$spawned_pid)"
      echo "      (NOTE: not under launchd supervision — a reboot, re-run of"
      echo "       this script, or ./toggle.sh is required to recreate."
      echo "       Last 5 lines of stderr captured to /tmp/nullexit-tailscaled-spawn.log:)"
      tail -n 5 /tmp/nullexit-tailscaled-spawn.log 2>/dev/null | sed 's/^/        /' || true
    fi
  fi

  if [ "$tailscaled_up" = 0 ]; then
    echo "    ✗ HARD FAIL: tailscaled refuses to stay alive across every recovery tier"
    echo "      launchctl-managed state (if available):"
    launchctl print "gui/$UID/homebrew.mxcl.tailscale" 2>/dev/null \
      | grep -E 'state =|last exit code =|runs =|path =' \
      | sed 's/^/        /' \
      || echo "        (no launchctl state available for homebrew.mxcl.tailscale)"
    echo "      Last 10 lines of /tmp/nullexit-tailscaled-spawn.log (if any):"
    tail -n 10 /tmp/nullexit-tailscaled-spawn.log 2>/dev/null | sed 's/^/        /' || echo "        (no log)"
    echo "      Most likely remaining cause: macOS Local Network permission denied."
    echo "      System Settings → Privacy & Security → Local Network → toggle Tailscale ON."
    exit 7
  fi
fi
sleep 3

# ---------- 8. Verify ----------
header "Step 8 — Verify fresh install"
echo "    brew service tailscale: $(brew services list 2>/dev/null | awk '$1=="tailscale"{print $2, $3}' | tr '\n' ' ' | sed 's/ $//')"
echo "    tailscaled process:     $(pgrep -lf tailscaled 2>/dev/null | head -1 || echo 'NONE (check brew logs)')"
ts_ver=""
if [ -x /opt/homebrew/bin/tailscale ]; then
  ts_ver="$(/opt/homebrew/bin/tailscale version 2>/dev/null | head -1 | tr -d '\n')"
elif command -v tailscale >/dev/null 2>&1; then
  ts_ver="$(tailscale version 2>/dev/null | head -1 | tr -d '\n')"
fi
echo "    tailscale version:      ${ts_ver:-binary missing}"
ts_status=""
if [ -x /opt/homebrew/bin/tailscale ]; then
  ts_status="$(/opt/homebrew/bin/tailscale status 2>/dev/null | head -3)"
fi
if [ -n "$ts_status" ]; then
  echo "    tailscale status:"
  printf '%s\n' "$ts_status" | sed 's/^/      /'
else
  echo "    tailscale status:       (binary missing or errored)"
fi

if { [ "$DRY" = 0 ] && /opt/homebrew/bin/tailscale status 2>/dev/null | grep -q '^Tailscale is stopped'; }; then
  echo
  echo "    ⚠ NOTICE: 'tailscale status' still reports stopped after a fresh install."
  echo "       Two equally likely causes:"
  echo "         (a) macOS hasn't yet shown the first-run 'Local Network' prompt for"
  echo "             Tailscale — open System Settings → Privacy & Security → Local"
  echo "             Network. Toggle Tailscale ON."
  echo "         (b) macOS denied Local Network permission at some prior point."
  echo "       Either way: System Settings → Privacy & Security → Local Network."
  echo "       If the entry isn't present, invoking any tailscale command will"
  echo "       re-trigger the prompt automatically."
fi

# ---------- 9. Done ----------
header "Done"
if [ "$DRY" = 1 ]; then
  echo "    (dry-mode finished; no follow-up commands were issued.)"
  exit 0
fi

cat <<'DONE'

  ⮕ Manual follow-ups (all of these; the script stops short of running sudo
    tailscale up so you can verify the brew install is actually live first):

    1. ⇨ System Settings → Privacy & Security → Local Network → Tailscale ON
       macOS will normally pop the prompt the first time you run `tailscale`.
       If it didn't, trigger it via the menu bar → check.

    2. ⇨ Re-engage the tailnet + exit node:
           sudo tailscale up --ssh=true --accept-dns=false \
             --exit-node="$(cat .gateway_ip | tr -d '\r' | awk 'NR==1{print $1; exit}')" \
             --exit-node-allow-lan-access=true

    3. ⇨ Re-run: ./toggle.sh
       (re-installs the com.nullexit.wake-recovery LaunchAgent — wiped
       in Step 5 to clear the slate — and re-engages the gateway)

    4. ⇨ Final verification:
           curl -s https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(warp|ip|colo)='
         expect: warp=on, ip=<Cloudflare IP>, colo=YYZ/YUL

    Container-side (gateway / 100.100.21.8) Tailscale is unaffected by this
    script. Other tailnet devices (S24, iPhone, Windows) are unaffected.

DONE
