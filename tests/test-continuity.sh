#!/bin/bash
# tests/test-continuity.sh: the handoff skill, its checkpoint template and helper,
# the write record, the ledger template and the ledger append script
# (REQ-CNT-002, REQ-CNT-003, REQ-NFR-003.3 for the handoff skill).
#
# The helper is the "checkpoint" command of hooks/hooklib.py. Everything runs from a
# copy inside the sandbox config folder, as installed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/lib/sandbox.sh"

sandbox_new
trap sandbox_cleanup EXIT
sandbox_guard

HPY=/usr/bin/python3
if [ ! -x "$HPY" ]; then HPY="$(command -v python3)"; fi
CFG="$CLAUDE_DIR"
HK="$CFG/conductor/hooks"
SKILL="$REPO/payload/claude/skills/handoff/SKILL.md"
TEMPLATE="$REPO/payload/claude/skills/handoff/CHECKPOINT-TEMPLATE.md"
mkdir -p "$HK" "$CFG/conductor/bin" "$CFG/conductor/ledger"
cp "$REPO"/payload/claude/conductor/hooks/*.py "$HK/"
cp "$REPO/payload/claude/conductor/bin/ledger-append" "$CFG/conductor/bin/"
cp "$REPO/payload/claude/conductor/ledger/LEDGER-TEMPLATE.md" "$CFG/conductor/ledger/"
chmod 755 "$CFG/conductor/bin/ledger-append"
LEDGER_APPEND="$CFG/conductor/bin/ledger-append"

CPRC=0
CPOUT=""
cp_run() { # args to the checkpoint helper; stdin passes through; sets CPRC and CPOUT (stdout+stderr)
  CPOUT="$("$HPY" "$HK/hooklib.py" checkpoint "$@" 2>&1)"
  CPRC=$?
}
sum_of() { (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | awk '{print $1}'; }
mkproj() {
  PROJ="$SBX/proj-$1"
  rm -rf "${SBX:?}/proj-$1"
  mkdir -p "$PROJ"
  PROJ="$(cd "$PROJ" && pwd -P)"
}
draft() { # SESSION [PIN] -> a draft from the template on stdout
  sed -e "s/^Session: .*/Session: $1/" -e "s/^Pinned commit: .*/Pinned commit: ${2:-none}/" "$TEMPLATE"
}
record_field() { # PATH FIELD -> value from the write record
  "$HPY" -c '
import json, sys
d = json.load(open(sys.argv[1]))["entries"]
print(d[sys.argv[2]][sys.argv[3]])' "$CFG/conductor/state/checkpoint-record.json" "$1" "$2"
}
pointer() { # CWD SESSION -> OUT of the pointer hook on a startup event
  printf '{"hook_event_name":"SessionStart","source":"startup","session_id":"%s","cwd":"%s","transcript_path":"/nonexistent"}' "$2" "$1" > "$SBX/ptr.json"
  POUT="$("$HPY" "$HK/session-start-pointer.py" < "$SBX/ptr.json" 2>/dev/null)"
}

# ============================================================================
# The template and the skill text
# ============================================================================
t_begin "REQ-CNT-002.1 the template has At a Glance, Done, In Progress, Decisions, Pinned Facts, Next Steps and Launch Prompt"
last=0
for sec in "At a Glance" "Done" "In Progress" "Decisions" "Pinned Facts" "Next Steps" "Launch Prompt"; do
  n="$(grep -n "^## $sec\$" "$TEMPLATE" | head -1 | cut -d: -f1)"
  if [ -z "$n" ]; then t_fail "missing section $sec"; continue; fi
  [ "$n" -gt "$last" ] || t_fail "section $sec is out of order"
  last="$n"
done
t_end

t_begin "REQ-CNT-002.6 the template's first lines are Status, Session, Pinned commit and Updated, and the hook reads exactly those"
assert_eq "Status:" "$(sed -n 1p "$TEMPLATE" | cut -d' ' -f1)" "line 1"
assert_eq "Session:" "$(sed -n 2p "$TEMPLATE" | cut -d' ' -f1)" "line 2"
assert_eq "Pinned" "$(sed -n 3p "$TEMPLATE" | cut -d' ' -f1)" "line 3"
assert_eq "Updated:" "$(sed -n 4p "$TEMPLATE" | cut -d' ' -f1)" "line 4"
mkproj t6
cp_run write --session sess-t6 --project "$PROJ" < <(draft sess-t6)
assert_eq 0 "$CPRC" "template written as is: $CPOUT"
pointer "$PROJ" sess-t6
assert_contains "$POUT" "Checkpoint: handoffs/CURRENT.md" "the hook reads the written template"
assert_contains "$POUT" "origin own;" "origin from the write record"
t_end

