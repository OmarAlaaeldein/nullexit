#!/bin/bash
set -e

TORRC="/etc/tor/torrc"
mkdir -p /etc/tor /var/lib/tor

# Base configuration: SOCKS 9050, Control 9051, TransPort 9040, DNSPort 5353 — all bound to
# 0.0.0.0 (required for Docker/Colima host port-mapping). The ControlPort is secured via a
# dynamic HashedControlPassword (added below when TOR_PASSWORD is set); see devref.md §15.10.2.
cat <<EOF > $TORRC
SocksPort 0.0.0.0:9050
ControlPort 0.0.0.0:9051
CookieAuthentication 0
Log notice stdout
DataDirectory /var/lib/tor

# Transparent proxying & DNS resolution for .onion mapping
TransPort 0.0.0.0:9040
DNSPort 0.0.0.0:5353
AutomapHostsOnResolve 1
VirtualAddrNetworkIPv4 198.18.0.0/15
EOF

if [ -n "$TOR_PASSWORD" ]; then
    HASH=$(tor --hash-password "$TOR_PASSWORD" | tail -n 1)
    echo "HashedControlPassword $HASH" >> $TORRC
fi

if [ -n "$TOR_EXCLUDE_EXIT_NODES" ]; then
    echo "ExcludeExitNodes $TOR_EXCLUDE_EXIT_NODES" >> $TORRC
    echo "StrictNodes 1" >> $TORRC
fi

if [ "${TOR_USE_BRIDGES:-false}" = "true" ]; then
    BRIDGE_FILE="${TOR_BRIDGE_LINES_FILE:-/tor-bridges.txt}"
    
    if ! grep -vE "^[[:space:]]*#" "$BRIDGE_FILE" | grep -q '[^[:space:]]'; then
        MSG="[$(date '+%Y-%m-%d %H:%M:%S')] [CRITICAL] [Tor Proxy] TOR_USE_BRIDGES is enabled, but no bridge lines found at $BRIDGE_FILE. Proxy startup ABORTED. Get bridges from https://bridges.torproject.org."
        echo "$MSG"
        if [ -w "/output.log" ]; then
            echo "$MSG" >> /output.log
        fi
        # Sleep indefinitely to prevent docker-compose 'unless-stopped' from triggering a crash loop
        exec sleep infinity
    fi
    
    echo "UseBridges 1" >> $TORRC
    echo "ClientTransportPlugin obfs4 exec /usr/bin/obfs4proxy" >> $TORRC
    
    while IFS= read -r line; do
        # Ignore comments and empty lines
        [[ -z "$line" || "$line" == \#* ]] && continue
        echo "Bridge $line" >> $TORRC
    done < "$BRIDGE_FILE"
fi

# Debian tor package uses 'debian-tor' user
chown -R debian-tor:debian-tor /var/lib/tor /etc/tor

exec gosu debian-tor /usr/bin/tor -f $TORRC
