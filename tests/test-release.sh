#!/bin/bash
# tests/test-release.sh: the release check (tools/release-check.py).
# Criteria: REQ-OPS-001.1 to .5, REQ-EXP-002.1 to .5 (with the leak scan of REQ-EXP-001),
# REQ-DOC-004.1 and .4, REQ-NFR-003.
# The fixture repositories are synthetic and clean; each case breaks 1 thing and checks
# that exactly the right line fails.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/tests/lib/assert.sh"
. "$REPO/tests/lib/sandbox.sh"
sandbox_new
trap sandbox_cleanup EXIT
sandbox_guard
export PYTHONDONTWRITEBYTECODE=1
RC_TOOL="$REPO/tools/release-check.py"
BASE="$SBX/fxbase"
FX="$SBX/fx"
PRIV="$SBX/priv"
LEAK="$SBX/leak-base.txt"
BUILD_DATE=2026-10-12
CHECKS="build-sync versions banned-strings cost-words v2-strings leak-scan verbatim-sources verbatim export-overlap private-files notices model-notes-date codex-map-date size-doctrine size-descriptions size-handoff record-fields changelog-entry"

printf '# base leaks\n\\bprivate-client\\b\n' > "$LEAK"

make_base() {
  rm -rf "$BASE"
  mkdir -p "$BASE" "$PRIV/skills"
  cp -R "$REPO/tools" "$REPO/installer" "$REPO/payload" "$BASE/"
  find "$BASE" -name '__pycache__' -prune -exec rm -rf {} +
  mkdir -p "$BASE/release" "$BASE/site"
  "$SBX_PY" -B - "$BASE" << 'PYEOF'
import re, sys
base = sys.argv[1]
for rel in ("payload/claude/skills/conductor/SKILL.md", "payload/codex/skills/conductor/SKILL.md"):
    p = base + "/" + rel
    t = open(p).read()
    t = re.sub(r"(?m)^description: .*$", "description: Run the orchestration loop on a multi-step objective.", t, count=1)
    open(p, "w").write(t)
open(base + "/payload/claude/skills/handoff/SKILL.md", "w").write("---\nname: handoff\ndescription: Write a checkpoint another session can resume from.\n---\n\nFixture handoff body.\n")
open(base + "/payload/claude/conductor/model-notes.md", "w").write("# Model notes\n\nVerified on 2026-10-01. Re-verify when a model ships or after 90 days.\n")
PYEOF
  sed 's/^Map ids re-checked on: [0-9-]*/Map ids re-checked on: 2026-10-10/' "$REPO/release/RECORD-0.4.0.md" > "$BASE/release/RECORD-0.4.0.md"
  cat > "$BASE/README.md" << 'DOC_EOF'
# Conductor

Conductor turns a session into a conductor that hands work to named workers.
Opus 5.5 and Sonnet 5.5 start at medium effort. A top-level effortLevel in user
settings does not reach Opus 5.5. Higher effort can use more of the plan's usage.
DOC_EOF
  cat > "$BASE/CHANGELOG.md" << 'DOC_EOF'
# Changelog

## 0.4.0 (2026-10-12)

Upgrade notes: run the installer again; your changed files are kept.
Effort: a top-level effortLevel does not reach Opus 5.5 or Sonnet 5.5.
Installer sha256: <filled at release>

## 0.3.0 (2026-07-04)

- Earlier work.
DOC_EOF
  cat > "$BASE/THIRD-PARTY-NOTICES.md" << 'DOC_EOF'
# Third-Party Notices

## Ponytail

An idea reimplemented in our own words. https://example.invalid/a1

## Honey

An idea reimplemented in our own words. https://example.invalid/a2

## review-ladder.workflow.js

Upstream: https://example.invalid/upstream/workflow
Pinned commit: 0123456789abcdef0123456789abcdef01234567
License: MIT
Local changes: renamed 2 variables.
DOC_EOF
  printf '<html><body><h1>Conductor</h1><p>A kit for conducting sessions.</p></body></html>\n' > "$BASE/site/index.html"
  printf 'skills/secret.md\n' > "$PRIV/verbatim-sources.txt"
  printf 'the quick brown fox jumps over the lazy dog while 7 grey wolves howl under a pale cold winter moon tonight\n' > "$PRIV/skills/secret.md"
  printf 'Ponytail\nHoney\n' > "$SBX/derived.txt"
  printf 'skills/other-private.md\n' > "$SBX/private-files.txt"
  printf 'product x\ndest /tmp/x\ncopy other/file.md -> payload/x.md\n' > "$SBX/export.manifest"
  (cd "$BASE" && "$SBX_PY" -B tools/build.py > /dev/null 2>&1) || { echo "the fixture build failed" >&2; exit 98; }
}

