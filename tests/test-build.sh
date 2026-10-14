#!/bin/bash
# tests/test-build.sh: tools/build.py (REQ-INS-001), the shape of the generated
# install.sh, the skeleton fragments, and the test harness itself.
#
# Build cases run on a copy of the repo inside the sandbox, so the real payload,
# installer and install.sh are never edited. Function-level cases source a copy
# of the generated install.sh without its last line (the call to main).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/lib/sandbox.sh"

sandbox_new
trap sandbox_cleanup EXIT
export PYTHONDONTWRITEBYTECODE=1
sandbox_guard
mkdir -p "$CLAUDE_DIR" "$CODEX_DIR" "$AGENTS_SKILLS_DIR"

LIB="$SBX/lib.sh"
sed '$d' "$REPO/install.sh" > "$LIB"
FIX_N=0

fixture_repo() { # $1=name -> prints the folder of a fresh copy of tools, installer, payload and install.sh
  local d="$SBX/$1"
  mkdir -p "$d"
  cp -R "$REPO/tools" "$REPO/installer" "$REPO/payload" "$d/"
  cp "$REPO/install.sh" "$d/install.sh"
  printf '%s' "$d"
}

new_fixture() { # makes a new numbered fixture folder and leaves its path in FX (no subshell: the counter must persist)
  FIX_N=$((FIX_N + 1))
  fixture_repo "fx$FIX_N" > /dev/null
  FX="$SBX/fx$FIX_N"
}

cj_edit() { # $1=fixture folder $2=python statements acting on d, the parsed components.json
  python3 - "$1/payload/components.json" "$2" <<'PYEOF'
import json, sys
p, code = sys.argv[1], sys.argv[2]
d = json.load(open(p))
exec(code)
open(p, "w").write(json.dumps(d, indent=1) + "\n")
PYEOF
}

file_edit() { # $1=file $2=python statements acting on t, the file text
  python3 - "$1" "$2" <<'PYEOF'
import sys
p, code = sys.argv[1], sys.argv[2]
t = open(p, encoding="utf-8", newline="").read()
exec(code)
open(p, "w", encoding="utf-8", newline="").write(t)
PYEOF
}

flip_last_letter() { # $1=file: upper-case the last lower-case ASCII letter (a 1 byte change)
  python3 - "$1" <<'PYEOF'
import sys
p = sys.argv[1]
b = bytearray(open(p, "rb").read())
for i in range(len(b) - 1, -1, -1):
    if 97 <= b[i] <= 122:
        b[i] -= 32
        break
else:
    raise SystemExit("no lower-case letter in " + p)
open(p, "wb").write(bytes(b))
PYEOF
}

sum_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# ---------------------------------------------------------------- REQ-INS-001

t_begin "REQ-INS-001.1 build.py --check exits 0 on the repo"
assert_exit 0 python3 "$REPO/tools/build.py" --check
assert_contains "$ASSERT_OUT" "OK     build is in sync"
t_end

t_begin "REQ-INS-001.1 sync-check.py is a wrapper: 0 in sync, 1 on drift"
assert_exit 0 python3 "$REPO/tools/sync-check.py"
new_fixture; d="$FX"
flip_last_letter "$d/payload/claude/skills/conductor/SKILL.md"
assert_exit 1 python3 "$d/tools/sync-check.py"
assert_contains "$ASSERT_OUT" "payload/claude/skills/conductor/SKILL.md"
t_end

t_begin "REQ-INS-001.2 1 changed doctrine byte fails the check and names that file"
new_fixture; d="$FX"
flip_last_letter "$d/payload/claude/doctrine.md"
assert_exit 1 python3 "$d/tools/build.py" --check
assert_contains "$ASSERT_OUT" "DRIFT  payload/claude/doctrine.md"
assert_contains "$ASSERT_OUT" "DRIFT  install.sh"
assert_not_contains "$ASSERT_OUT" "payload/claude/agents/builder.md"
t_end

t_begin "REQ-INS-001.2 1 changed agent byte names the agent and its Codex file"
new_fixture; d="$FX"
flip_last_letter "$d/payload/claude/agents/builder.md"
assert_exit 1 python3 "$d/tools/build.py" --check
assert_contains "$ASSERT_OUT" "DRIFT  payload/claude/agents/builder.md"
assert_contains "$ASSERT_OUT" "DRIFT  payload/codex/agents/builder.toml"
assert_contains "$ASSERT_OUT" "DRIFT  install.sh"
t_end

t_begin "REQ-INS-001.2 a hand-edited generated file (facts.json) is named"
new_fixture; d="$FX"
printf '\n' >> "$d/payload/claude/conductor/lib/facts.json"
assert_exit 1 python3 "$d/tools/build.py" --check
assert_contains "$ASSERT_OUT" "DRIFT  payload/claude/conductor/lib/facts.json"
t_end

t_begin "REQ-INS-001.2 a hand-edited installer fragment is named as install.sh drift"
new_fixture; d="$FX"
printf '# edited\n' >> "$d/installer/src/90-summary.sh"
assert_exit 1 python3 "$d/tools/build.py" --check
assert_contains "$ASSERT_OUT" "DRIFT  install.sh"
t_end

t_begin "REQ-INS-001.3 install.sh, both VERSION files, facts.json and the doctrine marker carry 0.4.0"
assert_eq "0.4.0" "$(cat "$REPO/payload/claude/skills/conductor/VERSION")" "claude VERSION"
assert_eq "0.4.0" "$(cat "$REPO/payload/codex/skills/conductor/VERSION")" "codex VERSION"
assert_eq "0.4.0" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$REPO/payload/claude/conductor/lib/facts.json")" "facts.json"
assert_eq "0.4.0" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$REPO/payload/components.json")" "components.json"
assert_eq 1 "$(grep -c '^CONDUCTOR_VERSION="0.4.0"$' "$REPO/install.sh")" "CONDUCTOR_VERSION lines"
assert_eq "<!-- BEGIN CONDUCTOR (managed) v0.4.0 - https://conductorskill.com -->" "$( . "$LIB"; printf '%s' "$BEGIN_MARKER")" "begin marker"
assert_eq "<!-- END CONDUCTOR (managed) -->" "$( . "$LIB"; printf '%s' "$END_MARKER")" "end marker"
t_end

t_begin "REQ-INS-001.3 a VERSION file out of step fails the check and is named"
new_fixture; d="$FX"
printf '9.9.9\n' > "$d/payload/codex/skills/conductor/VERSION"
assert_exit 1 python3 "$d/tools/build.py" --check
assert_contains "$ASSERT_OUT" "DRIFT  payload/codex/skills/conductor/VERSION"
t_end

t_begin "REQ-INS-001.3 a new version without a rebuild fails the check (install.sh, VERSION, facts)"
new_fixture; d="$FX"
cj_edit "$d" "d['version'] = '0.4.1'"
assert_exit 1 python3 "$d/tools/build.py" --check
assert_contains "$ASSERT_OUT" "DRIFT  install.sh"
assert_contains "$ASSERT_OUT" "DRIFT  payload/claude/skills/conductor/VERSION"
assert_contains "$ASSERT_OUT" "DRIFT  payload/claude/conductor/lib/facts.json"
t_end

t_begin "REQ-INS-001.3 a rebuild with a new version moves every carrier to it"
assert_exit 0 python3 "$d/tools/build.py"
assert_exit 0 python3 "$d/tools/build.py" --check
assert_eq "0.4.1" "$(cat "$d/payload/claude/skills/conductor/VERSION")" "claude VERSION"
assert_eq "0.4.1" "$(cat "$d/payload/codex/skills/conductor/VERSION")" "codex VERSION"
assert_eq 1 "$(grep -c '^CONDUCTOR_VERSION="0.4.1"$' "$d/install.sh")" "CONDUCTOR_VERSION"
t_end

