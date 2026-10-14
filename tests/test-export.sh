#!/bin/bash
# tests/test-export.sh: the export tool (tools/export.py and tools/export.sh).
# The 24 export cases of the export-tool spec, plus REQ-EXP-001.1 to .6.
# Hermetic: a temp root, temp destination repositories, temp manifests and temp lists;
# git runs with the global and system config switched off; the tool runs from a temp
# folder with a temp HOME and never reads a real product repository.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/tests/lib/assert.sh"
. "$REPO/tests/lib/sandbox.sh"
sandbox_new
trap sandbox_cleanup EXIT
sandbox_guard
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
export PYTHONDONTWRITEBYTECODE=1
W="$SBX/world"
ROOT="$W/root"
DEST="$W/dest"
CWD="$W/cwd"
LEAK="$W/leak-base.txt"
TOOL="$REPO/tools/export.py"

ex() { (cd "$CWD" && "$SBX_PY" -B "$TOOL" "$@"); }
run_ex() { OUT="$(ex "$@" 2>&1)"; RC=$?; }
# the common arguments of a check or an apply
CA() { printf '%s\n' --root "$ROOT" --leak-base "$LEAK"; }
check() { run_ex demo --check --root "$ROOT" --leak-base "$LEAK" "$@"; }
apply() { run_ex demo --apply --root "$ROOT" --leak-base "$LEAK" "$@"; }
dest_sum() { sandbox_tree_sum "$DEST" | grep -v '^\./\.git'; }
commit_count() { git -C "$DEST" rev-list --count HEAD; }

BASE_MANIFEST='product   demo
dest      __DEST__
branch    export/sync
copy      agents/builder.md  ->  payload/agents/builder.md
copy      scripts/run.sh  ->  payload/bin/run.sh
copy-tree skills/tmpl  ->  payload/tmpl  exclude=*.bak
portable  products/demo/src/doctrine.md  ->  payload/doctrine.md  tracks=CLAUDE.md#Rules;notes.md'

write_manifest() { # extra lines...
  { printf '%s\n' "${BASE_MANIFEST//__DEST__/$DEST}"; for l in "$@"; do printf '%s\n' "$l"; done; } > "$ROOT/products/demo.manifest"
}

new_world() {
  rm -rf "$W"
  mkdir -p "$ROOT/products/demo/src" "$ROOT/agents" "$ROOT/scripts" "$ROOT/skills/tmpl/sub" "$ROOT/skills/tmpl/__pycache__" "$DEST" "$CWD"
  printf '# Builder\nhello team\n' > "$ROOT/agents/builder.md"
  printf '#!/bin/sh\necho run\n' > "$ROOT/scripts/run.sh"
  chmod 755 "$ROOT/scripts/run.sh"
  printf 'a\n' > "$ROOT/skills/tmpl/a.txt"
  printf 'b\n' > "$ROOT/skills/tmpl/sub/b.txt"
  printf 'junk\n' > "$ROOT/skills/tmpl/x.bak"
  printf 'pyc\n' > "$ROOT/skills/tmpl/__pycache__/c.pyc"
  printf '# Doctrine\ngeneral rules\n' > "$ROOT/products/demo/src/doctrine.md"
  printf '# Notes\n\n## Rules\nrule 1\n\n## Other\nother text\n' > "$ROOT/CLAUDE.md"
  printf 'notes v1\n' > "$ROOT/notes.md"
  printf '# base leaks\n\\bprivate-client\\b\n' > "$LEAK"
  write_manifest
  git -C "$DEST" init -q
  git -C "$DEST" symbolic-ref HEAD refs/heads/main
  printf 'readme\n' > "$DEST/README.md"
  git -C "$DEST" add README.md
  git -C "$DEST" commit -q -m init
  git init -q --bare "$W/remote.git"
  git -C "$DEST" remote add origin "$W/remote.git"
  git -C "$DEST" push -q origin main
}

# ---------------------------------------------------------------------------------
t_begin "export case 3: apply writes the files and a following check exits 0"
new_world
apply
assert_eq 0 "$RC" "apply status"
assert_contains "$OUT" "wrote: payload/agents/builder.md"
assert_contains "$OUT" "drift: 0 of 5 files, 2 source(s) moved, 0 orphan(s)" "apply summary: only the unreconciled sources are drift"
assert_file "$DEST/payload/bin/run.sh"
assert_file "$DEST/payload/tmpl/sub/b.txt"
assert_eq "# Builder
hello team" "$(cat "$DEST/payload/agents/builder.md")" "copied content"
check
assert_contains "$OUT" "source never reconciled: CLAUDE.md#Rules" "the portable tracks are not reconciled yet"
run_ex demo --reconcile --root "$ROOT"
check
assert_eq 0 "$RC" "check status"
assert_contains "$OUT" "in sync: 5 files" "check summary"
t_end

