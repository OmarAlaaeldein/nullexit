# nullexit — Detailed Agent Analysis

> Complete per-file breakdown of every function, constant, duplication, and bug found.
> **Note (July 2026):** `sync-rules.py` and `logger.py` have been fully ported to Go (`scripts/rule-compiler/main.go` and `scripts/logger/main.go`) to dramatically improve performance and reduce container footprint via multi-stage Alpine builds. The analysis below reflects their previous Python states.

## 🛑 Important Agent Instruction
- **NEVER use `cat << EOF` or terminal redirections to write or modify files.** You must always use your native file-editing tools (`replace_file_content` or `multi_replace_file_content`). Using `cat EOF` leads to duplicated text, broken markdown headers, and structural corruption (which previously destroyed the section numbering in `devref.md`).
- **Always run `bash scripts/crypto.sh --sign` after making any modifications to the core bash scripts.** This is required to update the cryptographic HMAC-SHA256 signatures; otherwise, the startup integrity checks will fail and block execution.
- **Always run `git diff` and print the changes to the user *before* requesting or executing any git commit command.** The user must be shown the diff so they can review and understand the changes. Based on this diff, formulate a highly precise, detailed, and descriptive commit message (explaining exactly what was changed and why) rather than a generic summary, and present it to the user alongside the diff.
- **Always run `git status` before `git diff` to identify all modified and untracked files, ensuring no files (such as new scripts or configuration assets) are missed before formulating commit diffs and staging.**
- **Always use the `--restart` flag when asked to restart the toggle (e.g., run `./toggle.sh --restart`).**
- **NEVER execute any `sudo` commands (especially `sudo route`, `sudo dscacheutil`, or any network-modifying commands) without explicitly explaining to the user what the command does and why it is needed FIRST. Do not assume implicit permission. Wait for the user's approval before running it.**
- **When fixing an error and using logs to debug, always show the user the reasoning and the specific logs that support this theory.**
- **When the user tells you to "push", this means read git diffs and prepare commit messages that correspond to these changes (do not ignore any changes). If the changes can be atomized into multiple commits for easier understanding, do so.**
- **When the user says "latex this", it means you should run `python3 scripts/generate_tex.py` to regenerate the unified LaTeX document.**
- **NEVER apply changes to running gateway containers directly via `docker compose up` or `docker compose restart`.** Recreating or restarting containers (especially the `warp` container which hosts the network namespace) breaks the shared network stack for all other services (`adguardhome`, `tailscale`, `routing-fix`), severing host connectivity and freezing macOS DNS. If you need to apply changes or rebuild containers, cleanly stop the gateway first using `./toggle.sh`, or trigger `recover.sh --post-wake` to rebuild and re-verify the network stack safely in the correct dependency order. Do NOT run `./toggle.sh --restart` or any network-rebuilding commands yourself if the execution could sever host network access; instead, explain the changes and ask the USER to run `./toggle.sh --restart` (or `./toggle.sh` stop and start) themselves to safely apply the modifications.

## 🔬 How to Verify Gateway is Working
Whenever modifications are made to the gateway scripts, routing, or containers, execute these verification checks in order:
1. **Container Health:** Run `docker compose ps` to ensure all containers (`warp`, `adguardhome`, `routing-fix`, `tailscale`) are `running` and `healthy`.
2. **DNS Hijacking Status:** Run `networksetup -getdnsservers "Wi-Fi"` (or appropriate network service) and ensure it is set exclusively to the gateway's Tailscale static IP (typically `100.100.21.8`).
3. **DNS Query Interception:** Run `dig @100.100.21.8 google.com` (using the gateway static IP from `.gateway_ip`) to ensure AdGuard Home is active, intercepting, and resolving queries.
4. **Double-Tunnel Egress:** Run `curl -s https://www.cloudflare.com/cdn-cgi/trace | grep warp` to verify the egress is routed through Cloudflare WARP (`warp=on`).
5. **Host Leak Monitoring:** Run `tail -n 30 output.log` and verify the background watchers (DNS + WARP) report healthy status without `LEAK` warnings. For a deeper on-demand audit, run `bash scripts/diagnose-host-leak.sh` (add `--watch` to poll, `--fix` to remediate).

