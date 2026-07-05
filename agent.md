# nullexit — Detailed Agent Analysis

> Complete per-file breakdown of every function, constant, duplication, and bug found.
> This document is a work order for implementing the refactor described in `redundancy_analysis.md`.
> **Note (July 2026):** `sync-rules.py` and `logger.py` have been fully ported to Go (`scripts/rule-compiler/main.go` and `scripts/logger/main.go`) to dramatically improve performance and reduce container footprint via multi-stage Alpine builds. The analysis below reflects their previous Python states.

## 🛑 Important Agent Instruction
- **Always run `bash scripts/crypto.sh --sign` after making any modifications to the core bash scripts.** This is required to update the cryptographic HMAC-SHA256 signatures; otherwise, the startup integrity checks will fail and block execution.
- **Always run `git diff` and print the changes to the user *before* requesting or executing any git commit command.** The user must be shown the diff so they can review and understand the changes. Based on this diff, formulate a highly precise, detailed, and descriptive commit message (explaining exactly what was changed and why) rather than a generic summary, and present it to the user alongside the diff.
- **Always use the `--restart` flag when asked to restart the toggle (e.g., run `./toggle.sh --restart`).**
- **NEVER execute any `sudo` commands (especially `sudo route`, `sudo dscacheutil`, or any network-modifying commands) without explicitly explaining to the user what the command does and why it is needed FIRST. Do not assume implicit permission. Wait for the user's approval before running it.**
- **When fixing an error and using logs to debug, always show the user the reasoning and the specific logs that support this theory.**
- **When the user tells you to "push", this means read git diffs and prepare commit messages that correspond to these changes (do not ignore any changes). If the changes can be atomized into multiple commits for easier understanding, do so.**

## 🔬 How to Verify Gateway is Working
Whenever modifications are made to the gateway scripts, routing, or containers, execute these verification checks in order:
1. **Container Health:** Run `docker compose ps` to ensure all containers (`warp`, `adguardhome`, `routing-fix`, `tailscale`) are `running` and `healthy`.
2. **DNS Hijacking Status:** Run `networksetup -getdnsservers "Wi-Fi"` (or appropriate network service) and ensure it is set exclusively to the gateway's Tailscale static IP (typically `100.100.21.8`).
3. **DNS Query Interception:** Run `dig @100.100.21.8 google.com` (using the gateway static IP from `ADGUARD_IP.txt`) to ensure AdGuard Home is active, intercepting, and resolving queries.
4. **Double-Tunnel Egress:** Run `curl -s https://www.cloudflare.com/cdn-cgi/trace | grep warp` to verify the egress is routed through Cloudflare WARP (`warp=on`).
5. **Host Leak Monitoring:** Run `tail -n 30 output.log` and verify the background watchers and host leak prober are reporting healthy status without `LEAK` warnings.

---

## Part 1: macOS Main Scripts

### toggle.sh (1249 lines, 54KB)

**Functions (27 total):**