t_begin "export case 1: check on an in-sync destination exits 0 and prints in sync"
new_world
apply
run_ex demo --reconcile --root "$ROOT"
assert_eq 0 "$RC" "reconcile status"
check
assert_eq 0 "$RC" "check status"
assert_contains "$OUT" "in sync: 5 files"
t_end

t_begin "export case 2: check reports missing in dest, content differs and executable bit differs"
new_world
apply
run_ex demo --reconcile --root "$ROOT"
rm -f "$DEST/payload/tmpl/a.txt"
printf 'changed\n' >> "$DEST/payload/agents/builder.md"
chmod 644 "$DEST/payload/bin/run.sh"
check
assert_eq 1 "$RC" "check status"
assert_contains "$OUT" "missing in dest: payload/tmpl/a.txt"
assert_contains "$OUT" "content differs: payload/agents/builder.md"
assert_contains "$OUT" "executable bit differs: payload/bin/run.sh"
assert_contains "$OUT" "drift: 3 of 5 files, 0 source(s) moved, 0 orphan(s)"
t_end

# ---------------------------------------------------------------------------------
t_begin "export case 4: a harness-only block is stripped; a start with no end, an end with no start and a nested start each exit 1 and write nothing"
new_world
printf 'keep 1\n<!-- harness-only:start -->\nprivate lines\n<!-- harness-only:end -->\nkeep 2\n' > "$ROOT/agents/builder.md"
apply
assert_eq 0 "$RC" "apply status"
assert_eq "keep 1
keep 2" "$(cat "$DEST/payload/agents/builder.md")" "stripped content"
for case in 'a\n<!-- harness-only:start -->\nb\n' 'a\n<!-- harness-only:end -->\nb\n' 'a\n<!-- harness-only:start -->\n<!-- harness-only:start -->\nb\n<!-- harness-only:end -->\n'; do
  new_world
  printf "$case" > "$ROOT/agents/builder.md"
  before="$(dest_sum)"
  apply
  assert_eq 1 "$RC" "apply status for a marker error"
  assert_contains "$OUT" "marker error: payload/agents/builder.md:"
  assert_eq "$before" "$(dest_sum)" "nothing written"
  assert_no_file "$ROOT/products/demo.lock"
done
t_end

t_begin "export case 5 REQ-EXP-001.6: markers inside # comments and // comments both strip the enclosed block"
new_world
printf 'echo 1\n# <!-- harness-only:start -->\necho private\n# <!-- harness-only:end -->\necho 2\n' > "$ROOT/scripts/run.sh"
printf 'int a;\n// <!-- harness-only:start -->\nint secret;\n// <!-- harness-only:end -->\nint b;\n' > "$ROOT/skills/tmpl/a.txt"
apply
assert_eq 0 "$RC" "apply status"
assert_eq "echo 1
echo 2" "$(cat "$DEST/payload/bin/run.sh")" "# markers"
assert_eq "int a;
int b;" "$(cat "$DEST/payload/tmpl/a.txt")" "// markers"
assert_not_contains "$(cat "$DEST/payload/bin/run.sh")" "private"
assert_not_contains "$(cat "$DEST/payload/tmpl/a.txt")" "secret"
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-EXP-001.1 export case 6: a base leak pattern exits 1, names the destination file and line, writes nothing"
new_world
printf 'fine\nsecond line\nthe private-client list\n' > "$ROOT/agents/builder.md"
before="$(dest_sum)"
apply
assert_eq 1 "$RC" "apply status"
assert_contains "$OUT" "leak: payload/agents/builder.md:3: pattern \"\\bprivate-client\\b\""
assert_contains "$OUT" "nothing was written"
assert_eq "$before" "$(dest_sum)" "nothing written"
assert_no_file "$DEST/payload"
assert_eq main "$(git -C "$DEST" symbolic-ref --short HEAD)" "the branch was not switched"
t_end