---

## Part 1: macOS Main Scripts

### toggle.sh (2191 lines, unified macOS + Linux)

> **Refreshed 2026-07-15.** Post-unification (`$OSTYPE` switch at L20) + the July-2026 `common.sh` extraction, the tables below reflect the *current* file. Most former "toggle.sh functions" now live in `scripts/common.sh`; the host-leak-probe pair was removed. For the ordered execution flow see **"toggle.sh — Execution Map & Critical Path"** above.

**Functions still defined in `toggle.sh`** — several exist in *both* halves (Linux L63–848 / macOS L878–2191):

| Function | Linux L | macOS L | Purpose |
|----------|---------|---------|---------|
| `_log_exit_breadcrumb()` | 30 | 885 | Write lifecycle-phase breadcrumb on exit (post-mortem trail) |
| `get_free_port()` | 67 | 944 | Pick a random unused port (self- + kernel-collision checked) |
| `run_gui_cmd()` | — | 1033 | Run a command as the logged-in console GUI user |
| `write_gateway_active_marker()` | — | 1053 | Write `/tmp/nullexit-gateway-active.marker` (macOS only) |
| `clear_gateway_active_marker()` | — | 1059 | Remove active marker + `TUNNEL_FAILED_CLOSED.marker` |
| `start_sleep_prevention()` | 145 | 1091 | Start `caffeinate` w/ revert trap |
| `stop_sleep_prevention()` | 188 | — | Stop caffeinate via PID file |
| `stop_dns_watcher()` | 202 | — | Stop DNS watcher (macOS uses `stop_pidfile_daemon`) |
| `start_warp_watcher()` | — | 1164 | Background WARP liveness monitor → `recover.sh` after N fails |
| `stop_warp_watcher()` | — | 1241 | Stop WARP watcher via PID file |
| `cleanup_handler()` | 215 | 1258 | Fail-closed teardown trap (guarded by `SUCCESS_RUN`) |
| `restart_tailscaled_daemon()` | 327 | *(common)* | Restart tailscaled (Linux-half local copy; macOS uses common.sh) |
| `disconnect_tailscale_host()` | 337 | *(common)* | `tailscale down` w/ retry (Linux-half local copy; macOS uses common.sh) |
| `setup_exit_node_routing()` | — | 1430 | Override default route through the Tailscale utun interface |
| `cleanup_network_state()` | 354 | 1464 | Nuclear cleanup: proxies, DNS cache, routes, Wi-Fi, sharing services |

**Delegated to `scripts/common.sh`** (moved out of toggle.sh in the July-2026 refactor; line = common.sh):

| Function | common.sh L | Function | common.sh L |
|----------|-------------|----------|-------------|
| `run_with_timeout()` | 58 | `enable_socks_proxy()` | 769 |
| `is_gateway_active()` | 168 | `disable_socks_proxy()` | 803 |
| `gateway_state()` | 232 | `reset_dns()` | 824 |
| `get_active_service()` | 284 | `stop_local_dns_proxy()` | 898 |
| `restart_tailscaled_daemon()` | 338 | `start_local_dns_proxy()` | 909 |
| `disconnect_tailscale_host()` | 352 | `force_dns_to_gateway()` | 988 |
| `stop_pidfile_daemon()` | 393 | `add_warp_bypass_routes()` | 484 |
| `start_dns_watcher()` | 715 | `remove_warp_bypass_routes()` | 551 |

**Removed:** `start_host_leak_probe()` / `stop_host_leak_probe()` and the whole `HOST_LEAK_PROBE` prober subsystem — no longer defined or called anywhere in `toggle.sh`, `recover.sh`, or `common.sh`, and `HOST_LEAK_PROBE` is no longer an env var (all verified). The only surviving host-leak tool is the standalone, on-demand `scripts/diagnose-host-leak.sh` (there is **no** `scripts/host-leak-probe.sh`).

**Constants / anchors (current):**

