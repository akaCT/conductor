#!/usr/bin/env bash
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$here/rename.sh" ]; then
  echo "FAIL: rename.sh not found"
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/photos"
for n in 0042 0007 0100 0019 0003; do
  printf 'content %s\n' "$n" > "$tmp/photos/IMG_$n.jpg"
done
printf 'not a photo\n' > "$tmp/photos/notes.txt"
cp "$here/rename.sh" "$tmp/rename.sh"

(cd "$tmp" && bash rename.sh) > /dev/null 2>&1

expected_order="0003 0007 0019 0042 0100"
i=1
for n in $expected_order; do
  f="$(printf 'trip/trip-%03d.jpg' "$i")"
  if [ ! -f "$tmp/$f" ]; then
    echo "FAIL: $f missing"
    exit 1
  fi
  if [ "$(cat "$tmp/$f")" != "content $n" ]; then
    echo "FAIL: $f holds the wrong file (expected the copy of IMG_$n.jpg)"
    exit 1
  fi
  i=$((i + 1))
done

count="$(ls "$tmp/trip" | wc -l | tr -d ' ')"
if [ "$count" != "5" ]; then
  echo "FAIL: trip/ holds $count files, expected 5"
  exit 1
fi
if [ ! -f "$tmp/photos/IMG_0042.jpg" ]; then
  echo "FAIL: photos/ was changed"
  exit 1
fi
echo "PASS"
exit 0
