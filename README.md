# nullexit: Tailscale + Cloudflare WARP Docker Gateway

**nullexit** is a chained network gateway that routes all Tailscale exit-node traffic through a Cloudflare WARP VPN tunnel.

## 1. Prerequisites
- Docker and Docker Compose installed.
- A Tailscale account.
  - *macOS Host:* We recommend installing the Tailscale GUI application via Homebrew (`brew install --cask tailscale-app`). Note that because the GUI app is sandboxed, you cannot run a Tailscale SSH server on this macOS host. However, you can still easily SSH outbound to any other device on your tailnet by using its MagicDNS address directly (e.g., `ssh user@device.tailnet-name.ts.net`).
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
   ```

## 3. Deploy the Gateway

Run the following command to start the **nullexit** gateway in the background:
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

## 5. AdGuard Home DNS Filtering

**nullexit** includes a seamlessly integrated instance of **AdGuard Home** to act as a network-wide ad and tracker sinkhole for all your Tailscale devices.

### Setup Instructions
1. Navigate to `http://<tailscale-ip-of-gateway>:3000` in your web browser.
2. Under "Listen Interfaces", set the **Web interface** port to `80` (or `8080`) and the **DNS server** port to **`5335`**.
3. Finish the wizard by setting up your admin account.
4. Log into AdGuard Home, go to **Settings -> DNS Settings**.
5. Delete the default upstream servers and enter `127.0.0.1:53`. This securely routes your DNS requests back through the WireGuard WARP tunnel.
6. Add your favorite community blocklists (like OISD) under **Filters -> DNS blocklists**.

*Note: Custom `iptables` rules automatically intercept all DNS requests hitting the Tailscale IP and seamlessly redirect them to AdGuard Home on port 5335 without conflicting with the VPN's internal DNS.*

## 6. Quick Toggle Scripts (macOS & Windows)

For convenience (e.g., temporarily disabling the gateway for gaming), this repository includes native quick-toggle scripts for both operating systems. 

- **macOS:** The toggle logic lives in `toggle.sh`, a robust bash script with process timeouts, ordered VPN teardown, DNS recovery, and all the safeguards described in Section 8. You can launch it from a native macOS Application by compiling the provided `Toggle-Gateway.applescript` (which simply opens a Terminal window and runs `toggle.sh`):
  ```bash
  osacompile -o "Toggle Gateway.app" Toggle-Gateway.applescript
  ```
  This creates a self-contained app in the current directory. You can then right-click it and choose "Make Alias", and drag that alias to your Desktop for quick access. This ensures it intelligently toggles the **nullexit** gateway and the Colima VM on or off from the correct folder.
  
  **Automatic DNS Hijacking:** To ensure you maintain complete control of your DNS, create a text file named `ADGUARD_IP.txt` in the same directory and paste just your Tailscale IP address inside it (e.g. `100.x.x.x`). This is specifically required on macOS because the system often maintains a persistent list of default DNS servers that cannot be easily removed. The only reliable way to override them is to actively write your new AdGuard DNS IP over them so that AdGuard can intercept requests, block ads, and hand off any remaining legitimate traffic securely through the Tailscale mesh, which then routes it out through the Cloudflare WARP tunnel. 
  
  *Important Note on Routing:* The macOS script will automatically run `tailscale up` to ensure your Mac's host device is connected to the Tailscale mesh. This is critical—if the underlying Mac isn't connected to Tailscale, the Wi-Fi interface cannot route to the AdGuard container's `100.x.y.z` IP, meaning your device would lose internet access entirely. Once Tailscale is running, the script successfully updates your Mac's Wi-Fi DNS to route through AdGuard when toggled ON, and reverts it to 1.1.1.1 when toggled OFF.
  
- **Windows:** Simply double-click the `Toggle-Gateway.bat` script included in the root of the project. It natively hooks into Docker Desktop to cleanly toggle the **nullexit** gateway state without requiring manual command line input.

## 7. Networking Notes

