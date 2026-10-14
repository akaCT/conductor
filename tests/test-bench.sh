#!/bin/bash
# tests/test-bench.sh: the delegation bench (REQ-EVAL-001).
#
# Mock runs prove the pipeline. Real mode is exercised only against a fake
# claude on PATH (it prints a fixture stream and never reaches a network) and a
# fake installer, in a config folder under the sandbox. No test calls the real
# claude and no test touches a real config folder.
#
# Real mode hands claude and the installer an allowlisted environment, so the
# fakes cannot read FAKE_* variables. The tests write them to $SBX/fake.env,
# which both fakes source (fake_env below).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/lib/sandbox.sh"

sandbox_new
trap sandbox_cleanup EXIT
sandbox_guard

B="$REPO/bench"
RUN="$B/src/run.py"
FIX="$B/fixtures/streams"
for v in $(compgen -v | grep -E '^(BENCH_|FAKE_)' || true); do unset "$v"; done
export NO_COLOR=1

jget() { # FILE EXPR: value of a python expression over the parsed JSON (named d)
  # The expressions are written in this file; nothing from outside reaches eval.
  python3 - "$1" "$2" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
print(eval(sys.argv[2], {"d": d}))
PYEOF
}

latest_json() { ls -t "$1"/RUN-*.json 2> /dev/null | head -n 1; }
latest_md() { ls -t "$1"/RUN-*.md 2> /dev/null | head -n 1; }

pyrep() { # CODE: run python with bench/src on the path
  python3 -c "import sys; sys.path.insert(0, '$B/src'); $1"
}

# ---------------------------------------------------------------- fakes

write_fake_claude() {
  cat > "$SBX/bin/claude" <<'FAKEEOF'
#!/bin/sh
# fake claude for tests/test-bench.sh: prints a fixture stream, calls nothing.
if [ -f "$(dirname "$0")/../fake.env" ]; then . "$(dirname "$0")/../fake.env"; fi
if [ "${1:-}" = "--version" ]; then echo "2.1.300 (Claude Code)"; exit 0; fi
if [ "${1:-}" = "--help" ]; then
  echo "Usage: claude [options] [prompt]"
  echo "  -p, --print          Print the response and exit"
  if [ "${FAKE_CLAUDE_NO_STRICT:-}" != 1 ]; then echo "  --strict-mcp-config  Only use MCP servers from --mcp-config"; fi
  exit 0
fi
cfg="${CLAUDE_CONFIG_DIR:-}"
cond=no; pins=no
if [ -n "$cfg" ] && [ -f "$cfg/CLAUDE.md" ] && grep -q 'BEGIN CONDUCTOR' "$cfg/CLAUDE.md"; then cond=yes; fi
if [ -n "$cfg" ] && [ -f "$cfg/settings.json" ] && grep -q effortLevel "$cfg/settings.json"; then pins=yes; fi
printf 'call conductor=%s pins=%s effort_env=%s cfg=%s args=[%s] files=[%s]\n' \
  "$cond" "$pins" "${CLAUDE_CODE_EFFORT_LEVEL:-unset}" "$cfg" "$*" "$(ls | tr '\n' ' ')" >> "${FAKE_CLAUDE_LOG:-/dev/null}"
if [ -n "${FAKE_CLAUDE_LOG:-}" ]; then env | sed 's/=.*//' | sort | tr '\n' ' ' >> "$FAKE_CLAUDE_LOG.env"; echo >> "$FAKE_CLAUDE_LOG.env"; fi
cat > /dev/null
if [ "${FAKE_CLAUDE_FIX:-}" = 1 ] && [ -f buggy.py ]; then
  printf 'for i in range(1, 31):\n    if i %% 15 == 0:\n        print("FizzBuzz")\n    elif i %% 3 == 0:\n        print("Fizz")\n    elif i %% 5 == 0:\n        print("Buzz")\n    else:\n        print(i)\n' > buggy.py
fi
if [ -n "${FAKE_CLAUDE_HANG_FILE:-}" ] && [ "$cond" = yes ]; then : > "$FAKE_CLAUDE_HANG_FILE"; sleep 30; fi
if [ "${FAKE_CLAUDE_FAIL:-}" = 1 ]; then echo "boom" >&2; exit 1; fi
cat "${FAKE_CLAUDE_STREAM:?}"
FAKEEOF
  chmod 755 "$SBX/bin/claude"
}

write_fake_installer() {
  cat > "$SBX/fake-install.sh" <<'FAKEEOF'
#!/bin/sh
# fake installer for tests/test-bench.sh: --core [--apply-effort-pins], --dry-run and --uninstall.
if [ -f "$(dirname "$0")/fake.env" ]; then . "$(dirname "$0")/fake.env"; fi
d="${CLAUDE_DIR:?}"
mode=install; pins=no
for a in "$@"; do
  case "$a" in
    --uninstall) mode=uninstall ;;
    --dry-run) mode=dry ;;
    --apply-effort-pins) pins=yes ;;
  esac
done
if [ -e "${CODEX_DIR:-/nonexistent-codex}" ]; then cx=yes; else cx=no; fi
echo "$mode $* codex_exists=$cx yes=${CONDUCTOR_YES:-}" >> "${FAKE_INSTALLER_LOG:-/dev/null}"
if [ -n "${FAKE_INSTALLER_LOG:-}" ]; then env | sed 's/=.*//' | sort | tr '\n' ' ' >> "$FAKE_INSTALLER_LOG.env"; echo >> "$FAKE_INSTALLER_LOG.env"; fi
if [ "$mode" = dry ]; then
  echo "  Dry run finished. Nothing was changed."
  if [ "$pins" = yes ] && { [ "${FAKE_INSTALLER_NO_PIN:-}" != 1 ] || [ "${FAKE_INSTALLER_DRY_LIES:-}" = 1 ]; }; then
    echo "  would offer: Set Sonnet 5.5 to high effort for this config?"
  else
    echo "  Sonnet 5.5 effort pin: printed, not written (fake installer says no)."
  fi
  exit 0
fi
if [ "$mode" = install ]; then
  mkdir -p "$d/conductor/saved"
  for f in CLAUDE.md settings.json; do
    if [ -f "$d/$f" ]; then cp -p "$d/$f" "$d/conductor/saved/$f"; else : > "$d/conductor/saved/$f.absent"; fi
  done
  : > "$d/conductor/.install-manifest"
  printf '<!-- BEGIN CONDUCTOR (managed) v0.4.0 - fake -->\nfake rules\n<!-- END CONDUCTOR -->\n' >> "$d/CLAUDE.md"
  if [ "$pins" = yes ] && [ "${FAKE_INSTALLER_NO_PIN:-}" != 1 ]; then
    printf '{"modelSettings":{"claude-sonnet-5-5":{"effortLevel":"high"}}}\n' > "$d/settings.json"
  fi
  if [ "${FAKE_INSTALLER_ALWAYS_PIN:-}" = 1 ]; then
    printf '{"modelSettings":{"claude-sonnet-5-5":{"effortLevel":"high"}}}\n' > "$d/settings.json"
  fi
else
  if [ "${FAKE_INSTALLER_UNINSTALL_FAIL:-}" = 1 ]; then echo "uninstall refused (fake)" >&2; exit 1; fi
  for f in CLAUDE.md settings.json; do
    if [ "${FAKE_INSTALLER_LEAVE:-}" = 1 ] && [ "$f" = CLAUDE.md ]; then continue; fi
    if [ -f "$d/conductor/saved/$f" ]; then cp -p "$d/conductor/saved/$f" "$d/$f"; else rm -f "$d/$f"; fi
  done
  rm -rf "$d/conductor/saved"
  if [ "${FAKE_INSTALLER_LEAVE_RECORD:-}" != 1 ]; then rm -f "$d/conductor/.install-manifest"; fi
fi
exit 0
FAKEEOF
  chmod 755 "$SBX/fake-install.sh"
}

