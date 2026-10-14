#!/bin/bash
# tests/test-installer-fixes.sh: installer fixes from the release review. 1 test per
# finding id (a wording fix shares a test with its neighbours); each proves an exact
# expected value and failed on the installer before its fix.
#
# Everything runs in the sandbox from tests/lib/sandbox.sh through
# tests/lib/install-common.sh; nothing reads or writes a real config folder.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/install-common.sh"

SM="$REPO/installer/py/settings_merge.py"
IS_ROOT=0
if [ "$(id -u)" = "0" ]; then IS_ROOT=1; fi
flat() { printf '%s' "$1" | tr -d '\r' | tr '\n' ' ' | tr -s ' '; }

# hook_cmds EVENT: the commands wired for EVENT in settings.json, 1 per line
hook_cmds() {
  [ -f "$CLAUDE_DIR/settings.json" ] || return 0
  "$MY_PY" -I -B - "$CLAUDE_DIR/settings.json" "$1" << 'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
for g in d.get("hooks", {}).get(sys.argv[2], []):
    for h in g.get("hooks", []):
        print(h.get("command", ""))
PYEOF
}

# hook_shape: a picture of the hooks: event, matcher, then each command's script and timeout
hook_shape() {
  "$MY_PY" -I -B - "$CLAUDE_DIR/settings.json" << 'PYEOF'
import json, re, sys
d = json.load(open(sys.argv[1]))
for ev in d.get("hooks", {}):
    for g in d["hooks"][ev]:
        items = []
        for h in g["hooks"]:
            m = re.findall(r"/([A-Za-z0-9_.-]+\.py)", h["command"])
            items.append("%s:%s" % (m[-1] if m else h["command"], h.get("timeout")))
        print("%s|%s|%s" % (ev, g.get("matcher"), ",".join(items)))
PYEOF
}

# mutate_settings 'PYTHON': runs it with d = settings.json parsed; writes it back with 2-space indent
mutate_settings() {
  "$MY_PY" -I -B - "$CLAUDE_DIR/settings.json" "$1" << 'PYEOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
exec(sys.argv[2])
json.dump(d, open(p, "w"), indent=2)
PYEOF
}

# ============================================================================
# C-1: the installer's python never reads a module from the folder it started in
# ============================================================================
t_begin "C-1 no installer python reads a module from the folder it was started in, in a dry run and a real run"
fresh claude
sandbox_fake_claude 2.1.296
printf '{"theme": "dark"}\n' > "$CLAUDE_DIR/settings.json"
mkdir -p "$SBX/planted"
printf 'open("%s/c1-marker", "w").write("ran")\nloads = lambda *a, **k: {}\n' "$SBX" > "$SBX/planted/json.py"
cd "$SBX/planted" || exit 99
inst --dry-run
assert_eq 0 "$RC" "dry run exit code"
assert_no_file "$SBX/c1-marker" "the dry run ran the module planted in the current folder"
inst --core --judge-rung=3 --apply-effort-pins
assert_eq 0 "$RC" "real run exit code"
assert_no_file "$SBX/c1-marker" "the real run ran the module planted in the current folder"
cd "$REPO" || exit 99
assert_eq "high" "$(pyj "$CLAUDE_DIR/settings.json" 'd["modelSettings"]["claude-opus-5-5"]["effortLevel"]')" "positive control: the real run did read and write settings"
assert_eq "" "$(grep -nE '"\$(PY|cand)" -c' "$REPO"/installer/src/*.sh)" "every python -c in the installer sources runs with -I -B"
t_end

# ============================================================================
# O-31 S2-1 C-15: the vendor's own ANTHROPIC_BASE_URL is first-party
# ============================================================================
t_begin "O-31 S2-1 C-15 ANTHROPIC_BASE_URL equal to the vendor's own address (any host case, 1 optional trailing slash) is first-party, in the environment and in settings env"
for url in "https://api.anthropic.com" "https://api.anthropic.com/" "https://API.Anthropic.com/"; do
  fresh claude
  sandbox_fake_claude 2.1.296
  ANTHROPIC_BASE_URL="$url" CONDUCTOR_YES=1 inst --core --judge-rung=3 --apply-effort-pins
  assert_eq 0 "$RC" "exit code for $url"
  assert_eq "high" "$(pyj "$CLAUDE_DIR/settings.json" 'd["modelSettings"]["claude-opus-5-5"]["effortLevel"]')" "opus pin written for $url"
  assert_eq "high" "$(pyj "$CLAUDE_DIR/settings.json" 'd["modelSettings"]["claude-sonnet-5-5"]["effortLevel"]')" "sonnet pin written for $url"
  assert_not_contains "$OUT" "another address" "no provider message for $url"
done
fresh claude
sandbox_fake_claude 2.1.296
printf '{"env": {"ANTHROPIC_BASE_URL": "https://api.anthropic.com/"}}\n' > "$CLAUDE_DIR/settings.json"
CONDUCTOR_YES=1 inst --core --judge-rung=3 --apply-effort-pins
assert_eq "high" "$(pyj "$CLAUDE_DIR/settings.json" 'd["modelSettings"]["claude-opus-5-5"]["effortLevel"]')" "pin written with the vendor address in settings env"
assert_eq "https://api.anthropic.com/" "$(pyj "$CLAUDE_DIR/settings.json" 'd["env"]["ANTHROPIC_BASE_URL"]')" "the user's own value is untouched"
fresh claude
sandbox_fake_claude 2.1.296
ANTHROPIC_BASE_URL="https://api.anthropic.com" CONDUCTOR_YES=1 inst --core --judge-rung=1
assert_contains "$OUT" "You are on judge rung 1." "judge rung 1 is possible on the vendor address"
t_end