t_begin "REQ-INS-001.3 a doctrine file with another version's marker fails the build"
new_fixture; d="$FX"
before="$(sum_of "$d/install.sh")"
printf '<!-- BEGIN CONDUCTOR (managed) v0.3.0 - x -->\n' >> "$d/payload/claude/doctrine.md"
assert_exit 1 python3 "$d/tools/build.py"
assert_contains "$ASSERT_OUT" "payload/claude/doctrine.md"
assert_contains "$ASSERT_OUT" "doctrine marker v0.3.0"
assert_eq "$before" "$(sum_of "$d/install.sh")" "install.sh untouched by a failed build"
t_end

t_begin "REQ-INS-001.3 a fragment that sets CONDUCTOR_VERSION fails the build"
new_fixture; d="$FX"
printf 'CONDUCTOR_VERSION="0.3.0"\n' >> "$d/installer/src/10-detect.sh"
assert_exit 1 python3 "$d/tools/build.py"
assert_contains "$ASSERT_OUT" "installer/src/10-detect.sh"
t_end

t_begin "REQ-INS-001.4 a payload file with its own delimiter line fails the build and is named"
new_fixture; d="$FX"
before="$(sum_of "$d/install.sh")"
printf 'CONDUCTOR_EOF_AGENT_SCOUT\n' >> "$d/payload/claude/agents/scout.md"
assert_exit 1 python3 "$d/tools/build.py"
assert_contains "$ASSERT_OUT" "payload/claude/agents/scout.md"
assert_contains "$ASSERT_OUT" "own embed delimiter"
assert_eq "$before" "$(sum_of "$d/install.sh")" "install.sh untouched by a failed build"
t_end

t_begin "REQ-INS-001.4 a payload file without a trailing newline fails the build and is named"
new_fixture; d="$FX"
file_edit "$d/payload/claude/conductor/model-notes.md" "t = t.rstrip('\n')"
assert_exit 1 python3 "$d/tools/build.py"
assert_contains "$ASSERT_OUT" "payload/claude/conductor/model-notes.md"
assert_contains "$ASSERT_OUT" "exactly 1 trailing newline (found 0)"
t_end

t_begin "REQ-INS-001.4 a payload file with 2 trailing newlines fails the build and is named"
new_fixture; d="$FX"
file_edit "$d/payload/claude/doctrine.md" "t = t + '\n'"
assert_exit 1 python3 "$d/tools/build.py"
assert_contains "$ASSERT_OUT" "payload/claude/doctrine.md"
assert_contains "$ASSERT_OUT" "exactly 1 trailing newline (found 2)"
t_end

t_begin "REQ-INS-001.4 a payload file that is not UTF-8 fails the build and is named"
new_fixture; d="$FX"
printf '\377\n' >> "$d/payload/claude/conductor/defaults.md"
assert_exit 1 python3 "$d/tools/build.py"
assert_contains "$ASSERT_OUT" "payload/claude/conductor/defaults.md"
assert_contains "$ASSERT_OUT" "not valid UTF-8"
t_end

t_begin "REQ-INS-001.4 an installer helper that is not UTF-8 fails the build and is named"
new_fixture; d="$FX"
printf '\377\n' >> "$d/installer/py/manifest.py"
assert_exit 1 python3 "$d/tools/build.py"
assert_contains "$ASSERT_OUT" "installer/py/manifest.py"
t_end