| Constant | Value | Line |
|----------|-------|------|
| `LOG_FILE` | `$PWD/output.log` | L22 (Linux) / L863 (macOS) |
| `LOCK_FILE` | `/tmp/nullexit-toggle.lock` | L1020 |
| `PID_FILE` (caffeinate) | `/tmp/nullexit-caffeinate.pid` | L142 |
| `DNS_WATCHER_PID_FILE` | `/tmp/nullexit-dns-watcher.pid` | L200 |
| `WARP_WATCHER_PID_FILE` | `/tmp/nullexit-warp-watcher.pid` | L1144 |
| Gateway active marker | `/tmp/nullexit-gateway-active.marker` | L1054 (write) |
| TUNNEL_FAILED_CLOSED marker | `<repo>/TUNNEL_FAILED_CLOSED.marker` | L1061 |
| `SOCKS_PROXY_PORT` | random per-toggle, `1080` fallback | L91/L107 (Linux) · L968/L986 (macOS) |
| DNS search domain | `ts.net` | L763 |
| `PATH` (via `setup_standard_path`, common.sh) | Homebrew + system bins | L1330 |
| WARP endpoints (via `get_warp_endpoint_1/2`, common.sh) | `162.159.192.1` / `162.159.193.1` | common.sh L335-336 |
| DNS fallback | `1.1.1.1` (in `reset_dns`, common.sh) | common.sh L824 |

---

### toggle.sh — Execution Map & Critical Path (verified 2026-07-15)

> Traced from the current unified `toggle.sh` (2191 lines). The file carries **two halves** selected by `$OSTYPE` at **L20** (`if [[ "$OSTYPE" != "darwin"* ]]` runs the self-contained **Linux path ≈ L63–848** then `exit 0` at ~L845; darwin falls through to the **macOS path ≈ L878–2191**). Line numbers below are the **macOS path** (the deployment target). The halves are *similar in intent but not identical* — see "Linux path — where it diverges" below. `~Line` = current, approximate.

#### Entry & dispatch

```
./toggle.sh [ (no-arg) | --restart | restart ]
     |
     |-- verify HMAC signatures (crypto.sh --verify) --fail--> exit 1   (L857)
     |-- rotate output.log if > 1GB
     |-- arm teardown trap:  ERR/INT/TERM/HUP -> cleanup_handler        (L1317-1320)
     |-- generate random ports (Tor / SOCKS / DNS)                      (L940)
     |
     |-- --restart --> gateway_state? running -> run STOP, then START   (L999)
     |
     '-- no-arg   --> gateway_state?                                    (L1535)
                        running  -> STOP  branch  (L1538-1584)
                        stopped  -> START branch  (L1590-2191)
```

`gateway_state` is driven by `/tmp/nullexit-gateway-active.marker` (persisted intent), falling back to a live container probe.

#### START — synchronous critical path (all must complete)

| # | Step | ~Line | Effect if it fails / is interrupted |
|---|------|-------|-------------------------------------|
| 1 | `disconnect_tailscale_host` (clean slate) | 1595 | host left mesh |
| 2 | `colima_start_until_ready` (readiness poll, §15.8.7) | 1631 | no Docker VM → abort |
| 3 | honey-port reap (`pkill`) + arm (`nc -l`, disowned) | 1695 | tripwire missing (non-fatal) |
| 4 | rule-compile (hash-gated, OFF critical path §15.8.8) | 1708 | reuse prior compiled rules |
| 5 | build-gate routing-fix / tor images | 1743 | rebuild only on change |
| 6 | `docker compose up -d` → warp, tailscale, routing-fix, adguard, tor | 1758 | no gateway |
| 7 | wait tailscaled reachable | 1907 | host tailscale unusable |
| 8 | **host `tailscale set --exit-node=$TS_IP`** | 2046 | **host not routed via gateway → REAL-IP LEAK** |
| 9 | `add_warp_bypass_routes` + `setup_exit_node_routing` | 2048 | WARP endpoint unreachable / wrong route |
| 10 | **`force_dns_to_gateway`** (+ `start_local_dns_proxy`) | 2078 | host DNS not hijacked |
| 11 | `enable_socks_proxy` + verify SOCKS→WARP | 2100 | SOCKS off |
| 12 | print **"STARTED in Ns"** (timing marker) | 2127 | cosmetic only — NOT the commit point |
| 13 | `start_sleep_prevention` (caffeinate) | 2130 | Mac may sleep |
| 14 | `start_dns_watcher` (re-hijack DNS every 30s) | 2134 | no roam DNS recovery |
| 15 | `start_warp_watcher` (warp liveness → recover.sh) | 2138 | no WARP self-heal |
| 16 | **`write_gateway_active_marker`** | 2146 | watcher believes gateway is DOWN |
| 17 | **`SUCCESS_RUN=true`** — disarms the teardown trap | 2164 | *(true commit point)* |
| 18 | print "You can close this terminal window now." | 2191 | — |

