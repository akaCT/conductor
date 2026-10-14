#!/bin/bash
# tests/test-seats.sh: the judge ladder (REQ-SEAT-002, golden G-11)
# and the judge agent files (REQ-SEAT-001.4, REQ-SEAT-002.5, .8). This suite also
# holds the body of install case 11, "judge rung refused": a judge rung
# or alias that is not on the ladder, opus included, is refused before any write.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/lib/sandbox.sh"
. "$HERE/lib/l2-common.sh"

sandbox_new
trap sandbox_cleanup EXIT
sandbox_guard
build_installer seats

AGENTS="$REPO/payload/claude/agents"
JUDGE="$CLAUDE_DIR/agents/judge.md"

fm_get() { sed -n '2,/^---$/p' "$1" | sed -n "s/^$2: *//p" | head -n 1; }

# ---------------------------------------------------------------- the judge files

t_begin "REQ-SEAT-002.8 judge tools are exactly Read, Grep and Glob in both rung files"
for f in judge-rung1 judge-rung3; do
  assert_eq "[Read, Grep, Glob]" "$(fm_get "$AGENTS/$f.md" tools)" "$f tools"
  fmt="$(sed -n '2,/^---$/p' "$AGENTS/$f.md")"
  for banned in Bash Edit Write NotebookEdit Agent WebFetch WebSearch; do
    case "$fmt" in *"$banned"*) t_fail "$f frontmatter names $banned" ;; esac
  done
  txt="$(cat "$AGENTS/$f.md")"
  assert_contains "$txt" "Read only the paths your contract names" "$f path rule"
  assert_contains "$txt" "no shell and no network" "$f says it holds no shell or network"
done
t_end

t_begin "REQ-SEAT-002.5 rung 3 text requires a fresh context, a re-derivation from the spec and raw data, and says never max"
r3="$(cat "$AGENTS/judge-rung3.md")"
assert_contains "$r3" "fresh context"
assert_contains "$r3" "sees only the artifact" "sees only the artifact"
assert_contains "$r3" "Re-derive the result yourself from the spec and the raw data"
assert_contains "$r3" "Never max"
assert_contains "$r3" "weaker than a different family"
assert_eq "sonnet" "$(fm_get "$AGENTS/judge-rung3.md" model)" "rung 3 alias"
assert_eq "fable" "$(fm_get "$AGENTS/judge-rung1.md" model)" "rung 1 alias"
t_end

# ---------------------------------------------------------------- G-11

t_begin "REQ-SEAT-002.1 G-11 case 1: Fable 5.1 available, runtime 2.1.260, first-party -> rung 1"
fresh; set_cc 2.1.260
PTY_INPUT=$'y\nn\nn\n' inst_pty --core
assert_eq "0" "$RC" "rc"
assert_contains "$OUT" "Does your account have Fable 5.1?"
assert_contains "$OUT" "You are on judge rung 1"
assert_eq "fable" "$(fm_get "$JUDGE" model)" "model"
assert_eq "xhigh" "$(fm_get "$JUDGE" effort)" "effort"
assert_eq "[Read, Grep, Glob]" "$(fm_get "$JUDGE" tools)" "tools"
cmp -s "$AGENTS/judge-rung1.md" "$JUDGE" || t_fail "installed file differs from judge-rung1.md"
t_end

t_begin "REQ-SEAT-002.2 G-11 case 2: no Fable 5.1 -> rung 3 with the weaker-view statement"
fresh; set_cc 2.1.260
PTY_INPUT=$'n\nn\nn\n' inst_pty --core
assert_contains "$OUT" "You are on judge rung 3"
assert_contains "$OUT" "A same-lab judge is a weaker second view"
assert_eq "sonnet" "$(fm_get "$JUDGE" model)" "model"
assert_eq "xhigh" "$(fm_get "$JUDGE" effort)" "effort"
assert_eq "[Read, Grep, Glob]" "$(fm_get "$JUDGE" tools)" "tools"
cmp -s "$AGENTS/judge-rung3.md" "$JUDGE" || t_fail "installed file differs from judge-rung3.md"
t_end

t_begin "REQ-SEAT-002.6 G-11 case 3: no terminal, no flag, fresh config -> rung 3 and the way to change it is named"
fresh; set_cc 2.1.260
inst --core
assert_eq "0" "$RC" "rc"
assert_contains "$OUT" "You are on judge rung 3"
assert_contains "$OUT" "--judge-rung=1"
assert_not_contains "$OUT" "Does your account have Fable 5.1?"
assert_eq "sonnet" "$(fm_get "$JUDGE" model)" "model"
t_end

