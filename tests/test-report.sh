#!/bin/bash
# tests/test-report.sh: conductor report and default silence. The 150 canary
# strings, golden G-15, the network-denied run, the fake-opener run and the
# percent-encoding cases. Criteria: REQ-FBK-002.1 to .8, REQ-DATA-001.1 to .4.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/tests/lib/assert.sh"
. "$REPO/tests/lib/sandbox.sh"
sandbox_new
trap sandbox_cleanup EXIT
sandbox_guard
. "$REPO/tests/fixtures/doctor/lib.sh"
RFX="$REPO/tests/fixtures/report"
LIB="$REPO/payload/claude/conductor/lib"
export OPENER_LOG="$SBX/opener.log"

latest_report() { ls -t "$CLAUDE_DIR"/conductor/report-*.txt 2> /dev/null | head -n 1; }
report_args() { printf '%s\n' report --managed-settings "$SBX/managed-settings.json"; }

# run_report_pty ANSWER: conductor report on a pseudo terminal; OUT holds what it wrote
run_report_pty() {
  OUT="$(PTY_INPUT="$1" sandbox_pty /bin/bash "$CLAUDE_DIR/conductor/bin/conductor" report --managed-settings "$SBX/managed-settings.json")"
  RC=$?
}

run_report_notty() {
  OUT="$(sandbox_notty /bin/bash "$CLAUDE_DIR/conductor/bin/conductor" report --managed-settings "$SBX/managed-settings.json" < /dev/null 2>&1)"
  RC=$?
}

use_test_opener() {
  cp "$RFX/opener.sh" "$SBX/opener.sh"
  chmod 755 "$SBX/opener.sh"
  export CONDUCTOR_TEST_OPENER="$SBX/opener.sh" CONDUCTOR_TEST_SANDBOX="$SBX"
  rm -f "$OPENER_LOG" "$OPENER_LOG.url"
}

# seed a feedback-codes file and a debug trace
seed_trace() {
  printf 'H101\tfixture 1\nH102\tfixture 2\n' > "$CLAUDE_DIR/conductor/feedback-codes.txt"
  mkdir -p "$CLAUDE_DIR/conductor/logs"
  printf 'hook ran H101\nsomething H999 else\nH102 done\n' > "$CLAUDE_DIR/conductor/logs/trace.log"
}

# ---------------------------------------------------------------------------------
t_begin "REQ-FBK-002.3 the canary set is 150 strings, 25 in each of the 6 kinds"
out="$("$SBX_PY" -B "$RFX/canaries.py" 2>&1)"
assert_eq "150 canaries, 25 in each of 6 categories" "$out" "canary set"
t_end

t_begin "REQ-FBK-002.3 150 canaries seeded into every place user text sits leave 0 canaries and 0 path strings in the bundle"
out="$("$SBX_PY" -B "$RFX/canary_run.py" all --lib "$LIB" --work "$SBX/canary-work" 2>&1)"
rc=$?
assert_eq 0 "$rc" "canary run status"
assert_eq "canaries run: 150; seeded in the config: 150; bundles with a problem: 0" "$(printf '%s\n' "$out" | tail -n 1)" "canary summary"
t_end

t_begin "REQ-FBK-002.3 1 canary of each kind through the launcher: 0 canaries, 0 sandbox paths in the bundle, the screen and the file"
for idx in 0 25 50 75 100 125; do
  fresh_roots 2.1.296
  fx_launcher "$CLAUDE_DIR"
  token="$("$SBX_PY" -B "$RFX/canary_run.py" seed --claude "$CLAUDE_DIR" --bin "$SBX/bin" --index "$idx" --work "$SBX/proj")"
  canary="$("$SBX_PY" -B "$RFX/canary_run.py" show --index "$idx")"
  export FIXTURE_CANARY="$canary" ANTHROPIC_DEFAULT_OPUS_MODEL="$canary" CLAUDE_CODE_SUBAGENT_MODEL="$canary" ANTHROPIC_BASE_URL="$canary"
  run_conductor report --managed-settings "$SBX/managed-settings.json"
  unset FIXTURE_CANARY ANTHROPIC_DEFAULT_OPUS_MODEL CLAUDE_CODE_SUBAGENT_MODEL ANTHROPIC_BASE_URL
  assert_eq 0 "$RC" "exit status for canary $idx"
  file="$(latest_report)"
  assert_file "$file" "report file for canary $idx"
  shown="$(printf '%s\n' "$OUT" | grep -v '^Saved to: ')"
  for text in "$shown" "$(cat "$file")"; do
    case "$text" in *"$canary"*) t_fail "canary $idx is in the output" ;; esac
    case "$text" in *"$token"*) t_fail "token $token is in the output" ;; esac
    case "$text" in *"$SBX"*|*"$SBXR"*) t_fail "a sandbox path is in the output (canary $idx)" ;; esac
  done
  n="$(grep -c '[/\\~]' "$file")"
  assert_eq 0 "$n" "path characters in the report file for canary $idx"
