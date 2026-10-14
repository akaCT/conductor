#!/bin/bash
# tests/test-effort.sh: agent efforts (REQ-EFF-001), the pin offers and the
# version and provider gates (REQ-EFF-002, REQ-EFF-003, REQ-EFF-004, goldens G-01
# to G-06 and G-13), and the model notes (REQ-DOC-002.2, .3).
#
# Installs run in the sandbox against a fixture build of the installer (see
# tests/lib/l2-common.sh). A fake claude answers `claude --version`.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/lib/sandbox.sh"
. "$HERE/lib/l2-common.sh"

sandbox_new
trap sandbox_cleanup EXIT
sandbox_guard
build_installer eff

AGENTS="$REPO/payload/claude/agents"
NOTES="$REPO/payload/claude/conductor/model-notes.md"
OPUS_KEY="modelSettings.claude-opus-5-5.effortLevel"
SONNET_KEY="modelSettings.claude-sonnet-5-5.effortLevel"

fm_get() { # $1=file $2=key: value of a frontmatter line
  sed -n '2,/^---$/p' "$1" | sed -n "s/^$2: *//p" | head -n 1
}

pin_in_settings() { # $1=opus|sonnet -> the effortLevel written, or empty
  settings_val modelSettings "claude-$1-5-5" effortLevel
}

# ---------------------------------------------------------------- agent files

t_begin "REQ-EFF-001.1 5 agent files carry the seat map alias and effort"
for row in "builder.md sonnet high" "scout.md haiku high" "critic.md sonnet xhigh" "architect.md opus xhigh" "judge-rung1.md fable xhigh" "judge-rung3.md sonnet xhigh"; do
  set -- $row
  assert_eq "$2" "$(fm_get "$AGENTS/$1" model)" "$1 model"
  assert_eq "$3" "$(fm_get "$AGENTS/$1" effort)" "$1 effort"
done
t_end

t_begin "REQ-EFF-001.2 an agent file with no effort fails the build and is named"
d="$SBX/neg1"; mkdir -p "$d"; cp -R "$REPO/tools" "$REPO/installer" "$REPO/payload" "$d/"
sed -i.bak '/^effort:/d' "$d/payload/claude/agents/scout.md" && rm -f "$d/payload/claude/agents/scout.md.bak"
assert_exit 1 python3 "$d/tools/build.py"
assert_contains "$ASSERT_OUT" "scout.md" "names the file"
assert_contains "$ASSERT_OUT" "effort" "names the problem"
t_end

t_begin "REQ-EFF-001.3 no agent file sets effort max and the build refuses one"
n="$(grep -lE '^effort: *max' "$AGENTS"/*.md | wc -l | tr -d ' ')"
assert_eq "0" "$n" "agent files with effort max"
d="$SBX/neg2"; mkdir -p "$d"; cp -R "$REPO/tools" "$REPO/installer" "$REPO/payload" "$d/"
sed -i.bak 's/^effort: high/effort: max/' "$d/payload/claude/agents/builder.md" && rm -f "$d/payload/claude/agents/builder.md.bak"
assert_exit 1 python3 "$d/tools/build.py"
assert_contains "$ASSERT_OUT" "builder.md" "names the file"
t_end

t_begin "REQ-SEAT-001.1 agent files: alias and effort per seat, judge rung 1 fable and rung 3 sonnet"
assert_eq "name: judge" "$(sed -n '2p' "$AGENTS/judge-rung1.md")" "judge rung 1 name"
assert_eq "name: judge" "$(sed -n '2p' "$AGENTS/judge-rung3.md")" "judge rung 3 name"
for f in builder scout critic architect judge-rung1 judge-rung3; do
  d="$(fm_get "$AGENTS/$f.md" description)"
  [ "${#d}" -le 300 ] || t_fail "$f description is ${#d} characters"
  [ -n "$d" ] || t_fail "$f has no description"
done
t_end

t_begin "REQ-SEAT-001.2 agent files hold 0 full model ids and 0 model version numbers"
hits="$(grep -nE 'claude-[a-z]+-[0-9]|(Opus|Sonnet|Haiku|Fable|Mythos)[ -]?[0-9]|[0-9]+\.[0-9]+\.[0-9]+' "$AGENTS"/*.md || true)"
assert_eq "" "$hits" "scan hits"
t_end

