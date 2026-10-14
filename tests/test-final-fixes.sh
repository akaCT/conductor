#!/bin/bash
# tests/test-final-fixes.sh: the late review fixes, 1 test per fix. Each test proves an exact
# expected value, not only that 2 places agree, and each failed before its fix.
#
# Everything runs in the sandbox from tests/lib/sandbox.sh through tests/lib/install-common.sh;
# nothing reads or writes a real config folder. The update tests use the fixture host in
# tests/fixtures/update on 127.0.0.1.
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
LIBD="$REPO/payload/claude/conductor/lib"
FXH="$HERE/hooks/fixtures"
UFX="$HERE/fixtures/update"

# launcher ARGS...: the installed launcher of CLAUDE_DIR; leaves OUT and RC.
launcher() {
  OUT="$(NO_COLOR=1 /bin/bash "$CLAUDE_DIR/conductor/bin/conductor" "$@" 2>&1 < /dev/null)"
  RC=$?
}

# doctor_with [VAR=value ...]: the installed doctor with those variables set; leaves OUT and RC.
doctor_with() {
  OUT="$(for a in "$@"; do export "$a"; done; NO_COLOR=1 /bin/bash "$CLAUDE_DIR/conductor/bin/conductor" doctor --managed-settings "$SBX/managed-settings.json" 2>&1 < /dev/null)"
  RC=$?
}

wired_cmd() { # $1 = hook file name -> the command settings.json wires for it
  "$MY_PY" - "$CLAUDE_DIR/settings.json" "$1" << 'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
for groups in d.get("hooks", {}).values():
    for g in groups:
        for h in g.get("hooks", []):
            if h.get("command", "").endswith("/" + sys.argv[2] + '"'):
                print(h["command"])
PYEOF
}

# =============================================================================
# the summary's list of local data names conductor/state
# =============================================================================
t_begin "the summary lists conductor/state when a hook is wired, and not when none is"
fresh claude
CONDUCTOR_COMPONENTS=hook_pointer inst
assert_eq 0 "$RC" "install exit code"
assert_contains "$OUT" "      $CLAUDE_DIR/conductor/state" "the state folder is listed with a hook wired"
fresh claude
inst
assert_eq 0 "$RC" "install exit code with no hook"
assert_not_contains "$OUT" "$CLAUDE_DIR/conductor/state" "no hook wired, no state folder"
t_end

# =============================================================================
# the kill switch lines say what is true
# =============================================================================
t_begin "the summary says hooks run unless CONDUCTOR_HOOKS=off is set in Claude Code's environment, and the doctor tells a set value that is not off from off and from not set"
fresh claude
CONDUCTOR_COMPONENTS=hook_pointer inst
assert_contains "$OUT" "  Kill switch:   hooks run unless CONDUCTOR_HOOKS=off is set in Claude Code's" "summary line 1"
assert_contains "$OUT" "                 environment" "summary line 2"
assert_not_contains "$OUT" "stops every hook" "the old claim"
assert_not_contains "$OUT" "(now:" "a state taken from the installer's own environment"
assert_eq "" "$(printf '%s\n' "$OUT" | grep 'Kill switch' | awk 'length($0) > 79')" "kill switch line under 80 columns"
CONDUCTOR_HOOKS=off CONDUCTOR_COMPONENTS=hook_pointer inst
assert_not_contains "$OUT" "(now:" "the installer's own CONDUCTOR_HOOKS is not reported as Claude Code's"
sandbox_fake_claude 2.1.296
doctor_with
assert_contains "$OUT" "  Kill switch CONDUCTOR_HOOKS: not set (wired hooks run)" "not set"
for v in off OFF 0 false; do
  doctor_with "CONDUCTOR_HOOKS=$v"
  assert_contains "$OUT" "  Kill switch CONDUCTOR_HOOKS: off (every Conductor hook stays silent)" "off value [$v]"
done
for v in no 1 on yes; do
  doctor_with "CONDUCTOR_HOOKS=$v"
  assert_contains "$OUT" "  Kill switch CONDUCTOR_HOOKS: set, hooks still run" "set to [$v]: not an off value"
  assert_not_contains "$OUT" "not set (wired hooks run)" "set to [$v] must not read as not set"
done
t_end

