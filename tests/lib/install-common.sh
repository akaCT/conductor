# tests/lib/install-common.sh: the setup and the helpers shared by the 3 parts of the
# installer suite (tests/test-install.sh, tests/test-install-options.sh and
# tests/test-install-modes.sh). Source it after setting HERE and REPO. Each part makes
# its own sandbox, so the parts can run at the same time.
. "$HERE/lib/assert.sh"
. "$HERE/lib/sandbox.sh"

sandbox_new
trap sandbox_cleanup EXIT
export PYTHONDONTWRITEBYTECODE=1
sandbox_guard

INST="$REPO/install.sh"
OLD030="$HERE/fixtures/install-0.3.0.sh"
LIB="$SBX/lib.sh"
sed '$d' "$INST" > "$LIB"
FIX_N=0
mkdir -p "$SBX/keep"
OUT=""
RC=0
MY_PY="$SBX_PY"

# The machine that runs this suite may have a claude on its PATH. Every run here
# sees a claude whose version cannot be read, so no result depends on the machine.
clear_fakes() {
  sandbox_clear_fakes
  mkdir -p "$SBX/cl"
  printf '#!/bin/sh\necho "claude: version not available"\n' > "$SBX/cl/claude"
  chmod 755 "$SBX/cl/claude"
  export PATH="$SBX/bin:$SBX/cl:$SBX_BASE_PATH"
}

# ---------------------------------------------------------------- helpers

# fresh [claude] [codex]: an empty home with the named config folders.
fresh() {
  local r
  clear_fakes
  rm -rf "$HOME" "$SBX/w"
  mkdir -p "$HOME" "$SBX/w"
  for r in "$@"; do
    case "$r" in
      claude) mkdir -p "$CLAUDE_DIR" ;;
      codex) mkdir -p "$CODEX_DIR" ;;
    esac
  done
}

# run CMD...: runs with no terminal; leaves the output in OUT and the code in RC.
run() {
  sandbox_guard
  OUT="$(sandbox_notty "$@" < /dev/null 2>&1)"
  RC=$?
  if [ -z "${NOCOLLECT:-}" ]; then printf '%s\n' "$OUT" >> "$SBX/keep/run-output.txt"; fi
}

inst() { run /bin/bash "$INSTALLER" "$@"; }
INSTALLER="$INST"

# pty CMD...: runs on a pseudo terminal with PTY_INPUT typed in.
pty() {
  sandbox_guard
  OUT="$(sandbox_pty env NO_COLOR=1 "$@")"
  RC=$?
  printf '%s\n' "$OUT" >> "$SBX/keep/pty-output.txt"
}

# pyj FILE 'python expression on d' prints the value. The expression is always a
# literal written in this file, never data from a fixture or the installer.
pyj() {
  "$MY_PY" - "$1" "$2" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
print(eval(sys.argv[2]))
PYEOF
}

sum_of() { shasum -a 256 < "$1" | awk '{print $1}'; }

count_of() { # $1=text $2=fixed string -> number of lines containing it
  printf '%s\n' "$1" | grep -cF -- "$2" || true
}

# fixture_installer NAME: a copy of the repo (tools, installer, payload) whose
# install.sh is rebuilt after the caller edits a fragment. Leaves its folder in FX.
new_fixture() {
  FIX_N=$((FIX_N + 1))
  FX="$SBX/fx$FIX_N"
  mkdir -p "$FX"
  cp -R "$REPO/tools" "$REPO/installer" "$REPO/payload" "$FX/"
  cp "$REPO/install.sh" "$FX/install.sh"
}

build_fixture() {
  python3 "$FX/tools/build.py" > /dev/null 2>&1
}

core_list() { # prints "dest<TAB>src<TAB>mode<TAB>policy" for the Claude core files the installer writes itself
  "$MY_PY" - "$REPO/payload/components.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
for f in d["files"]:
    if f["harness"] == "claude" and f["component"] == "core" and f["policy"] != "doctrine-block" and not f.get("select"):
        print("%s\t%s\t%s\t%s" % (f["dest"], f["src"], f.get("mode", "644"), f["policy"]))
PYEOF
}