| # | Function | Lines | Purpose |
|---|----------|-------|---------|
| 1 | `run_with_timeout()` | L30–64 | Run a command with a timeout watchdog; kills after N seconds |
| 2 | `run_gui_cmd()` | L68–80 | Run a GUI command as the logged-in console user |
| 3 | `write_gateway_active_marker()` | L88–90 | Write timestamp to `/tmp/nullexit-gateway-active.marker` |
| 4 | `clear_gateway_active_marker()` | L92–95 | Remove gateway active marker + TUNNEL_FAILED_CLOSED.marker |
| 5 | `start_sleep_prevention()` | L108–154 | Start `caffeinate` in background with shutdown trap to revert DNS |
| 6 | `stop_sleep_prevention()` | L157–167 | Stop caffeinate process via PID file |
| 7 | `start_dns_watcher()` | L173–191 | Background loop to re-hijack DNS every 30s for Wi-Fi roaming |
| 8 | `stop_dns_watcher()` | L193–203 | Stop DNS watcher via PID file |
| 9 | `start_warp_watcher()` | L220–279 | Background WARP liveness monitor; triggers recover.sh after N consecutive failures |
| 10 | `stop_warp_watcher()` | L281–291 | Stop WARP watcher via PID file |
| 11 | `start_host_leak_probe()` | L297–310 | Start host-egress leak prober (300ms polling) |
| 12 | `stop_host_leak_probe()` | L312–322 | Stop host leak probe via PID file |
| 13 | `cleanup_handler()` | L325–382 | Error/signal handler: resets DNS, stops all watchers, tears down containers |
| 14 | `restart_tailscaled_daemon()` | L449–463 | Restart tailscaled via brew services (user then system fallback) |
| 15 | `disconnect_tailscale_host()` | L465–477 | Disconnect host Tailscale with retry on failure |
| 16 | `get_active_service()` | L480–508 | Detect active macOS network service name (e.g., "Wi-Fi") |
| 17 | `add_warp_bypass_routes()` | L524–546 | Add static routes for WARP endpoints (162.159.192.1, 162.159.193.1) |
| 18 | `remove_warp_bypass_routes()` | L548–552 | Remove WARP bypass routes |
| 19 | `setup_exit_node_routing()` | L558–577 | Override default route to point through Tailscale utun interface |
| 20 | `reset_dns()` | L588–595 | Reset DNS to 1.1.1.1 on ACTIVE_SERVICE + EN0_SERVICE |
| 21 | `cleanup_network_state()` | L600–645 | Nuclear cleanup: disable proxies, flush DNS cache, flush routes, power-cycle Wi-Fi, kill sharing services |
| 22 | `enable_socks_proxy()` | L663–682 | Enable system-wide SOCKS5 proxy on macOS |
| 23 | `disable_socks_proxy()` | L684–689 | Disable SOCKS5 proxy |
| 24 | `stop_local_dns_proxy()` | L702–710 | Kill local Python DNS proxy |
| 25 | `start_local_dns_proxy()` | L713–768 | Start Python DNS proxy (UDP:53 → TCP:5354) |
| 26 | `force_dns_to_gateway()` | L780–820 | Force DNS to a specific IP with 3-retry verification loop |
| 27 | `is_gateway_active()` | L833–854 | Check if gateway is running (containers, DNS, SOCKS proxy) |

**Constants:**

| Constant | Value | Line |
|----------|-------|------|
| `LOG_FILE` | `$PWD/output.log` | L8 |
| `PID_FILE` | `/tmp/nullexit-caffeinate.pid` | L105 |
| `DNS_WATCHER_PID_FILE` | `/tmp/nullexit-dns-watcher.pid` | L169 |
| `WARP_WATCHER_PID_FILE` | `/tmp/nullexit-warp-watcher.pid` | L170 |
| `HOST_LEAK_PROBE_PID_FILE` | `/tmp/nullexit-host-leak-probe.pid` | L171 |
| `SOCKS_PROXY_PORT` | `1080` | L661 |
| `PATH` export | `/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$PATH` | L396 |
| Gateway active marker | `/tmp/nullexit-gateway-active.marker` | L89 |
| TUNNEL_FAILED_CLOSED marker | `$SCRIPT_DIR/TUNNEL_FAILED_CLOSED.marker` | L94 |
| WARP endpoints | `162.159.192.1`, `162.159.193.1` | L535-544 |
| DNS fallback | `1.1.1.1` | L592 |
| DNS search domain | `ts.net` | L794 |
| `LOCK_FILE` | `/tmp/nullexit-toggle.lock` | L62 |

---

### recover.sh (484 lines, 20KB)

**Functions (7 total):**

| # | Function | Lines | Purpose |
|---|----------|-------|---------|
| 1 | `step()` | L40 | Print bold step header |
| 2 | `ok()` | L41 | Print green success message |
| 3 | `warn()` | L42 | Print yellow warning message |
| 4 | `fail()` | L43 | Print red failure message |
| 5 | `die()` | L44 | Print red error and exit |
| 6 | `run_with_timeout()` | L56–74 | Run command with timeout (bash-native, no GNU coreutils) |
| 7 | `restart_tailscaled_daemon()` | L118–129 | Restart tailscaled daemon via brew services |

**Constants:**

| Constant | Value | Line |
|----------|-------|------|
| Color codes | `RED`, `GREEN`, `YELLOW`, `BOLD`, `NC` | L37-38 |
| `SCRIPT_DIR` | `$(dirname "${BASH_SOURCE[0]}")` | L50 |
| `PATH` export | `/opt/homebrew/bin:/usr/local/bin:$PATH` | L77 |
| `PID_FILE` | `/tmp/nullexit-caffeinate.pid` | L387 |
| `DNS_WATCHER_PID_FILE` | `/tmp/nullexit-dns-watcher.pid` | L407 |
| `HOST_LEAK_PROBE_PID_FILE` | `/tmp/nullexit-host-leak-probe.pid` | L423 |
| WARP endpoints | `162.159.192.1`, `162.159.193.1` | L329-336 |
| TUNNEL_FAILED_CLOSED marker | `$SCRIPT_DIR/TUNNEL_FAILED_CLOSED.marker` | L51 |

