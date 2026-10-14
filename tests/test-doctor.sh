#!/bin/bash
# tests/test-doctor.sh: the doctor. The 9 fixture configs (Claude install,
# Codex install, judge file deleted, Bedrock, top-level effort only, unparseable settings,
# 0.3.0 install, python3 missing, no install). Criteria: REQ-DIAG-001.1 to .9, REQ-UI-001.2
# and .3 for the doctor.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/tests/lib/assert.sh"
. "$REPO/tests/lib/sandbox.sh"
sandbox_new
trap sandbox_cleanup EXIT
sandbox_guard
. "$REPO/tests/fixtures/doctor/lib.sh"
LAST_LINE="This output holds local paths. To share a problem, run: conductor report"
DOCTOR_PY="$REPO/payload/claude/conductor/lib/doctor.py"
FACTS="$REPO/payload/claude/conductor/lib/facts.json"
# A key-shaped fixture value (not a real key).
FIXTURE_KEY="sk-ant-fixture0000000000000000000000000000"

last_line() { printf '%s\n' "$1" | tail -n 1; }
# flat TEXT: the text on 1 line, so a warning wrapped at 78 columns can be matched whole
flat() { printf '%s' "$1" | tr '\n' ' ' | tr -s ' '; }

# ---------------------------------------------------------------------------------
t_begin "REQ-DIAG-001.1 fixture 1: a Claude install prints the expected lines, model lines say expected"
fresh_roots 2.1.296
fx_claude_install
run_doctor
assert_eq 0 "$RC" "exit status"
assert_contains "$OUT" "  Version: 0.4.0"
assert_contains "$OUT" "  Method: installer"
assert_contains "$OUT" "  Launcher: $SBXR/home/.claude/conductor/bin/conductor"
assert_contains "$OUT" "  Claude Code: 2.1.296"
assert_contains "$OUT" "    Opus 5.5 effort pin needs 2.1.280: met"
assert_contains "$OUT" "    Sonnet 5.5 effort pin needs 2.1.284: met"
assert_contains "$OUT" "    Haiku 5.5 needs 2.1.293: met"
assert_contains "$OUT" "  Provider: first-party"
for seat in conductor builder scout critic architect judge; do
  n="$(printf '%s\n' "$OUT" | grep -c "^  $seat: .*, expected [A-Z]")"
  assert_eq 1 "$n" "seat line for $seat"
done
assert_contains "$OUT" "  scout: haiku, expected Haiku 5.5"
assert_contains "$OUT" "    effort xhigh (agent file)"
assert_contains "$OUT" "    effort high (settings pin)"
assert_contains "$OUT" "  Rung: 3"
assert_contains "$OUT" "  Judge gates: available"
assert_contains "$OUT" "  Wired: pointer, nudge"
assert_contains "$OUT" "  Kill switch CONDUCTOR_HOOKS: not set (wired hooks run)"
assert_contains "$OUT" "  Duplicate installs: none"
assert_eq "$LAST_LINE" "$(last_line "$OUT")" "last line"
# no model line without the word expected
n="$(printf '%s\n' "$OUT" | grep -E '^  (conductor|builder|scout|critic|architect|judge): ' | grep -vc 'expected')"
assert_eq 0 "$n" "seat lines without expected"
t_end

t_begin "REQ-DIAG-001.1 a Claude Code below the floors says so and expects an older model"
fresh_roots 2.1.270
fx_claude_install
run_doctor
assert_eq 0 "$RC" "exit status"
assert_contains "$OUT" "    Opus 5.5 effort pin needs 2.1.280: not met"
assert_contains "$OUT" "  builder: sonnet, expected an older model (Claude Code below 2.1.284)"
t_end

