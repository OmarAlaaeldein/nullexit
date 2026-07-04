#!/bin/bash
# Resolve project root relative to this script's location, so the script
# works regardless of the caller's CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "Unlocking .env..."
if [ -f "$PROJECT_ROOT/.env" ]; then
  sudo cat "$PROJECT_ROOT/.env" > "$PROJECT_ROOT/.env.tmp" && mv "$PROJECT_ROOT/.env.tmp" "$PROJECT_ROOT/.env"
  echo "✅ .env unlocked"
fi

echo "Unlocking AdGuard cache files..."
for f in "$PROJECT_ROOT"/adguard/work/userfilters/compiled_rules.txt \
         "$PROJECT_ROOT"/adguard/work/userfilters/ip_blocklist.ipset \
         "$PROJECT_ROOT"/adguard/work/userfilters/cache/*.txt \
         "$PROJECT_ROOT"/adguard/work/userfilters/cache/ip/*.txt \
         "$PROJECT_ROOT"/adguard/work/data/filters/*.txt; do
  if [ -f "$f" ]; then
    cat "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    echo "✅ Unlocked $f"
  fi
done

echo ""
echo "All locked files have been successfully bypassed via atomic rename!"