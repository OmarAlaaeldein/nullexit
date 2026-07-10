# nullexit: Tailscale + Cloudflare WARP Docker Gateway

> **Last updated:** July 10, 2026 · [Architecture & Flow Diagrams →](./diagrams.md) · [Full Dev Reference →](./devref.md)

**nullexit** is a chained network gateway that routes all Tailscale exit-node traffic through a Cloudflare WARP VPN tunnel — double-encrypting every packet, hiding your ISP metadata, and providing network-wide DNS ad-blocking (AdGuard Home) and kernel-level IP threat blocking (`ipset`/`iptables`) for every device on your mesh.

---

## 1. Prerequisites
- Docker and Docker Compose installed.
- A Tailscale account.
- **macOS:** Install the standalone Tailscale CLI via Homebrew (`brew install tailscale`) and register `tailscaled` as a system service (`brew services start tailscale`). No `.app` GUI install required.

## 2. Installation & Setup

Run the interactive setup script for your OS. It downloads `wgcf`, generates fresh Cloudflare WARP WireGuard keys, prompts for a Tailscale Auth Key, and writes your `.env`.

```bash
./setup.sh          # macOS
./scripts/setup-linux.sh  # Linux
```

### Reference `.env`
```env
WIREGUARD_PRIVATE_KEY=<Generated>
WIREGUARD_PUBLIC_KEY=<Generated>
WIREGUARD_ADDRESSES=<Generated>
TS_AUTHKEY=tskey-auth-...
GATEWAY_RULE_PROFILE=medium        # light | medium | heavy
# Safe MSS for double-tunneled traffic (Tailscale + WARP). Change to 1180 if you experience slow speeds and have a healthy path.
GATEWAY_MSS=1120                   
# Set to false to run as a 'Headless Server' (Docker acts as an exit node, but the host Mac/Linux's own internet is NOT hijacked).
GATEWAY_HIJACK_HOST=true
GATEWAY_USE_EXIT_NODE=true
WARP_FAIL_THRESHOLD=6              # consecutive warp=off polls before auto-shutdown (default 6 = 30s)
KILL_SWITCH=false                  # enforce strict PF lock that breaks SSH if VPN fails
# On campus/enterprise networks (WPA2-Enterprise / 802.1x), AP Client Isolation blocks direct
# LAN traffic between devices. Tailscale attempts a local P2P upgrade anyway, which causes
# macOS gvproxy to SNAT-mangle the reply's source port — poisoning the phone's WireGuard
# endpoint and blackholing 100% of its traffic. Setting this to false drops those local
# hole-punch packets so the phone safely falls back to Tailscale DERP relays.
# watcher.sh auto-detects 802.1x and AP isolation on every Wi-Fi change and overrides
# this setting automatically — you only need to set this manually if auto-detection fails.
TAILSCALE_ALLOW_LAN_P2P=false     # auto-managed; true only on trusted hotspots/home networks
ADGUARD_PASSWORD=nullexit
BLOCKED_COUNTRIES="kp il"          # dynamically block country IP ranges via ipdeny.com
```

## 3. Deploy the Gateway

**macOS (Recommended):**
```bash
./toggle.sh
```
Running it again stops the gateway and restores your network. Handles the full lifecycle: Colima VM, containers, DNS hijacking, Tailscale exit-node routing, rule compilation, and sleep prevention.

**Linux / Manual:**
```bash
docker compose up -d
```

## 4. Post-Deployment