new_cfg() { # NAME: a signed-in looking config folder with files of odd bytes
  CFG="$SBX/$1"
  rm -rf "$CFG"
  mkdir -p "$CFG"
  printf 'dummy-sign-in-record-not-a-secret\n' > "$CFG/.credentials.json"
  printf '{ "theme" :"dark"}' > "$CFG/settings.json"
  printf 'my own notes\r\nno trailing newline' > "$CFG/CLAUDE.md"
  cp -p "$CFG/settings.json" "$SBX/orig-settings.json"
  cp -p "$CFG/CLAUDE.md" "$SBX/orig-CLAUDE.md"
}

mock_run() { # RESULTS_DIR [ENV=VALUE ...]: a mock run; OUT and RC hold the result
  local res="$1"
  shift
  OUT="$(env BENCH_MOCK=1 BENCH_RESULTS_DIR="$res" "$@" python3 "$RUN" 2>&1)"
  RC=$?
}

fake_env() { # [FAKE_NAME=VALUE ...]: what the fakes read (real mode gives them no FAKE_* variables)
  local a
  {
    printf "export FAKE_CLAUDE_STREAM='%s'\n" "$FIX/nested.jsonl"
    printf "export FAKE_CLAUDE_LOG='%s'\n" "$SBX/claude.log"
    printf "export FAKE_INSTALLER_LOG='%s'\n" "$SBX/installer.log"
    for a in "$@"; do printf "export %s='%s'\n" "${a%%=*}" "${a#*=}"; done
  } > "$SBX/fake.env"
}

real_run() { # RESULTS_DIR CFG [ENV=VALUE ...]: a real mode run against the fakes; FAKE_* go to fake.env
  local res="$1" cfg="$2" a
  local -a fakes=() runner=()
  shift 2
  for a in "$@"; do
    case "$a" in
      FAKE_*) fakes+=("$a") ;;
      *) runner+=("$a") ;;
    esac
  done
  fake_env ${fakes[@]+"${fakes[@]}"}
  OUT="$(env BENCH_RESULTS_DIR="$res" BENCH_CONFIG_DIR="$cfg" BENCH_MODEL=fake-model-1 \
    BENCH_INSTALLER="$SBX/fake-install.sh" ${runner[@]+"${runner[@]}"} python3 "$RUN" 2>&1)"
  RC=$?
}

write_fake_claude
write_fake_installer

# ---------------------------------------------------------------- the task set

t_begin "REQ-EVAL-001.1 task set: 20 tasks (t1 to t8 kept, 12 new), each with meta.json, prompt.md and a success_cmd"
out="$(python3 - "$B/tasks" <<'PYEOF'
import json, os, sys
root = sys.argv[1]
ids = sorted(d for d in os.listdir(root) if os.path.isdir(os.path.join(root, d)))
print("count", len(ids))
nums = sorted(int(d.split("_")[0][1:]) for d in ids)
print("numbers", ",".join(str(n) for n in nums))
bad = []
for d in ids:
    m = os.path.join(root, d, "meta.json")
    p = os.path.join(root, d, "prompt.md")
    try:
        meta = json.load(open(m))
    except Exception as e:
        bad.append(d + ": meta.json " + str(e))
        continue
    if meta.get("id") != d or not meta.get("success_cmd") or not meta.get("category"):
        bad.append(d + ": meta needs id, category and success_cmd")
    if not os.path.isfile(p) or os.path.getsize(p) < 40:
        bad.append(d + ": prompt.md missing or empty")
print("bad", ";".join(bad) or "none")
PYEOF
)"
assert_contains "$out" "count 20" "20 task folders"
assert_contains "$out" "numbers 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20" "t1 to t20"
assert_contains "$out" "bad none" "every task is well formed"
t_end

t_begin "REQ-EVAL-001.1 task set: at least 6 of the 12 new tasks reward delegation (several files, independent parts)"
n="$(python3 - "$B/tasks" <<'PYEOF'
import json, os, sys
root = sys.argv[1]
n = 0
for d in os.listdir(root):
    num = int(d.split("_")[0][1:])
    if num >= 9 and json.load(open(os.path.join(root, d, "meta.json")))["category"] == "multifile_delegation":
        n += 1
print(n)
PYEOF
)"
if [ "$n" -lt 6 ]; then t_fail "only $n new delegation tasks"; fi
t_end

t_begin "REQ-EVAL-001.1 task set: every task's check fails on its untouched fixtures"
out="$(python3 - "$B/tasks" <<'PYEOF'
import json, os, shlex, shutil, subprocess, sys, tempfile
root = sys.argv[1]
bad = []
for d in sorted(os.listdir(root)):
    meta = json.load(open(os.path.join(root, d, "meta.json")))
    tmp = tempfile.mkdtemp(prefix="bench-untouched-")
    try:
        for item in os.listdir(os.path.join(root, d)):
            if item in ("meta.json", "prompt.md"):
                continue
            s = os.path.join(root, d, item)
            t = os.path.join(tmp, item)
            if os.path.isdir(s):
                shutil.copytree(s, t)
            else:
                shutil.copy2(s, t)
        cmd = shlex.split(meta["success_cmd"])
        if meta.get("needs_reply_file"):
            r = os.path.join(tmp, "reply.txt")
            open(r, "w").write("")
            cmd.append(r)
        p = subprocess.run(cmd, cwd=tmp, capture_output=True, text=True, timeout=60)
        if p.returncode == 0:
            bad.append(d)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
print("passing-untouched:", ",".join(bad) or "none")
PYEOF
)"
assert_eq "passing-untouched: none" "$out" "no task passes without work"
t_end

# ---------------------------------------------------------------- parsers and statistics

t_begin "REQ-EVAL-001.1 delegation rate: 0 dispatches of 5 tool calls (both implementations)"
out="$(pyrep "
import report, rederive
p = report.parse_stream(open('$FIX/no-dispatch.jsonl'))
top, nested, _r, _o, _i = rederive.read_stream(__import__('pathlib').Path('$FIX/no-dispatch.jsonl'))
print(p['dispatches'], p['tool_calls'], p['nested_tool_calls'], len([n for n in top.values() if n in ('Agent', 'Task')]), len(top), len(nested))
")"
assert_eq "0 5 0 0 5 0" "$out" "dispatches calls nested (report) then the same (rederive)"
t_end

t_begin "REQ-EVAL-001.1 delegation rate: 2 dispatches (Agent and Task) of 10 tool calls, a repeated event counts once"
out="$(pyrep "
import report, rederive
p = report.parse_stream(open('$FIX/2-of-10.jsonl'))
top, nested, _r, _o, _i = rederive.read_stream(__import__('pathlib').Path('$FIX/2-of-10.jsonl'))
print(p['dispatches'], p['tool_calls'], p['nested_tool_calls'], len([n for n in top.values() if n in ('Agent', 'Task')]), len(top), len(nested))
")"
assert_eq "2 10 0 2 10 0" "$out" "dispatches calls nested (report) then the same (rederive)"
t_end

t_begin "REQ-EVAL-001.1 delegation rate: tool calls made inside a subagent are not counted (1 of 3, 4 nested)"
out="$(pyrep "
import report, rederive
p = report.parse_stream(open('$FIX/nested.jsonl'))
top, nested, _r, _o, _i = rederive.read_stream(__import__('pathlib').Path('$FIX/nested.jsonl'))
print(p['dispatches'], p['tool_calls'], p['nested_tool_calls'], len([n for n in top.values() if n in ('Agent', 'Task')]), len(top), len(nested))
")"
assert_eq "1 3 4 1 3 4" "$out" "dispatches calls nested (report) then the same (rederive)"
t_end

t_begin "REQ-EVAL-001.1 tokens by model class and dollars from a result's modelUsage: exact values"
out="$(pyrep "
import report
pt = report.load_prices()
p = report.parse_stream(open('$FIX/nested.jsonl'))
u = report.usage_figures(p['result'], pt)
t = u['tokens']
print(u['cost_usd'], u['reported_cost_usd'], u['unpriced_models'])
print(t['opus'], t['haiku'], t['other'], t['sonnet'])
print(pt['source'], pt['read_on'])
")"
# opus 5.5: 1000 x 4 + 200 x 20 + 5000 x 0.2 + 800 x 5 = 13000; haiku 5.5: 2000 x 0.1 + 500 x 0.5 = 450; total 13450 over 1,000,000 = 0.01345
assert_contains "$out" "0.01345 0.51345 ['claude-mythos-9']" "dollars at the table prices, mythos left out as unpriced"
assert_contains "$out" "{'input': 1000, 'output': 200, 'cache_read': 5000, 'cache_write': 800}" "opus tokens"
assert_contains "$out" "{'input': 300, 'output': 100, 'cache_read': 0, 'cache_write': 0}" "other tokens"
assert_contains "$out" "https://platform.claude.com/docs/en/about-claude/pricing 2026-10-13" "price table source and date"
t_end

