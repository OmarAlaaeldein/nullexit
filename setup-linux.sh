#!/bin/bash
# setup.sh — nullexit one-shot setup script
# Configures Cloudflare WARP + Tailscale + AdGuard Home from scratch.
set -euo pipefail

# ─── Formatting ──────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

step() { echo -e "\n${BLUE}${BOLD}▶ $*${NC}"; }
ok()   { echo -e "  ${GREEN}✓ $*${NC}"; }
warn() { echo -e "  ${YELLOW}⚠ $*${NC}"; }
die()  { echo -e "\n  ${RED}✗ $*${NC}\n"; exit 1; }

# ─── 1. Docker ───────────────────────────────────────────────────────────────
step "Checking Docker"

if ! command -v docker >> output.log 2>&1; then
    echo ""
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "  Docker is not installed. Two options:"
        echo ""
        echo "  A) Colima — lighter, recommended for this project (low memory):"
        echo "       brew install colima docker docker-compose"
        echo "       colima start --memory 0.6"
        echo ""
        echo "  B) Docker Desktop — easier GUI, higher memory overhead:"
        echo "       https://www.docker.com/products/docker-desktop/"
    else
        echo "  Docker is not installed. Run:"
        echo "       curl -fsSL https://get.docker.com | sh"
        echo "       sudo usermod -aG docker \$USER && newgrp docker"
    fi
    die "Install Docker, then re-run this script."
fi

if ! docker info >> output.log 2>&1; then
    echo ""
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "  Docker is installed but not running."
        echo "  If using Colima:        colima start --memory 0.6"
        echo "  If using Docker Desktop: open the app."
    else
        echo "  Docker is installed but not running."
        echo "  Run: sudo systemctl start docker"
    fi
    die "Start Docker, then re-run this script."
fi

if ! docker compose version >> output.log 2>&1; then
    die "Docker Compose v2 not found. Update Docker or install the compose plugin:\n  https://docs.docker.com/compose/install/"
fi

ok "Docker $(docker --version | grep -oP '[\d.]+' | head -1) is running."

# ─── 2. Tailscale (host) ──────────────────────────────────────────────────────
step "Checking Tailscale (host)"
# The host needs its own Tailscale installation — separate from the Docker
# container — so Toggle-Gateway can run 'tailscale down' before stopping
# containers and 'tailscale up' after starting them. Without this, the
# exit-node deadlock that setup.sh is designed to prevent can still occur.

# Resolve the tailscale binary: CLI (brew/package) or bundled macOS app
TAILSCALE_BIN=""
if command -v tailscale >> output.log 2>&1; then
    TAILSCALE_BIN="tailscale"
elif [[ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]]; then
    TAILSCALE_BIN="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
fi

if [[ -z "$TAILSCALE_BIN" ]]; then
    warn "Tailscale not found on host — installing..."

    if [[ "$OSTYPE" == "darwin"* ]]; then
        if command -v brew >> output.log 2>&1; then
            step "Installing Tailscale CLI formula via Homebrew (standalone, no .app GUI)..."
            brew install tailscale -q
            TAILSCALE_BIN="tailscale"

            step "Starting tailscaled as a per-user LaunchAgent (auto-starts at login)..."
            if brew services start tailscale 2>&1 | grep -qE 'Successfully|started'; then
                ok "tailscaled LaunchAgent registered."
            else
                warn "Could not auto-start tailscaled. Run 'brew services start tailscale' manually."
                warn "For a system-wide LaunchDaemon that runs before login, run instead:"
                warn "    sudo brew services start tailscale"
            fi
            echo ""
        else
            die "Homebrew not found. Install Tailscale manually:\n  https://tailscale.com/download/mac\n  Then re-run this script."
        fi

    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        curl -fsSL https://tailscale.com/install.sh | sh
        sudo systemctl enable --now tailscaled 2>> output.log || true
        TAILSCALE_BIN="tailscale"

    else
        die "Unsupported OS. Install Tailscale manually:\n  https://tailscale.com/download\n  Then re-run this script."
    fi

    ok "Tailscale installed."
else
    ok "Tailscale is already installed ($(${TAILSCALE_BIN} version 2>> output.log | head -1))."
fi

