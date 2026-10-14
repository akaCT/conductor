#!/bin/bash
# tests/test-release-fixes.sh: fixes from the review of the 0.4.0 release candidate. Each test is
# named with the review items it proves, and each one failed before its fix. The item ids are
# kept at the start of the names so a later pass can find (or strip) them in 1 place.
#
# Everything runs in the sandbox from tests/lib/sandbox.sh; nothing reads or writes a real
# config folder, and nothing touches the network.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/lib/sandbox.sh"
sandbox_new
trap sandbox_cleanup EXIT
sandbox_guard
. "$REPO/tests/fixtures/doctor/lib.sh"

DOCTOR_PY="$REPO/payload/claude/conductor/lib/doctor.py"
FACTS="$REPO/payload/claude/conductor/lib/facts.json"
LA="$REPO/payload/claude/conductor/bin/ledger-append"
RELCHECK="$REPO/tools/release-check.py"
export PYTHONDONTWRITEBYTECODE=1

flat() { printf '%s' "$1" | tr '\n' ' ' | tr -s ' '; }

# pycheck ARGS...: run the python on stdin; a failing assertion fails the open test
pycheck() {
  local out
  out="$(python3 -I -B - "$@" 2>&1)" || t_fail "$(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
}

# codex_doctor: the doctor on a Codex-only install under $CODEX_DIR; leaves the text in OUT
codex_doctor() { # [facts file]
  OUT="$("$SBX_PY" "$DOCTOR_PY" --facts "${1:-$FACTS}" --claude-dir "$SBX/none" --codex-dir "$CODEX_DIR" \
    --agents-dir "$AGENTS_SKILLS_DIR" --managed-settings "$SBX/managed.json" 2>&1 < /dev/null)"
  RC=$?
}

# ---------------------------------------------------------------------------------
# the /conductor skills
# ---------------------------------------------------------------------------------
t_begin "S2-2 O-34 C-14 Step 0 reflects a long prompt even when it holds a small job: the long rule comes before the small-job rule, in both skills"
pycheck "$REPO" <<'PYEOF'
import re, sys
repo = sys.argv[1]
for rel in ("payload/claude/skills/conductor/SKILL.md", "payload/codex/skills/conductor/SKILL.md"):
    text = open(repo + "/" + rel, encoding="utf-8").read()
    sec = re.search(r"(?ms)^## Step 0[^\n]*\n(.*?)(?=^## )", text).group(1)
    bullets = [b for b in sec.split("\n") if b.startswith("- ")]
    opens = [i for i, b in enumerate(bullets) if b.startswith("- Open")]
    longs = [i for i, b in enumerate(bullets) if b.startswith("- Long")]
    assert len(opens) == 1 and len(longs) == 1, (rel, opens, longs)
    assert "even when it holds a small job" in bullets[longs[0]], (rel, "long rule wording")
    small = [i for i, b in enumerate(bullets) if "small job" in b and i != longs[0]]
    assert len(small) == 1, (rel, "exactly 1 small-job rule", small)
    assert opens[0] < longs[0] < small[0], (rel, "order", opens, longs, small)
    assert "not long" in bullets[small[0]].lower(), (rel, "small-job rule applies only to a prompt that is not long")
    assert "A prompt that is long and open counts as open." in bullets[opens[0]], (rel, "open rule wording")
PYEOF
t_end

# ---------------------------------------------------------------------------------
# the doctor
# ---------------------------------------------------------------------------------
t_begin "O-9 the doctor prints each Codex agent's model id and the date the model map was checked"
fresh_roots 2.1.296
fx_codex_install
"$SBX_PY" - "$FACTS" "$SBX/facts-dated.json" <<'PYEOF'
import json, sys
f = json.load(open(sys.argv[1]))
f["facts"]["codex_map_checked_on"] = "2026-01-02"
json.dump(f, open(sys.argv[2], "w"), indent=2, sort_keys=True)
PYEOF
codex_doctor "$SBX/facts-dated.json"
assert_eq 0 "$RC" "exit status"
for a in builder scout critic architect; do
  assert_contains "$OUT" "  $a: effort not pinned, model fixture-model"
