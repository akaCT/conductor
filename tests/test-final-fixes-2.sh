#!/bin/bash
# tests/test-final-fixes-2.sh: the late review fixes, second part: a hook of yours is never
# removed, ledger-append, the doctor's claims, and the settings.json, CLAUDE.md and
# hook-entry fixes. 1 test per fix; each proves an exact expected value and failed before
# its fix.
#
# Everything runs in the sandbox from tests/lib/sandbox.sh through tests/lib/install-common.sh;
# nothing reads or writes a real config folder.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/install-common.sh"

LA="$REPO/payload/claude/conductor/bin/ledger-append"
SM="$REPO/installer/py/settings_merge.py"

# launcher ARGS...: the installed launcher of CLAUDE_DIR; leaves OUT and RC.
launcher() {
  OUT="$(NO_COLOR=1 /bin/bash "$CLAUDE_DIR/conductor/bin/conductor" "$@" 2>&1 < /dev/null)"
  RC=$?
}
flat() { printf '%s' "$1" | tr -d '\r' | tr '\n' ' ' | tr -s ' '; }

# =============================================================================
# a hook of yours is never removed
# =============================================================================
cat > "$SBX/hooks-of.py" << 'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
rows = []
for ev, groups in d.get("hooks", {}).items():
    for g in groups:
        for h in g.get("hooks", []):
            rows.append((ev, h.get("command", "")))
mine = json.load(open(sys.argv[2]))
if sys.argv[3] == "user":
    print(sum(1 for ev, c in rows if mine.get(ev) == c))
else:
    print(sum(1 for ev, c in rows if mine.get(ev) != c))
PYEOF
hooks_of() { "$MY_PY" "$SBX/hooks-of.py" "$CLAUDE_DIR/settings.json" "$CLAUDE_DIR/user-hooks.json" "$1"; }