# Authenticate the host machine if it isn't already connected.
# This is an interactive step — it opens a browser login URL.
# We do it now, before containers start, so Toggle-Gateway can
# safely run 'tailscale down/up' from day one.
if ! ${TAILSCALE_BIN} status >> output.log 2>&1; then
    echo ""
    echo "  Your host machine needs to join your Tailscale network."
    echo "  A browser window or login URL will appear — authenticate, then"
    echo "  return here. The script will continue automatically."
    echo ""
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        sudo ${TAILSCALE_BIN} up
    else
        ${TAILSCALE_BIN} up
    fi
    ok "Host machine connected to Tailscale."
else
    ok "Host machine is already connected to Tailscale."
fi

# ─── 3. wgcf ─────────────────────────────────────────────────────────────────
step "Checking wgcf (Cloudflare WARP key tool)"

if ! command -v wgcf >> output.log 2>&1; then
    warn "wgcf not found — installing..."

    if [[ "$OSTYPE" == "darwin"* ]]; then
        command -v brew >> output.log 2>&1 || die "Homebrew not found.\nInstall wgcf manually: https://github.com/ViRb3/wgcf/releases"
        brew install wgcf -q

    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        ARCH=$(uname -m)
        case $ARCH in
            x86_64)  WGCF_ARCH="amd64" ;;
            aarch64) WGCF_ARCH="arm64" ;;
            armv7l)  WGCF_ARCH="armv7" ;;
            *) die "Unsupported architecture: $ARCH.\nInstall wgcf manually: https://github.com/ViRb3/wgcf/releases" ;;
        esac

        echo "  Fetching latest release..."
        WGCF_VERSION=$(curl -sf https://api.github.com/repos/ViRb3/wgcf/releases/latest \
            | grep '"tag_name"' | cut -d'"' -f4)
        [[ -z "$WGCF_VERSION" ]] && die "Could not fetch wgcf version. Check your internet connection."

        curl -sfL \
            "https://github.com/ViRb3/wgcf/releases/download/${WGCF_VERSION}/wgcf_${WGCF_VERSION#v}_linux_${WGCF_ARCH}" \
            -o /usr/local/bin/wgcf
        chmod +x /usr/local/bin/wgcf
    else
        die "Unsupported OS. Install wgcf manually: https://github.com/ViRb3/wgcf/releases"
    fi
fi

ok "wgcf is ready."

# ─── 4. WARP profile ─────────────────────────────────────────────────────────
step "Generating Cloudflare WARP profile"

if [[ -f "wgcf-profile.conf" ]]; then
    warn "wgcf-profile.conf already exists — skipping key generation."
else
    wgcf register --accept-tos 2>> output.log || die "wgcf register failed. Check your internet connection."
    wgcf generate 2>> output.log           || die "wgcf generate failed."
    ok "WARP profile generated."
fi

# Parse keys (IPv4 address only — gluetun doesn't need the IPv6 one)
PRIVATE_KEY=$(awk '/PrivateKey/{print $3}' wgcf-profile.conf)
PUBLIC_KEY=$(awk '/PublicKey/{print $3}'   wgcf-profile.conf)
ADDRESSES=$(awk '/Address/{print $3}'       wgcf-profile.conf | grep -v ':' | head -1)

[[ -z "$PRIVATE_KEY" ]] && die "Could not parse PrivateKey from wgcf-profile.conf"
[[ -z "$PUBLIC_KEY" ]]  && die "Could not parse PublicKey from wgcf-profile.conf"
[[ -z "$ADDRESSES" ]]   && die "Could not parse IPv4 Address from wgcf-profile.conf"

ok "WARP keys extracted."

# ─── 5. Tailscale auth key ───────────────────────────────────────────────────
step "Tailscale authentication"
echo ""
echo "  Generate a key at: https://login.tailscale.com/admin/settings/keys"
echo "  → 'Generate auth key' → enable Reusable if you plan to re-run setup"
echo ""
read -rp "  Paste your Tailscale auth key: " TS_AUTHKEY
echo ""

[[ -z "$TS_AUTHKEY" ]] && die "Tailscale auth key is required."
[[ "$TS_AUTHKEY" != tskey-auth-* ]] && warn "Key doesn't look like a Tailscale auth key — proceeding anyway."
ok "Auth key accepted."

