#!/bin/bash
# tests/test-install-options.sh: the installer end to end, part 2 of 3 (REQ-INS-003, REQ-INS-005, REQ-INS-006, REQ-UPD-003, REQ-OPS-002.4).
#
# Every run happens in a sandbox (tests/lib/sandbox.sh): a fake HOME and the 3
# config roots under a fresh temp folder. No test reads or writes a real config
# folder. The installer runs with no terminal (sandbox_notty, stdin from
# /dev/null) unless a test types answers into a pseudo terminal (sandbox_pty).
# The 3 parts share tests/lib/install-common.sh and run at the same time.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/install-common.sh"

# ---------------------------------------------------------------- REQ-INS-003 optional items by name

describe_of() {
  "$MY_PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["components"][sys.argv[2]]["describe"])' "$REPO/payload/components.json" "$1"
}

t_begin "REQ-INS-003.1 an interactive full install asks 5 separate hook prompts with names and describe text; a no leaves the files unwritten and the entry unwired"
fresh claude
printf '{"theme": "dark"}\n' > "$CLAUDE_DIR/settings.json"
PTY_INPUT=$'y\nn\ny\nn\nn\nn\n' pty /bin/bash "$INST" --full
assert_eq 0 "$RC" "exit code"
assert_eq 5 "$(printf '%s\n' "$OUT" | grep -c 'Add the .* hook?')" "hook prompts"
for c in hook_pointer hook_nudge hook_usage_split hook_project_home hook_contract; do
  assert_contains "$OUT" "$(describe_of $c)" "describe text of $c"
done
assert_file "$CLAUDE_DIR/conductor/hooks/session-start-pointer.py" "yes: pointer"
assert_file "$CLAUDE_DIR/conductor/hooks/usage-split-check.py" "yes: usage split"
assert_no_file "$CLAUDE_DIR/conductor/hooks/checkpoint-nudge.py" "no: nudge"
assert_no_file "$CLAUDE_DIR/conductor/hooks/project-home-check.py" "no: project home"
assert_no_file "$CLAUDE_DIR/conductor/hooks/contract-check.py" "no: contract"
s="$CLAUDE_DIR/settings.json"
assert_eq "['SessionStart', 'Stop']" "$(pyj "$s" 'sorted(d["hooks"].keys())')" "only the accepted hooks are wired"
assert_eq "['hook_pointer', 'hook_usage_split']" "$(pyj "$CLAUDE_DIR/conductor/.install-manifest" 'sorted(h["id"] for h in d["hooks"])')" "manifest hook ids"
t_end

t_begin "REQ-UI-001.1 an interactive install prints the effort explanation, 6 lines or fewer, before the first pin prompt"
fresh claude
sandbox_fake_claude 2.1.296
PTY_INPUT=$'n\nn\nn\nn\nn\nn\nn\nn\nn\nn\n' pty /bin/bash "$INST"
assert_eq 0 "$RC" "exit code"
first="$(printf '%s\n' "$OUT" | grep -n 'start at medium effort' | head -n 1 | cut -d: -f1)"
last="$(printf '%s\n' "$OUT" | grep -n 'Each pin is written only with your yes' | head -n 1 | cut -d: -f1)"
prompt="$(printf '%s\n' "$OUT" | grep -n 'effort for this config?' | head -n 1 | cut -d: -f1)"
[ -n "$first" ] && [ -n "$last" ] && [ -n "$prompt" ] || t_fail "explanation or prompt line missing"
if [ -n "$first" ] && [ -n "$last" ] && [ -n "$prompt" ]; then
  assert_eq 1 "$([ "$last" -lt "$prompt" ] && echo 1 || echo 0)" "the explanation ends before the first pin prompt"
  assert_eq 1 "$([ $((last - first + 1)) -le 6 ] && echo 1 || echo 0)" "the explanation is 6 lines or fewer"
fi
assert_contains "$OUT" "Higher effort can use more of your plan's usage" "the usage caveat"
t_end

t_begin "REQ-INS-003.2 a fresh folder, CONDUCTOR_YES=1 and nothing named: only core is installed and 0 hooks are wired"
fresh claude
CONDUCTOR_YES=1 inst
assert_eq 0 "$RC" "exit code"
assert_eq "['core']" "$(pyj "$CLAUDE_DIR/conductor/.install-manifest" 'd["components"]')" "components"
assert_eq 0 "$(pyj "$CLAUDE_DIR/conductor/.install-manifest" 'len(d["hooks"])')" "hooks"
assert_no_file "$CLAUDE_DIR/settings.json" "settings.json was not created"
assert_no_file "$CLAUDE_DIR/conductor/hooks" "no hook files"
t_end

t_begin "REQ-INS-003.3 a record holding the full tier and 3 hooks, CONDUCTOR_YES=1 and nothing named: the same 3 hooks stay and 0 new ones are enabled"
fresh claude
CONDUCTOR_COMPONENTS=hook_pointer,hook_nudge,hook_usage_split inst
assert_eq 0 "$RC" "first run"
assert_eq "['core', 'full', 'hook_pointer', 'hook_nudge', 'hook_usage_split']" "$(pyj "$CLAUDE_DIR/conductor/.install-manifest" 'd["components"]')" "components after the first run"
before="$(sandbox_tree_sum "$HOME")"
CONDUCTOR_YES=1 inst
assert_eq 0 "$RC" "second run"
assert_eq "$before" "$(sandbox_tree_sum "$HOME")" "nothing changed, and nothing was added"
assert_eq "['SessionStart', 'Stop', 'UserPromptSubmit']" "$(pyj "$CLAUDE_DIR/settings.json" 'sorted(d["hooks"].keys())')" "events wired"
assert_no_file "$CLAUDE_DIR/conductor/hooks/project-home-check.py"
assert_no_file "$CLAUDE_DIR/conductor/hooks/contract-check.py"
t_end