t_begin "REQ-SEAT-001.3 builder body names the 4 xhigh triggers"
b="$(cat "$AGENTS/builder.md")"
assert_contains "$b" "auth, money, personal data, migrations or deletions"
assert_contains "$b" "parser, a sanitizer or a data transform"
assert_contains "$b" "long command-line procedure"
assert_contains "$b" "already failed at this task once"
t_end

t_begin "REQ-SEAT-001.4 agent tools match the seat map; critic has no WebFetch"
assert_eq "[Read, Grep, Glob, Bash, Edit, Write, NotebookEdit, Skill, Agent, WebFetch, WebSearch]" "$(fm_get "$AGENTS/builder.md" tools)" builder
assert_eq "[Read, Grep, Glob, Bash, WebFetch]" "$(fm_get "$AGENTS/scout.md" tools)" scout
assert_eq "[Read, Grep, Glob, Bash, Skill]" "$(fm_get "$AGENTS/critic.md" tools)" critic
assert_eq "[Read, Grep, Glob, Bash, Skill, Agent, WebFetch, WebSearch]" "$(fm_get "$AGENTS/architect.md" tools)" architect
assert_eq "[Read, Grep, Glob]" "$(fm_get "$AGENTS/judge-rung1.md" tools)" judge1
assert_eq "[Read, Grep, Glob]" "$(fm_get "$AGENTS/judge-rung3.md" tools)" judge3
assert_not_contains "$(fm_get "$AGENTS/critic.md" tools)" WebFetch
s="$(cat "$AGENTS/scout.md")"
assert_contains "$s" "never edit, write or delete" "scout never edits"
assert_contains "$s" "Secrets are never routed to you" "secrets rule"
t_end

t_begin "REQ-SEAT-001.4 critic body reports every finding and holds no severity filter"
c="$(cat "$AGENTS/critic.md")"
assert_contains "$c" "Report every finding you can support with evidence"
for phrase in "material only" "nitpick" "be conservative" "high-confidence only"; do
  case "$c" in *"$phrase"*) t_fail "critic holds the filter phrase: $phrase" ;; esac
done
t_end

# ---------------------------------------------------------------- model notes

t_begin "REQ-DOC-002.2 model notes carry an ISO verified-on date and the re-verify rule"
n="$(cat "$NOTES")"
assert_contains "$n" "re-verify when a model ships or after 90 days"
d="$(sed -n 's/^Verified on: \([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\)$/\1/p' "$NOTES")"
[ -n "$d" ] || t_fail "no ISO Verified on line"
t_end

t_begin "REQ-DOC-002.3 model notes hold 0 private tokens"
hits="$(private_hits "$NOTES")"
assert_eq "" "$hits" "private token hits (file:line; the names come from CONDUCTOR_LEAK_BASE)"
t_end

t_begin "REQ-EFF-003.3 vendor alias table: facts.json, model notes and the installer agree"
LIB="$SBX/lib-eff.sh"
sed '$d' "$INSTALL" > "$LIB"
python3 - "$REPO/payload/claude/conductor/lib/facts.json" > "$SBX/vat.txt" <<'PYEOF'
import json, sys
t = json.load(open(sys.argv[1]))["facts"]["vendor_alias_table"]
for prov, row in t.items():
    if isinstance(row, dict):
        for alias, model in row.items():
            print("%s %s %s" % (prov, alias, model))
PYEOF
rows="$(wc -l < "$SBX/vat.txt" | tr -d ' ')"
assert_eq "15" "$rows" "table rows (5 providers x 3 aliases)"
while IFS= read -r line; do
  p="${line%% *}"; rest="${line#* }"; a="${rest%% *}"; want="${rest#* }"
  got="$(bash -c ". '$LIB'; vendor_alias_model '$p' '$a'")"
  assert_eq "$want" "$got" "$p $a"
done < "$SBX/vat.txt"
assert_contains "$(cat "$NOTES")" "Sonnet 4.6" "model notes table"
t_end

# ---------------------------------------------------------------- unit: version, runtime

t_begin "REQ-EFF-003.1 version_ge compares part by part as integers"
check_ge() { bash -c ". '$LIB'; version_ge '$1' '$2'"; }
check_ge 2.1.280 2.1.280 || t_fail "equal"
check_ge 2.1.283 2.1.280 || t_fail "283 vs 280"
check_ge 2.1.1000 2.1.999 || t_fail "1000 vs 999 (integer compare)"
check_ge 2.10.0 2.9.9 || t_fail "10 vs 9"
check_ge 3.0.0 2.1.999 || t_fail "major"
check_ge 2.1.279 2.1.280 && t_fail "279 < 280"
check_ge 2.1.99 2.1.100 && t_fail "99 < 100"
check_ge "" 2.1.280 && t_fail "empty"
check_ge 2.1.x 2.1.280 && t_fail "non numeric"
t_end

