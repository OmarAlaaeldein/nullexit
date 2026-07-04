# nullexit — Complete & Exhaustive Project Review

> **Reviewed:** July 4, 2026  
> **Scope:** Full codebase review (Shell scripts, Go services, Docker infrastructure, CI/CD, documentation)  
> **Verdict:** Production-grade personal network gateway with double-tunnelling (Tailscale + Cloudflare WARP) and self-healing.

---

## Executive Summary & Scorecard

nullexit is an exceptionally well-engineered piece of systems infrastructure. The codebase demonstrates deep expertise in macOS/Linux networking, Docker orchestration, WireGuard tunneling, and defensive shell programming.

The architecture is elegant, the self-healing stack is incredibly mature, and the documentation is in the top percentile of open-source projects. However, the macOS-to-Linux porting of scripts has introduced several platform-specific command leaks and minor bugs that need to be addressed for full Linux parity.

### Overall Scorecard

| Category | Rating | Notes |
|----------|--------|-------|
| **Architecture** | ★★★★★ | Namespace-sharing Docker pattern, layered security, atomic lifecycle |
| **Code Quality** | ★★★★½ | Exceptional for shell scripts. Consistent style, good variable hygiene |
| **Error Handling** | ★★★★☆ | `set -e` + trap cleanup + retry loops + timeout wrappers. |
| **Security** | ★★★★☆ | HMAC integrity, fail-closed, kernel IP blocking. Minus for HTTP ipdeny, default creds, `.env` perms |
| **Self-Healing** | ★★★★★ | 6 failure types × dedicated detectors × automated responses. Best-in-class |
| **Documentation** | ★★★★★ | 144KB devref, Mermaid diagrams, agent instructions, inline rationale. Exceptional |
| **Diagnostics** | ★★★★★ | `diagnose-host-leak.sh` is the gold standard. Classify → explain → fix → verify |
| **macOS Support** | ★★★★★ | Deep platform knowledge: scutil, launchd, caffeinate, Wi-Fi cycling, AirDrop |
| **Linux Support** | ★★★☆☆ | Feature gaps + real bugs from macOS fork. ~10 macOS commands leaked into Linux scripts |
| **CI/CD** | ★★★★☆ | ShellCheck + crypto verify + Docker build. Missing Go linting and integration tests |
| **Go Services** | ★★★★½ | Zero-dependency, multi-stage builds, concurrent fetching. Minor: file handle leak, deprecated APIs |
| **Maintainability** | ★★★★☆ | `common.sh` refactor was right. Cross-platform adds complexity but is well-managed |

---

## Part 1: Deep Code Review — nullexit Core Shell Scripts

### 1. `toggle.sh` (1250 lines)

#### Overall Structure & Readability
- Well-organized: integrity check → log rotation → restart logic → sourcing → function defs → STOP branch → START branch → summary.
- Extensively commented — many comments explain the *why*, not just the *what* (e.g., the explanation of why DNS has no 1.1.1.1 fallback at line 677, or the `\r` carriage-return bug at line 960). This is excellent engineering documentation.
- The file is long (1250 lines) but the logical flow is clear.

#### Error Handling
- ✅ Excellent cleanup handler (`cleanup_handler`) at line 295 traps ERR/INT/TERM/HUP and restores DNS, kills background PIDs, tears down containers, and cleans up network state. Very thorough.
- ✅ `SUCCESS_RUN` flag prevents cleanup from running on successful exit — smart pattern.
- ✅ The `run_with_timeout` wrapper (from common.sh) is used pervasively to prevent wedged daemons from hanging the script.
- ✅ Troubleshooting steps printed on ERR (lines 341-350) are user-friendly.

#### Potential Bugs / Race Conditions
- 🐛 **Line 251-253 inside `start_warp_watcher` nohup heredoc**: The `sleep 5` / `sleep 30` branch uses `"$state"` (expanded by outer shell at definition time, always the initial value) whereas the rest of the heredoc uses `\"$state\"` (inner shell). This means the adaptive sleep interval **doesn't work** — it will always sleep based on whatever `$state` was when the outer shell expanded the heredoc (likely empty/undefined). This is a **real bug**.
- 🐛 **Line 99: `clear_gateway_active_marker` called unconditionally at startup** — this means if two toggle.sh instances run concurrently (e.g., user double-clicks), the second instance clears the marker the first one wrote. There's no lock/mutex to prevent concurrent execution. A PID file or `flock` would fix this.
- 🐛 **Line 1232: `START_GATEWAY` referenced but may be unset** — if the STOP branch runs, `START_GATEWAY` is never set, so `[ "$START_GATEWAY" = "true" ]` will evaluate to false (correct behavior) but ShellCheck would flag the uninitialized variable with `set -u`.
- ⚠️ **Line 44/49: recursive `bash "$0"`** for restart mode — this works but `$0` may resolve incorrectly if the script was invoked via a symlink or from a different CWD.
- **Colima readiness race:** After `colima start`, the script does `sleep 2` then checks `colima status`. If the VM isn't fully ready, subsequent Docker commands could fail. A retry loop would be more robust.
- **PID file staleness:** The script writes `caffeinate` PIDs to a file and kills them on cleanup. If a previous run was `kill -9`'d, stale PID files could cause issues (though the cleanup function handles this gracefully with `kill … 2>/dev/null`).
- **Tailscale race on toggle-off:** When toggling off, the script does `tailscale set --exit-node=` to clear the exit node. If Tailscale is unresponsive (e.g., during a network interruption), this could hang. No timeout wrapper is used here.

