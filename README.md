# nullexit: Tailscale + Cloudflare WARP Docker Gateway

**nullexit** is a chained network gateway that routes all Tailscale exit-node traffic through a Cloudflare WARP VPN tunnel.

## 1. Prerequisites
- Docker and Docker Compose installed.
- A Tailscale account.
  - *macOS Host:* Install the standalone Tailscale CLI via Homebrew (`brew install tailscale`) and register `tailscaled` as a system service (`brew services start tailscale`, optionally preceded by `sudo` for a system-wide LaunchDaemon that starts before login). No `.app` GUI install is required — `tailscale up` works directly because `tailscaled` is always listening on its local socket.
- `wgcf` tool to generate a WARP WireGuard profile.

## 2. Generate WARP WireGuard Profile
Use [`wgcf`](https://github.com/ViRb3/wgcf) to generate a Cloudflare WARP WireGuard profile.

1. Register a new identity:
   ```bash
   wgcf register
   ```
   Accept the Terms of Service. This will create a `wgcf-account.toml` file.

2. Generate the WireGuard profile:
   ```bash
   wgcf generate
   ```
   This will create a `wgcf-profile.conf` file.

3. Map the keys from `wgcf-profile.conf` to a `.env` file for your Docker setup. 
   Create a `.env` file in this directory and populate it:

   ```env
   # Extract these values from your generated wgcf-profile.conf
   WIREGUARD_PRIVATE_KEY=<PrivateKey from the [Interface] section>
   WIREGUARD_PUBLIC_KEY=<PublicKey from the [Peer] section>
   WIREGUARD_ADDRESSES=<Address from the [Interface] section (e.g., 172.16.0.2/32)>
   
   # Get this from your Tailscale Admin Console (Settings > Keys > Generate auth key)
   TS_AUTHKEY=tskey-auth-...

   # Optional: Toggle script settings (macOS)
   GATEWAY_RULE_PROFILE=medium        # light | medium | heavy (ad-blocking rule tier)
   GATEWAY_BYPASS_PING=false          # Skip exit-node ping verification on startup
   GATEWAY_USE_EXIT_NODE=true         # Set to false for DNS-only mode (no exit node)
   ```

## 3. Deploy the Gateway

### macOS (Recommended)
On macOS, use the toggle script which handles everything automatically — Colima VM lifecycle, Docker containers, DNS hijacking, Tailscale exit-node routing, ad-blocking rule compilation, and sleep prevention:
```bash
./toggle.sh
```
Running it again will stop the gateway and restore your network to its original state. See Section 6 for details on the toggle scripts and the companion `.app` launcher.

### Linux / Manual Deployment
On a native Linux host (or for manual control), start the containers directly:
```bash
docker compose up -d
```
*Note: Make sure your `.env` file is in the same directory as the `docker-compose.yml` file.*

## 4. Post-Deployment Instructions

### Approve the Exit Node
1. Go to the [Tailscale Admin Console - Machines](https://login.tailscale.com/admin/machines).
2. Locate the new `tailscale` device in your machine list.
3. Click the `...` menu next to the machine and select **Edit route settings...**.
4. Under the "Exit nodes" section, toggle the switch to approve this machine as an exit node.

### Verify the Traffic Flow
1. On your mobile device (or any other Tailscale client), open the Tailscale app.
2. Ensure Tailscale is connected.
3. Tap on "Exit Node" and select the newly deployed gateway node.
4. Visit a site like [ipinfo.io](https://ipinfo.io/) or [whatismyip.com](https://www.whatismyip.com/).
5. Your IP should now reflect a Cloudflare IP instead of your local ISP, confirming the tunnel-in-tunnel (Tailscale -> WARP) traffic flow is working successfully.

### Zero-Config Ad-Blocking (MagicDNS)
To ensure your phone and other Tailnet devices receive AdGuard filtering while using the exit node, you only need standard MagicDNS enabled — no custom Global Nameservers are required.

1. Go to the **Tailscale Admin Console → DNS**.
2. Ensure **MagicDNS** is enabled. (This sets `100.100.100.100` as the local DNS server for your devices).
3. **CRITICAL: Disable "Private DNS" on your mobile device.** Modern smartphones have built-in "Private DNS" or "Secure DNS" features that force DNS queries over TLS (port 853) or HTTPS (port 443). This bypasses the gateway's port 53 interception entirely, breaking ad-blocking and sometimes breaking the internet connection entirely.
   - **Android:** Go to `Settings -> Connections -> More connection settings -> Private DNS`, and change it to **Off**.
   - **iOS:** Ensure you don't have any custom DNS profiles installed in `Settings -> General -> VPN & Device Management`.

**How this works:** When a device (like your phone) routes its traffic through the **nullexit** exit node, all traffic — including DNS queries to `100.100.100.100` — passes through the gateway container. Our container automatically intercepts *any* traffic destined for port 53 using `PREROUTING` iptables rules. It seamlessly redirects those queries into the AdGuard container (port `5335`), stripping out ads before forwarding the query securely through Cloudflare WARP. You don't need to manually configure the container's Tailscale IP as a DNS server.

> [!WARNING]
> **Bandwidth Doubling on the Host Network:** When a remote device (like your phone on cellular or another Wi-Fi network) uses the exit node, the exit node machine must first download the traffic from the internet (via WARP), and then immediately upload it to your phone (via the Tailscale mesh). This means streaming a 1GB video on your phone will consume **1GB of download AND 1GB of upload (2GB total)** on the Wi-Fi or Ethernet network the exit node is connected to. Be mindful of this if your exit node machine is connected to a metered network or a cellular hotspot with strict data caps. *(Your phone's remote network will only consume the standard 1GB of download).*

## 5. AdGuard Home DNS Filtering

**nullexit** includes a seamlessly integrated instance of **AdGuard Home** to act as a network-wide ad and tracker sinkhole for all your Tailscale devices.

### Performance Impact
Because AdGuard Home intercepts and drops DNS queries for tracking and advertising domains *before* they are ever downloaded, it significantly reduces the CPU and rendering overhead on your devices. 

In automated headless browser tests (Lighthouse) loading ad-heavy sites like CNN over the exit node:
- **Time to Interactive (TTI):** Improved by **~18%** (51.0s → 41.8s)
- **Speed Index:** Improved by **~16%** (15.3s → 12.8s)

While the initial network ping (First Contentful Paint) is marginally slower due to the double-encryption tunnel (Tailscale + WARP), the real-world browsing experience is measurably faster and much smoother because your browser doesn't have to execute dozens of heavy tracking scripts.

### Automated Benchmarking
If you want to verify these speedups on your own machine, this repository includes an automated benchmark suite in the `benchmarks/` directory.

Simply run:
```bash
./benchmarks/benchmark.sh
```
This script will automatically:
1. Run a raw Python download test (`test_load.py`) and a headless Google Chrome `Lighthouse` HTML render test with the gateway **ON**.
2. Seamlessly toggle the gateway **OFF**.
3. Re-run all tests to establish a baseline.
4. Toggle the gateway back **ON**.

You can then compare the physical download speed and CPU "Time to Interactive" scores right in your terminal.

### Dashboard Access & Parental Controls
The AdGuard Home configuration is fully automated by `setup.sh`. To prevent accidental lockouts, the setup script hardcodes the default dashboard credentials. 

To manage your rules, access the AdGuard Dashboard:
1. Navigate to `http://<tailscale-ip-of-gateway>:3000` (or `http://100.100.21.8:3000` if using the static IP).
2. Log in with Username: **`admin`** | Password: **`nullexit`**

**Family & Parental Protection:** Because this exit node operates at the DNS level, it is incredibly powerful for family mesh networks. Inside the AdGuard dashboard, you can enable **Safe Search** (which intercepts and forces Google, Bing, and YouTube into family-safe modes at the network level, preventing users from bypassing it in their browser settings). You can also block specific apps (like TikTok) or subscribe to custom NSFW blocklists to instantly protect all devices connected to the exit node.

## 6. Quick Toggle Scripts (macOS & Windows)

For convenience (e.g., temporarily disabling the gateway for gaming), this repository includes native quick-toggle scripts for both operating systems. 

- **macOS:** The toggle logic lives in `toggle.sh`, a robust bash script with process timeouts, ordered VPN teardown, DNS recovery, and all the safeguards described in Section 9. You can launch it from a native macOS Application by compiling the provided `Toggle-Gateway.applescript` (which simply opens a Terminal window and runs `toggle.sh`):
  ```bash
  osacompile -o "Toggle Gateway.app" Toggle-Gateway.applescript
  ```
  This creates a self-contained app in the current directory. You can then right-click it and choose "Make Alias", and drag that alias to your Desktop for quick access. This ensures it intelligently toggles the **nullexit** gateway and the Colima VM on or off from the correct folder.
  
  **Automatic DNS Hijacking:** The toggle script automatically resolves your gateway's Tailscale IP by querying the container (`docker compose exec tailscale tailscale ip -4`) after it joins the mesh. It then overrides your host DNS servers with that IP so that AdGuard can intercept requests, block ads, and hand off any remaining legitimate traffic securely through the Tailscale mesh, which then routes it out through the Cloudflare WARP tunnel. No manual configuration file is needed.
  
  *Important Note on Routing:* Because `tailscaled` now runs as a background service, the host's mesh state is already determined before the toggle script runs — there is no need to launch any `.app` or click a menu bar item. When toggling ON, the script first issues `tailscale up --exit-node=` to clear any stale exit-node preference so the host can safely reach the gateway's `100.x.y.z` IP via plain Tailscale (otherwise we'd be routing the DNS lookup itself through a likely-dead exit node), and only then hijacks Wi-Fi DNS to the AdGuard container — **exclusively**, with no `1.1.1.1` fallback in the resolver list. Because the standalone `tailscaled` daemon briefly clobbers local DNS during the exit-node transition, the script calls `force_dns_to_gateway` once more at the very tail of the ENABLE branch and verifies via `networksetup -getdnsservers` that the host terminates pointing only at the AdGuard IP. When toggling OFF, the script reverts host DNS to `1.1.1.1` before halting containers, so a hung or failed stop can never leave you with no DNS.
  
- **Windows:** Simply double-click the `Toggle-Gateway.bat` script included in the root of the project. It natively hooks into Docker Desktop to cleanly toggle the **nullexit** gateway state without requiring manual command line input.

### System Sleep Prevention (macOS)

When the gateway is toggled ON, the script automatically launches `caffeinate -i` in the background to prevent macOS from entering idle sleep. This keeps Docker, the Colima VM, and all network services alive — even when the MacBook is unplugged from power and left unattended. Without this, macOS would eventually sleep and kill the gateway, breaking internet for all connected mobile devices using the exit node. *(If you are deploying this on another operating system or prefer a graphical interface, third-party utilities like **Amphetamine** achieve the exact same result).*

- **Screen behaviour:** The display is still allowed to turn off normally to conserve power. Only idle *system* sleep is prevented.
- **PID tracking:** The caffeinate process ID is stored in `/tmp/nullexit-caffeinate.pid` (outside the project directory).
- **Automatic cleanup:** When toggling OFF, on script error, or during recovery (`recover.sh`), the caffeinate process is automatically killed and the PID file removed.
- **Duplicate prevention:** If an old caffeinate process is still running from a previous session, the script kills it before starting a new one.

### Colima VM Teardown (Battery Saver)

By default, when you turn the gateway OFF, the `toggle.sh` script leaves the Colima Virtual Machine running in the background. This is the safest default, because forcibly killing Colima would instantly crash any other Docker containers you might be running for local web development.

However, if you are running **nullexit** on a dedicated laptop and *only* use Docker for this gateway, leaving the Linux VM running in the background wastes your host's RAM and drains the MacBook battery. 
To fix this, simply add `STOP_COLIMA_ON_EXIT=true` to your `.env` file. When this variable is detected, `toggle.sh` will completely shut down the Colima VM during its teardown sequence, ensuring zero background resource usage when the gateway is off.
## 7. Networking Notes

- **Port Usage**: Tailscale and WARP use entirely different internal ports, preventing any conflicts. Tailscale operates on random/dynamic UDP ports for its peer-to-peer mesh connections. Meanwhile, WARP's outbound WireGuard connection is explicitly targeting port 2408, which is the standard Cloudflare WARP destination port.
- **No Exposed Host Ports**: Because all communication relies purely on outbound tunnels, **nullexit** does not map or expose any ports to your local host machine.
- **Low-Latency Relay Path**: By default, forcing Tailscale traffic through WARP's strict NAT completely blackholes Tailscale's control and relay packets. **nullexit** mitigates this using a background policy routing script (`routing-fix.sh`) that identifies Tailscale's encrypted UDP packets (port `41641`) and forcibly ejects them out the raw `eth0` interface (bypassing WARP). This ensures Tailscale can reliably connect to the nearest local DERP relay (`relay "tor"` in Toronto) with very low latency (~27ms) instead of getting blocked.
- **VM Virtualization & DERP Fallback**: Because macOS/Windows runs Docker inside a Linux virtual machine, mapped UDP ports go through a user-space network proxy on the host. This proxy rewrites packet headers and masks source IPs/ports, which breaks Tailscale's STUN/WireGuard UDP hole-punching. Consequently, traffic to/from local peers on VM-based Docker hosts will always fall back to a DERP relay rather than establishing a direct P2P connection. For latency-sensitive applications like competitive gaming, it is recommended to disable the exit node and connect directly.


## 8. Privacy Architecture, Threat Model & Upgrades

### Layered Defense: What This Gateway Protects Against
This gateway stacks three layers of defense targeting different attack surfaces:
- **Layer 1 — ISP-Level Surveillance (Cloudflare WARP):** Your ISP is your most immediate privacy threat. In the US, ISPs can legally sell your browsing metadata to advertisers and are forced to comply with secret, gagged National Security Letters (NSLs). WARP routes all traffic through Cloudflare's network, so your ISP sees only an encrypted WireGuard tunnel to a Cloudflare IP.
- **Layer 2 — DNS Tracking (AdGuard Home):** DNS is the phone book of the internet. By default, queries go to your ISP's resolver, giving them a complete log of your traffic. AdGuard Home intercepts all DNS queries from devices on your Tailscale network, blocks trackers/ads before connections are made, and resolves queries through the WARP tunnel.
- **Layer 3 — Device Identity and IP Exposure (Tailscale):** On untrusted networks (coffee shops, public Wi-Fi), your device's IP is exposed. Tailscale creates an encrypted WireGuard mesh between your devices, routing all traffic safely to your home gateway exit node.

### The Documented Threat: Why This Matters
This architecture is calibrated against documented mass surveillance programs revealed in the Snowden disclosures:
- **PRISM:** Direct bulk collection of communication content from major tech providers.
- **UPSTREAM:** Tapping physical undersea/backbone fiber optic cables directly, collecting metadata and content in bulk.
- **XKeyscore:** An indexing system allowing retroactive search of unencrypted traffic.
- **MUSCULAR:** Infiltration of unencrypted internal datacenter interconnect links.

Passive bulk collection of browsing metadata is not paranoia; it is a documented reality. By double-encrypting and routing traffic, **nullexit** prevents your ISP from harvesting your metadata.

### Trust Assumptions & Shifting
Every component in this stack shifts trust rather than eliminating it:
1. **Physical Device Integrity:** You trust that your physical devices (phone, host computer) are not compromised.
2. **Cloudflare Integrity:** You trust Cloudflare not to correlate your WARP tunnel with decrypted exit traffic.
3. **Tailscale Integrity:** You trust Tailscale's coordination server not to perform a man-in-the-middle attack on WireGuard public keys.

The goal is to ensure **no single provider has a complete picture**. Your ISP sees an encrypted tunnel, Mullvad/WARP sees traffic with no account identity, and Tailscale/Headscale sees node topology but not content.

### Recommended Upgrades (Hardening the Stack)
For users requiring higher security levels, the gateway is designed to be fully compatible with these five hardening upgrades:

#### 1. Mullvad VPN (Replacing Cloudflare WARP)
Cloudflare is a US company subject to US jurisdiction. Swedish-based Mullvad is a privacy-first alternative:
- **Proven No-Logs:** Swedish police raided Mullvad's offices in 2023 and left empty-handed. No logs are kept.
- **No Identity Linkage:** Mullvad accounts are random numbers. You can pay using cash or Monero.
- **Gluetun Setup:** Replace `VPN_SERVICE_PROVIDER=custom` with `VPN_SERVICE_PROVIDER=mullvad` and provide your Mullvad WireGuard configuration in `docker-compose.yml`.

#### 2. Ephemeral Auth Keys (Reducing Tailscale Identity Linkage)
Logging into Tailscale with Google cryptographically links your Tailscale network to your Google identity.
- **How to harden:** Generate an **ephemeral auth key** in the Tailscale admin panel, and set it as `TS_AUTHKEY` in your `.env` file. These keys are used once to authenticate and cause the node to automatically disappear from your admin panel after it disconnects, breaking persistent identity linkage.

#### 3. Pre-Shared Keys / PSKs (Content Encryption)
Standard Tailscale relies on asymmetric keys distributed by their coordination server.
- **How to harden:** Generate and add a WireGuard **Pre-Shared Key (PSK)** manually between your peer nodes. This adds a symmetric encryption layer that Tailscale's coordination server has no knowledge of, blinding Tailscale from reading your transit content.

#### 4. Headscale (Self-Hosted Coordination Server)
Headscale is an open-source, self-hosted implementation of the Tailscale coordination server.
- **How to harden:** Point your Tailscale clients to a self-hosted Headscale instance on a VPS. This completely eliminates Tailscale the company, keeping all metadata and node topology entirely under your control.

#### 5. Hardening AdGuard Upstreams (Blinding Cloudflare via Mullvad DoH)
By default, AdGuard Home queries Gluetun's internal Unbound resolver (`127.0.0.1:53`), which forwards queries to Cloudflare (`1.1.1.1`) or Google (`8.8.8.8`) over plaintext. Although this traffic is encrypted inside the WARP tunnel, Cloudflare still acts as your ultimate DNS resolver.
- **How to harden:** You can completely blind Cloudflare from your DNS query content by pointing AdGuard Home's upstream resolvers directly to Mullvad's encrypted DNS-over-HTTPS (DoH) endpoints:
  - `https://dns.mullvad.net/dns-query` (Plain DNS resolution)
  - `https://adblock.dns.mullvad.net/dns-query` (Mullvad DNS-level ad blocking)
  - `https://extended.dns.mullvad.net/dns-query` (Mullvad ads + trackers + malware blocking)
- **Why this works:** When configured, AdGuard Home wraps queries in HTTPS before sending them. Cloudflare WARP only sees encrypted HTTPS packets going to Mullvad's IPs. Cloudflare is completely blind to your DNS queries, and Mullvad (a proven no-logs provider) resolves them.

### The Complete Hardened Stack

| Layer | Default Setup | Upgraded Setup |
|---|---|---|
| **VPN Exit** | Cloudflare WARP (US company) | Mullvad (Swedish, proven no-logs, anonymous payment) |
| **DNS Resolver** | AdGuard via WARP (plaintext upstreams) | AdGuard via Mullvad DoH (Cloudflare-blind queries) |
| **Coordination** | Tailscale (US company, OAuth) | Headscale (Self-hosted, no third-party) |
| **Authentication** | OAuth login / persistent keys | Ephemeral keys (no identity persistence) |
| **Content Security** | WireGuard asymmetric only | WireGuard + PSKs (coordination server blind) |

### Honest Remaining Limitations
- **Traffic Analysis / Metadata Surveillance:** Passive fiber tapping (UPSTREAM) can observe connection timestamps, data volumes, and IP ranges without reading content. Defeating traffic analysis requires mixing networks (like Tor) or continuous dummy packet padding, which heavily degrades performance.
- **Targeted State-Level Adversaries:** If a nation-state decides to actively target you, consumer-grade VPNs/proxies are not a complete shield. This stack is designed to defeat bulk passive surveillance and corporate dragnet collection.

## 9. Implementation Details

### Advanced Routing Hacks (Under the Hood)
Building this required navigating intense firewall and routing conflicts between two VPN clients fighting for control over the same network stack:
- **IPv6 Forwarding Bug:** Tailscale aggressively checks both IPv4 and IPv6 forwarding statuses in the kernel. If Docker disables IPv6 forwarding by default, Tailscale silently disables its Exit Node functionality. This is bypassed by explicitly setting `net.ipv6.conf.all.forwarding=1` in the Compose file.
- **Strict Firewall Loops (The "DERP" bypass):** Gluetun's strict leak-prevention firewall (`iptables-nft`) intentionally drops unrecognized forwarded traffic. Furthermore, its policy routing forces all returning traffic out the `tun0` (WARP) interface, creating a blackhole for returning Tailscale packets. This architecture deploys an automated sidecar container (`routing-fix`). It persistently injects a high-priority `ip rule` (`ip rule add to 100.64.0.0/10 lookup 52 pref 99`), ensuring returning packets bypass the VPN blackhole and flow back into the Tailscale mesh (allowing stable connections through local DERP relays).
- **Kernel-Space vs Userspace Conflict:** Tailscale is forced into kernel-space networking (`TS_USERSPACE=false`) because userspace mode prevents the container from functioning as a true Exit Node. This can occasionally cause Gluetun's strict health-checks to flap and restart due to kernel-table modifications. This is an accepted trade-off; Docker's `restart: unless-stopped` automatically recovers it, preserving maximum throughput.
- **VM Memory Overhead (Colima & Swap):** Because the host cannot run Linux containers natively, they must spin up a background Linux VM. To minimize host memory usage, the VM is restricted to a tight **512MB** of RAM (`colima start --memory 0.5`). To prevent out-of-memory (`OOMKilled`) crash loops on this tight memory limit while still running the comprehensive `medium` rule profile, **nullexit** automatically configures and activates a **512MB SSD swap file** inside the VM upon boot. To prevent unnecessary wear-and-tear on your host's SSD, the VM's default Linux `swappiness` is aggressively throttled down to `10`, ensuring the kernel strictly uses physical RAM first and only touches the SSD swap file as a last-resort safety net. Additional rule optimizations include subdomain deduplication (reducing lists by **~60%** with zero loss in blocking coverage). See Section 10 for details.

### "Blackhole Deadlock" Recovery
If the host machine is configured to route all traffic through the Tailscale Exit Node (which is hosted by **nullexit**), and the **nullexit** gateway is stopped or restarting, the host machine loses all internet connectivity. This creates a deadlock: Colima and the Docker daemon cannot fetch remote blocklists, pull images, or authenticate with Tailscale/WARP control servers because the host's network is completely blackholed. 

To solve this natively in `toggle.sh`:
1. **Immediate DNS Recovery:** The script immediately sets the host DNS to `1.1.1.1` at the very start of execution (for both starting and stopping). This ensures that if the script gets stuck or fails, the host is never left with a dead or unreachable DNS.
2. **Lightweight Disconnect:** With the standalone `tailscaled` daemon, the disable flow is just `tailscale down` — there is no `scutil --nc stop "Tailscale"` to undo, no AppleScript GUI quit, no `pkill`/`killall Tailscale`. We deliberately do **not** call `tailscale logout` because that would force a fresh browser-based authentication on every toggle, which would defeat the whole "toggle for gaming" workflow. The user's auth state persists in `tailscaled`'s state directory between toggle cycles, so reconnecting in milliseconds is the default.
3. **Process Timeout Hardening:** To prevent the script from hanging indefinitely when Docker compose, Colima, or Tailscale CLI commands block (common when the Docker socket or VM becomes unresponsive), we introduced a custom pure-bash watchdog system (`run_with_timeout`). Every system command is wrapped in a strict timeout (ranging from 15s to 120s). If a timeout is exceeded, the script terminates the active command, triggers the `cleanup_handler` to restore DNS to `1.1.1.1`, and exits cleanly.
4. **Pre-flight Exit-Node Clear:** At the very start of every enable flow we (re-)issue `tailscale up --exit-node=`, which is idempotent: it joins the mesh if the host is not already on it, and otherwise just clears any stale exit-node preference from a prior session. This *must* happen before Step 8's DNS hijack so the host can safely reach the gateway's `100.x.x.x` IP via the plain Tailscale mesh — otherwise we'd be routing the very DNS lookup that step 8 depends on through a possibly-dead exit node.
5. **Internal Docker Verification:** Rather than checking connectivity from the host (which could fail/deadlock if the host network is blocked), the script queries the container's status internally using `docker compose exec` over the local Docker socket to wait until the container has successfully joined the Tailscale mesh. Only after this verification succeeds does the script connect the host to the mesh and set the exit-node.
6. **Inline Auto-Compilation & Caching:** To prevent starting the gateway with stale configurations, the rule compiler (`sync-rules.py`) runs inline automatically on startup. We integrated a 24-hour file caching system under `adguard/work/userfilters/cache` to make toggling instant, falling back to cached copies if the host is offline. The gateway's Tailscale IP is also derived dynamically from the container at startup (`docker compose exec tailscale tailscale ip -4`), eliminating the need for a static `ADGUARD_IP.txt` file.
7. **Dual-State Active Gateway Detection:** To prevent starting the gateway when the user intends to stop it (e.g. if containers crashed but DNS remains hijacked), the script employs a smart state detection helper (`is_gateway_active`). The script considers the gateway active if **either** the containers are running **or** the host DNS is hijacked (not `1.1.1.1`). This ensures that running the toggle always triggers the STOP/cleanup branch when the network is in a dirty state.
8. **Standalone Daemon Resilience:** `tailscaled` is registered as a per-user LaunchAgent (`brew services start tailscale`, which `setup.sh` does automatically) or a system LaunchDaemon (`sudo brew services start tailscale`), so it is already running whenever the user is logged in — or before login, with `sudo`. The toggle script never has to launch an `.app`, fight a stuck Network Extension, or click the menu bar item: `tailscaled`'s local control socket is always reachable, and `tailscale up` / `tailscale down` are idempotent and run in a couple of seconds.
9. **Streamlined Daemon-Only Enable (Historical Context):** The previous five-phase flow was a workaround for macOS's sandboxed Network-Extension constraints: we had to launch `Tailscale.app`, click `Connect` in its menu bar via System Events (taking any failure as an abort signal with DNS still on `1.1.1.1`), poll the daemon, drop any stale exit-node preference, and finally call `scutil --nc start "Tailscale"` to engage the Network Extension. With the standalone `tailscaled` daemon, all five steps collapse into two CLI calls — verify `tailscale status` is responsive (15-second poll), then `tailscale up --exit-node=`. There is no `.app` to launch, no menu bar to click, no Network Extension sandbox to wake up, and no Accessibility permission required because nothing in the enable path touches the GUI.
10. **DNS Locked to Gateway Only, With Final Re-Force (No `1.1.1.1` Fallback):** Prior to this safeguard, `toggle.sh` configured DNS as `"$TS_IP" 1.1.1.1` and called it done. The host's resolver queries the DNS list in order and falls back to the next entry on timeout, so any extra entry creates a silent leak path that bypasses the gateway's ad-blocking the moment AdGuard is slow or unresponsive. We removed the fallback entirely: step 8 sets the DNS list to a single entry (the AdGuard IP) via `force_dns_to_gateway`, which both writes the setting *and* asserts via `networksetup -getdnsservers` that the only entry left is exactly that IP. Because the standalone `tailscaled` daemon briefly clobbers local DNS during the exit-node routing-table transition, `force_dns_to_gateway` is called a second time at the very tail of the ENABLE branch — well after step 9's `tailscale up --exit-node=...` has returned — and re-asserts the same single-server state across up to three progressively-backed-off attempts. The script ends only when the resolver is verifiably locked at AdGuard, or prints an explicit remediation command. A misbehaving gateway now produces a *visible* DNS outage (instead of silently falling through to `1.1.1.1`), which is the correct failure mode for a gateway whose whole purpose is filtering.

### AdGuard Home Local Cache Deception & Syntax Pitfalls
When modifying DNS rules, two hard-to-debug issues can block legitimate traffic even after adding domains to `white_list.txt`:
1. *Stale Filter Caching:* When referencing a local file path as a filter URL inside `AdGuardHome.yaml` (e.g. `/opt/adguardhome/work/userfilters/compiled_rules.txt`), AdGuard Home copies the rules into a database cache (`data/filters/*.txt`) and does *not* automatically monitor the local file for updates. Consequently, old rules (like a massive Facebook blocklist) remain loaded in-memory and cached. To resolve this, the compiler now automatically removes AdGuard's stale cached file (`4.txt`) and restarts the `adguardhome` container if active.
2. *Modifier Ordering Syntax:* When attempting to override wildcard whitelist rules with modifiers (e.g. blocking `an.facebook.com` using `$important` while whitelisting the rest of Facebook), the AdGuard separator `^` must precede the modifier. Writing `||domain$important^` is invalid and ignored; it must be written as `||domain^$important`. The rules engine now automatically checks for custom modifiers and structures them correctly.

### Debugging & Development
- **Logs:** If the `toggle.sh` script fails silently or behaves unexpectedly, all standard error output from its background processes and CLI calls is dumped into `output.log` in this directory. Always check `output.log` first.
- **Development Reference:** Before debugging, troubleshooting, or attempting to modify the routing architecture, **you MUST read** [`devref.md`](devref.md). This file contains the complete development history, a deep-dive analysis of the `rx 0` CGNAT bug, and an explanation of the conflicting macOS/Docker iptables stacks (`nftables` vs `legacy`). Do not attempt to fix network issues without reading it.


## 10. Custom Ad-Blocking Rules Engine
**nullexit** includes a powerful Python utility (`sync-rules.py`) to manage your own black/whitelist rules **and** subscribe to high-quality remote DNS blocklists. To guarantee cross-platform compatibility and eliminate host dependencies, this script is executed completely natively inside an ephemeral Alpine Docker container (`rule-compiler`) exactly once during the `docker compose up` sequence.

### Memory Profiles & Optimizations
Because macOS runs Docker containers inside a Colima VM (which we restrict to 512MB of RAM), loading huge blocklists (e.g. over 600,000 domains) would normally trigger out-of-memory (`OOMKilled`) crashes. 

To address this, two critical optimizations are built-in:
1. **Subdomain Deduplication**: In AdGuard Home syntax, `||domain.com^` automatically blocks all subdomains. The compiler automatically removes redundant subdomain rules (e.g., if `domain.com` is blocked, rules for `sub.domain.com` are skipped). This reduces the active rule count by **~60%** with **zero loss in blocking effectiveness**.
2. **Memory Profiles**: You can select a rule compilation tier in your `.env` file via `GATEWAY_RULE_PROFILE`:
   - `light` (Recommended for extremely low-memory hosts under 512MB RAM without swap): Generates **~52k** optimized rules.
   - `medium` (Default / Recommended balance, runs stably on 512MB RAM + 512MB Swap VM): Generates **~167k** optimized rules.
   - `heavy` (Highest security, requires increasing Colima memory allocation): Generates **~253k** optimized rules.

3. **Local SSD Caching**: To prevent unnecessary network saturation and API rate limits, the script caches all downloaded remote blocklists to your local disk. If a gateway reboot occurs within 24 hours of the last compile, the script bypasses the internet entirely and loads all lists concurrently from the SSD (often taking under 0.5 seconds).

### How to use:
1. Add domains you want to block to `black_list.txt` (e.g., `doubleclick.net`).
2. Add domains you want to forcefully allow to `white_list.txt` (e.g., `weather-analytics-events.apple.com`). Whitelists *always* win — they override every block source.
3. Configure `GATEWAY_RULE_PROFILE` in your `.env` file (defaults to `medium`).
4. Just restart the gateway! The `rule-compiler` init service will seamlessly re-compile everything automatically before AdGuard boots.

*Note: Because rule compilation is handled entirely by a Docker Compose init service, you never need to install Python on your host machine to run this gateway.*

### Whitelist Pattern: Use the Base Domain, Not the Subdomains

AdGuard's `||domain^` syntax matches a domain **and all of its subdomains**, so a single parent entry fans out to every subdomain automatically. This matters most for sites that host content on rotating or randomized subdomains you can't reasonably pre-enumerate.

**YouTube is the canonical example.** The actual video stream is served from servers like `r4---sn-25ge7ns7.googlevideo.com` (with new names per request), thumbnails come from rotating `i.ytimg.com` / `i1.ytimg.com` paths, and avatars come from `yt3.ggpht.com`. Listing each one would be impossible; instead `white_list.txt` carries the four base domains:

```text
youtube.com
googlevideo.com
ytimg.com
ggpht.com
```

One entry compiles to `@@||googlevideo.com^` and whitelistens every video stream server automatically. The redundant specific entries (`s.youtube.com`, `manifest.googlevideo.com`, etc.) above them are kept for human readability, but `sync-rules.py`'s subdomain optimizer collapses any subdomain whose parent is already in the list. The same pattern generalizes to any property that fans out across randomized subdomains (Spotify's `*.scdn.co`, Dropbox's `*.dl.dropboxusercontent.com`, social CDNs, etc.): roughly one short line per property family, regardless of how many subdomains it actually uses.

### Toggle Script Environment Variables
The `toggle.sh` script reads two optional `.env` settings:
- `GATEWAY_BYPASS_PING=true` — If the gateway container's Tailscale connection cannot be verified within the timeout, proceed with a warning instead of aborting and restoring DNS.
- `GATEWAY_USE_EXIT_NODE=false` — Skip forcing the host machine's traffic through the exit node, letting you control it manually or use DNS-only mode.

### Stability Incident Report
For a detailed write-up of the DNS deadlock, CLI hang, and Tailscale GUI launch issues that motivated the safeguards in `toggle.sh`, see [stability_incident_report.md](stability_incident_report.md).


## 11. Future Work
- **Direct P2P Traversal on VM Hosts (UDP Hole-Punching Constraints):** Because non-Linux hosts run Docker inside a Linux virtual machine, direct P2P connections are fundamentally blocked, forcing a fallback to local DERP relays. 
  - **Why Bridged VM Networking Still Fails:** Even if you configure the underlying Colima VM with true bridged networking (e.g., using `socket_vmnet` to get a physical LAN IP for the VM), direct connections still fail. This is because the Tailscale container runs inside Docker's bridged network namespace (`172.18.0.0/16`) and cannot see or advertise the VM's physical LAN IP to the Tailscale coordination server. It only advertises its private container IP, which is completely unroutable from your local network.
  - **The Only Working Solution (Dedicated Linux Host):** Deploying this container stack on a native Linux machine (e.g., a Raspberry Pi or Intel NUC) connected via Ethernet. Because Linux runs Docker natively without VM hypervisor translation or namespace network proxies, source IPs/ports are preserved and the host's physical network is directly accessible, allowing Tailscale P2P to establish direct connections out-of-the-box.
- **Native Linux Deployment:** Test and benchmark the architecture on a native Linux host (e.g., Raspberry Pi) to verify the native `~75MB` raw container footprint without the macOS hypervisor overhead.
- **Mesh-Wide Filesystem Access (SFTP over Tailscale):** Enable any device on the Tailscale mesh to passively expose its filesystem to all other mesh devices over SFTP, without requiring manual interaction on the source device.
  - **Proposed Implementation:** For Android devices, run a persistent SSH/SFTP server in the background using Termux (installed from F-Droid) with OpenSSH and a wakelock to prevent Android from suspending the process. This exposes shared storage to any mesh device at the device's static Tailscale IP. Because of iOS background process limitations, iOS devices will remain client-only (using apps like Secure ShellFish to browse other nodes).
  - **Key Constraints:** Android requires careful background process optimization and scoping to user-accessible storage only (unless rooted). Key-based authentication needs to be distributed consistently across mesh nodes.
  - **Outcome:** Every mesh device becomes a node in a fully accessible, distributed filesystem reachable from anywhere without touching the source device.
- **Post-Quantum Cryptography (PQC):** Tailscale currently relies on standard Curve25519 elliptic curve cryptography, which is theoretically vulnerable to future "harvest now, decrypt later" quantum attacks. To achieve true post-quantum resistance, future iterations of this gateway could completely eliminate the Tailscale container and replace it with a raw WireGuard mesh using [Rosenpass](https://rosenpass.eu/) to negotiate post-quantum Pre-Shared Keys (PSKs).
- **Decentralized Post-Quantum Blockchain Messaging:** To definitively defeat mass-surveillance dragnet tactics, future integrations could implement a hybrid protocol that is practically unbreakable against passive mass surveillance. By digitizing classic intelligence tradecraft, this architecture relies on five pillars:
  1. **In-person Key Exchange:** Exchanging a bundle of single-use Post-Quantum Pre-Shared Keys (PSKs) completely out-of-band, allowing for arbitrary-length messages without ever exposing the keys to network interception.
  2. **Blockchain Dead Drops:** Using an immutable, decentralized ledger via I2P as a censorship-resistant dead drop for the encrypted payloads.
  3. **Unconditional Network Presence (Defeating Daily Co-Presence):** If two nodes only ever connect to the I2P network on the same days, a global passive adversary can statistically correlate them over a 30-day period. To neutralize this, both parties must run persistent 24/7 full nodes. This ensures network co-presence is constant, carrying zero metadata. Reading a message becomes a purely local operation on an already-synced ledger, triggering zero new network activity.
     - *Fallback (Shared-Secret Scheduling):* If 24/7 nodes are impossible, connection days must be derived pseudorandomly from the PSK (e.g., `HMAC(shared_secret, week) mod 7`), making their connection days appear mathematically uncorrelated to outside observers.
  4. **Randomized Retrieval Windows (Defeating Within-Day Ordering):** When operating, senders and receivers interact with the network at independent, uniformly random times within the day. This completely breaks any sequential "Sender posts at 2 PM, Receiver reads at 4 PM" correlation.
  5. **Continuous Dummy Posting:** Pushing encrypted dummy posts alongside real messages on a continuous schedule, ensuring adversaries cannot build behavioral fingerprints or infer communication frequency.

  The underlying principle is absolute: any network behavior that is conditional on a message existing is a protocol-level side channel. This approach ensures that the only remaining vulnerabilities are targeted physical or endpoint compromises, creating an incredibly robust, zero-trust communication channel.

## 12. Acknowledgements
- **[SyameimaruKoa](https://github.com/SyameimaruKoa):** For providing advanced, production-grade architectural optimizations to this project, specifically the dual-stack TCP MSS clamping rules to prevent payload fragmentation stalls, the `SIGHUP` state-tracking logic in the routing sidecar to seamlessly survive Gluetun restarts, and the smart `TS_AUTH_ONCE` integration to prevent authentication crash loops.

## 13. License

This project is licensed under the GNU Affero General Public License version 3. See the [LICENSE](file:///Users/omar/Developer/nullexit/LICENSE) file for details.
