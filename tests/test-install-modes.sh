#!/bin/bash
# tests/test-install-modes.sh: the installer end to end, part 3 of 3 (REQ-INS-007, the hook, judge and Codex cases, no python3, REQ-NFR-001, REQ-UI-001).
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

# ---------------------------------------------------------------- REQ-INS-007 dry run and status

t_begin "case 13 / REQ-INS-007.1 --dry-run changes nothing in any state: a recursive listing with checksums is identical, and no backup, manifest or folder is created"
fresh claude codex
printf '%s' "$user_md" > "$CLAUDE_DIR/CLAUDE.md"
before="$(sandbox_tree_sum "$HOME")"
CONDUCTOR_COMPONENTS=hook_pointer inst --dry-run
assert_eq 0 "$RC" "fresh: exit code"
assert_contains "$OUT" "would write agents/builder.md"
assert_contains "$OUT" "would"
assert_eq "$before" "$(sandbox_tree_sum "$HOME")" "fresh"
assert_no_file "$CLAUDE_DIR/conductor" "no folder"
CONDUCTOR_COMPONENTS=hook_pointer inst
printf 'edited\n' > "$CLAUDE_DIR/agents/builder.md"
before="$(sandbox_tree_sum "$HOME")"
inst --dry-run --full
assert_eq 0 "$RC" "installed: exit code"
assert_eq "$before" "$(sandbox_tree_sum "$HOME")" "installed, with an edited file and --full"
inst --uninstall --dry-run
assert_eq 0 "$RC" "uninstall dry run: exit code"
assert_contains "$OUT" "would remove"
assert_eq "$before" "$(sandbox_tree_sum "$HOME")" "uninstall --dry-run"
old_install
before="$(sandbox_tree_sum "$HOME")"
inst --dry-run
assert_eq 0 "$RC" "0.3.0: exit code"
assert_contains "$OUT" "would replace"
assert_eq "$before" "$(sandbox_tree_sum "$HOME")" "over a 0.3.0 install"
inst --dry-run --uninstall
assert_eq "$before" "$(sandbox_tree_sum "$HOME")" "uninstall --dry-run over a 0.3.0 install"
PTY_INPUT=$'y\ny\ny\n' pty /bin/bash "$INST" --dry-run --full
assert_eq 0 "$RC" "a dry run on a terminal"
assert_not_contains "$OUT" "[n]:" "a dry run never prompts"
assert_eq "$before" "$(sandbox_tree_sum "$HOME")" "after a dry run on a terminal"
t_end

t_begin "case 22 / REQ-INS-007.2 --status prints version, method, components and wired hooks"
fresh claude codex
CONDUCTOR_COMPONENTS=hook_pointer,hook_nudge inst
inst --status
assert_eq 0 "$RC" "exit code"
assert_contains "$OUT" "Version:     0.4.0"
assert_contains "$OUT" "Method:      installer"
assert_contains "$(printf '%s' "$OUT" | tr '\n' ' ' | tr -s ' ')" "Components: core, full tier, session-start pointer hook, checkpoint nudge hook"
assert_contains "$(printf '%s' "$OUT" | tr '\n' ' ' | tr -s ' ')" "Hooks wired: checkpoint nudge hook, session-start pointer hook"
t_end

t_begin "case 22 / REQ-INS-007.3 --status with no install says so and exits 0; over a 0.3.0 install it says that"
fresh claude codex
inst --status
assert_eq 0 "$RC" "exit code"
assert_contains "$OUT" "No Conductor install found"
fresh
inst --status
assert_eq 0 "$RC" "no folders at all"
assert_contains "$OUT" "No Conductor install found"
old_install
inst --status
assert_eq 0 "$RC" "0.3.0 exit code"
assert_contains "$OUT" "Found a 0.3.0 install"
t_end

# ---------------------------------------------------------------- cases 3, 11 and 16

t_begin "case 3 hook files are installed 755, settings.json is created with the wired entries, and a second run does not duplicate them"
fresh claude
CONDUCTOR_COMPONENTS=$ALL5 inst
assert_eq 0 "$RC" "exit code"
for h in session-start-pointer checkpoint-nudge usage-split-check project-home-check contract-check; do
  assert_mode "$CLAUDE_DIR/conductor/hooks/$h.py" 755 "hook $h"