#### Security Considerations
- ✅ Integrity verification via `crypto.sh --verify` at the top (lines 8-12).
- ✅ `sudo -n` is used everywhere (non-interactive, relies on NOPASSWD sudoers entries).
- ✅ The shutdown trap in `start_sleep_prevention` (lines 121-146) is a sophisticated defense against DNS leaks on macOS shutdown — even if the process gets killed by the OS, it tries to revert DNS first.
- ⚠️ The `nohup bash -c "..."` pattern in `start_sleep_prevention` and `start_warp_watcher` embeds variable values via string interpolation into the shell code. If `$ACTIVE_SERVICE` or `$EN0_SERVICE` contained shell metacharacters (e.g., a service named `Wi-Fi"; rm -rf /; echo "`), it would be command injection. In practice, these come from `networksetup` output so the risk is negligible, but parameterized approaches (writing to a temp script) would be more robust.
- ⚠️ The `.env` file contains secrets (WARP private keys, Tailscale auth keys). The old comment (lines 31-33) mentions chmod 000 was abandoned — the file sits at default perms now.

#### Bash Best Practices
- ✅ Uses `set -e` for fail-fast.
- ⚠️ Does NOT use `set -u` (unset variable checking) — several variables could be undefined in edge cases.
- ✅ Good quoting throughout — `"$ACTIVE_SERVICE"`, `"$TS_IP"`, etc.
- ⚠️ `$TS_BIN` is used unquoted in several places (e.g., line 425, 1006, 1041) — `run_with_timeout 10 $TS_BIN down $ts_args`. If `TS_BIN` had spaces this would break. Low risk since it's `tailscale`.
- ⚠️ `echo $!` without quotes at lines 175, 258, 289 — should be `echo "$!"`.
- ⚠️ A few places use `echo` where `printf` would be more portable, but since the shebang is `#!/bin/bash`, this is fine.

#### Dead Code / Redundancy
- The `for dns_svc in "$ACTIVE_SERVICE" "$EN0_SERVICE"` loop in `reset_dns` (line 485) and similar dual-service patterns appear ~6 times across the file. Could be a helper function.
- Comment at line 31-33 about a removed chmod pattern — harmless historical note but adds clutter.

#### Strengths
- 🌟 The two-phase Tailscale connection (Phase A: mesh without exit node → Phase B: enable exit node after pre-flight) is excellent engineering. It prevents the exit-node deadlock problem elegantly.
- 🌟 The WARP watcher with adaptive polling (30s normal → 5s on failure) and statistical threshold analysis (line 188-193) is sophisticated and well-reasoned.
- 🌟 The `force_dns_to_gateway` function with retry + read-back verification (lines 680-719) is very robust.
- 🌟 The interactive "press r to reverse" prompt at the end (line 1242) is a great UX touch.

---

### 2. `recover.sh` (485 lines)

#### Overall Structure & Readability
- Clean dual-mode design: full recovery vs. `--post-wake` lightweight refresh. The code is well-separated with clear section headers.
- Good use of the `step`/`ok`/`warn` formatting functions from common.sh.

#### Error Handling
- ✅ `set -e` is used.
- ✅ Sudo credential keeper (lines 84-91) with proper cleanup via `trap EXIT`.
- ⚠️ The EXIT trap `kill $SUDO_KEEPER_PID` (line 91) doesn't quote the variable — `kill $SUDO_KEEPER_PID` would fail silently if empty. More importantly, this trap **overwrites** any previously set EXIT trap. If common.sh ever added one, it would be lost.

#### Potential Bugs
- 🐛 **Lines 277-281**: Redundant code — `if [ -n "${PHYSICAL_GW:-}" ]; then add_warp_bypass_routes; else add_warp_bypass_routes; fi` — both branches call the exact same function. The condition is meaningless dead code. Looks like a refactoring leftover where bypass routes were supposed to be added differently depending on whether a gateway IP existed.
- ⚠️ **Line 141**: `status_exit=$?` captures exit code of the `if` condition, but this is in an `if-else` — `$?` after a failed `if` test is the command's exit code, which is correct here. Subtle but correct.
- ⚠️ **Line 103**: `for src in ADGUARD_IP.txt; do` — this loop iterates over exactly one item. It looks like it once iterated over multiple sources and was reduced. The loop scaffolding is unnecessary overhead now.

#### Strengths
- 🌟 The post-wake mode is genuinely clever — it handles the subtle problem of UDP NAT bindings dying during Wi-Fi roams by selectively force-recreating only the warp container.
- 🌟 Multi-layered internet verification (DNS → HTTP/HTTPS → ping fallback) is robust.
- 🌟 The conditional bypass route restoration after route flush (lines 262-289) prevents a routing loop — shows deep understanding of the network stack.

---

### 3. `scripts/common.sh` (289 lines)

#### Overall Structure & Readability
- Excellent utility library. Clean, focused functions with clear names.
- Good separation of concerns — formatting, network helpers, daemon management.