# tree_outside_roots: everything under SBX that is not a config root, as a sum.
outside_sum() {
  ( cd "$SBX" && find . -path "./home/.claude" -prune -o -path "./home/.codex" -prune -o -path "./home/.agents" -prune -o \
      -path "./lib.sh" -prune -o -path "./cl" -prune -o -path "./fx*" -prune -o -path "./w" -prune -o -path "./keep" -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r p; do
      printf '%s %s\n' "$p" "$(sum_of "$p")"
    done )
}

user_md=$'# My notes\n\nI like short answers.\n'

# lists of hooks named by several parts
HOOKS2="hook_pointer,hook_usage_split"
ALL5=hook_pointer,hook_nudge,hook_usage_split,hook_project_home,hook_contract


user_settings='{
  "theme": "dark",
  "permissions": {"allow": ["Bash(ls)"]},
  "hooks": {
    "SessionStart": [{"matcher": "startup", "hooks": [{"type": "command", "command": "/usr/bin/true"}]}],
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/usr/bin/echo pre"}]}],
    "Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "/usr/bin/true"}]}]
  },
  "env": {"FOO": "bar"},
  "model": "opus"
}
'

old_install() { # a 0.3.0 install made by the committed 0.3.0 installer, in the sandbox
  fresh claude codex
  printf 'user claude\n' > "$CLAUDE_DIR/CLAUDE.md"
  printf 'user codex\n' > "$CODEX_DIR/AGENTS.md"
  CONDUCTOR_YES=1 NOCOLLECT=1 run /bin/bash "$OLD030"
}

pin_fixture() { # builds a fixture installer whose pin step writes 1 pin, then dies when CONDUCTOR_TEST_KILL is set
  new_fixture
  cat > "$FX/installer/src/50-effort.sh" <<'FRAG'
# test stand-in for the pin step: writes 1 pin through settings_set_key
gate_offer_pins() {
  settings_set_key modelSettings.claude-opus-5-5.effortLevel '"high"' || true
  if [ -n "${CONDUCTOR_TEST_KILL:-}" ]; then kill -9 $$; fi
  return 0
}
FRAG
  build_fixture
}

# long_lines FILE: every line over 80 characters in FILE once the sandbox paths are
# taken out, each printed as "length: line" (nothing when none).
long_lines() {
  "$MY_PY" - "$1" "$SBX" <<'PYEOF'
import re, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read().replace("]: ", "]:\n")
sbx = sys.argv[2]
seen = set()
for line in text.split("\n"):
    line = line.replace(sbx, "P")
    line = re.sub(r"P[^\s]*", "P", line)
    line = re.sub(r"/[^\s]*python3[^\s]*", "PY", line)
    if len(line) > 80 and line not in seen:
        seen.add(line)
        print("%d: %s" % (len(line), line))
PYEOF
}

# part_output_scan N: the escape and width checks over the output this part collected.
part_output_scan() {
  t_begin "REQ-UI-001.2 REQ-UI-001.3 no escape sequence and no fixed line over 80 characters in the output of part $1 of the install suite"
  assert_eq 0 "$(LC_ALL=C grep -c "$(printf '\033')" "$SBX/keep/run-output.txt" || true)" "escapes in piped output"
  if [ -f "$SBX/keep/pty-output.txt" ]; then
    assert_eq 0 "$(LC_ALL=C grep -c "$(printf '\033')" "$SBX/keep/pty-output.txt" || true)" "escapes in NO_COLOR terminal output"
    cat "$SBX/keep/run-output.txt" "$SBX/keep/pty-output.txt" > "$SBX/keep/all-output.txt"
  else
    cp "$SBX/keep/run-output.txt" "$SBX/keep/all-output.txt"
  fi
  assert_eq "" "$(long_lines "$SBX/keep/all-output.txt")" "lines over 80 characters once paths are taken out"
  assert_eq 1 "$([ "$(wc -l < "$SBX/keep/all-output.txt" | tr -d ' ')" -gt 500 ] && echo 1 || echo 0)" "the check covered more than 500 lines of output"
  t_end
}