- **Port Usage**: Tailscale and WARP use entirely different internal ports, preventing any conflicts. Tailscale operates on random/dynamic UDP ports for its peer-to-peer mesh connections. Meanwhile, WARP's outbound WireGuard connection is explicitly targeting port 2408, which is the standard Cloudflare WARP destination port.
- **No Exposed Host Ports**: Because all communication relies purely on outbound tunnels, **nullexit** does not map or expose any ports to your local host machine.

## 8. Architecture & Security Insights

This setup implements a highly secure, zero-trust "Tunnel-in-Tunnel" architecture by aggressively routing a Tailscale Exit Node directly through a Gluetun-managed Cloudflare WARP tunnel.

### Traffic Flow & Double Encryption
1. **Device to Gateway (Tailscale):** Traffic leaving your client device (e.g., your phone) is encrypted using Tailscale's WireGuard implementation. It travels securely over the internet or cellular network to your **nullexit** gateway.
2. **Gateway to Internet (Cloudflare WARP):** Inside the Docker network namespace, the Tailscale container passes the decrypted traffic to the Gluetun container. Gluetun immediately re-encrypts the traffic using standard WireGuard and forces it out through Cloudflare WARP's infrastructure.

This creates a **Double Encryption** scenario. While this inherently introduces a slight latency penalty due to the encryption overhead and geographical routing (bouncing to your home gateway before routing to the broader internet), it ensures total privacy from local ISPs, public Wi-Fi administrators, and even the host network itself.

**Note on Threat Model:** The outer WARP tunnel terminates at Cloudflare. While your traffic is double-encrypted in transit to the gateway and then to the edge, you are ultimately trusting Cloudflare to route the decrypted (inner HTTPS) traffic. Cloudflare will see the destination IPs and SNIs of your requests, though the actual payload remains HTTPS encrypted.

### Threat Model & Trust Assumptions
While this architecture effectively neutralizes local network threats (like man-in-the-middle attacks on cafe Wi-Fi) because traffic is heavily encrypted before touching a public network, it introduces a significant trust assumption:
1. **Physical Mesh Integrity:** Your physical devices (phone, host computer) and their private keys are not compromised.
2. **Cloudflare Integrity:** You are fully trusting Cloudflare not to maliciously log, intercept, or correlate your WARP connection with your decrypted exit traffic. This is a non-trivial assumption for a serious threat model.
3. **Operational Risk (`TS_AUTHKEY`):** Although the container environment is configured with `TS_AUTH_ONCE=true` to prevent expiration crash loops (by ignoring the `TS_AUTHKEY` environment variable once the container is authenticated), the key will still remain permanently visible in the raw `docker inspect` output. Anyone with socket access to your local Docker daemon can view it. However, this risk is largely moot: gaining socket access requires host-level access, which violates the first assumption of our threat model (Physical Mesh Integrity). If an attacker can run `docker inspect`, the physical device is already compromised.