done
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-FBK-002.3 golden G-15: a doctor output holding a home-folder path to the Claude folder gives {claude-dir}, per-component counts, 0 user names, 0 file names"
fresh_roots 2.1.296
fx_claude_install
out="$("$SBX_PY" -B - "$LIB" "$CLAUDE_DIR" "$SBX" <<'PYEOF'
import argparse, os, sys
lib, claude, sbx = sys.argv[1:4]
sys.path.insert(0, lib)
import doctor, report
args = argparse.Namespace(self_root="", facts=os.path.join(lib, "facts.json"), claude_dir=claude, codex_dir=os.path.join(sbx, "nocodex"),
                          agents_dir=os.path.join(sbx, "noagents"), managed_settings=os.path.join(sbx, "none.json"))
info = doctor.collect(args)
info["roots"] = {"claude": "/Users/alex/.claude", "codex": "/Users/alex/.codex", "agents": "/Users/alex/.agents"}
doctor_text = "\n".join(doctor.render(info))
bundle, dropped = report.make_bundle(info)
print("doctor holds the path: %s" % ("/Users/alex/.claude" in doctor_text))
print("doctor names a file: %s" % ("agents/builder.md" in doctor_text or "changed:" in doctor_text or "builder.md" in doctor_text))
print("bundle has token: %s" % ("roots: {claude-dir}" in bundle))
print("bundle has counts: %s" % ("- core: written 5, kept 0, modified 0" in bundle))
print("bundle has alex: %s" % ("alex" in bundle.lower()))
print("bundle has a file name: %s" % any(x in bundle for x in (".md", ".json", ".py", "agents/")))
print("bundle has a slash: %s" % ("/" in bundle))
PYEOF
)"
assert_contains "$out" "doctor holds the path: True"
assert_contains "$out" "bundle has token: True"
assert_contains "$out" "bundle has counts: True"
assert_contains "$out" "bundle has alex: False"
assert_contains "$out" "bundle has a file name: False"
assert_contains "$out" "bundle has a slash: False"
t_end

t_begin "REQ-FBK-002.8 free text in a model line, a raw model string and an odd version each become a value from the allowed set or other"
fresh_roots 2.1.296
fx_claude_install
fx_launcher "$CLAUDE_DIR"
printf -- '---\nname: builder\nmodel: my private nickname for the model v2\neffort: high\n---\nbody\n' > "$CLAUDE_DIR/agents/builder.md"
printf -- '---\nname: critic\nmodel: claude-sonnet-5-5-20260101\neffort: xhigh\n---\nbody\n' > "$CLAUDE_DIR/agents/critic.md"
printf -- '---\nname: scout\nmodel: arn:aws:bedrock:us-east-1:123456789012:inference-profile/x\neffort: high\n---\nbody\n' > "$CLAUDE_DIR/agents/scout.md"
printf '#!/bin/sh\necho "Claude Code build 9 secret-project"\n' > "$SBX/bin/claude"
printf '#!/bin/sh\necho "codex-cli 1.2"\n' > "$SBX/bin/codex"
export ANTHROPIC_BASE_URL="http://10.0.0.5:8080/v1"
run_conductor report --managed-settings "$SBX/managed-settings.json"
unset ANTHROPIC_BASE_URL
file="$(latest_report)"
bundle="$(cat "$file")"
assert_contains "$bundle" "- builder: other, unknown, agent file"
assert_contains "$bundle" "- critic: other, unknown, agent file"
assert_contains "$bundle" "- scout: other, unknown, agent file"
assert_contains "$bundle" "runtime: claude other; codex other; python3 "
assert_contains "$bundle" "provider: custom-base-url"
assert_contains "$bundle" "dropped (looked like a path or a key): seats"
assert_not_contains "$bundle" "nickname"
assert_not_contains "$bundle" "20260101"
assert_not_contains "$bundle" "10.0.0.5"
assert_not_contains "$bundle" "secret-project"
assert_not_contains "$bundle" "arn:"
t_end

