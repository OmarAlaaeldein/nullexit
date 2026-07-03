import os
import shutil
import time as _time
import urllib.request
import re

BLACK_LIST_PATH = "black_list.txt"
WHITE_LIST_PATH = "white_list.txt"
OUTPUT_PATH = "adguard/work/userfilters/compiled_rules.txt"

# Remote lists profiles to balance memory usage vs blocking power
CORE_LISTS = [
    "https://raw.githubusercontent.com/anudeepND/blacklist/master/adservers.txt",
    "https://raw.githubusercontent.com/anudeepND/blacklist/master/facebook.txt",
    "https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/spy.txt",
    "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/native.samsung.txt",
    "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/native.apple.txt",
    "https://abp.oisd.nl/basic/",
    "https://adaway.org/hosts.txt",
    "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=adblockplus&showintro=1&mimetype=plaintext",
    "https://raw.githubusercontent.com/nextdns/cname-cloaking-blocklist/master/domains"
]

MEDIUM_ADDITIONS = [
    "https://raw.githubusercontent.com/lightswitch05/hosts/master/docs/lists/facebook-extended.txt",
    "https://someonewhocares.org/hosts/zero/hosts",
    "https://urlhaus.abuse.ch/downloads/hostfile/"
]

HEAVY_ADDITIONS = [
    "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts",
    "https://raw.githubusercontent.com/Perflyst/PiHoleBlocklist/master/SmartTV-AGH.txt",
    "https://raw.githubusercontent.com/DandelionSprout/adfilt/master/GameConsoleAdblockList.txt"
]

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


    # Emerging Threats (Proofpoint) — Active C2, scanners, exploit kit IPs.
    # Maintained by professional threat researchers. Updated daily.
    "https://rules.emergingthreats.net/fwrules/emerging-Block-IPs.txt",

    # CINS Active Threat Intelligence — Active scanners and brute-force sources.
    "https://cinsscore.com/list/ci-badguys.txt",
]

IP_OUTPUT_PATH = "adguard/work/userfilters/ip_blocklist.ipset"
IP_CACHE_DIR   = "adguard/work/userfilters/cache/ip"

PROFILES = {
    "light": CORE_LISTS + [
        "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/domains/light.txt"
    ],
    "medium": CORE_LISTS + MEDIUM_ADDITIONS + [
        "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/domains/multi.txt"
    ],
    "heavy": CORE_LISTS + MEDIUM_ADDITIONS + HEAVY_ADDITIONS + [
        "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/domains/pro.txt"
    ]
}

def load_env_profile():
    """Load the GATEWAY_RULE_PROFILE variable from .env or system environment."""
    profile = "heavy"  # Default profile
    if os.path.exists(".env"):
        try:
            with open(".env", "r") as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith("#"):
                        parts = line.split("=", 1)
                        if len(parts) == 2:
                            key = parts[0].strip()
                            val = parts[1].strip()
                            if key == "GATEWAY_RULE_PROFILE":
                                profile = val.lower().strip("\"'")
        except Exception as e:
            print(f"Warning: Failed to read .env file for profile configuration ({e}). Using default.")
    
    # Allow environment variable override
    profile = os.environ.get("GATEWAY_RULE_PROFILE", profile).lower()
    if profile not in PROFILES:
        print(f"Warning: Profile '{profile}' is invalid. Falling back to 'heavy'.")
        profile = "heavy"
    return profile

def load_domains(filepath):
    if not os.path.exists(filepath):
        return set()
    with open(filepath, 'r') as f:
        return {line.strip().lower() for line in f if line.strip() and not line.startswith('#')}

CACHE_DIR = "adguard/work/userfilters/cache"