t_begin "O-31 S2-1 C-15 any other ANTHROPIC_BASE_URL value keeps nothing-written, says it is set to another address and prints the rerun command"
for url in "http://127.0.0.1:9" "https://api.anthropic.com.example.invalid" "https://api.anthropic.com/v1" "http://api.anthropic.com" "https://api.anthropic.com//"; do
  fresh claude
  sandbox_fake_claude 2.1.296
  ANTHROPIC_BASE_URL="$url" CONDUCTOR_YES=1 inst --core --judge-rung=3 --apply-effort-pins
  assert_eq 0 "$RC" "exit code for $url"
  assert_contains "$OUT" "ANTHROPIC_BASE_URL is set to another address" "message for $url"
  assert_contains "$(flat "$OUT")" "env -u ANTHROPIC_BASE_URL bash install.sh --apply-effort-pins" "rerun command for $url"
  assert_not_contains "$OUT" "custom ANTHROPIC_BASE_URL" "old wording for $url"
  assert_no_file "$CLAUDE_DIR/settings.json" "nothing written for $url"
done
fresh claude
sandbox_fake_claude 2.1.296
printf '{"env": {"ANTHROPIC_BASE_URL": "http://127.0.0.1:9"}}\n' > "$CLAUDE_DIR/settings.json"
before="$(sum_of "$CLAUDE_DIR/settings.json")"
CONDUCTOR_YES=1 inst --core --judge-rung=3 --apply-effort-pins
assert_contains "$OUT" "ANTHROPIC_BASE_URL is set to another address" "message when the address is in settings env"
assert_contains "$(flat "$OUT")" "env block of your settings.json" "it says where the address is"
assert_not_contains "$OUT" "env -u ANTHROPIC_BASE_URL" "a command that would not help is not printed"
assert_eq "$before" "$(sum_of "$CLAUDE_DIR/settings.json")" "settings.json untouched"
t_end

# ============================================================================
# S-2 J-7 O-18: the hook guard also tests python3, and the merge knows 2 forms
# ============================================================================
t_begin "S-2 J-7 a wired hook command does nothing and exits 0 when its python3 is gone or not executable"
fresh claude
mkdir -p "$SBX/pyshim"
ln -s "$MY_PY" "$SBX/pyshim/python3"
PATH="$SBX/pyshim:$PATH" CONDUCTOR_COMPONENTS=hook_pointer inst
assert_eq 0 "$RC" "install exit code"
script="$CLAUDE_DIR/conductor/hooks/session-start-pointer.py"
cmd="$(hook_cmds SessionStart | head -n 1)"
assert_eq "[ ! -x \"$SBX/pyshim/python3\" ] || [ ! -f \"$script\" ] || [ ! -r \"$script\" ] || \"$SBX/pyshim/python3\" -I -B \"$script\"" "$cmd" "the wired command"
printf 'print("ran")\n' > "$script"
out="$(/bin/sh -c "$cmd" < /dev/null 2>&1)"
assert_eq "ran" "$out" "positive control: with python3 there the hook runs"
rm "$SBX/pyshim/python3"
out="$(/bin/sh -c "$cmd" < /dev/null 2>&1)"
rc=$?
assert_eq 0 "$rc" "exit code with python3 gone"
assert_eq "" "$out" "output with python3 gone"
printf '#!/bin/sh\necho ran-anyway\n' > "$SBX/pyshim/python3"
chmod 644 "$SBX/pyshim/python3"
out="$(/bin/sh -c "$cmd" < /dev/null 2>&1)"
rc=$?
assert_eq 0 "$rc" "exit code with python3 not executable"
assert_eq "" "$out" "output with python3 not executable"
t_end

t_begin "O-18 the merge removes dangling entries in exactly 2 guarded forms, the current one and the one without the -x test; the form without the -r test is yours"
fresh claude
mkdir -p "$CLAUDE_DIR"
"$MY_PY" -I -B - "$CLAUDE_DIR" "$MY_PY" << 'PYEOF'
import json, os, sys
root, py = sys.argv[1], sys.argv[2]
h = root + "/conductor/hooks/"
cmds = [
    '[ ! -x "%s" ] || [ ! -f "%sgone-a.py" ] || [ ! -r "%sgone-a.py" ] || "%s" -I -B "%sgone-a.py"' % (py, h, h, py, h),
    '[ ! -f "%sgone-b.py" ] || [ ! -r "%sgone-b.py" ] || "%s" -I -B "%sgone-b.py"' % (h, h, py, h),
    '[ ! -f "%sgone-c.py" ] || "%s" -I -B "%sgone-c.py"' % (h, py, h),
]
d = {"hooks": {"Stop": [{"matcher": "", "hooks": [{"type": "command", "command": c, "timeout": 10}]} for c in cmds]}}
json.dump(d, open(os.path.join(root, "settings.json"), "w"), indent=2)
PYEOF
CONDUCTOR_COMPONENTS=hook_pointer inst
assert_eq 0 "$RC" "exit code"
cmds="$(hook_cmds Stop)"
assert_not_contains "$cmds" "gone-a.py" "the current form is Conductor's"
assert_not_contains "$cmds" "gone-b.py" "the delivered form (with -r, without -x) is Conductor's"
assert_contains "$cmds" "gone-c.py" "the form without the -r test is a hook of yours"
assert_eq "" "$(grep -n 'The form without the -r test' "$SM")" "the module no longer describes the form without -r"
t_end

