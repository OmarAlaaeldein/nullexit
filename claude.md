# claude.md — nullexit Project Context

> **Last updated:** June 26, 2026
> **Purpose:** Provide any LLM with complete project understanding so it can make informed changes without re-reading every file.

---

## 1. What Is nullexit?

nullexit is a **Tunnel-in-Tunnel VPN gateway** that chains **Tailscale** (mesh VPN) through **Cloudflare WARP** (exit VPN). It runs on a macOS host inside Docker containers managed by **Colima** (lightweight Linux VM). The goal: any device on the user's Tailscale mesh can use this gateway as an exit node, and all traffic exits through Cloudflare WARP — achieving double encryption, ISP invisibility, and network-wide ad-blocking via **AdGuard Home**.

### Traffic Flow (Ideal)
```
Phone/Laptop → Tailscale mesh (WireGuard) → Mac host → Docker container
  → Tailscale decrypts → Gluetun re-encrypts → WARP tun0 → Cloudflare → Internet
```

### Traffic Flow (Current Working Path — SOCKS5 Fallback)
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
| `routing-fix` | `alpine:3.20` | Sidecar that maintains routing tables + iptables rules every 5 seconds. |
| `adguardhome` | `adguard/adguardhome:v0.107.77` | DNS sinkhole for ads/trackers. Listens on port 5335. Upstream DNS: `127.0.0.1:53` (through WARP). |

### Port Mappings (on host via Colima SSH tunnel)
| Host Port | Container Port | Protocol | Purpose |
|-----------|---------------|----------|---------|
| 5354 | 5335 | TCP+UDP | AdGuard DNS |
| 80 | 80 | TCP | AdGuard web UI |
| 41641 | 41641 | UDP | Tailscale WireGuard direct |
| 1080 | 1080 | TCP | SOCKS5 proxy |

### Host Components
- **Colima VM** — Linux VM running Docker (recommended 0.6–0.8 GB RAM)
- **tailscaled** — Standalone Tailscale daemon via `brew install tailscale` + `brew services start tailscale` (NOT the GUI `.app`)
- **macOS network settings** — DNS, SOCKS proxy, routing all manipulated by `toggle.sh`

---

## 3. Key Files