### Approve the Exit Node
1. Go to [Tailscale Admin → Machines](https://login.tailscale.com/admin/machines).
2. Find the `tailscale` device → `...` → **Edit route settings** → enable as Exit Node.

### Verify Traffic Flow
On any Tailscale client device, select this gateway as the exit node, then visit [api.ipify.org](https://api.ipify.org) or run:
```bash
curl -s https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(warp|ip|colo)='
# expect: warp=on
```

### AdGuard DNS Setup

To ensure client devices correctly route DNS through the AdGuard container (and do not bypass it via `tailscaled`'s internal resolver), you **must** configure your Tailscale Admin Console:
1. Go to the **DNS** tab in the [Tailscale Admin Console](https://login.tailscale.com/admin/dns).
2. Enable **MagicDNS**.
3. Under **Nameservers**, add a **Custom** nameserver and enter the gateway's Tailscale IPv4 address (run `tailscale ip -4` on the gateway machine to find it, e.g., `100.x.x.x`).
4. Click the **three dots (...)** next to the nameserver you just added and enable **"Use with exit node"**.
5. Delete any other Global Nameservers (like Google or Cloudflare).
6. Toggle ON **Override local DNS**.

Traffic will now be correctly forced into the AdGuard sinkhole, and mobile devices will be blocked from bypassing it via encrypted DNS (DoH/DoT).

> [!WARNING]
> **Disable "Private DNS" on mobile devices.** Android's Private DNS (DoT/DoH) bypasses port 53 interception entirely. Go to `Settings → Connections → More connection settings → Private DNS → Off`.

> [!WARNING]
> **Bandwidth doubling:** Streaming 1GB of video on a remote device consumes 1GB download + 1GB upload on the host's network. Be mindful on metered connections.

### AdGuard Dashboard
Navigate to `http://<gateway-tailscale-ip>:3000` — credentials: **`admin` / `nullexit`**.

### Access Any Mesh Device From Anywhere (SFTP/SSH)

Once the gateway exit node is online, **any device on your Tailscale mesh can reach any other mesh device, anywhere in the world** — as long as both devices are on the mesh and the target device has an SSH server running. No port forwarding, no public IPs, no firewall holes. You can SSH into any device using its MagicDNS hostname (e.g. `ssh username@my-macbook`) or its assigned Tailscale IP (`100.x.x.x`).

#### Example: Browse your Android phone's files from your Mac

1. **On your Android phone**, install [Termux](https://termux.dev/) and [Termux:Boot](https://f-droid.org/packages/com.termux.boot/) from F-Droid.
2. In Termux, install and start the SSH server:
   ```bash
   pkg install openssh
   sshd
   ```
   Termux defaults to **port 8022** (ports below 1024 require root on Android).
3. Find your phone's Tailscale IP:
   ```bash
   tailscale ip -4   # e.g. 100.87.42.87
   ```
4. **Stop Android from killing Termux** — do ALL of these (Samsung One UI is especially aggressive):
   - **Settings → Apps → Termux → Battery → Unrestricted**
   - **Device Care → Battery → Background usage limits → Sleeping apps / Deep sleeping apps** — remove Termux if listed
   - In Termux, run `termux-wake-lock` to hold a persistent wakelock
5. **On your Mac/PC**, open [Cyberduck](https://cyberduck.io/) (or any SFTP client: WinSCP, FileZilla, FE File Explorer on iOS) and connect to:
   - **Server:** `100.87.42.87` (your phone's Tailscale IP)
   - **Port:** `8022`
   - **Protocol:** SFTP (SSH File Transfer Protocol)
   - **Username:** (your Termux username, usually `u0_a123` — run `whoami` in Termux to check)
   - **Password:** (your Termux password — set with `passwd` in Termux if you haven't already)

That's it — you can now browse, download, and upload files to your phone from any device on the mesh, no matter where either device is physically located. This works identically for any mesh device: Mac ↔ Mac, Windows ↔ Linux, phone ↔ NAS, etc.

> **Troubleshooting:** If the connection hangs for ~30 seconds before failing, your phone's SSH server isn't running. Open Termux and run `sshd` again. If Android keeps killing it despite Unrestricted battery, the `termux-wake-lock` command is your fix.

---

## 5. Multi-Layer Firewall & Kill-Switch

### Layer 1 — DNS Sinkhole (AdGuard Home)
Blocks ads and tracking domains before they are downloaded. In automated Lighthouse tests on ad-heavy sites:
- **Time to Interactive:** ~22% faster (51.0s → 41.8s)
- **Speed Index:** ~20% faster (15.3s → 12.8s)

Customize blocking via `black_list.txt` and `white_list.txt`. Rule profiles (`light` / `medium` / `heavy`) are set in `.env`.

### Layer 2 — Kernel IP Firewall (`ipset`/`iptables`)
On every startup, the `rule-compiler` fetches threat-intelligence feeds (Spamhaus DROP, Feodo Tracker, Emerging Threats, CINS) and compiles **~16,700 unique malicious IPs/CIDRs** into the kernel `FORWARD` chain — blocking both outbound C2 connections and inbound attack traffic. Zero configuration required.

### Layer 3 — Geo-IP Blocking
Dynamically blocks all traffic to and from specific countries using live IP ranges from `ipdeny.com`. 
To add countries to your blocklist, open your `.env` file and set the `BLOCKED_COUNTRIES` variable with 2-letter ISO country codes (e.g. `BLOCKED_COUNTRIES="kp il cn ru"`), then restart the gateway.

### Layer 4 — macOS PF Kill-Switch
A native macOS Packet Filter (`pf`) kill-switch that enforces a strict default-deny policy on your physical Wi-Fi interface (`en0`). When `KILL_SWITCH=true` is set in your `.env`, it drops all outgoing traffic except the Cloudflare WARP endpoints and Tailscale DERP relays.

- **Failsafe Design:** If the VPN tunnel crashes or Docker dies, your Mac completely loses internet access rather than leaking your real IP.
- **Remote-Access Safe:** Carefully designed to whitelist Tailscale's control plane (`192.200.0.0/24`), `utun*` tunnel traffic, and local LAN subnets. This guarantees that your remote SSH sessions and local AirDrop will survive even when the kill switch engages.
- **Setup Requirement:** The toggle scripts need permission to manipulate the network and firewall in the background without prompting you for a password. You must configure your passwordless sudo config by running exactly:
  ```bash
  echo "$USER ALL=(root) NOPASSWD: /sbin/pfctl, /usr/sbin/networksetup, /usr/bin/dscacheutil, /usr/bin/killall, /usr/bin/pkill, /bin/kill, /sbin/route, /sbin/ifconfig, /usr/bin/true, /opt/homebrew/bin/brew, /usr/local/bin/brew, /usr/bin/python3 $PWD/scripts/dns-proxy.py, /opt/homebrew/bin/python3 $PWD/scripts/dns-proxy.py, /usr/local/bin/python3 $PWD/scripts/dns-proxy.py" | sudo tee /etc/sudoers.d/nullexit
  ```

---

## 6. Toggle Scripts

### macOS — `toggle.sh`
Fully automated lifecycle script. Also supports a native `.app` launcher:
```bash
osacompile -o "Toggle Gateway.app" Toggle-Gateway.applescript
```

Optional `.env` settings:
- `GATEWAY_BYPASS_PING=true` — proceed even if pre-flight connectivity checks fail.
- `GATEWAY_USE_EXIT_NODE=false` — DNS-only mode, skip exit-node routing.
- `GATEWAY_HIJACK_HOST=false` — skip DNS hijacking on the host (provides VPN/adblocking only to external Tailscale peers).
- `GATEWAY_MSS=1360` — override TCP Maximum Segment Size for the tunnel (default is calculated automatically).
- `HOST_LEAK_PROBE=false` — disable background host-egress leak prober (default: true).
- `KILL_SWITCH=true` — enforce strict network lock that breaks SSH if the VPN fails.
- `STOP_COLIMA_ON_EXIT=true` — fully shut down the Colima VM on toggle-off (saves battery on dedicated hosts).
- `TAILSCALE_ALLOW_LAN_P2P=true` — allow direct Tailscale LAN P2P connections between devices on the same network.
  - **Default: `false`.** On campus or enterprise Wi-Fi (WPA2-Enterprise / 802.1x), AP Client Isolation blocks local device-to-device traffic. When Tailscale still attempts a local P2P upgrade, macOS's `gvproxy` layer SNAT-mangles the reply's source port. WireGuard's endpoint roaming treats this as a legitimate address change and updates the phone's outbound path to the newly-mangled port — which has no listener. This blackholes 100% of the phone's traffic while the DERP relay path is abandoned. Setting this to `false` preemptively drops all RFC1918-destined Tailscale UDP from the gateway so the phone receives a clean failure and safely falls back to DERP.
  - **Auto-managed:** `watcher.sh` automatically detects WPA2-Enterprise via `system_profiler SPAirPortDataType` (the `airport` binary was removed in macOS 14.4) and probes for AP isolation by pinging the default gateway (`route -n get 1.1.1.1`) on every network change. It writes the detected value to `.lan_p2p_detected` in the repo root, which `routing-fix.sh` re-reads every 30 seconds — **no restart required.** Only set this manually if auto-detection fails. See `devref.md §36` for the full SNAT endpoint poisoning analysis and `devref.md §40` for the `airport` removal background. *(Note: Direct P2P between the gateway container and the host Mac itself is always permitted via the Docker bridge to bypass DERP relays, regardless of this setting).*
  - Set to `true` on trusted home networks or Windows/mobile hotspots (no AP isolation) for a faster, lower-latency direct path.
- `WARP_FAIL_THRESHOLD=3` — number of consecutive failed checks before forcing a gateway teardown (default: 6 checks = 30s).
- `WARP_ENDPOINT_1` / `WARP_ENDPOINT_2` — override the Cloudflare WARP WireGuard endpoints.

### Linux — `scripts/toggle-linux.sh`
```bash
./scripts/toggle-linux.sh   # toggle ON/OFF
./scripts/recover-linux.sh  # recovery tool
```

### Sleep Prevention (macOS)
When the gateway is ON, `caffeinate -i` runs in the background to prevent idle system sleep, keeping Docker and all services alive even on battery. The display can still sleep normally.

### Auto-Recovery (macOS — post-wake / post-roam)
Install the launchd LaunchAgent so the gateway self-heals after sleep/wake and Wi-Fi roams:
```bash
cp ./launchd/com.nullexit.wake-recovery.plist ~/Library/LaunchAgents/
sed -i '' "s|__NULLEXIT_HOME__|$(pwd)|" ~/Library/LaunchAgents/com.nullexit.wake-recovery.plist
launchctl load -w ~/Library/LaunchAgents/com.nullexit.wake-recovery.plist
```
See `devref.md §11.16` for the full deep dive.

---

## 7. Networking Notes

- **Port conflicts:** None. Tailscale uses dynamic UDP ports; WARP uses outbound UDP:2408. The gateway binds `0.0.0.0:41642/udp` on the host for Tailscale's WireGuard listener — this is intentional and required to receive inbound hole-punch packets from peers on the internet. All other internal ports (AdGuard :5335, SOCKS5 :1080) are bound to `127.0.0.1` only and are not reachable from the LAN.
- **Tailscale P2P vs DERP:** On the same Wi-Fi, Tailscale establishes a fast P2P connection. On cellular (CGNAT), it always falls back to a DERP relay (~80-200ms). See `devref.md §5.1`.
- **AirDrop / AirPlay:** Unaffected — the gateway only touches standard Wi-Fi/Ethernet interfaces, not `awdl0`.
- **VPN coexistence:** Do **not** run a local VPN client (WARP, Mullvad, NordVPN) simultaneously with the exit node. Both fight for the default route and will blackhole your connection.
- **Banking & financial sites:** May intermittently block logins through WARP. Banks use anti-fraud databases that flag datacenter IP ranges (like Cloudflare's `104.28.x.x`) as VPN/proxy traffic. Success fluctuates depending on which WARP IP you land on. If a site blocks you, either disable the exit node temporarily for that session or use the bank's mobile app (which often uses different fraud detection).
- **MSS clamping (Bufferbloat):** Double-tunnelling adds ~120-160 bytes of overhead per packet. This is now automatically handled natively via the macOS `pf` firewall, which universally applies TCP MSS Clamping to all outbound packets to strictly prevent MTU fragmentation and bufferbloat. No manual `.env` configuration is required. Additionally, the host's Tailscale interface MTU is explicitly lowered to 1200 to guarantee packets fit inside the container's WARP tunnel without fragmenting.

---

## 8. Privacy & Security Hardening

The stack shifts trust across four layers: WARP hides traffic from your ISP, AdGuard blocks tracking at DNS, Tailscale encrypts device-to-device, and `ipset` blocks known malicious IPs at the kernel.

For higher security, the gateway supports these drop-in upgrades:

| Layer | Default | Hardened |
|---|---|---|
| VPN Exit | Cloudflare WARP (US) | Mullvad (Swedish, no-logs, anonymous payment) |
| DNS Resolver | AdGuard via WARP | AdGuard via Mullvad DoH |
| Coordination | Tailscale (US) | Headscale (self-hosted) |
| Auth | Persistent OAuth keys | Ephemeral auth keys |
| Content | WireGuard asymmetric | WireGuard + Pre-Shared Keys (PSK) |

See `devref.md §8` for the full threat model, Snowden programme analysis, and trust assumptions.

---

## 9. Debugging

- **`output.log`** — All stderr from `toggle.sh`, `recover.sh`, `setup.sh`, and the rule-compiler is written here. The WARP Watcher (`WARP_FAIL_THRESHOLD`) and the Host Leak Probe (`HOST_LEAK_PROBE`) also write all their events here — `LEAK`, `ROTATE`, `HOST-PROBE failed`, and WARP shutdown notices. Check this first.
- **`bash scripts/diagnose-host-leak.sh`** — One-shot host-routing diagnostic. Runs 8 checks and classifies your state into one of four known scenarios (System Extension conflict, SOCKS5 fallback, IPv6 leak, route-table freeze) or OK, and prints the exact fix command. Check 5 uses `route -n get 1.1.1.1` to ask the kernel which interface real traffic actually resolves through (more accurate than `netstat -rn | grep default` on macOS). Pass `--fix` to apply the remediation automatically. Pass `--watch` (or `--watch 30`) to run a full baseline diagnostic then continuously monitor warp/IPv6/default-route for leaks, alerting on any state change.
- **`bash scripts/host-leak-probe.sh`** — Sub-second host-egress prober (enabled automatically via `HOST_LEAK_PROBE=true` in `.env`). Polls `cdn-cgi/trace` every 300ms directly from the host NIC — not via `docker exec` — so it catches flash-leaks invisible to the in-container WARP Watcher. All state changes, curl errors, and probe timeouts land in `output.log`. Grep with `grep LEAK output.log`.
- **`bash scripts/fix-docker-bridge-collision.sh`** — One-shot fix for Docker bridge IP conflicts. If your local Wi-Fi router assigns you an IP in the `172.17.0.0/16` range, it will violently collide with Docker's default internal bridge, permanently killing your internet. This script detects the collision and auto-patches your Colima VM to use a safe subnet (e.g. `10.200.0.1/24`).
- **`devref.md`** — Complete architecture reference, routing deep-dives, and full resolved-issues log. Read this before modifying any routing or firewall logic.

> [!CAUTION]
> **Two infinite routing loops are possible.** (1) If a hotspot device providing internet to the gateway host is *also* using the gateway as its exit node, packets bounce forever between the two. (2) When the host's default route is redirected to `utun*`, WARP endpoint packets can loop back into the tunnel. Both are documented in `devref.md §11.10` and `§11.18` and are automatically handled by `toggle.sh`.

---

## 10. Acknowledgements
- **[SyameimaruKoa](https://github.com/SyameimaruKoa):** Dual-stack TCP MSS clamping, `SIGHUP` state-tracking in the routing sidecar, and `TS_AUTH_ONCE` integration.

## 11. License
GNU Affero General Public License v3. See [LICENSE](./LICENSE).

## 12. Changelog

- **July 10, 2026** — **Bug fixes:** 
  1. Resolved a race condition where Wi-Fi roaming caused the host IP to leak as the raw ISP IP (`132.x`) after every network switch. The WARP Watcher was firing nuclear shutdown while `recover.sh --post-wake` was still intentionally recreating the warp container. Fixed by adding a `/tmp/nullexit-warp-inhibit.marker` that pauses the watcher's failure counter during post-wake recovery. See `devref.md §25`.
  2. Resolved a startup race condition where the pre-flight connectivity check `[1/3] Gateway reachable via Tailscale` would fail because the host's `tailscaled` had not yet propagated the netmap immediately after `tailscale up --reset`. Upgraded the check to a 5-attempt retry loop with a 1-second delay. See `devref.md §26`.
  3. Resolved a concurrency collision where the network changes from a nuclear `recover.sh` teardown triggered `watcher.sh` to run `recover.sh --post-wake` in parallel, corrupting container states. Implemented a shared lifecycle lock (`/tmp/nullexit-toggle.lock`) across both scripts to safely skip post-wake logic during teardowns. See `devref.md §27`.
  4. Resolved an infinite auto-recovery loop after a tunnel failure shutdown. When the WARP Watcher triggered nuclear `recover.sh` to teardown the gateway, the active-state marker file `/tmp/nullexit-gateway-active.marker` was leaked on disk. The resulting network configuration changes from the teardown then triggered `watcher.sh`, which saw the marker and immediately restarted the gateway, looping indefinitely. Fixed by explicitly deleting the marker file at the start of nuclear `recover.sh`. See `devref.md §28`.
  5. Resolved a pre-flight check false negative during cold boots where the `[1/3] Gateway reachable via Tailscale` check would fail. Because gluetun blocks UDP STUN traffic to the public internet, Tailscale is forced to use a slower DERP-assisted handshake which takes ~30-35 seconds on cold boots. Increased the retry loop limit to 45 attempts (45s) to give the handshake sufficient time to complete. See `devref.md §29`.
  6. Resolved a startup race condition during restarts where `docker compose build` would fail with DNS resolution errors because physical Wi-Fi was power-cycled during teardown and Colima booted before the host obtained a DHCP lease. Implemented a unified `wait_for_dhcp_settle` helper (configured with a 30s timeout to tolerate macOS DHCP lease latency) in `scripts/common.sh` and added it to the start of `toggle.sh`. See `devref.md §30`.
  7. Resolved a bug where enabling the PF Kill-Switch during SOCKS5 fallback mode blocked all host traffic (including `tailscaled` daemon connections to the control plane) because SOCKS5 does not route non-TCP/system traffic. Removed kill-switch activation from the SOCKS5 fallback path in `toggle.sh`. See `devref.md §31`.
  8. Resolved a bug where host-side `tailscale up` calls passed the `--reset` flag, which aggressively cleared macOS Tailscale credentials and logged the user out. Removed the `--reset` flag from all host-side invocations to preserve authenticated sessions during exit-node state toggling. See `devref.md §32`.
  9. Resolved a bug where container connectivity check failures in `toggle.sh` and `recover.sh` were discarded to `/dev/null`. Redirected stderr of Docker exec checks to `output.log` to prevent diagnostic blind spots during tunnel outages. See `devref.md §33`.
- **July 6, 2026** — Edge-case security and stability hardening: DNS Watcher interface independence, robust lock-file PID verification, fail-closed crypto integrity check, strict `iptables` pinning for tailscale0↔tun0, Docker port binding to `127.0.0.1` to prevent LAN exposure, routing verification via `netstat -nr`. See `devref.md §12`.
- **July 4, 2026** — Colima bridged networking, SOCKS5 proxy migrated natively to Tailscale, headless prompt crashes fixed, proxy bypass domains added to fix LAN P2P. Python dependencies completely eliminated: `logger` and `rule-compiler` ported to blazing-fast Go multi-stage Docker builds. Added `crypto.sh` to enforce cryptographic signature validation on all core bash scripts. Massively refactored `toggle.sh` and `recover.sh` to eliminate ~200 lines of duplicated code by migrating network and process logic to `scripts/common.sh`. Added a concurrency mutex to `toggle.sh`, resolved unbound `TS_AUTHKEY` check crashes on setup, and integrated Go validation to the CI pipeline.
- **July 3, 2026** — **Critical Security Updates:** Addressed the overnight silent IP leak and improved geo-blocking. Introduced `scripts/host-leak-probe.sh` (a sub-second host-egress leak detector) and a statistical threshold auto-shutdown watcher. Added `unlock-files.sh` to safely reset file permissions. Resolved numerous startup regressions and system bugs.
- **July 2, 2026** — Two infinite routing loops resolved (`devref.md §11.18`): host-VM tunnel loop (WARP bypass routes now via gateway IP + manual `utun*` redirection) and Docker Compose subnet takeover (`10.200.1.0/24` lock). `--accept-routes=true` now explicit on all `tailscale up --reset` calls.
- **July 2, 2026** — Auto-recovery daemon documented in §6 above (`scripts/watcher.sh` + launchd plist). See `devref.md §11.16`.
- **July 2, 2026** — Linux scripts (`scripts/toggle-linux.sh`, `recover-linux.sh`, `setup-linux.sh`) documented in §6.
- **July 1, 2026** — `recover.sh --post-wake` ships; wired to watcher daemon. Triggered on every sleep/wake or network-state change.
- **June 28, 2026** — 8 internal scripts moved to `scripts/`. User-facing files (`toggle.sh`, `recover.sh`, `setup.sh`, `docker-compose.yml`) stay at repo root.
- **June 28, 2026** — All hardcoded install paths removed. `SCRIPT_DIR`-relative resolution and `__NULLEXIT_HOME__` placeholder used throughout.

### Cryptographic Integrity Verification

nullexit uses a built-in cryptographic integrity checker designed to provide tamper-*evidence* against accidental edits, logic bugs, or non-privileged malware. During setup, a 256-bit `NULLEXIT_SEED` is injected into your `.env` file. The core entrypoint scripts (`toggle.sh`, `recover.sh`, etc.) are hashed using HMAC-SHA256, and their signatures are stored in `.signatures`. 

*(Note: This is not a strict boundary against an attacker who already has write access to the repo, as they could simply read the seed and re-sign the scripts. It is designed as a strict footgun-catcher).*

If any script is modified without authorization, the gateway will loudly fail to boot. If you make intentional edits to the bash scripts, you must re-sign them by running:
```bash
./scripts/crypto.sh --sign
```
