#!/bin/bash
# scripts/watcher.sh — nullexit post-wake / post-roam recovery watcher
#
# Long-running daemon. Launched by launchd as a LaunchAgent at
# ~/Library/LaunchAgents/com.nullexit.wake-recovery.plist
# (label com.nullexit.wake-recovery).
#
# Two independent listeners run as backgrounded pipelines:
#
#   (1) WAKE listener — `log stream` live-follows the macOS unified log for
#       power-management events (lid close→wake, manual wake, DarkWake from
#       clamshell). Each event triggers run_recover (with a global debounce so
#       a single wake that emits 2-3 log lines only causes ONE post-wake run).
#
#   (2) NETWORK listener — `scutil n.watch` on `State:/Network/Global/IPv4`
#       fires on every Wi-Fi roam, ethernet swap, hotspot join, captive-portal
#       re-bind, VPN up/down, etc. Same debounce.
#
# Both listeners call run_recover, which:
#   - checks /tmp/nullexit-gateway-active.marker (only act when toggle.sh left
#     the gateway up)
#   - debounces (10s default) so multiple events don't pile up
#   - shells out to `bash <repo>/recover.sh --post-wake` directly (no GUI auth prompt needed due to NOPASSWD sudoers)
#
# See devref.md §10.29 for the full Apple power management primer and the
# rationale behind using `log stream` + `scutil n.watch` from a shell daemon.

# NOTE: errexit (`set -e`) is intentionally NOT enabled. This is a long-running
# daemon, not a discrete-step script, and errexit actively breaks the reconnect
# loops below: any failed pipe (log stream on rotation, scutil on state churn)
# would kill the outer subshell before `echo "reconnecting..."; sleep 5;` runs,
# AND the parent's final `wait` would propagate a non-zero child exit and kill
# the entire watcher. Every error path is already wrapped in `|| true` /
# `2>/dev/null` fallbacks.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
setup_standard_path

LOG="$SCRIPT_DIR/../output.log"
# Resolve our own directory; recover.sh lives one level up at the repo root.
# This makes the daemon install-agnostic — no need to template the path
# in launchd, no need to keep a deploy-specific hardcoded location in sync.
RECOVER="$SCRIPT_DIR/../recover.sh"
MARKER="$MARKER_FILE"
DEBOUNCE_FILE="/tmp/nullexit-watcher.last-recovery"
DEBOUNCE_SECONDS="${NULLEXIT_DEBOUNCE_SECONDS:-10}"
# Post-recovery SETTLE cooldown. A post-wake run re-asserts the exit node
# (recover.sh: `tailscale set --exit-node`), which re-writes the host default
# route — and that route IS State:/Network/Global/IPv4, the exact key Listener 2
# watches. The self-triggered change lands ~15-45s AFTER the run finishes, past
# the 10s debounce, so without a longer window the watcher re-fires post-wake in
# a ~40s self-feedback loop that only stops once routing happens to reach a fixed
# point (devref §15.12.21). This cooldown is armed ONLY after a recovery runs, so
# a genuine first wake/roam is still handled immediately; only the change we
# caused ourselves gets absorbed. A real new roam during the window is delayed at
# most this many seconds, which is acceptable.
COOLDOWN_FILE="/tmp/nullexit-watcher.settle-until"
POSTWAKE_SETTLE_SECONDS="${NULLEXIT_POSTWAKE_SETTLE_SECONDS:-45}"

exec >> "$LOG" 2>&1