t_begin "hooks of your own that name a path under conductor survive an install, a re-run and an uninstall, while Conductor's own entries are still replaced and removed, each removal printed"
fresh claude
mkdir -p "$CLAUDE_DIR"
"$MY_PY" - "$CLAUDE_DIR" "$MY_PY" "$HOME" << 'PYEOF'
import json, os, sys
root, py, home = sys.argv[1:4]
user = {
    "PostToolUse": 'tail -n 5 "%s/conductor/logs/errors.log"' % root,
    "SessionStart": 'cat "%s/conductor/hooks/my-own-config.json"' % root,
    "UserPromptSubmit": '"%s" "%s/conductor/hooks/contract-check.py" --report' % (py, root),
    "Notification": '[ ! -f "%s/other/h.py" ] || [ ! -r "%s/other/h.py" ] || "%s" -I -B "%s/other/h.py"' % (home, home, py, home),
    "PreCompact": '[ ! -f "%s/conductor/hooks/../../outside/h.py" ] || [ ! -r "%s/conductor/hooks/../../outside/h.py" ] || "%s" -I -B "%s/conductor/hooks/../../outside/h.py"' % (root, root, py, root),
}
d = {"hooks": {ev: [{"matcher": "", "hooks": [{"type": "command", "command": c}]}] for ev, c in user.items()}}
json.dump(d, open(os.path.join(root, "settings.json"), "w"), indent=2)
json.dump(user, open(os.path.join(root, "user-hooks.json"), "w"))
PYEOF
CONDUCTOR_COMPONENTS=hook_pointer inst
assert_eq 0 "$RC" "install exit code"
assert_eq 5 "$(hooks_of user)" "your 5 own hooks after the install"
assert_eq 1 "$(hooks_of other)" "Conductor's own entry, wired once"
assert_eq 0 "$(printf '%s\n' "$OUT" | grep -c 'removed hook entry:')" "an install over hooks of your own removes nothing"
after_install="$(cat "$CLAUDE_DIR/settings.json")"
CONDUCTOR_COMPONENTS=hook_pointer inst
assert_eq "$after_install" "$(cat "$CLAUDE_DIR/settings.json")" "a re-run leaves settings.json byte for byte"
assert_eq 0 "$(printf '%s\n' "$OUT" | grep -c 'removed hook entry:')" "a plain re-run removes and prints nothing"
# a Conductor entry whose script is gone is replaced, and the removal is named
"$MY_PY" - "$CLAUDE_DIR" "$MY_PY" << 'PYEOF'
import json, os, sys
root, py = sys.argv[1:3]
sp = os.path.join(root, "settings.json")
d = json.load(open(sp))
c = '[ ! -f "%s/conductor/hooks/gone-new.py" ] || [ ! -r "%s/conductor/hooks/gone-new.py" ] || "%s" -I -B "%s/conductor/hooks/gone-new.py"' % (root, root, py, root)
d["hooks"].setdefault("Stop", []).append({"matcher": "", "hooks": [{"type": "command", "command": c, "timeout": 10}]})
json.dump(d, open(sp, "w"), indent=2)
PYEOF
CONDUCTOR_COMPONENTS=hook_pointer inst
assert_eq 5 "$(hooks_of user)" "your 5 own hooks after the run that cleaned up"
assert_not_contains "$(cat "$CLAUDE_DIR/settings.json")" "gone-new.py" "Conductor's dangling entry is gone"
assert_eq 1 "$(printf '%s\n' "$OUT" | grep -c 'removed hook entry:')" "the removal is named in 1 entry"
assert_contains "$(flat "$OUT")" "gone-new.py" "it names the command"
# the uninstall
inst --uninstall
assert_eq 0 "$RC" "uninstall exit code"
assert_eq 5 "$(hooks_of user)" "your 5 own hooks after the uninstall"
assert_eq 0 "$(hooks_of other)" "no Conductor entry after the uninstall"
assert_eq 1 "$(printf '%s\n' "$OUT" | grep -c 'removed hook entry:')" "the uninstall names the 1 entry it removed"
# the merge program itself: removed commands come out 1 per line, with no line break, tab or return in them
"$MY_PY" - "$SBX" << 'PYEOF'
import json, os, sys
sbx = sys.argv[1]
cmd = 'echo one\ntwo\tthree\rfour'
json.dump({"hooks": {"Stop": [{"matcher": "", "hooks": [{"type": "command", "command": cmd}]}]}}, open(os.path.join(sbx, "sm-settings.json"), "w"))
json.dump([{"id": "x", "event": "Stop", "matcher": "", "command": cmd, "timeout": 5}], open(os.path.join(sbx, "sm-record.json"), "w"))
PYEOF
"$MY_PY" "$SM" "$SBX/sm-settings.json" unwire "$SBX/ROOT" "$SBX/sm-record.json" "$SBX/sm-removed.txt" > "$SBX/sm-out.json"
assert_eq "$(printf 'Stop\t\techo one two three four')" "$(cat "$SBX/sm-removed.txt")" "a command that is in the record is removed, as 1 line: event, matcher, name"
assert_eq 1 "$(wc -l < "$SBX/sm-removed.txt" | tr -d ' ')" "1 line for 1 removed command"
t_end

# =============================================================================
# ledger-append strips invisible and direction characters and refuses .claude
# =============================================================================
t_begin "ledger-append strips invisible and direction characters and refuses a ledger under .claude"
LP="$SBX/ledger-f25"
rm -rf "$LP"
mkdir -p "$LP/.claude/agents" "$LP/docs"
out="$(/bin/bash "$LA" --project "$LP" --ledger "$LP/.claude/agents/X-LEDGER.md" --disposition ASK --text "x" 2>&1)"
rc=$?
assert_eq 3 "$rc" "exit code under .claude/agents"
assert_contains "$out" "the ledger is inside a .claude folder; refused, nothing was changed" "the refusal"
assert_no_file "$LP/.claude/agents/X-LEDGER.md" "nothing was created there"
out="$(/bin/bash "$LA" --project "$LP" --ledger "$LP/.CLAUDE/Y-LEDGER.md" --disposition ASK --text "x" 2>&1)"
assert_eq 3 "$?" "exit code under .CLAUDE, any letter case"
out="$(/bin/bash "$LA" --project "$LP" --ledger "$LP/docs/X-LEDGER.md" --disposition ASK --text "x" 2>&1)"
assert_eq "added D-001" "$out" "a ledger in another folder is accepted"
text="$("$MY_PY" -c 'import sys; sys.stdout.write("re‮al​ly ok﻿\u0085⁦end")')"
out="$(/bin/bash "$LA" --project "$LP" --ledger "$LP/docs/X-LEDGER.md" --disposition ASK --text "$text" 2>&1)"
assert_eq "added D-002" "$out" "a row with hidden characters"
assert_eq 1 "$(grep -c '| really okend |' "$LP/docs/X-LEDGER.md")" "the row text, with the hidden characters gone"
assert_eq 0 "$("$MY_PY" -c '
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
print(len(re.findall("[\u0080-\u009f​-‏ -‮⁠-⁩﻿]", t)))' "$LP/docs/X-LEDGER.md")" "no hidden character left in the ledger"
t_end

