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

### Enable Ad-Blocking on Mobile (MagicDNS)
To ensure your phone and other Tailnet devices receive AdGuard filtering while using the exit node, you must configure MagicDNS:
1. Go to the **Tailscale Admin Console → DNS**.
2. Under **Global Nameservers**, click **Add Nameserver → Custom...**
3. Enter the Tailscale IP of your gateway container (e.g., `100.100.21.8`).
4. Toggle ON **Override local DNS**.
5. Enable **MagicDNS** if it isn't already.

**How this works:** MagicDNS assigns `100.100.100.100` as the DNS server for your phone. When your phone makes a DNS request, the local Tailscale app intercepts it and forwards it across the mesh to your Global Nameserver (`100.100.21.8:53`). Our gateway container automatically intercepts port 53 traffic using `PREROUTING` iptables rules and seamlessly redirects it into AdGuard (port `5335`), stripping out ads before forwarding the query securely through Cloudflare WARP.

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
  
  **Automatic DNS Hijacking:** The toggle script automatically resolves your gateway's Tailscale IP by querying the container (`docker compose exec tailscale tailscale ip -4`) after it joins the mesh. It then overrides your macOS DNS servers with that IP so that AdGuard can intercept requests, block ads, and hand off any remaining legitimate traffic securely through the Tailscale mesh, which then routes it out through the Cloudflare WARP tunnel. No manual configuration file is needed.
  
  *Important Note on Routing:* Because `tailscaled` now runs as a background service, the host's mesh state is already determined before the toggle script runs — there is no need to launch any `.app` or click a menu bar item. When toggling ON, the script first issues `tailscale up --exit-node=` to clear any stale exit-node preference so the host can safely reach the gateway's `100.x.y.z` IP via plain Tailscale (otherwise we'd be routing the DNS lookup itself through a likely-dead exit node), and only then hijacks Wi-Fi DNS to the AdGuard container — **exclusively**, with no `1.1.1.1` fallback in the resolver list. Because the standalone `tailscaled` daemon briefly clobbers local DNS during the exit-node transition, the script calls `force_dns_to_gateway` once more at the very tail of the ENABLE branch and verifies via `networksetup -getdnsservers` that the host terminates pointing only at the AdGuard IP. When toggling OFF, the script reverts host DNS to `1.1.1.1` before halting containers, so a hung or failed stop can never leave you with no DNS.
  
- **Windows:** Simply double-click the `Toggle-Gateway.bat` script included in the root of the project. It natively hooks into Docker Desktop to cleanly toggle the **nullexit** gateway state without requiring manual command line input.

## 7. Networking Notes

- **Port Usage**: Tailscale and WARP use entirely different internal ports, preventing any conflicts. Tailscale operates on random/dynamic UDP ports for its peer-to-peer mesh connections. Meanwhile, WARP's outbound WireGuard connection is explicitly targeting port 2408, which is the standard Cloudflare WARP destination port.
- **No Exposed Host Ports**: Because all communication relies purely on outbound tunnels, **nullexit** does not map or expose any ports to your local host machine.
- **Zero-Latency P2P Mesh**: By default, forcing Tailscale traffic through WARP's strict NAT destroys Tailscale's ability to punch holes for peer-to-peer connections, forcing a fallback to high-latency DERP relays. **nullexit** actively mitigates this using a background policy routing script (`routing-fix.sh`) that identifies Tailscale's encrypted UDP mesh packets (port `41641`) and forcibly ejects them out the raw `eth0` interface. This allows Tailscale to punch through your local router, enabling direct local LAN connections (e.g., dropping latency from 67ms to 7ms, and increasing bandwidth from 21Mbps to 32.5+ Mbps).
- **Latency Warning (Double Encryption)**: Despite the P2P fixes, this setup is still a "tunnel-in-tunnel" double-encrypted VPN. If Tailscale fails to establish a direct P2P connection (e.g., on highly restrictive public Wi-Fi) and falls back to a DERP relay, you will experience severe latency overhead. **For competitive gaming or highly latency-sensitive applications, it is always recommended to disable the mesh/exit node and connect directly if performance degrades.**

## 8. Architecture & Security Insights

### Threat Model: Passive Dragnet vs. Targeted Surveillance
Many privacy setups fail by attempting to defend against state-level targeted actors (e.g., using Tor), which destroys internet speeds, breaks apps, and introduces severe latency for a threat model that rarely applies to regular individuals. **nullexit** is calibrated for the real world. 

As revealed by the Snowden disclosures, there are two distinct types of collection:
1. **Bulk/Passive Surveillance**: Upstream taps at the ISP and backbone level that collect everything automatically and query it later. This scales infinitely with no marginal cost per person.
2. **Targeted/Active Surveillance**: Subpoenas or physical access targeting a specific individual. This requires a paper trail, legal effort, and immense friction.

**nullexit** is designed exclusively to defeat the first. By tunneling all DNS and HTTP traffic through WARP, you completely blind your ISP, cellular provider, and local Wi-Fi networks. Your ISP never sees the plaintext traffic to log in the first place, entirely removing you from the passive dragnet and opportunistic data harvesting. You move yourself into the "requires active effort" category. At the same time, because we accept that defending against physical device access is an exercise in diminishing returns, we don't cripple the network—allowing us to retain 7ms native latency and full bandwidth.

### Implementation Details
- **SOCKS5 vs. Default Gateways**: A standard container uses Docker's `172.18.0.1` bridge gateway, which translates directly to the host Mac's Wi-Fi interface (exposing traffic to the ISP). We bypass this by exclusively binding traffic to the SOCKS5 proxy running inside the Cloudflare WARP container.

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
- **macOS Memory Overhead (Colima):** Because macOS cannot run Linux containers natively, Colima must spin up a background Linux VM. While the actual containers (`warp`, `tailscale`, `routing-fix`) only consume roughly `~75MB` of RAM combined, loading massive blocklists into AdGuard Home requires significant memory. We recommend running the VM stably at `0.6 GB` (614MB) of RAM (`colima start --memory 0.6`). To prevent out-of-memory (`OOMKilled`) crash loops on this tight memory limit, the rules compiler uses **subdomain deduplication** (shrinking lists by **~60%** with zero loss in blocking coverage) and customizable **memory profiles** (`light`, `medium`, `heavy`). See Section 10 for details.
- **Host DNS/Exit-Node Deadlock (The Catch-22):** If the macOS host is configured to route all traffic through the Tailscale Exit Node (which is hosted by **nullexit**), and the **nullexit** gateway is stopped or restarting, the host Mac loses all internet connectivity. This creates a deadlock: Colima and the Docker daemon cannot fetch remote blocklists, pull images, or authenticate with Tailscale/WARP control servers because the host's network is completely blackholed. 
  To resolve this, we implemented ten key safeguards in our toggle script:
  1. **Immediate DNS Recovery:** The script immediately sets the macOS host DNS to `1.1.1.1` at the very start of execution (for both starting and stopping). This ensures that if the script gets stuck or fails, the host is never left with a dead or unreachable DNS.
  2. **Lightweight Disconnect:** With the standalone `tailscaled` daemon, the disable flow is just `tailscale down` — there is no `scutil --nc stop "Tailscale"` to undo, no AppleScript GUI quit, no `pkill`/`killall Tailscale`. We deliberately do **not** call `tailscale logout` because that would force a fresh browser-based authentication on every toggle, which would defeat the whole "toggle for gaming" workflow. The user's auth state persists in `tailscaled`'s state directory between toggle cycles, so reconnecting in milliseconds is the default.
  3. **Process Timeout Hardening:** To prevent the script from hanging indefinitely when Docker compose, Colima, or Tailscale CLI commands block (common when the Docker socket or VM becomes unresponsive), we introduced a custom pure-bash watchdog system (`run_with_timeout`). Every system command is wrapped in a strict timeout (ranging from 15s to 120s). If a timeout is exceeded, the script terminates the active command, triggers the `cleanup_handler` to restore DNS to `1.1.1.1`, and exits cleanly.
  4. **Pre-flight Exit-Node Clear:** At the very start of every enable flow we (re-)issue `tailscale up --exit-node=`, which is idempotent: it joins the mesh if the host is not already on it, and otherwise just clears any stale exit-node preference from a prior session. This *must* happen before Step 8's DNS hijack so the host can safely reach the gateway's `100.x.x.x` IP via the plain Tailscale mesh — otherwise we'd be routing the very DNS lookup that step 8 depends on through a possibly-dead exit node. With the previous `.app` GUI model this was hidden inside `disconnect_tailscale_host`; with the standalone model the explicit step is one `tailscale up --exit-node=` call.
  5. **Internal Docker Verification:** Rather than checking connectivity from the host (which could fail/deadlock if the host network is blocked), the script queries the container's status internally using `docker compose exec` over the local Docker socket to wait until the container has successfully joined the Tailscale mesh. Only after this verification succeeds does the script open the GUI app, start the host tunnel (`scutil --nc start`), and set the exit-node.
  6. **Inline Auto-Compilation & Caching:** To prevent starting the gateway with stale configurations, the rule compiler (`sync-rules.py`) runs inline automatically on startup. We integrated a 24-hour file caching system under `adguard/work/userfilters/cache` to make toggling instant, falling back to cached copies if the host is offline. The gateway's Tailscale IP is also derived dynamically from the container at startup (`docker compose exec tailscale tailscale ip -4`), eliminating the need for a static `ADGUARD_IP.txt` file.
  7. **Dual-State Active Gateway Detection:** To prevent starting the gateway when the user intends to stop it (e.g. if containers crashed but DNS remains hijacked), the script employs a smart state detection helper (`is_gateway_active`). The script considers the gateway active if **either** the containers are running **or** the host DNS is hijacked (not `1.1.1.1`). This ensures that running the toggle always triggers the STOP/cleanup branch and shuts down the GUI/tunnel when the network is in a dirty state.
  8. **Standalone Daemon Resilience:** `tailscaled` is registered as a per-user LaunchAgent (`brew services start tailscale`, which `setup.sh` does automatically) or a system LaunchDaemon (`sudo brew services start tailscale`), so it is already running whenever the user is logged in — or before login, with `sudo`. The toggle script never has to launch an `.app`, fight a stuck Network Extension, or click the menu bar item: `tailscaled`'s local control socket is always reachable, and `tailscale up` / `tailscale down` are idempotent and run in a couple of seconds.
  9. **Streamlined Daemon-Only Enable:** The previous five-phase flow was a workaround for macOS's sandboxed Network-Extension constraints: we had to launch `Tailscale.app`, click `Connect` in its menu bar via System Events (taking any failure as an abort signal with DNS still on `1.1.1.1`), poll the daemon, drop any stale exit-node preference, and finally call `scutil --nc start "Tailscale"` to engage the Network Extension. With the standalone `tailscaled` daemon, all five steps collapse into two CLI calls — verify `tailscale status` is responsive (15-second poll), then `tailscale up --exit-node=`. There is no `.app` to launch, no menu bar to click, no Network Extension sandbox to wake up, and no Accessibility permission required because nothing in the enable path touches the GUI.
  10. **DNS Locked to Gateway Only, With Final Re-Force (No `1.1.1.1` Fallback):** Prior to this safeguard, `toggle.sh` configured DNS as `"$TS_IP" 1.1.1.1` and called it done. macOS's resolver queries the DNS list in order and falls back to the next entry on timeout, so any extra entry creates a silent leak path that bypasses the gateway's ad-blocking the moment AdGuard is slow or unresponsive. We removed the fallback entirely: step 8 sets the DNS list to a single entry (the AdGuard IP) via `force_dns_to_gateway`, which both writes the setting *and* asserts via `networksetup -getdnsservers` that the only entry left is exactly that IP. Because the standalone `tailscaled` daemon briefly clobbers local DNS during the exit-node routing-table transition, `force_dns_to_gateway` is called a second time at the very tail of the ENABLE branch — well after step 9's `tailscale up --exit-node=...` has returned — and re-asserts the same single-server state across up to three progressively-backed-off attempts. The script ends only when the resolver is verifiably locked at AdGuard, or prints an explicit remediation command. A misbehaving gateway now produces a *visible* DNS outage (instead of silently falling through to `1.1.1.1`), which is the correct failure mode for a gateway whose whole purpose is filtering.
- **AdGuard Home Local Cache Deception & Syntax Pitfalls:** When modifying DNS rules, two hard-to-debug issues can block legitimate traffic even after adding domains to `white_list.txt`:
  1. *Stale Filter Caching:* When referencing a local file path as a filter URL inside `AdGuardHome.yaml` (e.g. `/opt/adguardhome/work/userfilters/compiled_rules.txt`), AdGuard Home copies the rules into a database cache (`data/filters/*.txt`) and does *not* automatically monitor the local file for updates. Consequently, old rules (like a massive Facebook blocklist) remain loaded in-memory and cached. To resolve this, the compiler now automatically removes AdGuard's stale cached file (`4.txt`) and restarts the `adguardhome` container if active.
  2. *Modifier Ordering Syntax:* When attempting to override wildcard whitelist rules with modifiers (e.g. blocking `an.facebook.com` using `$important` while whitelisting the rest of Facebook), the AdGuard separator `^` must precede the modifier. Writing `||domain$important^` is invalid and ignored; it must be written as `||domain^$important`. The rules engine now automatically checks for custom modifiers and structures them correctly.


## 9. Resolved Issues

This section documents the bugs, architecture limitations, and edge cases that were discovered and resolved during development. Each entry includes the problem, root cause, and solution.

### 9.1 DNS Proxy: TCP Wire Format Mismatch (socat / dnsmasq)

**Problem:** When the Tailscale data plane is unavailable (DERP relay only), the script falls back to a local DNS proxy that forwards queries from host UDP:53 to Docker's TCP:5354 (AdGuard). The `socat` and `dnsmasq` approaches both failed.

- **socat** forwards raw bytes — it does not prepend the 2-byte length prefix that DNS-over-TCP requires. AdGuard parses the stream incorrectly and returns garbage.
- **dnsmasq** tries UDP first to reach the upstream (`127.0.0.1#5354`), but Colima's SSH tunnel only forwards TCP. With a single upstream server, dnsmasq doesn't fall back to TCP even with `--timeout=1`.

**Solution:** Replaced both with a **Python DNS proxy** (`dns-proxy.py`, ~25 lines) that properly handles the DNS-over-TCP wire format: reads a UDP query from the host, prepends the 2-byte length prefix, sends it over TCP to AdGuard, strips the prefix from the response, and sends it back over UDP.

### 9.2 Exit Node Routing Conflict & The SOCKS5 Failover

**Problem:** For days, Tailscale's exit node refused to return traffic back to the client (`rx 0`), leading to the assumption that Tailscale's userspace forwarding was bypassing `iptables` and ignoring the WARP `tun0` interface. In a desperate attempt to fix this, a **SOCKS5 proxy** (`socks5-proxy.py`) was introduced as a replacement.

**The Real Root Cause:** Tailscale's userspace forwarding was *not* the problem. The issue was an environment variable in Gluetun (`FIREWALL_OUTBOUND_SUBNETS=100.64.0.0/10`) that instructed the VPN container to hijack all Tailscale CGNAT traffic and forcibly route it out the unencrypted Docker bridge (`eth0`). This blackholed all return packets back to the client.

**Solution:** Removed the offending `FIREWALL_OUTBOUND_SUBNETS` variable, immediately restoring the Tailscale exit node. Instead of removing the SOCKS5 proxy, we repurposed it into a **bulletproof failover** for when restrictive Wi-Fi networks block Tailscale UDP ports.

Architecture after the fix:
```
PRIMARY (Exit Node):
DNS/TCP/UDP: Apps → Tailscale Exit Node → gateway container → tun0 → WARP → internet

FAILOVER (SOCKS5 - if Tailscale is blocked by local Wi-Fi):
DNS: Browser → 127.0.0.1:53 → Python proxy → TCP:5354 → AdGuard → WARP
TCP: Apps → SOCKS5:1080 → gateway container → tun0 → WARP → internet
Mesh: SSH/ping 100.x.x.x → utun5 → WireGuard → peers (independent of proxy)
```

### 9.3 Pre-Flight Check 1: Wrong `tailscale ping` Flag

**Problem:** Check 1 of the pre-flight connectivity checks used `--c 1` (double dash) but `tailscale ping` accepts `-c 1` (single dash). The invalid flag caused the command to exit with code 1, marking the check as FAIL even though the gateway was reachable.

**Fix:** Changed `--c 1` to `-c 1`.

### 9.4 Pre-Flight Check 1: DERP Relay Exit Code

**Problem:** Even with the correct `-c 1` flag, `tailscale ping` exits with code 1 when the connection goes through a DERP relay (`direct connection not established`) — even though a pong was successfully received (28ms via DERP(tor)). The check treated relayed connections as failures.

**Fix:** Changed the check from relying on exit code to piping stdout through `grep -q "pong"`. This accepts relayed connections as valid (they work fine for the exit node use case), while still failing on true timeouts or unreachable peers.

### 9.5 Container Default Route Bypasses WARP

**Problem:** Inside the WARP container's network namespace, the main routing table's default route was via `eth0` (Docker bridge), not `tun0` (WARP tunnel). While gluetun uses policy routing (rule 101 → table 51820 → `tun0`) for most traffic, traffic originating from the container's own IP (`172.18.0.2`) hits rule 100 (`from 172.18.0.2 lookup 200`), whose default was also via `eth0`. This caused the SOCKS5 proxy's outbound connections to bypass WARP.

**Fix:** Updated the `routing-fix` container to:
1. Change the main table's default route to `default dev tun0`
2. Change table 200's default route to `default dev tun0`
3. Add a specific route for the WARP WireGuard endpoint (`162.159.192.1`) through `eth0` via the Docker gateway in table 200, preventing a tunnel loop
4. Re-assert all routes every 5 seconds (gluetun may reset them on health checks)
5. Dynamically detect the Docker subnet from `ip route show dev eth0` instead of hardcoding `172.18.0.0/16`

### 9.6 IPv6 Exit-Node Leak

**Problem:** Tailscale supports IPv6, but WARP/gluetun is IPv4-only. IPv6 packets forwarded through the exit node would leak through the Docker bridge unencrypted.

**Fix:** Added `ip6tables -A FORWARD -i tailscale0 -j DROP` to `post-rules.txt`, blocking all IPv6 forwarded traffic from the Tailscale interface.

### 9.7 Hardcoded Docker Subnet in Routing Fix

**Problem:** The `routing-fix` container hardcoded `172.18.0.0/16` and `172.18.0.1` for the Docker bridge subnet and gateway. If Docker's bridge network changed (after `docker network prune`, Colima restart, or on a different machine), these routes would be wrong.

**Fix:** Detection is now dynamic using `ip route show`:
- `DOCKER_NET=$(ip route show dev eth0 | grep -v default | head -1 | awk '{print $1}')`
- `DOCKER_GW=$(ip route show default | awk '{print $3}')`

This extracts the actual subnet and gateway directly from the routing table, working with any subnet size (`/16`, `/24`, `/20`, etc.).

### 9.8 SOCKS5 Proxy Threading Race Condition

**Problem:** The `forward` function in `socks5-proxy.py` called `select.select([src, dst], [], [])` which raised `ValueError: file descriptor cannot be a negative integer (-1)` when one thread closed a socket while the other thread was selecting on it.

**Fix:** Added `ValueError` exception handling around `select.select()` and `recv()` calls. When a file descriptor becomes negative, the thread breaks out of the forwarding loop cleanly instead of crashing.

### 9.9 Docker Healthcheck: Multi-line Python in CMD Array

**Problem:** The socks-proxy healthcheck used a `CMD` array with a multi-line Python string. YAML collapsed the newlines, causing the `#` comment to comment out the rest of the code and the `assert` statement to be mangled into `as`.

**Fix:** Changed from `["CMD", "python3", "-c", "..."]` to `["CMD-SHELL", "python3 -c '...'"]` with a single-line Python expression. Uses a real SOCKS5 handshake (sends `[5, 1, 0]`, expects `[5, 0]`) instead of a simple TCP port check.

### 9.10 Sudo Credential Caching Removed

**Problem:** The script used `sudo -v` at startup to cache sudo credentials, plus a background `SUDO_KEEPER_PID` loop refreshing them every 60 seconds. This required interactive password entry even with NOPASSWD sudoers configured, because `sudo -v` itself prompts.

**Fix:** Removed the entire `sudo -v` + `SUDO_KEEPER_PID` section. All privileged commands now use `sudo -n` (non-interactive), which works silently because the user has NOPASSWD rules in `/etc/sudoers.d/nullexit` for the specific commands needed (`networksetup`, `python3`, `dscacheutil`, `killall`, `pkill`, `route`, `ifconfig`).

---

## 10. Custom Ad-Blocking Rules Engine
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
- `GATEWAY_USE_EXIT_NODE=false` — Skip forcing the macOS host traffic through the exit node, letting you control it manually or use DNS-only mode.

### Stability Incident Report
For a detailed write-up of the DNS deadlock, CLI hang, and Tailscale GUI launch issues that motivated the safeguards in `toggle.sh`, see [stability_incident_report.md](stability_incident_report.md).


## 11. Future Work
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

## 12. Acknowledgements
- **[SyameimaruKoa](https://github.com/SyameimaruKoa):** For providing advanced, production-grade architectural optimizations to this project, specifically the dual-stack TCP MSS clamping rules to prevent payload fragmentation stalls, the `SIGHUP` state-tracking logic in the routing sidecar to seamlessly survive Gluetun restarts, and the smart `TS_AUTH_ONCE` integration to prevent authentication crash loops.

## 13. License

This project is licensed under the GNU Affero General Public License version 3. See the [LICENSE](file:///Users/omar/Developer/nullexit/LICENSE) file for details.
