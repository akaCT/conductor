#!/bin/sh
# A fake browser opener for the report tests. It records how it was called and opens nothing.
# OPENER_LOG names the record file; the address itself goes to $OPENER_LOG.url.
{
  printf 'argc=%s\n' "$#"
  printf 'parent=%s\n' "$(ps -o comm= -p "$PPID" 2>/dev/null)"
} > "$OPENER_LOG"
printf '%s' "${1:-}" > "$OPENER_LOG.url"
exit 0
