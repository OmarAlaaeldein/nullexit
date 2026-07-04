#!/bin/bash
# scripts/setup-linux.sh — nullexit one-shot setup script (Linux)
# Configures Cloudflare WARP + Tailscale + AdGuard Home from scratch.
set -euo pipefail

# Source common formatting and helper functions
source "$(dirname "$0")/common.sh"

# Run common installation logic
source "$(dirname "$0")/setup-common.sh"

# ─── Compile Linux Desktop Shortcuts ──────────────────────────────────────────
echo -e "\n${BOLD}Creating Linux Desktop Shortcuts...${NC}"
DIR="$(pwd)"
cat <<EOF > "Toggle Gateway.desktop"
[Desktop Entry]
Version=1.0
Name=Toggle Gateway
Comment=Start or Stop Nullexit Gateway
Exec=bash -c "cd '$DIR' && ./scripts/toggle-linux.sh; read -p 'Press Enter to close...' dummy"
Icon=utilities-terminal
Terminal=true
Type=Application
Categories=Network;Security;
EOF

cat <<EOF > "Recover Gateway.desktop"
[Desktop Entry]
Version=1.0
Name=Recover Gateway
Comment=Emergency DNS and Network Recovery
Exec=bash -c "cd '$DIR' && ./scripts/recover-linux.sh; read -p 'Press Enter to close...' dummy"
Icon=utilities-terminal
Terminal=true
Type=Application
Categories=Network;Security;
EOF
echo "  → Created 'Toggle Gateway.desktop' and 'Recover Gateway.desktop'"

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

if [[ -n "${TS_IP:-}" ]]; then
    echo -e "${BOLD}AdGuard Home dashboard:${NC}  http://${TS_IP}:3000  (username: admin)"
    echo ""
fi

echo -e "${BOLD}To update your block/allow rules:${NC}"
echo "  python3 scripts/sync-rules.py"
echo ""
echo -e "${BOLD}To toggle the gateway on/off:${NC}"
echo "  Linux: double-click the 'Toggle Gateway' desktop icon!"
echo "  (or run ./scripts/toggle-linux.sh in terminal)"
echo ""
