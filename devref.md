# nullexit — Development Reference & Resolved Issues

> **Last updated:** June 27, 2026
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
| `toggle.sh` | ~900 | **Main script.** Detects state, toggles gateway ON/OFF. Handles DNS hijacking, Tailscale exit node, SOCKS proxy, sleep prevention, timeouts, cleanup. |
| `setup.sh` | ~392 | **One-time setup.** Installs deps (Docker, Tailscale, wgcf), generates WARP keys, writes `.env`, configures AdGuard via API, starts containers. |
| `docker-compose.yml` | ~160 | Service definitions for all 5 containers. |
| `routing-fix.sh` | ~90 | Maintains routing tables (table 200 for SOCKS5, table 199 for CGNAT) and FORWARD iptables rules in both nftables and legacy backends. Runs in a 5-second loop. |
| `post-rules.txt` | ~16 | Gluetun iptables rules loaded at container start. FORWARD accept for tailscale0, NAT MASQUERADE on tun0, DNS redirect to port 5335, IPv6 drop, TCP MSS clamping. |
| `socks5-proxy.py` | ~200 | SOCKS5 proxy (Python). Handles RFC 1928 handshake, bidirectional forwarding with `select.select()`. |
| `dns-proxy.py` | ~90 | Local DNS proxy. UDP:53 → TCP:5354 with proper 2-byte length prefix. Fallback when exit node is unavailable. |
| `sync-rules.py` | ~300 | Ad-blocking rule compiler. Fetches remote blocklists, deduplicates subdomains (~60% reduction), compiles to AdGuard syntax. Memory profiles: `light`/`medium`/`heavy`. 24-hour file cache. |
| `recover.sh` | ~280 | Nuclear recovery script. Resets DNS on ALL services, disables proxies, flushes routes, stops containers, kills sleep prevention, power-cycles Wi-Fi. |
| `black_list.txt` | ~70 | Custom domains to block (ads, trackers, telemetry). Supports `$important` modifier. |
| `white_list.txt` | ~120 | Domains to force-allow (YouTube, Apple services, etc.). Always wins over blocks. |
| `.env` | ~14 | WARP WireGuard keys, Tailscale auth key, rule profile. **Contains secrets.** |
| `ADGUARD_IP.txt` | 1 | Static gateway Tailscale IP (fallback for dynamic resolution). |

---

## 4. toggle.sh Flow

### State Detection
`is_gateway_active()` returns true if EITHER containers are running OR host DNS is not `1.1.1.1`. This dual check prevents the script from starting when it should stop (e.g., containers crashed but DNS is still hijacked).

### START Path (gateway OFF → ON)
1. **Reset DNS to 1.1.1.1** — Prevents deadlocks during startup
2. **Disconnect host Tailscale** — `tailscale down` (prevents exit-node routing during container boot)
3. **Compile DNS rules** — `python3 sync-rules.py`
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
| 99 | `to 100.64.0.0/10` | 199 | CGNAT range → Tailscale routes (injected by routing-fix) |
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

### 5.5 Firewalling & Per-Device Access Control
Because every mesh device's traffic passes through the `warp` container's network namespace, this namespace serves as the ultimate choke point for network-wide firewall rules.

**Where to Put Rules**
The right place to add firewall rules is `routing-fix.sh`. It runs a 5-second loop inside the namespace and already handles re-injecting rules that Gluetun resets on reconnect. **Do not use `post-rules.txt` for dynamic rules**, as Gluetun flushes and resets it upon VPN reconnects.

**The Dual iptables Backend Constraint (CRITICAL)**
The container runs two simultaneous iptables backends: `iptables` (for the nftables backend used by Gluetun) and `iptables-legacy` (for Tailscale). Every rule **must** be added to both stacks, or it will silently fail for certain traffic. 

**Avoiding Duplication**
Because `routing-fix.sh` runs in a loop, you must always check for a rule's existence with `-C` before appending with `-A`. Otherwise, your rules will duplicate every 5 seconds.

**Per-Device Identification & Filtering**
Each mesh device has a stable `100.x.x.x` Tailscale IP, which is visible as the `src` IP in the `FORWARD` chain. This is how you identify devices for filtering.
* **Domain-level:** AdGuard Home (port 3000, credentials `admin/nullexit`) provides a REST API that supports per-client blocking rules based on their Tailscale IP.
* **IP-level:** Use `iptables` in `routing-fix.sh` (e.g., `iptables -I FORWARD -s 100.x.x.x -d <blocked_ip> -j DROP`).
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

**Fix:** Removed `FIREWALL_OUTBOUND_SUBNETS` entirely. `routing-fix.sh` now injects `lookup 52`, and return packets correctly flow back into `tailscale0`. The SOCKS5 proxy was repurposed as a bulletproof failover.

### 9.2 Gluetun Resets nftables FORWARD Rules
**Symptom:** FORWARD RELATED,ESTABLISHED rule disappears after Gluetun health check.

**Fix:** `routing-fix.sh` re-adds to both iptables backends every 5 seconds. Legacy backend (policy ACCEPT) acts as safety net.

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

**Fix:** Updated `docker-compose.yml` to `apk add --no-cache iptables iproute2` before `routing-fix.sh`.

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

---

## 10. Resolved Issues (from README)

These bugs and edge cases were discovered and resolved during development.