#### STOP — critical path

`disconnect_tailscale_host` (1543) → `docker compose down --remove-orphans` (1552) → `colima stop` (1558) → `reset_dns` (1568) → `stop_local_dns_proxy` (1571) → stop caffeinate (1574) → stop DNS watcher (1575) → `stop_warp_watcher` (1576) → `clear_gateway_active_marker` (1577) → "STOPPED in Ns" (1584).

#### Long-lived background processes spawned by START

| Process | Started | PID / reap | Role |
|---------|---------|------------|------|
| honey-port `nc -l localhost $PORT` (disowned) | L1695 | `pkill -f "nc -l localhost"` | port-scan tripwire |
| `caffeinate` | L2130 | `/tmp/nullexit-caffeinate.pid` | prevent system sleep |
| DNS watcher loop | L2134 | `/tmp/nullexit-dns-watcher.pid` | re-hijack DNS every 30s (Wi-Fi roam) |
| WARP watcher loop | L2138 | `/tmp/nullexit-warp-watcher.pid` | monitor warp; fire recover.sh after N fails |
| local DNS proxy `dns-proxy.py` | L2089 | (killed by `stop_local_dns_proxy`) | UDP:53 → gateway DNS fallback |

Separately, the **launchd `scripts/watcher.sh`** daemon (post-wake / post-roam recovery) runs independently of toggle and invokes `recover.sh --post-wake`; toggle does **not** spawn it.

#### `cleanup_handler` — the fail-closed teardown trap

Armed on `ERR/INT/TERM/HUP` (L1317-1320), guarded by `SUCCESS_RUN`. While `SUCCESS_RUN=false` it runs: `reset_dns`, `disconnect_tailscale_host`, `stop_local_dns_proxy`, stop watchers, `clear_gateway_active_marker`, `docker compose down` (+ `colima stop` on `ERR`). This is the **fail-closed guarantee**: a half-built gateway is torn down, not left leaking.

#### ⚠️ Correctness findings (verified against source)

1. **"STARTED in Ns" (L2127) is NOT the commit point — `SUCCESS_RUN=true` (L2164) is.** The marker write (L2146) and watcher starts (L2130-2138) sit *between* them. **Any TERM/INT — including a wrapping tool's timeout — in the L2127→L2164 window fires `cleanup_handler` → a FULL teardown** (containers + colima + host tailscale), leaving the marker ABSENT and the host on its raw ISP link, *despite* the printed success. This is exactly the 2026-07-15 incident. (The Linux half has the same shape but a *much* narrower window: STARTED L814 → `SUCCESS_RUN=true` L820, and it maintains no marker.)
2. **Never pipe `toggle.sh` through a reader** (`| tail`, `| grep`). The disowned children (honey-port, watchers, dns-proxy, caffeinate) inherit stdout, so the pipe never EOFs and the reader hangs long after toggle has exited — which then trips the wrapper's timeout → SIGTERM → finding #1. Run detached with a file redirect instead: `nohup ./toggle.sh --restart > /tmp/t.log 2>&1 &`, then poll the file.
3. **Host wiring is correctly on the synchronous critical path** (steps 8 & 10 precede "STARTED"), so a *completed* START cannot leave the host unrouted/leaking — the only way to that state is an interruption per finding #1.
4. **Namespace ordering:** step 6's `docker compose up` creates warp's network namespace that `tailscale`/`routing-fix`/`adguard` share (compose `depends_on: warp healthy` enforces order). Never `docker compose restart warp` on a live gateway — it detaches the shared netns (see Agent Instruction, L16).