# ============================================================================
# O-25: the Codex skills folder goes only when Conductor made it
# ============================================================================
t_begin "O-25 uninstall removes the Codex skills folder only when the install record says Conductor made it"
fresh claude codex
mkdir -p "$AGENTS_SKILLS_DIR"
CONDUCTOR_YES=1 inst --core
assert_eq 0 "$RC" "install exit code"
assert_eq "True" "$(pyj "$CODEX_DIR/conductor/.install-manifest" 'd["agents_skills_existed"]')" "the record says the folder was there"
inst --uninstall
assert_eq 0 "$RC" "uninstall exit code"
assert_eq 1 "$([ -d "$AGENTS_SKILLS_DIR" ] && echo 1 || echo 0)" "the folder you had stays"
assert_eq "" "$(ls -A "$AGENTS_SKILLS_DIR")" "and it is empty"
assert_contains "$(flat "$OUT")" "kept the empty Codex skills folder" "the uninstall says it kept the empty folder"
fresh claude codex
CONDUCTOR_YES=1 inst --core
assert_eq "False" "$(pyj "$CODEX_DIR/conductor/.install-manifest" 'd["agents_skills_existed"]')" "the record says Conductor made the folder"
CONDUCTOR_YES=1 inst --core
assert_eq "False" "$(pyj "$CODEX_DIR/conductor/.install-manifest" 'd["agents_skills_existed"]')" "a re-run keeps the first answer"
inst --uninstall
assert_no_file "$AGENTS_SKILLS_DIR" "the folder Conductor made goes"
fresh claude codex
sandbox_no_python
CONDUCTOR_YES=1 inst --core
assert_eq 0 "$RC" "install without python3, exit code"
assert_contains "$(cat "$CODEX_DIR/conductor/.install-manifest")" '"agents_skills_existed": false' "the record written without python3 says it too"
inst --uninstall
assert_eq 0 "$RC" "uninstall without python3, exit code"
assert_no_file "$AGENTS_SKILLS_DIR" "the folder Conductor made goes without python3 too"
sandbox_clear_fakes
t_end

# ============================================================================
# O3-1: the line that announces a kept empty Codex skills folder fits 80 columns
# ============================================================================
t_begin "O3-1 the uninstall line that announces a kept empty Codex skills folder is wrapped inside 80 columns and still says it on 1 line"
fresh claude codex
mkdir -p "$AGENTS_SKILLS_DIR"
CONDUCTOR_YES=1 inst --core
assert_eq 0 "$RC" "install exit code"
inst --uninstall
assert_eq 0 "$RC" "uninstall exit code"
assert_eq 1 "$(count_of "$OUT" "kept the empty Codex skills folder")" "the words stay together on 1 line"
printf '%s\n' "$OUT" > "$SBX/w/o3-1.txt"
assert_eq "" "$(long_lines "$SBX/w/o3-1.txt")" "lines over 80 characters once the sandbox paths are taken out"
assert_contains "$(flat "$OUT")" "Remove it if you do not use it." "the rest of the sentence is still there"
t_end

# ============================================================================
# S-16: uninstall keeps the user's own empty "hooks": {}
# ============================================================================
t_begin "S-16 uninstall keeps a \"hooks\": {} you had before the install, and still drops a key it added"
fresh claude
printf '{\n  "theme": "dark",\n  "hooks": {}\n}\n' > "$CLAUDE_DIR/settings.json"
cp "$CLAUDE_DIR/settings.json" "$SBX/w/hooks-empty.orig"
CONDUCTOR_COMPONENTS=hook_pointer,hook_contract inst
assert_eq 0 "$RC" "install exit code"
assert_contains "$(hook_shape)" "SessionStart" "positive control: the hook was wired"
inst --uninstall
assert_eq 0 "$RC" "uninstall exit code"
assert_eq "$(sum_of "$SBX/w/hooks-empty.orig")" "$(sum_of "$CLAUDE_DIR/settings.json")" "settings.json is back byte for byte, hooks object included"
fresh claude
printf '{\n  "theme": "dark"\n}\n' > "$CLAUDE_DIR/settings.json"
cp "$CLAUDE_DIR/settings.json" "$SBX/w/no-hooks.orig"
CONDUCTOR_COMPONENTS=hook_pointer inst
inst --uninstall
assert_eq "$(sum_of "$SBX/w/no-hooks.orig")" "$(sum_of "$CLAUDE_DIR/settings.json")" "a file with no hooks key comes back without one"
t_end

# ============================================================================
# S-8 O-16: the default-model prompt takes only a known alias or a claude- id
# ============================================================================
t_begin "S-8 O-16 model_name_ok accepts the 6 aliases and a claude- id, and nothing else"
for name in opus sonnet haiku fable best default claude-opus-5-5 claude-sonnet-5-5 claude-x; do
  ok="$( . "$LIB"; model_name_ok "$name" && echo yes || echo no)"
  assert_eq yes "$ok" "accepted: $name"