t_begin "REQ-INS-003.4 no terminal and no flag: settings.json is not written (absent stays absent, present stays identical)"
fresh claude
inst
assert_no_file "$CLAUDE_DIR/settings.json" "absent stays absent"
printf '%s' "$user_settings" > "$CLAUDE_DIR/settings.json"
cp "$CLAUDE_DIR/settings.json" "$SBX/w/s.orig"
inst
assert_eq "$(sum_of "$SBX/w/s.orig")" "$(sum_of "$CLAUDE_DIR/settings.json")" "present stays identical"
assert_eq 0 "$(ls "$CLAUDE_DIR/conductor/backups" 2> /dev/null | grep -c '^settings.json' || true)" "no settings backup either"
t_end

t_begin "REQ-INS-003.5 the default-model offer: no answer writes no model key; a yes writes it and records the previous value"
fresh claude
PTY_INPUT=$'\n\n' pty /bin/bash "$INST"
assert_eq 0 "$RC" "exit code"
assert_contains "$OUT" "Set a default model in settings.json?" "the offer was made"
assert_no_file "$CLAUDE_DIR/settings.json" "nothing written on Enter"
fresh claude
printf '{"model": "sonnet", "theme": "dark"}\n' > "$CLAUDE_DIR/settings.json"
PTY_INPUT=$'\ny\nopus\n' pty /bin/bash "$INST"
assert_eq 0 "$RC" "exit code with a yes"
assert_eq "opus" "$(pyj "$CLAUDE_DIR/settings.json" 'd["model"]')" "model written after a yes"
assert_eq "sonnet" "$(pyj "$CLAUDE_DIR/conductor/.install-manifest" 'd["pins"][0]["previous"]')" "previous value recorded"
fresh claude
PTY_INPUT=$'\ny\na;b\nc;d\n' pty /bin/bash "$INST"
assert_no_file "$CLAUDE_DIR/settings.json" "a model name with a semicolon is refused"
assert_contains "$OUT" "not a model name"
t_end

t_begin "REQ-INS-006.6 a pin written after the user's yes is restored to its recorded previous value by uninstall"
fresh claude
printf '{"model": "sonnet", "theme": "dark"}\n' > "$CLAUDE_DIR/settings.json"
PTY_INPUT=$'\ny\nopus\n' pty /bin/bash "$INST"
assert_eq "opus" "$(pyj "$CLAUDE_DIR/settings.json" 'd["model"]')" "model after install"
inst --uninstall
assert_eq 0 "$RC" "uninstall exit code"
assert_eq "sonnet" "$(pyj "$CLAUDE_DIR/settings.json" 'd["model"]')" "model restored"
assert_eq "dark" "$(pyj "$CLAUDE_DIR/settings.json" 'd["theme"]')" "other keys kept"
fresh claude
PTY_INPUT=$'\ny\nopus\n' pty /bin/bash "$INST"
assert_eq "opus" "$(pyj "$CLAUDE_DIR/settings.json" 'd["model"]')" "model written into a file Conductor created"
inst --uninstall
assert_no_file "$CLAUDE_DIR/settings.json" "the file Conductor created is removed when nothing else is in it"
t_end

t_begin "REQ-INS-003.6 Enter at the prompt of an installed component and hook keeps it, and the install is byte-identical"
fresh claude
CONDUCTOR_COMPONENTS=hook_pointer inst
assert_eq 0 "$RC" "first run"
before="$(sandbox_tree_sum "$HOME")"
PTY_INPUT=$'\n\n\n\n\n\n\n' pty /bin/bash "$INST"
assert_eq 0 "$RC" "interactive re-run"
assert_contains "$OUT" "Keep the session-start pointer hook?" "the held hook is asked as a keep question"
assert_eq "$before" "$(sandbox_tree_sum "$HOME")" "home, manifest included, is unchanged"
t_end

t_begin "REQ-INS-003.7 typing no for an installed hook removes its files and entry and updates the manifest"
fresh claude
CONDUCTOR_COMPONENTS=hook_pointer,hook_usage_split inst
PTY_INPUT=$'y\nn\n\n\n\n\n\n' pty /bin/bash "$INST"
assert_eq 0 "$RC" "exit code"
assert_no_file "$CLAUDE_DIR/conductor/hooks/session-start-pointer.py" "the removed hook's file"
assert_file "$CLAUDE_DIR/conductor/hooks/usage-split-check.py" "the kept hook's file"
assert_eq "['Stop']" "$(pyj "$CLAUDE_DIR/settings.json" 'sorted(d["hooks"].keys())')" "settings entries"
m="$CLAUDE_DIR/conductor/.install-manifest"
assert_eq "['core', 'full', 'hook_usage_split']" "$(pyj "$m" 'd["components"]')" "components"
assert_eq "['hook_usage_split']" "$(pyj "$m" '[h["id"] for h in d["hooks"]]')" "hook records"
assert_eq 0 "$(pyj "$m" 'len([f for f in d["files"] if f["id"] == "hook_pointer"])')" "file records of the removed hook"
assert_eq 1 "$(pyj "$m" 'len([f for f in d["files"] if f["id"] == "hook_usage_split"])')" "file records of the kept hook"
t_end

