#!/bin/bash
# tests/test-review-fixes.sh: the fixes made after the tier 4 review of the public candidate.
# Each test is named for what it proves and failed before its fix. Every install runs in a sandbox (tests/lib/sandbox.sh); nothing reads
# or writes a real config folder. Shares tests/lib/install-common.sh with the install suites.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/install-common.sh"

SRV_PIDS=""
cleanup() {
  { for p in $SRV_PIDS; do kill "$p"; done; for p in $SRV_PIDS; do wait "$p"; done; } 2> /dev/null
  sandbox_cleanup
}
trap cleanup EXIT

HOOK_SRC="$REPO/payload/claude/conductor/hooks"
LA="$REPO/payload/claude/conductor/bin/ledger-append"
FXH="$HERE/hooks/fixtures"
export CONDUCTOR_TEST_SANDBOX="$SBX"

# launcher ARGS...: the installed launcher of CLAUDE_DIR; leaves OUT and RC.
launcher() {
  OUT="$(NO_COLOR=1 /bin/bash "$CLAUDE_DIR/conductor/bin/conductor" "$@" 2>&1 < /dev/null)"
  RC=$?
}

hook_cmd() { # EVENT: the command of the first group wired for EVENT
  pyj "$CLAUDE_DIR/settings.json" "d['hooks']['$1'][0]['hooks'][0]['command']"
}

# plant_dangling NAME: a recorded script under conductor/hooks that the current release
# does not ship, plus a hook entry in Conductor's guarded form that points at it and is
# not in the install record (what an earlier release leaves behind).
plant_dangling() {
  "$MY_PY" - "$CLAUDE_DIR" "$1" "$MY_PY" << 'PYEOF'
import hashlib, json, os, sys
root, name, py = sys.argv[1:4]
d = os.path.join(root, "conductor", "hooks")
os.makedirs(d, exist_ok=True)
path = os.path.join(d, name)
data = b"print('x')\n"
with open(path, "wb") as fh:
    fh.write(data)
mp = os.path.join(root, "conductor", ".install-manifest")
m = json.load(open(mp))
m["files"].append({"dest": "conductor/hooks/" + name, "sha256": hashlib.sha256(data).hexdigest(),
                   "policy": "replace", "component": "full", "id": "extra_" + name})
with open(mp, "w") as fh:
    json.dump(m, fh, indent=2)
sp = os.path.join(root, "settings.json")
s = json.load(open(sp)) if os.path.exists(sp) else {}
cmd = '[ ! -f "%s" ] || [ ! -r "%s" ] || "%s" -I -B "%s"' % (path, path, py, path)
s.setdefault("hooks", {}).setdefault("Stop", []).append(
    {"matcher": "", "hooks": [{"type": "command", "command": cmd, "timeout": 10}]})
with open(sp, "w") as fh:
    json.dump(s, fh, indent=2)
PYEOF
}

# stop_event TEXT: a Stop event whose closing message is TEXT, on the 2 worker transcript
stop_event() {
  "$MY_PY" - "$1" "$SBX/tx.jsonl" "$SBX/w" << 'PYEOF'
import json, sys
print(json.dumps({"hook_event_name": "Stop", "session_id": "s-r", "cwd": sys.argv[3],
                  "transcript_path": sys.argv[2], "last_assistant_message": sys.argv[1]}))
PYEOF
}

# worker_stop_event AGENT_TYPE TEXT: a SubagentStop event
worker_stop_event() {
  "$MY_PY" - "$1" "$2" "$SBX/w" << 'PYEOF'
import json, sys
ev = {"hook_event_name": "SubagentStop", "session_id": "s-r", "cwd": sys.argv[3],
      "last_assistant_message": sys.argv[2]}
if sys.argv[1]:
    ev["agent_type"] = sys.argv[1]
print(json.dumps(ev))
PYEOF
}

# run_installed_hook NAME EVENTJSON: runs the installed hook the way its command does
run_installed_hook() {
  OUT="$(printf '%s' "$2" | env ${KS_VAR+"CONDUCTOR_HOOKS=$KS_VAR"} "$MY_PY" -I -B "$CLAUDE_DIR/conductor/hooks/$1.py" 2> /dev/null)"
  RC=$?
}

# ---------------------------------------------------------------- hook commands

t_begin "a wired hook command whose script was deleted exits 0 and prints nothing"
fresh claude
CONDUCTOR_COMPONENTS=hook_pointer,hook_usage_split inst
assert_eq 0 "$RC" "install exit code"
cmd="$(hook_cmd Stop)"
rm -f "$CLAUDE_DIR/conductor/hooks/usage-split-check.py"
out="$(/bin/sh -c "$cmd" < /dev/null 2>&1)"
rc=$?
assert_eq 0 "$rc" "exit code of the command"
assert_eq "" "$out" "output of the command"
t_end