done
for name in y n yes no Y opus5 "a;b" "opus sonnet" claude- "claude-opus-5-5[1m]" "" gpt-5; do
  ok="$( . "$LIB"; model_name_ok "$name" && echo yes || echo no)"
  assert_eq no "$ok" "refused: [$name]"
done
t_end

t_begin "S-8 O-16 a wrong model name is asked for once more, then no default model is set; an empty answer sets none; a known name is written"
fresh claude
PTY_INPUT=$'\ny\ny\nsonnet\n' pty /bin/bash "$INST"
assert_eq 0 "$RC" "exit code with a slip then a name"
assert_eq "sonnet" "$(pyj "$CLAUDE_DIR/settings.json" 'd["model"]')" "the second answer is written"
assert_contains "$OUT" "not a model name" "the slip is named"
fresh claude
PTY_INPUT=$'\ny\ny\nn\n' pty /bin/bash "$INST"
assert_eq 0 "$RC" "exit code with 2 slips"
assert_no_file "$CLAUDE_DIR/settings.json" "2 wrong answers set no model"
assert_contains "$OUT" "no default model is set" "it says so"
fresh claude
PTY_INPUT=$'\ny\n\n' pty /bin/bash "$INST"
assert_eq 0 "$RC" "exit code with an empty answer"
assert_no_file "$CLAUDE_DIR/settings.json" "an empty answer sets no model"
assert_contains "$OUT" "your setting stays as it is" "it says so"
fresh claude
PTY_INPUT=$'\ny\nclaude-sonnet-5-5\n' pty /bin/bash "$INST"
assert_eq "claude-sonnet-5-5" "$(pyj "$CLAUDE_DIR/settings.json" 'd["model"]')" "a full model id is written"
t_end

# ============================================================================
# S-12: the manual wiring text prints each event key once
# ============================================================================
t_begin "S-12 the hook entries printed for a settings.json that cannot be changed hold 1 key per event and parse as JSON"
fresh claude
printf '{\n  // my comment\n  "theme": "dark"\n}\n' > "$CLAUDE_DIR/settings.json"
before="$(sum_of "$CLAUDE_DIR/settings.json")"
CONDUCTOR_COMPONENTS="$ALL5" inst
assert_eq 0 "$RC" "exit code"
assert_eq "$before" "$(sum_of "$CLAUDE_DIR/settings.json")" "settings.json untouched"
printf '%s\n' "$OUT" | awk 'f && !/^  ("|\]| )/{exit} f{print} /add these under/{f=1}' > "$SBX/w/printed.txt"
got="$("$MY_PY" -I -B - "$SBX/w/printed.txt" << 'PYEOF'
import json, sys
text = "{" + open(sys.argv[1]).read() + "}"
keys = []
def hook(pairs):
    for k, v in pairs:
        keys.append(k)
    return dict(pairs)
d = json.loads(text, object_pairs_hook=hook)
events = [k for k in keys if k in ("SessionStart", "UserPromptSubmit", "Stop", "PreToolUse", "SubagentStop")]
n = sum(len(groups) for groups in d.values())
print("%d|%s" % (n, ",".join(sorted(events))))
PYEOF
)"
assert_eq "6|PreToolUse,SessionStart,Stop,SubagentStop,UserPromptSubmit" "$got" "6 groups, each event key exactly once"
t_end

# ============================================================================
# S-9 O-27: Claude Code lines under a Claude Code heading, Codex lines under Codex
# ============================================================================
t_begin "S-9 O-27 with both folders, every Claude Code action prints under the Claude Code heading and every Codex action under the Codex heading"
fresh claude codex
sandbox_fake_claude 2.1.296
CONDUCTOR_COMPONENTS=hook_pointer CONDUCTOR_YES=1 inst --full --judge-rung=3 --apply-effort-pins
assert_eq 0 "$RC" "exit code"
printf '%s\n' "$OUT" > "$SBX/w/both.txt"
got="$("$MY_PY" -I -B - "$SBX/w/both.txt" << 'PYEOF'
import re, sys
cur = None
want = {
    "CLAUDE.md block written": "Claude Code",
    "wrote agents/judge.md": "Claude Code",
    "wrote conductor/hooks/hooklib.py": "Claude Code",
    "wrote skills/handoff/SKILL.md": "Claude Code",
    "effort pin: wrote high": "Claude Code",
    "AGENTS.md block written": "Codex",
}
seen = {}
bad = []
for line in open(sys.argv[1], encoding="utf-8"):
    m = re.match(r"^  (Claude Code|Codex)(, continued)?: ", line)
    if m:
        cur = m.group(1)
        continue
    for key, head in want.items():
        if key in line:
            seen[key] = seen.get(key, 0) + 1
            if cur != head:
                bad.append("%s under %s" % (key, cur))
print("|".join(sorted(bad)) + "#" + str(len(seen)))
PYEOF
)"
assert_eq "#6" "$got" "no action under the wrong heading, and all 6 kinds seen"
assert_not_contains "$OUT" "Installing into" "the old heading is gone"
t_end

