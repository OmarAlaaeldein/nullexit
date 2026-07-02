# nullexit — Development Reference & Resolved Issues

> **Last updated:** July 1, 2026
> **Purpose:** Provide any LLM or developer with complete project understanding, debugging history, and resolved issues so they can make informed changes without re-reading every file.

---

## 1. What Is nullexit?

nullexit is a **Tunnel-in-Tunnel VPN gateway** that chains **Tailscale** (mesh VPN) through **Cloudflare WARP** (exit VPN). It runs on a macOS host inside Docker containers managed by **Colima** (lightweight Linux VM). The goal: any device on the user's Tailscale mesh can use this gateway as an exit node, and all traffic exits through Cloudflare WARP — achieving double encryption, ISP invisibility, and network-wide ad-blocking via **AdGuard Home**.

### Traffic Flow
```
Phone/Laptop → Tailscale mesh (WireGuard) → Mac host → Docker container
  → Tailscale decrypts → Gluetun re-encrypts → WARP tun0 → Cloudflare → Internet
```

### SOCKS5 Failover Path (if exit node is unavailable)
```
DNS:  Browser → host 127.0.0.1:53 → Python proxy → TCP:5354 → AdGuard → WARP DNS
TCP:  Apps → macOS SOCKS5 proxy (127.0.0.1:1080) → container → tun0 → WARP → Internet
```

---

## 2. Architecture

### Containers (all share `warp`'s network namespace via `network_mode: service:warp`)
| Container | Image | Role |
|-----------|-------|------|
| `warp` | `qmcgaw/gluetun:v3.41.1` | Gluetun WireGuard client → Cloudflare WARP. Owns the network namespace. Strict firewall. |
| `tailscale` | `tailscale/tailscale:v1.98.4` | Advertises as exit node on the Tailscale mesh. Kernel-space networking (`TS_USERSPACE=false`). |
| `socks-proxy` | `python:3.13-alpine` | RFC 1928 SOCKS5 proxy. Outbound connections go through kernel routing → tun0 → WARP. |
| `routing-fix` | `alpine:3.24` | Sidecar that maintains routing tables + iptables rules every 5 seconds. |
| `adguardhome` | `adguard/adguardhome:v0.107.77` | DNS sinkhole for ads/trackers. Listens on port 5335. Upstream DNS: `127.0.0.1:53` (through WARP). |

### Port Mappings (on host via Colima)
| Host Port | Container Port | Protocol | Purpose |
|-----------|---------------|----------|---------|
| 5354 | 5335 | TCP+UDP | AdGuard DNS |
| 80 | 80 | TCP | AdGuard web UI |
| 41641 | 41641 | UDP | Tailscale WireGuard direct |
| 1080 | 1080 | TCP | SOCKS5 proxy |

### Host Components
- **Colima VM** — Linux VM running Docker (600MB RAM + 400MB swap)
- **tailscaled** — Standalone Tailscale daemon via `brew install tailscale` + `brew services start tailscale` (NOT the GUI `.app`)
- **macOS network settings** — DNS, SOCKS proxy, routing all manipulated by `toggle.sh`

---

## 3. Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `toggle.sh` | 1143 | **Main script.** Detects state, toggles gateway ON/OFF. Handles DNS hijacking, Tailscale exit node, SOCKS proxy, sleep prevention, timeouts, cleanup. |
| `setup.sh` | 406 | **One-time setup.** Installs deps (Docker, Tailscale, wgcf), generates WARP keys, writes `.env`, configures AdGuard via API, starts containers. |
| `docker-compose.yml` | 194 | Service definitions for all 5 containers. |
| `scripts/routing-fix.sh` | 201 | Maintains routing tables (table 200 for SOCKS5, table 52 for CGNAT) and FORWARD iptables rules in both nftables and legacy backends. Loads and enforces the IP blocklist via `ipset`. Runs in a 5-second loop. |
| `post-rules.txt` | 18 | Gluetun iptables rules loaded at container start. FORWARD accept for tailscale0, NAT MASQUERADE on tun0, DNS redirect to port 5335, IPv6 drop, TCP MSS clamping. |
| `scripts/socks5-proxy.py` | 198 | SOCKS5 proxy (Python). Handles RFC 1928 handshake, bidirectional forwarding with `select.select()`. |
| `scripts/dns-proxy.py` | 91 | Local DNS proxy. UDP:53 → TCP:5354 with proper 2-byte length prefix. Fallback when exit node is unavailable. |
| `scripts/sync-rules.py` | 668 | Unified threat compiler. **DNS pipeline:** fetches remote blocklists, deduplicates against AdGuard native filters, optimizes subdomains (~50% reduction), compiles to AdGuard syntax. **IP pipeline:** fetches threat-intel feeds (Spamhaus, Feodo, ET, CINS), strips private/Tailscale ranges, outputs atomic `ipset` restore file. Memory profiles: `light`/`medium`/`heavy`. 24-hour file cache for both pipelines. |
| **`adguard/work/`** | — | **Bind-mounted container data folder. Off-limits from outside Docker — READ-ONLY-EXCEPT-VIA-`scripts/sync-rules.py`. See README §6.** |
| `recover.sh` | 538 | Nuclear recovery script (gain: use `--post-wake` for non-destructive refresh after sleep/wake or Wi-Fi roam — keeps the gateway live while still re-hijacking DNS + refreshing Tailscale exit-node + force-recreating warp if unhealthy). Resets DNS on ALL services, disables proxies, flushes routes, stops containers, kills sleep prevention, power-cycles Wi-Fi. |
| `scripts/watcher.sh` | 194 | **Long-running post-wake + post-roam daemon.** Launched by launchd LaunchAgent; subscribes to `com.apple.powermanagement` events via `log stream` and to network-state changes via `scutil n.watch`. Both fire `recover.sh --post-wake`. Single-instance lock + SCRIPT_DIR-relative resolve of `RECOVER`. See §10.29. |
| `scripts/toggle-linux.sh` | 930 | **Linux sibling of `toggle.sh`.** Native Linux equivalents for every macOS-specific primitive — `nmcli radio wifi off/on` instead of `networksetup -setairportpower`, `ip link set ... down/up` fallback, distro-detection for the gateway install, systemd-resolved wiring. Paired with the `.desktop` shortcuts `setup.sh` builds. |
| `scripts/recover-linux.sh` | 256 | **Linux sibling of `recover.sh`.** Same nuclear semantics (flush, restart, verify) — but using `nmcli` / `ip link` instead of macOS `networksetup`, with a graceful fallback to `journalctl` for diagnostic-readback. |
| `scripts/setup-linux.sh` | 415 | **Linux sibling of `setup.sh`.** Distro detection (apt/dnf/pacman), installs distro-specific deps (Docker, Tailscale CLI, wgcf), generates Tailscale + AdGuard systemd-resolved wiring, creates `.desktop` shortcuts that point at the linux scripts. |
| `logger.py` | 60 | **Internal logger piped from `scripts/routing-fix.sh`** inside the `warp` container. Not invoked from the host; emits the routing-fix loop's structured output. |
| `black_list.txt` | 71 | Custom domains to block (ads, trackers, telemetry). Supports `$important` modifier. |
| `white_list.txt` | 222 | Domains to force-allow (YouTube, Apple services, etc.). Always wins over blocks. |
| `.env` | ~14 | WARP WireGuard keys, Tailscale auth key, rule profile. **Contains secrets.** |
| `ADGUARD_IP.txt` | 1 | Static gateway Tailscale IP (fallback for dynamic resolution). |

---

## 4. toggle.sh Flow

### State Detection
`is_gateway_active()` returns true if EITHER containers are running OR host DNS is not `1.1.1.1`. This dual check prevents the script from starting when it should stop (e.g., containers crashed but DNS is still hijacked).

### START Path (gateway OFF → ON)
1. **Reset DNS to 1.1.1.1** — Prevents deadlocks during startup
2. **Disconnect host Tailscale** — `tailscale down` (prevents exit-node routing during container boot)
3. **Compile DNS rules** — `python3 scripts/sync-rules.py`
4. **Boot Colima VM** — `colima start --memory 0.6` if not running
5. **Configure VM swap** — 400MB swap file inside the VM to prevent OOM
6. **Clean corrupted AdGuard config** — Remove empty `AdGuardHome.yaml`
7. **Start containers** — `docker compose up -d`
8. **Wait for gateway Tailscale** — Poll `tailscale status` for "offers exit node" (up to 60s, abort at 40 consecutive NoState)
9. **Resolve gateway IP** — From `ADGUARD_IP.txt` or `docker compose exec tailscale tailscale ip -4`
10. **Connect host to mesh** — Verify `tailscaled` is running (auto-start if needed), then `tailscale up --reset --ssh=true --accept-dns=false --exit-node=`
11. **Pre-flight checks** — [1/3] `tailscale ping` gateway, [2/3] `dig +tcp` AdGuard DNS, [3/3] WARP container internet
12. **If all pass** → Set exit node + hijack DNS to gateway IP (single server, no fallback)
13. **If any fail** → Enable SOCKS5 proxy + local DNS proxy as fallback
14. **Final DNS re-force** — `force_dns_to_gateway` called again after exit-node transition (tailscaled clobbers DNS briefly)
15. **Enable sleep prevention** — `caffeinate -i` in background to prevent idle sleep

### STOP Path (gateway ON → OFF)
1. Disconnect host Tailscale (`tailscale down`)
2. `docker compose down -t 5`
3. Reset DNS to 1.1.1.1
4. Stop local DNS proxy
5. **Stop sleep prevention** — Kill caffeinate process
6. Full network state cleanup (proxies off, DNS cache flush, route flush, Wi-Fi power cycle)

### Safety Mechanisms
- `run_with_timeout()` — Pure-bash watchdog for every system command (15s–120s)
- `cleanup_handler()` — Trap on ERR/INT/TERM/HUP restores DNS to 1.1.1.1, kills caffeinate, and tears down Tailscale
- `force_dns_to_gateway()` — Sets DNS and VERIFIES via `networksetup -getdnsservers` (3 attempts with backoff)
- `SUCCESS_RUN` flag — Cleanup only runs if script didn't complete successfully
- `start_sleep_prevention()` / `stop_sleep_prevention()` — Manages `caffeinate -i` via PID file at `/tmp/nullexit-caffeinate.pid`

---

## 5. Routing & Firewall Architecture (Inside Container)

