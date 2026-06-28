# IP Blocklist Implementation — nullexit

Three files need changes. Apply them in order.

---

## 1. `sync-rules.py` — Add IP feed fetching and compilation

### 1a. Add constants after the existing `PROFILES` dict (after line ~50)

```python
# ─── IP Blocklist Feeds ──────────────────────────────────────────────────────
# Curated, low-false-positive threat intelligence feeds.
# All are free, actively maintained, and safe to block without breaking
# legitimate services. Combined they cover ~30k-80k IPs/CIDRs.
IP_BLOCK_LISTS = [
    # Feodo Tracker (abuse.ch) — Verified botnet C2 IPs (Emotet, TrickBot,
    # QakBot, Dridex). Curated by malware researchers. Extremely low FP rate.
    "https://feodotracker.abuse.ch/downloads/ipblocklist.txt",

    # Spamhaus DROP — "Don't Route or Peer". IPs allocated to criminal orgs.
    # Used by major ISPs at the BGP level. Nothing legitimate uses these.
    "https://www.spamhaus.org/drop/drop.txt",

    # Spamhaus EDROP — Extended DROP. Hijacked netblocks operated by criminals.
    "https://www.spamhaus.org/drop/edrop.txt",

    # Emerging Threats (Proofpoint) — Active C2, scanners, exploit kit IPs.
    # Maintained by professional threat researchers. Updated daily.
    "https://rules.emergingthreats.net/fwrules/emerging-Block-IPs.txt",

    # CINS Active Threat Intelligence — Active scanners and brute-force sources.
    "https://cinsscore.com/list/ci-badguys.txt",
]

IP_OUTPUT_PATH = "adguard/work/userfilters/ip_blocklist.ipset"
IP_CACHE_DIR   = "adguard/work/userfilters/cache/ip"
```

### 1b. Add three functions after the `optimize_subdomains()` function