t_begin "O-27 S-9 the Codex-only uninstall says its backups hold Codex files, not settings.json; the Claude Code uninstall keeps the settings.json warning"
fresh codex
printf 'my codex notes\n' > "$CODEX_DIR/AGENTS.md"
CONDUCTOR_YES=1 inst --core
assert_eq 0 "$RC" "install exit code"
inst --uninstall
assert_eq 0 "$RC" "uninstall exit code"
assert_contains "$OUT" "backups from the installer are in" "the backups are named"
assert_contains "$OUT" "copies of Codex files Conductor replaced" "what they hold"
assert_not_contains "$OUT" "settings.json" "the Codex backups are not said to hold settings.json"
fresh claude
printf '{"theme": "dark"}\n' > "$CLAUDE_DIR/settings.json"
sandbox_fake_claude 2.1.296
CONDUCTOR_YES=1 inst --core --judge-rung=3 --apply-effort-pins
inst --uninstall
assert_contains "$OUT" "copies of your settings.json, which may contain secrets" "the Claude Code folder keeps its warning"
t_end

# ============================================================================
# S-10: an unreadable Conductor file gives a plain message and no false "wired"
# ============================================================================
t_begin "S-10 an unreadable hook script gives a plain message naming it, no raw shell error, and no claim that the hook was wired"
if [ "$IS_ROOT" = 1 ]; then
  echo "  note: running as root, file modes do not stop a read; S-10 is not provable here"
else
  fresh claude
  mkdir -p "$CLAUDE_DIR/conductor/hooks"
  printf 'x\n' > "$CLAUDE_DIR/conductor/hooks/checkpoint-nudge.py"
  chmod 000 "$CLAUDE_DIR/conductor/hooks/checkpoint-nudge.py"
  CONDUCTOR_COMPONENTS=hook_nudge inst
  assert_eq 0 "$RC" "install exit code"
  assert_not_contains "$OUT" "Permission denied" "no raw shell error"
  assert_not_contains "$OUT" "install.sh: line" "no line number of the generated installer"
  assert_contains "$OUT" "conductor/hooks/checkpoint-nudge.py (it cannot be read" "the file is named in plain words"
  assert_not_contains "$OUT" "wired the checkpoint nudge hook" "no claim that the hook was wired"
  assert_contains "$OUT" "did not wire the checkpoint nudge hook" "it says it did not"
  assert_eq "" "$(hook_cmds UserPromptSubmit)" "no hook entry points at the unreadable script"
  inst --uninstall
  assert_not_contains "$OUT" "Permission denied" "no raw shell error on uninstall"
  assert_not_contains "$OUT" "install.sh: line" "no line number on uninstall"
  chmod 644 "$CLAUDE_DIR/conductor/hooks/checkpoint-nudge.py"
fi
t_end

# ============================================================================
# S-11: removed hook entries are named by event, matcher and script
# ============================================================================
t_begin "S-11 each removed hook entry is named on 1 line as event, matcher and script name, with no guard fragment"
fresh claude
CONDUCTOR_COMPONENTS="$ALL5" inst
assert_eq 0 "$RC" "install exit code"
n="$(pyj "$CLAUDE_DIR/conductor/.install-manifest" 'len(d["hooks"])')"
inst --uninstall
assert_eq 0 "$RC" "uninstall exit code"
removed="$(printf '%s\n' "$OUT" | grep 'removed hook entry:')"
assert_eq "$n" "$(printf '%s\n' "$removed" | grep -c .)" "1 line for each of the $n entries"
assert_not_contains "$removed" "[ ! -" "no guard fragment"
assert_not_contains "$removed" "-I -B" "no command text"
assert_contains "$removed" "removed hook entry: SessionStart, no matcher, session-start-pointer.py" "event, matcher, script"
assert_contains "$removed" "removed hook entry: PreToolUse, matcher Agent|Task, contract-check.py" "a matcher is shown"
assert_eq "" "$(printf '%s\n' "$removed" | awk 'length($0) > 79')" "no line over 79 characters"
t_end

# ============================================================================
# S-7: a matcher you narrowed stays on a re-run
# ============================================================================
t_begin "S-7 a re-run keeps a matcher you narrowed on a Conductor hook, keeps the event where it is, and the summary line stays true"
fresh claude
CONDUCTOR_COMPONENTS=hook_pointer,hook_contract inst
assert_eq 0 "$RC" "install exit code"
mutate_settings '
h = d["hooks"]
h["PreToolUse"][0]["matcher"] = "Agent"
import re
for ev in h:
    for g in h[ev]:
        for e in g["hooks"]:
            e["command"] = re.sub(r"^\[ ! -x \"[^\"]+\" \] \|\| ", "", e["command"])'
assert_not_contains "$(cat "$CLAUDE_DIR/settings.json")" "[ ! -x" "setup: the entries are in the delivered guard form"
events_before="$(pyj "$CLAUDE_DIR/settings.json" '",".join(d["hooks"].keys())')"
CONDUCTOR_COMPONENTS=hook_pointer,hook_contract inst
assert_eq 0 "$RC" "re-run exit code"
assert_eq "Agent" "$(pyj "$CLAUDE_DIR/settings.json" 'd["hooks"]["PreToolUse"][0]["matcher"]')" "the narrowed matcher is kept"
assert_eq 1 "$(pyj "$CLAUDE_DIR/settings.json" 'len(d["hooks"]["PreToolUse"])')" "no second PreToolUse group was added"
assert_eq "$events_before" "$(pyj "$CLAUDE_DIR/settings.json" '",".join(d["hooks"].keys())')" "the events keep their order"
assert_contains "$(cat "$CLAUDE_DIR/settings.json")" "[ ! -x" "the entries are back in the current form"
assert_eq "Agent" "$(pyj "$CLAUDE_DIR/conductor/.install-manifest" '[h["matcher"] for h in d["hooks"] if h["event"] == "PreToolUse"][0]')" "the record holds the matcher that is in the file"
assert_contains "$(flat "$OUT")" "Hook entries: Conductor's own were refreshed; your timeouts, matchers and order stay" "the summary line"
assert_not_contains "$OUT" "removed hook entry" "no entry was removed"
t_end