done
assert_mode "$CLAUDE_DIR/conductor/hooks/hooklib.py" 644 "the shared module"
s="$CLAUDE_DIR/settings.json"
assert_eq "['PreToolUse', 'SessionStart', 'Stop', 'SubagentStop', 'UserPromptSubmit']" "$(pyj "$s" 'sorted(d["hooks"].keys())')" "events"
assert_eq "Agent|Task" "$(pyj "$s" 'd["hooks"]["PreToolUse"][0]["matcher"]')" "the matcher of the contract hook"
assert_eq 2 "$(pyj "$s" 'len(d["hooks"]["SessionStart"][0]["hooks"]) if len(d["hooks"]["SessionStart"]) == 1 else -1')" "2 SessionStart hooks share 1 matcher group of ours"
total="$(pyj "$s" 'sum(len(g["hooks"]) for gs in d["hooks"].values() for g in gs)')"
assert_eq 6 "$total" "6 hook entries"
before="$(sandbox_tree_sum "$HOME")"
CONDUCTOR_COMPONENTS=$ALL5 inst
assert_eq "$before" "$(sandbox_tree_sum "$HOME")" "a second run changes nothing"
t_end

t_begin "case 11 judge rung refused: a judge seat other than 1 or 3 is refused with exit 2 and nothing is written"
fresh claude codex
before="$(sandbox_tree_sum "$HOME")"
for v in 2 0 13 opus haiku sonnet fable 'a;b' '' '1 ' ' 3'; do
  inst "--judge-rung=$v"
  assert_eq 2 "$RC" "exit code for [$v]"
  assert_contains "$OUT" "--judge-rung" "message for [$v]"
  assert_eq "$before" "$(sandbox_tree_sum "$HOME")" "nothing written for [$v]"
done
t_end

t_begin "case 11 judge rung: rung 1 writes the fable judge and records the rung once, rung 3 switches the same file to sonnet"
fresh claude
sandbox_fake_claude 2.1.296
inst --judge-rung=1
assert_eq 0 "$RC" "exit code, rung 1"
j="$CLAUDE_DIR/agents/judge.md"
assert_file "$j" "judge file"
assert_eq "fable" "$(sed -n 's/^model: *//p' "$j" | head -n 1)" "rung 1 model"
m="$CLAUDE_DIR/conductor/.install-manifest"
assert_eq 1 "$(pyj "$m" 'd["judge_rung"]')" "judge_rung recorded"
assert_eq 1 "$(pyj "$m" 'len([f for f in d["files"] if f["dest"] == "agents/judge.md"])')" "1 judge entry"
assert_contains "$OUT" "bash install.sh --judge-rung=3" "the hint names the other rung"
inst --judge-rung=3
assert_eq 0 "$RC" "exit code, rung 3"
assert_eq "sonnet" "$(sed -n 's/^model: *//p' "$j" | head -n 1)" "rung 3 model"
assert_eq 3 "$(pyj "$m" 'd["judge_rung"]')" "judge_rung changed"
assert_eq 1 "$(pyj "$m" 'len([f for f in d["files"] if f["dest"] == "agents/judge.md"])')" "still 1 judge entry"
assert_contains "$OUT" "bash install.sh --judge-rung=1" "the hint names the other rung"
t_end

CDXINST="$INST"

