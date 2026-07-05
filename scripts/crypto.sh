#!/usr/bin/env bash
# crypto.sh - Cryptographic Integrity Check

set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$#" -ne 1 ] || { [ "$1" != "--sign" ] && [ "$1" != "--verify" ]; }; then
  echo "Usage: $0 --sign | --verify"
  exit 1
fi

if [ ! -f .env ]; then
  echo "Error: .env not found."
  exit 1
fi

SEED=$(grep "^NULLEXIT_SEED=" .env | cut -d '=' -f2)
if [ -z "$SEED" ]; then
  echo "Error: NULLEXIT_SEED not found in .env."
  exit 1
fi

if [ "$1" == "--sign" ]; then
  echo "Generating cryptographic signatures using seed..."
  rm -f .signatures
  for file in toggle.sh recover.sh scripts/common.sh scripts/routing-fix.sh scripts/toggle-linux.sh scripts/recover-linux.sh scripts/diagnose-host-leak.sh; do
    if [ -f "$file" ]; then
      hash=$(openssl dgst -sha256 -hmac "$SEED" "$file" | awk '{print $NF}')
      echo "$file:$hash" >> .signatures
      echo "  [Signed] $file"
    else
      echo "  [Skipped] $file not found"
    fi
  done
  echo "Signatures saved to .signatures"
  exit 0
fi

if [ "$1" == "--verify" ]; then
  if [ ! -f .signatures ]; then
    echo "Error: .signatures file missing. Run $0 --sign first."
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
    echo "To authorize these changes, run: ./scripts/crypto.sh --sign"
    echo "──────────────────────────────────────────────"
    exit 1
  fi
  exit 0
fi