t_begin "export case 7: a manifest leak pattern exits 1"
new_world
write_manifest 'leak      \bsome-product-only-token\b'
printf 'a some-product-only-token b\n' > "$ROOT/skills/tmpl/sub/b.txt"
check
assert_eq 1 "$RC" "check status"
assert_contains "$OUT" "leak: payload/tmpl/sub/b.txt:1: pattern"
t_end

t_begin "export case 8: allow suppresses only inside the matching glob; the same token elsewhere fails; allow with no in= exits 2"
new_world
printf 'uses private-client here\n' > "$ROOT/agents/builder.md"
printf 'and private-client there\n' > "$ROOT/skills/tmpl/a.txt"
write_manifest 'allow     \bprivate-client\b  in=payload/agents/*'
check
assert_eq 1 "$RC" "the other output still fails"
assert_contains "$OUT" "leak: payload/tmpl/a.txt:1"
assert_not_contains "$OUT" "payload/agents/builder.md:1"
printf 'clean\n' > "$ROOT/skills/tmpl/a.txt"
check
assert_not_contains "$OUT" "leak:" "allowed inside its glob"
write_manifest 'allow     \bprivate-client\b'
check
assert_eq 2 "$RC" "allow with no in="
assert_contains "$OUT" "allow needs in=DSTGLOB"
t_end

t_begin "export case 9: rewrite applies in order and respects in=; a rewrite that removes a leak makes the file pass"
new_world
printf 'private-client 1\nalpha\n' > "$ROOT/agents/builder.md"
printf 'alpha\n' > "$ROOT/skills/tmpl/a.txt"
write_manifest 'rewrite   alpha  =>  beta' 'rewrite   beta  =>  gamma   in=payload/agents/*' 'rewrite   private-client  =>  the customer'
apply
assert_eq 0 "$RC" "apply status"
assert_eq "the customer 1
gamma" "$(cat "$DEST/payload/agents/builder.md")" "in order, and the leak is gone"
assert_eq "beta" "$(cat "$DEST/payload/tmpl/a.txt")" "in= limits the second rule"
t_end

t_begin "REQ-EXP-001.2 a rewrite rule that matches nothing exits 1 and names the rule; a rule limited to an output set that does not exist is the same"
new_world
write_manifest 'rewrite   never-in-any-file  =>  x'
check
assert_eq 1 "$RC" "check status"
assert_contains "$OUT" "rewrite rule matches nothing: manifest line 8: never-in-any-file"
before="$(dest_sum)"
apply
assert_eq 1 "$RC" "apply status"
assert_eq "$before" "$(dest_sum)" "nothing written"
write_manifest 'rewrite   hello  =>  x   in=payload/nowhere/*'
check
assert_eq 1 "$RC" "a glob that matches no output"
assert_contains "$OUT" "rewrite rule matches nothing for outputs matching payload/nowhere/*"
t_end

t_begin "export case 10: each built-in secret shape is caught and the matched secret text is not printed"
new_world
# the secrets are assembled here from pieces so this file holds none of them
p1='sk-'; p2='abcdefghijklmnop0123456789'
shapes=(
  "-----BEGIN RSA PRIVATE KEY-----"
  "${p1}${p2}"
  "sk_live_${p2}"
  "rk_live_${p2}"
  "ghp_${p2}"
  "github_pat_${p2}"
  "xoxb-1234567890-${p2}"
  "AKIAABCDEFGHIJKLMNOP"
  "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r"
  "harness-only:start"
)
n=0
for secret in "${shapes[@]}"; do
  n=$((n + 1))
  printf 'prefix %s suffix\n' "$secret" > "$ROOT/agents/builder.md"
  check
  assert_eq 1 "$RC" "shape $n exits 1"
  assert_contains "$OUT" "leak: payload/agents/builder.md:1: secret shape" "shape $n named"
  case "$secret" in
    harness-only:*) ;;
    *) assert_not_contains "$OUT" "${secret#*-}" "shape $n: the secret text is not printed" ;;
  esac
  assert_not_contains "$OUT" "$p2" "shape $n: the secret body is not printed"
done
assert_eq 10 "$n" "shapes tried"
t_end

