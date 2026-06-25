import os
import urllib.request
import re

BLACK_LIST_PATH = "black_list.txt"
WHITE_LIST_PATH = "white_list.txt"
OUTPUT_PATH = "adguard/work/userfilters/compiled_rules.txt"

# Remote lists to subscribe to
REMOTE_BLACKLIST_URLS = [
    "https://raw.githubusercontent.com/anudeepND/blacklist/master/adservers.txt",
    "https://raw.githubusercontent.com/anudeepND/blacklist/master/facebook.txt",
    "https://raw.githubusercontent.com/lightswitch05/hosts/master/docs/lists/facebook-extended.txt"
]

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

def main():
    # Load local lists
    local_black_list = load_domains(BLACK_LIST_PATH)
    white_list = load_domains(WHITE_LIST_PATH)

    # Initialize master blacklist with local entries
    black_list = set(local_black_list)

    # Fetch and merge remote blacklists
    for url in REMOTE_BLACKLIST_URLS:
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

    # Generate AdGuard Syntax
    os.makedirs(os.path.dirname(OUTPUT_PATH), exist_ok=True)
    with open(OUTPUT_PATH, 'w') as f:
        f.write("! Custom Compiled Rules (Auto-Generated)\n")
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