# ─── 6. AdGuard Home admin password ─────────────────────────────────────────
step "AdGuard Home admin account"

# Hardcoded default credentials to prevent lockout
# Username: admin
# Password: nullexit
ADGUARD_PASSWORD="nullexit"
ADGUARD_PWD_ESC="nullexit"
ok "Default password set to 'nullexit'."


# ─── 7. Write .env ───────────────────────────────────────────────────────────
step "Writing .env"

if [[ -f ".env" ]]; then
    read -rp "  .env already exists. Overwrite? [y/N]: " OVERWRITE
    if [[ "$OVERWRITE" != "y" && "$OVERWRITE" != "Y" ]]; then
        warn "Keeping existing .env."
    else
        WRITE_ENV=1
    fi
else
    WRITE_ENV=1
fi

if [[ "${WRITE_ENV:-0}" == "1" ]]; then
    cat > .env <<EOF
WIREGUARD_PRIVATE_KEY=${PRIVATE_KEY}
WIREGUARD_PUBLIC_KEY=${PUBLIC_KEY}
WIREGUARD_ADDRESSES=${ADDRESSES}
TS_AUTHKEY=${TS_AUTHKEY}
GATEWAY_RULE_PROFILE=medium
# Safe MSS for double-tunneled traffic (Tailscale + WARP). Change to 1180 if you experience slow speeds and have a healthy path.
GATEWAY_MSS=1120
EOF
    ok ".env written."
fi

# ─── 8. Prepare directories ───────────────────────────────────────────────────
step "Preparing AdGuard directories"

mkdir -p adguard/conf adguard/work/userfilters

# Remove empty AdGuardHome.yaml that would cause a crash loop (same logic as Toggle-Gateway scripts)
if [[ -f "adguard/conf/AdGuardHome.yaml" && ! -s "adguard/conf/AdGuardHome.yaml" ]]; then
    rm "adguard/conf/AdGuardHome.yaml"
    warn "Removed empty AdGuardHome.yaml to prevent crash loop."
fi

ok "Directories ready."

# ─── 9. Compile DNS filter rules ─────────────────────────────────────────────
step "Compiling DNS filter rules (this may take a minute)"

if command -v python3 >> output.log 2>&1; then
    python3 sync-rules.py
    ok "Rules compiled."
else
    warn "python3 not found — skipping rule compilation."
    warn "Run 'python3 sync-rules.py' manually after setup."
fi

# ─── 10. Start containers ──────────────────────────────────────────────────────
step "Starting containers"
# Note: tailscale depends on adguardhome being healthy (port 5335 up),
# so Docker Compose will hold it back automatically until the wizard is done.
docker compose up -d
ok "Containers starting."

# ─── 11. Wait for AdGuard Home setup wizard ──────────────────────────────────
step "Waiting for AdGuard Home setup wizard"
echo "  (up to 60 seconds...)"

MAX=60; ELAPSED=0
until docker exec routing-fix curl -sf http://127.0.0.1:3000 >> output.log 2>&1; do
    sleep 2; ELAPSED=$((ELAPSED + 2))
    [[ $ELAPSED -ge $MAX ]] && die "AdGuard Home didn't come up.\nDebug with: docker compose logs adguardhome"
done

ok "AdGuard Home is up."

# ─── 12. Configure AdGuard Home via API ──────────────────────────────────────
step "Configuring AdGuard Home"

