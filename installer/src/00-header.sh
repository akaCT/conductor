#!/usr/bin/env bash
#
# Conductor installer.
#
# This file is GENERATED. Edit installer/src/*.sh, installer/py/*.py and
# payload/, then run: python3 tools/build.py
#
#   Install:    curl --proto '=https' --tlsv1.2 -fsSL https://conductorskill.com/install.sh | bash
#   Local:      bash install.sh [options]      (bash install.sh --help)
#
# Rules every fragment follows (tests/test-build.sh checks the result):
#   1. Top level holds only assignments, readonly constants and function
#      definitions. Nothing at top level reads, writes or prompts.
#   2. The only statement that acts is the last line, main "$@". A copy cut
#      off at any earlier line therefore changes nothing.
#   3. bash 3.2 compatible: no associative arrays, no readlink -f, no
#      ${var,,}, no mapfile.
set -u

CONDUCTOR_URL="https://conductorskill.com"

# ---------- output ----------
# No escape sequences when NO_COLOR is set, TERM is dumb or stdout is not a
# terminal. Errors go to stderr and are coloured only when stderr is also a
# terminal.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYN=$'\033[36m'; RST=$'\033[0m'
  if [ -t 2 ]; then RED=$'\033[31m'; RSTE=$'\033[0m'; else RED=""; RSTE=""; fi
else
  B=""; DIM=""; GRN=""; YEL=""; CYN=""; RED=""; RST=""; RSTE=""
fi
say()  { printf '%s\n' "$*"; }
ok()   { printf '  %s✓%s %s\n' "$GRN" "$RST" "$*"; }
info() { printf '  %s•%s %s\n' "$CYN" "$RST" "$*"; }
warn() { printf '  %s!%s %s\n' "$YEL" "$RST" "$*"; }
err()  { printf '  %s✗%s %s\n' "$RED" "$RSTE" "$*" >&2; }
die()  { err "$*"; exit 1; }

# installer_name: the file name this installer was run as, for the commands the
# text tells the user to type. When it was piped in, when it is the launcher's
# temporary copy (installer.sh), or when the name is odd, it is install.sh.
installer_name() {
  local n="${BASH_SOURCE[0]:-$0}"
  n="${n##*/}"
  case "$n" in
    ""|bash|sh|-bash|-sh|dash|zsh|main|installer.sh|*[!A-Za-z0-9._-]*) n="install.sh" ;;
  esac
  printf '%s' "$n"
}

# wrap_text WIDTH: filter on stdin. Breaks the words at blanks so no line is
# longer than WIDTH characters; a word longer than WIDTH stays whole.
wrap_text() {
  awk -v w="$1" '{
    line = ""
    for (i = 1; i <= NF; i++) {
      if (line == "") line = $i
      else if (length(line) + 1 + length($i) <= w) line = line " " $i
      else { print line; line = $i }
    }
    if (line != "") print line
  }'
}

# note_wrapped KIND WIDTH PREFIX TEXT: prints TEXT in lines of at most WIDTH
# characters after PREFIX. KIND (info, warn, ok or say) prints the first line;
# the others are plain lines indented under it. It keeps long fixed text inside
# 80 columns (REQ-UI-001.3).
note_wrapped() {
  local kind="$1" width="$2" pre="$3" text="$4" l first=1 pad
  pad="$pre"
  case "$kind" in info|warn|ok) pad="    $pre" ;; esac
  while IFS= read -r l; do
    if [ "$first" = 1 ]; then
      "$kind" "$pre$l"
      first=0
    else
      say "$pad$l"
    fi
  done <<EOF
$(printf '%s\n' "$text" | wrap_text "$width")
EOF
}

banner() {
  say ""
  say "${B}${CYN}  Conductor${RST} ${DIM}v${CONDUCTOR_VERSION}${RST}"
  say "${DIM}  A set of files that make your session act as a conductor.${RST}"
  say ""
}

# Filter on stdin: drops every C0 control character except newline and tab
# (the carriage return and ESC included), DEL, and the C1 characters (U+0080
# to U+009F, which are the 2 bytes C2 80 to C2 9F in UTF-8). It also drops the
# invisible format characters that can reorder or hide printed text: U+200B to
# U+200F (zero width marks), U+2028 to U+202E (separators and bidirectional
# embeddings), U+2060 to U+2069 (word joiner, isolates), U+FEFF, U+061C (Arabic
# letter mark) and the tag characters U+E0000 to U+E007F. Other UTF-8
# text passes unchanged. Run it on any text taken from a fetched or project file
# before that text is printed.
sanitize_text() {
  LC_ALL=C tr -d '\000-\010\013-\037\177' | LC_ALL=C sed -e $'s/\xc2[\x80-\x9f]//g' \
    -e $'s/\xe2\x80[\x8b-\x8f\xa8-\xae]//g' -e $'s/\xe2\x81[\xa0-\xa9]//g' -e $'s/\xef\xbb\xbf//g' \
    -e $'s/\xd8\x9c//g' -e $'s/\xf3\xa0[\x80\x81][\x80-\xbf]//g'
}

# json_quote TEXT: prints TEXT as a JSON string. Backslash and double quote are
# escaped and a tab becomes \t. It is used for names, versions and the python3
# path, none of which holds a line break.
json_quote() {
  printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/'"$(printf '\t')"'/\\t/g')"
}

# ---------- terminal prompts ----------
# True when /dev/tty can actually be opened. `-r /dev/tty` can report readable
# even when the open fails (some non-terminal contexts on macOS), which then
# prints "Device not configured". Testing the real open avoids that noise.
tty_ok() {
  ( : < /dev/tty ) 2>/dev/null
}

# True when no prompt can be shown: CONDUCTOR_YES=1, a dry run, or no terminal
# anywhere.
no_prompt() {
  [ "${CONDUCTOR_YES:-}" = "1" ] || [ "${DRY_RUN:-0}" = "1" ] || { [ ! -t 0 ] && ! tty_ok; }
}

# ask_yn QUESTION DEFAULT(y|n): returns 0 for yes. Reads /dev/tty when stdin is
# not a terminal (curl | bash); uses DEFAULT when there is no terminal at all.
ask_yn() {
  local q="$1" def="$2" ans=""
  if no_prompt; then
    ans="$def"
  else
    printf '  %s%s%s [%s]: ' "$B" "$q" "$RST" "$def" > /dev/tty
    read -r ans < /dev/tty || ans="$def"
    ans="${ans:-$def}"
  fi
  case "$ans" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# ask_str QUESTION DEFAULT: echoes the answer. An empty DEFAULT is not shown in
# brackets; Enter then answers with the empty string.
ask_str() {
  local q="$1" def="$2" ans="" shown=""
  if no_prompt; then
    printf '%s' "$def"
    return 0
  fi
  if [ -n "$def" ]; then shown=" [$def]"; fi
  printf '  %s%s%s%s: ' "$B" "$q" "$RST" "$shown" > /dev/tty
  read -r ans < /dev/tty || ans="$def"
  printf '%s' "${ans:-$def}"
}