t_begin "REQ-INS-001.5 the last statement is the single call to main, after every function"
assert_eq 'main "$@"' "$(tail -n 1 "$REPO/install.sh")" "last line"
res="$(awk '
  /^emit_[A-Za-z0-9_]+\(\) \{ cat <<.CONDUCTOR_EOF_[A-Z0-9_]+.$/ { skip = 1; match($0, /CONDUCTOR_EOF_[A-Z0-9_]+/); d = substr($0, RSTART, RLENGTH); next }
  skip && $0 == d { skip = 0; next }
  skip { next }
  /^[A-Za-z_][A-Za-z0-9_]*\(\) *\{/ { lastdef = NR }
  $0 == "main \"$@\"" { n++; mainline = NR }
  END { print n + 0, (lastdef < mainline ? "after" : "before"), (mainline == NR ? "last" : "notlast") }
' "$REPO/install.sh")"
assert_eq "1 after last" "$res" "main call count, position, last line"
t_end

t_begin "REQ-INS-001.5 a copy cut off at an earlier line changes nothing in a temp config folder"
total="$(wc -l < "$REPO/install.sh" | tr -d ' ')"
before="$(sandbox_tree_sum "$SBX/home")"
bad=""
cuts="$((total / 2)) $((total - 1)) $((total - 2))"
n=10
while [ "$n" -lt "$total" ]; do cuts="$cuts $n"; n=$((n + 53)); done
for n in $cuts; do
  head -n "$n" "$REPO/install.sh" > "$SBX/cut.sh"
  CONDUCTOR_YES=1 /bin/bash "$SBX/cut.sh" < /dev/null > "$SBX/cut.out" 2>&1
  if [ "$(sandbox_tree_sum "$SBX/home")" != "$before" ]; then bad="$bad $n"; fi
  if grep -q 'Conductor installer v' "$SBX/cut.out"; then bad="$bad run@$n"; fi
done
assert_eq "" "$bad" "cut points that changed the sandbox or ran main"
head -n "$(( $(grep -n '^sanitize_text() {' "$REPO/install.sh" | head -1 | cut -d: -f1) + 1 ))" "$REPO/install.sh" > "$SBX/cut.sh"
assert_exit "!0" /bin/bash -n "$SBX/cut.sh"
t_end

t_begin "REQ-INS-001 build output is deterministic and independent of the checkout path"
new_fixture; d1="$FX"
new_fixture; d2="$FX"
assert_exit 0 python3 "$d1/tools/build.py"
assert_exit 0 python3 "$d2/tools/build.py"
assert_eq "$(sum_of "$REPO/install.sh")" "$(sum_of "$d1/install.sh")" "rebuild equals the committed install.sh"
assert_eq "$(sum_of "$d1/install.sh")" "$(sum_of "$d2/install.sh")" "2 builds in 2 folders"
assert_exit 0 python3 "$d1/tools/build.py" --payload "$d1/payload" --out "$SBX/out1.sh"
assert_exit 0 python3 "$d1/tools/build.py" --payload "$d2/payload" --out "$SBX/out2.sh"
assert_eq "$(sum_of "$SBX/out1.sh")" "$(sum_of "$SBX/out2.sh")" "fixture builds"
assert_eq "$(sum_of "$REPO/install.sh")" "$(sum_of "$SBX/out1.sh")" "fixture build equals install.sh"
assert_exit 0 python3 "$d1/tools/build.py"
assert_contains "$ASSERT_OUT" "nothing changed"
t_end

t_begin "REQ-INS-001 embedding is byte-exact for awkward text (tab, quotes, backslash, CRLF, unicode, a line EOF, trailing spaces)"
new_fixture; d="$FX"
python3 - "$d/payload/claude/conductor/defaults.md" <<'PYEOF'
import sys
lines = ["\tTab $HOME `cmd` $(cmd) \\", "' \" ", "\u00e9 \u2713 \u4e2d", "line with CRLF\r", "", "EOF", "CONDUCTOR_EOF", "}", ") done   ", "x" * 5000]
open(sys.argv[1], "w", encoding="utf-8", newline="").write("\n".join(lines) + "\n")
PYEOF
assert_exit 0 python3 "$d/tools/build.py"
sed '$d' "$d/install.sh" > "$SBX/libx.sh"
assert_exit 0 /bin/bash -c ". '$SBX/libx.sh'; payload_emit defaults | cmp - '$d/payload/claude/conductor/defaults.md'"
assert_eq "$(sum_of "$d/payload/claude/conductor/defaults.md")" "$( . "$SBX/libx.sh"; payload_emit defaults | shasum -a 256 | awk '{print $1}')" "embedded text hash"
t_end

t_begin "REQ-INS-001 --payload needs --out, so a fixture build cannot overwrite install.sh"
assert_exit 2 python3 "$REPO/tools/build.py" --payload "$SBX/fx1/payload"
t_end

t_begin "REQ-INS-001 every embedded function writes exactly the payload file (40 embeds)"
assert_eq 37 "$( . "$LIB"; set -- $FILE_IDS; echo $#)" "file count"
assert_eq 7 "$( . "$LIB"; set -- $COMPONENT_IDS; echo $#)" "component count"
bad="$( . "$LIB"
  for id in $FILE_IDS; do
    payload_emit "$id" | cmp -s - "$REPO/payload/$(file_src "$id")" || printf '%s ' "$id"
  done
  emit_prior_hashes | cmp -s - "$REPO/installer/prior-hashes.txt" || printf 'prior_hashes '
  emit_py_manifest | cmp -s - "$REPO/installer/py/manifest.py" || printf 'py_manifest '
  emit_py_settings_merge | cmp -s - "$REPO/installer/py/settings_merge.py" || printf 'py_settings_merge ')"
assert_eq "" "$bad" "embeds that differ from their file"
t_end

t_begin "REQ-INS-001 the file table matches components.json (dest, mode, policy, select, wire)"
assert_eq "agents/judge.md|agents/judge.md" "$( . "$LIB"; echo "$(file_dest agent_judge_r1)|$(file_dest agent_judge_r3)")" "judge dest"
assert_eq "judge_rung=1|judge_rung=3" "$( . "$LIB"; echo "$(file_select agent_judge_r1)|$(file_select agent_judge_r3)")" "judge select"
assert_eq "755|644|755" "$( . "$LIB"; echo "$(file_mode launcher)|$(file_mode model_notes)|$(file_mode hook_nudge)")" "modes"
assert_eq "create-only|conductor/defaults.default.md" "$( . "$LIB"; echo "$(file_policy defaults)|$(file_also defaults)")" "create-only also"
assert_eq "agents_skills|skills/conductor/SKILL.md" "$( . "$LIB"; echo "$(file_root codex_skill)|$(file_dest codex_skill)")" "codex skill root"
assert_eq "2|PreToolUse|Agent|Task|SubagentStop|10" "$( . "$LIB"; echo "$(file_wire_count hook_contract)|$(file_wire hook_contract 1 event)|$(file_wire hook_contract 1 matcher)|$(file_wire hook_contract 2 event)|$(file_wire hook_contract 2 timeout)")" "contract hook wiring"
assert_eq "SessionStart|UserPromptSubmit|Stop|SessionStart" "$( . "$LIB"; echo "$(file_wire hook_pointer 1 event)|$(file_wire hook_nudge 1 event)|$(file_wire hook_usage_split 1 event)|$(file_wire hook_project_home 1 event)")" "hook events"
assert_eq "1|0|python3|full" "$( . "$LIB"; echo "$(component_default core)|$(component_default full)|$(component_needs full)|$(component_requires hook_nudge)")" "components"
t_end

# ---------------------------------------------------------------- invalid components.json

BF_N=0
expect_build_fail() { # $1=test name $2=python edit of components.json $3=text the failure must hold
  local d before
  new_fixture; d="$FX"
  before="$(sum_of "$d/install.sh")"
  cj_edit "$d" "$2"
  t_begin "$1"
  assert_exit 1 python3 "$d/tools/build.py"
  assert_contains "$ASSERT_OUT" "$3" "failure text"
  assert_eq "$before" "$(sum_of "$d/install.sh")" "install.sh untouched by a failed build"
  t_end
}

expect_build_fail "REQ-INS-001 components.json: a duplicate id fails and is named" \
  "d['files'].append(dict(d['files'][0]))" "duplicate id 'agent_builder'"
expect_build_fail "REQ-INS-001 components.json: an unknown policy fails and is named" \
  "d['files'][1]['policy'] = 'overwrite'" "unknown policy 'overwrite'"
expect_build_fail "REQ-INS-001 components.json: '..' in a dest fails and is named" \
  "d['files'][1]['dest'] = '../escape.md'" "(id 'agent_scout') dest: path '../escape.md' holds '..'"
expect_build_fail "REQ-INS-001 components.json: an absolute src fails and is named" \
  "d['files'][1]['src'] = '/etc/hosts'" "is an absolute path"
expect_build_fail "REQ-INS-001 components.json: a backslash in a dest fails and is named" \
  "d['files'][1]['dest'] = 'agents\\\\scout.md'" "holds a backslash"
expect_build_fail "REQ-INS-001 components.json: an unknown harness fails and is named" \
  "d['files'][1]['harness'] = 'gemini'" "unknown harness 'gemini'"
expect_build_fail "REQ-INS-001 components.json: an unknown component fails and is named" \
  "d['files'][1]['component'] = 'extras'" "unknown component 'extras'"
expect_build_fail "REQ-INS-001 components.json: wire on a Codex file fails and is named" \
  "d['files'][-1]['wire'] = [{'event': 'Stop', 'matcher': '', 'args': '', 'timeout': 5}]" "wire is allowed on claude files only"
expect_build_fail "REQ-INS-001 components.json: a missing src fails and is named" \
  "d['files'][1]['src'] = 'claude/agents/nothing.md'" "payload/claude/agents/nothing.md"
expect_build_fail "REQ-INS-001 components.json: a shared dest without select fails and is named" \
  "d['files'][5].pop('select')" "agents/judge.md"
expect_build_fail "REQ-INS-001 components.json: a component requiring an unknown component fails" \
  "d['components']['hook_nudge']['requires'] = ['nothing']" "requires unknown component 'nothing'"
expect_build_fail "REQ-INS-001 components.json: an unknown key in a file entry fails (catches typos)" \
  "d['files'][1]['polcy'] = 'agent'" "unknown key 'polcy'"
expect_build_fail "REQ-CDX-001.2 a model alias missing from codex_models fails the build" \
  "del d['codex_models']['haiku']" "model alias 'haiku' is not in codex_models"

t_begin "REQ-INS-001 components.json: invalid JSON fails and is named"
new_fixture; d="$FX"
printf '{ not json\n' > "$d/payload/components.json"
assert_exit 1 python3 "$d/tools/build.py"
assert_contains "$ASSERT_OUT" "payload/components.json: not valid JSON"
t_end

t_begin "REQ-EFF-001 an agent file with no effort line fails the build and is named"
new_fixture; d="$FX"
file_edit "$d/payload/claude/agents/critic.md" "t = t.replace('effort: xhigh\n', '', 1)"
assert_exit 1 python3 "$d/tools/build.py"
assert_contains "$ASSERT_OUT" "payload/claude/agents/critic.md"
assert_contains "$ASSERT_OUT" "no effort: line"
t_end

t_begin "REQ-EFF-001 an agent file with effort: max fails the build and is named"
new_fixture; d="$FX"
file_edit "$d/payload/claude/agents/architect.md" "t = t.replace('effort: xhigh', 'effort: max', 1)"
assert_exit 1 python3 "$d/tools/build.py"
assert_contains "$ASSERT_OUT" "payload/claude/agents/architect.md"
assert_contains "$ASSERT_OUT" "effort: max is not allowed"
t_end

t_begin "REQ-EFF-001 the judge files are checked for effort too (never max)"
new_fixture; d="$FX"
file_edit "$d/payload/claude/agents/judge-rung1.md" "t = t.replace('effort: xhigh', 'effort: max', 1)"
assert_exit 1 python3 "$d/tools/build.py"
assert_contains "$ASSERT_OUT" "payload/claude/agents/judge-rung1.md"
t_end

t_begin "REQ-INS-001 a payload file that components.json does not list fails the build and is named"
new_fixture; d="$FX"
printf 'stray\n' > "$d/payload/claude/conductor/stray.md"
assert_exit 1 python3 "$d/tools/build.py"
assert_contains "$ASSERT_OUT" "payload/claude/conductor/stray.md: not listed in components.json"
t_end

# ---------------------------------------------------------------- Codex agents

t_begin "REQ-CDX-001.1 4 TOML files are generated with the mapped model ids, none for the judge"
ls_out="$(cd "$REPO/payload/codex/agents" && ls | tr '\n' ' ')"
assert_eq "architect.toml builder.toml critic.toml scout.toml " "$ls_out" "codex agents"
cmodel() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['codex_models'][sys.argv[2]])" "$REPO/payload/components.json" "$1"; }
assert_contains "$(grep '^model' "$REPO/payload/codex/agents/builder.toml")" "model = \"$(cmodel sonnet)\""
assert_contains "$(grep '^model' "$REPO/payload/codex/agents/critic.toml")" "model = \"$(cmodel sonnet)\""
assert_contains "$(grep '^model' "$REPO/payload/codex/agents/scout.toml")" "model = \"$(cmodel haiku)\""
assert_contains "$(grep '^model' "$REPO/payload/codex/agents/architect.toml")" "model = \"$(cmodel opus)\""
t_end