# ─── Single-instance lock ──────────────────────────────────────────────────────
# Without this, repeated lid-close→wake cycles under macOS Sonoma+ accumulate
# orphan watcher.sh processes: launchd suspends on sleep and SIGCONT-resumes
# on wake, and KeepAlive.Crashed=true caused relaunch on any non-zero exit;
# the listener grandchildren (log stream | while ...  and  (echo n.add ...;
# sleep 86400) | scutil | while ...) stay alive because pipe producers don't
# reliably respond to plain SIGTERM if the consumer is in a half-closed state.
#
# We solve it with a PID-file lock (POSIX-portable; macOS does NOT ship `flock`).
# The trap below removes the lock file on every exit so a stale lock never
# outlives a crashed watcher. On launch: read the existing PID, check it is
# alive AND is actually a `scripts/watcher.sh` process; if so, exit 0; else
# overwrite with our PID and proceed. The check-then-write window has a TOCTOU
# race but is microseconds wide and only matters for hand-launched duplicate
# test invocations; production is single-launch via launchctl load -w.
LOCK_FILE="/tmp/nullexit-watcher.lock"
LOCK_PID=""
if [ -e "$LOCK_FILE" ]; then
  LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    # Verify the holder is actually a scripts/watcher.sh process (not some
    # unrelated process that got the recycled PID). The exact-launchd pattern
    # `bash <abs-path>/scripts/watcher.sh` is hard to accidentally match with
    # a `grep scripts/watcher.sh .` invocation because we anchor on `^bash`
    # followed by whitespace and end-of-line on the script path.
    if ps -p "$LOCK_PID" -o args= 2>/dev/null | grep -qE "(^|[[:space:]])bash[[:space:]]+.*scripts/watcher\.sh$"; then
      echo "[$(date -u +%FT%TZ)] watcher.sh: another instance holds $LOCK_FILE (pid=$LOCK_PID), exiting"
      exit 0
    fi
  fi
fi
echo $$ > "$LOCK_FILE"

echo "[$(date -u +%FT%TZ)] watcher.sh start (pid=$$ ppid=$PPID user=$(id -un) lock=acquired)"

# Treat launchd-resume as a wake signal. Apple's launchd SUSPENDS LaunchAgents
# during system sleep and restores them on wake; during that suspended gap,
# macOS's `log stream` cannot catch the wake event that prompted the resume.
# The next thing that happens after wake IS our own startup, so we always
# fire one post-wake run unconditionally here. The marker check + debounce
# in run_recover() make this idempotent: if the gateway isn't up or we just
# debounced, it no-ops. Without this, the FIRST wake-after-install goes
# unseen and the watcher appears broken until the SECOND wake.
# ─── Helper: run recover.sh --post-wake if the gateway is active ──────────
run_recover() {
  local why="$1"
  if [ ! -f "$MARKER" ]; then
    echo "[$(date -u +%FT%TZ)] $why → no $MARKER, skip"
    return 0
  fi
  local now last settle_until
  now=$(date +%s)
  # Post-recovery settle window: ignore the Global/IPv4 change our own last
  # post-wake run caused (exit-node re-assert) so we don't self-feedback loop.
  settle_until=$(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0)
  if [ "$now" -lt "$settle_until" ]; then
    echo "[$(date -u +%FT%TZ)] $why → settling ($((settle_until - now))s left in post-recovery cooldown), skip"
    return 0
  fi
  last=$(cat "$DEBOUNCE_FILE" 2>/dev/null || echo 0)
  if [ "$((now - last))" -lt "$DEBOUNCE_SECONDS" ]; then
    echo "[$(date -u +%FT%TZ)] $why → debounced ($((now - last))s since last, threshold ${DEBOUNCE_SECONDS}s)"
    return 0
  fi
  echo "$now" > "$DEBOUNCE_FILE"
  echo "[$(date -u +%FT%TZ)] $why → bash $RECOVER --post-wake"
  bash "$RECOVER" --post-wake
  local exit_code=$?
  now=$(date +%s)
  echo "$now" > "$DEBOUNCE_FILE"
  # Arm the settle cooldown so the route change this run just caused can't re-fire us.
  echo "$((now + POSTWAKE_SETTLE_SECONDS))" > "$COOLDOWN_FILE"
  echo "[$(date -u +%FT%TZ)] $why → exit=$exit_code (settle until +${POSTWAKE_SETTLE_SECONDS}s, now=$now)"
  return $exit_code
}

