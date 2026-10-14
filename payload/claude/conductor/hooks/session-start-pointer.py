#!/usr/bin/env python3
"""Session-start pointer: 1 fixed-format line per active checkpoint.

Prints the checkpoint's validated relative path, age, origin (own, own from
unverified or unverified, decided from the write record) and pinned versus live
commit. Never prints checkpoint text, a header value or a session id. Each line
is a statement of fact.
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

UNPRINTABLE = "1 checkpoint with an unprintable name"


def short(commit):
    return commit[:12]


def checkpoint_line(ctx, cp, origins, cwd, live_cache):
    where = "handoffs/" + cp.name if cp.printable else UNPRINTABLE
    parts = ["Checkpoint: " + where, "age " + hooklib.format_age(cp.age),
             "origin " + hooklib.origin_of(origins, cp)]
    if cp.session_present and cp.pinned is not None:
        if cp.pinned == "invalid":
            parts.append("pinned commit invalid")
        elif cp.pinned == "none":
            parts.append("pinned commit none")
        else:
            if "v" not in live_cache:
                live_cache["v"] = hooklib.live_commit(ctx, cwd)
            live = live_cache["v"]
            parts.append("pinned commit " + short(cp.pinned))
            if live is None:
                parts.append("live commit unavailable")
            else:
                tail = "live commit " + short(live)
                if live != cp.pinned:
                    tail += " [CODE-MOVED]"
                parts.append(tail)
    return "; ".join(parts) + "."


def list_line(cp):
    where = "handoffs/" + cp.name if cp.printable else UNPRINTABLE
    return "Other active checkpoint: %s; age %s." % (where, hooklib.format_age(cp.age))


def link_line(links):
    if links == 1:
        return "1 checkpoint was not read because it is a link."
    return "%d checkpoints were not read because they are links." % links


def compact_count(ctx, sid):
    path = hooklib.state_path(ctx, "compact", sid)
    data = hooklib.load_json_file(path, ctx)
    n = data.get("n")
    n = (n if isinstance(n, int) and not isinstance(n, bool) and 0 <= n < 10 ** 6 else 0) + 1
    hooklib.save_json_file(path, {"n": n}, ctx)
    return n


def handle(ev, ctx):
    cwd = ev.get("cwd")
    sid = ev.get("session_id")
    source = ev.get("source")
    now = time.time()
    items, links = hooklib.scan_checkpoints(cwd, now)
    active = [c for c in items if c.active]
    origins = hooklib.load_record(ctx.config, ctx) if active else {}
    live_cache = {}
    lines = []
    root = os.path.realpath(cwd) if isinstance(cwd, str) and cwd.startswith("/") else None

    if source == "compact":
        n = compact_count(ctx, sid)
        mine = [c for c in active
                if isinstance(sid, str) and c.session is not None and c.session == sid]
        rest = [c for c in active if c not in mine]
        if len(active) > 1:
            lines.append("More than 1 checkpoint is active (%d)." % len(active))
        for c in mine:
            lines.append(checkpoint_line(ctx, c, origins, root, live_cache))
        for c in rest:
            lines.append(list_line(c))
        if links:
            lines.append(link_line(links))
        if n >= 3:
            lines.append("This session has compacted %d times." % n)
    elif source == "startup":
        if len(active) > 1:
            lines.append("More than 1 checkpoint is active (%d)." % len(active))
        for c in active:
            lines.append(checkpoint_line(ctx, c, origins, root, live_cache))
        if links:
            lines.append(link_line(links))
    else:
        # resume, clear, fork or an unknown source: 1 line at most
        if len(active) == 1:
            lines.append(checkpoint_line(ctx, active[0], origins, root, live_cache))
        elif len(active) > 1:
            lines.append("More than 1 checkpoint is active (%d)." % len(active))
        elif links:
            lines.append(link_line(links))
    if not lines:
        return None
    return hooklib.context_output("SessionStart", lines)


if __name__ == "__main__":
    hooklib.main("session-start-pointer", {"SessionStart": handle})