t_begin "REQ-CDX-001.3 the generated Codex files hold 0 occurrences of gpt-5.4, gpt-5.4-mini and gpt-5.5"
assert_eq 0 "$(grep -rEc 'gpt-5\.4|gpt-5\.5' "$REPO/payload/codex/agents" | awk -F: '{s += $2} END {print s + 0}')" "hits"
t_end

t_begin "REQ-CDX-001 TOML: read-only sandbox for agents without write tools, bodies substituted"
assert_eq 0 "$(grep -c '^sandbox_mode' "$REPO/payload/codex/agents/builder.toml")" "builder is not read-only"
for n in scout critic architect; do
  assert_eq 1 "$(grep -c '^sandbox_mode = "read-only"$' "$REPO/payload/codex/agents/$n.toml")" "$n read-only"
done
assert_eq 0 "$(grep -rc '(Skill tool)\|Agent tool' "$REPO/payload/codex/agents" | awk -F: '{s += $2} END {print s + 0}')" "substitutions left"
assert_eq 0 "$(grep -c '^effort\|model_reasoning_effort' "$REPO/payload/codex/agents/builder.toml")" "no effort key without codex_effort"
t_end

t_begin "REQ-CDX-001 TOML: every generated file parses and round-trips the Claude agent text"
out="$(python3 - "$REPO" <<'PYEOF'
import re, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1] + "/tools")
import build
try:
    import tomllib
except ImportError:
    tomllib = None
root = sys.argv[1] + "/payload/"
bad = []
for name in ("builder", "scout", "critic", "architect"):
    toml_text = open(root + "codex/agents/%s.toml" % name, encoding="utf-8").read()
    md = open(root + "claude/agents/%s.md" % name, encoding="utf-8").read()
    fm, body = build.parse_frontmatter(md)
    want = body.replace(" (Skill tool)", "").replace("Agent tool", "spawn_agent tool").strip("\n") + "\n"
    # no seat names a Codex effort here, so the Claude effort sentence becomes the no-pin one
    want = re.sub(r"(?<=Effort: )you run at (?:low|medium|high|xhigh)(?=\.)",
                  "your effort is whatever your Codex session or config sets", want)
    mine = build.minimal_toml_parse(toml_text)
    parsed = [mine]
    if tomllib is not None:
        parsed.append(tomllib.loads(toml_text))
    for p in parsed:
        if p["developer_instructions"] != want or p["name"] != name or p["description"] != fm["description"]:
            bad.append(name)
print("tomllib" if tomllib else "minimal", "bad=%s" % ",".join(bad))
PYEOF
)"
assert_contains "$out" "bad=" "parse run"
assert_not_contains "$out" "bad=b" "no builder mismatch"
assert_eq "bad=" "${out#* }" "files that did not round-trip ($out)"
t_end

t_begin "REQ-CDX-001 TOML substitutions: '(Skill tool)' leaves with its space, 'Agent tool' becomes 'spawn_agent tool', nothing else changes"
new_fixture; d="$FX"
file_edit "$d/payload/claude/agents/scout.md" "t = t.replace('Rules:', 'Rules: use it (Skill tool) and the Agent tool, not the agent tool or Agent tools', 1)"
assert_exit 0 python3 "$d/tools/build.py"
assert_contains "$(cat "$d/payload/codex/agents/scout.toml")" "Rules: use it and the spawn_agent tool, not the agent tool or spawn_agent tools"
t_end

t_begin "REQ-CDX-001 codex_effort: a key is written only for a seat that has a value"
new_fixture; d="$FX"
cj_edit "$d" "d['codex_effort'] = {'critic': 'xhigh'}"
assert_exit 0 python3 "$d/tools/build.py"
assert_eq 1 "$(grep -c '^model_reasoning_effort = "xhigh"$' "$d/payload/codex/agents/critic.toml")" "critic effort"
assert_eq 0 "$(grep -c 'model_reasoning_effort' "$d/payload/codex/agents/builder.toml")" "builder effort"
t_end

t_begin "REQ-CDX-001 TOML escaping: a backslash and a quote in an agent survive the round trip"
new_fixture; d="$FX"
file_edit "$d/payload/claude/agents/scout.md" "t = t.replace('Rules:', 'Rules: \"quoted\" and a back\\\\slash \\\\n:', 1)"
assert_exit 0 python3 "$d/tools/build.py"
assert_contains "$(cat "$d/payload/codex/agents/scout.toml")" 'back\\slash'
t_end

t_begin "REQ-CDX-001 TOML: a body holding a triple quote fails the build and is named"
new_fixture; d="$FX"
file_edit "$d/payload/claude/agents/scout.md" "t = t.replace('Rules:', 'Rules: \"\"\"', 1)"
assert_exit 1 python3 "$d/tools/build.py"
assert_contains "$ASSERT_OUT" "payload/claude/agents/scout.md"
t_end

t_begin "REQ-INS-001 facts.json holds the release facts of components.json (exact values)"
out="$(python3 - "$REPO/payload/claude/conductor/lib/facts.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
f = d["facts"]
print(d["version"], f["floor_opus_pin"], f["floor_sonnet_pin"], f["floor_haiku55"], f["floor_fable"], f["floor_per_call_effort"],
      d["update"]["host"] + d["update"]["path"], d["report"]["repo"], len(f["provider_vars"]), len(f["provider_block_vars"]))