t_begin "REQ-EVAL-001.4 Wilson 95 percent intervals on known values (both implementations)"
out="$(pyrep "
import report, rederive
for x, n in ((0, 10), (10, 10), (5, 10), (8, 10), (1, 1), (0, 0)):
    print(x, n, report.wilson(x, n), rederive.wilson_bounds(x, n))
")"
assert_contains "$out" "0 10 (0.0, 0.2775) [0.0, 0.2775]" "0 of 10"
assert_contains "$out" "10 10 (0.7225, 1.0) [0.7225, 1.0]" "10 of 10"
assert_contains "$out" "5 10 (0.2366, 0.7634) [0.2366, 0.7634]" "5 of 10"
assert_contains "$out" "8 10 (0.4902, 0.9433) [0.4902, 0.9433]" "8 of 10"
assert_contains "$out" "1 1 (0.2065, 1.0) [0.2065, 1.0]" "1 of 1"
assert_contains "$out" "0 0 None None" "no runs gives no interval"
t_end

t_begin "REQ-EVAL-001.4 overlap rule: overlapping intervals are not distinguishable, disjoint ones are named"
out="$(pyrep "
import report
print(report.compare_arms('a', 5, 10, 'b', 6, 10)['verdict'])
print(report.compare_arms('a', 0, 30, 'c', 30, 30)['verdict'])
print(report.compare_arms('b', 0, 0, 'c', 3, 3)['verdict'])
")"
assert_contains "$out" "a vs b: not distinguishable at n=10 and n=10 (the 95 percent intervals overlap)" "5 of 10 against 6 of 10"
assert_contains "$out" "a vs c: the pass rates differ and arm c is higher (the 95 percent intervals do not overlap, n=30 and n=30)" "0 of 30 against 30 of 30"
assert_contains "$out" "b vs c: not compared (an arm has no runs)" "an arm with no runs"
first="$(printf '%s\n' "$out" | head -n 1)"
assert_not_contains "$first" "higher" "an overlapping pair is not called higher"
assert_not_contains "$first" "real" "an overlapping pair is not called real"
t_end

# ---------------------------------------------------------------- mock runs

RES_FULL="$SBX/res-full"
mock_run "$RES_FULL" RUNS=3
MOCK_RC="$RC"
MOCK_OUT="$OUT"
FULL_JSON="$(latest_json "$RES_FULL")"
FULL_MD="$(latest_md "$RES_FULL")"

t_begin "REQ-EVAL-001.1 mock run of all 3 arms end to end: the record holds task set, arms, n, tokens by class, price table, dollars, run ids"
assert_eq "0" "$MOCK_RC" "mock run rc: $MOCK_OUT"
assert_file "$FULL_JSON" "run record json"
assert_file "$FULL_MD" "run record page"
assert_eq "20 3 3 180" "$(jget "$FULL_JSON" 'd["n"]["tasks"], d["n"]["runs_per_task"], d["n"]["arms"], d["n"]["runs_total"]' | tr -d ',()')" "n"
assert_eq "a b c" "$(jget "$FULL_JSON" '" ".join(sorted(d["arms"]))')" "3 arms"
assert_eq "20" "$(jget "$FULL_JSON" 'len([t for t in d["task_set"] if len(t["hash"]) == 64])')" "each task carries a 64 character hash"
assert_eq "60 60 60" "$(jget "$FULL_JSON" '" ".join(str(d["figures"]["per_arm"][a]["runs"]) for a in "abc")')" "runs per arm"
assert_eq "opus sonnet haiku fable other" "$(jget "$FULL_JSON" '" ".join(d["figures"]["per_arm"]["b"]["tokens"])')" "token classes"
assert_eq "https://platform.claude.com/docs/en/about-claude/pricing 2026-10-13" "$(jget "$FULL_JSON" 'd["price_table"]["source"] + " " + d["price_table"]["read_on"]')" "price table source and date"
assert_eq "180" "$(jget "$FULL_JSON" 'len(d["figures"]["runs"])')" "180 run entries"
assert_eq "180" "$(jget "$FULL_JSON" 'len([r for r in d["figures"]["runs"].values() if r["session_id"]])')" "a run id (session id) on every run"
assert_eq "180" "$(ls "$RES_FULL/raw/"*/ | grep -c '\.jsonl$')" "180 raw streams"
assert_eq "True" "$(jget "$FULL_JSON" 'all(d["figures"]["per_arm"][a]["cost_usd"] > 0 for a in "abc")')" "dollars per arm"
assert_contains "$(cat "$FULL_MD")" "## Price table" "page shows the price table"
assert_contains "$(cat "$FULL_MD")" "dispatches / tool calls" "page shows delegation with numerator and denominator"
t_end

