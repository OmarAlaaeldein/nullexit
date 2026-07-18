#!/bin/bash
# common.sh — shared bash utilities for nullexit scripts

# ─── Formatting ──────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Constants & Environment ───────────────────────────────────────────────────
export MARKER_FILE="/tmp/nullexit-gateway-active.marker"
export PID_CAFFEINATE="/tmp/nullexit-caffeinate.pid"
export PID_DNS_WATCHER="/tmp/nullexit-dns-watcher.pid"
export DEFAULT_WARP_ENDPOINT_1="162.159.192.1"
export DEFAULT_WARP_ENDPOINT_2="162.159.193.1"

setup_standard_path() {
  export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$PATH"
}

step() { echo -e "\n[$(date '+%Y-%m-%d %H:%M:%S')] ${BLUE}${BOLD}▶ $*${NC}"; }
ok()   { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')]   ${GREEN}✓ $*${NC}"; }
warn() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')]   ${YELLOW}⚠ $*${NC}"; }
fail() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')]   ${RED}✗ $*${NC}"; }
die()  { echo -e "\n[$(date '+%Y-%m-%d %H:%M:%S')]   ${RED}✗ $*${NC}\n"; exit 1; }

# ─── Helper Functions ────────────────────────────────────────────────────────

# Append a timestamped line to output.log (best-effort; never fails the caller).
# Used to record lifecycle breadcrumbs (EXEC/EXIT markers, phase changes) so a
# START/STOP that is killed or window-closed still leaves a retraceable trail.
log_line() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${LOG_FILE:-output.log}" 2>/dev/null || true
}

# Run a lifecycle command with FULL observability: log the command, stream its
# combined stdout+stderr to the terminal AND append it to output.log via tee,
# then log the exit code explicitly. Returns the command's real exit code (not
# tee's). This closes the blind spot where `docker compose up` / `colima start`
# printed only to the terminal — so when they fail (or the run is interrupted),
# output.log shows exactly what the last command was and whether it succeeded.
#
# Usage:  run_logged docker compose up -d --build
run_logged() {
  local logf="${LOG_FILE:-output.log}"
  log_line "EXEC: $*"
  # PIPESTATUS[0] is the command's exit code; tee (PIPESTATUS[1]) is ignored.
  "$@" 2>&1 | tee -a "$logf"
  local rc=${PIPESTATUS[0]}
  log_line "EXIT $rc: $*"
  return "$rc"
}

# Pure-bash timeout (no dependency on GNU coreutils' timeout)
# Runs a command with a safety cutoff so a wedged daemon can't hang the script.
run_with_timeout() {
  local timeout_sec="$1"
  shift
  if [ $# -eq 0 ]; then return 1; fi
  
  "$@" &
  local cmd_pid=$!
  CURRENT_BG_PID="$cmd_pid"
  
  (
    sleep "$timeout_sec"
    if kill -0 "$cmd_pid" 2>> output.log; then
      echo -e "\n[Timeout] Command '$*' exceeded $timeout_sec seconds. Terminating..." >&2
      kill -15 "$cmd_pid" 2>> output.log || true
      sleep 2
      if kill -0 "$cmd_pid" 2>> output.log; then
        kill -9 "$cmd_pid" 2>> output.log || true
      fi
    fi
  ) &
  local watcher_pid=$!
  
  # Disable set -e temporarily to capture exit status of wait
  set +e
  wait "$cmd_pid" 2>> output.log
  local exit_status=$?
  set -e
  
  # Kill the watcher since the command finished
  kill "$watcher_pid" 2>> output.log && wait "$watcher_pid" 2>> output.log || true
  
  CURRENT_BG_PID=""
  return "$exit_status"
}

# Start Colima and return the moment Docker is actually reachable, instead of
# blocking on colima 0.10.3's post-provision hang. Observed on macOS/vz: the VM
# reaches READY and creates the `colima` docker context in ~10-15s, then
# `colima start` frequently fails to return for ~110s (until a watchdog kills it)
# even though Docker is fully usable the entire time. We poll the colima docker
# context and proceed as soon as it answers, then reap the (usually hung) starter.
# The VM keeps running and `colima status` stays accurate. $@ = colima start args.
# Returns 0 once Docker responds, 1 if it never does within the cap.
colima_start_until_ready() {
  local max_wait=90 waited=0 ready=false start_pid
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] EXEC(bg): colima start $*" >> output.log
  colima start "$@" >> output.log 2>&1 &
  start_pid=$!
  while [ "$waited" -lt "$max_wait" ]; do
    if run_with_timeout 5 docker --context colima info >/dev/null 2>&1; then
      ready=true
      break
    fi
    # If colima start exited on its own (genuine finish or hard failure), stop waiting.
    if ! kill -0 "$start_pid" 2>/dev/null; then
      run_with_timeout 5 docker --context colima info >/dev/null 2>&1 && ready=true
      break
    fi
    sleep 3
    waited=$((waited + 3))
  done
  # Reap the starter (harmless if it already exited); this does NOT stop the VM.
  kill "$start_pid" 2>/dev/null || true
  wait "$start_pid" 2>/dev/null || true
  if [ "$ready" = "true" ]; then
    docker context use colima >/dev/null 2>&1 || true
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Colima Docker ready after ~${waited}s (starter reaped)." >> output.log
    return 0
  fi
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Colima Docker NOT ready after ${max_wait}s." >> output.log
  return 1
}

# Hash the files that feed the long-running locally-built images that `docker
# compose up` starts (routing-fix, tor). toggle.sh uses this to skip
# `docker compose --build` when nothing changed: BuildKit re-evaluating those
# images on the 600MB Colima VM costs ~30s per toggle even when every layer is
# CACHED (§15.8.8). Includes the Dockerfiles, everything they COPY (routing-fix.sh,
# tor/entrypoint.sh, the logger/ Go source), and docker-compose.yml. The
# rule-compiler image is NOT here — it is a `compile`-profiled one-off, built+run
# by the gated compile step (§15.8.8). Prints a sha256 hex digest, or empty.
compute_build_inputs_hash() {
  local root="${SCRIPT_DIR:-.}" f
  {
    for f in \
      "$root/scripts/Dockerfile.routing-fix" \
      "$root/scripts/routing-fix.sh" \
      "$root/docker/tor/Dockerfile" \
      "$root/docker/tor/entrypoint.sh" \
      "$root/docker-compose.yml"; do
      printf '::%s::' "$f"; cat "$f" 2>/dev/null
    done
    find "$root/scripts/logger" -type f 2>/dev/null \
      | LC_ALL=C sort | while IFS= read -r f; do printf '::%s::' "$f"; cat "$f" 2>/dev/null; done
  } | openssl dgst -sha256 2>/dev/null | awk '{print $NF}'
}