PYEOF
)"
assert_eq "0.4.0 2.1.280 2.1.284 2.1.293 2.1.257 2.1.292 raw.githubusercontent.com/akaCT/conductor/main/install.sh akaCT/conductor 5 2" "$out" "facts"
assert_eq "2.1.280|2.1.284|2.1.293|2.1.257|2.1.292" "$( . "$LIB"; echo "$FLOOR_OPUS_PIN|$FLOOR_SONNET_PIN|$FLOOR_HAIKU55|$FLOOR_FABLE|$FLOOR_PER_CALL_EFFORT")" "installer constants"
assert_eq "raw.githubusercontent.com|/akaCT/conductor/main/install.sh|akaCT/conductor" "$( . "$LIB"; echo "$UPDATE_HOST|$UPDATE_PATH|$REPORT_REPO")" "update constants"
assert_eq "CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_ANTHROPIC_AWS CLAUDE_CODE_USE_MANTLE|ANTHROPIC_BASE_URL CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST" "$( . "$LIB"; echo "$PROVIDER_VARS|$PROVIDER_BLOCK_VARS")" "provider vars"
t_end

# ---------------------------------------------------------------- prior hashes

t_begin "REQ-INS-001 prior-hashes.txt is seeded with the 14 files the 0.3.0 installer wrote"
assert_eq 14 "$(grep -c '^[0-9a-f]\{64\}  0\.3\.0  \(claude\|codex\):' "$REPO/installer/prior-hashes.txt")" "0.3.0 lines"
assert_eq 14 "$(wc -l < "$REPO/installer/prior-hashes.txt" | tr -d ' ')" "all lines"
assert_contains "$(cat "$REPO/installer/prior-hashes.txt")" "30f90dd636d4147774912e00572ad07d1afb127561f165743a525b6f9abf1556  0.3.0  claude:agents/builder.md"
assert_contains "$(cat "$REPO/installer/prior-hashes.txt")" "d915cc95d6ca8f47ae297713ed46d4e5c5d99ddd29fc3c61e263bdf305f2b5b0  0.3.0  claude:skills/conductor/VERSION"
assert_eq "$(printf '0.3.0\n' | shasum -a 256 | awk '{print $1}')" "d915cc95d6ca8f47ae297713ed46d4e5c5d99ddd29fc3c61e263bdf305f2b5b0" "0.3.0 VERSION hash"
t_end

t_begin "REQ-INS-001 the 0.3.0 installer fixture is the committed file (1147 lines, exact hash)"
assert_eq "8882587474eb3d75216c482460da999fb0173b953b9699cdc3eeae5c7807087d 1147" "$(echo "$(sum_of "$HERE/fixtures/install-0.3.0.sh") $(wc -l < "$HERE/fixtures/install-0.3.0.sh" | tr -d ' ')")" "fixture"
t_end

t_begin "REQ-INS-001 --record-release appends the current hashes once (idempotent) and rebuilds"
new_fixture; d="$FX"
assert_exit 0 python3 "$d/tools/build.py" --record-release
assert_eq 38 "$(grep -c '^[0-9a-f]\{64\}  0\.4\.0  ' "$d/installer/prior-hashes.txt")" "0.4.0 lines (37 files and 1 also copy)"
assert_eq 14 "$(grep -c '  0\.3\.0  ' "$d/installer/prior-hashes.txt")" "0.3.0 lines kept"
assert_exit 0 python3 "$d/tools/build.py" --check
sum1="$(sum_of "$d/installer/prior-hashes.txt")"
assert_exit 0 python3 "$d/tools/build.py" --record-release
assert_eq "$sum1" "$(sum_of "$d/installer/prior-hashes.txt")" "second run changes nothing"
assert_contains "$(cat "$d/installer/prior-hashes.txt")" "  0.4.0  claude:conductor/defaults.default.md"
assert_contains "$(cat "$d/installer/prior-hashes.txt")" "  0.4.0  codex:skills/conductor/SKILL.md"
assert_exit 2 python3 "$d/tools/build.py" --record-release --check
t_end

# ---------------------------------------------------------------- smoke: the generated installer

t_begin "smoke: bash -n passes on install.sh and every fragment-derived section runs under /bin/bash 3.2"
assert_exit 0 /bin/bash -n "$REPO/install.sh"
assert_contains "$(/bin/bash --version | head -1)" "version 3.2" "bash used for the suite"
t_end

t_begin "smoke: --help exits 0 and prints the usage"
before="$(sandbox_tree_sum "$SBX/home")"
assert_exit 0 /bin/bash "$REPO/install.sh" --help
assert_contains "$ASSERT_OUT" "Conductor installer v0.4.0"
assert_contains "$ASSERT_OUT" "--judge-rung=1|3"
assert_eq "$before" "$(sandbox_tree_sum "$SBX/home")" "sandbox unchanged"
t_end

t_begin "smoke: --judge-rung=opus exits 2, names the allowed values, writes nothing"
before="$(sandbox_tree_sum "$SBX/home")"
assert_exit 2 /bin/bash "$REPO/install.sh" --judge-rung=opus
assert_contains "$ASSERT_OUT" "--judge-rung must be 1 or 3 (got: opus)"
assert_exit 2 /bin/bash "$REPO/install.sh" --judge-rung=2
assert_exit 2 /bin/bash "$REPO/install.sh" --judge-rung
assert_contains "$ASSERT_OUT" "--judge-rung=1 or --judge-rung=3"
assert_eq "$before" "$(sandbox_tree_sum "$SBX/home")" "sandbox unchanged"
t_end

t_begin "smoke: an unknown flag, or a bad combination, exits 2 before any write"
before="$(sandbox_tree_sum "$SBX/home")"
assert_exit 2 /bin/bash "$REPO/install.sh" --frobnicate
assert_contains "$ASSERT_OUT" "unknown argument: --frobnicate"
assert_exit 2 /bin/bash "$REPO/install.sh" --full --core
assert_exit 2 /bin/bash "$REPO/install.sh" --status --uninstall
assert_exit 2 /bin/bash "$REPO/install.sh" update --full
assert_exit 2 /bin/bash "$REPO/install.sh" --check
assert_exit 2 /bin/bash "$REPO/install.sh" --full --frobnicate
assert_eq "$before" "$(sandbox_tree_sum "$SBX/home")" "sandbox unchanged"
t_end

t_begin "smoke: every documented flag and subcommand parses (exit 0), and writes only inside the roots it was given"
before="$(sandbox_tree_sum "$SBX/home")"
bad=""
for args in "" "--full" "--core" "--dry-run" "--status" "--uninstall" "-u" "--replace-modified" "--apply-effort-pins" \
  "--judge-rung=1" "--judge-rung=3" "--full --dry-run --judge-rung=1" "update" "update --check" "-h"; do
  rm -rf "$SBX/smoke"
  mkdir -p "$SBX/smoke/claude" "$SBX/smoke/codex" "$SBX/smoke/agents"
  # shellcheck disable=SC2086
  CLAUDE_DIR="$SBX/smoke/claude" CLAUDE_CONFIG_DIR="$SBX/smoke/claude" CODEX_DIR="$SBX/smoke/codex" \
    CODEX_HOME="$SBX/smoke/codex" AGENTS_SKILLS_DIR="$SBX/smoke/agents" CONDUCTOR_YES=1 \
    /bin/bash "$REPO/install.sh" $args < /dev/null > /dev/null 2>&1 || bad="$bad [$args]"
done
rm -rf "$SBX/smoke"
assert_eq "" "$bad" "arguments that failed"
assert_eq "$before" "$(sandbox_tree_sum "$SBX/home")" "the default roots are unchanged"
t_end

t_begin "smoke: do_install calls the steps in the contract order"
order="$( . "$LIB"
  for fn in detect_cc_version detect_provider detect_existing print_plan select_components resolve_judge_rung \
    install_core_files write_doctrine_block install_judge gate_offer_pins install_full_tier install_codex \
    manifest_finish print_summary; do
    eval "$fn() { echo \"$fn \$*\"; }"
  done
  do_install | tr '\n' ',')"
