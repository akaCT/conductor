#!/usr/bin/env python3
"""Usage-split check (Stop): a soft note when workers were dispatched this turn
and the closing message has no line that begins `Usage split:` (leading markdown
emphasis, a quote mark, a heading mark or a list number is fine; a heading or label with
the split below it counts, up to 2 blank lines later) and names at least 1 model alias.
Silent when no worker was dispatched, and when every worker dispatched was a scout.

The local tally holds model alias counts only (state/usage-tally.json).
"""
import os
import re
import sys

sys.dont_write_bytecode = True
# python3 runs a hook with -I, which keeps the hook's own folder off sys.path.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import hooklib
except Exception:
    sys.exit(0)

DISPATCH_TOOLS = ("Agent", "Task")
TALLY_KEYS = ("opus", "sonnet", "haiku", "fable", "inherit", "other", "unspecified")
# The line may open with markdown emphasis, a bullet, a heading mark, a quote mark or a
# list number (**Usage split:** ..., > Usage split: ..., 1. Usage split: ...), and the
# colon may sit inside or outside the emphasis. A heading has no colon: "## Usage split"
# on a line of its own, with the split on the next line.
SPLIT_RE = re.compile(
    "^[ \\t>*_#`\"'\\-\u2018\u2019\u201c\u201d]*(?:[0-9]{1,3}[.)][ \\t>*_#`\"'\u2018\u2019\u201c\u201d]*)?"
    "Usage split[ \\t*_`]*(?::|$)", re.I)
ALIAS_RE = re.compile(r"\b(opus|sonnet|haiku|fable)\b", re.I)


def dispatch_aliases(ctx, entries, cwd):
    """(aliases, all_scouts): the model alias of each worker dispatched this turn, and
    whether every one of them was a scout."""
    found = []
    scouts = []
    for e in entries:
        if e.get("isSidechain"):
            continue
        if e.get("type") == "user" and hooklib.is_real_prompt(e.get("message")):
            found = []
            scouts = []
            continue
        for b in hooklib.tool_uses(e):
            if b.get("name") not in DISPATCH_TOOLS:
                continue
            inp = b.get("input") if isinstance(b.get("input"), dict) else {}
            model = inp.get("model")
            if isinstance(model, str) and model.strip():
                alias = hooklib.agent_alias_from_text(model)
            else:
                alias = hooklib.agent_model(ctx, cwd, inp.get("subagent_type")) or "unspecified"
            found.append(alias if alias in TALLY_KEYS else "other")
            scouts.append(inp.get("subagent_type") == "scout")
    return found, bool(scouts) and all(scouts)


def has_split_line(message):
    lines = message.split("\n")
    for i, ln in enumerate(lines):
        m = SPLIT_RE.match(ln)
        if m:
            # A heading or a label with nothing after it has its split below: up to 2 blank
            # lines may sit between them. A line that already says something ends at the
            # first blank line.
            alone = ln[m.end():].strip(" \t*_`") == ""
            blanks = 0
            block = [ln]
            for nxt in lines[i + 1:i + 10]:
                if nxt.strip() == "":
                    if alone and len(block) == 1 and blanks < 2:
                        blanks += 1
                        continue
                    break
                block.append(nxt)
            if ALIAS_RE.search("\n".join(block)):
                return True
    return False


def last_assistant_text(entries):
    text = None
    for e in entries:
        if e.get("isSidechain") or e.get("type") != "assistant":
            continue
        parts = [b.get("text") for b in hooklib._blocks(e.get("message")) if b.get("type") == "text"]
        parts = [p for p in parts if isinstance(p, str)]
        if parts:
            text = "\n".join(parts)
    return text


def update_tally(ctx, aliases):
    path = hooklib.state_dir(ctx) + "/usage-tally.json"
    tally = hooklib.load_json_file(path, ctx)
    clean = {}
    for k in TALLY_KEYS:
        v = tally.get(k)
        clean[k] = v if isinstance(v, int) and not isinstance(v, bool) and 0 <= v < 10 ** 9 else 0
    for a in aliases:
        clean[a] += 1
    hooklib.save_json_file(path, clean, ctx)
    return clean


def handle(ev, ctx):
    if ev.get("stop_hook_active") is True:
        return None
    tpath = ev.get("transcript_path")
    if not isinstance(tpath, str) or not tpath:
        ctx.note("H005")
        return None
    try:
        entries = hooklib.transcript_entries(tpath)
    except Exception:
        ctx.note("H005")
        return None
    aliases, all_scouts = dispatch_aliases(ctx, entries, ev.get("cwd"))
    if not aliases:
        return None
    tally = update_tally(ctx, aliases)
    if all_scouts:
        return None
    msg = ev.get("last_assistant_message")
    if not isinstance(msg, str):
        msg = last_assistant_text(entries) or ""
    if has_split_line(msg):
        return None
    this_turn = ", ".join("%d %s" % (aliases.count(k), k) for k in TALLY_KEYS if k in aliases)
    seen = ", ".join("%s %d" % (k, tally[k]) for k in TALLY_KEYS if tally[k])
    lines = ["No usage-split line was found in the closing message after %d worker dispatch%s this turn (%s)."
             % (len(aliases), "" if len(aliases) == 1 else "es", this_turn)]
    if seen:
        lines.append("Local tally of worker model aliases: %s." % seen)
    return hooklib.soft_message(lines)


if __name__ == "__main__":
    hooklib.main("usage-split-check", {"Stop": handle})