**Duplicated logic from toggle.sh:**
*(Note: As of July 2026, **ALL** of the below duplicated logic has been successfully extracted to `scripts/common.sh`!)*
- `run_with_timeout()` — simpler subshell version vs toggle's PID-tracking version
- `restart_tailscaled_daemon()` — near-identical (uses warn()/ok() vs echo)
- Active network service detection — inline at L217-233 (toggle has `get_active_service()` function)
- EN0 service resolution — inline at L230-233 (same as toggle L515-516)
- WARP bypass routes — inline at L329-337 (toggle has `add_warp_bypass_routes()`)
- Exit node routing setup — inline at L340-345 (toggle has `setup_exit_node_routing()`)
- DNS cache flushing — L296-302 (same as toggle L611-616)
- Wi-Fi power-cycling — L442-461 (similar to toggle L626-637)
- Proxy disabling — L282-288 (same as toggle L604-608)
- Sharing services reset — L586 (same as toggle L642)
- PID file stop pattern — L387-399, L407-419, L423-435 (same as toggle L157-167, L193-203, L312-322)
- KILL_SWITCH check — L194 (same as toggle L141, L469)
- ADGUARD_IP.txt reading — L138-142, L209-213 (same pattern as toggle L1080)

---

### setup.sh (410 lines, 18KB)

**Functions (4 total):**

| # | Function | Lines | Purpose |
|---|----------|-------|---------|
| 1 | `step()` | L10 | Print bold blue step header |
| 2 | `ok()` | L11 | Print green success message |
| 3 | `warn()` | L12 | Print yellow warning message |
| 4 | `die()` | L13 | Print red error and exit |

**Constants:**

| Constant | Value | Line |
|----------|-------|------|
| Color codes | `RED`, `GREEN`, `YELLOW`, `BLUE`, `BOLD`, `NC` | L7-8 |
| `RECOMMENDED_TS_VERSION` | `1.98.5` | L71 |
| `ADGUARD_PASSWORD` | `nullexit` | L215 |
| Default .env values | `GATEWAY_RULE_PROFILE=medium`, `GATEWAY_MSS=1120`, etc. | L240-248 |

---

## Part 2: Linux Scripts

### scripts/toggle-linux.sh (931 lines, 39KB)

**Functions (17 total):**

| # | Function | Line | Purpose |
|---|----------|------|---------|
| 1 | `run_with_timeout()` | L19 | Runs command with timeout watchdog, kills on expiry |
| 2 | `run_gui_cmd()` | L57 | ⚠️ macOS code — uses `stat -f '%Su' /dev/console`, DEAD CODE on Linux |
| 3 | `start_sleep_prevention()` | L74 | Uses `systemd-inhibit` (Linux) to block sleep |
| 4 | `stop_sleep_prevention()` | L116 | Kills sleep prevention process via PID file |
| 5 | `start_dns_watcher()` | L130 | Background daemon polling DNS every 30s, re-hijacks if changed |
| 6 | `stop_dns_watcher()` | L149 | Kills DNS watcher process via PID file |
| 7 | `cleanup_handler()` | L162 | Trap handler for ERR/INT/TERM/HUP — restores DNS, kills bg processes |
| 8 | `disconnect_tailscale_host()` | L273 | Disconnects host Tailscale from mesh |
| 9 | `get_active_service()` | L283 | Gets active network interface via `ip route` (Linux) |
| 10 | `reset_dns()` | L304 | Restores DNS via `resolvectl revert` (Linux) |
| 11 | `cleanup_network_state()` | L314 | Flushes DNS cache, routes, power-cycles network interface |
| 12 | `enable_socks_proxy()` | L361 | Stub — prints message that Linux global SOCKS is DE-specific |
| 13 | `disable_socks_proxy()` | L367 | Stub — prints skip message |
| 14 | `stop_local_dns_proxy()` | L383 | Kills Python DNS proxy processes |
| 15 | `start_local_dns_proxy()` | L394 | Starts Python DNS proxy (UDP:53 → TCP:5354) + hijacks DNS |
| 16 | `force_dns_to_gateway()` | L461 | 3-attempt loop to set + verify DNS via `resolvectl` |
| 17 | `is_gateway_active()` | L495 | Checks if containers running or DNS was hijacked |

**Shared constants with macOS toggle.sh:**