assert_eq "detect_cc_version ,detect_provider ,detect_existing ,print_plan ,select_components ,resolve_judge_rung ,install_core_files ,write_doctrine_block claude,install_judge ,gate_offer_pins ,install_full_tier ,install_codex ,manifest_finish ,print_summary ," "$order" "call order"
t_end

t_begin "smoke: output has 0 escape sequences when piped, and when NO_COLOR is set on a terminal"
assert_eq 0 "$(/bin/bash "$REPO/install.sh" --help | LC_ALL=C grep -c "$(printf '\033')" || true)" "escapes when piped"
out="$(sandbox_pty env TERM=xterm /bin/bash -c ". '$LIB'; ok hello; banner")"
assert_eq 1 "$(printf '%s' "$out" | LC_ALL=C grep -c "$(printf '\033')" | awk '{print ($1 > 0) ? 1 : 0}')" "escapes on a terminal without NO_COLOR (positive control)"
out="$(sandbox_pty env TERM=xterm NO_COLOR=1 /bin/bash -c ". '$LIB'; ok hello; banner")"
assert_eq 0 "$(printf '%s' "$out" | LC_ALL=C grep -c "$(printf '\033')" || true)" "escapes on a terminal with NO_COLOR"
assert_contains "$out" "hello"
out="$(sandbox_pty env TERM=dumb /bin/bash -c ". '$LIB'; ok hello")"
assert_eq 0 "$(printf '%s' "$out" | LC_ALL=C grep -c "$(printf '\033')" || true)" "escapes on TERM=dumb"
t_end

# ---------------------------------------------------------------- fragments: prompts

t_begin "skeleton: ask_yn and ask_str read /dev/tty when stdin is not a terminal"
out="$(PTY_INPUT=$'y\n' sandbox_pty /bin/bash -c ". '$LIB'; echo piped | { ask_yn 'Go on?' n && echo ANSWER=yes || echo ANSWER=no; }")"
assert_contains "$out" "ANSWER=yes" "typed y over default n"
assert_contains "$out" "Go on?"
out="$(PTY_INPUT=$'\n' sandbox_pty /bin/bash -c ". '$LIB'; echo piped | { ask_yn 'Go on?' n && echo ANSWER=yes || echo ANSWER=no; }")"
assert_contains "$out" "ANSWER=no" "Enter keeps the default"
out="$(PTY_INPUT=$'n\n' sandbox_pty /bin/bash -c ". '$LIB'; echo piped | { ask_yn 'Go on?' y && echo ANSWER=yes || echo ANSWER=no; }")"
assert_contains "$out" "ANSWER=no" "typed n over default y"
out="$(PTY_INPUT=$'bob\n' sandbox_pty /bin/bash -c ". '$LIB'; echo piped | { v=\$(ask_str 'Name?' dflt); echo NAME=\$v; }")"
assert_contains "$out" "NAME=bob" "typed answer"
out="$(PTY_INPUT=$'\n' sandbox_pty /bin/bash -c ". '$LIB'; echo piped | { v=\$(ask_str 'Name?' dflt); echo NAME=\$v; }")"
assert_contains "$out" "NAME=dflt" "default answer"
t_end

t_begin "skeleton: with CONDUCTOR_YES=1, or with no terminal, prompts take the default and never block"
out="$(PTY_INPUT=$'n\n' sandbox_pty env CONDUCTOR_YES=1 /bin/bash -c ". '$LIB'; ask_yn 'Go on?' y && echo ANSWER=yes || echo ANSWER=no")"
assert_contains "$out" "ANSWER=yes" "CONDUCTOR_YES takes the default (y)"
out="$(sandbox_notty /bin/bash -c ". '$LIB'; ask_yn 'Go on?' y && echo ANSWER=yes || echo ANSWER=no; echo NAME=\$(ask_str 'Name?' dflt)" < /dev/null 2>&1)"
assert_contains "$out" "ANSWER=yes"
assert_contains "$out" "NAME=dflt"
t_end

# ---------------------------------------------------------------- fragments: detection

t_begin "skeleton: detect_roots follows CLAUDE_DIR, CLAUDE_CONFIG_DIR, CODEX_HOME and a missing folder"
out="$( . "$LIB"; unset CLAUDE_DIR CODEX_DIR; CLAUDE_CONFIG_DIR="$SBX/cfg-claude"; CODEX_HOME="$SBX/cfg-codex"; AGENTS_SKILLS_DIR="$SBX/agents"
  mkdir -p "$SBX/cfg-claude"; detect_roots; echo "$CLAUDE_DIR|$CODEX_DIR|$AGENTS_SKILLS_DIR|$HAVE_CLAUDE|$HAVE_CODEX")"
assert_eq "$SBX/cfg-claude|$SBX/cfg-codex|$SBX/agents|1|0" "$out" "roots"
out="$( . "$LIB"; unset CLAUDE_DIR CLAUDE_CONFIG_DIR CODEX_DIR CODEX_HOME AGENTS_SKILLS_DIR; detect_roots; echo "$CLAUDE_DIR|$CODEX_DIR|$AGENTS_SKILLS_DIR")"
assert_eq "$HOME/.claude|$HOME/.codex|$HOME/.agents" "$out" "defaults under HOME"
out="$( . "$LIB"; CLAUDE_DIR=$CLAUDE_DIR; detect_roots; echo "$STAMP")"
assert_contains "$out" "." "stamp has a PID suffix"
assert_exit "!0" env -u HOME -u CLAUDE_DIR -u CLAUDE_CONFIG_DIR /bin/bash -c ". '$LIB'; detect_roots"
assert_contains "$ASSERT_OUT" "HOME is not set"
assert_exit "!0" env CLAUDE_DIR=relative/path /bin/bash -c ". '$LIB'; detect_roots"
assert_contains "$ASSERT_OUT" "must be absolute"
t_end

t_begin "skeleton: detect_os names darwin, linux, windows and other"
for pair in "Darwin:darwin" "Linux:linux" "MINGW64_NT-10.0:windows" "MSYS_NT-10.0:windows" "CYGWIN_NT-10.0:windows" "FreeBSD:other"; do
  sandbox_fake_uname "${pair%%:*}"
  assert_eq "${pair#*:}" "$( . "$LIB"; detect_os; echo "$OS_KIND")" "uname ${pair%%:*}"
done
sandbox_clear_fakes
t_end

py_case() { # $1=fake python version (empty: none) -> prints PY=... and REASON=...
  sandbox_clear_fakes
  if [ -n "$1" ]; then sandbox_fake_python "$1"; fi
  ( . "$LIB"; OS_KIND=linux; detect_python; echo "PY=$PY"; echo "REASON=$PY_REASON" )
  sandbox_clear_fakes
}

t_begin "skeleton: detect_python accepts 3.9 or later and says why it rejects anything else"
out="$(py_case 3.9.1)"
assert_eq "PY=$SBX/bin/python3
REASON=" "$out" "3.9.1 accepted"
out="$(py_case 3.12.4)"
assert_contains "$out" "PY=$SBX/bin/python3" "3.12.4 accepted"
out="$(py_case 3.8.10)"
assert_contains "$out" "PY=
" "3.8.10 rejected"
assert_contains "$out" "is version 3.8.10; 3.9 or newer is needed"
out="$(py_case 2.7.18)"
assert_contains "$out" "is version 2.7.18"
out="$(py_case garbage)"
assert_contains "$out" "did not run" "unparseable output"
out="$(py_case 3.9)"
assert_contains "$out" "PY=$SBX/bin/python3" "major.minor only"
t_end