t_begin "REQ-INS-003 a name that is not a component (a feedback channel, a typo) is a usage error, exit 2, before any write"
fresh claude codex
before="$(sandbox_tree_sum "$HOME")"
for name in feedback oracle core,feedback fulll; do
  CONDUCTOR_COMPONENTS=$name inst
  assert_eq 2 "$RC" "exit code for $name"
  assert_contains "$OUT" "not a component" "message for $name"
  assert_eq "$before" "$(sandbox_tree_sum "$HOME")" "nothing written for $name"
done
CONDUCTOR_YES=1 CONDUCTOR_COMPONENTS=feedback inst
assert_eq 2 "$RC" "CONDUCTOR_YES does not add a feedback channel"
t_end

t_begin "REQ-INS-003 --core asks nothing and keeps what the record holds; --full names the full tier"
fresh claude
CONDUCTOR_COMPONENTS=hook_pointer inst
before="$(sandbox_tree_sum "$HOME")"
PTY_INPUT=$'n\nn\nn\nn\nn\nn\nn\n' pty /bin/bash "$INST" --core
assert_eq 0 "$RC" "exit code"
assert_not_contains "$OUT" "Keep the" "no prompt"
assert_not_contains "$OUT" "Add the" "no prompt"
assert_eq "$before" "$(sandbox_tree_sum "$HOME")" "nothing changed"
fresh claude
CONDUCTOR_YES=1 inst --full
assert_eq "['core', 'full']" "$(pyj "$CLAUDE_DIR/conductor/.install-manifest" 'd["components"]')" "--full installs the full tier"
assert_eq 0 "$(pyj "$CLAUDE_DIR/conductor/.install-manifest" 'len(d["hooks"])')" "and no hook"
t_end

# ---------------------------------------------------------------- REQ-INS-005 keep what the user changed

t_begin "case 8 / REQ-INS-005.1 a user-modified builder.md is kept and named, with no terminal, with CONDUCTOR_YES=1, without --replace-modified"
fresh claude
inst
printf 'my own builder\n' > "$CLAUDE_DIR/agents/builder.md"
CONDUCTOR_YES=1 inst
assert_eq 0 "$RC" "exit code"
assert_eq "my own builder" "$(cat "$CLAUDE_DIR/agents/builder.md")" "kept"
assert_contains "$OUT" "kept agents/builder.md (you changed it)" "named at the file"
assert_contains "$OUT" "Kept as yours (not replaced):" "named in the summary"
assert_eq 1 "$(printf '%s\n' "$OUT" | grep -c '^      agents/builder.md$')" "listed once in the summary"
inst
assert_eq "my own builder" "$(cat "$CLAUDE_DIR/agents/builder.md")" "kept with no terminal and no flag"
t_end

t_begin "case 8 / REQ-INS-005.2 with --replace-modified the file is replaced, a backup exists and its path is printed"
inst --replace-modified
assert_eq 0 "$RC" "exit code"
assert_eq "$(sum_of "$REPO/payload/claude/agents/builder.md")" "$(sum_of "$CLAUDE_DIR/agents/builder.md")" "replaced"
bk="$(ls "$CLAUDE_DIR/conductor/backups" | grep '^agents__builder.md.bak' | head -1)"
assert_eq 1 "$([ -n "$bk" ] && echo 1 || echo 0)" "a backup exists"
assert_eq "my own builder" "$(cat "$CLAUDE_DIR/conductor/backups/$bk")" "the backup holds the user's file"
assert_contains "$OUT" "backup: $CLAUDE_DIR/conductor/backups/$bk" "the path is printed"
t_end

t_begin "REQ-INS-005 a terminal asks first: a yes replaces after a backup, Enter and no keep (default no)"
fresh claude
inst
printf 'mine v1\n' > "$CLAUDE_DIR/agents/scout.md"
PTY_INPUT=$'\n\n\n' pty /bin/bash "$INST"
assert_contains "$OUT" "agents/scout.md has changes of yours" "the question names the file"
assert_contains "$OUT" "Replace it with the new version?" "and asks"
assert_eq "mine v1" "$(cat "$CLAUDE_DIR/agents/scout.md")" "Enter keeps"
PTY_INPUT=$'\n\nn\n' pty /bin/bash "$INST"
assert_eq "mine v1" "$(cat "$CLAUDE_DIR/agents/scout.md")" "n keeps"
PTY_INPUT=$'\n\ny\n' pty /bin/bash "$INST"
assert_eq "$(sum_of "$REPO/payload/claude/agents/scout.md")" "$(sum_of "$CLAUDE_DIR/agents/scout.md")" "y replaces"
assert_eq "mine v1" "$(cat "$CLAUDE_DIR/conductor/backups/"agents__scout.md.bak.*)" "after a backup"
t_end