t_begin "case 16 Codex: the agents, the skill under the skills root and the AGENTS.md block install through the shared helpers, no hook is wired, and uninstall removes them"
fresh codex
printf 'codex user text\n' > "$CODEX_DIR/AGENTS.md"
run /bin/bash "$CDXINST"
assert_eq 0 "$RC" "exit code"
for a in builder scout critic architect; do assert_file "$CODEX_DIR/agents/$a.toml" "agent $a"; done
assert_file "$AGENTS_SKILLS_DIR/skills/conductor/SKILL.md" "skill under the skills root"
assert_eq 1 "$(grep -c '^<!-- BEGIN CONDUCTOR' "$CODEX_DIR/AGENTS.md")" "a single block"
assert_eq "codex user text" "$(head -1 "$CODEX_DIR/AGENTS.md")" "user text first"
assert_no_file "$CLAUDE_DIR" "no Claude folder"
assert_no_file "$CODEX_DIR/settings.json" "no settings.json for Codex"
cm="$CODEX_DIR/conductor/.install-manifest"
assert_eq "agents_skills" "$(pyj "$cm" '[f["root"] for f in d["files"] if f["dest"] == "skills/conductor/SKILL.md"][0]')" "the skills-root files carry their root"
if "$MY_PY" -c 'import tomllib' 2> /dev/null; then
  for a in builder scout critic architect; do
    assert_eq 0 "$("$MY_PY" -c 'import sys, tomllib; tomllib.load(open(sys.argv[1], "rb"))' "$CODEX_DIR/agents/$a.toml" > /dev/null 2>&1; echo $?)" "TOML parses ($a)"
  done
fi
before="$(sandbox_tree_sum "$HOME")"
run /bin/bash "$CDXINST"
assert_eq "$before" "$(sandbox_tree_sum "$HOME")" "a second run changes nothing"
run /bin/bash "$CDXINST" --uninstall
assert_eq 0 "$RC" "uninstall exit code"
assert_no_file "$CODEX_DIR/agents" "agents removed with their folder"
assert_no_file "$AGENTS_SKILLS_DIR/skills" "skills folder removed"
assert_eq "codex user text" "$(cat "$CODEX_DIR/AGENTS.md")" "AGENTS.md is the user's text again"
assert_no_file "$CODEX_DIR/conductor/.install-manifest"
t_end

t_begin "REQ-INS-006.7 2 Claude folders sharing 1 Codex folder, with Codex files in both the Codex folder and the skills root"
fresh codex
CA="$HOME/claude-a"
CB="$HOME/claude-b"
mkdir -p "$CA" "$CB"
CLAUDE_DIR="$CA" CLAUDE_CONFIG_DIR="$CA" run /bin/bash "$CDXINST"
CLAUDE_DIR="$CB" CLAUDE_CONFIG_DIR="$CB" run /bin/bash "$CDXINST"
CLAUDE_DIR="$CA" CLAUDE_CONFIG_DIR="$CA" run /bin/bash "$CDXINST" --uninstall
assert_file "$CODEX_DIR/agents/builder.toml" "Codex agents stay after the first uninstall"
assert_file "$AGENTS_SKILLS_DIR/skills/conductor/SKILL.md" "the skill stays too"
assert_contains "$OUT" "another install still uses them"
assert_eq 1 "$(grep -c '^<!-- BEGIN CONDUCTOR' "$CODEX_DIR/AGENTS.md")" "the AGENTS.md block stays"
CLAUDE_DIR="$CB" CLAUDE_CONFIG_DIR="$CB" run /bin/bash "$CDXINST" --uninstall
assert_no_file "$CODEX_DIR/agents/builder.toml" "gone after the last uninstall"
assert_no_file "$AGENTS_SKILLS_DIR/skills/conductor" "skill gone"
t_end

t_begin "REQ-INS-002.3 a Codex skill file kept in the skills folder and replaced on request is backed up in the Codex root under a short name"
fresh codex
run /bin/bash "$CDXINST"
printf 'my edit\n' >> "$AGENTS_SKILLS_DIR/skills/conductor/SKILL.md"
run /bin/bash "$CDXINST" --replace-modified
assert_eq 0 "$RC" "exit code"
assert_eq 1 "$(ls "$CODEX_DIR/conductor/backups" | grep -c '^agents__skills__conductor__SKILL.md.bak\.')" "1 backup with the short name"
assert_eq 0 "$(ls "$CODEX_DIR/conductor/backups" | awk 'length($0) > 80' | grep -c .)" "no backup name over 80 characters"
t_end

# ---------------------------------------------------------------- no python3: the record without it

