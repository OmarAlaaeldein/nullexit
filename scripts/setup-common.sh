#!/bin/bash
# ─── 1. Docker ───────────────────────────────────────────────────────────────
step "Checking Docker"

if ! command -v docker >> output.log 2>&1; then
    echo ""
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "  Docker is not installed."
        # Note: Homebrew aggressively rolls forward and discourages version pinning.
        # This setup is confirmed stable on Colima v0.10.3 and Docker v29.6.1.
        read -rp "  Would you like to automatically install Colima & Docker via Homebrew? [y/N]: " INSTALL_DOCKER
        if [[ "$INSTALL_DOCKER" == "y" || "$INSTALL_DOCKER" == "Y" ]]; then
            step "Installing Colima and Docker..."
            brew install colima docker docker-compose
            step "Starting Colima VM..."
            colima start --memory 0.6 --vm-type vz --network-address --network-mode bridged
        else
            echo ""
            echo "  Please install Docker manually. Two options:"
            echo "  A) Colima (Recommended): brew install colima docker docker-compose && colima start --memory 0.6 --vm-type vz --network-address --network-mode bridged"
            echo "  B) Docker Desktop: https://www.docker.com/products/docker-desktop/"
            die "Install Docker, then re-run this script."
        fi
    else
        echo "  Docker is not installed."
        # Note: The Docker convenience script always fetches the latest stable release.
        # This setup is confirmed stable on Docker Engine v29.6.1.
        read -rp "  Would you like to automatically install Docker? (Requires sudo) [y/N]: " INSTALL_DOCKER
        if [[ "$INSTALL_DOCKER" == "y" || "$INSTALL_DOCKER" == "Y" ]]; then
            step "Installing Docker..."
            curl -fsSL https://get.docker.com | sh
            sudo usermod -aG docker "$USER"
            echo -e "\n\033[0;32m[OK] Docker installed successfully!\033[0m"
            echo -e "\033[0;33m[!] CRITICAL: You must log out of your SSH session and log back in for Docker permissions to apply.\033[0m"
            die "Please log out, log back in, and re-run setup.sh."
        else
            echo "  Please install Docker manually:"
            echo "       curl -fsSL https://get.docker.com | sh"
            echo "       sudo usermod -aG docker \$USER && newgrp docker"
            die "Install Docker, then re-run this script."
        fi
    fi
fi

if ! docker info >> output.log 2>&1; then
    echo ""
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "  Docker is installed but not running."
        echo "  If using Colima:        colima start --memory 0.6 --vm-type vz --network-address --network-mode bridged"
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

ok "Docker $(docker --version | grep -oE '[0-9.]+' | head -1) is running."

# ─── 1.5 Python 3 ─────────────────────────────────────────────────────────────
step "Checking Python 3"

if ! command -v python3 >> output.log 2>&1; then
    echo ""
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "  Python 3 is not installed."
        echo "  macOS includes it via Xcode Command Line Tools, or you can install it via Homebrew:"
        echo "       brew install python3"
        die "Install Python 3, then re-run this script."
    else
        echo "  Python 3 is not installed."
        echo "  Please install it using your system's package manager. For example:"
        echo "       Debian/Ubuntu:  sudo apt install python3"
        echo "       Fedora:         sudo dnf install python3"
        echo "       Arch:           sudo pacman -S python"
        die "Install Python 3, then re-run this script."
    fi
fi

# Note: This setup is confirmed stable on Python 3.9.6 (macOS default).
PYTHON_VER=$(python3 --version 2>&1 | head -n 1)
ok "$PYTHON_VER is installed."

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

RECOMMENDED_TS_VERSION="1.98.5"

if [[ -z "$TAILSCALE_BIN" ]]; then
    warn "Tailscale not found on host — installing..."

    if [[ "$OSTYPE" == "darwin"* ]]; then
        if command -v brew >> output.log 2>&1; then
            step "Installing Tailscale CLI formula via Homebrew (standalone, no .app GUI)..."
            # Note: We install Tailscale via Homebrew, targeting the stable version (recommended: 1.98.5)
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
            die "Homebrew not found. Install Tailscale manually (recommended version: ${RECOMMENDED_TS_VERSION}):\n  https://tailscale.com/download/mac\n  Then re-run this script."
        fi

    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        curl -fsSL https://tailscale.com/install.sh | sh
        sudo systemctl enable --now tailscaled 2>> output.log || true
        TAILSCALE_BIN="tailscale"

    else
        die "Unsupported OS. Install Tailscale manually (recommended version: ${RECOMMENDED_TS_VERSION}):\n  https://tailscale.com/download\n  Then re-run this script."
    fi

    TAILSCALE_VER=$(${TAILSCALE_BIN} version 2>> output.log | head -n 1)
    if [[ "$TAILSCALE_VER" != "$RECOMMENDED_TS_VERSION" ]]; then
        warn "Tailscale installed, but version ($TAILSCALE_VER) differs from recommended version ($RECOMMENDED_TS_VERSION)."
    else
        ok "Tailscale installed (version $TAILSCALE_VER)."
    fi
else
    TAILSCALE_VER=$(${TAILSCALE_BIN} version 2>> output.log | head -n 1)
    if [[ "$TAILSCALE_VER" != "$RECOMMENDED_TS_VERSION" ]]; then
        warn "Tailscale is already installed ($TAILSCALE_VER), but recommended version is $RECOMMENDED_TS_VERSION for host/container consistency."
    else
        ok "Tailscale is already installed at recommended version ($TAILSCALE_VER)."
    fi
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

        sudo curl -sfL \
            "https://github.com/ViRb3/wgcf/releases/download/${WGCF_VERSION}/wgcf_${WGCF_VERSION#v}_linux_${WGCF_ARCH}" \
            -o /usr/local/bin/wgcf
        sudo chmod +x /usr/local/bin/wgcf
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