def parse_domains_from_content(content):
    domains = set()
    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith('!') or line.startswith('['):
            continue
        line = line.split('#')[0].strip()
        if not line:
            continue
        
        parts = line.split()
        if len(parts) >= 2:
            if re.match(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$', parts[0]):
                rule = parts[1]
            else:
                rule = parts[0]
        else:
            rule = parts[0]
            
        rule = rule.lower().strip()
        
        # Normalize simple AdGuard rules to base domains to maximize deduplication
        m = re.match(r'^\|\|([a-z0-9.-]+)\^$', rule)
        if m:
            domain = m.group(1)
        elif re.match(r'^[a-z0-9.-]+$', rule):
            domain = rule
        else:
            domain = rule
        
        if domain and domain not in ("localhost", "0.0.0.0", "127.0.0.1", "broadcasthost"):
            domains.add(domain)
    return domains

def get_adguard_native_lists():
    yaml_path = "adguard/conf/AdGuardHome.yaml"
    enabled_urls = []
    if not os.path.exists(yaml_path):
        return enabled_urls
        
    try:
        with open(yaml_path, 'r') as f:
            content = f.read()
            
        # Extract filters: section
        filters_match = re.search(r'^filters:(.*?)(?:^[a-zA-Z_]+:|\Z)', content, re.MULTILINE | re.DOTALL)
        if filters_match:
            filters_text = filters_match.group(1)
            blocks = filters_text.split('\n  - ')
            for block in blocks:
                if not block.strip():
                    continue
                if 'enabled: true' in block:
                    url_match = re.search(r'url:\s*(\S+)', block)
                    if url_match:
                        url = url_match.group(1)
                        if 'compiled_rules.txt' not in url:
                            enabled_urls.append(url)
    except Exception as e:
        print(f"Warning: Failed to parse AdGuardHome.yaml for native lists ({e})")
        
    return enabled_urls

def get_adguard_compiled_rules_cache_path():
    """Resolve the on-disk path of AdGuard Home's cached copy of compiled_rules.txt.

    AdGuard Home stores cached filter content in
    ``adguard/work/data/filters/<filter_id>.txt`` where ``<filter_id>`` is a
    timestamp-derived integer assigned at subscription time (this depends on
    AdGuard internals and is *not* predictable from our config). The previous
    hardcoded path ``data/filters/4.txt`` silently fell out of sync with reality,
    so the cache deletion was a no-op and AdGuard kept serving stale in-memory
    rules across restarts.

    Parses ``adguard/conf/AdGuardHome.yaml`` using the same regex approach as
    ``get_adguard_native_lists()`` to find the block whose URL contains our
    compiled rules file, then returns ``data/filters/<id>.txt``.

    Returns ``None`` if AdGuardHome.yaml is missing, no filter URL matches, or
    parsing fails (caller should log and continue).
    """
    yaml_path = "adguard/conf/AdGuardHome.yaml"
    if not os.path.exists(yaml_path):
        return None

    try:
        with open(yaml_path, "r") as f:
            content = f.read()

        # Same regex used by get_adguard_native_lists() to locate the filters: block.
        filters_match = re.search(
            r'^filters:(.*?)(?:^[a-zA-Z_]+:|\Z)',
            content,
            re.MULTILINE | re.DOTALL,
        )
        if not filters_match:
            return None

        # Each filter entry begins with `  - id: <int>` (the first entry begins with `- id:`).
        blocks = filters_match.group(1).split("\n  - ")
        for block in blocks:
            if "compiled_rules.txt" not in block:
                continue
            id_match = re.search(r'id:\s*(\d+)', block)
            if id_match:
                return f"adguard/work/data/filters/{id_match.group(1)}.txt"
    except Exception as e:
        print(f"Warning: Failed to resolve compiled_rules.txt cache path ({e})")
    return None

def fetch_remote_domains(url):
    import hashlib
    import time
    
    os.makedirs(CACHE_DIR, exist_ok=True)
    url_hash = hashlib.md5(url.encode()).hexdigest()
    cache_file = os.path.join(CACHE_DIR, f"{url_hash}.txt")
    
    # Check if we have a valid cached copy (less than 24 hours old)
    if os.path.exists(cache_file):
        file_age = time.time() - os.path.getmtime(cache_file)
        if file_age < 86400:
            print(f"Loading remote blacklist from cache: {url}")
            try:
                with open(cache_file, 'r', encoding='utf-8') as f:
                    content = f.read()
                domains = parse_domains_from_content(content)
                print(f" -> Loaded from cache (copy is {file_age/3600:.1f} hours old, {len(domains)} domains).")
                return domains
            except Exception as e:
                print(f" -> Warning: Failed to read cache file {cache_file} ({e}). Re-fetching...")
    
    print(f"Fetching remote blacklist from: {url} ...")
    try:
        req = urllib.request.Request(
            url, 
            headers={'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)'}
        )
        with urllib.request.urlopen(req, timeout=15) as response:
            content = response.read().decode('utf-8')
            
            domains = parse_domains_from_content(content)
            
            # Sanity check: if a URL goes 404 and returns HTML, it will parse to ~0 domains.
            if len(domains) < 10:
                raise ValueError(f"Sanity check failed: only found {len(domains)} domains. Possible 404 or bad URL.")
            
            # Save raw content to cache ONLY if sanity check passes.
            # setup may have written the file with restrictive mode).
            try:
                tmp_cache = cache_file + ".tmp"
                with open(tmp_cache, 'w', encoding='utf-8') as f:
                    f.write(content)
                os.replace(tmp_cache, cache_file)
            except Exception as e:
                print(f" -> Warning: Failed to save cache file ({e})")
                
            print(f" -> Successfully fetched and cached {len(domains)} domains.")
            return domains
    except Exception as e:
        if os.path.exists(cache_file):
            print(f" -> Warning: Failed to fetch {url} ({e}). Falling back to expired local cache.")
            try:
                with open(cache_file, 'r', encoding='utf-8') as f:
                    content = f.read()
                domains = parse_domains_from_content(content)
                print(f" -> Loaded from expired cache ({len(domains)} domains).")
                return domains
            except Exception as e2:
                print(f" -> Warning: Failed to read expired cache ({e2}). Using local lists only.")
        else:
            print(f" -> Warning: Failed to fetch {url} ({e}). Using local lists only for this source.")
        return set()

def optimize_subdomains(domains, list_name="blocklist"):
    """
    Remove redundant subdomains. Since AdGuard's '||domain.com^' syntax
    already blocks all of its subdomains, having rules for both domain.com
    and sub.domain.com is redundant. Removing them saves substantial memory.
    """
    print(f"Optimizing {list_name} by removing redundant subdomains...")
    raw_count = len(domains)
    if raw_count == 0:
        return set()
        
    optimized = set()
    for domain in domains:
        # Skip subdomain optimization if the rule contains custom AdGuard syntax
        if any(char in domain for char in ('|', '^', '@', '$', '/')):
            optimized.add(domain)
            continue
            
        parts = domain.split('.')
        has_parent = False
        # Check parent domains (e.g., b.c.com and c.com for a.b.c.com)
        # Note: range starts at 1 to skip the full domain, and ends at len-1 to avoid checking TLD (e.g. 'com')
        for i in range(1, len(parts) - 1):
            parent = '.'.join(parts[i:])
            if parent in domains:
                has_parent = True
                break
        if not has_parent:
            optimized.add(domain)
            
    saved = raw_count - len(optimized)
    reduction = (saved / raw_count) * 100 if raw_count > 0 else 0
    print(f" -> Reduced {list_name} from {raw_count} to {len(optimized)} domains (-{saved} / {reduction:.1f}% reduction).")
    return optimized

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
        if len(ips) < 1:
            raise ValueError(f"Sanity check failed: only {len(ips)} IPs found. Possible 404.")

        try:
            tmp_cache = cache_file + ".tmp"
            with open(tmp_cache, 'w', encoding='utf-8') as f:
                f.write(content)
            os.replace(tmp_cache, cache_file)
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

    print(f"IP blocklist written to {IP_OUTPUT_PATH}")
    return len(clean_ips)

def main():
    profile = load_env_profile()
    print(f"Active memory profile: '{profile.upper()}'")
    
    # Load local lists
    local_black_list = load_domains(BLACK_LIST_PATH)
    white_list = load_domains(WHITE_LIST_PATH)

    # Initialize master blacklist with local entries
    black_list = set(local_black_list)

    # Fetch and merge remote blacklists concurrently
    urls_to_fetch = PROFILES[profile]
    
    import concurrent.futures
    import time
    
    print(f"\nStarting concurrent downloads for {len(urls_to_fetch)} lists...")
    start_time = time.time()
    
    # Use multithreading to fetch all lists concurrently. 
    # Python releases the GIL during network I/O, making threads perfect here.
    # We cap max_workers at 16 to prevent container OOM/socket exhaustion.
    max_threads = min(16, len(urls_to_fetch))
    with concurrent.futures.ThreadPoolExecutor(max_workers=max_threads) as executor:
        # Submit all download tasks
        future_to_url = {executor.submit(fetch_remote_domains, url): url for url in urls_to_fetch}
        
        # As each thread finishes downloading its list, merge it into the master set
        for future in concurrent.futures.as_completed(future_to_url):
            try:
                remote_domains = future.result()
                black_list.update(remote_domains)
            except Exception as e:
                print(f"Error fetching a remote list: {e}")
                
    end_time = time.time()
    print(f"Finished concurrent downloads in {end_time - start_time:.2f} seconds using {max_threads} threads.")

    # Fetch AdGuard native lists for deduplication
    adguard_native_urls = get_adguard_native_lists()
    adguard_native_domains = set()
    if adguard_native_urls:
        print(f"\nFetching {len(adguard_native_urls)} AdGuard native list(s) for deduplication...")
        with concurrent.futures.ThreadPoolExecutor(max_workers=min(4, len(adguard_native_urls))) as executor:
            future_to_url = {executor.submit(fetch_remote_domains, url): url for url in adguard_native_urls}
            for future in concurrent.futures.as_completed(future_to_url):
                try:
                    domains = future.result()
                    adguard_native_domains.update(domains)
                except Exception as e:
                    print(f"Error fetching native list: {e}")
        
        if adguard_native_domains:
            print(f"Deduplicating compiled rules against AdGuard native lists...")
            original_size = len(black_list)
            black_list = black_list - adguard_native_domains
            print(f" -> Removed {original_size - len(black_list)} redundant rules already covered by AdGuard.")

    # Detect contradictions and prioritize whitelist
    contradictions = black_list.intersection(white_list)
    if contradictions:
        print(f"Detected {len(contradictions)} contradictions. Whitelist taking priority.")
        for domain in sorted(contradictions):
            # Print local contradictions, but don't flood terminal for thousands of remote ones
            if domain in local_black_list:
                print(f" -> Removed local blacklist domain: {domain}")
            black_list.remove(domain)

    # Apply subdomain optimization
    black_list = optimize_subdomains(black_list, "blacklist")
    white_list = optimize_subdomains(white_list, "whitelist")

    # Generate AdGuard Syntax
    os.makedirs(os.path.dirname(OUTPUT_PATH), exist_ok=True)
    with open(OUTPUT_PATH, 'w') as f:
        f.write("! Custom Compiled Rules (Auto-Generated)\n")
        f.write(f"! Memory Profile: {profile.upper()}\n")
        f.write(f"! Total Block Rules: {len(black_list)}\n")
        f.write(f"! Native AdGuard Rules: {len(adguard_native_domains) if 'adguard_native_domains' in locals() else 0}\n")
        f.write(f"! Total Whitelist Rules: {len(white_list)}\n\n")
        
        f.write("! --- Blacklist Rules ---\n")
        for domain in sorted(black_list):
            if '$' in domain:
                parts = domain.split('$', 1)
                dom, mod = parts[0], parts[1]
                if dom.startswith('||'):
                    if dom.endswith('^'):
                        f.write(f"{dom}${mod}\n")
                    else:
                        f.write(f"{dom}^${mod}\n")
                else:
                    f.write(f"||{dom}^${mod}\n")
            elif domain.startswith('/') or domain.startswith('|') or domain.endswith('|') or domain.endswith('^'):
                f.write(f"{domain}\n")
            else:
                f.write(f"||{domain}^\n")
            
        f.write("\n! --- Whitelist Rules ---\n")
        for domain in sorted(white_list):
            if domain.startswith('/') or domain.startswith('|') or domain.endswith('|') or domain.endswith('^') or domain.startswith('@@'):
                rule = domain if domain.startswith('@@') else f"@@{domain}"
                f.write(f"{rule}\n")
            else:
                f.write(f"@@||{domain}^\n")

    print(f"\nSuccessfully compiled {len(black_list)} block rules and {len(white_list)} allow rules to {OUTPUT_PATH}")

    # Atomically replace AdGuard Home's cached filter file so the next restart
    # loads the new whitelist. We OVERWRITE — not DELETE — because AdGuard Home
    # treats a missing cache file as "filter disabled" rather than "filter
    # needs re-fetch"; deleting silently disables the filter instead of
    # reloading from disk.
    # NOTE: We do not touch file permissions here. The cache file is written
    # with whatever mode the caller / umask produces — that's fine.
    cached_filter_path = get_adguard_compiled_rules_cache_path()
    if cached_filter_path:
        try:
            shutil.copyfile(OUTPUT_PATH, cached_filter_path)
            print(f"Updated AdGuard filter cache: {cached_filter_path}")
        except Exception as e:
            print(f"Warning: Could not update AdGuard filter cache {cached_filter_path} ({e})")
    else:
        print("Warning: Could not determine compiled_rules.txt cache path from AdGuardHome.yaml; skipping cache update.")

    adguard_reachable = False

    # Restart AdGuard Home container if docker is running, then trigger an
    # explicit filter refresh via the REST API so the new whitelist is loaded
    # without waiting for AdGuard's periodic refresh interval (default 24h).
    # (Python's urllib is used because the adguardhome image does not include
    # curl/wget — and when sync-rules.py is invoked from the rule-compiler
    # container, adguardhome isn't yet running, so this block is a no-op there.)
    if os.path.exists("docker-compose.yml") and shutil.which("docker"):
        try:
            import subprocess
            res = subprocess.run(["docker", "compose", "ps", "--status", "running", "-q", "adguardhome"], capture_output=True, text=True)
            if res.returncode == 0 and res.stdout.strip():
                print("Force-recreating AdGuard Home container to drop persisted filter state...")
                # `restart` is SIGTERM+SIGHUP, which AdGuard Home catches and gracefully
                # reloads from its BoltDB-persisted snapshot. For file:// subscriptions,
                # AdGuard hashes the URL content and considers it "unchanged" if the hash
                # matches the previous run, even when the file's *contents* have evolved.
                # --force-recreate destroys the container and starts a fresh one, which
                # forces AdGuard to genuinely re-read the source file.
                subprocess.run(
                    ["docker", "compose", "up", "-d", "--force-recreate", "--no-deps", "adguardhome"],
                    capture_output=True,
                )
                print("AdGuard Home force-recreated successfully.")
                # AdGuard's REST listener takes a while to come up after a force-recreate
                # on Colima. 8s is conservative but necessary; on faster hosts we waste
                # only ~5s. Without this sleep the /control/filtering/refresh POST races
                # the bind and silently returns "Empty reply from server".
                _time.sleep(8)
                adguard_reachable = True
        except Exception as e:
            print("Failed to restart AdGuard Home. Is it running?")

    # Trigger AdGuard's filter refresh API to force-load the new whitelist into
    # in-memory rules immediately, without waiting for the periodic refresh
    # interval or another container restart. Uses urllib because curl/wget are
    # not present in the adguardhome image.
    if adguard_reachable:
        try:
            import urllib.request as _ur, base64 as _b64
            creds = _b64.b64encode(b"admin:nullexit").decode("ascii")
            req = _ur.Request(
                "http://127.0.0.1:3000/control/filtering/refresh",
                method="POST",
                headers={"Authorization": f"Basic {creds}", "Content-Type": "application/json"},
                data=b"{}",
            )
            resp = _ur.urlopen(req, timeout=15)
            print(f"Triggered AdGuard filter refresh via REST API (HTTP={resp.status}).")
        except Exception as e:
            # IMPORTANT: container force-recreate alone is NOT sufficient. AdGuard
            # Home stores filter rules in its BoltDB and only re-reads cache files on
            # an explicit refresh. If this REST POST fails, the new whitelist
            # will not be honored until the next periodic refresh tick (default
            # 24h) OR a manual /control/filtering/refresh call.
            print(f"Warning: AdGuard filter refresh API call failed ({e}). New whitelist will not load until next refresh tick (~24h) or manual refresh.")

    # Compile IP blocklist for kernel-level blocking in routing-fix.sh
    compile_ip_blocklist()

if __name__ == "__main__":
    main()