t_begin "REQ-CNT-002.4 the handoff skill's description is 300 characters or fewer and its body 8 KB or fewer"
"$HPY" - "$SKILL" <<'PYEOF' || t_fail "skill size check"
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
m = re.match(r"---\n(.*?)\n---\n(.*)", t, re.S)
assert m, "no frontmatter"
fm, body = m.group(1), m.group(2)
d = re.search(r"^description:\s*(.*)$", fm, re.M).group(1).strip()
print("description %d characters, body %d bytes" % (len(d), len(body.encode("utf-8"))))
assert len(d) <= 300, "description too long"
assert len(body.encode("utf-8")) <= 8192, "body too long"
assert re.search(r"^name:\s*handoff\s*$", fm, re.M), "name"
PYEOF
t_end

t_begin "REQ-NFR-003.3 the handoff skill's description is 300 characters or fewer"
desc_len="$(sed -n 's/^description: //p' "$SKILL" | head -1 | tr -d '\n' | wc -c | tr -d ' ')"
[ "$desc_len" -le 300 ] || t_fail "description is $desc_len characters"
[ "$desc_len" -gt 40 ] || t_fail "description is suspiciously short"
t_end

t_begin "REQ-CNT-002.5 the skill and template name no maintainer-only tool, path or address"
# The private tool names come from the list file a release run names in CONDUCTOR_LEAK_BASE;
# without one only a /Users/ path and an email address are checked.
assert_eq "" "$(private_hits "$SKILL" "$TEMPLATE" "$REPO/payload/claude/conductor/ledger/LEDGER-TEMPLATE.md")" "private tokens (file:line)"
t_end

t_begin "REQ-CNT-002.7 the skill warns that checkpoints are plain text that may be committed, suggests an ignore line and writes no ignore file"
skill_text="$(cat "$SKILL")"
assert_contains "$skill_text" "plain text in the project and may be committed" "plain text warning"
assert_contains "$skill_text" "keep secrets out" "secrets out"
assert_contains "$skill_text" "ignore line" "ignore line"
assert_contains "$skill_text" "Do not write or edit any ignore file" "no ignore file"
mkproj t7
cp_run write --session sess-t7 --project "$PROJ" < <(draft sess-t7)
assert_eq 0 "$CPRC" "write"
assert_no_file "$PROJ/.gitignore" "no .gitignore written"
assert_eq "handoffs" "$(ls -A "$PROJ")" "only handoffs/ was created"
t_end

t_begin "REQ-CNT-002.3 an objective that ends: the skill closes with Status: DONE"
assert_contains "$skill_text" "close --session" "close command named"
assert_contains "$skill_text" "Status: DONE" "DONE named in the skill"
mkproj t3
cp_run write --session sess-t3 --project "$PROJ" < <(draft sess-t3)
assert_contains "$(head -1 "$PROJ/handoffs/CURRENT.md")" "Status: ACTIVE" "starts active"
cp_run close --session sess-t3 --project "$PROJ"
assert_eq 0 "$CPRC" "close: $CPOUT"
assert_eq "Status: DONE" "$(head -1 "$PROJ/handoffs/CURRENT.md")" "header reads DONE"
pointer "$PROJ" sess-t3
assert_eq "" "$POUT" "a DONE checkpoint is not shown"
assert_eq "$(sum_of "$PROJ/handoffs/CURRENT.md")" "$(record_field "$PROJ/handoffs/CURRENT.md" sha256)" "record follows the close"
cp_run close --session sess-nobody --project "$PROJ"
assert_eq 5 "$CPRC" "close for a session with no checkpoint"
t_end