t_begin "REQ-EFF-003.1 an unreadable or hanging claude gives an unknown version"
fresh; set_cc hang
start="$(date +%s)"
got="$(bash -c ". '$LIB'; CLAUDE_DIR='$CLAUDE_DIR'; detect_cc_version; printf '[%s]' \"\$CC_VERSION\"")"
end="$(date +%s)"
assert_eq "[]" "$got" "hung claude"
[ $((end - start)) -le 12 ] || t_fail "took $((end - start)) seconds"
set_cc none
got="$(bash -c ". '$LIB'; detect_cc_version; printf '[%s]' \"\$CC_VERSION\"")"
assert_eq "[]" "$got" "claude with no version text"
set_cc 2.1.290
got="$(bash -c ". '$LIB'; detect_cc_version; printf '[%s]' \"\$CC_VERSION\"")"
assert_eq "[2.1.290]" "$got" "parsed version"
t_end

# ---------------------------------------------------------------- goldens

t_begin "REQ-EFF-003.1 G-01 version 2.1.279 first-party terminal: no pin, update shown, nothing written"
fresh; set_cc 2.1.279
PTY_INPUT=$'\n\n\n' inst_pty --core --judge-rung=3
assert_eq "0" "$RC" "rc"
assert_contains "$OUT" "claude update"
assert_contains "$OUT" "Opus 5.5 effort pin: not offered"
assert_contains "$OUT" "Sonnet 5.5 effort pin: not offered"
assert_not_contains "$OUT" "Set Opus 5.5 to high effort"
assert_no_file "$CLAUDE_DIR/settings.json"
t_end

t_begin "REQ-EFF-003.1 G-02 version 2.1.283: Opus pin offered, Sonnet pin and Haiku not"
fresh; set_cc 2.1.283
PTY_INPUT=$'y\n' inst_pty --core --judge-rung=3
assert_contains "$OUT" "Set Opus 5.5 to high effort for this config?"
assert_not_contains "$OUT" "Set Sonnet 5.5 to high effort"
assert_contains "$OUT" "Sonnet 5.5 effort pin: not offered (Claude Code 2.1.283 is below 2.1.284)"
assert_contains "$OUT" "Haiku 5.5 needs Claude Code v2.1.293 or later"
assert_eq "high" "$(pin_in_settings opus)" "opus pin"
assert_eq "" "$(pin_in_settings sonnet)" "sonnet pin"
assert_eq "" "$(settings_val env ANTHROPIC_DEFAULT_HAIKU_MODEL)" "haiku env"
t_end

t_begin "REQ-EFF-003.1 G-03 version 2.1.290: both pins offered, Haiku env not offered, 2.1.293 note printed"
fresh; set_cc 2.1.290
PTY_INPUT=$'y\ny\n' inst_pty --core --judge-rung=3
assert_contains "$OUT" "Set Opus 5.5 to high effort for this config?"
assert_contains "$OUT" "Set Sonnet 5.5 to high effort for this config?"
assert_contains "$OUT" "Haiku 5.5 needs Claude Code v2.1.293 or later"
assert_contains "$OUT" "claude update"
assert_eq "high" "$(pin_in_settings opus)" "opus pin"
assert_eq "high" "$(pin_in_settings sonnet)" "sonnet pin"
assert_eq "" "$(settings_val env ANTHROPIC_DEFAULT_HAIKU_MODEL)" "haiku env never written"
assert_not_contains "$OUT" "Set Haiku"
t_end

