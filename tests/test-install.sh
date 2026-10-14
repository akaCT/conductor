#!/bin/bash
# tests/test-install.sh: the installer end to end, part 1 of 3 (REQ-OPS-002.2, REQ-INS-002, REQ-INS-001, REQ-INS-004, the python3 gate).
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

# ---------------------------------------------------------------- REQ-OPS-002.2 the guard

t_begin "REQ-OPS-002.2 the install suite aborts when HOME is outside its temp root, before any installer runs"
out="$(HOME=/tmp/not-the-sandbox /bin/bash -c ". '$HERE/lib/sandbox.sh'; SBX='$SBX'; CLAUDE_DIR='$SBX/c'; CLAUDE_CONFIG_DIR='$SBX/c'; CODEX_DIR='$SBX/x'; CODEX_HOME='$SBX/x'; AGENTS_SKILLS_DIR='$SBX/a'; sandbox_guard; echo SURVIVED" 2>&1)"
assert_not_contains "$out" "SURVIVED"
assert_contains "$out" "HOME="
out="$(CLAUDE_DIR=/tmp/not-the-sandbox/.claude /bin/bash -c ". '$HERE/lib/assert.sh'; . '$HERE/lib/sandbox.sh'; SBX='$SBX'; HOME='$SBX/home'; CLAUDE_CONFIG_DIR='$SBX/c'; CODEX_DIR='$SBX/x'; CODEX_HOME='$SBX/x'; AGENTS_SKILLS_DIR='$SBX/a'; SBX_PY='$MY_PY'; run() { sandbox_guard; echo RAN; }; run" 2>&1)"
assert_not_contains "$out" "RAN"
assert_contains "$out" "CLAUDE_DIR="
t_end

# ---------------------------------------------------------------- case 1 fresh install

fresh claude codex
printf '%s' "$user_md" > "$CLAUDE_DIR/CLAUDE.md"
outside_before="$(outside_sum)"
inst
fresh_out="$OUT"
fresh_rc="$RC"

t_begin "case 1 / REQ-INS-002.1 a fresh core install writes every core file with the payload bytes and mode"
assert_eq 0 "$fresh_rc" "exit code"
n=0
while IFS="$(printf '\t')" read -r dest src mode policy; do
  n=$((n + 1))
  assert_file "$CLAUDE_DIR/$dest" "core file $dest"
  assert_eq "$(sum_of "$REPO/payload/$src")" "$(sum_of "$CLAUDE_DIR/$dest" 2>/dev/null)" "bytes of $dest"
  assert_mode "$CLAUDE_DIR/$dest" "$mode" "mode of $dest"
done <<EOF
$(core_list)
EOF
assert_eq 1 "$([ "$n" -ge 17 ] && echo 1 || echo 0)" "at least 17 core files were checked (got $n)"
assert_file "$CLAUDE_DIR/conductor/bin/conductor"
assert_file "$CLAUDE_DIR/conductor/.install-manifest"
assert_file "$CLAUDE_DIR/conductor/defaults.default.md"
assert_file "$CLAUDE_DIR/agents/builder.md"
assert_file "$CLAUDE_DIR/agents/scout.md"
assert_file "$CLAUDE_DIR/agents/critic.md"
assert_file "$CLAUDE_DIR/agents/architect.md"
assert_file "$CLAUDE_DIR/skills/conductor/SKILL.md"
assert_file "$CLAUDE_DIR/conductor/model-notes.md"
assert_file "$CLAUDE_DIR/conductor/templates/review-ladder.workflow.js"
t_end

t_begin "REQ-INS-002.1 the manifest lists each file with its sha256, and holds the doctrine block"
m="$CLAUDE_DIR/conductor/.install-manifest"
assert_eq 1 "$(pyj "$m" 'd["schema"]')" "schema"
assert_eq "conductor" "$(pyj "$m" 'd["product"]')" "product"
bad=0
while IFS="$(printf '\t')" read -r dest sha; do
  [ "$(sum_of "$CLAUDE_DIR/$dest")" = "$sha" ] || bad=$((bad + 1))