# Hash the ad-block lists the user controls: black_list.txt (custom blocks) and
# white_list.txt (the allow-list that governs what DNS resolves through). toggle.sh
# gates the ~28s rule recompile on this — editing either list changes the digest
# and triggers a one-off recompile of compiled_rules.txt + ip_blocklist.ipset;
# an unchanged toggle skips it entirely (§15.8.8). Prints a sha256 hex digest.
compute_rules_hash() {
  local root="${SCRIPT_DIR:-.}"
  { printf '::black::'; cat "$root/black_list.txt" 2>/dev/null
    printf '::white::'; cat "$root/white_list.txt" 2>/dev/null
  } | openssl dgst -sha256 2>/dev/null | awk '{print $NF}'
}

# Check if the gateway is active (either containers are running, or host DNS is hijacked)
is_gateway_active() {
  # 1. Check if containers are running (suppress stderr to avoid errors if docker is down)
  if run_with_timeout 15 docker compose ps --status running 2>/dev/null | grep -q 'warp'; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] is_gateway_active: TRUE (warp container is running)" >> "$LOG_FILE"
    return 0
  fi
  
  # 2. Check if host DNS was hijacked (not 1.1.1.1 and not default/empty)
  local current_dns=""
  local active_svc=""
  if [[ "$OSTYPE" == "darwin"* ]]; then
    active_svc=$(get_active_service)
    current_dns=$(networksetup -getdnsservers "$active_svc" 2>> output.log || true)
  else
    current_dns=$(resolvectl dns 2>/dev/null | awk '/Global|Link/ {for(i=4;i<=NF;i++) print $i}' | head -n1)
  fi

  if [[ -n "$current_dns" && "$current_dns" != "1.1.1.1" && ! "$current_dns" =~ "There aren't any DNS Servers" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] is_gateway_active: TRUE (DNS was hijacked: $current_dns)" >> "$LOG_FILE"
    return 0
  fi
  
  # 3. Check if SOCKS proxy is enabled (macOS only)
  if [[ "$OSTYPE" == "darwin"* ]]; then
    local socks_proxy
    socks_proxy=$(networksetup -getsocksfirewallproxy "$active_svc" 2>> output.log || true)
    if echo "$socks_proxy" | grep -q "Enabled: Yes"; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] is_gateway_active: TRUE (SOCKS proxy enabled)" >> "$LOG_FILE"
      return 0
    fi
  fi
  
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] is_gateway_active: FALSE (Containers down, DNS clean, SOCKS disabled)" >> "$LOG_FILE"
  return 1
}

# Decide whether the gateway SHOULD be running, from persisted *intent* rather
# than a live health probe. This is the correct signal for toggle.sh's
# STOP-vs-START decision: a disable should tear down whatever the last START
# left behind — it should NOT depend on whether Docker/Colima happens to be
# reachable right now.
#
# Why this exists: using is_gateway_active() for the decision means every toggle
# (including *disable*) runs `docker compose ps` first. When Colima is down the
# socket is absent, that call blocks for the full run_with_timeout window, and
# under `set -e` + the ERR trap a non-zero result at the `if … then … else … fi`
# boundary could abort the script BEFORE the START body runs — so the very path
# that would boot Colima never executed (observed as `EXIT: code=1 phase=start`).
#
# Signal source: MARKER_FILE is written at the end of a successful START
# (write_gateway_active_marker) and cleared at the top of STOP and in
# cleanup_handler. Reading it is instant and cannot hang or abort.
#
# ECHOES "running" or "stopped" to stdout (and ALWAYS returns 0). Callers read
# the string:  [ "$(gateway_state)" = "running" ] && …
#
# CRITICAL — why this echoes instead of using a 0/1 return code: on macOS
# /bin/bash 3.2, with `set -e` + an `ERR` trap + `set -x` (DEBUG_TRACE=true) all
# active, a function that does `return 1` triggers a SPURIOUS `set -e` abort in
# the caller even when the call is guarded (`if f; then`, or even `f || rc=$?`).
# The `return N` from the function, traced by `set -x`, trips the ERR trap. This
# is a genuine bash-3.2 interaction (see devref §15.11.8). Echoing a result and
# always returning 0 sidesteps `return`/`set -e`/`set -x` entirely — the function
# can never contribute a non-zero status, so no caller can be aborted by it.
gateway_state() {
  # Primary: persisted intent. Marker present => a START completed and no STOP
  # has cleared it yet.
  #
  # NOTE: toggle.sh runs a "defensive stale-marker clear" near the top of every
  # invocation (before this decision) to stop the wake-watcher firing against a
  # crashed gateway. That would wipe the marker before we read it, so toggle.sh
  # captures the marker's existence into GATEWAY_MARKER_AT_STARTUP *before* that
  # clear and we honor it here. If the variable is unset (other callers, or the
  # --restart pre-check which runs before the defensive clear), fall back to the
  # live marker file.
  if [ -n "${GATEWAY_MARKER_AT_STARTUP:-}" ]; then
    if [ "$GATEWAY_MARKER_AT_STARTUP" = "yes" ]; then echo "running"; return 0; fi
  elif [ -f "$MARKER_FILE" ]; then
    echo "running"; return 0
  fi

  # Marker absent. Normally this means "stopped". But cover the edge case where
  # the marker was lost (e.g. /tmp cleared, or gateway started by an older build)
  # yet containers are genuinely up — reconcile via is_gateway_active, but ONLY
  # when Docker is actually reachable, so a dead-socket probe can never hang. On
  # macOS Docker runs in the Colima VM; if that socket is absent, the gateway
  # definitively is not running.
  local docker_up="no"
  if [[ "$OSTYPE" == "darwin"* ]]; then
    if [ -S /var/run/docker.sock ] || [ -S "$HOME/.colima/default/docker.sock" ]; then docker_up="yes"; fi
  else
    if [ -S /var/run/docker.sock ]; then docker_up="yes"; fi
  fi

  if [ "$docker_up" = "yes" ] && is_gateway_active; then
    echo "running"; return 0
  fi
  echo "stopped"
  return 0
}