t_begin "REQ-DIAG-001.1 no claude on PATH: version not found, floors unknown, exit 0"
fresh_roots 2.1.296
fx_claude_install
printf '#!/bin/sh\necho "not a version"\n' > "$SBX/bin/claude"
chmod 755 "$SBX/bin/claude"
run_doctor
assert_eq 0 "$RC" "exit status"
assert_contains "$OUT" "  Claude Code: version not found"
assert_contains "$OUT" "needs 2.1.280: unknown"
assert_contains "$OUT" "expected Opus 5.5 if Claude Code is 2.1.280 or later"
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-DIAG-001.9 fixture 2: a Codex install prints each agent as not pinned or its verified value"
fresh_roots 2.1.296
fx_codex_install
out="$("$SBX_PY" "$DOCTOR_PY" --facts "$FACTS" --claude-dir "$SBX/none" --codex-dir "$CODEX_DIR" --agents-dir "$AGENTS_SKILLS_DIR" --managed-settings "$SBX/managed.json" 2>&1 < /dev/null)"
assert_eq 0 "$?" "exit status"
assert_contains "$out" "Codex agents"
for a in builder scout critic architect; do
  assert_contains "$out" "  $a: effort not pinned"
done
assert_contains "$out" "  Claude folder: not found"
assert_eq "$LAST_LINE" "$(last_line "$out")" "last line"
fx_codex_install builder-with-effort.toml
out="$("$SBX_PY" "$DOCTOR_PY" --facts "$FACTS" --claude-dir "$SBX/none" --codex-dir "$CODEX_DIR" --agents-dir "$AGENTS_SKILLS_DIR" --managed-settings "$SBX/managed.json" 2>&1 < /dev/null)"
assert_contains "$out" "  builder: effort high (found in the agent file)"
assert_contains "$out" "  scout: effort not pinned"
t_end

t_begin "REQ-DIAG-001.9 a Codex install beside a Claude install reaches the same lines through the launcher"
fresh_roots 2.1.296
fx_claude_install
fx_codex_install
printf 'user text\n' > "$CODEX_DIR/AGENTS.override.md"
run_doctor
assert_eq 0 "$RC" "exit status"
assert_contains "$OUT" "  builder: effort not pinned"
assert_contains "$(flat "$OUT")" "AGENTS.override.md in the Codex folder is not empty"
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-DIAG-001.8 fixture 3: a deleted judge agent file reports the judge gates unavailable"
fresh_roots 2.1.296
fx_claude_install
rm -f "$CLAUDE_DIR/agents/judge.md"
run_doctor
assert_eq 0 "$RC" "warnings only exit 0"
assert_contains "$OUT" "  Judge file: missing"
assert_contains "$OUT" "  Judge gates: unavailable (the judge file is missing)"
assert_contains "$OUT" "  judge: agent file is missing (judge gates unavailable)"
assert_contains "$OUT" "The judge agent file is missing."
assert_eq "$LAST_LINE" "$(last_line "$OUT")" "last line"
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-DIAG-001.4 fixture 4: Bedrock names the provider, and the table gives each alias"
fresh_roots 2.1.296
fx_claude_install
export CLAUDE_CODE_USE_BEDROCK=1
run_doctor
assert_eq 0 "$RC" "exit status"
assert_contains "$OUT" "  Provider: bedrock (set by CLAUDE_CODE_USE_BEDROCK)"
assert_contains "$OUT" "Aliases can resolve to older models on this provider."
# the shipped facts file holds a vendor table with a row for Bedrock
assert_contains "$OUT" "  builder: sonnet, expected Sonnet 4.5 (bedrock table)"
assert_contains "$OUT" "  scout: haiku, expected Haiku 4.5 (bedrock table)"
assert_contains "$OUT" "  conductor: opus, expected not stated (bedrock table)"
# with no vendor table in a copy of the facts file
"$SBX_PY" - "$FACTS" "$SBX/facts-notable.json" <<'PYEOF'
import json, sys
f = json.load(open(sys.argv[1]))
f["facts"].pop("vendor_alias_table", None)
json.dump(f, open(sys.argv[2], "w"), indent=2, sort_keys=True)
PYEOF
cp "$SBX/facts-notable.json" "$CLAUDE_DIR/conductor/lib/facts.json"
run_doctor
assert_contains "$OUT" "expected unknown on bedrock (no table entry)"
# with a custom vendor table in a copy of the facts file
"$SBX_PY" - "$FACTS" "$SBX/facts-table.json" <<'PYEOF'
import json, sys
f = json.load(open(sys.argv[1]))
f["facts"]["vendor_alias_table"] = {"bedrock": {"opus": "Opus 4.8", "sonnet": "Sonnet 4.6", "haiku": "Haiku 4.5", "fable": "not stated"}}
json.dump(f, open(sys.argv[2], "w"), indent=2, sort_keys=True)
PYEOF
cp "$SBX/facts-table.json" "$CLAUDE_DIR/conductor/lib/facts.json"
run_doctor
assert_contains "$OUT" "  builder: sonnet, expected Sonnet 4.6 (bedrock table)"
assert_contains "$OUT" "  scout: haiku, expected Haiku 4.5 (bedrock table)"
assert_contains "$OUT" "  conductor: opus, expected Opus 4.8 (bedrock table)"
assert_contains "$(flat "$OUT")" "Provider is bedrock: no model id was written"
unset CLAUDE_CODE_USE_BEDROCK
t_end

