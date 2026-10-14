#!/bin/bash
# tests/run.sh: runs every tests/test-*.sh (with /bin/bash) and tests/test_*.py
# (with python3), prints 1 line per test, a table per suite and a total.
# Exit 0 when every suite ran and no test failed, 1 otherwise.
#
# A suite reports through lines that start with "PASS " or "FAIL " (see
# tests/lib/assert.sh). A suite that exits non-zero without printing a FAIL line
# is counted as 1 failure.
#
# The suites share nothing (each makes its own sandbox folder and picks free
# ports), so they run at the same time and the whole run takes about as long as
# the slowest suite. Each suite's output is kept in its own file and printed in
# the order of the file names once every suite has finished.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/.." || exit 1

total_pass=0
total_fail=0
rows=""
dir="$(mktemp -d)" || exit 1
trap 'rm -rf "$dir"' EXIT

n=0
for suite in tests/test-*.sh tests/test_*.py; do
  [ -f "$suite" ] || continue
  n=$((n + 1))
  case "$suite" in
    *.sh) (/bin/bash "$suite" < /dev/null > "$dir/$n.out" 2>&1; echo $? > "$dir/$n.rc") & ;;
    *) (python3 "$suite" < /dev/null > "$dir/$n.out" 2>&1; echo $? > "$dir/$n.rc") & ;;
  esac
done
wait

n=0
for suite in tests/test-*.sh tests/test_*.py; do
  [ -f "$suite" ] || continue
  n=$((n + 1))
  out="$dir/$n.out"
  rc="$(cat "$dir/$n.rc" 2> /dev/null || echo 1)"
  printf '== %s\n' "$suite"
  cat "$out"
  p="$(grep -c '^PASS ' "$out" || true)"
  f="$(grep -c '^FAIL ' "$out" || true)"
  if [ "$rc" -ne 0 ] && [ "$f" -eq 0 ]; then
    f=1
    printf 'FAIL %s (exited %d without a FAIL line)\n' "$suite" "$rc"
  fi
  if [ "$rc" -eq 0 ] && [ "$p" -eq 0 ] && [ "$f" -eq 0 ]; then
    f=1
    printf 'FAIL %s (reported no tests)\n' "$suite"
  fi
  total_pass=$((total_pass + p))
  total_fail=$((total_fail + f))
  rows="${rows}$(printf '%-28s %5d %5d %4d' "$suite" "$p" "$f" "$rc")"$'\n'
done

printf '\n%-28s %5s %5s %4s\n' suite pass fail rc
printf '%s' "$rows"
printf '%-28s %5d %5d\n' total "$total_pass" "$total_fail"
if [ "$total_fail" -gt 0 ] || [ "$total_pass" -eq 0 ]; then
  exit 1
fi
exit 0
