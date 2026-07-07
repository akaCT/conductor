#!/usr/bin/env bash
# Keyword-presence check against the captured final text reply.
# Usage: bash check.sh <path-to-final-text-file>
# The runner passes the path to the captured final assistant text as $1.
set -euo pipefail

reply_file="${1:-}"
if [ -z "$reply_file" ] || [ ! -f "$reply_file" ]; then
  echo "FAIL: no reply file provided (expected path as \$1)"
  exit 1
fi

text="$(cat "$reply_file")"
lower="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"

missing=0
for kw in "owner_id" "account_id" "token" "deprecated"; do
  if ! printf '%s' "$lower" | grep -qi -- "$kw"; then
    echo "MISSING: $kw"
    missing=1
  fi
done

if [ "$missing" -eq 0 ]; then
  echo "PASS"
  exit 0
else
  echo "FAIL"
  exit 1
fi