# Reads an environment variable from a file (default: .env), strips quotes and whitespace
read_env_var() {
  local var_name="$1"
  local env_file="${2:-.env}"
  grep -E "^${var_name}=" "$env_file" 2>/dev/null | cut -d'=' -f2- | tr -d "\"\\'" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || echo ""
}

# Load KILL_SWITCH variable from .env (defaults to false if not found/empty)
export KILL_SWITCH
KILL_SWITCH=$(read_env_var "KILL_SWITCH" 2>/dev/null | tr '[:upper:]' '[:lower:]')
if [ -z "$KILL_SWITCH" ]; then
  KILL_SWITCH="false"
fi

# Function to get the active network service name (e.g., "Wi-Fi" or "USB 10/100 LAN")
get_active_service() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    local iface
    iface=$(route get default 2>> output.log | awk '/interface:/ {print $2}')

    # If the default interface is empty or a VPN tunnel (like utunX), fallback to the active physical interface
    if [[ -z "$iface" || ! "$iface" =~ ^en[0-9]+$ ]]; then
      for i in en0 en1 en2 en3; do
        if ifconfig "$i" 2>> output.log | grep -q "status: active" && ifconfig "$i" 2>> output.log | grep -q "inet "; then
          iface="$i"
          break
        fi
      done
    fi

    # Default fallback if still empty or not enX
    if [[ -z "$iface" || ! "$iface" =~ ^en[0-9]+$ ]]; then
      iface="en0"
    fi

    # Map interface (e.g., en0) to service name (e.g., Wi-Fi)
    local service
    service=$(networksetup -listnetworkserviceorder 2>> output.log | grep -B 1 "Device: $iface" | head -n 1 | sed -E 's/^\([0-9\*]+\) //')

    if [ -n "$service" ]; then
      echo "$service"
    else
      echo "Wi-Fi"
    fi
  else
    # Get the interface used for default internet routing
    local iface
    iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')
    if [ -z "$iface" ]; then
      echo ""
      return 1
    fi
    echo "$iface"
  fi
}

get_en0_service() {
  local service
  service=$(networksetup -listnetworkserviceorder 2>> output.log | grep -B1 "Device: en0" | head -1 | sed -E 's/^\([0-9\*]+\) //' || true)
  if [ -z "$service" ]; then
    echo "Wi-Fi"
  else
    echo "$service"
  fi
}

get_warp_endpoint_1() { read_env_var "WARP_ENDPOINT_1" ".env" | grep -Eo '^[0-9\.]+' || echo "$DEFAULT_WARP_ENDPOINT_1"; }
get_warp_endpoint_2() { read_env_var "WARP_ENDPOINT_2" ".env" | grep -Eo '^[0-9\.]+' || echo "$DEFAULT_WARP_ENDPOINT_2"; }

restart_tailscaled_daemon() {
  echo "  [Tailscale Recovery] tailscaled daemon appears to be wedged/unresponsive."
  echo "  [Tailscale Recovery] Attempting to restart tailscaled service..."
  
  if run_with_timeout 15 brew services restart tailscale >> output.log 2>&1; then
    echo "  [Tailscale Recovery] Successfully restarted tailscaled (user service)."
  elif run_with_timeout 15 sudo -n brew services restart tailscale >> output.log 2>&1; then
    echo "  [Tailscale Recovery] Successfully restarted tailscaled (system service)."
  else
    echo "  [Tailscale Recovery] WARNING: Failed to restart tailscaled. Manual intervention may be needed."
  fi
  sleep 3
}

disconnect_tailscale_host() {
  local ts_bin="${1:-tailscale}"
  if command -v "$ts_bin" >> output.log 2>&1; then
    echo "  Disconnecting host Tailscale from mesh..."
    
    # Check if actually connected first (with timeout — tailscaled could be wedged)
    local status_ok=false
    if run_with_timeout 5 "$ts_bin" status >> output.log 2>&1; then
      status_ok=true
    else
      local status_exit=$?
      # If it was a quick exit code 1 (disconnected), it is still reachable
      if [ "$status_exit" -ne 143 ] && [ -S /var/run/tailscaled.socket ]; then
        status_ok=true
      fi
    fi

    if [ "$status_ok" = "false" ]; then
      restart_tailscaled_daemon
    fi

    # Explicitly reset any exit-node so it doesn't linger.
    "$ts_bin" up >> output.log 2>&1 || true
    if run_with_timeout 10 "$ts_bin" set --ssh=true --accept-dns=false --exit-node= >> output.log 2>&1; then
      echo "  [✓] Exit-node preference cleared."
    else
      echo "  [!] tailscale up didn't respond (tailscaled may be wedged)"
    fi
    
    local ts_args=""
    if is_kill_switch_enabled; then ts_args="--accept-risk=lose-ssh"; fi
    if run_with_timeout 10 "$ts_bin" down $ts_args >> output.log 2>&1; then
      echo "  [✓] Tailscale disconnected."
    else
      echo "  [!] tailscale down didn't respond"
    fi
  else
    echo "  [!] tailscale CLI not found — skipping"
  fi
}

stop_pidfile_daemon() {
  local pid_file="$1"
  local label="$2"
  if [ -f "$pid_file" ]; then
    local pid
    pid=$(cat "$pid_file")
    if kill -0 "$pid" 2>/dev/null; then
      echo "  Stopping $label (PID $pid)..."
      sudo -n kill "$pid" 2>> output.log || kill "$pid" 2>> output.log || true
      sleep 0.5
      if kill -0 "$pid" 2>/dev/null; then
        sudo -n kill -9 "$pid" 2>> output.log || kill -9 "$pid" 2>> output.log || true
      fi
    fi
    rm -f "$pid_file"
  fi
}

disable_all_proxies() {
  local svc="$1"
  if [ -n "$svc" ]; then
    sudo -n networksetup -setsocksfirewallproxystate "$svc" off 2>> output.log || true
    sudo -n networksetup -setwebproxystate "$svc" off 2>> output.log || true
    sudo -n networksetup -setsecurewebproxystate "$svc" off 2>> output.log || true
  fi
}