t_begin "case 7 / REQ-INS-005.3 a user-edited defaults.md survives an upgrade, and defaults.default.md holds the current payload"
fresh claude
inst
printf 'my defaults\n' > "$CLAUDE_DIR/conductor/defaults.md"
printf 'stale reference copy\n' > "$CLAUDE_DIR/conductor/defaults.default.md"
CONDUCTOR_YES=1 inst
assert_eq 0 "$RC" "exit code"
assert_eq "my defaults" "$(cat "$CLAUDE_DIR/conductor/defaults.md")" "defaults.md untouched"
assert_eq "$(sum_of "$REPO/payload/claude/conductor/defaults.md")" "$(sum_of "$CLAUDE_DIR/conductor/defaults.default.md")" "the reference copy is refreshed"
inst --replace-modified
assert_eq "my defaults" "$(cat "$CLAUDE_DIR/conductor/defaults.md")" "even --replace-modified never overwrites a create-only file"
t_end

# ---------------------------------------------------------------- REQ-INS-006 uninstall


t_begin "case 14 / REQ-INS-006.1 uninstall after a full install: settings.json back to the user's entries, block gone, user text intact, logs, state and reports named as kept"
fresh claude
printf '%s' "$user_settings" > "$CLAUDE_DIR/settings.json"
printf '%s' "$user_md" > "$CLAUDE_DIR/CLAUDE.md"
CONDUCTOR_COMPONENTS=$ALL5 inst
assert_eq 0 "$RC" "install exit code"
assert_eq 5 "$(pyj "$CLAUDE_DIR/conductor/.install-manifest" 'len(set(h["id"] for h in d["hooks"]))')" "all 5 hooks wired"
mkdir -p "$CLAUDE_DIR/conductor/logs" "$CLAUDE_DIR/conductor/state"
printf 'trace\n' > "$CLAUDE_DIR/conductor/logs/hook.log"
printf '{}\n' > "$CLAUDE_DIR/conductor/state/checkpoint-record.json"
printf 'report\n' > "$CLAUDE_DIR/conductor/report-20261012.txt"
printf 'a file of the user in a Conductor folder\n' > "$CLAUDE_DIR/conductor/runbooks/mine.md"
inst --uninstall
assert_eq 0 "$RC" "uninstall exit code"
assert_eq "$("$MY_PY" -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1]), sort_keys=True))' "$user_settings")" \
  "$("$MY_PY" -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), sort_keys=True))' "$CLAUDE_DIR/settings.json")" "settings.json holds only the user's entries"
assert_eq "['theme', 'permissions', 'hooks', 'env', 'model']" "$(pyj "$CLAUDE_DIR/settings.json" 'list(d.keys())')" "key order"
assert_eq "['SessionStart', 'PreToolUse', 'Stop']" "$(pyj "$CLAUDE_DIR/settings.json" 'list(d["hooks"].keys())')" "event order"
assert_eq "$(printf '%s' "$user_md" | shasum -a 256 | awk '{print $1}')" "$(sum_of "$CLAUDE_DIR/CLAUDE.md")" "CLAUDE.md is the original, byte for byte"
assert_contains "$OUT" "kept $CLAUDE_DIR/conductor/logs" "the logs folder is named as kept"
assert_contains "$OUT" "kept $CLAUDE_DIR/conductor/state" "the state folder is named as kept"
assert_file "$CLAUDE_DIR/conductor/state/checkpoint-record.json" "the state folder stays"
assert_contains "$OUT" "kept $CLAUDE_DIR/conductor/report-20261012.txt" "the report file is named as kept"
assert_file "$CLAUDE_DIR/conductor/logs/hook.log"
assert_file "$CLAUDE_DIR/conductor/report-20261012.txt"
assert_file "$CLAUDE_DIR/conductor/runbooks/mine.md" "a user file parked in a Conductor folder survives with its folder"
assert_no_file "$CLAUDE_DIR/conductor/.install-manifest"
assert_no_file "$CLAUDE_DIR/agents" "the emptied agents folder is gone"
assert_no_file "$CLAUDE_DIR/skills" "the emptied skills folder is gone"
assert_no_file "$CLAUDE_DIR/conductor/hooks" "the emptied hooks folder is gone"
t_end

t_begin "case 14 / REQ-INS-006 0 residue: after uninstall only the user's files, the create-only file, backups, logs and reports remain"
fresh claude codex
printf '%s' "$user_md" > "$CLAUDE_DIR/CLAUDE.md"
CONDUCTOR_COMPONENTS=$ALL5 inst
inst --uninstall
left="$(cd "$HOME" && find .claude .codex -type f -not -path '.claude/conductor/backups/*' -not -path '.codex/conductor/backups/*' | LC_ALL=C sort | tr '\n' ' ')"
assert_eq ".claude/CLAUDE.md .claude/conductor/defaults.md " "$left" "files left"
assert_eq "" "$(cd "$HOME" && find .claude .codex -type d -empty | grep -Ev '^\.(claude|codex)$|backups$' | tr '\n' ' ')" "empty folders left (other than the config roots)"
assert_no_file "$CODEX_DIR/conductor/.install-manifest"
t_end

t_begin "REQ-INS-006.2 a file the user changed after install is kept and named, and a create-only file remains and is named"
fresh claude
inst
printf 'edited\n' > "$CLAUDE_DIR/agents/critic.md"
printf 'my defaults\n' > "$CLAUDE_DIR/conductor/defaults.md"
inst --uninstall
assert_eq 0 "$RC" "exit code"
assert_eq "edited" "$(cat "$CLAUDE_DIR/agents/critic.md")" "kept"
assert_contains "$OUT" "kept agents/critic.md (you changed it)" "named"
assert_eq "my defaults" "$(cat "$CLAUDE_DIR/conductor/defaults.md")" "create-only file remains"
assert_contains "$OUT" "kept conductor/defaults.md" "create-only file named"
assert_no_file "$CLAUDE_DIR/agents/builder.md" "the untouched files are removed"
t_end