### IP Rules (`ip rule show`)
| Priority | Match | Table | Purpose |
|----------|-------|-------|---------|
| 99 | `to 100.64.0.0/10` | 52 | CGNAT range → Tailscale routes (injected by routing-fix) |
| 100 | `from 172.18.0.2` | 200 | Container's own traffic (SOCKS5 proxy) → tun0 |
| 101 | all | 51820 | Gluetun's WireGuard fwmark → tun0 |

### Table 200 (SOCKS5 proxy traffic)
- `162.159.192.1 via $DOCKER_GW dev eth0` — WARP endpoint exception (prevents tunnel loop)
- `default dev tun0` — Everything else through WARP

### iptables (TWO separate stacks!)
- **nftables backend** (`iptables`) — Used by Gluetun's `post-rules.txt`. FORWARD policy DROP.
- **legacy backend** (`iptables-legacy`) — Used by Tailscale's `ts-forward`. FORWARD policy ACCEPT.
- Both stacks apply to every packet. FORWARD RELATED,ESTABLISHED must exist in BOTH.

### post-rules.txt (loaded by Gluetun)
```
FORWARD: ACCEPT for tailscale0 in/out
INPUT: ACCEPT for tailscale0
NAT POSTROUTING: MASQUERADE on tun0
MANGLE: TCP MSS clamp to 1180
NAT PREROUTING: Redirect DNS (53) → 5335 on tailscale0 and eth0
ip6tables: DROP FORWARD on tailscale0
```

---

### 5.5 Tailscale Local Network Discovery (DERP Bypass)
By default, Gluetun's strict NAT swallows all of Tailscale's UDP hole-punching packets, forcing Tailscale to fall back to incredibly slow DERP relay servers (often adding 500ms+ latency). 

To fix this, we use `FIREWALL_OUTBOUND_SUBNETS=192.168.0.0/16,172.16.0.0/12,10.0.0.0/8` in `docker-compose.yml` (on the `warp` container). This creates `ip rule` bypasses (Priority 99, Table 199) that route all packets destined for private IP ranges *outside* the WARP tunnel directly to the host's `eth0`. 
- **172.16.0.0/12** is especially critical because many modern Wi-Fi routers (and Docker itself) assign IPs in this block (e.g., `172.17.x.x`). 
- This bypass allows Tailscale's UDP packets to reach devices on the same Wi-Fi directly, establishing a fast peer-to-peer connection while the actual web traffic inside the tunnel remains fully routed through WARP.

---

### 5.6 Firewalling & Per-Device Access Control
Because every mesh device's traffic passes through the `warp` container's network namespace, this namespace serves as the ultimate choke point for network-wide firewall rules.

**Where to Put Rules**
The right place to add firewall rules is `scripts/routing-fix.sh`. It runs a 5-second loop inside the namespace and already handles re-injecting rules that Gluetun resets on reconnect. **Do not use `post-rules.txt` for dynamic rules**, as Gluetun flushes and resets it upon VPN reconnects.

**The Dual iptables Backend Constraint (CRITICAL)**
The container runs two simultaneous iptables backends: `iptables` (for the nftables backend used by Gluetun) and `iptables-legacy` (for Tailscale). Every rule **must** be added to both stacks, or it will silently fail for certain traffic. 

**Avoiding Duplication**
Because `scripts/routing-fix.sh` runs in a loop, you must always check for a rule's existence with `-C` before appending with `-A`. Otherwise, your rules will duplicate every 5 seconds.

**Per-Device Identification & Filtering**
Each mesh device has a stable `100.x.x.x` Tailscale IP, which is visible as the `src` IP in the `FORWARD` chain. This is how you identify devices for filtering.
* **Domain-level:** AdGuard Home (port 3000, credentials `admin/nullexit`) provides a REST API that supports per-client blocking rules based on their Tailscale IP.
* **IP-level:** Use `iptables` in `scripts/routing-fix.sh` (e.g., `iptables -I FORWARD -s 100.x.x.x -d <blocked_ip> -j DROP`).
* **Country-level:** Add `ipset` to the `routing-fix` apk install step in `docker-compose.yml`, and load CIDR ranges from `ipdeny.com` into an ipset, then block that set in the `FORWARD` chain.

## 6. macOS Quirks to Remember

1. **Colima SSH tunnel is TCP-only** — UDP ports (like 5354/udp) are NOT accessible from host. Use `dig +tcp` or the Python DNS proxy (UDP→TCP converter).
2. **`docker compose exec -T` injects `\r`** — Always `tr -d '\r'` when capturing output for comparisons or `networksetup` commands.
3. **`brew services` can get stuck** — Fix with `sudo brew services restart tailscale`. Common state: `brew services list` shows `started` but `tailscale status` shows "Tailscale is stopped."
4. **No `timeout` command** — macOS lacks GNU `timeout`. Use the `run_with_timeout()` bash function.
5. **`sudo -v` prompts even with NOPASSWD** — Use `sudo -n` (non-interactive) everywhere.
6. **DNS is scoped to en0** — macOS scutil DNS resolver is scoped to en0 (Wi-Fi). DNS changes on other interfaces (like USB Ethernet) are ignored unless en0's service is also updated. The script always sets DNS on BOTH `$ACTIVE_SERVICE` and `$EN0_SERVICE`.
7. **tailscaled clobbers DNS during exit-node transition** — `force_dns_to_gateway` is called a second time at the end of the ENABLE branch to counteract this.
8. **`tailscale up --reset`** resets all unspecified flags to defaults — Every `--reset` call MUST also pass `--accept-dns=false` explicitly or tailscaled re-enables DNS management.

---

## 7. Environment Variables

### `.env` File
| Variable | Purpose |
|----------|---------|
| `WIREGUARD_PRIVATE_KEY` | WARP WireGuard private key (from `wgcf generate`) |
| `WIREGUARD_PUBLIC_KEY` | WARP WireGuard public key |
| `WIREGUARD_ADDRESSES` | WARP WireGuard address (e.g., `172.16.0.2/32`) |
| `TS_AUTHKEY` | Tailscale auth key for the container |
| `GATEWAY_RULE_PROFILE` | Rule compilation tier: `light`, `medium`, `heavy` |
| `GATEWAY_BYPASS_PING` | (Optional) `true` to proceed even if pre-flight checks fail |
| `GATEWAY_USE_EXIT_NODE` | (Optional) `false` to skip exit node, DNS-only mode |

---

## 8. Diagnostic Commands

### Container Health
```bash
docker ps --format '{{.Names}} {{.Status}}'
docker compose exec -T tailscale tailscale status
docker compose exec -T warp wget -qO- --timeout=5 https://www.cloudflare.com/cdn-cgi/trace
```

### SOCKS5 Proxy
```bash
curl --socks5-hostname 127.0.0.1:1080 --max-time 5 -s https://www.cloudflare.com/cdn-cgi/trace
```

### AdGuard DNS
```bash
dig +tcp @127.0.0.1 -p 5354 google.com +short +timeout=5
```

### Firewall & Routing
```bash
# nftables FORWARD chain
docker compose exec -T warp iptables -L FORWARD -v --line-numbers
# Legacy FORWARD chain
docker compose exec -T warp iptables-legacy -L FORWARD -v --line-numbers
# IP rules + routing tables
docker compose exec -T warp ip rule show
docker compose exec -T warp ip route show table 199
docker compose exec -T warp ip route show table 200
```

### Host macOS
```bash
tailscale status
brew services list | grep tailscale
networksetup -getdnsservers Wi-Fi
networksetup -getsocksfirewallproxy Wi-Fi
sysctl net.inet.ip.forwarding
```

---

## 9. Development Issue Tracker

This section documents issues encountered during development, their status, and resolutions.

### 9.1 Exit Node Return Path (`rx 0`) — RESOLVED
**Symptom:** Gateway showed `tx 936 rx 0` — transmitted but never received return traffic.

**Root Cause:** `docker-compose.yml` included `FIREWALL_OUTBOUND_SUBNETS=100.64.0.0/10`. Gluetun created a strict routing rule (`ip rule add to 100.64.0.0/10 lookup 199`, priority 99) that forced all Tailscale CGNAT traffic to bypass the VPN via the Docker bridge. Return packets were sent to the macOS host instead of back through `tailscale0`.

**Fix:** Removed `FIREWALL_OUTBOUND_SUBNETS` entirely. `scripts/routing-fix.sh` now injects `lookup 52`, and return packets correctly flow back into `tailscale0`. The SOCKS5 proxy was repurposed as a bulletproof failover.

### 9.2 Gluetun Resets nftables FORWARD Rules
**Symptom:** FORWARD RELATED,ESTABLISHED rule disappears after Gluetun health check.

**Fix:** `scripts/routing-fix.sh` re-adds to both iptables backends every 5 seconds. Legacy backend (policy ACCEPT) acts as safety net.

### 9.3 docker compose exec `\r` Injection
**Fix:** All `docker compose exec` output piped through `tr -d '\r'`.

### 9.4 Colima VM Memory / Swap Thrashing Latency
**Symptom:** After running nullexit flawlessly for over 24 hours straight to test stability, the 0.5GB VM RAM configuration began experiencing severe network latency on the Tailscale mesh later in the day.

**Root Cause:** Services (like AdGuard, Tailscale, Docker logs) slowly accumulate cache and state over extended periods. Under the tight 512MB physical RAM limit, this slow creep forced the Linux kernel to aggressively swap memory to the 512MB SSD swap file. The constant disk I/O thrashing blocked process execution, causing DNS resolutions and packet forwarding to delay significantly (making the internet feel "very slow").

