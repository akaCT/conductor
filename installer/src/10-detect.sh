# 10-detect.sh [L1a]: roots, operating system, python3, terminal, existing install.
#
# Sets: CLAUDE_DIR CODEX_DIR AGENTS_SKILLS_DIR HAVE_CLAUDE HAVE_CODEX STAMP
#       OS_KIND (darwin, linux, windows, other)
#       PY (absolute path of a usable python3, or empty) and PY_REASON
#       INTERACTIVE (0 or 1) and EXISTING (none, v030, v04)
#       EXISTING_CLAUDE and EXISTING_CODEX (the same values, per root)
#       LEGACY_CLAUDE_MD_PATCHED, LEGACY_CODEX_MD_PATCHED, LEGACY_MODEL_SET
#       (what a 0.3.0 install recorded; read by detect_existing)
# DRY_RUN and the OPT_* variables belong to 99-main.sh (argument parsing).
# CLAUDE_DIR, CODEX_DIR, AGENTS_SKILLS_DIR and STAMP are set by detect_roots only;
# the rest start with safe values so an early read never trips set -u.

HAVE_CLAUDE=0
HAVE_CODEX=0
OS_KIND="other"
PY=""
PY_REASON=""
INTERACTIVE=0
EXISTING="none"
EXISTING_CLAUDE="none"
EXISTING_CODEX="none"
LEGACY_CLAUDE_MD_PATCHED=0
LEGACY_CODEX_MD_PATCHED=0
LEGACY_MODEL_SET=""

# strip_slashes PATH: PATH without trailing slashes (the root folder stays /).
strip_slashes() {
  local p="$1"
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  printf '%s' "$p"
}

# Roots, overridable for tests and unusual layouts. Refuses to guess when HOME
# is unset and a root was not given, and refuses a relative root.
detect_roots() {
  local home="${HOME:-}" v
  if [ -z "$home" ]; then
    if [ -z "${CLAUDE_DIR:-${CLAUDE_CONFIG_DIR:-}}" ] || [ -z "${CODEX_DIR:-${CODEX_HOME:-}}" ] || [ -z "${AGENTS_SKILLS_DIR:-}" ]; then
      die "HOME is not set. Set it, or set CLAUDE_DIR, CODEX_DIR and AGENTS_SKILLS_DIR."
    fi
  fi
  CLAUDE_DIR="${CLAUDE_DIR:-${CLAUDE_CONFIG_DIR:-$home/.claude}}"
  CODEX_DIR="${CODEX_DIR:-${CODEX_HOME:-$home/.codex}}"
  AGENTS_SKILLS_DIR="${AGENTS_SKILLS_DIR:-$home/.agents}"
  for v in "$CLAUDE_DIR" "$CODEX_DIR" "$AGENTS_SKILLS_DIR"; do
    case "$v" in
      /*) ;;
      *) die "folder paths must be absolute (got: $v)" ;;
    esac
  done
  # A folder given with trailing slashes is the same folder; every path built from it
  # (hook commands included) is written without the doubled slash.
  CLAUDE_DIR="$(strip_slashes "$CLAUDE_DIR")"
  CODEX_DIR="$(strip_slashes "$CODEX_DIR")"
  AGENTS_SKILLS_DIR="$(strip_slashes "$AGENTS_SKILLS_DIR")"
  HAVE_CLAUDE=0
  if [ -d "$CLAUDE_DIR" ]; then HAVE_CLAUDE=1; fi
  HAVE_CODEX=0
  if [ -d "$CODEX_DIR" ]; then HAVE_CODEX=1; fi
  # The PID suffix keeps concurrent runs from colliding on backup names.
  STAMP="$(date +%Y%m%d-%H%M%S).$$"
}

detect_os() {
  case "$(uname -s 2>/dev/null || true)" in
    Darwin) OS_KIND=darwin ;;
    Linux) OS_KIND=linux ;;
    MINGW*|MSYS*|CYGWIN*) OS_KIND=windows ;;
    *) OS_KIND=other ;;
  esac
}

# A usable python3 is on PATH, runs, reports 3.9 or later and, on macOS, is not
# the Command Line Tools stub. The stub is /usr/bin/python3 while
# `xcode-select -p` fails; it is never executed here, because running it opens
# a system install dialog.
detect_python() {
  PY=""
  PY_REASON=""
  local cand real ver major rest minor
  cand="$(command -v python3 2>/dev/null || true)"
  case "$cand" in
    /*) ;;
    ./*) cand="$PWD/${cand#./}" ;;
    */*) cand="$PWD/$cand" ;;
    *) PY_REASON="python3 was not found on your PATH"; return 0 ;;
  esac
  if [ "$OS_KIND" = "darwin" ]; then
    real="$(resolve_link "$cand" 2>/dev/null || printf '%s' "$cand")"
    if [ "$real" = "/usr/bin/python3" ] && ! xcode-select -p >/dev/null 2>&1; then
      PY_REASON="python3 is the Command Line Tools stub (run: xcode-select --install)"
      return 0
    fi
  fi
  ver="$("$cand" -I -B -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null || true)"
  case "$ver" in
    ""|*[!0-9.]*|*.*.*.*) PY_REASON="python3 at $cand did not run"; return 0 ;;
    *.*) ;;
    *) PY_REASON="python3 at $cand did not run"; return 0 ;;
  esac
  major="${ver%%.*}"
  rest="${ver#*.}"
  minor="${rest%%.*}"
  if [ -z "$major" ] || [ -z "$minor" ]; then
    PY_REASON="python3 at $cand did not run"
    return 0
  fi
  if [ "$major" -lt 3 ] || { [ "$major" -eq 3 ] && [ "$minor" -lt 9 ]; }; then
    PY_REASON="python3 at $cand is version $ver; 3.9 or newer is needed"
    return 0
  fi
  PY="$cand"
}