t_begin "REQ-EFF-003.4 G-04 version 2.1.293 with a recorded Haiku value: both pins offered, removal offered"
fresh; set_cc 2.1.293
mkdir -p "$CLAUDE_DIR/conductor"
printf '{"schema": 1, "product": "conductor", "files": [], "pins": [], "env_written": ["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "judge_rung": null}\n' > "$CLAUDE_DIR/conductor/.install-manifest"
printf '{"env": {"ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-haiku-5-5", "KEEP": "1"}}\n' > "$CLAUDE_DIR/settings.json"
PTY_INPUT=$'y\ny\ny\n' inst_pty --core --judge-rung=3
assert_contains "$OUT" "Set Opus 5.5 to high effort for this config?"
assert_contains "$OUT" "Set Sonnet 5.5 to high effort for this config?"
assert_contains "$OUT" "Remove env.ANTHROPIC_DEFAULT_HAIKU_MODEL from your settings?"
assert_not_contains "$OUT" "Haiku 5.5 needs Claude Code"
assert_eq "" "$(settings_val env ANTHROPIC_DEFAULT_HAIKU_MODEL)" "recorded value removed"
assert_eq "1" "$(settings_val env KEEP)" "other env keys kept"
t_end

t_begin "REQ-EFF-003.4 a recorded Haiku value with no terminal is named for removal and left in place"
fresh; set_cc 2.1.296
mkdir -p "$CLAUDE_DIR/conductor"
printf '{"schema": 1, "product": "conductor", "files": [], "pins": [], "env_written": ["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "judge_rung": null}\n' > "$CLAUDE_DIR/conductor/.install-manifest"
printf '{"env": {"ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-haiku-5-5"}}\n' > "$CLAUDE_DIR/settings.json"
before="$(cat "$CLAUDE_DIR/settings.json")"
inst --core --judge-rung=3
assert_contains "$OUT" "delete the ANTHROPIC_DEFAULT_HAIKU_MODEL line"
assert_eq "$before" "$(cat "$CLAUDE_DIR/settings.json")" "settings.json unchanged"
t_end

t_begin "REQ-EFF-003.1 G-05 version unknown: nothing written, every eligible snippet printed"
fresh; set_cc none
inst --core --judge-rung=3
assert_eq "0" "$RC" "rc"
assert_contains "$OUT" "version: unknown"
assert_contains "$OUT" '"claude-opus-5-5": { "effortLevel": "high" }'
assert_contains "$OUT" '"claude-sonnet-5-5": { "effortLevel": "high" }'
assert_no_file "$CLAUDE_DIR/settings.json"
inst --core --judge-rung=3 --apply-effort-pins
assert_no_file "$CLAUDE_DIR/settings.json"
t_end

t_begin "REQ-EFF-003.1 G-06 version 2.1.290 Bedrock: nothing written, expected models printed, no model id written"
fresh; set_cc 2.1.290; export CLAUDE_CODE_USE_BEDROCK=1
PTY_INPUT=$'y\ny\n' inst_pty --core --judge-rung=3
assert_contains "$OUT" "Amazon Bedrock"
assert_contains "$OUT" "alias sonnet runs Sonnet 4.5"
assert_contains "$OUT" "alias haiku runs Haiku 4.5"
assert_not_contains "$OUT" "Set Opus 5.5"
assert_no_file "$CLAUDE_DIR/settings.json"
unset CLAUDE_CODE_USE_BEDROCK
t_end

t_begin "REQ-EFF-003.1 G-13 python3 not on PATH: nothing written, snippets printed, core installed"
fresh; sandbox_no_python; set_cc 2.1.290
PTY_INPUT=$'y\ny\n' inst_pty --core --judge-rung=3
assert_eq "0" "$RC" "rc"
assert_no_file "$CLAUDE_DIR/settings.json"
assert_contains "$OUT" '"claude-opus-5-5": { "effortLevel": "high" }'
assert_contains "$OUT" '"claude-sonnet-5-5": { "effortLevel": "high" }'
assert_contains "$OUT" "python3"
assert_file "$CLAUDE_DIR/agents/judge.md" "core file installed"
sandbox_clear_fakes
t_end

t_begin "REQ-EFF-003.1 G-13 python3 reporting 3.8: nothing written, snippets printed"
fresh; sandbox_fake_python 3.8; set_cc 2.1.290
PTY_INPUT=$'y\ny\n' inst_pty --core --judge-rung=3
assert_eq "0" "$RC" "rc"
assert_no_file "$CLAUDE_DIR/settings.json"
assert_contains "$OUT" '"claude-opus-5-5": { "effortLevel": "high" }'
assert_contains "$OUT" "3.9 or newer"
assert_file "$CLAUDE_DIR/agents/judge.md" "core file installed"
t_end