t_begin "REQ-FBK-002.3 a clean install gives exactly the 10 bug fields and nothing else"
fresh_roots 2.1.296
fx_claude_install
seed_trace
run_conductor report --managed-settings "$SBX/managed-settings.json"
assert_eq 0 "$RC"
bundle="$(cat "$(latest_report)")"
pyver="$("$SBX_PY" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])')"
expected="Conductor bug report (made by conductor report)
version: 0.4.0
method: installer, full
runtime: claude 2.1.296; codex 0.46.0; python3 $pyver
provider: first-party
seats:
- conductor: opus, Opus 5.5, settings pin
- builder: sonnet, Sonnet 5.5, agent file
- scout: haiku, Haiku 5.5, agent file
- critic: sonnet, Sonnet 5.5, agent file
- architect: opus, Opus 5.5, agent file
- judge: sonnet, Sonnet 5.5, agent file
judge_rung: 3
hooks: pointer, nudge; hooks running: on
error_codes: H101, H102
roots: {claude-dir}
counts:
- core: written 5, kept 0, modified 0"
assert_eq "$expected" "$bundle" "the bundle"
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-FBK-002.1 REQ-FBK-002.7 REQ-FBK-002.4 REQ-DATA-001.3 a yes opens the address through the opener, 1 argument, no shell, 0 network calls"
fresh_roots 2.1.296
fx_claude_install
net_deny_setup
use_test_opener
run_report_pty $'y\n'
assert_eq 0 "$RC" "exit status"
assert_file "$OPENER_LOG" "the opener was called"
assert_contains "$(cat "$OPENER_LOG")" "argc=1" "the opener got 1 argument"
parent="$(basename "$(sed -n 's/^parent=//p' "$OPENER_LOG")")"
case "$parent" in
  sh|bash|zsh|dash|ksh|csh|tcsh|fish|-*) t_fail "the opener's parent is a shell: $parent" ;;
esac
case "$parent" in
  [Pp]ython*) ;;
  *) t_fail "the opener's parent should be python, got: $parent" ;;
esac
file="$(latest_report)"
assert_file "$file" "report file"
assert_eq 600 "$(file_mode_of "$file")" "report file mode"
desc="$("$SBX_PY" -B "$RFX/urlcheck.py" "$OPENER_LOG.url" "$file")"
assert_contains "$desc" "scheme=https"
assert_contains "$desc" "host=github.com"
assert_contains "$desc" "path=/akaCT/conductor/issues/new"
assert_contains "$desc" "keys=body,title"
assert_contains "$desc" "labels=no"
assert_contains "$desc" "body_equal=yes"
assert_contains "$desc" "title=Conductor bug report"
assert_contains "$desc" "raw_unsafe=no"
# the body in the address is the bundle shown on screen
bundle="$(cat "$file")"
assert_contains "$OUT" "$bundle" "the screen shows the whole bundle"
# the warning comes before the question
"$SBX_PY" -B - "$OUT" <<'PYEOF' || t_fail "the public-repository line does not come before the question"
import sys
out = sys.argv[1]
a = out.index("An issue on the public Conductor repository can be read by anyone.")
b = out.index("Open a prefilled issue? [y/N]")
sys.exit(0 if a < b else 1)
PYEOF
assert_eq "" "$(net_deny_calls)" "network calls recorded"
net_deny_teardown
t_end