# ============================================================================
# The helper: names, record, refusals, secrets
# ============================================================================
t_begin "REQ-CNT-002.2 a folder whose CURRENT.md names another session gets a session-qualified file and the first is not overwritten"
mkproj t2
cp_run write --session sess-first --project "$PROJ" < <(draft sess-first)
assert_contains "$CPOUT" "wrote handoffs/CURRENT.md" "first session"
before="$(sum_of "$PROJ/handoffs/CURRENT.md")"
cp_run write --session sess-second --project "$PROJ" < <(draft sess-second)
assert_eq 0 "$CPRC" "second session: $CPOUT"
assert_contains "$CPOUT" "wrote handoffs/CURRENT-sess-second.md" "qualified name"
assert_eq "$before" "$(sum_of "$PROJ/handoffs/CURRENT.md")" "CURRENT.md untouched"
assert_contains "$(sed -n 2p "$PROJ/handoffs/CURRENT-sess-second.md")" "sess-second" "session header"
cp_run write --session sess-second --project "$PROJ" < <(draft sess-second)
assert_contains "$CPOUT" "wrote handoffs/CURRENT-sess-second.md" "same session writes the same file"
assert_eq 2 "$(ls "$PROJ/handoffs" | wc -l | tr -d ' ')" "2 files"
cp_run write --session sess-first --project "$PROJ" < <(draft sess-first)
assert_contains "$CPOUT" "wrote handoffs/CURRENT.md" "first session keeps its file"
# a qualified name taken by another session
printf 'Status: ACTIVE\nSession: sess-intruder\nPinned commit: none\nUpdated: 2026-01-01T00:00:00Z\n' > "$PROJ/handoffs/CURRENT-sess-third.md"
cp_run write --session sess-third --project "$PROJ" < <(draft sess-third)
assert_eq 5 "$CPRC" "qualified name owned by another session"
assert_contains "$(cat "$PROJ/handoffs/CURRENT-sess-third.md")" "sess-intruder" "intruder file untouched"
t_end

t_begin "REQ-CNT-002.8 a checkpoint the skill just wrote has its path and sha256 in the Conductor folder"
mkproj t8
cp_run write --session sess-t8 --project "$PROJ" < <(draft sess-t8)
rec="$CFG/conductor/state/checkpoint-record.json"
assert_file "$rec" "write record"
assert_mode "$rec" 600 "record mode"
assert_contains "$(cat "$rec")" "$PROJ/handoffs/CURRENT.md" "path in the record"
assert_eq "$(sum_of "$PROJ/handoffs/CURRENT.md")" "$(record_field "$PROJ/handoffs/CURRENT.md" sha256)" "sha256 matches the file"
assert_eq "own" "$(record_field "$PROJ/handoffs/CURRENT.md" lineage)" "lineage"
printf '\nedited by hand\n' >> "$PROJ/handoffs/CURRENT.md"
pointer "$PROJ" sess-t8
assert_contains "$POUT" "origin unverified;" "an edit outside the helper makes the file unverified"
t_end

