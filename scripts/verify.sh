#!/usr/bin/env bash
# verify.sh - Verifies cryptographic signatures for core scripts

set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f .env ] || [ ! -f .signatures ]; then
  echo "Error: Missing .env or .signatures file. Run scripts/signer.sh first."
  exit 1
fi

SEED=$(grep "^NULLEXIT_SEED=" .env | cut -d '=' -f2)
if [ -z "$SEED" ]; then
  echo "Error: NULLEXIT_SEED not found in .env."
  exit 1
fi

FAIL=0

while IFS=: read -r file expected_hash; do
  if [ -z "$file" ]; then continue; fi
  
  if [ ! -f "$file" ]; then
    echo "[FAIL] $file is missing!"
    FAIL=1
    continue
  fi
  
  actual_hash=$(openssl dgst -sha256 -hmac "$SEED" "$file" | awk '{print $NF}')
  
  if [ "$actual_hash" != "$expected_hash" ]; then
    echo "[FAIL] $file has been modified! Hash mismatch."
    FAIL=1
  fi
done < .signatures

if [ "$FAIL" -eq 1 ]; then
  echo "──────────────────────────────────────────────"
  echo "CRITICAL: Script integrity verification failed!"
  echo "One or more core files have been modified without authorization."
  echo "To authorize these changes, run: ./scripts/signer.sh"
  echo "──────────────────────────────────────────────"
  exit 1
fi