t_begin "REQ-FBK-002.7 with no test opener, the opener found on PATH (open or xdg-open) is called with 1 argument"
fresh_roots 2.1.296
fx_claude_install
unset CONDUCTOR_TEST_OPENER CONDUCTOR_TEST_SANDBOX
rm -f "$OPENER_LOG" "$OPENER_LOG.url"
cp "$RFX/opener.sh" "$SBX/bin/open"
cp "$RFX/opener.sh" "$SBX/bin/xdg-open"
chmod 755 "$SBX/bin/open" "$SBX/bin/xdg-open"
run_report_pty $'y\n'
assert_eq 0 "$RC" "exit status"
assert_file "$OPENER_LOG" "the opener was called"
assert_contains "$(cat "$OPENER_LOG")" "argc=1"
assert_contains "$OUT" "Opened your browser on the prefilled issue."
t_end

t_begin "REQ-FBK-002.7 a test opener outside the sandbox, or without the sandbox named, is refused and the address is printed"
fresh_roots 2.1.296
fx_claude_install
use_test_opener
export CONDUCTOR_TEST_OPENER=/bin/echo
run_report_pty $'y\n'
assert_contains "$OUT" "Could not open a browser. This is the address:"
assert_contains "$OUT" "https://github.com/akaCT/conductor/issues/new?title="
assert_no_file "$OPENER_LOG"
use_test_opener
unset CONDUCTOR_TEST_SANDBOX
run_report_pty $'y\n'
assert_contains "$OUT" "Could not open a browser. This is the address:"
assert_no_file "$OPENER_LOG"
t_end

t_begin "REQ-FBK-002.2 REQ-DATA-001.3 an answer of no, or just Enter, opens 0 addresses, keeps the file, makes 0 network calls"
fresh_roots 2.1.296
fx_claude_install
net_deny_setup
use_test_opener
run_report_pty $'n\n'
assert_eq 0 "$RC" "exit status"
assert_no_file "$OPENER_LOG"
assert_contains "$OUT" "Nothing was opened."
file="$(latest_report)"
assert_file "$file" "report file kept"
assert_eq 600 "$(file_mode_of "$file")" "report file mode"
rm -f "$CLAUDE_DIR"/conductor/report-*.txt
run_report_pty $'\n'
assert_no_file "$OPENER_LOG"
assert_contains "$OUT" "Nothing was opened."
assert_file "$(latest_report)" "report file kept after Enter"
assert_eq "" "$(net_deny_calls)" "network calls recorded"
net_deny_teardown
t_end

t_begin "REQ-FBK-002.2 with no terminal 0 addresses are opened, the file is kept (mode 600), 0 network calls"
fresh_roots 2.1.296
fx_claude_install
net_deny_setup
use_test_opener
run_report_notty
assert_eq 0 "$RC" "exit status"
assert_no_file "$OPENER_LOG"
assert_contains "$OUT" "No terminal to ask on, so nothing was opened."
file="$(latest_report)"
assert_file "$file" "report file kept"
assert_eq 600 "$(file_mode_of "$file")" "report file mode"
assert_eq "" "$(net_deny_calls)" "network calls recorded"
net_deny_teardown
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-FBK-002.6 values holding & # % newline and a quote are percent-encoded; host, path, cap and labels hold"
out="$("$SBX_PY" -B - "$LIB" "$RFX" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
sys.path.insert(0, sys.argv[2])
import report, urlcheck
body = "a&b#c%d\ne\"f g=h+i?j\n" + "x" * 20
url = report.build_url('Title & "quote" # 100%', body, "akaCT/conductor")
out, decoded = urlcheck.describe(url)
print("host=%s path=%s scheme=%s" % (out["host"], out["path"], out["scheme"]))
print("keys=%s labels=%s fragment=%s amp=%s" % (out["keys"], out["labels"], out["fragment"], out["amp_count"]))
print("raw_unsafe=%s bad_escape=%s" % (out["raw_unsafe"], out["bad_escape"]))
print("roundtrip=%s" % (decoded == body and out["title"] == 'Title & "quote" # 100%'))
print("within_cap=%s" % (len(url) <= 4000))
PYEOF
)"
assert_contains "$out" "host=github.com path=/akaCT/conductor/issues/new scheme=https"
assert_contains "$out" "keys=body,title labels=no fragment=no amp=1"
assert_contains "$out" "raw_unsafe=no bad_escape=no"
assert_contains "$out" "roundtrip=True"
assert_contains "$out" "within_cap=True"
t_end