t_begin "skeleton: detect_python reports no python3 on PATH (REQ-INS-003 G-13)"
sandbox_clear_fakes
sandbox_no_python
out="$( . "$LIB"; OS_KIND=linux; detect_python; echo "PY=$PY"; echo "REASON=$PY_REASON")"
sandbox_clear_fakes
assert_contains "$out" "PY=
"
assert_contains "$out" "python3 was not found on your PATH"
t_end

if [ "$(uname -s)" = "Darwin" ] && [ -x /usr/bin/python3 ]; then
  t_begin "skeleton: detect_python treats /usr/bin/python3 as the stub when xcode-select -p fails (contract section 7)"
  sandbox_clear_fakes
  sandbox_fake_xcode_select FAIL
  out="$( export PATH="$SBX/bin:/usr/bin:/bin"; . "$LIB"; OS_KIND=darwin; detect_python; echo "PY=$PY"; echo "REASON=$PY_REASON")"
  assert_contains "$out" "PY=
"
  assert_contains "$out" "Command Line Tools stub"
  sandbox_clear_fakes
  sandbox_fake_xcode_select OK
  out="$( export PATH="$SBX/bin:/usr/bin:/bin"; . "$LIB"; OS_KIND=darwin; detect_python; echo "PY=$PY")"
  assert_contains "$out" "PY=/usr/bin/python3" "usable when xcode-select -p succeeds"
  sandbox_clear_fakes
  t_end
fi

