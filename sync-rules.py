import os

BLACK_LIST_PATH = "black_list.txt"
WHITE_LIST_PATH = "white_list.txt"
OUTPUT_PATH = "adguard/work/userfilters/compiled_rules.txt"

def load_domains(filepath):
    if not os.path.exists(filepath):
        return set()
    with open(filepath, 'r') as f:
        return {line.strip() for line in f if line.strip() and not line.startswith('#')}

def main():
    black_list = load_domains(BLACK_LIST_PATH)
    white_list = load_domains(WHITE_LIST_PATH)

    # Detect contradictions and prioritize whitelist
    contradictions = black_list.intersection(white_list)
    if contradictions:
        print(f"Detected {len(contradictions)} contradictions. Whitelist taking priority.")
        for domain in contradictions:
            print(f" -> Removed from blacklist: {domain}")
            black_list.remove(domain)

    # Generate AdGuard Syntax
    os.makedirs(os.path.dirname(OUTPUT_PATH), exist_ok=True)
    with open(OUTPUT_PATH, 'w') as f:
        f.write("! Custom Compiled Rules (Auto-Generated)\n")
        
        f.write("\n! --- User Blacklist ---\n")
        for domain in sorted(black_list):
            f.write(f"||{domain}^\n")
            
        f.write("\n! --- User Whitelist ---\n")
        for domain in sorted(white_list):
            f.write(f"@@||{domain}^\n")

    print(f"\nSuccessfully compiled {len(black_list)} block rules and {len(white_list)} allow rules to {OUTPUT_PATH}")

if __name__ == "__main__":
    main()
