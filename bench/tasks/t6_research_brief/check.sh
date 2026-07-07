#!/usr/bin/env bash
# Keyword-presence check against the captured final text reply.
# Usage: bash check.sh <path-to-final-text-file>
set -euo pipefail

reply_file="${1:-}"
if [ -z "$reply_file" ] || [ ! -f "$reply_file" ]; then
  echo "FAIL: no reply file provided (expected path as \$1)"
  exit 1
fi

lower="$(tr '[:upper:]' '[:lower:]' < "$reply_file")"

# Accept either vendor as a defensible pick (Ridgeport for speed/reliability,
# Cedarline for cost/quality) as long as a single vendor is named with a
# reason and a tradeoff is acknowledged. This keeps the check about
# structure (pick + reason + risk), not about agreeing with one answer.
picked_ridgeport=0
picked_cedarline=0
grep -qi "ridgeport" <<<"$lower" && picked_ridgeport=1
grep -qi "cedarline" <<<"$lower" && picked_cedarline=1

if [ "$picked_ridgeport" -eq 0 ] && [ "$picked_cedarline" -eq 0 ]; then
  echo "FAIL: no recognized vendor pick found"
  exit 1
fi

missing=0
for kw in "risk\|tradeoff\|trade-off\|downside\|drawback"; do
  if ! grep -qi -- "$kw" <<<"$lower"; then
    echo "MISSING: a risk/tradeoff term"
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
