#!/usr/bin/env python3
"""Checkpoint nudge (UserPromptSubmit): a soft note, never a block.

Notes, each a statement of fact:
  - context use at or above 50 percent of CONDUCTOR_WINDOW (unset: no percent note)
  - this session's checkpoint is older than 45 minutes and 10 or more tool calls
    have run since it was last modified (counted from the last 2 MB of the transcript)
At most 1 note per 25,000 tokens per session. An unreadable transcript prints nothing.
"""
import os
import sys
import time

sys.dont_write_bytecode = True
# python3 runs a hook with -I, which keeps the hook's own folder off sys.path.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import hooklib
except Exception:
    sys.exit(0)

NUDGE_PERCENT = 50
STALE_SECONDS = 45 * 60
STALE_TOOL_CALLS = 10
QUIET_TOKENS = 25000


def window_size():
    raw = os.environ.get("CONDUCTOR_WINDOW", "").strip()
    if raw.isdigit() and raw.isascii() and 0 < int(raw) <= 10 ** 9:
        return int(raw)
    return None


def tool_calls_since(entries, since):
    n = 0
    for e in entries:
        if e.get("isSidechain"):
            continue
        ts = hooklib.parse_iso(e.get("timestamp"))
        if ts is None or ts <= since:
            continue
        n += len(hooklib.tool_uses(e))
    return n


def handle(ev, ctx):
    tpath = ev.get("transcript_path")
    sid = ev.get("session_id")
    cwd = ev.get("cwd")
    if not isinstance(tpath, str) or not tpath:
        ctx.note("H005")
        return None
    try:
        entries = hooklib.transcript_entries(tpath)
    except Exception:
        ctx.note("H005")
        return None
    now = time.time()
    tokens = hooklib.context_tokens(entries)
    notes = []

    window = window_size()
    if window is not None and tokens is not None:
        pct = int(tokens * 100 / window)
        if pct >= NUDGE_PERCENT:
            notes.append("Context use is %d percent of the %d token window." % (pct, window))

    if isinstance(sid, str) and hooklib.SESSION_RE.fullmatch(sid):
        items, _links = hooklib.scan_checkpoints(cwd, now)
        for cp in items:
            if not cp.active or cp.session != sid:
                continue
            age = now - cp.mtime
            if age < STALE_SECONDS:
                continue
            calls = tool_calls_since(entries, cp.mtime)
            if calls >= STALE_TOOL_CALLS:
                notes.append("This session's checkpoint was last modified %s ago and %d tool calls have run since."
                             % (hooklib.format_age(age), calls))
                break

    if not notes:
        return None
    path = hooklib.state_path(ctx, "nudge", sid)
    state = hooklib.load_json_file(path, ctx)
    last = state.get("tokens")
    last = last if isinstance(last, int) and not isinstance(last, bool) and last >= 0 else None
    here = tokens if tokens is not None else 0
    if last is not None and here >= last and here - last < QUIET_TOKENS:
        return None
    hooklib.save_json_file(path, {"tokens": here}, ctx)
    return hooklib.context_output("UserPromptSubmit", notes)


if __name__ == "__main__":
    hooklib.main("checkpoint-nudge", {"UserPromptSubmit": handle})
