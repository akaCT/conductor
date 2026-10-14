#!/bin/bash
# tools/export.sh: thin wrapper around tools/export.py. Passes every argument and the exit
# code through unchanged. bash 3.2 compatible. See: export.sh --help
HERE="$(cd "$(dirname "$0")" && pwd)"
if ! command -v python3 > /dev/null 2>&1; then
  echo "export.sh needs python3 3.9 or later" >&2
  exit 2
fi
exec python3 "$HERE/export.py" "$@"