# ============================================================================
# S-4 C-9 S-5: the settings layout, and numbers and strings that cannot be kept
# ============================================================================
t_begin "S-4 C-9 settings.json keeps CRLF line endings and its final-newline state through an install and an uninstall, byte for byte"
"$MY_PY" -I -B - "$SBX/keep" << 'PYEOF'
import json, os, sys
w = sys.argv[1]
d = {"theme": "dark", "permissions": {"allow": ["Bash(ls)"]}}
text = json.dumps(d, indent=2)
open(os.path.join(w, "crlf.json"), "wb").write((text.replace("\n", "\r\n") + "\r\n").encode())
open(os.path.join(w, "crlf-nonl.json"), "wb").write(text.replace("\n", "\r\n").encode())
open(os.path.join(w, "lf-nonl.json"), "wb").write(text.encode())
PYEOF
for name in crlf crlf-nonl lf-nonl; do
  fresh claude
  cp "$SBX/keep/$name.json" "$CLAUDE_DIR/settings.json"
  CONDUCTOR_COMPONENTS=hook_pointer inst
  assert_eq 0 "$RC" "install exit code [$name]"
  assert_contains "$(cat "$CLAUDE_DIR/settings.json")" "session-start-pointer.py" "positive control: the hook was wired [$name]"
  got="$("$MY_PY" -I -B - "$CLAUDE_DIR/settings.json" << 'PYEOF'
import sys
b = open(sys.argv[1], "rb").read()
lf, crlf = b.count(b"\n"), b.count(b"\r\n")
ending = "crlf" if lf and lf == crlf else ("lf" if crlf == 0 else "mixed")
print("%s|%s" % (ending, "nl" if b.endswith(b"\n") else "nonl"))
PYEOF
)"
  case "$name" in
    crlf) assert_eq "crlf|nl" "$got" "line ending and final line break after the install [$name]" ;;
    crlf-nonl) assert_eq "crlf|nonl" "$got" "line ending and final line break after the install [$name]" ;;
    lf-nonl) assert_eq "lf|nonl" "$got" "line ending and final line break after the install [$name]" ;;
  esac
  inst --uninstall
  assert_eq 0 "$RC" "uninstall exit code [$name]"
  assert_eq "$(sum_of "$SBX/keep/$name.json")" "$(sum_of "$CLAUDE_DIR/settings.json")" "settings.json is back byte for byte [$name]"
done
t_end

t_begin "C-9 S-4 an object on 1 line may be spread over several, every key and value stays, and the summary says so"
fresh claude
printf '{\n  "permissions": {"allow": ["Bash(ls)"]},\n  "env": {"FOO_TOKEN": "x"}\n}\n' > "$CLAUDE_DIR/settings.json"
sandbox_fake_claude 2.1.296
CONDUCTOR_YES=1 inst --core --judge-rung=3 --apply-effort-pins
assert_eq 0 "$RC" "install exit code"
assert_eq '["Bash(ls)"]' "$(pyj "$CLAUDE_DIR/settings.json" 'json.dumps(d["permissions"]["allow"])')" "your value is kept"
assert_eq "x" "$(pyj "$CLAUDE_DIR/settings.json" 'd["env"]["FOO_TOKEN"]')" "your env value is kept"
assert_contains "$(flat "$OUT")" "Settings file: your indentation, line endings and final line break were kept. An object you wrote on 1 line may now span several." "the summary line"
inst --uninstall
assert_contains "$(flat "$OUT")" "Settings file: your indentation, line endings and final line break were kept. An object you wrote on 1 line may now span several." "the uninstall says it too"
assert_eq '["Bash(ls)"]' "$(pyj "$CLAUDE_DIR/settings.json" 'json.dumps(d["permissions"]["allow"])')" "your value is kept after the uninstall"
t_end

t_begin "S-5 a number too large to keep (1e999) and a lone surrogate escape leave settings.json as it is, with a plain message and no crash"
fresh claude
printf '{"x": 1e999, "theme": "dark"}\n' > "$CLAUDE_DIR/settings.json"
before="$(sum_of "$CLAUDE_DIR/settings.json")"
sandbox_fake_claude 2.1.296
CONDUCTOR_YES=1 inst --core --judge-rung=3 --apply-effort-pins
assert_eq 0 "$RC" "exit code with 1e999"
assert_eq "$before" "$(sum_of "$CLAUDE_DIR/settings.json")" "the file is byte for byte as it was"
assert_not_contains "$(cat "$CLAUDE_DIR/settings.json")" "Infinity" "no Infinity written"
assert_contains "$OUT" "could not be changed safely" "the pins are printed with a plain reason"
fresh claude
printf '{"note": "bad \\ud83d surrogate", "hooks": {}}\n' > "$CLAUDE_DIR/settings.json"
before="$(sum_of "$CLAUDE_DIR/settings.json")"
CONDUCTOR_COMPONENTS=hook_pointer inst
assert_eq 0 "$RC" "exit code with a lone surrogate"
assert_eq "$before" "$(sum_of "$CLAUDE_DIR/settings.json")" "the file is byte for byte as it was"
assert_contains "$OUT" "was left as it is" "the plain message"
assert_not_contains "$OUT" "could not read settings.json" "not the misleading one"
assert_not_contains "$OUT" "install stopped" "the install did not stop"
assert_contains "$OUT" "add these under" "the entries are printed instead"
t_end

