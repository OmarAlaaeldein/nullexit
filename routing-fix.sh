#!/bin/sh
# routing-fix: Maintains routing for SOCKS5 proxy traffic through WARP (tun0)
#              and FORWARD rules for Tailscale exit-node return traffic.
#
# Runs inside the warp container's network namespace. This script ensures:
# 1. Table 200 has default via tun0 (for SOCKS5 proxy traffic from 172.18.0.2)
#    with the WARP endpoint exception via eth0 (prevents tunnel loop)
# 2. The CGNAT ip rule (100.64.0.0/10 → table 52 → tailscale routes) is maintained for Tailscale
# 3. FORWARD RELATED,ESTABLISHED rule allows return traffic for exit-node
#    forwarded connections (S24 → tailscale0 → eth0 → host → internet)
#
# CRITICAL: Does NOT touch the main table's default route. Gluetun handles that
# internally via its own routing rules and WireGuard fwmark (0xca6c → table 51820).
# Overriding the main table default would create a loop: encrypted WireGuard
# packets exiting tun0 would match default dev tun0 and re-enter the tunnel.

set -e

sleep 5

echo "routing-fix: Setting up routing for SOCKS5 proxy through WARP (tun0)..."

# Dynamically detect Docker subnet from eth0
DOCKER_NET=$(ip route show dev eth0 | grep -v default | head -1 | awk '{print $1}')
DOCKER_GW=$(ip route show default | head -1 | awk '{print $3}')
WARP_ENDPOINT=${WARP_ENDPOINT:-162.159.192.1}
IP_BLOCKLIST_FILE="/userfilters/ip_blocklist.ipset"
LAST_IP_MTIME=""
echo "routing-fix: Docker network: ${DOCKER_NET}, gateway: ${DOCKER_GW}"

# Table 200: Used by ip rule 100 (from 172.18.0.2) for SOCKS5 proxy traffic
# WARP endpoint goes via eth0 to avoid tunnel loop, everything else via tun0
ip route add "${WARP_ENDPOINT}" via "${DOCKER_GW}" dev eth0 table 200 2>/dev/null || \
  ip route replace "${WARP_ENDPOINT}" via "${DOCKER_GW}" dev eth0 table 200 2>/dev/null || true
ip route replace default dev tun0 table 200 2>/dev/null || true

# Main table: Just ensure the Docker subnet route exists via eth0
# (gluetun owns the default route here — do NOT touch it)
ip route replace "${DOCKER_NET}" dev eth0 2>/dev/null || true

# FORWARD RELATED,ESTABLISHED: Allow return traffic for exit-node connections.
# The container has BOTH iptables (nftables backend) and iptables-legacy
# loaded. Gluetun's post-rules.txt uses the nftables backend, while Tailscale
# uses the legacy backend. Packets go through BOTH stacks, so we add the rule
# to both to ensure it survives regardless of which backend has policy DROP.
#
# Packet flow: S24 outgoing (tailscale0->eth0) ACCEPTed by first rule.
# Return traffic (eth0->eth0 via table 199 to host) needs RELATED,ESTABLISHED
# to match the conntrack entry created by the outgoing flow.
add_fwd_related_established() {
  # nftables backend (used by gluetun's post-rules.txt)
  if ! iptables -C FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
    iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
  fi
  # legacy backend (used by Tailscale's ts-forward)
  if command -v iptables-legacy >/dev/null 2>&1; then
    if ! iptables-legacy -C FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
      iptables-legacy -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    fi
  fi
}

add_fwd_related_established

# Policy Routing for Tailscale P2P:
# Tailscale sends its encrypted mesh UDP packets from port 41641.
# If these go out tun0 (WARP), Cloudflare's strict NAT drops the returning
# hole-punch packets, causing Tailscale to fail P2P and fall back to DERP relays (high latency).
# We mark packets originating from port 41641 and force them out the main table (eth0).
add_tailscale_p2p_bypass() {
  if ! iptables -t mangle -C OUTPUT -p udp --sport 41641 -j MARK --set-mark 0x8888 2>/dev/null; then
    iptables -t mangle -A OUTPUT -p udp --sport 41641 -j MARK --set-mark 0x8888 2>/dev/null || true
  fi
  if ! ip rule show | grep -q 'fwmark 0x8888'; then
    ip rule add fwmark 0x8888 lookup 254 pref 98 2>/dev/null || true
  fi
}