#### Potential Bugs
- 🐛 **Line 98: `read_env_var`** — `tr -d "\"\\' "` strips ALL spaces from the value, not just leading/trailing. A value like `BLOCKED_COUNTRIES="kp il"` would become `kpil`. This function is used for `BLOCKED_COUNTRIES` in setup-common.sh line 309. However, looking at the actual usage, the value is quoted in .env as `BLOCKED_COUNTRIES="kp il"` and the `tr` strips the double quotes but also strips the space between `kp` and `il`. **This is a real bug for space-delimited values.**
- ⚠️ **Line 61**: `is_gateway_active` references `$LOG_FILE` but common.sh doesn't define it — it relies on the caller having set it. If common.sh is sourced by a script that doesn't define `$LOG_FILE`, these writes would go to a file literally named `$LOG_FILE` or error out.
- ⚠️ **Line 33**: `run_with_timeout` watchdog writes to `output.log` (relative path) — fragile if CWD changes.
- ⚠️ `run_with_timeout` sets global `CURRENT_BG_PID` (line 29) — this is not thread-safe. If two timeouts were nested or concurrent, the outer PID would be lost. Unlikely in practice but a design fragility.

#### Strengths
- 🌟 `stop_pidfile_daemon` (lines 159-175) is a textbook PID-file daemon stopper: check existence → check liveness → SIGTERM → wait → SIGKILL escalation → cleanup PID file.
- 🌟 Cross-platform awareness (darwin vs linux) in `add_warp_bypass_routes`, `flush_dns_cache`, `bounce_wifi_interfaces`.
- 🌟 `get_active_service` (lines 102-130) has excellent fallback logic: route table → ifconfig scan → en0 default.

---

### 4. `scripts/crypto.sh` (69 lines)

#### Overall Structure & Readability
- Very clean and focused. Does one thing well.
- `set -euo pipefail` — the strictest mode. Good.

#### Potential Bugs
- 🐛 **Line 26**: `scripts/routing-fix.sh` is hardcoded in the sign list — but it's not in the verify list's input (the `.signatures` file drives that). If a new file is added to the project, someone has to remember to update this list. There's no auto-discovery.
- ⚠️ **Line 45**: `IFS=:` parsing — if a hash value ever contained a `:`, the parsing would break. SHA-256 hex output never contains `:`, so this is safe in practice.
- ⚠️ The `.signatures` file is not itself signed — an attacker who modifies both a script AND the `.signatures` file can bypass verification. The HMAC seed in .env protects against this only if .env is separately secured.

#### Strengths
- 🌟 Simple, correct, and effective for its purpose.
- 🌟 The `set -euo pipefail` is the gold standard for script strictness.

---

### 5. `setup.sh` (52 lines) + `scripts/setup-common.sh` (451 lines)