# ============================================================================
# C-10 O3-2 C3-11: install writes through a linked folder and says so; uninstall leaves those files
# ============================================================================
t_begin "C-10 a linked sub-folder of the Claude folder is written through on install, with 1 line that says so; uninstall leaves those files and lists them"
fresh claude
mkdir -p "$SBX/elsewhere/hooks" "$CLAUDE_DIR/conductor"
ln -s "$SBX/elsewhere/hooks" "$CLAUDE_DIR/conductor/hooks"
CONDUCTOR_COMPONENTS=hook_pointer inst
assert_eq 0 "$RC" "install exit code"
assert_file "$SBX/elsewhere/hooks/hooklib.py" "the file was written through the link"
assert_file "$SBX/elsewhere/hooks/session-start-pointer.py" "and the hook script"
assert_eq 1 "$(count_of "$OUT" "wrote through the symbolic link")" "1 line for the 1 linked folder"
assert_contains "$(flat "$OUT")" "wrote through the symbolic link $CLAUDE_DIR/conductor/hooks" "the line names the link"
assert_contains "$(flat "$OUT")" "(uninstall will leave those files for you to remove)" "and says what uninstall will do"
assert_not_contains "$OUT" "a folder on the way is a symbolic link" "the refusal wording is gone"
assert_contains "$OUT" "Done. Conductor v" "the install is complete"
assert_contains "$(hook_cmds SessionStart)" "session-start-pointer.py" "the hook is wired to the script that was written"
assert_not_contains "$OUT" "did not wire" "no hook was left unwired"
inst --uninstall
assert_eq 0 "$RC" "uninstall exit code"
assert_file "$SBX/elsewhere/hooks/hooklib.py" "the uninstall never follows the link"
assert_contains "$OUT" "Left alone (a link, or not a plain file; delete them yourself):"
assert_contains "$OUT" "    conductor/hooks/hooklib.py"
fresh claude
mkdir -p "$SBX/shared-agents"
ln -s "$SBX/shared-agents" "$CLAUDE_DIR/agents"
CONDUCTOR_YES=1 inst --core
assert_eq 0 "$RC" "install exit code with a linked agents folder"
assert_file "$SBX/shared-agents/builder.md" "the agent file is in the linked folder"
assert_file "$CLAUDE_DIR/skills/conductor/SKILL.md" "the rest of the install went ahead"
assert_eq 1 "$(count_of "$OUT" "wrote through the symbolic link")" "1 line for the linked agents folder"
inst --uninstall
assert_file "$SBX/shared-agents/builder.md" "the uninstall leaves the agent file"
assert_contains "$OUT" "    agents/builder.md" "and lists it"
t_end

t_begin "O3-2 with agents/ and skills/ both linked to other folders, install writes the 5 agents and the /conductor skill through them, says so once per link, and ends with Done"
fresh claude
mkdir -p "$SBX/dot/agents" "$SBX/dot/skills"
ln -s "$SBX/dot/agents" "$CLAUDE_DIR/agents"
ln -s "$SBX/dot/skills" "$CLAUDE_DIR/skills"
CONDUCTOR_YES=1 inst --core
assert_eq 0 "$RC" "install exit code"
for a in builder scout critic architect judge; do
  assert_file "$SBX/dot/agents/$a.md" "agents/$a.md was written through the link"
done
assert_file "$SBX/dot/skills/conductor/SKILL.md" "skills/conductor/SKILL.md was written through the link"
assert_file "$SBX/dot/skills/conductor/VERSION" "skills/conductor/VERSION was written through the link"
assert_eq 2 "$(count_of "$OUT" "wrote through the symbolic link")" "1 line per linked folder, 2 folders"
assert_contains "$(flat "$OUT")" "wrote through the symbolic link $CLAUDE_DIR/agents" "the agents link is named"
assert_contains "$(flat "$OUT")" "wrote through the symbolic link $CLAUDE_DIR/skills" "the skills link is named"
assert_contains "$OUT" "Done. Conductor v" "a complete install says Done"
assert_not_contains "$OUT" "Kept as yours" "nothing is listed as the user's"
assert_not_contains "$OUT" "Not installed" "nothing is listed as not installed"
printf '%s\n' "$OUT" > "$SBX/w/o3-2.txt"
assert_eq "" "$(long_lines "$SBX/w/o3-2.txt")" "lines over 80 characters once the sandbox paths are taken out"
CONDUCTOR_YES=1 inst --core
assert_eq 0 "$(count_of "$OUT" "wrote through the symbolic link")" "a re-run that writes nothing says nothing about the links"
inst --uninstall
assert_eq 0 "$RC" "uninstall exit code"
assert_file "$SBX/dot/agents/builder.md" "uninstall leaves the agent file behind the link"
assert_file "$SBX/dot/skills/conductor/SKILL.md" "and the skill file"
assert_contains "$OUT" "Left alone (a link, or not a plain file; delete them yourself):"
assert_contains "$OUT" "    agents/builder.md"
assert_contains "$OUT" "    skills/conductor/SKILL.md"
assert_contains "$OUT" "Conductor removed, except the files listed below."
t_end

