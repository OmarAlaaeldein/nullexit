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
    if run_with_timeout 10 "$ts_bin" up --reset --ssh=true --accept-dns=false --exit-node= >> output.log 2>&1; then
      echo "  [✓] Exit-node preference cleared."
    else
      echo "  [!] tailscale up --reset didn't respond (tailscaled may be wedged)"
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

reset_sharing_services() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sudo -n killall sharingd rapportd 2>> output.log || true
  fi
}

read_adguard_ip() {
  if [ -f "ADGUARD_IP.txt" ]; then
    tr -d '\r' < "ADGUARD_IP.txt" | awk 'NR==1{print $1;exit}'
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