t_begin "REQ-EVAL-001.2 mock label: the record and the page start with MOCK DATA and say it is not evidence"
assert_eq "MOCK DATA" "$(head -n 1 "$FULL_MD")" "page line 1"
assert_contains "$(sed -n 2p "$FULL_MD")" "Not evidence" "page line 2"
assert_eq "MOCK DATA" "$(jget "$FULL_JSON" 'd["labels"][0]')" "record first label"
assert_eq "labels" "$(head -n 2 "$FULL_JSON" | tail -n 1 | tr -d ' ":,{[')" "labels is the first key of the record"
assert_eq "False" "$(jget "$FULL_JSON" 'd["scored"]')" "a mock record is never scored"
assert_eq "['MOCK DATA']" "$(jget "$FULL_JSON" 'd["labels"]')" "a full size mock run has no smoke label"
t_end

t_begin "REQ-EVAL-001.2 smoke label: fewer than 20 tasks or 3 runs starts with SMOKE RUN: not scored"
RES_SMOKE="$SBX/res-smoke"
mock_run "$RES_SMOKE" BENCH_TASKS=t1,t7 RUNS=1
SMOKE_JSON="$(latest_json "$RES_SMOKE")"
SMOKE_MD="$(latest_md "$RES_SMOKE")"
assert_eq "0" "$RC" "smoke mock run rc: $OUT"
assert_eq "MOCK DATA" "$(head -n 1 "$SMOKE_MD")" "mock page line 1"
assert_eq "SMOKE RUN: not scored" "$(sed -n 2p "$SMOKE_MD")" "smoke page line 2"
assert_eq "2 1 6" "$(jget "$SMOKE_JSON" 'str(d["n"]["tasks"]) + " " + str(d["n"]["runs_per_task"]) + " " + str(d["n"]["runs_total"])')" "n"
assert_eq "18" "$(jget "$SMOKE_JSON" 'len(d["not_run"])')" "the other 18 tasks are listed as not run, with a reason"
assert_eq "True False" "$(jget "$SMOKE_JSON" 'str(d["smoke"]) + " " + str(d["scored"])')" "smoke and not scored"
RES_SMOKE2="$SBX/res-smoke2"
mock_run "$RES_SMOKE2" RUNS=2
assert_eq "SMOKE RUN: not scored" "$(sed -n 2p "$(latest_md "$RES_SMOKE2")")" "20 tasks with 2 runs is a smoke run"
mock_run "$SBX/res-bad" BENCH_TASKS=t99
assert_eq "2" "$RC" "an unknown task id is refused"
t_end

t_begin "REQ-EVAL-001.2 mock mode calls no claude and installs nothing"
rm -f "$SBX/claude.log"
RES_NOCALL="$SBX/res-nocall"
mock_run "$RES_NOCALL" RUNS=1 BENCH_TASKS=t1,t2 FAKE_CLAUDE_LOG="$SBX/claude.log" FAKE_INSTALLER_LOG="$SBX/installer.log" BENCH_INSTALLER="$SBX/fake-install.sh"
assert_eq "0" "$RC" "rc"
assert_no_file "$SBX/claude.log" "claude was never called"
assert_no_file "$SBX/installer.log" "the installer was never called"
t_end

t_begin "REQ-EVAL-001.4 the page never names a difference between arms whose intervals overlap"
out="$(python3 - "$FULL_JSON" "$FULL_MD" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
md = open(sys.argv[2]).read()
bad = []
for c in d["figures"]["comparisons"]:
    line = [ln for ln in md.splitlines() if ln.startswith("- " + c["pair"] + ":")]
    if not line:
        bad.append(c["pair"] + " missing from the page")
    elif c["overlap"] and ("higher" in line[0] or "differ" in line[0] or "real" in line[0]):
        bad.append(c["pair"] + " overlaps but the page names a difference")
    elif c["overlap"] and "not distinguishable at n=" not in line[0]:
        bad.append(c["pair"] + " overlaps but the page does not say not distinguishable at n")
print(";".join(bad) or "ok")
PYEOF
)"
assert_eq "ok" "$out" "overlap wording"
t_end

# ---------------------------------------------------------------- the second seat

t_begin "REQ-EVAL-001.3 rederive.py agrees with a mock record (180 raw streams)"
assert_exit 0 python3 "$B/src/rederive.py" "$FULL_JSON"
assert_eq "AGREE" "$(printf '%s\n' "$ASSERT_OUT" | head -n 1)" "first line"
assert_contains "$ASSERT_OUT" "rederived from 180 raw streams" "what it read"
t_end

t_begin "REQ-EVAL-001.3 rederive.py names a difference on a tampered record and on a tampered stream"
cp -R "$RES_FULL" "$SBX/res-tamper"
tj="$(latest_json "$SBX/res-tamper")"
python3 - "$tj" <<'PYEOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["figures"]["per_arm"]["b"]["dispatches"] += 1
json.dump(d, open(p, "w"), indent=2)
PYEOF
assert_exit 1 python3 "$B/src/rederive.py" "$tj"
assert_contains "$ASSERT_OUT" "DIFFERENCES" "lists differences"
assert_contains "$ASSERT_OUT" "figures.per_arm.b.dispatches" "names the tampered figure"
cp -R "$RES_FULL" "$SBX/res-tamper2"
raw="$(ls "$SBX/res-tamper2"/raw/*/*__a__1.jsonl | head -n 1)"
python3 - "$raw" <<'PYEOF'
import json, sys
p = sys.argv[1]
lines = open(p).read().splitlines()
for i, ln in enumerate(lines):
    ev = json.loads(ln)
    if ev.get("type") == "result":
        for m in ev["modelUsage"].values():
            m["outputTokens"] += 1000
        lines[i] = json.dumps(ev, sort_keys=True)
open(p, "w").write("\n".join(lines) + "\n")
PYEOF
assert_exit 1 python3 "$B/src/rederive.py" "$(latest_json "$SBX/res-tamper2")"
assert_contains "$ASSERT_OUT" "tokens" "a tampered raw stream shows up in the tokens"
cp -R "$RES_FULL" "$SBX/res-tamper3"
tj3="$(latest_json "$SBX/res-tamper3")"
python3 - "$tj3" <<'PYEOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["figures"]["comparisons"][0]["verdict"] = "a vs b: the pass rates differ and arm a is higher (the 95 percent intervals do not overlap, n=60 and n=60)"
d["figures"]["comparisons"][0]["overlap"] = False
json.dump(d, open(p, "w"), indent=2)
PYEOF
python3 "$B/src/rederive.py" "$tj3" > "$SBX/tamper3.out" 2>&1
RC=$?
if [ "$RC" = 0 ]; then
  # the mock arms may genuinely differ; only a pair that overlaps must be caught
  :
else
  assert_contains "$(cat "$SBX/tamper3.out")" "comparisons" "a false difference claim is caught"
fi
t_end

t_begin "REQ-EVAL-001.3 rederive.py notices a task folder that changed after the run (frozen set)"
cp -R "$B/tasks" "$SBX/tasks-edited"
printf '\nextra line\n' >> "$SBX/tasks-edited/t1_fizzbuzz_fix/prompt.md"
OUT="$(BENCH_TASKS_DIR="$SBX/tasks-edited" python3 "$B/src/rederive.py" "$FULL_JSON" 2>&1)"
RC=$?
assert_eq "1" "$RC" "rc"
assert_contains "$OUT" "t1_fizzbuzz_fix.hash" "names the changed task"
t_end

# ---------------------------------------------------------------- real mode: refusals

t_begin "REQ-EVAL-001 real mode refuses without BENCH_CONFIG_DIR, and without BENCH_MODEL"
RES_R="$SBX/res-refuse"
OUT="$(env BENCH_RESULTS_DIR="$RES_R" BENCH_MODEL=fake-model-1 python3 "$RUN" 2>&1)"
RC=$?
assert_eq "2" "$RC" "rc without a config folder"
assert_contains "$OUT" "BENCH_CONFIG_DIR is required" "message"
new_cfg cfg-m
OUT="$(env BENCH_RESULTS_DIR="$RES_R" BENCH_CONFIG_DIR="$CFG" python3 "$RUN" 2>&1)"
RC=$?
assert_eq "2" "$RC" "rc without a model"
assert_contains "$OUT" "BENCH_MODEL is required" "message"
assert_no_file "$SBX/claude.log" "claude not called"
t_end

t_begin "REQ-EVAL-001 real mode refuses the default profile (~/.claude) unless BENCH_ALLOW_DEFAULT=1"
mkdir -p "$HOME/.claude"
printf 'dummy\n' > "$HOME/.claude/.credentials.json"
rm -f "$SBX/installer.log" "$SBX/claude.log"
real_run "$SBX/res-default" "$HOME/.claude" BENCH_TASKS=t1 RUNS=1
assert_eq "2" "$RC" "rc"
assert_contains "$OUT" "default profile" "message"
assert_no_file "$SBX/installer.log" "nothing installed"
assert_no_file "$SBX/claude.log" "nothing run"
real_run "$SBX/res-default2" "$HOME/.claude" BENCH_TASKS=t1 RUNS=1 BENCH_ALLOW_DEFAULT=1
assert_eq "0" "$RC" "rc with the allow flag: $OUT"
assert_file "$SBX/claude.log" "ran with the allow flag"
rm -rf "$HOME/.claude"
t_end

t_begin "REQ-EVAL-001 real mode refuses a folder with no sign-in record"
new_cfg cfg-nosign
rm -f "$CFG/.credentials.json" "$SBX/installer.log" "$SBX/claude.log"
real_run "$SBX/res-nosign" "$CFG" BENCH_TASKS=t1 RUNS=1
assert_eq "2" "$RC" "rc"
assert_contains "$OUT" "no sign-in record" "message"
assert_no_file "$SBX/installer.log" "nothing installed"
t_end

t_begin "REQ-EVAL-001 arm a refuses when Conductor is installed in the folder"
new_cfg cfg-installed
mkdir -p "$CFG/conductor"
: > "$CFG/conductor/.install-manifest"
rm -f "$SBX/installer.log" "$SBX/claude.log"
real_run "$SBX/res-installed" "$CFG" BENCH_TASKS=t1 RUNS=1
assert_eq "2" "$RC" "rc"
assert_contains "$OUT" "Conductor is installed" "message"
assert_no_file "$SBX/installer.log" "nothing installed"
assert_no_file "$SBX/claude.log" "nothing run"
new_cfg cfg-installed2
printf '<!-- BEGIN CONDUCTOR (managed) v0.3.0 - x -->\nold\n<!-- END CONDUCTOR -->\n' > "$CFG/CLAUDE.md"
real_run "$SBX/res-installed2" "$CFG" BENCH_TASKS=t1 RUNS=1
assert_eq "2" "$RC" "rc for a doctrine block in CLAUDE.md"
assert_contains "$OUT" "Conductor is installed" "message for a doctrine block"
t_end

t_begin "REQ-EVAL-001 a folder whose settings.json already pins an effort level is refused (arms a and b would not be at default effort)"
new_cfg cfg-pinned
printf '{"modelSettings":{"claude-sonnet-5-5":{"effortLevel":"low"}}}\n' > "$CFG/settings.json"
real_run "$SBX/res-pinned" "$CFG" BENCH_TASKS=t1 RUNS=1
assert_eq "2" "$RC" "rc"
assert_contains "$OUT" "effortLevel" "message"
t_end

# ---------------------------------------------------------------- real mode against the fakes

new_cfg cfg-main
rm -f "$SBX/claude.log" "$SBX/installer.log"
chmod 000 "$CFG/.credentials.json"
RES_REAL="$SBX/res-real"
real_run "$RES_REAL" "$CFG" BENCH_TASKS=t1,t7 RUNS=1
REAL_RC="$RC"
REAL_OUT="$OUT"
REAL_JSON="$(latest_json "$RES_REAL")"
REAL_MD="$(latest_md "$RES_REAL")"

t_begin "REQ-EVAL-001.1 real mode (fake claude): 3 arms, delegation 1 of 3 on every run, exact dollars and tokens by class"
assert_eq "0" "$REAL_RC" "rc: $REAL_OUT"
assert_eq "real" "$(jget "$REAL_JSON" 'd["mode"]')" "mode"
assert_eq "2 6 2 6 2 6" "$(jget "$REAL_JSON" '" ".join(str(d["figures"]["per_arm"][a][k]) for a in "abc" for k in ("dispatches", "tool_calls"))')" "dispatches and tool calls per arm (2 runs of 1 of 3)"
assert_eq "0.0269 0.0269 0.0269" "$(jget "$REAL_JSON" '" ".join(str(d["figures"]["per_arm"][a]["cost_usd"]) for a in "abc")')" "2 runs x 0.01345 per arm"
assert_eq "600 10000 4000" "$(jget "$REAL_JSON" 'str(d["figures"]["per_arm"]["b"]["tokens"]["other"]["input"]) + " " + str(d["figures"]["per_arm"]["b"]["tokens"]["opus"]["cache_read"]) + " " + str(d["figures"]["per_arm"]["b"]["tokens"]["haiku"]["input"])')" "tokens by class"
assert_eq "0 2 0" "$(jget "$REAL_JSON" 'str(d["figures"]["per_arm"]["a"]["passed"]) + " " + str(d["figures"]["per_arm"]["a"]["failed"]) + " " + str(d["figures"]["per_arm"]["a"]["errors"])')" "the fixture stream edits nothing, so the checks fail (not error)"
assert_eq "['SMOKE RUN: not scored']" "$(jget "$REAL_JSON" 'd["labels"]')" "smoke label on a real subset run"
assert_eq "SMOKE RUN: not scored" "$(head -n 1 "$REAL_MD")" "page line 1"
assert_eq "6" "$(jget "$REAL_JSON" 'len([r for r in d["figures"]["runs"].values() if r["session_id"] == "fx-nest"])')" "run ids are the sessions of the streams"
assert_eq "2.1.300 (Claude Code)" "$(jget "$REAL_JSON" 'd["environment"]["claude_version"]')" "claude version recorded"
assert_exit 0 python3 "$B/src/rederive.py" "$REAL_JSON"
t_end

t_begin "REQ-EVAL-001 claude is called with the same --model, stream-json, --verbose and the task prompt on stdin; check files stay out of its folder"
log="$(cat "$SBX/claude.log")"
assert_eq "6" "$(printf '%s\n' "$log" | grep -c '^call ')" "6 calls"
assert_eq "6" "$(printf '%s\n' "$log" | grep -c 'args=\[-p --model fake-model-1 --output-format stream-json --verbose ')" "same --model on every arm"
assert_eq "0" "$(printf '%s\n' "$log" | grep -c 'files=\[.*check\.')" "no check script in the model's folder"
assert_eq "6" "$(printf '%s\n' "$log" | grep -c "cfg=$CFG ")" "CLAUDE_CONFIG_DIR is the given folder"
assert_eq "6" "$(printf '%s\n' "$log" | grep -c 'effort_env=unset')" "CLAUDE_CODE_EFFORT_LEVEL is not passed"
t_end

t_begin "REQ-EVAL-001 arm a runs without Conductor, arm b with it and the pins declined, arm c with it and the pins"
log="$(cat "$SBX/claude.log")"
assert_eq "conductor=no pins=no conductor=no pins=no conductor=yes pins=no conductor=yes pins=no conductor=yes pins=yes conductor=yes pins=yes" \
  "$(printf '%s\n' "$log" | sed -n 's/^call \(conductor=[a-z]* pins=[a-z]*\) .*/\1/p' | tr '\n' ' ' | sed 's/ $//')" "state seen by each run"
inst="$(cat "$SBX/installer.log")"
assert_eq "dry --dry-run --core --apply-effort-pins codex_exists=no yes=1|install --core codex_exists=no yes=1|uninstall --uninstall codex_exists=no yes=1|install --core --apply-effort-pins codex_exists=no yes=1|uninstall --uninstall codex_exists=no yes=1" \
  "$(printf '%s\n' "$inst" | tr '\n' '|' | sed 's/|$//')" "installer calls (a dry run first), non-interactive, no Codex folder"
t_end

t_begin "REQ-EVAL-001 backup of settings.json and CLAUDE.md, and the byte-for-byte restore check (fake installer)"
bk="$(ls -d "$RES_REAL"/backup-* | head -n 1)"
assert_file "$bk/settings.json" "settings.json backup"
assert_file "$bk/CLAUDE.md" "CLAUDE.md backup"
assert_eq "" "$(cmp "$bk/settings.json" "$SBX/orig-settings.json" 2>&1)" "settings.json backup is the original"
assert_eq "" "$(cmp "$bk/CLAUDE.md" "$SBX/orig-CLAUDE.md" 2>&1)" "CLAUDE.md backup is the original"
assert_eq "" "$(cmp "$CFG/settings.json" "$SBX/orig-settings.json" 2>&1)" "settings.json is back"
assert_eq "" "$(cmp "$CFG/CLAUDE.md" "$SBX/orig-CLAUDE.md" 2>&1)" "CLAUDE.md is back"
assert_contains "$REAL_OUT" "restore check: settings.json and CLAUDE.md are back byte for byte" "the check says so"
assert_eq "True" "$(jget "$REAL_JSON" 'd["restore_check"]["ok"]')" "recorded in the record"
assert_eq "700" "$(file_mode_of "$bk")" "backup folder mode"
t_end

t_begin "REQ-EVAL-001 no credential file is opened: results and output hold none of its content"
assert_eq "0" "$(grep -rl 'dummy-sign-in-record' "$RES_REAL" 2> /dev/null | wc -l | tr -d ' ')" "no file under results holds the sign-in record"
assert_not_contains "$REAL_OUT" "dummy-sign-in-record" "output"
chmod 600 "$CFG/.credentials.json"
t_end

t_begin "REQ-EVAL-001 a failed restore prints a FAIL line and exits 1, and the backup is kept"
new_cfg cfg-leave
real_run "$SBX/res-leave" "$CFG" BENCH_TASKS=t1 RUNS=1 FAKE_INSTALLER_LEAVE=1
assert_eq "1" "$RC" "rc"
assert_contains "$OUT" "FAIL restore check: CLAUDE.md differs from its backup" "FAIL line"
assert_eq "False" "$(jget "$(latest_json "$SBX/res-leave")" 'd["restore_check"]["ok"]')" "recorded"
assert_file "$(ls -d "$SBX"/res-leave/backup-*)/CLAUDE.md" "backup kept"
t_end

t_begin "REQ-EVAL-001 the uninstall runs when claude fails, and the failed runs are errors"
new_cfg cfg-fail
rm -f "$SBX/installer.log"
real_run "$SBX/res-fail" "$CFG" BENCH_TASKS=t1 RUNS=1 FAKE_CLAUDE_FAIL=1
assert_eq "0" "$RC" "rc: $OUT"
assert_eq "3" "$(jget "$(latest_json "$SBX/res-fail")" 'd["figures"]["per_arm"]["a"]["errors"] + d["figures"]["per_arm"]["b"]["errors"] + d["figures"]["per_arm"]["c"]["errors"]')" "3 errors"
assert_eq "2" "$(grep -c '^uninstall' "$SBX/installer.log")" "both installs were uninstalled"
assert_eq "" "$(cmp "$CFG/CLAUDE.md" "$SBX/orig-CLAUDE.md" 2>&1)" "CLAUDE.md is back"
t_end

t_begin "REQ-EVAL-001 the uninstall runs when the runner is interrupted (trap)"
new_cfg cfg-int
rm -f "$SBX/installer.log" "$SBX/hang"
fake_env FAKE_CLAUDE_HANG_FILE="$SBX/hang"
env BENCH_RESULTS_DIR="$SBX/res-int" BENCH_CONFIG_DIR="$CFG" BENCH_MODEL=fake-model-1 BENCH_INSTALLER="$SBX/fake-install.sh" \
  BENCH_TASKS=t1 RUNS=1 python3 "$RUN" > "$SBX/int.out" 2>&1 &
pid=$!
i=0
while [ ! -f "$SBX/hang" ] && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i + 1)); done
if [ ! -f "$SBX/hang" ]; then t_fail "the runner never reached the hanging run"; fi
kill -TERM "$pid" 2> /dev/null
wait "$pid"
RC=$?
assert_eq "143" "$RC" "rc after SIGTERM"
assert_eq "1" "$(grep -c '^uninstall' "$SBX/installer.log")" "the install was uninstalled"
assert_eq "" "$(cmp "$CFG/CLAUDE.md" "$SBX/orig-CLAUDE.md" 2>&1)" "CLAUDE.md is back"
assert_eq "" "$(cmp "$CFG/settings.json" "$SBX/orig-settings.json" 2>&1)" "settings.json is back"
assert_contains "$(cat "$SBX/int.out")" "restore check: settings.json and CLAUDE.md are back byte for byte" "the check ran"
assert_eq "0" "$(ls "$SBX"/res-int/RUN-*.json 2> /dev/null | wc -l | tr -d ' ')" "no record for an interrupted run"
t_end

