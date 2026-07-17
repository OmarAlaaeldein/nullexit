# nullexit: Tailscale + Cloudflare WARP Docker Gateway

> **Last updated:** July 12, 2026 · [Architecture & Flow Diagrams →](./diagrams.md) · [Full Dev Reference →](./devref.md)

**nullexit** is a chained network gateway that routes all Tailscale exit-node traffic through a Cloudflare WARP VPN tunnel — double-encrypting every packet, hiding your ISP metadata, and providing network-wide DNS ad-blocking (AdGuard Home) and kernel-level IP threat blocking (`ipset`/`iptables`) for every device on your mesh.

---

## 1. Prerequisites
- Docker and Docker Compose installed.
- A Tailscale account.
- **macOS:** Install the standalone Tailscale CLI via Homebrew (`brew install tailscale`) and register `tailscaled` as a system service (`brew services start tailscale`). No `.app` GUI install required.
- **OS & Python:** Developed and tested against **macOS 26.5.2**. The project has zero external Python dependencies (no `requirements.txt`) and explicitly targets the default Apple-provided **Python 3.9.6** (`/usr/bin/python3`). While the scripts could function on newer versions, `nullexit` explicitly avoids experimenting with or modifying the built-in system Python environment to prevent unexpected OS-level side effects.

## 2. Installation & Setup

Run the interactive setup script for your OS. It downloads `wgcf`, generates fresh Cloudflare WARP WireGuard keys, prompts for a Tailscale Auth Key, and writes your `.env`.

```bash
./setup.sh          # macOS
./scripts/setup-linux.sh  # Linux
```

### Reference `.env`
This is a quick reference of the common variables. For the **complete, authoritative list** of every `.env` variable (including all optional/advanced settings), see `devref.md §7`.
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
ADGUARD_USER=admin                 # Username for AdGuard Home (defaults to admin if not set)
ADGUARD_PASSWORD=nullexit          # Shared password for AdGuard Home and Tor ControlPort (defaults to nullexit if not set)
BLOCKED_COUNTRIES="kp il"          # dynamically block country IP ranges via ipdeny.com
TOR_EXCLUDE_EXIT_NODES=""          # comma-separated country codes to exclude as Tor exit nodes (e.g. {us},{gb})
DEBUG_TRACE=false                  # true = mirror a full command-by-command trace of the toggle to output.log (see §9)
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

> **Security Tip (Zero Local Attack Surface):** It is highly recommended to disable macOS's native "Remote Login" and "Screen Sharing" in System Settings to prevent exposing those ports (22, 5900) to physical Wi-Fi networks (which scanners can fingerprint). The gateway enforces `tailscale up --ssh=true` and the `pf` Kill-Switch automatically blocks local Wi-Fi access to these ports. Since both MagicDNS and Tailscale IPs route through the exact same encrypted tunnel, they are equally secure—but **MagicDNS is recommended simply for ease of use.**

### Extreme OPSEC: The Secret Tor-over-WARP Proxy
`nullexit` includes a completely isolated, headless Tor infrastructure proxy designed for terminals and hacking tools (e.g., `curl`, `sqlmap`, `nmap`).
To protect against local malware fingerprinting:
1. **Procedural Ports:** The proxy ports are randomized into the ephemeral range (10000-65000) on every single boot using a strict kernel socket collision-avoidance check (`netstat`). 
2. **Honey-Port Tripwire:** The gateway spawns a fake trap port. If any malware attempts a sequential port-scan on `localhost` to find the proxy, it trips the Honey-Port, instantly triggering a macOS desktop notification and a critical log alert.

> [!NOTE]  
> **Threat Model limitation:** Port randomization and the Honey-Port only defeat blind, generic port scanners. They do not protect against targeted local malware that runs `lsof -i` or reads the `/tmp/nullexit-ports.env` file directly. To actually prevent malicious local processes from reaching the proxy, you must run a host-level outbound firewall (like LuLu 4.3.0+ or Little Snitch) with **localhost/loopback filtering explicitly enabled** to gate access by process identity.

To use the Tor proxy, run `cat /tmp/nullexit-ports.env` to find your `$TOR_SOCKS_PORT` for the current session, and point your hardened browser (LibreWolf/Tor Browser) or CLI tool to `127.0.0.1:$TOR_SOCKS_PORT`.