### Advanced Routing Hacks (Under the Hood)
Building this required navigating intense firewall and routing conflicts between two VPN clients fighting for control over the same network stack:
- **IPv6 Forwarding Bug:** Tailscale aggressively checks both IPv4 and IPv6 forwarding statuses in the kernel. If Docker disables IPv6 forwarding by default, Tailscale silently disables its Exit Node functionality. This is bypassed by explicitly setting `net.ipv6.conf.all.forwarding=1` in the Compose file.
- **Strict Firewall Loops (The "DERP" bypass):** Gluetun's strict leak-prevention firewall (`iptables-nft`) intentionally drops unrecognized forwarded traffic. Furthermore, its policy routing forces all returning traffic out the `tun0` (WARP) interface, creating a blackhole for returning Tailscale packets. While most community setups accept degraded, slow DERP relay connections here, this architecture deploys an automated sidecar container (`routing-fix`). It persistently injects a high-priority `ip rule` (`ip rule add to 100.64.0.0/10 lookup 52 pref 99`), ensuring returning packets bypass the VPN blackhole and establish high-speed, direct P2P connections back into the Tailscale mesh.
- **Kernel-Space vs Userspace Conflict:** Tailscale is forced into kernel-space networking (`TS_USERSPACE=false`) because userspace mode prevents the container from functioning as a true Exit Node. This can occasionally cause Gluetun's strict health-checks to flap and restart due to kernel-table modifications. This is an accepted trade-off; Docker's `restart: unless-stopped` automatically recovers it, preserving maximum throughput and Exit Node capabilities.
- **macOS Memory Overhead (Colima):** Because macOS cannot run Linux containers natively, Colima must spin up a background Linux VM. While the actual containers (`warp`, `tailscale`, `routing-fix`) only consume roughly `~75MB` of RAM combined, loading massive blocklists into AdGuard Home requires significant memory. We recommend running the VM stably at `0.6 GB` (614MB) of RAM (`colima start --memory 0.6`). To prevent out-of-memory (`OOMKilled`) crash loops on this tight memory limit, the rules compiler uses **subdomain deduplication** (shrinking lists by **~60%** with zero loss in blocking coverage) and customizable **memory profiles** (`light`, `medium`, `heavy`). See Section 9 for details.
- **Host DNS/Exit-Node Deadlock (The Catch-22):** If the macOS host is configured to route all traffic through the Tailscale Exit Node (which is hosted by **nullexit**), and the **nullexit** gateway is stopped or restarting, the host Mac loses all internet connectivity. This creates a deadlock: Colima and the Docker daemon cannot fetch remote blocklists, pull images, or authenticate with Tailscale/WARP control servers because the host's network is completely blackholed. 
  To resolve this, we implemented eight key safeguards in our toggle script:
  1. **Immediate DNS Recovery:** The script immediately sets the macOS host DNS to `1.1.1.1` at the very start of execution (for both starting and stopping). This ensures that if the script gets stuck or fails, the host is never left with a dead or unreachable DNS.
  2. **Ordered VPN Teardown:** To prevent the macOS Network Extension from getting orphaned in a `Connected` state when terminating the Tailscale GUI app, the script executes teardown in a strict sequence: it stops the tunnel first (`scutil --nc stop`), waits 1.5 seconds for the extension to disconnect the interface cleanly, and only then gracefully quits the GUI app using AppleScript (`osascript`) with `pkill`/`killall` fallback and runs `tailscale down`.
  3. **Process Timeout Hardening:** To prevent the script from hanging indefinitely when Docker compose, Colima, or Tailscale CLI commands block (common when the Docker socket or VM becomes unresponsive), we introduced a custom pure-bash watchdog system (`run_with_timeout`). Every system command is wrapped in a strict timeout (ranging from 15s to 120s). If a timeout is exceeded, the script terminates the active command, triggers the `cleanup_handler` to restore DNS to `1.1.1.1`, and exits cleanly.
  4. **Post-Deployment GUI & Tunnel Launch:** The script keeps the host's Tailscale GUI and VPN tunnel completely closed/disconnected during the Colima, Docker, and rules compile boot phases. This guarantees that any previous exit-node configuration does not block the host network.
  5. **Internal Docker Verification:** Rather than checking connectivity from the host (which could fail/deadlock if the host network is blocked), the script queries the container's status internally using `docker compose exec` over the local Docker socket to wait until the container has successfully joined the Tailscale mesh. Only after this verification succeeds does the script open the GUI app, start the host tunnel (`scutil --nc start`), and set the exit-node.
  6. **Inline Auto-Compilation & Caching:** To prevent starting the gateway with stale configurations, the rule compiler (`sync-rules.py`) runs inline automatically on startup. We integrated a 24-hour file caching system under `adguard/work/userfilters/cache` to make toggling instant, falling back to cached copies if the host is offline.
  7. **Dual-State Active Gateway Detection:** To prevent starting the gateway when the user intends to stop it (e.g. if containers crashed but DNS remains hijacked), the script employs a smart state detection helper (`is_gateway_active`). The script considers the gateway active if **either** the containers are running **or** the host DNS is hijacked (not `1.1.1.1`). This ensures that running the toggle always triggers the STOP/cleanup branch and shuts down the GUI/tunnel when the network is in a dirty state.
  8. **Session-Aware GUI Privilege Routing:** To prevent macOS LaunchServices and sandboxing blocks (which cause AppleScript and `open` commands to fail silently when the parent script has cached or is run under `sudo`), we integrated a GUI privilege router (`run_gui_cmd`). It automatically resolves the active console user and routes all GUI launch (`osascript ... to activate`) and quit commands directly to their session, ensuring the Tailscale app opens cleanly in their menu bar and dock.