pin_fixture
PININST="$FX/install.sh"

t_begin "REQ-INS-006.3 a pin that existed before the install and that Conductor did not change is not removed"
fresh claude
printf '{"modelSettings": {"claude-opus-5-5": {"effortLevel": "high"}}, "theme": "dark"}\n' > "$CLAUDE_DIR/settings.json"
run /bin/bash "$PININST"
assert_eq 0 "$RC" "install (the stand-in writes the value that is already there)"
assert_eq 0 "$(pyj "$CLAUDE_DIR/conductor/.install-manifest" 'len(d["pins"])')" "no pin is recorded for a value Conductor did not change"
run /bin/bash "$PININST" --uninstall
assert_eq "high" "$(pyj "$CLAUDE_DIR/settings.json" 'd["modelSettings"]["claude-opus-5-5"]["effortLevel"]')" "the user's pin is still there"
t_end

t_begin "case 22 / REQ-INS-006.4 uninstall with no install says so and exits 0, in every folder state"
fresh
inst --uninstall
assert_eq 0 "$RC" "no folders"
assert_contains "$OUT" "No Conductor install found"
fresh claude codex
printf '%s' "$user_md" > "$CLAUDE_DIR/CLAUDE.md"
before="$(sandbox_tree_sum "$HOME")"
inst --uninstall
assert_eq 0 "$RC" "empty folders"
assert_contains "$OUT" "No Conductor install found"
assert_eq "$before" "$(sandbox_tree_sum "$HOME")" "nothing touched"
t_end

t_begin "REQ-INS-006.7 2 Claude folders sharing 1 Codex folder: the first uninstall keeps the Codex files and says so, the second removes them"
fresh codex
CA="$HOME/claude-a"
CB="$HOME/claude-b"
mkdir -p "$CA" "$CB"
CLAUDE_DIR="$CA" CLAUDE_CONFIG_DIR="$CA" inst
CLAUDE_DIR="$CB" CLAUDE_CONFIG_DIR="$CB" inst
assert_eq "['$CA', '$CB']" "$(pyj "$CODEX_DIR/conductor/.install-manifest" 'd["shared_with"]')" "both users recorded"
CLAUDE_DIR="$CA" CLAUDE_CONFIG_DIR="$CA" inst --uninstall
assert_eq 0 "$RC" "first uninstall"
assert_file "$CODEX_DIR/conductor/bin/conductor" "Codex files stay"
assert_contains "$OUT" "another install still uses them" "the summary says why"
assert_contains "$OUT" "$CB" "and names the other install"
assert_no_file "$CA/agents/builder.md" "the first Claude folder is cleaned"
assert_file "$CB/agents/builder.md" "the second Claude folder is untouched"
assert_eq "['$CB']" "$(pyj "$CODEX_DIR/conductor/.install-manifest" 'd["shared_with"]')" "only the second is left"
CLAUDE_DIR="$CB" CLAUDE_CONFIG_DIR="$CB" inst --uninstall
assert_eq 0 "$RC" "second uninstall"
assert_no_file "$CODEX_DIR/conductor/bin/conductor" "Codex files are removed by the last user"
assert_no_file "$CODEX_DIR/conductor/.install-manifest"
t_end

t_begin "REQ-INS-006.8 a record that lists a path outside the roots, a link, a changed file, a key outside the allowed set or a value outside its set: none is touched, each is named"
fresh claude
printf '{"permissions": {"allow": ["x"]}, "modelSettings": {"claude-opus-5-5": {"effortLevel": "max"}}, "theme": "dark"}\n' > "$CLAUDE_DIR/settings.json"
cp "$CLAUDE_DIR/settings.json" "$SBX/w/s.orig"
inst
printf 'outside 1\n' > "$HOME/outside1.txt"
printf 'outside 2\n' > "$HOME/outside2.txt"
mkdir -p "$SBX/w/linktarget"
cp "$CLAUDE_DIR/agents/scout.md" "$SBX/w/linktarget/scout.md"
rm "$CLAUDE_DIR/agents/scout.md"
ln -s "$SBX/w/linktarget/scout.md" "$CLAUDE_DIR/agents/scout.md"
printf 'changed\n' > "$CLAUDE_DIR/agents/critic.md"
"$MY_PY" - "$CLAUDE_DIR/conductor/.install-manifest" "$HOME" <<'PYEOF'
import hashlib, json, sys
p, home = sys.argv[1], sys.argv[2]
d = json.load(open(p))
sha = lambda path: hashlib.sha256(open(path, "rb").read()).hexdigest()
d["files"].append({"dest": "../outside1.txt", "sha256": sha(home + "/outside1.txt"), "policy": "replace", "component": "core", "id": "x1"})
d["files"].append({"dest": home + "/outside2.txt", "sha256": sha(home + "/outside2.txt"), "policy": "replace", "component": "core", "id": "x2"})
d["pins"].append({"key": "permissions.allow", "value": ["x"], "previous": None, "previous_present": False})
d["pins"].append({"key": "modelSettings.claude-opus-5-5.effortLevel", "value": "max", "previous": "low", "previous_present": True})
json.dump(d, open(p, "w"), indent=2)
PYEOF
inst --uninstall
assert_eq 0 "$RC" "exit code"
assert_eq "outside 1" "$(cat "$HOME/outside1.txt")" "path with .. untouched"
assert_eq "outside 2" "$(cat "$HOME/outside2.txt")" "absolute path untouched"
assert_contains "$OUT" "left alone: ../outside1.txt" "named: .. path"
assert_contains "$OUT" "left alone: $HOME/outside2.txt" "named: absolute path"
assert_eq 1 "$([ -L "$CLAUDE_DIR/agents/scout.md" ] && echo 1 || echo 0)" "the link was not removed"
assert_eq "$(sum_of "$REPO/payload/claude/agents/scout.md")" "$(sum_of "$SBX/w/linktarget/scout.md")" "the link target was not removed"
assert_contains "$OUT" "left alone: agents/scout.md (a symbolic link)" "named: link"
assert_eq "changed" "$(cat "$CLAUDE_DIR/agents/critic.md")" "changed file kept"
assert_contains "$OUT" "kept agents/critic.md (you changed it)" "named: changed file"
assert_eq "$("$MY_PY" -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), sort_keys=True))' "$SBX/w/s.orig")" \
  "$("$MY_PY" -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), sort_keys=True))' "$CLAUDE_DIR/settings.json")" "settings.json is unchanged"
