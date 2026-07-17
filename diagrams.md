# nullexit — Flow Diagrams & Architecture

---

## 1. System Architecture — What's Running & Where

```mermaid
graph TB
    subgraph INTERNET["☁️  Internet / Cloudflare Edge"]
        CF["Cloudflare WARP\n(Exit Point)\nwarp=on"]
    end

    subgraph TAILNET["🌐 Tailscale Mesh (100.x.x.x)"]
        PHONE["📱 Phone / Laptop\n(Tailnet Client)"]
    end

    subgraph MACHOST["💻 macOS Host"]
        direction TB
        PFFIREWALL["macOS pf Firewall\n(Kill-Switch & TCP MSS Clamping)"]
        TSDAEMON["tailscaled\n(brew service)\nhost Tailscale"]
        HOSTDNS["Host DNS\n→ Gateway IP\n(hijacked by toggle.sh)"]
        HOSTSOCKS["Host SOCKS5\n127.0.0.1:1080\n(fallback only)"]
        HOSTTOR["Host Tor SOCKS5\n127.0.0.1:$TOR_SOCKS_PORT\n(randomized)"]
        HOSTTORCTRL["Host Tor Control\n127.0.0.1:$TOR_CONTROL_PORT\n(randomized)"]

        subgraph MONITORS["🔍 Background Daemons (toggle.sh children)"]
            WARPWATCH["WARP Watcher\n(every 30s, via docker exec)\n→ output.log"]
            DNSWATCHER["DNS Watcher\n(re-hijacks if drift detected)\n→ output.log"]
            CAFFEINATE["caffeinate -i\n(sleep prevention)"]
        end

        subgraph COLIMAVM["🖥️  Colima VM (Linux, 600MB RAM)"]
            subgraph NETNS["warp container network namespace (shared by ALL containers)"]
                GLUETUN["warp / Gluetun\nWireGuard → tun0\n(owns the namespace)"]
                TS["tailscale container\nAdvertises exit node\ntailscale0 interface"]
                SOCKS["tailscale\nSOCKS5\nport 1080"]
                ADGUARD["adguardhome\nDNS sinkhole\nport 5335"]
                ROUTINGFIX["routing-fix sidecar\nGeo-IP Blocking & Go Logger\n(writes blocked.log)"]
                TOR["tor container\nSOCKS5: port 9050\nControl: port 9051\nTransparent Proxy: port 9040\nDNSPort: port 5353"]
            end
        end

        subgraph LAUNCHD["⏰ launchd (always-on)"]
            WATCHER["scripts/watcher.sh\n(sleep/wake + Wi-Fi roam\n+ LAN P2P auto-detection)"]
        end
    end

    subgraph RECOVERY["🚨 Recovery"]
        RECOVER["recover.sh\n(nuclear reset)"]
        RECOVERPOST["recover.sh --post-wake\n(light refresh)"]
    end

    %% Traffic flow
    PHONE -->|"WireGuard / Tailscale mesh"| TSDAEMON
    TSDAEMON -->|"exit-node route utun*"| TS
    TS -->|"FORWARD → tun0 (MASQUERADE)"| GLUETUN
    GLUETUN -->|"WireGuard UDP (macOS Host Egress)"| PFFIREWALL
    PFFIREWALL -->|"TCP MSS Clamped / Kill-Switch check"| CF
    TS -->|"198.18.0.0/15 PREROUTING redirect"| TOR
    TOR -->|"internal path / exit nodes via tun0"| GLUETUN

    %% DNS
    HOSTDNS -->|"UDP:53 → TCP:5354"| ADGUARD
    ADGUARD -->|"DNS upstream via tun0"| CF
    ADGUARD -->|"onion queries → localhost:5353"| TOR

    %% Monitoring
    WARPWATCH -->|"docker exec warp wget cdn-cgi/trace"| GLUETUN
    DNSWATCHER -->|"networksetup -getdnsservers"| HOSTDNS

    %% Logging
    ROUTINGFIX -->|"writes"| BLOCKEDLOG["blocked.log\n(Host-side)"]
    HOSTTOR -->|"port mapping"| TOR
    HOSTTORCTRL -->|"port mapping"| TOR

    %% Recovery triggers
    WARPWATCH -->|"≥6 consecutive warp=off"| RECOVER
    WATCHER -->|"sleep/wake / roam"| RECOVERPOST
    RECOVERPOST -->|"if gateway unhealthy"| RECOVER
    WATCHER -->|"writes .lan_p2p_detected"| ROUTINGFIX

    style MONITORS fill:#1a1a2e,color:#e0e0ff
    style COLIMAVM fill:#0d2137,color:#e0e0ff
    style NETNS fill:#0a1628,color:#e0e0ff
    style RECOVERY fill:#2d0a0a,color:#ffe0e0
    style INTERNET fill:#0a2d1a,color:#e0ffe0
    style TAILNET fill:#1a2d0a,color:#e8ffe0
    style LAUNCHD fill:#2d1a2d,color:#ffe0ff
```