> [!WARNING]  
> **Preventing DNS Leaks (SOCKS5 vs. SOCKS5-Hostname):**  
> When routing command-line tools through Tor, you **must** force the tool to delegate DNS resolution to the Tor proxy. Using plain SOCKS5 (e.g., `socks5://` or curl's `--socks5` flag) will resolve hostnames *locally* using the host's DNS settings (AdGuard/WARP) before establishing the connection. While this DNS traffic is encrypted inside the WARP tunnel, the destination domain name is still leaked to AdGuard and Cloudflare, undermining your anonymity.
> 
> Use these correct protocols and configurations:
> - **`curl`:** Use `--socks5-hostname` or the `socks5h://` scheme (e.g., `curl -x socks5h://127.0.0.1:$TOR_SOCKS_PORT https://check.torproject.org`). Do **not** use `--socks5` or `socks5://`.
> - **`sqlmap`:** Pass the proxy URL using the `socks5h://` scheme to ensure remote resolution: `--proxy="socks5h://127.0.0.1:$TOR_SOCKS_PORT"`.
> - **`nmap`:** Nmap's built-in `--proxies` option resolves hostnames locally. To safely scan targets without DNS leaks, tunnel it using `proxychains-ng` configured with `proxy_dns` enabled (add `socks5 127.0.0.1 <PORT>` to `/etc/proxychains.conf` or a local config, then run `proxychains4 nmap <args>`).


#### Transparent .onion Browsing & Dark Web Access
In addition to the randomized SOCKS5 proxy port, `nullexit` provides seamless, transparent `.onion` domain browsing for **all devices** on your Tailscale mesh:
- **Zero-Config DNS:** AdGuard Home automatically intercepts queries for `.onion` domains and resolves them to Tor's virtual mapping subnet.
- **Tailscale Auto-Routing:** The virtual subnet is mapped to the `198.18.0.0/15` benchmark range (RFC 2544). Since this range is not a private IP subnet, Tailscale's Exit Node mode automatically routes it to the gateway (bypassing local LAN exclusions).
- **Transparent NAT Proxying:** Kernel firewall rules in the gateway redirect all TCP traffic destined for `198.18.0.0/15` directly into Tor's transparent port (`9040`).
- **Exit Node Exclusion:** Supports the ability to exclude specific countries from being used as Tor exit nodes via the `TOR_EXCLUDE_EXIT_NODES` environment variable in `.env`.

##### Enable in Web Browsers
To prevent accidental DNS leaks, web browsers block `.onion` lookups by default. To browse dark web sites natively:
- **Firefox:** Go to `about:config`, search for `network.dns.blockDotOnion`, and set it to `false`. Type any onion address (e.g. `duckduckgogg42xjoc72x3sjasowoarfbgcmvfimaftt6twagswzczad.onion`) directly into the URL bar and it will load.
- **Mobile Browsers (iOS/Android):** Connect to your Tailscale exit node, open Firefox (with blockDotOnion disabled), and browse onion sites natively on the go.

#### Hardening: Using obfs4 Tor Bridges
If you want to disguise your Tor traffic from the WARP exit node provider, you can optionally enable Tor bridges:
1. Obtain private `obfs4` bridge lines from [bridges.torproject.org](https://bridges.torproject.org) or the official Telegram bot.
2. Create a file named `tor-bridges.txt` in the root of the `nullexit` folder and paste your bridge lines inside it (one per line).
3. Set `TOR_USE_BRIDGES=true` in your `.env` file and restart the gateway. The proxy will refuse to start if the bridges file is empty or missing.

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
  echo "$USER ALL=(root) NOPASSWD: /sbin/pfctl, /usr/sbin/networksetup, /usr/bin/dscacheutil, /usr/bin/killall, /usr/bin/pkill, /bin/kill, /sbin/route, /sbin/ifconfig, /usr/bin/true, /opt/homebrew/bin/brew, /usr/local/bin/brew, /usr/bin/python3 -I $PWD/scripts/dns-proxy.py, /opt/homebrew/bin/python3 -I $PWD/scripts/dns-proxy.py, /usr/local/bin/python3 -I $PWD/scripts/dns-proxy.py" | sudo tee /etc/sudoers.d/nullexit
  ```

---

## 6. Toggle Scripts

### macOS — `toggle.sh`
Fully automated lifecycle script. Also supports a native `.app` launcher:
```bash
osacompile -o "Toggle Gateway.app" Toggle-Gateway.applescript
```

Optional `.env` settings (common subset; the full canonical table lives in `devref.md §7`):
- `GATEWAY_BYPASS_PING=true` — proceed even if pre-flight connectivity checks fail.
- `GATEWAY_USE_EXIT_NODE=false` — DNS-only mode, skip exit-node routing.
- `GATEWAY_HIJACK_HOST=false` — skip DNS hijacking on the host (provides VPN/adblocking only to external Tailscale peers).
- `GATEWAY_MSS=1180` — override the TCP MSS clamp for the double-tunnel (default `1120`; raise to `1180` for more speed on a healthy path).
- `HOST_MTU=1200` — override the host Tailscale interface MTU. Defaults to 1200 to fit inside the 1280-byte WARP tunnel.
- `KILL_SWITCH=true` — enforce strict network lock that breaks SSH if the VPN fails.
- `STOP_COLIMA_ON_EXIT=true` — fully shut down the Colima VM on toggle-off (saves battery on dedicated hosts).
- `TAILSCALE_ALLOW_LAN_P2P=true` — allow direct Tailscale LAN P2P connections between devices on the same network.
  - **Default: `false`.** On campus or enterprise Wi-Fi (WPA2-Enterprise / 802.1x), AP Client Isolation blocks local device-to-device traffic. When Tailscale still attempts a local P2P upgrade, macOS's `gvproxy` layer SNAT-mangles the reply's source port. WireGuard's endpoint roaming treats this as a legitimate address change and updates the phone's outbound path to the newly-mangled port — which has no listener. This blackholes 100% of the phone's traffic while the DERP relay path is abandoned. Setting this to `false` preemptively drops all RFC1918-destined Tailscale UDP from the gateway so the phone receives a clean failure and safely falls back to DERP.
  - **Auto-managed:** `watcher.sh` automatically detects WPA2-Enterprise via `system_profiler SPAirPortDataType` (the `airport` binary was removed in macOS 14.4) and probes for AP isolation by pinging the default gateway (`route -n get 1.1.1.1`) on every network change. It writes the detected value to `.lan_p2p_detected` in the repo root, which `routing-fix.sh` re-reads every 30 seconds — **no restart required.** Only set this manually if auto-detection fails. See `devref.md §15.7.1` for the full SNAT endpoint poisoning analysis and `devref.md §15.11.6` for the `airport` removal background. *(Note: Direct P2P between the gateway container and the host Mac itself is always permitted via the Docker bridge to bypass DERP relays, regardless of this setting).*
  - Set to `true` on trusted home networks or Windows/mobile hotspots (no AP isolation) for a faster, lower-latency direct path.
- `WARP_FAIL_THRESHOLD=3` — number of consecutive failed checks before forcing a gateway teardown (default: 6 checks = 30s).
- `WARP_ENDPOINT_1` / `WARP_ENDPOINT_2` — override the Cloudflare WARP WireGuard endpoints.

### Linux — `toggle.sh` / `recover.sh`
```bash
./toggle.sh    # toggle ON/OFF   (cross-platform, dispatches on $OSTYPE)
./recover.sh   # recovery tool   (cross-platform)
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
See `devref.md §15.5.1` for the full deep dive.

---

## 7. Networking Notes

- **Port conflicts:** None. Tailscale uses dynamic UDP ports; WARP uses outbound UDP:2408. The gateway binds `0.0.0.0:41642/udp` on the host for Tailscale's WireGuard listener — this is intentional and required to receive inbound hole-punch packets from peers on the internet. All other internal ports (AdGuard :5335, SOCKS5 :1080) are bound to `127.0.0.1` only and are not reachable from the LAN.
- **Tailscale P2P vs DERP:** On the same Wi-Fi, Tailscale establishes a fast P2P connection. On cellular (CGNAT), it always falls back to a DERP relay (~80-200ms). See `devref.md §5.1`.
- **AirDrop / AirPlay:** Unaffected — the gateway only touches standard Wi-Fi/Ethernet interfaces, not `awdl0`.
- **VPN coexistence:** Do **not** run a local VPN client (WARP, Mullvad, NordVPN) simultaneously with the exit node. Both fight for the default route and will blackhole your connection.
- **Banking & financial sites:** May intermittently block logins through WARP. Banks use anti-fraud databases that flag datacenter IP ranges (like Cloudflare's `104.28.x.x`) as VPN/proxy traffic. Success fluctuates depending on which WARP IP you land on. If a site blocks you, either disable the exit node temporarily for that session or use the bank's mobile app (which often uses different fraud detection).
- **MSS clamping (Bufferbloat):** Double-tunnelling adds ~120-160 bytes of overhead per packet. This is now automatically handled natively via the macOS `pf` firewall, which universally applies TCP MSS Clamping to all outbound packets to strictly prevent MTU fragmentation and bufferbloat. No manual `.env` configuration is required. Additionally, the host's Tailscale interface MTU is explicitly lowered to 1200 (configurable via `HOST_MTU` in `.env`) to guarantee packets fit inside the container's WARP tunnel without fragmenting.

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

#### Python Runtime Airgap (Isolated Mode)
**Never** install third-party `pip` packages (like `requests` or `pyyaml`) into the Python environment that `nullexit` uses. All python scripts in this project (e.g., the `dns-proxy.py` daemon) are strictly engineered to run on the zero-dependency Python Standard Library. To strictly isolate the environment from supply-chain attacks, `nullexit` executes these scripts using **Python's Isolated Mode** (`python3 -I`). This deliberately blinds the execution environment to any malicious user-installed `pip` packages on the host, permanently air-gapping the gateway from PyPI.

See `devref.md §9` for the full threat model, Snowden programme analysis, and trust assumptions.

---

## 9. Debugging

- **`output.log`** — All stderr from `toggle.sh`, `recover.sh`, `setup.sh`, and the rule-compiler is written here. The WARP Watcher (`WARP_FAIL_THRESHOLD`) also writes its events here — `WARP DOWN`, `WARP RECOVERED`, and `WARP SHUTDOWN` notices. Check this first.
  - Every run now records lifecycle breadcrumbs regardless of `DEBUG_TRACE`: an `EXEC:` / `EXIT <code>:` line brackets each heavyweight command (`colima start`, `docker compose up -d --build`, `docker compose down`), and an `EXIT: code=<N> phase=<init|stop|start>` line is written when the script exits **for any reason** — including a killed terminal, `pkill`, or OOM. This closes a prior blind spot where an interrupted **START** (e.g. a `--restart` race while Wi-Fi was re-associating) left the log ending abruptly after the teardown with no indication of what failed. If a toggle "does nothing" or the gateway ends up half-up, `grep -E 'EXEC:|EXIT ' output.log | tail` shows the last command run and its result.
- **`DEBUG_TRACE=true`** (in `.env`) — Full command-by-command execution trace of `toggle.sh`, mirrored to `output.log` for deep post-mortems of intermittent failures. Each traced line is timestamped and tagged with `file:line:function` (via a custom `PS4`), so you can follow the *exact* code path a run took — including subshells, Docker/Colima calls, and where it aborted. Off by default because it is verbose (the log grows quickly); enable it only while reproducing a specific problem, then set it back to `false`. Implementation note: it prefers bash's `BASH_XTRACEFD` (bash ≥ 4.1, e.g. most Linux) to send the trace to the log while keeping your terminal clean; on macOS's stock `/bin/bash` 3.2 it transparently falls back to teeing stderr to the log (trace also appears in the terminal). It never uses the dynamic-fd (`exec {var}>>`) form, so it is safe on 3.2. To read a trace: `grep -nE '^\+ ' output.log`.
- **`bash scripts/diagnose-host-leak.sh`** — One-shot host-routing diagnostic. Runs 8 checks and classifies your state into one of four known scenarios (System Extension conflict, SOCKS5 fallback, IPv6 leak, route-table freeze) or OK, and prints the exact fix command. Check 5 uses `route -n get 1.1.1.1` to ask the kernel which interface real traffic actually resolves through (more accurate than `netstat -rn | grep default` on macOS). Pass `--fix` to apply the remediation automatically. Pass `--watch` (or `--watch 30`) to run a full baseline diagnostic then continuously monitor warp/IPv6/default-route for leaks, alerting on any state change.
- **`bash scripts/sweep.sh`** — One-shot, read-only gateway health sweep. Runs 6 checks — containers up/healthy, double-tunnel/IP-leak (host egress == container egress with `warp=on`), direct P2P to the gateway (no DERP relay), AdGuard compiled-rule counts + live DNS interception, PF kill-switch armed, and tailnet reachability (a `tailscale ping` to every online peer) — then rolls them into a PASS/WARN/FAIL verdict. Writes a timestamped `sweep-<UTC>.txt` report to the repo root (diffable across runs) and exits non-zero on FAIL, so it can gate launchd hooks or CI. Pass `--quiet` for just the verdict line. It never mutates routing, PF, DNS, or containers — safe to run against a live gateway at any time.
- **`bash scripts/fix-docker-bridge-collision.sh`** — One-shot fix for Docker bridge IP conflicts. If your local Wi-Fi router assigns you an IP in the `172.17.0.0/16` range, it will violently collide with Docker's default internal bridge, permanently killing your internet. This script detects the collision and auto-patches your Colima VM to use a safe subnet (e.g. `10.200.0.1/24`).
- **`devref.md`** — Complete architecture reference, routing deep-dives, and full resolved-issues log. Read this before modifying any routing or firewall logic.

> [!CAUTION]
> **Two infinite routing loops are possible.** (1) If a hotspot device providing internet to the gateway host is *also* using the gateway as its exit node, packets bounce forever between the two. (2) When the host's default route is redirected to `utun*`, WARP endpoint packets can loop back into the tunnel. Both are documented in `devref.md §15.2.1` and `§15.2.2` and are automatically handled by `toggle.sh`.

---

## 10. Unified Project Document (Quine)

The project includes a `generate_tex.py` script that compiles the entire source code, configurations, and documentation into a single, unified LaTeX document (`nullexit_unified.tex` / `.pdf`).

Funnily enough, this document acts as a "project-level quine." It encapsulates the entirety of its own source code, its documentation, and the exact Python code required to generate itself. It serves as a self-contained, long-term archiving strategy—providing everything needed to reconstruct and understand the `nullexit` system from a single file.

---

## 11. Acknowledgements
- **[SyameimaruKoa](https://github.com/SyameimaruKoa):** Dual-stack TCP MSS clamping, `SIGHUP` state-tracking in the routing sidecar, and `TS_AUTH_ONCE` integration.

## 12. License
GNU Affero General Public License v3. See [LICENSE](./LICENSE).

## 13. Changelog

- **July 17, 2026** — `scripts/sweep.sh` (the read-only automated health sweep added July 15, mirroring `sweep.md §1`) gained a 6th check: **tailnet reachability** — every Tailscale peer reported online is probed with `tailscale ping` (TSMP, so it works even on phones that drop ICMP) and rolled into the PASS/WARN/FAIL verdict. Documented in §9 above.
- **July 12, 2026** — Tor ControlPort dynamic password authentication (unified with `ADGUARD_PASSWORD`), enabling live circuit inspection via `/sweep`. See `devref.md §15.10.2`.
- **July 11, 2026** — Tor container hardening: `obfs4proxy` restored (base image → `debian:bookworm-slim`), robust bridge-file validation, and image pinning. See `devref.md §15.10.1`.
- **July 10, 2026** — Roaming/startup stabilization suite: fixed the Wi-Fi-roam host-IP leak (raw ISP `132.x`) caused by the WARP Watcher racing post-wake recovery, plus a batch of pre-flight/concurrency/kill-switch/Tailscale-flag bugs and the macOS SNAT endpoint-poisoning P2P blackhole. Full post-mortems in the Incident Log — see `devref.md §15.2.7`, `§15.5.3`–`§15.5.5`, `§15.2.8`–`§15.2.9`, `§15.7.1`, `§15.7.3`–`§15.7.5`, `§15.12.18`.
- **July 6, 2026** — Edge-case security and stability hardening: DNS Watcher interface independence, robust lock-file PID verification, fail-closed crypto integrity check, strict `iptables` pinning for tailscale0↔tun0, Docker port binding to `127.0.0.1` to prevent LAN exposure, routing verification via `netstat -nr`. See `devref.md §17`.
- **July 4, 2026** — Colima bridged networking, SOCKS5 proxy migrated natively to Tailscale, headless prompt crashes fixed, proxy bypass domains added to fix LAN P2P. Python dependencies completely eliminated: `logger` and `rule-compiler` ported to blazing-fast Go multi-stage Docker builds. Added `crypto.sh` to enforce cryptographic signature validation on all core bash scripts. Massively refactored `toggle.sh` and `recover.sh` to eliminate ~200 lines of duplicated code by migrating network and process logic to `scripts/common.sh`. Added a concurrency mutex to `toggle.sh`, resolved unbound `TS_AUTHKEY` check crashes on setup, and integrated Go validation to the CI pipeline.
- **July 3, 2026** — **Critical Security Updates:** Addressed the overnight silent IP leak and improved geo-blocking. Introduced `scripts/host-leak-probe.sh` (a sub-second host-egress leak detector) and a statistical threshold auto-shutdown watcher. Added `unlock-files.sh` to safely reset file permissions. Resolved numerous startup regressions and system bugs.
- **July 2, 2026** — Two infinite routing loops resolved (`devref.md §15.2.2`): host-VM tunnel loop (WARP bypass routes now via gateway IP + manual `utun*` redirection) and Docker Compose subnet takeover (`10.200.1.0/24` lock). `--accept-routes=true` now explicit on all `tailscale up --reset` calls.
- **July 2, 2026** — Auto-recovery daemon documented in §6 above (`scripts/watcher.sh` + launchd plist). See `devref.md §15.5.1`.
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