#### Potential Bugs
- 🐛 **Line 62 of setup-common.sh**: `grep -oP '[\d.]+' ` — the `-P` (Perl regex) flag is **not available on macOS's grep** (BSD grep). This would fail silently or error on macOS. Should use `grep -oE '[0-9.]+'` instead. **This is a real bug on the target platform (macOS).**
- 🐛 **setup-common.sh line 239**: `TS_AUTHKEY` variable referenced but never initialized with a default before the `if` check. With `set -u` from `setup.sh`, this would cause an "unbound variable" error if `.env` doesn't exist or doesn't have the key. The variable needs `${TS_AUTHKEY:-}` or initialization.
- 🐛 **setup-common.sh line 198**: `curl -sfL ... -o /usr/local/bin/wgcf` — needs `chmod +x` afterward (missing).
- ⚠️ **setup-common.sh line 387**: The AdGuard password is interpolated into a JSON payload inside a `docker exec sh -c "..."` heredoc. Special characters in the password (quotes, backslashes) would break the JSON/shell escaping. The hardcoded default "nullexit" is safe, but a user-set password with `"` or `\` would cause a silent misconfiguration.

#### Strengths
- 🌟 Idempotent design — re-running setup.sh preserves existing `.env` configuration flags.
- 🌟 Auto-installation of dependencies (Docker, Tailscale, wgcf) with clear manual fallback instructions.
- 🌟 The AdGuard API configuration (lines 381-426) is impressively thorough — wizard completion, login, upstream DNS config, filter list registration, and forced refresh in a single `docker exec` call.

---

## Part 2: nullexit Infrastructure & Documentation Review

### 1. `docker-compose.yml` (188 lines)

#### Architecture Decisions
- **Shared network namespace pattern**: All containers (`tailscale`, `routing-fix`, `adguardhome`) use `network_mode: service:warp`, sharing Gluetun's network namespace. This is the correct pattern for VPN gateway stacks — all containers see the same `tun0`, `eth0`, and `tailscale0` interfaces, and port mappings only need to exist on the `warp` container.
- **Strict dependency chain**: `tailscale` depends on both `warp` (healthy) AND `adguardhome` (healthy). `routing-fix` depends on `warp` (healthy) AND `rule-compiler` (completed successfully). This ensures containers don't start into a broken environment.
- **Init container pattern**: `rule-compiler` is a build-time-only service (no restart policy, no healthcheck) — it compiles threat rules and exits. Other services depend on `service_completed_successfully`. Clean pattern.
- **Custom subnet**: `10.200.1.0/24` is explicitly defined for the Docker bridge — avoids collisions with common home networks (`192.168.x.x`, `10.0.0.x`). There's even a dedicated `fix-docker-bridge-collision.sh` script.

#### Docker Networking
- Gluetun owns the namespace and all port mappings: `5354` (AdGuard DNS), `41641` (Tailscale WireGuard), `1080` (SOCKS5 proxy).
- Port `5354` is used instead of `5335` because SSH on the host already uses `5335` — documented inline.
- `FIREWALL_OUTBOUND_SUBNETS` includes all RFC1918 ranges to allow Tailscale LAN-local P2P connections (avoid DERP relay fallback).
- `WIREGUARD_MTU=1280` — critical for double-encapsulation (Tailscale WireGuard inside Cloudflare WARP WireGuard).

#### Security
- `warp` has `cap_add: [NET_ADMIN]` and `devices: [/dev/net/tun]` — necessary for WireGuard, minimal privilege.
- `tailscale` has `cap_add: [NET_ADMIN, NET_RAW, SYS_MODULE]` — `SYS_MODULE` is needed for loading kernel modules in some environments. Slightly broad but standard for Tailscale in Docker.
- `rule-compiler` runs with `cap_add: [NET_ADMIN, NET_RAW]` for `iptables`/`ipset` manipulation. Correct.
- Healthchecks are defined on `warp` (curl cloudflare trace for `warp=on`) and `tailscale` (tailscale status). Good.
- `routing-fix` is a sidecar that runs `routing-fix.sh` to handle `iptables` rules. It uses `network_mode: "service:warp"` and `cap_add: [NET_ADMIN]`. It depends on `tailscale` being healthy.
- Volumes are well-managed: Tailscale state is persisted in `ts_data`, AdGuard config in `./adguard/conf` and `./adguard/work`.

#### Potential Issues
- ⚠️ **`routing-fix` mounts the entire repo root (`.:/app`)** which is broader than necessary — could be tightened to specific files (like `scripts/routing-fix.sh`) to avoid exposing `.env` credentials.
- Gluetun's built-in DNS blocking (`BLOCK_MALICIOUS`, `BLOCK_SURVEILLANCE`, `BLOCK_ADS`) is all set to `off` with the assumption AdGuard handles this. The comment explains no fallback filtering exists if AdGuard fails, but the healthcheck chain mitigates this.
- Logging config is inconsistent: `warp` and `tailscale` get `10m/3 files`, `routing-fix` gets `1m/1 file`, `adguardhome` has no log limit or rotation set.

#### Strengths
- 🌟 The `network_mode: "service:warp"` pattern is elegant — it guarantees traffic chaining without complex routing.
- 🌟 Pinned image versions (`v3.41.1`, `v1.98.4`, `v0.107.77`) — reproducible builds.
- 🌟 `start_period: 60s` on WARP healthcheck gives WireGuard time to establish, with an appropriately aggressive `interval: 2s` after.

---

### 2. `cloud-init.yaml` (39 lines)

#### Architecture
- Minimal bootstrap for Ubuntu/Debian VPS: installs Docker, adds user to docker group, enables IP forwarding, creates `/opt/nullexit`.
- Intentionally **does NOT** clone the repo or start containers — the `final_message` instructs the user to SSH in, clone, add `.env`, and run `./setup-linux.sh`. This is the right approach — keeps secrets out of cloud-init logs.

#### Potential Issues
- Hardcodes `ubuntu` as the default user (with `debian` as fallback). Works for most providers (AWS, DigitalOcean, Hetzner) but would fail on providers using different defaults (e.g., `root` on Vultr).
- Uses `>>` to append to `/etc/sysctl.d/99-tailscale.conf` — running cloud-init twice would create duplicate entries (idempotency issue, though cloud-init rarely runs twice).

---

### 3. `diagrams.md` (360 lines)

#### Documentation Quality
- **Exceptional.** Contains multiple Mermaid diagrams covering:
  1. Full network flow — device → Tailscale → WARP → Internet, with DNS interception and ad-blocking shown.
  2. Docker container architecture — shows namespace sharing and port mappings.
  3. DNS resolution chain — client → iptables DNAT → AdGuard → WARP → Cloudflare.
  4. Toggle lifecycle — state machine for toggle-on/toggle-off with all intermediate steps.
  5. Recovery flow — post-wake recovery decision tree.
  6. Threat model layers — visual representation of the 4-layer security stack.
  7. Routing loop diagrams — both known infinite loop scenarios with visual explanations.

#### Strengths
- The diagrams are not decorative — they document real architectural decisions and failure modes.
- The routing loop diagrams are particularly valuable for anyone trying to understand or modify the networking.
- Well-integrated with `devref.md` section references.

---

### 4. `launchd/com.nullexit.wake-recovery.plist` (69 lines)

#### Implementation
- A macOS LaunchAgent that triggers `recover.sh --post-wake` on two events:
  1. `com.apple.system.wake` — system wakes from sleep.
  2. Network state change — via WatchPaths on `/Library/Preferences/SystemConfiguration/NetworkInterfaces.plist` and `/etc/resolv.conf`.
- Uses `ThrottleInterval` of 10 seconds to prevent rapid re-triggering.
- Logs stdout/stderr to `/tmp/nullexit-watcher.out.log` and `/tmp/nullexit-watcher.err.log` — `/tmp` is cleared on reboot, so post-crash forensics from a prior boot are lost.
- Sets working directory to `__NULLEXIT_HOME__` (replaced by `sed` during installation).

#### Quality
- Correct and well-structured. The `WatchPaths` approach is the right way to detect network changes on macOS.
- `ThrottleInterval` is a good debounce mechanism.
- The `__NULLEXIT_HOME__` placeholder pattern is clean for install-time customization.

#### Potential Issue
- The plist comment references `flock -n`, but `watcher.sh` actually implements a PID-file lock (since macOS doesn't ship `flock`). The comment is slightly misleading.

---

### 5. `scripts/diagnose-host-leak.sh` (710 lines)

#### Overview
This is a **comprehensive diagnostic tool** that classifies host-routing state into known leak scenarios and can auto-remediate.

#### Modes
1. **One-shot diagnostic** (default) — Runs all checks, classifies state, prints fix command.
2. **`--fix`** — Applies the fix automatically.
3. **`--watch`** — Continuous monitoring mode with configurable interval.

#### Leak Scenarios Detected
1. **SOCKS5 fallback** — Host traffic going through Tailscale SOCKS5 instead of WARP.
2. **IPv6 leak** — IPv6 traffic bypassing the tunnel entirely.
3. **Route-table freeze** — Default route stuck pointing at a stale interface after a network change.
4. **WARP endpoint routing** — WARP's own endpoint packets getting captured by the tunnel.

#### Quality
- **Outstanding diagnostic engineering.** Each scenario has a detection heuristic (checking route tables, interface states, curl tests), a human-readable explanation of what went wrong, and an exact fix command.
- The `--watch` mode is particularly well-done: it runs a full baseline, then continuously monitors for state changes, printing alerts on any drift.

#### Potential Issues
- 🐛 **Missing Source Statement:** `resolve_active_service()` on line 292 calls `get_active_service` which isn't defined in this script — it must be sourced from `scripts/common.sh`, but there's no `source` statement visible. This would cause a runtime error if run standalone.
- The `run_with_timeout()` implementation spawns a background watcher that does `kill -9` (SIGKILL) — no graceful SIGTERM first.
- Hardcodes `1.1.1.1` as the DNS fallback check target.

---

### 6. `scripts/host-leak-probe.sh` (120 lines)

#### Overview
- Sub-second host-egress leak detector that polls Cloudflare's `cdn-cgi/trace` every 300ms directly from the host NIC.
- Detects "flash leaks" — brief moments when traffic bypasses the tunnel.
- Logs all state transitions (`LEAK`, `ROTATE`, `OK`) to `output.log`.

#### Quality
- Small, focused, and well-implemented.
- Uses `curl --connect-timeout 0.3` for fast failure detection.
- State machine logic is clean: tracks previous state, only logs on transitions.
- The 300ms polling interval is aggressive but appropriate for detecting transient leaks.

#### Potential Issues
- At 300ms polling, Cloudflare could rate-limit the client. The script doesn't implement exponential backoff on failures.
- Millisecond-precision timestamps use `date +%3N` which isn't portable (works on GNU `date`, not BSD `date` on macOS without Homebrew coreutils). There is a fallback check but it tests for literal `3N` in the output.

---

### 7. `scripts/watcher.sh` (212 lines)

#### Overview
- The launchd-triggered watcher daemon. Runs on wake/network-change events.
- Checks: Colima status → Docker status → container health → WARP connectivity → DNS resolution.
- If any check fails, triggers appropriate recovery.

#### Quality
- Well-structured with progressive checks.
- Has a 30-second cooldown after last recovery to prevent thrashing.
- Logs all actions to `output.log` with timestamps.
- Uses lock files to prevent concurrent executions.

#### Potential Issues
- ⚠️ The subsystem-based `log stream` predicate (`subsystem == "com.apple.powermanagement"`) is broader than the previous phrasing-based one — it will fire on `didDim`, `didUndim`, etc. (not just wake events). The debounce mitigates this but it means extra `recover.sh --post-wake` invocations.

---

### 8. `scripts/routing-fix.sh` (236 lines)

#### Overview
- Docker sidecar script that runs inside the `routing-fix` container.
- Handles:
  1. DNS interception — Sets up iptables DNAT rules to redirect port 53 traffic to AdGuard.
  2. MSS clamping — Applies TCP MSS clamping to prevent MTU issues in double-tunneled traffic.
  3. Rule compilation — Waits for the `rule-compiler` to finish, then loads the compiled `ipset` rules.
  4. Signal handling — Listens for `SIGHUP` to reload rules without container restart.
  5. Geo-IP blocking — Downloads country IP ranges and blocks them via `ipset`.

#### Quality
- **Production-grade.** The `SIGHUP` reload mechanism is a nice touch for zero-downtime rule updates.
- `iptables` rules are applied atomically using chains and `ipset swap`.
- MSS clamping is correctly applied to both IPv4 and IPv6.
- The geo-IP blocking implementation is clean: downloads zone files, creates ipsets, adds iptables rules.

#### Potential Issues
- ⚠️ **Country block data is fetched from `http://www.ipdeny.com` (plain HTTP, not HTTPS)** — vulnerable to MITM during zone file download. An attacker could inject routes.
- The 30-second re-assertion loop means there's a window where rules could be missing after a Gluetun restart.
- The `ipset restore` for the IP blocklist doesn't have a size/sanity check — a corrupted file could flush the entire set.