t_begin "a wired hook runs with -I -B and leaves no bytecode beside the hooks"
fresh claude
CONDUCTOR_COMPONENTS=hook_pointer,hook_usage_split inst
cmd="$(hook_cmd SessionStart)"
assert_contains "$cmd" " -I -B " "the command isolates the interpreter and writes no bytecode"
out="$(printf '{"hook_event_name":"SessionStart","session_id":"s","cwd":"%s","source":"startup"}' "$SBX/w" | /bin/sh -c "$cmd" 2>&1)"
assert_eq 0 "$?" "the hook runs under -I"
assert_eq 0 "$(find "$CLAUDE_DIR/conductor" -name '__pycache__' | wc -l | tr -d ' ')" "bytecode folders"
t_end

t_begin "a re-run that removes a dropped script also unwires the entry that points at it"
fresh claude
CONDUCTOR_COMPONENTS=hook_pointer inst
plant_dangling old-hook.py
assert_contains "$(cat "$CLAUDE_DIR/settings.json")" "conductor/hooks/old-hook.py" "setup: the entry is there"
CONDUCTOR_COMPONENTS=hook_pointer inst
assert_eq 0 "$RC" "re-run exit code"
assert_no_file "$CLAUDE_DIR/conductor/hooks/old-hook.py" "the dropped script is removed"
assert_eq 0 "$(grep -c 'old-hook.py' "$CLAUDE_DIR/settings.json")" "entries that point at the removed script"
assert_contains "$(cat "$CLAUDE_DIR/settings.json")" "session-start-pointer.py" "the wired hook stays"
assert_contains "$OUT" "removed hook entry:" "the removal is named"
t_end

t_begin "uninstall also unwires an entry whose script it removes"
fresh claude
CONDUCTOR_COMPONENTS=hook_pointer inst
plant_dangling gone.py
inst --uninstall
assert_eq 0 "$RC" "uninstall exit code"
assert_no_file "$CLAUDE_DIR/conductor/hooks/gone.py" "the script is removed"
if [ -f "$CLAUDE_DIR/settings.json" ]; then
  assert_eq 0 "$(grep -c 'conductor/' "$CLAUDE_DIR/settings.json")" "entries left in settings.json"
fi
t_end

t_begin "the doctor warns when a wired command points at a missing file"
fresh claude
sandbox_fake_claude 2.1.296
CONDUCTOR_COMPONENTS=hook_pointer,hook_usage_split inst
launcher doctor
assert_not_contains "$(printf '%s' "$OUT" | tr '\n' ' ' | tr -s ' ')" "points at" "setup: no missing-script warning while the scripts exist"
rm -f "$CLAUDE_DIR/conductor/hooks/usage-split-check.py"
launcher doctor
flat_out="$(printf '%s' "$OUT" | tr '\n' ' ' | tr -s ' ')"
assert_contains "$flat_out" "points at" "the warning"
assert_contains "$flat_out" "which is not there" "the warning says the script is missing"
assert_contains "$OUT" "Script not found: $CLAUDE_DIR/conductor/hooks/usage-split-check.py" "the hooks section names the file"
t_end

# ---------------------------------------------------------------- the kill switch

t_begin "the hooks and the doctor read CONDUCTOR_HOOKS by the same rule"
"$MY_PY" -I -B - "$HOOK_SRC" "$REPO/payload/claude/conductor/lib" << 'PYEOF' > "$SBX/ks.txt" 2>&1
import os, sys
sys.path.insert(0, sys.argv[1])
sys.path.insert(0, sys.argv[2])
import hooklib, doctor
table = [("off", True), ("OFF", True), ("Off", True), ("0", True), ("false", True), ("FALSE", True),
         (" off ", True), ("", False), ("on", False), ("no", False), ("1", False), ("true", False)]
for val, want in table:
    os.environ["CONDUCTOR_HOOKS"] = val
    h = hooklib.hooks_off()
    d = doctor.hooks_switch_off(os.environ)
    if h != want or d != want:
        print("value %r: want %s, hooks say %s, doctor says %s" % (val, want, h, d))
del os.environ["CONDUCTOR_HOOKS"]
if hooklib.hooks_off() or doctor.hooks_switch_off(os.environ):
    print("unset must mean on")
PYEOF
assert_eq "" "$(cat "$SBX/ks.txt")" "disagreements between the hooks and the doctor"
t_end

t_begin "CONDUCTOR_HOOKS=OFF and CONDUCTOR_HOOKS=0 silence a hook that would speak"
fresh claude
CONDUCTOR_COMPONENTS=$ALL5 inst
ev='{"hook_event_name":"PreToolUse","session_id":"s","cwd":"'"$SBX/w"'","tool_name":"Agent","tool_input":{"prompt":"x"}}'
unset KS_VAR
run_installed_hook contract-check "$ev"
assert_contains "$OUT" "model pin is missing" "positive control: the hook speaks with the switch unset"
for v in OFF 0 false " off "; do
  KS_VAR="$v"
  run_installed_hook contract-check "$ev"
  assert_eq "" "$OUT" "output with CONDUCTOR_HOOKS=[$v]"
done
unset KS_VAR
t_end