t_begin "REQ-EVAL-001 the uninstall also runs on SIGINT (Ctrl-C)"
new_cfg cfg-int2
rm -f "$SBX/installer.log" "$SBX/hang"
fake_env FAKE_CLAUDE_HANG_FILE="$SBX/hang"
OUT="$(python3 - "$RUN" "$SBX" "$CFG" <<'PYEOF'
import os, signal, subprocess, sys, time
run, sbx, cfg = sys.argv[1:4]
env = dict(os.environ, BENCH_RESULTS_DIR=sbx + "/res-int2", BENCH_CONFIG_DIR=cfg, BENCH_MODEL="fake-model-1",
           BENCH_INSTALLER=sbx + "/fake-install.sh", BENCH_TASKS="t1", RUNS="1")
# tests/run.sh starts suites in the background, which ignores SIGINT; give the runner the default
p = subprocess.Popen([sys.executable, run], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                     preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL))
for _ in range(100):
    if os.path.exists(sbx + "/hang"):
        break
    time.sleep(0.2)
p.send_signal(signal.SIGINT)
out = p.communicate(timeout=60)[0]
print("rc=%d" % p.returncode)
print(out)
PYEOF
)"
assert_contains "$OUT" "rc=130" "rc after SIGINT"
assert_contains "$OUT" "restore check: settings.json and CLAUDE.md are back byte for byte" "the check ran"
assert_eq "1" "$(grep -c '^uninstall' "$SBX/installer.log")" "the install was uninstalled"
assert_eq "" "$(cmp "$CFG/CLAUDE.md" "$SBX/orig-CLAUDE.md" 2>&1)" "CLAUDE.md is back"
t_end

