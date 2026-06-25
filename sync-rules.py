import os
import urllib.request
import re

BLACK_LIST_PATH = "black_list.txt"
WHITE_LIST_PATH = "white_list.txt"
OUTPUT_PATH = "adguard/work/userfilters/compiled_rules.txt"

# Remote lists profiles to balance memory usage vs blocking power
PROFILES = {
    "light": [
        "https://raw.githubusercontent.com/anudeepND/blacklist/master/adservers.txt",
        "https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/spy.txt",
        "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/domains/light.txt"
    ],
    "medium": [
        "https://raw.githubusercontent.com/anudeepND/blacklist/master/adservers.txt",
        "https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/spy.txt",
        "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/domains/multi.txt"
    ],
    "heavy": [
        "https://raw.githubusercontent.com/anudeepND/blacklist/master/adservers.txt",
        "https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/spy.txt",
        "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/domains/pro.txt",
        "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
    ]
}

def load_env_profile():
    """Load the GATEWAY_RULE_PROFILE variable from .env or system environment."""
    profile = "medium"  # Default profile
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
        print(f"Warning: Profile '{profile}' is invalid. Falling back to 'medium'.")
        profile = "medium"
    return profile

def load_domains(filepath):
    if not os.path.exists(filepath):
        return set()
    with open(filepath, 'r') as f:
        return {line.strip().lower() for line in f if line.strip() and not line.startswith('#')}

def fetch_remote_domains(url):
    print(f"Fetching remote blacklist from: {url} ...")
    try:
        req = urllib.request.Request(
            url, 
            headers={'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)'}
        )
        with urllib.request.urlopen(req, timeout=15) as response:
            content = response.read().decode('utf-8')
            domains = set()
            for line in content.splitlines():
                # Strip comments
                line = line.split('#')[0].strip()
                if not line:
                    continue
                # Parse hosts format: "0.0.0.0 domain.com" or just "domain.com"
                parts = line.split()
                if len(parts) >= 2:
                    # check if the first part is an IP address
                    if re.match(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$', parts[0]):
                        domain = parts[1]
                    else:
                        domain = parts[0]
                elif len(parts) == 1:
                    domain = parts[0]
                else:
                    continue
                
                domain = domain.lower().strip()
                # Exclude localhost/common routing loops
                if domain and domain not in ("localhost", "0.0.0.0", "127.0.0.1", "broadcasthost"):
                    domains.add(domain)
            print(f" -> Successfully fetched {len(domains)} domains.")
            return domains
    except Exception as e:
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

def main():
    profile = load_env_profile()
    print(f"Active memory profile: '{profile.upper()}'")
    
    # Load local lists
    local_black_list = load_domains(BLACK_LIST_PATH)
    white_list = load_domains(WHITE_LIST_PATH)

    # Initialize master blacklist with local entries
    black_list = set(local_black_list)

    # Fetch and merge remote blacklists based on selected profile
    urls_to_fetch = PROFILES[profile]
    for url in urls_to_fetch:
        remote_domains = fetch_remote_domains(url)
        black_list.update(remote_domains)

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
        f.write(f"! Total Whitelist Rules: {len(white_list)}\n\n")
        
        f.write("! --- Blacklist Rules ---\n")
        for domain in sorted(black_list):
            f.write(f"||{domain}^\n")
            
        f.write("\n! --- Whitelist Rules ---\n")
        for domain in sorted(white_list):
            f.write(f"@@||{domain}^\n")

    print(f"\nSuccessfully compiled {len(black_list)} block rules and {len(white_list)} allow rules to {OUTPUT_PATH}")

if __name__ == "__main__":
    main()