t_begin "the install summary names the kill switch in 1 line, and the README names it"
fresh claude
CONDUCTOR_COMPONENTS=hook_pointer inst
assert_eq 1 "$(count_of "$OUT" "CONDUCTOR_HOOKS")" "summary lines that name the switch"
assert_contains "$OUT" "Kill switch:   hooks run unless CONDUCTOR_HOOKS=off is set in Claude Code's"
# the installer's own environment is not Claude Code's: the line never reports it
CONDUCTOR_HOOKS=off CONDUCTOR_COMPONENTS=hook_pointer inst
assert_contains "$OUT" "hooks run unless CONDUCTOR_HOOKS=off is set in Claude Code's"
assert_not_contains "$OUT" "(now: off)" "the summary reports the installer's own variable"
fresh claude
inst
assert_not_contains "$OUT" "CONDUCTOR_HOOKS" "no hooks wired, no switch line"
assert_contains "$(cat "$REPO/README.md")" "CONDUCTOR_HOOKS=off"
t_end

# ---------------------------------------------------------------- prompts default to no

t_begin "Enter at both effort-pin prompts writes nothing, and the text says so"
fresh claude
sandbox_fake_claude 2.1.296
PTY_INPUT=$'\n\n' pty /bin/bash "$INST" --core --judge-rung=3
assert_eq 0 "$RC" "exit code"
assert_contains "$OUT" "Set Opus 5.5 to high effort for this config? [n]"
assert_contains "$OUT" "Pressing Enter answers no and changes nothing."
if [ -f "$CLAUDE_DIR/settings.json" ]; then assert_eq 0 "$(grep -c 'effortLevel' "$CLAUDE_DIR/settings.json")" "pins written by Enter"; fi
PTY_INPUT=$'y\ny\n' pty /bin/bash "$INST" --core --judge-rung=3
assert_eq 2 "$(grep -c 'effortLevel' "$CLAUDE_DIR/settings.json")" "positive control: yes writes both pins"
t_end

t_begin "Enter at the Haiku-removal prompt keeps the value"
fresh claude
sandbox_fake_claude 2.1.296
mkdir -p "$CLAUDE_DIR/conductor"
printf '{"schema": 1, "product": "conductor", "files": [], "pins": [], "env_written": ["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "judge_rung": null}\n' > "$CLAUDE_DIR/conductor/.install-manifest"
printf '{"env": {"ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-haiku-5-5"}}\n' > "$CLAUDE_DIR/settings.json"
PTY_INPUT=$'\n\n\n' pty /bin/bash "$INST" --core --judge-rung=3
assert_contains "$OUT" "Remove env.ANTHROPIC_DEFAULT_HAIKU_MODEL from your settings? [n]"
assert_contains "$(cat "$CLAUDE_DIR/settings.json")" "ANTHROPIC_DEFAULT_HAIKU_MODEL" "the value survives Enter"
PTY_INPUT=$'\n\ny\n' pty /bin/bash "$INST" --core --judge-rung=3
assert_not_contains "$(cat "$CLAUDE_DIR/settings.json")" "ANTHROPIC_DEFAULT_HAIKU_MODEL" "positive control: yes removes it"
t_end

# ---------------------------------------------------------------- usage split

t_begin "the usage-split hook accepts a Usage split line with emphasis or a quote mark"
fresh claude
CONDUCTOR_COMPONENTS=hook_usage_split inst
"$MY_PY" -B "$FXH/gen-transcript.py" "$FXH/transcripts/dispatch2.spec.json" "$SBX/tx.jsonl"
mkdir -p "$SBX/w"
body='conductor on opus; 2 workers on sonnet.'
for line in "Usage split: $body" "**Usage split:** $body" "**Usage split**: $body" "> Usage split: $body" "\"Usage split: $body\"" "- **Usage split:** $body" "_Usage split:_ $body" "\`Usage split:\` $body"; do
  run_installed_hook usage-split-check "$(stop_event "All done.
$line")"
  assert_eq "" "$OUT" "the hook accepts: $line"
done
for line in "Usage splitter: $body" "I wrote the Usage split: here, mid-line $body" "All done."; do
  run_installed_hook usage-split-check "$(stop_event "Done.
$line")"
  assert_contains "$OUT" "No usage-split line was found" "the hook still asks for: $line"
done
t_end

t_begin "the doctrine and both /conductor skills teach a closing line that starts Usage split:"
assert_contains "$(cat "$REPO/payload/claude/doctrine.md")" 'starts `Usage split:`'
assert_contains "$(cat "$REPO/payload/codex/doctrine.md")" 'starts `Usage split:`'
assert_contains "$(cat "$REPO/payload/claude/skills/conductor/SKILL.md")" 'starts "Usage split:"'
assert_contains "$(cat "$REPO/payload/codex/skills/conductor/SKILL.md")" 'starts "Usage split:"'
assert_contains "$(cat "$REPO/payload/claude/skills/conductor/SKILL.md")" '"Usage split: Conductor on opus;'
t_end

# ---------------------------------------------------------------- reply shapes