#### Linux path — where it diverges (L63–848)

The Linux half is intent-similar but **not** a line-for-line mirror of macOS. Verified differences:

| Aspect | macOS (L878–2191) | Linux (L63–848) |
|--------|-------------------|-----------------|
| VM layer | Colima (`colima_start_until_ready`, L1631) | none — native Docker |
| Host exit-node assert | `$TS_BIN set … --exit-node="$TS_IP"` (L2046) | `$TS_BIN up --reset … --exit-node="$TS_IP"` (L735) |
| gateway-active marker | written (L2146) | **not maintained** (L119) — `gateway_state` degrades to a live container probe |
| Commit window | STARTED L2127 → `SUCCESS_RUN` L2164 | STARTED L814 → `SUCCESS_RUN` L820 |
| Port gen tooling | `jot` / `netstat` | `shuf`/`$RANDOM` / `ss` |

The `up --reset` vs `set` distinction matters: `--reset` re-applies *all* prefs and forces a route re-eval, whereas `set` mutates only the exit-node pref — the same asymmetry `recover.sh --post-wake` relies on (devref §15.12.21).

---

### recover.sh (566 lines, 23KB)

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
- .gateway_ip reading — L138-142, L209-213 (same pattern as toggle L1080)

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

### toggle.sh — Linux path (unified into the root cross-platform script)

The Linux toggle is no longer a separate file. `scripts/toggle-linux.sh` was
merged into the repo-root `toggle.sh`, which dispatches on `$OSTYPE`: an early
`if [[ "$OSTYPE" != darwin* ]]` block runs the self-contained Linux toggle
(shuf / ss / nmcli / ip / systemd) and exits before the macOS body. The shared
DNS/proxy/daemon primitives it used were already moved to `common.sh` in the
`313dc32` unification, so both branches call them by the same names.

---

### recover.sh — Linux path (unified into the root cross-platform script)

Linux recovery is no longer a separate file. `scripts/recover-linux.sh` was
merged into the repo-root `recover.sh`, which dispatches on `$OSTYPE`: the Linux
branch runs a self-contained teardown (resolvectl / nmcli / ip) and exits before
the macOS dual-mode body. All formatting/timeout helpers come from `common.sh`.

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
3. .env template: macOS adds `GATEWAY_USE_EXIT_NODE`, `WARP_FAIL_THRESHOLD`, `KILL_SWITCH` — Linux omits these

---

## Part 3: Utility Scripts

### scripts/diagnose-host-leak.sh (722 lines, 38KB)

**Purpose:** Comprehensive host-routing diagnostic. 8 checks classify host IP leaks. Supports `--fix` and `--watch` modes.

**Duplicated logic:**
- `resolve_active_service()` — identical pattern as toggle.sh, recover.sh, fix-docker-bridge-collision.sh
- `run_with_timeout()` — reimplemented timeout
- Color codes — RED/GREEN/YELLOW/BOLD/NC with tty detection
- WARP check via `cloudflare.com/cdn-cgi/trace`
- `export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"`
- .gateway_ip reading pattern

### scripts/fix-docker-bridge-collision.sh (402 lines, 18KB)

**Purpose:** Fixes Docker bridge subnet collisions with `10.200.1.0/24`.

**Duplicated logic:**
- `resolve_active_iface()` — same interface detection as diagnose-host-leak.sh
- Color codes, step()/ok()/warn()/fail()/die() formatting helpers

### scripts/fix-ssh-delay.sh (63 lines, 2.7KB)

**Purpose:** One-shot fix for ~20s SSH delay. Standalone, minimal duplication (uses hardcoded ✓/✗ instead of color functions).

### scripts/reinstall-host-tailscale.sh (740 lines, 31KB)

**Purpose:** Complete uninstall + reinstall of host Tailscale.

**Duplicated logic:**
- `with_timeout()` — yet another bash timeout implementation (polling-based, different from diagnose and toggle versions)
- Color codes + logging functions
- System Extension detection logic (similar to diagnose-host-leak.sh)