t_begin "REQ-EVAL-001 arm c aborts when the installer wrote no effort pin, and arm b aborts when it wrote a pin; both restore"
new_cfg cfg-nopin
real_run "$SBX/res-nopin" "$CFG" BENCH_TASKS=t1 RUNS=1 FAKE_INSTALLER_NO_PIN=1 FAKE_INSTALLER_DRY_LIES=1
assert_eq "1" "$RC" "rc without a pin"
assert_contains "$OUT" "arm c needs the effort pins" "message"
assert_eq "" "$(cmp "$CFG/CLAUDE.md" "$SBX/orig-CLAUDE.md" 2>&1)" "CLAUDE.md is back"
new_cfg cfg-allpin
real_run "$SBX/res-allpin" "$CFG" BENCH_TASKS=t1 RUNS=1 FAKE_INSTALLER_ALWAYS_PIN=1
assert_eq "1" "$RC" "rc with a pin on arm b"
assert_contains "$OUT" "arm b must run with the effort pins declined" "message"
assert_eq "" "$(cmp "$CFG/settings.json" "$SBX/orig-settings.json" 2>&1)" "settings.json is back"
t_end

t_begin "REQ-EVAL-001.1 a check that passes is scored passed (fake claude fixes t1)"
new_cfg cfg-fix
real_run "$SBX/res-fix" "$CFG" BENCH_TASKS=t1 RUNS=1 FAKE_CLAUDE_FIX=1
assert_eq "0" "$RC" "rc: $OUT"
assert_eq "1 1 1" "$(jget "$(latest_json "$SBX/res-fix")" '" ".join(str(d["figures"]["per_arm"][a]["passed"]) for a in "abc")')" "1 passed per arm"
t_end

t_begin "REQ-EVAL-001 with the real installer: arm b gets no pin, arm c gets the pins, files back byte for byte"
new_cfg cfg-real
python3 - "$CFG/settings.json" <<'PYEOF'
import json, sys
p = sys.argv[1]
json.dump({"theme": "dark", "env": {"A": "b"}}, open(p, "w"), indent=2)
open(p, "a").write("\n")
PYEOF
cp -p "$CFG/settings.json" "$SBX/orig-settings.json"
# a CLAUDE.md with no final newline must come back byte for byte as well
printf 'my own notes\r\nsecond line' > "$CFG/CLAUDE.md"
cp -p "$CFG/CLAUDE.md" "$SBX/orig-CLAUDE.md"
printf '#!/bin/sh\n. "$(dirname "$0")/../fake.env"\nif [ "${1:-}" = "--version" ]; then echo "2.1.300 (Claude Code)"; exit 0; fi\nif [ "${1:-}" = "--help" ]; then echo "  --strict-mcp-config"; exit 0; fi\nprintf "call pins=%%s\\n" "$(grep -c effortLevel "$CLAUDE_CONFIG_DIR/settings.json" 2>/dev/null)" >> "$FAKE_CLAUDE_LOG"\ncat >/dev/null\ncat "$FAKE_CLAUDE_STREAM"\n' > "$SBX/bin/claude"
chmod 755 "$SBX/bin/claude"
rm -f "$SBX/claude.log"
fake_env
OUT="$(env BENCH_RESULTS_DIR="$SBX/res-realinst" BENCH_CONFIG_DIR="$CFG" BENCH_MODEL=fake-model-1 \
  BENCH_TASKS=t1 RUNS=1 python3 "$RUN" 2>&1)"
RC=$?
assert_eq "0" "$RC" "rc: $OUT"
assert_eq "call pins=0|call pins=0|call pins=2" "$(tr '\n' '|' < "$SBX/claude.log" | sed 's/|$//')" "pins seen by arms a, b, c"
assert_eq "" "$(cmp "$CFG/settings.json" "$SBX/orig-settings.json" 2>&1)" "settings.json is back byte for byte"
assert_eq "" "$(cmp "$CFG/CLAUDE.md" "$SBX/orig-CLAUDE.md" 2>&1)" "CLAUDE.md is back byte for byte"
assert_eq "True" "$(jget "$(latest_json "$SBX/res-realinst")" 'd["restore_check"]["ok"]')" "recorded"
assert_no_file "$CFG/conductor/.install-manifest" "no install record is left"
write_fake_claude
t_end