| Constant | Value | Both |
|----------|-------|------|
| `SOCKS_PROXY_PORT` | `1080` | toggle-linux L359, toggle.sh L661 |
| `PID_FILE` | `/tmp/nullexit-caffeinate.pid` | toggle-linux L71, toggle.sh L105 |
| `DNS_WATCHER_PID_FILE` | `/tmp/nullexit-dns-watcher.pid` | toggle-linux L128, toggle.sh L169 |
| ARP threshold | `15` devices | toggle-linux L518, toggle.sh L863 |
| Colima memory | `0.6` (600MB) | toggle-linux L578, toggle.sh L928 |
| Colima swap | `400MB` | toggle-linux L587, toggle.sh L937 |
| Tailscale wait loop | `60 iterations × 1s` | toggle-linux L613, toggle.sh L1010 |
| NoState stuck threshold | `40 consecutive` | toggle-linux L628, toggle.sh L1025 |

---

### scripts/recover-linux.sh (257 lines, 10KB)

**Functions (6 total):**

| # | Function | Line | Purpose |
|---|----------|------|---------|
| 1 | `step()` | L24 | Print formatted step header |
| 2 | `ok()` | L25 | Print green success message |
| 3 | `warn()` | L26 | Print yellow warning message |
| 4 | `fail()` | L27 | Print red failure message |
| 5 | `die()` | L28 | Print red error + exit 1 |
| 6 | `run_with_timeout()` | L33 | Simplified timeout (immediate SIGKILL, no PID tracking) |

---

### scripts/setup-linux.sh (416 lines, 18KB)

**Functions (4 total):**

| # | Function | Line | Purpose |
|---|----------|------|---------|
| 1 | `step()` | L10 | Print formatted step header |
| 2 | `ok()` | L11 | Print green success message |
| 3 | `warn()` | L12 | Print yellow warning message |
| 4 | `die()` | L13 | Print red error + exit 1 |

**~95% identical to macOS setup.sh.** Only differences:
1. Desktop shortcuts (L366-391 Linux `.desktop` files vs macOS `.app` via `osacompile`)
2. Final instructions text
3. .env template: macOS adds `GATEWAY_USE_EXIT_NODE`, `WARP_FAIL_THRESHOLD`, `HOST_LEAK_PROBE`, `KILL_SWITCH` — Linux omits these

---

## Part 3: Utility Scripts

### scripts/diagnose-host-leak.sh (726 lines, 38KB)

**Purpose:** Comprehensive host-routing diagnostic. 8 checks classify host IP leaks. Supports `--fix` and `--watch` modes.

**Duplicated logic:**
- `resolve_active_service()` — identical pattern as toggle.sh, recover.sh, fix-docker-bridge-collision.sh
- `run_with_timeout()` — reimplemented timeout
- Color codes — RED/GREEN/YELLOW/BOLD/NC with tty detection
- WARP check via `cloudflare.com/cdn-cgi/trace`
- `export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"`
- ADGUARD_IP.txt reading pattern

### scripts/fix-docker-bridge-collision.sh (402 lines, 18KB)

**Purpose:** Fixes Docker bridge subnet collisions with `10.200.1.0/24`.

**Duplicated logic:**
- `resolve_active_iface()` — same interface detection as diagnose-host-leak.sh
- Color codes, step()/ok()/warn()/fail()/die() formatting helpers

### scripts/fix-ssh-delay.sh (63 lines, 2.7KB)

**Purpose:** One-shot fix for ~20s SSH delay. Standalone, minimal duplication (uses hardcoded ✓/✗ instead of color functions).

### scripts/host-leak-probe.sh (110 lines, 5.5KB)

**Purpose:** Sub-second host-egress leak prober at 300ms intervals.

**Duplicated logic:**
- WARP check via cdn-cgi/trace (same curl + awk as toggle.sh WARP Watcher)
- Color codes (hardcoded; status updates and warnings are conditioned on TTY detection to prevent log pollution)
- LOG_FILE = `$PROJECT_ROOT/output.log`

### scripts/reinstall-host-tailscale.sh (740 lines, 31KB)

**Purpose:** Complete uninstall + reinstall of host Tailscale.

**Duplicated logic:**
- `with_timeout()` — yet another bash timeout implementation (polling-based, different from diagnose and toggle versions)
- Color codes + logging functions
- System Extension detection logic (similar to diagnose-host-leak.sh)

### scripts/routing-fix.sh (232 lines, 9.7KB)

**Purpose:** Runs INSIDE warp container. Maintains routing table 200, FORWARD rules, country blocking, IP blocklists, tunnel health checks.