# =============================================================================
# the claims about what the doctor does and what a run with no terminal does
# =============================================================================
t_begin "every description of the doctor says it also asks claude and codex for their version numbers, and none says it only reads files"
fresh claude
sandbox_fake_claude 2.1.296
CONDUCTOR_YES=1 inst --core
launcher doctor --managed-settings "$SBX/managed-settings.json"
assert_contains "$(flat "$OUT")" "This check reads files and the environment, and asks claude and codex for their version numbers. It sends nothing." "the doctor's own first lines"
assert_not_contains "$OUT" "reads files and the environment only" "the old claim in the doctor"
launcher help
assert_contains "$(flat "$OUT")" "conductor doctor check this install: reads files and the environment, asks claude and codex for their version numbers, sends nothing" "launcher help"
assert_not_contains "$OUT" "reads files, sends nothing" "the old claim in the launcher help"
launcher
assert_contains "$(flat "$OUT")" "asks claude and codex for their version numbers" "launcher usage with no argument"
assert_contains "$(flat "$(sed -n '1,12p' "$REPO/payload/claude/conductor/bin/conductor")")" "asks claude and codex for their version numbers" "launcher header comment"
assert_not_contains "$(sed -n '1,12p' "$REPO/payload/claude/conductor/bin/conductor")" "reads files only" "the old claim in the launcher header"
assert_contains "$(flat "$(sed -n '1,12p' "$REPO/payload/claude/conductor/lib/doctor.py")")" "asks claude and codex for their version numbers" "doctor.py header"
assert_contains "$(flat "$(cat "$REPO/README.md")")" "reads files and the environment, asks \`claude\` and \`codex\` for their version numbers, and sends nothing" "README"
assert_not_contains "$(cat "$REPO/README.md")" "prints, offline," "the old README claim"
t_end

t_begin "the README says what a run with no terminal does, and the installer does exactly that"
readme_flat="$(flat "$(cat "$REPO/README.md")")"
assert_contains "$readme_flat" "With no terminal at all, the installer asks nothing. It adds only what a flag or \`CONDUCTOR_COMPONENTS\` names (a hook it adds is wired into your settings, and each one is printed) and keeps what its install record already holds. Effort pins are printed, not written, and no default model is set." "README"
assert_not_contains "$readme_flat" "it prints each change it would make to your settings and writes nothing" "the old claim"
fresh claude
CONDUCTOR_COMPONENTS=hook_pointer inst
assert_eq 0 "$RC" "install exit code"
assert_contains "$OUT" "wired the session-start pointer hook" "a hook it adds is printed"
assert_contains "$(cat "$CLAUDE_DIR/settings.json")" "session-start-pointer.py" "the hook is wired into settings.json"
assert_eq "" "$(pyj "$CLAUDE_DIR/settings.json" 'd.get("model", "")')" "no default model is set"
assert_not_contains "$(cat "$CLAUDE_DIR/settings.json")" "effortLevel" "effort pins are not written"
assert_contains "$OUT" "effort pins printed for you to apply" "effort pins are printed"
inst
assert_contains "$(cat "$CLAUDE_DIR/settings.json")" "session-start-pointer.py" "a re-run keeps what the record holds"
t_end