t_begin "skeleton: detect_python finds an absolute, runnable python3 on the real PATH"
out="$( . "$LIB"; detect_os; detect_python; echo "$PY")"
case "$out" in /*) ok_abs=1 ;; *) ok_abs=0 ;; esac
assert_eq 1 "$ok_abs" "PY is absolute ($out)"
assert_exit 0 "$out" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)'
t_end

t_begin "skeleton: detect_interactive is 0 with no terminal and 1 with a terminal"
out="$(sandbox_notty /bin/bash -c ". '$LIB'; detect_interactive; echo INTERACTIVE=\$INTERACTIVE" < /dev/null 2>&1)"
assert_contains "$out" "INTERACTIVE=0"
out="$(sandbox_pty /bin/bash -c ". '$LIB'; detect_interactive; echo INTERACTIVE=\$INTERACTIVE")"
assert_contains "$out" "INTERACTIVE=1"
t_end

# ---------------------------------------------------------------- fragments: file helpers

t_begin "skeleton: sha256_of prints the digest of a file and fails on a missing file"
printf 'abc' > "$SBX/abc.txt"
assert_eq "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" "$( . "$LIB"; sha256_of "$SBX/abc.txt")" "sha256 of abc"
assert_exit 1 /bin/bash -c ". '$LIB'; sha256_of '$SBX/missing.txt'"
t_end

t_begin "skeleton: resolve_link follows a chain without readlink -f, and stops on a loop"
mkdir -p "$SBX/rl"
printf 'x\n' > "$SBX/rl/real"
ln -sf real "$SBX/rl/b"
ln -sf b "$SBX/rl/a"
ln -sf "$SBX/rl/a" "$SBX/rl/abs"
ln -sf loop2 "$SBX/rl/loop1"
ln -sf loop1 "$SBX/rl/loop2"
ln -sf nowhere "$SBX/rl/dangling"
assert_eq "$SBX/rl/real" "$( . "$LIB"; resolve_link "$SBX/rl/a")" "relative chain"
assert_eq "$SBX/rl/real" "$( . "$LIB"; resolve_link "$SBX/rl/abs")" "absolute then relative"
assert_eq "$SBX/rl/real" "$( . "$LIB"; resolve_link "$SBX/rl/real")" "not a link"
assert_eq "$SBX/rl/nowhere" "$( . "$LIB"; resolve_link "$SBX/rl/dangling")" "dangling"
assert_exit 1 /bin/bash -c ". '$LIB'; resolve_link '$SBX/rl/loop1'"
t_end

t_begin "skeleton: atomic_write writes the mode asked for whatever the umask, leaves no temp file, keeps a link a link"
mkdir -p "$SBX/aw"
( . "$LIB"; umask 077; printf 'hello\n' | atomic_write "$SBX/aw/new.txt" 644; printf '#!/bin/sh\n' | atomic_write "$SBX/aw/run.sh" 755 )
assert_eq "hello" "$(cat "$SBX/aw/new.txt")" "content"
assert_mode "$SBX/aw/new.txt" 644
assert_mode "$SBX/aw/run.sh" 755
printf 'v1\n' > "$SBX/aw/real.txt"
ln -sf real.txt "$SBX/aw/link.txt"
( . "$LIB"; printf 'v2\n' | atomic_write "$SBX/aw/link.txt" 640 )
assert_eq 1 "$([ -L "$SBX/aw/link.txt" ] && echo 1 || echo 0)" "link is still a link"
assert_eq "v2" "$(cat "$SBX/aw/real.txt")" "target updated"
assert_mode "$SBX/aw/real.txt" 640
assert_eq "link.txt new.txt real.txt run.sh" "$(ls -A "$SBX/aw" | tr '\n' ' ' | sed 's/ $//')" "no temp residue"
( . "$LIB"; printf 'deep\n' | atomic_write "$SBX/aw/sub/dir/file.txt" 644 )
assert_eq "deep" "$(cat "$SBX/aw/sub/dir/file.txt")" "parent folders made"
t_end

t_begin "REQ-INS-002.3 backup_file copies into {root}/conductor/backups (mode 700), keeps the mode, writes nothing beside the file"
mkdir -p "$CLAUDE_DIR/agents"
printf 'mine\n' > "$CLAUDE_DIR/agents/builder.md"
chmod 640 "$CLAUDE_DIR/agents/builder.md"
bak="$( . "$LIB"; detect_roots; backup_file "$CLAUDE_DIR/agents/builder.md")"
case "$bak" in "$CLAUDE_DIR/conductor/backups/agents__builder.md.bak."*) ok_name=1 ;; *) ok_name=0 ;; esac
assert_eq 1 "$ok_name" "backup path ($bak)"
assert_file "$bak"
assert_eq "mine" "$(cat "$bak")" "backup content"
assert_mode "$bak" 640
assert_mode "$CLAUDE_DIR/conductor/backups" 700
assert_eq "builder.md" "$(ls -A "$CLAUDE_DIR/agents")" "nothing beside the file"
out="$( . "$LIB"; detect_roots; backup_file "$CLAUDE_DIR/agents/builder.md"; echo; backup_file "$CLAUDE_DIR/agents/builder.md")"
assert_eq 3 "$(ls "$CLAUDE_DIR/conductor/backups" | wc -l | tr -d ' ')" "same-second backups get distinct names"
printf 'x\n' > "$SBX/outside.txt"
assert_exit 1 /bin/bash -c ". '$LIB'; detect_roots; backup_file '$SBX/outside.txt'"
assert_no_file "$SBX/conductor"
t_end

t_begin "REQ-INS-002 install_payload_file (policy replace) writes with the mode, leaves identical files, keeps edited ones"
rm -rf "$CLAUDE_DIR" "$AGENTS_SKILLS_DIR"
mkdir -p "$CLAUDE_DIR" "$AGENTS_SKILLS_DIR"
out="$( . "$LIB"; detect_roots; install_payload_file launcher; install_payload_file model_notes; install_payload_file codex_skill)"
assert_file "$CLAUDE_DIR/conductor/bin/conductor"
assert_mode "$CLAUDE_DIR/conductor/bin/conductor" 755
assert_mode "$CLAUDE_DIR/conductor/model-notes.md" 644
assert_eq "$(cat "$REPO/payload/claude/conductor/bin/conductor")" "$(cat "$CLAUDE_DIR/conductor/bin/conductor")" "launcher content"
assert_file "$AGENTS_SKILLS_DIR/skills/conductor/SKILL.md"
assert_eq "$(sum_of "$REPO/payload/codex/skills/conductor/SKILL.md")" "$(sum_of "$AGENTS_SKILLS_DIR/skills/conductor/SKILL.md")" "codex skill under the skills root"
assert_no_file "$CLAUDE_DIR/conductor/backups" "no backup for a fresh install"
out="$( . "$LIB"; detect_roots; install_payload_file launcher)"
assert_contains "$out" "(unchanged)"
assert_no_file "$CLAUDE_DIR/conductor/backups" "no backup for an unchanged file"
printf 'edited\n' > "$CLAUDE_DIR/conductor/model-notes.md"
out="$( . "$LIB"; detect_roots; CONDUCTOR_YES=1 install_payload_file model_notes)"
assert_contains "$out" "kept conductor/model-notes.md (you changed it)"
assert_eq "edited" "$(cat "$CLAUDE_DIR/conductor/model-notes.md")" "an edited file is kept"
assert_no_file "$CLAUDE_DIR/conductor/backups" "no backup when nothing is replaced"
out="$( . "$LIB"; detect_roots; OPT_REPLACE_MODIFIED=1 install_payload_file model_notes)"
assert_contains "$out" "backup: $CLAUDE_DIR/conductor/backups/"
assert_eq "$(cat "$REPO/payload/claude/conductor/model-notes.md")" "$(cat "$CLAUDE_DIR/conductor/model-notes.md")" "replaced"
assert_eq "edited" "$(cat "$CLAUDE_DIR/conductor/backups/conductor__model-notes.md.bak."*)" "backup holds the edit"
t_end

t_begin "REQ-INS-002 install_payload_file with DRY_RUN=1 changes nothing, and through a link it writes the target"
before="$(sandbox_tree_sum "$SBX/home")"
out="$( . "$LIB"; detect_roots; DRY_RUN=1; install_payload_file runbook_review_ladder; install_payload_file launcher)"
assert_contains "$out" "would write conductor/runbooks/review-ladder.md"
assert_eq "$before" "$(sandbox_tree_sum "$SBX/home")" "sandbox unchanged"
mkdir -p "$SBX/elsewhere" "$CLAUDE_DIR/conductor/runbooks"
printf 'old\n' > "$SBX/elsewhere/target.md"
ln -sf "$SBX/elsewhere/target.md" "$CLAUDE_DIR/conductor/runbooks/review-ladder.md"
( . "$LIB"; detect_roots; OPT_REPLACE_MODIFIED=1 install_payload_file runbook_review_ladder ) > /dev/null
assert_eq 1 "$([ -L "$CLAUDE_DIR/conductor/runbooks/review-ladder.md" ] && echo 1 || echo 0)" "link kept"
assert_eq "$(cat "$REPO/payload/claude/conductor/runbooks/review-ladder.md")" "$(cat "$SBX/elsewhere/target.md")" "target written"
t_end

# ---------------------------------------------------------------- the harness itself

t_begin "REQ-OPS-002.2 sandbox_guard aborts the suite when HOME is outside the sandbox"
assert_exit 99 /bin/bash -c ". '$HERE/lib/sandbox.sh'; SBX='$SBX'; HOME=/tmp/not-the-sandbox; sandbox_guard; echo SURVIVED"
assert_not_contains "$ASSERT_OUT" "SURVIVED"
assert_contains "$ASSERT_OUT" "HOME="
assert_exit 99 /bin/bash -c ". '$HERE/lib/sandbox.sh'; SBX='$SBX'; HOME='$SBX/home'; CLAUDE_DIR='$SBX/home/.claude'; CLAUDE_CONFIG_DIR='$SBX/home/.claude'; CODEX_DIR='$SBX/home/.codex'; CODEX_HOME='$SBX/home/.codex'; AGENTS_SKILLS_DIR=/other/home/.agents; sandbox_guard"
assert_contains "$ASSERT_OUT" "AGENTS_SKILLS_DIR="
assert_exit 99 /bin/bash -c ". '$HERE/lib/sandbox.sh'; sandbox_guard"
assert_exit 0 /bin/bash -c ". '$HERE/lib/sandbox.sh'; SBX='$SBX'; $(for v in HOME CLAUDE_DIR CLAUDE_CONFIG_DIR CODEX_DIR CODEX_HOME AGENTS_SKILLS_DIR; do eval "printf '%s=%s; ' $v \"\$$v\""; done) sandbox_guard"
t_end

t_begin "harness: sandbox_new clears provider and Conductor variables and roots everything under SBX"
out="$(CLAUDE_CODE_USE_BEDROCK=1 ANTHROPIC_BASE_URL=http://x CLAUDE_CODE_EFFORT_LEVEL=max CONDUCTOR_YES=1 NO_COLOR=1 CLAUDE_CODE_USE_MANTLE=1 /bin/bash -c ". '$HERE/lib/sandbox.sh'; sandbox_new; env | grep -E '^(CLAUDE_CODE_USE_|CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST|CLAUDE_CODE_EFFORT_LEVEL|ANTHROPIC_BASE_URL|CONDUCTOR_|NO_COLOR)=' | wc -l | tr -d ' '; echo \"\$HOME|\$CLAUDE_CONFIG_DIR|\$CODEX_HOME\"; sandbox_guard; echo GUARD_OK; sandbox_cleanup")"
assert_contains "$out" "0
" "variables cleared"
assert_contains "$out" "GUARD_OK"
t_end

t_begin "harness: sandbox_notty drops the terminal, keeps the exit code; sandbox_no_python drops python3; fakes work"
assert_exit 7 sandbox_notty /bin/bash -c 'exit 7' < /dev/null
assert_exit "!0" sandbox_notty /bin/bash -c ': < /dev/tty' < /dev/null
assert_exit 0 sandbox_pty /bin/bash -c 'test -t 0 && test -t 1'
sandbox_fake_claude 2.1.292
assert_eq "2.1.292 (Claude Code)" "$(claude --version)" "fake claude"
sandbox_clear_fakes
assert_eq "" "$( sandbox_no_python; command -v python3 || true)" "no python3 on the no-python PATH"
assert_contains "$( sandbox_no_python; command -v bash)" "bash" "bash still found"
sandbox_clear_fakes
assert_contains "$(command -v python3)" "python3" "real python3 back"
t_end

t_begin "harness: sandbox_tree_sum sees a changed byte, a changed mode, a new file and a link"
mkdir -p "$SBX/ts"
printf 'a\n' > "$SBX/ts/f"
s0="$(sandbox_tree_sum "$SBX/ts")"
printf 'b\n' > "$SBX/ts/f"
s1="$(sandbox_tree_sum "$SBX/ts")"
chmod 600 "$SBX/ts/f"
s2="$(sandbox_tree_sum "$SBX/ts")"
touch "$SBX/ts/g"
s3="$(sandbox_tree_sum "$SBX/ts")"
ln -s f "$SBX/ts/l"
s4="$(sandbox_tree_sum "$SBX/ts")"
assert_eq 5 "$( for s in "$s0" "$s1" "$s2" "$s3" "$s4"; do printf '%s\n' "$s" | shasum | cut -c1-8; done | sort -u | wc -l | tr -d ' ')" "5 distinct states"
t_end

t_summary