t_begin "export case 11: a binary file is copied byte for byte and listed as not scanned"
new_world
printf '\377\376\000private-client\000\001\002' > "$ROOT/skills/tmpl/blob.bin"
before="$(sha_of_bin=$(cat "$ROOT/skills/tmpl/blob.bin" | od -An -tx1 | tr -d ' \n'); echo "$sha_of_bin")"
apply
assert_eq 0 "$RC" "apply status"
assert_contains "$OUT" "binary (not scanned): payload/tmpl/blob.bin"
after="$(cat "$DEST/payload/tmpl/blob.bin" | od -An -tx1 | tr -d ' \n')"
assert_eq "$before" "$after" "bytes"
t_end

t_begin "export case 12: copy-tree copies nested files, honors exclude and skips __pycache__"
new_world
apply
assert_file "$DEST/payload/tmpl/a.txt"
assert_file "$DEST/payload/tmpl/sub/b.txt"
assert_no_file "$DEST/payload/tmpl/x.bak"
assert_no_file "$DEST/payload/tmpl/__pycache__"
t_end

# ---------------------------------------------------------------------------------
refusal() { # NAME EXPECTED_TEXT: the manifest (already written) is refused with status 2 and nothing is written
  before="$(dest_sum)"
  check
  assert_eq 2 "$RC" "check status: $1"
  assert_contains "$OUT" "$2" "message: $1"
  apply
  assert_eq 2 "$RC" "apply status: $1"
  assert_eq "$before" "$(dest_sum)" "nothing written: $1"
}

t_begin "export case 13: refusals with exit 2: absolute path, .., backslash, duplicate destination, unknown directive, product mismatch, branch main"
new_world
write_manifest 'copy      /etc/hostname  ->  payload/x'
refusal "absolute source" "absolute path"
write_manifest 'copy      agents/builder.md  ->  /payload/x'
refusal "absolute destination" "absolute path"
write_manifest 'copy      agents/../agents/builder.md  ->  payload/x'
refusal "dot dot" "'..' in path"
write_manifest 'copy      agents\builder.md  ->  payload/x'
refusal "backslash" "backslash in path"
write_manifest 'copy      agents/builder.md  ->  payload/agents/builder.md'
refusal "duplicate destination" "duplicate destination"
write_manifest 'frobnicate x'
refusal "unknown directive" "unknown directive"
{ printf 'product   other\n'; sed 1d "$ROOT/products/demo.manifest"; } > "$ROOT/products/demo.manifest.new"
mv "$ROOT/products/demo.manifest.new" "$ROOT/products/demo.manifest"
refusal "product mismatch" "product is 'other'"
write_manifest 'branch    main'
refusal "branch main" "branch main is refused"
write_manifest 'branch    master'
refusal "branch master" "branch master is refused"
t_end

t_begin "export case 13: refusals with exit 2: a symlink in a source path, a destination target that is a symlink, a destination folder that is a symlink out of the destination"
new_world
mkdir -p "$W/outside"
ln -s "$ROOT/agents" "$ROOT/agents-link"
write_manifest 'copy      agents-link/builder.md  ->  payload/linked.md'
refusal "symlink in a source path" "symbolic link"
ln -s "$W/outside/x" "$ROOT/agents/builder-link.md"
write_manifest 'copy-tree agents  ->  payload/agents-tree'
refusal "symlink inside a source tree" "symbolic link"
rm -f "$ROOT/agents/builder-link.md"
write_manifest
mkdir -p "$DEST/payload/agents"
ln -s "$W/outside/target" "$DEST/payload/agents/builder.md"
refusal "destination target is a symlink" "symbolic link"
rm -f "$DEST/payload/agents/builder.md"
rmdir "$DEST/payload/agents" "$DEST/payload"
mkdir -p "$DEST/payload"
ln -s "$W/outside" "$DEST/payload/agents"
refusal "destination folder is a symlink" "symbolic link"
assert_no_file "$W/outside/builder.md"
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-EXP-001.5 export case 14: apply refuses a destination with uncommitted changes to tracked files, and writes nothing"
new_world
printf 'dirty\n' >> "$DEST/README.md"
before="$(dest_sum)"
apply
assert_eq 2 "$RC" "apply status"
assert_contains "$OUT" "uncommitted changes to tracked files"
assert_eq "$before" "$(dest_sum)" "nothing written"
assert_no_file "$DEST/payload"
t_end

t_begin "export case 14: apply refuses an untracked file at a target path"
new_world
mkdir -p "$DEST/payload/agents"
printf 'mine\n' > "$DEST/payload/agents/builder.md"
apply
assert_eq 2 "$RC" "apply status"
assert_contains "$OUT" "a target path exists and is not tracked: payload/agents/builder.md"
assert_eq "mine" "$(cat "$DEST/payload/agents/builder.md")" "the file is untouched"
assert_no_file "$DEST/payload/bin"
t_end