t_begin "the reply shape of every pinned agent file passes the contract check"
fresh claude
CONDUCTOR_COMPONENTS=hook_contract inst
for pair in builder:builder scout:scout critic:critic architect:architect judge-rung1:judge judge-rung3:judge; do
  file="${pair%%:*}"
  type="${pair##*:}"
  reply="$("$MY_PY" - "$REPO/payload/claude/agents/$file.md" << 'PYEOF'
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
start = max(i for i, ln in enumerate(lines) if "exactly this" in ln)
for ln in lines[start + 1:]:
    m = re.match(r"^- ([A-Z][A-Z -]*):", ln)
    if m:
        print("- %s: x" % m.group(1))
PYEOF
)"
  run_installed_hook contract-check "$(worker_stop_event "$type" "$reply")"
  assert_eq "" "$OUT" "$file reply shape passes the contract check"
done
for f in scout architect; do
  assert_contains "$(cat "$REPO/payload/codex/agents/$f.toml")" "STATUS: done | partial | blocked" "the Codex $f file carries the status line"
done
t_end

t_begin "the contract check's report note fires only for Conductor's pinned agent types"
no_status="I finished the work and all is well."
run_installed_hook contract-check "$(worker_stop_event builder "$no_status")"
assert_contains "$OUT" "no STATUS, VERDICT or OUTCOME line" "positive control: a pinned type is checked"
for type in general-purpose Explore Plan "x:scout" ""; do
  run_installed_hook contract-check "$(worker_stop_event "$type" "$no_status")"
  assert_eq "" "$OUT" "agent type [$type]"
done
t_end


# ---------------------------------------------------------------- update fixtures

WWW="$SBX/www"
UTMP="$SBX/utmp"
UFX="$HERE/fixtures/update"
CONST_URL="https://raw.githubusercontent.com/akaCT/conductor/main/install.sh"
mkdir -p "$WWW" "$UTMP"