flush_dns_cache() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sudo -n dscacheutil -flushcache 2>> output.log || true
    sudo -n killall -HUP mDNSResponder 2>> output.log || true
  else
    resolvectl flush-caches 2>> output.log || true
  fi
}

wait_for_dhcp_settle() {
  # Resolve physical interface (Wi-Fi or Ethernet)
  local physical_iface
  physical_iface=$(networksetup -listallhardwareports 2>> output.log | awk '/Hardware Port: (Wi-Fi|Ethernet)/{getline; print $2; exit}')
  [ -z "$physical_iface" ] && physical_iface="en0"

  echo -n "Waiting for physical network interface ($physical_iface) DHCP lease to settle..."
  local settled=false
  for attempt in {1..60}; do
    PHYSICAL_GW=$(ipconfig getpacket "$physical_iface" 2>> output.log | awk -F'[{}]' '/router /{print $2}')
    local local_ip
    local_ip=$(ifconfig "$physical_iface" 2>/dev/null | awk '/inet /{print $2}')
    
    if [ -n "$PHYSICAL_GW" ] && [[ "$PHYSICAL_GW" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && \
       [ -n "$local_ip" ] && [[ "$local_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && \
       [[ "$local_ip" != "169.254."* ]]; then
      echo " settled (Interface IP: $local_ip, Router IP: $PHYSICAL_GW)."
      settled=true
      break
    fi
    
    if [ "$attempt" -gt 15 ] && [ -n "$local_ip" ] && [[ "$local_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ "$local_ip" != "169.254."* ]]; then
      local fallback_gw
      fallback_gw=$(route get default 2>> output.log | awk '/gateway:/ {print $2}')
      if [ -n "$fallback_gw" ] && [[ "$fallback_gw" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        PHYSICAL_GW="$fallback_gw"
      fi
      echo " static/settled detected (Interface IP: $local_ip, Gateway IP: ${PHYSICAL_GW:-unknown})."
      settled=true
      break
    fi
    echo -n "."
    sleep 0.5
  done
  if [ "$settled" = "false" ]; then
    echo " timed out or no active link. Proceeding anyway."
  fi
}

reset_sharing_services() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sudo -n killall sharingd rapportd 2>> output.log || true
  fi
}

read_adguard_ip() {
  if [ -f ".gateway_ip" ]; then
    tr -d '\r' < ".gateway_ip" | awk 'NR==1{print $1;exit}'
  fi
}

is_kill_switch_enabled() {
  [ "$KILL_SWITCH" = "true" ]
}

add_warp_bypass_routes() {
  local target="${1:-}"
  local ep1
  ep1=$(get_warp_endpoint_1)
  local ep2
  ep2=$(get_warp_endpoint_2)
  
  if [[ "$OSTYPE" == "darwin"* ]]; then
    local routing_arg=""
    local msg_via=""
    if [ -n "$target" ]; then
      if [[ "$target" =~ ^en[0-9]+$ || "$target" == "bridge"* ]]; then
        routing_arg="-interface $target"
        msg_via="interface $target"
      else
        routing_arg="$target"
        msg_via="gateway $target"
      fi
    else
      local gateway_ip
      gateway_ip=$(route get default 2>> output.log | awk '/gateway:/ {print $2}')
      if [ -z "$gateway_ip" ]; then
        local iface
        iface=$(route get default 2>> output.log | awk '/interface:/ {print $2}')
        if [[ -z "$iface" || ! "$iface" =~ ^en[0-9]+$ ]]; then
          iface="en0"
        fi
        routing_arg="-interface $iface"
        msg_via="interface $iface"
      else
        routing_arg="$gateway_ip"
        msg_via="gateway $gateway_ip"
      fi
    fi
    
    echo -e "\nAdding host bypass routes for Cloudflare WARP endpoints via $msg_via..."
    sudo -n route delete -host "$ep1" 2>/dev/null || true
    sudo -n route delete -host "$ep2" 2>/dev/null || true
    sudo -n route add -host "$ep1" $routing_arg >> output.log 2>&1 || true
    sudo -n route add -host "$ep2" $routing_arg >> output.log 2>&1 || true
    
    echo -e "Adding host bypass routes for Tailscale control plane via $msg_via..."
    sudo -n route delete -net 192.200.0.0/24 2>/dev/null || true
    sudo -n route add -net 192.200.0.0/24 $routing_arg >> output.log 2>&1 || true

    echo -e "Adding host bypass routes for Tailscale DERP relays via $msg_via..."
    local derp_ips
    derp_ips=$(curl -s --connect-timeout 5 https://login.tailscale.com/derpmap/default | grep -oE '"IPv4"[[:space:]]*:[[:space:]]*"[0-9.]+"' | cut -d'"' -f4 | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
    if [ -n "$derp_ips" ]; then
      echo "$derp_ips" > /tmp/nullexit-derp-ips.txt
      for ip in $derp_ips; do
        sudo -n route delete -host "$ip" 2>/dev/null || true
        sudo -n route add -host "$ip" $routing_arg >> output.log 2>&1 || true
      done
    fi
  else
    local gateway_ip="${target}"
    if [ -z "$gateway_ip" ]; then
      gateway_ip=$(ip route show default 2>/dev/null | awk '/default/ {print $3}')
    fi
    if [ -n "$gateway_ip" ]; then
      sudo ip route add "$ep1" via "$gateway_ip" >> output.log 2>&1 || true
      sudo ip route add "$ep2" via "$gateway_ip" >> output.log 2>&1 || true
    fi
  fi
}

remove_warp_bypass_routes() {
  local ep1
  ep1=$(get_warp_endpoint_1)
  local ep2
  ep2=$(get_warp_endpoint_2)
  
  if [[ "$OSTYPE" == "darwin"* ]]; then
    echo -e "\nRemoving host bypass routes for Cloudflare WARP endpoints..."
    sudo -n route delete -host "$ep1" >> output.log 2>&1 || true
    sudo -n route delete -host "$ep2" >> output.log 2>&1 || true
    echo -e "Removing host bypass routes for Tailscale control plane..."
    sudo -n route delete -net 192.200.0.0/24 >> output.log 2>&1 || true
    if [ -f /tmp/nullexit-derp-ips.txt ]; then
      echo -e "Removing host bypass routes for Tailscale DERP relays..."
      while read -r ip; do
        sudo -n route delete -host "$ip" >> output.log 2>&1 || true
      done < /tmp/nullexit-derp-ips.txt
      rm -f /tmp/nullexit-derp-ips.txt
    fi
  else
    sudo ip route del "$ep1" >> output.log 2>&1 || true
    sudo ip route del "$ep2" >> output.log 2>&1 || true
  fi
}

# ─── FaceTime / real-time P2P split-route (opt-in, default OFF) ──────────────
# Mitigation for the FaceTime Double-Tunnel bug (§15.12.22). Adds more-specific
# host routes for Apple's FaceTime media/relay /16s via the PHYSICAL gateway, so
# longest-prefix match beats the exit-node 0.0.0.0/1 + 128.0.0.0/1 and ONLY those
# /16s leave direct — real-time media can then hole-punch from the real IP instead
# of dying behind WARP's symmetric NAT. Mirrors add_warp_bypass_routes.
#
# ⚠️ PRIVACY: the direct /16s expose the real ISP IP (not WARP) for that traffic —
# a deliberate, narrow hole in the Double-Tunnel promise, scoped to Apple infra
# (which already ties traffic to your Apple ID). Inert unless FACETIME_SPLIT_ROUTE
# =true. Needs BOTH a route AND a PF pass: 'block out on en0 all' would otherwise
# drop the packets, so we populate the <apple_direct> table pf.conf permits.
facetime_split_enabled() {
  [ "$(read_env_var FACETIME_SPLIT_ROUTE | tr '[:upper:]' '[:lower:]')" = "true" ]
}

facetime_direct_subnets() {
  local s; s=$(read_env_var FACETIME_DIRECT_SUBNETS)
  echo "${s:-17.249.0.0/16}"
}

add_apple_split_routes() {
  facetime_split_enabled || return 0
  [[ "$OSTYPE" == "darwin"* ]] || return 0
  local gw="${1:-}"
  if [ -z "$gw" ]; then
    # The physical default route survives alongside the exit-node /1 override,
    # so the real gateway is still the 'default' entry in the table.
    gw=$(netstat -rn -f inet 2>/dev/null | awk '$1=="default"{print $2; exit}')
  fi
  if [ -z "$gw" ] || [[ "$gw" =~ ^utun ]] || [[ "$gw" =~ ^link ]]; then
    echo "  [FaceTime split-route] could not resolve a physical gateway — skipping."
    return 0
  fi
  local subnets; subnets=$(facetime_direct_subnets)
  echo -e "\n[FaceTime split-route] routing Apple subnets DIRECT via $gw (real IP exposed for these): $subnets"
  for net in $subnets; do
    sudo -n route delete -net "$net" >> output.log 2>&1 || true
    sudo -n route add -net "$net" "$gw" >> output.log 2>&1 || true
    # Kill-switch pass: the <apple_direct> table is what pf.conf lets out on en0.
    sudo -n pfctl -a com.apple/nullexit -t apple_direct -T add "$net" >> output.log 2>&1 || true
  done
}

remove_apple_split_routes() {
  [[ "$OSTYPE" == "darwin"* ]] || return 0
  local subnets; subnets=$(facetime_direct_subnets)
  for net in $subnets; do
    sudo -n route delete -net "$net" >> output.log 2>&1 || true
  done
  # Flush the whole table so no direct Apple exception lingers after teardown.
  sudo -n pfctl -a com.apple/nullexit -t apple_direct -T flush >> output.log 2>&1 || true
}

bounce_wifi_interfaces() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    local wifi_port
    wifi_port=$(networksetup -listallhardwareports 2>> output.log | awk '/Hardware Port: Wi-Fi/{getline; print $2}')
    if [ -n "$wifi_port" ]; then
      sudo -n networksetup -setairportpower "$wifi_port" off 2>> output.log || true
      sleep 2
      sudo -n networksetup -setairportpower "$wifi_port" on 2>> output.log || true
      echo "Wi-Fi bounced (interface $wifi_port)"
      sleep 3
    else
      echo "Could not detect Wi-Fi interface. Bouncing fallback interfaces..."
      set +e
      for iface in en0 en1 en2 en3 en4 en5; do
        if ifconfig "$iface" >> output.log 2>&1; then
          sudo -n ifconfig "$iface" down 2>> output.log || true
          sudo -n ifconfig "$iface" up 2>> output.log || true
        fi
      done
      set -e
      echo "Fallback interfaces bounced"
    fi
  fi
}

get_active_interface() {
  local iface
  iface=$(route get default 2>> output.log | awk '/interface:/ {print $2}')
  
  # If the default interface is empty or a VPN tunnel (like utunX), fallback to the active physical interface
  if [[ -z "$iface" || ! "$iface" =~ ^en[0-9]+$ ]]; then
    for i in en0 en1 en2 en3; do
      if ifconfig "$i" 2>> output.log | grep -q "status: active" && ifconfig "$i" 2>> output.log | grep -q "inet "; then
        iface="$i"
        break
      fi
    done
  fi

  # Default fallback if still empty or not enX
  if [[ -z "$iface" || ! "$iface" =~ ^en[0-9]+$ ]]; then
    iface="en0"
  fi

  echo "$iface"
}

enable_killswitch() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    if ! is_kill_switch_enabled; then
      return 0
    fi

    local ext_if
    ext_if=$(get_active_interface)
    local ep1
    ep1=$(get_warp_endpoint_1)
    local ep2
    ep2=$(get_warp_endpoint_2)
    local pf_conf_path
    pf_conf_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pf.conf"

    # Keep the host's scrub max-mss in sync with GATEWAY_MSS (same variable that drives
    # post-rules.txt's --set-mss for the container). The host egresses through the same
    # double-tunnel (Tailscale+WARP) as forwarded phone traffic, so it needs the same
    # empirically-safe clamp — a stale/higher value here reproduces the §15.3.2 stalling
    # bug for the host's own connections (see devref.md).
    local gateway_mss
    gateway_mss=$(read_env_var GATEWAY_MSS)
    if [[ "$gateway_mss" =~ ^[0-9]+$ ]]; then
      sed -i '' "s/max-mss [0-9]*/max-mss ${gateway_mss}/g" "$pf_conf_path" 2>/dev/null || true
    fi

    echo -e "\nEnabling macOS Packet Filter (PF) Kill-Switch on $ext_if..."

    # Enable PF and capture the reference token
    local token_out
    token_out=$(sudo -n pfctl -E 2>> output.log || true)
    local token
    token=$(echo "$token_out" | awk '/Token/{print $NF}')
    if [ -n "$token" ]; then
      echo "$token" > /tmp/nullexit-pf-token.txt
      echo "  [✓] PF enabled with token $token."
    else
      echo "  [!] WARNING: Could not capture PF reference token (may already be enabled or sudo failed)."
    fi

    # Load the rules into the anchor
    if sudo -n pfctl -D "ext_if=$ext_if" -a com.apple/nullexit -f "$pf_conf_path" >> output.log 2>&1; then
      echo "  [✓] Ruleset loaded into anchor com.apple/nullexit."
    else
      echo "  [!] ERROR: Failed to load ruleset into anchor."
    fi

    # Populate tables in the anchor
    sudo -n pfctl -a com.apple/nullexit -t vpn_endpoints -T flush >> output.log 2>&1 || true
    sudo -n pfctl -a com.apple/nullexit -t vpn_endpoints -T add "$ep1" >> output.log 2>&1 || true
    sudo -n pfctl -a com.apple/nullexit -t vpn_endpoints -T add "$ep2" >> output.log 2>&1 || true

    if [ -f /tmp/nullexit-derp-ips.txt ]; then
      local derp_ips
      derp_ips=$(tr '\n' ' ' < /tmp/nullexit-derp-ips.txt)
      if [ -n "$derp_ips" ]; then
        sudo -n pfctl -a com.apple/nullexit -t derp_relays -T flush >> output.log 2>&1 || true
        sudo -n pfctl -a com.apple/nullexit -t derp_relays -T add $derp_ips >> output.log 2>&1 || true
      fi
    fi
    echo "  [✓] Kill-switch tables populated."
  fi
}

disable_killswitch() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    if ! is_kill_switch_enabled; then
      return 0
    fi
    echo -e "\nDisabling macOS PF Kill-Switch..."

    # Flush rules from anchor com.apple/nullexit
    sudo -n pfctl -a com.apple/nullexit -F all >> output.log 2>&1 || true

    # Release the enable reference if token is present
    if [ -f /tmp/nullexit-pf-token.txt ]; then
      local token
      token=$(cat /tmp/nullexit-pf-token.txt)
      if [ -n "$token" ]; then
        sudo -n pfctl -X "$token" >> output.log 2>&1 || true
        echo "  [✓] Released PF enable reference token $token."
      fi
      rm -f /tmp/nullexit-pf-token.txt
    else
      echo "  [✓] Rules flushed from anchor com.apple/nullexit."
    fi
  fi
}


write_host_ips() {
  # Gather all active IPv4 addresses on the host and write to .host_ips
  # routing-fix.sh will read this file to explicitly whitelist them for direct Tailscale P2P
  local repo_dir
  repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  
  if [[ "$OSTYPE" == "darwin"* ]]; then
    ifconfig | awk '/inet /{print $2}' | grep -v '127.0.0.1' > "$repo_dir/.host_ips" 2>/dev/null || true
  else
    ip -4 addr show 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | grep -v '127.0.0.1' > "$repo_dir/.host_ips" 2>/dev/null || true
  fi
}

start_dns_watcher() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    local target_ip=$1
    stop_pidfile_daemon "/tmp/nullexit-dns-watcher.pid" "background DNS Watcher"
    echo "  Starting background DNS Watcher for seamless Wi-Fi roaming..."
    nohup bash -c "
      source \"$SCRIPT_DIR/scripts/common.sh\"
      trap 'exit 0' SIGTERM SIGINT SIGHUP
      while true; do
        ACTIVE_IF=\$(get_active_service)
        if [ -n \"\$ACTIVE_IF\" ]; then
          CURRENT_DNS=\$(networksetup -getdnsservers \"\$ACTIVE_IF\" 2>/dev/null)
          if [ \"\$CURRENT_DNS\" != \"$target_ip\" ]; then
            networksetup -setdnsservers \"\$ACTIVE_IF\" \"$target_ip\" >/dev/null 2>&1
          fi
        fi
        sleep 30
      done
    " >> output.log 2>&1 &
    echo $! > "$DNS_WATCHER_PID_FILE"
  else
    local target_ip=$1
    stop_dns_watcher
    echo "  Starting background DNS Watcher for seamless Wi-Fi roaming..."
    nohup bash -c "
      trap 'exit 0' SIGTERM SIGINT SIGHUP
      while true; do
        if [ -n \"\$ACTIVE_SERVICE\" ]; then
          CURRENT_DNS=\$(resolvectl dns \"\$ACTIVE_SERVICE\" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
          if [ \"\$CURRENT_DNS\" != \"$target_ip\" ]; then
            resolvectl dns \"\$ACTIVE_SERVICE\" \"$target_ip\" >/dev/null 2>&1 || true
          fi
        fi
        sleep 30
      done
    " >> output.log 2>&1 &
    echo $! > "$DNS_WATCHER_PID_FILE"
  fi
}

# ─── SOCKS5 Proxy (WARP Tunnel) ────────────────────────────────────────────
# When Tailscale's exit node can't route through WARP (due to userspace
# forwarding), we use a SOCKS5 proxy running inside the warp container's
# network namespace. Connections created by this proxy go through the
# kernel routing table (table 200 -> tun0 -> WARP), unlike Tailscale's
# userspace exit node which bypasses it.
#
# The SOCKS5 proxy is exposed on localhost:${SOCKS_PROXY_PORT} via Docker port mapping.
# `networksetup -setsocksfirewallproxy` on macOS routes system TCP traffic
# through the proxy, which then goes through WARP.
#
# IMPORTANT: CLI tools like curl do NOT respect macOS system proxy settings.
# They must use --socks5-hostname or the ALL_PROXY env variable explicitly.

enable_socks_proxy() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    local svc="$1"
    if [ -z "$svc" ]; then
      svc="$ACTIVE_SERVICE"
    fi

    echo -n "  Enabling system-wide SOCKS5 proxy on $svc (localhost:$SOCKS_PROXY_PORT)... "
    sudo -n networksetup -setsocksfirewallproxy "$svc" 127.0.0.1 $SOCKS_PROXY_PORT 2>> output.log || true
    sudo -n networksetup -setsocksfirewallproxystate "$svc" on 2>> output.log || true

    # Also set on en0 service for macOS resolver consistency
    if [ "$svc" != "$EN0_SERVICE" ]; then
      sudo -n networksetup -setsocksfirewallproxy "$EN0_SERVICE" 127.0.0.1 $SOCKS_PROXY_PORT 2>> output.log || true
      sudo -n networksetup -setsocksfirewallproxystate "$EN0_SERVICE" on 2>> output.log || true
    fi

    # IMPORTANT: Exclude local LAN and mDNS traffic from the proxy so P2P works natively
    # without source-IP masking from the Colima VM bridge.
    sudo -n networksetup -setproxybypassdomains "$svc" 127.0.0.1 localhost 192.168.0.0/16 10.0.0.0/8 172.16.0.0/12 "*.local" 2>> output.log || true
    if [ "$svc" != "$EN0_SERVICE" ]; then
      sudo -n networksetup -setproxybypassdomains "$EN0_SERVICE" 127.0.0.1 localhost 192.168.0.0/16 10.0.0.0/8 172.16.0.0/12 "*.local" 2>> output.log || true
    fi

    echo "done."
    echo "  All TCP traffic now routed through gateway -> WARP tunnel -> internet."
    echo "  (CLI tools: export ALL_PROXY=socks5://127.0.0.1:$SOCKS_PROXY_PORT)"
  else
    local svc="$1"
    echo "  (Linux global SOCKS proxy configuration is desktop-environment specific, skipping.)"
    echo "  SOCKS5 proxy is active and listening on 127.0.0.1:$SOCKS_PROXY_PORT"
  fi
}

disable_socks_proxy() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    for svc in "$ACTIVE_SERVICE" "$EN0_SERVICE"; do
      sudo -n networksetup -setsocksfirewallproxystate "$svc" off 2>> output.log || true
    done
    echo "  SOCKS5 proxy disabled."
  else
    local svc="$1"
    echo "  (Linux global SOCKS proxy configuration skipped.)"
  fi
}

# Helper to restore host DNS to a clean state (used on script start, on failure,
# and after a successful STOP). Without this, a successful toggle-off leaves the
# host's resolver pinned to a now-dead gateway IP — every lookup stalls for macOS's
# DNS timeout (~5s) before falling through to whatever next server is configured.
# With it, we always leave the host in `1.1.1.1 / no search domain`.
#
# We set DNS on BOTH the active service AND the en0 service because macOS's scutil DNS
# resolver is commonly scoped to en0 (Wi-Fi). A per-service change on e.g.
# "USB 10/100 LAN" is ignored by the system resolver unless the en0 service is also updated.
reset_dns() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    if [ -n "$ACTIVE_SERVICE" ]; then
      for dns_svc in "$ACTIVE_SERVICE" "$EN0_SERVICE"; do
        networksetup -setsearchdomains "$dns_svc" "Empty" 2>> output.log || true
        networksetup -setdnsservers "$dns_svc" 1.1.1.1 2>> output.log || true
      done
    fi
  else
    if [ -n "$ACTIVE_SERVICE" ]; then
      resolvectl domain "$ACTIVE_SERVICE" "" 2>/dev/null || true
      resolvectl revert "$ACTIVE_SERVICE" 2>/dev/null || true
    fi
  fi
}

# Verify basic direct-internet connectivity after a recovery/teardown: DNS via
# 1.1.1.1, then HTTP (curl) or ping to 1.1.1.1. Sets the global INTERNET_OK to
# "true" on any successful check (callers read $INTERNET_OK in their summary).
# Always returns 0 so a bare call can't trip `set -e`. Used by recover.sh's macOS
# and Linux recovery paths (extracted from a formerly-duplicated block).
verify_internet_connectivity() {
  step "Verifying internet connectivity"

  # Wait a moment for the network to settle
  sleep 2

  INTERNET_OK=false

  # Try DNS resolution first
  if host -W 3 google.com 1.1.1.1 >> output.log 2>&1; then
    ok "DNS resolution works (google.com via 1.1.1.1)"
    INTERNET_OK=true
  elif nslookup google.com 1.1.1.1 >> output.log 2>&1; then
    ok "DNS resolution works (nslookup google.com via 1.1.1.1)"
    INTERNET_OK=true
  else
    warn "DNS resolution check failed — will still try ping/curl"
  fi

  # Try actual HTTP connectivity
  if command -v curl >> output.log 2>&1; then
    if curl -sf --max-time 5 https://1.1.1.1 >> output.log 2>&1; then
      ok "Internet reachable via HTTP"
      INTERNET_OK=true
    elif curl -sf --max-time 5 http://1.1.1.1 >> output.log 2>&1; then
      ok "Internet reachable via HTTP (plain)"
      INTERNET_OK=true
    else
      warn "HTTP check failed"
    fi
  elif command -v ping >> output.log 2>&1; then
    if ping -c 1 -W 3 1.1.1.1 >> output.log 2>&1; then
      ok "Internet reachable via ping"
      INTERNET_OK=true
    else
      warn "Ping check failed"
    fi
  fi

  return 0
}

# ─── Local DNS Proxy (Python) ───────────────────────────────────────────────
# When the tailnet data plane cannot establish, we use a Python DNS proxy.
# It listens on UDP:53, receives DNS queries, forwards them over TCP to
# AdGuard at 127.0.0.1:${DNS_PROXY_PORT} (Docker port mapping), and returns the response.
# The Python script handles the DNS-over-TCP wire format (2-byte length prefix)
# correctly — unlike socat which just forwards raw bytes.
#
# Python3 is built into macOS — no external dependencies.
DNS_PROXY_PID=""

# Kill any leftover DNS proxy process
stop_local_dns_proxy() {
  if [ -n "$DNS_PROXY_PID" ]; then
    kill "$DNS_PROXY_PID" 2>/dev/null || true
    wait "$DNS_PROXY_PID" 2>/dev/null || true
    DNS_PROXY_PID=""
  fi
  # Clean up any stale Python DNS proxy processes
  sudo -n pkill -f "dns-proxy.py" 2>/dev/null || true
}

# Start local DNS proxy (Python)
start_local_dns_proxy() {
  if [ -z "$DNS_PROXY_BIN" ]; then
    echo "  Python not found. Python3 is built into macOS — this shouldn't happen."
    return 1
  fi

  if [ ! -f "$DNS_PROXY_SCRIPT" ]; then
    echo "  DNS proxy script not found at $DNS_PROXY_SCRIPT"
    return 1
  fi

  # Kill any leftover process first
  stop_local_dns_proxy

  echo -n "  Starting local DNS proxy via Python (UDP:53 → TCP:${DNS_PROXY_PORT})... "
  sudo -n bash -c "TARGET_PORT=$DNS_PROXY_PORT \"$DNS_PROXY_BIN\" \"$DNS_PROXY_SCRIPT\"" &
  DNS_PROXY_PID=$!
  disown "$DNS_PROXY_PID" 2>/dev/null || true

  # Give it a moment to bind
  sleep 0.5

  if kill -0 "$DNS_PROXY_PID" 2>/dev/null; then
    echo "started (PID $DNS_PROXY_PID)."

    # Hijack host DNS to localhost
    echo -n "  Hijacking host DNS to 127.0.0.1 for ad-blocking... "
    if [[ "$OSTYPE" == "darwin"* ]]; then
      networksetup -setsearchdomains "$ACTIVE_SERVICE" "Empty" 2>/dev/null || true
      networksetup -setsearchdomains "$EN0_SERVICE" "Empty" 2>/dev/null || true
      if ! networksetup -setdnsservers "$ACTIVE_SERVICE" 127.0.0.1; then
        echo "FAILED (networksetup error — check permissions)."
        stop_local_dns_proxy
        return 1
      fi
      networksetup -setdnsservers "$EN0_SERVICE" 127.0.0.1 2>/dev/null || true
      sudo -n dscacheutil -flushcache 2>/dev/null || true
      sudo -n killall -HUP mDNSResponder 2>/dev/null || true
    else
      resolvectl domain "$ACTIVE_SERVICE" "" 2>/dev/null || true
      resolvectl domain "$ACTIVE_SERVICE" "" 2>/dev/null || true
      if ! sudo -n resolvectl dns "$ACTIVE_SERVICE" 127.0.0.1; then
        echo "FAILED (resolvectl error — check permissions)."
        stop_local_dns_proxy
        return 1
      fi
      resolvectl dns "$ACTIVE_SERVICE" 127.0.0.1 2>/dev/null || true
      sudo -n resolvectl flush-caches 2>/dev/null || true
    fi

    # Verify DNS actually works through the proxy
    echo -n "  Verifying DNS resolution... "
    if dig @127.0.0.1 google.com +short +timeout=5 &>/dev/null; then
      echo "ok."
      return 0
    else
      echo "FAILED (DNS queries not reaching AdGuard)."
      echo "  Restoring DNS to 1.1.1.1..."
      reset_dns
      stop_local_dns_proxy
      return 1
    fi
  else
    echo "FAILED (could not bind port 53 — is it in use?)."
    DNS_PROXY_PID=""
    return 1
  fi
}

# Helper to FORCIBLY hijack host DNS to a single server (the gateway's AdGuard IP)
# and VERIFY via `networksetup -getdnsservers` that the only name server is exactly
# $1. Returns 0 iff the live state matches; non-zero if it can't be confirmed.
#
# This deliberately does NOT append a 1.1.1.1 fallback: macOS's resolver queries
# the list in order and falls back to the next entry on timeout, so on a
# misbehaving AdGuard (filter compile crash, OOM kill, etc.) the resolver still
# leaks to 1.1.1.1 and silently bypasses ad-blocking. With no fallback, a broken
# gateway manifests as a *visible* DNS outage that prompts the user to
# investigate — which is the correct failure mode.
force_dns_to_gateway() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    local target_ip="$1"
    if [ -z "$target_ip" ] || [ -z "$ACTIVE_SERVICE" ]; then
      echo "  [force_dns] ERROR: target_ip or ACTIVE_SERVICE is empty" >&2
      return 1
    fi

    local attempt
    for attempt in 1 2 3; do
      echo -n "  [force_dns] Attempt $attempt/3: setting DNS to $target_ip on \"$ACTIVE_SERVICE\" + \"$EN0_SERVICE\"... "

      # Apply to BOTH the active service AND the en0 service — the scutil DNS resolver
      # is scoped to en0 (Wi-Fi) and ignores per-service changes that don't include it.
      # Fail fast on ACTIVE_SERVICE; best-effort on EN0_SERVICE (it may not exist).
      networksetup -setsearchdomains "$ACTIVE_SERVICE" "ts.net" || true
      if ! networksetup -setdnsservers "$ACTIVE_SERVICE" "$target_ip"; then
        echo "FAILED (networksetup error — check permissions)"
        sleep 1
        continue
      fi
      networksetup -setsearchdomains "$EN0_SERVICE" "ts.net" || true
      networksetup -setdnsservers "$EN0_SERVICE" "$target_ip" || true

      local entries
      entries=$(networksetup -getdnsservers "$ACTIVE_SERVICE" 2>> output.log \
                | awk '/^(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$/ {print}')
      if echo "$entries" | grep -qFx "$target_ip"; then
        echo "VERIFIED"
        return 0
      fi

      local current
      current=$(echo "$entries" | tr '\n' ' ' | sed 's/ $//')
      echo "NOT YET (current DNS: [${current:-none}])"

      if [ "$attempt" = "3" ]; then sleep 2; else sleep 1; fi
    done

    echo "  [force_dns] FAILED after 3 attempts"
    return 1
  else
    local target_ip="$1"

    for attempt in {1..3}; do
      echo -n "  [force_dns] Attempt $attempt/3: setting DNS to $target_ip on $ACTIVE_SERVICE... "
      sudo -n resolvectl domain "$ACTIVE_SERVICE" "~ts.net" 2>/dev/null || true
      if ! sudo -n resolvectl dns "$ACTIVE_SERVICE" "$target_ip"; then
        echo "FAILED (resolvectl error)"
      else
        # Verify
        entries=$(resolvectl dns "$ACTIVE_SERVICE" 2>> output.log | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
        if [ "$entries" == "$target_ip" ]; then
          echo "VERIFIED"
          return 0
        else
          echo "MISMATCH (Resolver refused lock)"
        fi
      fi
      sleep 2
    done
    return 1
  fi
}