reset() { rm -rf "$FX"; cp -R "$BASE" "$FX"; }
rebuild() { (cd "$FX" && "$SBX_PY" -B tools/build.py > /dev/null 2>&1); }

run_rc() { # extra args
  OUT="$("$SBX_PY" -B "$RC_TOOL" --repo "$FX" --leak-base "$LEAK" --verbatim-sources "$PRIV/verbatim-sources.txt" --verbatim-root "$PRIV" \
    --export-manifest "$SBX/export.manifest" --private-files "$SBX/private-files.txt" --derived-works "$SBX/derived.txt" --build-date "$BUILD_DATE" "$@" 2>&1)"
  RC=$?
}
line() { printf '%s\n' "$OUT" | grep -E "^(PASS|FAIL|SKIP) $1:" | head -n 1; }
expect_only_fail() { # CHECK: that check failed, and no other did
  local c="$1" fails
  assert_eq 1 "$RC" "exit status"
  assert_contains "$(line "$c")" "FAIL $c:" "the $c line"
  fails="$(printf '%s\n' "$OUT" | grep -c '^FAIL ' || true)"
  if [ "$fails" != 1 ]; then t_fail "expected only $c to fail, got: $(printf '%s\n' "$OUT" | grep '^FAIL ' | tr '\n' '|')"; fi
}
sha_of() { (sha256sum "$1" 2> /dev/null || shasum -a 256 "$1") | awk '{print $1}'; }

make_base

# ---------------------------------------------------------------------------------
t_begin "a clean fixture repository passes every check: 1 line per check, exit 0, no skip"
reset
run_rc
assert_eq 0 "$RC" "exit status"
for c in $CHECKS; do
  assert_contains "$(line "$c")" "PASS $c" "the $c line"