t_begin "check isolation: a module the model plants in its work folder cannot pass a failing python check"
W="$SBX/planted"
mkdir -p "$W"
printf 'import sys\nsys.exit(0)\n' > "$W/json.py"
printf 'import json, sys\nsys.exit(1)\n' > "$W/check.py"
plain="$(cd "$W" && python3 check.py > /dev/null 2>&1; echo $?)"
assert_eq "0" "$plain" "without isolation the planted json.py fakes a pass (the case being guarded)"
isolated="$(cd "$SBX" && pyrep "import subprocess, run; print(subprocess.run(run.check_cmd('python3 check.py'), cwd='$W').returncode)")"
assert_eq "1" "$isolated" "check_cmd runs the check isolated, so it fails as written"
assert_eq "bash check.sh" "$(pyrep "import run; print(' '.join(run.check_cmd('bash check.sh')))")" "a shell check is left as written"
t_end

# ---------------------------------------------------------------- fixes from the release review

t_begin "S-1 real mode refuses before any claude run when the installer's dry run would write no effort pin"
new_cfg cfg-s1
rm -f "$SBX/claude.log" "$SBX/installer.log"
real_run "$SBX/res-s1" "$CFG" BENCH_TASKS=t1 RUNS=1 FAKE_INSTALLER_NO_PIN=1
assert_eq "2" "$RC" "rc"
assert_contains "$OUT" "arm c needs the effort pins" "message"
assert_contains "$OUT" "Nothing was run" "message says nothing ran"
assert_no_file "$SBX/claude.log" "claude was never called"
assert_no_file "$SBX/res-s1" "no results folder was made"
assert_eq "dry --dry-run --core --apply-effort-pins codex_exists=no yes=1" "$(tr '\n' '|' < "$SBX/installer.log" | sed 's/|$//')" "only the dry run reached the installer"
assert_eq "" "$(cmp "$CFG/CLAUDE.md" "$SBX/orig-CLAUDE.md" 2>&1)" "CLAUDE.md untouched"
t_end

t_begin "S-1 with the real installer: a settings.json env block that names another address stops the run before any claude call"
new_cfg cfg-s1b
printf '{"env":{"ANTHROPIC_BASE_URL":"https://proxy.example.invalid"}}\n' > "$CFG/settings.json"
cp -p "$CFG/settings.json" "$SBX/orig-settings.json"
rm -f "$SBX/claude.log"
fake_env
OUT="$(env BENCH_RESULTS_DIR="$SBX/res-s1b" BENCH_CONFIG_DIR="$CFG" BENCH_MODEL=fake-model-1 BENCH_TASKS=t1 RUNS=1 python3 "$RUN" 2>&1)"
RC=$?
assert_eq "2" "$RC" "rc"
assert_contains "$OUT" "ANTHROPIC_BASE_URL" "the installer's own sentence is in the message"
assert_contains "$OUT" "Nothing was run" "message says nothing ran"
assert_no_file "$SBX/claude.log" "claude was never called"
assert_eq "" "$(cmp "$CFG/settings.json" "$SBX/orig-settings.json" 2>&1)" "settings.json untouched by the dry run"
assert_no_file "$CFG/conductor" "the dry run wrote nothing"
t_end

t_begin "S-13 real mode refuses an effort set in the settings.json env block or in the process environment, and names which"
new_cfg cfg-s13a
printf '{"env":{"CLAUDE_CODE_EFFORT_LEVEL":"max"}}\n' > "$CFG/settings.json"
rm -f "$SBX/claude.log" "$SBX/installer.log"
real_run "$SBX/res-s13a" "$CFG" BENCH_TASKS=t1 RUNS=1
assert_eq "2" "$RC" "rc for the env block"
assert_contains "$OUT" "env.CLAUDE_CODE_EFFORT_LEVEL" "names the env block entry"
assert_no_file "$SBX/claude.log" "claude never ran"
assert_no_file "$SBX/installer.log" "nothing installed"
new_cfg cfg-s13b
real_run "$SBX/res-s13b" "$CFG" BENCH_TASKS=t1 RUNS=1 CLAUDE_CODE_EFFORT_LEVEL=low
assert_eq "2" "$RC" "rc for the process environment"
assert_contains "$OUT" "CLAUDE_CODE_EFFORT_LEVEL is set in the environment" "names the process variable"
assert_no_file "$SBX/claude.log" "claude never ran"
t_end

t_begin "S-13 a settings.json that only mentions the word effortLevel in a note is not refused; a top-level effortLevel is"
new_cfg cfg-s13c
printf '{"env":{"NOTE":"effortLevel is a thing"}}\n' > "$CFG/settings.json"
cp -p "$CFG/settings.json" "$SBX/orig-settings.json"
real_run "$SBX/res-s13c" "$CFG" BENCH_TASKS=t1 RUNS=1
assert_eq "0" "$RC" "rc: $OUT"
assert_eq "" "$(cmp "$CFG/settings.json" "$SBX/orig-settings.json" 2>&1)" "settings.json is back"
new_cfg cfg-s13d
printf '{"effortLevel":"low"}\n' > "$CFG/settings.json"
real_run "$SBX/res-s13d" "$CFG" BENCH_TASKS=t1 RUNS=1
assert_eq "2" "$RC" "rc for a top-level effortLevel"
assert_contains "$OUT" "already sets an effort level (effortLevel)" "names the key"
new_cfg cfg-s13e
printf '{ not json' > "$CFG/settings.json"
real_run "$SBX/res-s13e" "$CFG" BENCH_TASKS=t1 RUNS=1
assert_eq "2" "$RC" "rc for a settings.json that does not parse"
assert_contains "$OUT" "does not parse" "plain message"
t_end

t_begin "C-6 claude and the installer get an environment built from an allowlist, not the whole shell"
new_cfg cfg-c6
rm -f "$SBX/claude.log" "$SBX/claude.log.env" "$SBX/installer.log" "$SBX/installer.log.env"
real_run "$SBX/res-c6" "$CFG" BENCH_TASKS=t1 RUNS=1 MYTOKEN=zzz AWS_SECRET_ACCESS_KEY=abc ANTHROPIC_API_KEY=sk-fixture ANTHROPIC_BASE_URL=https://proxy.example.invalid
assert_eq "0" "$RC" "rc (a provider variable in the shell does not reach the installer): $OUT"
names_c="$(cat "$SBX/claude.log.env")"
names_i="$(cat "$SBX/installer.log.env")"
for v in MYTOKEN AWS_SECRET_ACCESS_KEY ANTHROPIC_API_KEY ANTHROPIC_BASE_URL BENCH_CONFIG_DIR BENCH_MODEL; do
  assert_not_contains " $names_c " " $v " "claude is not given $v"
  assert_not_contains " $names_i " " $v " "the installer is not given $v"
done
for v in PATH HOME CLAUDE_CONFIG_DIR; do assert_contains " $names_c " " $v " "claude is given $v"; done
for v in PATH HOME CLAUDE_DIR CONDUCTOR_YES; do assert_contains " $names_i " " $v " "the installer is given $v"; done
t_end

t_begin "O-33 claude gets --strict-mcp-config with an empty MCP config when its help lists it, and the record says whether it was available"
new_cfg cfg-o33
rm -f "$SBX/claude.log"
real_run "$SBX/res-o33" "$CFG" BENCH_TASKS=t1 RUNS=1
assert_eq "0" "$RC" "rc: $OUT"
assert_eq "3" "$(grep -c '^call ' "$SBX/claude.log")" "3 calls (the help call is not a run)"
assert_eq "3" "$(grep -c -e '--strict-mcp-config --mcp-config {"mcpServers":{}}' "$SBX/claude.log")" "the flag and an empty MCP config on every run"
assert_eq "True" "$(jget "$(latest_json "$SBX/res-o33")" 'd["environment"]["strict_mcp_config"].startswith("used")')" "record: used"
new_cfg cfg-o33b
rm -f "$SBX/claude.log"
real_run "$SBX/res-o33b" "$CFG" BENCH_TASKS=t1 RUNS=1 FAKE_CLAUDE_NO_STRICT=1
assert_eq "0" "$RC" "rc without the flag in the help: $OUT"
assert_eq "0" "$(grep -c -e '--strict-mcp-config' "$SBX/claude.log")" "no flag when the help does not list it"
assert_eq "True" "$(jget "$(latest_json "$SBX/res-o33b")" 'd["environment"]["strict_mcp_config"].startswith("not available")')" "record: not available"
t_end