### scripts/routing-fix.sh (266 lines, 10.5KB)

**Purpose:** Runs INSIDE warp container. Maintains routing table 200, FORWARD rules, country blocking, IP blocklists, tunnel health checks.

**Duplicated logic:**
- (Fixed) WARP_ENDPOINT defaults are now centralized in common.sh
- WARP health check via cdn-cgi/trace (another instance)
- iptables dual-backend pattern (for-loop over `iptables iptables-legacy`)

### scripts/watcher.sh (269 lines, 13KB)

**Purpose:** Long-running launchd daemon for post-wake/post-roam recovery.

**Key function — `detect_lan_p2p_mode()`:**
Added July 10, 2026. Called on startup and on every network state change (Listener 2 NET: events). Determines whether the current Wi-Fi network safely allows direct Tailscale LAN P2P connections:
1. **WPA2-Enterprise check:** `system_profiler SPAirPortDataType` → reads the `Security:` field for the current association. Enterprise = 802.1x = always AP-isolated → sets `allow=false`.
2. **AP isolation probe:** `route -n get 1.1.1.1` → finds default gateway IP, then `ping -c 3 -t 1 -q "$gw"` → if 0 responses on a non-empty network, AP isolation is active → sets `allow=false`.
3. **Output:** Writes `'true'` or `'false'` to `.lan_p2p_detected` in the repo root.
4. **Consumer:** `routing-fix.sh` reads this file every 30 seconds and enforces/relaxes the RFC1918 DROP rule accordingly — no restart required.

**Duplicated logic:**
- PATH export (similar to toggle.sh/recover.sh)
- Marker file pattern (`/tmp/nullexit-gateway-active.marker`)

### scripts/dns-proxy.py (92 lines, 2.9KB) — ✅ Clean, standalone

### scripts/logger.py (144 lines, 5.9KB) — ✅ Clean, standalone

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

These exist in `toggle.sh`'s macOS branch but NOT its Linux branch:

1. `write_gateway_active_marker()` / `clear_gateway_active_marker()`
2. `restart_tailscaled_daemon()`
3. `start_warp_watcher()` / `stop_warp_watcher()` — WARP liveness monitor
5. `add_warp_bypass_routes()` / `remove_warp_bypass_routes()` / `setup_exit_node_routing()`
6. `LOG_FILE` structured logging (timestamps to output.log)
7. MSS clamping injection (step 4c)
8. Rule count reporting
9. `--post-wake` mode in recover
10. Container teardown on failure in cleanup_handler

---



## Part 5: Constant Duplication Map

| Value | Files |
|-------|-------|
| `162.159.192.1` (WARP endpoint) | docker-compose.yml, routing-fix.sh (now dynamically loaded via .env/common.sh!) |
| `5335` (AdGuard DNS port) | docker-compose.yml, AdGuardHome.yaml, post-rules.txt |
| `5354` (mapped DNS port) | docker-compose.yml, dns-proxy.py |
| `41642` (Tailscale WireGuard) | docker-compose.yml, routing-fix.sh, post-rules.txt |
| `1080` (SOCKS5 port) | docker-compose.yml, toggle.sh |
| `1120` (MSS clamp) | post-rules.txt, .env |
| `admin:nullexit` (AdGuard creds) | AdGuardHome.yaml (bcrypt) |
| `10.200.1.0/24` (Docker subnet) | (Fixed) no longer duplicated |
| `America/New_York` (timezone) | docker-compose.yml (×4 services) |
| `/tmp/nullexit-caffeinate.pid` | (Fixed) centralized in common.sh |
| `/tmp/nullexit-dns-watcher.pid` | (Fixed) centralized in common.sh |
| `/opt/homebrew/bin:...` (PATH) | (Fixed) centralized in common.sh |

---

## Part 6: Refactoring Outcome (Implemented July 2026)

**Decision: "Scripts-only" architecture**
Instead of introducing a new `lib/` directory, all shared code was moved into the existing `scripts/` directory to keep the project hierarchy flat and simple.