start_server() { # NAME: the fixture update host; its port lands in $SBX/NAME.port
  local name="$1" i=0
  "$MY_PY" -B "$UFX/server.py" --root "$WWW" --log "$SBX/$name.log" --port-file "$SBX/$name.port" > /dev/null 2>&1 &
  SRV_PIDS="$SRV_PIDS $!"
  while [ ! -s "$SBX/$name.port" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if [ ! -s "$SBX/$name.port" ]; then echo "the fixture server $name did not start" >&2; exit 98; fi
}

# A built installer 1 version up, made from this repo (the real installer, so the
# update runs real code).
rm -rf "$SBX/buildrepo"
mkdir -p "$SBX/buildrepo"
cp -R "$REPO/tools" "$REPO/installer" "$REPO/payload" "$SBX/buildrepo/"
cp "$REPO/CHANGELOG.md" "$SBX/buildrepo/CHANGELOG.md"
"$MY_PY" -B - "$SBX/buildrepo" << 'PYEOF'
import json, sys
root = sys.argv[1]
p = root + "/payload/components.json"
c = json.load(open(p))
c["version"] = "0.5.0"
json.dump(c, open(p, "w"), indent=2)
cl = root + "/CHANGELOG.md"
text = open(cl).read()
text = text.replace("## 0.3.0", "## 0.5.0 (2026-11-01)\n\n- Entry for the review fix tests.\n\n## 0.3.0", 1)
open(cl, "w").write(text)
PYEOF
if (cd "$SBX/buildrepo" && "$MY_PY" -B tools/build.py > "$SBX/build.out" 2>&1); then BUILD_OK=1; else BUILD_OK=0; fi
start_server plain
PLAIN_PORT="$(cat "$SBX/plain.port")"

# update_env: a fresh sandbox whose launcher fetches from the fixture host
update_env() {
  rm -rf "$UTMP"
  mkdir -p "$UTMP"
  : > "$SBX/plain.log"
  export TMPDIR="$UTMP"
  export CONDUCTOR_TEST_UPDATE_URL="http://127.0.0.1:$PLAIN_PORT/install.sh"
}

# update_pty LAUNCHER ANSWERS: runs `update` on a terminal; env CLAUDE_DIR and CLAUDE_CONFIG_DIR are removed
update_pty() {
  OUT="$(PTY_INPUT="$2" sandbox_pty env -u CLAUDE_DIR -u CLAUDE_CONFIG_DIR NO_COLOR=1 /bin/bash "$1" update)"
  RC=$?
}

t_begin "build: the 0.5.0 fixture installer used by the update tests was built"
assert_eq 1 "$BUILD_OK" "build of the fixture installer: $(tail -n 3 "$SBX/build.out")"
t_end

t_begin "update installs into the launcher's own config folder, not the default folder"
fresh
ALT="$SBX/alt-claude"
mkdir -p "$ALT" "$HOME/.claude"
CLAUDE_DIR="$ALT" CLAUDE_CONFIG_DIR="$ALT" CONDUCTOR_YES=1 inst --core
assert_eq 0 "$RC" "install into the alternate folder"
update_env
cp "$SBX/buildrepo/install.sh" "$WWW/install.sh"
update_pty "$ALT/conductor/bin/conductor" $'y\n\n\n\n\n\n\n\n\n\n'
assert_eq 0 "$RC" "update exit code: $(printf '%s' "$OUT" | tail -n 4)"
assert_contains "$OUT" "Update finished. Installed version: 0.5.0"
assert_eq "0.5.0" "$(pyj "$ALT/conductor/.install-manifest" 'd["version"]')" "the alternate folder holds the new version"
assert_no_file "$HOME/.claude/conductor" "no stray install in the default folder"
t_end

t_begin "an installer run that did not change the install record is not reported as finished"
fresh
ALT="$SBX/alt-claude"
mkdir -p "$ALT"
CLAUDE_DIR="$ALT" CLAUDE_CONFIG_DIR="$ALT" CONDUCTOR_YES=1 inst --core
update_env
sed 's/^do_install() {$/do_install() { return 0/' "$SBX/buildrepo/install.sh" > "$WWW/install.sh"
update_pty "$ALT/conductor/bin/conductor" $'y\n'
assert_eq 1 "$RC" "update exit code"
assert_contains "$(printf '%s' "$OUT" | tr '\n' ' ' | tr -s ' ')" "The update did not take effect: the install record says 0.4.0, not 0.5.0."
assert_not_contains "$OUT" "Update finished"
t_end

t_begin "the update preview lists none of the launcher files of the Codex copy as files to remove"
fresh claude codex
CONDUCTOR_YES=1 inst --core
assert_eq 0 "$RC" "install into both folders"
assert_file "$CODEX_DIR/conductor/lib/doctor.py" "setup: the Codex copy of the launcher set"
update_env
cp "$SBX/buildrepo/install.sh" "$WWW/install.sh"
update_pty "$CLAUDE_DIR/conductor/bin/conductor" $'n\n'
assert_contains "$OUT" "Update preview"
assert_contains "$OUT" "Files to remove (no longer shipped) (0)" "no file is listed as no longer shipped"
assert_not_contains "$OUT" "conductor/lib/doctor.py"
t_end

t_begin "the update address is a constant in the launcher: the facts file cannot change it"
fresh claude
CONDUCTOR_YES=1 inst --core
"$MY_PY" - "$CLAUDE_DIR/conductor/lib/facts.json" << 'PYEOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["update"] = {"host": "evil.example", "path": "/x/install.sh"}
json.dump(d, open(p, "w"))
PYEOF
cp "$UFX/fake-curl.sh" "$SBX/bin/curl"
chmod 755 "$SBX/bin/curl"
export CURL_ARGV_LOG="$SBX/curl-argv.log"
unset CONDUCTOR_TEST_UPDATE_URL
rm -f "$CURL_ARGV_LOG"
launcher update --check
assert_eq "$CONST_URL" "$(tail -n 1 "$CURL_ARGV_LOG")" "the address fetched when the facts file names another host"
rm -f "$SBX/bin/curl"
unset CURL_ARGV_LOG
t_end

t_begin "a redirect to another host is refused before a single request reaches that host"
fresh claude
CONDUCTOR_YES=1 inst --core
update_env
export CONDUCTOR_TEST_UPDATE_URL="http://127.0.0.1:$PLAIN_PORT/redir-other"
OUT="$(NO_COLOR=1 /bin/bash "$CLAUDE_DIR/conductor/bin/conductor" update --check 2>&1 < /dev/null)"
RC=$?
assert_eq 1 "$RC" "exit code"
assert_contains "$(printf '%s' "$OUT" | tr '\n' ' ' | tr -s ' ')" "Update refused: the fetch was redirected to another host. Nothing was changed."
assert_eq 1 "$(grep -c '^GET ' "$SBX/plain.log")" "requests the fixture host saw"
assert_eq 0 "$(grep -ic '^host: localhost' "$SBX/plain.log")" "requests addressed to the other host name"
t_end

t_begin "conductor doctor passes no subcommand through: record-sha does not rewrite the install record"
fresh claude
sandbox_fake_claude 2.1.296
CONDUCTOR_YES=1 inst --core
before="$(sum_of "$CLAUDE_DIR/conductor/.install-manifest")"
launcher doctor record-sha --sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
assert_eq 2 "$RC" "exit code for an unknown argument"
assert_eq "$before" "$(sum_of "$CLAUDE_DIR/conductor/.install-manifest")" "the install record"
t_end

# ---------------------------------------------------------------- doctor

t_begin "the doctor on a Codex-only install reports no false missing files or agent warnings"
fresh codex
sandbox_fake_claude 2.1.296
CONDUCTOR_YES=1 inst --core
assert_eq 0 "$RC" "install into the Codex folder"
OUT="$(NO_COLOR=1 /bin/bash "$CODEX_DIR/conductor/bin/conductor" doctor --managed-settings "$SBX/managed-settings.json" 2>&1 < /dev/null)"
flat_out="$(printf '%s' "$OUT" | tr '\n' ' ' | tr -s ' ')"
assert_contains "$flat_out" "Warnings none" "no warning"
assert_contains "$OUT" ", 0 missing," "no file is missing"
assert_not_contains "$OUT" "CLAUDE.md" "the Claude doctrine file is not looked for"
assert_contains "$OUT" "Codex only" "the Codex-only state is named"
t_end

t_begin "an unreadable Claude install record is warned about, not masked by a good Codex record"
fresh claude codex
sandbox_fake_claude 2.1.296
CONDUCTOR_YES=1 inst --core
printf 'not json at all\n' > "$CLAUDE_DIR/conductor/.install-manifest"
OUT="$(NO_COLOR=1 /bin/bash "$CODEX_DIR/conductor/bin/conductor" doctor --managed-settings "$SBX/managed-settings.json" 2>&1 < /dev/null)"
flat_out="$(printf '%s' "$OUT" | tr '\n' ' ' | tr -s ' ')"
assert_not_contains "$flat_out" "Warnings none" "the warnings are not empty"
assert_contains "$flat_out" "install record cannot be read" "the warning names the unreadable record"
t_end

t_begin "the summary and --status name components and hooks in words, not by id"
fresh claude
CONDUCTOR_COMPONENTS=hook_nudge,hook_contract inst
assert_eq 0 "$RC" "install exit code"
summary_lines="$(printf '%s\n' "$OUT" | grep -E '^  (Components|Hooks wired):|^                 ')"
assert_not_contains "$summary_lines" "hook_" "ids in the summary lines"
assert_contains "$summary_lines" "checkpoint nudge hook"
assert_contains "$summary_lines" "contract check hook"
inst --status
status_lines="$(printf '%s\n' "$OUT" | grep -E 'Components:|Hooks wired:|^       ')"
assert_not_contains "$status_lines" "hook_" "ids in the status lines"
assert_contains "$status_lines" "checkpoint nudge hook"
t_end

t_begin "the judge reason says the answer that was given"
fresh claude
sandbox_fake_claude 2.1.296
PTY_INPUT=$'y\n\n\n' pty /bin/bash "$INST" --core
assert_contains "$OUT" "you said yes to the Fable 5.1 question"
fresh claude
sandbox_fake_claude 2.1.296
PTY_INPUT=$'n\n\n\n' pty /bin/bash "$INST" --core
assert_contains "$OUT" "you said no to the Fable 5.1 question"
assert_not_contains "$OUT" "you answered"
t_end

t_begin "the fixed text names the installer file by the name it was run as"
fresh claude
cp "$INST" "$SBX/my-conductor-install.sh"
OUT="$(sandbox_notty /bin/bash "$SBX/my-conductor-install.sh" --help < /dev/null 2>&1)"
assert_contains "$OUT" "bash my-conductor-install.sh [options]"
assert_not_contains "$OUT" "bash install.sh"
CONDUCTOR_YES=1 OUT="$(sandbox_notty /bin/bash "$SBX/my-conductor-install.sh" --core --judge-rung=3 < /dev/null 2>&1)"
assert_contains "$OUT" "bash my-conductor-install.sh --judge-rung=1"
OUT="$(sandbox_notty /bin/bash "$SBX/my-conductor-install.sh" --bogus < /dev/null 2>&1)"
assert_contains "$OUT" "Run: bash my-conductor-install.sh --help"
t_end

t_begin "the default-model offer and the hook offers say what they do; the plan lists the questions to come"
fresh claude
sandbox_fake_claude 2.1.296
PTY_INPUT="$(printf 'n\n%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15)" pty /bin/bash "$INST" --full --judge-rung=3
assert_contains "$OUT" 'A yes writes the "model" key'
assert_contains "$OUT" "project-home check at session start (silent until you list homes)"
assert_contains "$OUT" "contract check before a subagent starts and on its final report"
assert_contains "$OUT" "you may be asked about: optional parts, effort pins, judge seat, a model"
inst --core
assert_not_contains "$OUT" "you may be asked about" "a run with nothing to ask does not list questions"
t_end

t_begin "a hook is reported as wired once, however often the wiring step runs"
new_fixture
"$MY_PY" - "$FX/installer/src/99-main.sh" << 'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("  install_full_tier || stop_install\n", "  install_full_tier || stop_install\n  settings_merge_hooks\n", 1)
open(p, "w").write(s)
PYEOF
build_fixture
fresh claude
CONDUCTOR_COMPONENTS=$ALL5 NOCOLLECT=1 run /bin/bash "$FX/install.sh"
assert_eq 0 "$RC" "exit code"
for n in "session-start pointer" "checkpoint nudge" "usage-split check" "project-home check" "contract check"; do
  assert_eq 1 "$(count_of "$OUT" "wired the $n hook")" "wired lines for the $n hook"
done
t_end

t_begin "a config folder given with trailing slashes gives hook commands without doubled slashes"
fresh claude
CLAUDE_DIR="$CLAUDE_DIR//" CLAUDE_CONFIG_DIR="$CLAUDE_DIR//" CONDUCTOR_COMPONENTS=hook_pointer inst
assert_eq 0 "$RC" "exit code"
assert_not_contains "$(cat "$CLAUDE_DIR/settings.json")" ".claude//" "doubled slashes in a hook command"
assert_contains "$(cat "$CLAUDE_DIR/settings.json")" ".claude/conductor/hooks/session-start-pointer.py"
t_end

t_begin "an uninstall that leaves files behind says so and lists them"
fresh claude
mkdir -p "$SBX/shared-agents"
ln -s "$SBX/shared-agents" "$CLAUDE_DIR/agents"
CONDUCTOR_YES=1 inst --core
assert_eq 0 "$RC" "install through the linked folder"
assert_file "$SBX/shared-agents/builder.md" "setup: the install wrote through the link"
inst --uninstall
assert_file "$SBX/shared-agents/builder.md" "the uninstall never follows the link"
assert_contains "$OUT" "Left alone (a link, or not a plain file; delete them yourself):"
assert_contains "$OUT" "    agents/builder.md"
assert_not_contains "$OUT" "Conductor removed. Files you changed" "the plain all-clear is not claimed"
assert_contains "$OUT" "Conductor removed, except the files listed below."
t_end

t_begin "the installer's text filter drops bidirectional and zero width controls"
bad="$(printf 'a\342\200\256b\342\201\246c\357\273\277d\342\200\213e\342\200\250f\342\201\240g\302\233h')"
got="$( . "$LIB"; printf '%s\n' "$bad" | sanitize_text )"
assert_eq "abcdefgh" "$got" "text after the filter"
keep="$( . "$LIB"; printf 'caf\303\251 \342\200\224 \342\234\223\n' | sanitize_text )"
assert_eq "$(printf 'caf\303\251 \342\200\224 \342\234\223')" "$keep" "other UTF-8 text passes unchanged"
t_end

t_begin "the doctor's text filter drops the same controls"
got="$("$MY_PY" -I -B - "$REPO/payload/claude/conductor/lib" << 'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
import doctor
print(doctor.clean("a\u202eb\u2066c\ufeffd\u200be\u2028f\u2060g\x9bh"))
PYEOF
)"
assert_eq "abcdefgh" "$got" "text after the filter"
t_end

