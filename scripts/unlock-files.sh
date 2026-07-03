#!/bin/bash

echo "Unlocking .env..."
if [ -f .env ]; then
  sudo cat .env > .env.tmp && mv .env.tmp .env
  echo "✅ .env unlocked"
fi

echo "Unlocking AdGuard cache files..."
for f in adguard/work/userfilters/compiled_rules.txt adguard/work/userfilters/ip_blocklist.ipset adguard/work/userfilters/cache/*.txt adguard/work/userfilters/cache/ip/*.txt adguard/work/data/filters/*.txt; do
  if [ -f "$f" ]; then
    cp "$f" "$f.tmp" && mv "$f.tmp" "$f"
    echo "✅ Unlocked $f"
  fi
done

echo ""
echo "All locked files have been successfully bypassed via atomic rename!"