**Duplicated logic:**
- (Fixed) WARP_ENDPOINT defaults are now centralized in common.sh
- WARP health check via cdn-cgi/trace (another instance)
- iptables dual-backend pattern (for-loop over `iptables iptables-legacy`)

### scripts/watcher.sh (212 lines, 11KB)

**Purpose:** Long-running launchd daemon for post-wake/post-roam recovery.

**Duplicated logic:**
- PATH export (similar to toggle.sh/recover.sh)
- Marker file pattern (`/tmp/nullexit-gateway-active.marker`)

### scripts/dns-proxy.py (92 lines, 2.9KB) — ✅ Clean, standalone

### scripts/logger.py (144 lines, 5.9KB) — ✅ Clean, standalone

### scripts/sync-rules.py (666 lines, 29KB)

**Internal duplication:**
- `fetch_remote_domains()` and `fetch_remote_ips()` are structurally identical (fetch → cache → sanity check → stale fallback). Should be a single `fetch_with_cache(url, parser_fn, cache_dir)`.
- `.env` parsing — custom hand-rolled reader duplicates bash scripts' `grep/sed` approach
- AdGuard credentials `admin:nullexit` hardcoded (also in AdGuardHome.yaml as bcrypt hash)

---

## Part 4: Cross-Cutting Issues

### Functions Identical Across macOS ↔ Linux

| Function | macOS toggle | macOS recover | macOS setup | Linux toggle | Linux recover | Linux setup |
|----------|:-----------:|:------------:|:-----------:|:------------:|:-------------:|:----------:|
| `run_with_timeout()` | ✅ | ✅ | — | ✅ identical | ✅ identical | — |
| `stop_local_dns_proxy()` | ✅ | — | — | ✅ identical | — | — |
| `start_local_dns_proxy()` | ✅ | — | — | ~95% similar | — | — |
| `is_gateway_active()` | ✅ | — | — | ~80% similar | — | — |
| `step/ok/warn/die` | — | ✅ | ✅ | — | ✅ identical | ✅ identical |

### Platform-Adapted Functions (same logic, different OS commands)

| Function | Linux Command | macOS Command |
|----------|--------------|---------------|
| `get_active_service()` | `ip route get 1.1.1.1 \| awk '{print $5}'` | `route get default` + `networksetup -listnetworkserviceorder` |
| `reset_dns()` | `resolvectl revert` | `networksetup -setdnsservers` |
| `cleanup_network_state()` | `ip link set dev down/up` | `networksetup -setairportpower off/on` + proxy disable |
| `force_dns_to_gateway()` | `resolvectl dns` + `resolvectl domain ~ts.net` | `networksetup -setdnsservers` + `-setsearchdomains ts.net` |
| `start_sleep_prevention()` | `systemd-inhibit --what=sleep` | `caffeinate -i` |
| `enable/disable_socks_proxy()` | Stub (no-op on Linux) | `networksetup -setsocksfirewallproxy` |
| DNS cache flush | `resolvectl flush-caches` | `dscacheutil -flushcache` + `killall -HUP mDNSResponder` |

### Features Missing From Linux Scripts

These exist in macOS toggle.sh but NOT in toggle-linux.sh:

1. `write_gateway_active_marker()` / `clear_gateway_active_marker()`
2. `restart_tailscaled_daemon()`
3. `start_warp_watcher()` / `stop_warp_watcher()` — WARP liveness monitor
4. `start_host_leak_probe()` / `stop_host_leak_probe()` — host egress leak prober
5. `add_warp_bypass_routes()` / `remove_warp_bypass_routes()` / `setup_exit_node_routing()`
6. `LOG_FILE` structured logging (timestamps to output.log)
7. MSS clamping injection (step 4c)
8. Rule count reporting
9. `--post-wake` mode in recover
10. Container teardown on failure in cleanup_handler

---

## Part 5: Bugs & Stale Code

### 🔴 Bugs

