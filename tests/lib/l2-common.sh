# tests/lib/l2-common.sh: helpers shared by test-effort.sh, test-seats.sh and
# test-codex.sh. Source it after assert.sh and sandbox.sh, and after
# setting REPO and HERE.
#
#   build_installer NAME   copy tools, installer and payload into $SBX/b-NAME,
#                          build, set INSTALL
#   fresh                  reset the sandbox folders, fakes and provider variables
#   set_cc VERSION         a fake claude: VERSION, "none" (no version printed),
#                          or "hang" (never answers)
#   inst ARGS...           run INSTALL with no terminal; OUT and RC hold the result
#   inst_pty ARGS...       run INSTALL on a terminal; PTY_INPUT is typed into it
#   flat TEXT              TEXT with each line break and indent turned into 1 space
#   settings_val KEY...    value at that path in $CLAUDE_DIR/settings.json, or empty
#   manifest_pins          the pins list of the Claude manifest, as JSON

OUT=""
RC=0
INSTALL=""

build_installer() {
  local d="$SBX/b-$1"
  rm -rf "$d"
  mkdir -p "$d"
  cp -R "$REPO/tools" "$REPO/installer" "$REPO/payload" "$d/"
  if ! python3 "$d/tools/build.py" > "$SBX/build-$1.log" 2>&1; then
    echo "build_installer $1 failed:" >&2
    cat "$SBX/build-$1.log" >&2
    exit 99
  fi
  INSTALL="$d/install.sh"
}

fresh() {
  local v
  rm -rf "$HOME/.claude" "$HOME/.codex" "$HOME/.agents"
  sandbox_clear_fakes
  for v in $(compgen -v | grep -E '^(CLAUDE_CODE_USE_|CONDUCTOR_)' || true); do unset "$v"; done
  unset ANTHROPIC_BASE_URL CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST CLAUDE_CODE_EFFORT_LEVEL PTY_INPUT
  export NO_COLOR=1
  mkdir -p "$CLAUDE_DIR"
  sandbox_guard
}

set_cc() {
  case "$1" in
    none) printf '#!/bin/sh\nexit 1\n' > "$SBX/bin/claude" ;;
    hang) printf '#!/bin/sh\nsleep 30\n' > "$SBX/bin/claude" ;;
    *) sandbox_fake_claude "$1"; return 0 ;;
  esac
  chmod 755 "$SBX/bin/claude"
}

inst() {
  sandbox_guard
  OUT="$(sandbox_notty /bin/bash "$INSTALL" "$@" < /dev/null 2>&1)"
  RC=$?
}

inst_pty() {
  sandbox_guard
  OUT="$(sandbox_pty /bin/bash "$INSTALL" "$@" 2>&1)"
  RC=$?
}

flat() { printf '%s' "$1" | tr '\n' ' ' | tr -s ' '; }

settings_val() {
  [ -f "$CLAUDE_DIR/settings.json" ] || return 0
  python3 - "$CLAUDE_DIR/settings.json" "$@" <<'PYEOF'
import json, sys
node = json.load(open(sys.argv[1]))
for k in sys.argv[2:]:
    if not isinstance(node, dict) or k not in node:
        sys.exit(0)
    node = node[k]
print(node if isinstance(node, str) else json.dumps(node))
PYEOF
}

manifest_pins() {
  [ -f "$CLAUDE_DIR/conductor/.install-manifest" ] || { echo "[]"; return 0; }
  python3 - "$CLAUDE_DIR/conductor/.install-manifest" <<'PYEOF'
import json, sys
print(json.dumps(json.load(open(sys.argv[1])).get("pins", [])))
PYEOF
}