t_begin "REQ-INS-004.7 / REQ-UPD-001 with no python3 the record is still written, a re-run changes nothing, and uninstall removes everything"
fresh claude codex
printf '%s' "$user_md" > "$CLAUDE_DIR/CLAUDE.md"
sandbox_no_python
inst
clear_fakes
assert_eq 0 "$RC" "install exit code"
m="$CLAUDE_DIR/conductor/.install-manifest"
assert_file "$m"
assert_eq "None" "$(pyj "$m" 'd["python3"]')" "python3 is recorded as null"
assert_eq "['core']" "$(pyj "$m" 'd["components"]')" "components"
assert_eq "True" "$(pyj "$m" 'd["doctrine_block"]')" "doctrine block recorded"
assert_eq "0.4.0" "$(pyj "$m" 'd["version"]')" "version"
bad=0
while IFS="$(printf '\t')" read -r dest sha; do
  [ "$(sum_of "$CLAUDE_DIR/$dest")" = "$sha" ] || bad=$((bad + 1))
done <<EOF
$("$MY_PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); [print(f["dest"]+"\t"+f["sha256"]) for f in d["files"]]' "$m")
EOF
assert_eq 0 "$bad" "entries whose hash differs from the file"
assert_eq 19 "$(pyj "$m" 'len(d["files"])')" "files listed"
before="$(sandbox_tree_sum "$HOME")"
sandbox_no_python
inst
clear_fakes
assert_eq "$before" "$(sandbox_tree_sum "$HOME")" "a re-run changes nothing"
sandbox_no_python
inst --uninstall
clear_fakes
assert_eq 0 "$RC" "uninstall exit code"
assert_eq "$(printf '%s' "$user_md" | shasum -a 256 | awk '{print $1}')" "$(sum_of "$CLAUDE_DIR/CLAUDE.md")" "CLAUDE.md is the original"
left="$(cd "$HOME" && find .claude .codex -type f -not -path '*/conductor/backups/*' | LC_ALL=C sort | tr '\n' ' ')"
assert_eq ".claude/CLAUDE.md .claude/conductor/defaults.md " "$left" "files left"
t_end

t_begin "REQ-INS-004.7 a record that holds hooks is left as it was by a run with no python3, which says so"
fresh claude
CONDUCTOR_COMPONENTS=$HOOKS2 inst
cp "$CLAUDE_DIR/conductor/.install-manifest" "$SBX/w/m.before"
cp "$CLAUDE_DIR/settings.json" "$SBX/w/s.before"
sandbox_no_python
inst
clear_fakes
assert_eq 0 "$RC" "exit code"
assert_eq "$(sum_of "$SBX/w/m.before")" "$(sum_of "$CLAUDE_DIR/conductor/.install-manifest")" "the record is as it was"
assert_eq "$(sum_of "$SBX/w/s.before")" "$(sum_of "$CLAUDE_DIR/settings.json")" "settings.json is as it was"
assert_contains "$OUT" "python3"
assert_file "$CLAUDE_DIR/conductor/hooks/session-start-pointer.py" "the hook files stay"
t_end

# ---------------------------------------------------------------- REQ-NFR-001

t_begin "REQ-NFR-001.3 on a system whose uname says MINGW the installer offers no hooks and says why"
fresh claude
sandbox_fake_uname MINGW64_NT-10.0
CONDUCTOR_COMPONENTS=hook_pointer inst
clear_fakes
assert_eq 0 "$RC" "exit code"
assert_contains "$OUT" "hooks are supported on macOS and Linux only"
assert_eq 0 "$(pyj "$CLAUDE_DIR/conductor/.install-manifest" 'len(d["hooks"])')" "no hook recorded"
assert_no_file "$CLAUDE_DIR/settings.json" "settings.json not written"
assert_no_file "$CLAUDE_DIR/conductor/hooks/session-start-pointer.py" "no hook file"
assert_file "$CLAUDE_DIR/agents/builder.md" "core files are installed"
for u in MSYS_NT-10.0 CYGWIN_NT-10.0; do
  fresh claude
  sandbox_fake_uname "$u"
  PTY_INPUT=$'y\ny\ny\ny\ny\ny\ny\n' pty /bin/bash "$INST" --full
  clear_fakes
  assert_not_contains "$OUT" "Add the" "no hook is offered on $u"
  assert_contains "$OUT" "macOS and Linux only" "message on $u"
done
t_end

t_begin "REQ-NFR-001.2 every Python file in the payload and the installer helpers is valid for python 3.9 (compiled with the 3.9 grammar)"
bad="$("$MY_PY" - "$REPO" <<'PYEOF'
import ast, os, sys
root = sys.argv[1]
bad = []
for base in ("payload", "installer/py", "tools"):
    for d, _, files in os.walk(os.path.join(root, base)):
        for f in files:
            if f.endswith(".py"):
                p = os.path.join(d, f)
                try:
                    ast.parse(open(p, encoding="utf-8").read(), p, feature_version=(3, 9))
                except SyntaxError as exc:
                    bad.append("%s: %s" % (p, exc))
print("\n".join(bad))
PYEOF
)"
assert_eq "" "$bad" "files that do not compile for 3.9"
t_end

