# nullexit — Development Reference & Resolved Issues

> **Last updated:** July 12, 2026
> **Purpose:** Provide any LLM or developer with complete project understanding, debugging history, and resolved issues so they can make informed changes without re-reading every file.
> **Diagrams:** See [`diagrams.md`](./diagrams.md) for system architecture, toggle.sh flowcharts, monitoring layer, traffic sequence, recover.sh decision tree, and the full failure→self-healing map.

This reference is organized into four parts:
> - **Part I — Architecture & Reference** (§1–§8)
> - **Part II — Design Decisions & Threat Model** (§9–§14)
> - **Part III — Incident Log & Resolved Issues** (§15)
> - **Part IV — Observations, Changelog & TODO** (§16–§18)

---

# Part I — Architecture & Reference

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
| `tailscale` | `tailscale/tailscale:v1.98.4` | Advertises as exit node on the mesh. Also provides the built-in SOCKS5 proxy fallback via `TS_SOCKS5_SERVER=:1080`. |
| `routing-fix` | `alpine:3.20` | Sidecar that maintains routing tables + iptables rules every 30 seconds. |
| `rule-compiler`| `golang:1.22-alpine` / `alpine:3.20` | One-shot startup container that compiles 500k+ DNS block rules in <2s and immediately exits. |
| `adguardhome` | `adguard/adguardhome:v0.107.77` | DNS sinkhole for ads/trackers. Listens on port 5335. Upstream DNS: `127.0.0.1:53` (through WARP). |

### Port Mappings (on host via Colima)
| Host Port | Container Port | Protocol | Purpose |
|-----------|---------------|----------|---------|
| 5354 | 5335 | TCP+UDP | AdGuard DNS |
| (Tailscale IP):3000 | 3000 | TCP | AdGuard web UI (Internal to Mesh) |
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
| `toggle.sh` | ~2109 | **Main script (macOS + Linux).** Dispatches on `$OSTYPE` — an early Linux block (shuf/ss/nmcli/ip, systemd) runs and exits before the macOS body (jot/netstat/networksetup, launchd/pf). Detects state, toggles gateway ON/OFF. Handles DNS hijacking, Tailscale exit node, SOCKS proxy, sleep prevention, timeouts, cleanup. |
| `setup.sh` | 406 | **One-time setup.** Installs deps (Docker, Tailscale, wgcf), generates WARP keys, writes `.env`, configures AdGuard via API, starts containers. |
| `docker-compose.yml` | 194 | Service definitions for all 5 containers. |
| `scripts/routing-fix.sh` | 201 | Maintains routing tables (table 200 for SOCKS5, table 52 for CGNAT) and FORWARD iptables rules in both nftables and legacy backends. Loads and enforces the IP blocklist via `ipset`. Runs in a 30-second loop. |
| `post-rules.txt` | 18 | Gluetun iptables rules loaded at container start. FORWARD accept for tailscale0, NAT MASQUERADE on tun0, DNS redirect to port 5335, IPv6 drop, TCP MSS clamping. |

| `scripts/dns-proxy.py` | 91 | Local DNS proxy. UDP:53 → TCP:5354 with proper 2-byte length prefix. Fallback when exit node is unavailable. |
| `scripts/rule-compiler/` | ~800 | Unified threat compiler (ported to Go from Python). **DNS pipeline:** fetches remote blocklists, deduplicates against AdGuard native filters, optimizes subdomains (~50% reduction), compiles to AdGuard syntax. **IP pipeline:** fetches threat-intel feeds (Spamhaus, Feodo, ET, CINS), strips private/Tailscale ranges, outputs atomic `ipset` restore file. Built dynamically in Docker multi-stage build. |
| **`adguard/work/`** | — | **Bind-mounted container data folder. Off-limits from outside Docker — READ-ONLY-EXCEPT-VIA-`sync-rules`. See README §6.** |
| `recover.sh` | ~742 | Nuclear recovery script (**macOS + Linux** — dispatches on `$OSTYPE`; the Linux branch runs a self-contained teardown via `resolvectl`/`nmcli`/`ip` and exits, macOS falls through to the dual-mode body). Gain: use `--post-wake` (macOS) for non-destructive refresh after sleep/wake or Wi-Fi roam — keeps the gateway live while still re-hijacking DNS + refreshing Tailscale exit-node + force-recreating warp if unhealthy. Resets DNS on ALL services, disables proxies, flushes routes, stops containers, kills sleep prevention, power-cycles Wi-Fi. Cryptographically verified. |
| `scripts/diagnose-host-leak.sh` | 580+ | **One-shot host-routing diagnostic.** Runs 8 checks (Tailscale, SOCKS5, CDN-cgi/trace, IPv6 leak, default route, output.log hints, gateway IP, Tailscale System Extension conflict), classifies into ONE of three known leak scenarios (A=SOCKS5 fallback, B=IPv6 leak, C=route freeze) or OK, writes a timestamped report to `host-leak-diagnostic-<UTC>.txt`, and prints a ready-to-run fix on stdout. Pass `--fix` to apply the matched remediation and re-verify egress. Pass `--watch` (or `--watch 30`) to run a full baseline then continuously monitor warp/IPv6/default-route every N seconds, alerting on any state change. See §15.6.1. |
| `scripts/host-leak-probe.sh` | — | **REMOVED (2026-07-15, verified deleted/untracked).** Was a continuous sub-second host-egress prober auto-launched via `HOST_LEAK_PROBE`. Its fail-closed role is now covered by the **PF kill-switch** (`enable_killswitch` in `common.sh`) + the in-container **WARP Watcher** (§15.6.2); on-demand auditing is `scripts/diagnose-host-leak.sh`. See §15.6.1 (retained as historical rationale). |
| `scripts/fix-docker-bridge-collision.sh` | ~290 | **One-shot fix for §15.2.3 (Docker bridge subnet collision).** Detects Docker's `172.17.0.0/16` bridge colliding with the host Wi-Fi subnet (the symptom that produces `default 172.17.0.1 UGScg en0` in `netstat -rn`), picks a non-colliding `docker.bip` from a small candidate set, idempotently edits `~/.colima/default/colima.yaml` with a timestamped backup, restarts Colima, rebinds Wi-Fi DHCP, verifies the new default route is no longer Docker's bridge, and re-runs `toggle.sh` + `scripts/diagnose-host-leak.sh`. Supports `--dry` and `--skip-toggle`. |
| `scripts/watcher.sh` | 194 | **Long-running post-wake + post-roam daemon.** Launched by launchd LaunchAgent; subscribes to `com.apple.powermanagement` events via `log stream` and to network-state changes via `scutil n.watch`. Both fire `recover.sh --post-wake`. Single-instance lock + SCRIPT_DIR-relative resolve of `RECOVER`. See §15.5.1. |
| `scripts/common.sh` | ~40 | **Shared script primitives.** Centralizes formatted echo statements (`step`, `ok`, `warn`, `die`) and the safe background `run_with_timeout` execution wrapper. Sourced by all orchestrator scripts across macOS and Linux. |
| `scripts/setup-common.sh` | ~350 | **Shared installation logic.** Centralizes logic for verifying Docker, installing Tailscale/wgcf, generating `.env`, and prompting for auth keys. Sourced by `setup.sh` and `setup-linux.sh`. |
| `scripts/setup-linux.sh` | ~80 | **Linux sibling of `setup.sh`.** Sources `setup-common.sh`. Distro detection (apt/dnf/pacman), installs Linux-specific dependencies, creates `.desktop` shortcuts. |
| `scripts/Toggle-Gateway.bat` | ~300 | **Windows Toggle helper.** Moved from root to `scripts/`. Helps invoke the framework on Windows if applicable. |
| `scripts/reinstall-host-tailscale.sh` | ~740 | **Nuke-and-reinstall tool for host Tailscale.** Completely purges Tailscale, its settings, macOS Background Items (`.btm` database), and stale System Extensions. Wipes ALL Login Items via `sfltool reset-login-items` (requires sudo). Useful for crisis recovery but destructive to other login items. |
| `scripts/fix-ssh-delay.sh` | ~100 | **Fixes SSH connection delays.** One-shot script to address SSH delays caused by DNS or routing issues, useful in crisis situations. |
| `scripts/logger/` | ~100 | **Internal logger piped from `scripts/routing-fix.sh`** inside the `warp` container. Ported to Go from Python. Built via Docker multi-stage build. |
| `black_list.txt` | 71 | Custom domains to block (ads, trackers, telemetry). Supports `$important` modifier. |
| `white_list.txt` | 222 | Domains to force-allow (YouTube, Apple services, etc.). Always wins over blocks. |
| `.env` | ~14 | WARP WireGuard keys, Tailscale auth key, rule profile. **Contains secrets & NULLEXIT_SEED.** |
| `.gateway_ip` | 1 | Static gateway Tailscale IP (fallback for dynamic resolution). |
| `scripts/unlock-files.sh` | ~20 | **One-shot stale-permission fix.** Uses atomic rename (`cp` + `mv`) to replace locked inodes (mode `000`/`0444` from old `chmod` decisions) with fresh writable ones — no `chmod` called. |
| `scripts/crypto.sh` | ~50 | **Cryptographic integrity enforcement.** Uses `NULLEXIT_SEED` from `.env` to sign core bash scripts (HMAC-SHA256) and strictly verify them on start to prevent manipulation. Pass `--sign` or `--verify`. |
| `scripts/pf.conf` | 35 | **macOS native firewall ruleset.** Enforces the default-deny kill-switch, allows local LAN / Tailscale traffic, and applies TCP MSS Clamping (`max-mss 1160`) to prevent WireGuard MTU fragmentation. |

---

## 4. toggle.sh Flow

### State Detection
`is_gateway_active()` returns true if EITHER containers are running OR host DNS is not `1.1.1.1`. This dual check prevents the script from starting when it should stop (e.g., containers crashed but DNS is still hijacked).

### START Path (gateway OFF → ON)
1. **Reset DNS to 1.1.1.1** — Prevents deadlocks during startup
2. **Disconnect host Tailscale** — `tailscale down` (prevents exit-node routing during container boot)
3. **Compile DNS rules** — `docker compose run --rm rule-compiler` (Go binary inside multi-stage Docker build)
4. **Boot Colima VM** (if not running) — via `colima_start_until_ready()`, which returns as soon as Docker is reachable (~12s) instead of blocking on Colima's ~2-min post-provision hang (§15.8.7). The networking mode is **gated on the LAN-P2P signal** (`.lan_p2p_detected`, falling back to `TAILSCALE_ALLOW_LAN_P2P` in `.env`): a trusted home network requests `--network-address --network-mode bridged` (or `shared` on WPA2-Enterprise), while the common AP-isolated / untrusted case boots plain fast user-mode networking (`colima start --memory 0.6 --vm-type vz`).
   - **Why Bridged Networking (when enabled)?** The `--network-mode bridged` and `--network-address` flags force the VM to receive its own IP directly from your local router's DHCP server, placing it on the same physical subnet as the host. This bypasses macOS network isolation and is what lets **external LAN devices** (phones, laptops on the same LAN), mDNS, and local service discovery reach across the container boundary. It requires the `socket_vmnet` helper and is only worthwhile on a trusted LAN, which is why it is gated rather than always requested. **It is *not* required for direct host↔container P2P** — that path (the gateway ↔ its own Mac) works even in user-mode networking via the routing-fix `.host_ips` RETURN-rule carve-out; see §15.3.5 and §15.8.7.
   - **Enterprise Wi-Fi Fallback & Dynamic Roaming:** `toggle.sh` dynamically queries `system_profiler SPAirPortDataType` on boot. If it detects a **WPA2-Enterprise** connection (802.1X), it forces Colima to fall back to `--network-mode shared`. This prevents aggressive network intrusion systems on corporate/university Wi-Fi switches from terminating the host's Wi-Fi connection due to "MAC spoofing" (detecting multiple MAC addresses originating from a single authenticated port). P2P connections are impossible on these networks anyway due to AP Client Isolation.
     - **Dynamic Roam Downgrading:** `toggle.sh` writes its selected network mode to `/tmp/nullexit_colima_mode.txt`. When roaming between networks (e.g., Home to University), `recover.sh` actively checks this state against the new network's security requirement (`.lan_p2p_detected`). If a mismatch is detected (e.g., bridged Colima on an Enterprise network), `recover.sh` automatically forces a full `toggle.sh --restart` in the background to safely transition the Virtual Machine's network mode and protect the host from de-authentication.
5. **Configure VM swap** — 400MB swap file inside the VM to prevent OOM
6. **Clean corrupted AdGuard config** — Remove empty `AdGuardHome.yaml`
7. **Start containers** — `docker compose up -d`
8. **Wait for gateway Tailscale** — Poll `tailscale status` for "offers exit node" (up to 60s, abort at 40 consecutive NoState)
9. **Resolve gateway IP** — From `.gateway_ip` or `docker compose exec tailscale tailscale ip -4`
10. **Connect host to mesh** — Verify `tailscaled` is running (auto-start if needed), then `tailscale up --reset --ssh=true --accept-dns=false --accept-routes=true --exit-node=` (`--accept-routes=true` must be explicit — `--reset` reverts it to `false` otherwise, silently preventing the default route from switching to `utun*`)
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

### 5.1 Tailscale Local Network Discovery (DERP Bypass)
By default, Gluetun's strict NAT swallows all of Tailscale's UDP hole-punching packets, forcing Tailscale to fall back to incredibly slow DERP relay servers (often adding 500ms+ latency). 

To fix this, we use `FIREWALL_OUTBOUND_SUBNETS=192.168.0.0/16,172.16.0.0/12,10.0.0.0/8` in `docker-compose.yml` (on the `warp` container). This creates `ip rule` bypasses (Priority 99, Table 199) that route all packets destined for private IP ranges *outside* the WARP tunnel directly to the host's `eth0`. 
- **172.16.0.0/12** is especially critical because many modern Wi-Fi routers (and Docker itself) assign IPs in this block (e.g., `172.17.x.x`). 
- This bypass allows Tailscale's UDP packets to reach devices on the same Wi-Fi directly, establishing a fast peer-to-peer connection while the actual web traffic inside the tunnel remains fully routed through WARP.

---

### 5.2 Firewalling & Per-Device Access Control
Because every mesh device's traffic passes through the `warp` container's network namespace, this namespace serves as the ultimate choke point for network-wide firewall rules.

**Where to Put Rules**
The right place to add firewall rules is `scripts/routing-fix.sh`. It runs a 30-second loop inside the namespace and already handles re-injecting rules that Gluetun resets on reconnect. **Do not use `post-rules.txt` for dynamic rules**, as Gluetun flushes and resets it upon VPN reconnects.

**The Dual iptables Backend Constraint (CRITICAL)**
The container runs two simultaneous iptables backends: `iptables` (for the nftables backend used by Gluetun) and `iptables-legacy` (for Tailscale). Every rule **must** be added to both stacks, or it will silently fail for certain traffic. 

**Avoiding Duplication**
Because `scripts/routing-fix.sh` runs in a loop, you must always check for a rule's existence with `-C` before appending with `-A`. Otherwise, your rules will duplicate every 30 seconds.

**Per-Device Identification & Filtering**
Each mesh device has a stable `100.x.x.x` Tailscale IP, which is visible as the `src` IP in the `FORWARD` chain. This is how you identify devices for filtering.
* **Domain-level:** AdGuard Home (port 3000, credentials `admin/nullexit`) provides a REST API that supports per-client blocking rules based on their Tailscale IP.
* **IP-level:** Use `iptables` in `scripts/routing-fix.sh` (e.g., `iptables -I FORWARD -s 100.x.x.x -d <blocked_ip> -j DROP`).
* **Country-level:** Add `ipset` to the `routing-fix` apk install step in `docker-compose.yml`, and load CIDR ranges from `ipdeny.com` into an ipset, then block that set in the `FORWARD` chain. See §5.3 (Geo-IP Blocking) for the full configuration flow.