| File | Lines | Purpose |
|------|-------|---------|
| [`toggle.sh`](file:///Users/omar/Developer/nullexit/toggle.sh) | ~866 | **Main script.** Detects state, toggles gateway ON/OFF. Handles DNS hijacking, Tailscale exit node, SOCKS proxy, timeouts, cleanup. |
| [`setup.sh`](file:///Users/omar/Developer/nullexit/setup.sh) | ~392 | **One-time setup.** Installs deps (Docker, Tailscale, wgcf), generates WARP keys, writes `.env`, configures AdGuard via API, starts containers. |
| [`docker-compose.yml`](file:///Users/omar/Developer/nullexit/docker-compose.yml) | 157 | Service definitions for all 5 containers. |
| [`routing-fix.sh`](file:///Users/omar/Developer/nullexit/routing-fix.sh) | 87 | Maintains routing tables (table 200 for SOCKS5, table 199 for CGNAT) and FORWARD iptables rules in both nftables and legacy backends. Runs in a 5-second loop. |
| [`post-rules.txt`](file:///Users/omar/Developer/nullexit/post-rules.txt) | 16 | Gluetun iptables rules loaded at container start. FORWARD accept for tailscale0, NAT MASQUERADE on tun0, DNS redirect to port 5335, IPv6 drop, TCP MSS clamping. |
| [`socks5-proxy.py`](file:///Users/omar/Developer/nullexit/socks5-proxy.py) | 199 | SOCKS5 proxy (Python). Handles RFC 1928 handshake, bidirectional forwarding with `select.select()`. |
| [`dns-proxy.py`](file:///Users/omar/Developer/nullexit/dns-proxy.py) | 87 | Local DNS proxy. UDP:53 → TCP:5354 with proper 2-byte length prefix. Fallback when exit node is unavailable. |
| [`sync-rules.py`](file:///Users/omar/Developer/nullexit/sync-rules.py) | 297 | Ad-blocking rule compiler. Fetches remote blocklists, deduplicates subdomains (~60% reduction), compiles to AdGuard syntax. Memory profiles: `light`/`medium`/`heavy`. 24-hour file cache. |
| [`recover.sh`](file:///Users/omar/Developer/nullexit/recover.sh) | 266 | Nuclear recovery script. Resets DNS on ALL services, disables proxies, flushes routes, stops containers, power-cycles Wi-Fi. |
| [`black_list.txt`](file:///Users/omar/Developer/nullexit/black_list.txt) | 72 | Custom domains to block (ads, trackers, telemetry). Supports `$important` modifier. |
| [`white_list.txt`](file:///Users/omar/Developer/nullexit/white_list.txt) | ~120 | Domains to force-allow (YouTube, Apple services, etc.). Always wins over blocks. |
| [`.env`](file:///Users/omar/Developer/nullexit/.env) | 14 | WARP WireGuard keys, Tailscale auth key, rule profile. **Contains secrets.** |
| [`ADGUARD_IP.txt`](file:///Users/omar/Developer/nullexit/ADGUARD_IP.txt) | 1 | Static gateway Tailscale IP (fallback for dynamic resolution). |

---

## 4. toggle.sh Flow

### State Detection
`is_gateway_active()` returns true if EITHER containers are running OR host DNS is not `1.1.1.1`. This dual check prevents the script from starting when it should stop (e.g., containers crashed but DNS is still hijacked).

### START Path (gateway OFF → ON)
1. **Reset DNS to 1.1.1.1** — Prevents deadlocks during startup
2. **Disconnect host Tailscale** — `tailscale down` (prevents exit-node routing during container boot)
3. **Compile DNS rules** — `python3 sync-rules.py`
4. **Boot Colima VM** — `colima start --memory 0.6` if not running
5. **Clean corrupted AdGuard config** — Remove empty `AdGuardHome.yaml`
6. **Start containers** — `docker compose up -d`
7. **Wait for gateway Tailscale** — Poll `tailscale status` for "offers exit node" (up to 60s, abort at 40 consecutive NoState)
8. **Resolve gateway IP** — From `ADGUARD_IP.txt` or `docker compose exec tailscale tailscale ip -4`
9. **Connect host to mesh** — Verify `tailscaled` is running (auto-start if needed), then `tailscale up --reset --accept-dns=false --exit-node=`
10. **Pre-flight checks** — [1/3] `tailscale ping` gateway, [2/3] `dig +tcp` AdGuard DNS, [3/3] WARP container internet
11. **If all pass** → Set exit node + hijack DNS to gateway IP (single server, no fallback)
12. **If any fail** → Enable SOCKS5 proxy + local DNS proxy as fallback
13. **Final DNS re-force** — `force_dns_to_gateway` called again after exit-node transition (tailscaled clobbers DNS briefly)

### STOP Path (gateway ON → OFF)
1. Reset DNS to 1.1.1.1
2. Disconnect host Tailscale (`tailscale down`)
3. `docker compose down -t 5`
4. Reset DNS again
5. Stop local DNS proxy
6. Full network state cleanup (proxies off, DNS cache flush, route flush, Wi-Fi power cycle)

### Safety Mechanisms
- `run_with_timeout()` — Pure-bash watchdog for every system command (15s–120s)
- `cleanup_handler()` — Trap on ERR/INT/TERM/HUP restores DNS to 1.1.1.1 and tears down Tailscale
- `force_dns_to_gateway()` — Sets DNS and VERIFIES via `networksetup -getdnsservers` (3 attempts with backoff)
- `SUCCESS_RUN` flag — Cleanup only runs if script didn't complete successfully

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

## 6. Known Problems (from handoff.md)

### 🔴 CRITICAL: Exit Node Return Path (`rx 0`)
- **Symptom:** Gateway shows `tx 936 rx 0` — transmits but never receives return traffic
- **Impact:** Tailscale exit node mode is broken. SOCKS5 proxy works as fallback.
- **Possible causes:**
  1. Gluetun firewall dropping incoming RELATED,ESTABLISHED on `eth0`
  2. Docker bridge not forwarding return traffic container → host
  3. Host IP forwarding not working for the return path
  4. Conntrack not tracking NAT MASQUERADE through the double-VPN setup
- **Status:** UNRESOLVED. The SOCKS5 proxy path works and is the current workaround.

### 🟡 Host `tailscale up` Fails Silently
- **Symptom:** `tailscale up` returns exit code 0 but host doesn't join mesh
- **Workaround:** `sudo brew services restart tailscale`
- **Root cause:** `tailscaled` daemon gets into a "started but stopped" state where `brew services list` shows it running but `tailscale status` says "Tailscale is stopped."

### 🟡 Gluetun Resets nftables FORWARD Rules
- **Symptom:** FORWARD RELATED,ESTABLISHED rule disappears after Gluetun health check
- **Mitigation:** `routing-fix.sh` re-adds to both iptables backends every 5 seconds
- **Still possible:** Gluetun might also flush the legacy ruleset

### 🟡 DNS Pre-flight Check Flaky
- **Symptom:** `dig +tcp @127.0.0.1 -p 5354` times out even when AdGuard is healthy
- **Cause:** Colima SSH tunnel TCP-only forwarding may be inconsistent

### 🟢 Resolved: docker compose exec \\r Injection
- All `docker compose exec` output piped through `tr -d '\r'`
- `ts_short` in error output still doesn't strip `\r` (display-only issue)

### 🟢 Resolved: Wi-Fi Power Cycle on Cleanup
- Causes 5-10s internet outage on every failed toggle
- Could be made optional

### 🟢 Resolved: stderr Swallowed
- Most commands redirect stderr to `output.log` making failures invisible
- Partially fixed: Tailscale wait loop now shows output

---

## 7. macOS Quirks to Remember

1. **Colima SSH tunnel is TCP-only** — UDP ports (like 5354/udp) are NOT accessible from host. Use `dig +tcp` or the Python DNS proxy (UDP→TCP converter).
2. **`docker compose exec -T` injects `\r`** — Always `tr -d '\r'` when capturing output for comparisons or `networksetup` commands.
3. **`brew services` can get stuck** — Fix with `sudo brew services restart tailscale`.
4. **No `timeout` command** — macOS lacks GNU `timeout`. Use the `run_with_timeout()` bash function.
5. **`sudo -v` prompts even with NOPASSWD** — Use `sudo -n` (non-interactive) everywhere.
6. **DNS is scoped to en0** — macOS scutil DNS resolver is scoped to en0 (Wi-Fi). DNS changes on other interfaces (like USB Ethernet) are ignored unless en0's service is also updated. The script always sets DNS on BOTH `$ACTIVE_SERVICE` and `$EN0_SERVICE`.
7. **tailscaled clobbers DNS during exit-node transition** — `force_dns_to_gateway` is called a second time at the end of the ENABLE branch to counteract this.
8. **`tailscale up --reset`** resets all unspecified flags to defaults — Every `--reset` call MUST also pass `--accept-dns=false` explicitly or tailscaled re-enables DNS management.

---

## 8. Environment Variables

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

## 9. Diagnostic Commands

```bash
# Container health
docker ps --format '{{.Names}} {{.Status}}'
docker compose exec -T tailscale tailscale status
docker compose exec -T warp wget -qO- --timeout=5 https://www.cloudflare.com/cdn-cgi/trace

# SOCKS5 proxy test
curl --socks5-hostname 127.0.0.1:1080 -s https://www.cloudflare.com/cdn-cgi/trace | grep warp

# AdGuard DNS
dig +tcp @127.0.0.1 -p 5354 google.com +short +timeout=5

# Firewall (both backends!)
docker compose exec -T warp iptables -L FORWARD -v --line-numbers
docker compose exec -T warp iptables-legacy -L FORWARD -v --line-numbers

# IP rules + routing tables
docker compose exec -T warp ip rule show
docker compose exec -T warp ip route show table 199
docker compose exec -T warp ip route show table 200

# Host
tailscale status
networksetup -getdnsservers Wi-Fi
networksetup -getsocksfirewallproxy Wi-Fi
sysctl net.inet.ip.forwarding
```

---

## 10. Next Steps / Priorities

1. **Fix exit node return path (`rx 0`)** — The core unresolved problem. Need to trace where return packets are dropped (Gluetun firewall? Docker bridge? Host forwarding? Conntrack?).
2. **Or: Embrace SOCKS5 as primary** — It works. Consider making it the default path and dropping the exit node complexity.
3. **Clean up toggle.sh** — Remove stderr swallowing for critical commands, make Wi-Fi power cycle optional, add visible error messages.
4. **Verify with S24** — The Android phone was offline during all diagnostics. Reconnect it to the mesh before testing exit node.

---

## 11. What I Actually Think Is Happening (June 26, 2026)

### Current live state
- Host tailscaled: **error state** (`brew services list` shows `error 78`, `tailscale status` says "stopped")
- Colima: running
- All 5 containers: running (warp/socks-proxy/adguardhome healthy, tailscale up 5 min, routing-fix up 14 min)
- The tailscale container restarted more recently than the others (5 min vs 14 min) — it likely flapped due to a gluetun health check, confirming the known instability

### The exit node was probably never going to work in this container topology

Here's the packet path I traced by reading `ip rule show` and the routing tables live:

**Outbound (S24 → internet):**
1. S24 sends packet to gateway via Tailscale mesh
2. Gateway's tailscale0 (kernel TUN, `TS_USERSPACE=false`) decrypts → packet enters FORWARD chain
3. Packet has src=`100.87.42.87` (S24), dst=some internet IP
4. FORWARD chain (nftables): Rule 1 matches (`-i tailscale0 -j ACCEPT`) ✅
5. Routing decision for the forwarded packet. Which ip rule matches?
   - Rule 98: `to 172.18.0.0/16` → no (dst is internet)
   - Rule 99: `to 100.64.0.0/10` → no (dst is internet)
   - Rule 100: `from 172.18.0.2` → **NO** (src is `100.87.42.87`, not the container IP!)
   - Rule 101: `not fwmark 0xca6c lookup 51820` → **YES** (no fwmark on forwarded packets)
6. Table 51820: `default dev tun0` → packet goes out through WARP ✅
7. NAT POSTROUTING: `MASQUERADE on tun0` → src becomes WARP IP ✅
8. Packet exits through WARP to internet ✅ (in theory)

**Return (internet → S24):**
1. Return packet arrives on tun0, conntrack de-MASQUERADEs dst back to `100.87.42.87`
2. Routing decision for dst=`100.87.42.87`:
   - Rule 99: `to 100.64.0.0/10 lookup 199` → **YES**
3. Table 199: `100.64.0.0/10 via 172.18.0.1 dev eth0` → **sends it to the Docker gateway!**
4. **This is wrong.** The packet should go to tailscale0 (to be re-encrypted and sent to S24), but table 199 sends it out eth0 to the Docker bridge host.

**Table 199 is the smoking gun.** It has one route: `100.64.0.0/10 via 172.18.0.1 dev eth0`. This sends ALL Tailscale CGNAT return traffic out the Docker bridge to the host — not back through tailscale0. The return packet leaves the container's network namespace entirely, hits the host's routing stack, and gets dropped because the host has no idea what to do with a raw packet for `100.87.42.87`.

### Why table 199 exists and why it's wrong for exit node traffic

Table 199 + the CGNAT rule (pref 99) was designed so that the **container itself** can reach other Tailscale peers (e.g., for mesh management, DERP relay). For that use case, routing CGNAT traffic via the Docker bridge to the host (which has its own tailscaled) makes sense.

But for **forwarded exit node traffic**, the return packet needs to go back through tailscale0 inside the container — not out to the host. The CGNAT rule intercepts the return packet before it can be routed back to tailscale0 through the main table or Tailscale's own routing (table 52, which is at pref 5270).

### The FORWARD counters confirm it

Both iptables backends show **0 packets** on all FORWARD rules. Not "some packets, some dropped" — zero. This means either:
- (a) No exit node traffic is being forwarded at all (nobody is using the exit node right now, which is expected since host tailscaled is in error state), or
- (b) The traffic never reached the FORWARD chain to begin with

Given that handoff.md reports `tx 936 rx 0` even when traffic WAS flowing, the return path is definitely the failure point — and table 199 is the most likely culprit.

### The SOCKS5 path works because it dodges all of this

SOCKS5 proxy creates connections **from the container's own IP** (`172.18.0.2`). So:
- ip rule 100 (`from 172.18.0.2 lookup 200`) matches ✅
- Table 200 has `default dev tun0` ✅
- Return traffic comes back to `172.18.0.2` on tun0, conntrack de-NATs, proxy sends response to client ✅

No FORWARD chain involved. No CGNAT rule involved. No table 199. It just works.

### The missing FORWARD RELATED,ESTABLISHED rule

The `routing-fix.sh` adds `FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT` to both iptables backends. But looking at the live nftables FORWARD chain, **it's not there**.
**Root Cause Found:** The `routing-fix` container runs `alpine:3.20`, which **does not have iptables installed by default!** The `iptables -C` and `iptables -A` commands were failing with `executable file not found in $PATH`, but the script was swallowing the errors with `2>/dev/null || true`.
**Fix Applied:** Updated `docker-compose.yml` to run `apk add --no-cache iptables iproute2` before starting `routing-fix.sh`. The rule now persists successfully.

### The variable parsing bug in routing-fix.sh

`DOCKER_GW=$(ip route show default | awk '{print $3}')` was picking up two lines because `ip route show default` prints a `scope link` route as well. This resulted in `172.18.0.1\neth0`, which caused the SOCKS5 proxy tunnel loop exception route (`ip route add ... table 200`) to fail silently.
**Fix Applied:** Added `head -1` to the parsing chain in `routing-fix.sh`.

### The host tailscaled is broken right now

`brew services list` shows tailscale with `error 78`. Exit code 78 from launchd typically means the plist couldn't be loaded. The daemon is dead. This means:
- `tailscale up` from toggle.sh will fail
- The host can't join the mesh
- Exit node can't be set
- DNS hijack to the gateway IP is pointless

This matches handoff.md Issue #6. The fix (`sudo brew services restart tailscale`) works but the root cause isn't addressed — repeated `tailscale down` calls from the cleanup handler may be corrupting the daemon state.

### Summary of my suspicions

| Suspicion | Confidence | Evidence |
|-----------|-----------|----------|
| Table 199 CGNAT route hijacks exit node return traffic | **Fixed** | Changed `lookup 199` to `lookup 52` in `routing-fix.sh`. Return packets will now route via tailscale0. |
| FORWARD RELATED,ESTABLISHED missing | **Fixed** | Installed `iptables` via apk in `docker-compose.yml`. Rule now injects successfully. |
| DOCKER_GW variable parsing error | **Fixed** | Added `head -1` in `routing-fix.sh`. |
| Host tailscaled error state is caused by aggressive `tailscale down` in cleanup | Medium | handoff.md documents repeated daemon corruption after toggle failures |
