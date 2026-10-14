#!/usr/bin/env python3
"""Project-home check (SessionStart): 1 warning line when the working folder is
the parent of a listed project home, the user's home folder, or a sibling of a
listed home. Silent with no list, and silent inside a listed home.

The list is `project_homes:` followed by `- /path` lines in
{config dir}/conductor/defaults.md.
"""
import os
import sys

sys.dont_write_bytecode = True
# python3 runs a hook with -I, which keeps the hook's own folder off sys.path.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import hooklib
except Exception:
    sys.exit(0)

SOURCES = ("startup", "resume", "clear", "fork")


def norm(path):
    return os.path.realpath(os.path.expanduser(path))


def inside(path, folder):
    return path == folder or path.startswith(folder.rstrip("/") + "/")


def handle(ev, ctx):
    if ev.get("source") not in SOURCES:
        return None
    cwd = ev.get("cwd")
    if not isinstance(cwd, str) or not cwd.startswith("/"):
        return None
    homes = [norm(h) for h in hooklib.defaults_list(hooklib.defaults_lines(ctx), "project_homes")
             if h.startswith("/") or h.startswith("~")]
    if not homes:
        return None
    here = norm(cwd)
    if any(inside(here, h) for h in homes):
        return None
    user_home = os.environ.get("HOME", "")
    for h in homes:
        parent = os.path.dirname(h)
        if here != parent and inside(h, here):
            relation = "an ancestor folder of"
        elif here == parent:
            relation = "the parent folder of"
        elif os.path.dirname(here) == parent:
            relation = "a sibling of"
        else:
            continue
        return hooklib.context_output("SessionStart", [
            "The working folder is %s the listed project home %s."
            % (relation, hooklib.sanitize(h))])
    if user_home and here == norm(user_home):
        return hooklib.context_output("SessionStart", [
            "The working folder is the user's home folder; the listed project home is %s."
            % hooklib.sanitize(homes[0])])
    return None


if __name__ == "__main__":
    hooklib.main("project-home-check", {"SessionStart": handle})