if [ -f "$MARKER" ]; then
  run_recover "initial post-wake (launchd resume = wake signal)"
fi

# ─── LAN P2P Auto-Detection ────────────────────────────────────────────────
# Detects whether the current network allows safe Tailscale LAN P2P by:
#   1. Checking WPA2-Enterprise (802.1x) via system_profiler SPAirPortDataType — always forces P2P=false
#      because enterprise networks almost universally have AP Client Isolation.
#   2. AP Isolation probe — sends a broadcast ping and checks if ANY LAN host responds.
#      If no LAN hosts respond on a non-empty network, AP Isolation is active.
# Writes 'true' or 'false' to .lan_p2p_detected in the repo root.
# routing-fix.sh reads this file dynamically every 30s loop iteration.
P2P_OVERRIDE_FILE="$SCRIPT_DIR/../.lan_p2p_detected"


detect_lan_p2p_mode() {
  local reason="unknown" allow="false"

  # Step 1: Detect Wi-Fi security type via system_profiler (airport binary removed in macOS 14.4+)
  # SPAirPortDataType lists all known networks; the first "Security:" line is the current association.
  local security
  security=$(system_profiler SPAirPortDataType 2>/dev/null \
    | awk '/Current Network Information:/{found=1} found && /Security:/{print $NF; exit}')

  if [ -z "$security" ]; then
    # Not on Wi-Fi or system_profiler unavailable — fail safe
    reason="no-wifi" allow="false"
  elif echo "$security" | grep -qi "Enterprise"; then
    # WPA2/WPA3 Enterprise = 802.1x — always AP isolated
    reason="802.1x-enterprise" allow="false"
  elif echo "$security" | grep -qi "Personal\|None\|Open"; then
    # WPA2/WPA3 Personal or open — probe for AP isolation
    local gw
    gw=$(route -n get 1.1.1.1 2>/dev/null | awk '/gateway:/{print $2}')
    if [ -z "$gw" ]; then
      reason="no-default-route" allow="false"
    else
      local responses
      responses=$(ping -c 3 -t 1 -q "$gw" 2>/dev/null | awk '/packets transmitted/{print $4}')
      if [ "${responses:-0}" -gt 0 ]; then
        reason="wpa-personal-lan-reachable" allow="true"
      else
        reason="wpa-personal-ap-isolated" allow="false"
      fi
    fi
  else
    # Unknown security type — fail safe
    reason="unknown-security-type" allow="false"
  fi

  echo "[$(date -u +%FT%TZ)] P2P detect: security='${security:-none}' → allow=${allow} (reason: ${reason})"
  echo "$allow" > "$P2P_OVERRIDE_FILE"
  write_host_ips
}

# Run once on startup
detect_lan_p2p_mode

# ─── Listener 1: WAKE events via unified log ───────────────────────────────
# Predicate picks up:
#   * "didWake"             — regular kernel wake events (lid open, RTC alarm)
#   * "Wake from Sleep"     — powerd-driven normal wake
#   * "DarkWake"            — clamshell-display wake that didn't fully wake the
#                             Mac (relevant when lid opens during display sleep)
#   * "Waking from"         — generic catch-all for variations in newer macOS
# `[c]` makes the match case-insensitive (the unified log uses mixed-case
# phrases). --info reduces noise by dropping debug/trace log levels.
# Subsystem-based predicate catches every powermanagement emission (willSleep,
# didWake, didDim, didUndim, DarkWake, etc.) regardless of message phrasing
# across kernel versions. Phrasing-based predicates ('didWake', 'Wake from Sleep')
# are fragile across macOS releases. We accept the extra log noise because the
# run_recover() debounce + marker check filter out anything that isn't a real
# gateway-relevant event.
(
  # Reconnect loop: macOS rotates the unified log buffer periodically; when
  # that happens, this `log stream` subscriber's pipe EOFs, the inner
  # `while read` consumer terminates, and without this wrapper the listener
  # would be silently dead for the rest of the watcher's lifetime.
  while :; do
    log stream --predicate \
      'subsystem == "com.apple.powermanagement"' \
       --style compact --info 2>/dev/null \
      | while IFS= read -r line; do
          [ -z "$line" ] && continue
          run_recover "WAKE: $(echo "$line" | head -c 100)"
        done
    echo "[$(date -u +%FT%TZ)] log stream subshell exited; reconnecting in 5s"
    sleep 5
  done
) &

