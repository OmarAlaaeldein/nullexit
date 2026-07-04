#!/usr/bin/env bash
# signer.sh - Generates cryptographic signatures for core scripts

set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo "Error: .env not found."
  exit 1
fi

SEED=$(grep "^NULLEXIT_SEED=" .env | cut -d '=' -f2)
if [ -z "$SEED" ]; then
  echo "Error: NULLEXIT_SEED not found in .env."
  exit 1
fi

echo "Generating cryptographic signatures using seed..."
rm -f .signatures

for file in toggle.sh recover.sh scripts/routing-fix.sh; do
  if [ -f "$file" ]; then
    # Calculate HMAC-SHA256 using the seed
    hash=$(openssl dgst -sha256 -hmac "$SEED" "$file" | awk '{print $NF}')
    echo "$file:$hash" >> .signatures
    echo "  [Signed] $file"
  else
    echo "  [Skipped] $file not found"
  fi
done

echo "Signatures saved to .signatures"
