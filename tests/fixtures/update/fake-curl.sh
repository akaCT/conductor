#!/bin/sh
# A fake curl for tests/test-update.sh (REQ-UPD-002.11). It records its argument list, 1
# per line, in $CURL_ARGV_LOG, and the modes of the output file and its folder at the time
# of the call in $CURL_ARGV_LOG.modes, then fails like an unreachable host. It fetches nothing.
{
  for a in "$@"; do printf '%s\n' "$a"; done
} > "$CURL_ARGV_LOG"
out=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ]; then out="$a"; fi
  prev="$a"
done
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }
if [ -n "$out" ]; then
  printf 'file_mode=%s\ndir_mode=%s\n' "$(mode_of "$out")" "$(mode_of "$(dirname "$out")")" > "$CURL_ARGV_LOG.modes"
fi
echo "curl: (7) fixture: not reachable" >&2
exit 7