# ---------------------------------------------------------------- REQ-UI-001

t_begin "REQ-UI-001.4 the summary lists version, components, files, backups, hooks, settings keys, judge rung, launcher, alias line, data paths, the nothing-collected line and the next step"
fresh claude codex
printf '%s' "$user_md" > "$CLAUDE_DIR/CLAUDE.md"
CONDUCTOR_COMPONENTS=hook_nudge inst
for needle in "Version:       0.4.0" "Components:    core, full tier, checkpoint nudge hook" "Files:" "written" "unchanged" "replaced" "Backups:" "Hooks wired:   checkpoint nudge hook" \
  "Settings keys:" "Judge seat:" "Launcher:      $CLAUDE_DIR/conductor/bin/conductor" "alias conductor=" "wrote nothing there" \
  "Local files that can hold your data" "$CLAUDE_DIR/conductor/backups" "$CLAUDE_DIR/conductor/logs" "$CLAUDE_DIR/conductor/report-*.txt" \
  "$CODEX_DIR/conductor/backups" "Nothing is collected or sent" "conductor report" "Next:"; do
  assert_contains "$OUT" "$needle"
done
alias_line="$(printf '%s\n' "$OUT" | grep '^      alias conductor=' | head -1)"
target="${alias_line#*alias conductor=}"
assert_eq 1 "$([ -x "$(eval "printf '%s' $target")" ] && echo 1 || echo 0)" "the alias points at an executable launcher"
for f in .bashrc .zshrc .profile .bash_profile .zprofile .zshenv .config; do assert_no_file "$HOME/$f" "no shell profile written ($f)"; done
assert_contains "$OUT" "CONDUCTOR_WINDOW" "the window line when the nudge hook is wired and the value is unset"
CONDUCTOR_WINDOW=200000 CONDUCTOR_COMPONENTS=hook_nudge inst
assert_not_contains "$OUT" "CONDUCTOR_WINDOW" "no window line when the value is set"
fresh claude
CONDUCTOR_COMPONENTS=hook_pointer inst
assert_not_contains "$OUT" "CONDUCTOR_WINDOW" "no window line when the nudge hook is not wired"
t_end

t_begin "REQ-UI-001.5 no prompt asks for something the installer could read from the system"
prompts="$(cd "$REPO/installer/src" && grep -h 'ask_yn \|ask_str \|ask_secret ' 00-header.sh 10-detect.sh 30-files.sh 35-settings.sh 40-components.sh 80-uninstall.sh 90-summary.sh 99-main.sh | grep -v '^[a-z_]*() \|^#\|local q=' | sed 's/^ *//')"
assert_eq 6 "$(printf '%s\n' "$prompts" | grep -c .)" "prompts written by the installer core: $(printf '%s' "$prompts" | tr '\n' '|')"
assert_eq 1 "$(printf '%s\n' "$prompts" | grep -c 'ask_str')" "the only free-text prompt is the model name"
assert_eq 0 "$(printf '%s\n' "$prompts" | grep -ciE 'which folder|your path|python|operating system|which shell|terminal|your home' || true)" "none asks about the system"
t_end