done
n="$(printf '%s\n' "$OUT" | grep -cE '^(PASS|FAIL|SKIP) ' || true)"
assert_eq 18 "$n" "check lines"
assert_not_contains "$OUT" "SKIP "
assert_contains "$OUT" "release-check: 18 passed, 0 failed, 0 skipped"
assert_contains "$(line size-doctrine)" "estimate, characters divided by 3.2, rounded up"
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-OPS-001.2 a version that differs between components.json, the VERSION files, the marker and the changelog heading blocks the release"
reset
printf '0.4.1\n' > "$FX/payload/claude/skills/conductor/VERSION"
run_rc
assert_eq 1 "$RC"
assert_contains "$(line versions)" "FAIL versions: expected 0.4.0; payload/claude/skills/conductor/VERSION=0.4.1"
reset
sed -i.bak 's/^## 0.4.0/## 0.4.1/' "$FX/CHANGELOG.md" && rm -f "$FX/CHANGELOG.md.bak"
run_rc
assert_contains "$(line versions)" "CHANGELOG.md top heading=0.4.1"
reset
printf '0.4.2\n' > "$FX/payload/codex/skills/conductor/VERSION"
run_rc
assert_contains "$(line versions)" "payload/codex/skills/conductor/VERSION=0.4.2"
reset
sed -i.bak 's/^BEGIN_MARKER=.*/BEGIN_MARKER="<!-- BEGIN CONDUCTOR (managed) v0.3.0 - ${CONDUCTOR_URL} -->"/' "$FX/install.sh" && rm -f "$FX/install.sh.bak"
run_rc
assert_contains "$(line versions)" "install.sh BEGIN_MARKER=0.3.0"
reset
sed -i.bak 's/^CONDUCTOR_VERSION=.*/CONDUCTOR_VERSION="0.4.9"/' "$FX/install.sh" && rm -f "$FX/install.sh.bak"
run_rc
assert_contains "$(line versions)" "install.sh CONDUCTOR_VERSION=0.4.9"
assert_contains "$(line build-sync)" "FAIL build-sync" "build drift is caught too"
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-OPS-001.4 model-notes verified more than 90 days before the build date fails and names the file; 90 days passes"
reset
printf '# Model notes\n\nVerified on 2026-07-14. Re-verify when a model ships or after 90 days.\n' > "$FX/payload/claude/conductor/model-notes.md"
rebuild
run_rc
assert_eq 0 "$RC" "90 days old passes"
assert_contains "$(line model-notes-date)" "verified 90 days before the build date"
printf '# Model notes\n\nVerified on 2026-07-13. Re-verify when a model ships or after 90 days.\n' > "$FX/payload/claude/conductor/model-notes.md"
rebuild
run_rc
expect_only_fail model-notes-date
assert_contains "$(line model-notes-date)" "payload/claude/conductor/model-notes.md was verified 91 days before the build date (limit 90)"
printf '# Model notes\n\nNo date here.\n' > "$FX/payload/claude/conductor/model-notes.md"
rebuild
run_rc
assert_contains "$(line model-notes-date)" "has no 'verified on' date"
t_end

t_begin "REQ-OPS-001.4 a Codex model map checked more than 14 days before the build date fails and names the record; 14 days passes"
reset
sed -i.bak 's/^Map ids re-checked on: [0-9-]*/Map ids re-checked on: 2026-09-28/' "$FX/release/RECORD-0.4.0.md" && rm -f "$FX/release/RECORD-0.4.0.md.bak"
run_rc
assert_eq 0 "$RC" "14 days old passes"
sed -i.bak 's/^Map ids re-checked on: [0-9-]*/Map ids re-checked on: 2026-09-27/' "$FX/release/RECORD-0.4.0.md" && rm -f "$FX/release/RECORD-0.4.0.md.bak"
run_rc
expect_only_fail codex-map-date
assert_contains "$(line codex-map-date)" "release/RECORD-0.4.0.md: the Codex model map was checked 15 days before the build date (limit 14)"
sed -i.bak 's/^Map ids re-checked on: [0-9-]*/Map ids re-checked on: <filled at release>/' "$FX/release/RECORD-0.4.0.md" && rm -f "$FX/release/RECORD-0.4.0.md.bak"
run_rc
assert_contains "$(line codex-map-date)" "has no check date"
t_end

t_begin "REQ-OPS-001.5 Conductor v2, Conductor 2 and v2 release in the README, changelog, installer text or site text are hits; v2.1.293 is not"
for where in README.md CHANGELOG.md site/index.html; do
  for phrase in "Conductor v2" "conductor 2" "the v2 release"; do
    reset
    printf '\nwe ship %s soon\n' "$phrase" >> "$FX/$where"
    rebuild
    run_rc
    expect_only_fail v2-strings
    assert_contains "$(line v2-strings)" "$where:"
  done
done
reset
sed -i.bak 's/act as a conductor/Conductor v2 plays/' "$FX/installer/src/00-header.sh" && rm -f "$FX/installer/src/00-header.sh.bak"
rebuild
run_rc
assert_contains "$(line v2-strings)" "install.sh:"
reset
printf '\nTested with Claude Code v2.1.293 and Conductor 0.4.0.\n' >> "$FX/README.md"
printf '\nCompatible with v2.1.293.\n' >> "$FX/CHANGELOG.md"
run_rc
assert_contains "$(line v2-strings)" "PASS v2-strings"
t_end