t_begin "REQ-FBK-002.1 above the 4,000-character cap the address holds the title and a short body, the file holds the whole bundle"
out="$("$SBX_PY" -B - "$LIB" "$RFX" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
sys.path.insert(0, sys.argv[2])
import report, urlcheck
big = "line of the bundle with some words\n" * 400
url = report.build_url(report.TITLE, big, "akaCT/conductor")
out, decoded = urlcheck.describe(url)
print("short_body=%s within_cap=%s title=%s" % (decoded == report.SHORT_BODY, len(url) <= 4000, out["title"]))
PYEOF
)"
assert_contains "$out" "short_body=True within_cap=True title=Conductor bug report"
fresh_roots 2.1.296
fx_claude_install
use_test_opener
code='import sys; sys.path.insert(0, sys.argv[1]); import report; report.MAX_URL = 300; sys.exit(report.main(sys.argv[2:]))'
OUT="$(PTY_INPUT=$'y\n' sandbox_pty "$SBX_PY" -B -c "$code" "$LIB" --facts "$LIB/facts.json" --claude-dir "$CLAUDE_DIR" --codex-dir "$SBX/nocodex" --agents-dir "$SBX/noagents" --managed-settings "$SBX/managed-settings.json")"
file="$(latest_report)"
assert_file "$file" "report file"
desc="$("$SBX_PY" -B "$RFX/urlcheck.py" "$OPENER_LOG.url" "$file")"
assert_contains "$desc" "body_equal=no"
assert_contains "$desc" "title=Conductor bug report"
assert_contains "$(cat "$file")" "Conductor bug report (made by conductor report)"
assert_contains "$(cat "$file")" "judge_rung: 3" "the file holds the whole bundle"
n="$(awk -F= '/^length=/ {print ($2 <= 4000) ? "ok" : "over"}' <<< "$desc")"
assert_eq ok "$n" "address length"
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-DATA-001.3 REQ-FBK-002.2 the network denied: the report run with and without a yes records 0 network calls"
fresh_roots 2.1.296
fx_claude_install
net_deny_setup
use_test_opener
"$SBX_PY" -c 'import socket; socket.create_connection(("127.0.0.1", 9))' > /dev/null 2>&1
assert_contains "$(net_deny_calls)" "python socket call" "the python hook works"
: > "$SBX/net-calls.log"
: > "$SBX/netdeny.log"
run_report_pty $'y\n'
run_report_pty $'n\n'
run_report_notty
run_conductor doctor --managed-settings "$SBX/managed-settings.json"
run_conductor version
run_conductor help
assert_eq "" "$(net_deny_calls)" "network calls recorded"
net_deny_teardown
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-FBK-002.5 the install summary of a real install names conductor report and says nothing is collected"
fresh_roots 2.1.296
mkdir -p "$CLAUDE_DIR"
OUT="$(CONDUCTOR_YES=1 sandbox_notty /bin/bash "$REPO/install.sh" --core < /dev/null 2>&1)"
RC=$?
assert_eq 0 "$RC" "install exit status"
assert_contains "$OUT" "Nothing is collected or sent. To report a problem, run:"
assert_contains "$OUT" "      conductor report"
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-DATA-001.2 the only outbound-call code in the launcher, hooks, tools and installer is the update fetch"
files=""
for f in "$REPO"/payload/claude/conductor/bin/* "$REPO"/payload/claude/conductor/lib/*.py "$REPO"/payload/claude/conductor/hooks/*.py \
  "$REPO"/installer/src/*.sh "$REPO"/tools/*.py "$REPO"/tools/*.sh; do
  [ -f "$f" ] && files="$files $f"
done
# shellcheck disable=SC2086
hits="$("$SBX_PY" -B "$RFX/netscan.py" $files)"
# allowed: the update fetch in the launcher
other="$(printf '%s\n' "$hits" | grep -v '^$' | grep -v "payload/claude/conductor/bin/conductor:[0-9]*:out=\"\$(curl -q --proto" || true)"
assert_eq "" "$other" "outbound-call code other than the update fetch"
fetch="$(printf '%s\n' "$hits" | grep -c "payload/claude/conductor/bin/conductor:[0-9]*:out=\"\$(curl -q --proto")"
assert_eq 1 "$fetch" "the scan finds the update fetch (positive control)"
mkdir -p "$SBX/scan"
printf '#!/usr/bin/env bash\nsay hello\nwget http://example.invalid/x\n' > "$SBX/scan/a.sh"
printf 'import urllib.request\nimport json\n' > "$SBX/scan/b.py"
printf '#!/usr/bin/env bash\ncat <<EOF\ncurl in help text\nEOF\n# curl in a comment\n' > "$SBX/scan/c.sh"
planted="$("$SBX_PY" -B "$RFX/netscan.py" "$SBX/scan/a.sh" "$SBX/scan/b.py" "$SBX/scan/c.sh" | wc -l | tr -d ' ')"
assert_eq 2 "$planted" "the scan finds planted calls and skips help text and comments (negative control)"
t_end

t_begin "REQ-DATA-001.4 the doctrine, skills, runbooks, hooks and doctor never invoke update or update --check"
hits="$(grep -rnE 'conductor update|update --check' "$REPO/payload/claude/doctrine.md" "$REPO/payload/claude/skills" \
  "$REPO/payload/claude/conductor/runbooks" "$REPO/payload/claude/conductor/hooks" "$REPO/payload/claude/conductor/templates" \
  "$REPO/payload/claude/conductor/lib/doctor.py" "$REPO/payload/claude/conductor/lib/report.py" "$REPO/payload/codex" 2> /dev/null || true)"
assert_eq "" "$hits" "invocations of update"
launcher_hits="$(grep -c 'conductor update' "$REPO/payload/claude/conductor/bin/conductor")"
if [ "$launcher_hits" -lt 1 ]; then t_fail "positive control: the launcher itself names conductor update"; fi
t_end

t_begin "REQ-DATA-001.1 a default run of the launcher, doctor and report with the network denied attempts 0 calls"
fresh_roots 2.1.296
fx_claude_install
net_deny_setup
run_conductor doctor --managed-settings "$SBX/managed-settings.json"
assert_eq 0 "$RC"
run_conductor report --managed-settings "$SBX/managed-settings.json"
assert_eq 0 "$RC"
assert_eq "" "$(net_deny_calls)" "network calls recorded"
net_deny_teardown
t_end

t_begin "REQ-DATA-001.1 a default full install with the network denied attempts 0 calls"
fresh_roots 2.1.296
mkdir -p "$CLAUDE_DIR"
net_deny_setup
OUT="$(PTY_INPUT=$'y\ny\ny\ny\ny\ny\ny\ny\ny\ny\ny\ny\n' sandbox_pty /bin/bash "$REPO/install.sh" --full)"
RC=$?
assert_eq 0 "$RC" "install exit status"
assert_file "$CLAUDE_DIR/conductor/hooks/session-start-pointer.py" "the full tier is installed"
assert_eq "" "$(net_deny_calls)" "network calls recorded"
t_end

t_begin "REQ-DATA-001.1 a session's 5 hooks with the network denied attempt 0 calls"
mkdir -p "$SBX/proj"
env_for() { # EVENT: a hook envelope for the fixture project
  printf '{"hook_event_name": "%s", "session_id": "sess-net", "cwd": "%s", "transcript_path": "%s/transcript.jsonl", "tool_name": "Agent", "tool_input": {"description": "d", "prompt": "p", "subagent_type": "builder"}, "prompt": "hello", "source": "startup"}' "$1" "$SBX/proj" "$SBX/proj"
}
printf '{"type": "user", "message": {"role": "user", "content": "hello"}}\n' > "$SBX/proj/transcript.jsonl"
for pair in session-start-pointer:SessionStart checkpoint-nudge:UserPromptSubmit usage-split-check:Stop project-home-check:SessionStart contract-check:PreToolUse; do
  hook="${pair%%:*}"
  ev="${pair#*:}"
  env_for "$ev" > "$SBX/env.json"
  hout="$("$SBX_PY" -B "$CLAUDE_DIR/conductor/hooks/$hook.py" < "$SBX/env.json" 2>&1)"
  hrc=$?
  assert_eq 0 "$hrc" "$hook exit status: $hout"
done
assert_eq "" "$(net_deny_calls)" "network calls recorded"
net_deny_teardown
t_end

t_summary