t_begin "REQ-CNT-002.9 a link, a non-regular file or an outside path for handoffs/, the checkpoint: refused, said so, target unchanged"
mkproj t9a
mkdir -p "$SBX/outside9"
printf 'outside original\n' > "$SBX/outside9/CURRENT.md"
ln -s "$SBX/outside9" "$PROJ/handoffs"
sumbefore="$(sum_of "$SBX/outside9/CURRENT.md")"
cp_run write --session sess-t9 --project "$PROJ" < <(draft sess-t9)
assert_eq 2 "$CPRC" "write through a handoffs link"
assert_contains "$CPOUT" "symbolic link" "says so"
cp_run read CURRENT.md --project "$PROJ"; assert_eq 2 "$CPRC" "read through a handoffs link"
cp_run list --project "$PROJ"; assert_eq 2 "$CPRC" "list through a handoffs link"
cp_run close --session sess-t9 --project "$PROJ"; assert_eq 2 "$CPRC" "close through a handoffs link"
assert_eq "$sumbefore" "$(sum_of "$SBX/outside9/CURRENT.md")" "link target unchanged"
assert_eq "1" "$(ls "$SBX/outside9" | wc -l | tr -d ' ')" "nothing added to the link target"
mkproj t9b
mkdir -p "$PROJ/handoffs"
ln -s "$SBX/outside9/CURRENT.md" "$PROJ/handoffs/CURRENT.md"
cp_run write --session sess-t9 --project "$PROJ" < <(draft sess-t9)
assert_eq 2 "$CPRC" "write over a CURRENT.md link"
assert_contains "$CPOUT" "symbolic link" "says so"
cp_run read CURRENT.md --project "$PROJ"; assert_eq 2 "$CPRC" "read a CURRENT.md link"
assert_not_contains "$CPOUT" "outside original" "link target text must not be read"
assert_eq "$sumbefore" "$(sum_of "$SBX/outside9/CURRENT.md")" "CURRENT.md link target unchanged"
mkproj t9c
mkdir -p "$PROJ/handoffs/CURRENT.md"
cp_run write --session sess-t9 --project "$PROJ" < <(draft sess-t9)
assert_eq 2 "$CPRC" "write over a folder named CURRENT.md"
assert_contains "$CPOUT" "not a regular file" "says so"
mkproj t9d
printf 'plain file where the folder should be\n' > "$PROJ/handoffs"
cp_run write --session sess-t9 --project "$PROJ" < <(draft sess-t9)
assert_eq 2 "$CPRC" "handoffs is a file"
assert_eq "plain file where the folder should be" "$(cat "$PROJ/handoffs")" "unchanged"
mkproj t9e
mkdir -p "$PROJ/handoffs"
mkfifo "$PROJ/handoffs/CURRENT.md" 2>/dev/null
if [ -p "$PROJ/handoffs/CURRENT.md" ]; then
  cp_run write --session sess-t9 --project "$PROJ" < <(draft sess-t9)
  assert_eq 2 "$CPRC" "write over a named pipe"
fi
mkproj t9f
mkdir -p "$PROJ/handoffs" "$SBX/outside9f"
cp_run write --session sess-t9 --project "$PROJ" < <(draft sess-t9)
assert_eq 0 "$CPRC" "an ordinary write still works"
cp_run read CURRENT-../../etc.md --project "$PROJ"
assert_eq 6 "$CPRC" "a name with a path in it is refused"
cp_run read ../x --project "$PROJ"
assert_eq 6 "$CPRC" "a path is refused"
t_end

t_begin "REQ-CNT-002.10 a session that resumed an unverified checkpoint writes an 'own, from unverified' record and the hook labels it so"
mkproj t10
cp_run write --session sess-t10 --from-unverified --project "$PROJ" < <(draft sess-t10)
assert_eq 0 "$CPRC" "$CPOUT"
assert_eq "from-unverified" "$(record_field "$PROJ/handoffs/CURRENT.md" lineage)" "record lineage"
pointer "$PROJ" sess-t10
assert_contains "$POUT" "origin own from unverified;" "hook label"
cp_run write --session sess-t10 --project "$PROJ" < <(draft sess-t10)
pointer "$PROJ" sess-t10
assert_contains "$POUT" "origin own from unverified;" "the lineage stays marked on later writes"
t_end

t_begin "REQ-CNT-002.11 a checkpoint draft that holds a secret-shaped string: the helper warns before writing"
mkproj t11
# the strings are built here so that no secret-shaped text is committed
aws="AK""IA0123456789ABCDEF"
gh="gh""p_0123456789abcdefghijklmnopqrstuvwxyz"
sk="sk""-ant-0123456789abcdefghij0123"
pk="-----BEGIN RSA PRIVATE ""KEY-----"
cred="api_key = ""abcdef0123456789abcdef"
for secret in "$aws" "$gh" "$sk" "$pk" "$cred"; do
  rm -rf "${PROJ:?}/handoffs"
  { draft sess-t11; printf 'Note: the value is %s end\n' "$secret"; } > "$SBX/secret-draft.md"
  cp_run write --session sess-t11 --project "$PROJ" < "$SBX/secret-draft.md"
  assert_eq 4 "$CPRC" "warns: $CPOUT"
  assert_contains "$CPOUT" "looks like" "the warning"
  assert_contains "$CPOUT" "Nothing was written" "nothing written"
  assert_not_contains "$CPOUT" "$secret" "the warning must not repeat the value"
  assert_no_file "$PROJ/handoffs/CURRENT.md" "no file written"
done
cp_run write --session sess-t11 --allow-secret-shaped --project "$PROJ" < "$SBX/secret-draft.md"
assert_eq 0 "$CPRC" "after the user confirms"
assert_file "$PROJ/handoffs/CURRENT.md" "written after confirmation"
t_end