t_begin "the install command in the installer's header comment is the hardened form"
line="$(grep -n 'Install:' "$REPO/install.sh" | head -n 1)"
assert_contains "$line" "curl --proto '=https' --tlsv1.2 -fsSL https://conductorskill.com/install.sh | bash"
t_end

# ---------------------------------------------------------------- ledger-append

led_fresh() { # makes a project folder $LP with a .git folder
  LP="$SBX/ledger-proj"
  rm -rf "$LP"
  mkdir -p "$LP/.git" "$LP/sub"
  printf '[core]\n' > "$LP/.git/config"
}

t_begin "a long non-ASCII finding leaves the ledger valid UTF-8"
led_fresh
text="a$("$MY_PY" -c "print('\u00e9' * 1500)")"
out="$(/bin/bash "$LA" --project "$LP" --disposition DO-NEXT --text "$text" 2>&1)"
assert_eq "added D-001" "$out" "output"
"$MY_PY" -c "open('$LP/DEFERRED-FINDINGS.md', encoding='utf-8').read()" 2> "$SBX/utf.err" || t_fail "the ledger is not valid UTF-8: $(tail -n 1 "$SBX/utf.err")"
text="$("$MY_PY" -c "print('\U0001F600' * 400)")"
out="$(/bin/bash "$LA" --project "$LP" --disposition DO-NEXT --text "$text" 2>&1)"
"$MY_PY" -c "open('$LP/DEFERRED-FINDINGS.md', encoding='utf-8').read()" 2> "$SBX/utf.err" || t_fail "4 byte characters: the ledger is not valid UTF-8"
t_end