- **AdGuard Home Local Cache Deception & Syntax Pitfalls:** When modifying DNS rules, two hard-to-debug issues can block legitimate traffic even after adding domains to `white_list.txt`:
  1. *Stale Filter Caching:* When referencing a local file path as a filter URL inside `AdGuardHome.yaml` (e.g. `/opt/adguardhome/work/userfilters/compiled_rules.txt`), AdGuard Home copies the rules into a database cache (`data/filters/*.txt`) and does *not* automatically monitor the local file for updates. Consequently, old rules (like a massive Facebook blocklist) remain loaded in-memory and cached. To resolve this, the compiler now automatically removes AdGuard's stale cached file (`4.txt`) and restarts the `adguardhome` container if active.
  2. *Modifier Ordering Syntax:* When attempting to override wildcard whitelist rules with modifiers (e.g. blocking `an.facebook.com` using `$important` while whitelisting the rest of Facebook), the AdGuard separator `^` must precede the modifier. Writing `||domain$important^` is invalid and ignored; it must be written as `||domain^$important`. The rules engine now automatically checks for custom modifiers and structures them correctly.


## 9. Custom Ad-Blocking Rules Engine
**nullexit** includes a self-contained Python utility (`sync-rules.py`) to manage your own black/whitelist rules **and** subscribe to high-quality remote DNS blocklists — without needing to learn strict AdGuard syntax. It is zero-dependency (Python standard library only).

### Memory Profiles & Optimizations
Because macOS runs Docker containers inside a Colima VM (which we recommend allocating `0.8 GB` of RAM to), loading huge blocklists (e.g. over 600,000 domains) will trigger out-of-memory (`OOMKilled`) crashes. 

To address this, two critical optimizations are built-in:
1. **Subdomain Deduplication**: In AdGuard Home syntax, `||domain.com^` automatically blocks all subdomains. The compiler automatically removes redundant subdomain rules (e.g., if `domain.com` is blocked, rules for `sub.domain.com` are skipped). This reduces the active rule count by **~60%** with **zero loss in blocking effectiveness**.
2. **Memory Profiles**: You can select a rule compilation tier in your `.env` file via `GATEWAY_RULE_PROFILE`:
   - `light` (Recommended for low-memory hosts or if the VM is restricted to 0.8GB and experiences memory pressure): Generates **~52k** optimized rules.
   - `medium` (Default / Recommended balance): Generates **~167k** optimized rules.
   - `heavy` (Highest security, requires increasing Colima memory allocation): Generates **~253k** optimized rules.

### How to use:
1. Add domains you want to block to `black_list.txt` (e.g., `doubleclick.net`).
2. Add domains you want to forcefully allow to `white_list.txt` (e.g., `weather-analytics-events.apple.com`). Whitelists *always* win — they override every block source.
3. Configure `GATEWAY_RULE_PROFILE` in your `.env` file (defaults to `medium`).
4. Run `python3 sync-rules.py` to compile.

*Note: The `toggle.sh` script automatically runs `sync-rules.py` on gateway startup (the START branch), so manual compilation is only needed if you want to preview rules without toggling the gateway. Remote blocklists are cached locally for 24 hours under `adguard/work/userfilters/cache` to make subsequent toggles instant.*