t_begin "REQ-EFF-003.1 G-13 macOS python3 stub: nothing written, snippets printed, stub never run"
fresh; sandbox_fake_uname Darwin; sandbox_fake_xcode_select FAIL; ln -s /usr/bin/python3 "$SBX/bin/python3"; set_cc 2.1.290
# This case hit its 30 second deadline under a load average of 16: give it 120 (same assertions).
PTY_TIMEOUT=120 PTY_INPUT=$'y\ny\n' inst_pty --core --judge-rung=3
assert_eq "0" "$RC" "rc"
assert_no_file "$CLAUDE_DIR/settings.json"
assert_contains "$OUT" "Command Line Tools stub"
assert_contains "$OUT" '"claude-opus-5-5": { "effortLevel": "high" }'
t_end

# ---------------------------------------------------------------- prompts and consent

t_begin "REQ-EFF-002.1 2 prompts with current value, proposed value, reason and the usage line; yes writes only that key"
fresh; set_cc 2.1.290
PTY_INPUT=$'y\nn\n' inst_pty --core --judge-rung=3
assert_contains "$OUT" "Opus 5.5 effort pin: current not set, proposed high."
assert_contains "$OUT" "Sonnet 5.5 effort pin: current not set, proposed high."
assert_contains "$OUT" "Why: Opus 5.5 starts at medium"
assert_contains "$OUT" "Higher effort can use more of your plan's usage."
assert_eq "high" "$(pin_in_settings opus)" "opus written"
assert_eq "" "$(pin_in_settings sonnet)" "sonnet untouched"
fresh; set_cc 2.1.290
PTY_INPUT=$'n\ny\n' inst_pty --core --judge-rung=3
assert_eq "" "$(pin_in_settings opus)" "opus untouched"
assert_eq "high" "$(pin_in_settings sonnet)" "sonnet written"
t_end

t_begin "REQ-EFF-002.1 the effort gap is explained in 6 lines or fewer"
fresh; set_cc 2.1.290
PTY_INPUT=$'n\nn\n' inst_pty --core --judge-rung=3
start="$(printf '%s\n' "$OUT" | grep -n 'start at medium effort' | head -n 1 | cut -d: -f1)"
stop="$(printf '%s\n' "$OUT" | grep -n 'only with your yes' | head -n 1 | cut -d: -f1)"
[ -n "$start" ] && [ -n "$stop" ] || t_fail "explanation lines not found"
[ $((stop - start + 1)) -le 6 ] || t_fail "explanation spans $((stop - start + 1)) lines"
assert_contains "$OUT" "does not reach them"
assert_contains "$OUT" "pin under modelSettings"
t_end

t_begin "REQ-EFF-002.2 a key the user set to another value: Enter keeps it, only an explicit yes changes it"
fresh; set_cc 2.1.290
printf '{"modelSettings": {"claude-opus-5-5": {"effortLevel": "xhigh"}}}\n' > "$CLAUDE_DIR/settings.json"
PTY_INPUT=$'\ny\n' inst_pty --core --judge-rung=3
assert_contains "$OUT" "Opus 5.5 effort pin: current xhigh, proposed high."
assert_eq "xhigh" "$(pin_in_settings opus)" "Enter kept the user's value"
assert_eq "high" "$(pin_in_settings sonnet)" "sonnet answered yes"
fresh; set_cc 2.1.290
printf '{"modelSettings": {"claude-opus-5-5": {"effortLevel": "xhigh"}}}\n' > "$CLAUDE_DIR/settings.json"
PTY_INPUT=$'y\nn\n' inst_pty --core --judge-rung=3
assert_eq "high" "$(pin_in_settings opus)" "explicit yes changed it"
t_end

t_begin "REQ-EFF-002.3 a declined key is unchanged and the install continues"
fresh; set_cc 2.1.290
printf '{"theme": "dark"}\n' > "$CLAUDE_DIR/settings.json"
before="$(cat "$CLAUDE_DIR/settings.json")"
PTY_INPUT=$'n\nn\n' inst_pty --core --judge-rung=3
assert_eq "0" "$RC" "rc"
assert_eq "$before" "$(cat "$CLAUDE_DIR/settings.json")" "settings.json byte-identical"
assert_file "$CLAUDE_DIR/agents/judge.md" "install continued"
t_end

t_begin "REQ-EFF-002.4 the proposed value is never max"
fresh; set_cc 2.1.290
PTY_INPUT=$'y\ny\n' inst_pty --core --judge-rung=3
assert_not_contains "$OUT" "proposed max"
assert_not_contains "$OUT" '"max"'
assert_not_contains "$OUT" "to max effort"
assert_eq "high" "$(pin_in_settings opus)" "value written"
t_end