# =============================================================================
# settings.json and CLAUDE.md keep their form through install and uninstall
# =============================================================================
settings_style() { # STYLE: writes $CLAUDE_DIR/settings.json in that style, with a trailing line feed
  "$MY_PY" - "$CLAUDE_DIR/settings.json" "$1" << 'PYEOF'
import json, sys
d = {"theme": "dark", "permissions": {"allow": ["Bash(ls)"]}, "env": {"FOO": "bar"}}
style = sys.argv[2]
if style == "tab":
    text = json.dumps(d, indent="\t")
elif style == "2":
    text = json.dumps(d, indent=2)
elif style == "4":
    text = json.dumps(d, indent=4)
elif style == "line":
    text = json.dumps(d)
else:
    text = json.dumps(d, separators=(",", ":"))
open(sys.argv[1], "w").write(text + "\n")
PYEOF
}
style_ok() { # STYLE: 0 when $CLAUDE_DIR/settings.json is laid out in that style
  "$MY_PY" - "$CLAUDE_DIR/settings.json" "$1" << 'PYEOF'
import sys
text = open(sys.argv[1]).read()
lines = text.split("\n")
style = sys.argv[2]
second = lines[1] if len(lines) > 1 else ""
if style == "tab":
    ok = second.startswith('\t"') and not second.startswith('\t\t')
elif style == "2":
    ok = second.startswith('  "') and not second.startswith('   ')
elif style == "4":
    ok = second.startswith('    "') and not second.startswith('     ')
elif style == "line":
    ok = text.count("\n") == 1 and '": ' in text and ", " in text
else:
    ok = text.count("\n") == 1 and '": ' not in text and ", " not in text
sys.exit(0 if ok else 1)
PYEOF
}

t_begin "settings.json keeps the indentation of the file (tab, 2 spaces, 4 spaces, 1 line, 1 compact line) through an install and an uninstall, byte for byte"
for style in tab 2 4 line compact; do
  fresh claude
  settings_style "$style"
  cp "$CLAUDE_DIR/settings.json" "$SBX/settings.original"
  CONDUCTOR_COMPONENTS=hook_pointer inst
  assert_eq 0 "$RC" "install exit code [$style]"
  assert_contains "$(cat "$CLAUDE_DIR/settings.json")" "session-start-pointer.py" "the hook is wired [$style]"
  if style_ok "$style"; then :; else t_fail "settings.json is not laid out in the style [$style] after the install"; fi
  inst --uninstall
  assert_eq 0 "$RC" "uninstall exit code [$style]"
  assert_eq "$(cat "$SBX/settings.original")" "$(cat "$CLAUDE_DIR/settings.json")" "settings.json after install and uninstall [$style]"
done
t_end

t_begin "the characters U+2028 and U+2029 inside a value come out escaped, never raw, and the value is unchanged"
fresh claude
printf '{"theme": "a\342\200\250b\342\200\251c"}\n' > "$CLAUDE_DIR/settings.json"
CONDUCTOR_COMPONENTS=hook_pointer inst
assert_eq 0 "$RC" "install exit code"
"$MY_PY" - "$CLAUDE_DIR/settings.json" << 'PYEOF' || t_fail "the written settings.json holds a raw U+2028 or U+2029, or the value changed"
import json, sys
raw = open(sys.argv[1], "rb").read()
assert b"\xe2\x80\xa8" not in raw and b"\xe2\x80\xa9" not in raw, "raw separator"
assert b"\\u2028" in raw and b"\\u2029" in raw, "escapes missing"
assert json.loads(raw.decode("utf-8"))["theme"] == "a b c", "value changed"
PYEOF
t_end

t_begin "an event list you left empty stays through a wire, a re-run and an uninstall, and an event Conductor added goes"
fresh claude
printf '{\n  "theme": "dark",\n  "hooks": {\n    "PreToolUse": [],\n    "Stop": []\n  }\n}\n' > "$CLAUDE_DIR/settings.json"
cp "$CLAUDE_DIR/settings.json" "$SBX/settings.original"
CONDUCTOR_COMPONENTS=hook_contract inst
assert_eq 0 "$RC" "install exit code"
assert_contains "$(cat "$CLAUDE_DIR/settings.json")" "contract-check.py" "setup: the hook is wired into the empty PreToolUse list"
CONDUCTOR_COMPONENTS=hook_contract inst
assert_eq 0 "$RC" "re-run exit code"
assert_eq 1 "$(pyj "$CLAUDE_DIR/settings.json" 'len(d["hooks"]["PreToolUse"])')" "a re-run does not add a second group"
inst --uninstall
assert_eq 0 "$RC" "uninstall exit code"
assert_eq "$(cat "$SBX/settings.original")" "$(cat "$CLAUDE_DIR/settings.json")" "settings.json after install, re-run and uninstall (PreToolUse and Stop stay as empty lists, SubagentStop is gone)"
t_end