# =============================================================================
# the public launcher has no build switch
# =============================================================================
t_begin "the public launcher and the installer hold no *_BUILD constant and no never-fetch branch"
assert_eq 0 "$(grep -cE '[A-Z_]_BUILD([^A-Za-z0-9_]|$)' "$REPO/payload/claude/conductor/bin/conductor" | tr -d ' ')" "a *_BUILD constant in the launcher"
assert_eq 0 "$(grep -cE '[A-Z_]_BUILD([^A-Za-z0-9_]|$)' "$REPO/install.sh" | tr -d ' ')" "a *_BUILD constant in the installer"
assert_eq 0 "$(grep -ciE 'never[ -]fetch|build switch' "$REPO/payload/claude/conductor/bin/conductor" | tr -d ' ')" "a never-fetch branch in the launcher"
t_end

# =============================================================================
# the usage-split check
# =============================================================================
stop_event() { # $1 = closing text, $2 = transcript path: a Stop event
  "$MY_PY" - "$1" "$2" "$SBX/w" << 'PYEOF'
import json, sys
print(json.dumps({"hook_event_name": "Stop", "session_id": "s-r", "cwd": sys.argv[3],
                  "transcript_path": sys.argv[2], "last_assistant_message": sys.argv[1]}))
PYEOF
}
run_installed_hook() { # NAME EVENTJSON: runs the installed hook the way its command does
  OUT="$(printf '%s' "$2" | "$MY_PY" -I -B "$CLAUDE_DIR/conductor/hooks/$1.py" 2> /dev/null)"
  RC=$?
}

t_begin "the usage-split check accepts a numbered line and a heading followed by the split, and says nothing after a turn of scouts only"
fresh claude
CONDUCTOR_COMPONENTS=hook_usage_split inst
mkdir -p "$SBX/w"
"$MY_PY" -B "$FXH/gen-transcript.py" "$FXH/transcripts/dispatch2.spec.json" "$SBX/tx2.jsonl"
body='conductor on opus; 2 workers on sonnet.'
for line in "1. Usage split: $body" "2) Usage split: $body" "10. **Usage split:** $body" "- 3. Usage split: $body"; do
  run_installed_hook usage-split-check "$(stop_event "All done.
$line" "$SBX/tx2.jsonl")"
  assert_eq "" "$OUT" "the hook accepts: $line"
done
for head in "## Usage split" "### Usage split:" "**Usage split**" "1. Usage split"; do
  run_installed_hook usage-split-check "$(stop_event "All done.
$head
$body" "$SBX/tx2.jsonl")"
  assert_eq "" "$OUT" "the hook accepts a heading [$head] with the split on the next line"
done
run_installed_hook usage-split-check "$(stop_event "All done.
## Usage split

$body" "$SBX/tx2.jsonl")"
assert_eq "" "$OUT" "a blank line between the heading and the split is accepted"
run_installed_hook usage-split-check "$(stop_event "All done.
## Usage split
nothing useful here." "$SBX/tx2.jsonl")"
assert_contains "$OUT" "No usage-split line was found" "a heading with no model name under it"
for line in "Usage splitter: $body" "I wrote the Usage split: here, mid-line $body" "All done."; do
  run_installed_hook usage-split-check "$(stop_event "Done.
$line" "$SBX/tx2.jsonl")"
  assert_contains "$OUT" "No usage-split line was found" "the hook still asks for: $line"
done
# a turn whose only dispatches are scouts
cat > "$SBX/scouts.spec.json" << 'JSONEOF'
[{"type":"user","ago":"10m","text":"look around"},
 {"type":"assistant","ago":"5m","tools":[{"name":"Agent","input":{"subagent_type":"scout","prompt":"list the files"}},{"name":"Agent","input":{"subagent_type":"scout","prompt":"count the tests"}}]},
 {"type":"tool_result","ago":"4m"},
 {"type":"assistant","ago":"3m","text":"All done."}]
JSONEOF
"$MY_PY" -B "$FXH/gen-transcript.py" "$SBX/scouts.spec.json" "$SBX/tx-scouts.jsonl"
run_installed_hook usage-split-check "$(stop_event "All done." "$SBX/tx-scouts.jsonl")"
assert_eq "" "$OUT" "2 scout dispatches and no split line: no note"
cat > "$SBX/mixed.spec.json" << 'JSONEOF'
[{"type":"user","ago":"10m","text":"build it"},
 {"type":"assistant","ago":"5m","tools":[{"name":"Agent","input":{"subagent_type":"scout","prompt":"list the files"}},{"name":"Agent","input":{"model":"sonnet","prompt":"build the thing"}}]},
 {"type":"tool_result","ago":"4m"},
 {"type":"assistant","ago":"3m","text":"All done."}]