t_begin "REQ-EFF-002.5 an accepted key is recorded with its value and previous value"
fresh; set_cc 2.1.290
printf '{"modelSettings": {"claude-opus-5-5": {"effortLevel": "medium"}}}\n' > "$CLAUDE_DIR/settings.json"
PTY_INPUT=$'y\ny\n' inst_pty --core --judge-rung=3
pins="$(manifest_pins)"
python3 - "$pins" <<'PYEOF' || t_fail "manifest pins wrong"
import json, sys
pins = {p["key"]: p for p in json.loads(sys.argv[1])}
o = pins["modelSettings.claude-opus-5-5.effortLevel"]
s = pins["modelSettings.claude-sonnet-5-5.effortLevel"]
assert o["value"] == "high" and o["previous"] == "medium" and o["previous_present"] is True, o
assert s["value"] == "high" and s["previous"] is None and s["previous_present"] is False, s
PYEOF
t_end

t_begin "REQ-EFF-002.1 a pin that already equals the proposed value is not asked again"
fresh; set_cc 2.1.290
printf '{"modelSettings": {"claude-opus-5-5": {"effortLevel": "high"}}}\n' > "$CLAUDE_DIR/settings.json"
PTY_INPUT=$'y\n' inst_pty --core --judge-rung=3
assert_contains "$OUT" "Opus 5.5 effort pin: already high"
assert_not_contains "$OUT" "Set Opus 5.5 to high effort"
t_end

# ---------------------------------------------------------------- no terminal

t_begin "REQ-EFF-004.1 CONDUCTOR_YES=1 and no flag: snippets printed, settings.json unchanged"
fresh; set_cc 2.1.290
printf '{"theme": "dark"}\n' > "$CLAUDE_DIR/settings.json"
before="$(cat "$CLAUDE_DIR/settings.json")"
CONDUCTOR_YES=1 PTY_INPUT=$'y\ny\n' inst_pty --core --judge-rung=3
assert_contains "$OUT" '"claude-opus-5-5": { "effortLevel": "high" }'
assert_contains "$OUT" '"claude-sonnet-5-5": { "effortLevel": "high" }'
assert_contains "$OUT" "printed, not written"
assert_eq "$before" "$(cat "$CLAUDE_DIR/settings.json")" "settings.json unchanged"
fresh; set_cc 2.1.290
CONDUCTOR_YES=1 inst --core --judge-rung=3
assert_no_file "$CLAUDE_DIR/settings.json"
assert_contains "$OUT" "no terminal to ask in"
t_end

t_begin "REQ-EFF-004.2 --apply-effort-pins writes each eligible key after a backup and lists it"
fresh; set_cc 2.1.290
printf '{"theme": "dark"}\n' > "$CLAUDE_DIR/settings.json"
inst --core --judge-rung=3 --apply-effort-pins
assert_eq "0" "$RC" "rc"
assert_eq "high" "$(pin_in_settings opus)" "opus"
assert_eq "high" "$(pin_in_settings sonnet)" "sonnet"
assert_eq "dark" "$(settings_val theme)" "other keys kept"
assert_contains "$OUT" "Opus 5.5 effort pin: wrote high"
assert_contains "$OUT" "Sonnet 5.5 effort pin: wrote high"
nb="$(ls "$CLAUDE_DIR/conductor/backups" 2>/dev/null | grep -c 'settings.json' || true)"
[ "$nb" -ge 1 ] || t_fail "no settings.json backup in conductor/backups"
t_end

t_begin "REQ-EFF-004.2 --apply-effort-pins keeps a value the user set and says so"
fresh; set_cc 2.1.290
printf '{"modelSettings": {"claude-opus-5-5": {"effortLevel": "xhigh"}}}\n' > "$CLAUDE_DIR/settings.json"
inst --core --judge-rung=3 --apply-effort-pins
assert_eq "xhigh" "$(pin_in_settings opus)" "user's value kept"
assert_eq "high" "$(pin_in_settings sonnet)" "sonnet written"
assert_contains "$OUT" "kept your value xhigh"
t_end