**Proof (Empirical Observation):** While in this OOM-thrashing state, direct DNS queries through the Tailscale mesh (`dig @100.100.21.8 google.com`) would intermittently hang or take several seconds to resolve. After restarting with the 600MB configuration, the exact same query immediately dropped to a lightning-fast **41ms** response time. (Note: Querying the mapped host port via `127.0.0.1:5354` will always time out due to Gluetun's strict leak-prevention firewall blocking non-VPN ingress traffic).

**Fix:** Increased VM base physical RAM to 600MB (`--memory 0.6`) and reduced the swap file to 400MB. This provides enough native RAM headroom for long-running state caches without forcing heavy I/O swapping. Subdomain deduplication still reduces blocklists by ~60%. Memory profiles (`light`/`medium`/`heavy`) let users trade off coverage for memory.

### 9.5 tailscaled Daemon Broken State
**Symptom:** `brew services list` shows `started` but `tailscale status` shows "stopped".

**Fix:** `sudo brew services restart tailscale`. Toggle script now detects and auto-restarts.

### 9.6 Stderr Invisibly Swallowed
**Symptom:** Failures were silent due to stderr redirected to `output.log`.

**Fix:** Tailscale wait loop now shows output. Critical commands show errors inline.

### 9.7 Missing iptables in routing-fix Container
**Root Cause:** `alpine:3.20` does not have iptables installed. Commands failed silently with `2>/dev/null || true`.

**Fix:** Updated `docker-compose.yml` to `apk add --no-cache iptables iproute2` before `scripts/routing-fix.sh`.

### 9.8 DOCKER_GW Variable Parsing Bug
**Root Cause:** `ip route show default` printed two lines; `awk '{print $3}'` picked up both, causing route commands to fail.

**Fix:** Added `head -1` to the parsing chain.

### 9.9 Native SSH & SFTP Security (Zero Local Attack Surface)
**Context:** macOS "Remote Login" (`sshd`) and "File Sharing" (`smbd`) open ports on the local network (e.g. `172.x.x.x`), exposing the host to brute-force attacks on public Wi-Fi.

**Implementation:** The script strictly enforces `tailscale up --ssh=true` whenever the mesh state is reset. This empowers the user to completely disable native macOS Remote Login and File Sharing. This provides an incredible zero-trust security advantage: even if an attacker steals your Mac username and password, they **cannot** access your files remotely. Disabling the native services completely closes the listening ports on the local Wi-Fi interface (`172.x.x.x`), rendering the Mac impenetrable to local network logins. Meanwhile, Tailscale intercepts port 22 traffic exclusively over the encrypted mesh and authenticates cryptographically based on your Tailscale SSO identity. Stolen Mac passwords are mathematically useless without first bypassing your Tailscale Two-Factor Authentication and registering a device onto the mesh.

**Cross-Platform File Exchange:** To easily browse and exchange files securely, simply use an SFTP client and connect to your Mac's MagicDNS name on port 22. Recommended clients: **WinSCP** or **FileZilla** (Windows), **Cyberduck** (macOS), and **FE File Explorer** or **Solid Explorer** (iOS/Android).

### 9.10 Changing macOS Local Hostname
**Context:** Users may wish to change their Mac's computer name/hostname in macOS System Settings.
**Effect:** Changing the Mac's hostname will **not** break Nullexit (which relies on internal routing/localhost). However, Tailscale will automatically detect this change and update the machine name on the Tailnet. 
- The underlying Tailscale `100.x.x.x` IPv4 address will remain exactly the same.
- The **MagicDNS name** will change to match the new hostname. Users must remember to update their SFTP/SSH clients to use the new MagicDNS address.

### 9.11 Logging Architecture
For debugging, logs are strictly segmented based on the component's lifecycle:
- **`output.log` (Host-side):** Contains all standard error (`stderr`) and verbose output from the host scripts (`toggle.sh`, `recover.sh`, `setup.sh`). Since the `rule-compiler` container is ephemeral and deleted after running, its logs (and any Python errors from `scripts/sync-rules.py`) are extracted and appended to this file before deletion.
- **`docker logs <container>` (Guest-side):** The persistent containers (`warp`, `tailscale`, `routing-fix`, `adguardhome`, `socks-proxy`) use the Docker `json-file` logging driver with a strict `max-size` (1m-10m) to prevent VM disk exhaustion. Use standard `docker logs` to view them.

### 9.12 Chrome Remote Desktop Connection Failures
**Context:** When attempting to access a remote machine via Chrome Remote Desktop (CRD), the connection fails or hangs if Tailscale is active **on the remote device**. The connection works fine even if Tailscale (and the exit node) is active **on the local client/viewer device**, but only if Tailscale is disabled on the remote machine.

**Why:** Having Tailscale active on the remote machine creates virtual network interfaces and DNS/routing modifications that conflict with Chrome Remote Desktop's WebRTC bindings and signaling traffic.

**Workaround:**
- **Use Tailscale Native RDP/RustDesk (Recommended):** Connect directly to the remote device's Tailscale IP (`100.X.Y.Z`) via an RDP or RustDesk client. This is faster and avoids third-party relay conflicts.
- **Disable Tailscale on the Remote Device:** If you must use CRD, disable Tailscale on the remote machine before connecting.

### 9.13 Docker Default Bridge vs Host Wi-Fi Subnet Collision (The 172.17.0.0/16 Subnet Overlap)
**Context:** When attempting to ping a local Windows client (`172.17.22.187`) or the default gateway (`172.17.0.1`) directly over Wi-Fi, the Mac host returns `No route to host` (displaying a `REJECT` / `!` flag in the routing table). Tailscale on the client also drops offline shortly after starting when using the exit node, failing to establish direct P2P connections and falling back to slow DERP relays.

**Root Cause & Subnet Overlap Mechanism:** 
1. **Docker Default Subnet:** By default, the Docker daemon initializes its default bridge network (`docker0`) on the **`172.17.0.0/16`** IP range.
2. **Subnet Conflict:** The host's physical Wi-Fi network happens to be assigned the exact same **`172.17.0.0/16`** range by the local network router.
3. **Routing Clash:** Colima launches a Linux VM on the Mac host to run the Docker engine. Because Docker inside that VM creates `docker0` and claims the `172.17.0.0/16` subnet, any packet sent to `172.17.x.x` from within the containers (such as Tailscale local discovery) is captured by the VM's internal virtual bridge interface (which is down/empty) and is blackholed. On the Mac host, macOS dynamically marks routes as `REJECT` (`!`) when local ARP resolution fails, causing local pings to immediately abort with `No route to host`.
4. **Tailscale Relay Saturation**: Because local peer-to-peer discovery is blackholed, Tailscale falls back to public DERP relay servers (e.g. `relay "tor"` in Toronto). When exit-node routing is enabled, all client web traffic is routed through the relay. Public relays impose strict rate limits and throttle high-volume traffic, resulting in packet drops. This saturation drops Tailscale's control packets, causing the connection to time out and showing the client as offline.

**Fix:**
Configure a custom, non-conflicting default bridge IP (`bip`) for the Docker daemon. 
Edit the Colima configuration file (`~/.colima/default/colima.yaml`) on your Mac to define:
```yaml
docker:
  bip: 172.26.0.1/24
```
Then, restart Colima to apply the new subnet inside the VM:
```bash
colima restart
```
This forces Docker to use `172.26.x.x` for its default bridge, freeing the physical `172.17.x.x` range and letting pings and direct Tailscale peer-to-peer connections flow normally.

---

## 10. Resolved Issues (from README)

These bugs and edge cases were discovered and resolved during development.

### 10.1 DNS Proxy: TCP Wire Format Mismatch (socat / dnsmasq)

**Problem:** When the Tailscale data plane is unavailable (DERP relay only), the script falls back to a local DNS proxy that forwards queries from host UDP:53 to Docker's TCP:5354 (AdGuard). The `socat` and `dnsmasq` approaches both failed.

- **socat** forwards raw bytes — it does not prepend the 2-byte length prefix that DNS-over-TCP requires. AdGuard parses the stream incorrectly and returns garbage.
- **dnsmasq** tries UDP first to reach the upstream (`127.0.0.1#5354`), but Colima's SSH tunnel only forwards TCP. With a single upstream server, dnsmasq doesn't fall back to TCP even with `--timeout=1`.

**Solution:** Replaced both with a **Python DNS proxy** (`scripts/dns-proxy.py`, ~25 lines) that properly handles the DNS-over-TCP wire format: reads a UDP query from the host, prepends the 2-byte length prefix, sends it over TCP to AdGuard, strips the prefix from the response, and sends it back over UDP.

### 10.2 Exit Node Routing Conflict & The SOCKS5 Failover

**Problem:** For days, Tailscale's exit node refused to return traffic back to the client (`rx 0`), leading to the assumption that Tailscale's userspace forwarding was bypassing `iptables` and ignoring the WARP `tun0` interface. In a desperate attempt to fix this, a **SOCKS5 proxy** (`scripts/socks5-proxy.py`) was introduced as a replacement.

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

### 10.3 Pre-Flight Check 1: Wrong `tailscale ping` Flag

**Problem:** Check 1 of the pre-flight connectivity checks used `--c 1` (double dash) but `tailscale ping` accepts `-c 1` (single dash). The invalid flag caused the command to exit with code 1, marking the check as FAIL even though the gateway was reachable.

**Fix:** Changed `--c 1` to `-c 1`.

### 10.4 Pre-Flight Check 1: DERP Relay Exit Code

**Problem:** Even with the correct `-c 1` flag, `tailscale ping` exits with code 1 when the connection goes through a DERP relay (`direct connection not established`) — even though a pong was successfully received (28ms via DERP(tor)). The check treated relayed connections as failures.

**Fix:** Changed the check from relying on exit code to piping stdout through `grep -q "pong"`. This accepts relayed connections as valid (they work fine for the exit node use case), while still failing on true timeouts or unreachable peers.

### 10.5 Container Default Route Bypasses WARP

**Problem:** Inside the WARP container's network namespace, the main routing table's default route was via `eth0` (Docker bridge), not `tun0` (WARP tunnel). While gluetun uses policy routing (rule 101 → table 51820 → `tun0`) for most traffic, traffic originating from the container's own IP (`172.18.0.2`) hits rule 100 (`from 172.18.0.2 lookup 200`), whose default was also via `eth0`. This caused the SOCKS5 proxy's outbound connections to bypass WARP.

**Fix:** Updated the `routing-fix` container to:
1. Change the main table's default route to `default dev tun0`
2. Change table 200's default route to `default dev tun0`
3. Add a specific route for the WARP WireGuard endpoint (`162.159.192.1`) through `eth0` via the Docker gateway in table 200, preventing a tunnel loop
4. Re-assert all routes every 5 seconds (gluetun may reset them on health checks)
5. Dynamically detect the Docker subnet from `ip route show dev eth0` instead of hardcoding `172.18.0.0/16`

### 10.6 IPv6 Exit-Node Leak

**Problem:** Tailscale supports IPv6, but WARP/gluetun is IPv4-only. IPv6 packets forwarded through the exit node would leak through the Docker bridge unencrypted.

**Fix:** Added `ip6tables -A FORWARD -i tailscale0 -j DROP` to `post-rules.txt`, blocking all IPv6 forwarded traffic from the Tailscale interface.

### 10.7 Hardcoded Docker Subnet in Routing Fix

**Problem:** The `routing-fix` container hardcoded `172.18.0.0/16` and `172.18.0.1` for the Docker bridge subnet and gateway. If Docker's bridge network changed (after `docker network prune`, Colima restart, or on a different machine), these routes would be wrong.

**Fix:** Detection is now dynamic using `ip route show`:
- `DOCKER_NET=$(ip route show dev eth0 | grep -v default | head -1 | awk '{print $1}')`
- `DOCKER_GW=$(ip route show default | awk '{print $3}')`

This extracts the actual subnet and gateway directly from the routing table, working with any subnet size (`/16`, `/24`, `/20`, etc.).

### 10.8 SOCKS5 Proxy Threading Race Condition

**Problem:** The `forward` function in `scripts/socks5-proxy.py` called `select.select([src, dst], [], [])` which raised `ValueError: file descriptor cannot be a negative integer (-1)` when one thread closed a socket while the other thread was selecting on it.

**Fix:** Added `ValueError` exception handling around `select.select()` and `recv()` calls. When a file descriptor becomes negative, the thread breaks out of the forwarding loop cleanly instead of crashing.

### 10.9 Docker Healthcheck: Multi-line Python in CMD Array

**Problem:** The socks-proxy healthcheck used a `CMD` array with a multi-line Python string. YAML collapsed the newlines, causing the `#` comment to comment out the rest of the code and the `assert` statement to be mangled into `as`.

**Fix:** Changed from `["CMD", "python3", "-c", "..."]` to `["CMD-SHELL", "python3 -c '...'"]` with a single-line Python expression. Uses a real SOCKS5 handshake (sends `[5, 1, 0]`, expects `[5, 0]`) instead of a simple TCP port check.

### 10.10 Sudo Credential Caching Removed

**Problem:** The script used `sudo -v` at startup to cache sudo credentials, plus a background `SUDO_KEEPER_PID` loop refreshing them every 60 seconds. This required interactive password entry even with NOPASSWD sudoers configured, because `sudo -v` itself prompts.

**Fix:** Removed the entire `sudo -v` + `SUDO_KEEPER_PID` section. All privileged commands now use `sudo -n` (non-interactive), which works silently because the user has NOPASSWD rules in `/etc/sudoers.d/nullexit` for the specific commands needed (`networksetup`, `python3`, `dscacheutil`, `killall`, `pkill`, `route`, `ifconfig`).

### 10.11 macOS Application Firewall Silently Blocking AirDrop & Continuity

**Problem:** Users of complex network extensions (Tailscale, LuLu, Docker, etc.) often run into an issue where AirDrop, AirPlay, and Universal Clipboard silently fail, even with the gateway inactive and Wi-Fi/Bluetooth correctly configured. The internal Apple Wireless Direct Link (`awdl0`) interface appears healthy, but connections never establish.

**Root Cause:** The built-in macOS Application Firewall has a specific list of explicitly blocked applications. Apple's own core networking services (e.g., `/usr/libexec/sharingd`, `/usr/libexec/rapportd`, `/usr/libexec/avconferenced`) can be silently added to the "Block incoming connections" list—either through accidental "Deny" clicks on permission prompts, execution of aggressive privacy-hardening scripts, or a known macOS bug that retains strict blocks even after toggling the "Block all incoming connections" setting off. Since these are background daemons, macOS provides no visible error.

**Fix:** The firewall rules must be cleared via the terminal (or System Settings > Network > Firewall > Options):
```bash
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp /usr/libexec/sharingd
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp /usr/libexec/rapportd
```
Once unblocked, `sharingd` immediately resumes broadcasting mDNS/Bonjour discovery packets, and AirDrop restores instantly without requiring a reboot.

### 10.12 Hard Reboots Leave Stale Docker Socket in Colima VM

**Problem:** If the macOS host machine is subjected to a hard reboot, sudden power loss, or a kernel panic, the Colima VM running in the background is abruptly killed. Upon next boot, running `toggle.sh` resulted in the contradictory output:
`Colima is already running.` followed by `Cannot connect to the Docker daemon at unix://~/.colima/default/docker.sock.`

**Root Cause:** The hard crash prevents the inner Docker daemon from executing its graceful shutdown routines. It leaves behind a corrupted `docker.sock` file inside the VM. On boot, the outer VM spins up (hence "already running"), but the inner Docker daemon sees the stale socket, assumes another instance is running, and crashes.

**Fix:** Added an Auto-Healing routine directly into `toggle.sh` (Step 4b). The script now explicitly tests the Docker daemon with `docker ps`. If the daemon is unresponsive despite Colima reporting as active, it assumes a stale socket and automatically runs `colima restart` in the background to cleanly rebuild the VM and socket before proceeding.

### 10.13 Graceful Shutdowns Leave DNS Hijacked

**Problem:** The gateway overrides the macOS host's DNS settings (via `networksetup`) to route queries to the AdGuard container. Because macOS persists `networksetup` changes to disk, shutting down the Mac while the gateway is running causes the Mac to boot up later with hijacked DNS. Since the Colima VM and Docker containers don't auto-start on boot, the user would have no internet access until they manually run the toggle script.

**Root Cause:** The `toggle.sh` script exits after the gateway starts. There was no background daemon listening for macOS system shutdown signals to revert the network settings.

**Fix:** Wrapped the background `caffeinate` process (used to prevent system sleep) in a bash `trap` command. The trap listens for `SIGTERM`, `SIGINT`, and `SIGHUP`. When the user initiates a graceful shutdown, macOS sends `SIGTERM` to the background trap, which instantly executes `recover.sh` to flush the host DNS back to `1.1.1.1` right before the machine powers off.
*Note:* We explicitly use `recover.sh` instead of `toggle.sh` because during a shutdown, the OS limits process cleanup time and is already independently sending termination signals to Docker and Colima. Trying to run `docker compose down` inside a shutdown trap creates a race condition that can hang the script until macOS forcefully `SIGKILL`s it. `recover.sh` abandons container management and surgically flushes the macOS network settings in milliseconds, guaranteeing completion before the OS pulls the plug.

---

## 11. Deep Dive: Exit Node Return Path Analysis (June 26, 2026)

This section preserves the detailed packet-level analysis that led to identifying and fixing the `rx 0` bug.

### The exit node was probably never going to work in this container topology

Here's the packet path traced by reading `ip rule show` and the routing tables live:

**Outbound (Phone-1 → internet):**
1. Phone-1 sends packet to gateway via Tailscale mesh
2. Gateway's tailscale0 (kernel TUN, `TS_USERSPACE=false`) decrypts → packet enters FORWARD chain
3. Packet has src=`100.87.42.87` (Phone-1), dst=some internet IP
4. FORWARD chain (nftables): Rule 1 matches (`-i tailscale0 -j ACCEPT`) ✅
5. Routing decision for the forwarded packet. Which ip rule matches?
   - Rule 98: `to 172.18.0.0/16` → no (dst is internet)
   - Rule 99: `to 100.64.0.0/10` → no (dst is internet)
   - Rule 100: `from 172.18.0.2` → **NO** (src is `100.87.42.87`, not the container IP!)
   - Rule 101: `not fwmark 0xca6c lookup 51820` → **YES** (no fwmark on forwarded packets)
6. Table 51820: `default dev tun0` → packet goes out through WARP ✅
7. NAT POSTROUTING: `MASQUERADE on tun0` → src becomes WARP IP ✅
8. Packet exits through WARP to internet ✅ (in theory)

**Return (internet → Phone-1):**
1. Return packet arrives on tun0, conntrack de-MASQUERADEs dst back to `100.87.42.87`
2. Routing decision for dst=`100.87.42.87`:
   - Rule 99: `to 100.64.0.0/10 lookup 199` → **YES**
3. Table 199: `100.64.0.0/10 via 172.18.0.1 dev eth0` → **sends it to the Docker gateway!**
4. **This is wrong.** The packet should go to tailscale0 (to be re-encrypted and sent to Phone-1), but table 199 sends it out eth0 to the Docker bridge host.

**Table 199 is the smoking gun.** It has one route: `100.64.0.0/10 via 172.18.0.1 dev eth0`. This sends ALL Tailscale CGNAT return traffic out the Docker bridge to the host — not back through tailscale0. The return packet leaves the container's network namespace entirely, hits the host's routing stack, and gets dropped because the host has no idea what to do with a raw packet for `100.87.42.87`.

### Why table 199 exists and why it's wrong for exit node traffic

Table 199 + the CGNAT rule (pref 99) was designed so that the **container itself** can reach other Tailscale peers (e.g., for mesh management, DERP relay). For that use case, routing CGNAT traffic via the Docker bridge to the host (which has its own tailscaled) makes sense.

But for **forwarded exit node traffic**, the return packet needs to go back through tailscale0 inside the container — not out to the host. The CGNAT rule intercepts the return packet before it can be routed back to tailscale0 through the main table or Tailscale's own routing (table 52, which is at pref 5270).

### The SOCKS5 path works because it dodges all of this

SOCKS5 proxy creates connections **from the container's own IP** (`172.18.0.2`). So:
- ip rule 100 (`from 172.18.0.2 lookup 200`) matches ✅
- Table 200 has `default dev tun0` ✅
- Return traffic comes back to `172.18.0.2` on tun0, conntrack de-NATs, proxy sends response to client ✅

No FORWARD chain involved. No CGNAT rule involved. No table 199. It just works.

### Summary of findings

| Finding | Status | Evidence |
|---------|--------|----------|
| Table 199 CGNAT route hijacks exit node return traffic | **Fixed** | Changed `lookup 199` to `lookup 52` in `scripts/routing-fix.sh`. Return packets now route via tailscale0. |
| FORWARD RELATED,ESTABLISHED missing | **Fixed** | Installed `iptables` via apk in `docker-compose.yml`. Rule now injects successfully. |
| DOCKER_GW variable parsing error | **Fixed** | Added `head -1` in `scripts/routing-fix.sh`. |
| `FIREWALL_OUTBOUND_SUBNETS` was the root cause | **Fixed** | Removed from `docker-compose.yml`. Gluetun no longer hijacks CGNAT routing. |
| Host tailscaled error state from aggressive `tailscale down` | **Mitigated** | Toggle script now detects and auto-restarts. |

### 10.14 Double-Tunneling MSS Clamping (Stalling Bug)

**Problem:** Traffic double-wrapped through Tailscale (WireGuard) and WARP (WireGuard) suffered 120 bytes of MTU overhead (60 + 60). The default MSS clamp of 1180 was still slightly too large, causing large packets to fragment or drop, which resulted in mysterious web page stalls on strict-MSS endpoints.

**Fix:** Lowered the TCP MSS clamp in `post-rules.txt` to `1120` to guarantee double-tunneled payloads fit safely within standard internet MTUs.

### 10.15 Linux Native Wi-Fi Bouncing

**Problem:** The generated `scripts/recover-linux.sh` incorrectly retained the macOS `networksetup` commands, which would crash and fail to bounce Wi-Fi on Linux hosts.

**Fix:** Swapped the macOS logic for native Linux commands. The script now attempts `nmcli radio wifi off/on` first, and gracefully falls back to `ip link set wl... down/up` if NetworkManager is unavailable.

### 10.16 TS_AUTH_ONCE Cloud Footgun & Ephemeral Keys

**Decision:** The compose file uses `TS_AUTH_ONCE=true` to prevent authentication loops. However, on headless cloud VPS deployments, if a standard auth key expires (usually 90 days), the container will silently drop off the mesh. We documented this trade-off explicitly in `docker-compose.yml` and recommended the use of **Tailscale Ephemeral Keys** for cloud deployments, which automatically clean themselves up and bypass this issue.

### 10.17 Hardcoded AdGuard Credentials

**Decision:** AdGuard is deployed with the hardcoded credentials `admin / nullexit`. This is perfectly safe behind a NAT on a local macOS laptop. However, if deployed on a cloud host with exposed ports, this becomes a severe security risk. We added a stark warning comment in `docker-compose.yml` to ensure cloud users change this before deployment.

### 10.18 Routing Fix: 5-Second Polling vs Netlink Socket

**Decision:** Instead of building a complex Netlink socket listener (`ip monitor`) to react instantly to iptables and routing flushes from Gluetun, we retained the 5-second `sleep` loop in `scripts/routing-fix.sh`. 
- **Reasoning:** Building a netlink listener in pure bash on Alpine is incredibly brittle and complex (especially for iptables events). The 5-second polling loop is bulletproof. The only trade-off is a potential 1-4 second stutter if Gluetun reconnects, which was deemed an acceptable edge case for absolute reliability.

### 10.19 Cache Poisoning and URL Rot in scripts/sync-rules.py

**Problem:** If a remote blocklist URL went permanently offline (404 Not Found), the Python `urllib` request would return the 404 HTML string. The script would aggressively regex-parse this HTML, find no domains, and overwrite the healthy local cache with a 0-domain file. This effectively disabled ad-blocking until the URL was fixed.

**Fix:** Implemented a defensive programming sanity check in `scripts/sync-rules.py`. Before overwriting the cache, the script now verifies that the compiled domain count is greater than 10 (and 1 for IP feeds). If it falls below this threshold (indicating a catastrophic 404 failure across multiple URLs), it aborts the cache overwrite, raises a `ValueError`, and keeps the previous day's healthy cache intact.

### 10.20 Cellular Networks & PMTUD Blackholes (The 1280 Byte Limit)

**Experiment:** Conducted a live packet sweep from the PC-1 host to Phone-1 connected via a cellular network + Tailscale DERP relay using `ping -D -s <size>`.

**Result:**
- Packets with a payload of `1252` bytes (+ 28 bytes IP/ICMP headers = **1280 bytes total**) succeeded perfectly with ~60ms latency.
- Packets with a payload of `1253` bytes (**1281 bytes total**) and above resulted in a silent timeout.

**Analysis:** The cellular network (or the Tailscale DERP relay) enforces a strict MTU of 1280 bytes. Critically, it acts as a "PMTUD Blackhole" — it silently drops packets larger than 1280 bytes instead of returning an ICMP "Fragmentation Needed" warning. If the exit node tries to send a standard 1500-byte internet packet to the phone over this link, it vanishes, causing web pages to stall permanently.

**Conclusion:** This empirically validates the absolute necessity of the TCP MSS clamping rule in `post-rules.txt`. By artificially clamping the MSS to `1120` (or `1180`), we ensure the TCP payload + headers + double-WireGuard overhead never exceeds the strict 1280-byte ceiling of the cellular mesh link.

### 10.21 Gluetun nf_tables Parser Crash (Bash Interpolation Failure)

**Problem:** Attempting to make the TCP MSS dynamically configurable by using a standard bash variable inside `post-rules.txt` (`iptables ... --set-mss ${GATEWAY_MSS:-1120}`) caused the Gluetun container to catastrophically crash during startup. Gluetun's internal parser executes `post-rules.txt` line by line without a shell, meaning the variable was never expanded. It literally attempted to inject the string `${GATEWAY_MSS:-1120}` into iptables, resulting in a fatal `bad value for option "--set-mss"` error.

**Fix:** Removed the bash variable from `post-rules.txt` and reverted it to a pure hardcoded integer. To retain dynamic `.env` configuration, we moved the interpolation logic to `toggle.sh`. Right before Docker starts, the host script parses `GATEWAY_MSS` from the `.env` file and uses a cross-platform `sed` command to dynamically overwrite the integer directly inside `post-rules.txt`. This perfectly mimics manual configuration and completely bypasses Gluetun's strict parser.

### 10.22 Seamless Wi-Fi Roaming & The macOS DNS Wipeout Loophole

**Problem:** The Tailscale, WireGuard, and Colima NAT stacks are natively designed for connectionless roaming and will seamlessly survive when the macOS host switches Wi-Fi networks (e.g., roaming from home Wi-Fi to a cellular hotspot). However, the internet completely breaks upon network transition. This occurs because macOS intentionally wipes out all custom DNS settings (`networksetup -setdnsservers`) and reverts to the new network's default DHCP nameserver whenever the active Wi-Fi BSSID changes. Since the Mac is locked to the exit node, its DNS requests are swallowed by WARP and dumped onto the public internet, which cannot route private DHCP IPs. This results in a total DNS failure.

**Solution:** Implementing a silent background "DNS Watcher" daemon (`nullexit-dns-watcher`) in `toggle.sh`. When the gateway starts, it spawns a background polling loop that checks the active Wi-Fi DNS every 5 seconds. If macOS resets the DNS during a network change, the watcher instantly detects the drift and forcefully re-injects `100.100.21.8` via `networksetup`. When the gateway stops, the watcher process is cleanly killed. This allows true, seamless roaming across physical networks without ever dropping the gateway state.

### 10.23 The Infinite Recursive Routing Loop (Hotspot Paradox)

**Problem:** A critical network topology crash occurs if the host Mac connects to a Mobile Hotspot (e.g., a Windows PC or Phone) that is *also* connected to the Tailscale mesh and has "Use Exit Node" enabled. Because the Mac is hosting the Exit Node, it routes its internet traffic to the Hotspot. The Hotspot intercepts the Mac's traffic on its way to the cellular tower and routes it *back* to the Exit Node (the Mac) via Tailscale. The Mac receives it, tries to send it out again, and the Hotspot intercepts it again. This creates an infinite, recursive encryption loop that instantly destroys network bandwidth and drops all connections.

**Fix:** This is a physical routing paradox that cannot be resolved in software. The upstream physical router providing internet to the Mac **must** be allowed to route its traffic directly to the physical WAN interface. The user must manually disable "Use Exit Node" on the upstream device providing the hotspot.

**Advanced Workaround:** If the upstream hotspot is a Windows machine and the user explicitly wants it to remain connected to the Exit Node, a permanent static route can be injected into the Windows routing kernel to forcefully bypass the Tailscale WFP interception for WARP packets. By binding the route to the physical adapter's Interface Index (IF), it becomes a permanent, roaming-aware bypass. 

On Windows (Admin Command Prompt):
```cmd
route print  (find Interface List, note the IF number for the active Wi-Fi adapter, e.g. 15)
route -p add 162.159.192.1 mask 255.255.255.255 0.0.0.0 IF 15
route -p add 162.159.193.1 mask 255.255.255.255 0.0.0.0 IF 15
```

On Linux (Root Terminal):
```bash
ip route add 162.159.192.1 dev wlan0
ip route add 162.159.193.1 dev wlan0
```

On macOS (Root Terminal):
```bash
route add -host 162.159.192.1 -interface en0
route add -host 162.159.193.1 -interface en0
```

*(Note: If the upstream router is an iPhone or Android device, you cannot inject static routes without jailbreak/root. You must simply disable "Use Exit Node" in the mobile Tailscale app).*

This punches a tiny hole straight through the paradox, letting the Mac's WARP packets escape to the physical internet while keeping the rest of the upstream router's traffic securely trapped in the Tailscale Exit Node.

### 10.24 AdGuard Filter Redundancy & Memory Optimization

**Problem:** AdGuard Home does not perform cross-list deduplication in memory. When it loads its own native subscription filters (e.g., `AdGuard DNS filter`) alongside our massive `compiled_rules.txt`, overlapping rules are loaded twice, wasting significant RAM in the Colima VM. The UI would show ~500k rules, representing the sum of all lists rather than unique domains.

**Fix:** Updated `scripts/sync-rules.py` to intelligently cross-reference AdGuard's configuration and deduplicate our list against it.
1. The script now reads `adguard/conf/AdGuardHome.yaml` to dynamically fetch the exact URLs of any enabled native AdGuard filters.
2. The parsing engine was upgraded to normalize basic AdGuard syntax (`||domain^`) back into raw base domains during the build process.
3. The script subtracts the native AdGuard domains from our custom blocklist *before* compiling, immediately purging ~83,000 completely redundant rules. 
4. The normalized base domains then pass through our subdomain optimizer, which squashes an additional ~50% of the remaining rules.

This reduces the final compiled output from ~325k to ~281k rules on the `heavy` profile, saving ~45k rules from being loaded into memory twice and reducing the overall RAM footprint of the `adguardhome` container.

### 10.25 Kernel-Level IP Blocklist (Threat Intelligence Firewall)

**Problem:** DNS sinkholing cannot stop malware or botnets that bypass DNS entirely by hardcoding direct IP addresses (a common technique for C2 communication). These connections pass straight through AdGuard unseen.

**Fix:** Added a second compilation pipeline to `scripts/sync-rules.py` that runs on every startup alongside the DNS pipeline.
1. The compiler concurrently fetches four curated threat-intelligence feeds: **Feodo Tracker** (abuse.ch — botnet C2 IPs), **Spamhaus DROP** (IPs allocated to criminal organizations), **Emerging Threats** (Proofpoint — active C2 and scanners), and **CINS** (active brute-force sources).
2. All entries are normalized via Python's `ipaddress` module. Any IP or CIDR that overlaps with RFC1918 private ranges, loopback, link-local, or the Tailscale CGNAT range (`100.64.0.0/10`) is stripped to prevent accidentally locking users out of their own LAN or mesh.
3. The cleaned list (16,721 unique IPs/CIDRs) is written as an `ipset restore` file using an **atomic swap pattern**: `create_new → populate → swap with live → destroy_new`. This guarantees the live `block_malicious` ipset is never empty during a reload.
4. `scripts/routing-fix.sh` watches the file's mtime every 5 seconds. On change it runs `ipset restore` and idempotently re-injects `FORWARD DROP` rules for both `src` and `dst` into both iptables backends (nftables + legacy).
5. `docker-compose.yml` mounts `adguard/work/userfilters/` into `routing-fix` as `/userfilters:ro` and adds `rule-compiler: service_completed_successfully` to its `depends_on`, eliminating the race condition where routing-fix could start before the file existed.

**Memory cost:** The entire 16,721-entry ipset costs only ~1.6 MiB of kernel memory — negligible in the 600MB VM budget.

### 10.26 Standalone Tailscale Daemon Freeze after macOS Sleep/Wake

**Problem:** When the macOS host goes to sleep and wakes up, the network interfaces and routing tables are rebuilt. The standalone `tailscaled` daemon (installed via Homebrew) occasionally fails to handle this transition and becomes completely frozen/unresponsive. In this state, any command like `tailscale down` or `tailscale status` hangs indefinitely, and all DNS requests sent to the local Tailscale resolver (`100.100.21.8`) time out, causing a total internet blackout on the host.

**Fix:** Enhanced the Tailscale verification and teardown logic in `toggle.sh` and `recover.sh`:
1. **Unresponsive Daemon Detection:** Instead of assuming the daemon is healthy just because the Unix socket `/var/run/tailscaled.socket` exists, the scripts now actively run a status check with a 5-second timeout (`run_with_timeout 5 tailscale status`). If the check times out (exit code 143), the daemon is classified as unresponsive.
2. **Auto-Recovery Loop:** If the daemon is unresponsive, the script now automatically attempts to restart the service using `brew services restart tailscale` (falling back to `sudo -n brew services restart tailscale`).
3. **Graceful Retry:** Once restarted, the script pauses for 3 seconds for the daemon to initialize before proceeding with connection or teardown commands.

### 10.27 macOS Sharing Services (AirDrop/AirPlay) Freeze on Network Transitions

**Problem:** When the gateway is turned on or off, the scripts perform network configuration cleanups which include flushing the routing tables (`route -n flush`), restarting the `mDNSResponder` daemon (`killall -HUP mDNSResponder`), and power-cycling the Wi-Fi interface (`setairportpower` or `ifconfig en0 down/up`). While AirDrop BLE discovery continues to function, the actual file transfers stall at "Waiting..." indefinitely.

**Root Cause:** The rapid tear-down and rebuild of the local routing table and Wi-Fi interface causes Apple's core sharing and connection daemons (`sharingd` and `rapportd`) to lose their socket bindings to the mDNS/Bonjour discovery interface. Instead of reconnecting gracefully, they enter a wedged state and try to route peer-to-peer (AWDL) IPv6/TCP transfer traffic into the default gateway (the Tailscale interface `utun`) instead of the direct wireless link, causing the TLS verification handshake to time out.

**Fix:** Integrated an automatic sharing services reset into both `toggle.sh` and `recover.sh`:
1. The script now automatically runs `sudo -n killall sharingd rapportd` at the end of both the **START** path and the **STOP** path (as well as inside `recover.sh`).
2. Killing these daemons forces macOS to immediately relaunch them, binding them fresh to the newly initialized network interfaces and routing tables, allowing AirDrop to work seamlessly while the gateway is active.

### 10.28 Unlocking Mode-Locked Output Files Without `chmod`

**Context:** The nullexit project has a strict project-wide policy of `no chmod from scripts` (see README §6). This rule exists because every prior `chmod 0444` (post-write tamper-proof lock) and `chmod 000` (post-toggle `.env` lock) call from `scripts/sync-rules.py` / `toggle.sh` could leave a file permanently unreadable on disk if the script exited early, was killed mid-flight, or simply set a restrictive mode without ever being re-flipped. We've stripped every `chmod` from the codebase. But files **written by older versions of those scripts** are still on disk in those restrictive modes (`0444` for `compiled_rules.txt`, `ip_blocklist.ipset`, `data/filters/<id>.txt`; `000` for `.env` after end-of-toggle lock). Re-running `toggle.sh` or `scripts/sync-rules.py` against those leftovers hits `PermissionError: [Errno 13] Permission denied` immediately.

**Problem:** You (the owner) cannot `cat`, `cp`, `rm`, `> redirect`, or any normal POSIX write against a `mode=000` file even though you own it — the basic mode bits block ALL access for owner, group, and other. The script does not call `chmod` and you want a permanent fix that never relies on a chmod from any future run either.

**Solution:** Replace the locked inode with a fresh readable one. `mv` is atomic; mode bits live in the inode, not the directory entry. Two flavors cover every case we hit on a real machine:

**Flavor A — locked file is mode `000` (owner can't even READ it):**
NOPASSWD sudoers (`/etc/sudoers.d/nullexit`) already includes `/usr/bin/python3`. So we read via `sudo python3` (which has the DAC override root has) and pipe the bytes around as base64 in user space, where the redirect happens with the user's normal umask = `0644`:
```bash
sudo -n /usr/bin/python3 -c "import base64,sys; sys.stdout.write(base64.b64encode(open('<FILE>','rb').read()).decode())" > /tmp/snap.b64
base64 -d < /tmp/snap.b64 > <FILE>.new
mv -f <FILE>.new <FILE>
ls -la <FILE>          # mode is now 0644
```
The old `mode=000` inode is unlinked by `mv`; the new `mode=0644` inode (created by base64-decode via the calling user's umask) takes the path. No chmod ever called. The parent directory just needs to be writable by you (it always is, since you own it).

**Flavor B — locked file is mode `0444` (you can READ but cannot WRITE; `scripts/sync-rules.py` needs to re-write):**
You own the file and can read it, you just cannot truncate/overwrite it. The simplest path is to rename it aside and let the writer create a fresh inode from scratch (which gets the umask-default `0644`):
```bash
mv <FILE> /tmp/old.<FILE>.$$
python3 scripts/sync-rules.py    # now writes <FILE> cleanly at mode 0644
```
Or apply Flavor A if you'd prefer to preserve the contents while resetting the mode.

**Why this is the canonical recovery, not a hack:**
- Mode bits live in the inode, not the path. `mv -f` replaces the path's inode reference; the old locked inode drops out of the directory entirely (dentry eviction) and loses its last link, so the kernel reclaims it. The new inode (whatever it is: a freshly-written one, or a base64-decoded copy) gets the path.
- The only prerequisite to apply Flavor B's `mv` is: you own the parent directory (so you can unlink entries from it) AND you have a NOPASSWD-capable binary that can read the byte stream if mode prohibits user read.
- This pattern generalizes. Any time a script ends up producing a "locked file that the next run can't update" situation, the same trick applies without a single chmod anywhere.

**Empirical verification (user machine, July 1, 2026):**
- `.env` was `mode=000` (owner $USER, i.e. you): Flavor A unblocked it in 3 commands, no chmod.
  - Before: `----------  1 $USER  staff  899 Jun 28 07:07 .env`
  - After:  `-rw-r--r--@ 1 $USER  staff  899 Jul  1 20:39 .env`
  - `docker compose config` immediately picked up `TS_AUTHKEY` + `WIREGUARD_PRIVATE_KEY` substitution.
- `compiled_rules.txt`, `ip_blocklist.ipset`, `data/filters/1782645604.txt` were `mode=0444`: Flavor B (`mv`-aside) unblocked all three.
  - scripts/sync-rules.py then ran clean: 279587 block rules + 171 allow rules + 16710 IP entries compiled; new files came out at `0644`.
- `toggle.sh` then went end-to-end in 48s (warp / routing-fix / adguardhome / socks-proxy / tailscale all healthy, gateway mesh-joined, DNS hijack verified single-server).

**When this trick is appropriate vs. inappropriate:**
- ✓ You own the parent directory and the file (typical desktop scenario).
- ✓ The lock is a leftover from a removed `chmod` call that you want off disk forever.
- ✓ NOPASSWD sudo includes at least one interpreter (`python3` on this system) that can be used to read mode-0 files. If it does not, add it first: `<USER> ALL=(ALL) NOPASSWD: /usr/bin/python3`.
- ✗ The file is owned by another user (root, another account) and the lock is intentional — respect it; do not bypass another user's security boundary.
- ✗ The parent directory is owned/writable only by another user — escalate properly via sudo, or stop and ask the user.
- ✗ You do not actually own the file and there is a legitimate reason for its lock state — restore the file via a trusted source rather than circumventing the perms.

**Reusable cookbook:**

```bash
# Quick diagnostic: figure out which flavor you need.
WHOAMI=$(whoami)
ls -la <FILE>
stat -f 'mode=%Sp owner=%Su group=%Sg' <FILE>
# mode=--------- or mode=----r----- : you cannot even read it → Flavor A.
# mode=r--r--r-- but writer fails  : you are blocked from write but can read → Flavor B.
# mode=rw-r--r--                    : not actually locked at all; unrelated write failure.

# Flavor A (mode=000):
sudo -n /usr/bin/python3 -c "import base64,sys; sys.stdout.write(base64.b64encode(open('<FILE>','rb').read()).decode())" > /tmp/snap.b64
base64 -d < /tmp/snap.b64 > <FILE>.new && mv -f <FILE>.new <FILE> && rm -f /tmp/snap.b64

# Flavor B (mode=0444, file is readable):
mv <FILE> /tmp/old.<FILE>.$(date +%s)
# (let the original writer recreate <FILE>; new file lands at mode 0644)

# Verify after either flavor:
ls -la <FILE>             # mode should be 0644
<your normal validation command>
```


### 10.29 Gateway Breakage on Lid Close / Wi-Fi Roam — Post-Wake + Post-Roam Auto-Recovery

**Context / Symptom.** Closing the lid (sleep/wake) OR losing + reconnecting Wi-Fi (e.g. in an elevator, café, or roaming between APs) leaves the gateway in a partly-dead state. Symptoms range from a ~30s window of dead DNS to a permanent outage that only full `recover.sh` or `toggle.sh` fixes. The root cause is that nullexit has **no daemon watching macOS sleep/wake or network-state-change events** — the existing DNS Watcher inside `toggle.sh` only runs in-process and is suspended along with the rest of the user shell on lid close, so the gateway cannot self-heal after either event.

**Diagnosis.** Two distinct failure modes share the same root gap.

* **(A) Lid close → sleep → wake.** `caffeinate -i` (used by `toggle.sh`) blocks *idle* sleep but **does not block forced sleep from lid close**. Closing the lid hard-suspends Colima VM + every container + every Tailscale-quit-shells-except-tailscaled. On wake the VM clock needs ~5-30s to resync via NTP, during which TLS cert validation fails: Cloudflare WARP `162.159.192.1:2408` rejects the handshake → gluetun's healthcheck (`interval: 2s, retries: 15`) eventually flips unhealthy → Docker `unless-stopped` restarts the `warp` container (~30s gap). `mDNSResponder`'s in-memory cache still holds pre-sleep entries (stale A records for tailnet hosts) so the first dozen DNS queries after wake time out. `tailscaled` on the host often keeps its stale DERP relay preference and routes packets through a dead relay for another 30-60s.
* **(B) Wi-Fi roam / loss in elevators, captive portals.** WARP is a UDP tunnel to Cloudflare's anycast edge. Carrier NATs and captive-portal networks silently invalidate the UDP binding on roam and on hotspot-bound re-association. macOS `networksetup` *should* preserve DNS settings on the same Wi-Fi service across a roam, but most captive-portal networks DHCP-replace DNS to the captive-portal resolver **during the captive-portal dance itself**, before the user has authenticated — so even DNS hijack survives a clean roam and quietly breaks on captive-portal handoff.

**Resolution.** A single **launchd LaunchAgent** (`com.nullexit.wake-recovery`) runs a long-running shell daemon (`scripts/watcher.sh`) that listens for both event sources and, on each fire, executes `bash recover.sh --post-wake` — a *lighter-touch* recovery mode that's the opposite of the existing `--nuclear` semantics: it keeps the gateway live while still refreshing every stale subsystem.

#### Apple Power Management Primer (for the unfamiliar)

macOS exposes several relevant surfaces; the right primitive depends on what you actually need to detect. None of these are obvious and none of them have a standard splash screen in the docs.

* **`caffeinate <flags>`** creates I/O Kit power assertions via `IOPMAssertionCreateWithName`. It does NOT block forced sleep (lid close, low-battery shutdown, sleep timer firing on a per-set Energy Settings policy). Flags:
  * `-i`  PreventIdleSleep (the only one `toggle.sh` uses; protects against the OS going idle while the user is active — but a clamshell close still hard-puts it to sleep)
  * `-s`  PreventSystemSleep (only honored on AC power; the user may be on battery)
  * `-u`  DeclareUserActive (resets the idle timer every 5s by default; equivalent to keeping the cursor moving)
  * `-d`  PreventDisplaySleep
  * `-m`  PreventDiskIdleSleep
  * There is NO `-l` (lid-block) flag in any modern macOS. Lid close is a kernel-firmware-level event that ignores user-space assertions.
  * To prove any of this on live hardware: `pmset -g assertions` lists every active assertion with type / process / reason / timeout.
* **`pmset`** is the read-side of the same system:
  * `pmset -g log | grep -E 'Sleep|Wake|DarkWake'` shows the recent timeline.
  * `pmset -g history` is the per-day summary.
  * `pmset -g assertions` is the live assertion list (matches `-i -s -d -u` to processes).
* **`launchd` does NOT have a native "on-wake" hook.** Not in any version of macOS as of Sonoma. The canonical recipe is `StartCalendarInterval` with a sub-minute cadence and let launchd queue missed intervals for replay-on-wake, or use a third-party daemon (Sleepwatcher). For our use case a long-running shell daemon listening to the unified log is more responsive than a polling agent.
* **`com.apple.system.powermanagement.*` Darwin notifications** (`willSleep`, `didWake`, `didDim`, `didUndim`) are the C-level signal. From a shell, they are best reached through the unified log with `log stream --predicate` — see the watcher implementation.
* **`scutil n.watch`** is the canonical CLI for live-following network-state changes. Pairs with `n.add State:/Network/Global/IPv4` to get a single tap that fires on **any** IPv4 link/route/DNS/address change across **all** interfaces. This is what `scripts/watcher.sh`'s network-change listener uses.
* **`com.apple.networkChange` Darwin notification** is the C-level equivalent but has no shell-friendly listener; use `scutil` instead.
* **`SCNetworkReachability`** is the Objective-C API used by SOCKS5/HTTP clients to detect route changes per target. Never a fit for shell scripts.

#### The Fix (component-by-component)

1. **`recover.sh --post-wake`** (new flag, **non-destructive** by design). Adding `--post-wake` to the existing nuclear recovery script inverts the semantics. The default mode still tears down Tailscale, resets DNS to empty, stops caffeinate, runs `docker compose down`, power-cycles Wi-Fi. The new mode does:
  * Skip Tailscale disconnect (we WANT it to keep the mesh connection)
  * **Re-hijack** DNS to the gateway Tailscale IP read from `ADGUARD_IP.txt` (instead of resetting to empty) — applies to both `ACTIVE_SERVICE` and `EN0_SERVICE` because the system resolver is scoped to en0
  * **Refresh** the exit-node preference with `tailscale up --reset --ssh=true --accept-dns=false --exit-node=\"$TS_IP\" --exit-node-allow-lan-access=true` (the exact flags `toggle.sh` START uses). This re-asserts DERP mapping without dropping the mesh
  * Inspect `docker inspect --format '{{.State.Health.Status}}' nullexit-warp-1` and **only** `docker compose up -d --force-recreate warp` if gluetun is unhealthy — this single targeted recreate nudges the UDP NAT binding back to Cloudflare without disturbing Tailscale or AdGuard
  * Run the §10.27 sharingd-reset step (existing fix from `toggle.sh` START path) so AirDrop doesn't freeze on the new IP lease
  * Verify the gateway with `dig +tcp @127.0.0.1 -p 5354 google.com` (AdGuard via TCP through Colima's SSH tunnel) and a 4-second `tailscale ping` to the gateway Tailscale IP, instead of the default mode's direct-to-1.1.1.1 check
  * Crucially: **skip `sudo -v`** because the LaunchAgent has no TTY to prompt on; all privileged calls use `sudo -n` and lean on `/etc/sudoers.d/nullexit` NOPASSWD entries (`networksetup`, `dnsmasq`, `dscacheutil`, `killall`, `pkill`).
2. **`toggle.sh`** writes and clears `/tmp/nullexit-gateway-active.marker` (an ISO-8601 UTC timestamp) at the bottom of the START path and the top of the STOP path / `cleanup_handler`. Two new helpers: `write_gateway_active_marker` and `clear_gateway_active_marker`. The watcher uses this file as its **only signal** that the gateway is live: if `toggle.sh` was stopped (or never started), the watcher no-ops. This prevents waking-up-only-on-counterfactual events from churning DNS.
3. **`scripts/watcher.sh`** (long-running daemon, sibling-style source file). Two backgrounded pipelines:
  * **Wake listener**: `log stream --predicate 'composedMessage CONTAINS[c] "didWake" OR composedMessage CONTAINS[c] "Wake from Sleep" OR composedMessage CONTAINS[c] "Waking from" OR composedMessage CONTAINS[c] "DarkWake"' --style compact --info` piped through `while read; do run_recover "WAKE: ..."; done`. `[c]` makes the predicate case-insensitive (the unified log writes phrases in mixed case across versions).
  * **Network listener**: `(echo "n.add State:/Network/Global/IPv4"; echo "n.watch"; while true; do sleep 86400; done) | scutil 2>/dev/null` piped through a `case` match on `n.state*` / `SCEventUpdate*`.
  * **`run_recover`** checks the marker, debounces via `/tmp/nullexit-watcher.last-recovery` (default 10s, configurable via `NULLEXIT_DEBOUNCE_SECONDS`), and shells out to `bash recover.sh --post-wake`. The 10s debounce prevents a single wake event (which typically emits 2-3 log lines) from triggering multiple recoveries.
  * `trap ... TERM INT` → `kill 0` cleanly tears down the process group on launchctl `bootout` so the `sleep 86400` inside the scutil pipe also dies.
  * `wait` blocks indefinitely while both pipelines feed it.
4. **`launchd/com.nullexit.wake-recovery.plist`** (LaunchAgent in the user domain — runs as the console user at every login without needing sudo).
  * `Label: com.nullexit.wake-recovery`
  * `ProgramArguments: ["/bin/bash", "<absolute-path-to-your-nullexit-install>/scripts/watcher.sh"]`
  * `RunAtLoad: true` — starts immediately on `launchctl load` (no need to log out and back in)
  * `KeepAlive: { SuccessfulExit: false, Crashed: false }` — **don't** restart on clean SIGTERM exit (so `launchctl bootout` doesn't get stuck in a relaunch loop). Also **don't** restart on hard crash: we observed that macOS Sonoma+'s sleep/wake suspend-resume path accumulates orphan watcher.sh PIDs because SIGCONT does not reliably clean up the prior instance's listener grandchildren, and a `KeepAlive.Crashed=true`-driven relaunch actively races with the still-live prior process. The script enforces single-instance on its own via a `flock`-style PID-file lock, so a relaunch-on-crash would be skipped by the lock and produce 0 listener coverage until the live instance happened to die. Trade-off: a real crash leaves the user without auto-recovery until they run `launchctl load -w` manually — acceptable because (a) gateway still works without auto-recovery, (b) a relaunch wouldn't fix whatever caused the crash, and (c) the gateway-recovery itself is observably broken (no DNS, no exit-node) if it does go down.
  * `ProcessType: Background` — hint to App Nap not to suspend us.
  * `StandardOutPath/StandardErrorPath: /tmp/nullexit-watcher.{out,err}.log` — separates launchd-level diagnostics from the script's own `/tmp/nullexit-watcher.log` (which `exec >>` redirects).

#### Install (one-time)

The plist lives in the repo at **`launchd/com.nullexit.wake-recovery.plist`** for version control. The installed (live) copy must land in `~/Library/LaunchAgents/` so launchd picks it up on the user session.

```bash
# Copy the plist to the user-launchd location (run from repo root)
cp ./launchd/com.nullexit.wake-recovery.plist \
   ~/Library/LaunchAgents/

# Substitute __NULLEXIT_HOME__ with your local install absolute path.
# The plist uses WorkingDirectory + a relative program arg, so this
# single substitution is the only place it references your machine.
sed -i '' "s|__NULLEXIT_HOME__|$(pwd)|" \
    ~/Library/LaunchAgents/com.nullexit.wake-recovery.plist

# Validate the XML
plutil -lint ~/Library/LaunchAgents/com.nullexit.wake-recovery.plist

# Load + persist this user session + every future login
launchctl load -w ~/Library/LaunchAgents/com.nullexit.wake-recovery.plist

# Confirm it actually started
launchctl list | grep nullexit
```

To **stop** the watcher (without uninstalling):

```bash
launchctl bootout gui/$UID/com.nullexit.wake-recovery
# or:
launchctl unload -w ~/Library/LaunchAgents/com.nullexit.wake-recovery.plist
```

To **uninstall** completely:

```bash
launchctl bootout gui/$UID/com.nullexit.wake-recovery 2>/dev/null || true
rm ~/Library/LaunchAgents/com.nullexit.wake-recovery.plist
```

#### Why this fix was preferred over alternatives

* **Polling with `StartCalendarInterval`** would have given ~30-60s detection latency per wake. The unified-log stream is sub-second.
* **Sleepwatcher** would have covered wake events but not network changes. We'd still need a separate `scutil` listener, and introducing a third-party dependency for what amounts to ~150 lines of shell is unjustified.
* **Forcing `caffeinate -l`** doesn't exist and the closest equivalent (`caffeinate -s`) only works on AC power. The whole point of the gateway is to stay usable on battery while traveling — lid close must NOT silently kill the gateway.
* **A kernel extension** is impossible (no entitlement) and out of scope.

#### Reproduction recipe

Test both events in isolation to confirm the fix actually closes the gap.

* **(A) Lid-only repro**: with the gateway up, run in a terminal: `pmset displaysleepnow && sleep 30 && pmset wake` (without physically closing the lid). Watch the wake wake-fires the watcher → post-wake routine runs — login should still work in <5s after wake. Compare to baseline pre-fix: pre-fix the gateway would be dead for 30-90s.
* **(B) Roam-only repro**: with the gateway up: `networksetup -setairportpower off && sleep 30 && networksetup -setairportpower on` (or simply walk out of Wi-Fi range and back). The captive-portal WILL repave DHCP DNS for a few seconds; the watcher fires on the second `State:/Network/Global/IPv4` change (after the Wi-Fi re-associates) and the post-wake routine re-hijacks DNS within 2-3s.

#### Operative files

* `recover.sh` — added arg parsing; wrapped destructive sections behind `POST_WAKE`; added re-hijack DNS / refresh exit-node / force-recreate-if-unhealthy path.
* `toggle.sh` — added `write_gateway_active_marker` / `clear_gateway_active_marker` called at the END of START and TOP of STOP / cleanup_handler.
* `scripts/watcher.sh` — new long-running daemon.
* `launchd/com.nullexit.wake-recovery.plist` — launchd LaunchAgent descriptor.
* `~/Library/LaunchAgents/com.nullexit.wake-recovery.plist` — the installed copy (one-time copy).

#### Honest assessment (read before testing)

This fix has two asymmetric halves:

* **Network / roam / captive-portal path — RELIABLE.** `scutil n.watch` on `State:/Network/Global/IPv{4,6}` catches every Wi-Fi roam, captive-portal DHCP-rebind, hotspot handoff, and VPN change with zero missed events. To validate, drop Wi-Fi for 30 s and re-add it; `/tmp/nullexit-watcher.log` will record a `NET:` trigger and `recover.sh --post-wake` will run within ~10 s of the network coming back.
* **Lid close / wake path — BEST-EFFORT on macOS Sonoma+.** Apple *suspends* LaunchAgents process-state during forced sleep and *resumes* them on wake; it does NOT re-launch them every wake. As a result: (a) `log stream` is a live subscription — events emitted during the agent's suppressed window are DROPPED, not buffered, so the wake event that prompted the resume is invisible to `log stream` on resume; (b) the "fire on startup" guard runs once on `launchctl load -w` and after a `KeepAlive` crash-recovery, NOT on every successive wake; (c) `subsystem == "com.apple.powermanagement"` will catch FUTURE emissions (display dim/restore, manual sleep/wake) but not the lid-close→open wake directly.

In practice the lid-wake gap is short, because `toggle.sh`'s existing DNS Watcher already polls every 5 s and re-hijacks DNS (so DNS recovers within 5 s of any roam or wake), `tailscaled` self-heals via DERP fallback within 30–60 s, and `gluetun` reconnects via its healthcheck retry within 30 s. The user-visible pain on lid open is ~30 s of wonky DNS, not a permanent outage.

**Test the ROAM path FIRST.** If ROAM works in your testing, the lid-wake gap is acceptable. If lid-wake handling is critical, the two clean follow-ups are:
1. **Sleepwatcher** (one canonical install): `brew install sleepwatcher`; drop `recover.sh --post-wake` into `~/.sleep` and `~/.wake` so Sleepwatcher invokes it directly on every wake without the launchd propagation problem.
2. **Move the watcher to a LaunchDaemon** (root) and use `IOPMSchedulePowerEvent` via a tiny C wrapper — not portable to shell.

A truly reliable shell-only solution to "wake events from inside a LaunchAgent" does not exist on macOS Sonoma+.

#### Empirical lessons from deployment

Two findings came up while deploying this fix end-to-end; recording so the next operator doesn't lose an evening to each.

1. **Bash function-call-before-definition gotcha.** While introducing the gateway-active marker helpers, the defensive `clear_gateway_active_marker` call was inserted at the very top of `toggle.sh` (right after `set -e`), but the function definition lived near `PID_FILE="/tmp/nullexit-caffeinate.pid"` ~90 lines down. Bash parses top-to-bottom and resolves names at first invocation, so the call site exited with code 127 (`clear_gateway_active_marker: command not found`). The gateway stayed unreachable from the START path even though `bash -n` passed (the parser doesn't catch order-of-resolution errors). Rule: define functions BEFORE any block that calls them. Verify with `grep -n '^name()\s*{'` followed by `grep -n '^name\s*$'` — the latter must appear on a line number AFTER the former.

2. **`networksetup -setairportpower off+on` is not a faithful roam reproduction.** Synthetic Wi-Fi radio-cycling (`sudo networksetup -setairportpower Wi-Fi off` for 30 s, then back on) is expected to produce a `NET:` trigger in `scutil n.watch` but produced ZERO during testing — because `setairportpower` powers the radio at the driver level while leaving the network SERVICE in the `"up"` state from scutil's perspective, so no `n.state State:/Network/Global/IPv4` event is generated. A real roam (macOS briefly loses the AP and re-associates into a different one) DOES fire the event because the link actually changes.
   Better reproduction recipes in priority order:
   * Walk between two real SSIDs via `networksetup -switchtolocation` (or actual physical station movement) — guaranteed to fire the scutil event.
   * Force a DHCP rebind on the same SSID with `sudo ipconfig set en0 DHCP` — triggers `State:/Network/Global/IPv4` to update.
   * Trust the existing 5-second DNS Watcher inside `toggle.sh` for the DNS path: it re-hijacks DNS automatically. The post-wake watcher adds clear value mostly for tailscale exit-node re-assertion and warp gluetun force-recreate, both of which self-heal within ~30 s anyway.

---

## 11. Recent Updates

Reflects the current branch's state. Each entry one line + commit hash; read the commit message for detail.

- **July 1, 2026 — `c5b92c0` (refactor: omar cleanup)** — eliminated every residual `omar` personal-username leak across source + config files. The launchd `com.nullexit.wake-recovery.plist` now uses `WorkingDirectory` + a relative program arg with the `__NULLEXIT_HOME__` sentinel; the install recipe in §10.29 gains a single `sed -i '' "s|__NULLEXIT_HOME__|$(pwd)|"` step right after the `cp`. 8 `devref.md` prose sites genericized to `~/.colima/...`, `~/Library/LaunchAgents/...`, `$USER` for sample output, `<USER>` for the sudoers example.
- **July 1, 2026 — `a5e2a5a` (refactor: script-relative paths)** — replaced 6 hardcoded `/Users/omar/Developer/nullexit/...` source-code sites with script-relative resolution. `recover.sh` injects `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` near the top and uses it for the post-wake warn (l.321) and the broken-for-60s hint echo (l.446). `scripts/watcher.sh` uses the same pattern; `RECOVER="$SCRIPT_DIR/../recover.sh"` resolves without launching-path dependency.
- **June 28, 2026 — `f8f8e4e` (M1: scripts/ move)** — 8 internal-collaborator scripts (routing-fix.sh, socks5-proxy.py, dns-proxy.py, sync-rules.py, logger.py, toggle-linux.sh, recover-linux.sh, setup-linux.sh) consolidated into a `scripts/` subfolder. The 4 user-facing / orchestrator / config files (`toggle.sh`, `recover.sh`, `setup.sh`, `docker-compose.yml`) deliberately stayed at repo root.
- **June 28, 2026 — `0875ef3` (ci: glob)** — CI `py_compile` line switched from `python3 -m py_compile *.py scripts/*.py` to `python3 -m py_compile scripts/*.py` after M1 left root with zero `.py` files (the old form was lazy-empty on bash `nullglob=off` runners).
- **June 28, 2026 — `25b37a1` (docs: scripts/ prefix)** — `devref.md` + `README.md` updated to use the `scripts/` prefix for every reference of the 8 moved files. ~22 sites in devref + ~9 sites in README = ~31 patches.

### End-to-end verification (commit `c5b92c0` cyclone)
Manual START → STOP cycle ran clean on macOS after the path relativization + omar cleanup landed:
- `bash toggle.sh` START: exit 0, ~135s (cold Colima boot); marker present (`2026-07-02T03:41:41Z`), all 5 containers healthy, host DNS hijacked to `100.100.21.8` (no fallback), exit node selected, Cloudflare trace through WARP succeeds.
- `bash toggle.sh` STOP: exit 0, ~12s; marker cleared, all nullexit containers gone, host DNS restored to `1.1.1.1`, Tailscale disconnected.