t_begin "REQ-CNT-002.2 a draft with missing or wrong headers is refused and writes nothing"
mkproj t2b
cp_run write --session sess-t2b --project "$PROJ" < <(printf 'No headers here\n')
assert_eq 3 "$CPRC" "no headers"
cp_run write --session sess-t2b --project "$PROJ" < <(draft sess-other)
assert_eq 3 "$CPRC" "session header does not match the session id given"
cp_run write --session sess-t2b --project "$PROJ" < <(draft sess-t2b "not-a-commit")
assert_eq 3 "$CPRC" "bad pinned commit"
cp_run write --session 'bad id/../' --project "$PROJ" < <(draft sess-t2b)
assert_eq 6 "$CPRC" "bad session id"
assert_no_file "$PROJ/handoffs/CURRENT.md" "nothing written"
cp_run write --session sess-t2b --project "$PROJ" < <(draft sess-t2b 0123456789abcdef0123456789abcdef01234567)
assert_eq 0 "$CPRC" "a 40-character commit id is accepted"
t_end

# ============================================================================
# Ledger
# ============================================================================
t_begin "REQ-CNT-003.1 the ledger template holds the rules header and 0 rows"
tpl="$CFG/conductor/ledger/LEDGER-TEMPLATE.md"
text="$(cat "$tpl")"
for w in ASK DO-NEXT WONTFIX BLOCKED "Append only" "open"; do assert_contains "$text" "$w" "rules header: $w"; done
assert_contains "$text" "evidence" "closing needs evidence"
assert_eq 0 "$(grep -c '^| D-' "$tpl" | tr -d ' ')" "rows"
assert_contains "$text" "| Id | Date | Disposition | Status | Finding | Evidence |" "table header"
mkproj l1
out="$("$LEDGER_APPEND" --project "$PROJ" --disposition ASK --text "first finding" 2>&1)"
assert_contains "$out" "added D-001" "first row"
assert_eq 1 "$(grep -c '^| D-' "$PROJ/DEFERRED-FINDINGS.md" | tr -d ' ')" "1 row after the first append"
assert_contains "$(cat "$PROJ/DEFERRED-FINDINGS.md")" "Rules:" "ledger starts from the template"
t_end

t_begin "REQ-CNT-003.2 a row with no disposition: a failing status and nothing added"
mkproj l2
out="$("$LEDGER_APPEND" --project "$PROJ" --text "no disposition" 2>&1)"; rc=$?
assert_eq 2 "$rc" "exit code"
assert_contains "$out" "disposition is required" "says why"
assert_no_file "$PROJ/DEFERRED-FINDINGS.md" "no ledger created"
"$LEDGER_APPEND" --project "$PROJ" --disposition ASK --text "ok" > /dev/null 2>&1
before="$(sum_of "$PROJ/DEFERRED-FINDINGS.md")"
for bad in "" "ask" "MAYBE" "ASK|DO-NEXT"; do
  out="$("$LEDGER_APPEND" --project "$PROJ" --disposition "$bad" --text "x" 2>&1)"; rc=$?
  assert_eq 2 "$rc" "disposition [$bad]"
done
out="$("$LEDGER_APPEND" --project "$PROJ" --disposition ASK 2>&1)"; rc=$?
assert_eq 5 "$rc" "no text"
assert_eq "$before" "$(sum_of "$PROJ/DEFERRED-FINDINGS.md")" "ledger unchanged"
t_end

t_begin "REQ-CNT-003.3 2 append processes started together: the ledger holds 2 rows and none is lost"
mkproj l3
"$HPY" - "$LEDGER_APPEND" "$PROJ" <<'PYEOF' || t_fail "concurrent appends"
import subprocess, sys
bin_, proj = sys.argv[1:3]
for n in (2, 12):
    procs = [subprocess.Popen([bin_, "--project", proj, "--disposition", "DO-NEXT", "--text", "row from writer %d of %d" % (i, n)],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE) for i in range(n)]
    for p in procs:
        out, err = p.communicate(timeout=60)
        assert p.returncode == 0, (p.returncode, err)