t_begin "CLAUDE.md and AGENTS.md keep their final line feed state through install and uninstall, and a file that existed before the install is never deleted, even an empty one"
for spec in "no-newline|user text, no final line feed" "newline|user text with a final line feed\n" "blank|user text then a blank line\n\n" "empty|"; do
  name="${spec%%|*}"
  content="${spec#*|}"
  fresh claude codex
  printf "$content" > "$CLAUDE_DIR/CLAUDE.md"
  printf "$content" > "$CODEX_DIR/AGENTS.md"
  cp "$CLAUDE_DIR/CLAUDE.md" "$SBX/claude.original"
  cp "$CODEX_DIR/AGENTS.md" "$SBX/agents.original"
  CONDUCTOR_YES=1 inst --core
  assert_eq 0 "$RC" "install exit code [$name]"
  assert_contains "$(cat "$CLAUDE_DIR/CLAUDE.md")" "BEGIN CONDUCTOR (managed)" "setup: the block is in CLAUDE.md [$name]"
  inst --uninstall
  assert_eq 0 "$RC" "uninstall exit code [$name]"
  assert_file "$CLAUDE_DIR/CLAUDE.md" "CLAUDE.md still exists [$name]"
  assert_file "$CODEX_DIR/AGENTS.md" "AGENTS.md still exists [$name]"
  if cmp -s "$SBX/claude.original" "$CLAUDE_DIR/CLAUDE.md"; then :; else t_fail "CLAUDE.md differs from the original after install and uninstall [$name]: $(od -c "$CLAUDE_DIR/CLAUDE.md" | head -3 | tr '\n' ' ')"; fi
  if cmp -s "$SBX/agents.original" "$CODEX_DIR/AGENTS.md"; then :; else t_fail "AGENTS.md differs from the original after install and uninstall [$name]"; fi
done
fresh claude codex
CONDUCTOR_YES=1 inst --core
assert_file "$CLAUDE_DIR/CLAUDE.md" "positive control: a CLAUDE.md the install created"
inst --uninstall
assert_no_file "$CLAUDE_DIR/CLAUDE.md" "a CLAUDE.md the install created goes with the uninstall"
assert_no_file "$CODEX_DIR/AGENTS.md" "an AGENTS.md the install created goes with the uninstall"
t_end

t_begin "the uninstall log says removed when it deletes a key and restored only when it puts an old value back"
fresh claude
PTY_INPUT=$'\ny\nopus\n' pty /bin/bash "$INST"
assert_eq "opus" "$(pyj "$CLAUDE_DIR/settings.json" 'd["model"]')" "setup: a default model was written into a file Conductor created"
inst --uninstall
assert_contains "$OUT" "removed setting model" "the key did not exist before: it is removed"
assert_not_contains "$OUT" "restored setting model" "nothing old was put back"
fresh claude
printf '{"model": "sonnet", "theme": "dark"}\n' > "$CLAUDE_DIR/settings.json"
PTY_INPUT=$'\ny\nopus\n' pty /bin/bash "$INST"
assert_eq "opus" "$(pyj "$CLAUDE_DIR/settings.json" 'd["model"]')" "setup: the default model was changed"
inst --uninstall
assert_contains "$OUT" "restored setting model" "an old value is put back: restored"
assert_not_contains "$OUT" "removed setting model" "the key was not deleted"
assert_eq "sonnet" "$(pyj "$CLAUDE_DIR/settings.json" 'd["model"]')" "the old value is back"
fresh claude
sandbox_fake_claude 2.1.296
mkdir -p "$CLAUDE_DIR/conductor"
printf '{"schema": 1, "product": "conductor", "files": [], "pins": [], "env_written": ["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "judge_rung": null}\n' > "$CLAUDE_DIR/conductor/.install-manifest"
printf '{"env": {"ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-haiku-5-5"}}\n' > "$CLAUDE_DIR/settings.json"
PTY_INPUT=$'\n\ny\n' pty /bin/bash "$INST" --core --judge-rung=3
assert_contains "$OUT" "removed env.ANTHROPIC_DEFAULT_HAIKU_MODEL" "a recorded env key that is deleted is called removed"
assert_not_contains "$OUT" "restored env.ANTHROPIC_DEFAULT_HAIKU_MODEL" "it was not restored"
t_end