---

## 2. toggle.sh — Full START Flow

```mermaid
flowchart TD
    START(["./toggle.sh"])
    CHECK{"is_gateway_active?\n(containers running OR\nDNS ≠ 1.1.1.1)"}

    START --> CHECK
    CHECK -->|"YES → already ON"| STOPFLOW["→ See STOP Flow"]
    CHECK -->|"NO → start it"| S1

    S1["1. Reset DNS → 1.1.1.1\n(prevent deadlocks)"]
    S2["2. tailscale down\n(prevent exit-node routing during boot)"]
    S3["3. Check Colima VM\n(colima start --memory 0.6 --vm-type vz --network-address --network-mode bridged)"]
    S4["4. Configure VM swap\n(400MB, prevent OOM)"]
    S5["5. Clean corrupted AdGuard config\n(prevent container crash loop)"]
    S6["6. docker compose up -d --build\n(compile Go threat rules & boot containers)"]
    S7["7. Poll tailscale status\n(wait for 'offers exit node'\nup to 60s)"]
    TSREADY{"container\nTailscale ready?"}
    ABORT(["❌ ABORT\n→ cleanup_handler"])
    S8["8. Resolve gateway Tailscale IP\n(.gateway_ip or docker exec)"]
    S9["9. Verify tailscaled running\n(auto-start if needed)"]
    S10["10. tailscale up --reset\n--exit-node=\n--accept-routes=true\n--ssh=true --accept-dns=false"]

    PF1{"Pre-flight 1/3\ntailscale ping gateway"}
    PF2{"Pre-flight 2/3\ndig +tcp AdGuard DNS"}
    PF3{"Pre-flight 3/3\nWARP internet check"}
    ALLPASS{"All 3 pass?"}

    EXITPATH["✅ EXIT NODE PATH\n• tailscale up --exit-node=\n• force_dns_to_gateway (3× retry)\n• SOCKS5 disabled"]
    SOCKSPATH["⚠️ SOCKS5 FALLBACK PATH\n• macOS SOCKS5 → 127.0.0.1:1080\n• DNS proxy → 127.0.0.1:53\n• No exit node (SKIP_EXIT_NODE=true)"]

    DAEMONS["Start background daemons\n• caffeinate -i (sleep prevention)\n• DNS Watcher\n• WARP Watcher\n(all write → output.log)"]

    RULECOMPILE["Rule compiler status\n(log rule/IP counts)"]
    WRITEMARKER["write_gateway_active_marker\n(/tmp/nullexit-gateway-active.marker)"]
    DONE(["✅ Gateway UP"])

    S1 --> S2 --> S3 --> S4 --> S5 --> S6 --> S7
    S7 --> TSREADY
    TSREADY -->|"NO (40× NoState)"| ABORT
    TSREADY -->|"YES"| S8
    S8 --> S9 --> S10
    S10 --> PF1 --> PF2 --> PF3
    PF1 & PF2 & PF3 --> ALLPASS
    ALLPASS -->|"YES"| EXITPATH
    ALLPASS -->|"NO"| SOCKSPATH
    EXITPATH --> DAEMONS
    SOCKSPATH --> DAEMONS
    DAEMONS --> RULECOMPILE --> WRITEMARKER --> DONE

    style ABORT fill:#5c1010,color:#fff
    style EXITPATH fill:#0a3d1a,color:#c0ffc0
    style SOCKSPATH fill:#3d2d00,color:#ffe0a0
    style DAEMONS fill:#0a1f3d,color:#c0d8ff
    style DONE fill:#0a3d1a,color:#fff
```

---

## 3. toggle.sh — STOP Flow

```mermaid
flowchart TD
    STOP(["./toggle.sh\n(gateway already ON)"])

    ST1["1. tailscale down\n(disconnect from mesh)"]
    ST2["2. docker compose down -t 5\n(stop all containers)"]
    ST3["3. Reset DNS → 1.1.1.1\n(networksetup on all services)"]
    ST4["4. stop_local_dns_proxy\n(kill Python UDP proxy)"]
    ST5["5. stop_pidfile_daemon\n(kill caffeinate, rm PID)"]
    ST6["6. stop_pidfile_daemon\n(kill DNS Watcher, rm PID)"]
    ST7["7. stop_warp_watcher\n(kill WARP Watcher, rm PID)"]
    ST8["8. clear_gateway_active_marker\n(rm /tmp/nullexit-gateway-active.marker)"]
    ST9["9. cleanup_network_state\n• disable_all_proxies\n• Flush DNS cache (dscacheutil)\n• Flush stale routes\n• Power-cycle Wi-Fi (off→on)"]

    DONE(["✅ Gateway DOWN\nInternet restored"])

    STOP --> ST1 --> ST2 --> ST3 --> ST4
    ST4 --> ST5 --> ST6 --> ST7 --> ST8 --> ST9 --> DONE

    style DONE fill:#0a3d1a,color:#fff
```