# A terminal on stdin or reachable through /dev/tty. CONDUCTOR_YES is separate:
# it stops prompts but does not change what the install may replace.
detect_interactive() {
  if [ -t 0 ] || tty_ok; then INTERACTIVE=1; else INTERACTIVE=0; fi
}

# The marker line of a 0.3.0 doctrine block, as 0.3.0 wrote it.
has_030_marker() { # $1=file
  [ -f "$1" ] && grep -q '^<!-- BEGIN CONDUCTOR (managed) v0\.3\.0 ' "$1" 2>/dev/null
}

# Recognizes a 0.4 install record (conductor/.install-manifest in a root) and a
# 0.3.0 install (its plain-list manifest, or its v0.3.0 doctrine marker), and
# reads what 0.3.0 recorded so the upgrade can carry it forward.
detect_existing() {
  EXISTING="none"
  EXISTING_CLAUDE="none"
  EXISTING_CODEX="none"
  LEGACY_CLAUDE_MD_PATCHED=0
  LEGACY_CODEX_MD_PATCHED=0
  LEGACY_MODEL_SET=""
  local m v
  if [ "$HAVE_CLAUDE" = 1 ]; then
    if [ -f "$CLAUDE_DIR/conductor/.install-manifest" ]; then
      EXISTING_CLAUDE="v04"
    elif [ -f "$CLAUDE_DIR/skills/conductor/.install-manifest" ] || has_030_marker "$CLAUDE_DIR/CLAUDE.md"; then
      EXISTING_CLAUDE="v030"
    fi
    if [ "$EXISTING_CLAUDE" = "v030" ]; then
      m="$CLAUDE_DIR/skills/conductor/.install-manifest"
      if has_030_marker "$CLAUDE_DIR/CLAUDE.md" || { [ -f "$m" ] && grep -qx 'CLAUDE_MD_PATCHED' "$m"; }; then
        LEGACY_CLAUDE_MD_PATCHED=1
      fi
      if [ -f "$m" ]; then
        v="$(sed -n 's/^SETTINGS_MODEL_SET://p' "$m" | head -1)"
        case "$v" in
          ""|*[!A-Za-z0-9._-]*) ;;
          *) LEGACY_MODEL_SET="$v" ;;
        esac
      fi
    fi
  fi
  if [ "$HAVE_CODEX" = 1 ]; then
    if [ -f "$CODEX_DIR/conductor/.install-manifest" ]; then
      EXISTING_CODEX="v04"
    elif [ -f "$CODEX_DIR/.conductor-manifest" ] || has_030_marker "$CODEX_DIR/AGENTS.md"; then
      EXISTING_CODEX="v030"
    fi
    if [ "$EXISTING_CODEX" = "v030" ]; then
      m="$CODEX_DIR/.conductor-manifest"
      if has_030_marker "$CODEX_DIR/AGENTS.md" || { [ -f "$m" ] && grep -qx 'CODEX_AGENTS_MD_PATCHED' "$m"; }; then
        LEGACY_CODEX_MD_PATCHED=1
      fi
    fi
  fi
  if [ "$EXISTING_CLAUDE" = "v04" ] || [ "$EXISTING_CODEX" = "v04" ]; then
    EXISTING="v04"
  elif [ "$EXISTING_CLAUDE" = "v030" ] || [ "$EXISTING_CODEX" = "v030" ]; then
    EXISTING="v030"
  fi
}

# An install needs at least 1 of the 2 folders, and every folder it will write to
# must be writable. Both checks happen before anything is written.
require_a_root() {
  if [ "$HAVE_CLAUDE" = 0 ] && [ "$HAVE_CODEX" = 0 ]; then
    err "Neither folder exists: Claude Code ($CLAUDE_DIR) and Codex ($CODEX_DIR)."
    err "Nothing was written. Run Claude Code or Codex once, or set"
    err "CLAUDE_DIR or CODEX_DIR to the folder to use."
    exit 1
  fi
  local d
  for d in "$CLAUDE_DIR:$HAVE_CLAUDE" "$CODEX_DIR:$HAVE_CODEX"; do
    if [ "${d##*:}" = 1 ] && { [ ! -w "${d%:*}" ] || [ ! -x "${d%:*}" ]; }; then
      err "Cannot write to ${d%:*}: the folder is not writable. Nothing was written."
      exit 1
    fi
  done
  if [ "$HAVE_CODEX" = 1 ] && [ -d "$AGENTS_SKILLS_DIR" ] && [ ! -w "$AGENTS_SKILLS_DIR" ]; then
    err "Cannot write to $AGENTS_SKILLS_DIR: the folder is not writable. Nothing was written."
    exit 1
  fi
  return 0
}

# Hooks run on macOS and Linux only.
hooks_os_ok() {
  [ "$OS_KIND" = "darwin" ] || [ "$OS_KIND" = "linux" ]
}