### 10.1 DNS Proxy: TCP Wire Format Mismatch (socat / dnsmasq)

**Problem:** When the Tailscale data plane is unavailable (DERP relay only), the script falls back to a local DNS proxy that forwards queries from host UDP:53 to Docker's TCP:5354 (AdGuard). The `socat` and `dnsmasq` approaches both failed.

- **socat** forwards raw bytes — it does not prepend the 2-byte length prefix that DNS-over-TCP requires. AdGuard parses the stream incorrectly and returns garbage.
- **dnsmasq** tries UDP first to reach the upstream (`127.0.0.1#5354`), but Colima's SSH tunnel only forwards TCP. With a single upstream server, dnsmasq doesn't fall back to TCP even with `--timeout=1`.

**Solution:** Replaced both with a **Python DNS proxy** (`dns-proxy.py`, ~25 lines) that properly handles the DNS-over-TCP wire format: reads a UDP query from the host, prepends the 2-byte length prefix, sends it over TCP to AdGuard, strips the prefix from the response, and sends it back over UDP.

### 10.2 Exit Node Routing Conflict & The SOCKS5 Failover

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

**Problem:** The `forward` function in `socks5-proxy.py` called `select.select([src, dst], [], [])` which raised `ValueError: file descriptor cannot be a negative integer (-1)` when one thread closed a socket while the other thread was selecting on it.

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
`Colima is already running.` followed by `Cannot connect to the Docker daemon at unix:///Users/omar/.colima/default/docker.sock.`

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
| Table 199 CGNAT route hijacks exit node return traffic | **Fixed** | Changed `lookup 199` to `lookup 52` in `routing-fix.sh`. Return packets now route via tailscale0. |
| FORWARD RELATED,ESTABLISHED missing | **Fixed** | Installed `iptables` via apk in `docker-compose.yml`. Rule now injects successfully. |
| DOCKER_GW variable parsing error | **Fixed** | Added `head -1` in `routing-fix.sh`. |
| `FIREWALL_OUTBOUND_SUBNETS` was the root cause | **Fixed** | Removed from `docker-compose.yml`. Gluetun no longer hijacks CGNAT routing. |
| Host tailscaled error state from aggressive `tailscale down` | **Mitigated** | Toggle script now detects and auto-restarts. |

### 10.14 Double-Tunneling MSS Clamping (Stalling Bug)

**Problem:** Traffic double-wrapped through Tailscale (WireGuard) and WARP (WireGuard) suffered 120 bytes of MTU overhead (60 + 60). The default MSS clamp of 1180 was still slightly too large, causing large packets to fragment or drop, which resulted in mysterious web page stalls on strict-MSS endpoints.

**Fix:** Lowered the TCP MSS clamp in `post-rules.txt` to `1120` to guarantee double-tunneled payloads fit safely within standard internet MTUs.

### 10.15 Linux Native Wi-Fi Bouncing

**Problem:** The generated `recover-linux.sh` incorrectly retained the macOS `networksetup` commands, which would crash and fail to bounce Wi-Fi on Linux hosts.

**Fix:** Swapped the macOS logic for native Linux commands. The script now attempts `nmcli radio wifi off/on` first, and gracefully falls back to `ip link set wl... down/up` if NetworkManager is unavailable.

### 10.16 TS_AUTH_ONCE Cloud Footgun & Ephemeral Keys

**Decision:** The compose file uses `TS_AUTH_ONCE=true` to prevent authentication loops. However, on headless cloud VPS deployments, if a standard auth key expires (usually 90 days), the container will silently drop off the mesh. We documented this trade-off explicitly in `docker-compose.yml` and recommended the use of **Tailscale Ephemeral Keys** for cloud deployments, which automatically clean themselves up and bypass this issue.

### 10.17 Hardcoded AdGuard Credentials

**Decision:** AdGuard is deployed with the hardcoded credentials `admin / nullexit`. This is perfectly safe behind a NAT on a local macOS laptop. However, if deployed on a cloud host with exposed ports, this becomes a severe security risk. We added a stark warning comment in `docker-compose.yml` to ensure cloud users change this before deployment.

### 10.18 Routing Fix: 5-Second Polling vs Netlink Socket

**Decision:** Instead of building a complex Netlink socket listener (`ip monitor`) to react instantly to iptables and routing flushes from Gluetun, we retained the 5-second `sleep` loop in `routing-fix.sh`. 
- **Reasoning:** Building a netlink listener in pure bash on Alpine is incredibly brittle and complex (especially for iptables events). The 5-second polling loop is bulletproof. The only trade-off is a potential 1-4 second stutter if Gluetun reconnects, which was deemed an acceptable edge case for absolute reliability.

### 10.19 Cache Poisoning and URL Rot in sync-rules.py

**Problem:** If a remote blocklist URL went permanently offline (404 Not Found), the Python `urllib` request would return the 404 HTML string. The script would aggressively regex-parse this HTML, find no domains, and overwrite the healthy local cache with a 0-domain file. This effectively disabled ad-blocking until the URL was fixed.

**Fix:** Implemented a defensive programming sanity check in `sync-rules.py`. Before overwriting the cache, the script now verifies that the compiled domain count is greater than 1,000. If it falls below this threshold (indicating a catastrophic 404 failure across multiple URLs), it aborts the cache overwrite, logs a `WARNING: Domain count suspiciously low`, and keeps the previous day's healthy cache intact.

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