t_begin "REQ-UI-001.2 no escape sequence in any output when NO_COLOR is set or output is not a terminal; colours do appear on a terminal without NO_COLOR"
assert_eq 0 "$(LC_ALL=C grep -c "$(printf '\033')" "$SBX/keep/run-output.txt" || true)" "escapes in $(wc -l < "$SBX/keep/run-output.txt" | tr -d ' ') lines of piped output"
assert_eq 0 "$(LC_ALL=C grep -c "$(printf '\033')" "$SBX/keep/pty-output.txt" || true)" "escapes in $(wc -l < "$SBX/keep/pty-output.txt" | tr -d ' ') lines of NO_COLOR terminal output"
fresh claude
out="$(sandbox_pty env TERM=xterm /bin/bash "$INST" --status)"
assert_eq 1 "$(printf '%s' "$out" | LC_ALL=C grep -c "$(printf '\033')" | awk '{print ($1 > 0) ? 1 : 0}')" "positive control: escapes on a terminal without NO_COLOR"
out="$(sandbox_pty env TERM=xterm NO_COLOR=1 /bin/bash "$INST" --status)"
assert_eq 0 "$(printf '%s' "$out" | LC_ALL=C grep -c "$(printf '\033')" || true)" "NO_COLOR on a terminal"
out="$(sandbox_pty env TERM=dumb /bin/bash "$INST" --status)"
assert_eq 0 "$(printf '%s' "$out" | LC_ALL=C grep -c "$(printf '\033')" || true)" "TERM=dumb on a terminal"
inst --help
assert_eq 0 "$(printf '%s' "$OUT" | LC_ALL=C grep -c "$(printf '\033')" || true)" "--help piped"
t_end

t_begin "REQ-UI-001.3 no line of fixed text in any output of part 3 of the install suite is longer than 80 characters"
cat "$SBX/keep/run-output.txt" "$SBX/keep/pty-output.txt" > "$SBX/keep/all-output.txt"
inst --help
printf '%s\n' "$OUT" >> "$SBX/keep/all-output.txt"
long="$(long_lines "$SBX/keep/all-output.txt")"
assert_eq "" "$long" "lines over 80 characters once paths are taken out"
assert_eq 1 "$([ "$(wc -l < "$SBX/keep/all-output.txt" | tr -d ' ')" -gt 2000 ] && echo 1 || echo 0)" "the check covered more than 2000 lines of output"
t_end

t_begin "REQ-UI-001.6 control characters are stripped from text taken from a file, C0 and C1 alike, keeping newline, tab and other UTF-8"
printf 'a\033[31mred\033[0m\rb\007c\302\205d\302\237e\303\251\342\200\246\t\nf\001\002\177g\n' > "$SBX/w/in.bin"
( . "$LIB"; sanitize_text < "$SBX/w/in.bin" ) > "$SBX/w/out.bin"
printf 'a[31mred[0mbcde\303\251\342\200\246\t\nfg\n' > "$SBX/w/want.bin"
assert_eq "$(sum_of "$SBX/w/want.bin")" "$(sum_of "$SBX/w/out.bin")" "sanitize_text output"
"$MY_PY" -c '
import sys
sys.stdout.buffer.write(bytes(i for i in range(256) if i not in (10,)))
' > "$SBX/w/all.bin"
( . "$LIB"; LC_ALL=C sanitize_text < "$SBX/w/all.bin" ) > "$SBX/w/all.out"
assert_eq 0 "$("$MY_PY" -c '
import sys
data = open(sys.argv[1], "rb").read()
bad = [b for b in data if (b < 32 and b not in (9, 10)) or b == 127]
print(len(bad))' "$SBX/w/all.out")" "no C0 control (except tab and newline) or DEL survives any single byte"
fresh claude
inst
"$MY_PY" - "$CLAUDE_DIR/conductor/.install-manifest" <<'PYEOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["files"].append({"dest": "agents/\x1b[31mevil\x07.md", "sha256": "0" * 64, "policy": "replace", "component": "core", "id": "x"})
json.dump(d, open(p, "w"), indent=2)
PYEOF
inst --uninstall
assert_eq 0 "$(printf '%s' "$OUT" | LC_ALL=C grep -c "$(printf '\033')" || true)" "a name with an escape in the record never reaches the screen raw"
assert_contains "$OUT" "[31mevil.md" "the cleaned name is shown"
t_end

t_summary