#### Strengths
- The atomic ipset swap prevents any window where rules are partially applied.
- Signal-driven reloading is the Unix Way™.

---

### 9. `agent.md` (394 lines)

#### Overview
- A **comprehensive developer reference** for AI coding agents working on this codebase.
- Covers: architecture, file map, coding standards, known pitfalls, testing procedures.

#### Quality
- **Excellent.** One of the most thorough agent reference documents.
- Includes exact file locations, Docker networking model explained in detail, known failure modes and how to handle them, coding conventions, testing checklists, and forbidden actions.
- The "Forbidden Actions" section is particularly valuable — it prevents common mistakes.

---

## Part 3: Supporting Scripts, Platform-Specific Files, Go Programs, Dockerfiles, CI, and Benchmarks

### 1. `scripts/toggle-linux.sh` (918 lines)

#### Purpose
Main gateway toggle script for the Linux platform—starts/stops Docker containers, manages Tailscale, DNS hijacking, exit-node routing, sleep prevention, SOCKS5 proxy, and a local DNS proxy fallback.

#### Strengths
- **Extremely robust error handling:** A `cleanup_handler` traps ERR, INT, TERM, HUP and restores DNS/Tailscale/proxy state on any failure. Sets a `SUCCESS_RUN` flag to avoid double-cleanup.
- **Shutdown trap via systemd-inhibit:** The sleep prevention wrapper includes a SIGTERM trap that surgically restores DNS during OS shutdown—avoids running the heavy `recover-linux.sh`.
- **DNS watcher for Wi-Fi roaming:** A background process polls every 30s and re-applies DNS if it drifts (e.g., on Wi-Fi reconnect/roaming).
- **Pre-flight checks (3-step):** Validates Tailscale reachability, AdGuard DNS, and WARP container internet before enabling exit node. Graceful fallback to SOCKS5 proxy if checks fail.
- **Tailscaled recovery:** Automatically restarts tailscaled via `systemctl restart tailscaled` if it appears wedged.
- **Interactive reverse:** At script end, user can press `r` to instantly toggle state back.