t_begin "REQ-DOC-004.1 60-80, 3-5x, Copilot, Gemini and Antigravity in the README, site or installer text are hits"
for word in "60-80" "3-5x" "Copilot" "Gemini" "Antigravity"; do
  reset
  printf '\nOur claim: %s here\n' "$word" >> "$FX/README.md"
  run_rc
  expect_only_fail banned-strings
  assert_contains "$(line banned-strings)" "README.md:"
  assert_contains "$(line banned-strings)" "$word"
done
reset
printf '<p>works with Gemini</p>\n' >> "$FX/site/index.html"
run_rc
assert_contains "$(line banned-strings)" "site/index.html:"
reset
sed -i.bak 's/act as a conductor/Antigravity plays/' "$FX/installer/src/00-header.sh" && rm -f "$FX/installer/src/00-header.sh.bak"
rebuild
run_rc
assert_contains "$(line banned-strings)" "install.sh:"
t_end

t_begin "REQ-DOC-004.4 cost words in the README's first 20 lines or the installer's opening text are hits; later lines and ordinary wording are not"
for word in cheaper cheap "cost less" savings "save money" "save tokens"; do
  reset
  { printf '# Conductor\n\nA kit that will %s for you.\n' "$word"; sed 1,2d "$FX/README.md"; } > "$FX/README.new" && mv "$FX/README.new" "$FX/README.md"
  run_rc
  expect_only_fail cost-words
  assert_contains "$(line cost-words)" "README.md first 20 lines:"