| File | Line | Issue |
|------|------|-------|
| `toggle-linux.sh` | L2 | Comment says "for macOS" — should say Linux |
| `toggle-linux.sh` | L57-69 | `run_gui_cmd()` uses macOS-only `stat -f '%Su' /dev/console` — dead code on Linux |
| `toggle-linux.sh` | L325 | Calls `dscacheutil` (macOS tool) — doesn't exist on Linux |
| `toggle-linux.sh` | L325 | Calls `killall -HUP mDNSResponder` — doesn't exist on Linux |
| `toggle-linux.sh` | L330 | Calls `route -n flush` — Linux uses `ip route flush cache` |
| `recover-linux.sh` | L148 | PID file path `/tmp/nullexit-systemd-inhibit.pid` but toggle-linux writes to `/tmp/nullexit-caffeinate.pid` — **MISMATCH** |
| `recover-linux.sh` | L89-90 | Broken escaping: `ts_args=\"\"` and `grep -iq \"^KILL_SWITCH=true\"` have literal backslash-quotes |
| `setup-linux.sh` | L54 | Uses `grep -oP` (Perl regex) — may not work with all grep versions |
| `benchmark.sh` | L69 | References `test_load.py` (root) instead of `benchmarks/test_load.py` |

### 🟡 Stale Code

| File | Issue |
|------|-------|
| `toggle-linux.sh` | `run_gui_cmd()` is macOS-specific dead code — never called on Linux |
| `toggle-linux.sh` | Colima memory/swap constants present but Colima isn't used on Linux |

---

## Part 6: Constant Duplication Map

| Value | Files |
|-------|-------|
| `162.159.192.1` (WARP endpoint) | docker-compose.yml, routing-fix.sh (now dynamically loaded via .env/common.sh!) |
| `5335` (AdGuard DNS port) | docker-compose.yml, AdGuardHome.yaml, post-rules.txt |
| `5354` (mapped DNS port) | docker-compose.yml, dns-proxy.py |
| `41641` (Tailscale WireGuard) | docker-compose.yml, routing-fix.sh, post-rules.txt |
| `1080` (SOCKS5 port) | docker-compose.yml, toggle.sh |
| `1120` (MSS clamp) | post-rules.txt, .env |
| `admin:nullexit` (AdGuard creds) | AdGuardHome.yaml (bcrypt), sync-rules.py (plaintext) |
| `10.200.1.0/24` (Docker subnet) | (Fixed) no longer duplicated |
| `America/New_York` (timezone) | docker-compose.yml (×4 services) |
| `/tmp/nullexit-caffeinate.pid` | (Fixed) centralized in common.sh |
| `/tmp/nullexit-dns-watcher.pid` | (Fixed) centralized in common.sh |
| `/tmp/nullexit-host-leak-probe.pid` | toggle.sh, recover.sh |
| `/opt/homebrew/bin:...` (PATH) | (Fixed) centralized in common.sh |

---

## Part 7: Refactoring Outcome (Implemented July 2026)

**Decision: "Scripts-only" architecture**
Instead of introducing a new `lib/` directory, all shared code was moved into the existing `scripts/` directory to keep the project hierarchy flat and simple.

### 1. `scripts/common.sh` (288 lines, 10KB)
Extracts the fundamental primitives and networking logic used across orchestrator scripts:
- **Formatters:** `step()`, `ok()`, `warn()`, `fail()`, `die()`
- **Timeout Wrapper:** `run_with_timeout()` (Canonical version with PID tracking, graceful SIGTERM, and SIGKILL fallback)
- **Daemon Lifecycle:** `restart_tailscaled_daemon()`, `stop_pidfile_daemon()` (collapsed caffeinate, DNS watcher, WARP watcher, and host leak prober teardown logic)
- **Network Interface/Routing:** `get_active_service()`, `get_en0_service()`, `bounce_wifi_interfaces()`, `add_warp_bypass_routes()`, `remove_warp_bypass_routes()`
- **Proxy/DNS Cleanup:** `disable_all_proxies()`, `flush_dns_cache()`, `reset_sharing_services()`
- **Configuration Helpers:** `read_adguard_ip()`, `is_kill_switch_enabled()`, `get_warp_endpoint_1()`, `get_warp_endpoint_2()` (which centralizes the hardcoded 162.159.192.1 / .193.1 into .env logic)

### 2. `scripts/setup-common.sh` (~350 lines)
Extracts the heavy, duplicated installation logic shared between `setup.sh` (macOS) and `scripts/setup-linux.sh`:
- Docker and Colima prerequisite checks
- `wgcf` binary download and WARP key generation
- `.env` configuration file generation
- Interactive Tailscale Auth Key and AdGuard Rule Profile prompts

### Sourcing Pattern
- macOS root scripts (`toggle.sh`, `recover.sh`, `setup.sh`) source via:
  `source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/common.sh"`
- Linux sibling scripts (`scripts/toggle-linux.sh`, etc.) source via:
  `source "$(dirname "${BASH_SOURCE[0]}")/common.sh"`