PYEOF
ledger="$PROJ/DEFERRED-FINDINGS.md"
assert_eq 14 "$(grep -c '^| D-' "$ledger" | tr -d ' ')" "rows after 2 + 12 concurrent appends"
assert_eq 14 "$(grep '^| D-' "$ledger" | cut -d'|' -f2 | sort -u | wc -l | tr -d ' ')" "unique ids"
for i in 0 1; do assert_contains "$(cat "$ledger")" "row from writer $i of 2" "writer $i"; done
[ ! -e "$ledger.lock" ] || t_fail "the lock folder was left behind"
t_end

t_begin "REQ-CNT-003.4 a ledger that is a symbolic link to a file outside the project: refused, said so, target unchanged"
mkproj l4
printf 'outside file\n' > "$SBX/outside4.md"
ln -s "$SBX/outside4.md" "$PROJ/DEFERRED-FINDINGS.md"
out="$("$LEDGER_APPEND" --project "$PROJ" --disposition ASK --text "x" 2>&1)"; rc=$?
assert_eq 3 "$rc" "exit code"
assert_contains "$out" "symbolic link" "says so"
assert_eq "outside file" "$(cat "$SBX/outside4.md")" "target unchanged"
out="$("$LEDGER_APPEND" --project "$PROJ" --ledger "$SBX/elsewhere.md" --disposition ASK --text "x" 2>&1)"; rc=$?
assert_eq 3 "$rc" "a ledger path outside the project"
assert_no_file "$SBX/elsewhere.md" "nothing created outside"
mkproj l4b
mkdir "$PROJ/DEFERRED-FINDINGS.md"
out="$("$LEDGER_APPEND" --project "$PROJ" --disposition ASK --text "x" 2>&1)"; rc=$?
assert_eq 3 "$rc" "a ledger that is a folder"
assert_contains "$out" "not a regular file" "says so"
mkproj l4c
mkdir -p "$SBX/outside4c"
ln -s "$SBX/outside4c" "$PROJ/sub"
out="$("$LEDGER_APPEND" --project "$PROJ" --ledger sub/TEAM-LEDGER.md --disposition ASK --text "x" 2>&1)"; rc=$?
assert_eq 3 "$rc" "a ledger reached through a linked folder that leaves the project"
assert_eq 0 "$(ls "$SBX/outside4c" | wc -l | tr -d ' ')" "nothing created through the linked folder"
t_end

t_begin "REQ-CNT-003.2 a row is a single line, closes need evidence, and the lock is taken and released"
mkproj l5
"$LEDGER_APPEND" --project "$PROJ" --disposition BLOCKED --text "$(printf 'first part\nsecond part | with a pipe')" > /dev/null 2>&1
assert_eq 1 "$(grep -c '^| D-' "$PROJ/DEFERRED-FINDINGS.md" | tr -d ' ')" "multi-line text stays 1 row"
assert_not_contains "$(grep '^| D-' "$PROJ/DEFERRED-FINDINGS.md")" "first part
" "no newline in a row"
out="$("$LEDGER_APPEND" --project "$PROJ" --close D-001 2>&1)"; rc=$?
assert_eq 5 "$rc" "a close with no evidence"
out="$("$LEDGER_APPEND" --project "$PROJ" --close D-009 --evidence "proof" 2>&1)"; rc=$?
assert_eq 5 "$rc" "a close of a row that is not there"
out="$("$LEDGER_APPEND" --project "$PROJ" --close D-001 --evidence "commit 0123abc" 2>&1)"
assert_contains "$out" "added D-002" "close row"
assert_contains "$(tail -n 1 "$PROJ/DEFERRED-FINDINGS.md")" "closes D-001" "close row text"
assert_contains "$(tail -n 1 "$PROJ/DEFERRED-FINDINGS.md")" "BLOCKED" "close row keeps the disposition"
mkdir "$PROJ/DEFERRED-FINDINGS.md.lock"
deadpid="$(sh -c 'echo $$')"
printf '%s\n' "$deadpid" > "$PROJ/DEFERRED-FINDINGS.md.lock/pid"
out="$("$LEDGER_APPEND" --project "$PROJ" --disposition ASK --text "after a dead writer's lock" 2>&1)"
assert_contains "$out" "added D-003" "a stale lock from a dead process is cleared"
t_end

t_summary
