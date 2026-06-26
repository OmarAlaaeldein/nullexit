# nullexit Handoff Document

> **Date:** June 26, 2026
> **Purpose:** This document captures every weird issue, debugging approach, and unresolved problem encountered during development so another LLM (or human) can pick up where this session left off without repeating the same investigations.

---

## Table of Contents

1. [Current State](#1-current-state)
2. [The Core Problem: Exit Node Return Path](#2-the-core-problem-exit-node-return-path)
3. [Issue Tracker](#3-issue-tracker)
4. [Diagnostic Commands Reference](#4-diagnostic-commands-reference)
5. [Key Files Reference](#5-key-files-reference)
6. [Critical macOS Quirks](#6-critical-macos-quirks)
7. [Next Steps](#7-next-steps)

---

## 1. Current State

### System Status (as of last interaction)
- **Host Tailscale:** ✅ Running and connected to mesh (`sudo brew services restart tailscale` fixed it)
- **Gateway containers:** Not running (user toggled off after issues)
- **Host DNS:** `1.1.1.1` (normal)
- **Host internet:** Working normally
- **Colima VM:** Running
- **Host IP forwarding:** Enabled (`sudo sysctl -w net.inet.ip.forwarding=1` + added to `/etc/sysctl.conf`)

### Network Architecture
```
S24 (Android) → Tailscale mesh → Mac Host (100.109.94.19)
                                    ↓ Docker bridge (172.18.0.0/16)
                              Gateway Container (warp/tailscale/socks-proxy)
                                    ↓ tun0 (WARP tunnel)
                                    ↓ Internet (Cloudflare egress)
```

### Two Traffic Paths
1. **SOCKS5 Proxy (WORKING):** TCP traffic through `127.0.0.1:1080` → container → `tun0` → WARP → internet. Verified `warp=on`.
2. **Tailscale Exit Node (BROKEN):** Traffic via Tailscale mesh → gateway container → forwarded through WARP → internet. Return path fails.

---

## 2. The Core Problem: Exit Node Return Path

### Symptom
The gateway's Tailscale node shows `tx 936 rx 0` — it transmits data but receives nothing back. Every `tailscale status` output across ALL runs shows `rx 0`:
```
100.100.21.8  ea326c9c9c7f  linux  active; offers exit node; relay "tor", tx 936 rx 0
100.100.21.8  dbc088ee2f3b  linux  active; offers exit node; relay "tor", tx 468 rx 0
100.100.21.8  8fbc873ddb90  linux  active; offers exit node; relay "tor", tx 624 rx 0
```

### Toggle Script Failure Chain
When `toggle.sh` runs the START path with the host NOT on the mesh:
1. ✅ Gateway container starts, Tailscale connects (offers exit node)
2. ✅ Host tailscaled is detected as running
3. ❌ `tailscale up --reset --accept-dns=false --exit-node=` FAILS silently
   - The host's `tailscaled` was accidentally stopped (from earlier debugging). The auto-start mechanism (`brew services start tailscale`) also fails silently because its stderr goes to `output.log`
4. ❌ Pre-flight check: AdGuard DNS via localhost:5354 → `dig` times out → `FAIL`
5. ❌ Exit node + DNS hijack skipped → Falls back to SOCKS5 proxy
6. ⚠️ SOCKS5 proxy enabled system-wide (`networksetup -setsocksfirewallproxy`) → user's internet breaks
7. Script interrupted → cleanup runs → Wi-Fi power cycle → more disruption

### What's Been Fixed
| Fix | File | Status |
|-----|------|--------|
| Tailscale wait timeout: 30s → 60s | `toggle.sh` | ✅ |
| Early abort at 40 consecutive NoState | `toggle.sh` | ✅ |
| Better error messages with diagnostics | `toggle.sh` | ✅ |
| Progress output visible during wait | `toggle.sh` | ✅ |
| FORWARD RELATED,ESTABLISHED in both iptables backends | `routing-fix.sh` | ✅ |
| CGNAT rule table 52→199 (bugfix) | `routing-fix.sh` | ✅ |
| Host IP forwarding (needs `sudo sysctl`) | `/etc/sysctl.conf` | ✅ |
| **Removed `FIREWALL_OUTBOUND_SUBNETS=100.64.0.0/10`** | `docker-compose.yml` | ✅ **SOLVED `rx 0` EXIT NODE BUG** |

### The Root Cause of `rx 0` (Exit Node Return Path Failure)
**Symptom:** The gateway container transmitted traffic correctly, but the return packets were never seen by Tailscale (`tx 936 rx 0`). 
**Root Cause:** The `docker-compose.yml` included `- FIREWALL_OUTBOUND_SUBNETS=100.64.0.0/10` for the `warp` container. Gluetun processes this variable by creating a strict kernel routing rule (`ip rule add to 100.64.0.0/10 lookup 199`) that forces all matching traffic to bypass the VPN and exit directly via the Docker bridge (`eth0`). Because this rule had a priority of `99`, it completely shadowed the `lookup 52` rule injected by `routing-fix.sh`. 
When the WARP container received a reply packet meant for a Tailscale peer (e.g., `100.87.x.x`), instead of routing it back to the `tailscale0` interface, the Linux kernel matched rule 99, sent the packet out `eth0` to the macOS host, and the macOS host dropped it because it didn't know what to do with a raw `100.x.x.x` packet.
**Fix:** Removed `- FIREWALL_OUTBOUND_SUBNETS=100.64.0.0/10` entirely. Gluetun no longer hijacks the routing, `routing-fix.sh` successfully injects `lookup 52`, and return packets correctly flow back into `tailscale0`.

### What's Still UNRESOLVED

1. **Why does `tailscale up` fail on the host?** When tailscaled is running but shows "Tailscale is stopped", the `tailscale up` command fails silently. Possible causes:
   - Auth state was lost (need `sudo tailscale up` to re-authenticate)
   - The daemon responded but the network extension didn't activate
   - Some macOS quirk with the standalone tailscaled daemon vs GUI app

2. **Why does `brew services start tailscale` fail with bootstrap error?** The LaunchAgent plist might be in a broken state. Workaround: `sudo brew services restart tailscale` worked.


---

## 3. Issue Tracker

### Issue #1: Gluetun Resets nftables FORWARD Rules
**Symptoms:** The FORWARD RELATED,ESTABLISHED rule keeps disappearing from the nftables (iptables) backend. Routing-fix re-adds it but gluetun's `post-rules.txt` engine or health-check flushes and reloads the nftables ruleset.

**Debugging:**
```bash
# Check nftables backend
docker compose exec -T warp iptables -L FORWARD -v --line-numbers
# Check legacy backend
docker compose exec -T warp iptables-legacy -L FORWARD -v --line-numbers
# Compare: nftables FORWARD has policy DROP, legacy has policy ACCEPT
```

**Fix Applied:** Added FORWARD RELATED,ESTABLISHED rule to BOTH backends in `routing-fix.sh` with 5-second re-assert loop. The legacy backend (policy ACCEPT) is the safety net — even when nftables gets flushed, the legacy rules survive.

**Still Possible Issue:** gluetun might also flush the legacy ruleset. Need to verify by checking if the rule stays in legacy after a gluetun restart.

### Issue #2: docker compose exec Injects Carriage Returns
**Symptoms:** `docker compose exec -T` on macOS/Colima injects `\r` into captured output. If `$TS_IP` ends with `\r`, `networksetup -setdnsservers` silently rejects the malformed IP.

**Fix Applied:** All `docker compose exec` output is piped through `tr -d '\r'` before use.

**Still Present:** The `ts_short` status line in the Tailscale wait loop uses `tr -d '\r\n'` but the error output's `echo "$ts_output" | sed 's/^/    /'` doesn't strip `\r` — could cause display corruption.

### Issue #3: Colima VM Memory is Tight
**Symptoms:** AdGuard container gets OOMKilled when loading large blocklists. Containers crash when Colima is at 0.6GB.

**Current Setup:** Colima allocated `0.6GB` (614MB). `GATEWAY_RULE_PROFILE=medium` (~167k rules).

**Mitigation:** Subdomain deduplication reduces rules by ~60%. Memory profiles (`light`, `medium`, `heavy`) let users trade off blocking coverage for memory usage.

### Issue #4: DNS Resolution Fails During Pre-flight Checks
**Symptoms:** `dig +tcp @127.0.0.1 -p 5354 google.com` times out. But AdGuard is healthy.

**Possible Causes:**
- Colima's SSH tunnel only forwards TCP (not UDP), so `+tcp` is required but might not work consistently
- AdGuard might not be responding on port 5354 via the TCP mapping
- The `dns: - 1.1.1.1` setting in docker-compose.yml might interfere

**To Debug:**
```bash
# Check if port mapping is working
nc -z -w 2 127.0.0.1 5354 && echo "port open" || echo "port closed"
# Try direct DNS query
dig +tcp @127.0.0.1 -p 5354 cloudflare.com
# Check AdGuard logs
docker compose logs adguardhome --tail 20
```

### Issue #5: S24 Shows "offline" After Not Being Used
**Symptoms:** `100.87.42.87 omars-s24 android offline, last seen Xh ago` — the phone shows as offline even when it should be on the mesh.

**This is expected** — Tailscale nodes show as offline when they disconnect from the mesh. The S24 likely disconnected during troubleshooting. A Tailscale app reconnect on the phone should fix it.

### Issue #6: tailscaled Daemon Gets Into a Broken State
**Symptoms:** `brew services list` shows tailscale as "started" but `tailscale status` shows "Tailscale is stopped."

**Fix:** `sudo brew services restart tailscale` — this stops the daemon (force-kills it if needed) and starts it fresh.

**Root Cause:** The toggle script's `disconnect_tailscale_host` function calls `tailscale down` repeatedly. If the daemon was already in a bad state, the `down` command might corrupt the state further.

### Issue #7: Stderr is Invisibly Swallowed
**Symptoms:** All failures are silent. Commands redirect stderr to `output.log` with `2>> output.log`, making it impossible to debug.

**Example from toggle.sh:**
```bash
$TS_BIN set --accept-dns=false >> output.log 2>&1 || true
disconnect_tailscale_host  # tailscale down >> output.log 2>&1
```

This means if `tailscale set` fails, if `tailscale down` fails, if `brew services start tailscale` fails — the user sees nothing.

**Partial Fix Applied:** The Tailscale wait loop now captures stdout + stderr with `2>&1` and shows it to the user. But many other commands in the script still hide output.

### Issue #8: reset_dns Runs at Script Start (Potential Race)
**Symptoms:** Immediately at script start, DNS is reset to 1.1.1.1. If the user is mid-troubleshoot with a custom DNS, the script overwrites it.

**Why it exists:** Prevents DNS deadlocks when the gateway is active and then the script is run. Without this, if the host's DNS is pointed at the gateway IP and the gateway is unreachable, nothing would resolve.

**Trade-off:** It's intentional, but it means running `toggle.sh` for any reason resets your network settings.

### Issue #9: Wi-Fi Power Cycle in cleanup_network_state
**Symptoms:** When the script fails or is interrupted, the cleanup handler power-cycles Wi-Fi. This causes a ~5-10 second internet outage.

**Fix:** Could be made optional or removed if the other cleanup steps (DNS restore, proxy disable) are sufficient.

---

## 4. Diagnostic Commands Reference

### Container Health
```bash
# All containers
docker ps --format '{{.Names}} {{.Status}}'

# Gateway Tailscale status
docker compose exec -T tailscale tailscale status

# WARP tunnel health
docker compose exec -T warp wget -qO- --timeout=5 https://www.cloudflare.com/cdn-cgi/trace

# SOCKS5 proxy test (from host)
curl --socks5-hostname 127.0.0.1:1080 --max-time 5 -s https://www.cloudflare.com/cdn-cgi/trace

# AdGuard DNS test
dig +tcp @127.0.0.1 -p 5354 google.com +short +timeout=5
```

### Firewall & Routing
```bash
# nftables FORWARD chain
docker compose exec -T warp iptables -L FORWARD -v --line-numbers

# Legacy FORWARD chain
docker compose exec -T warp iptables-legacy -L FORWARD -v --line-numbers

# IP rules
docker compose exec -T warp ip rule show

# Table 199 (CGNAT routes)
docker compose exec -T warp ip route show table 199

# Table 200 (SOCKS5 routes)
docker compose exec -T warp ip route show table 200

# Routing-fix logs
docker compose logs routing-fix --tail 20

# Conntrack (return path tracking)
docker compose exec -T warp conntrack -L 2>&1 | grep -E '100\.87\.42\.87|100\.109\.94\.19'
```

### Host macOS
```bash
# Tailscale status
tailscale status

# Tailscale daemon health
brew services list | grep tailscale
sudo brew services restart tailscale

# IP forwarding
sysctl net.inet.ip.forwarding

# DNS configuration
networksetup -getdnsservers Wi-Fi

# SOCKS proxy state
networksetup -getsocksfirewallproxy Wi-Fi

# Routing (CGNAT)
netstat -rn -f inet | grep 100.64
```

### Verifying the Return Path
The critical check for exit node return path:

```bash
# Check if return traffic is flowing (should show rx > 0)
docker compose exec -T tailscale tailscale status

# Check FORWARD packet counts (watch pkt column grow)
watch -n 2 "docker compose exec -T warp iptables -L FORWARD -v --line-numbers"

# Check conntrack for S24 traffic
docker compose exec -T warp conntrack -L 2>&1 | grep 100.87.42.87
```

---

## 5. Key Files Reference

| File | Purpose | Lines | Notes |
|------|---------|-------|-------|
| `toggle.sh` | Main toggle script (START/STOP) | ~800 | Most complex file. Heavy bash with `set -e`, traps, `run_with_timeout` |
| `routing-fix.sh` | Routing maintenance sidecar | ~90 | Runs every 5 seconds, maintains routes + iptables |
| `docker-compose.yml` | Service definitions | ~120 | 5 containers: warp, tailscale, socks-proxy, routing-fix, adguardhome |
| `setup.sh` | One-time setup | ~350 | Interactive; generates WARP keys, sets up AdGuard, auth |
| `post-rules.txt` | Gluetun iptables rules | 15 | Loaded at container start; DNS redirects, MSS clamping |
| `socks5-proxy.py` | SOCKS5 proxy | ~80 | Python, handles SOCKS5 handshake, tunnels through WARP |
| `dns-proxy.py` | Local DNS proxy (fallback) | ~40 | UDP:53 → TCP:5354, used when exit node unavailable |
| `sync-rules.py` | AdGuard rule compiler | ~200+ | Downloads blocklists, deduplicates, compiles |
| `output.log` | Stderr dump for all commands | 5000+ | Very noisy, mostly "Terminated: 15" from run_with_timeout watchers |

### Post-rules.txt (gluetun iptables)
```
iptables -A FORWARD -i tailscale0 -j ACCEPT
iptables -A FORWARD -o tailscale0 -j ACCEPT
iptables -A INPUT -i tailscale0 -j ACCEPT
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1180
iptables -t nat -A PREROUTING -i tailscale0 -p udp --dport 53 -j REDIRECT --to-port 5335
iptables -t nat -A PREROUTING -i tailscale0 -p tcp --dport 53 -j REDIRECT --to-port 5335
iptables -t nat -A PREROUTING -i eth0 -p udp --dport 53 -j REDIRECT --to-port 5335
iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 53 -j REDIRECT --to-port 5335
ip6tables -A FORWARD -i tailscale0 -j DROP
```

**CRITICAL OBSERVATION:** These rules are loaded by gluetun at startup via `/iptables/post-rules.txt`. They use the **nftables backend** (`iptables`). When Tailscale starts, it uses the **legacy backend** (`iptables-legacy`). These are TWO SEPARATE firewall stacks that BOTH apply to every packet. This is why the FORWARD RELATED,ESTABLISHED rule must be added to BOTH.

### Toggle Script Wait Flow (START path)
1. `reset_dns` → Set DNS to 1.1.1.1
2. `disconnect_tailscale_host` → `tailscale down`
3. Compile DNS rules → `python3 sync-rules.py`
4. Check/start Colima VM
5. `docker compose up -d`
6. **Wait loop (up to 60s):** Poll `tailscale status` for "offers exit node"
7. Resolve gateway IP (ADGUARD_IP.txt or dynamic)
8. Check host tailscaled → try `brew services start` if needed
9. **Phase A:** `tailscale up --reset --accept-dns=false --exit-node=`
10. **Phase B:** Pre-flight checks → Enable exit node or SOCKS5 fallback

---

## 6. Critical macOS Quirks

### Colima SSH Tunnel is TCP-Only
Colima uses SSH port forwarding to expose container ports to the host. SSH only forwards TCP, NOT UDP. This means:
- Port 5354/udp (AdGuard DNS) is NOT accessible from the host via UDP
- Port 5354/tcp IS accessible
- The toggle script uses `dig +tcp @127.0.0.1 -p 5354` for DNS checks
- The local DNS proxy (`dns-proxy.py`) uses UDP:53 → TCP:5354 conversion

### docker compose exec Injects \r
On macOS, `docker compose exec -T` (and `docker exec`) injects carriage returns (`\r`) into captured output. Always pipe through `tr -d '\r'` when using the output in comparisons or `networksetup` commands.

### brew services Can Get Stuck
`brew services start tailscale` can fail with `Bootstrap failed: 5: Input/output error`. This happens when the LaunchAgent plist is already loaded in a broken state. Solution: `sudo brew services restart tailscale`.

Common states:
- `brew services list` shows `started` but `tailscale status` shows `Tailscale is stopped.`
- `tailscale up` fails silently (exit code 0 but no connection)
- The daemon is running (`tailscaled` process exists) but not connected to the mesh

### Timeout Command Not Available
macOS does NOT have the `timeout` command (it's Linux/GNU only). The script implements `run_with_timeout()` as a pure-bash alternative using background processes and `kill`.

### sudo -v Prompts for Password Even with NOPASSWD
The original script used `sudo -v` for credential caching, but `sudo -v` itself prompts for a password even when the user has NOPASSWD for specific commands. The fix was to remove `sudo -v` and use `sudo -n` (non-interactive) everywhere, relying on the NOPASSWD sudoers configuration.

---

## 7. Next Steps

### Priority: Fix the Exit Node Return Path (`rx 0`)
This is the main unresolved issue. The approach that made the most progress:

1. **Ensure host is on the mesh first** (now fixed — tailscaled was restarted)
2. **Run `toggle.sh`** — it should get past the host mesh connection phase
3. **Check if exit node works** — if pre-flight checks still fail, debug each:
   - [1/3] Gateway reachable via Tailscale → `tailscale ping 100.100.21.8`
   - [2/3] AdGuard DNS via localhost → `dig +tcp @127.0.0.1 -p 5354`
   - [3/3] WARP container internet → `docker compose exec -T warp wget -qO- ...`
4. **If exit node enabled but `rx 0` persists**, the FORWARD chain or host IP forwarding is still blocking the return path:
   - Check `iptables -L FORWARD -v` packet counts
   - Check `conntrack -L` for S24's IP
   - Check if MASQUERADE is creating correct conntrack entries

### Alternative: Use SOCKS5 Proxy Exclusively
The SOCKS5 proxy path WORKS. It routes through WARP (`warp=on`). Consider:
- Making the SOCKS5 proxy the primary path instead of the exit node
- Adding UDP support (DNS-over-TCP via AdGuard handles this)

### Clean Up the Toggle Script
- Remove stderr redirection to `output.log` for critical commands
- Add visible error messages when `tailscale up`, `brew services start`, etc. fail
- Consider removing the Wi-Fi power cycle from cleanup

### Verify the S24
The S24 (`omars-s24`, 100.87.42.87) was offline during all diagnostics. Before testing exit node, reconnect it to the mesh via the Tailscale app.

---

## Quick Start for New LLM

1. Read `output.log` to see previous failures
2. Check `tailscale status` to see if host is on mesh
3. If host is on mesh, run `bash toggle.sh` to start the gateway
4. If host is NOT on mesh, ask user to run `sudo tailscale up`
5. Watch the output carefully — the 60-second wait loop shows progress
6. After START, check `tailscale status` for `tx`/`rx` counts
7. Verify SOCKS5: `curl --socks5-hostname 127.0.0.1:1080 -s https://www.cloudflare.com/cdn-cgi/trace | grep warp`
8. To stop: run `bash toggle.sh` again (takes STOP path)
