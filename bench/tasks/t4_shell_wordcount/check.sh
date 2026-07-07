#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

if [ ! -f topwords.sh ]; then
  echo "FAIL: topwords.sh not found"
  exit 1
fi

got="$(bash topwords.sh)"

# fox=6, dog=5; lazy/quick/yard tie at 2, alphabetical tie-break picks lazy
expected="fox 6
dog 5
lazy 2"

if [ "$got" = "$expected" ]; then
  echo "PASS"
  exit 0
else
  echo "FAIL"
  echo "expected:"
  echo "$expected"
  echo "got:"
  echo "$got"
  exit 1
fi