# =============================================================================
# a re-run keeps what you set on Conductor's hook entries
# =============================================================================
mutate_settings() { # PYTHON-SNIPPET: runs it with d = settings.json parsed; writes it back with 2-space indent
  "$MY_PY" - "$CLAUDE_DIR/settings.json" "$1" << 'PYEOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
exec(sys.argv[2])
json.dump(d, open(p, "w"), indent=2)
PYEOF
}
hook_shape() { # a compact picture of the hooks: event, matcher, then each command's file name and timeout
  "$MY_PY" - "$CLAUDE_DIR/settings.json" << 'PYEOF'
import json, re, sys
d = json.load(open(sys.argv[1]))
for ev in sorted(d.get("hooks", {})):
    for g in d["hooks"][ev]:
        items = []
        for h in g["hooks"]:
            m = re.findall(r"/([A-Za-z0-9_.-]+\.py)", h["command"])
            items.append("%s:%s" % (m[-1] if m else h["command"], h.get("timeout")))
        print("%s|%s|%s" % (ev, g.get("matcher"), ",".join(items)))
PYEOF
}

t_begin "a re-run keeps a timeout you set on Conductor's hook entries, keeps each group where it is, and never splits your hook out of a group it shares with Conductor's"
fresh claude
CONDUCTOR_COMPONENTS=hook_pointer,hook_contract inst
assert_eq 0 "$RC" "install exit code"
mutate_settings '
h = d["hooks"]
for g in h["PreToolUse"]:
    for e in g["hooks"]:
        e["timeout"] = 99
h["PreToolUse"].insert(0, {"matcher": "Bash", "hooks": [{"type": "command", "command": "/usr/bin/true"}]})
h["PreToolUse"].append({"matcher": "Write", "hooks": [{"type": "command", "command": "/usr/bin/false"}]})
h["SessionStart"][0]["hooks"].append({"type": "command", "command": "/usr/bin/echo shared"})'
before="$(hook_shape)"
CONDUCTOR_COMPONENTS=hook_pointer,hook_contract inst
assert_eq 0 "$RC" "re-run exit code"
assert_eq "$before" "$(hook_shape)" "the hook layout after the re-run: timeouts, order and groups as they were"
assert_contains "$(hook_shape)" "PreToolUse|Agent|Task|contract-check.py:99" "the timeout of 99 is kept on Conductor's entry"
assert_contains "$(hook_shape)" "SessionStart||session-start-pointer.py:10,/usr/bin/echo shared:None" "your hook still shares the group with Conductor's"
assert_eq "PreToolUse|Bash|/usr/bin/true:None" "$(hook_shape | grep '^PreToolUse|Bash|')" "your group in front of Conductor's stays in front"
assert_eq 3 "$(pyj "$CLAUDE_DIR/settings.json" 'len(d["hooks"]["PreToolUse"])')" "3 PreToolUse groups"
assert_eq "Bash,Agent|Task,Write" "$(pyj "$CLAUDE_DIR/settings.json" '",".join(g["matcher"] for g in d["hooks"]["PreToolUse"])')" "group order"
assert_not_contains "$OUT" "refreshed" "a re-run that changes no entry does not claim to have refreshed any"
t_end