---

## 4. Monitoring Layer — The 3 Background Daemons

```mermaid
graph LR
    subgraph DAEMONS["Background Daemons (all start with gateway, stop on teardown)"]
        direction TB

        subgraph D1["☕ Sleep Prevention"]
            CAFF["caffeinate -i\nPID: /tmp/nullexit-caffeinate.pid\n\nKeeps Mac awake while\ngateway is active"]
        end

        subgraph D2["🔁 DNS Watcher"]
            DNSW["Polls networksetup every ~30s\nPID: /tmp/nullexit-dns-watcher.pid\n\nIf DNS drifts from gateway IP\n→ re-hijacks automatically\n→ output.log"]
        end

        subgraph D3["🔭 WARP Watcher"]
            WARPW["Polls every 30s via:\ndocker compose exec warp wget cdn-cgi/trace\nPID: /tmp/nullexit-warp-watcher.pid\n\nCounts consecutive warp=off\n≥ WARP_FAIL_THRESHOLD (default 6=30s)\n→ runs recover.sh (nuclear)\n→ output.log"]
        end

    end

    subgraph BLIND["What each monitor can/can't see"]
        B1["WARP Watcher sees:\n✅ Container WARP tunnel state\n❌ Host NIC traffic\n❌ Flash leaks < 5s"]
        B2["Host-NIC blind spot covered by:\n🔒 PF kill-switch (kernel, fail-closed)\n🔍 on-demand: diagnose-host-leak.sh\n(--watch to monitor) / sweep.sh"]
    end

    D3 -.->|"covers"| B1
    B1 -.->|"gap closed by"| B2

    style D1 fill:#1a2d0a
    style D2 fill:#0a1a2d
    style D3 fill:#2d0a2d
    style BLIND fill:#1a1a1a,color:#aaa
```

---

## 5. Traffic Flow — Data Path (Normal Operation)

```mermaid
sequenceDiagram
    participant PHONE as 📱 Phone<br/>(Tailnet client)
    participant TS_HOST as tailscaled<br/>(macOS host)
    participant TS_CONTAINER as tailscale<br/>(container)
    participant GLUETUN as Gluetun/warp<br/>(container)
    participant CF as ☁️ Cloudflare<br/>WARP Edge
    participant INTERNET as 🌍 Internet

    Note over PHONE,INTERNET: Normal EXIT NODE path (all 3 pre-flights passed)

    PHONE->>TS_HOST: WireGuard packet<br/>(encrypted, UDP 41641)
    TS_HOST->>TS_CONTAINER: route via utun* → tailscale0
    TS_CONTAINER->>GLUETUN: FORWARD chain<br/>(iptables MASQUERADE on tun0)
    GLUETUN->>TS_HOST: WireGuard tunnel (tun0) egresses macOS Host
    Note over TS_HOST: macOS pf Firewall applies<br/>Kill-Switch & TCP MSS Clamping
    TS_HOST->>CF: re-encrypted UDP packet (MSS 1160)
    CF->>INTERNET: Plain HTTPS from<br/>Cloudflare IP

    Note over PHONE,INTERNET: DNS Resolution path
    PHONE->>TS_HOST: DNS query
    TS_HOST->>TS_CONTAINER: UDP:53 → TCP:5354 → AdGuard :5335
    TS_CONTAINER->>GLUETUN: AdGuard upstream DNS via tun0
    GLUETUN->>CF: Encrypted DNS query
    CF-->>GLUETUN: DNS response
    GLUETUN-->>TS_CONTAINER: response
    TS_CONTAINER-->>TS_HOST: response
    TS_HOST-->>PHONE: DNS answer
```

---

## 6. recover.sh — Decision Tree