# ---------------------------------------------------------------------------------
t_begin "export case 15: apply with a branch creates it from HEAD, a second run stays on it, and main is never written to"
new_world
main_head="$(git -C "$DEST" rev-parse main)"
apply
assert_eq 0 "$RC" "first apply"
assert_contains "$OUT" "branch: export/sync"
assert_eq export/sync "$(git -C "$DEST" symbolic-ref --short HEAD)" "branch after the first run"
assert_eq "$main_head" "$(git -C "$DEST" rev-parse main)" "main did not move"
assert_eq "$main_head" "$(git -C "$DEST" rev-parse export/sync)" "the branch starts at HEAD"
git -C "$DEST" add -A && git -C "$DEST" commit -q -m "export 1"
printf 'second\n' >> "$ROOT/agents/builder.md"
apply
assert_eq 0 "$RC" "second apply"
assert_not_contains "$OUT" "branch: export/sync" "no switch on the second run"
assert_eq export/sync "$(git -C "$DEST" symbolic-ref --short HEAD)" "branch after the second run"
assert_eq "$main_head" "$(git -C "$DEST" rev-parse main)" "main did not move"
assert_eq "$(printf 'readme\n')" "$(cat "$DEST/README.md")" "main's file"
git -C "$DEST" add -A && git -C "$DEST" commit -q -m "export 2"
# with no branch set, apply refuses on main
git -C "$DEST" switch -q main
write_manifest
sed -i.bak '/^branch/d' "$ROOT/products/demo.manifest" && rm -f "$ROOT/products/demo.manifest.bak"
apply
assert_eq 2 "$RC" "apply on main with no branch"
assert_contains "$OUT" "the manifest names no branch to write on"
t_end

t_begin "REQ-EXP-001.4 export case 16: apply leaves everything uncommitted: commit count and remote refs are unchanged"
new_world
count="$(commit_count)"
remote_before="$(git -C "$W/remote.git" for-each-ref)"
tracking_before="$(git -C "$DEST" for-each-ref refs/remotes)"
heads_before="$(git -C "$DEST" for-each-ref refs/heads)"
apply
assert_eq 0 "$RC" "apply status"
assert_eq "$count" "$(commit_count)" "commit count on the branch"
assert_eq "$remote_before" "$(git -C "$W/remote.git" for-each-ref)" "refs on the remote"
assert_eq "$tracking_before" "$(git -C "$DEST" for-each-ref refs/remotes)" "remote-tracking refs"
assert_eq "$(git -C "$DEST" rev-parse main)" "$(git -C "$DEST" rev-parse export/sync)" "the new branch sits at the old HEAD"
assert_contains "$heads_before" "refs/heads/main" "the starting branch"
status="$(git -C "$DEST" status --porcelain)"
assert_contains "$status" "?? payload/" "the files are in the working tree, uncommitted"
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-EXP-001.3 export case 17: tracks: never reconciled, then in sync, then source moved when the tracked section changes, and quiet for another section"
new_world
apply
check
assert_eq 1 "$RC" "before reconcile"
assert_contains "$OUT" "source never reconciled: CLAUDE.md#Rules"
assert_contains "$OUT" "source never reconciled: notes.md"
run_ex demo --reconcile --root "$ROOT"
assert_eq 0 "$RC" "reconcile status"
assert_contains "$OUT" "reconciled: CLAUDE.md#Rules (in products/demo/src/doctrine.md)"
check
assert_eq 0 "$RC" "after reconcile"
assert_not_contains "$OUT" "source moved"
printf '# Notes\n\n## Rules\nrule 1\n\n## Other\nother text CHANGED\n' > "$ROOT/CLAUDE.md"
check
assert_eq 0 "$RC" "a different section changed: quiet"
assert_not_contains "$OUT" "source moved"
printf '# Notes\n\n## Rules\nrule 1 CHANGED\n\n## Other\nother text CHANGED\n' > "$ROOT/CLAUDE.md"
check
assert_eq 1 "$RC" "the tracked section changed"
assert_contains "$OUT" "source moved: CLAUDE.md#Rules (generalized in products/demo/src/doctrine.md; see: git diff "
assert_contains "$OUT" "drift: 0 of 5 files, 1 source(s) moved, 0 orphan(s)"
printf 'notes v2\n' > "$ROOT/notes.md"
check
assert_contains "$OUT" "source moved: notes.md"
run_ex demo --reconcile --root "$ROOT" --only products/demo/src/doctrine.md
assert_eq 0 "$RC" "reconcile --only"
check
assert_eq 0 "$RC" "after reconcile --only"
lock="$(cat "$ROOT/products/demo.lock")"
assert_contains "$lock" '"harness_commit": "unknown"' "outside a git worktree the commit is unknown"
assert_contains "$lock" '"written": ['
assert_contains "$lock" '"reconciled": "20'
t_end