# ─── Listener 2: NETWORK state changes via scutil ──────────────────────────
# `scutil n.watch` on a state key prints SCEventUpdate lines whenever the key
# changes. We watch Global/IPv4 because that's the umbrella that catches link,
# address, route, and DNS changes for ALL interfaces in one namespace.
# The pipe is kept alive by an `sleep 86400` loop so scutil never sees EOF
# from us (which would silently terminate the watch).
(
  # Reconnect loop: scutil can exit noisily on certain state changes (rare,
  # but observed). Without the wrapper, the network listener's pipe EOFs and
  # every subsequent roam goes unseen until launchd restarts us.
  while :; do
    (
      # Watch both IPv4 and IPv6 umbrella state — IPv6-only or dual-stack
      # networks never fire on the IPv4 key alone, and the user's first roam
      # in a hotel / airport / on cellular hotspot is often IPv6-first under
      # NAT64.
      echo "n.add State:/Network/Global/IPv4"
      echo "n.add State:/Network/Global/IPv6"
      echo "n.watch"
      while true; do sleep 86400; done
    ) | script -q /dev/null scutil 2>/dev/null \
      | while IFS= read -r line; do
          case "$line" in
            *changedKey*|*State:/Network/Global/IPv*|*n.state*|*SCEventUpdate*)
              detect_lan_p2p_mode
              run_recover "NET: $(echo "$line" | head -c 100)"
              ;;
            *) ;;
          esac
        done
    echo "[$(date -u +%FT%TZ)] scutil pipe exited; reconnecting in 5s"
    sleep 5
  done
) &
# ─── Listener 3: TUNNEL_FAILED_CLOSED.marker Watcher ──────────────────────────
# Polls for the fail-closed marker dropped by the routing-fix container.
(
  last_notified=0
  while :; do
    if [ -f "$SCRIPT_DIR/../TUNNEL_FAILED_CLOSED.marker" ]; then
      now=$(date +%s)
      # Notify once every 5 minutes (300s) if it stays failed
      if [ "$((now - last_notified))" -ge 300 ]; then
        osascript -e 'display notification "VPN Tunnel Health Check Failed. Internet traffic is blackholed to prevent IP leak." with title "NullExit Alert"' || true
        last_notified=$now
      fi
    else
      last_notified=0
    fi
    sleep 3
  done
) &

# ─── Lifetime ──────────────────────────────────────────────────────────────
# `wait` blocks until both background pipelines exit (which they normally
# never do). launchctl `bootout`/SIGTERM triggers the trap, which kills the
# whole process group so the sleep-forever in the scutil pipe also dies.
# We catch TERM/INT/HUP for explicit signals and EXIT for any normal-exit path
# (so listeners always get cleaned up even if `exit 0` runs somewhere).
# `rm -f $LOCK_FILE` first so a stale lock can never block the next launch.
# `pkill -TERM -P $$` then targets direct listener-children, then `kill 0`
# takes care of any backgrounded group-mates not reachable via the parent.
trap 'echo "[$(date -u +%FT%TZ)] watcher.sh terminating (signal/exit=$?)"; rm -f "$LOCK_FILE" 2>/dev/null || true; pkill -TERM -P $$ 2>/dev/null || true; kill 0 2>/dev/null || true; exit 0' TERM INT HUP EXIT
wait