assert_contains "$OUT" "left alone: setting permissions.allow" "named: key outside the allowed set"
assert_contains "$OUT" "left alone: setting modelSettings.claude-opus-5-5.effortLevel" "named: value outside its set"
t_end

t_begin "REQ-INS-006.9 uninstall offers to delete the backups, says they may hold secrets, and keeps them on a no or with no terminal"
fresh claude
printf '%s' "$user_settings" > "$CLAUDE_DIR/settings.json"
CONDUCTOR_COMPONENTS=hook_pointer inst
inst --uninstall
assert_contains "$OUT" "may contain secrets" "the warning"
assert_eq 1 "$([ -d "$CLAUDE_DIR/conductor/backups" ] && echo 1 || echo 0)" "kept with no terminal"
assert_contains "$OUT" "kept $CLAUDE_DIR/conductor/backups"
fresh claude
CONDUCTOR_COMPONENTS=hook_pointer inst
PTY_INPUT=$'n\n' pty /bin/bash "$INST" --uninstall
assert_contains "$OUT" "Delete that backups folder?" "the question"
assert_eq 1 "$([ -d "$CLAUDE_DIR/conductor/backups" ] && echo 1 || echo 0)" "kept on a no"
fresh claude
printf '%s' "$user_settings" > "$CLAUDE_DIR/settings.json"
CONDUCTOR_COMPONENTS=hook_pointer inst
PTY_INPUT=$'y\n' pty /bin/bash "$INST" --uninstall
assert_no_file "$CLAUDE_DIR/conductor/backups" "deleted on a yes"
t_end

t_begin "REQ-INS-006 uninstall of an install made with no python3 that changed settings.json refuses and changes nothing"
fresh claude
printf '%s' "$user_settings" > "$CLAUDE_DIR/settings.json"
CONDUCTOR_COMPONENTS=$HOOKS2 inst
before="$(sandbox_tree_sum "$HOME")"
sandbox_no_python
inst --uninstall
clear_fakes
assert_eq "!0" "$([ "$RC" != 0 ] && echo '!0' || echo 0)" "a non-zero exit"
assert_contains "$OUT" "python3 is needed to undo that"
assert_eq "$before" "$(sandbox_tree_sum "$HOME")" "nothing changed"
t_end

# ---------------------------------------------------------------- upgrade from 0.3.0


t_begin "case 9 / REQ-UPD-003.1 an upgrade over a 0.3.0 install replaces unmodified agents with no prompt, removes the old manifests, keeps 1 block with the new version"
old_install
assert_eq 0 "$RC" "the 0.3.0 install ran"
assert_file "$CLAUDE_DIR/skills/conductor/.install-manifest" "0.3.0 Claude manifest"
assert_file "$CODEX_DIR/.conductor-manifest" "0.3.0 Codex manifest"
assert_eq 1 "$(grep -c '^<!-- BEGIN CONDUCTOR (managed) v0.3.0' "$CLAUDE_DIR/CLAUDE.md")" "a single 0.3.0 block"
PTY_INPUT=$'\n\n\n\n\n\n\n\n' pty /bin/bash "$INST"
assert_eq 0 "$RC" "upgrade exit code (a terminal is present, nothing is typed beyond Enter)"
assert_not_contains "$OUT" "Replace it with" "no prompt for an unmodified old file"
assert_contains "$OUT" "an upgrade from 0.3.0"
for a in builder scout critic architect; do
  assert_eq "$(sum_of "$REPO/payload/claude/agents/$a.md")" "$(sum_of "$CLAUDE_DIR/agents/$a.md")" "agent $a replaced"
done
assert_no_file "$CLAUDE_DIR/skills/conductor/.install-manifest" "0.3.0 Claude manifest removed"
assert_no_file "$CODEX_DIR/.conductor-manifest" "0.3.0 Codex manifest removed"
assert_eq 1 "$(grep -c '^<!-- BEGIN CONDUCTOR (managed) v0.4.0' "$CLAUDE_DIR/CLAUDE.md")" "a single block with the new version"
assert_eq 0 "$(grep -c 'v0.3.0' "$CLAUDE_DIR/CLAUDE.md")" "no 0.3.0 marker is left"
assert_eq "user claude" "$(head -1 "$CLAUDE_DIR/CLAUDE.md")" "the user's text is first"
assert_file "$CLAUDE_DIR/conductor/.install-manifest"
listed="$("$MY_PY" -c 'import json,sys
d = json.load(open(sys.argv[1]))
for f in d["files"]:
    print(f["dest"])' "$CODEX_DIR/conductor/.install-manifest" | sort)"