```python
def parse_ips_from_content(content):
    """Parse IPs and CIDRs from various threat intel feed formats.

    Handles:
      - Plain IPs:        1.2.3.4
      - CIDR notation:    1.2.3.0/24
      - Inline comments:  1.2.3.4 # Feodo C2
      - Spamhaus format:  1.2.3.0/24 ; SBL123456
    """
    import ipaddress
    ips = set()
    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith('#') or line.startswith(';'):
            continue
        # Take only the first whitespace-delimited token
        token = line.split()[0].rstrip(';,')
        try:
            ipaddress.ip_network(token, strict=False)
            ips.add(token)
        except ValueError:
            continue
    return ips


def fetch_remote_ips(url):
    """Fetch an IP blocklist from URL with 24-hour disk caching.

    Mirrors the fetch_remote_domains() caching strategy: fresh fetch →
    cache on disk → serve from cache for 24h → fall back to stale cache
    on network failure.
    """
    import hashlib
    import time

    os.makedirs(IP_CACHE_DIR, exist_ok=True)
    url_hash   = hashlib.md5(url.encode()).hexdigest()
    cache_file = os.path.join(IP_CACHE_DIR, f"{url_hash}.txt")

    if os.path.exists(cache_file):
        file_age = time.time() - os.path.getmtime(cache_file)
        if file_age < 86400:
            print(f"Loading IP feed from cache: {url}")
            try:
                with open(cache_file, 'r', encoding='utf-8') as f:
                    content = f.read()
                ips = parse_ips_from_content(content)
                print(f" -> {len(ips)} IPs (cache is {file_age/3600:.1f}h old).")
                return ips
            except Exception as e:
                print(f" -> Warning: cache read failed ({e}). Re-fetching...")

    print(f"Fetching IP feed: {url} ...")
    try:
        req = urllib.request.Request(
            url, headers={'User-Agent': 'Mozilla/5.0'}
        )
        with urllib.request.urlopen(req, timeout=15) as response:
            content = response.read().decode('utf-8', errors='replace')

        ips = parse_ips_from_content(content)

        # Sanity check: a 404 HTML page will parse to ~0 IPs.
        if len(ips) < 10:
            raise ValueError(f"Sanity check failed: only {len(ips)} IPs found. Possible 404.")

        try:
            if os.path.exists(cache_file):
                os.chmod(cache_file, 0o644)
            with open(cache_file, 'w', encoding='utf-8') as f:
                f.write(content)
            os.chmod(cache_file, 0o444)
        except Exception as e:
            print(f" -> Warning: cache write failed ({e})")

        print(f" -> {len(ips)} IPs fetched and cached.")
        return ips

    except Exception as e:
        if os.path.exists(cache_file):
            print(f" -> Warning: fetch failed ({e}). Falling back to stale cache.")
            try:
                with open(cache_file, 'r', encoding='utf-8') as f:
                    content = f.read()
                ips = parse_ips_from_content(content)
                print(f" -> {len(ips)} IPs loaded from stale cache.")
                return ips
            except Exception as e2:
                print(f" -> Warning: stale cache also failed ({e2}).")
        else:
            print(f" -> Warning: {url} failed ({e}). No cache available. Skipping.")
        return set()


def compile_ip_blocklist():
    """Fetch all IP feeds concurrently, deduplicate, strip private ranges,
    and write an ipset restore file using an atomic swap pattern so the
    live ipset is never empty during a reload.
    """
    import ipaddress
    import concurrent.futures

    print("\n─── IP Blocklist Compilation ───")

    # Fetch all feeds concurrently (same pattern as domain lists)
    all_ips = set()
    max_threads = min(8, len(IP_BLOCK_LISTS))
    with concurrent.futures.ThreadPoolExecutor(max_workers=max_threads) as executor:
        futures = {executor.submit(fetch_remote_ips, url): url for url in IP_BLOCK_LISTS}
        for future in concurrent.futures.as_completed(futures):
            try:
                all_ips.update(future.result())
            except Exception as e:
                print(f"IP feed thread error: {e}")

    print(f"Total unique entries before filtering: {len(all_ips)}")

    # Strip private, loopback, link-local, and Tailscale CGNAT ranges.
    # Blocking these would lock users out of their own LAN or mesh network.
    RESERVED = [
        ipaddress.ip_network("10.0.0.0/8"),        # RFC1918 private
        ipaddress.ip_network("172.16.0.0/12"),      # RFC1918 private
        ipaddress.ip_network("192.168.0.0/16"),     # RFC1918 private
        ipaddress.ip_network("127.0.0.0/8"),        # Loopback
        ipaddress.ip_network("169.254.0.0/16"),     # Link-local
        ipaddress.ip_network("100.64.0.0/10"),      # Tailscale CGNAT — CRITICAL
        ipaddress.ip_network("0.0.0.0/8"),          # "This" network
    ]

    clean_ips = set()
    for entry in all_ips:
        try:
            net = ipaddress.ip_network(entry, strict=False)
            if not any(net.overlaps(r) for r in RESERVED):
                clean_ips.add(entry)
        except ValueError:
            continue

    removed = len(all_ips) - len(clean_ips)
    if removed:
        print(f" -> Removed {removed} private/reserved entries.")
    print(f" -> Final IP blocklist: {len(clean_ips)} entries.")

    # Write ipset restore format with atomic swap.
    #
    # Pattern: create a new temporary set → populate it → swap it atomically
    # with the live set → destroy the now-empty temp set. This guarantees
    # the live ipset (block_malicious) is never empty during a reload, even
    # if routing-fix.sh triggers an ipset restore mid-refresh.
    os.makedirs(os.path.dirname(IP_OUTPUT_PATH), exist_ok=True)
    if os.path.exists(IP_OUTPUT_PATH):
        try:
            os.chmod(IP_OUTPUT_PATH, 0o644)
        except Exception:
            pass

    with open(IP_OUTPUT_PATH, 'w') as f:
        f.write(f"# nullexit Compiled IP Blocklist\n")
        f.write(f"# Sources: Feodo Tracker, Spamhaus DROP/EDROP, Emerging Threats, CINS\n")
        f.write(f"# Entries: {len(clean_ips)}\n\n")
        # Step 1: Create temp set (maxelem covers worst-case list growth)
        f.write("create block_malicious_new hash:net maxelem 200000 -exist\n")
        # Step 2: Populate temp set
        for ip in sorted(clean_ips):
            f.write(f"add block_malicious_new {ip} -exist\n")
        # Step 3: Ensure live set exists before swap
        f.write("create block_malicious hash:net maxelem 200000 -exist\n")
        # Step 4: Atomic swap
        f.write("swap block_malicious block_malicious_new\n")
        # Step 5: Destroy temp (now contains old data)
        f.write("destroy block_malicious_new\n")

    try:
        os.chmod(IP_OUTPUT_PATH, 0o444)
    except Exception:
        pass

    print(f"IP blocklist written to {IP_OUTPUT_PATH}")
    return len(clean_ips)
```

### 1c. Add call at the end of `main()`, after the AdGuard restart block

Find the last lines of `main()` (the `subprocess.run(["docker", "compose", "restart", ...])` block) and add this immediately after:

```python
    # Compile IP blocklist for kernel-level blocking in routing-fix.sh
    compile_ip_blocklist()
```

---

## 2. `routing-fix.sh` — Load and enforce the IP blocklist

### 2a. Add variables after the WARP_ENDPOINT line (after line 26)

```sh
IP_BLOCKLIST_FILE="/userfilters/ip_blocklist.ipset"
LAST_IP_MTIME=""
```

### 2b. Add the `add_ip_blocklist()` function after `add_country_block()` (after line 99)