t_begin "export case 18: tracked heading not found when the heading is renamed"
new_world
apply
run_ex demo --reconcile --root "$ROOT"
printf '# Notes\n\n## Renamed Rules\nrule 1\n' > "$ROOT/CLAUDE.md"
check
assert_eq 1 "$RC" "check status"
assert_contains "$OUT" "tracked heading not found: CLAUDE.md#Rules"
run_ex demo --reconcile --root "$ROOT"
assert_eq 1 "$RC" "reconcile refuses a heading that is not there"
assert_contains "$OUT" "nothing was stamped"
t_end

t_begin "export case 19: status prints 1 line for a drifted product, nothing for a clean one, exits 0 both times, survives a malformed manifest"
new_world
apply
run_ex demo --reconcile --root "$ROOT"
run_ex --status --root "$ROOT"
assert_eq 0 "$RC" "clean status"
assert_eq "" "$OUT" "clean output"
printf '# Notes\n\n## Rules\nrule CHANGED\n' > "$ROOT/CLAUDE.md"
run_ex --status --root "$ROOT"
assert_eq 0 "$RC" "drifted status"
assert_eq 1 "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "1 line"
assert_contains "$OUT" "product-drift: demo: 1 source(s) moved since 20"
run_ex --status demo --root "$ROOT"
assert_contains "$OUT" "product-drift: demo:"
printf 'product   broken\nfrobnicate\n' > "$ROOT/products/broken.manifest"
run_ex --status --root "$ROOT"
assert_eq 0 "$RC" "status with a malformed manifest"
assert_contains "$OUT" "product-drift: broken: manifest error:"
assert_contains "$OUT" "product-drift: demo:"
t_end

t_begin "export case 20: prune removes an orphan that is in written and never removes a dest file that is not"
new_world
apply
git -C "$DEST" add -A && git -C "$DEST" commit -q -m "export 1"
printf 'mine\n' > "$DEST/payload/mine.txt"
git -C "$DEST" add -A && git -C "$DEST" commit -q -m "mine"
write_manifest
sed -i.bak '/skills\/tmpl/d' "$ROOT/products/demo.manifest" && rm -f "$ROOT/products/demo.manifest.bak"
check
assert_eq 1 "$RC" "orphans are drift"
assert_contains "$OUT" "orphan in dest: payload/tmpl/a.txt"
assert_not_contains "$OUT" "payload/mine.txt"
apply
assert_file "$DEST/payload/tmpl/a.txt" "no prune without --prune"
apply --prune
assert_eq 0 "$RC" "apply --prune status"
assert_no_file "$DEST/payload/tmpl/a.txt"
assert_no_file "$DEST/payload/tmpl/sub/b.txt"
assert_file "$DEST/payload/mine.txt" "a file that is not in written stays"
assert_file "$DEST/README.md"
t_end

t_begin "export case 21: a failing post command exits 1 and shows its output; --no-post skips it"
new_world
write_manifest 'post      echo POST-OUTPUT-LINE; exit 3'
apply
assert_eq 1 "$RC" "apply status"
assert_contains "$OUT" "post command failed (3): echo POST-OUTPUT-LINE; exit 3"
assert_contains "$OUT" "POST-OUTPUT-LINE"
new_world
write_manifest 'post      echo POST-OUTPUT-LINE; exit 3'
apply --no-post
assert_eq 0 "$RC" "apply --no-post status"
assert_not_contains "$OUT" "POST-OUTPUT-LINE"
new_world
write_manifest 'post      pwd > post-ran.txt'
apply
assert_eq 0 "$RC" "a passing post command"
assert_file "$DEST/post-ran.txt" "post runs in dest"
t_end