done
reset
{ cat "$FX/README.md"; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22; do printf 'filler line %d\n' "$i"; done; printf 'later we mention cheaper options\n'; } > "$FX/README.new" && mv "$FX/README.new" "$FX/README.md"
run_rc
assert_contains "$(line cost-words)" "PASS cost-words" "a later line is outside the opening"
reset
sed -i.bak 's/act as a conductor/act as a cheaper conductor/' "$FX/installer/src/00-header.sh" && rm -f "$FX/installer/src/00-header.sh.bak"
rebuild
run_rc
expect_only_fail cost-words
assert_contains "$(line cost-words)" "install.sh opening text:"
reset
sed -i.bak 's/act as a conductor/backup saved, nothing to save/' "$FX/installer/src/00-header.sh" && rm -f "$FX/installer/src/00-header.sh.bak"
rebuild
run_rc
assert_contains "$(line cost-words)" "PASS cost-words" "ordinary installer wording is not a claim"
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-EXP-001.1 REQ-EXP-002 the leak scan: a private token or a secret shape in a payload file or install.sh fails, naming the file and line, never printing the secret"
reset
printf 'line 1\nthe private-client list\n' > "$FX/payload/claude/conductor/model-notes.md"
printf 'Verified on 2026-10-01. Re-verify when a model ships or after 90 days.\n' >> "$FX/payload/claude/conductor/model-notes.md"
rebuild
run_rc
expect_only_fail leak-scan
assert_contains "$(line leak-scan)" "payload/claude/conductor/model-notes.md:2 pattern"
assert_contains "$(line leak-scan)" "install.sh:"
secret="$(printf '%s%s' 'ghp_' 'abcdefghijklmnop0123456789')"
reset
printf 'Verified on 2026-10-01. Re-verify when a model ships or after 90 days.\ntoken %s\n' "$secret" > "$FX/payload/claude/conductor/model-notes.md"
rebuild
run_rc
expect_only_fail leak-scan
assert_contains "$(line leak-scan)" "secret shape: a ghp_ token"
assert_not_contains "$OUT" "abcdefghijklmnop" "the secret is not printed"
reset
extra="$SBX/extra-installer.sh"
printf '#!/usr/bin/env bash\necho private-client\n' > "$extra"
run_rc --installer "$extra"
expect_only_fail leak-scan
assert_contains "$(line leak-scan)" "extra-installer.sh:2"
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-EXP-001.1 --allow FILE: a leak hit is dropped only when the matched text sits inside an allowed string on that line"
ALLOW="$SBX/allow.txt"
printf '# the public address, a comment line and a blank line follow\n\ngithub.com/private-client/conductor\n' > "$ALLOW"
note() { printf 'Verified on 2026-10-01. Re-verify when a model ships or after 90 days.\n%s\n' "$1" > "$FX/payload/claude/conductor/model-notes.md"; rebuild; }
reset
note 'source: github.com/private-client/conductor'
run_rc
expect_only_fail leak-scan
run_rc --allow "$ALLOW"
assert_eq 0 "$RC" "the hit inside the allowed string passes"
assert_contains "$(line leak-scan)" "PASS leak-scan"
assert_contains "$(line leak-scan)" "allowed by --allow"
assert_not_contains "$OUT" "github.com/private-client/conductor" "the allowed string is not printed"
note 'source: github.com/private-client/conductor and the private-client list'
run_rc --allow "$ALLOW"
expect_only_fail leak-scan
assert_contains "$(line leak-scan)" "payload/claude/conductor/model-notes.md:2 pattern"
note 'the private-client list'
run_rc --allow "$ALLOW"
expect_only_fail leak-scan
printf 'client/conductor\n' > "$SBX/allow-part.txt"
note 'source: github.com/private-client/conductor'
run_rc --allow "$SBX/allow-part.txt"
expect_only_fail leak-scan
printf 'github.com/private-clients/other\n' > "$SBX/allow-other.txt"
run_rc --allow "$SBX/allow-other.txt"
expect_only_fail leak-scan
run_rc --allow "$SBX/no-such-allow.txt"
assert_eq 2 "$RC" "an unreadable allow file is a usage error"
assert_contains "$OUT" "--allow file cannot be read"
reset
run_rc --allow "$ALLOW"
assert_eq 0 "$RC" "a clean tree passes with an allow file"
assert_contains "$(line leak-scan)" "PASS leak-scan: 0 hits"
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-EXP-002.1 a shipped file that repeats 8 consecutive words of a private source fails and names both files; 7 words pass"
reset
printf '\nNote: 7 grey wolves howl under a pale cold winter moon is a line.\n' >> "$FX/README.md"
run_rc
expect_only_fail verbatim
assert_contains "$(line verbatim)" "README.md shares 8 consecutive words with skills/secret.md"
reset
printf '\nNote: grey wolves howl under a pale cold moon is a line.\n' >> "$FX/README.md"
run_rc
assert_eq 0 "$RC" "7 shared words pass"
reset
printf 'the quick brown fox jumps over the lazy dog\nand more\n' > "$FX/payload/claude/conductor/runbooks/review-ladder.md"
run_rc
assert_contains "$(line verbatim)" "payload/claude/conductor/runbooks/review-ladder.md shares 8 consecutive words with skills/secret.md"
t_end

t_begin "REQ-EXP-002.2 a payload file that is on the private and partner file list fails; a clean list passes"
reset
printf 'skills/conductor/SKILL.md\n' > "$SBX/private-files.txt"
run_rc
expect_only_fail private-files
assert_contains "$(line private-files)" "claude/skills/conductor/SKILL.md"
assert_contains "$(line private-files)" "codex/skills/conductor/SKILL.md"
printf '%s\n' "$(sha_of "$FX/payload/claude/doctrine.md")" > "$SBX/private-files.txt"
run_rc
expect_only_fail private-files
assert_contains "$(line private-files)" "claude/doctrine.md"
printf 'skills/other-private.md\n' > "$SBX/private-files.txt"
run_rc
assert_contains "$(line private-files)" "PASS private-files: 0 of 1 listed files are in the payload"
t_end