### Toggle Script Environment Variables
The `toggle.sh` script reads two optional `.env` settings:
- `GATEWAY_BYPASS_PING=true` — If the gateway container's Tailscale connection cannot be verified within the timeout, proceed with a warning instead of aborting and restoring DNS.
- `GATEWAY_USE_EXIT_NODE=false` — Skip forcing the macOS host traffic through the exit node, letting you control it manually or use DNS-only mode.

### Stability Incident Report
For a detailed write-up of the DNS deadlock, CLI hang, and Tailscale GUI launch issues that motivated the safeguards in `toggle.sh`, see [stability_incident_report.md](stability_incident_report.md).


## 10. Future Work
- **Native Linux Deployment:** Test and benchmark the architecture on a native Linux host (e.g., Raspberry Pi) to verify the native `~75MB` raw container footprint without the macOS hypervisor overhead.
- **Post-Quantum Cryptography (PQC):** Tailscale currently relies on standard Curve25519 elliptic curve cryptography, which is theoretically vulnerable to future "harvest now, decrypt later" quantum attacks. To achieve true post-quantum resistance, future iterations of this gateway could completely eliminate the Tailscale container and replace it with a raw WireGuard mesh using [Rosenpass](https://rosenpass.eu/) to negotiate post-quantum Pre-Shared Keys (PSKs).
- **Decentralized Post-Quantum Blockchain Messaging:** To definitively defeat mass-surveillance dragnet tactics, future integrations could implement a hybrid protocol that is practically unbreakable against passive mass surveillance. By digitizing classic intelligence tradecraft, this architecture relies on five pillars:
  1. **In-person Key Exchange:** Exchanging a bundle of single-use Post-Quantum Pre-Shared Keys (PSKs) completely out-of-band, allowing for arbitrary-length messages without ever exposing the keys to network interception.
  2. **Blockchain Dead Drops:** Using an immutable, decentralized ledger via I2P as a censorship-resistant dead drop for the encrypted payloads.
  3. **Unconditional Network Presence (Defeating Daily Co-Presence):** If two nodes only ever connect to the I2P network on the same days, a global passive adversary can statistically correlate them over a 30-day period. To neutralize this, both parties must run persistent 24/7 full nodes. This ensures network co-presence is constant, carrying zero metadata. Reading a message becomes a purely local operation on an already-synced ledger, triggering zero new network activity.
     - *Fallback (Shared-Secret Scheduling):* If 24/7 nodes are impossible, connection days must be derived pseudorandomly from the PSK (e.g., `HMAC(shared_secret, week) mod 7`), making their connection days appear mathematically uncorrelated to outside observers.
  4. **Randomized Retrieval Windows (Defeating Within-Day Ordering):** When operating, senders and receivers interact with the network at independent, uniformly random times within the day. This completely breaks any sequential "Sender posts at 2 PM, Receiver reads at 4 PM" correlation.
  5. **Continuous Dummy Posting:** Pushing encrypted dummy posts alongside real messages on a continuous schedule, ensuring adversaries cannot build behavioral fingerprints or infer communication frequency.

  The underlying principle is absolute: any network behavior that is conditional on a message existing is a protocol-level side channel. This approach ensures that the only remaining vulnerabilities are targeted physical or endpoint compromises, creating an incredibly robust, zero-trust communication channel.

## 11. Acknowledgements
- **[SyameimaruKoa](https://github.com/SyameimaruKoa):** For providing advanced, production-grade architectural optimizations to this project, specifically the dual-stack TCP MSS clamping rules to prevent payload fragmentation stalls, the `SIGHUP` state-tracking logic in the routing sidecar to seamlessly survive Gluetun restarts, and the smart `TS_AUTH_ONCE` integration to prevent authentication crash loops.

## 12. License

This project is licensed under the GNU Affero General Public License version 3. See the [LICENSE](file:///Users/omar/Developer/nullexit/LICENSE) file for details.