#### Potential Issues (macOS-specific Command Leaks)
- 🐛 **macOS-specific references throughout:** Comments mention "macOS", `dscacheutil`, `mDNSResponder`, `networksetup`, `Colima`, `.applescript`—these are vestigial from the macOS version fork. Specifically:
  - **Line 315:** `dscacheutil` check (macOS tool) alongside `resolvectl flush-caches`.
  - **Line 318:** `killall -HUP mDNSResponder` (macOS-only daemon).
  - **Lines 179-184:** Troubleshooting mentions `colima status` which is macOS/Colima-specific.
  - **Line 389:** `"Python3 is built into macOS — this shouldn't happen."` (wrong platform).
  - **Lines 521-527:** Colima stop logic (Colima is macOS, not typical for Linux).
  - **Lines 557-569:** Entire Colima VM boot + swap configuration section—wouldn't apply to native Docker on Linux.
  - **`run_gui_cmd()` function (line 37-49):** References `/dev/console` and `stat -f '%Su'` (macOS `stat` syntax). On Linux, `stat -f` has different semantics.
  - **`route -n flush` (line 323):** This is macOS syntax; Linux uses `ip route flush cache`.
  - **Line 841:** Fallback messages still mention `networksetup -setdnsservers`.
- `START_GATEWAY` variable referenced at line 902 but never explicitly set.

---

### 2. `scripts/setup-linux.sh` (63 lines)

#### Purpose
One-shot Linux setup wrapper. Sources `common.sh` + `setup-common.sh`, then creates `.desktop` shortcut files.

#### Potential Issues
- The `.desktop` `Exec=` uses `bash -c "cd '$DIR' && ..."` which could break if `$DIR` contains single quotes.
- No `chmod +x` on the `.desktop` files (some desktop environments require it).

---

### 3. `scripts/setup-common.sh` (451 lines)

#### Purpose
Shared setup logic for both macOS and Linux—installs Docker, Python 3, Tailscale, wgcf, generates WARP profiles, writes `.env`, starts containers, configures AdGuard via REST API.

#### Strengths
- **Cross-platform branching:** Clean `$OSTYPE` checks for darwin vs linux-gnu throughout.
- **Version pinning awareness:** Documents confirmed-stable versions with warnings when actual differs from recommended.
- **Architecture detection for wgcf:** Handles x86_64, aarch64, armv7l.
- **Idempotent:** Preserves existing .env values if file exists. Skips steps if tools already installed.
- **AdGuard API configuration:** Complete 6-step API setup (wizard, wait, login, upstream DNS, filter registration, filter refresh) all in a single `docker exec` session.

#### Potential Issues
- **Hardcoded default password:** `ADGUARD_PASSWORD="nullexit"` (line 265-266). Documented but worth noting for security.
- **wgcf binary download (line 196-198):** Downloads to `/usr/local/bin/wgcf` but never `chmod +x` it.
- **AdGuard password escaping (lines 387, 401):** Uses `${ADGUARD_PWD_ESC}` inside a heredoc `sh -c` string—if password contains `'`, `"`, or `\`, the JSON could break.

---

### 4. `scripts/recover-linux.sh` (227 lines)

#### Purpose
Nuclear recovery script—undoes everything toggle does on Linux. Disconnects Tailscale, resets DNS, flushes routing, stops containers, power-cycles Wi-Fi, verifies internet.

#### Potential Issues
- 🐛 **Lines 59-60: Escape quoting bug:**
  ```bash
  ts_args=\"\"
  if grep -iq \"^KILL_SWITCH=true\" .env 2>/dev/null; then ts_args=\"--accept-risk=lose-ssh\"; fi
  ```
  These lines have literal backslash-escaped quotes (`\"`) which would NOT be interpreted correctly in a normal bash script context. They look copy-pasted from a heredoc or `nohup bash -c` block where escaping was needed. The variable assignment will contain literal `\"` characters instead of empty/correct values.
