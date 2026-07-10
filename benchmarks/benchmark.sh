#!/usr/bin/env bash

# benchmark.sh
# Automates the full benchmarking suite (both Python download test and Lighthouse HTML test)
# Runs the suite with Gateway ON, toggles OFF, runs again, then toggles back ON.

set -e

# Change to project root so we can access toggle.sh reliably
cd "$(dirname "$0")/.."

# Ensure jq is installed
if ! command -v jq &> /dev/null; then
    echo "Error: 'jq' is not installed. Please run 'brew install jq'"
    exit 1
fi

run_lighthouse() {
    local url=$1
    local file_prefix=$2
    echo "  [Lighthouse] Testing $url ..."
    
    # Run lighthouse headlessly, silencing standard output
    npx -y lighthouse "$url" --chrome-flags="--headless" --only-categories=performance --output=json --output-path="${file_prefix}.json" >/dev/null 2>&1
    
    # Parse the results
    local score=$(jq -r '.categories.performance.score' "${file_prefix}.json")
    local tti=$(jq -r '.audits["interactive"].displayValue' "${file_prefix}.json")
    local si=$(jq -r '.audits["speed-index"].displayValue' "${file_prefix}.json")
    
    # Convert score to percentage
    local score_pct=$(awk "BEGIN {print $score*100}")
    
    echo "    -> Performance Score: ${score_pct}%"
    echo "    -> Time to Interactive: $tti"
    echo "    -> Speed Index: $si"
    
    # Cleanup
    rm -f "${file_prefix}.json"
}

echo "============================================="
echo "   PHASE 1: Testing with Gateway ON"
echo "============================================="
# 1. Run raw Python download test
python3 benchmarks/test_load.py

# 2. Run Lighthouse HTML render test
echo ""
echo "Starting Lighthouse HTML Tests (this takes ~30-60s per site)..."
run_lighthouse "https://www.cnet.com/" "on_cnet"
run_lighthouse "https://www.independent.co.uk/" "on_ind"


echo ""
echo "============================================="
echo "   PHASE 2: Toggling Gateway OFF"
echo "============================================="
./toggle.sh
echo "Waiting 10 seconds for macOS Wi-Fi to stabilize after DNS reset..."
sleep 10


echo ""
echo "============================================="
echo "   PHASE 3: Testing with Gateway OFF"
echo "============================================="
# 1. Run raw Python download test
python3 benchmarks/test_load.py

# 2. Run Lighthouse HTML render test
echo ""
echo "Starting Lighthouse HTML Tests (this takes ~30-60s per site)..."
run_lighthouse "https://www.cnet.com/" "off_cnet"
run_lighthouse "https://www.independent.co.uk/" "off_ind"


echo ""
echo "============================================="
echo "   PHASE 4: Restoring Gateway ON"
echo "============================================="
./toggle.sh

echo ""
echo "============================================="
echo "✅ BENCHMARKS COMPLETE!"
echo "You can scroll up to compare Phase 1 (AdGuard ON) vs Phase 3 (AdGuard OFF)."
echo "============================================="