t_begin "REQ-DIAG-001.4 each provider variable, a base URL and a host-managed switch name their provider"
for pair in "CLAUDE_CODE_USE_VERTEX:vertex" "CLAUDE_CODE_USE_FOUNDRY:foundry" "CLAUDE_CODE_USE_ANTHROPIC_AWS:anthropic-aws" \
  "CLAUDE_CODE_USE_MANTLE:mantle" "ANTHROPIC_BASE_URL:custom-base-url" "CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST:host-managed"; do
  var="${pair%%:*}"
  want="${pair#*:}"
  fresh_roots 2.1.296
  fx_claude_install
  export "$var=1"
  run_doctor
  assert_contains "$OUT" "  Provider: $want (set by $var)" "$var"
  unset "$var"
done
t_end

t_begin "O-31 the doctor counts ANTHROPIC_BASE_URL equal to the vendor's own address as first-party, in the environment and in settings env"
for u in "https://api.anthropic.com" "HTTPS://API.Anthropic.com/"; do
  fresh_roots 2.1.296
  fx_claude_install
  export ANTHROPIC_BASE_URL="$u"
  run_doctor
  assert_contains "$OUT" "  Provider: first-party" "environment: $u"
  unset ANTHROPIC_BASE_URL
  printf '{"env": {"ANTHROPIC_BASE_URL": "%s"}}\n' "$u" > "$CLAUDE_DIR/settings.json"
  run_doctor
  assert_contains "$OUT" "  Provider: first-party" "settings env: $u"
done
fresh_roots 2.1.296
fx_claude_install
export ANTHROPIC_BASE_URL="https://proxy.example.test"
run_doctor
assert_contains "$OUT" "  Provider: custom-base-url (set by ANTHROPIC_BASE_URL)" "another address"
unset ANTHROPIC_BASE_URL
t_end

t_begin "REQ-DIAG-001.4 an empty provider variable is unset; a provider in the settings env block counts"
fresh_roots 2.1.296
fx_claude_install
export CLAUDE_CODE_USE_BEDROCK=""
run_doctor
assert_contains "$OUT" "  Provider: first-party"
unset CLAUDE_CODE_USE_BEDROCK
printf '{"env": {"CLAUDE_CODE_USE_VERTEX": "1"}}\n' > "$CLAUDE_DIR/settings.json"
run_doctor
assert_contains "$OUT" "  Provider: vertex (set by CLAUDE_CODE_USE_VERTEX)"
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-DIAG-001.3 fixture 5: a top-level effortLevel with no model pin warns it does not reach Opus 5.5 or Sonnet 5.5"
fresh_roots 2.1.296
fx_claude_install
cp "$REPO/tests/fixtures/doctor/settings-top-effort.json" "$CLAUDE_DIR/settings.json"
run_doctor
assert_eq 0 "$RC" "exit status"
assert_contains "$(flat "$OUT")" "That value does not reach Opus 5.5 or Sonnet 5.5."
assert_contains "$OUT" "  conductor: opus, expected Opus 5.5"
assert_contains "$OUT" "effort inherited from the session"
t_end