### 5.3 Geo-IP Blocking
To block traffic to and from specific countries, the system dynamically downloads country-specific IP ranges from [ipdeny.com](http://www.ipdeny.com/ipblocks/data/countries/) and drops them via iptables `FORWARD` rules.

To add a new country to the blocklist:
1. Find the 2-letter ISO country code (e.g., `cn` for China, `ru` for Russia, `il` for Israel, `kp` for North Korea).
2. Open your `.env` file.
3. Update the `BLOCKED_COUNTRIES` variable: e.g., `BLOCKED_COUNTRIES="kp il cn ru"`.
4. Run `toggle.sh` to restart the gateway and apply the new environment variables to the routing-fix container.

> [!NOTE]
> **Limitations of Geo-IP Blocking:** IP-based blocking is highly effective at blocking servers, direct apps, and raw infrastructure physically located and registered in a specific country (e.g., `www.gov.il`). However, it will **not** block high-profile websites (e.g., `jpost.com`) that route their traffic through global Content Delivery Networks (CDNs) like Google Cloud, Cloudflare, or Fastly. Because the CDN's IP addresses are registered in the US or globally, the network traffic physically never routes to the blocked country, allowing it to bypass the Geo-IP firewall.

## 6. macOS Quirks to Remember

1. **Colima SSH tunnel is TCP-only** — UDP ports (like 5354/udp) are NOT accessible from host. Use `dig +tcp` or the Python DNS proxy (UDP→TCP converter).
2. **`docker compose exec -T` injects `\r`** — Always `tr -d '\r'` when capturing output for comparisons or `networksetup` commands.
3. **`brew services` can get stuck** — Fix with `sudo brew services restart tailscale`. Common state: `brew services list` shows `started` but `tailscale status` shows "Tailscale is stopped."
4. **No `timeout` command** — macOS lacks GNU `timeout`. Use the `run_with_timeout()` bash function.
5. **`sudo -v` prompts even with NOPASSWD** — Use `sudo -n` (non-interactive) everywhere.
6. **DNS is scoped to en0** — macOS scutil DNS resolver is scoped to en0 (Wi-Fi). DNS changes on other interfaces (like USB Ethernet) are ignored unless en0's service is also updated. The script always sets DNS on BOTH `$ACTIVE_SERVICE` and `$EN0_SERVICE`.
7. **tailscaled clobbers DNS during exit-node transition** — `force_dns_to_gateway` is called a second time at the end of the ENABLE branch to counteract this.
8. **`tailscale up --reset`** resets all unspecified flags to defaults — Every `--reset` call MUST also pass `--accept-dns=false` explicitly or tailscaled re-enables DNS management.
9. **`docker compose ps` CWD pitfall** — `docker compose` commands require a `docker-compose.yml` in the current working directory. Use `docker ps` for raw container listing from any CWD; `docker compose ps` requires the project directory.

---

## 7. Environment Variables

### `.env` File
| Variable | Purpose |
|----------|---------|
| `WIREGUARD_PRIVATE_KEY` | WARP WireGuard private key (from `wgcf generate`) |
| `WIREGUARD_PUBLIC_KEY` | WARP WireGuard public key |
| `WIREGUARD_ADDRESSES` | WARP WireGuard address (e.g., `172.16.0.2/32`) |
| `TS_AUTHKEY` | Tailscale auth key for the container |
| `NULLEXIT_SEED` | 256-bit seed for HMAC-SHA256 script integrity signing (generated by `setup.sh`) |
| `GATEWAY_RULE_PROFILE` | Rule compilation tier: `light`, `medium`, `heavy` |
| `GATEWAY_BYPASS_PING` | (Optional) `true` to proceed even if pre-flight checks fail |
| `GATEWAY_USE_EXIT_NODE` | (Optional) `false` to skip exit node, DNS-only mode |
| `GATEWAY_HIJACK_HOST` | (Optional) `false` to skip DNS hijacking on the host (VPN/adblocking for Tailscale peers only) |
| `GATEWAY_MSS` | (Optional) TCP MSS clamp value (default 1120); 1180 for speed on healthy paths |
| `WARP_FAIL_THRESHOLD` | (Optional) Consecutive `warp=off` polls before auto-shutdown (default 6 = 30s; 3 = 15s) |
| `WARP_ENDPOINT_1` | (Optional) Override Cloudflare WARP WireGuard endpoint IP 1 (default `162.159.192.1`) |
| `WARP_ENDPOINT_2` | (Optional) Override Cloudflare WARP WireGuard endpoint IP 2 (default `162.159.193.1`) |
| `KILL_SWITCH` | (Optional) `true` to enforce strict PF lock — drops all host traffic if VPN fails. Breaks SSH if VPN dies. |
| `STOP_COLIMA_ON_EXIT` | (Optional) `true` to fully shut down the Colima VM on toggle-off (saves battery on dedicated hosts) |
| `ADGUARD_USER` | (Optional) AdGuard Home web UI username (default: `admin`) |
| `ADGUARD_PASSWORD` | (Optional) Shared password for AdGuard Home and Tor ControlPort (default: `nullexit`) |
| `BLOCKED_COUNTRIES` | Space-separated 2-letter ISO codes to block via ipdeny.com CIDR ranges (e.g. `"kp il cn ru"`) |

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

# Part II — Design Decisions & Threat Model

## 9. Privacy Architecture & Threat Model

### Layered Defense
The gateway stacks four layers targeting different attack surfaces:

- **Layer 1 — ISP-Level Surveillance (WARP):** Your ISP sees only an encrypted WireGuard tunnel to a Cloudflare IP. In the US, ISPs can legally sell your browsing metadata and are subject to secret NSLs (National Security Letters). WARP removes their visibility entirely.
- **Layer 2 — DNS Tracking (AdGuard Home):** DNS is the phone book of the internet. By default, queries go to your ISP's resolver, giving them a complete log of your traffic. AdGuard intercepts all DNS from mesh devices, blocks trackers, and resolves queries through the WARP tunnel.
- **Layer 3 — Device Identity & IP Exposure (Tailscale):** On untrusted networks (coffee shops, public Wi-Fi), your device's IP is exposed. Tailscale creates an encrypted WireGuard mesh between your devices, routing all traffic to your gateway exit node.
- **Layer 4 — Kernel-Level IP Blocking (ipset/iptables):** Sophisticated malware bypasses DNS entirely with hardcoded IPs. The `rule-compiler` fetches ~16,700 threat-intelligence IPs/CIDRs (Spamhaus, Feodo Tracker, Emerging Threats, CINS) and enforces them as `DROP` rules in the kernel `FORWARD` chain — blocking both outbound C2 connections and inbound attack traffic.

### The Documented Threat: Why This Matters
This architecture is calibrated against documented mass-surveillance programs revealed in the Snowden disclosures:
- **PRISM:** Bulk collection of communication content from major tech providers.
- **UPSTREAM:** Tapping physical backbone fiber, collecting metadata and content in bulk.
- **XKeyscore:** Retroactive search of unencrypted traffic.
- **MUSCULAR:** Infiltration of unencrypted internal datacenter interconnect links.

Passive bulk collection is not paranoia — it is a documented reality. By double-encrypting and routing traffic, nullexit prevents your ISP from harvesting your metadata.

### Trust Assumptions & Shifting
Every component shifts trust rather than eliminating it:
1. **Physical Device Integrity:** You trust your physical devices are not compromised.
2. **Cloudflare Integrity:** You trust Cloudflare not to correlate your WARP tunnel with exit traffic.
3. **Tailscale Integrity:** You trust Tailscale's coordination server not to MITM WireGuard keys.

The goal: no single provider has a complete picture. Your ISP sees an encrypted tunnel. WARP sees traffic with no account identity. Tailscale sees node topology but not content.

### 9.1 Exit Node IP Rotation (Design Decision)

A common question for privacy architectures is whether the system should aggressively rotate its public exit IP (e.g., every 5 minutes, like a Tor circuit or a proxy rotator). 

`nullexit` uses Cloudflare WARP via Gluetun. WARP provides **anonymity in a crowd** rather than aggressive rotation. Thousands of users share the same Cloudflare Edge IP simultaneously, making your traffic indistinguishable from the herd. The IP may occasionally rotate on its own (historically surfaced as a `ROTATE` event in `output.log`), but it remains generally stable.

**Why aggressive IP rotation was intentionally excluded:**
1. **Broken TCP Connections:** Every rotation instantly drops all long-lived TCP sessions (SSH, large downloads, WebSockets, gaming, Zoom). 
2. **CAPTCHA & 2FA Hell:** Modern web security (e.g., Cloudflare, Akamai) aggressively flags IP-hopping as bot behavior. Aggressive rotation guarantees the user will be bombarded with "Verify you are human" CAPTCHAs and "New Login Detected" 2FA emails constantly.
3. **WireGuard Architecture:** WireGuard is stateless and does not natively support IP hopping on the fly. To rotate an IP, the VPN client must actively drop the tunnel, request a new endpoint, and re-handshake. This introduces latency gaps where the kill-switch would repeatedly trigger and blackhole the user's internet.

**Verdict:** For a daily-driver secure gateway, shared-IP crowding (WARP) is superior to aggressive rotation. As an added benefit, Cloudflare WARP IPs are actually highly static (tied to the persistent WireGuard public key generated for your device identity). Because your IP stays static and is part of Cloudflare's own trusted network, it builds a high "trust score," virtually eliminating CAPTCHA loops while still hiding you within the massive crowd of other users in that data center. All mesh devices routing through your gateway will reliably share this exact same trusted IP. 

*(Note: The only exception where aggressive IP rotation is genuinely required is for specialized offensive security tasks—like high-volume web scraping or dark web research—where avoiding IP bans or active tracking overrides the need for TCP stability.)*

### 9.2 Cloudflare WARP Privacy & Logging

Because `nullexit` uses Cloudflare WARP (via Gluetun) as its upstream exit node, the system inherits Cloudflare's consumer privacy policy.

**What Cloudflare DOES NOT log (Strict No-Logs Policy):**
* **Browsing History:** They do not log the domains or URLs you visit.
* **Traffic Destinations:** They do not log the IP addresses of the servers you connect to.
* **Content:** They do not inspect or log the payload/data of your traffic.
* **Data Brokering:** They explicitly guarantee they will never sell or rent your data to advertisers.

**What Cloudflare DOES log (Minimal Telemetry):**
* **Data Transfer Volume:** Total bandwidth used (required to enforce 10GB/mo quotas if you are not using a paid WARP+ key).
* **Performance Metrics:** Anonymized connection speeds and latency to optimize their network routing.
* **Aggregate Volume:** Total traffic volumes to popular destinations in aggregate (e.g., "datacenter X sent 50TB to Netflix"), stripped of all user IDs.
* **Device ID (Public Key):** They store the persistent WireGuard public key generated by your container to authorize the connection.

**Privacy Verdict:**
Cloudflare WARP provides excellent **historical privacy**. Because they do not log your destinations, they cannot comply with historical subpoenas asking what websites you visited yesterday. However, it is **not absolute anonymity**. They still know your real ISP IP address while you are actively connected. For daily-driver privacy against ISPs, hackers, and corporate trackers, it is top-tier. For nation-state evasion, use Tor (see §11).

### 9.3 OPSEC: Python Runtime Airgap (Isolated Mode)
`nullexit` explicitly relies on the host's native system Python 3 runtime for critical components like `scripts/dns-proxy.py`. Because this script runs with elevated privileges (`sudo -n`) to bind to the privileged UDP/53 socket, modifying or polluting this Python environment is strictly forbidden.

**The Zero-Dependency Rule & Isolated Mode (`-I`)**
You must **NEVER** install third-party `pip` packages (e.g., `requests`, `pyyaml`) into the system Python environment that `nullexit` uses. 
- All Python scripts in this repository must be written using *only* the Python Standard Library (`socket`, `urllib`, `json`, `ssl`).
- Third-party packages introduce a massive supply-chain attack vector. A compromised `pip` package installed globally could allow local malware to hook into the Python runtime and exploit the `sudo` privilege of the DNS proxy to gain full root access.
- To enforce strict immunity against user-installed malicious packages, `toggle.sh` explicitly invokes the proxy using **Python's Isolated Mode** (`python3 -I`). This flag forces the interpreter to completely ignore `PYTHONPATH`, `PYTHONHOME`, and the user's `site-packages` directory, executing exclusively from the read-only, Apple-signed system framework.

### 9.4 Recommended Upgrades

| Layer | Default | Upgraded |
|---|---|---|
| VPN Exit | Cloudflare WARP (US) | Mullvad (Swedish, proven no-logs, anonymous payment) |
| DNS Resolver | AdGuard via WARP | AdGuard via Mullvad DoH (Cloudflare-blind) |
| Coordination | Tailscale (US, OAuth) | Headscale (self-hosted, no third-party) |
| Auth | OAuth / persistent keys | Ephemeral auth keys (no identity persistence) |
| Content | WireGuard asymmetric | WireGuard + PSKs (coordination server blind) |

#### Mullvad (Replacing WARP)
Swedish-based. Police raided their offices in 2023 and left empty-handed — no logs exist to seize. Accounts are random numbers. Payment by cash or Monero. Replace `VPN_SERVICE_PROVIDER=custom` with `VPN_SERVICE_PROVIDER=mullvad` in `docker-compose.yml`.

#### Mullvad DoH Upstreams
Point AdGuard's upstream resolvers to `https://adblock.dns.mullvad.net/dns-query`. Cloudflare WARP only sees encrypted HTTPS to Mullvad's IPs — completely blind to your DNS queries.

#### Headscale
Self-hosted Tailscale coordination server. Eliminates Tailscale the company, keeping all node topology under your control.

#### Ephemeral Auth Keys
Generate in the Tailscale admin panel. Used once to authenticate; node disappears from the admin panel after disconnect. Breaks persistent identity linkage.

#### Pre-Shared Keys (PSKs)
Add a WireGuard PSK between peer nodes. Adds a symmetric encryption layer that Tailscale's coordination server has no knowledge of, blinding it from reading transit content.

### 9.5 Structural Limitations
- **Traffic Analysis / Metadata:** Passive fiber tapping (UPSTREAM) can observe timestamps, data volumes, and IP ranges without reading content. Defeating traffic analysis requires mixing networks (Tor) or continuous dummy packet padding — both heavily degrade performance.
- **Targeted State-Level Adversaries:** Consumer-grade VPNs are not a complete shield against a nation-state actively targeting you. This stack is designed to defeat bulk passive surveillance and corporate dragnet collection.

---

## 10. Per-Device Access Control

Because every mesh device routes internet-bound traffic through the `warp` container's `FORWARD` chain, they all appear with their stable `100.x.x.x` Tailscale IP as the `src` address. This gives two powerful enforcement surfaces:

### IP & Port Level (`scripts/routing-fix.sh`)
Write raw `iptables` rules targeting specific devices. The 30-second idempotent loop auto-survives Gluetun reconnects:

```bash
# Block a specific device from a target subnet
iptables -I FORWARD -s 100.x.x.x -d 203.0.113.0/24 -j DROP

# Restrict a device to only HTTP/HTTPS
iptables -I FORWARD -s 100.x.x.x -p tcp ! --dport 3000 -j DROP
iptables -I FORWARD -s 100.x.x.x -p tcp ! --dport 443 -j DROP

# Block a device from internet egress entirely (mesh only)
iptables -I FORWARD -s 100.x.x.x -j DROP

# Time-based (e.g., cut off 10 PM – 7 AM)
iptables -I FORWARD -s 100.x.x.x -m time --timestart 22:00 --timestop 07:00 -j DROP
```

### DNS Level (AdGuard REST API)
AdGuard Home supports per-client rules keyed by Tailscale IP:

```bash
curl -X POST http://localhost:80/control/clients/add \
  -H "Content-Type: application/json" \
  -d '{
    "name": "kids-ipad",
    "ids": ["100.x.x.x"],
    "blocked_services": ["youtube", "tiktok", "instagram"],
    "safesearch_enabled": true
  }'
```

---

## 11. Tor & OPSEC Architecture

### 11.1 Tor-over-WARP Topology

When extreme anonymity is required, integrating the Tor network into `nullexit` provides a powerful Tor-over-VPN topology:
* **The University/ISP** sees only an encrypted Cloudflare WireGuard tunnel, rendering them completely blind to the fact that you are using Tor (effectively bypassing Enterprise firewall Tor blocks).
* **Cloudflare** sees an encrypted TCP stream heading to a Tor Guard Node. They cannot see your DNS lookups, the destination website, or the content of your traffic.
* **The Tor Exit Node** sees your traffic, but not your real IP (only the Cloudflare IP).

#### The "Transparent Proxy" Trap (What NOT to do)
It is tempting to build a system-wide "Transparent Tor Proxy" that forces all host traffic (e.g., standard Chrome/Safari browsers, background iCloud syncs) through Tor automatically. **This is a massive OPSEC trap and destroys anonymity.**
Modern operating systems and browsers will instantly leak your identity through background syncing (e.g., Apple Mail, Google Drive) and browser fingerprinting (canvas fingerprints, WebRTC, screen resolution). The Tor network protects your *IP*, but if your payload contains identifying cookies or unique fingerprints, the Tor Exit Node (which could be run by malicious actors) will instantly tie your session to your real identity.

#### The nullexit Implementation: Isolated Procedural Proxy
To safely integrate Tor without triggering the transparent proxy trap, `nullexit` implements an **Isolated Tor SOCKS5 Proxy** with **Procedurally Generated Ports**:
1. **Isolated Container:** A lightweight `tor` Docker container runs securely inside the `warp` network namespace. It does not hijack system traffic.
2. **Opt-In Usage:** You must consciously configure a highly-hardened browser (like the official Tor Browser or a dedicated Firefox profile) to use the proxy. This prevents accidental background sync leaks.
3. **Procedurally Generated Ports:** Rather than hardcoding the standard proxy ports (like `127.0.0.1:9050` or `1080`), `toggle.sh` randomizes all internal proxy ports on every boot into the ephemeral range (10000-65000) and silently writes them to `/tmp/nullexit-ports.env`. This completely defeats static fingerprinting by malware.
4. **Kernel-Level Collision Avoidance:** To prevent the randomizer from picking a port already in use by a root daemon or Apple service (which would crash the gateway), the script directly queries the macOS kernel socket table (`netstat -an -p tcp`) to verify the port is absolutely free before assigning it.
5. **The Honey-Port Tripwire:** While procedural ports defeat static fingerprinting, advanced malware might attempt a full sequential port scan of `localhost` to find the hidden proxy. To counter this, `toggle.sh` spawns a "Honey-Port" (a fake random port with a netcat listener attached). If any local application attempts to connect to the Honey-Port, it instantly logs a critical security alert to `output.log` and fires a macOS desktop notification, serving as an early-warning Intrusion Detection System (IDS) for local malware.

> **Threat Model note:** The Tor SOCKS proxy and Honey-Port Tripwire only bind to `127.0.0.1` (loopback). Port randomization and the Honey-Port only defeat blind, generic port-scanners — they do NOT protect against a targeted local process that reads `/tmp/nullexit-ports.env`, greps process memory, or runs `lsof -i`. The proper mitigation is a host-level loopback-filtering firewall (LuLu/Little Snitch). See §15.9 (Threat Model: Local Proxy Discovery) for the full analysis and the rogue-binary verification test.

### 11.2 Hardening: Tor Bridges and obfs4 Pluggable Transports
For users operating under severe Deep Packet Inspection (DPI), `nullexit` supports configuring Tor to connect exclusively through private bridges using the `obfs4` pluggable transport. 

When `TOR_USE_BRIDGES=true` is set:
- **What it does:** It hides the entry IP from being matched against the public Tor consensus list, and disguises the traffic's protocol fingerprint from the WARP exit provider (Cloudflare).
- **What it does NOT do:** It does *not* add any extra layers of anonymity beyond what Tor already provides. It is purely a censorship-circumvention and obfuscation mechanism.
- **Limitations:** `obfs4` is highly effective against passive DPI, but it is not guaranteed to defeat active-probing-resistant detection by a highly sophisticated state-level adversary.

> **Architecture Rule:** The `nullexit` gateway deliberately does NOT bundle, hardcode, or automatically fetch bridge lines. Bridge lines are highly sensitive and expire. Users must obtain their own bridge lines from `https://bridges.torproject.org` and manually populate the `tor-bridges.txt` file. If bridges are enabled but the file is missing or empty, the Tor container will intentionally crash and fail to start rather than silently falling back to public guard relays.

**The Bootstrapping Paradox (Out-of-Band Key Exchange)**
Automating the bridge acquisition process (e.g., scripting the gateway to log into the Telegram `@GetBridgesBot` via MTProto API) introduces catastrophic OPSEC flaws:
1. **Identity Leaks:** Baking a Telegram session into the container explicitly links the "anonymous" gateway to a real-world physical phone number.
2. **The Chicken & Egg Deadlock:** In heavily censored regimes, Telegram itself is usually blocked. If the container requires Telegram to fetch bridges to bypass the firewall, it will fail because it cannot bypass the firewall to reach Telegram.
3. **Bridge Exhaustion & CAPTCHAs:** Automated scraping behaves identically to state-sponsored scrapers, triggering Tor's anti-bot CAPTCHAs which leads to silent proxy failures and exhausts the limited public bridge pool.

Instead, users should rely on a less secure layer to manually reach Telegram, obtain the bridges, and populate `tor-bridges.txt`. This can be done via the standard `nullexit` WARP tunnel, a mobile phone on cellular data, Mullvad VPN, or a secure remote VPS. *(Note: We plan on fully integrating Mullvad and VPS architectures directly into `nullexit` in the future, but have not had the time to build it yet).* This intentionally "air-gaps" the cryptographic key exchange from the proxy infrastructure, leaving zero API tokens and zero network traces for an adversary to exploit.

### 11.3 Tor Container Kill-Switch Inheritance & Fail-Closed Egress Verification

#### Context
Unlike the host's SOCKS5 fallback path (whose kill-switch interaction is documented in §15.7), the `tor` container's connection status and fail-closed behavior under VPN tunnel drops is not governed by macOS `pf` rules. Instead, it relies on network namespace inheritance inside Docker Compose.

#### Mechanics
1. **Shared Network Namespace:** The `tor` service is configured with `network_mode: service:warp` in `docker-compose.yml`. This shares the network namespace of the `warp` (Gluetun) container.
2. **Inherited Egress Rules:** All socket communication within the namespace is bound to the same networking stack. Gluetun manages this stack by redirecting traffic through `tun0` (the WireGuard/WARP tunnel) and applying `iptables` rules that explicitly drop outbound traffic originating on `eth0` (the physical/bridge interface), except for permitted local subnets or the VPN server's endpoint.
3. **Tunnel Fail-Closed:** If the WARP connection drops or the `tun0` interface is brought down, the routing table entries for `tun0` become invalid or disappear. Because the `iptables` rules in the shared namespace continue to drop any outgoing internet traffic attempting to exit via `eth0`, the `tor` container cannot leak raw traffic to the host's underlying networks. Egress fails closed.

#### Verification / Manual Test Case
To manually verify that the Tor container fails closed and does not leak traffic when the tunnel dies:

1. **Verify active path:** Ensure the gateway is active (`toggle.sh start`) and fetch the Tor port (`$TOR_SOCKS_PORT` in `/tmp/nullexit-ports.env`). Verify Tor traffic routes correctly:
   ```bash
   curl --socks5-hostname 127.0.0.1:$TOR_SOCKS_PORT https://check.torproject.org/api/ip
   ```
   *(This should output a Tor exit node IP).*

2. **Simulate tunnel drop:** Bring down the virtual interface inside the shared network namespace:
   ```bash
   docker compose exec warp ip link set dev tun0 down
   ```

3. **Re-run the egress check:**
   ```bash
   curl --socks5-hostname 127.0.0.1:$TOR_SOCKS_PORT https://check.torproject.org/api/ip
   ```
   * **Expected Result:** The request must hang and eventually time out, or immediately fail with a proxy error (e.g., `curl: (97) SOCKS5: connection failed` or `curl: (7) Failed to connect`).
   * **Leaked Egress Check:** Check the host's Wi-Fi router or firewall logs. No outbound packets from the Tor container should route directly over the bridge network to the internet.

### 11.4 Transparent .onion Routing via RFC 2544 Subnet (198.18.0.0/15)

#### Context
To enable seamless dark web browsing across the entire mesh, the gateway requires a mechanism to dynamically map `.onion` domains to IP addresses that the host operating system and network layers can route.

#### IP Address Conflict & Solution
1. **Initial Conflict:** Initially, the Tor virtual address network was configured to map `.onion` sites within the `10.192.0.0/10` range. However, the Colima Docker daemon dynamically allocated `10.200.1.0/24` to the containers. Because this Docker subnet mathematically falls within the `10.192.0.0/10` block, a routing loop occurred: all host packets destined for the Docker containers on ports like `9050` or `9051` were intercepted by the transparent proxy NAT rules and dropped, causing proxy failures.
2. **Tailscale Private IP Exclusion:** Shifting the subnet to another private range like `10.123.0.0/16` resolved the port conflict, but led to connection timeouts. On macOS, Tailscale's Exit Node routing actively excludes RFC 1918 private subnets (e.g. `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) to maintain accessibility to local LAN resources (like printers/routers). Thus, packets targeting `10.123.x.x` were dropped locally by Tailscale before reaching the gateway tunnel.
3. **The Benchmarking Subnet Solution:** To bypass these private IP exclusions without manual static routing tables, Tor's virtual network was changed to **`198.18.0.0/15`** (reserved by RFC 2544 for benchmarking). Since this is not a private RFC 1918 range, Tailscale exit-node routing automatically encapsulates and routes all traffic destined for `198.18.0.0/15` through the tunnel to the gateway.
4. **Transparent NAT Redirection:** The `routing-fix` sidecar applies NAT rules in the shared network namespace:
   ```bash
   iptables -t nat -I PREROUTING -d 198.18.0.0/15 -p tcp -j REDIRECT --to-ports 9040
   ```
   This intercepts all incoming TCP traffic targeting the mapped `.onion` range and transparently proxies it through Tor's transparent port (`9040`).

#### Exit Node Exclusions
The gateway supports the ability to exclude specific countries from being used as exit nodes (e.g. to avoid certain jurisdictions or nodes with poor network latency). This is configured globally via the `TOR_EXCLUDE_EXIT_NODES` environment variable in `.env`, which gets dynamically appended to Tor's `ExcludeExitNodes` and strictly enforced with `StrictNodes 1`.

---

## 12. Censorship-Resistant Transport & Egress Compartmentalization

### 12.1 Why this is needed
WARP can be blocked from deployment countries with strict internet controls. The most likely cause isn't that "encrypted traffic is blocked" in general — it's that WireGuard has a recognizable handshake signature, and `WIREGUARD_ENDPOINT_IP=162.159.192.1` on `WIREGUARD_ENDPOINT_PORT=2408` is a fixed, easily-enumerable target (Cloudflare's known WARP range). That combination is exactly what IP/ASN-based and DPI-based blocking is good at catching.

### 12.2 Important correction: Gluetun's `SHADOWSOCKS=on` is the wrong direction
Gluetun's built-in Shadowsocks option runs a Shadowsocks **server** inside the already-connected VPN tunnel, so other LAN devices can reach out through Gluetun's *existing* connection via the SS protocol. It is not a way to make Gluetun itself connect **outbound** through a Shadowsocks server — Gluetun only speaks OpenVPN or WireGuard as its actual transport. There is no `VPN_TYPE=shadowsocks`. Confirmed against Gluetun's own maintainer/community discussion: people have asked for a "Shadowsocks-client" mode specifically to chain through Gluetun, and the standing answer is "run a separate Shadowsocks client container."

### 12.3 Diagnose before building anything
The right fix depends entirely on what's actually being blocked:
- Point Gluetun at a **different provider/IP/ASN** (any other Gluetun-supported WireGuard/OpenVPN provider, or a self-hosted WireGuard server) and test. If that gets through, the block is Cloudflare/WARP-specific, not a general WireGuard block — **no new component needed**, just swap `VPN_SERVICE_PROVIDER` / the endpoint.
- If WireGuard fails regardless of endpoint, the block is protocol-level (DPI fingerprinting the handshake) — proceed to obfuscation.

### 12.4 Path A: Swap WARP for a different Gluetun-native transport
Simplest fix, only applies if 12.3 shows the block is Cloudflare-specific. Change `VPN_SERVICE_PROVIDER` / `VPN_TYPE` / endpoint in `docker-compose.yml` and in the now-centralized `WARP_ENDPOINT_*` values in `.env`. Nothing else in the stack needs to change.

### 12.5 Path B: Add an obfuscation hop
Needed if WireGuard itself is being fingerprinted/blocked. Two ways to slot it in:

**B1 — Wrap (recommended):** Run a Shadowsocks (or obfs4/v2ray) client as a new sidecar container. Point Gluetun's `WIREGUARD_ENDPOINT_IP` at `127.0.0.1:<local-port>` instead of Cloudflare directly; the sidecar relays that traffic to a Shadowsocks server you run yourself abroad. Keeps Gluetun's kill-switch, healthchecks, and the entire rest of the stack (Tailscale, AdGuard, ipset, `routing-fix.sh`) untouched, since none of them know the transport changed underneath `warp`.

**B2 — Replace:** Swap the `warp` service entirely for a Shadowsocks-client + `tun2socks` container that owns the network namespace instead of Gluetun. More invasive — loses Gluetun's built-in kill-switch/healthcheck, which would need to be rebuilt by hand (see Section 12.9 for the pluggable architecture to support this natively).

**Recommendation: B1.** Smaller surface area, preserves the self-healing architecture already built and documented.

### 12.6 Fingerprinting caveat
Plain Shadowsocks can still be caught by active-probing DPI in more aggressive censorship environments. If plain SS gets blocked too, the next step up is an obfuscation plugin (`v2ray-plugin`, `Cloak`) or a newer protocol designed against active probing (VLESS+Reality, Hysteria2). Test plain SS first — don't over-build before confirming it's needed.

### 12.7 AmneziaWG (The High-Speed Alternative)
If you want to maintain the bare-metal speeds of WireGuard while bypassing DPI (e.g. in Egypt or Russia), the best alternative to Shadowsocks/V2Ray is AmneziaWG. AmneziaWG is a fork of WireGuard that pads the handshake packets with randomized "junk" data, entirely destroying the 148-byte DPI signature that firewalls look for.
- **Pros:** Because it runs entirely as UDP without TCP-over-TCP overhead, it completely avoids "TCP meltdown" latency spikes associated with Shadowsocks/V2Ray wrappers.
- **Cons:** You cannot use Cloudflare WARP. Furthermore, it requires completely ripping Gluetun out of the `nullexit` stack and building a custom Docker container, meaning you lose Gluetun's built-in kill-switches and health-check logic.

### 12.8 Infrastructure Costs & Privacy
To use either Shadowsocks (Path B) or AmneziaWG, you cannot use the free Cloudflare WARP infrastructure, because Cloudflare servers only speak standard WireGuard. The software for both custom protocols is 100% free and open-source, but you must host the remote server infrastructure yourself. 
- **Free Tier (Oracle Cloud):** You can host your remote server on Oracle Cloud's "Always Free" tier for $0. However, this routes your highly sensitive, censorship-evading traffic directly through Oracle—a massive corporate data broker. If privacy is the core objective, handing all your metadata to Oracle defeats the purpose.
- **Paid Tier (Hetzner / Mullvad):** The recommended path is to rent a standard ~$4/month Virtual Private Server (VPS) in a free country (e.g., Hetzner in Germany, subject to strict EU GDPR privacy laws) and self-host the server. Alternatively, Mullvad VPN (€5/month) provides native v2ray/Shadowsocks bridges built into their network, allowing you to bypass censorship with a strict zero-logs policy. It is highly recommended to pay with untrackable payment methods to maintain complete anonymity, which these providers typically support without requiring local residency.

### 12.9 The Future: Egress Compartmentalization (Pluggable Architecture)
To natively support invasive replacement paths like **Path B2** or **AmneziaWG** (Section 12.7) without breaking the core `nullexit` routing and monitoring logic, the architecture must be refactored into a modular, "pluggable" design.

1. **The Egress Plugin System:** Currently, WARP-specific logic (like `cdn-cgi/trace` health checks and hardcoded interface names) is scattered across `toggle.sh` and `scripts/routing-fix.sh`. This should be abstracted into a `scripts/plugins/` directory, where each egress method (`warp.sh`, `v2ray.sh`) implements standardized functions: `get_egress_interface()`, `check_health()`, and `get_bypass_ips()`.
2. **Dynamic Docker Compose:** Based on an `EGRESS_TYPE` variable in `.env`, dynamic compose file generation would spin up only the required egress containers (e.g., skipping the `warp` container when `EGRESS_TYPE=v2ray` is set).
3. **Agnostic Routing & Watchers:** `routing-fix.sh` would dynamically read the `EGRESS_INTERFACE` from the active plugin to apply `iptables` rules, and the background watchers in `toggle.sh` would become an agnostic `Egress Watcher` that invokes `check_health()` periodically.

This compartmentalization transforms `nullexit` into a universal, censorship-resistant gateway where the entire egress layer can be swapped by changing a single `.env` variable and running `./toggle.sh --restart`.

---

## 13. Roaming & Recovery Design: How nullexit Mimics Commercial VPNs

The `nullexit` roaming/network recovery subsystem replicates the exact engineering mechanics used by commercial, premium VPN clients (like Mullvad or NordVPN) to transition across Wi-Fi networks safely and seamlessly. This is the design overview; the specific bugs encountered and fixed along the way live in the Incident Log (§15.5 Roaming/Sleep-Wake, §15.7 Tailscale P2P/SNAT).

### The 4-Step Transition Cycle
When your Mac disconnects from one Wi-Fi and associates with another, `nullexit` coordinates the following events:

1. **Firewall Lock (Kill-Switch)**: The macOS Packet Filter (PF) anchor `com.apple/nullexit` remains locked on the physical interface (`en0`), blocking all direct outbound IPv4 and IPv6 traffic. This guarantees that your real ISP IP or unencrypted DNS requests **never leak** onto the new network while the connection is rebuilding.
2. **System Event Interception**: A launchd LaunchAgent (`watcher.sh`) listens to the macOS System Configuration framework for the `State:/Network/Global/IPv4` key changes, spawning `recover.sh --post-wake` in under 500ms when a change is detected.
3. **Bypass Routing**: The script dynamically resolves the new physical network's IP gateway (e.g. `192.168.137.1`), cleans up stale bypass routes from the previous network, and adds static bypass routes pointing to Cloudflare's WARP endpoints and the Tailscale control plane directly via the new gateway. This allows the VPN client to negotiate its handshake outside of the tunnel.
4. **Hole-Punching / NAT Re-negotiation**: The script runs a target check on the `warp` container's tunnel. If the WireGuard connection is wedged by the network switch, it force-recreates the container to establish a fresh NAT binding to Cloudflare, restoring connection in ~15 seconds.

---

## 14. Deployment, Packaging & Known Limitations

### 14.1 Packaging nullexit as a macOS Application (.dmg)

nullexit can be packaged into a native `.app` bundle, but this introduces nested virtualization requirements.

nullexit uses **Colima** (Apple Virtualization Framework `vz`) to run a Linux VM hosting Docker. Installing the `.app` inside a virtualized macOS environment (Parallels, cloud Mac) means running a Linux VM inside a macOS VM — requiring hardware-level **nested virtualization**.

#### Hardware Support
- **Supported:** Apple Silicon M3/M4 (macOS Sequoia 15+), Intel Macs with VMX passthrough.
- **Unsupported:** M1, M2, A18 Pro. Colima crashes silently; the terminal (`setup.sh`) surfaces crash logs.

#### Build Steps
```bash
# 1. Verify nested virtualization support
sysctl -a | grep hv_nested_virt_supported  # expect: 1

# 2. Compile the AppleScript launcher
osacompile -o "Nullexit.app" "Toggle Gateway.applescript"

# 3. Embed scripts into app resources
mkdir -p "Nullexit.app/Contents/Resources/scripts"
cp toggle.sh setup.sh recover.sh docker-compose.yml "Nullexit.app/Contents/Resources/"

# 4. Package into DMG
hdiutil create -volname "Nullexit Installer" -srcfolder "./Nullexit.app" -ov -format UDZO Nullexit.dmg

# 5. Bypass Gatekeeper (unsigned app)
xattr -cr /Applications/Nullexit.app
```

Without a paid Apple Developer certificate ($99/yr), users see an "App is damaged" Gatekeeper warning and need to run step 5.

### 14.2 Moonlight/Sunshine + Tailscale Race Condition

When streaming from a remote Windows host running Sunshine over a Tailscale mesh (e.g., while the client is on a cellular hotspot), a race condition can occur on boot:

1. Both Tailscale and Sunshine are set to start automatically on boot.
2. Tailscale takes a few seconds to fully initialize its `100.x.x.x` virtual adapter and establish a connection.
3. **Sunshine starts too fast.** It launches before Tailscale is fully ready. Since Sunshine only binds to network interfaces that are active at the exact moment of startup, it misses the Tailscale adapter entirely.
4. Moonlight clients (even when configured with the correct Tailscale IP) will fail to connect because Sunshine isn't listening on that interface.

**The "Magic Toggle" Symptom:** 
If the user manually enables or disables Wi-Fi on the host PC, it triggers a global Windows network change event. Sunshine listens for these events, re-enumerates all network adapters, and says, "Oh, there's a Tailscale adapter here!" and finally binds to it. Suddenly, Moonlight can connect.

**The Permanent Fix:**
On the Windows host, open `services.msc`, locate the **Sunshine Service**, and change its Startup type from **Automatic** to **Automatic (Delayed Start)**. This forces Windows to wait a minute or two after booting before launching Sunshine, ensuring Tailscale's virtual adapter is fully initialized first.

### 14.3 Chrome Remote Desktop Performance (UDP NAT)

#### Observation (July 11, 2026)
When the user connects to their host Mac using Chrome Remote Desktop (CRD) while `nullexit` is active, the connection suffers from massive latency, lag, and degraded video quality. AdGuard Home's `blocked.log` shows zero blocked DNS requests for Google, WebRTC, or `chromoting` endpoints, indicating this is not a DNS sinkhole issue. *(See also §15.11 for the separate CRD-on-remote-device connection-failure quirk.)*

#### Root Cause
This is a fundamental limitation of tunneling all host traffic through a strict commercial NAT (Cloudflare WARP).
1. Chrome Remote Desktop attempts to use **STUN (UDP hole-punching)** to establish a lightning-fast, direct peer-to-peer WebRTC connection between the client device and the host Mac.
2. Because all non-Tailscale traffic is forcefully routed through the `warp` container, the STUN packets exit the network from a Cloudflare IP.
3. Cloudflare's enterprise NAT infrastructure strictly drops unsolicited inbound UDP packets. The UDP hole-punch fails.
4. Because a direct P2P connection cannot be established, CRD falls back to **Relay Mode** (TURN), bouncing all video data back and forth through Google's cloud servers instead of sending it directly over the local or mesh network. This relaying introduces massive latency.

#### Workaround / Fix
This lag is the accepted "tax" for maintaining absolute cryptographic anonymity; the only way to restore CRD speed would be to leak its UDP traffic outside the tunnel (violating zero-trust).
To achieve low-latency remote access, users should bypass CRD entirely and use macOS's built-in **Screen Sharing (VNC)** directly over the Tailscale IP. Tailscale's sophisticated custom DERP/WireGuard architecture successfully UDP hole-punches through strict NATs, providing a direct, encrypted, high-speed connection without relying on external cloud relays.

### 14.4 Dynamic IP Fetch vs. MagicDNS

#### Observation
The `nullexit` gateway uses a dynamically fetched IP address (cached in `.gateway_ip`) to configure host routing and the `pf` kill-switch, rather than utilizing Tailscale's user-friendly MagicDNS hostname (e.g., `nullexit-gateway`).

#### Why MagicDNS is Not Used
1. **The "Chicken and Egg" Bootstrapping Problem:** 
   macOS's Packet Filter (`pf`) and low-level routing commands (`route add`) operate strictly at Layer 3 and require raw IP addresses. If `toggle.sh` or `recover.sh` attempted to use `nullexit-gateway`, the host Mac would need to perform a DNS lookup to resolve it. However, the very first step of the gateway's initialization is to completely hijack the host's DNS and point it *at the gateway itself*. The Mac cannot resolve the gateway's MagicDNS name if it needs the gateway's IP to know where to send the DNS query!
2. **Dynamic Self-Healing (Avoiding Stale Cache):**
   To solve the bootstrapping problem without causing bugs if the node is deleted and re-authenticated on the Tailscale Admin Console, `toggle.sh` explicitly runs `docker compose exec ... tailscale ip -4` during boot to fetch the absolute freshest IP dynamically. It saves this to `.gateway_ip` so that fast-roaming scripts like `recover.sh` can instantly retrieve the routing target without incurring the latency of querying Docker.

### 14.5 Battery & Power Measurement Quirks

When trying to optimize this framework (or any daemon) for battery life, developers often look for a way to programmatically measure the exact Wattage consumed by a specific process (e.g., "How many Watts is `toggle.sh` using?"). 

**This is a hardware impossibility on macOS and Linux.**

#### Why Activity Monitor is Lying to You
Your machine's logic board only has physical power sensors for the *entire* CPU package, the GPU, and the RAM. It knows the CPU is pulling 5W total, but it has no physical hardware capability to know whether Docker is using 3W and Chrome is using 2W. 

The "Energy Impact" score you see in macOS Activity Monitor is a **synthetic, heuristic score** calculated by `powerd`. It penalizes apps for waking up the CPU (idle wakes), doing disk I/O, or keeping the screen awake. It is a relative score, not actual Wattage.

#### The Proper A/B Testing Methodology
If you want to truly know how many Watt-hours or mAh your background daemons (`routing-fix.sh`, the DNS/WARP watchers, etc.) are costing you, you must perform a hardware-level A/B drain test:

1. Unplug the laptop, run the gateway, and note your exact battery mAh using:
   ```bash
   ioreg -l | grep "AppleRawCurrentCapacity"
   ```
2. Leave the laptop idle for exactly 1 hour.
3. Run the command again to see exactly how many mAh were drained.
4. Turn the gateway off and repeat the test for another hour.

The delta in mAh drained between the two tests is the true, exact cost of running the software. When optimizing polling loops (e.g., changing `sleep 5` to `sleep 30`), this is the only reliable way to measure the actual battery life returned to the user.

### 14.6 Host Lockdown Mode (Why It's Impossible on macOS)

A common privacy feature request is a "Host Lockdown Mode" (Mode 3): A mode where the Docker exit node remains perfectly functional for remote devices, but the host machine itself is completely blocked from accessing the internet (to prevent even encrypted host traffic from leaking metadata).

**Why this is impossible on macOS:**
On Linux (e.g., a Raspberry Pi), Docker runs natively. The host's traffic traverses the `OUTPUT` iptables chain, while Docker traffic traverses the `FORWARD` chain. We could easily drop all `OUTPUT` traffic to kill the host's internet, and Docker would continue routing traffic perfectly.

However, Docker on macOS runs inside a Linux Virtual Machine (via `qemu` or Apple `Virtualization.framework`). This VM runs as a standard macOS user-space application. If you configure the macOS firewall (`pf`) to drop all host outbound traffic, it will indiscriminately drop the VM application's traffic as well, instantly killing the Cloudflare WARP tunnel and the exit node. 

Writing complex macOS `pf` rules to "allow the VM app, allow Cloudflare WARP IPs, allow Tailscale DERP IPs, but block everything else" is highly fragile and heavily discouraged. Since the current `toggle.sh` default mode already fully encrypts the host's traffic via the WARP tunnel, the host is already protected from ISP leaks.

---

# Part III — Incident Log & Resolved Issues

This is the single, deduplicated log of every incident, bug, and resolved issue. Entries are organized into subsystem groups (§15.1–§15.12). Each entry follows a **Symptom / Root Cause / Fix** shape where applicable; packet-level analyses are preserved as clearly-labeled **Deep dive** blocks. The terse dated changelog lives in §17; this section holds the full post-mortems.

## 15. Incident Log

### 15.1 Exit-Node Return Path & SOCKS5 Failover

#### 15.1.1 Exit Node Return Path (`rx 0`) & The SOCKS5 Failover — RESOLVED
**Symptom:** Gateway showed `tx 936 rx 0` — transmitted but never received return traffic. For days, Tailscale's exit node refused to return traffic back to the client, leading to the assumption that Tailscale's userspace forwarding was bypassing `iptables` and ignoring the WARP `tun0` interface. In a desperate attempt to fix this, a **SOCKS5 proxy** (`scripts/socks5-proxy.py`) was introduced as a replacement.

**Root Cause:** Tailscale's userspace forwarding was *not* the problem. `docker-compose.yml` included `FIREWALL_OUTBOUND_SUBNETS=100.64.0.0/10`. Gluetun created a strict routing rule (`ip rule add to 100.64.0.0/10 lookup 199`, priority 99) that forced all Tailscale CGNAT traffic to bypass the VPN via the unencrypted Docker bridge (`eth0`). Return packets were sent to the macOS host instead of back through `tailscale0`, blackholing all return packets back to the client.

**Fix:** Removed `FIREWALL_OUTBOUND_SUBNETS` entirely, immediately restoring the Tailscale exit node. `scripts/routing-fix.sh` now injects `lookup 52`, and return packets correctly flow back into `tailscale0`. Instead of removing the SOCKS5 proxy, we repurposed it into a **bulletproof failover** for when restrictive Wi-Fi networks block Tailscale UDP ports.

Architecture after the fix:
```
PRIMARY (Exit Node):
DNS/TCP/UDP: Apps → Tailscale Exit Node → gateway container → tun0 → WARP → internet

FAILOVER (SOCKS5 - if Tailscale is blocked by local Wi-Fi):
DNS: Browser → 127.0.0.1:53 → Python proxy → TCP:5354 → AdGuard → WARP
TCP: Apps → SOCKS5:1080 → gateway container → tun0 → WARP → internet
Mesh: SSH/ping 100.x.x.x → utun5 → WireGuard → peers (independent of proxy)
```

**Deep dive: Exit Node Return Path Analysis (June 26, 2026).**
This preserves the detailed packet-level analysis that led to identifying and fixing the `rx 0` bug.

*The exit node was probably never going to work in this container topology.* Here's the packet path traced by reading `ip rule show` and the routing tables live:

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

*Why table 199 exists and why it's wrong for exit node traffic.* Table 199 + the CGNAT rule (pref 99) was designed so that the **container itself** can reach other Tailscale peers (e.g., for mesh management, DERP relay). For that use case, routing CGNAT traffic via the Docker bridge to the host (which has its own tailscaled) makes sense. But for **forwarded exit node traffic**, the return packet needs to go back through tailscale0 inside the container — not out to the host. The CGNAT rule intercepts the return packet before it can be routed back to tailscale0 through the main table or Tailscale's own routing (table 52, which is at pref 5270).

*The SOCKS5 path works because it dodges all of this.* SOCKS5 proxy creates connections **from the container's own IP** (`172.18.0.2`). So:
- ip rule 100 (`from 172.18.0.2 lookup 200`) matches ✅
- Table 200 has `default dev tun0` ✅
- Return traffic comes back to `172.18.0.2` on tun0, conntrack de-NATs, proxy sends response to client ✅

No FORWARD chain involved. No CGNAT rule involved. No table 199. It just works.

*Summary of findings:*

| Finding | Status | Evidence |
|---------|--------|----------|
| Table 199 CGNAT route hijacks exit node return traffic | **Fixed** | Changed `lookup 199` to `lookup 52` in `scripts/routing-fix.sh`. Return packets now route via tailscale0. |
| FORWARD RELATED,ESTABLISHED missing | **Fixed** | Installed `iptables` via apk in `docker-compose.yml`. Rule now injects successfully. |
| DOCKER_GW variable parsing error | **Fixed** | Added `head -1` in `scripts/routing-fix.sh`. |
| `FIREWALL_OUTBOUND_SUBNETS` was the root cause | **Fixed** | Removed from `docker-compose.yml`. Gluetun no longer hijacks CGNAT routing. |
| Host tailscaled error state from aggressive `tailscale down` | **Mitigated** | Toggle script now detects and auto-restarts. |

#### 15.1.2 Container Default Route Bypasses WARP
**Problem:** Inside the WARP container's network namespace, the main routing table's default route was via `eth0` (Docker bridge), not `tun0` (WARP tunnel). While gluetun uses policy routing (rule 101 → table 51820 → `tun0`) for most traffic, traffic originating from the container's own IP (`172.18.0.2`) hits rule 100 (`from 172.18.0.2 lookup 200`), whose default was also via `eth0`. This caused the SOCKS5 proxy's outbound connections to bypass WARP.

**Fix:** Updated the `routing-fix` container to:
1. Change the main table's default route to `default dev tun0`
2. Change table 200's default route to `default dev tun0`
3. Add a specific route for the WARP WireGuard endpoint (`162.159.192.1`) through `eth0` via the Docker gateway in table 200, preventing a tunnel loop
4. Re-assert all routes every 30 seconds (gluetun may reset them on health checks)
5. Dynamically detect the Docker subnet from `ip route show dev eth0` instead of hardcoding `172.18.0.0/16`

#### 15.1.3 Hardcoded Docker Subnet in Routing Fix
**Problem:** The `routing-fix` container hardcoded `172.18.0.0/16` and `172.18.0.1` for the Docker bridge subnet and gateway. If Docker's bridge network changed (after `docker network prune`, Colima restart, or on a different machine), these routes would be wrong.

**Fix:** Detection is now dynamic using `ip route show`:
- `DOCKER_NET=$(ip route show dev eth0 | grep -v default | head -1 | awk '{print $1}')`
- `DOCKER_GW=$(ip route show default | awk '{print $3}')`

This extracts the actual subnet and gateway directly from the routing table, working with any subnet size (`/16`, `/24`, `/20`, etc.).

### 15.2 Routing Loops & Subnet Collisions

#### 15.2.1 The Infinite Recursive Routing Loop (Hotspot Paradox)
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

#### 15.2.2 Infinite Egress Routing Loops & Subnet Takeover Paradoxes
**Problem:** Two distinct network loops can break host egress connectivity entirely when the exit node is active:

1. **The Recursive Host-VM Tunnel Loop:**
   - **Mechanism:** The host Mac's default route points to the Tailscale exit node (`utun*`). The exit node container sends its encrypted tunnel packets (destined for the WARP endpoint `162.159.192.1`) back to the host via the VM NAT. Without a static route exception on the host Mac, the host Mac routes those packets right back into the exit node (`utun*`), creating an infinite loop that blackouts all host network egress.
   - **ARP-Scoping Pitfall:** Simply binding the bypass route to the interface (`route add -host 162.159.192.1 -interface en0`) fails when the default route is deleted or redirected to `utun*`. Since `162.159.192.1` is not local to the physical link, macOS fails to resolve it via ARP, dropping all tunnel packets.
   - **Fix:** Dynamically resolve the active physical gateway IP (e.g. `172.17.0.1`) on startup, and add the static host routes for the WARP endpoints via the gateway IP directly (`route add -host 162.159.192.1 <gateway_ip>`). Additionally, because standalone `tailscaled` on macOS does not automatically modify the system default route via the CLI, we manually redirect the default gateway to `utun*` using `setup_exit_node_routing`.

2. **The Docker Compose Subnet Takeover Collision:**
   - **Mechanism:** To avoid collisions with the host's campus network, Colima's default bridge (`docker.bip`) is moved (e.g. to `10.200.0.1/24`). However, because `172.17.0.0/16` is now free inside the VM, Docker Compose's IPAM dynamically takes it over for the project's custom network (`nullexit_default`). Because the containers receive IPs on `172.17.0.0/16`, the host Mac cannot send local peer discovery packets (e.g., Tailscale `magicsock` packets on `172.17.0.2:41641`) directly. The host routing table sends them out `en0` to the physical Wi-Fi, returning `host is down` or `no route to host`.
   - **Fix:** Explicitly configure a custom default network subnet `10.200.1.0/24` in `docker-compose.yml` to prevent Docker Compose from ever reclaiming the conflicting `172.17/172.18` ranges.

> See also §15.2.1 (The Hotspot Paradox) for the related infinite loop that occurs when the physical upstream router is also a Tailscale exit-node client.

#### 15.2.3 Docker Default Bridge vs Host Wi-Fi Subnet Collision (The 172.17.0.0/16 Subnet Overlap)
**Context:** When attempting to ping a local Windows client (`172.17.22.187`) or the default gateway (`172.17.0.1`) directly over Wi-Fi, the Mac host returns `No route to host` (displaying a `REJECT` / `!` flag in the routing table). Tailscale on the client also drops offline shortly after starting when using the exit node, failing to establish direct P2P connections and falling back to slow DERP relays.

**Root Cause & Subnet Overlap Mechanism:** 
1. **Docker Default Subnet:** By default, the Docker daemon initializes its default bridge network (`docker0`) on the **`172.17.0.0/16`** IP range.
2. **Subnet Conflict:** The host's physical Wi-Fi network happens to be assigned the exact same **`172.17.0.0/16`** range by the local network router.
3. **Routing Clash:** Colima launches a Linux VM on the Mac host to run the Docker engine. Because Docker inside that VM creates `docker0` and claims the `172.17.0.0/16` subnet, any packet sent to `172.17.x.x` from within the containers (such as Tailscale local discovery) is captured by the VM's internal virtual bridge interface (which is down/empty) and is blackholed. On the Mac host, macOS dynamically marks routes as `REJECT` (`!`) when local ARP resolution fails, causing local pings to immediately abort with `No route to host`.
4. **Tailscale Relay Saturation**: Because local peer-to-peer discovery is blackholed, Tailscale falls back to public DERP relay servers (e.g. `relay "tor"` in Toronto). When exit-node routing is enabled, all client web traffic is routed through the relay. Public relays impose strict rate limits and throttle high-volume traffic, resulting in packet drops. This saturation drops Tailscale's control packets, causing the connection to time out and showing the client as offline.

**Fix:**
The canonical script for this is `scripts/fix-docker-bridge-collision.sh`. **One command applies the entire fix:**

```bash
bash scripts/fix-docker-bridge-collision.sh        # apply
bash scripts/fix-docker-bridge-collision.sh --dry  # preview changes without applying
```

It auto-detects the host's actual Wi-Fi subnet (no more guessing whether the campus DHCP handed out `172.x`, `10.x`, or `192.168.x`), picks a non-conflicting `docker.bip` from a small candidate set (defaulting to `172.26.0.1/24` if no overlap is matched), backs up `~/.colima/default/colima.yaml` with an ISO-8601 timestamp, edits the file **in place** (idempotent — replaces an existing `docker.bip` if present, appends under an existing `docker:` block, or creates a fresh block), restarts Colima, rebinds Wi-Fi DHCP, verifies the new default route is no longer Docker's bridge, and re-runs both `./toggle.sh` and `scripts/diagnose-host-leak.sh` to print the post-fix verdict.

For reference, the underlying manual fix is: edit the Colima configuration file (`~/.colima/default/colima.yaml`) on your Mac to define:
```yaml
docker:
  bip: 172.26.0.1/24   # any /24 that does NOT overlap your Wi-Fi subnet
```
Then, restart Colima to apply the new subnet inside the VM:
```bash
colima restart
```
This forces Docker to use `172.26.x.x` for its default bridge, freeing the physical `172.17.x.x` range and letting pings and direct Tailscale peer-to-peer connections flow normally.

#### 15.2.4 July 4, 2026: The "Network Unreachable" Host Leak & Post-Wake Container Destructions
**Symptom:**
1. Running `docker compose config` with dummy keys corrupted the user's `.env` file by appending invalid WireGuard keys. This caused the `warp` container to become unhealthy on boot, which triggered a full teardown of the gateway by `toggle.sh`.
2. After fixing `.env`, `toggle.sh` successfully booted the gateway, but the host's internet started bypassing the tunnel entirely (a massive host leak). The Cloudflare trace returned `warp=off` and exposed the host's physical ISP IP.
3. Running `recover.sh --post-wake` would violently force-recreate all gateway containers and drop the host's internet connection.

**Root Cause:**
- **Bug 1 (The Host Leak):** In `toggle.sh`, the logic to find the Tailscale `utun` interface used `ifconfig | grep -B4 "inet 100."`. Due to the 4 lines of before-context, this regex was accidentally capturing the interface *above* the actual Tailscale interface (e.g. grabbing `utun4` instead of `utun5`). Because `utun4` had no IP address, the subsequent `sudo route add -net 0.0.0.0/1 -interface utun4` silently failed with "Network is unreachable", leaving the host's default route exposed.
- **Bug 2 (The Post-Wake Destructions):** The health check in `recover.sh --post-wake` relied on `docker compose exec -T warp curl -sf https://www.cloudflare.com/cdn-cgi/trace`. However, the newer `qmcgaw/gluetun` Alpine-based Docker image no longer ships with `curl` pre-installed. The health check failed with `executable file not found in $PATH`, tricking `recover.sh` into thinking the tunnel was completely dead and needed to be forcefully recreated via `docker compose up -d --force-recreate`.
- **Bug 3 (Restart Flags):** Previous refactors incorrectly permitted `toggle.sh restart` instead of strictly enforcing `toggle.sh --restart`.

**Resolution:**
- Cleaned the `.env` file of duplicate dummy entries.
- Replaced the brittle `grep -B4` interface parsing in `toggle.sh` with a strict AWK parser: `awk '/^[a-z0-9]+:/{iface=$1} /inet 100\./{print iface; exit}' | tr -d ':'`. This mathematically isolates the exact interface possessing the Tailscale `100.x.x.x` IP address, preventing the `0.0.0.0/1` route from silently failing.
- Changed the health check in `recover.sh` to use `wget -qO- --timeout=3` which is natively installed in the Gluetun image. This stopped the unnecessary destructive recreations of the containers during post-wake events.
- Reverted the `restart` alias in `toggle.sh` to strictly require `--restart`.

#### 15.2.5 July 4-5, 2026: Tailscale Data-Plane Loop (The DERP Relay Deadlock)
**Symptom:**
After bypassing the Tailscale control plane (`192.200.0.0/16`) to fix the "offline" mesh status, the Mac appeared online. However, external peer devices (like the user's phone on cellular) could not successfully ping or SSH into the Mac. `tailscale netcheck` reported `Nearest DERP: unknown (no response to latency probes)`.

**Root Cause:**
While bypassing the control plane kept the daemon connected to the coordination servers, Tailscale's actual peer-to-peer data plane relies on STUN (for NAT traversal) and DERP relays. These relays span ~80 dynamically allocated IP addresses across multiple cloud providers. Because we were forcing `0.0.0.0/1` through the `utun*` exit node, the Mac's own outbound connection attempts to DERP relays were being routed back into the tunnel. To prevent an infinite loop, Tailscale's daemon dropped its own packets when it saw them returning on the TUN interface. This effectively left the daemon deaf and blind to peer connections.

**Resolution:**
- Modified `add_warp_bypass_routes` in `scripts/common.sh` to execute a live API fetch (`curl -s https://login.tailscale.com/derpmap/default`) during startup.
- The script parses out all active DERP relay IPv4 addresses (~80 IPs) and adds a physical host bypass route for every single one of them.
- These IPs are written to a temporary file (`/tmp/nullexit-derp-ips.txt`) so they can be cleanly un-routed by `remove_warp_bypass_routes` when the gateway shuts down. Peer connectivity (ping, SSH, SFTP) was fully restored.

#### 15.2.6 July 5, 2026: Hardcoded WARP Endpoints in docker-compose
**Symptom:**
The bash scripts allowed overriding the default Cloudflare WARP IP endpoints via `.env` variables (`WARP_ENDPOINT_1` and `WARP_ENDPOINT_2`) to establish bypass routes. However, `docker-compose.yml` statically hardcoded `162.159.192.1` for the `warp` container's `WIREGUARD_ENDPOINT_IP`.

**Root Cause & Risk:**
If a user set a custom endpoint in `.env`, the script would successfully bypass the custom IP on the host level. However, Gluetun would still attempt to connect to the hardcoded `162.159.192.1`. Since `162.159.192.1` was no longer explicitly bypassed, its packets would be sucked into the `utun*` exit node, causing an infinite WireGuard routing loop that instantly breaks the gateway.

**Resolution:**
Modified `docker-compose.yml` to dynamically read the environment variable via `${WARP_ENDPOINT_1:-162.159.192.1}`, ensuring both the host routing scripts and the container use the exact same endpoint.

#### 15.2.7 Incident Post-Mortem: WARP Watcher Race vs Post-Wake (July 10, 2026)
**Symptom:** After switching Wi-Fi networks, the host IP appeared as the raw ISP IP (`132.x.x.x`) instead of a Cloudflare/WARP IP. The gateway appeared to complete post-wake recovery successfully in the logs, but nuclear shutdown fired immediately after and killed everything.

**Root Cause:** A fatal race condition between two concurrent processes:

1. **Wi-Fi roam** → `watcher.sh` fires `recover.sh --post-wake`
2. **Post-wake** finds the `warp` container missing/dead → calls `docker compose up -d --force-recreate` (~35 seconds)
3. **In parallel**, the WARP Watcher (running as a child of `toggle.sh`) polls the warp container every 5s during failures
4. While the container is being recreated it returns `warp=off` for those 35 seconds → 7 consecutive failures → **WARP SHUTDOWN fires**, calling nuclear `recover.sh`
5. Nuclear `recover.sh` tears down Tailscale, resets DNS to 1.1.1.1, stops all containers → **gateway dead, IP exposed**
6. The post-wake `docker compose up` finishes at ~35s mark, container healthy — but the gateway is already gone

The evidence in `output.log`:
```
[2026-07-10T06:07:27Z] NET: ... → bash recover.sh --post-wake
[2026-07-10T06:07:47Z] WARP DOWN — cdn-cgi/trace reports warp=off   ← watcher starts counting
...
add net 0.0.0.0: gateway utun5   ← post-wake successfully re-routes at 02:08:22
...
[2026-07-10T06:09:04Z] WARP SHUTDOWN — 6 consecutive failures        ← watcher fires nuclear
```

**Fix (July 10, 2026):** Added a **WARP Watcher inhibit marker** (`/tmp/nullexit-warp-inhibit.marker`):
- `recover.sh --post-wake` writes the marker at startup **before** any container operations
- The WARP Watcher loop checks for the marker at the top of every iteration; if present it resets `consec_off=0` and sleeps 5s (skips the poll entirely)
- `recover.sh` removes the marker at the very end (on both success and failure via `trap cleanup_inhibit EXIT`)
- This guarantees the watcher never counts failures during the intentional container-down window of a post-wake force-recreate

The marker file path is hardcoded to `/tmp/nullexit-warp-inhibit.marker` in both `toggle.sh` and `recover.sh`.

#### 15.2.8 Incident Post-Mortem: Concurrency Collision between Nuclear Teardown and Post-Wake (July 10, 2026)
**Symptom:** When the background WARP Watcher triggers a nuclear shutdown (due to a real or simulated tunnel failure), the gateway is completely torn down. However, the network configuration changes made during the teardown trigger a `State:/Network/Global/IPv4` network change event. The LaunchAgent-based network watcher (`watcher.sh`) intercepts this event and concurrently spawns `recover.sh --post-wake` to heal/restore the gateway. This causes `docker compose down` (from nuclear teardown) and `docker compose up` (from post-wake) to run in parallel, resulting in container errors like `dependency failed to start: container warp exited (0)` and the gateway becoming wedged.

**Root Cause:** A lack of coordination/locking between the lifecycle control scripts. While `toggle.sh` used `/tmp/nullexit-toggle.lock` to prevent concurrent `toggle.sh` runs, `recover.sh` (both nuclear and `--post-wake` modes) did not utilize or check any lock files. 

**Fix (July 10, 2026):** Implemented a shared lifecycle lock file (`/tmp/nullexit-toggle.lock`) across both scripts:
- **`recover.sh` (all modes)**: Checks `/tmp/nullexit-toggle.lock` at startup. If the lock is held by another running lifecycle script (`toggle.sh` or `recover.sh`):
  - In `--post-wake` mode, it logs a skip message to `output.log` and exits cleanly (`exit 0`). This safely prevents the auto-recovery agent from recreating containers during a teardown.
  - In nuclear recovery mode, it exits with an error.
- **`recover.sh` Lock Cleanup**: Cleans up the lock file upon completion using `trap cleanup_recover EXIT` (which checks if the lock file belongs to the current PID).
- **`toggle.sh` update**: The lock check in `toggle.sh` was updated to look for both `toggle.sh` and `recover.sh` in the running processes to enforce proper exclusion.

#### 15.2.9 Incident Post-Mortem: Infinite Auto-Recovery Loop after WARP Watcher Nuclear Shutdown (July 10, 2026)
**Symptom:** When the background WARP Watcher triggered a nuclear shutdown (due to a tunnel outage), it successfully executed `recover.sh` (nuclear). However, immediately after the teardown completed, the system started spawning `recover.sh --post-wake` and rebuilding the containers again. This created an infinite loop of tearing down and auto-restarting the gateway, keeping the host's internet route permanently wedged.

**Root Cause:** An active-state marker file leak. The LaunchAgent-based network watcher (`watcher.sh`) only fires `recover.sh --post-wake` when `/tmp/nullexit-gateway-active.marker` is present on disk. While `toggle.sh` (STOP path) correctly deleted this marker, the nuclear `recover.sh` script did not. When the WARP Watcher ran `recover.sh` (nuclear), the containers were stopped but the active-state marker was left on disk. The network changes from the teardown then triggered `watcher.sh`, which saw the marker, believed the gateway was still supposed to be active, and triggered `--post-wake` to start it back up.

**Fix (July 10, 2026):** Modified the start of `recover.sh` to explicitly delete `/tmp/nullexit-gateway-active.marker` if `POST_WAKE` is `false` (nuclear mode). This ensures that any subsequent network configuration changes made during the teardown are correctly ignored by `watcher.sh` because the marker file is gone.

### 15.3 MTU, Fragmentation & Throughput

#### 15.3.1 Network Bufferbloat & MTU Optimizations (Double-VPN UDP Crash)
**Symptom:** When running aggressive UDP bandwidth tests (such as macOS `networkQuality`, which uses QUIC/HTTP3), the `nullexit` tunnel completely crashes or exhibits severe lag (6,000ms+ bufferbloat). 

**Root Cause:** The bug is a cascading MTU mismatch. Tailscale generates a UDP packet. Cloudflare WARP (also WireGuard) receives the packet, wraps it in another layer of encryption, pushing the packet size beyond the standard 1500 byte limit. Unlike TCP, UDP packets cannot be resized dynamically via MSS negotiation, resulting in massive IP packet fragmentation. The Apple Virtualization framework (`vz`), which Colima uses for bridged networking, silently drops heavily fragmented UDP packets under high load. This blackholes the entire UDP upload stream, instantly dropping the connection.

**Fix (Partial):** To prevent MTU fragmentation for standard web traffic, **TCP MSS Clamping** is strictly enforced via the macOS `pf` firewall. By adding `scrub out all max-mss 1160` to `scripts/pf.conf`, macOS unilaterally shrinks all outgoing TCP headers to fit comfortably inside the double-encrypted tunnel, bypassing Path MTU Discovery blackholes. `TS_DEBUG_MTU=1200` was also added to `docker-compose.yml` to minimize internal fragmentation.
**Unresolved:** The only way to solve the UDP crash bug natively is to artificially cap the maximum tunnel bandwidth using SQM (`fq_codel`). Because a static bandwidth cap would artificially throttle high-speed networks, `nullexit` leaves the bandwidth uncapped, optimizing perfectly for TCP while accepting UDP fragmentation under extreme edge-case load tests.
*Why not Dynamic SQM (Autorate)?* Implementing an EMA/PID-controlled autorate daemon (like `sqm-autorate`) requires a constant 100ms polling loop to measure the kernel packet queue, which severely degrades laptop battery life by preventing deep C-state CPU idling. Furthermore, macOS's native firewall (`dummynet`) only supports `fq_codel` and does not support the newer Linux `CAKE` algorithm, which is the only algorithm that offers kernel-native, event-driven `autorate-ingress` (zero polling penalty). Therefore, dynamic SQM is computationally hostile to battery-powered macOS hosts.

#### 15.3.2 Double-Tunneling MSS Clamping (Stalling Bug)
**Problem:** Traffic double-wrapped through Tailscale (WireGuard) and WARP (WireGuard) suffered 120 bytes of MTU overhead (60 + 60). The default MSS clamp of 1180 was still slightly too large, causing large packets to fragment or drop, which resulted in mysterious web page stalls on strict-MSS endpoints.

**Fix:** Lowered the TCP MSS clamp in `post-rules.txt` to `1120` to guarantee double-tunneled payloads fit safely within standard internet MTUs.

#### 15.3.3 Wi-Fi Edge Packet Loss via QUIC (UDP) Fragmentation
**Problem:** Applications that heavily utilize HTTP/3 (QUIC) over UDP—such as Facebook, Instagram, and Google services—experience massive stuttering and stalled image loading when the client device is far away from the router (weak Wi-Fi signal). The issue did not occur when close to the router.

**Root Cause:** The `nullexit` gateway uses a double-encrypted tunnel (Tailscale + WARP). To prevent packets from fragmenting when entering these tunnels, a firewall rule in `post-rules.txt` uses `--set-mss 1120` to safely clamp TCP packets. However, because QUIC runs entirely over UDP, it bypasses the TCP MSS handshake completely. QUIC blasts maximum-MTU (1280 byte) UDP packets. The inner `tailscale0` interface (MTU 1200) forces these large UDP packets to fragment into two pieces. When the client is on the edge of Wi-Fi range (where 5-10% packet loss is common), losing *either* UDP fragment destroys the *entire* image frame. This exponential amplification of packet loss stalled QUIC streams.

**Fix & Trade-offs:** Appended an `iptables` rule to `post-rules.txt` that explicitly blocks `UDP --dport 443` (QUIC). When modern web apps detect QUIC is blocked, they instantly fall back to HTTP/2 (TCP 443). Because TCP is routed through the MSS clamp, the packets are resized *before* they leave, entirely eliminating IP fragmentation and restoring high-speed loading over weak Wi-Fi. 
*Consequences:* This adds a minor latency penalty (TCP 3-way handshake) compared to QUIC's zero-RTT connection. It may also force WebRTC video calls (Google Meet/Discord) to fall back to TCP TURN servers, slightly inflating real-time video latency. However, in a constrained double-tunnel mesh, the absolute stability gained from eliminating fragmentation vastly outweighs these trade-offs.

#### 15.3.4 Cellular Networks & PMTUD Blackholes (The 1280 Byte Limit)
**Experiment:** Conducted a live packet sweep from the PC-1 host to Phone-1 connected via a cellular network + Tailscale DERP relay using `ping -D -s <size>`.

**Result:**
- Packets with a payload of `1252` bytes (+ 28 bytes IP/ICMP headers = **1280 bytes total**) succeeded perfectly with ~60ms latency.
- Packets with a payload of `1253` bytes (**1281 bytes total**) and above resulted in a silent timeout.

**Analysis:** The cellular network (or the Tailscale DERP relay) enforces a strict MTU of 1280 bytes. Critically, it acts as a "PMTUD Blackhole" — it silently drops packets larger than 1280 bytes instead of returning an ICMP "Fragmentation Needed" warning. If the exit node tries to send a standard 1500-byte internet packet to the phone over this link, it vanishes, causing web pages to stall permanently.

**Conclusion:** This empirically validates the absolute necessity of the TCP MSS clamping rule in `post-rules.txt`. By artificially clamping the MSS to `1120` (or `1180`), we ensure the TCP payload + headers + double-WireGuard overhead never exceeds the strict 1280-byte ceiling of the cellular mesh link.

#### 15.3.5 Low Gateway Throughput (DERP Relay & MTU Fragmentation) — Fixed
**Problem:** The host Mac's internet throughput through the gateway dropped significantly (e.g., from 34Mbps raw to 2.1Mbps via gateway). This was caused by a combination of two bottlenecks:

**1. Tailscale DERP Relay Bottleneck:**
Because the host Mac and the Docker container operate behind the same public IP, standard hole-punching for Tailscale P2P failed, forcing traffic through Tailscale's NYC DERP relay. Normally, `routing-fix.sh` explicitly drops container Tailscale UDP packets destined for local subnets (when `TAILSCALE_ALLOW_LAN_P2P=false` in `.env` or auto-detected). We nuke these P2P connections on purpose to prevent the severe macOS `gvproxy` SNAT endpoint poisoning issue we faced earlier (see §15.7 SNAT Endpoint Poisoning). However, this strict policy unintentionally blocked direct communication between the container and the Mac host itself via the Docker bridge network.

**Fix:** Tailscale's control plane registers the Mac host using its physical IP (e.g., `172.17.52.223`), not the Docker bridge IP. If this physical IP falls within the dropped local subnets (like `172.16.0.0/12`), the P2P handshake is dropped. To solve this natively, `scripts/common.sh` now features a `write_host_ips()` function that actively grabs all physical IPv4 addresses on the Mac and writes them to `.host_ips`. `routing-fix.sh` dynamically reads this file every 30 seconds and injects priority `RETURN` rules for those exact physical IPs. This guarantees direct container-to-host P2P over the local bridge (bypassing DERP) while continuing to block external LAN devices (like phones) to prevent the §15.7 SNAT poisoning bug.

**2. MTU Double-Encapsulation Fragmentation:**
The host's Tailscale interface (`utun5`) defaulted to an MTU of 1280. The WARP tunnel inside the container also uses an MTU of 1280. When a full 1280-byte Tailscale packet from the host entered the container and was encapsulated by WARP (adding ~60 bytes of overhead), the resulting packet exceeded 1280 bytes, leading to severe fragmentation and performance degradation.

**Fix:** In `toggle.sh`'s `setup_exit_node_routing` function, the host's Tailscale `utun` interface MTU is explicitly lowered to `1200` (configurable via `HOST_MTU` in `.env`). This ensures that host-originated packets can comfortably fit inside the container's WARP tunnel encapsulation without fragmenting.

> **Design Note — Is direct host↔container P2P a Docker bug, or are we "exploiting a VM/host relationship"?**
> Neither. It is expected, well-defined behavior, and the RETURN-rule carve-out is a *defensive de-restriction*, not an exploit. The reasoning:
> - **On native Linux**, the container and host share one kernel; the Docker bridge is a first-class local interface and host↔container is *trivially* direct. Nobody calls that an exploit. Our RETURN rules simply reproduce that same local reachability on macOS.
> - **The RETURN rules add nothing new; they *stop blocking* something legitimate.** `routing-fix.sh` broadly DROPs container→LAN Tailscale UDP to prevent the real §15.7 `gvproxy` SNAT endpoint-poisoning bug caused by *external* LAN peers (e.g. a phone on another AP). Tailscale's control plane registers the Mac host by its *physical* LAN IP (e.g. `172.17.52.223`), which falls inside those DROPped ranges — so the host, the one peer that is literally the same physical machine, became collateral damage. The `.host_ips` RETURN rules are the minimal, precise exception that re-permits exactly that same-machine path and nothing else.
> - **The genuinely VM-specific wart is `gvproxy` SNAT poisoning (§15.7), and we route *around* it, not through a hole in it.** Keeping host↔container traffic on the Docker bridge (direct) avoids letting it get NATed through the userspace `gvproxy` endpoint rewriter that confuses Tailscale's peer-endpoint learning. That is the opposite of exploiting the VM boundary — it is respecting it.
> - **What genuinely *doesn't* work on a VM host is UDP hole-punching to arbitrary *external* peers** (see §15.13). That is a real limitation of userspace VM networking, and it is why remote peers fall back to DERP unless bridged mode is enabled on a trusted LAN. Direct host↔container P2P is the one case that works regardless — because both endpoints live on the same physical machine, no hole-punching is needed at all. It was verified `direct 172.17.52.223` even in plain user-mode networking (no `--network-address`).
>
> In short: the DROP is the deliberate policy, the RETURN is a surgical exception for same-machine traffic, and the whole thing is standard bridge networking — not a Docker bug and not an exploit.

### 15.4 DNS Interception & Proxy

#### 15.4.1 DNS Proxy: TCP Wire Format Mismatch (socat / dnsmasq)
**Problem:** When the Tailscale data plane is unavailable (DERP relay only), the script falls back to a local DNS proxy that forwards queries from host UDP:53 to Docker's TCP:5354 (AdGuard). The `socat` and `dnsmasq` approaches both failed.

- **socat** forwards raw bytes — it does not prepend the 2-byte length prefix that DNS-over-TCP requires. AdGuard parses the stream incorrectly and returns garbage.
- **dnsmasq** tries UDP first to reach the upstream (`127.0.0.1#5354`), but Colima's SSH tunnel only forwards TCP. With a single upstream server, dnsmasq doesn't fall back to TCP even with `--timeout=1`.

**Solution:** Replaced both with a **Python DNS proxy** (`scripts/dns-proxy.py`, ~25 lines) that properly handles the DNS-over-TCP wire format: reads a UDP query from the host, prepends the 2-byte length prefix, sends it over TCP to AdGuard, strips the prefix from the response, and sends it back over UDP.

*Architectural Note: Why is the DNS proxy in Python while the SOCKS5 proxy was moved to a compiled Go Docker container?*
The SOCKS5 proxy handles heavy data streaming (e.g., video, downloads). Python introduces massive CPU/battery overhead for raw socket streaming, which is why we rely on the compiled Go implementation built directly into the `tailscaled` daemon via `TS_SOCKS5_SERVER=:1080`. 
Conversely, the DNS proxy only handles intermittent UDP queries (a few bytes per minute) generated solely by the local host machine. The Python overhead for this is effectively 0.001 Watts. We deliberately kept `dns-proxy.py` in Python because it runs natively on the macOS/Linux host—rewriting it in Go would force users to install a Go compiler (`brew install go`) on their host machine for zero noticeable battery gain. (Note: If this architecture is ever adapted to serve as a public DNS resolver for thousands of users or for massive automated web-scraping clusters, `dns-proxy.py` must be rewritten in Go to survive the concurrent packet flood).

#### 15.4.2 Tailscale MagicDNS Bypassing the AdGuard PREROUTING Intercept
**Context:** The `routing-fix.sh` script applies an iptables NAT rule (`PREROUTING -i tailscale0 -p udp --dport 53 -j REDIRECT`) to intercept all incoming DNS queries from connected Tailscale peers and force them into the AdGuard container on port 5335.
**Problem:** When remote clients (like Android or iOS) have "Use Tailscale DNS settings" turned on, they query Tailscale's MagicDNS IP (`100.100.100.100`). This packet enters the exit node, but the `tailscaled` daemon running *inside* the gateway container intercepts the `100.100.100.100` packet internally. `tailscaled` then generates a brand new, local DNS request to the upstream DNS server to resolve the query. Because this new request is generated *locally* by the daemon (not arriving externally via the `tailscale0` interface), it bypasses the `PREROUTING` chain completely. The request glides straight out the WARP tunnel to Cloudflare/Google, entirely bypassing the AdGuard sinkhole.
**Fix:** The only way to fix this blindspot is to force `tailscaled` to use AdGuard as its upstream. In the Tailscale Admin Console, the gateway's Tailscale IPv4 address (e.g., `100.x.x.x`) must be added as the sole Custom Global Nameserver, and "Override local DNS" must be enabled. Additionally, to block Android devices from bypassing this via Private DNS (DNS-over-TLS), outbound Port 853 traffic is explicitly REJECTED in both `routing-fix.sh` and `post-rules.txt`.

#### 15.4.3 Seamless Wi-Fi Roaming & The macOS DNS Wipeout Loophole
**Problem:** The Tailscale, WireGuard, and Colima NAT stacks are natively designed for connectionless roaming and will seamlessly survive when the macOS host switches Wi-Fi networks (e.g., roaming from home Wi-Fi to a cellular hotspot). However, the internet completely breaks upon network transition. This occurs because macOS intentionally wipes out all custom DNS settings (`networksetup -setdnsservers`) and reverts to the new network's default DHCP nameserver whenever the active Wi-Fi BSSID changes. Since the Mac is locked to the exit node, its DNS requests are swallowed by WARP and dumped onto the public internet, which cannot route private DHCP IPs. This results in a total DNS failure.

**Solution:** Implementing a silent background "DNS Watcher" daemon (`nullexit-dns-watcher`) in `toggle.sh`. When the gateway starts, it spawns a background polling loop that checks the active Wi-Fi DNS every 30 seconds. If macOS resets the DNS during a network change, the watcher instantly detects the drift and forcefully re-injects `100.100.21.8` via `networksetup`. When the gateway stops, the watcher process is cleanly killed. This allows true, seamless roaming across physical networks without ever dropping the gateway state.

#### 15.4.4 docker compose exec `\r` Injection
**Fix:** All `docker compose exec` output piped through `tr -d '\r'`.

#### 15.4.5 Stderr Invisibly Swallowed
**Symptom:** Failures were silent due to stderr redirected to `output.log`.

**Fix:** Tailscale wait loop now shows output. Critical commands show errors inline.

### 15.5 Roaming, Sleep/Wake & Auto-Recovery

#### 15.5.1 Gateway Breakage on Lid Close / Wi-Fi Roam — Post-Wake + Post-Roam Auto-Recovery
**Context / Symptom.** Closing the lid (sleep/wake) OR losing + reconnecting Wi-Fi (e.g. in an elevator, café, or roaming between APs) leaves the gateway in a partly-dead state. Symptoms range from a ~30s window of dead DNS to a permanent outage that only full `recover.sh` or `toggle.sh` fixes. The root cause is that nullexit has **no daemon watching macOS sleep/wake or network-state-change events** — the existing DNS Watcher inside `toggle.sh` only runs in-process and is suspended along with the rest of the user shell on lid close, so the gateway cannot self-heal after either event.

**Diagnosis.** Two distinct failure modes share the same root gap.

* **(A) Lid close → sleep → wake.** `caffeinate -i` (used by `toggle.sh`) blocks *idle* sleep but **does not block forced sleep from lid close**. Closing the lid hard-suspends Colima VM + every container + every Tailscale-quit-shells-except-tailscaled. On wake the VM clock needs ~5-30s to resync via NTP, during which TLS cert validation fails: Cloudflare WARP `162.159.192.1:2408` rejects the handshake → gluetun's healthcheck (`interval: 2s, retries: 15`) eventually flips unhealthy → Docker `unless-stopped` restarts the `warp` container (~30s gap). `mDNSResponder`'s in-memory cache still holds pre-sleep entries (stale A records for tailnet hosts) so the first dozen DNS queries after wake time out. `tailscaled` on the host often keeps its stale DERP relay preference and routes packets through a dead relay for another 30-60s.
* **(B) Wi-Fi roam / loss in elevators, captive portals.** WARP is a UDP tunnel to Cloudflare's anycast edge. Carrier NATs and captive-portal networks silently invalidate the UDP binding on roam and on hotspot-bound re-association. macOS `networksetup` *should* preserve DNS settings on the same Wi-Fi service across a roam, but most captive-portal networks DHCP-replace DNS to the captive-portal resolver **during the captive-portal dance itself**, before the user has authenticated — so even DNS hijack survives a clean roam and quietly breaks on captive-portal handoff.

**Resolution.** A single **launchd LaunchAgent** (`com.nullexit.wake-recovery`) runs a long-running shell daemon (`scripts/watcher.sh`) that listens for both event sources and, on each fire, executes `bash recover.sh --post-wake` — a *lighter-touch* recovery mode that's the opposite of the existing `--nuclear` semantics: it keeps the gateway live while still refreshing every stale subsystem.

**Deep dive: Apple Power Management Primer (for the unfamiliar).**
macOS exposes several relevant surfaces; the right primitive depends on what you actually need to detect. None of these are obvious and none of them have a standard splash screen in the docs.

* **`caffeinate <flags>`** creates I/O Kit power assertions via `IOPMAssertionCreateWithName`. It does NOT block forced sleep (lid close, low-battery shutdown, sleep timer firing on a per-set Energy Settings policy). Flags:
  * `-i`  PreventIdleSleep (the only one `toggle.sh` uses; protects against the OS going idle while the user is active — but a clamshell close still hard-puts it to sleep)
  * `-s`  PreventSystemSleep (only honored on AC power; the user may be on battery)
  * `-u`  DeclareUserActive (resets the idle timer every 30s by default; equivalent to keeping the cursor moving)
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

**The Fix (component-by-component).**

1. **`recover.sh --post-wake`** (new flag, **non-destructive** by design). Adding `--post-wake` to the existing nuclear recovery script inverts the semantics. The default mode still tears down Tailscale, resets DNS to empty, stops caffeinate, runs `docker compose down`, power-cycles Wi-Fi. The new mode does:
  * Skip Tailscale disconnect (we WANT it to keep the mesh connection)
  * **Re-hijack** DNS to the gateway Tailscale IP read from `.gateway_ip` (instead of resetting to empty) — applies to both `ACTIVE_SERVICE` and `EN0_SERVICE` because the system resolver is scoped to en0
  * **Refresh** the exit-node preference with `tailscale up --reset --ssh=true --accept-dns=false --exit-node=\"$TS_IP\" --exit-node-allow-lan-access=true` (the exact flags `toggle.sh` START uses). This re-asserts DERP mapping without dropping the mesh
  * Inspect `docker inspect --format '{{.State.Health.Status}}' nullexit-warp-1` and **only** `docker compose up -d --force-recreate warp` if gluetun is unhealthy — this single targeted recreate nudges the UDP NAT binding back to Cloudflare without disturbing Tailscale or AdGuard
  * Run the sharingd-reset step (existing fix from `toggle.sh` START path; see §15.11) so AirDrop doesn't freeze on the new IP lease
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
  * `KeepAlive: { SuccessfulExit: false, Crashed: false }` — **don't** restart on clean SIGTERM exit (so `launchctl bootout` doesn't get stuck in a relaunch loop). Also **don't** restart on hard crash: we observed that macOS Sonoma+'s sleep/wake suspend-resume path accumulates orphan watcher.sh PIDs because SIGCONT does not reliably clean up the prior instance's listener grandchildren, and a `KeepAlive.Crashed=true`-driven relaunch actively races with the still-live prior process. The script enforces single-instance on its own via a `flock`-style PID-file lock, so a relaunch-on-crash would be skipped by the lock and produce   0 listener coverage until the live instance happened to die. Trade-off: a real crash leaves the user without auto-recovery until they run `launchctl load -w` manually — acceptable because (a) gateway still works without auto-recovery, (b) a relaunch wouldn't fix whatever caused the crash, and (c) the gateway-recovery itself is observably broken (no DNS, no exit-node) if it does go down.
  * `ProcessType: Background` — hint to App Nap not to suspend us.
  * `StandardOutPath/StandardErrorPath: /tmp/nullexit-watcher.{out,err}.log` — separates launchd-level diagnostics from the script's own `/tmp/nullexit-watcher.log` (which `exec >>` redirects).

**Install (one-time).** The plist lives in the repo at **`launchd/com.nullexit.wake-recovery.plist`** for version control. The installed (live) copy must land in `~/Library/LaunchAgents/` so launchd picks it up on the user session.

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

**Why this fix was preferred over alternatives.**

* **Polling with `StartCalendarInterval`** would have given ~30-60s detection latency per wake. The unified-log stream is sub-second.
* **Sleepwatcher** would have covered wake events but not network changes. We'd still need a separate `scutil` listener, and introducing a third-party dependency for what amounts to ~150 lines of shell is unjustified.
* **Forcing `caffeinate -l`** doesn't exist and the closest equivalent (`caffeinate -s`) only works on AC power. The whole point of the gateway is to stay usable on battery while traveling — lid close must NOT silently kill the gateway.
* **A kernel extension** is impossible (no entitlement) and out of scope.

**Reproduction recipe.** Test both events in isolation to confirm the fix actually closes the gap.

* **(A) Lid-only repro**: with the gateway up, run in a terminal: `pmset displaysleepnow && sleep 30 && pmset wake` (without physically closing the lid). Watch the wake wake-fires the watcher → post-wake routine runs — login should still work in <5s after wake. Compare to baseline pre-fix: pre-fix the gateway would be dead for 30-90s.
* **(B) Roam-only repro**: with the gateway up: `networksetup -setairportpower off && sleep 30 && networksetup -setairportpower on` (or simply walk out of Wi-Fi range and back). The captive-portal WILL repave DHCP DNS for a few seconds; the watcher fires on the second `State:/Network/Global/IPv4` change (after the Wi-Fi re-associates) and the post-wake routine re-hijacks DNS within 2-3s.

**Operative files.**

* `recover.sh` — added arg parsing; wrapped destructive sections behind `POST_WAKE`; added re-hijack DNS / refresh exit-node / force-recreate-if-unhealthy path.
* `toggle.sh` — added `write_gateway_active_marker` / `clear_gateway_active_marker` called at the END of START and TOP of STOP / cleanup_handler.
* `scripts/watcher.sh` — new long-running daemon.
* `launchd/com.nullexit.wake-recovery.plist` — launchd LaunchAgent descriptor.
* `~/Library/LaunchAgents/com.nullexit.wake-recovery.plist` — the installed copy (one-time copy).

**Honest assessment (read before testing).** This fix has two asymmetric halves:

* **Network / roam / captive-portal path — RELIABLE.** `scutil n.watch` on `State:/Network/Global/IPv{4,6}` catches every Wi-Fi roam, captive-portal DHCP-rebind, hotspot handoff, and VPN change with zero missed events. To validate, drop Wi-Fi for 30 s and re-add it; `/tmp/nullexit-watcher.log` will record a `NET:` trigger and `recover.sh --post-wake` will run within ~10 s of the network coming back.
* **Lid close / wake path — BEST-EFFORT on macOS Sonoma+.** Apple *suspends* LaunchAgents process-state during forced sleep and *resumes* them on wake; it does NOT re-launch them every wake. As a result: (a) `log stream` is a live subscription — events emitted during the agent's suppressed window are DROPPED, not buffered, so the wake event that prompted the resume is invisible to `log stream` on resume; (b) the "fire on startup" guard runs once on `launchctl load -w` and after a `KeepAlive` crash-recovery, NOT on every successive wake; (c) `subsystem == "com.apple.powermanagement"` will catch FUTURE emissions (display dim/restore, manual sleep/wake) but not the lid-close→open wake directly.

In practice the lid-wake gap is short, because `toggle.sh`'s existing DNS Watcher already polls every 5 s and re-hijacks DNS (so DNS recovers within 5 s of any roam or wake), `tailscaled` self-heals via DERP fallback within 30–60 s, and `gluetun` reconnects via its healthcheck retry within 30 s. The user-visible pain on lid open is ~30 s of wonky DNS, not a permanent outage.

**Test the ROAM path FIRST.** If ROAM works in your testing, the lid-wake gap is acceptable. If lid-wake handling is critical, the two clean follow-ups are:
1. **Sleepwatcher** (one canonical install): `brew install sleepwatcher`; drop `recover.sh --post-wake` into `~/.sleep` and `~/.wake` so Sleepwatcher invokes it directly on every wake without the launchd propagation problem.
2. **Move the watcher to a LaunchDaemon** (root) and use `IOPMSchedulePowerEvent` via a tiny C wrapper — not portable to shell.

A truly reliable shell-only solution to "wake events from inside a LaunchAgent" does not exist on macOS Sonoma+.

**Empirical lessons from deployment.** Two findings came up while deploying this fix end-to-end; recording so the next operator doesn't lose an evening to each.

1. **Bash function-call-before-definition gotcha.** While introducing the gateway-active marker helpers, the defensive `clear_gateway_active_marker` call was inserted at the very top of `toggle.sh` (right after `set -e`), but the function definition lived near `PID_FILE="/tmp/nullexit-caffeinate.pid"` ~90 lines down. Bash parses top-to-bottom and resolves names at first invocation, so the call site exited with code 127 (`clear_gateway_active_marker: command not found`). The gateway stayed unreachable from the START path even though `bash -n` passed (the parser doesn't catch order-of-resolution errors). Rule: define functions BEFORE any block that calls them. Verify with `grep -n '^name()\s*{'` followed by `grep -n '^name\s*$'` — the latter must appear on a line number AFTER the former.
2. **`networksetup -setairportpower off+on` is not a faithful roam reproduction.** Synthetic Wi-Fi radio-cycling (`sudo networksetup -setairportpower Wi-Fi off` for 30 s, then back on) is expected to produce a `NET:` trigger in `scutil n.watch` but produced ZERO during testing — because `setairportpower` powers the radio at the driver level while leaving the network SERVICE in the `"up"` state from scutil's perspective, so no `n.state State:/Network/Global/IPv4` event is generated. A real roam (macOS briefly loses the AP and re-associates into a different one) DOES fire the event because the link actually changes.
   Better reproduction recipes in priority order:
   * Walk between two real SSIDs via `networksetup -switchtolocation` (or actual physical station movement) — guaranteed to fire the scutil event.
   * Force a DHCP rebind on the same SSID with `sudo ipconfig set en0 DHCP` — triggers `State:/Network/Global/IPv4` to update.
   * Trust the existing 30-second DNS Watcher inside `toggle.sh` for the DNS path: it re-hijacks DNS automatically. The post-wake watcher adds clear value mostly for tailscale exit-node re-assertion and warp gluetun force-recreate, both of which self-heal within ~30 s anyway.

#### 15.5.2 July 8, 2026: Network Watcher Event Mismatch, Sudo-in-Background Crash, and Loop-Prevention
**Symptom:**
1. Switching Wi-Fi or waking the Mac from sleep did not trigger a post-wake recovery (`recover.sh --post-wake`) automatically.
2. The network connection would eventually get completely sinkholed/blocked. If the user tried to restart or wait, it did not self-heal.
3. During the recovery attempt, checking the public IP on the host would return the unencrypted campus/ISP IP (starting with `132.`) instead of the encrypted tunnel IP.

**Root Cause:**
- **Bug 1 (Network Watcher Mismatch):** In `scripts/watcher.sh`, the network change listener watched `State:/Network/Global/IPv4` changes via `scutil n.watch` but matched them against `*n.state*|*SCEventUpdate*`. On macOS, the actual output is `changedKey [0] = State:/Network/Global/IPv4`. Because the pattern did not match, all network switches were silently ignored.
- **Bug 2 (Sudo Caching Background Crash):** When the background WARP Watcher eventually detected the broken tunnel (after 6 failures/30s), it triggered the default nuclear `recover.sh` (with `POST_WAKE=false`). Because there was no active TTY in the background context, the `sudo -v` caching check aborted instantly with a terminal required error. Due to `set -e`, `recover.sh` died immediately before resetting DNS, disabling the packet-filter killswitch, or stopping containers, leaving the host network completely sinkholed.
- **Bug 3 (Post-Wake Infinite Loop):** Once the watcher patterns were fixed, `recover.sh --post-wake` triggered successfully on network changes. However, because the script deleted the default routing entries at the start, spent ~15 seconds rebuilding 88 DERP relay bypass routes, and re-added the default routes at the end, this execution time exceeded the watcher's 10-second debounce threshold. Furthermore, the watcher recorded the *start* timestamp in the debounce file. Consequently, the route changes made by the script itself triggered the watcher again immediately after completion, trapping the system in an infinite loop of recovery runs. During this loop, the VPN routes were constantly deleted, resulting in the host leaking traffic through the real ISP interface (an IP starting with `132.`) for 15s out of every cycle.

**Resolution:**
- **Fixed Watcher Matching:** Updated `scripts/watcher.sh` to match `*changedKey*` and `*State:/Network/Global/IPv*` to correctly catch network changes.
- **Bypassed Background Sudo:** Added `--auto`/`--non-interactive` flags to `recover.sh` and added a TTY check `[ -t 0 ]` to skip interactive `sudo -v` authentication when running headlessly in the background. Updated the WARP Watcher call in `toggle.sh` to pass `--auto`.
- **Prevented Infinite Loops:** Modified `scripts/watcher.sh` to write the **completion** timestamp of `recover.sh` to `DEBOUNCE_FILE` (instead of only the start timestamp). This ensures all buffered network config events generated during route reconstruction are evaluated against the end-of-run timestamp and successfully debounced, breaking the infinite loop.
- **Centralized & Timestamped Logs:** Redirected `watcher.sh` stdout/stderr from `/tmp/nullexit-watcher.log` to the repository's main `output.log` and updated `scripts/common.sh`'s `step`, `ok`, `warn`, `fail`, and `die` helpers to prefix logs with a local `[YYYY-MM-DD HH:MM:SS]` timestamp.

#### 15.5.3 Incident Post-Mortem: Startup Pre-Flight Check Tailscale Race (July 10, 2026)
**Symptom:** Immediately after startup via `toggle.sh`, the pre-flight connectivity check `[1/3] Gateway reachable via Tailscale` returned `FAIL`, forcing `toggle.sh` to skip the full exit-node activation and fall back to SOCKS5/local DNS proxy mode. 

**Root Cause:** A timing race condition during startup. In `toggle.sh`, the host joins the mesh using `tailscale up --reset` (Phase A) right before performing the pre-flight check. Because `tailscale up` resets and reconfigures the host's `tailscaled` daemon, the local daemon must fetch the latest netmap asynchronously from the coordination servers. This network map propagation and route establishment takes a few seconds. Running `tailscale ping` immediately after `tailscale up` returns (with no delay) causes the check to fail because the local daemon has not yet discovered the gateway node `100.100.21.8`.

**Fix (July 10, 2026):** Upgraded pre-flight Check 1 in both `toggle.sh` and `scripts/toggle-linux.sh` to use a 5-attempt retry loop with a 1-second delay between checks. This allows up to 5 seconds for local tailnet routing paths to settle, ensuring the gateway is correctly reached and a pong is received before deciding whether to enable exit-node routing.

#### 15.5.4 Incident Post-Mortem: Pre-Flight Check False Negatives due to VPN Firewall STUN Blocks (July 10, 2026)
**Symptom:** Immediately after a cold boot or full restart of the gateway, the pre-flight connectivity check `[1/3] Gateway reachable via Tailscale` failed, causing `toggle.sh` to skip the full exit-node configuration and fall back to SOCKS5/local DNS proxy mode. However, manually running `tailscale ping 100.100.21.8` immediately after startup succeeded in 1ms.

**Root Cause:** An asynchronous Tailscale handshake delay caused by firewall restrictions. Inside the container network namespace, the `warp` container (gluetun) implements a strict firewall that blocks all outbound UDP traffic to the public internet except to the designated WireGuard endpoint. Because of this, the `tailscale` container's STUN requests to public STUN servers are blocked, causing the local daemon to report `UDP is blocked, trying HTTPS`. Without UDP STUN capability, Tailscale is forced to fall back to a slower DERP-assisted handshake (relayed via HTTPS/TCP). This negotiation and direct-path punch-through takes roughly 30 to 35 seconds to establish on cold boots (after a full `tailscale up --reset`). Since the pre-flight check only waited 15 seconds (15 attempts with 1-second sleeps), the check timed out and aborted before the path completed.

**Fix (July 10, 2026):** Increased the pre-flight ping retry limit from 15 to 45 attempts (45 seconds) in both `toggle.sh` and `scripts/toggle-linux.sh`. This provides sufficient time for the DERP-assisted handshake to complete on cold boots, while still passing immediately (in 1-2 seconds) on warm starts or once the path is established.

#### 15.5.5 Incident Post-Mortem: Docker Image Build DNS Failures on Immediate Restart (July 10, 2026)
**Symptom:** When executing `toggle.sh --restart`, the script successfully stops the gateway but then immediately fails during startup during `docker compose build` with DNS resolution errors:
`failed to do request: Head "https://registry-1.docker.io/...": dial tcp: lookup registry-1.docker.io on 192.168.5.1:53: no such host`.

**Root Cause:** A race condition between physical link negotiation and virtual machine startup. The STOP path of the restart command invokes `cleanup_network_state` which power-cycles the host's physical Wi-Fi interface (`en0`) to flush stale routing states. Immediately after, `toggle.sh` starts the gateway boot sequence. Because `toggle.sh` did not verify the status of the physical interface, it proceeded to boot Colima and build Docker containers while `en0` was still negotiating a DHCP lease. Consequently, the host (and by extension, the VM bridge) had no active internet gateway/DNS path, causing Docker's registry check to fail.

**Fix (July 10, 2026):**
1. Created a unified `wait_for_dhcp_settle` helper function in `scripts/common.sh` that polls `ipconfig getpacket` and `ifconfig` until a valid IP and router are assigned. To handle typical macOS Wi-Fi reassociation and DHCP negotiation latency (which commonly takes 15-20 seconds after a power-cycle), this loop was configured to poll up to 60 times (30 seconds total).
2. Injected a call to `wait_for_dhcp_settle` at the beginning of the `START` action in `toggle.sh` (right before checking Colima status) to block container builds until the host's physical network is online.
3. Refactored `recover.sh` to reuse the unified `wait_for_dhcp_settle` function.

#### 15.5.6 Watcher.sh Suppressed Exit Code Bug (Fixed)
**Observation:** The `scripts/watcher.sh` script is a long-running daemon that invokes `recover.sh --post-wake` when it detects system wake or network roam events. Previously, it contained the following bug:
```bash
  bash "$RECOVER" --post-wake
  local exit_code=$?
  ...
  return $exit_code || true
```
The `|| true` mistakenly swallowed the actual `$exit_code` returned by `recover.sh`, causing `run_recover()` to always return `0` (success), masking any underlying failures in the wake recovery process.

**Fix:** The `|| true` statement was removed from the return line:
```bash
  return $exit_code
```
Since `watcher.sh` explicitly omits `set -e` (to prevent pipe breakages from killing the daemon), removing `|| true` safely allows the underlying exit code to propagate without risking daemon termination. The watcher daemon was then reloaded (`launchctl kickstart -k`) to pick up the script changes in memory.

#### 15.5.7 Network Readiness Race Condition on `--restart` (Fixed)
**Problem:** When running `./toggle.sh --restart`, the script tears down the gateway and immediately begins the startup sequence. On systems with Wi-Fi (or any wireless interface), the OS takes a moment to re-associate with the network after the teardown's DNS/routing changes. If the startup sequence ran before the OS had a default route, `get_active_service` would return nothing, routing bypass targets would be wrong, and DNS/WARP setup would silently fail — resulting in a partially configured gateway that self-heals only once the `watcher.sh` re-runs.

**Root cause:** The original code had no gate before the first network-dependent call (`ACTIVE_SERVICE=$(get_active_service)` at the top of the start branch). This was a pure timing race.

**First fix (Wi-Fi specific):** A polling loop on `ipconfig getifaddr en0` was added to wait for an IPv4 address on `en0` before proceeding. This worked but was brittle — it only handled Wi-Fi and would fail for Ethernet, USB-C adapters, or iPhone USB tethering.

**Generalized fix:** Replaced the `en0` check with `route get default | grep 'gateway:'`. This detects a valid default gateway on *any* interface, covering all connection types. The loop polls every 2 seconds with a 60-second hard timeout (then proceeds with a warning rather than hanging forever). The output prints the detected gateway IP so failures are easy to diagnose in logs.

```bash
# In toggle.sh, before ACTIVE_SERVICE=$(get_active_service)
while true; do
  if route get default 2>/dev/null | grep -q 'gateway:'; then
    _gw=$(route get default 2>/dev/null | awk '/gateway:/{print $2}')
    echo "  Network ready (default gateway: $_gw)."
    break
  fi
  ...
done
```

**Why not ping?** Pinging an IP (e.g. `1.1.1.1`) during restart is unreliable because DNS may still be hijacked from the previous session, and the exit node routing may not yet be cleared, causing the ping to loop back through the tunnel. `route get default` is a pure local kernel query — no packets sent.

### 15.6 WARP Tunnel Liveness & Host Leaks

#### 15.6.1 Host-Side Traffic Leaking Past the Exit Node (with Remote Clients Routing Correctly)
**Symptom.** `toggle.sh` reports success. Remote tailnet clients (e.g. an S24 phone) correctly egress through Cloudflare WARP and see a Cloudflare IP on `whatismyip.com`. But on the **HOST Mac running the gateway**, `whatismyip.com` reports the underlying physical ISP's ASN (e.g. `campus_isp` for a university campus Wi-Fi). The gateway container itself is healthy; the leak is specifically on the host.

**Root causes.** Three distinct mechanisms can each produce this exact symptom on the host alone, while leaving remote clients unaffected. They are mutually rankable so the diagnostic picks the active one deterministically.

* **(A) SOCKS5 fallback lane active.** `toggle.sh`'s three Phase-B pre-flight checks (`tailscale ping` → AdGuard via `dig +tcp` → WARP internet, toggle.sh ~lines 750-820) sometimes flake during the first minute. When ANY of the three fails, the script sets `SKIP_EXIT_NODE=true` (toggle.sh:849) and instead activates the SOCKS5 fallback path (toggle.sh:894). The SOCKS5 fallback hijacks DNS to `127.0.0.1` (so AdGuard filtering still works) but **modern browsers on macOS do NOT honor the system SOCKS5 proxy** — they ignore `networksetup -setsocksfirewallproxy`. Result: DNS gets ad-filtered but actual HTTP/S traffic exits direct through the campus ISP. This branch is invisible from a remote tailnet client because the client's tunnel is unaffected.

* **(B) IPv6 leak over campus Wi-Fi.** The Tailscale exit node and WARP tunnel are both IPv4-only (gluetun + `post-rules.txt` drop all IPv6 forwarded traffic; see §15.12 IPv6 Exit-Node Leak). But many university and enterprise APs are dual-stack — the host happily accepts AAAA DNS responses and sends IPv6 traffic straight out `en0`. macOS happily encrypts that traffic through Tailscale ONLY if Tailscale has IPv6 advertised; with an IPv4-only exit node, IPv6 traffic skips Tailscale entirely. This branch is invisible from a phone because iOS/Android Tailscale apps actively sinkhole IPv6 in their VPN profile, but the macOS host's `tailscaled` does not.

* **(C) Route-table freeze and `--accept-routes` reset after `tailscaled` wake/toggle.** Running `tailscale up --reset` clears the exit-node preference and reverts `--accept-routes` back to its default (`false`). Without explicitly passing `--accept-routes=true`, `tailscaled` will not attempt to install the default route through the `utun*` tunnel interface even if the exit node preference is reconciled. Additionally, macOS occasionally freezes and fails to apply route-table changes (see §15.11 Standalone Tailscale Daemon Freeze). In both cases, `netstat -rn` shows the default route still pointing to the physical Wi-Fi gateway (e.g. `172.17.0.1`) instead of the Tailscale `utun*` interface, causing host traffic to exit direct while remote clients route correctly.

**Why remote clients don't see this.** Each remote phone/laptop uses its OWN Tailscale tunnel to reach the container's `100.x.x.x:443` over the mesh — they're end-to-end encrypted regardless of how the host Mac itself is configured. Only the HOST's own egress sockets (HTTP requests from the host's browser, curl, etc.) are affected.

**Resolution.** A single script: `scripts/diagnose-host-leak.sh`. It runs the 8 checks, classifies into one of A / B / C / OK, prints a verdict + a ready-to-run fix command on stdout, AND writes the full report to `host-leak-diagnostic-<UTC>.txt` so the user can paste the file back instead of scrolling-and-copying from the terminal. With `--fix`, the matched remediation is applied and the two checks that could change (warp + ipv6) are re-verified. With `--watch` (or `--watch 30`), it runs the full baseline diagnostic then enters a continuous loop checking warp/IPv6/default-route every N seconds, alerting only on state changes — logs to `host-leak-watch.log`.

```bash
# Diagnose only:
bash scripts/diagnose-host-leak.sh

# Diagnose + apply matched fix + re-verify:
bash scripts/diagnose-host-leak.sh --fix
```

**What it prints.** A 7-section report (`tailscale status`, SOCKS5 state, `cdn-cgi/trace` warp=, IPv6 leak probe, host default route, last toggle.sh output.log hints, resolved gateway Tailscale IP), followed by a classification block (`Scenario: A | B | C | OK`) with the exact command(s) the user needs to paste into their terminal — they don't have to figure out which `tailscale up` flags match their environment.

**What it does NOT do.** It does not touch `toggle.sh` or `toggle.sh`'s pre-flight logic, does not modify `.env` (except `--fix` mode appends `GATEWAY_BYPASS_PING=true` when fixing Scenario A), and does not restart Docker. It is a read-only diagnostic with an opt-in remediation flag. Safe to run on a healthy gateway — the worst case is a 30-line report that says "OK".

**Why cdn-cgi/trace over whatismyip.com for the verdict.** `whatismyip.com`'s ISP database routinely mislabels campus IPv6 ranges as residential ISPs (that's why the local ISP's ASN appears even when you're routing through Cloudflare). `cdn-cgi/trace` is hosted by Cloudflare ITSELF and reports `warp=on|off` plus the exact edge colo serving the request. It is the only public endpoint that can truthfully confirm whether the WARP tunnel is in use.

**Common false alarms.**

* **`warp=on` but whatismyip.com still shows the local ISP.** `whatismyip.com`'s ISP-detection database is unreliable on academic networks. Trust `cdn-cgi/trace`'s `warp=on` over `whatismyip.com`'s ISP string. Use `https://api.ipify.org` (returns just the IP, no ISP DB lookup) as a third confirmatory check.
* **`tailscale status` shows the host online but exit node preference is missing.** `tailscale up --reset --exit-node=` (empty value) clears any stale preference; `tailscale up --reset --exit-node=<100.x.x.x>` re-establishes it. The diagnostic prints the exact command with the resolved TS_IP filled in.
* **Both IPv6 leak AND route-freeze flags set simultaneously.** Scenario B outranks Scenario C — fixing IPv6 makes IPv4 the only viable egress, after which the route-freeze usually self-resolves within ~30s (or one more `toggle.sh` cycle).

**Deep dive: Host Leak Probe — Continuous Sub-Second Egress Monitor (`scripts/host-leak-probe.sh`).**

> **⚠️ STATUS: REMOVED (historical).** `scripts/host-leak-probe.sh` and the `HOST_LEAK_PROBE` env flag no longer exist — the file is deleted/untracked and nothing launches it (verified 2026-07-15). Its fail-closed role was superseded by the **PF kill-switch** (`enable_killswitch` in `common.sh`) plus the in-container **WARP Watcher** (§15.6.2); the only surviving host-leak tool is the on-demand `scripts/diagnose-host-leak.sh`. The text below is kept for design rationale only — treat every present-tense claim (auto-launch, PID file, `HOST_LEAK_PROBE=false` toggle) as past tense.

*What it is.* `scripts/host-leak-probe.sh` is a lightweight background daemon (~1.4 MB RSS, ~0–1% CPU) that polls `https://www.cloudflare.com/cdn-cgi/trace` every 300ms directly from the host via `curl` — not via `docker compose exec`. This is a fundamentally different vantage point from the WARP Watcher (§15.6.2): the WARP Watcher asks the WARP *container* whether it sees `warp=on`; the Host Leak Probe asks what a real browser request leaving the host's physical NIC looks like. The two blind spots it covers that the WARP Watcher cannot:

1. **Host-side flash-leaks** — a Cloudflare anycast edge re-route, a browser reusing a stale pooled connection across a tunnel state change, or a split-second routing gap during a Gluetun healthcheck restart (see §15.12.13 Routing Fix 30-second polling — acknowledged 1–4s window).
2. **Host egress while container is healthy** — the container can report `warp=on` while the host's own traffic exits direct (the three-scenario leak class documented above in §15.6.1).

*Lifecycle.* Started by `toggle.sh`'s START path (`start_host_leak_probe`) immediately after `start_warp_watcher`. Controlled by:

| Signal path | What happens |
|---|---|
| `toggle.sh` STOP | `stop_host_leak_probe()` — SIGTERM + PID file cleanup |
| `toggle.sh` `cleanup_handler` (error/INT/TERM/HUP) | Same |
| `recover.sh` (default, non `--post-wake`) | §6d block — kill by PID file |
| `recover.sh --post-wake` | Left running — the gateway is still live |

PID file: `/tmp/nullexit-host-leak-probe.pid`. Toggle with `HOST_LEAK_PROBE=false` in `.env` to disable at next gateway start.

*Output format.* All events are written to `output.log` (repo root) with UTC timestamps. Only state *changes* are logged — the probe is silent during normal healthy operation.

```
[09:10:26] LEAK warp=off ip=45.23.1.1 prev_warp=on prev_ip=104.28.246.50
[09:10:26] ROTATE warp=on ip=104.28.248.11 prev_ip=104.28.246.50
[09:10:26] HOST-PROBE failed/timeout (count=1)
```

curl transport errors (`TLS handshake failed`, `Connection refused`, etc.) are also appended to `output.log` via `2>>output.log` — nothing is silenced to `/dev/null`.

*Grep cheatsheet.*

```bash
grep LEAK output.log            # real warp=off events from the host
grep ROTATE output.log          # Cloudflare anycast edge rotations (harmless)
grep 'HOST-PROBE' output.log    # curl failures / timeouts
```

*Resource budget.* ~1.4 MB RSS, ~0% CPU at rest, ~3 HTTPS requests/second to Cloudflare. Safe to leave running for hours. Back off the polling interval (`bash scripts/host-leak-probe.sh 1.0`) if you observe probe-failure pile-ups indicating Cloudflare rate-limiting.

*Detection vs prevention.* This script detects leaks; it does not prevent them. A sub-300ms flash-leak can still slip between two polls undetected. If `grep LEAK output.log` shows confirmed leak events, the next step is a kill-switch (prevention) — an `iptables` rule on the host's `en0` that drops non-Tailscale, non-local egress whenever the gateway is active. That is a separate engineering task not yet implemented.

#### 15.6.2 In-Flight WARP Tunnel Liveness Monitor & Statistical Auto-Shutdown
**Why.** nullexit's core promise is that your IP always appears as Cloudflare. If the WARP tunnel silently dies — due to a UDP NAT timeout, a Cloudflare edge rotation, a Colima VM clock skew causing TLS cert rejection, or any of a dozen other failure modes — the host silently falls back to egressing through the physical ISP. The user sees the gateway as "up" (containers running, Tailscale connected, DNS hijacked) but their real IP is exposed. This is the exact class of failure that Ingo Blechschmidt documented in his chilling 2024 Linux kernel post-mortem: for over two years, LUKS disk encryption on suspend was silently broken because a refactored kernel syscall returned success while doing nothing ([source](https://mathstodon.xyz/@iblech/116769502749142438)). The lesson: **a security mechanism that fails silently is worse than no mechanism at all** — it creates a false sense of safety that prevents the user from taking corrective action.

**Design principle.** The WARP Watcher (`start_warp_watcher()` in `toggle.sh`) is a background daemon that polls `cdn-cgi/trace` every 30 seconds and applies a **statistically calibrated threshold** before triggering any safety response. This threshold distinguishes transient network blips (which self-heal within seconds) from genuine outages (which require intervention). A single `warp=off` reading is meaningless — Docker might be slow, the network might be congested, a container healthcheck might be restarting. But 6 consecutive off readings (30 continuous seconds of downtime) has vanishingly low probability of being a false positive: even at an unrealistically high 10% false-positive rate per poll, P(6 consecutive) = 0.1⁶ ≈ 0.0001%. In practice, the per-poll false-positive rate is far lower than 10%, making the real probability astronomically small.

**What it does.**

1. **Always logs.** Every state transition (on→off, off→on) is timestamped to `output.log`. The user can `grep WARP output.log` to audit the tunnel's entire lifetime. This is the "never fail silently" mandate.

2. **Tracks consecutive failures.** A counter increments on each `off` reading and resets to 0 on any `on` reading. This ensures the watcher never fires on intermittent flapping.

3. **Auto-shuts down at threshold.** When the counter reaches `WARP_FAIL_THRESHOLD` (default 6, configurable in `.env`), the watcher declares a statistically significant outage and runs `recover.sh` — the nuclear recovery script that disconnects Tailscale, stops Docker containers, resets DNS to `1.1.1.1`, flushes routes, and power-cycles Wi-Fi. This instantly reverts the host to normal (un-encrypted) internet, guaranteeing no traffic leaks through a dead tunnel while the user thinks they're protected. A trigger file at `/tmp/nullexit-warp-shutdown-triggered` prevents double-firing.

4. **Exits cleanly.** After shutdown, the watcher exits (the gateway is dead, there's nothing left to monitor). `stop_warp_watcher()` is also called by `toggle.sh`'s STOP path and `cleanup_handler` to terminate the daemon cleanly during normal teardown.

**Configuration.** Set `WARP_FAIL_THRESHOLD=3` in `.env` for a more aggressive 15s timeout, or `WARP_FAIL_THRESHOLD=12` for a conservative 60s window. The variable is parsed from `.env` using the same `grep` pattern as `GATEWAY_MSS` and `GATEWAY_BYPASS_PING`.

**Log sample.** After a real outage (or a forced test via `docker compose pause warp`):

```
[2026-07-03T21:15:17Z] WARP DOWN — cdn-cgi/trace reports warp=off
[2026-07-03T21:15:47Z] WARP SHUTDOWN — 6 consecutive failures (threshold=6). Running recover.sh to kill the gateway and restore normal internet. Your IP is NO LONGER Cloudflare.
[2026-07-03T21:15:52Z] WARP SHUTDOWN — recover.sh completed, watcher exiting. Your IP is now your real ISP IP.
```

Or, if WARP self-recovers before the threshold:

```
[2026-07-03T21:15:17Z] WARP DOWN — cdn-cgi/trace reports warp=off
[2026-07-03T21:15:32Z] WARP RECOVERED — warp=on after 3 consecutive off readings (threshold was 6)
```

**Relationship to other monitors.** The WARP Watcher is the **innermost safety layer** — it runs as a child of `toggle.sh` and only while the gateway is active. It complements (does not replace) the `scripts/watcher.sh` daemon (§15.5.1, which handles sleep/wake and Wi-Fi roam) and `scripts/diagnose-host-leak.sh` (§15.6.1, which is a manual diagnostic tool). The WARP Watcher is the only component that actively verifies end-to-end tunnel liveness and takes autonomous action when it fails.

#### 15.6.3 Incident: The Overnight Silent IP Leak (July 2026)
**The Problem:** The host leaked traffic over its raw, unencrypted `eth0` IP continuously for roughly 8 hours, completely bypassing the VPN. The `toggle.sh` state and the container liveness checks all reported the gateway as healthy and active.

**The Investigation:**
1. **Sleep/Wake Checks:** We initially suspected macOS sleep cycles broke the routing table. A check of `pmset -g log` confirmed the laptop literally never slept (0 sleep events recorded since boot), ruling out all sleep/wake code paths.
2. **Keepalive Expiry:** We discovered `docker-compose.yml` was missing `WIREGUARD_PERSISTENT_KEEPALIVE_INTERVAL`. Without a keepalive, standard router NAT tables (which typically garbage collect UDP after 30 to 120 seconds of silence) quietly expired the WireGuard port mapping overnight.
3. **Container State Masking:** Because WireGuard is stateless, the `warp` container didn't immediately crash. It stayed "Up", which meant Docker's healthchecks and our `toggle.sh` liveness checks never noticed the tunnel inside it was totally dead.

**The Solution:**
1. Added `WIREGUARD_PERSISTENT_KEEPALIVE_INTERVAL=25s` (the WireGuard standard to beat standard 30s NAT timeouts) to keep the UDP tunnel permanently pinned open through the router.
2. Injected a **Fail-Closed Kill-Switch** into `routing-fix.sh`: A 30-second loop now actively verifies tunnel health by running `curl` over `tun0` to Cloudflare's trace endpoint. If it fails 3 consecutive times, it immediately rewrites the default route to `blackhole`, severing all traffic instead of letting it leak through `eth0`.
3. Added a listener in `watcher.sh` that detects this fail-closed event and instantly pushes a native macOS UI notification to the desktop, alerting the user to manually intervene.

> [!NOTE]
> **Why dual failure systems?** 
> The system now relies on two independent failure handlers that cover each other's blind spots:
> 1. **Automated Self-Healing (WARP Watcher + `recover.sh`):** Triggered when the `warp` container logs `warp=off`. This happens when the server actively kicks the client. Because the container *knows* it is disconnected, it triggers `recover.sh` to safely reboot Docker and reconnect.
> 2. **Fail-Closed Kill-Switch (`routing-fix.sh` + `watcher.sh`):** Triggered when a silent network failure occurs (e.g., NAT timeouts). The container incorrectly believes it is connected (`warp=on`), so auto-recovery never fires. Instead of auto-recovering (which risks falling back to raw Wi-Fi mid-process while the user isn't looking), this kill-switch actively blackholes the internet and forces a manual intervention via a desktop notification.

### 15.7 Tailscale P2P, SNAT & Control Plane

#### 15.7.1 macOS SNAT Endpoint Poisoning & The P2P Blackhole (July 10, 2026)
**Symptom:** When a Tailscale client (like an S24) connected to the exact same Wi-Fi network as the macOS gateway, it completely lost internet connectivity. However, if the S24 connected to a Windows PC's hotspot on the same network, the tunnel worked flawlessly.

**Root Cause:** Claude's critique correctly dismantled the port collision theory: the gateway daemon wasn't failing to bind, and macOS wasn't load-balancing ports. The real culprit was **macOS SNAT Source Port Mangling poisoning Tailscale's path discovery**.

Here is the exact step-by-step of the "infinite loop" blackhole:
1. **The P2P Handshake:** The S24 and the Mac are on the same Wi-Fi (`192.168.1.x`). The S24 discovers the Mac's local IP and sends a UDP hole-punch packet to `192.168.1.5:41641`. Colima successfully forwards this to the gateway container.
2. **The Bypass Rule:** The gateway replies. Because `routing-fix.sh` forces all Tailscale UDP traffic out `eth0` to bypass WARP, the reply goes to the macOS host.
3. **macOS SNAT Mangling:** macOS routes the reply out `en0` to the S24. Because the packet crosses from the Colima VM bridge to the Wi-Fi interface, macOS applies Source NAT (SNAT). Critically, macOS **randomizes the source port** (e.g., changes it from `41641` to `58291`).
4. **Endpoint Poisoning:** The S24 receives the authenticated Tailscale packet from `192.168.1.5:58291`. Tailscale's `magicsock` is designed to handle NAT dynamically, so it assumes the Mac has roamed to port `58291`! The S24 updates its endpoint and starts sending all its encrypted internet traffic to `192.168.1.5:58291`.
5. **The Blackhole:** macOS has no port forward for `58291`. It drops 100% of the S24's outbound data packets. The connection is completely dead.

**Why did the Hotspot work?** When the S24 connected to the PC hotspot, it was behind the PC's NAT. The S24 sent the packet, PC NATted it, and the Mac replied (mangled to `58291`). When the reply hit the PC, the PC's strict NAT dropped it because the source port (`58291`) didn't match the destination port it originally sent to (`41641`). Because the mangled packet was dropped, the S24 never poisoned its endpoint! It safely gave up on P2P, fell back to the 100% reliable TCP DERP relay, and the internet worked perfectly.

**Fix & Resolution (July 10, 2026):**

**Phase 1 — Port disambiguation:** Changed the gateway container's Tailscale listen port from the default `41641` to `41642` across `docker-compose.yml`, `post-rules.txt`, and `routing-fix.sh`. This prevents any bind conflict with the macOS host's native Tailscale daemon.

**Phase 2 — RFC1918 DROP rules:** Updated `routing-fix.sh`'s `add_tailscale_p2p_bypass()` to explicitly drop all outgoing Tailscale UDP packets destined for private subnets (`192.168.0.0/16`, `10.0.0.0/8`, `172.16.0.0/12`) when `TAILSCALE_ALLOW_LAN_P2P=false`. This surgically kills the local P2P hole-punch attempt *before* it can trigger the macOS gvproxy SNAT mangling. The S24 receives a clean failure and immediately locks onto the public DERP relay with 0% packet loss.

**Phase 3 — Automatic network detection:** Because `TAILSCALE_ALLOW_LAN_P2P=false` breaks P2P on trusted hotspots that genuinely don't have AP isolation, a `.env` toggle and a full auto-detection system were implemented:

- **`.env` toggle:** `TAILSCALE_ALLOW_LAN_P2P=true/false` — static fallback, used only if auto-detection cannot run.
- **`watcher.sh` auto-detection (`detect_lan_p2p_mode`):** On every network change, `watcher.sh` runs two checks:
  1. **WPA2-Enterprise detection:** `airport -I` is used to read the current Wi-Fi `link auth` field. If the auth type does not contain `-psk` (e.g., it is plain `wpa2` = 802.1x), the network is classified as enterprise and P2P is forced off. *(Note: the `airport` binary was removed in macOS Sonoma 14.4 — the detection now uses `system_profiler SPAirPortDataType`; see §15.11 for the full migration.)*
  2. **AP Isolation probe:** For WPA2-Personal networks, a short `ping` is sent to the default gateway. If the gateway responds (it always should on a real home/hotspot network), P2P is allowed. If not, AP isolation is inferred and P2P is forced off.
  - The result (`true` or `false`) is written to `.lan_p2p_detected` in the repo root.
- **`routing-fix.sh` dynamic reading:** `add_tailscale_p2p_bypass()` re-reads `.lan_p2p_detected` on every 30-second loop iteration and atomically adds or removes the RFC1918 DROP rules. **No container restart is needed when switching networks.**

**Known Unknowns (Pending Verification):**
- The gvproxy SNAT source port mangling theory is mechanistically sound and backed by observed behavior (gvproxy's UDP proxy changelog has documented edge cases in this exact code path), but has not yet been confirmed via `tcpdump -i en0 udp portrange 40000-60000` while triggering a P2P handshake from the phone. A packet capture cross-referenced with `tailscale ping` endpoint reports on the phone side would confirm the theory definitively.
- Claude's recommendation: run `tcpdump -i en0 udp port 41642 or portrange 40000-60000` on the Mac while triggering the handshake from the phone to see whether the reply leaves with a different source port than `41642`.
- **Client-Side VPN Cycling (Roaming Recovery):** An observation (July 10, 2026) suggests that when a hung DNS probe state is triggered by roaming between Access Points (APs) on a WPA2-Enterprise network, simply toggling the VPN connection (Tailscale) off and on locally on the client phone immediately resolves the issue. You do not need to cycle the phone's physical Wi-Fi. This reinforces the theory that roaming on Enterprise networks leaves a stale/poisoned P2P endpoint in the phone's Tailscale magicsock state, which gets instantly flushed upon a local VPN restart. (Status: Possible but not formally verified).

#### 15.7.2 July 6, 2026: Packet Filter (pfctl) Defaulting Local LAN Rules to TCP-Only
**Symptom:** Devices on the exact same local Wi-Fi network as the gateway were experiencing ~500ms latency to the gateway instead of the expected ~80ms.

**Root Cause:** When writing the `pf.conf` rules to whitelist local LAN traffic (`pass out quick on $ext_if to { 192.168.0.0/16, ... }`), the rule omitted an explicit protocol. The macOS `pfctl` compiler implicitly applies state tracking to all `pass` rules. However, because state tracking (`keep state`) natively evaluates TCP sessions, `pfctl` automatically appended the `flags S/SA` modifier to the compiled rule in the kernel. This silently restricted the whitelist to **TCP only**, causing all local UDP traffic to be dropped by the default-deny kill-switch. Since Tailscale relies on UDP port 41641 for direct P2P connections, the local devices were unable to hole-punch and were forced to fall back to routing traffic through a remote Tailscale DERP relay, massively inflating latency.

**Resolution:** Split the single implicit rule into explicit `proto tcp`, `proto udp`, and `proto icmp` rules in `scripts/pf.conf` to guarantee the macOS compiler allows all three core transport protocols on the local subnet without mutating the rule into a TCP-only lock.

#### 15.7.3 Incident Post-Mortem: PF Kill-Switch Bricks Host Internet in SOCKS5 Fallback Mode (July 10, 2026)
**Symptom:** When the pre-flight checks fail (e.g. because host Tailscale was unauthenticated/logged out), the script falls back to SOCKS5 proxy mode but the host immediately loses all internet connectivity and tailscaled reports `You are logged out... connect: no route to host`. Even running `sudo tailscale up` to log in fails because the connection to the control plane times out.

**Root Cause:** An architectural mismatch. The macOS Packet Filter (PF) Kill-Switch works at the IP level: it blocks all outbound traffic on the physical interface (`en0`) except to explicitly whitelisted VPN endpoints, expecting all other traffic to go through the virtual VPN interface (`utun*`). In SOCKS5 fallback mode, the exit-node (`utun*`) is NOT enabled; instead, only specific applications (like browsers) use the localhost SOCKS5 proxy, while all other host traffic (including the `tailscaled` daemon's UDP packets) continues to go through `en0`. Because the script still enabled the PF Kill-Switch during SOCKS5 fallback, it blocked all non-SOCKS5 traffic on `en0`, completely bricking the host's internet and locking the Tailscale daemon out of the control plane.

**Fix (July 10, 2026):** Modified `toggle.sh` to remove the `enable_killswitch` call from the SOCKS5 fallback path. The firewall kill-switch is now strictly reserved for exit-node VPN mode, ensuring SOCKS5 fallback leaves the host's direct internet route open for system daemons to authenticate.

#### 15.7.4 Incident Post-Mortem: Host Tailscale Logouts due to Aggressive reset Flags (July 10, 2026)
**Symptom:** Every time the user runs `toggle.sh` or `recover.sh` which disconnects/reconnects the host client, the host client randomly gets logged out, forcing them to re-run `sudo tailscale up` to authenticate.

**Root Cause:** An overly aggressive configuration reset. The host-side `tailscale up` calls (used in `disconnect_tailscale_host` and the startup/enable exit node paths) all passed the `--reset` flag. On macOS, `--reset` resets the entire configuration state and authentication token cache of the daemon. Since the script does not pass a `TS_AUTHKEY` to the host's commands (which are meant for the user's private interactive client), the `--reset` flag effectively logged the user out of their tailnet, requiring interactive re-login.

**Fix (July 10, 2026):** Removed the `--reset` flag from all host-side `tailscale up` invocations in `toggle.sh` and `scripts/common.sh`. This ensures that exit-node state transitions (enabling/disabling) are handled safely while preserving the host client's authenticated session.

#### 15.7.5 Incident Post-Mortem: macOS Tailscale Flag Requirement Abort (July 10, 2026)
**Symptom:** When the `toggle.sh` stop trap or the roaming watcher triggered, the gateway failed to shut down or disconnect properly. The `output.log` showed the error: `Error: changing settings via 'tailscale up' requires mentioning all non-default flags. To proceed, either re-run your command with --reset...`

**Root Cause:** In a previous attempt to stop host-side logouts (§15.7.4), we removed the `--reset` flag from all `tailscale up` invocations. However, if the Tailscale daemon on macOS is already running with non-default flags (like `--ssh` or `--accept-routes`), invoking `tailscale up` with only a subset of flags (like `--exit-node=`) triggers a strict safety check in the Tailscale CLI that aborts the command completely. Because the command aborted, exit-node routing remained stuck.

**Fix (July 10, 2026):** Migrated all specific preference changes in `toggle.sh` and `scripts/common.sh` from `tailscale up` to a two-step sequence:
1. `tailscale up` (with no flags) — to safely ensure the interface is brought up using the current authenticated state.
2. `tailscale set --exit-node=...` — to modify the specific target preference cleanly without triggering the missing flags error or requiring `--reset`.

### 15.8 Docker / Colima Lifecycle

#### 15.8.1 Colima VM Memory / Swap Thrashing Latency
**Symptom:** After running nullexit flawlessly for over 24 hours straight to test stability, the 0.5GB VM RAM configuration began experiencing severe network latency on the Tailscale mesh later in the day.

**Root Cause:** Services (like AdGuard, Tailscale, Docker logs) slowly accumulate cache and state over extended periods. Under the tight 512MB physical RAM limit, this slow creep forced the Linux kernel to aggressively swap memory to the 512MB SSD swap file. The constant disk I/O thrashing blocked process execution, causing DNS resolutions and packet forwarding to delay significantly (making the internet feel "very slow").

**Proof (Empirical Observation):** While in this OOM-thrashing state, direct DNS queries through the Tailscale mesh (`dig @100.100.21.8 google.com`) would intermittently hang or take several seconds to resolve. After restarting with the 600MB configuration, the exact same query immediately dropped to a lightning-fast **41ms** response time. (Note: Querying the mapped host port via `127.0.0.1:5354` will always time out due to Gluetun's strict leak-prevention firewall blocking non-VPN ingress traffic).

**Fix:** Increased VM base physical RAM to 600MB (`--memory 0.6`) and reduced the swap file to 400MB. This provides enough native RAM headroom for long-running state caches without forcing heavy I/O swapping. Subdomain deduplication still reduces blocklists by ~60%. Memory profiles (`light`/`medium`/`heavy`) let users trade off coverage for memory.

#### 15.8.2 Missing iptables in routing-fix Container
**Root Cause:** `alpine:3.20` does not have iptables installed. Commands failed silently with `2>/dev/null || true`.

**Fix:** Updated `docker-compose.yml` to `apk add --no-cache iptables iproute2` before `scripts/routing-fix.sh`.

#### 15.8.3 DOCKER_GW Variable Parsing Bug
**Root Cause:** `ip route show default` printed two lines; `awk '{print $3}'` picked up both, causing route commands to fail.

**Fix:** Added `head -1` to the parsing chain.

#### 15.8.4 Hard Reboots Leave Stale Docker Socket in Colima VM
**Problem:** If the macOS host machine is subjected to a hard reboot, sudden power loss, or a kernel panic, the Colima VM running in the background is abruptly killed. Upon next boot, running `toggle.sh` resulted in the contradictory output:
`Colima is already running.` followed by `Cannot connect to the Docker daemon at unix://~/.colima/default/docker.sock.`

**Root Cause:** The hard crash prevents the inner Docker daemon from executing its graceful shutdown routines. It leaves behind a corrupted `docker.sock` file inside the VM. On boot, the outer VM spins up (hence "already running"), but the inner Docker daemon sees the stale socket, assumes another instance is running, and crashes.

**Fix:** Added an Auto-Healing routine directly into `toggle.sh` (Step 4b). The script now explicitly tests the Docker daemon with `docker ps`. If the daemon is unresponsive despite Colima reporting as active, it assumes a stale socket and automatically runs `colima restart` in the background to cleanly rebuild the VM and socket before proceeding.

#### 15.8.5 Cloudflare WARP 24-Second Startup Delay (UDP Session Rate-Limiting)
**Context:** When running `toggle.sh` to turn the gateway ON, `docker compose up -d` often hangs for exactly 24-25 seconds waiting for the `warp` container to become `healthy`. Users might mistakenly blame the Go `rule-compiler` processing 400k+ rules for this delay, as Docker prints `rule-compiler Exited 24.3s` at the end of the wait.
**Root Cause:** The `rule-compiler` actually finishes its work in <2 seconds. The 24-second blockage is entirely due to Cloudflare WARP's edge server rate-limiting. WireGuard is a stateless protocol with no "disconnect" packet. When the toggle is turned OFF, the old UDP session state remains active on Cloudflare's backend for 20-30 seconds. When the toggle is instantly turned back ON, Docker starts a new WireGuard connection from a new ephemeral UDP source port but uses the **same static cryptographic key** (from `.env`). Cloudflare detects this as a potential replay attack or key-sharing abuse, and intentionally drops all packets (rate-limits) for the new connection until the old session's ghost state fully expires (~20-25 seconds).
**Result:** Gluetun's healthcheck fails repeatedly every 2 seconds until Cloudflare lifts the penalty box, at which point traffic flows and Docker unblocks the rest of the startup sequence. This is a known, expected behavior of reusing static keys rapidly on Cloudflare's network and cannot be bypassed.

#### 15.8.6 July 4, 2026: Multi-stage Docker Builds for Go Ports & Teardown Hang Fix
**Symptom:** The Python implementations of `logger.py` and `sync-rules.py` were slow and required a heavy python runtime inside Alpine containers. Also, `routing-fix` container teardown was hanging for 30s during `toggle.sh` shutdown.
**Root Cause:**
- Python is slower than Go and installing it dynamically via `apk add` added overhead and complexity to the containers.
- Docker containers ignore `SIGTERM` if the init process doesn't handle it, causing a full 30s timeout on shutdown.
**Resolution:**
- Ported `logger` and `sync-rules` to Go using Goroutines for massive concurrent speedups.
- Implemented **Multi-stage Docker builds** (using `golang:1.22-alpine` as builder) to compile the static binaries inside Docker. The final containers are raw Alpine with zero dependencies.
- Added `--build` to `docker compose up -d` in `toggle.sh` to ensure updates are consistently applied on boot.
- Added `stop_grace_period: 1s` to `routing-fix` in `docker-compose.yml` which eliminates the 30-second teardown hang instantly.
- Implemented a cryptographic integrity checker (`scripts/crypto.sh`) using HMAC-SHA256 and `NULLEXIT_SEED` in `.env` to prevent tampering of bash scripts. (See also §15.9.4.)

#### 15.8.7 Colima `start` Post-Provision Hang (~2 min) & the Docker-Readiness Poll (July 14, 2026)
**Symptom:** `toggle.sh` took ~197s of wall-clock time to bring the gateway up, and almost the entire delay lived in a single step: `colima start`. Timestamps in `output.log` showed the VM reaching `READY` and creating the `colima` Docker context in ~8-12 seconds, after which `colima start` simply *did not return* for ~110 more seconds — until the `run_with_timeout 120` watchdog `SIGKILL`ed it. The rest of the boot (containers, routing) then proceeded normally.

**Root Cause:** A colima-internal hang that occurs *after* `Successfully created context colima` is printed. It is **mode-independent**. It was initially misattributed to `--network-address` / `--network-mode bridged` needing the `socket_vmnet` helper, but a controlled test with plain user-mode networking (`colima start --memory 0.6 --vm-type vz`, no `--network-address`) reproduced the identical ~120s hang (04:40:34 → 04:42:34, watchdog-killed) while Docker was fully usable the entire time. Crucially, killing the hung `colima start` process does **not** stop the VM and does **not** corrupt state — `colima status` correctly reports `running` afterwards and `docker` keeps working via the `colima` context. The ~110s was therefore pure dead time waiting on a CLI that had already done its real work.

**Fix:** `scripts/common.sh` now provides `colima_start_until_ready()`. It launches `colima start "$@"` in the background and polls `docker --context colima info` every 3s. The moment Docker answers (~12s in practice) it stops waiting, reaps the (usually still-hung) starter with `kill`, runs `docker context use colima` to guarantee the default context is set, and returns 0. If Docker never answers within a 90s cap it returns non-zero and `toggle.sh` continues to the existing Step 4b `docker ps` auto-heal (§15.8.4). Both Colima start call sites in `toggle.sh` — the LAN-P2P bridged/shared path and the user-mode fast path — now go through this helper instead of `run_with_timeout 120 colima start`.

**Result:** The Colima phase dropped from ~120s to ~12s and total `toggle.sh --restart` wall time from ~197s to ~106s, with the double-tunnel and direct host↔container P2P confirmed intact after the change. The key insight: treat "Docker is reachable" — not "the `colima start` CLI returned" — as the definition of *started*.

#### 15.8.8 Toggle-On Startup Optimizations: Rule-Compiler Off the Critical Path (July 14, 2026)
**Context:** A genuine cold toggle-on (VM bounced for RAM, WARP down) measured **95s**. Profiled per-phase with the now-fixed `DEBUG_TRACE` (§15.11.8-A): Colima cold start **19s** (near floor), `docker compose up` **45s**, tailscale connect+poll **21s**, final checks **7s**.

**Two wrong hypotheses first (documented so they aren't re-tried):** (1) that BuildKit `--build` was the ~30s cost — it wasn't; every layer was already `CACHED`, so gating `--build` saved only ~2s. (2) that `docker compose exec` was slow in the poll loop — it isn't (0.18s steady-state vs 0.06s for `docker exec`); the ~5s/iteration was `tailscale status` **blocking during cold connect** and hitting the `run_with_timeout 5` cap.

**Real bottleneck (evidence-backed):** the 45s `compose up` was **not** WARP. On a genuine cold start WARP goes healthy fast (tor starts right with it → no §15.8.5 same-key penalty; that only bites rapid off→on). The long pole is the **rule-compiler re-deduping ~340k rules inside the 600MB VM (~28s), every toggle** — `adguardhome` started 28s after warp because it waited on `rule-compiler: service_completed_successfully`, even though all 16 remote lists loaded from cache unchanged.

**Fix — hash-gated, off the critical path (kept in-container):**
- `rule-compiler` is now a **`compile`-profiled** service, excluded from `docker compose up`. `adguardhome` and `routing-fix` no longer `depends_on` it — they boot instantly on the `compiled_rules.txt` / `ip_blocklist.ipset` already in `./adguard/work`.
- `toggle.sh` runs it on-demand via `docker compose run --build --rm rule-compiler`, **gated on `compute_rules_hash()`** = sha256 of `black_list.txt` + `white_list.txt` (the lists the user controls). Recompile only when that hash changes, when an artifact is missing, or when the compiled file is older than `RULES_MAX_AGE_DAYS` (default 7, so the remote blocklists still refresh occasionally). A compile failure is **non-fatal** — we keep the previous compiled rules rather than bricking the tunnel (ad-block ≠ the kill-switch).
- Also trimmed the tailscale-connect poll timeouts (status `5s→3s`, `ip -4` `10s→5s`) to reduce overshoot.

**Why NOT run the compiler natively on the Mac host (the tempting idea):** rejected on purpose. There is no Go on the host, so "native" means either `brew install go` (a host toolchain dependency that drifts the project from *portable+secure-on-any-device* toward *faster-on-mine*) or committing a prebuilt arch-specific **binary blob** you'd then have to trust/sign. Worse, it would make the **host** write into the `./adguard/work` bind-mount — violating the deliberate *"single allowed writer is the rule-compiler container"* invariant (host↔container UID/perms mismatches corrupt AdGuard's BoltDB store). Staying in-container preserves both properties; the gate delivers the speed.

**Result:** unchanged toggle → `compose up` **45s → 9s**, total `--restart` **~95–106s → 63s**, with AdGuard still serving the full 342,519 rules (it reuses the existing compiled file) and the double-tunnel + direct host↔container P2P intact. Editing `black_list.txt`/`white_list.txt` flips the hash → one-off recompile → new rules take effect. Both lists were added to the `crypto.sh` signed set (they're security inputs), so editing them requires a re-sign — which is the same moment you'd want the recompile. Local state files `.build_hash` / `.rules_hash` are gitignored.

### 15.9 Permissions, Crypto & Security Hardening

#### 15.9.1 Sudo Credential Caching Removed
**Problem:** The script used `sudo -v` at startup to cache sudo credentials, plus a background `SUDO_KEEPER_PID` loop refreshing them every 60 seconds. This required interactive password entry even with NOPASSWD sudoers configured, because `sudo -v` itself prompts.

**Fix:** Removed the entire `sudo -v` + `SUDO_KEEPER_PID` section. All privileged commands now use `sudo -n` (non-interactive), which works silently because the user has NOPASSWD rules in `/etc/sudoers.d/nullexit` for the specific commands needed (`networksetup`, `python3`, `dscacheutil`, `killall`, `pkill`, `route`, `ifconfig`).

#### 15.9.2 Background Sudo Failures
**Context:** The `--post-wake` script is intentionally designed to skip the `sudo -v` interactive prompt because it is launched by `watcher.sh` running via `launchd` in the background (which has no TTY and cannot accept password input). Thus, it relies entirely on `sudo -n` (non-interactive sudo) for all its internal routing changes.
**Problem:** If the user has not configured the `/etc/sudoers.d/nullexit` file properly, any automated background wake event will silently fail: `sudo -n` commands drop out, the WARP bypass routes fail to apply, and the `warp` container loses internet connectivity.

#### 15.9.3 Tailscale Hijacking the Default Route (PHYSICAL_GW Bug)
**Problem:** When `--post-wake` runs, it clears the routing table using `sudo route -n flush` to ensure a clean slate after the Wi-Fi card roams or wakes up. Because it skips bouncing the Wi-Fi interface (to make the reconnect faster), macOS's DHCP client does not automatically rebuild the physical default route. To counteract this, the script must manually restore the physical default route. Originally, the script tried to capture the physical gateway via `route get default`. However, because the gateway is already running and Tailscale is active, the default route is often already pointing to `utunX`. When this happens, `route get default` does not output a `gateway:` field (it only outputs the `interface:`), causing the captured `PHYSICAL_GW` variable to be empty.
When `PHYSICAL_GW` is empty, the physical default route is never restored, causing the `en0` interface to be isolated from the physical network. The WARP bypass routes then fall back to targeting `-interface en0` (instead of routing via the gateway), which breaks WireGuard's remote connections completely.
**Fix:** The script now bypasses the OS routing table entirely and directly queries the hardware DHCP lease (`ipconfig getpacket en0`) to reliably extract the physical router IP, ensuring the physical route is correctly restored even when Tailscale is active.

#### 15.9.4 July 4, 2026: Consolidation of Core Bash Scripts (Refactoring)
**Symptom:** Over 200 lines of bash logic were directly duplicated across `toggle.sh` and `recover.sh` (e.g. `restart_tailscaled_daemon`, `stop_sleep_prevention`, WARP bypass routes). This caused drift when one script was updated without the other.
**Root Cause:** Historical separation of responsibilities allowed `recover.sh` to grow complex alongside `toggle.sh`.
**Resolution:**
- Massively refactored both scripts by extracting all duplicated networking logic, PID lifecycle management, and environmental configuration down to `scripts/common.sh`.
- Specifically, the `stop_sleep_prevention`, `stop_dns_watcher`, `stop_host_leak_probe`, and `stop_warp_watcher` functions were collapsed into a single `stop_pidfile_daemon()` abstraction.
- Proxy disable loops were abstracted to `disable_all_proxies()`.
- The `162.159.192.1/.193.1` WARP edge IPs are now dynamically resolved from `.env` instead of hardcoded.

#### 15.9.5 Threat Model: Local Proxy Discovery
The Tor SOCKS proxy and Honey-Port Tripwire only bind to `127.0.0.1` (loopback). The real security boundary here is "can an unprivileged local process reach the loopback interface," not "does the malware know the port number." 

The port-randomization and the Honey-Port trap only catch blind or generic port-scanners that do not already know where to look. They **do not protect** against a process that directly reads the `/tmp/nullexit-ports.env` file, greps the `toggle.sh` memory space, or runs `lsof -i` to inspect open socket bindings. 

Because modifying file ownership on `/tmp/nullexit-ports.env` via `chown`/`chmod` to restrict read-access introduces an unavoidable Time-Of-Check to Time-Of-Use (TOCTOU) race condition (the file is created user-owned before privilege escalation, meaning file descriptors can be snatched), it is deliberately left as a standard user-owned file.

The actual, proper mitigation for preventing a malicious local process from reaching the proxy is not hiding the port—it is running a host-level outbound firewall with strict localhost/loopback filtering enabled (e.g., LuLu 4.3.0+ or Little Snitch). These firewalls gate access by cryptographic process identity (binary signature) at the kernel/network-extension level, rather than by port secrecy.

**Verifying Localhost Filtering (The Rogue Binary Test).** To empirically validate that the host firewall properly intercepts local proxy hijacking, you can compile and execute a completely unknown, un-whitelisted "rogue" binary to attempt a connection to the proxy port:

```c
// lulu-test.c
#include <stdio.h>
#include <stdlib.h>
#include <arpa/inet.h>

int main(int argc, char *argv[]) {
    int port = atoi(argv[1]);
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in server = { .sin_family = AF_INET, .sin_port = htons(port) };
    server.sin_addr.s_addr = inet_addr("127.0.0.1");
    
    printf("Rogue binary attempting connection to 127.0.0.1:%d...\n", port);
    if (connect(sock, (struct sockaddr *)&server, sizeof(server)) < 0) {
        printf("Connection BLOCKED by firewall.\n");
        return 1;
    }
    printf("Connection SUCCESSFUL (Firewall bypassed!).\n");
    return 0;
}
```
Compile with `gcc -o lulu-test lulu-test.c`. When executed against the `$TOR_SOCKS_PORT`, a properly configured host firewall (with "Allow Loopback" disabled in LuLu Preferences) will immediately pause the socket execution and generate a desktop alert for the unrecognized binary signature. This physically stops targeted local malware from exfiltrating data through the Tor tunnel, proving the threat model mitigation.

#### 15.9.6 Unlocking Mode-Locked Output Files Without `chmod` (→ `unlock-files.sh`)
**The one-command fix:** `bash scripts/unlock-files.sh` — replaces every known locked inode in the project with a fresh writable one. No `chmod`. Covers `.env` (mode `000`), `adguard/work/userfilters/compiled_rules.txt`, `ip_blocklist.ipset`, `cache/*.txt`, `cache/ip/*.txt`, and `adguard/work/data/filters/*.txt` (mode `0444`). Run it once after setup or after pulling an old repo; `toggle.sh` and `sync-rules.py` will then work without permission errors.

**Context:** The nullexit project has a strict project-wide policy of `no chmod from scripts` (see README §6). This rule exists because every prior `chmod 0444` (post-write tamper-proof lock) and `chmod 000` (post-toggle `.env` lock) call from `scripts/sync-rules.py` / `toggle.sh` could leave a file permanently unreadable on disk if the script exited early, was killed mid-flight, or simply set a restrictive mode without ever being re-flipped. We've stripped every `chmod` from the codebase. But files **written by older versions of those scripts** are still on disk in those restrictive modes (`0444` for `compiled_rules.txt`, `ip_blocklist.ipset`, `data/filters/<id>.txt`; `000` for `.env` after end-of-toggle lock). Re-running `toggle.sh` or `scripts/sync-rules.py` against those leftovers hits `PermissionError: [Errno 13] Permission denied` immediately.

**Why the stale permissions also block `mv`/`rm` of the parent folder:** The restrictive modes (`000` on `.env`, `0444` on output files) don't just block writes — they prevent the kernel from unlinking the file's dentry during a `mv` or `rm` of the **containing directory** (`adguard/work/`). macOS enforces this at the VFS layer: you own the directory, but you can't delete a directory that contains entries you can't write to. This made the entire `adguard/work/` tree unmovable/undeletable until the locked inodes inside it were replaced. `unlock-files.sh` resolves this permanently by swapping each locked inode for a fresh `0644` one via atomic rename (`cp` + `mv`), which operates on the directory entry rather than the file contents — no `chmod` called, no permission bypass needed.

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
- `toggle.sh` then went end-to-end in 48s (warp / routing-fix / adguardhome / tailscale all healthy, gateway mesh-joined, DNS hijack verified single-server).

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

### 15.10 Tor Container

#### 15.10.1 July 11, 2026: Tor Container Hardening & obfs4proxy Restoration
**Symptom:**
1. The Tor container entered a fatal crash loop upon boot, throwing `exec: "obfs4proxy": executable file not found in $PATH` when `TOR_USE_BRIDGES=true`.
2. When the user pasted Tor bridge lines containing comments (`#`) or blank lines into `tor-bridges.txt`, the container failed to validate the file properly and crashed.

**Root Cause:**
- **Bug 1 (Missing Pluggable Transports):** The Tor Dockerfile was built on `debian:bullseye-slim`, which had silently dropped or failed to resolve the `obfs4proxy` package in its latest apt repositories.
- **Bug 2 (Fragile Validation):** The `entrypoint.sh` bridge validation check merely checked `[ -s tor-bridges.txt ]` (file size > 0). It did not verify if the file actually contained valid, uncommented bridge lines. Passing empty lines or comments tricked the validation script into appending invalid `Bridge` directives to the `torrc`, causing the Tor daemon to instantly exit.

**Resolution:**
- **Upgraded Base Image:** Shifted the Tor Dockerfile base image to `debian:bookworm-slim`, restoring access to the `obfs4proxy` pluggable transport package.
- **Robust Bridge Validation:** Replaced the fragile `[ -s ]` check with a strict `grep -vE '^\s*(#|$)'` command that strips comments and empty lines. If no valid lines remain, the container safely falls back to standard public guard relays instead of crashing, ensuring Tor remains available even with a misconfigured bridge file.
- **Image Pinning:** Explicitly pinned `image: nullexit-tor:v1.0.0` in `docker-compose.yml` to prevent arbitrary local builds from drifting to `:latest`.

#### 15.10.2 July 12, 2026: Tor ControlPort Dynamic Password Authentication & User Config
**Symptom:** Querying the Tor Control Port (e.g., via the `/sweep` script or `check_circuits.py`) returned empty responses or connection errors. Logs showed that Tor automatically closed its ControlPort:
`You have a ControlPort set to accept unauthenticated connections from a non-local address. ... That's so bad that I'm closing your ControlPort for you.`

**Root Cause:** Docker port mapping (especially under Colima on macOS) requires container sockets to bind to `0.0.0.0` to be reachable from the host. However, when Tor's ControlPort is bound to `0.0.0.0` (non-local) with no authentication, Tor closes it by default as a safety precaution. Sourcing SOCKS5/ControlPort to `127.0.0.1` inside the container was not an option as it broke the Docker bridge routing path.

**Resolution:**
- **Dynamic Password Authentication**: Updated the Tor container's `entrypoint.sh` to read `TOR_PASSWORD` and dynamically generate its HMAC hash via `tor --hash-password`, adding `HashedControlPassword <hash>` to `torrc`. This secures the ControlPort on `0.0.0.0` so Tor keeps it open.
- **Unified Credentials in `.env`**: Exposed `ADGUARD_USER=admin` and `ADGUARD_PASSWORD=nullexit` in `.env` to serve as the unified gateway credentials. Sourced `TOR_PASSWORD` directly from `ADGUARD_PASSWORD` in `docker-compose.yml`.
- **Client Authentication**: Updated `scripts/check_circuits.py` to fetch `TOR_PASSWORD` (defaulting to `ADGUARD_PASSWORD` or `nullexit`) and authenticate with the ControlPort using `AUTHENTICATE "<password>"` to regain access.

> See also §11.3 (Tor Container Kill-Switch Inheritance & Fail-Closed Egress Verification) for the design-level fail-closed guarantee.

### 15.11 macOS Platform Quirks

#### 15.11.1 macOS Application Firewall Silently Blocking AirDrop & Continuity
**Problem:** Users of complex network extensions (Tailscale, LuLu, Docker, etc.) often run into an issue where AirDrop, AirPlay, and Universal Clipboard silently fail, even with the gateway inactive and Wi-Fi/Bluetooth correctly configured. The internal Apple Wireless Direct Link (`awdl0`) interface appears healthy, but connections never establish.

**Root Cause:** The built-in macOS Application Firewall has a specific list of explicitly blocked applications. Apple's own core networking services (e.g., `/usr/libexec/sharingd`, `/usr/libexec/rapportd`, `/usr/libexec/avconferenced`) can be silently added to the "Block incoming connections" list—either through accidental "Deny" clicks on permission prompts, execution of aggressive privacy-hardening scripts, or a known macOS bug that retains strict blocks even after toggling the "Block all incoming connections" setting off. Since these are background daemons, macOS provides no visible error.

**Fix:** The firewall rules must be cleared via the terminal (or System Settings > Network > Firewall > Options):
```bash
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp /usr/libexec/sharingd
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp /usr/libexec/rapportd
```
Once unblocked, `sharingd` immediately resumes broadcasting mDNS/Bonjour discovery packets, and AirDrop restores instantly without requiring a reboot.

#### 15.11.2 Standalone Tailscale Daemon Freeze after macOS Sleep/Wake
**Problem:** When the macOS host goes to sleep and wakes up, the network interfaces and routing tables are rebuilt. The standalone `tailscaled` daemon (installed via Homebrew) occasionally fails to handle this transition and becomes completely frozen/unresponsive. In this state, any command like `tailscale down` or `tailscale status` hangs indefinitely, and all DNS requests sent to the local Tailscale resolver (`100.100.21.8`) time out, causing a total internet blackout on the host.

**Fix:** Enhanced the Tailscale verification and teardown logic in `toggle.sh` and `recover.sh`:
1. **Unresponsive Daemon Detection:** Instead of assuming the daemon is healthy just because the Unix socket `/var/run/tailscaled.socket` exists, the scripts now actively run a status check with a 5-second timeout (`run_with_timeout 5 tailscale status`). If the check times out (exit code 143), the daemon is classified as unresponsive.
2. **Auto-Recovery Loop:** If the daemon is unresponsive, the script now automatically attempts to restart the service using `brew services restart tailscale` (falling back to `sudo -n brew services restart tailscale`).
3. **Graceful Retry:** Once restarted, the script pauses for 3 seconds for the daemon to initialize before proceeding with connection or teardown commands.

#### 15.11.3 macOS Sharing Services (AirDrop/AirPlay) Freeze on Network Transitions
**Problem:** When the gateway is turned on or off, the scripts perform network configuration cleanups which include flushing the routing tables (`route -n flush`), restarting the `mDNSResponder` daemon (`killall -HUP mDNSResponder`), and power-cycling the Wi-Fi interface (`setairportpower` or `ifconfig en0 down/up`). While AirDrop BLE discovery continues to function, the actual file transfers stall at "Waiting..." indefinitely.

**Root Cause:** The rapid tear-down and rebuild of the local routing table and Wi-Fi interface causes Apple's core sharing and connection daemons (`sharingd` and `rapportd`) to lose their socket bindings to the mDNS/Bonjour discovery interface. Instead of reconnecting gracefully, they enter a wedged state and try to route peer-to-peer (AWDL) IPv6/TCP transfer traffic into the default gateway (the Tailscale interface `utun`) instead of the direct wireless link, causing the TLS verification handshake to time out.

**Fix:** Integrated an automatic sharing services reset into both `toggle.sh` and `recover.sh`:
1. The script now automatically runs `sudo -n killall sharingd rapportd` at the end of both the **START** path and the **STOP** path (as well as inside `recover.sh`).
2. Killing these daemons forces macOS to immediately relaunch them, binding them fresh to the newly initialized network interfaces and routing tables, allowing AirDrop to work seamlessly while the gateway is active.

#### 15.11.4 Chrome Remote Desktop Connection Failures (Tailscale on Remote Device)
**Context:** When attempting to access a remote machine via Chrome Remote Desktop (CRD), the connection fails or hangs if Tailscale is active **on the remote device**. The connection works fine even if Tailscale (and the exit node) is active **on the local client/viewer device**, but only if Tailscale is disabled on the remote machine. *(This is distinct from the CRD-through-WARP latency limitation in §14.3.)*

**Why:** Having Tailscale active on the remote machine creates virtual network interfaces and DNS/routing modifications that conflict with Chrome Remote Desktop's WebRTC bindings and signaling traffic.

**Workaround:**
- **Use Tailscale Native RDP/RustDesk (Recommended):** Connect directly to the remote device's Tailscale IP (`100.X.Y.Z`) via an RDP or RustDesk client. This is faster and avoids third-party relay conflicts.
- **Disable Tailscale on the Remote Device:** If you must use CRD, disable Tailscale on the remote machine before connecting.

#### 15.11.5 tailscaled Daemon Broken State (brew services)
**Symptom:** `brew services list` shows `started` but `tailscale status` shows "stopped".

**Fix:** `sudo brew services restart tailscale`. Toggle script now detects and auto-restarts.

#### 15.11.6 Apple Silently Removed the `airport` Binary in macOS Sonoma 14.4 (March 2024)
**What happened:** `watcher.sh`'s `detect_lan_p2p_mode()` was written to use the `airport` CLI tool at:
```
/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport
```
This path returned `exit 127: no such file or directory`. The function silently fell back to `reason="no-wifi"` even while the Mac was actively connected to WPA2 Enterprise Wi-Fi.

**Why Apple removed it:** `airport` was never a real public binary — it lived inside a **private framework** and was always technically unsupported. Apple deprecated it quietly years ago and finally removed it in **macOS Sonoma 14.4 (March 2024)**. The removal is part of a broader privacy clampdown on Wi-Fi metadata:
- Starting in **macOS 14.5**, BSSIDs and other Wi-Fi association details are **redacted** (`<redacted>`) in most tools, including the official replacement `wdutil`
- Apple's official recommendation is to use the **CoreWLAN framework** (Swift/Objective-C) with proper entitlements — useless for a bash script
- The official CLI replacement `wdutil` requires `sudo` for most useful output — also useless for a background LaunchAgent

**Fix:** Replaced `airport -I | awk '/link auth/'` with:
```bash
system_profiler SPAirPortDataType | awk '/Current Network Information:/{found=1} found && /Security:/{print $NF; exit}'
```
This returns human-readable strings like `WPA2 Enterprise`, `WPA2 Personal`, or `None` for the currently associated network — without `sudo`, and without any removed private binary.

**Confirmed working output on this machine:**
```
P2P detect: security='Enterprise' → allow=false (reason: 802.1x-enterprise)
```

> **⚠️ Risk: `system_profiler` may not survive forever either.** `system_profiler SPAirPortDataType` still works as of macOS Sequoia (15.x) without sudo and without redaction. However, given Apple's trajectory on Wi-Fi privacy, this could be locked down in a future release. If `security` comes back empty on a future macOS version while the Mac is actively on Wi-Fi, the function will silently fall back to `allow=false` (safe default), but the detection will be broken again. The long-term fix would be a small Swift helper using CoreWLAN that we compile once and bundle in the repo. *(This forward-looking caveat is also tracked as an observation in §16.)*

#### 15.11.7 Changing macOS Local Hostname
**Context:** Users may wish to change their Mac's computer name/hostname in macOS System Settings.
**Effect:** Changing the Mac's hostname will **not** break Nullexit (which relies on internal routing/localhost). However, Tailscale will automatically detect this change and update the machine name on the Tailnet. 
- The underlying Tailscale `100.x.x.x` IPv4 address will remain exactly the same.
- The **MagicDNS name** will change to match the new hostname. Users must remember to update their SFTP/SSH clients to use the new MagicDNS address.

#### 15.11.8 Shell-Language Landmines: macOS `/bin/bash` 3.2 + `set -e` (Field Notes)

This project's lifecycle scripts (`toggle.sh`, `recover.sh`, `common.sh`, …) run under `#!/bin/bash`, which on macOS is **GNU bash 3.2.57 (2007)** — Apple has never shipped a newer bash because bash 4+ is GPLv3. (Homebrew's bash 5 lives at `/opt/homebrew/bin/bash` but is *not* the shebang target, and cannot be assumed on PATH — a bare `bash --version` on a stock Mac reports 3.2.) Every script here also runs `set -e` (exit-on-error) with an `ERR`/`INT`/`TERM`/`HUP` trap. That combination — **ancient bash + `set -e` + traps + `set -x` xtrace redirection** — is a minefield. The traps below were all hit and fixed during development; document them so they are not re-discovered.

**A. `set -e` + `if … then … else … fi` can abort at the `else` (bash 3.2 heisenbug).**
The nastiest one. A construct as innocent as:
```bash
if [ -f "$MARKER_FILE" ]; then
  X="yes"
else
  X="no"
fi
```
aborted `toggle.sh` at init under `set -e` whenever the file was **absent** — the false status of the `[ -f … ]` test leaked through the compound and `set -e` killed the script (`EXIT: code=1 phase=init`), before any real work ran. Two things made this vicious: (1) it is intermittent/context-dependent — it did **not** reproduce in isolated `bash -c '…'` snippets of the identical block; it only manifested inside the full script with the `set -x` xtrace fd-redirect (`exec 2> >(tee …)`) active. We only proved causation by **bisecting the live script** (replace the block with a trivial assignment → the script sailed past init). (2) Static tools (`bash -n`, `shellcheck`) cannot see it — it is a runtime interaction. **Safe pattern:** default-assign, then an `if` with **no `else`** (an `if` whose false condition has no else-branch yields status 0):
```bash
X="no"
if [ -f "$MARKER_FILE" ]; then X="yes"; fi
```
**Confirmed root cause (2026-07-13, reproduced head-to-head).** The trigger is specifically **`set -x` plus a `PS4` that contains a command substitution** — here the `DEBUG_TRACE` prompt `PS4='+ [$(date …)] …'`. Forcing the false-condition/else path (`gateway_state` → `stopped`, so `if [ "$(gateway_state)" = "running" ]` takes the else/START branch) on stock `/bin/bash` 3.2.57: with the **default `PS4`** it survives (3/3, exit 0); with toggle's **`$(date)` `PS4`** the `ERR` trap fires on the else branch (`rc=1` from the false condition, 3/3, exit 42). The `$(date)` runs a subshell on *every* traced command; while tracing the `if`-condition it perturbs `$?` so the condition's non-zero status leaks past the normal `if`-exemption and trips the `ERR` trap. This is a true **heisenbug** — enabling tracing (`DEBUG_TRACE=true`) is what *causes* the abort, which is exactly why it's invisible with `DEBUG_TRACE=false` (the default) and why every isolated repro on the *default* `PS4` passes (this misled an entire debugging session into briefly "disproving" the landmine). It aborted the gateway START decision (`toggle.sh:689`) under `DEBUG_TRACE=true`; with `DEBUG_TRACE=false` the gateway starts cleanly (verified: 192 s, all five containers healthy). **Fixed (2026-07-14).** `DEBUG_TRACE`'s `PS4` now uses the subshell-free `${SECONDS}` (elapsed seconds since the shell started) instead of `$(date "+%H:%M:%S")`, removing the per-traced-command subshell that perturbed `$?`. bash 3.2 has no subshell-free *wall-clock* token for `PS4` (`$EPOCHSECONDS` is 5.0+, `printf '%(…)T'` is 4.2+), so the per-line stamp is now elapsed-seconds — the absolute start time is still logged once in the `DEBUG_TRACE enabled …` header line, so wall-clock is recoverable. Bonus: this also drops a `date` fork on *every* traced line (previously thousands). **Verified head-to-head on stock `/bin/bash` 3.2.57:** `toggle.sh --restart` with `DEBUG_TRACE=true` now completes `code=0` with tracing active straight through the exact decision that aborted before — the trace shows `gateway_state → stopped` (`common.sh:229`) feeding the false `if [ "$(gateway_state)" = "running" ]`, then the else branch reaching `Action: STARTUP GATEWAY` (1436 traced lines, no `ERR` trap firing, all five containers healthy). `DEBUG_TRACE` is now safe to use on the STOP/START decision path.

More generally, any command whose "failure" is normal control flow (`grep -q`, `[ … ]`, `diff`, `kill -0`) that ends up as the *last* command of a function/branch/script under `set -e` is a landmine; guard it (`|| true`) or restructure so a non-zero status can't be the tail value.

**B. `BASH_XTRACEFD` and the `exec {var}>>file` dynamic-fd form are bash 4.1+ (hard-fail on 3.2).**
Our `DEBUG_TRACE` feature wants xtrace (`set -x`) sent to `output.log` while keeping the terminal clean — the clean way is `exec {BASH_XTRACEFD}>>"$LOG_FILE"`. On 3.2 this is a **syntax/runtime error**: `exec: {BASH_XTRACEFD}: not found` (dynamic-fd allocation `{var}>>` didn't exist until 4.1, and `BASH_XTRACEFD` itself is 4.1+; on 3.2 it's just an ordinary variable that `set -x` ignores). Left unguarded it would abort the script at startup — i.e. the debug feature would break the very thing it's meant to observe. **Safe pattern:** branch on `${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}` — on ≥4.1 use `exec 9>>"$LOG_FILE"; export BASH_XTRACEFD=9`; on 3.2 fall back to `exec 2> >(tee -a "$LOG_FILE" >&2)` (xtrace goes to stderr, which we duplicate to the log; the terminal also shows it, which is acceptable). Never use the `exec {var}>>` form unless you *know* you're on ≥4.1.

**C. `trap … ERR` + `$LINENO` misattributes the failing line on 3.2.**
When a command fails under `set -e`, our trap runs `cleanup_handler ERR $LINENO`. On bash 3.2, `$LINENO` inside an `ERR` trap frequently reports the line of the **enclosing `fi`/closing brace of a compound statement**, not the true failing line. During the STOP/START-decision bug this produced `Script failed at line 1202` where 1202 is a bare `fi` — actively misleading. **Mitigation:** don't trust the trap's line number as gospel on macOS; corroborate with the `EXEC:`/`EXIT:` lifecycle breadcrumbs and the `DEBUG_TRACE` xtrace (which prints `file:line:function` via a custom `PS4`), which pin the *actual* last-executed command.

**D. `set -e` is not inherited by command substitutions / subshells the way people expect, and is suppressed inside `if`/`&&`/`||` conditions.**
This cuts both ways and is a frequent source of "why didn't it fail?" and "why *did* it fail?": a non-zero command used as an `if` condition (or left/right of `&&`/`||`) is *exempt* from `set -e` (by design), but the moment that same call is a bare statement it aborts. `is_gateway_active()` relies on this (it's always called as `if is_gateway_active; then …`), which is precisely why moving the decision to a marker file — instead of a probe that must be `if`-guarded to be safe — is more robust (see §15.12.19). Also note `local X=$(cmd)` masks `cmd`'s exit status (the `local` builtin's status wins) — a `shellcheck` SC2155 we see repeatedly; harmless when we don't check `$?`, but a real footgun if you do.

**E. Process substitution (`>(…)`, `<(…)`) is a bashism, and its lifecycle is loose.**
Our 3.2 xtrace fallback (`exec 2> >(tee -a "$LOG_FILE" >&2)`) uses process substitution — fine under bash, but (1) it is **not** POSIX `sh`, so these scripts must never be invoked as `sh script.sh`; and (2) the background `tee` it spawns is reaped asynchronously, so the very last few lines written just before exit can occasionally be truncated in the log. Acceptable for a debug trace; do not rely on it for critical last-gasp logging (use a direct `>> "$LOG_FILE"` append for must-capture lines, as the `EXIT` breadcrumb does).

**F. GNU-vs-BSD userland divergence (not bash itself, but same class of pain).**
macOS ships BSD variants of the core tools, so idioms differ from Linux: `sed -i ''` (BSD requires the empty backup-suffix arg) vs `sed -i` (GNU); `stat -f%z` (BSD) vs `stat -c%s` (GNU); `date` format flags; `jot` (BSD) vs `shuf` (GNU) for random port generation; `route`/`networksetup`/`dscacheutil` (macOS-only) vs `ip`/`resolvectl` (Linux). This is *why* the codebase branches on `[[ "$OSTYPE" == "darwin"* ]]` everywhere — `toggle.sh` and `recover.sh` are each single cross-platform scripts that dispatch on `$OSTYPE` (an early Linux block runs and exits before the macOS body). `timeout(1)` doesn't exist on stock macOS at all — hence the pure-bash `run_with_timeout` in `common.sh`.

**Working rules distilled from the above:**
- Assume **bash 3.2** semantics for anything under `#!/bin/bash` on macOS; gate any 4.0+ feature (`BASH_XTRACEFD`, dynamic `{var}` fds, associative arrays, `${var^^}` case-conversion, `mapfile`/`readarray`, negative array indices) behind a `BASH_VERSINFO` check or avoid it.
- Under `set -e`, never let a "benign non-zero" command (`[ … ]`, `grep -q`, `kill -0`, `diff`) be the tail statement of a branch/function/script; use no-`else` `if`s, `|| true`, or explicit `$?` handling.
- Prefer **persisted state (marker files)** over **live probes** for control-flow decisions — a probe forces an `if`-guard and can hang/abort; a file read cannot (see §15.12.19).
- `bash -n` and `shellcheck` catch syntax and many smells but **cannot** catch `set -e`/trap runtime interactions — a **live run is mandatory** to validate lifecycle-script changes; the `DEBUG_TRACE` + breadcrumb instrumentation exists precisely to make those live runs diagnosable.
- Never run these scripts as `sh` — they are bashisms end to end.

### 15.12 Misc Resolved

#### 15.12.1 Gluetun Resets nftables FORWARD Rules
**Symptom:** FORWARD RELATED,ESTABLISHED rule disappears after Gluetun health check.

**Fix:** `scripts/routing-fix.sh` re-adds to both iptables backends every 30 seconds. Legacy backend (policy ACCEPT) acts as safety net.

#### 15.12.2 Native SSH & SFTP Security (Zero Local Attack Surface)
**Context:** macOS "Remote Login" (`sshd`) and "File Sharing" (`smbd`) open ports on the local network (e.g. `172.x.x.x`), exposing the host to brute-force attacks on public Wi-Fi.

**Implementation:** The script strictly enforces `tailscale up --ssh=true` whenever the mesh state is reset. This empowers the user to completely disable native macOS Remote Login and File Sharing. This provides an incredible zero-trust security advantage: even if an attacker steals your Mac username and password, they **cannot** access your files remotely. Disabling the native services completely closes the listening ports on the local Wi-Fi interface (`172.x.x.x`), rendering the Mac inaccessible to local network logins. Meanwhile, Tailscale intercepts port 22 traffic exclusively over the encrypted mesh and authenticates cryptographically based on your Tailscale SSO identity. Stolen Mac passwords are mathematically useless without first bypassing your Tailscale Two-Factor Authentication and registering a device onto the mesh.

**Cross-Platform File Exchange:** To easily browse and exchange files securely, simply use an SFTP client and connect to your Mac's MagicDNS name on port 22. Recommended clients: **WinSCP** or **FileZilla** (Windows), **Cyberduck** (macOS), and **FE File Explorer** or **Solid Explorer** (iOS/Android).

#### 15.12.3 Logging Architecture
For debugging, logs are strictly segmented based on the component's lifecycle:
- **`output.log` (Host-side):** Contains all standard error (`stderr`) and verbose output from the host scripts (`toggle.sh`, `recover.sh`, `setup.sh`). Since the `rule-compiler` container is ephemeral and deleted after running, its logs (and any Python errors from `scripts/sync-rules.py`) are extracted and appended to this file before deletion.
  - **Log Rotation Policy:** On startup, `toggle.sh` checks if `output.log` exceeds **1GB** (`1,073,741,824` bytes). If it does, it performs a metadata-only rename (`mv output.log output.log.old`), preserving history while resetting the active log to 0 bytes. This rename-based rotation avoids the heavy disk I/O and CPU overhead of rewriting a massive file line-by-line. The threshold is intentionally large because with `DEBUG_TRACE=true` the log accumulates a full command-by-command execution trace (effectively the framework's entire compilation/warning history), which is valuable to retain for post-mortems; a smaller cap would rotate that history away too quickly.
  - **Egress Probe Logging:** The background host-egress leak prober checks if stdout is a TTY (`[ -t 1 ]`) and will only print live status updates (using carriage return `\r`) or duplicate console warnings in interactive mode. It automatically detects macOS/BSD vs. Linux environments to dynamically construct timestamps with date and time (omitting milliseconds on macOS to prevent high CPU utilization from spawning sub-second processes).
- **`docker logs <container>` (Guest-side):** The persistent containers (`warp`, `tailscale`, `routing-fix`, `adguardhome`) use the Docker `json-file` logging driver with a strict `max-size` (1m-10m) to prevent VM disk exhaustion. Use standard `docker logs` to view them.

#### 15.12.4 Pre-Flight Check 1: Wrong `tailscale ping` Flag
**Problem:** Check 1 of the pre-flight connectivity checks used `--c 1` (double dash) but `tailscale ping` accepts `-c 1` (single dash). The invalid flag caused the command to exit with code 1, marking the check as FAIL even though the gateway was reachable.

**Fix:** Changed `--c 1` to `-c 1`.

#### 15.12.5 Pre-Flight Check 1: DERP Relay Exit Code
**Problem:** Even with the correct `-c 1` flag, `tailscale ping` exits with code 1 when the connection goes through a DERP relay (`direct connection not established`) — even though a pong was successfully received (28ms via DERP(tor)). The check treated relayed connections as failures.

**Fix:** Changed the check from relying on exit code to piping stdout through `grep -q "pong"`. This accepts relayed connections as valid (they work fine for the exit node use case), while still failing on true timeouts or unreachable peers.

#### 15.12.6 IPv6 Exit-Node Leak
**Problem:** Tailscale supports IPv6, but WARP/gluetun is IPv4-only. IPv6 packets forwarded through the exit node would leak through the Docker bridge unencrypted.

**Fix:** Added `ip6tables -A FORWARD -i tailscale0 -j DROP` to `post-rules.txt`, blocking all IPv6 forwarded traffic from the Tailscale interface. *(This is the fix referenced by the IPv6-leak scenario in §15.6.1.)*

#### 15.12.7 SOCKS5 Proxy Threading Race Condition
**Problem:** The `forward` function in `scripts/socks5-proxy.py` called `select.select([src, dst], [], [])` which raised `ValueError: file descriptor cannot be a negative integer (-1)` when one thread closed a socket while the other thread was selecting on it.

**Fix:** Added `ValueError` exception handling around `select.select()` and `recv()` calls. When a file descriptor becomes negative, the thread breaks out of the forwarding loop cleanly instead of crashing.

#### 15.12.8 Docker Healthcheck: Multi-line Python in CMD Array
**Problem:** The socks-proxy healthcheck used a `CMD` array with a multi-line Python string. YAML collapsed the newlines, causing the `#` comment to comment out the rest of the code and the `assert` statement to be mangled into `as`.

**Fix:** Changed from `["CMD", "python3", "-c", "..."]` to `["CMD-SHELL", "python3 -c '...'"]` with a single-line Python expression. Uses a real SOCKS5 handshake (sends `[5, 1, 0]`, expects `[5, 0]`) instead of a simple TCP port check.

#### 15.12.9 Graceful Shutdowns Leave DNS Hijacked
**Problem:** The gateway overrides the macOS host's DNS settings (via `networksetup`) to route queries to the AdGuard container. Because macOS persists `networksetup` changes to disk, shutting down the Mac while the gateway is running causes the Mac to boot up later with hijacked DNS. Since the Colima VM and Docker containers don't auto-start on boot, the user would have no internet access until they manually run the toggle script.

**Root Cause:** The `toggle.sh` script exits after the gateway starts. There was no background daemon listening for macOS system shutdown signals to revert the network settings.

**Fix:** Wrapped the background `caffeinate` process (used to prevent system sleep) in a bash `trap` command. The trap listens for `SIGTERM`, `SIGINT`, and `SIGHUP`. When the user initiates a graceful shutdown, macOS sends `SIGTERM` to the background trap, which instantly executes `recover.sh` to flush the host DNS back to `1.1.1.1` right before the machine powers off.
*Note:* We explicitly use `recover.sh` instead of `toggle.sh` because during a shutdown, the OS limits process cleanup time and is already independently sending termination signals to Docker and Colima. Trying to run `docker compose down` inside a shutdown trap creates a race condition that can hang the script until macOS forcefully `SIGKILL`s it. `recover.sh` abandons container management and surgically flushes the macOS network settings in milliseconds, guaranteeing completion before the OS pulls the plug.

#### 15.12.10 Linux Native Wi-Fi Bouncing
**Problem:** The generated `scripts/recover-linux.sh` incorrectly retained the macOS `networksetup` commands, which would crash and fail to bounce Wi-Fi on Linux hosts.

**Fix:** Swapped the macOS logic for native Linux commands. The script now attempts `nmcli radio wifi off/on` first, and gracefully falls back to `ip link set wl... down/up` if NetworkManager is unavailable.

#### 15.12.11 TS_AUTH_ONCE Cloud Footgun & Ephemeral Keys
**Decision:** The compose file uses `TS_AUTH_ONCE=true` to prevent authentication loops. However, on headless cloud VPS deployments, if a standard auth key expires (usually 90 days), the container will silently drop off the mesh. We documented this trade-off explicitly in `docker-compose.yml` and recommended the use of **Tailscale Ephemeral Keys** for cloud deployments, which automatically clean themselves up and bypass this issue.

#### 15.12.12 Hardcoded AdGuard Credentials
**Decision:** AdGuard is deployed with the hardcoded credentials `admin / nullexit`. This is perfectly safe behind a NAT on a local macOS laptop. However, if deployed on a cloud host with exposed ports, this becomes a severe security risk. We added a stark warning comment in `docker-compose.yml` to ensure cloud users change this before deployment.

#### 15.12.13 Routing Fix: 30-second polling vs Netlink Socket
**Decision:** Instead of building a complex Netlink socket listener (`ip monitor`) to react instantly to iptables and routing flushes from Gluetun, we retained the 5-second `sleep` loop in `scripts/routing-fix.sh`. 
- **Reasoning:** Building a netlink listener in pure bash on Alpine is incredibly brittle and complex (especially for iptables events). The 30-second polling loop is bulletproof. The only trade-off is a potential 1-4 second stutter if Gluetun reconnects, which was deemed an acceptable edge case for absolute reliability.

#### 15.12.14 Cache Poisoning and URL Rot in scripts/sync-rules.py
**Problem:** If a remote blocklist URL went permanently offline (404 Not Found), the Python `urllib` request would return the 404 HTML string. The script would aggressively regex-parse this HTML, find no domains, and overwrite the healthy local cache with a 0-domain file. This effectively disabled ad-blocking until the URL was fixed.

**Fix:** Implemented a defensive programming sanity check in `scripts/sync-rules.py`. Before overwriting the cache, the script now verifies that the compiled domain count is greater than 10 (and 1 for IP feeds). If it falls below this threshold (indicating a catastrophic 404 failure across multiple URLs), it aborts the cache overwrite, raises a `ValueError`, and keeps the previous day's healthy cache intact.

#### 15.12.15 Gluetun nf_tables Parser Crash (Bash Interpolation Failure)
**Problem:** Attempting to make the TCP MSS dynamically configurable by using a standard bash variable inside `post-rules.txt` (`iptables ... --set-mss ${GATEWAY_MSS:-1120}`) caused the Gluetun container to catastrophically crash during startup. Gluetun's internal parser executes `post-rules.txt` line by line without a shell, meaning the variable was never expanded. It literally attempted to inject the string `${GATEWAY_MSS:-1120}` into iptables, resulting in a fatal `bad value for option "--set-mss"` error.

**Fix:** Removed the bash variable from `post-rules.txt` and reverted it to a pure hardcoded integer. To retain dynamic `.env` configuration, we moved the interpolation logic to `toggle.sh`. Right before Docker starts, the host script parses `GATEWAY_MSS` from the `.env` file and uses a cross-platform `sed` command to dynamically overwrite the integer directly inside `post-rules.txt`. This perfectly mimics manual configuration and completely bypasses Gluetun's strict parser.

#### 15.12.16 AdGuard Filter Redundancy & Memory Optimization
**Problem:** AdGuard Home does not perform cross-list deduplication in memory. When it loads its own native subscription filters (e.g., `AdGuard DNS filter`) alongside our massive `compiled_rules.txt`, overlapping rules are loaded twice, wasting significant RAM in the Colima VM. The UI would show ~500k rules, representing the sum of all lists rather than unique domains.

**Fix:** Updated `scripts/sync-rules.py` to intelligently cross-reference AdGuard's configuration and deduplicate our list against it.
1. The script now reads `adguard/conf/AdGuardHome.yaml` to dynamically fetch the exact URLs of any enabled native AdGuard filters.
2. The parsing engine was upgraded to normalize basic AdGuard syntax (`||domain^`) back into raw base domains during the build process.
3. The script subtracts the native AdGuard domains from our custom blocklist *before* compiling, immediately purging ~83,000 completely redundant rules. 
4. The normalized base domains then pass through our subdomain optimizer, which squashes an additional ~50% of the remaining rules.

This reduces the final compiled output from ~325k to ~281k rules on the `heavy` profile, saving ~45k rules from being loaded into memory twice and reducing the overall RAM footprint of the `adguardhome` container.

#### 15.12.17 Kernel-Level IP Blocklist (Threat Intelligence Firewall)
**Problem:** DNS sinkholing cannot stop malware or botnets that bypass DNS entirely by hardcoding direct IP addresses (a common technique for C2 communication). These connections pass straight through AdGuard unseen.

**Fix:** Added a second compilation pipeline to `scripts/sync-rules.py` that runs on every startup alongside the DNS pipeline.
1. The compiler concurrently fetches four curated threat-intelligence feeds: **Feodo Tracker** (abuse.ch — botnet C2 IPs), **Spamhaus DROP** (IPs allocated to criminal organizations), **Emerging Threats** (Proofpoint — active C2 and scanners), and **CINS** (active brute-force sources).
2. All entries are normalized via Python's `ipaddress` module. Any IP or CIDR that overlaps with RFC1918 private ranges, loopback, link-local, or the Tailscale CGNAT range (`100.64.0.0/10`) is stripped to prevent accidentally locking users out of their own LAN or mesh.
3. The cleaned list (16,721 unique IPs/CIDRs) is written as an `ipset restore` file using an **atomic swap pattern**: `create_new → populate → swap with live → destroy_new`. This guarantees the live `block_malicious` ipset is never empty during a reload.
4. `scripts/routing-fix.sh` watches the file's mtime every 30 seconds. On change it runs `ipset restore` and idempotently re-injects `FORWARD DROP` rules for both `src` and `dst` into both iptables backends (nftables + legacy).
5. `docker-compose.yml` mounts `adguard/work/userfilters/` into `routing-fix` as `/userfilters:ro` and adds `rule-compiler: service_completed_successfully` to its `depends_on`, eliminating the race condition where routing-fix could start before the file existed.

**Memory cost:** The entire 16,721-entry ipset costs only ~1.6 MiB of kernel memory — negligible in the 600MB VM budget.

#### 15.12.18 Incident Post-Mortem: Discarded Docker Exec Errors in logs (July 10, 2026)
**Symptom:** When the `warp` container is stopped, dead, or failing to connect to its endpoints, the `toggle.sh` and `recover.sh` connectivity health checks fail, but no details are printed to `output.log`. The logs only show generic `FAIL` outputs, making it hard to see if the failure was a network timeout, Docker daemon error, or a missing binary.

**Root Cause:** Overly broad error silencing. The `docker compose exec` commands in the health checks (Check 3 in `toggle.sh` and the traffic check in `recover.sh`) both redirected stderr to `/dev/null` (`&>/dev/null` and `2>/dev/null` respectively), completely throwing away any diagnostic error messages produced by Docker or `wget`.

**Fix (July 10, 2026):** Redirected stderr of the `docker compose exec` check commands to `output.log` (`2>> output.log`). This ensures that any command execution failures or connection timeout details are logged.

#### 15.12.19 Incident Post-Mortem: Toggle Decided STOP/START From a Live Probe, Aborting When Docker Was Down (July 13, 2026)
**Symptom:** Running `./toggle.sh` (or `--restart`) while the Colima VM / Docker daemon was **not** running caused the script to hang for ~15 seconds and then abort during the START phase without ever booting Colima. With `DEBUG_TRACE` the lifecycle breadcrumb showed `toggle.sh EXIT: code=1 phase=start`, and the trace showed execution jumping straight from the START-branch entry to the `ERR` trap (`cleanup_handler ERR`) with the START body never executing. Historically this silent failure occurred 57× in `output.log`. Spam-clicking the toggle during the resulting window (each retry rejected by the lock guard, then finally succeeding) is what produced the earlier "pile of stacked toggle processes" and Wi-Fi-bounce confusion.

**Root Cause:** `toggle.sh` decided whether to STOP or START by calling `is_gateway_active()` (`scripts/common.sh`), which **live-probes** the running system — its first step is `run_with_timeout 15 docker compose ps --status running`. When `/var/run/docker.sock` is absent (Colima down), that call blocks for the full 15 s timeout and returns non-zero. Combined with the script's global `set -e` and `ERR` trap, a non-zero result evaluated at the `if is_gateway_active; then … else … fi` boundary aborted the whole script *before* the `else` (START) branch body ran — precisely the branch whose job is to start Colima. Design-wise the deeper flaw is that a **disable** should not depend on whether the gateway is *currently* healthy; it should act on whether the gateway is *supposed* to be running (persisted intent). The correct signal already existed — `MARKER_FILE=/tmp/nullexit-gateway-active.marker`, written at the end of a successful START and cleared on STOP — but `toggle.sh` only wrote/cleared it and never read it for this decision. **Note:** this was a long-standing latent bug, not a regression from the July 2026 `common.sh` platform-function unification or the `DEBUG_TRACE` work; those changes only made the previously-silent abort *visible* (via the `EXEC:`/`EXIT:` breadcrumbs and xtrace).

**Fix (July 13, 2026):** Introduced `gateway_should_be_running()` in `common.sh` and routed all four decision sites through it (`toggle.sh` main decision + `--restart` pre-check; `scripts/toggle-linux.sh` main decision + `--restart` pre-check). It decides from persisted intent:
1. `toggle.sh` captures the marker's existence into `GATEWAY_MARKER_AT_STARTUP` **before** the top-of-script "defensive stale-marker clear" wipes it, and the helper honors that captured value (falling back to the live marker file for callers that run before the clear, e.g. the `--restart` pre-check).
2. Marker present → STOP path; marker absent → START path. This is instant and cannot hang or abort.
3. Only when the marker is absent **and** the Docker socket is actually reachable (`/var/run/docker.sock` or `~/.colima/default/docker.sock` on macOS) does it consult `is_gateway_active` as a non-fatal reconciliation fallback (covers a marker lost to a `/tmp` wipe while containers are genuinely up). A dead socket short-circuits to "stopped" with no probe, so `set -e` can never be tripped.
4. The STOP path's `docker compose down` is now `|| true`-guarded so a disable always completes even with Docker down; the START path's `docker compose up` is deliberately left unguarded (a failed start *should* trigger cleanup). On Linux the marker isn't maintained, so the helper degrades to the `is_gateway_active` fallback — fast there because native Docker has no Colima VM to hang.

**How we got here (methodology note).** This one is worth recording because the *process* mattered as much as the patch. The failure had been happening silently for a long time — the log simply ended after a teardown with no error, so there was nothing to chase. We first attacked the **observability gap** rather than guessing at the cause: we wrapped the heavyweight lifecycle commands (`colima start`, `docker compose up/down`) so their output and exit codes always land in `output.log`, added an `EXIT: code=… phase=…` breadcrumb that fires even when the process is killed, and put a full opt-in xtrace behind `DEBUG_TRACE`. Only *then* did we reproduce the failure — and this time the trace said, unambiguously, `EXIT: code=1 phase=start` with the START body never entered. The instrumentation didn't fix anything, but it converted an invisible abort into a precise, reproducible fact. (Lesson, consistent with §15.12.18 and the LUKS post-mortem referenced in §15.11: **a mechanism that fails silently is worse than one that fails loudly** — so we make it fail loudly first.)

The root-cause leap, though, came from a **design-smell intuition, not the stack trace**: the observation that it is nonsensical for a *disable* to first check whether the gateway is *currently online* — a teardown should act on whether the gateway is *supposed* to be running, not probe a subsystem to find out. That instinct turned out to name the bug exactly. The smell was a **conflated responsibility with an inverted dependency**: to decide whether to *start* the gateway, the code first had to *talk to* the gateway (via Docker) — the very thing START is responsible for bringing up — so the check was guaranteed to be unavailable in precisely the cold-start case that mattered. A second tell was **false symmetry**: enable (builds state) and disable (tears it down) are not symmetric operations, yet both ran the identical expensive probe; whenever two operations that should differ share suspiciously identical machinery, the code is usually lying about the structure of the problem, and reality eventually calls the bluff. The fix invented nothing — the honest signal (`MARKER_FILE`, literally "the gateway is supposed to be up") already existed and was maintained in all the right places; it was simply never consulted for the decision it was made for. We just pointed the decision at the answer the codebase already knew. General principle worth keeping: **design smells here are load-bearing — they tend to *be* latent bugs, not merely cosmetic**, and are worth chasing on intuition even before a trace confirms them.

**Acceptance verified (static + live):** with marker present → STOP (instant, even with Docker down); with marker absent + Docker down → START (0 s, no `set -e` abort); a real run now proceeds past init to the gateway-status decision. `bash -n` clean on all three scripts; no new `shellcheck` findings; re-signed `.signatures` (`toggle.sh`/`common.sh`/`toggle-linux.sh` are in the signed set) and `crypto.sh --verify` exits 0.

**Follow-up (same day) — a `set -e` regression the fix introduced, and why only a live run caught it.** The first cut of the marker capture wrote the intent as a full `if [ -f "$MARKER_FILE" ]; then GATEWAY_MARKER_AT_STARTUP="yes"; else GATEWAY_MARKER_AT_STARTUP="no"; fi`. On macOS `/bin/bash` 3.2, with `set -e` active and the `DEBUG_TRACE` xtrace redirect (`exec 2> >(tee …)`) in effect, that construct **aborted the script at init** the moment the marker was absent — the false `[ -f ]` status leaked through the compound and `set -e` killed the run (`EXIT: code=1 phase=init`), before the gateway logic ran at all. Notably this did **not** reproduce in isolated `bash -c` snippets of the same block — it only surfaced in the script's real runtime context — so we had to bisect against the actual `toggle.sh` (swap the block for a trivial assignment → the script sailed past init) to prove causation. Fix: write it as a default assignment plus an `if` **without an `else`** (`GATEWAY_MARKER_AT_STARTUP="no"` then `if [ -f "$MARKER_FILE" ]; then GATEWAY_MARKER_AT_STARTUP="yes"; fi`), which yields status 0 when the condition is false. Lesson reinforced: `set -e` on legacy bash is genuinely treacherous around conditionals, and the observability work paid for itself again — the breadcrumb pinned the abort to init instantly, and a live run (not static checks) was the only thing that exposed a heisenbug invisible to isolated reproduction.

#### 15.12.20 Honey-Port Tripwire Accumulation (July 14, 2026)
**Symptom:** After many toggle-ons, `ps` showed a pile of idle `bash ./toggle.sh` subshells, each blocked on an `nc -l localhost <port>` listener — one leaked per toggle-on, never reaped.

**Root Cause:** The Honey-Port Tripwire arms a fresh random port each START via a disowned `( nc -l … ) &` subshell. `nc -l` blocks until a connection that (by design) almost never comes, so each toggle-on leaks one idle listener; because the port is random, successive listeners never collide and simply stack up over time.

**Fix:** `toggle.sh` now reaps the previous tripwire before arming a new one — `pkill -f "nc -l localhost"` (macOS) / `pkill -f "nc -l .*127.0.0.1"` + `"nc -l localhost"` (Linux) — immediately before `HONEY_PORT=$(get_free_port)` at both arming sites. No `sudo` needed (the listeners are user-owned). Net effect: at most one tripwire alive at a time instead of one per toggle. (The same `pkill` pattern cleared the backlog that this session's ~15 test toggles produced.)

#### 15.12.21 Post-Wake Self-Feedback Loop: The Watcher Re-Fires On The Route Change It Caused (July 14, 2026)
**Symptom:** After a container restart (or wake), `output.log` showed `recover.sh --post-wake` launching ~6 times in a row, one launch roughly every ~40s, each exiting `exit=0` — recovery *worked* every time yet kept re-firing "until it worked." Every launch was triggered by `NET: … changedKey State:/Network/Global/IPv4`.

**Root Cause — a self-feedback loop, NOT PF.** `scripts/watcher.sh` Listener 2 watches `State:/Network/Global/IPv4` via `scutil n.watch` and launches `recover.sh --post-wake` on any change. But post-wake re-asserts the exit node (`recover.sh` ~L367, `tailscale set --exit-node`), and even though `set` is deliberately used instead of `--reset` to minimise churn (recover.sh ~L360-366), **re-asserting the exit node re-writes the host default route — and the default route IS `State:/Network/Global/IPv4`.** So each run mutates the exact key the watcher triggers on. The self-triggered change lands ~15-45s after the run finishes; `run_recover()`'s old 10s debounce (reset to the run's *finish* time at the tail of the function) had long expired by then, so the watcher re-fired. The loop self-terminates only once `tailscale set` becomes a no-op (route already correct) → no route change → no re-trigger.

**Why the debounce couldn't stop it:** the loop period (~40s = one full post-wake run + settle) far exceeds the 10s debounce, which therefore only ever caught macOS's rapid *duplicate* scutil notifications for a single change (the `+0.2s` doublets), not the self-trigger.

**Not PF:** post-wake never calls `pfctl` (the kill-switch is armed once, in `scripts/common.sh`, not per cycle); no PF-enable line falls inside the loop window. The `No ALTQ support in kernel` warning is normal macOS pfctl noise (Apple ships pfctl without ALTQ compiled in), and `Could not capture PF reference token` is a separate benign ref-count bookkeeping wart — both unrelated to the loop.

**Fix:** `scripts/watcher.sh` `run_recover()` now arms a **post-recovery settle cooldown** (`/tmp/nullexit-watcher.settle-until`, `NULLEXIT_POSTWAKE_SETTLE_SECONDS` default 45s) *after* each post-wake run, and skips launching while `now < settle-until`. Because it is armed only after a recovery runs, a genuine first wake/roam is still handled immediately; only the Global/IPv4 change the run caused itself is absorbed. A real new roam during the window is delayed at most `POSTWAKE_SETTLE_SECONDS`, an acceptable trade for killing the loop. Watcher-side only — `recover.sh` is unchanged. Severity was low (self-correcting, healthy every iteration, no leak/outage; cost was wasted ~28s runs + log noise).

#### 15.12.22 FaceTime (and Real-Time P2P Media) Over the Double-Tunnel: Why It Breaks + the Split-Route Plan (July 15, 2026)
**Symptom:** A FaceTime call placed while nullexit is up fails to connect.

**Diagnosis — nullexit is NOT blocking it; every layer passes the traffic (all verified live):**
- **DNS:** no Apple/FaceTime domain is sinkholed — `dig` via the gateway (`100.100.21.8`) returns real Apple A/CNAME records, none `0.0.0.0`/`127.0.0.1`. The `<no answer>` domains (`gateway.push.apple.com`, `fmn.apple.com`, `identityservices.apple.com`, `fdr.apple.com`) return empty on `1.1.1.1` too — CNAME/non-A, not our block.
- **routing-fix `FORWARD`:** the exit-path rule `-i tailscale0 -o tun0 -j ACCEPT` carries ~203K pkts / 73M bytes and accepts *everything*.
- **Country / threat blocklists** (`block_il`, `block_kp`, `block_malicious`): **0** packets dropped.
- **WARP (gluetun) egress:** `-A OUTPUT -o tun0 -j ACCEPT` + `-A POSTROUTING -o tun0 -j MASQUERADE` — all outbound UDP (any port) leaves and is SNAT'd through WARP.

**Root cause — double symmetric NAT ending at Cloudflare WARP.** Path: `host → Tailscale (MASQUERADE) → WARP (MASQUERADE) → Cloudflare shared egress`. WARP is a CGNAT-style shared egress with **no inbound UDP mappings**, and the double-MASQUERADE presents as **symmetric NAT** — the exact condition that defeats FaceTime's STUN/ICE UDP hole-punching. No P2P path can form; the Apple-relay fallback is unreliable through the stacked tunnel, and the 1280→1200 MTU squeeze degrades media. This is inherent to routing real-time P2P media through WARP, **not** a firewall rule. (Zoom/WhatsApp *calls* hit the same wall.)

**Latent finding (separate bug, NOT yet fixed):** the `FORWARD` chain's `-i tailscale0 -p udp --dport 443` (QUIC) and `--dport 853` (DoT) `REJECT` rules are **shadowed** by the earlier `-i tailscale0 -o tun0 -j ACCEPT` (first-match wins) — verified **0 pkts** on each. So the intended QUIC-block / force-through-AdGuard (block DoT) on the exit path is **not enforced**: a mesh client can use DoT (853) to bypass AdGuard filtering entirely. To actually enforce, those port-`REJECT` rules must be inserted **before** the `tailscale0 → tun0` ACCEPT (or scoped `-o tun0`). **TODO.**

**Fix plan (chosen: Option 2 — narrow, always-on, opt-in split-route). DESIGNED / STAGED, not yet implemented in code:**
- **Mechanism:** add more-specific host routes for FaceTime's Apple `/16`s via the **physical** gateway (`172.17.0.1`/`en0`). Longest-prefix match beats Tailscale's exit-node `0.0.0.0/1` + `128.0.0.0/1` routes, so only those `/16`s leave **direct** while everything else stays double-tunneled. Mirrors `add_warp_bypass_routes`.
- **Wiring:** `add_apple_split_routes()` / `remove_apple_split_routes()` in `common.sh`; called in toggle START (after exit-node assert) + `recover.sh --post-wake` (survives roam) + removed on STOP; guarded by an **opt-in `.env` flag (default OFF)** so the privacy posture is unchanged unless enabled.
- **Privacy tradeoff:** whatever `/16`s go direct see the **real ISP IP** (not WARP). Apple already ties traffic to the Apple ID, so Apple-direct is the accepted scope; user chose **narrow** (FaceTime-infra `/16`s only) over all-`17.0.0.0/8` to minimise the surface.
- **CIDR list — to be finalised from an empirical capture (PENDING, deferred at user request):** host-side `sudo tcpdump -n -i <exit-utun, e.g. utun6> net 17.0.0.0/8` during a real call, then extract distinct `/16`s. Known-likely from DNS today: `17.57/16` (APNs push/ringing), `17.248/16` (iCloud/FaceTime gateway), `17.253/16` (aaplimg push CDN), `17.157/16` (GSA auth). **The relay/STUN `/16`s — the load-bearing media path — are call-time-discovered and MUST come from the capture;** routing signaling-only will leave media broken. Signed scripts are untouched until the capture yields the media ranges. See P2P note §16.4.

---

# Part IV — Observations, Changelog & TODO

## 16. Unverified Observations

### 16.1 AdGuard Returns Two Different Sinkhole IPs (Unverified)

> **Status: Observed but not formally verified. Needs a deeper audit of the rule-compiler sources to confirm.**

**Observation (July 10, 2026):** When querying AdGuard Home for blocked ad domains, some domains resolve to `0.0.0.0` and others resolve to `127.0.0.1`. Both are blocked, both cause connection failure, but the different responses were unexpected.

```
doubleclick.net             → 0.0.0.0    (blocked)
ads.google.com              → 127.0.0.1  (blocked)
pagead2.googlesyndication.com → 0.0.0.0  (blocked)
scorecardresearch.com       → 127.0.0.1  (blocked)
```

**Likely Explanation (Unverified):** There are three historical schools of thought on the "correct" DNS sinkhole response, and AdGuard faithfully preserves whichever the source blocklist used:

| Sinkhole IP | Convention | Origin |
|---|---|---|
| `0.0.0.0` | AdBlock-style lists (`\|\|domain^`) | Modern DNS-level blocking; AdGuard's native format. Fails fast — OS doesn't attempt a TCP connection. Works for both IPv4 and IPv6 without a separate rule. |
| `127.0.0.1` | Hosts-file-style lists (`127.0.0.1 domain`) | 90s-era `/etc/hosts` tradition. Steven Black's hosts list (500k+ domains) still uses this. |
| `NXDOMAIN` | Purist / Pi-hole default | Returns "domain doesn't exist." Semantically most accurate but requires browsers to handle NXDOMAIN gracefully. |

The dual-response behavior in this project is because `rule-compiler` pulls from both AdBlock-format sources (Hagezi, uBlock origin lists) and hosts-format sources (Spamhaus DROP, Steven Black, Feodo Tracker), and AdGuard returns whatever sinkhole IP the matching rule specifies.

**To Verify:** Run `docker compose exec tailscale cat /etc/hosts` to confirm no hosts-file rules are being injected at the container level, and check which specific AdGuard rule matched each domain via the AdGuard query log at `http://100.100.21.8:3000/#logs`.

### 16.2 AGY CLI Appears to Generate Native macOS Notification Pop-ups (Unverified)

> **Status: Observed but source unverified. macOS security logs ruled out system-level origin.**

**Observation (July 10, 2026):** While running a DNS blocklist verification via the Antigravity CLI (`agy`), a command was proposed that included `malware.wicar.org` (a known-safe DNS blocklist test domain) in a `dig` loop. Shortly after, a macOS-style notification popup appeared describing a "malicious" or "blocked" event. The AGY CLI terminal session then closed.

**Investigation:**
- **macOS XProtect / Gatekeeper logs:** Empty. Zero events in the 30-minute window around the incident.
- **macOS Endpoint Security / System Policy logs:** Empty.
- **Broad `log show` search for "malicious", "malware", "blocked":** Empty.
- **Conclusion:** macOS itself did not generate the notification. No system security subsystem fired.

**Likely Explanation (Unverified):** The notification appears to have originated from **AGY CLI's own internal safety system**. AGY CLI is a native macOS application (not just a terminal process) and has access to the macOS Notification Center API (`UNUserNotificationCenter`). When its guardrails detected a domain containing the word "malware" (`malware.wicar.org`) in a proposed shell command, it likely:
1. Blocked the command from executing
2. Posted a native macOS-style notification via the Notification Center

This is surprising behavior for a CLI tool — most terminal programs don't send GUI notifications — but AGY CLI appears to bridge both worlds: it runs in a terminal but is packaged as a native app with full system API access. The notification would be indistinguishable from a system security alert at a glance.

**Notes:**
- `malware.wicar.org` is the DNS/AV equivalent of the EICAR test file — a deliberately benign domain that triggers blocklist/AV systems to verify they work. It was included in the test set to confirm the AdGuard blocklist was catching it. AGY's safety system is not aware of this distinction.
- For future DNS blocklist testing, use only ad/tracking domains (e.g., `doubleclick.net`, `adnxs.com`) to avoid triggering AGY's guardrails.

### 16.3 `system_profiler SPAirPortDataType` Longevity (Wi-Fi Detection)
The Wi-Fi security detection used by `watcher.sh`'s `detect_lan_p2p_mode()` currently relies on `system_profiler SPAirPortDataType` (after the `airport` binary removal — full history in §15.11.6). This works as of macOS Sequoia (15.x) without sudo and without redaction, but given Apple's ongoing Wi-Fi privacy clampdown, it may be locked down in a future release. If `security` comes back empty on a future macOS version while on Wi-Fi, detection silently falls back to `allow=false` (a safe default). The long-term fix would be a small Swift CoreWLAN helper compiled and bundled in the repo.

### 16.4 Tailscale LAN P2P Succeeds Cross-AP But Fails Same-AP (Client Isolation + No NAT Hairpin)

**Observation (July 15, 2026):** On the residence Wi-Fi, a Galaxy S24 in the lobby reception — 6 floors away, associated to a *different* AP — establishes a **direct, low-ping** Tailscale P2P session to an iPhone 11. The *same* pair on the *same* AP / same floor / close range does **not** go direct. Counterintuitively, **farther apart = P2P works**. The effect shows for the iPhone 11 (a plain client) but **not** for S24→macOS or S24→the gateway container.

**Mechanism:**
- **Same AP:** the AP enforces **client isolation** (L2 device↔device block on one radio). Both devices then share one public IP; STUN returns identical external mappings, so reaching each other would need the residence router to **NAT-hairpin** — which most campus/consumer gear does not do → direct P2P fails and falls back to a DERP relay.
- **Different AP (floors away):** large residence networks **segment per AP/area into distinct VLANs/subnets**, so the two devices sit on different L3 networks routed through the campus core, where client isolation does not apply and the STUN path works **without** hairpin → clean direct P2P.
- **Why macOS / the container are immune:** nullexit pins a **direct WireGuard endpoint** (Tailscale port `41642`, `direct 172.x`), so those peers already hold a negotiated direct path and do not depend on same-AP L2 discovery. A plain iPhone 11 has no pinned endpoint, so its path is entirely at the mercy of the Wi-Fi topology — which is exactly why *it* exposes the isolation effect.

**Relevance:** refines `watcher.sh`'s `detect_lan_p2p_mode()` (which probes same-subnet AP isolation via a broadcast ping). The probe correctly flags same-AP isolation, but this observation adds that isolation is **per-AP** and cross-VLAN P2P can succeed even when same-AP fails — so a single "LAN P2P allowed?" boolean under-describes a multi-AP network. No code change; documents expected behavior. Related: the FaceTime NAT analysis in §15.12.22 (same STUN/hairpin physics, different symptom).

### 16.5 Working Theory — iPhone Cross-Device Visibility Reaches Other Phones, Not macOS (Instagram Auto-Open, July 15, 2026)

**Observation:** Opening Instagram on a Galaxy S24 (specifically via **Chrome** on the S24, not Samsung Internet) auto-opens a tab on a nearby MacBook, but **only when the S24 is physically close** to the Mac — it does not happen when the phone is away. **Chrome on the S24 has zero granted Android permissions** (no Bluetooth, no location, no nearby-devices) — this rules out Chrome itself performing any BLE/Nearby proximity scan, since Android enforces those permissions at the app level regardless of what the browser ships. This pushes the likely actor down to **Google Play Services**, which holds system-level Bluetooth/nearby-device access independent of per-app grants and could be doing the proximity detection on Chrome's behalf (e.g. via Android's "Nearby" APIs) — then handing the result to Chrome only for the actual tab-open. A purely local, short-range channel is still required to explain the proximity gating regardless of which component performs it; this also rules out any cloud-mediated mechanism (Chrome cloud tab sync, FCM push, Tailscale/WAN P2P per §16.4) since those are distance-independent. Live probes during the session (`system_profiler SPBluetoothDataType` for a paired device, `dns-sd -B _services._dns-sd._udp` for 8s) found **no paired Bluetooth device and no Android/Google/Instagram mDNS service** — only the Mac's own Bonjour services (AirPlay, RFB, `_companion-link`, Spotify Connect). Inconclusive: a BLE-advertisement-only channel (no formal pairing) would not show up in either probe.

**User's working theory:** the iPhone (also on hand, on the same network/Apple ID as the Mac) makes *other devices connected to it* — even an Android phone — visible to nearby devices, but this visibility channel reaches **other phones more readily than it reaches macOS**. I.e., the iPhone may be acting as a discovery bridge/relay between the S24 and the Mac rather than the S24 and Mac talking directly. Combined with the Play Services angle above, a refined version is: **Play Services on the S24 detects proximity to an Apple mesh (iPhone and/or Mac both signed into iCloud/AWDL-visible) via some cross-ecosystem discovery Google has built**, rather than the S24 and Mac negotiating directly.

**Cross-ecosystem refinement:** this isn't Google-only. Apple runs an equivalent OS-level background BLE scanning layer for its own Continuity stack (Handoff, Universal Clipboard, AirDrop discovery, Find My — the latter using *every nearby Apple device*, not just the owner's, as a passive BLE relay), implemented as system daemons (`bluetoothd`/`sharingd`/`rapportd`, already implicated in the unrelated AWDL wedge bug at §15.10) rather than anything gated by app-level permission. The key mechanism that makes the two ecosystems mutually visible: **BLE advertisement packets are broadcast in the clear over open air** — Apple's Continuity BLE frames are semi-proprietary but unencrypted at the advertisement layer, so any BLE radio (including Android's, via Play Services once Android's own "Wi-Fi & Bluetooth scanning" system-level toggle is on) can passively observe "an Apple device is here" and react, without pairing or explicit permission from Apple's side. So both ecosystems maintain a BLE mesh-discovery layer that sits below their own per-app permission model, and each side's layer is passively readable by the other's radio — which is a plausible bridge for a Play-Services-mediated Chrome trigger reacting to iPhone/Mac Continuity broadcasts.

**Status:** Unverified. Not yet reproduced under an active capture — the July 15 session ran the mDNS browse *before* confirming the phone was actively broadcasting, so it's not a clean negative result. To confirm: capture `tcpdump -i en0 udp port 5353` (mDNS) **and a raw BLE advertisement capture** (e.g. `nRF Connect` or similar BLE scanner app on a third device, or `sudo btmon`-equivalent on Linux — macOS does not expose raw BLE advertisement capture without a hardware sniffer) at the exact moment Instagram is opened on the S24 while close, with the iPhone present vs. absent, to isolate whether the iPhone's Continuity broadcasts are the trigger or the S24↔Mac channel exists independently of it. On the Android side, checking `Settings → Location → Location Services → Wi-Fi & Bluetooth scanning` and whether **Google Play Services** (not Chrome) holds Bluetooth/nearby-device/location permissions would confirm or kill the Play-Services-as-actor theory. Related: §16.4 (same physical-proximity family of P2P/discovery quirks, different mechanism and inverted distance relationship).

## 17. Changelog / Recent Updates

Reflects the current branch's state. Each entry is a one-line summary + commit hash; read the commit message (and the linked Incident Log entry) for full detail. Full post-mortems live in §15.

- **July 10, 2026 — `fix(race): suppress WARP Watcher during post-wake force-recreate`** — Fixed a race where switching Wi-Fi caused the host IP to leak as the raw ISP IP (`132.x`) on every roam; `recover.sh --post-wake`'s warp force-recreate tripped the WARP Watcher into a nuclear shutdown. Fixed via `/tmp/nullexit-warp-inhibit.marker`. See §15.2.7.
- **July 10, 2026 — startup/roaming stabilization suite** — Pre-flight Tailscale race (§15.5.3), STUN-block cold-boot false negative (§15.5.4), restart DNS-build race via `wait_for_dhcp_settle` (§15.5.5), nuclear/post-wake concurrency lock (§15.2.8), infinite auto-recovery loop marker leak (§15.2.9), PF kill-switch bricking SOCKS5 fallback (§15.7.3), `--reset` host logouts (§15.7.4), missing-flags abort (§15.7.5), discarded docker-exec errors (§15.12.18), and the SNAT endpoint poisoning fix (§15.7.1).
- **July 6, 2026 — `fix: resolve edge-case vulnerabilities and system state leaks`** — Security-review hardening suite:
  1. **DNS Watcher Interface Independence:** `start_dns_watcher` now detects the active interface via `get_active_service()` instead of hardcoding a `grep` for "Wi-Fi".
  2. **Robust Lock Verification:** `toggle.sh` lock-file logic uses `ps -p` verification to prevent permanent lockouts from a recycled PID.
  3. **Fail-Closed Crypto:** `crypto.sh` integrity check switched from `[ -x ]` to `[ -f ]` so it runs even if git strips the `+x` bit.
  4. **Strict `iptables` Pinning:** `post-rules.txt` FORWARD-chain rules explicitly pin `tailscale0`↔`tun0` both directions, preventing escape via `eth0` during WARP drops.
  5. **Docker Local Network Isolation:** `docker-compose.yml` binds exposed WARP ports (`1080`, `5354`) to `127.0.0.1` to prevent LAN access.
  6. **Routing Verification & Sudoers:** Added a `netstat -nr` default-route override check and ensured `/usr/bin/python3` is permitted in the sudoers template.
- **July 4, 2026 — `cc789c5`** — Concurrency mutex on `toggle.sh` (`/tmp/nullexit-toggle.lock`); defensive `TS_AUTHKEY` init under `set -u`; Go `go vet`/`go build` steps in CI; AdGuard log capping; macOS BSD `grep` fixes in `setup-common.sh`; `recover-linux.sh` quoting/PID fixes; removed redundant bypass-routes block in `recover.sh`.
- **July 4, 2026 — `fix: post-wake routing loop & destructive recovery`** — (1) `add_warp_bypass_routes` now accepts explicit interface args so post-wake stops routing WARP traffic back into `utun*` (was an infinite loop killing internet on every wake). (2) Replaced `sudo route -n flush` with targeted deletions of `0.0.0.0/1`/`128.0.0.0/1` + WARP bypass routes, so recovery no longer destroys loopback/multicast routes and wedges `configd`/`mDNSResponder` until reboot.
- **July 4, 2026 — `feat: secure execution`** — Restricted the blanket `/usr/bin/python3` NOPASSWD sudo to exactly `/usr/bin/python3 -I .../scripts/dns-proxy.py`; locked `dns-proxy.py` with `chown root:wheel` + `chmod 755`; added native auth prompts to `Toggle Gateway.app`/`Recover Gateway.app`; `toggle.sh` now captures `warp` logs on failure before teardown.
- **July 4, 2026 — Go ports + refactor** — `logger` and `rule-compiler` ported to Go multi-stage Docker builds (§15.8.6); ~200 lines of duplicated bash extracted to `scripts/common.sh` (§15.9.4); `crypto.sh` HMAC-SHA256 script integrity added.
- **July 3, 2026 — `fix: resolve numerous system regressions`** — Fixed truncated `/etc/sudoers.d/nullexit` line; temporary `.tmp`+`os.replace()` atomic writes in `sync-rules.py` (later reverted, see below); `recover.sh` `ts_args` quoting; ANSI `%b`/`-e` output in `diagnose-host-leak.sh`/`fix-docker-bridge-collision.sh`; `toggle-linux.sh` using `resolvectl dns` instead of macOS `networksetup`; AdGuard REST refresh POST targeting port `3000`; restored `START_GATEWAY=true`; purged stale port `80` mapping; verified `output.log` in `.gitignore`.
- **July 3, 2026 — `unlock-files.sh` + revert atomic writes** — Reverted all 5 `.tmp`+`os.replace()` sites in `sync-rules.py` to direct writes; created `scripts/unlock-files.sh` to permanently fix stale `0444`/`000` file permissions via atomic rename (no `chmod`). Covers `.env`, `compiled_rules.txt`, `ip_blocklist.ipset`, `cache/*.txt`, `cache/ip/*.txt`, `data/filters/*.txt`. See §15.9.6 + §3.
- **July 3, 2026 — Overnight leak + geo-blocking** — Introduced `scripts/host-leak-probe.sh` (sub-second host-egress detector, §15.6.1) and the statistical-threshold WARP auto-shutdown watcher (§15.6.2); fixed the overnight silent IP leak (§15.6.3).
- **July 2, 2026 — `8c5fae1` + `181e1e1`** — Two infinite routing loops fixed: host-VM tunnel loop (WARP bypass routes via physical gateway IP + `setup_exit_node_routing` forcing default to `utun*`) and Docker Compose subnet takeover (`10.200.1.0/24` lock). `--accept-routes=true` added explicitly to all `tailscale up --reset` calls. See §15.2.2.
- **July 2, 2026 — auto-recovery daemon** — `scripts/watcher.sh` + launchd LaunchAgent documented. See §15.5.1.
- **July 1, 2026 — `c5b92c0` (refactor: personal-leak cleanup)** — Eliminated every residual personal-username leak across source + config; launchd plist uses `WorkingDirectory` + relative program arg with the `__NULLEXIT_HOME__` sentinel (install recipe gains a single `sed -i '' "s|__NULLEXIT_HOME__|$(pwd)|"` step); 8 devref prose sites genericized to `~/.colima/...`, `~/Library/LaunchAgents/...`, `$USER`, `<USER>`.
- **July 1, 2026 — `a5e2a5a` (refactor: script-relative paths)** — Replaced 6 hardcoded `/Users/<user>/.../nullexit/...` literals with script-relative resolution. `recover.sh`/`watcher.sh` inject `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`; `RECOVER="$SCRIPT_DIR/../recover.sh"` resolves without launch-path dependency.
- **June 28, 2026 — `f8f8e4e` (M1: scripts/ move)** — 8 internal scripts consolidated into `scripts/`; the 4 user-facing/orchestrator/config files (`toggle.sh`, `recover.sh`, `setup.sh`, `docker-compose.yml`) stayed at repo root.
- **June 28, 2026 — `0875ef3` (ci: glob)** — CI `py_compile` switched to `python3 -m py_compile scripts/*.py` after M1 left root with zero `.py` files.
- **June 28, 2026 — `25b37a1` (docs: scripts/ prefix)** — `devref.md` + `README.md` updated to the `scripts/` prefix for all 8 moved files (~31 patches).

### End-to-end verification (commit `c5b92c0`)
Manual START → STOP cycle ran clean on macOS after path relativization + personal-leak cleanup:
- `bash toggle.sh` START: exit 0, ~135s (cold Colima boot); marker present (`2026-07-02T03:41:41Z`), all 5 containers healthy, host DNS hijacked to `100.100.21.8` (no fallback), exit node selected, Cloudflare trace through WARP succeeds.
- `bash toggle.sh` STOP: exit 0, ~12s; marker cleared, all nullexit containers gone, host DNS restored to `1.1.1.1`, Tailscale disconnected.

## 18. TODO & Future Work

### 18.1 TODO
* **FaceTime / real-time P2P split-route (Option 2, narrow):** Implement `add_apple_split_routes()` / `remove_apple_split_routes()` in `common.sh` (route FaceTime's Apple `/16`s direct via the physical gateway, opt-in `.env` flag, default OFF), wired into toggle START/STOP + `recover.sh --post-wake`. **Blocked on** an empirical `tcpdump` capture of the relay/STUN `/16`s during a real call (user-triggered). Full design + diagnosis in §15.12.22.
* **Fix the shadowed exit-path port REJECTs (DoT/QUIC bypass):** The `FORWARD` `-i tailscale0 -p udp --dport 853`/`--dport 443` REJECT rules are shadowed by the earlier `tailscale0 → tun0` ACCEPT (0 pkts), so the intended block-DoT / force-AdGuard and QUIC-block are **not enforced** — a mesh client can bypass AdGuard via DoT (853). Re-order the REJECTs before the ACCEPT (or scope `-o tun0`). See §15.12.22.
* **Decide toggle STOP/START from persisted *intent*, not a live probe:** ~~`toggle.sh` decided STOP-vs-START by calling `is_gateway_active()`, which live-probes the running system (`docker compose ps` + DNS + SOCKS checks). When Colima/Docker was down the `docker compose ps` blocked for the full 15 s `run_with_timeout` window and, under `set -e` + the `ERR` trap, aborted the script *before the START body ran* — so the path that would boot Colima never executed (`EXIT: code=1 phase=start`, seen 57× historically).~~ **Closed** — added `gateway_should_be_running()` in `common.sh`, which reads persisted intent (`MARKER_FILE`) captured into `GATEWAY_MARKER_AT_STARTUP` before the defensive stale-marker clear, and only falls back to `is_gateway_active` when the marker is absent *and* the Docker socket is actually reachable (so a dead-socket probe can neither hang nor trip `set -e`). All four decision sites (`toggle.sh` main + `--restart`, `toggle-linux.sh` main + `--restart`) now use it, and the STOP `docker compose down` is `|| true`-guarded so a disable always completes even with Docker down. See §15.12 Misc Resolved.
* **Verify Wi-Fi Roaming:** Investigate and test whether switching Wi-Fi networks now successfully and smoothly recovers the gateway end-to-end without any tailscale flag errors or dead tunnels. (Pending user verification).
* **Fix Diagnostic Script Check 5/8:** ~~Investigate why `diagnose-host-leak.sh` check 5/8 (`Host default route`) sometimes reports "default route goes via physical Wi-Fi — Tailscale route assertion failed" on macOS even though the `warp=on` egress checks confirm that traffic is successfully tunneling.~~ **Closed** — fixed by switching check 5 from `netstat -rn | grep default` to `route -n get 1.1.1.1`. macOS Tailscale uses interface-scoped routes and does not replace the DHCP default route entry. See §15.7.1 Known Unknowns.
* **Expose Tor Control Port (9051):** ~~Consider mapping the Tor Control port to localhost and adding `nyx` (the Tor terminal status monitor) to allow users to inspect their entry, middle, and exit node IPs in real-time.~~ **Closed** — mapped the Tor Control Port to a procedurally generated, localhost-bound port `TOR_CONTROL_PORT`, configured `ControlPort` and disabled cookie authentication in `docker/tor/entrypoint.sh`, and integrated it into the `/sweep` verification protocol.
* **Host-Only Tor Mode (Pluggable Egress):** Implement an `EGRESS_TYPE=tor_host_only` mode for users in heavily censored (DPI-restricted) environments. This mode would skip booting `warp` and `tailscale`, boot `adguardhome` and `tor` (using Telegram `obfs4` bridges), set AdGuard's upstream to Tor's `DNSPort`, and use the `pf` kill-switch to force all host Mac traffic strictly through the Tor network. This provides a 100% free, DPI-resistant evasion path without requiring an external VPS.
  * **The Technical Realities (What You Need to Watch Out For):**
    * **The UDP Problem:** Tor only transports TCP traffic. It does not support UDP (aside from DNS requests passed directly to its DNSPort). macOS is incredibly chatty over UDP (FaceTime, mDNS, QUIC protocols). Your pf rules defined in `scripts/pf.conf` must be configured to aggressively and silently DROP all host UDP traffic (except for local DNS queries to AdGuard). If you don't drop it cleanly, macOS services might hang indefinitely while waiting for timeouts.
    * **The "Daily Driver" Friction:** Routing a whole host OS through Tor is brutal on performance. Background daemons (iCloud sync, macOS software updates, Spotlight indexing) will blindly attempt to download gigabytes of data over Tor, which could saturate the circuits or time out completely.
    * **Bridge Rot:** State firewalls actively hunt and block obfs4 bridges. When a user's bridges burn out, they will lose all internet access due to the pf kill-switch. You will need to ensure the user has a frictionless way to update the `tor-bridges.txt` file and restart the Tor container without exposing their IP.
    * **Exit Node Discrimination:** Because all traffic will exit from known Tor nodes, the user will face an onslaught of Cloudflare CAPTCHAs, and many banking or streaming services will flat-out reject the connections.

### 18.2 Future Work
- **Direct P2P on VM Hosts:** Non-Linux hosts run Docker inside a VM, making true UDP hole-punching **to arbitrary external peers** impossible; those peers fall back to the DERP relay unless bridged mode is enabled on a trusted LAN. The only fully general solution is a native Linux host (Raspberry Pi, Intel NUC) where Docker runs without VM hypervisor translation. *(The one case that works regardless is direct **host↔container** P2P — the gateway and its own Mac, the same physical machine — re-permitted via routing-fix `.host_ips` RETURN rules and confirmed `direct` even in plain user-mode networking; see §15.3.5 and §15.8.7.)*
- **Native Linux Deployment:** Benchmark on a Raspberry Pi — native container footprint is ~75MB without macOS hypervisor overhead.
- **Mesh-Wide Filesystem (SFTP over Tailscale):** Any mesh device passively exposes its filesystem over SFTP. Android via Termux + OpenSSH + wakelock; iOS is client-only due to background process limits.
- **Post-Quantum Cryptography (PQC):** Tailscale uses Curve25519, theoretically vulnerable to "harvest now, decrypt later" quantum attacks. A future iteration could replace the Tailscale container with raw WireGuard + [Rosenpass](https://rosenpass.eu/) to negotiate post-quantum PSKs.
- **Egress Compartmentalization (Pluggable Architecture):** See §12.9 for the full plan to make the entire egress layer swappable via a single `.env` variable.