t_begin "a re-run that refreshes an entry says so in 1 line in the summary and still keeps the timeout, the place and the shared group"
fresh claude
CONDUCTOR_COMPONENTS=hook_pointer inst
assert_eq 0 "$RC" "install exit code"
assert_not_contains "$OUT" "Conductor's own hook entries were refreshed" "a first install refreshes nothing"
mutate_settings '
h = d["hooks"]
g = h["SessionStart"][0]
g["hooks"][0]["timeout"] = 77
import re
g["hooks"][0]["command"] = re.sub(r"^\[ ! -x \"[^\"]+\" \] \|\| ", "", g["hooks"][0]["command"])
g["hooks"].append({"type": "command", "command": "/usr/bin/echo shared"})
h["SessionStart"].insert(0, {"matcher": "startup", "hooks": [{"type": "command", "command": "/usr/bin/true"}]})'
assert_not_contains "$(cat "$CLAUDE_DIR/settings.json")" "[ ! -x" "setup: the entry is in the older guard form"
CONDUCTOR_COMPONENTS=hook_pointer inst
assert_eq 0 "$RC" "re-run exit code"
assert_contains "$(flat "$OUT")" "Hook entries: Conductor's own were refreshed; your timeouts, matchers and order stay" "the summary line"
assert_eq 1 "$(printf '%s\n' "$OUT" | grep -c 'were refreshed')" "said once"
assert_eq "" "$(printf '%s\n' "$OUT" | grep 'Hook entries:' | awk 'length($0) > 79')" "the line is under 80 columns"
assert_contains "$(cat "$CLAUDE_DIR/settings.json")" "[ ! -x" "the entry is back in the current form"
assert_eq "SessionStart|startup|/usr/bin/true:None
SessionStart||session-start-pointer.py:77,/usr/bin/echo shared:None" "$(hook_shape)" "your group stays in front, the timeout of 77 is kept, your hook stays in the shared group"
CONDUCTOR_COMPONENTS=hook_pointer inst
assert_not_contains "$OUT" "were refreshed" "the next re-run has nothing to refresh"
t_end

# =============================================================================
# agent types Claude Code runs on a model it chooses itself
# =============================================================================
t_begin "a dispatch of fork, claude-code-guide or statusline-setup needs no model pin in block mode, and any other unpinned type is still denied"
fresh claude
CONDUCTOR_COMPONENTS=hook_contract inst
assert_eq 0 "$RC" "install exit code"
printf 'hook_block_mode: on\n' > "$CLAUDE_DIR/conductor/defaults.md"
mkdir -p "$SBX/w"
for t in fork claude-code-guide statusline-setup Explore Plan general-purpose; do
  OUT="$("$MY_PY" -c '
import json, sys
print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Agent", "session_id": "s-f19", "cwd": sys.argv[1],
                  "transcript_path": sys.argv[1] + "/none.jsonl", "tool_input": {"prompt": "x", "subagent_type": sys.argv[2]}}))' "$SBX/w" "$t" \
    | "$MY_PY" -I -B "$CLAUDE_DIR/conductor/hooks/contract-check.py" 2> /dev/null)"
  case "$t" in
    fork|claude-code-guide|statusline-setup) assert_eq "" "$OUT" "$t is left alone" ;;
    *) assert_contains "$OUT" '"permissionDecision": "deny"' "$t is denied" ;;
  esac
done
t_end

# =============================================================================
# the site deploy workflow
# =============================================================================
t_begin "pages.yml pins the 3 actions to commit SHAs and checks out without keeping credentials"
pages="$(cat "$REPO/.github/workflows/pages.yml")"
assert_contains "$pages" "uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4" "checkout"
assert_contains "$pages" "uses: actions/upload-pages-artifact@56afc609e74202658d3ffba0e8f6dda462b719fa # v3" "upload-pages-artifact"
assert_contains "$pages" "uses: actions/deploy-pages@d6db90164ac5ed86f2b6aed7e0febac5b3c0c03e # v4" "deploy-pages"
assert_eq 3 "$(grep -c 'uses: ' "$REPO/.github/workflows/pages.yml" | tr -d ' ')" "3 actions"
assert_eq 0 "$(grep 'uses: ' "$REPO/.github/workflows/pages.yml" | grep -vcE '@[0-9a-f]{40} # v[0-9]+$' | tr -d ' ')" "an action not pinned to a 40 character commit"
assert_eq "        with:
          persist-credentials: false" "$(sed -n '/actions\/checkout@/,/^$/p' "$REPO/.github/workflows/pages.yml" | sed -n '2,3p')" "the checkout step's with block"
assert_eq 1 "$(grep -c 'persist-credentials' "$REPO/.github/workflows/pages.yml" | tr -d ' ')" "persist-credentials appears once"
t_end

t_summary