```sh
add_ip_blocklist() {
  # Only reload when the compiled file has actually changed (mtime check).
  # This prevents a pointless ipset restore on every 5-second loop tick.
  if [ ! -f "$IP_BLOCKLIST_FILE" ]; then
    return 0
  fi

  CURRENT_MTIME=$(stat -c %Y "$IP_BLOCKLIST_FILE" 2>/dev/null || echo "0")
  if [ "$CURRENT_MTIME" = "$LAST_IP_MTIME" ]; then
    return 0
  fi

  echo "routing-fix: IP blocklist changed, reloading..."

  # ipset restore handles the atomic swap internally:
  # create_new → populate → swap with live → destroy_new
  if ipset restore < "$IP_BLOCKLIST_FILE" 2>/dev/null; then
    LAST_IP_MTIME="$CURRENT_MTIME"
    echo "routing-fix: IP blocklist loaded ($(ipset list block_malicious | grep -c '^[0-9]') entries)."
  else
    echo "routing-fix: Warning: ipset restore failed. Retrying next cycle."
    return 1
  fi

  # Apply FORWARD DROP rules in BOTH iptables backends.
  # dst: blocks outbound connections to C2/malicious infrastructure (malware phoning home)
  # src: blocks inbound attack traffic from known malicious sources
  for ipt in iptables iptables-legacy; do
    command -v "$ipt" >/dev/null 2>&1 || continue

    if ! $ipt -C FORWARD -m set --match-set block_malicious dst -j DROP 2>/dev/null; then
      $ipt -I FORWARD -m set --match-set block_malicious dst -j DROP 2>/dev/null || true
    fi

    if ! $ipt -C FORWARD -m set --match-set block_malicious src -j DROP 2>/dev/null; then
      $ipt -I FORWARD -m set --match-set block_malicious src -j DROP 2>/dev/null || true
    fi
  done
}
```

### 2c. Add initial call after `add_country_block` (after line 101)

```sh
add_ip_blocklist
```

So that block becomes:
```sh
add_country_block
add_ip_blocklist

echo 'routing-fix: Routes applied.'
```

### 2d. Add loop call inside the `while true` loop, after `add_country_block` (after line 129)

```sh
  # Enforce IP blocklist (reloads automatically when file changes)
  add_ip_blocklist
```

So the end of the loop becomes:
```sh
  # Enforce country blocklist
  add_country_block

  # Enforce IP blocklist (reloads automatically when file changes)
  add_ip_blocklist

  sleep 5
done
```

---

## 3. `docker-compose.yml` — Mount the compiled file and fix startup order

### 3a. Add volume mount to the `routing-fix` service

Find the `routing-fix` volumes block:
```yaml
    volumes:
      - ./routing-fix.sh:/routing-fix.sh:ro
```

Replace with:
```yaml
    volumes:
      - ./routing-fix.sh:/routing-fix.sh:ro
      - ./adguard/work/userfilters:/userfilters:ro
```

### 3b. Add `rule-compiler` to `routing-fix` depends_on

Find the `routing-fix` depends_on block:
```yaml
    depends_on:
      warp:
        condition: service_healthy
```

Replace with:
```yaml
    depends_on:
      warp:
        condition: service_healthy
      rule-compiler:
        condition: service_completed_successfully
```

This guarantees the `ip_blocklist.ipset` file exists before routing-fix starts,
eliminating the race condition where routing-fix boots before the compiler finishes.

---

## Summary of what this adds

| Layer | What it blocks | How |
|-------|---------------|-----|
| DNS (existing) | Ad/tracker/malware domains | AdGuard 500k rules |
| IP (new) | C2 servers, botnet infrastructure, criminal netblocks | ipset + iptables FORWARD DROP |

**Feeds used and why:**

| Feed | Operator | Covers | False positive risk |
|------|----------|--------|-------------------|
| Feodo Tracker | abuse.ch | Active botnet C2 (Emotet, TrickBot, QakBot) | Extremely low — researcher-curated |
| Spamhaus DROP | Spamhaus | IPs allocated to criminal organizations | Essentially zero — BGP-level list |
| Spamhaus EDROP | Spamhaus | Hijacked netblocks operated by criminals | Essentially zero |
| Emerging Threats | Proofpoint | Active C2, scanners, exploit kits | Low — professionally maintained |
| CINS | Team Cymru | Active scanners, brute-force sources | Low |

**What it does NOT do:**
- It does not inspect payload (no SSL MITM)
- It does not block private/CGNAT ranges (your LAN and Tailscale mesh are safe)
- It does not replace the DNS layer — both layers are complementary

**How the reload works:**
- `sync-rules.py` regenerates `ip_blocklist.ipset` on every `docker compose up` (with 24h cache)
- `routing-fix.sh` checks the file's mtime every 5 seconds
- If the file changed, it runs `ipset restore` which atomically swaps the live set
- The iptables rules are only re-added if they're missing (idempotent `-C` check)
- If the file doesn't exist yet (race condition on first boot), routing-fix silently skips and retries next cycle