add_tailscale_p2p_bypass

add_country_block() {
  # Create the ipset if it doesn't exist
  if ! ipset list block_kp >/dev/null 2>&1; then
    ipset create block_kp hash:net 2>/dev/null || true
    echo "routing-fix: Downloading North Korea IPs for blocklist..."
    curl -sS "http://www.ipdeny.com/ipblocks/data/countries/kp.zone" | grep -v '^#' | while read -r subnet; do
      [ -n "$subnet" ] && ipset add block_kp "$subnet" 2>/dev/null || true
    done
  fi

  # Apply DROP rule to nftables backend
  if ! iptables -C FORWARD -m set --match-set block_kp dst -j DROP 2>/dev/null; then
    iptables -I FORWARD -m set --match-set block_kp dst -j DROP 2>/dev/null || true
  fi
  # Apply DROP rule to legacy backend
  if command -v iptables-legacy >/dev/null 2>&1; then
    if ! iptables-legacy -C FORWARD -m set --match-set block_kp dst -j DROP 2>/dev/null; then
      iptables-legacy -I FORWARD -m set --match-set block_kp dst -j DROP 2>/dev/null || true
    fi
  fi
}

add_ip_blocklist() {
  # Only reload when the compiled file has actually changed (mtime check).
  # This prevents a pointless ipset restore on every 5-second loop tick.
  if [ ! -f "$IP_BLOCKLIST_FILE" ]; then
    return 0
  fi

  CURRENT_MTIME=$(stat -c %Y "$IP_BLOCKLIST_FILE" 2>/dev/null || echo "0")
  if [ "$CURRENT_MTIME" = "$LAST_IP_MTIME" ]; then
    return 0
  fi

  echo "routing-fix: IP blocklist changed, reloading..."

  # ipset restore handles the atomic swap internally:
  # create_new → populate → swap with live → destroy_new
  if ipset restore < "$IP_BLOCKLIST_FILE" 2>/dev/null; then
    LAST_IP_MTIME="$CURRENT_MTIME"
    echo "routing-fix: IP blocklist loaded ($(ipset list block_malicious | grep -c '^[0-9]') entries)."
  else
    echo "routing-fix: Warning: ipset restore failed. Retrying next cycle."
    return 1
  fi

  # Apply FORWARD DROP rules in BOTH iptables backends.
  # dst: blocks outbound connections to C2/malicious infrastructure (malware phoning home)
  # src: blocks inbound attack traffic from known malicious sources
  for ipt in iptables iptables-legacy; do
    command -v "$ipt" >/dev/null 2>&1 || continue

    if ! $ipt -C FORWARD -m set --match-set block_malicious dst -j DROP 2>/dev/null; then
      $ipt -I FORWARD -m set --match-set block_malicious dst -j DROP 2>/dev/null || true
    fi

    if ! $ipt -C FORWARD -m set --match-set block_malicious src -j DROP 2>/dev/null; then
      $ipt -I FORWARD -m set --match-set block_malicious src -j DROP 2>/dev/null || true
    fi
  done
}

add_country_block
add_ip_blocklist

echo 'routing-fix: Routes applied.'

# Re-assert loop (every 5 seconds)
while true; do
  # Table 200 routes
  ip route replace "${WARP_ENDPOINT}" via "${DOCKER_GW}" dev eth0 table 200 2>/dev/null || true
  ip route replace default dev tun0 table 200 2>/dev/null || true

  # Main table: keep Docker subnet route
  ip route replace "${DOCKER_NET}" dev eth0 2>/dev/null || true

  # CGNAT ip rule for Tailscale
  if ! ip rule show | grep -q '100.64.0.0/10'; then
    ip rule add to 100.64.0.0/10 lookup 52 pref 99 2>/dev/null || true
    echo 'routing-fix: CGNAT rule missing, re-injected'
  fi

  # FORWARD RELATED,ESTABLISHED: Allow return traffic in both iptables
  # backends. Gluetun may reset the nftables ruleset on VPN reconnect,
  # and Tailscale may reset the legacy ruleset on auth refresh.
  add_fwd_related_established
  
  # Ensure P2P packets bypass WARP to maintain low latency
  add_tailscale_p2p_bypass

  # Enforce country blocklist
  add_country_block

  # Enforce IP blocklist (reloads automatically when file changes)
  add_ip_blocklist

  sleep 5
done