if [[ -f ".env" ]]; then
    EXISTING_TS_KEY=$(read_env_var TS_AUTHKEY)
    if [[ -n "$EXISTING_TS_KEY" ]]; then
        TS_AUTHKEY="$EXISTING_TS_KEY"
        warn "Found existing TS_AUTHKEY in .env. Skipping prompt."
    fi
fi

if [[ -z "$TS_AUTHKEY" ]]; then
    echo ""
    echo "  Generate a key at: https://login.tailscale.com/admin/settings/keys"
    echo "  → 'Generate auth key' → enable Reusable if you plan to re-run setup"
    echo ""
    read -rp "  Paste your Tailscale auth key: " TS_AUTHKEY
    echo ""
fi

[[ -z "$TS_AUTHKEY" ]] && die "Tailscale auth key is required."
[[ "$TS_AUTHKEY" != tskey-auth-* ]] && warn "Key doesn't look like a Tailscale auth key — proceeding anyway."
ok "Auth key accepted."

# ─── 6. AdGuard Home admin password ─────────────────────────────────────────
step "AdGuard Home admin account"

# Hardcoded default credentials to prevent lockout
# Username: admin
# Password: nullexit
if [[ -f ".env" ]]; then
    EXISTING_AG_PASS=$(read_env_var ADGUARD_PASSWORD)
    if [[ -n "$EXISTING_AG_PASS" ]]; then
        ADGUARD_PASSWORD="$EXISTING_AG_PASS"
        ADGUARD_PWD_ESC="$EXISTING_AG_PASS"
        ok "Found existing ADGUARD_PASSWORD in .env."
    else
        ADGUARD_PASSWORD="nullexit"
        ADGUARD_PWD_ESC="nullexit"
        ok "Default password set to 'nullexit'."
    fi
else
    ADGUARD_PASSWORD="nullexit"
    ADGUARD_PWD_ESC="nullexit"
    ok "Default password set to 'nullexit'."
fi


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
    # Preserve existing configuration flags if .env already exists
    EXISTING_PROFILE="medium"
    EXISTING_MSS="1120"
    EXISTING_HIJACK="true"
    EXISTING_EXIT="true"
    EXISTING_THRESH="6"
    EXISTING_PROBE="true"
    EXISTING_KILL="false"
    EXISTING_BLOCKED="kp il"
    
    if [[ -f ".env" ]]; then
        [[ -n "$(read_env_var GATEWAY_RULE_PROFILE)" ]] && EXISTING_PROFILE=$(read_env_var GATEWAY_RULE_PROFILE)
        [[ -n "$(read_env_var GATEWAY_MSS)" ]] && EXISTING_MSS=$(read_env_var GATEWAY_MSS)
        [[ -n "$(read_env_var GATEWAY_HIJACK_HOST)" ]] && EXISTING_HIJACK=$(read_env_var GATEWAY_HIJACK_HOST)
        [[ -n "$(read_env_var GATEWAY_USE_EXIT_NODE)" ]] && EXISTING_EXIT=$(read_env_var GATEWAY_USE_EXIT_NODE)
        [[ -n "$(read_env_var WARP_FAIL_THRESHOLD)" ]] && EXISTING_THRESH=$(read_env_var WARP_FAIL_THRESHOLD)
        [[ -n "$(read_env_var HOST_LEAK_PROBE)" ]] && EXISTING_PROBE=$(read_env_var HOST_LEAK_PROBE)
        [[ -n "$(read_env_var KILL_SWITCH)" ]] && EXISTING_KILL=$(read_env_var KILL_SWITCH)
        [[ -n "$(read_env_var BLOCKED_COUNTRIES)" ]] && EXISTING_BLOCKED=$(read_env_var BLOCKED_COUNTRIES)
    fi

    cat > .env <<EOF
WIREGUARD_PRIVATE_KEY=${PRIVATE_KEY}
WIREGUARD_PUBLIC_KEY=${PUBLIC_KEY}
WIREGUARD_ADDRESSES=${ADDRESSES}
TS_AUTHKEY=${TS_AUTHKEY}
GATEWAY_RULE_PROFILE=${EXISTING_PROFILE}
# Safe MSS for double-tunneled traffic (Tailscale + WARP). Change to 1180 if you experience slow speeds and have a healthy path.
GATEWAY_MSS=${EXISTING_MSS}
# Set to false to run as a 'Headless Server' (Docker acts as an exit node, but the host Mac/Linux's own internet is NOT hijacked).
GATEWAY_HIJACK_HOST=${EXISTING_HIJACK}
GATEWAY_USE_EXIT_NODE=${EXISTING_EXIT}
WARP_FAIL_THRESHOLD=${EXISTING_THRESH}
# Set to false to disable the 300ms host-egress leak prober (scripts/host-leak-probe.sh).
HOST_LEAK_PROBE=${EXISTING_PROBE}
KILL_SWITCH=${EXISTING_KILL}
ADGUARD_PASSWORD=${ADGUARD_PASSWORD}
BLOCKED_COUNTRIES="${EXISTING_BLOCKED}"
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
    python3 scripts/sync-rules.py
    ok "Rules compiled."
else
    warn "python3 not found — skipping rule compilation."
    warn "Run 'python3 scripts/sync-rules.py' manually after setup."
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
            warn "Once it does, re-run the toggle script — it will resolve the IP dynamically."
            break
        fi
    fi
done

if [[ -n "$TS_IP" ]]; then
    ok "Tailscale IP: ${TS_IP} (resolved dynamically by the toggle script on each startup)"
fi