t_begin "REQ-DIAG-001.3 with both model pins present there is no such warning"
fresh_roots 2.1.296
fx_claude_install
cp "$REPO/tests/fixtures/doctor/settings-pins.json" "$CLAUDE_DIR/settings.json"
run_doctor
assert_not_contains "$OUT" "does not reach"
assert_contains "$OUT" "effort high (settings pin)"
t_end

t_begin "REQ-DIAG-001.3 a value only in project, local or managed settings makes no such warning"
fresh_roots 2.1.296
fx_claude_install
printf '{}\n' > "$CLAUDE_DIR/settings.json"
mkdir -p "$SBX/proj/.claude"
printf '{"effortLevel": "high"}\n' > "$SBX/proj/.claude/settings.json"
run_doctor
assert_not_contains "$OUT" "does not reach"
assert_contains "$OUT" "project settings set effortLevel high; it applies to every model"
rm -f "$SBX/proj/.claude/settings.json"
printf '{"effortLevel": "xhigh"}\n' > "$SBX/proj/.claude/settings.local.json"
run_doctor
assert_not_contains "$OUT" "does not reach"
assert_contains "$OUT" "local settings set effortLevel xhigh; it applies to every model"
rm -f "$SBX/proj/.claude/settings.local.json"
printf '{"effortLevel": "high"}\n' > "$SBX/managed-settings.json"
run_doctor
assert_not_contains "$OUT" "does not reach"
assert_contains "$OUT" "managed settings set effortLevel high; it applies to every model"
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-DIAG-001.5 fixture 6: unparseable settings warn, exit 0, the file stays as it was, provider unknown"
fresh_roots 2.1.296
fx_claude_install
cp "$REPO/tests/fixtures/doctor/settings-unparseable.json" "$CLAUDE_DIR/settings.json"
before="$(sandbox_tree_sum "$CLAUDE_DIR")"
run_doctor
assert_eq 0 "$RC" "warnings only exit 0"
assert_contains "$(flat "$OUT")" "The user settings file is not valid JSON or cannot be read."
assert_contains "$OUT" "  Provider: unknown"
assert_eq "$LAST_LINE" "$(last_line "$OUT")" "last line"
after="$(sandbox_tree_sum "$CLAUDE_DIR")"
assert_eq "$before" "$after" "the config folder is byte-identical after the doctor"
t_end

t_begin "REQ-DIAG-001.5 an unreadable install record or facts file is the only failing status"
fresh_roots 2.1.296
fx_claude_install
printf '{ not json' > "$CLAUDE_DIR/conductor/.install-manifest"
run_doctor
assert_eq 1 "$RC" "unreadable record"
assert_contains "$OUT" "Install record: unreadable"
fx_claude_install
mv "$CLAUDE_DIR/conductor/lib/facts.json" "$CLAUDE_DIR/conductor/lib/facts.json.off"
run_doctor
assert_eq 1 "$RC" "missing facts"
assert_contains "$OUT" "facts"
mv "$CLAUDE_DIR/conductor/lib/facts.json.off" "$CLAUDE_DIR/conductor/lib/facts.json"
run_doctor
assert_eq 0 "$RC" "back to a readable install"
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-DIAG-001.1 fixture 7: a 0.3.0 install is named and the upgrade command shown"
fresh_roots 2.1.296
mkdir -p "$CLAUDE_DIR/skills/conductor" "$CLAUDE_DIR/conductor/lib" "$CLAUDE_DIR/conductor/bin"
cp "$REPO/tests/fixtures/doctor/manifest-v030-claude.txt" "$CLAUDE_DIR/skills/conductor/.install-manifest"
cp "$REPO/payload/claude/conductor/bin/conductor" "$CLAUDE_DIR/conductor/bin/conductor"
cp "$REPO/payload/claude/conductor/lib/"*.py "$REPO/payload/claude/conductor/lib/facts.json" "$CLAUDE_DIR/conductor/lib/"
fx_agents "$CLAUDE_DIR"
fx_claude_md "$CLAUDE_DIR" 0.3.0
run_doctor
assert_eq 0 "$RC" "exit status"
assert_contains "$OUT" "Version: 0.3.0 (old install record)"
assert_contains "$(flat "$OUT")" "This is a 0.3.0 install. Run the 0.4.0 installer to upgrade it."
assert_eq "$LAST_LINE" "$(last_line "$OUT")" "last line"
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-DIAG-001.7 fixture 8: no python3 on PATH, the doctor says it needs python3 3.9 or later, exit 0"
fresh_roots 2.1.296
fx_claude_install
sandbox_no_python
run_doctor
assert_eq 0 "$RC" "exit status"
assert_contains "$OUT" "The doctor needs python3 3.9 or later."
assert_contains "$OUT" "python3 was not found on your PATH"
t_end