t_begin "REQ-EFF-004.3 --apply-effort-pins never writes a key whose gate fails"
fresh; set_cc 2.1.283
inst --core --judge-rung=3 --apply-effort-pins
assert_eq "high" "$(pin_in_settings opus)" "opus eligible"
assert_eq "" "$(pin_in_settings sonnet)" "sonnet below its floor"
fresh; set_cc 2.1.279
inst --core --judge-rung=3 --apply-effort-pins
assert_no_file "$CLAUDE_DIR/settings.json"
fresh; set_cc 2.1.296; export CLAUDE_CODE_USE_VERTEX=1
inst --core --judge-rung=3 --apply-effort-pins
assert_no_file "$CLAUDE_DIR/settings.json"
unset CLAUDE_CODE_USE_VERTEX
fresh; sandbox_no_python; set_cc 2.1.296
inst --core --judge-rung=3 --apply-effort-pins
assert_no_file "$CLAUDE_DIR/settings.json"
sandbox_clear_fakes
t_end

t_begin "REQ-EFF-004.1 --dry-run with --apply-effort-pins and a Codex folder writes nothing"
fresh; set_cc 2.1.290
mkdir -p "$CODEX_DIR"
printf '{"theme": "dark"}\n' > "$CLAUDE_DIR/settings.json"
sandbox_tree_sum "$HOME" > "$SBX/dry-before.txt"
inst --dry-run --core --judge-rung=1 --apply-effort-pins
assert_eq "0" "$RC" "rc"
sandbox_tree_sum "$HOME" > "$SBX/dry-after.txt"
cmp -s "$SBX/dry-before.txt" "$SBX/dry-after.txt" || t_fail "dry run changed something under HOME"
assert_contains "$OUT" "would offer: Set Opus 5.5 to high effort"
t_end

t_begin "REQ-EFF-003.2 a version below a key's floor never writes that key"
fresh; set_cc 2.1.280
inst --core --judge-rung=3 --apply-effort-pins
assert_eq "high" "$(pin_in_settings opus)" "opus at its floor"
assert_eq "" "$(pin_in_settings sonnet)" "sonnet has a higher floor"
fresh; set_cc 2.1.284
inst --core --judge-rung=3 --apply-effort-pins
assert_eq "high" "$(pin_in_settings sonnet)" "sonnet at its floor"
t_end

# ---------------------------------------------------------------- providers

t_begin "REQ-EFF-003.3 each of the 5 provider variables in the environment blocks all writes and prints expected models"
for pv in "CLAUDE_CODE_USE_BEDROCK Amazon Bedrock" "CLAUDE_CODE_USE_VERTEX Vertex" "CLAUDE_CODE_USE_FOUNDRY Microsoft Foundry" "CLAUDE_CODE_USE_ANTHROPIC_AWS Claude Platform on AWS" "CLAUDE_CODE_USE_MANTLE Bedrock Mantle"; do
  var="${pv%% *}"; label="${pv#* }"
  fresh; set_cc 2.1.296
  export "$var=1"
  inst --core --judge-rung=3 --apply-effort-pins
  assert_contains "$OUT" "$label" "$var provider named"
  assert_not_contains "$OUT" "wrote high" "$var wrote nothing"
  assert_no_file "$CLAUDE_DIR/settings.json" "$var"
  unset "$var"
done
fresh; set_cc 2.1.296; export CLAUDE_CODE_USE_FOUNDRY=1
inst --core --judge-rung=3
assert_contains "$OUT" "alias opus runs Opus 4.6"
assert_contains "$OUT" "alias haiku runs Haiku 4.5"
assert_contains "$OUT" "alias sonnet runs Sonnet 4.5"
unset CLAUDE_CODE_USE_FOUNDRY
fresh; set_cc 2.1.296; export CLAUDE_CODE_USE_ANTHROPIC_AWS=1
inst --core --judge-rung=3
assert_contains "$OUT" "alias sonnet runs Sonnet 4.6"
unset CLAUDE_CODE_USE_ANTHROPIC_AWS
t_end

t_begin "REQ-EFF-003.3 each of the 5 provider variables in the settings env block blocks all writes"
for var in CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_ANTHROPIC_AWS CLAUDE_CODE_USE_MANTLE; do
  fresh; set_cc 2.1.296
  printf '{"env": {"%s": "1"}}\n' "$var" > "$CLAUDE_DIR/settings.json"
  before="$(cat "$CLAUDE_DIR/settings.json")"
  inst --core --judge-rung=3 --apply-effort-pins
  assert_not_contains "$OUT" "wrote high" "$var in settings env"
  assert_eq "$before" "$(cat "$CLAUDE_DIR/settings.json")" "$var settings unchanged"
  assert_contains "$OUT" "Aliases can resolve to older models" "$var table printed"