JSONEOF
"$MY_PY" -B "$FXH/gen-transcript.py" "$SBX/mixed.spec.json" "$SBX/tx-mixed.jsonl"
run_installed_hook usage-split-check "$(stop_event "All done." "$SBX/tx-mixed.jsonl")"
assert_contains "$OUT" "No usage-split line was found" "a scout and a builder dispatch together still need the line"
run_installed_hook usage-split-check "$(stop_event "All done." "$SBX/tx2.jsonl")"
assert_contains "$OUT" "No usage-split line was found" "positive control: 2 sonnet dispatches and no line"
t_end

# =============================================================================
# prune removes only Conductor's own guarded entries
# =============================================================================
hook_commands() { # $1 = event -> the commands wired for it, 1 per line
  "$MY_PY" -c '
import json, sys
d = json.load(open(sys.argv[1]))
print("\n".join(h["command"] for g in d.get("hooks", {}).get(sys.argv[2], []) for h in g["hooks"]))' "$CLAUDE_DIR/settings.json" "$1"
}

t_begin "a re-run removes a Conductor entry whose script is gone (current and earlier guard forms), names it, and never removes a hook of your own, whatever it names under conductor"
fresh claude
CONDUCTOR_COMPONENTS=hook_pointer inst
assert_eq 0 "$RC" "install exit code"
"$MY_PY" - "$CLAUDE_DIR" "$MY_PY" << 'PYEOF'
import json, os, sys
root, py = sys.argv[1], sys.argv[2]
sp = os.path.join(root, "settings.json")
d = json.load(open(sp))
existing = os.path.join(root, "conductor", "mine-existing.sh")
open(existing, "w").write("#!/bin/sh\nexit 0\n")
user = [
    '/bin/sh "%s"' % existing,
    '/bin/sh "%s/conductor/mine-future.sh"' % root,
    'ls "%s/conductor/backups" > /dev/null; echo mine' % root,
    'tail -n 1 "%s/conductor/logs/hook-trace.log"' % root,
    '[ ! -f "%s/conductor/mine-guard.sh" ] || /bin/sh "%s/conductor/mine-guard.sh"' % (root, root),
    'test -f "%s/conductor/mine-test.sh" && /bin/sh "%s/conductor/mine-test.sh"' % (root, root),
    '"%s" "%s/conductor/hooks/hooklib.py" --mine' % (py, root),
]
ours = [
    '[ ! -x "%s" ] || [ ! -f "%s/conductor/hooks/gone-new.py" ] || [ ! -r "%s/conductor/hooks/gone-new.py" ] || "%s" -I -B "%s/conductor/hooks/gone-new.py"' % (py, root, root, py, root),
    '[ ! -f "%s/conductor/hooks/gone-old.py" ] || [ ! -r "%s/conductor/hooks/gone-old.py" ] || "%s" -I -B "%s/conductor/hooks/gone-old.py"' % (root, root, py, root),
]
for c in user + ours:
    d.setdefault("hooks", {}).setdefault("Stop", []).append({"matcher": "", "hooks": [{"type": "command", "command": c, "timeout": 10}]})
json.dump(d, open(sp, "w"), indent=2)
PYEOF
CONDUCTOR_COMPONENTS=hook_pointer inst
assert_eq 0 "$RC" "re-run exit code"
cmds="$(hook_commands Stop)"
assert_contains "$cmds" "mine-existing.sh" "a hook of yours naming an existing file under conductor"
assert_contains "$cmds" "mine-future.sh" "a hook of yours naming a file that does not exist yet"
assert_contains "$cmds" "conductor/backups" "a hook of yours naming an existing folder under conductor"
assert_contains "$cmds" "hook-trace.log" "a hook of yours that reads a log under conductor"
assert_contains "$cmds" "mine-guard.sh" "a hook of yours in a guard form of its own"
assert_contains "$cmds" "mine-test.sh" "a hook of yours using test -f"
assert_contains "$cmds" "hooklib.py\" --mine" "a hook of yours that runs a script under conductor/hooks without Conductor's guard"
assert_not_contains "$cmds" "gone-new.py" "Conductor's dangling entry, current form"
assert_not_contains "$cmds" "gone-old.py" "Conductor's dangling entry, earlier form"
assert_eq 2 "$(printf '%s\n' "$OUT" | grep -c 'removed hook entry:')" "each removal is named, 2 entries"
assert_contains "$(printf '%s' "$OUT" | tr '\n' ' ' | tr -s ' ')" "gone-new.py" "the removal names the command"
t_end