t_begin "a ledger row carries the local date, not the UTC date"
for tz in Pacific/Kiritimati Etc/GMT+12; do
  led_fresh
  want="$(TZ=$tz date +%Y-%m-%d)"
  TZ=$tz /bin/bash "$LA" --project "$LP" --disposition ASK --text "x" > /dev/null 2>&1
  assert_contains "$(cat "$LP/DEFERRED-FINDINGS.md")" "| D-001 | $want |" "date in $tz"
done
t_end

t_begin "--ledger accepts only a .md file outside any .git folder"
led_fresh
before="$(cat "$LP/.git/config")"
for target in "$LP/.git/config" "$LP/.git/ledger.md" "$LP/.GIT/ledger.md" "$LP/notes.txt" "$LP/sub/.git/L.md"; do
  mkdir -p "$(dirname "$target")"
  out="$(/bin/bash "$LA" --project "$LP" --ledger "$target" --disposition ASK --text "x" 2>&1)"
  rc=$?
  assert_eq 3 "$rc" "exit code for $target"
done
assert_eq "$before" "$(cat "$LP/.git/config")" ".git/config is unchanged"
assert_no_file "$LP/notes.txt" "no file was created for the refused name"
out="$(/bin/bash "$LA" --project "$LP" --ledger "$LP/sub/TEAM-LEDGER.md" --disposition ASK --text "x" 2>&1)"
assert_eq "added D-001" "$out" "a LEDGER.md file in the project is accepted"
t_end