ondisk="$( (cd "$CODEX_DIR" && find agents -type f; cd "$AGENTS_SKILLS_DIR" && find skills -type f) | sort)"
assert_eq "" "$(comm -13 <(printf '%s\n' "$listed") <(printf '%s\n' "$ondisk"))" "every Codex file on disk is in the new manifest (no orphan 0.3.0 file)"
t_end

t_begin "REQ-INS-005.4 an unmodified file whose hash is in the prior-release list is replaced with no prompt, and a backup is kept"
assert_eq 1 "$(ls "$CLAUDE_DIR/conductor/backups" | grep -c '^agents__builder.md.bak')" "backup of the old builder.md"
t_end

t_begin "REQ-UPD-002.8 an install over a record that lists files this release no longer ships removes an unmodified file with its entry, and keeps and names a file the user changed"
fresh claude
inst
assert_eq 0 "$RC" "first install"
printf 'retired a\n' > "$CLAUDE_DIR/agents/retired-a.md"
printf 'retired b\n' > "$CLAUDE_DIR/agents/retired-b.md"
sha_a="$(sum_of "$CLAUDE_DIR/agents/retired-a.md")"
sha_b="$(sum_of "$CLAUDE_DIR/agents/retired-b.md")"
"$MY_PY" - "$CLAUDE_DIR/conductor/.install-manifest" "$sha_a" "$sha_b" <<'PYEOF'
import json, sys
p, a, b = sys.argv[1:4]
d = json.load(open(p))
d["files"].append({"dest": "agents/retired-a.md", "sha256": a, "policy": "replace", "component": "core", "id": "retired_a"})
d["files"].append({"dest": "agents/retired-b.md", "sha256": b, "policy": "replace", "component": "core", "id": "retired_b"})
json.dump(d, open(p, "w"), indent=2)
PYEOF
printf 'retired b, edited by the user\n' > "$CLAUDE_DIR/agents/retired-b.md"
inst
assert_eq 0 "$RC" "second install"
assert_no_file "$CLAUDE_DIR/agents/retired-a.md" "the unmodified dropped file is removed"
assert_file "$CLAUDE_DIR/agents/retired-b.md" "the modified dropped file is kept"
assert_contains "$OUT" "retired-b.md" "the kept file is named"
assert_eq 0 "$(pyj "$CLAUDE_DIR/conductor/.install-manifest" 'len([f for f in d["files"] if f["dest"].startswith("agents/retired-")])')" "neither dropped file stays in the record"
assert_contains "$OUT" "1 removed" "the summary counts the removal"
t_end

t_begin "case 10 / REQ-UPD-003.2 a modified 0.3.0 agent is kept and named when the upgrade runs without CONDUCTOR_YES"
old_install
printf 'my builder from 0.3.0 days\n' > "$CLAUDE_DIR/agents/builder.md"
inst
assert_eq 0 "$RC" "exit code"
assert_eq "my builder from 0.3.0 days" "$(cat "$CLAUDE_DIR/agents/builder.md")" "kept"
assert_contains "$OUT" "kept agents/builder.md (you changed it)"
assert_eq 1 "$(printf '%s\n' "$OUT" | grep -c '^      agents/builder.md$')" "named in the summary"
assert_eq "$(sum_of "$REPO/payload/claude/agents/scout.md")" "$(sum_of "$CLAUDE_DIR/agents/scout.md")" "the others were upgraded"
t_end

t_begin "REQ-UPD-003.3 the 0.3.0 flags are carried into legacy_030, and uninstall names the model change as the 0.3.0 installer's and leaves it"
old_install
printf '{"model": "opus", "theme": "dark"}\n' > "$CLAUDE_DIR/settings.json"
printf 'SETTINGS_MODEL_SET:opus\n' >> "$CLAUDE_DIR/skills/conductor/.install-manifest"
CONDUCTOR_YES=1 inst
assert_eq 0 "$RC" "upgrade exit code"
m="$CLAUDE_DIR/conductor/.install-manifest"
assert_eq "opus" "$(pyj "$m" 'd["legacy_030"]["settings_model_set"]')" "model carried"
assert_eq "True" "$(pyj "$m" 'd["legacy_030"]["claude_md_patched"]')" "CLAUDE.md patch carried"
assert_eq "True" "$(pyj "$CODEX_DIR/conductor/.install-manifest" 'd["legacy_030"]["codex_agents_md_patched"]')" "AGENTS.md patch carried"
inst --uninstall
assert_eq 0 "$RC" "uninstall exit code"
assert_contains "$OUT" "the 0.3.0 install set your default model to 'opus'" "named as the 0.3.0 installer's"
assert_eq "opus" "$(pyj "$CLAUDE_DIR/settings.json" 'd["model"]')" "the model is left in place"
assert_eq "user claude" "$(cat "$CLAUDE_DIR/CLAUDE.md")" "the doctrine block is removed"
t_end