t_begin "REQ-DIAG-001.7 python3 below 3.9 is not usable: the same message, exit 0"
fresh_roots 2.1.296
fx_claude_install
sandbox_fake_python 3.8.18
run_doctor
assert_eq 0 "$RC" "exit status"
assert_contains "$OUT" "The doctor needs python3 3.9 or later."
assert_contains "$OUT" "is version 3.8.18"
t_end

t_begin "REQ-DIAG-001.7 the macOS stub is not usable and is never run"
if [ "$(uname -s)" = "Darwin" ] && [ -x /usr/bin/python3 ]; then
  fresh_roots 2.1.296
  fx_claude_install
  sandbox_no_python
  ln -sf /usr/bin/python3 "$SBX/nopy/python3"
  sandbox_fake_xcode_select FAIL
  run_doctor
  assert_eq 0 "$RC" "exit status"
  assert_contains "$OUT" "The doctor needs python3 3.9 or later."
  assert_contains "$OUT" "macOS stub"
else
  echo "SKIP no /usr/bin/python3 stub case on this system"
fi
t_end

t_begin "REQ-DIAG-001.7 with python3 missing the doctor makes 0 network calls"
fresh_roots 2.1.296
fx_claude_install
sandbox_no_python
net_deny_setup
run_doctor
assert_eq "" "$(net_deny_calls)" "recorded calls"
net_deny_teardown
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-DIAG-001.1 fixture 9: no install says so and shows the install command, exit 0"
fresh_roots 2.1.296
mkdir -p "$CLAUDE_DIR/conductor/bin" "$CLAUDE_DIR/conductor/lib"
cp "$REPO/payload/claude/conductor/bin/conductor" "$CLAUDE_DIR/conductor/bin/conductor"
cp "$REPO/payload/claude/conductor/lib/"*.py "$REPO/payload/claude/conductor/lib/facts.json" "$CLAUDE_DIR/conductor/lib/"
run_doctor
assert_eq 0 "$RC" "exit status"
assert_contains "$OUT" "No Conductor install found."
assert_contains "$OUT" "curl --proto '=https' --tlsv1.2 -fsSL https://conductorskill.com/install.sh | bash"
assert_eq "$LAST_LINE" "$(last_line "$OUT")" "last line"
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-DIAG-001.2 key-shaped settings values print key present, free text prints set (not shown), and no value is ever shown"
fresh_roots 2.1.296
fx_claude_install
printf '{"model": "%s", "env": {"ANTHROPIC_DEFAULT_SONNET_MODEL": "%s", "CLAUDE_CODE_SUBAGENT_MODEL": "free text with spaces"}}\n' "$FIXTURE_KEY" "$FIXTURE_KEY" > "$CLAUDE_DIR/settings.json"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="$FIXTURE_KEY"
run_doctor
assert_eq 0 "$RC" "exit status"
assert_contains "$OUT" "settings (user) set the default model: key present"
assert_contains "$OUT" "ANTHROPIC_DEFAULT_SONNET_MODEL is set in the user settings env block: key present"
assert_contains "$OUT" "ANTHROPIC_DEFAULT_HAIKU_MODEL is set in the environment: key present"
assert_contains "$OUT" "CLAUDE_CODE_SUBAGENT_MODEL is set in the user settings env block: set (not shown)"
assert_not_contains "$OUT" "$FIXTURE_KEY"
assert_not_contains "$OUT" "fixture0000"
assert_not_contains "$OUT" "free text"
unset ANTHROPIC_DEFAULT_HAIKU_MODEL
t_end