t_begin "several writers that find the same dead lock each add exactly 1 row"
led_fresh
mkdir "$LP/DEFERRED-FINDINGS.md.lock"
echo 99999999 > "$LP/DEFERRED-FINDINGS.md.lock/pid"
wpids=""
for i in 1 2 3 4 5 6 7 8; do
  /bin/bash "$LA" --project "$LP" --disposition DO-NEXT --text "writer $i" > "$SBX/led-$i.out" 2>&1 &
  wpids="$wpids $!"
done
for p in $wpids; do wait "$p"; done
assert_eq 8 "$(grep -c '^| D-[0-9]' "$LP/DEFERRED-FINDINGS.md")" "rows"
assert_eq 8 "$(grep '^| D-[0-9]' "$LP/DEFERRED-FINDINGS.md" | cut -d'|' -f2 | sort -u | wc -l | tr -d ' ')" "distinct ids"
assert_no_file "$LP/DEFERRED-FINDINGS.md.lock" "no lock left behind"
assert_no_file "$LP/DEFERRED-FINDINGS.md.lock.reclaim" "no election folder left behind"
t_end

# ---------------------------------------------------------------- hooklib list parsing

t_begin "a project_homes line written as [] starts no list"
got="$("$MY_PY" -I -B - "$HOOK_SRC" << 'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
import hooklib
print(hooklib.defaults_list(["project_homes: []", "- /a", "- /b"], "project_homes"))
print(hooklib.defaults_list(["project_homes:", "- /a", "- /b"], "project_homes"))
PYEOF
)"
assert_eq "[]
['/a', '/b']" "$got" "lists read"
t_end

# ---------------------------------------------------------------- text

t_begin "the README says what the update fetches and when the effort pins are offered"
readme="$(cat "$REPO/README.md")"
assert_not_contains "$readme" "Nothing. Conductor sends nothing anywhere." "the false claim"
assert_contains "$readme" "raw.githubusercontent.com/akaCT/conductor/main/install.sh" "the address the update fetches"
assert_not_contains "$readme" "does not change your settings." "the false Haiku sentence"
assert_contains "$readme" "leaves the Haiku setting alone"
t_end

t_begin "the doctrine tells each install only to use what it has, and the start contract reads the defaults file"
cdoc="$(cat "$REPO/payload/codex/doctrine.md")"
assert_not_contains "$cdoc" "conductor/defaults.md" "the Codex doctrine names a file a Codex-only install lacks"
doc="$(cat "$REPO/payload/claude/doctrine.md")"
start="$(printf '%s\n' "$doc" | sed -n '/^## Start contract/,/^## Dispatch contract/p')"
assert_contains "$start" "1. Load this doctrine and read \`conductor/defaults.md\` in your config folder."
assert_contains "$start" "6. With the full tier, keep a living checkpoint"
assert_contains "$start" "3. Read the active checkpoint, if there is one"
t_end

t_begin "the changelog lists the start-and-close contract under core, not under the full tier"
cl="$(cat "$REPO/CHANGELOG.md")"
assert_contains "$(printf '%s\n' "$cl" | grep '^- New in core:')" "start-and-close contract"
assert_not_contains "$(printf '%s\n' "$cl" | grep '^- New in the full tier:')" "start-and-close contract"
t_end

t_begin "a hook component dropped on a re-run loses its script and its settings entry (regression check)"
fresh claude
sandbox_fake_claude 2.1.296
CONDUCTOR_COMPONENTS=hook_pointer,hook_usage_split inst
PTY_INPUT="$(printf 'y\ny\nn\nn\n'; printf 'n\n%.0s' 1 2 3 4 5 6 7 8 9 10)" pty /bin/bash "$INST" --judge-rung=3
assert_eq 0 "$RC" "exit code"
assert_no_file "$CLAUDE_DIR/conductor/hooks/usage-split-check.py" "the dropped script"
assert_not_contains "$(cat "$CLAUDE_DIR/settings.json")" "usage-split-check.py" "the dropped hook's entry"
assert_contains "$(cat "$CLAUDE_DIR/settings.json")" "session-start-pointer.py" "the kept hook's entry"
t_end

t_begin "the doctor does not print an expected model for a provider it could not identify as if it were a name"
fresh claude
sandbox_fake_claude 2.1.296
CONDUCTOR_YES=1 inst --core
printf '{bad json' > "$CLAUDE_DIR/settings.json"
launcher doctor
assert_not_contains "$OUT" "unknown on unknown" "the old wording"
assert_not_contains "$OUT" "no table entry" "the old wording"
assert_contains "$OUT" "expected unknown (the provider could not be identified)"
t_end

t_summary