```mermaid
flowchart TD
    INVOKE(["recover.sh called"])
    MODE{"--post-wake\nflag?"}

    subgraph POSTWAKE["🔄 --post-wake (light refresh, gateway stays UP)"]
        PW1["Re-hijack DNS → gateway IP"]
        PW2["Flush DNS cache"]
        PW3["Refresh tailscale exit-node"]
        PW4["Force-recreate warp container\n(if Gluetun healthcheck failed)"]
        PW5["Leave: containers, Wi-Fi,\ncaffeinate, DNS watcher — untouched"]
    end

    subgraph NUCLEAR["☢️ Default (nuclear — gateway torn down)"]
        N0["Sudo keep-alive loop (background)"]
        N1["1. tailscale down\n(disconnect from mesh)"]
        N2["2. Reset DNS → 1.1.1.1\n(ALL network services)"]
        N3["3. disable_all_proxies\n(all interfaces)"]
        N4["4. Flush DNS cache\n(dscacheutil -flushcache)"]
        N5["5. Flush stale routes\n(WARP endpoint routes)"]
        N6a["6a. docker compose down -t 30\n(stop all containers)"]
        N6b["6b. stop_pidfile_daemon\n(kill caffeinate)"]
        N6c["6c. stop_pidfile_daemon\n(kill DNS Watcher)"]
        N7["7. Power-cycle Wi-Fi\n(networksetup off→sleep 2→on)"]
        N8["8. Verify internet working\n(curl ifconfig.io)"]
    end

    DONE_PW(["✅ Gateway refreshed\n(still running)"])
    DONE_NUC(["✅ Internet restored\n(gateway fully stopped)"])

    INVOKE --> MODE
    MODE -->|"yes"| PW1
    PW1 --> PW2 --> PW3 --> PW4 --> PW5 --> DONE_PW
    MODE -->|"no"| N0
    N0 --> N1 --> N2 --> N3 --> N4 --> N5
    N5 --> N6a --> N6b --> N6c --> N7 --> N8 --> DONE_NUC

    style POSTWAKE fill:#0a2d1a,color:#c0ffc0
    style NUCLEAR fill:#2d0505,color:#ffc0c0
    style DONE_PW fill:#0a3d1a,color:#fff
    style DONE_NUC fill:#3d1a00,color:#ffe0c0
```

---

## 7. Failure Paths & Self-Healing

```mermaid
flowchart LR
    subgraph EVENTS["Failure / Event"]
        E1["WARP tunnel drops\n(warp=off)"]
        E2["Mac wakes from sleep\nor Wi-Fi roams"]
        E3["DNS drifts from\ngateway IP"]
        E4["toggle.sh crashes /\nCtrl-C / SIGTERM"]
        E5["Host-side leak\n(non-tunnel HOST NIC egress)"]
        E6["Silent NAT timeout\n(ping stops working)"]
    end

    subgraph DETECTORS["Detector"]
        D1["WARP Watcher\n(30s poll, docker exec)"]
        D2["scripts/watcher.sh\n(launchd, always on)"]
        D3["DNS Watcher\n(30s poll, networksetup)"]
        D4["cleanup_handler\n(ERR/INT/TERM/HUP trap)"]
        D5["PF kill-switch\n(kernel, always-on) +\ndiagnose-host-leak.sh --watch\n(on-demand)"]
        D6["routing-fix.sh\n(30s curl over tun0)"]
    end

    subgraph ACTIONS["Response"]
        A1["≥ threshold consecutive off\n→ recover.sh (nuclear)"]
        A2["recover.sh --post-wake\n(gentle refresh)"]
        A3["Re-hijack DNS\n(networksetup setdnsservers)"]
        A4["Stop all daemons\nReset DNS → 1.1.1.1\nTear down Tailscale"]
        A5["Non-tunnel egress blocked\nfail-closed at kernel;\n--watch alerts on state change"]
        A6["Blackhole internet traffic\n+ Drop TUNNEL_FAILED_CLOSED.marker"]
        A7["Push macOS Desktop Notification\n(via watcher.sh listener)"]
    end

    E1 --> D1 --> A1
    E2 --> D2 --> A2
    E3 --> D3 --> A3
    E4 --> D4 --> A4
    E5 --> D5 --> A5
    E6 --> D6 --> A6
    A6 -.->|"marker detected"| D2
    D2 --> A7

    style EVENTS fill:#2d1010,color:#ffcccc
    style DETECTORS fill:#0a1a2d,color:#cce0ff
    style ACTIONS fill:#0a2d0a,color:#ccffcc
```

---

## 8. output.log — Who Writes What

All events converge into a single `output.log` at the repo root.

| Writer | Event Types | Format |
|--------|-------------|--------|
| `toggle.sh` | All startup/shutdown steps, errors, pre-flight results | Plain text with timestamps |
| `recover.sh` | Every recovery step (nuclear or post-wake) | Plain text |
| **WARP Watcher** | `WARP DOWN`, `WARP RECOVERED`, `WARP SHUTDOWN` | `[UTC timestamp]` prefix |
| **DNS Watcher** | DNS re-hijack events | Appended inline |
| `docker compose` | Container logs on failure (last 100 lines of warp) | Dumped on ERR path |
| `routing-fix.sh` | (via `nullexit-logger` inside container) | Structured |

**Grep cheatsheet:**
```bash
grep 'WARP DOWN' output.log    # Container-side tunnel drops
grep 'WARP SHUTDOWN' output.log # Auto-recovery triggered
grep 'WARP RECOVERED' output.log # Self-healed before threshold
grep -E 'EXEC:|EXIT ' output.log # Lifecycle breadcrumbs (last command + exit)
```
