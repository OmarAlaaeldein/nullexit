#!/bin/bash
# setup.sh — nullexit one-shot setup script (macOS)
# Configures Cloudflare WARP + Tailscale + AdGuard Home from scratch.
set -euo pipefail

# Source common formatting and helper functions
source "$(dirname "$0")/scripts/common.sh"

# Run common installation logic
source "$(dirname "$0")/scripts/setup-common.sh"

# ─── Compile macOS Shortcuts ──────────────────────────────────────────────────
echo -e "\n${BOLD}Compiling macOS Desktop Shortcuts...${NC}"
if command -v osacompile &> /dev/null; then
    osacompile -o "Toggle Gateway.app" "Toggle-Gateway.applescript" >/dev/null 2>&1
    osacompile -o "Recover Gateway.app" "Recover-Gateway.applescript" >/dev/null 2>&1
    echo "  → Created 'Toggle Gateway.app' and 'Recover Gateway.app'"
fi

# ─── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║            Setup complete!                   ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}One manual step remaining — approve the exit node:${NC}"
echo "  → https://login.tailscale.com/admin/machines"
echo "  → Find your gateway → '...' → 'Edit route settings' → enable Exit Node"
echo ""

echo -e "${YELLOW}${BOLD}Sudoers / Background Execution Requirements:${NC}"
echo "  To allow silent, non-interactive execution of the firewall and network routes (especially during sleep/wake recovery), you must configure passwordless sudo."
echo "  Run this exact command in your terminal (grants are scoped to least privilege):"
echo "    echo \"\$USER ALL=(root) NOPASSWD: /sbin/pfctl, /usr/sbin/networksetup, /sbin/route, /sbin/ifconfig, /usr/bin/dscacheutil -flushcache, /usr/bin/killall -HUP mDNSResponder, /usr/bin/killall sharingd rapportd, /usr/bin/pkill -9 tailscaled, /usr/bin/pkill -f dns-proxy.py, /bin/kill, /usr/bin/true, /opt/homebrew/bin/brew services * tailscale, /opt/homebrew/bin/brew uninstall tailscale, /usr/local/bin/brew services * tailscale, /usr/local/bin/brew uninstall tailscale, /usr/bin/python3 -I \$PWD/scripts/dns-proxy.py, /opt/homebrew/bin/python3 -I \$PWD/scripts/dns-proxy.py, /usr/local/bin/python3 -I \$PWD/scripts/dns-proxy.py\" | sudo tee /etc/sudoers.d/nullexit >/dev/null && sudo visudo -cf /etc/sudoers.d/nullexit"
echo ""

if [[ -n "${TS_IP:-}" ]]; then
    echo -e "${BOLD}AdGuard Home dashboard:${NC}  http://${TS_IP}:3000  (username: admin)"
    echo ""
fi

echo -e "${BOLD}To toggle the gateway on/off:${NC}"
echo "  macOS:   double-click the 'Toggle Gateway' app icon!"
echo "  Windows: double-click Toggle-Gateway.bat"
echo ""

if [[ "$OSTYPE" == "darwin"* ]]; then
    # LuLu localhost filtering check
    if [ -d "/Applications/LuLu.app" ] || systemextensionsctl list 2>/dev/null | grep -q "com.objective-see.lulu"; then
        echo -e "${YELLOW}${BOLD}LuLu Firewall Detected:${NC}"
        echo "  LuLu's localhost (loopback) filtering is OFF by default. To properly protect the"
        echo "  local nullexit proxy ports from malicious local processes, you must manually enable"
        echo "  'Allow Loopback' (or block it selectively) in LuLu's Preferences -> Rules."
        echo ""
    fi

    echo -e "${YELLOW}${BOLD}Note on macOS Tailscale Sandboxing:${NC}"
    echo "  The Tailscale GUI app (tailscale-app) installed on macOS is sandboxed."
    echo "  While you cannot run a Tailscale SSH server on this Mac host, you can"
    echo "  still SSH outbound to other devices on the mesh using their MagicDNS"
    echo "  addresses directly (e.g. ssh user@device.tailnet-name.ts.net)."
    echo ""
fi
