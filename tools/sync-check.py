#!/usr/bin/env python3
"""sync-check.py - repo-side drift detector for install.sh vs payload/.

install.sh embeds 12 heredoc bodies (one per emit_* function) that must stay
byte-identical to the human-readable payload/ files they mirror. This script
is NEVER shipped by the installer; it only runs from a checkout of this repo,
after editing either install.sh or payload/, to prove the two stayed in sync.

TRANSFORM RULE (discovered 2026-07-04, holds for all 12 pairs as of v0.3.0):
  Each heredoc body is a byte-identical copy of its payload file's full
  content, including a single trailing newline. No wrapper markers, no
  frontmatter rewriting, no escaping. The only place a wrapper is added is
  the doctrine.md pair when *installed* (BEGIN/END CONDUCTOR markers around
  it in CLAUDE.md/AGENTS.md) -- that wrapping happens at install time, not in
  install.sh's source, so it is out of scope for this static check.
  Delimiters are quoted (e.g. <<'CONDUCTOR_BUILDER_MD') on every heredoc, so
  shell expansion never touches the body; this matters for emit_codex_skill,
  whose payload contains a literal "$conductor" that must not be expanded.

TRAILING-NEWLINE INVARIANT (why the byte-safety check below exists):
  install.sh's install_agent() does new="$($emit)" then printf '%s\n' "$new"
  to write the target file. Command substitution ($()) strips ALL trailing
  newlines from $emit's output before printf restores exactly one, so the
  round-trip is only byte-safe if the mirrored payload file already ends in
  exactly one trailing newline: two or more collapse silently to one, a
  content change the byte-string heredoc comparison above cannot see (both
  sides get read/joined with a single trailing "\n" regardless). This script
  asserts the invariant directly on the 12 payload files.

RELEASE LINE-BUDGET CONVENTION (informational only, not asserted below):
  Since v0.3.0 the repo caps how far each payload file may drift in line
  count from its .pre-v030 baseline backup, to keep review diffs small:
  doctrine.md +35 lines max, each agent file (scout/builder/critic/architect,
  both harnesses) +12 lines max, SKILL.md +60 lines max. This convention is
  enforced by hand (wc -l against the .pre-v030-* bak) during review, not by
  this script; it is documented here so the budget has one canonical home.

Usage: python3 tools/sync-check.py
Exit:  0 if every pair matches, both harnesses' CONDUCTOR_VERSION/VERSION
       agree, and every payload file ends in exactly one trailing newline;
       1 on any drift or violation.
"""
import difflib
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
INSTALL_SH = REPO / "install.sh"

# (emit function name, payload file it must mirror byte-for-byte)
PAIRS = [
    ("emit_builder", "payload/claude/agents/builder.md"),
    ("emit_scout", "payload/claude/agents/scout.md"),
    ("emit_critic", "payload/claude/agents/critic.md"),
    ("emit_architect", "payload/claude/agents/architect.md"),
    ("emit_skill", "payload/claude/skills/conductor/SKILL.md"),
    ("emit_doctrine", "payload/claude/doctrine.md"),
    ("emit_codex_builder", "payload/codex/agents/builder.toml"),
    ("emit_codex_scout", "payload/codex/agents/scout.toml"),
    ("emit_codex_critic", "payload/codex/agents/critic.toml"),
    ("emit_codex_architect", "payload/codex/agents/architect.toml"),
    ("emit_codex_skill", "payload/codex/skills/conductor/SKILL.md"),
    ("emit_codex_doctrine", "payload/codex/doctrine.md"),
]

FN_RE = re.compile(r"^(emit_\w+)\(\) \{ cat <<'([A-Za-z_]+)'$")