done <<EOF
$("$MY_PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); [print(f["dest"]+"\t"+f["sha256"]) for f in d["files"]]' "$m")
EOF
assert_eq 0 "$bad" "manifest entries whose sha256 differs from the file"
assert_eq "True" "$(pyj "$m" 'd["doctrine_block"]')" "doctrine_block"
assert_eq 0 "$(pyj "$m" 'len(d["hooks"])')" "no hooks"
assert_eq 1 "$(pyj "$m" 'len([f for f in d["files"] if f["dest"] == "conductor/bin/conductor"])')" "launcher is listed"
t_end

t_begin "REQ-UPD-001.1 the manifest holds method, version, source URL, install and update time, components, launcher, python3 and hashes"
assert_eq "installer" "$(pyj "$m" 'd["method"]')" "method"
assert_eq "0.4.0" "$(pyj "$m" 'd["version"]')" "version"
assert_contains "$(pyj "$m" 'd["source_url"]')" "https://" "source url"
assert_contains "$(pyj "$m" 'd["installed_at"]')" "T" "install time"
assert_contains "$(pyj "$m" 'd["updated_at"]')" "T" "update time"
assert_eq "['core']" "$(pyj "$m" 'd["components"]')" "components"
assert_eq "conductor/bin/conductor" "$(pyj "$m" 'd["launcher"]')" "launcher"
case "$(pyj "$m" 'd["python3"]')" in /*python3*) ok_py=1 ;; *) ok_py=0 ;; esac
assert_eq 1 "$ok_py" "absolute python3 path"
assert_eq "False" "$(pyj "$m" 'd["hooks_wired"]')" "hooks_wired"
t_end

t_begin "REQ-UPD-001.2 an install over an older record changes version, update time and installer sha256, and keeps the install time"
sha_a="$(printf 'a%.0s' $(seq 1 64))"
sha_b="$(printf 'b%.0s' $(seq 1 64))"
"$MY_PY" - "$m" "$sha_a" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["version"] = "0.3.9"
d["installed_at"] = "2020-01-01T00:00:00Z"
d["updated_at"] = "2020-01-01T00:00:00Z"
d["installer_sha256"] = sys.argv[2]
open(sys.argv[1], "w").write(json.dumps(d, indent=1) + "\n")
PYEOF
CONDUCTOR_YES=1 CONDUCTOR_INSTALLER_SHA256="$sha_b" inst
assert_eq 0 "$RC" "exit code ($OUT)"
assert_eq "0.4.0" "$(pyj "$m" 'd["version"]')" "version moved"
assert_eq "$sha_b" "$(pyj "$m" 'd["installer_sha256"]')" "installer sha256 moved"
assert_eq "2020-01-01T00:00:00Z" "$(pyj "$m" 'd["installed_at"]')" "install time kept"
assert_eq "True" "$(pyj "$m" 'd["updated_at"] != "2020-01-01T00:00:00Z"')" "update time moved"
t_end

t_begin "case 1 / REQ-INS-002.3 the doctrine block is there once, user text is intact, the Conductor folder line is right"
claude_md="$(cat "$CLAUDE_DIR/CLAUDE.md")"
assert_eq 1 "$(grep -c '^<!-- BEGIN CONDUCTOR (managed) v0.4.0 ' "$CLAUDE_DIR/CLAUDE.md")" "begin markers"
assert_eq 1 "$(grep -c '^<!-- END CONDUCTOR (managed) -->' "$CLAUDE_DIR/CLAUDE.md")" "end markers"
assert_contains "$claude_md" "Conductor folder: $CLAUDE_DIR/conductor"
line_end="$(grep -n '^<!-- END CONDUCTOR' "$CLAUDE_DIR/CLAUDE.md" | cut -d: -f1)"
line_cf="$(grep -n '^Conductor folder: ' "$CLAUDE_DIR/CLAUDE.md" | cut -d: -f1)"
assert_eq 1 "$([ "$line_cf" -lt "$line_end" ] && [ "$line_cf" -eq $((line_end - 1)) ] && echo 1 || echo 0)" "folder line sits just before the end marker"
# every byte before the block is the user's original text, then 1 blank line
printf '%s' "$user_md" > "$SBX/w/orig.md"
orig_bytes="$(wc -c < "$SBX/w/orig.md" | tr -d ' ')"
head -c "$orig_bytes" "$CLAUDE_DIR/CLAUDE.md" > "$SBX/w/head.md"
assert_eq "$(sum_of "$SBX/w/orig.md")" "$(sum_of "$SBX/w/head.md")" "the first bytes are the original text"
assert_eq "" "$(sed -n "$((1 + $(wc -l < "$SBX/w/orig.md" | tr -d ' ')))p" "$CLAUDE_DIR/CLAUDE.md")" "1 blank line separates the block"
t_end

t_begin "REQ-INS-002.3 a copy of the original CLAUDE.md is in {root}/conductor/backups (mode 700), none beside it"
bak="$(ls "$CLAUDE_DIR/conductor/backups/" | grep '^CLAUDE.md.bak\.' | head -1)"
assert_eq 1 "$([ -n "$bak" ] && echo 1 || echo 0)" "a backup of CLAUDE.md exists"
assert_eq "$(printf '%s' "$user_md" | wc -c | tr -d ' ')" "$(wc -c < "$CLAUDE_DIR/conductor/backups/$bak" | tr -d ' ')" "backup size is the original size"
assert_eq "$(sum_of "$SBX/w/orig.md")" "$(sum_of "$CLAUDE_DIR/conductor/backups/$bak")" "backup bytes"
assert_mode "$CLAUDE_DIR/conductor/backups" 700
assert_eq 0 "$(ls -A "$CLAUDE_DIR" | grep -c '\.bak' || true)" "no backup beside CLAUDE.md"
assert_eq 0 "$(find "$CLAUDE_DIR" -name '*.bak.*' -not -path "$CLAUDE_DIR/conductor/backups/*" | wc -l | tr -d ' ')" "no backup anywhere else"
t_end

t_begin "REQ-INS-002.4 0 files are created outside the 3 config roots, and no program is written on the PATH"
assert_eq "$outside_before" "$(outside_sum)" "files outside the roots"
assert_eq 0 "$(ls -A "$SBX/bin" | wc -l | tr -d ' ')" "nothing in the PATH folder"
assert_eq ".agents .claude .codex" "$(ls -A "$HOME" | tr '\n' ' ' | sed 's/ $//')" "home holds only the 3 config roots"
for f in .bashrc .zshrc .profile .bash_profile .zprofile .zshenv; do assert_no_file "$HOME/$f" "shell profile $f"; done
t_end

t_begin "case 1 the Codex root gets its own manifest and launcher"
assert_file "$CODEX_DIR/conductor/.install-manifest"
assert_file "$CODEX_DIR/conductor/bin/conductor"
assert_eq "codex" "$(pyj "$CODEX_DIR/conductor/.install-manifest" 'd["harness"]')" "harness"
assert_eq "['$CLAUDE_DIR']" "$(pyj "$CODEX_DIR/conductor/.install-manifest" 'd["shared_with"]')" "shared_with names the Claude root"
t_end

t_begin "REQ-UPD-001.3 no value in the manifest matches a secret shape (canary)"
fresh claude codex
mkdir -p "$CLAUDE_DIR"
printf '{"env": {"ANTHROPIC_API_KEY": "sk-ant-CANARY-0123456789abcdefghij", "GITHUB_TOKEN": "ghp_CANARY0123456789abcdefghijklmnop"}, "apiKeyHelper": "echo hunter2-CANARY"}\n' > "$CLAUDE_DIR/settings.json"
ANTHROPIC_API_KEY=sk-ant-CANARY-ENV-0123456789abcdef CONDUCTOR_COMPONENTS=hook_pointer inst
assert_eq 0 "$RC" "exit code"
all="$(cat "$CLAUDE_DIR/conductor/.install-manifest" "$CODEX_DIR/conductor/.install-manifest")"
for needle in CANARY hunter2 sk-ant ghp_ AKIA BEGIN\ PRIVATE; do assert_not_contains "$all" "$needle" "manifest holds $needle"; done
assert_eq 0 "$(printf '%s' "$all" | grep -cE 'sk-[A-Za-z0-9_-]{16,}|ghp_[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{12,}' || true)" "secret-shaped values"
assert_not_contains "$OUT" "CANARY" "installer output"
t_end

# ---------------------------------------------------------------- case 2 idempotent re-run

fresh claude codex
printf '%s' "$user_md" > "$CLAUDE_DIR/CLAUDE.md"
inst
before="$(sandbox_tree_sum "$HOME")"
inst
after="$(sandbox_tree_sum "$HOME")"

t_begin "case 2 / REQ-INS-002.2 a second run changes 0 files, makes 0 backups and keeps 1 doctrine block"
assert_eq 0 "$RC" "exit code"
assert_eq "$before" "$after" "the whole home, manifests included"
assert_eq 1 "$(grep -c '^<!-- BEGIN CONDUCTOR' "$CLAUDE_DIR/CLAUDE.md")" "doctrine blocks"
assert_eq 1 "$(ls "$CLAUDE_DIR/conductor/backups" | wc -l | tr -d ' ')" "backups"
assert_contains "$OUT" "0 written, 30 unchanged, 0 replaced" "summary counts"
t_end

# ---------------------------------------------------------------- REQ-INS-002.5 malformed markers

t_begin "REQ-INS-002.5 a CLAUDE.md with malformed markers is backed up, left unedited, and a warning is printed"
for kind in "begin-only" "2-begins" "end-first"; do
  fresh claude
  case "$kind" in
    begin-only) printf 'before\n<!-- BEGIN CONDUCTOR (managed) v0.3.0 - https://x -->\nold text\nafter\n' > "$CLAUDE_DIR/CLAUDE.md" ;;
    2-begins) printf '<!-- BEGIN CONDUCTOR (managed) v0.4.0 - x -->\na\n<!-- BEGIN CONDUCTOR (managed) v0.4.0 - x -->\nb\n<!-- END CONDUCTOR (managed) -->\n' > "$CLAUDE_DIR/CLAUDE.md" ;;
    end-first) printf '<!-- END CONDUCTOR (managed) -->\ntext\n<!-- BEGIN CONDUCTOR (managed) v0.4.0 - x -->\n' > "$CLAUDE_DIR/CLAUDE.md" ;;
  esac
  cp "$CLAUDE_DIR/CLAUDE.md" "$SBX/w/claude-md.orig"
  inst
  assert_eq 0 "$RC" "exit code ($kind)"
  assert_eq "$(sum_of "$SBX/w/claude-md.orig")" "$(sum_of "$CLAUDE_DIR/CLAUDE.md")" "CLAUDE.md untouched ($kind)"
  assert_contains "$OUT" "markers" "warning ($kind)"
  assert_eq 1 "$(ls "$CLAUDE_DIR/conductor/backups" | grep -c '^CLAUDE.md.bak')" "a backup was made ($kind)"
  assert_file "$CLAUDE_DIR/agents/builder.md" "the rest of the install still ran ($kind)"
done
t_end

# ---------------------------------------------------------------- REQ-INS-002.6 roots

t_begin "REQ-INS-002.6 a Codex folder and no Claude folder: the Codex part installs with its own manifest and launcher"
fresh codex
inst
assert_eq 0 "$RC" "exit code"
assert_file "$CODEX_DIR/conductor/.install-manifest"
assert_file "$CODEX_DIR/conductor/bin/conductor"
assert_no_file "$CLAUDE_DIR" "no Claude folder is created"
assert_contains "$OUT" "skipping Claude Code: $CLAUDE_DIR does not exist" "the absent folder is named"
assert_eq "[]" "$(pyj "$CODEX_DIR/conductor/.install-manifest" 'd["shared_with"]')" "no Claude user"
t_end

t_begin "REQ-INS-002.6 neither folder exists: a failing exit that names both, and nothing is written"
fresh
inst
assert_eq 1 "$RC" "exit code"
assert_contains "$OUT" "$CLAUDE_DIR"
assert_contains "$OUT" "$CODEX_DIR"
assert_eq 0 "$(find "$HOME" | wc -l | tr -d ' ' | awk '{print $1 - 1}')" "nothing under HOME"
t_end

t_begin "REQ-INS-002.6 an unwritable root exits 1 naming the folder before anything is written"
fresh claude
chmod 500 "$CLAUDE_DIR"
inst
chmod 700 "$CLAUDE_DIR"
if [ "$(id -u)" != 0 ]; then
  assert_eq 1 "$RC" "exit code"
  assert_contains "$OUT" "$CLAUDE_DIR"
  assert_eq 0 "$(ls -A "$CLAUDE_DIR" | wc -l | tr -d ' ')" "nothing written"
fi
t_end

# ---------------------------------------------------------------- REQ-INS-002.7 symlinked doctrine file

t_begin "REQ-INS-002.7 a CLAUDE.md that is a link: the target holds the block, the link stays, the target is backed up"
fresh claude
mkdir -p "$HOME/dotfiles"
printf 'dotfile notes\n' > "$HOME/dotfiles/claude-notes.md"
ln -s "$HOME/dotfiles/claude-notes.md" "$CLAUDE_DIR/CLAUDE.md"
printf 'keep me\n' > "$HOME/dotfiles/other.txt"
other_sum="$(sum_of "$HOME/dotfiles/other.txt")"
inst
assert_eq 0 "$RC" "exit code"
assert_eq 1 "$([ -L "$CLAUDE_DIR/CLAUDE.md" ] && echo 1 || echo 0)" "CLAUDE.md is still a link"
assert_eq "$HOME/dotfiles/claude-notes.md" "$(readlink "$CLAUDE_DIR/CLAUDE.md")" "link target"
assert_eq 1 "$(grep -c '^<!-- BEGIN CONDUCTOR' "$HOME/dotfiles/claude-notes.md")" "the target holds the block"
assert_eq "dotfile notes" "$(head -1 "$HOME/dotfiles/claude-notes.md")" "the target's own text is first"
assert_eq "$other_sum" "$(sum_of "$HOME/dotfiles/other.txt")" "another file in that folder"
assert_eq "claude-notes.md other.txt" "$(ls -A "$HOME/dotfiles" | tr '\n' ' ' | sed 's/ $//')" "nothing else appears in that folder"
bak="$(ls "$CLAUDE_DIR/conductor/backups" | grep '^CLAUDE.md.bak' | head -1)"
assert_eq "dotfile notes" "$(cat "$CLAUDE_DIR/conductor/backups/$bak")" "the former content is backed up in the root"
t_end

t_begin "REQ-INS-002.7 the same holds for an AGENTS.md link in the Codex root"
fresh codex
mkdir -p "$HOME/dotfiles"
printf 'codex notes\n' > "$HOME/dotfiles/agents-notes.md"
ln -s "$HOME/dotfiles/agents-notes.md" "$CODEX_DIR/AGENTS.md"
# the Codex doctrine block belongs to install_codex: drive it through write_doctrine_block
out="$(sandbox_notty /bin/bash -c ". '$LIB'; detect_roots; detect_os; detect_python; py_prepare; manifest_begin '$CODEX_DIR'; write_doctrine_block codex" < /dev/null 2>&1)"
assert_eq 1 "$([ -L "$CODEX_DIR/AGENTS.md" ] && echo 1 || echo 0)" "AGENTS.md is still a link"
assert_eq 1 "$(grep -c '^<!-- BEGIN CONDUCTOR' "$HOME/dotfiles/agents-notes.md")" "the target holds the block"
assert_eq "codex notes" "$(cat "$CODEX_DIR/conductor/backups/"AGENTS.md.bak.*)" "former content backed up in the Codex root"
t_end

# ---------------------------------------------------------------- REQ-INS-002.8 and .9 interrupted runs

pin_fixture
PININST="$FX/install.sh"

t_begin "REQ-INS-002.8 stopped after a pin change, run again, then uninstall: the value from before the first run comes back"
fresh claude
printf '{\n  "theme": "dark",\n  "modelSettings": {\n    "claude-opus-5-5": {\n      "effortLevel": "medium"\n    }\n  }\n}\n' > "$CLAUDE_DIR/settings.json"
cp "$CLAUDE_DIR/settings.json" "$SBX/w/settings.orig"
CONDUCTOR_TEST_KILL=1 run /bin/bash "$PININST"
assert_eq 137 "$RC" "the run was killed"
assert_eq "high" "$(pyj "$CLAUDE_DIR/settings.json" 'd["modelSettings"]["claude-opus-5-5"]["effortLevel"]')" "the pin was written before the kill"
assert_eq "medium" "$(pyj "$CLAUDE_DIR/conductor/.install-manifest" 'd["pins"][0]["previous"]')" "the manifest recorded the previous value first"
run /bin/bash "$PININST"
assert_eq 0 "$RC" "the second run completes"
assert_eq "medium" "$(pyj "$CLAUDE_DIR/conductor/.install-manifest" 'd["pins"][0]["previous"]')" "the previous value is still the first value"
assert_eq 1 "$(pyj "$CLAUDE_DIR/conductor/.install-manifest" 'len(d["pins"])')" "1 pin record"
run /bin/bash "$PININST" --uninstall
assert_eq 0 "$RC" "uninstall exit code"
assert_eq "$("$MY_PY" -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), sort_keys=True))' "$SBX/w/settings.orig")" \
  "$("$MY_PY" -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), sort_keys=True))' "$CLAUDE_DIR/settings.json")" "settings.json is back to the original values"
t_end

t_begin "REQ-INS-002.8 the same with the key absent before: uninstall removes it, and the emptied parents with it"
fresh claude
printf '{"theme": "dark"}\n' > "$CLAUDE_DIR/settings.json"
CONDUCTOR_TEST_KILL=1 run /bin/bash "$PININST"
assert_eq 137 "$RC"
run /bin/bash "$PININST"
run /bin/bash "$PININST" --uninstall
assert_eq '{"theme": "dark"}' "$("$MY_PY" -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))))' "$CLAUDE_DIR/settings.json")" "settings.json holds only the original key"
t_end

t_begin "REQ-INS-002.9 stopped during a manifest write: the manifest parses, holds the previous complete write, and uninstall still restores the pin"
fresh claude
printf '{"model": "opus", "modelSettings": {"claude-opus-5-5": {"effortLevel": "low"}}}\n' > "$CLAUDE_DIR/settings.json"
cp "$CLAUDE_DIR/settings.json" "$SBX/w/settings.orig"
run /bin/bash "$PININST"
assert_eq 0 "$RC"
( . "$LIB"; emit_py_manifest ) > "$SBX/w/manifest.py"
m="$CLAUDE_DIR/conductor/.install-manifest"
cp "$m" "$SBX/w/manifest.before"
for cmd in 'set components ["core","full"]' 'pin-record model "sonnet" "opus" 1' 'add-file extra/file.md - abc replace core x'; do
  # shellcheck disable=SC2086
  "$MY_PY" -c '
import os, runpy, sys
def interrupted(a, b):
    os._exit(9)
os.replace = interrupted
script = sys.argv[1]
sys.argv = ["manifest.py"] + sys.argv[2:]
runpy.run_path(script, run_name="__main__")
' "$SBX/w/manifest.py" "$m" $cmd 2> /dev/null
  assert_eq 9 "$?" "the interrupted write ended the process ($cmd)"
  assert_eq 0 "$("$MY_PY" "$SBX/w/manifest.py" "$m" check > /dev/null 2>&1; echo $?)" "the manifest still parses ($cmd)"
  assert_eq "$(sum_of "$SBX/w/manifest.before")" "$(sum_of "$m")" "the manifest is the previous complete write ($cmd)"
done
assert_eq "['modelSettings.claude-opus-5-5.effortLevel']" "$(pyj "$m" '[p["key"] for p in d["pins"]]')" "only the first pin is recorded"
run /bin/bash "$PININST"
assert_eq 0 "$RC" "a run after the interruption completes"
run /bin/bash "$PININST" --uninstall
assert_eq 0 "$RC" "uninstall exit code"
assert_eq "low" "$(pyj "$CLAUDE_DIR/settings.json" 'd["modelSettings"]["claude-opus-5-5"]["effortLevel"]')" "the pin is back to its value from before the first run"
assert_eq 0 "$(ls -A "$CLAUDE_DIR/conductor" | grep -c 'manifest-tmp' || true)" "no temp file of an interrupted write is left"
t_end

# ---------------------------------------------------------------- truncated installer

t_begin "case 21 / REQ-INS-001 a copy of install.sh cut off at an earlier line or byte changes nothing"
fresh claude codex
printf '%s' "$user_md" > "$CLAUDE_DIR/CLAUDE.md"
total="$(wc -l < "$INST" | tr -d ' ')"
before="$(sandbox_tree_sum "$HOME")"
for n in 1 25 120 400 900 1800 3000 $((total - 40)) $((total - 2)) $((total - 1)); do
  head -n "$n" "$INST" > "$SBX/w/cut.sh"
  run /bin/bash "$SBX/w/cut.sh"
  assert_eq "$before" "$(sandbox_tree_sum "$HOME")" "home after a copy cut at line $n"
done
size="$(wc -c < "$INST" | tr -d ' ')"
head -c $((size - 3)) "$INST" > "$SBX/w/cut.sh"
run /bin/bash "$SBX/w/cut.sh"
assert_eq "$before" "$(sandbox_tree_sum "$HOME")" "home after a copy cut inside the last line"
t_end

t_begin "case 21 / REQ-NFR-001.1 bash -n passes on install.sh under /bin/bash 3.2, and the suite runs under it"
assert_exit 0 /bin/bash -n "$INST"
assert_contains "$(/bin/bash --version | head -1)" "version 3.2" "the shell the suite runs under"
assert_contains "$BASH_VERSION" "3.2" "BASH_VERSION of this suite"
t_end

# ---------------------------------------------------------------- settings.json permutations (INS-004)


t_begin "REQ-INS-004.1 / .2 user keys and hooks are preserved in order, Conductor sits in its own groups, and a re-run adds nothing"
fresh claude
printf '%s' "$user_settings" > "$CLAUDE_DIR/settings.json"
CONDUCTOR_COMPONENTS=$HOOKS2 inst
assert_eq 0 "$RC" "exit code"
s="$CLAUDE_DIR/settings.json"
assert_eq "['theme', 'permissions', 'hooks', 'env', 'model']" "$(pyj "$s" 'list(d.keys())')" "top-level key order"
assert_eq "['SessionStart', 'PreToolUse', 'Stop']" "$(pyj "$s" 'list(d["hooks"].keys())')" "event order"
assert_eq "{'matcher': 'startup', 'hooks': [{'type': 'command', 'command': '/usr/bin/true'}]}" "$(pyj "$s" 'd["hooks"]["SessionStart"][0]')" "the user's SessionStart group is untouched and first"
assert_eq "{'matcher': '', 'hooks': [{'type': 'command', 'command': '/usr/bin/true'}]}" "$(pyj "$s" 'd["hooks"]["Stop"][0]')" "the user's Stop group is untouched and first"
assert_eq 2 "$(pyj "$s" 'len(d["hooks"]["SessionStart"])')" "SessionStart groups"
assert_eq 2 "$(pyj "$s" 'len(d["hooks"]["Stop"])')" "Stop groups (the user's and ours stay separate)"
assert_eq "{'matcher': 'Bash', 'hooks': [{'type': 'command', 'command': '/usr/bin/echo pre'}]}" "$(pyj "$s" 'd["hooks"]["PreToolUse"][0]')" "an event we do not use is untouched"
assert_eq "{'allow': ['Bash(ls)']}" "$(pyj "$s" 'd["permissions"]')" "unrelated key"
assert_eq "opus" "$(pyj "$s" 'd["model"]')" "model key not touched"
cmd="$(pyj "$s" 'd["hooks"]["SessionStart"][1]["hooks"][0]["command"]')"
py_recorded="$(pyj "$CLAUDE_DIR/conductor/.install-manifest" 'd["python3"]')"
assert_eq "[ ! -x \"$py_recorded\" ] || [ ! -f \"$CLAUDE_DIR/conductor/hooks/session-start-pointer.py\" ] || [ ! -r \"$CLAUDE_DIR/conductor/hooks/session-start-pointer.py\" ] || \"$py_recorded\" -I -B \"$CLAUDE_DIR/conductor/hooks/session-start-pointer.py\"" "$cmd" "the command is guarded against a missing python3 and a missing or unreadable script, uses the absolute python3 of the manifest with -I -B and a quoted path"
assert_eq "True" "$(pyj "$CLAUDE_DIR/conductor/.install-manifest" 'd["hooks_wired"]')" "hooks_wired"
assert_eq 2 "$(pyj "$CLAUDE_DIR/conductor/.install-manifest" 'len(d["hooks"])')" "2 hook records"
first="$(sandbox_tree_sum "$HOME")"
CONDUCTOR_COMPONENTS=$HOOKS2 inst
assert_eq "$first" "$(sandbox_tree_sum "$HOME")" "a second run changes nothing, entry count included"
t_end

t_begin "REQ-INS-004.6 absent, empty, whitespace-only, no hooks key, hooks {} and an empty event list: the file parses and holds the user's entries plus ours"
for kind in absent empty whitespace nohooks emptyhooks emptyevent; do
  fresh claude
  case "$kind" in
    absent) ;;
    empty) : > "$CLAUDE_DIR/settings.json" ;;
    whitespace) printf '  \n\t\n' > "$CLAUDE_DIR/settings.json" ;;
    nohooks) printf '{"theme": "dark"}\n' > "$CLAUDE_DIR/settings.json" ;;
    emptyhooks) printf '{"theme": "dark", "hooks": {}}\n' > "$CLAUDE_DIR/settings.json" ;;
    emptyevent) printf '{"theme": "dark", "hooks": {"SessionStart": []}}\n' > "$CLAUDE_DIR/settings.json" ;;
  esac
  CONDUCTOR_COMPONENTS=$HOOKS2 inst
  assert_eq 0 "$RC" "exit code ($kind)"
  s="$CLAUDE_DIR/settings.json"
  assert_eq 1 "$("$MY_PY" -c 'import json,sys; json.load(open(sys.argv[1])); print(1)' "$s" 2> /dev/null || echo 0)" "parses ($kind)"
  assert_eq 1 "$(pyj "$s" 'len(d["hooks"]["SessionStart"])')" "SessionStart holds only ours ($kind)"
  assert_eq 1 "$(pyj "$s" 'len(d["hooks"]["Stop"])')" "Stop holds only ours ($kind)"
  case "$kind" in
    absent|empty|whitespace) assert_eq "['hooks']" "$(pyj "$s" 'list(d.keys())')" "keys ($kind)" ;;
    *) assert_eq "dark" "$(pyj "$s" 'd["theme"]')" "user key kept ($kind)" ;;
  esac
  case "$kind" in
    absent) assert_eq 0 "$(ls "$CLAUDE_DIR/conductor/backups" 2> /dev/null | grep -c '^settings.json' || true)" "an absent file needs no backup"
            assert_mode "$s" 600 "a created file is private"
            assert_eq "True" "$(pyj "$CLAUDE_DIR/conductor/.install-manifest" 'd.get("settings_created", False)')" "the record says Conductor created it" ;;
    *) assert_eq 1 "$(ls "$CLAUDE_DIR/conductor/backups" | grep -c '^settings.json.bak')" "backed up first ($kind)" ;;
  esac
done
t_end

t_begin "REQ-INS-004.3 an unparseable settings.json stays byte-identical, the entries are printed, the install goes on, hooks_wired is false"
fresh claude
printf '{ "theme": "dark", "hooks": ' > "$CLAUDE_DIR/settings.json"
cp "$CLAUDE_DIR/settings.json" "$SBX/w/bad.json"
CONDUCTOR_COMPONENTS=$HOOKS2 inst
assert_eq 0 "$RC" "exit code"
assert_eq "$(sum_of "$SBX/w/bad.json")" "$(sum_of "$CLAUDE_DIR/settings.json")" "byte-identical"
assert_contains "$OUT" "not valid JSON"
assert_contains "$OUT" "\"SessionStart\"" "the entry for SessionStart is printed"
assert_contains "$OUT" "session-start-pointer.py"
assert_contains "$OUT" "\"Stop\"" "the entry for Stop is printed"
assert_file "$CLAUDE_DIR/agents/builder.md" "the install went on"
assert_eq "False" "$(pyj "$CLAUDE_DIR/conductor/.install-manifest" 'd["hooks_wired"]')" "hooks_wired"
assert_eq 0 "$(ls "$CLAUDE_DIR/conductor/backups" 2> /dev/null | grep -c '^settings.json' || true)" "no backup of a file that was not changed"
t_end

t_begin "REQ-INS-004.4 a settings.json with mode 600 keeps it, and its backup has mode 600"
fresh claude
printf '%s' "$user_settings" > "$CLAUDE_DIR/settings.json"
chmod 600 "$CLAUDE_DIR/settings.json"
CONDUCTOR_COMPONENTS=$HOOKS2 inst
assert_mode "$CLAUDE_DIR/settings.json" 600
sb="$(ls "$CLAUDE_DIR/conductor/backups" | grep '^settings.json.bak' | head -1)"
assert_mode "$CLAUDE_DIR/conductor/backups/$sb" 600 "backup mode"
assert_eq "$(printf '%s' "$user_settings" | shasum -a 256 | awk '{print $1}')" "$(sum_of "$CLAUDE_DIR/conductor/backups/$sb")" "the backup is the original"
t_end

t_begin "REQ-INS-004.9 under a umask of 022, settings.json and CLAUDE.md keep mode 600 or 644 as they were"
for mode in 600 644; do
  fresh claude
  printf '%s' "$user_settings" > "$CLAUDE_DIR/settings.json"
  printf '%s' "$user_md" > "$CLAUDE_DIR/CLAUDE.md"
  chmod "$mode" "$CLAUDE_DIR/settings.json" "$CLAUDE_DIR/CLAUDE.md"
  CONDUCTOR_COMPONENTS=$HOOKS2 inst
  assert_eq 0 "$RC" "exit code ($mode)"
  assert_mode "$CLAUDE_DIR/settings.json" "$mode" "settings.json"
  assert_mode "$CLAUDE_DIR/CLAUDE.md" "$mode" "CLAUDE.md"
  assert_eq 1 "$(grep -c '^<!-- BEGIN CONDUCTOR' "$CLAUDE_DIR/CLAUDE.md")" "the block went in ($mode)"
  assert_eq 2 "$(pyj "$CLAUDE_DIR/settings.json" 'len(d["hooks"]["Stop"])')" "the hooks went in ($mode)"
done
t_end

t_begin "REQ-INS-004.8 a settings.json that is a link to a file in another folder: the link stays, the target holds the change, the backup is in the root"
fresh claude
mkdir -p "$HOME/dotfiles"
printf '%s' "$user_settings" > "$HOME/dotfiles/settings.json"
ln -s "$HOME/dotfiles/settings.json" "$CLAUDE_DIR/settings.json"
CONDUCTOR_COMPONENTS=$HOOKS2 inst
assert_eq 0 "$RC" "exit code"
assert_eq 1 "$([ -L "$CLAUDE_DIR/settings.json" ] && echo 1 || echo 0)" "still a link"
assert_eq "$HOME/dotfiles/settings.json" "$(readlink "$CLAUDE_DIR/settings.json")" "link target"
assert_eq 2 "$(pyj "$HOME/dotfiles/settings.json" 'len(d["hooks"]["Stop"])')" "the target holds the hooks"
assert_eq "settings.json" "$(ls -A "$HOME/dotfiles")" "nothing else appears beside the target"
assert_eq 1 "$(ls "$CLAUDE_DIR/conductor/backups" | grep -c '^settings.json.bak')" "the backup is in the root"
t_end

t_begin "REQ-INS-004.5 a config path with a space: the hook command quotes the path and uses the absolute python3 of the manifest"
fresh
SP="$HOME/my config"
mkdir -p "$SP"
out_before="$(outside_sum)"
CLAUDE_DIR="$SP" CLAUDE_CONFIG_DIR="$SP" CONDUCTOR_COMPONENTS=$HOOKS2 inst
assert_eq 0 "$RC" "exit code"
cmd="$(pyj "$SP/settings.json" 'd["hooks"]["SessionStart"][0]["hooks"][0]["command"]')"
py_recorded="$(pyj "$SP/conductor/.install-manifest" 'd["python3"]')"
assert_eq "[ ! -x \"$py_recorded\" ] || [ ! -f \"$SP/conductor/hooks/session-start-pointer.py\" ] || [ ! -r \"$SP/conductor/hooks/session-start-pointer.py\" ] || \"$py_recorded\" -I -B \"$SP/conductor/hooks/session-start-pointer.py\"" "$cmd" "command"
assert_eq "[|!|-x|$py_recorded|]||||[|!|-f|$SP/conductor/hooks/session-start-pointer.py|]||||[|!|-r|$SP/conductor/hooks/session-start-pointer.py|]||||$py_recorded|-I|-B|$SP/conductor/hooks/session-start-pointer.py" "$("$MY_PY" -c 'import shlex,sys; print("|".join(shlex.split(sys.argv[1])))' "$cmd")" "the command splits into the 3 guards, the interpreter, -I -B and the script path"
case "$py_recorded" in /*) ok_abs=1 ;; *) ok_abs=0 ;; esac
assert_eq 1 "$ok_abs" "python3 is absolute, never bare"
t_end

t_begin "REQ-INS-004.5 a config path with a quote, dollar, backtick, backslash or line break: no hook is wired, the path is named, core files are installed"
for name in 'q"uote' 'dol$lar' 'back`tick' 'back\slash' $'line\nbreak'; do
  fresh
  D="$HOME/$name"
  mkdir -p "$D"
  printf '{"theme": "dark"}\n' > "$D/settings.json"
  cp "$D/settings.json" "$SBX/w/s.orig"
  CLAUDE_DIR="$D" CLAUDE_CONFIG_DIR="$D" CONDUCTOR_COMPONENTS=$HOOKS2 inst
  label="$(printf '%s' "$name" | tr '\n' '~')"
  assert_eq 0 "$RC" "exit code ($label)"
  assert_file "$D/agents/builder.md" "core files ($label)"
  assert_eq "$(sum_of "$SBX/w/s.orig")" "$(sum_of "$D/settings.json")" "settings.json untouched ($label)"
  assert_contains "$OUT" "no hook is offered" "message ($label)"
  assert_eq 0 "$(pyj "$D/conductor/.install-manifest" 'len(d["hooks"])')" "no hook recorded ($label)"
done
t_end

# ---------------------------------------------------------------- python3 not usable (G-13)

t_begin "REQ-INS-004.7 python3 absent, too old, or the macOS stub: settings.json is byte-identical, core files install, the warning names python3"
for kind in absent old stub; do
  fresh claude
  printf '%s' "$user_settings" > "$CLAUDE_DIR/settings.json"
  cp "$CLAUDE_DIR/settings.json" "$SBX/w/s.orig"
  case "$kind" in
    absent) sandbox_no_python ;;
    old) sandbox_fake_python 3.8.10 ;;
    stub)
      if [ "$(uname -s)" != "Darwin" ] || [ ! -x /usr/bin/python3 ]; then continue; fi
      sandbox_fake_xcode_select FAIL
      export PATH="$SBX/bin:/usr/bin:/bin"
      ;;
  esac
  CONDUCTOR_COMPONENTS=$HOOKS2 inst
  clear_fakes
  assert_eq 0 "$RC" "exit code ($kind)"
  assert_eq "$(sum_of "$SBX/w/s.orig")" "$(sum_of "$CLAUDE_DIR/settings.json")" "settings.json byte-identical ($kind)"
  assert_file "$CLAUDE_DIR/agents/builder.md" "core files ($kind)"
  assert_contains "$OUT" "python3" "warning names python3 ($kind)"
  assert_contains "$OUT" "skipped" "something was skipped ($kind)"
  assert_eq 1 "$(grep -c '^<!-- BEGIN CONDUCTOR' "$CLAUDE_DIR/CLAUDE.md")" "doctrine block still written ($kind)"
  assert_no_file "$CLAUDE_DIR/conductor/hooks" "no hook files ($kind)"
  assert_no_file "$CLAUDE_DIR/skills/handoff" "no full tier ($kind)"
done
sandbox_fake_uname Darwin
sandbox_fake_xcode_select FAIL
clear_fakes
t_end

t_begin "REQ-INS-004.7 the macOS stub is never executed: a python3 that records its own use is not run when xcode-select -p fails"
if [ "$(uname -s)" = "Darwin" ] && [ -x /usr/bin/python3 ]; then
  fresh claude
  sandbox_fake_xcode_select FAIL
  out="$(export PATH="$SBX/bin:/usr/bin:/bin"; . "$LIB"; OS_KIND=darwin; detect_python; echo "PY=$PY"; echo "REASON=$PY_REASON")"
  clear_fakes
  assert_contains "$out" "PY=
"
  assert_contains "$out" "Command Line Tools stub"
fi
t_end

part_output_scan 1

t_summary