# Run all API calls in a single docker exec sh -c so the session cookie file
# is shared across calls without leaving the container.
docker exec routing-fix sh -c "
  set -e

  # Step 1: Complete the setup wizard (sets admin creds + DNS port to 5335)
  curl -sf -X POST http://127.0.0.1:3000/control/install/configure \
    -H 'Content-Type: application/json' \
    -d '{\"web\":{\"ip\":\"0.0.0.0\",\"port\":3000},\"dns\":{\"ip\":\"0.0.0.0\",\"port\":5335},\"username\":\"admin\",\"password\":\"${ADGUARD_PWD_ESC}\"}' \
    >/dev/null || true

  # Step 2: Wait for AdGuard to restart after wizard
  sleep 4
  WAITED=0
  until curl -sf http://127.0.0.1:3000 >/dev/null 2>&1; do
    sleep 2; WAITED=\$((WAITED + 2))
    [ \$WAITED -ge 30 ] && { echo 'AdGuard did not restart in time'; exit 1; }
  done

  # Step 3: Login to get session cookie
  curl -sf -X POST http://127.0.0.1:3000/control/login \
    -H 'Content-Type: application/json' \
    -d '{\"name\":\"admin\",\"password\":\"${ADGUARD_PWD_ESC}\"}' \
    -c /tmp/agh.cookie >/dev/null

  # Step 4: Point upstream DNS back through the WARP tunnel
  curl -sf -X POST http://127.0.0.1:3000/control/dns_config \
    -H 'Content-Type: application/json' \
    -b /tmp/agh.cookie \
    -d '{\"upstream_dns\":[\"127.0.0.1:53\"],\"bootstrap_dns\":[\"1.1.1.1\",\"8.8.8.8\"],\"upstream_mode\":\"load_balance\"}' \
    >/dev/null

  # Step 5: Register the compiled rules file as a filter list
  curl -sf -X POST http://127.0.0.1:3000/control/filtering/add_url \
    -H 'Content-Type: application/json' \
    -b /tmp/agh.cookie \
    -d '{\"name\":\"Custom Compiled Rules\",\"url\":\"/opt/adguardhome/work/userfilters/compiled_rules.txt\"}' \
    >/dev/null || true

  # Step 6: Force a filter refresh to load the rules immediately
  curl -sf -X POST http://127.0.0.1:3000/control/filtering/refresh \
    -H 'Content-Type: application/json' \
    -b /tmp/agh.cookie \
    -d '{\"whitelist\":false}' \
    >/dev/null || true

  rm -f /tmp/agh.cookie
"

ok "AdGuard Home configured."

# ─── 13. Wait for Tailscale ───────────────────────────────────────────────────
step "Waiting for Tailscale to authenticate"
echo "  (Tailscale only starts once AdGuard's healthcheck passes — up to 90s)"

MAX=90; ELAPSED=0; TS_IP=""
until [[ -n "$TS_IP" ]]; do
    TS_IP=$(docker exec tailscale tailscale ip -4 2>> output.log || true)
    if [[ -z "$TS_IP" ]]; then
        sleep 3; ELAPSED=$((ELAPSED + 3))
        if [[ $ELAPSED -ge $MAX ]]; then
            warn "Tailscale hasn't authenticated yet."
            warn "Once it does, re-run toggle.sh — it will resolve the IP dynamically."
            break
        fi
    fi
done

if [[ -n "$TS_IP" ]]; then
    ok "Tailscale IP: ${TS_IP} (resolved dynamically by toggle.sh on each startup)"
fi

# ─── Compile Linux Desktop Shortcuts ──────────────────────────────────────────
echo -e "\n${BOLD}Creating Linux Desktop Shortcuts...${NC}"
DIR="$(pwd)"
cat <<EOF > "Toggle Gateway.desktop"
[Desktop Entry]
Version=1.0
Name=Toggle Gateway
Comment=Start or Stop Nullexit Gateway
Exec=bash -c "cd '$DIR' && ./toggle-linux.sh; read -p 'Press Enter to close...' dummy"
Icon=utilities-terminal
Terminal=true
Type=Application
Categories=Network;Security;
EOF
chmod +x "Toggle Gateway.desktop"

cat <<EOF > "Recover Gateway.desktop"
[Desktop Entry]
Version=1.0
Name=Recover Gateway
Comment=Emergency DNS and Network Recovery
Exec=bash -c "cd '$DIR' && ./recover-linux.sh; read -p 'Press Enter to close...' dummy"
Icon=utilities-terminal
Terminal=true
Type=Application
Categories=Network;Security;
EOF
chmod +x "Recover Gateway.desktop"
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
echo "  python3 sync-rules.py"
echo ""
echo -e "${BOLD}To toggle the gateway on/off:${NC}"
echo "  Linux: double-click the 'Toggle Gateway' desktop icon!"
echo "  (or run ./toggle-linux.sh in terminal)"
echo ""