def check_trailing_newlines():
    """Assert each of the 12 payload files ends with exactly one b"\\n" (see
    TRAILING-NEWLINE INVARIANT above). Returns True if any file fails."""
    any_fail = False
    for _, rel_payload in PAIRS:
        payload_path = REPO / rel_payload
        if not payload_path.exists():
            print(f"FAIL   trailing-newline    {rel_payload}  (file missing)")
            any_fail = True
            continue
        data = payload_path.read_bytes()
        trailing = len(data) - len(data.rstrip(b"\n"))
        if trailing == 1:
            print(f"OK     trailing-newline    {rel_payload}")
        else:
            print(f"FAIL   trailing-newline    {rel_payload}  (found {trailing}, want exactly 1)")
            any_fail = True
    return any_fail


def extract_heredoc_bodies(text):
    """Map each emit_* function name to its heredoc body (payload-comparable
    string: joined lines plus one trailing newline, matching a plain file read)."""
    lines = text.split("\n")
    bodies = {}
    i = 0
    while i < len(lines):
        m = FN_RE.match(lines[i])
        if m:
            fn_name, delim = m.group(1), m.group(2)
            j = i + 1
            while j < len(lines) and lines[j] != delim:
                j += 1
            if j >= len(lines):
                sys.exit(f"FATAL: unterminated heredoc for {fn_name} (delimiter {delim} not found)")
            bodies[fn_name] = "\n".join(lines[i + 1 : j]) + "\n"
            i = j + 1
            continue
        i += 1
    return bodies


def main():
    install_text = INSTALL_SH.read_text()
    bodies = extract_heredoc_bodies(install_text)

    drift = False
    for fn_name, rel_payload in PAIRS:
        payload_path = REPO / rel_payload
        if fn_name not in bodies:
            print(f"DRIFT  {fn_name:22s} <- {rel_payload}  (function not found in install.sh)")
            drift = True
            continue
        if not payload_path.exists():
            print(f"DRIFT  {fn_name:22s} <- {rel_payload}  (payload file missing)")
            drift = True
            continue
        heredoc_body = bodies[fn_name]
        payload_content = payload_path.read_text()
        if heredoc_body == payload_content:
            print(f"OK     {fn_name:22s} <- {rel_payload}")
        else:
            print(f"DRIFT  {fn_name:22s} <- {rel_payload}")
            diff = difflib.unified_diff(
                payload_content.splitlines(keepends=True),
                heredoc_body.splitlines(keepends=True),
                fromfile=f"payload:{rel_payload}",
                tofile=f"install.sh:{fn_name}",
                n=2,
            )
            for line in list(diff)[:20]:
                print(f"       {line}", end="" if line.endswith("\n") else "\n")
            drift = True

    m = re.search(r'^CONDUCTOR_VERSION="([^"]+)"', install_text, re.MULTILINE)
    install_version = m.group(1) if m else None
    claude_version = (REPO / "payload/claude/skills/conductor/VERSION").read_text().strip()
    codex_version = (REPO / "payload/codex/skills/conductor/VERSION").read_text().strip()
    if install_version == claude_version == codex_version:
        print(f"OK     version           install.sh={install_version} claude={claude_version} codex={codex_version}")
    else:
        print(f"DRIFT  version           install.sh={install_version} claude={claude_version} codex={codex_version}")
        drift = True

    # Coverage check: PAIRS must name every emit_* function install.sh defines,
    # and vice versa, or a future 13th function could silently go unchecked.
    # Single source of truth: reuse extract_heredoc_bodies' FN_RE match pass
    # (the same one that built `bodies` above) instead of a second ad hoc regex,
    # so this check can never drift from what was actually parsed.
    defined_fns = set(bodies.keys())
    mapped_fns = {fn for fn, _ in PAIRS}
    missing_from_pairs = sorted(defined_fns - mapped_fns)
    missing_from_install = sorted(mapped_fns - defined_fns)
    if missing_from_pairs or missing_from_install:
        print(f"DRIFT  coverage          in install.sh but unmapped: {missing_from_pairs or 'none'}; "
              f"in PAIRS but not in install.sh: {missing_from_install or 'none'}")
        drift = True
    else:
        print(f"OK     coverage          {len(defined_fns)} emit_* functions, all mapped")

    if check_trailing_newlines():
        drift = True

    sys.exit(1 if drift else 0)


if __name__ == "__main__":
    main()