t_begin "REQ-EXP-002.3 the third-party notices name each derived work and the vendored template's upstream, pinned commit, license and local changes"
reset
sed -i.bak '/Honey/d' "$FX/THIRD-PARTY-NOTICES.md" && rm -f "$FX/THIRD-PARTY-NOTICES.md.bak"
run_rc
expect_only_fail notices
assert_contains "$(line notices)" "does not name Honey"
reset
sed -i.bak '/Pinned commit/d' "$FX/THIRD-PARTY-NOTICES.md" && rm -f "$FX/THIRD-PARTY-NOTICES.md.bak"
run_rc
assert_contains "$(line notices)" "lacks a pinned commit (40 hex digits)"
reset
sed -i.bak '/Local changes/d' "$FX/THIRD-PARTY-NOTICES.md" && rm -f "$FX/THIRD-PARTY-NOTICES.md.bak"
run_rc
assert_contains "$(line notices)" "lacks local changes"
reset
sed -i.bak '/License/d' "$FX/THIRD-PARTY-NOTICES.md" && rm -f "$FX/THIRD-PARTY-NOTICES.md.bak"
run_rc
assert_contains "$(line notices)" "lacks a license"
reset
sed -i.bak '/review-ladder.workflow.js/d' "$FX/THIRD-PARTY-NOTICES.md" && rm -f "$FX/THIRD-PARTY-NOTICES.md.bak"
run_rc
assert_contains "$(line notices)" "the vendored template review-ladder.workflow.js has no section"
reset
"$SBX_PY" -B - "$FX/THIRD-PARTY-NOTICES.md" << 'PYEOF'
import re, sys
p = sys.argv[1]
t = open(p).read()
t = re.sub(r"(?s)## review-ladder\.workflow\.js.*", "## Original work\n\n`review-ladder.workflow.js` is original work written for Conductor. It is not\nvendored, so it has no upstream, no pinned commit and no license of its own.\n", t)
open(p, "w").write(t)
PYEOF
run_rc
assert_eq 0 "$RC" "a template stated as original work, with no upstream, is not read as a derived work"
assert_contains "$(line notices)" "PASS notices"
sed -i.bak 's/no upstream, //' "$FX/THIRD-PARTY-NOTICES.md" && rm -f "$FX/THIRD-PARTY-NOTICES.md.bak"
run_rc
assert_contains "$(line notices)" "lacks an upstream address"
t_end

t_begin "REQ-EXP-002.4 a missing, empty or unlisted verbatim source list fails and says the source list is missing"
reset
OUT="$("$SBX_PY" -B "$RC_TOOL" --repo "$FX" --leak-base "$LEAK" --verbatim-sources "$SBX/no-such-list.txt" --build-date "$BUILD_DATE" 2>&1)"
RC=$?
assert_eq 1 "$RC"
assert_contains "$(line verbatim-sources)" "FAIL verbatim-sources: the source list is missing or empty"
printf '# only a comment\n\n' > "$SBX/empty-list.txt"
OUT="$("$SBX_PY" -B "$RC_TOOL" --repo "$FX" --leak-base "$LEAK" --verbatim-sources "$SBX/empty-list.txt" --build-date "$BUILD_DATE" 2>&1)"
RC=$?
assert_eq 1 "$RC"
assert_contains "$(line verbatim-sources)" "the source list is missing or empty"
OUT="$("$SBX_PY" -B "$RC_TOOL" --repo "$FX" --leak-base "$LEAK" --build-date "$BUILD_DATE" 2>&1)"
RC=$?
assert_eq 1 "$RC"
assert_contains "$(line verbatim-sources)" "no --verbatim-sources given"
printf 'skills/not-there.md\n' > "$SBX/stale-list.txt"
OUT="$("$SBX_PY" -B "$RC_TOOL" --repo "$FX" --leak-base "$LEAK" --verbatim-sources "$SBX/stale-list.txt" --verbatim-root "$PRIV" --build-date "$BUILD_DATE" 2>&1)"
assert_contains "$(line verbatim-sources)" "listed source not found: skills/not-there.md"
t_end