t_begin "REQ-DIAG-001.1 overrides, kill switch, debug flag, effort variable and duplicate hook entries are reported"
fresh_roots 2.1.296
fx_claude_install
export CLAUDE_CODE_SUBAGENT_MODEL=haiku CLAUDE_CODE_EFFORT_LEVEL=low CONDUCTOR_HOOKS=off CONDUCTOR_DEBUG=1
"$SBX_PY" - "$CLAUDE_DIR" <<'PYEOF'
import json, os, sys
root = sys.argv[1]
p = os.path.join(root, "settings.json")
s = json.load(open(p))
s["hooks"]["SessionStart"].append(s["hooks"]["SessionStart"][0])
json.dump(s, open(p, "w"))
PYEOF
run_doctor
assert_contains "$OUT" "CLAUDE_CODE_SUBAGENT_MODEL is set in the environment: haiku"
assert_contains "$OUT" "CLAUDE_CODE_EFFORT_LEVEL is set in the environment: low"
assert_contains "$OUT" "overridden by CLAUDE_CODE_EFFORT_LEVEL"
assert_contains "$OUT" "Kill switch CONDUCTOR_HOOKS: off (every Conductor hook stays silent)"
assert_contains "$OUT" "Debug trace CONDUCTOR_DEBUG: on"
assert_contains "$OUT" "Duplicate hook entry: pointer (SessionStart)"
t_end

t_begin "REQ-DIAG-001.1 a second Conductor folder in a hook entry, a doubled block and an old record count as duplicates"
fresh_roots 2.1.296
fx_claude_install
mkdir -p "$CLAUDE_DIR/skills/conductor"
cp "$REPO/tests/fixtures/doctor/manifest-v030-claude.txt" "$CLAUDE_DIR/skills/conductor/.install-manifest"
printf '<!-- BEGIN CONDUCTOR (managed) v0.4.0 - x -->\nb\n<!-- END CONDUCTOR (managed) -->\n' >> "$CLAUDE_DIR/CLAUDE.md"
"$SBX_PY" - "$CLAUDE_DIR" <<'PYEOF'
import json, os, sys
p = os.path.join(sys.argv[1], "settings.json")
s = json.load(open(p))
s["hooks"]["Stop"] = [{"matcher": "", "hooks": [{"type": "command", "command": "python3 /elsewhere/conductor/hooks/usage-split-check.py"}]}]
json.dump(s, open(p, "w"))
PYEOF
run_doctor
assert_contains "$OUT" "  Duplicate installs: found"
assert_contains "$OUT" "an old 0.3.0 install record sits beside the 0.4 record"
assert_contains "$OUT" "the Conductor block appears 2 times in CLAUDE.md"
assert_contains "$OUT" "hook entries point at a Conductor folder other than this one"
t_end