### 1. `scripts/common.sh` (288 lines, 10KB)
Extracts the fundamental primitives and networking logic used across orchestrator scripts:
- **Formatters:** `step()`, `ok()`, `warn()`, `fail()`, `die()`
- **Timeout Wrapper:** `run_with_timeout()` (Canonical version with PID tracking, graceful SIGTERM, and SIGKILL fallback)
- **Daemon Lifecycle:** `restart_tailscaled_daemon()`, `stop_pidfile_daemon()` (collapsed caffeinate, DNS watcher, and WARP watcher teardown logic)
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
- Scripts under `scripts/` (`watcher.sh`, `diagnose-host-leak.sh`, etc.) source via:
  `source "$(dirname "${BASH_SOURCE[0]}")/common.sh"`

## Agent Verbs / Protocols

### `/sweep` (or `sweep the gateway`)
When the user invokes this verb, the agent MUST perform a full end-to-end connectivity, health, security, and performance audit of the gateway:
1. **WARP Validation:** Run `curl -s https://www.cloudflare.com/cdn-cgi/trace | grep warp=` (must equal `on`).
2. **Tor Proxy & Control Validation:**
   - Source the dynamically generated ports from `/tmp/nullexit-ports.env` (or identify them using `docker compose ps`).
   - **SOCKS5 Check:** Run `curl -s --socks5-hostname 127.0.0.1:$TOR_SOCKS_PORT https://check.torproject.org/api/ip` to confirm the SOCKS5 proxy successfully connects and routes through the Tor network.
   - **Control Port Check:** Query the Tor Control Port using netcat: `echo "PROTOCOLINFO" | nc 127.0.0.1:$TOR_CONTROL_PORT`. Verify it returns a standard `250-PROTOCOLINFO` response, confirming the Control Port is active and communicating.
   - **Circuit & Node Lookup:** Query the Tor Control Port for the active path (`GETINFO circuit-status`). For each active built circuit, parse the relay fingerprints, lookup their IP addresses (`GETINFO ns/id/<fingerprint>`), and resolve their country codes using Tor's local GeoIP database (`GETINFO ip-to-country/<IP>`). Include the list of active circuits, showing the role (Guard/Middle/Exit), nickname, IP, and country of each hop in the final sweep report.
   - **Transparent Onion Validation:** Run `nslookup duckduckgogg42xjoc72x3sjasowoarfbgcmvfimaftt6twagswzczad.onion` to verify it resolves to an IP within `198.18.0.0/15` benchmark range. Verify transparent dark web routing by running `curl -sI -H "Host: duckduckgogg42xjoc72x3sjasowoarfbgcmvfimaftt6twagswzczad.onion" http://<resolved-ip>/` (should return HTTP 301/200).
3. **DNS Leak Validation:**
   - Audit the upstream resolver currently utilized by the host. Run `curl -s https://edns.ip-api.com/json` to fetch details of the DNS resolver processing the client's requests.
   - Verify that the resolver IP and organization returned belong to Cloudflare (e.g., AS13335) or match the WARP tunnel's exit range, and that **no** DNS traffic leaks to the user's raw physical ISP DNS.
4. **Performance Benchmark Audit:**
   - Run the python benchmark script `python3 benchmarks/test_load.py`.
   - Report the overall load speed and the ratio of successfully fetched vs. blocked/failed subresources for the targeted domains to ensure ad-blocking and MTU encapsulation are performing correctly.
5. **Tailscale Mesh Validation:**
   - Run `ping -c 1 100.100.21.8` to ensure the gateway is reachable.
   - Run `tailscale status` to identify all active/online nodes in the mesh.
   - For every online peer returned in the status output, execute a ping check (`ping -c 1 <peer-ip>`) to verify bidirectional connectivity and confirm healthy routing to all active mesh devices.
6. **Log Audit:** Run `tail -n 100 output.log | grep -iE "(error|fail|warn)"` to catch any underlying component failures or warnings.

### `/latex` (or `generate latex`)
When the user invokes this verb, the agent MUST run `python3 -I scripts/generate_tex.py` to regenerate the documentation source code (`nullexit_unified.tex`). The agent MUST NOT attempt to compile the `.tex` file into a PDF (the user handles PDF compilation locally).