- 🐛 **PID file path mismatch (line 118):** Uses `/tmp/nullexit-systemd-inhibit.pid` but `toggle-linux.sh` uses `/tmp/nullexit-caffeinate.pid` (line 51). The recovery script won't find the actual PID file.
- **Comment says "macOS" in step 4 header (line 90):** `# ─── 4. Flush macOS DNS cache`.
- **`sudo route -n flush` (line 220):** This is macOS syntax, not Linux. Should be `sudo ip route flush cache`.

---

### 5. `scripts/fix-docker-bridge-collision.sh` (399 lines)

#### Purpose
Detects and fixes Docker bridge (172.17.0.0/16) colliding with Wi-Fi subnet on campus/enterprise networks. Edits Colima YAML, restarts, rebinds DHCP, re-runs toggle and diagnostics.

#### Strengths
- **Excellent problem analysis:** Header comments thoroughly explain the root cause (Docker's 172.17.0.0/16 vs campus 172.16.0.0/12).
- **RFC1918 family-aware candidate selection:** Avoids naive prefix matching by classifying the host's /8 family first, then picking candidates from a different family entirely. Properly handles the case where 172.26.0.1/24 is still inside 172.16.0.0/12.
- **Dry-run mode (`--dry`):** Previews all changes without executing anything.
- **`--skip-toggle` option:** Fix the bridge without restarting the gateway.

#### Potential Issues
- **Colima-specific:** This is fundamentally a Colima/macOS script (edits `~/.colima/default/colima.yaml`). The Linux path at step 6 uses `dhclient` which is correct, but the core fix targets Colima's Docker bridge.
- **`resolve_active_iface()`** uses macOS `ifconfig` + `route get` syntax, not `ip route` (Linux).
- **Step 7** uses `netstat -rn` (macOS) instead of `ip route` (Linux).
- **No `set -e`** — intentional and well-documented (line 38-41). Good engineering decision.

---

### 6. `scripts/reinstall-host-tailscale.sh` (740 lines)

#### Purpose
Complete uninstall + reinstall of Homebrew-managed Tailscale on macOS hosts. Handles wedged LaunchAgents, orphan processes, stale state, Network Extensions, Login Items.

#### Strengths
- **Exceptionally thorough:** 9 steps covering brew services, orphan process killing, brew uninstall (with root-owned keg detection), state directory wipe, LaunchAgent plist cleanup, Login Items drainage, fresh install, quarantine xattr stripping, multi-tier service startup recovery.
- **4-tier service startup recovery:** (1) `launchctl kickstart`, (2) explicit plist `bootout + bootstrap`, (3) `brew services restart`, (4) direct binary spawn with stderr capture. Each tier has polling loops.
- **3-strategy aliveness detection:** API check (`tailscale status`), process check (`pgrep`), launchctl PID check.

#### Potential Issues
- **macOS-only:** This entire script is macOS/Homebrew-specific. Not applicable to Linux at all.
- **Hardcoded `/opt/homebrew/` paths:** Won't work on Intel Macs where Homebrew installs to `/usr/local/`. The script partially handles this (lines 590-596 for plist path) but direct binary references at lines 511, 642, 677-678 are Apple Silicon–only.
- **`sfltool reset-login-items` (line 446):** Wipes ALL Login Items system-wide—aggressive but documented.

---

### 7. `scripts/fix-ssh-delay.sh` (63 lines)

- Fixes ~20s SSH connection delay caused by `UseDNS yes` doing PTR lookups on 100.x.x.x CGNAT addresses.
- **`sed -i ''` on line 32, 35:** macOS BSD sed syntax. Will fail on Linux (`sed -i` without argument works on GNU sed).

---

### 8. `scripts/unlock-files.sh` (26 lines)

- Bypasses file-lock issues by atomically copying locked files to temp then moving back (effectively re-creating with current user ownership).
- **Line 9:** Uses `sudo cat` to read `.env` (root-readable) then writes to `.env.tmp` as current user. The `mv` could fail if the directory is root-owned.

---

### 9. `scripts/dns-proxy.py` (92 lines)

- UDP-to-TCP DNS proxy. Listens on UDP:53, forwards to AdGuard at TCP:5354, handles DNS-over-TCP wire format (2-byte length prefix).
- **No logging of failures:** `except Exception: pass` in `handle_query()` silently swallows all errors.
- **TCP connection per query:** Each DNS query opens a new TCP connection. Under load, this could exhaust file descriptors. A connection pool would be more efficient but adds complexity.

---

### 10. `scripts/logger/` (Go program)

#### `main.go` (269 lines)
Dual-purpose block logger that monitors both DNS blocks (from AdGuard's `querylog.json`) and IP blocks (from kernel log `/proc/kmsg`).

#### Potential Issues
- 🐛 **`tailFile()` re-open after rotation (line 72):** Opens new file but doesn't `defer f.Close()` on the re-opened handle—the original `defer f.Close()` only covers the first open. **This is a file descriptor leak.**
- **`os.SEEK_END` (line 52):** Deprecated; should use `io.SeekEnd`.
- **`f.WriteString(formattedMsg)` (line 32):** Return value (bytes written, error) is silently ignored.
- **No buffered writes:** Each log message opens/writes/closes the output file. Under high block rates, this could be I/O intensive.

---

### 11. `scripts/rule-compiler/` (Go program)

#### `main.go` (821 lines)
Compiles DNS filter rules from multiple remote blocklists + local black/white lists into AdGuard-compatible format. Also compiles IP blocklists into ipset format.

#### Potential Issues
- **MD5 for cache keys (line 270):** MD5 is fine for non-security cache hashing but technically deprecated. SHA256 would be more modern.
- **YAML parsing via regex (lines 195-217):** Parses `AdGuardHome.yaml` using regex (`(?ms)^filters:...`) instead of a proper YAML parser. Fragile if YAML structure changes.
- **No context/cancellation:** HTTP requests have 15s timeout but no `context.Context` for graceful cancellation.
- **No fallback on total failure:** If all feeds fail and no cache exists, it compiles an empty ruleset, disabling the IP firewall. A cached fallback would be more resilient.

---

### 12. `benchmarks/benchmark.sh` (89 lines)

- Runs Lighthouse audits on ad-heavy sites with and without the gateway.
- **Line 69:** References `test_load.py` (in current dir) but line 46 references `benchmarks/test_load.py`. Inconsistent paths—phase 3 would fail.

---

### 13. Dockerfiles

#### `scripts/Dockerfile.rule-compiler` (10 lines)
Multi-stage build: Go 1.22-alpine builder → alpine:3.20 runtime. Clean.

#### `scripts/Dockerfile.routing-fix` (11 lines)
Based on alpine:3.19. Installs only needed tools: `iptables`, `iproute2`, `curl`, `ipset`.

---

### 14. `.github/workflows/ci.yml` (52 lines)

- CI pipeline that runs on push/PR to main. Validates Python syntax, lints shell scripts, validates Docker Compose config.
- ⚠️ **No Go compilation check:** The rule-compiler and logger Go code are not built or linted in CI. `go vet`, `go build`, or `golangci-lint` would catch compile errors.
- ⚠️ **No Hadolint:** Dockerfiles are not linted.

---

## Part 4: Cross-Cutting Themes & Porting Gaps

1. **macOS→Linux porting artifacts:** `toggle-linux.sh`, `recover-linux.sh`, and `fix-ssh-delay.sh` contain substantial macOS-specific references (Colima, `networksetup`, `mDNSResponder`, `stat -f`, `sed -i ''`, `route -n flush`) that are either dead code or would fail on Linux.
2. **PID file inconsistency:** `toggle-linux.sh` uses `/tmp/nullexit-caffeinate.pid`; `recover-linux.sh` looks for `/tmp/nullexit-systemd-inhibit.pid`.
3. **Go code quality:** Both Go programs are zero-dependency stdlib-only. Clean, readable, well-structured. Minor issues with deprecated APIs and error handling.
4. **Defensive programming:** Excellent throughout—fallback paths, caching, timeout wrappers, idempotency, dry-run modes.
5. **Documentation quality:** Outstanding in-code comments explaining not just what but WHY decisions were made.
6. **Security:** Default password "nullexit" is hardcoded. Credentials only sent to localhost. WARP keys stored in `.env` (gitignored). No secrets in CI.
7. **CI gaps:** No Go linting/building, no integration tests.
8. **Inconsistent logging config** across containers (some have log rotation, AdGuard doesn't).
9. **`.:/app` bind mount** in routing-fix gives the container access to the entire repo including `.env` with secrets.

---

## Part 5: Master Actionable Recommendations

### High Priority
1. **Fix the 3 critical bugs** — the adaptive sleep, `grep -oP`, and `read_env_var` space-stripping.
2. **Add `flock`/PID-file mutex to `toggle.sh`** — concurrent invocations (e.g., double-clicking the .app launcher) would race on the gateway marker.
3. **Harden `.env` permissions** — `chmod 600 .env` after creation in setup scripts.
4. **Fix Linux script bugs** — the PID file mismatch, macOS command leakage, and escape quoting bugs in `recover-linux.sh` and `toggle-linux.sh` would cause real failures.
5. **Add missing `chmod +x`** on `wgcf` binary in `setup-common.sh`.

### Medium Priority
6. **Add Go build/lint to CI** — the rule-compiler and logger Go code aren't validated in the pipeline. `go vet` + `go build` would catch compile errors.
7. **Add `Hadolint` to CI** — Dockerfile linting alongside ShellCheck.
8. **Switch ipdeny.com to HTTPS** — or verify checksums on downloaded zone files.
9. **Remove or archive `dns-proxy.py`** — if it's truly unused after the Python elimination, it adds confusion.
10. **Consider `set -u` in `toggle.sh`** — currently only `set -e` is used, but several variables could be undefined in edge cases.
11. **Fix `logger/main.go` file handle leak** — close old handle before re-opening on rotation.
12. **Fix `logger/main.go` deprecated API** — `os.SEEK_END` → `io.SeekEnd`.
13. **Tighten routing-fix volume mount** — mount only specific files instead of `.:/app`.
14. **Add log rotation config to AdGuard** in `docker-compose.yml` for consistency.
15. **Fix `diagnose-host-leak.sh`** to source `common.sh` explicitly for standalone use.