done
assert_contains "$OUT" "  Model map checked on 2026-01-02"
# the shipped agent files: the ids of the map in components.json, and the date the shipped facts hold
fresh_roots 2.1.296
fx_codex_install
cp "$REPO"/payload/codex/agents/*.toml "$CODEX_DIR/agents/"
want="$("$SBX_PY" - "$REPO/payload/components.json" <<'PYEOF'
import json, sys
c = json.load(open(sys.argv[1]))
m = c["codex_models"]
seats = {"builder": "sonnet", "critic": "sonnet", "scout": "haiku", "architect": "opus"}
for seat, alias in sorted(seats.items()):
    print("  %s: effort not pinned, model %s" % (seat, m[alias]))
print("  Model map checked on " + c["facts"]["codex_map_checked_on"])
PYEOF
)"
codex_doctor
while IFS= read -r ln; do
  [ -n "$ln" ] || continue
  assert_contains "$OUT" "$ln" "shipped agent files"
done <<EOF
$want
EOF
# an agent file with no model line, and a facts file with no date
"$SBX_PY" - "$FACTS" "$SBX/facts-nodate.json" <<'PYEOF'
import json, sys
f = json.load(open(sys.argv[1]))
f["facts"].pop("codex_map_checked_on", None)
json.dump(f, open(sys.argv[2], "w"), indent=2, sort_keys=True)
PYEOF
sed -i.bak '/^model = /d' "$CODEX_DIR/agents/scout.toml" && rm -f "$CODEX_DIR/agents/scout.toml.bak"
codex_doctor "$SBX/facts-nodate.json"
assert_contains "$OUT" "  scout: effort not pinned, model not found in the agent file"
assert_contains "$OUT" "  Model map check date: not recorded"
t_end

pins_off() { # a Claude install whose settings hold no effort pin and no top-level effort
  fresh_roots "${1:-2.1.296}"
  fx_claude_install
  printf '{}\n' > "$CLAUDE_DIR/settings.json"
}
NOPIN_LINE="    effort inherited from the session; no pin is set, so it runs at the model's default, medium (Opus 5.5)"

t_begin "J-6 O-17 with no effort pin and no effort variable the conductor line names the model default, and the warnings give the --apply-effort-pins command"
pins_off
run_doctor
assert_eq 0 "$RC" "exit status"
assert_contains "$OUT" "  conductor: opus, expected Opus 5.5"
assert_contains "$OUT" "$NOPIN_LINE"
f="$(flat "$OUT")"
assert_contains "$f" "No effort pin is set for Opus 5.5, so the conductor runs at the model's default, medium."
assert_contains "$f" "| bash -s -- --apply-effort-pins"
assert_not_contains "$f" "Warnings none"
# the seats whose agent file carries an effort do not get the line
n="$(printf '%s\n' "$OUT" | grep -c "no pin is set")"
assert_eq 1 "$n" "only the conductor seat inherits"
t_end

t_begin "J-6 O-17 a pin, an effort variable, an effort in project settings, a Claude Code below the floor or a cloud provider each keep the line and the warning away"
fresh_roots 2.1.296
fx_claude_install
run_doctor
assert_not_contains "$OUT" "no pin is set" "a settings pin"
assert_not_contains "$(flat "$OUT")" "--apply-effort-pins" "a settings pin"
pins_off
export CLAUDE_CODE_EFFORT_LEVEL=high
run_doctor
assert_not_contains "$OUT" "no pin is set" "an effort variable"
assert_not_contains "$(flat "$OUT")" "--apply-effort-pins" "an effort variable"
unset CLAUDE_CODE_EFFORT_LEVEL
pins_off
printf '{"env": {"CLAUDE_CODE_EFFORT_LEVEL": "high"}}\n' > "$CLAUDE_DIR/settings.json"
run_doctor
assert_not_contains "$OUT" "no pin is set" "an effort variable in the settings env block"
pins_off
mkdir -p "$SBX/proj/.claude"
printf '{"effortLevel": "high"}\n' > "$SBX/proj/.claude/settings.json"
run_doctor
assert_not_contains "$OUT" "no pin is set" "project settings"
pins_off 2.1.270
run_doctor
assert_not_contains "$OUT" "no pin is set" "below the floor"
assert_not_contains "$(flat "$OUT")" "--apply-effort-pins" "below the floor"
pins_off
export CLAUDE_CODE_USE_BEDROCK=1
run_doctor
assert_not_contains "$OUT" "no pin is set" "a cloud provider"
assert_not_contains "$(flat "$OUT")" "--apply-effort-pins" "a cloud provider"
unset CLAUDE_CODE_USE_BEDROCK
t_end

t_begin "S-2 the doctor warns when the python3 recorded for the hooks is missing or not executable, and not when it works"
fresh_roots 2.1.296
fx_claude_install
run_doctor
assert_not_contains "$(flat "$OUT")" "python3 recorded for the hooks" "a working python3"
COMPS='components=["core","full","hook_pointer","hook_nudge"]'
gone="$SBX/gone/venv/bin/python3"
fx_manifest "$CLAUDE_DIR" "$COMPS" "python3=\"$gone\""
run_doctor
assert_eq 0 "$RC" "warnings only exit 0"
assert_contains "$OUT" "  python3 for hooks: $gone (missing)"
assert_contains "$(flat "$OUT")" "The python3 recorded for the hooks ($gone) is missing or not executable."
mkdir -p "$SBX/plain"
printf '#!/bin/sh\n' > "$SBX/plain/python3"
chmod 644 "$SBX/plain/python3"
fx_manifest "$CLAUDE_DIR" "$COMPS" "python3=\"$SBX/plain/python3\""
run_doctor
assert_contains "$OUT" "  python3 for hooks: $SBX/plain/python3 (not executable)"
assert_contains "$(flat "$OUT")" "The python3 recorded for the hooks ($SBX/plain/python3) is missing or not executable."
mkdir -p "$SBX/dead"
ln -s "$SBX/dead/target" "$SBX/dead/python3"
fx_manifest "$CLAUDE_DIR" "$COMPS" "python3=\"$SBX/dead/python3\""
run_doctor
assert_contains "$OUT" "  python3 for hooks: $SBX/dead/python3 (missing)" "a link whose target is gone"
chmod 755 "$SBX/plain/python3"
fx_manifest "$CLAUDE_DIR" "$COMPS" "python3=\"$SBX/plain/python3\""
run_doctor
assert_not_contains "$(flat "$OUT")" "python3 recorded for the hooks" "an executable python3"
t_end

# ---------------------------------------------------------------------------------
# the Codex agent files
# ---------------------------------------------------------------------------------
t_begin "O-20 Codex agent files do not tell the model an effort it does not have, and a pinned effort is stated as pinned"
n="$(grep -ciE 'you run at (low|medium|high|xhigh)' "$REPO"/payload/codex/agents/*.toml | grep -vc ':0$' || true)"
assert_eq 0 "$n" "agent files that state an effort"
assert_contains "$(cat "$REPO/payload/codex/agents/builder.toml")" "Effort: your effort is whatever your Codex session or config sets."
assert_eq 0 "$(grep -c model_reasoning_effort "$REPO"/payload/codex/agents/builder.toml | tr -d ' ')" "no effort key in the shipped file"
d="$SBX/cdx-effort"
rm -rf "$d"
mkdir -p "$d"
cp -R "$REPO/tools" "$REPO/installer" "$REPO/payload" "$d/"
"$SBX_PY" - "$d/payload/components.json" <<'PYEOF'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
c["codex_effort"] = {"builder": "xhigh"}
open(p, "w").write(json.dumps(c, indent=1) + "\n")
PYEOF
assert_exit 0 python3 "$d/tools/build.py"
b="$(cat "$d/payload/codex/agents/builder.toml")"
assert_contains "$b" 'model_reasoning_effort = "xhigh"'
assert_contains "$b" "Effort: you run at xhigh."
assert_not_contains "$b" "you run at high"
t_end

# ---------------------------------------------------------------------------------
# the usage-split hook
# ---------------------------------------------------------------------------------
t_begin "S-17 the usage-split check accepts a heading, a blank line, then the split, and still rejects a split with no model alias"
pycheck "$REPO/payload/claude/conductor/hooks/usage-split-check.py" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("usage_split_check", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
has = m.has_split_line
assert has("Done.\n\n## Usage split\n\n- builder: sonnet x2\n") is True, "heading, 1 blank line, list"
assert has("Done.\n\n## Usage split\n\n\nbuilder: sonnet x2\n") is True, "heading, 2 blank lines"
assert has("Done.\n\n## Usage split\n- builder: sonnet x2\n") is True, "heading, list directly under it"
assert has("**Usage split:** builder sonnet x2\n") is True, "1 line"
assert has("Usage split:\n\nconductor on opus; 2 builders on sonnet\n") is True, "label alone, blank line, then the split"
assert has("Done.\n\n## Usage split\n\n\n\nbuilder: sonnet x2\n") is False, "more than 2 blank lines"
assert has("Done.\n\n## Usage split\n\n- 2 workers, no model named\n") is False, "no alias"
assert has("Usage split: 2 workers\n\nopus wrote the plan\n") is False, "a later paragraph is not the split"
assert has("Done.\n\n## Usage split\n") is False, "heading with nothing under it"
PYEOF
t_end

# ---------------------------------------------------------------------------------
# ledger-append
# ---------------------------------------------------------------------------------
t_begin "C-5 ledger-append refuses a ledger whose real path is inside a .git or .claude folder, whether or not the project is that folder"
LB="$SBX/ledger-c5"
rm -rf "$LB"
mkdir -p "$LB/proj/.claude" "$LB/proj/.git" "$LB/proj/.Claude" "$LB/home/.claude/agents" "$LB/plain"
for cwd in "$LB/proj/.claude" "$LB/proj/.git" "$LB/proj/.Claude"; do
  out="$(cd "$cwd" && /bin/bash "$LA" --disposition ASK --text x 2>&1)"; rc=$?
  assert_eq 3 "$rc" "exit code from inside $cwd"
  assert_not_contains "$out" "added" "$cwd"
  assert_no_file "$cwd/DEFERRED-FINDINGS.md" "no ledger created in $cwd"
done
out="$(/bin/bash "$LA" --project "$LB/proj/.git" --disposition ASK --text x 2>&1)"; rc=$?
assert_eq 3 "$rc" "--project naming a .git folder"
assert_no_file "$LB/proj/.git/DEFERRED-FINDINGS.md"
out="$(/bin/bash "$LA" --project "$LB/home/.claude" --ledger agents/x-FINDINGS.md --disposition ASK --text x 2>&1)"; rc=$?
assert_eq 3 "$rc" "a project that is a config folder, with a ledger in a folder below it"
assert_contains "$out" ".claude folder"
assert_no_file "$LB/home/.claude/agents/x-FINDINGS.md"
out="$(/bin/bash "$LA" --project "$LB/proj" --ledger .claude/DEFERRED-FINDINGS.md --disposition ASK --text x 2>&1)"; rc=$?
assert_eq 3 "$rc" "the earlier rule: a .claude folder below the project"
out="$(/bin/bash "$LA" --project "$LB/plain" --disposition ASK --text x 2>&1)"; rc=$?
assert_eq 0 "$rc" "control: an ordinary project"
assert_eq "added D-001" "$out" "control output"
t_end

t_begin "O3-3 C3-1 ledger-append accepts a project in Claude Code's worktree layout, <repo>/.claude/worktrees/<name>, and still refuses every other place under a .claude folder"
LB="$SBX/ledger-o33"
rm -rf "$LB"
mkdir -p "$LB/repo/.claude/worktrees/x/docs" "$LB/repo/.claude/worktrees/x/.claude/agents" "$LB/repo/.claude/worktrees/x/.git" "$LB/repo/.claude/agents"
out="$(cd "$LB/repo/.claude/worktrees/x" && /bin/bash "$LA" --disposition ASK --text x 2>&1)"; rc=$?
assert_eq 0 "$rc" "exit code from a project at <repo>/.claude/worktrees/x"
assert_eq "added D-001" "$out" "the row was added"
assert_file "$LB/repo/.claude/worktrees/x/DEFERRED-FINDINGS.md" "the ledger is in the worktree"
out="$(/bin/bash "$LA" --project "$LB/repo/.claude/worktrees/x" --ledger docs/TEAM-LEDGER.md --disposition ASK --text x 2>&1)"; rc=$?
assert_eq 0 "$rc" "a ledger in a folder below the worktree"
assert_eq "added D-001" "$out" "its row was added"
out="$(cd "$LB/repo/.claude/worktrees" && /bin/bash "$LA" --disposition ASK --text x 2>&1)"; rc=$?
assert_eq 3 "$rc" "a ledger directly under .claude/worktrees, with no worktree name"
assert_no_file "$LB/repo/.claude/worktrees/DEFERRED-FINDINGS.md"
out="$(cd "$LB/repo/.claude" && /bin/bash "$LA" --disposition ASK --text x 2>&1)"; rc=$?
assert_eq 3 "$rc" "a ledger directly under <repo>/.claude"
assert_contains "$out" "the ledger is inside a .claude folder; refused, nothing was changed" "the refusal"
assert_no_file "$LB/repo/.claude/DEFERRED-FINDINGS.md"
out="$(/bin/bash "$LA" --project "$LB/repo/.claude" --ledger agents/x-FINDINGS.md --disposition ASK --text x 2>&1)"; rc=$?
assert_eq 3 "$rc" "a ledger in .claude/agents"
assert_no_file "$LB/repo/.claude/agents/x-FINDINGS.md"
out="$(/bin/bash "$LA" --project "$LB/repo/.claude/worktrees/x" --ledger .claude/agents/y-FINDINGS.md --disposition ASK --text x 2>&1)"; rc=$?
assert_eq 3 "$rc" "another .claude folder inside a worktree is not excused by the worktree layout"
assert_no_file "$LB/repo/.claude/worktrees/x/.claude/agents/y-FINDINGS.md"
out="$(/bin/bash "$LA" --project "$LB/repo/.claude/worktrees/x" --ledger .git/z-LEDGER.md --disposition ASK --text x 2>&1)"; rc=$?
assert_eq 3 "$rc" "a .git folder inside a worktree"
assert_contains "$out" "the ledger is inside a .git folder; refused, nothing was changed" "the refusal"
assert_no_file "$LB/repo/.claude/worktrees/x/.git/z-LEDGER.md"
t_end

t_begin "C3-2 ledger-append also refuses a ledger under a .claude-name profile folder, .codex and .agents, in any letter case, and a .git folder anywhere"
LB="$SBX/ledger-c32"
rm -rf "$LB"
mkdir -p "$LB/home/.claude-alt/agents" "$LB/home/.claude-other" "$LB/home/.codex/agents" "$LB/home/.agents/skills" "$LB/home/.CODEX" "$LB/repo/.git" "$LB/repo/sub/.git/hooks" "$LB/home/.claude-alt/worktrees/w" "$LB/home/.claude-work" "$LB/home/claude-plain"
for spec in ".claude-alt|agents/x-FINDINGS.md" ".claude-alt|y-LEDGER.md" ".claude-other|y-LEDGER.md" ".codex|agents/x-FINDINGS.md" ".codex|y-LEDGER.md" ".agents|skills/x-FINDINGS.md" ".agents|y-LEDGER.md" ".CODEX|y-LEDGER.md"; do
  d="${spec%%|*}"
  f="${spec#*|}"
  out="$(cd "$LB/home/$d" && /bin/bash "$LA" --ledger "$f" --disposition ASK --text x 2>&1)"; rc=$?
  assert_eq 3 "$rc" "a ledger $f under $d"
  assert_contains "$out" "refused, nothing was changed" "the refusal under $d"
  assert_no_file "$LB/home/$d/$f" "nothing created under $d"
done
out="$(cd "$LB/repo/.git" && /bin/bash "$LA" --ledger y-LEDGER.md --disposition ASK --text x 2>&1)"; rc=$?
assert_eq 3 "$rc" "a ledger directly under .git"
out="$(/bin/bash "$LA" --project "$LB/repo/sub" --ledger .git/hooks/y-LEDGER.md --disposition ASK --text x 2>&1)"; rc=$?
assert_eq 3 "$rc" "a ledger deeper under a .git folder"
assert_no_file "$LB/repo/sub/.git/hooks/y-LEDGER.md"
out="$(cd "$LB/home/.claude-alt/worktrees/w" && /bin/bash "$LA" --disposition ASK --text x 2>&1)"; rc=$?
assert_eq 0 "$rc" "the worktree layout is excused for any config folder name, as the rule is written"
out="$(cd "$LB/home/claude-plain" && /bin/bash "$LA" --disposition ASK --text x 2>&1)"; rc=$?
assert_eq 0 "$rc" "control: a folder named claude-plain is not a config folder"
out="$(cd "$LB/home/.claude-work" && /bin/bash "$LA" --disposition ASK --text x 2>&1)"; rc=$?
assert_eq 3 "$rc" "any .claude- name is a config folder"
t_end

# A fake date that swaps the ledger for a link between the last check and the append, which is
# the window the finding describes. The real date still answers.
REAL_DATE="$(command -v date)"
mkdir -p "$SBX/bin"
cat > "$SBX/bin/date" <<'EOF'
#!/bin/sh
if [ -n "${SWAP_LEDGER:-}" ] && [ ! -L "$SWAP_LEDGER" ]; then
  rm -f "$SWAP_LEDGER"
  ln -s "$SWAP_TARGET" "$SWAP_LEDGER"
fi
exec "$REAL_DATE" "$@"
EOF
chmod 755 "$SBX/bin/date"
export REAL_DATE

swap_run() { # $1 = project folder: a ledger swapped for a link to $SBX/outside-n4 after the checks
  rm -rf "$1"
  mkdir -p "$1"
  printf 'outside file\n' > "$SBX/outside-n4"
  SWAP_LEDGER="$1/DEFERRED-FINDINGS.md" SWAP_TARGET="$SBX/outside-n4" \
    /bin/bash "$LA" --project "$1" --disposition ASK --text "swapped" 2>&1
}
export SWAP_LEDGER="" SWAP_TARGET=""

t_begin "N-4 ledger-append opens the ledger without following a link swapped in after its checks (python3 present)"
out="$(swap_run "$SBX/ledger-n4a")"; rc=$?
assert_eq 3 "$rc" "exit code"
assert_contains "$out" "symbolic link" "says so"
assert_eq "outside file" "$(cat "$SBX/outside-n4")" "the file the link points at is unchanged"
t_end

t_begin "N-4 without python3 the link is tested again immediately before the append"
(
  sandbox_no_python
  out="$(swap_run "$SBX/ledger-n4b")"; rc=$?
  [ "$rc" = 3 ] || echo "exit code [$rc], expected 3: $out"
  case "$out" in *"symbolic link"*) ;; *) echo "no 'symbolic link' in: $out" ;; esac
  [ "$(cat "$SBX/outside-n4")" = "outside file" ] || echo "the file the link points at changed"
) > "$SBX/n4b.out" 2>&1
[ ! -s "$SBX/n4b.out" ] || t_fail "$(cat "$SBX/n4b.out")"
t_end

t_begin "N-4 an ordinary append still adds the row, with and without python3, and a ledger with no final line feed gets one"
rm -rf "$SBX/ledger-n4c"
mkdir -p "$SBX/ledger-n4c"
out="$(/bin/bash "$LA" --project "$SBX/ledger-n4c" --disposition ASK --text "first" 2>&1)"
assert_eq "added D-001" "$out"
printf '| D-009 | 2026-01-01 | ASK | open | no final line feed | |' >> "$SBX/ledger-n4c/DEFERRED-FINDINGS.md"
out="$(/bin/bash "$LA" --project "$SBX/ledger-n4c" --disposition DO-NEXT --text "second" 2>&1)"
assert_eq "added D-003" "$out"
out="$( ( sandbox_no_python; /bin/bash "$LA" --project "$SBX/ledger-n4c" --disposition WONTFIX --text "third" 2>&1 ) )"
assert_eq "added D-004" "$out" "without python3"
assert_eq 4 "$(grep -c '^| D-' "$SBX/ledger-n4c/DEFERRED-FINDINGS.md" | tr -d ' ')" "rows"
assert_eq 0 "$(grep -c '^| D-009.*| *| D-' "$SBX/ledger-n4c/DEFERRED-FINDINGS.md" | tr -d ' ')" "no row was glued to the line before it"
t_end
rm -f "$SBX/bin/date"

# ---------------------------------------------------------------------------------
# README, changelog, notices and the issue form
# ---------------------------------------------------------------------------------
t_begin "O-6 the README opening and the process-kit line are plain scope statements, not the working pitch lines"
readme="$(cat "$REPO/README.md")"
for phrase in "decide how to work" "pins who does it" "pick up where the last one stopped" "do the labor" "plans, decides and talks to you"; do
  assert_not_contains "$readme" "$phrase" "pitch phrase"
done
assert_contains "$readme" "## What Conductor is, and is not"
assert_contains "$readme" "a replacement for Claude Code's own Workflows or for process kits"
t_end

t_begin "O-21 J-5 the README names the plans that list the Codex builder and critic model and tells a Free or Go user to set both to gpt-6-luna"
sec="$(awk '/^## Codex model ids/{f=1;next} /^## /{f=0} f' "$REPO/README.md" | tr '\n' ' ' | tr -s ' ')"
sol="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["codex_models"]["sonnet"])' "$REPO/payload/components.json")"
luna="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["codex_models"]["haiku"])' "$REPO/payload/components.json")"
assert_eq "gpt-6.1-sol" "$sol" "the map's builder and critic id"
assert_eq "gpt-6-luna" "$luna" "the map's scout id"
assert_contains "$sec" "$sol"
assert_contains "$sec" "Plus, Pro, Business, Enterprise and Edu"
assert_contains "$sec" "Enterprise and Edu need an administrator"
assert_contains "$sec" "Free or Go"
assert_contains "$sec" "builder and critic"
assert_contains "$sec" "$luna"
assert_contains "$sec" "builder.toml"
assert_contains "$sec" "critic.toml"
assert_contains "$sec" "prints each agent's model id"
t_end

t_begin "J-8 where judge rungs 1 and 3 are listed, rung 2 is said to be a judge from another lab that comes later"
pycheck "$REPO" <<'PYEOF2'
import re, sys
for rel in ("README.md", "CHANGELOG.md", "payload/claude/conductor/model-notes.md",
            "payload/claude/conductor/runbooks/review-ladder.md", "payload/claude/doctrine.md"):
    t = open(sys.argv[1] + "/" + rel, encoding="utf-8").read()
    assert re.search(r"(?i)rung 1", t) and re.search(r"(?i)rung 3", t), (rel, "lists rungs 1 and 3")
    assert re.search(r"(?i)rung 2, a judge from another lab", t), (rel, "rung 2 is not explained")
PYEOF2
t_end

t_begin "O-28 the README requirements say conductor update needs python3 3.9 or later"
line="$(grep -E '^- python3' "$REPO/README.md")"
assert_contains "$line" "3.9 or later"
assert_contains "$line" "conductor update"
t_end

t_begin "O-14 the changelog says the 0.3.0 figures were synthesized test data, not measurements"
cl="$(cat "$REPO/CHANGELOG.md")"
assert_contains "$cl" "synthesized"
assert_contains "$cl" "MOCK DATA"
assert_contains "$cl" "not from measurement"
assert_not_contains "$cl" "rested on sample data"
t_end

t_begin "O-30 J-11 N-2 J-4 the 0.4.0 heading says unreleased, the date rule no longer points at SPEC.md, and no placeholder is left in the changelog"
assert_eq "## 0.4.0 (unreleased: dated at the tag)" "$(grep -m1 '^## ' "$REPO/CHANGELOG.md")" "first heading"
assert_not_contains "$cl" "SPEC.md"
assert_not_contains "$cl" "<filled at release>"
assert_contains "$cl" "Installer sha256: given beside the installer file"
t_end

t_begin "O-23 the notices credit Gonzalo Paternoster's Thinking Partner method for thinking-partner mode, say no text was copied, and no longer call it common practice"
nt="$(cat "$REPO/THIRD-PARTY-NOTICES.md")"
assert_contains "$nt" "Gonzalo Paternoster"
assert_contains "$nt" "Thinking Partner"
assert_contains "$nt" "Thinking-partner mode"
assert_not_contains "$nt" "common practice"
assert_not_contains "$nt" "no text from any outside source"
F="$SBX/rc-notices"
rm -rf "$F"
mkdir -p "$F"
cp "$REPO/THIRD-PARTY-NOTICES.md" "$F/"
cp -R "$REPO/payload" "$F/"
printf 'Ponytail\nDietrichGebert\nHoney\nGreen-PT\nGonzalo Paternoster\n' > "$SBX/derived.txt"
RCL="$SBX/rc-leak.txt"
printf '# fixture list\n\\bprivate-client\\b\n' > "$RCL"
rcrun() { # FOLDER [args]: the release check on a synthetic folder; OUT and RC hold the result
  local d="$1"
  shift
  OUT="$("$SBX_PY" -B "$RELCHECK" --repo "$d" --leak-base "$RCL" "$@" 2>&1)"
  RC=$?
}
rcline() { printf '%s\n' "$OUT" | grep -E "^(PASS|FAIL|SKIP) $1:" | head -n 1; }
rcrun "$F" --derived-works "$SBX/derived.txt"
assert_contains "$(rcline notices)" "PASS notices" "release-check finds every derived work named"
t_end

t_begin "S-3 O-24 C-8 J-3 the issue form asks for no savings figure, carries no percentage example, promises to feature no figure and shows the Usage split format"
form="$REPO/.github/ISSUE_TEMPLATE/conductor-win.yml"
assert_eq 0 "$(grep -c '%' "$form" | tr -d ' ')" "percent signs"
for w in savings 60-80 burn featured "cut my" "Rough"; do
  assert_eq 0 "$(grep -ci -- "$w" "$form" | tr -d ' ')" "the word [$w]"
done
assert_contains "$(cat "$form")" "Usage split:"
assert_eq 0 "$(grep -c 'Dispatched:' "$form" | tr -d ' ')" "the old receipt format"
t_end

# ---------------------------------------------------------------------------------
# the release check
# ---------------------------------------------------------------------------------
rc_base() { # FOLDER: a clean synthetic repository
  rm -rf "$1"
  mkdir -p "$1/payload/claude" "$1/site"
  printf '# Conductor\n\nA fixture readme.\n' > "$1/README.md"
  printf '# Changelog\n\n## 0.4.0\n\nA fixture entry.\n' > "$1/CHANGELOG.md"
  printf '# Third-Party Notices\n\nNothing here.\n' > "$1/THIRD-PARTY-NOTICES.md"
  printf 'plain text\n' > "$1/payload/claude/note.md"
}

t_begin "S-3 O-24 C-8 J-3 the banned-strings scan reaches .github and every published text file outside site and bench, and not tests, tools or bench"
F="$SBX/rc-banned"
rc_base "$F"
rcrun "$F"
assert_contains "$(rcline banned-strings)" "PASS banned-strings" "control"
for target in .github/ISSUE_TEMPLATE/f.yml SPEC.md THIRD-PARTY-NOTICES.md CHANGELOG.md payload/claude/note.md release/RECORD-0.4.0.md site/index.html; do
  rc_base "$F"
  mkdir -p "$F/$(dirname "$target")"
  printf 'usually 60-80%% less\n' >> "$F/$target"
  rcrun "$F"
  l="$(rcline banned-strings)"
  assert_contains "$l" "FAIL banned-strings" "$target"
  assert_contains "$l" "$target:" "$target is named with its line"
  assert_contains "$l" "60-80" "$target names the string"
done
for target in tests/x.sh tools/y.py bench/z.md; do
  rc_base "$F"
  mkdir -p "$F/$(dirname "$target")"
  printf 'usually 60-80%% less\n' >> "$F/$target"
  rcrun "$F"
  assert_contains "$(rcline banned-strings)" "PASS banned-strings" "$target is not published text"
done
t_end

t_begin "S-3 the text this repository publishes outside site and bench holds no banned string"
F="$SBX/rc-real"
rm -rf "$F"
mkdir -p "$F"
cp "$REPO/README.md" "$REPO/CHANGELOG.md" "$REPO/THIRD-PARTY-NOTICES.md" "$REPO/install.sh" "$F/"
cp -R "$REPO/.github" "$REPO/payload" "$F/"
[ -d "$REPO/release" ] && cp -R "$REPO/release" "$F/"
rcrun "$F"
assert_contains "$(rcline banned-strings)" "PASS banned-strings"
t_end

t_begin "O-8 release-check --all-files runs the leak scan and the verbatim check over every tracked file, with site/ reported on its own line"
G="$SBX/rc-git"
rm -rf "$G"
mkdir -p "$G/tests" "$G/docs" "$G/site" "$G/payload" "$SBX/rc-priv"
printf 'a clean readme\n' > "$G/README.md"
printf 'echo private-client\n' > "$G/tests/x.sh"
printf 'the quick brown fox jumps over the lazy dog while 7 grey wolves howl under a pale cold winter moon tonight\n' > "$G/tests/y.txt"
printf 'site copy mentions private-client\n' > "$G/site/index.html"
printf 'clean payload text\n' > "$G/payload/p.md"
printf 'private-client in a file git does not track\n' > "$G/untracked.txt"
printf 'the quick brown fox jumps over the lazy dog while 7 grey wolves howl under a pale cold winter moon tonight\n' > "$SBX/rc-priv/secret.md"
printf 'secret.md\n' > "$SBX/rc-priv/verbatim-sources.txt"
git -C "$G" init -q
git -C "$G" add README.md tests site payload
VER="--verbatim-sources $SBX/rc-priv/verbatim-sources.txt --verbatim-root $SBX/rc-priv"
rcrun "$G" $VER
assert_contains "$(rcline leak-scan)" "PASS leak-scan" "without the flag, tests/ is not scanned"
assert_contains "$(rcline verbatim)" "PASS verbatim" "without the flag, tests/ is not compared"
assert_eq "" "$(rcline leak-scan-site)" "no site line without the flag"
rcrun "$G" $VER --all-files
l="$(rcline leak-scan)"
assert_contains "$l" "FAIL leak-scan"
assert_contains "$l" "tests/x.sh:1"
assert_not_contains "$l" "site/index.html" "site hits stay on their own line"
assert_not_contains "$l" "untracked.txt" "a file git does not list is not scanned"
l="$(rcline leak-scan-site)"
assert_contains "$l" "FAIL leak-scan-site"
assert_contains "$l" "site/index.html:1"
l="$(rcline verbatim)"
assert_contains "$l" "FAIL verbatim"
assert_contains "$l" "tests/y.txt"
# a clean tracked tree passes both, and the site line passes on its own
printf 'echo fine\n' > "$G/tests/x.sh"
printf 'nothing to see\n' > "$G/tests/y.txt"
printf 'site copy\n' > "$G/site/index.html"
rcrun "$G" $VER --all-files
assert_contains "$(rcline leak-scan)" "PASS leak-scan"
assert_contains "$(rcline leak-scan-site)" "PASS leak-scan-site"
assert_contains "$(rcline verbatim)" "PASS verbatim"
# a folder that is not a git checkout is a usage error
rc_base "$SBX/rc-nogit"
rcrun "$SBX/rc-nogit" --all-files
assert_eq 2 "$RC" "exit status outside a git checkout"
assert_contains "$OUT" "git"
t_end

t_begin "O-8 the private-token helper reads private names from the list file when one is given, and otherwise checks only a /Users/ path and an email"
H="$SBX/hits"
mkdir -p "$H"
printf 'the private-client tool\n' > "$H/a.txt"
printf 'a path /Users/someone/x\n' > "$H/b.txt"
printf 'mail a.b@example.com\n' > "$H/c.txt"
printf 'clean\n' > "$H/d.txt"
assert_eq "$H/b.txt:1
$H/c.txt:1" "$(LEAK_BASE_FILE="" private_hits "$H/a.txt" "$H/b.txt" "$H/c.txt" "$H/d.txt")" "generic patterns only"
assert_eq "$H/a.txt:1
$H/b.txt:1
$H/c.txt:1" "$(LEAK_BASE_FILE="$RCL" private_hits "$H/a.txt" "$H/b.txt" "$H/c.txt" "$H/d.txt")" "with a list file"
assert_not_contains "$(LEAK_BASE_FILE="$RCL" private_hits "$H/a.txt")" "private-client" "the matched text is never printed"
t_end

t_begin "O-8 test file headers and test names carry no lane name, no review id prefix and no private name"
NAMES_OUT="$SBX/test-names.txt"
export NAMES_OUT
pycheck "$REPO" <<'PYEOF2'
import glob, os, re, sys
repo = sys.argv[1]
# Shapes of the ids a review leaves behind: lane names and codes, finding prefixes, round
# letters and gate numbers. Private tool and person names are checked below against the list
# file a release run supplies, never embedded here.
bad = re.compile(r"\bREL-[A-Z]+|\blane\b|\[L[0-9][ab]?\]|\([A-Z][0-9][ab]?\)|\b(?:RC[12]|F[12]|S[1-4])-[0-9]+[a-z]?\b|\bR-[A-E]\b|\bB-[0-9]+\b")
mine = {"test-release-fixes.sh", "test-bench.sh", "test-installer-fixes.sh"}
names = []
problems = []
for path in sorted(glob.glob(repo + "/tests/test-*.sh")):
    if os.path.basename(path) in mine:
        continue
    lines = open(path, encoding="utf-8").read().split("\n")
    head = []
    for ln in lines[1:]:
        if not ln.startswith("#"):
            break
        head.append(ln)
    for ln in head + [l for l in lines if l.startswith("t_begin ")]:
        names.append(ln)
        if bad.search(ln):
            problems.append("%s: %s" % (os.path.basename(path), ln[:90]))
assert not problems, "; ".join(problems[:4]) + " (+%d more)" % (len(problems) - 4 if len(problems) > 4 else 0)
open(os.environ["NAMES_OUT"], "w").write("\n".join(names) + "\n")
PYEOF2
assert_eq "" "$(private_hits "$NAMES_OUT")" "private names in headers or test names (the list file, or a /Users/ path or an email)"
t_end

t_summary