t_begin "C3-11 an install that could not write a payload file for a reason other than a file you changed does not say Done, lists the file under Not installed with the reason, and gives the next step"
fresh claude
mkdir -p "$CLAUDE_DIR/agents/builder.md"
CONDUCTOR_YES=1 inst --core
assert_not_contains "$OUT" "Done. Conductor v" "no Done line"
assert_contains "$OUT" "Incomplete. Conductor v" "the install says it is incomplete"
assert_contains "$OUT" "Not installed (1 file):" "the heading"
assert_contains "$OUT" "      agents/builder.md (a folder is there)" "the file and the reason"
assert_not_contains "$OUT" "Kept as yours" "a folder in the way is not a file you changed"
assert_contains "$(flat "$OUT")" "run the installer again" "the next step"
assert_not_contains "$OUT" "/conductor <your objective>" "no promise of a working skill"
assert_file "$CLAUDE_DIR/agents/scout.md" "the other files went in"
fresh claude
mkdir -p "$CLAUDE_DIR/agents" "$CLAUDE_DIR/CLAUDE.md"
ln -s scout.md "$CLAUDE_DIR/agents/scout.md"
CONDUCTOR_YES=1 inst --core
assert_not_contains "$OUT" "Done. Conductor v" "no Done line"
assert_contains "$OUT" "Not installed (2 files):" "the heading counts both"
assert_contains "$OUT" "      agents/scout.md (the symbolic links loop)" "a link that loops, with the reason"
assert_contains "$OUT" "      CLAUDE.md (a folder is there)" "the doctrine file as a folder, with the reason"
fresh claude
CONDUCTOR_YES=1 inst --core
printf 'my own scout\n' > "$CLAUDE_DIR/agents/scout.md"
CONDUCTOR_YES=1 inst --core
assert_contains "$OUT" "Done. Conductor v" "a file you changed alone does not make the install incomplete"
assert_contains "$OUT" "Kept as yours (not replaced):" "it stays under Kept as yours"
assert_not_contains "$OUT" "Not installed" "and not under Not installed"
if [ "$IS_ROOT" = 1 ]; then
  echo "  note: running as root, file modes do not stop a read; the unreadable file is not provable here"
else
  fresh claude
  CONDUCTOR_YES=1 inst --core
  printf 'changed\n' > "$CLAUDE_DIR/agents/critic.md"
  chmod 000 "$CLAUDE_DIR/agents/critic.md"
  CONDUCTOR_YES=1 inst --core
  chmod 644 "$CLAUDE_DIR/agents/critic.md"
  assert_not_contains "$OUT" "Done. Conductor v" "an unreadable file is not a file you changed: no Done line"
  assert_contains "$OUT" "      agents/critic.md (it cannot be read; check its permissions)" "listed with the reason"
fi
t_end

# ============================================================================
# J-9 J-10: wording
# ============================================================================
t_begin "J-9 a file you had before Conductor is reported as yours from before; a Conductor file you changed since is reported as changed"
fresh claude
mkdir -p "$CLAUDE_DIR/agents"
printf 'MY OWN BUILDER\n' > "$CLAUDE_DIR/agents/builder.md"
CONDUCTOR_YES=1 inst --core
assert_eq 0 "$RC" "install exit code"
assert_contains "$OUT" "kept your agents/builder.md (it was there before Conductor)" "first install over your file"
assert_not_contains "$OUT" "kept agents/builder.md (you changed it)" "not the changed wording"
assert_eq "MY OWN BUILDER" "$(cat "$CLAUDE_DIR/agents/builder.md")" "your file is untouched"
printf 'edited scout\n' > "$CLAUDE_DIR/agents/scout.md"
CONDUCTOR_YES=1 inst --core
assert_contains "$OUT" "kept agents/scout.md (you changed it)" "a Conductor file you edited since"
assert_contains "$OUT" "kept your agents/builder.md (it was there before Conductor)" "your own file, on the re-run"
t_end

t_begin "J-10 the summary says the checkpoint nudge works without CONDUCTOR_WINDOW and what setting it adds"
fresh claude
CONDUCTOR_COMPONENTS=hook_nudge inst
assert_eq 0 "$RC" "install exit code"
assert_contains "$(flat "$OUT")" "The checkpoint nudge works without CONDUCTOR_WINDOW." "works without it"
assert_contains "$(flat "$OUT")" "to add a note at 50 percent of context use" "what it adds"
assert_not_contains "$OUT" "needs your context window size" "the old claim is gone"
t_end

# ============================================================================
# S-15 N-1
# ============================================================================
t_begin "S-15 uninstall with an unreadable install record prints the next step"
fresh claude
CONDUCTOR_YES=1 inst --core
printf 'garbage\n' > "$CLAUDE_DIR/conductor/.install-manifest"
inst --uninstall
assert_eq 1 "$RC" "exit code"
assert_contains "$OUT" "cannot be read; nothing was changed there" "the problem"
assert_contains "$OUT" "Run the installer again" "the next step"
inst --core
inst --uninstall
assert_eq 0 "$RC" "after the installer ran again, the uninstall works"
t_end

t_begin "N-1 the installer carries no secret-prompt helper"
assert_eq 0 "$(grep -c 'ask_secret' "$REPO/install.sh")" "ask_secret in install.sh"
assert_eq 0 "$(grep -rl 'ask_secret' "$REPO/installer" | wc -l | tr -d ' ')" "ask_secret in installer sources"
t_end

t_summary