done
t_end

t_begin "REQ-EFF-003.3 ANTHROPIC_BASE_URL or CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST set: not first-party, nothing written"
fresh; set_cc 2.1.296; export ANTHROPIC_BASE_URL="http://127.0.0.1:9"
inst --core --judge-rung=3 --apply-effort-pins
assert_contains "$OUT" "ANTHROPIC_BASE_URL is set to another address"
assert_no_file "$CLAUDE_DIR/settings.json"
unset ANTHROPIC_BASE_URL
fresh; set_cc 2.1.296; export CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST=1
inst --core --judge-rung=3 --apply-effort-pins
assert_contains "$OUT" "host-managed provider"
assert_no_file "$CLAUDE_DIR/settings.json"
unset CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST
fresh; set_cc 2.1.296
printf '{"env": {"ANTHROPIC_BASE_URL": "http://127.0.0.1:9"}}\n' > "$CLAUDE_DIR/settings.json"
inst --core --judge-rung=3 --apply-effort-pins
assert_contains "$OUT" "ANTHROPIC_BASE_URL is set to another address"
assert_eq "" "$(pin_in_settings opus)" "no pin with a base url in settings env"
t_end

t_begin "REQ-EFF-003.3 an empty-string provider variable counts as unset, in the environment and in settings env"
fresh; set_cc 2.1.296
export CLAUDE_CODE_USE_BEDROCK="" ANTHROPIC_BASE_URL="" CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST=""
inst --core --judge-rung=3 --apply-effort-pins
assert_eq "high" "$(pin_in_settings opus)" "first-party with empty variables"
unset CLAUDE_CODE_USE_BEDROCK ANTHROPIC_BASE_URL CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST
fresh; set_cc 2.1.296
printf '{"env": {"CLAUDE_CODE_USE_VERTEX": "", "ANTHROPIC_BASE_URL": ""}}\n' > "$CLAUDE_DIR/settings.json"
inst --core --judge-rung=3 --apply-effort-pins
assert_eq "high" "$(pin_in_settings opus)" "first-party with empty settings env values"
assert_eq "high" "$(pin_in_settings sonnet)" "sonnet too"
t_end

t_begin "REQ-EFF-003.3 an unparseable settings.json leaves the provider unknown: nothing written, file untouched"
fresh; set_cc 2.1.296
printf '{not json' > "$CLAUDE_DIR/settings.json"
inst --core --judge-rung=3 --apply-effort-pins
assert_eq "{not json" "$(cat "$CLAUDE_DIR/settings.json")" "byte-identical"
assert_contains "$OUT" "does not parse"
t_end

t_begin "REQ-EFF-003.3 the process environment names a provider even without python3"
fresh; sandbox_no_python; set_cc 2.1.296; export CLAUDE_CODE_USE_MANTLE=1
inst --core --judge-rung=3
assert_contains "$OUT" "Bedrock Mantle"
assert_no_file "$CLAUDE_DIR/settings.json"
unset CLAUDE_CODE_USE_MANTLE
sandbox_clear_fakes
t_end

# ---------------------------------------------------------------- Haiku

t_begin "REQ-EFF-003.6 the Haiku env value is never written, at any version"
for v in 2.1.288 2.1.289 2.1.290 2.1.292 2.1.293 2.1.296; do
  fresh; set_cc "$v"
  inst --core --judge-rung=3 --apply-effort-pins
  assert_eq "" "$(settings_val env ANTHROPIC_DEFAULT_HAIKU_MODEL)" "$v settings"
  assert_not_contains "$OUT" "claude-haiku-5-5" "$v output offers no id"
done
fresh; set_cc 2.1.290
CONDUCTOR_YES=1 inst --core --judge-rung=3
assert_not_contains "$OUT" "claude-haiku-5-5"
t_end

t_begin "REQ-EFF-003.5 the release record says the Haiku value was not observed"
r="$(cat "$REPO/release/RECORD-0.4.0.md")"
assert_contains "$r" "was not observed"
assert_contains "$r" "2.1.289 to 2.1.292"
assert_contains "$r" "The installer never writes the value at any version"
t_end

t_summary