t_begin "export case 22: list prints each manifest"
new_world
printf 'product   second\ndest      %s\ncopy      agents/builder.md -> a.md\ncopy      scripts/run.sh -> b.sh\n' "$W/other-dest" > "$ROOT/products/second.manifest"
run_ex --list --root "$ROOT"
assert_eq 0 "$RC" "status"
assert_contains "$OUT" "demo  $DEST  4 file directives"
assert_contains "$OUT" "second  $W/other-dest  2 file directives"
t_end

t_begin "export case 23: the wrapper tools/export.sh passes arguments and the exit code through unchanged"
new_world
OUT="$(cd "$CWD" && /bin/bash "$REPO/tools/export.sh" demo --check --root "$ROOT" --leak-base "$LEAK" 2>&1)"
RC=$?
assert_eq 1 "$RC" "drift exit code"
assert_contains "$OUT" "missing in dest: payload/agents/builder.md"
OUT="$(cd "$CWD" && /bin/bash "$REPO/tools/export.sh" demo --apply --root "$ROOT" --leak-base "$LEAK" 2>&1)"
assert_eq 0 "$?" "apply through the wrapper"
OUT="$(cd "$CWD" && /bin/bash "$REPO/tools/export.sh" demo --check --root "$ROOT" 2>&1)"
assert_eq 2 "$?" "refusal exit code (no --leak-base)"
OUT="$(cd "$CWD" && /bin/bash "$REPO/tools/export.sh" --help 2>&1)"
assert_eq 0 "$?" "help exit code"
assert_contains "$OUT" "--root is the private root"
t_end

t_begin "export case 24: nothing outside the fixture is read (temp cwd, temp HOME, every opened file audited)"
new_world
apply > /dev/null
run_ex demo --reconcile --root "$ROOT"
leaks="$(cd "$CWD" && "$SBX_PY" -B - "$REPO/tools" "$W" "$ROOT" "$LEAK" "$DEST" << 'PYEOF'
import contextlib, io, os, sys
tools, world, root, leak, dest = sys.argv[1:6]
opened = []
sys.addaudithook(lambda ev, args: opened.append(str(args[0])) if ev == "open" and args and isinstance(args[0], (str, bytes, os.PathLike)) else None)
sys.path.insert(0, tools)
import export
prefixes = [os.path.realpath(p) for p in (world, sys.prefix, sys.base_prefix, sys.exec_prefix, "/dev", tools)]
rc = 0
for mode in (["--check"], ["--apply"], ["--status"], ["--list"]):
    argv = ["demo"] + mode + ["--root", root, "--leak-base", leak] if mode[0] in ("--check", "--apply") else mode + ["--root", root]
    with contextlib.redirect_stdout(io.StringIO()):
        export.main(argv)
for p in opened:
    rp = os.path.realpath(p)
    if not any(rp == q or rp.startswith(q + os.sep) for q in prefixes) and not rp.endswith((".py", ".pyc", ".so", ".cfg", ".pth", ".dylib")):
        print("OPENED OUTSIDE: %s" % p)
PYEOF
)"
assert_eq "" "$leaks" "files opened outside the fixture"
assert_eq "$W/cwd" "$(cd "$CWD" && pwd -P | sed "s#^/private##")" "the tool ran from the temp folder"
t_end

# ---------------------------------------------------------------------------------
t_begin "the export modes refuse bad arguments with exit 2 and need --root, --leak-base and exactly 1 mode"
new_world
run_ex demo --check --leak-base "$LEAK"
assert_eq 2 "$RC" "no --root"
assert_contains "$OUT" "--root is required"
run_ex demo --check --root "$ROOT"
assert_eq 2 "$RC" "no --leak-base"
run_ex demo --check --apply --root "$ROOT" --leak-base "$LEAK"
assert_eq 2 "$RC" "2 modes"
run_ex --check --root "$ROOT" --leak-base "$LEAK"
assert_eq 2 "$RC" "no product"
run_ex demo --root "$ROOT"
assert_eq 2 "$RC" "no mode"
run_ex demo --check --frob --root "$ROOT" --leak-base "$LEAK"
assert_eq 2 "$RC" "unknown option"
printf '(unclosed\n' > "$W/badleak.txt"
run_ex demo --check --root "$ROOT" --leak-base "$W/badleak.txt"
assert_eq 2 "$RC" "a leak list line that is not a regular expression"
t_end

t_summary