t_begin "case 15 / REQ-INS-006.5 uninstall of a 0.3.0 install removes its files and block under the limits of .8, and names what it leaves"
old_install
printf 'edited scout\n' > "$CLAUDE_DIR/agents/scout.md"
cp "$CLAUDE_DIR/agents/critic.md" "$SBX/w/critic-target.md"
rm "$CLAUDE_DIR/agents/critic.md"
ln -s "$SBX/w/critic-target.md" "$CLAUDE_DIR/agents/critic.md"
printf 'outside 030\n' > "$SBX/w/outside-030.txt"
printf '%s\n' "$SBX/w/outside-030.txt" "../escape.txt" "$CLAUDE_DIR/../escape2.txt" >> "$CLAUDE_DIR/skills/conductor/.install-manifest"
printf 'SETTINGS_MODEL_SET:opus\n' >> "$CLAUDE_DIR/skills/conductor/.install-manifest"
printf '{"model": "opus"}\n' > "$CLAUDE_DIR/settings.json"
printf 'escape\n' > "$HOME/escape.txt"
printf 'escape 2\n' > "$HOME/escape2.txt"
inst --uninstall
assert_eq 0 "$RC" "exit code"
assert_no_file "$CLAUDE_DIR/agents/builder.md" "builder removed"
assert_no_file "$CLAUDE_DIR/agents/architect.md" "architect removed"
assert_no_file "$CLAUDE_DIR/skills/conductor" "skill folder removed"
assert_no_file "$CODEX_DIR/agents" "Codex agents removed with their folder"
assert_no_file "$AGENTS_SKILLS_DIR/skills/conductor" "Codex skill removed"
assert_no_file "$CODEX_DIR/.conductor-manifest"
assert_eq "edited scout" "$(cat "$CLAUDE_DIR/agents/scout.md")" "the edited file is kept"
assert_contains "$OUT" "kept agents/scout.md (you changed it)"
assert_eq 1 "$([ -L "$CLAUDE_DIR/agents/critic.md" ] && echo 1 || echo 0)" "the link is kept"
assert_file "$SBX/w/critic-target.md" "the link target is kept"
assert_contains "$OUT" "left alone: agents/critic.md (a symbolic link)"
assert_eq "outside 030" "$(cat "$SBX/w/outside-030.txt")" "the path outside the roots is kept"
assert_contains "$OUT" "outside the Conductor folders"
assert_eq "escape" "$(cat "$HOME/escape.txt")" "a .. path is kept"
assert_eq "escape 2" "$(cat "$HOME/escape2.txt")" "a path that climbs out is kept"
assert_eq "user claude" "$(head -1 "$CLAUDE_DIR/CLAUDE.md")" "user text intact"
assert_eq 0 "$(grep -c 'BEGIN CONDUCTOR' "$CLAUDE_DIR/CLAUDE.md")" "block removed from CLAUDE.md"
assert_eq "user codex" "$(cat "$CODEX_DIR/AGENTS.md")" "AGENTS.md is the user's text again"
assert_contains "$OUT" "the 0.3.0 install set your default model to 'opus'"
assert_eq "opus" "$(pyj "$CLAUDE_DIR/settings.json" 'd["model"]')" "the model is left"
t_end

t_begin "case 15 a 0.3.0 install with no manifest is still removed by name, only where the file matches a released hash"
old_install
rm -f "$CLAUDE_DIR/skills/conductor/.install-manifest" "$CODEX_DIR/.conductor-manifest"
printf 'edited critic\n' > "$CLAUDE_DIR/agents/critic.md"
inst --uninstall
assert_eq 0 "$RC" "exit code"
assert_no_file "$CLAUDE_DIR/agents/builder.md"
assert_eq "edited critic" "$(cat "$CLAUDE_DIR/agents/critic.md")" "edited file kept"
assert_eq "user claude" "$(cat "$CLAUDE_DIR/CLAUDE.md" | head -1)"
t_end

t_begin "REQ-OPS-002.4 rollback: 0.3.0, then 0.4.0, then the steps of 12.5 give the file set of a fresh 0.3.0 install except the user's files"
old_install
# the 0.3.0 manifests hold the time of their run, so only their names are compared
fileset() {
  ( cd "$HOME" && find .claude .codex .agents -type f -not -path '*/conductor/*' -not -name '*.bak.*' 2> /dev/null | LC_ALL=C sort | while IFS= read -r p; do
      case "$p" in
        *manifest) printf '%s -\n' "$p" ;;
        *) printf '%s %s\n' "$p" "$(sum_of "$p")" ;;
      esac
    done )
}
fresh_030="$(fileset)"
CONDUCTOR_YES=1 inst
printf 'my defaults\n' > "$CLAUDE_DIR/conductor/defaults.md"
# 12.5 user install: run uninstall; restore edited files from backups; run the previous release's installer
inst --uninstall
assert_eq 0 "$RC" "step 1: uninstall"
CONDUCTOR_YES=1 NOCOLLECT=1 run /bin/bash "$OLD030"
assert_eq 0 "$RC" "step 3: the previous release's installer"
assert_eq "$fresh_030" "$(fileset)" "the file set matches a fresh 0.3.0 install"
assert_eq "my defaults" "$(cat "$CLAUDE_DIR/conductor/defaults.md")" "the file the user changed is still theirs"
assert_eq "conductor/backups conductor/defaults.md" "$(cd "$CLAUDE_DIR" && find conductor -maxdepth 1 -mindepth 1 | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')" "the Conductor folder holds only backups and the user's file"
t_end

part_output_scan 2

t_summary
