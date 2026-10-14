#!/usr/bin/env bash
# Checks the captured final text reply. Usage: bash check.sh <reply-file>
set -euo pipefail

reply_file="${1:-}"
if [ -z "$reply_file" ] || [ ! -f "$reply_file" ]; then
  echo "FAIL: no reply file provided (expected path as \$1)"
  exit 1
fi

# Basic 12 x 24 = 288; Plus 9 x 24 + 60 = 276; Max 7 x 24 + 150 = 318.
text="$(tr -d ',$' < "$reply_file")"
missing=0
for kw in 288 276 318; do
  if ! grep -q -- "$kw" <<<"$text"; then
    echo "MISSING: total $kw"
    missing=1
  fi
done
last="$( (grep -v '^[[:space:]]*$' "$reply_file" || true) | tail -n 1 | tr '[:upper:]' '[:lower:]' | tr -d '*` ')"
if [ "$last" != "cheapest:plus" ]; then
  echo "MISSING: last line CHEAPEST: Plus (got: $last)"
  missing=1
fi

if [ "$missing" -eq 0 ]; then
  echo "PASS"
  exit 0
fi
echo "FAIL"
exit 1