t_begin "REQ-EXP-002.5 a path on the verbatim source list that is also a copy source of the export fails and names the path"
reset
printf 'product x\ndest /tmp/x\ncopy skills/secret.md -> payload/x.md\n' > "$SBX/export.manifest"
run_rc
expect_only_fail export-overlap
assert_contains "$(line export-overlap)" "a verbatim source is also a copy source: skills/secret.md"
printf 'product x\ndest /tmp/x\ncopy-tree skills -> payload/skills\n' > "$SBX/export.manifest"
run_rc
assert_contains "$(line export-overlap)" "skills/secret.md" "a copy-tree above the listed file"
printf 'product x\ndest /tmp/x\ncopy other/file.md -> payload/x.md\n' > "$SBX/export.manifest"
run_rc
assert_eq 0 "$RC" "no overlap passes"
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-NFR-003 the doctrine block over 2,500 tokens by the stated estimate fails; skill descriptions over 300 characters fail; the handoff skill body over 8 KB fails"
reset
"$SBX_PY" -B - "$FX" << 'PYEOF'
import sys
p = sys.argv[1] + "/payload/claude/doctrine.md"
t = open(p).read().rstrip("\n")
need = 8000 - len(t)
open(p, "w").write(t + "\n" + ("word " * (need // 5)).rstrip() + "\n")
PYEOF
run_rc
assert_contains "$(line size-doctrine)" "FAIL size-doctrine: payload/claude/doctrine.md is about 25"
reset
for n in 300 301; do
  "$SBX_PY" -B - "$FX" "$n" << 'PYEOF'
import re, sys
p = sys.argv[1] + "/payload/claude/skills/conductor/SKILL.md"
t = open(p).read()
t = re.sub(r"(?m)^description: .*$", "description: " + "d" * int(sys.argv[2]), t, count=1)
open(p, "w").write(t)
PYEOF
  run_rc
  if [ "$n" = 300 ]; then
    assert_contains "$(line size-descriptions)" "PASS size-descriptions" "300 characters passes"
  else
    assert_contains "$(line size-descriptions)" "payload/claude/skills/conductor/SKILL.md description is 301 characters (cap 300)"
  fi
done
reset
for n in 8192 8193; do
  "$SBX_PY" -B - "$FX" "$n" << 'PYEOF'
import sys
n = int(sys.argv[2])
open(sys.argv[1] + "/payload/claude/skills/handoff/SKILL.md", "w").write("---\nname: handoff\ndescription: Write a checkpoint.\n---\n" + "x" * (n - 1) + "\n")
PYEOF
  run_rc
  if [ "$n" = 8192 ]; then
    assert_contains "$(line size-handoff)" "PASS size-handoff: body is 8192 bytes"
  else
    assert_contains "$(line size-handoff)" "FAIL size-handoff: body is 8193 bytes (cap 8192)"
  fi
done
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-OPS-001.1 the release record must hold each listed field"
for heading in "Commit" "Installer sha256" "Version strings" "Codex model map" "Gates (R-25)" "Bench run ids" "Test runs" "Review tier" "Approver" "cso report" "Tokenizer" "Update fetch rules" "Tag v0.3.0" "Main protection read-out" "Registrar lock and auto-renew" "2-factor sign-in"; do
  reset
  "$SBX_PY" -B - "$FX/release/RECORD-0.4.0.md" "$heading" << 'PYEOF'
import sys
p, h = sys.argv[1:3]
lines = open(p).read().split("\n")
lines = ["## Renamed" if ln == "## " + h else ln for ln in lines]
open(p, "w").write("\n".join(lines))
PYEOF
  run_rc
  assert_eq 1 "$RC" "exit status without the $heading heading"
  assert_contains "$(line record-fields)" "FAIL record-fields:" "without $heading"
done
reset
sed -i.bak '/^### Gate 4/d' "$FX/release/RECORD-0.4.0.md" && rm -f "$FX/release/RECORD-0.4.0.md.bak"
run_rc
assert_contains "$(line record-fields)" "gate 4"
reset
sed -i.bak '/estimate, characters divided by 3.2/d' "$FX/release/RECORD-0.4.0.md" && rm -f "$FX/release/RECORD-0.4.0.md.bak"
run_rc
assert_contains "$(line record-fields)" "the tokenizer statement"
reset
sed -i.bak '/built in bash 3.2/d' "$FX/release/RECORD-0.4.0.md" && rm -f "$FX/release/RECORD-0.4.0.md.bak"
run_rc
assert_contains "$(line record-fields)" "the bash 3.2 statement"
reset
rm -f "$FX/release/RECORD-0.4.0.md"
run_rc
assert_contains "$(line record-fields)" "release/RECORD-0.4.0.md is missing"
reset
run_rc
assert_contains "$(line record-fields)" "PASS record-fields: every field is present ("
t_end

t_begin "REQ-OPS-001.3 the changelog entry holds upgrade notes, the effort explanation and the installer sha256 line"
reset
sed -i.bak '/^Upgrade notes/d' "$FX/CHANGELOG.md" && rm -f "$FX/CHANGELOG.md.bak"
run_rc
assert_contains "$(line changelog-entry)" "lacks: upgrade notes"
reset
sed -i.bak '/^Effort/d' "$FX/CHANGELOG.md" && rm -f "$FX/CHANGELOG.md.bak"
run_rc
assert_contains "$(line changelog-entry)" "the effort explanation"
reset
sed -i.bak '/^Installer sha256/d' "$FX/CHANGELOG.md" && rm -f "$FX/CHANGELOG.md.bak"
run_rc
assert_contains "$(line changelog-entry)" "an 'Installer sha256:' line"
t_end

t_begin "REQ-OPS-001.3 --final: placeholders in the record fail, the changelog sha256 must equal the sha256 of install.sh, and a skip counts as a failure"
reset
run_rc --final
assert_eq 1 "$RC" "placeholders left"
assert_contains "$(line record-fields)" "placeholder(s)"
assert_contains "$(line changelog-entry)" "an installer sha256 equal to the sha256 of install.sh"
# a release-ready fixture: every placeholder filled, the changelog names the real hash
sed -i.bak 's/<filled[^>]*>/done/g' "$FX/release/RECORD-0.4.0.md" && rm -f "$FX/release/RECORD-0.4.0.md.bak"
sed -i.bak 's/^Map ids re-checked on: [0-9-]*/Map ids re-checked on: 2026-10-10/' "$FX/release/RECORD-0.4.0.md" && rm -f "$FX/release/RECORD-0.4.0.md.bak"
sha="$(sha_of "$FX/install.sh")"
sed -i.bak "s/^Installer sha256: .*/Installer sha256: $sha/" "$FX/CHANGELOG.md" && rm -f "$FX/CHANGELOG.md.bak"
rebuild
assert_eq "$sha" "$(sha_of "$FX/install.sh")" "the installer does not change when its own hash is written into the changelog"
run_rc --final
assert_eq 0 "$RC" "release-ready fixture with --final"
assert_contains "$OUT" "release-check: 18 passed, 0 failed, 0 skipped"
OUT="$("$SBX_PY" -B "$RC_TOOL" --repo "$FX" --leak-base "$LEAK" --build-date "$BUILD_DATE" --final 2>&1)"
RC=$?
assert_eq 1 "$RC" "--final without the optional lists: skipped checks fail"
assert_contains "$(line private-files)" "FAIL private-files: not run"
t_end

# ---------------------------------------------------------------------------------
t_begin "--installer scans a second installer; bad arguments exit 2"
reset
extra="$SBX/second-installer.sh"
printf '#!/usr/bin/env bash\necho "works with Copilot"\n' > "$extra"
run_rc --installer "$extra"
assert_contains "$(line banned-strings)" "second-installer.sh:2 Copilot"
OUT="$("$SBX_PY" -B "$RC_TOOL" --repo "$FX" 2>&1)"
assert_eq 2 "$?" "no --leak-base"
OUT="$("$SBX_PY" -B "$RC_TOOL" --repo "$FX" --leak-base "$LEAK" --frob 2>&1)"
assert_eq 2 "$?" "unknown argument"
OUT="$("$SBX_PY" -B "$RC_TOOL" --repo "$FX" --leak-base "$LEAK" --build-date yesterday 2>&1)"
assert_eq 2 "$?" "bad build date"
t_end

t_summary