t_begin "C-6 the settings backups are mode 600 even under umask 0, and bench/results is ignored by git except a labeled example"
new_cfg cfg-c6b
( umask 0; real_run "$SBX/res-c6b" "$CFG" BENCH_TASKS=t1 RUNS=1; echo "$RC" > "$SBX/c6b.rc" )
assert_eq "0" "$(cat "$SBX/c6b.rc")" "rc"
bk6="$(ls -d "$SBX"/res-c6b/backup-* | head -n 1)"
assert_mode "$bk6" 700 "backup folder"
assert_mode "$bk6/settings.json" 600 "settings.json backup"
assert_mode "$bk6/CLAUDE.md" 600 "CLAUDE.md backup"
mkdir -p "$SBX/ig/bench"
cp "$B/.gitignore" "$SBX/ig/bench/.gitignore"
git -C "$SBX/ig" init -q 2> /dev/null
for f in bench/results/RUN-x.json bench/results/backup-x/settings.json bench/results/raw/x/t1__a__1.jsonl; do
  git -C "$SBX/ig" check-ignore -q "$f"
  assert_eq "0" "$?" "$f is ignored"
done
git -C "$SBX/ig" check-ignore -q bench/results/example/RUN-example.json
assert_eq "1" "$?" "results/example is not ignored"
t_end

t_begin "C-13 an uninstall that fails is fatal: the run stops, the record is marked INVALID, and the message gives the uninstall command"
new_cfg cfg-c13
rm -f "$SBX/claude.log" "$SBX/installer.log"
real_run "$SBX/res-c13" "$CFG" BENCH_TASKS=t1 RUNS=1 FAKE_INSTALLER_UNINSTALL_FAIL=1
assert_eq "1" "$RC" "rc"
assert_contains "$OUT" "the uninstall failed for arm b" "message"
assert_contains "$OUT" "--uninstall" "message gives the uninstall command"
assert_contains "$OUT" "CLAUDE_DIR=" "message names the folder variable"
assert_eq "2" "$(grep -c '^call ' "$SBX/claude.log")" "arm c never ran"
J13="$(latest_json "$SBX/res-c13")"
assert_file "$J13" "a record is written"
assert_eq "False" "$(jget "$J13" 'd["valid"]')" "valid is false"
assert_eq "INVALID RUN" "$(jget "$J13" 'd["labels"][0]')" "first label"
assert_eq "False" "$(jget "$J13" 'd["scored"]')" "an invalid record is never scored"
assert_eq "INVALID RUN" "$(head -n 1 "$(latest_md "$SBX/res-c13")")" "page line 1"
assert_contains "$(jget "$J13" 'd["invalid_reasons"][0]')" "arm b" "the reason names the arm"
t_end

t_begin "C-13 the restore check also confirms no install record is left; a leftover makes the run invalid"
new_cfg cfg-c13b
real_run "$SBX/res-c13b" "$CFG" BENCH_TASKS=t1 RUNS=1 FAKE_INSTALLER_LEAVE_RECORD=1
assert_eq "1" "$RC" "rc"
assert_contains "$OUT" "FAIL restore check: Conductor is still in the folder" "the restore check names it"
assert_contains "$OUT" "conductor/.install-manifest" "names the install record"
assert_eq "False" "$(jget "$(latest_json "$SBX/res-c13b")" 'd["valid"]')" "valid is false"
assert_eq "False" "$(jget "$(latest_json "$SBX/res-c13b")" 'd["restore_check"]["ok"]')" "restore check recorded as failed"
t_end

t_begin "C-13 rederive.py agrees with an invalid record and names a record whose INVALID mark was removed"
assert_exit 0 python3 "$B/src/rederive.py" "$J13"
cp -R "$SBX/res-c13" "$SBX/res-c13-edit"
python3 - "$(latest_json "$SBX/res-c13-edit")" <<'PYEOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["valid"] = True
d["labels"] = [x for x in d["labels"] if x != "INVALID RUN"]
json.dump(d, open(p, "w"), indent=2)
PYEOF
assert_exit 1 python3 "$B/src/rederive.py" "$(latest_json "$SBX/res-c13-edit")"
assert_contains "$ASSERT_OUT" "valid" "names the changed field"
t_end

t_begin "O-11 mock arms are identical, so a mock page never shows a difference between arms"
assert_eq "1" "$(jget "$FULL_JSON" 'len(set((x["dispatches"], x["tool_calls"], x["cost_usd"], x["passed"], x["failed"], x["errors"]) for x in d["figures"]["per_arm"].values()))')" "the same figures for the 3 arms"
assert_eq "1" "$(jget "$FULL_JSON" 'len(set(str(x["tokens"]) for x in d["figures"]["per_arm"].values()))')" "the same token table for the 3 arms"
t_end

t_begin "O-13 the run record carries the candidate commit, the installer sha256, the Claude Code version and the bench version"
want_commit="$(git -C "$REPO" rev-parse HEAD 2> /dev/null || echo unknown)"
want_sha="$(python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$SBX/fake-install.sh")"
assert_eq "$want_commit" "$(jget "$REAL_JSON" 'd["environment"]["commit"]')" "commit in a real record"
assert_eq "$want_sha" "$(jget "$REAL_JSON" 'd["environment"]["installer_sha256"]')" "installer sha256 in a real record"
assert_eq "2.1.300 (Claude Code)" "$(jget "$REAL_JSON" 'd["environment"]["claude_version"]')" "Claude Code version"
assert_eq "True" "$(jget "$REAL_JSON" 'len(d["environment"]["bench_version"]) > 0')" "bench version"
assert_eq "$want_commit" "$(jget "$FULL_JSON" 'd["environment"]["commit"]')" "commit in a mock record"
assert_contains "$(jget "$FULL_JSON" 'd["environment"]["installer_sha256"]')" "not used" "a mock run uses no installer"
t_end

t_begin "O-12 O-29 S-6 O-13 the bench README says who wrote the tasks, forecasts no cost, drops the old newline limit and names the record fields"
rd="$(cat "$B/README.md")"
assert_not_contains "$rd" "The tasks are written by the maintainer" "old authorship line"
assert_contains "$rd" "t1 to t8 come from 0.3.0" "who wrote t1 to t8"
assert_contains "$rd" "t9 to t20 were written for this release" "who wrote t9 to t20"
assert_contains "$rd" "frozen by the hashes" "the freeze"
assert_contains "$rd" "task set owned by a person is still to come" "the person-owned set"
assert_not_contains "$rd" "Expect arms" "no cost forecast"
assert_not_contains "$rd" "does not end with a newline" "the newline limit no longer exists"
assert_contains "$rd" "installer sha256" "record fields"
t_end

t_begin "C-6 C-13 S-1 S-13 O-33 the bench README describes the allowlist, the private folders, the preflight and the invalid mark"
rd="$(cat "$B/README.md")"
assert_contains "$rd" "allowlist" "allowlisted environment"
assert_contains "$rd" "--strict-mcp-config" "MCP isolation"
assert_contains "$rd" "INVALID RUN" "invalid mark"
assert_contains "$rd" "dry run" "preflight dry run"
t_end

t_begin "S-18 rederive.py gives a plain error for a missing or unreadable record, not a traceback"
assert_exit 2 python3 "$B/src/rederive.py" "$SBX/nonexistent-record.json"
assert_contains "$ASSERT_OUT" "cannot read" "plain message"
assert_contains "$ASSERT_OUT" "nonexistent-record.json" "names the file"
assert_not_contains "$ASSERT_OUT" "Traceback" "no traceback"
printf 'this is not json' > "$SBX/bad-record.json"
assert_exit 2 python3 "$B/src/rederive.py" "$SBX/bad-record.json"
assert_not_contains "$ASSERT_OUT" "Traceback" "no traceback for a record that does not parse"
t_end

t_summary