t_begin "REQ-DIAG-001.1 files the user changed are counted and named; the doctor never edits"
fresh_roots 2.1.296
fx_claude_install
printf 'my edit\n' >> "$CLAUDE_DIR/agents/scout.md"
rm -f "$CLAUDE_DIR/agents/critic.md"
before="$(sandbox_tree_sum "$CLAUDE_DIR")"
run_doctor
assert_contains "$OUT" "Files: 5 recorded, 1 missing, 1 changed by you"
assert_contains "$OUT" "    changed: agents/scout.md"
assert_contains "$OUT" "The critic agent file is missing."
assert_eq "$before" "$(sandbox_tree_sum "$CLAUDE_DIR")" "the doctor changed nothing"
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-DIAG-001.6 the network denied: the doctor on a full fixture install completes with 0 network calls"
fresh_roots 2.1.296
fx_claude_install
fx_codex_install
net_deny_setup
# the harness itself works: a socket call and a curl call are recorded and fail
"$SBX_PY" -c 'import socket; socket.create_connection(("127.0.0.1", 9))' > /dev/null 2>&1
assert_eq "python socket call" "$(net_deny_calls)" "the python hook records a call"
curl --max-time 1 http://127.0.0.1:9/ > /dev/null 2>&1
assert_contains "$(net_deny_calls)" "curl --max-time 1 http://127.0.0.1:9/" "the fake curl records a call"
: > "$SBX/net-calls.log"
: > "$SBX/netdeny.log"
run_doctor
assert_eq 0 "$RC" "exit status"
assert_contains "$OUT" "Conductor doctor"
assert_eq "" "$(net_deny_calls)" "calls recorded during the doctor"
net_deny_teardown
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-UI-001.2 output is free of escape sequences with NO_COLOR set and when not a terminal"
fresh_roots 2.1.296
fx_claude_install
run_doctor
n="$(printf '%s' "$OUT" | LC_ALL=C grep -c "$(printf '\033')")"
assert_eq 0 "$n" "escape sequences, piped"
export NO_COLOR=1
out="$(PTY_INPUT="" sandbox_pty /bin/bash "$CLAUDE_DIR/conductor/bin/conductor" doctor --managed-settings "$SBX/managed-settings.json")"
n="$(printf '%s' "$out" | LC_ALL=C grep -c "$(printf '\033')")"
assert_eq 0 "$n" "escape sequences, NO_COLOR on a terminal"
assert_contains "$out" "Conductor doctor"
unset NO_COLOR
out="$(sandbox_pty /bin/bash "$CLAUDE_DIR/conductor/bin/conductor" doctor --managed-settings "$SBX/managed-settings.json")"
n="$(printf '%s' "$out" | LC_ALL=C grep -c "$(printf '\033')")"
assert_eq 0 "$n" "escape sequences on a terminal"
t_end

t_begin "REQ-UI-001.3 no doctor line is longer than 80 characters once paths are measured as tokens"
fresh_roots 2.1.296
fx_claude_install
export CLAUDE_CODE_USE_BEDROCK=1 CLAUDE_CODE_EFFORT_LEVEL=low
cp "$REPO/tests/fixtures/doctor/settings-top-effort.json" "$CLAUDE_DIR/settings.json"
rm -f "$CLAUDE_DIR/agents/judge.md"
run_doctor
long="$(printf '%s\n' "$OUT" | sed -e "s#$SBXR#{sbx}#g" -e "s#$SBX#{sbx}#g" -e "s#$SBX_PY#{py}#g" | awk 'length($0) > 80 { print length($0) ": " $0 }')"
assert_eq "" "$long" "lines over 80 characters"
unset CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_EFFORT_LEVEL
t_end

t_begin "REQ-DIAG-001.1 launcher help, version and a bad command"
fresh_roots 2.1.296
fx_claude_install
run_conductor help
assert_eq 0 "$RC"
assert_contains "$OUT" "conductor doctor"
run_conductor version
assert_eq "Conductor 0.4.0" "$OUT"
run_conductor nonsense
assert_eq 2 "$RC" "unknown command"
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-NFR-001 python 3.9: the doctor and the report parse as 3.9 and run under /usr/bin/python3 when it is 3.9 or later"
for f in "$DOCTOR_PY" "$REPO/payload/claude/conductor/lib/report.py"; do
  "$SBX_PY" -B -c 'import ast, sys; ast.parse(open(sys.argv[1]).read(), feature_version=(3, 9))' "$f" || t_fail "does not parse as python 3.9: $f"
done
sysver="$(/usr/bin/python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)"
case "$sysver" in
  3.9|3.1[0-9])
    fresh_roots 2.1.296
    fx_claude_install
    ln -sf /usr/bin/python3 "$SBX/bin/python3"
    sandbox_fake_xcode_select OK
    run_doctor
    assert_eq 0 "$RC" "exit status"
    assert_contains "$OUT" "  python3 running the doctor: $sysver."
    run_conductor report --managed-settings "$SBX/managed-settings.json"
    assert_eq 0 "$RC" "report exit status"
    assert_contains "$OUT" "python3 $sysver."
    ;;
  *) echo "SKIP /usr/bin/python3 is not 3.9 or later here" ;;
esac
t_end

t_summary