# =============================================================================
# ledger-append writes only a ledger file
# =============================================================================
t_begin "ledger-append --ledger accepts only a file named *LEDGER.md or *FINDINGS.md outside .git and .claude, and the default ledger"
LP="$SBX/ledger-project"
rm -rf "$LP"
mkdir -p "$LP/.git" "$LP/.claude/agents" "$LP/sub"
printf 'rules\n' > "$LP/CLAUDE.md"
before_claude="$(cat "$LP/CLAUDE.md")"
for target in "$LP/CLAUDE.md" "$LP/.claude/agents/x.md" "$LP/notes.md" "$LP/ledger.md" "$LP/LEDGER.md.txt" "$LP/.git/X-LEDGER.md" "$LP/sub/.git/X-LEDGER.md"; do
  mkdir -p "$(dirname "$target")"
  out="$(/bin/bash "$LA" --project "$LP" --ledger "$target" --disposition ASK --text "x" 2>&1)"
  rc=$?
  assert_eq 3 "$rc" "exit code for $target"
  case "$target" in */.git/*) ;; *) assert_contains "$out" "LEDGER.md or FINDINGS.md" "the refusal for $target says which names are accepted" ;; esac
done
assert_eq "$before_claude" "$(cat "$LP/CLAUDE.md")" "CLAUDE.md is unchanged"
assert_no_file "$LP/.claude/agents/x.md" "no file was created in the agents folder"
assert_no_file "$LP/notes.md" "no file was created for notes.md"
for target in "$LP/X-LEDGER.md" "$LP/LEDGER.md" "$LP/DEFERRED-FINDINGS.md" "$LP/sub/TEAM-LEDGER.md"; do
  rm -f "$target"
  out="$(/bin/bash "$LA" --project "$LP" --ledger "$target" --disposition ASK --text "x" 2>&1)"
  assert_eq "added D-001" "$out" "accepted: $target"
done
rm -f "$LP/DEFERRED-FINDINGS.md"
out="$(/bin/bash "$LA" --project "$LP" --disposition ASK --text "x" 2>&1)"
assert_eq "added D-001" "$out" "the default ledger"
t_end

# =============================================================================
# an unreadable hook script exits 0
# =============================================================================
t_begin "each wired hook command exits 0 and prints nothing when its script is there but not readable"
if [ "$(id -u)" = "0" ]; then
  echo "  note: running as root, file modes do not stop a read; this check is not provable here"
else
  fresh claude
  CONDUCTOR_COMPONENTS=hook_pointer,hook_contract inst
  assert_eq 0 "$RC" "install exit code"
  for name in session-start-pointer.py contract-check.py; do
    script="$CLAUDE_DIR/conductor/hooks/$name"
    cmd="$(wired_cmd "$name" | head -n 1)"
    if [ -z "$cmd" ]; then t_fail "no command is wired for $name"; continue; fi
    assert_contains "$cmd" "[ ! -r \"$script\" ]" "the guard tests -r for $name"
    cp "$script" "$SBX/$name.keep"
    printf 'print("ran")\n' > "$script"
    chmod 644 "$script"
    out="$(printf '{}' | /bin/sh -c "$cmd" 2> "$SBX/hook.err")"
    assert_eq "ran" "$out" "positive control: a readable $name runs"
    chmod 000 "$script"
    out="$(printf '{}' | /bin/sh -c "$cmd" 2> "$SBX/hook.err")"
    rc=$?
    assert_eq 0 "$rc" "exit code with $name unreadable"
    assert_eq "" "$out" "stdout with $name unreadable"
    assert_eq "" "$(cat "$SBX/hook.err")" "stderr with $name unreadable"
    chmod 644 "$script"
    cp "$SBX/$name.keep" "$script"
  done
fi
t_end

# =============================================================================
# tag characters and U+061C are removed by all 3 sanitizers
# =============================================================================
t_begin "tag characters and U+061C are removed by the doctor, the installer and ledger-append, and the 3 agree on every code point tried"
CODEPOINTS="061B 061C 061D 200B 200F 2028 202E 2060 2069 FEFF E0000 E0001 E0041 E007F E0080 00E9 2014 1F600"
want="$("$MY_PY" -c '
import sys
gone = set(range(0xE0000, 0xE0080)) | {0x061C, 0xFEFF} | set(range(0x200B, 0x2010)) | set(range(0x2028, 0x202F)) | set(range(0x2060, 0x206A))
print(" ".join("x" if int(c, 16) in gone else "k" for c in sys.argv[1:]))' $CODEPOINTS)"
got_doctor="$("$MY_PY" -I -B - "$LIBD" $CODEPOINTS << 'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
import doctor
out = []
for c in sys.argv[2:]:
    ch = chr(int(c, 16))
    out.append("x" if doctor.clean("a" + ch + "b") == "ab" else "k")
print(" ".join(out))
PYEOF
)"
got_installer=""
for c in $CODEPOINTS; do
  r="$( . "$LIB"; "$MY_PY" -c 'import sys; sys.stdout.write("a" + chr(int(sys.argv[1], 16)) + "b\n")' "$c" | sanitize_text )"
  if [ "$r" = "ab" ]; then got_installer="$got_installer x"; else got_installer="$got_installer k"; fi
done
got_installer="${got_installer# }"
LP="$SBX/ledger-rc211"
rm -rf "$LP"
mkdir -p "$LP"
got_ledger=""
for c in $CODEPOINTS; do
  rm -f "$LP/DEFERRED-FINDINGS.md"
  text="$("$MY_PY" -c 'import sys; sys.stdout.write("a" + chr(int(sys.argv[1], 16)) + "b")' "$c")"
  /bin/bash "$LA" --project "$LP" --disposition ASK --text "$text" > /dev/null 2>&1
  row="$(grep '^| D-001' "$LP/DEFERRED-FINDINGS.md")"
  if printf '%s' "$row" | grep -q '| ab |'; then got_ledger="$got_ledger x"; else got_ledger="$got_ledger k"; fi
done
got_ledger="${got_ledger# }"
assert_eq "$want" "$got_doctor" "the doctor's filter"
assert_eq "$want" "$got_installer" "the installer's filter"
assert_eq "$want" "$got_ledger" "ledger-append's filter"
t_end

# =============================================================================
# an update redirect is followed only when its path equals the update path
# =============================================================================
WWW="$SBX/www"
UTMP="$SBX/utmp"
mkdir -p "$WWW" "$UTMP"
cp "$REPO/install.sh" "$WWW/install.sh"
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
start_server plain
PLAIN_PORT="$(cat "$SBX/plain.port")"

t_begin "a redirect to another path on the same host is refused with a plain message and never requested; a redirect to the same path is followed"
fresh claude
sandbox_fake_claude 2.1.296
CONDUCTOR_YES=1 inst --core
assert_eq 0 "$RC" "install exit code"
rm -rf "$UTMP"
mkdir -p "$UTMP"
export TMPDIR="$UTMP"
: > "$SBX/plain.log"
export CONDUCTOR_TEST_UPDATE_URL="http://127.0.0.1:$PLAIN_PORT/install.sh"
launcher update --check
assert_eq 0 "$RC" "positive control: the direct address answers"
assert_contains "$OUT" "Conductor 0.4.0 is up to date." "positive control: the fetched installer is read"
export CONDUCTOR_TEST_UPDATE_URL="http://127.0.0.1:$PLAIN_PORT/redir-same"
: > "$SBX/plain.log"
launcher update --check
assert_eq 0 "$RC" "a redirect to the update path itself is followed"
assert_contains "$OUT" "Conductor 0.4.0 is up to date." "the redirect to the same path reaches the installer"
export CONDUCTOR_TEST_UPDATE_URL="http://127.0.0.1:$PLAIN_PORT/install.sh"
: > "$SBX/plain.log"
OUT="$(NO_COLOR=1 CONDUCTOR_TEST_UPDATE_URL="http://127.0.0.1:$PLAIN_PORT/redir-path" /bin/bash "$CLAUDE_DIR/conductor/bin/conductor" update --check 2>&1 < /dev/null)"
RC=$?
assert_eq 1 "$RC" "a redirect to another path: exit code"
assert_contains "$(printf '%s' "$OUT" | tr '\n' ' ' | tr -s ' ')" "Update refused: the fetch was redirected to another path on the same host. Nothing was changed." "the plain message"
assert_eq 1 "$(grep -c '^GET ' "$SBX/plain.log")" "requests the fixture host saw (only the first)"
assert_eq 0 "$(grep -c '^GET /other/' "$SBX/plain.log")" "requests for the other path"
unset CONDUCTOR_TEST_UPDATE_URL TMPDIR
t_end

t_summary