t_begin "REQ-SEAT-002.7 G-11 case 4: Fable 5.1 stated, runtime 2.1.256 -> rung 3 with the reason printed"
fresh; set_cc 2.1.256
inst --core --judge-rung=1
assert_contains "$OUT" "You are on judge rung 3"
assert_contains "$OUT" "rung 1 needs Claude Code 2.1.257 or later, and yours is 2.1.256"
assert_eq "sonnet" "$(fm_get "$JUDGE" model)" "model"
fresh; set_cc 2.1.296; export CLAUDE_CODE_USE_BEDROCK=1
inst --core --judge-rung=1
assert_contains "$OUT" "You are on judge rung 3"
assert_contains "$OUT" "rung 1 needs the Anthropic API"
assert_eq "sonnet" "$(fm_get "$JUDGE" model)" "model off first-party"
unset CLAUDE_CODE_USE_BEDROCK
fresh; set_cc none
inst --core --judge-rung=1
assert_contains "$(flat "$OUT")" "version could not be read"
assert_eq "sonnet" "$(fm_get "$JUDGE" model)" "model with unknown version"
t_end

t_begin "REQ-SEAT-002.7 below 2.1.257 the Fable 5.1 question is not asked"
fresh; set_cc 2.1.256
PTY_INPUT=$'y\nn\nn\n' inst_pty --core
assert_not_contains "$OUT" "Does your account have Fable 5.1?"
assert_contains "$OUT" "You are on judge rung 3"
assert_contains "$OUT" "yours is 2.1.256"
fresh; set_cc 2.1.296; export CLAUDE_CODE_USE_VERTEX=1
PTY_INPUT=$'y\nn\nn\n' inst_pty --core
assert_not_contains "$OUT" "Does your account have Fable 5.1?"
assert_contains "$OUT" "You are on judge rung 3"
unset CLAUDE_CODE_USE_VERTEX
t_end

t_begin "REQ-SEAT-002.6 G-11 case 5: no terminal, no flag, manifest records rung 1 -> rung 1 kept"
fresh; set_cc 2.1.260
mkdir -p "$CLAUDE_DIR/conductor"
printf '{"schema": 1, "product": "conductor", "files": [], "pins": [], "env_written": [], "judge_rung": 1}\n' > "$CLAUDE_DIR/conductor/.install-manifest"
inst --core
assert_contains "$OUT" "You are on judge rung 1"
assert_eq "fable" "$(fm_get "$JUDGE" model)" "model"
assert_eq "fable" "$(fm_get "$JUDGE" model)" "kept"
t_end

t_begin "REQ-SEAT-002.6 a re-run keeps the rung the first run recorded, and --judge-rung changes it"
fresh; set_cc 2.1.260
PTY_INPUT=$'y\nn\nn\n' inst_pty --core
assert_eq "fable" "$(fm_get "$JUDGE" model)" "first run"
inst --core
assert_eq "fable" "$(fm_get "$JUDGE" model)" "re-run with no terminal"
assert_contains "$OUT" "You are on judge rung 1"
inst --core --judge-rung=3
assert_eq "sonnet" "$(fm_get "$JUDGE" model)" "flag changed it"
inst --core
assert_eq "sonnet" "$(fm_get "$JUDGE" model)" "new rung recorded"
t_end

t_begin "REQ-SEAT-002.6 an interactive re-run over a recorded rung 1 defaults to yes"
fresh; set_cc 2.1.260
inst --core --judge-rung=1
PTY_INPUT=$'\nn\nn\n' inst_pty --core
assert_eq "fable" "$(fm_get "$JUDGE" model)" "Enter kept rung 1"
t_end

t_begin "REQ-SEAT-002.1 --judge-rung=1 on a qualifying runtime writes rung 1 with no question"
fresh; set_cc 2.1.260
inst --core --judge-rung=1
assert_eq "fable" "$(fm_get "$JUDGE" model)" "model"
assert_contains "$OUT" "You are on judge rung 1"
t_end

# ---------------------------------------------------------------- case 11

t_begin "case 11 judge rung refused: any rung or alias off the ladder exits non-zero before any write and leaves an earlier judge file alone"
fresh; set_cc 2.1.260
inst --core --judge-rung=1
cmp -s "$AGENTS/judge-rung1.md" "$JUDGE" || t_fail "setup: rung 1 judge not written"
before_judge="$(cat "$JUDGE")"
sandbox_tree_sum "$HOME" > "$SBX/tree-before.txt"
for bad in opus haiku 2 'a;b' 0 '' fable sonnet 13 '1 ' ' 3'; do
  assert_exit '!0' sandbox_notty /bin/bash "$INSTALL" --core "--judge-rung=$bad"
  assert_contains "$ASSERT_OUT" "1 or 3" "names the allowed values for [$bad]"
  sandbox_tree_sum "$HOME" > "$SBX/tree-after.txt"
  cmp -s "$SBX/tree-before.txt" "$SBX/tree-after.txt" || t_fail "[$bad] changed something under HOME"
done
assert_exit '!0' sandbox_notty /bin/bash "$INSTALL" --core --judge-rung
assert_contains "$ASSERT_OUT" "--judge-rung=1 or --judge-rung=3"
assert_eq "$before_judge" "$(cat "$JUDGE")" "earlier judge file unchanged"
t_end

t_begin "case 11 judge rung refused: a bad value is refused on a fresh config with 0 files written"
fresh; set_cc 2.1.260
rm -rf "$CLAUDE_DIR"
for bad in opus 2; do
  assert_exit '!0' sandbox_notty /bin/bash "$INSTALL" --core "--judge-rung=$bad"
  assert_no_file "$CLAUDE_DIR"
done
t_end

t_summary
