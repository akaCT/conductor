#!/usr/bin/env python3
"""Conductor installer helper: change settings.json without losing anything.

The installer runs it as "$PY" "$tmp" SETTINGS COMMAND [ARGS] from a mode 600
temp copy. Python 3.9 standard library only. Nothing here writes SETTINGS: a
command that changes the file prints the complete new text on stdout and exits
0, and the installer backs the file up and writes it through its own atomic
write. Data comes in by file path or as a separate argument, never as code.

Commands:
  get KEYPATH                     print the value as JSON (exit 12 when absent)
  set KEYPATH JSON                new text with that key set
  unset KEYPATH                   new text without that key (empty parents go)
  wire SPEC ROOT PYTHON RECORD [REMOVED]
                                  make the hook entries of Conductor match SPEC (a
                                  tab separated file: id, event, matcher, hook path,
                                  arguments, timeout; empty means none), in place:
                                  an entry that is there stays where it is, with the
                                  timeout and the matcher you gave it and the other
                                  hooks of its group; one that is missing is added in
                                  a group of its own; one that is no longer wanted is
                                  removed. RECORD is read first (the list of an earlier
                                  wire, as JSON, when the file holds one) and then
                                  receives the list of entries wired, as JSON. REMOVED,
                                  when given, receives a row for each entry that was
                                  removed: its event, its matcher and the name of its
                                  script, separated by tabs, 1 row per line.
  unwire ROOT RECORD [REMOVED]    remove every Conductor hook entry (RECORD is a
                                  JSON list from an earlier wire, or -). REMOVED,
                                  when given, receives a row for each entry removed
                                  (event, matcher, script name), as above.
  prune ROOT [REMOVED [RECORD]]   remove every hook entry written in Conductor's
                                  own guarded form (see below) whose script, a
                                  file under ROOT/conductor/hooks/, is no longer
                                  there (a script an installer step deleted); any
                                  other hook entry is left alone. REMOVED, when
                                  given, receives a row for each entry removed.
  check                           exit 0 when the file can be changed safely
  empty                           exit 0 when the file holds an empty object
                                  (or nothing), 11 when it holds anything else

KEYPATH is dot separated. A file that is absent, empty or only whitespace counts
as an empty object. A hook entry is Conductor's own only when its command equals
one in RECORD, or is in Conductor's own guarded form (below) and runs a script
under ROOT/conductor/hooks/. A hook of your own is never removed, whatever path its
command names (a command that only mentions a file there, such as a tail of a log,
or runs a script there without Conductor's guard, is yours).

A hook command is written as `[ ! -x "PYTHON" ] || [ ! -f "SCRIPT" ] || [ ! -r "SCRIPT" ]
|| "PYTHON" -I -B "SCRIPT"`: with the interpreter gone or not executable, or the script
gone, or there but not readable, the command does nothing and exits 0, so a removed
interpreter or script never blocks a prompt, a dispatch or a stop. -I and -B keep the
environment, the user's site folder and bytecode files out of the hook. The merge knows
exactly 2 forms of its own: this one and the one without the -x test (what the delivered
0.4.0 build wrote); it refreshes the second into the first where it stands.

The file keeps the form it had: the indentation (a tab, 2 or 4 spaces, or a file on 1
line stays on 1 line), the line ending (CRLF stays CRLF) and whether the last line ends
with a line break. An object you wrote on 1 line inside an indented file may be spread
over several lines. An event list you left empty stays an empty list when the last
Conductor entry leaves it, and a "hooks" object you left empty stays when the last entry
leaves (RECORD tells which: "empty_before" on an entry, "hooks_empty_before" on any entry).
U+2028 and U+2029 are written escaped. A number that is not finite (1e999) and a string
holding a lone surrogate make the file one this program will not change (exit 4).

Exit codes: 0 new text printed, 11 nothing to change, 12 key absent,
3 the file is not valid JSON (left untouched), 4 the file has a shape this
program will not change (left untouched), 2 usage.
"""
import copy
import json
import os
import re
import sys

CHANGED, UNCHANGED, ABSENT, UNPARSEABLE, UNSUPPORTED, USAGE = 0, 11, 12, 3, 4, 2


class Stop(Exception):
    def __init__(self, code, message):
        Exception.__init__(self, message)
        self.code = code
        self.message = message


# The layout of the file that was read, kept for the text written back: INDENT is what json
# puts in front of each level (a string of spaces or a tab), or None for a file on 1 line,
# and SEPARATORS then tells the item and key separators of that line.
INDENT = 2
SEPARATORS = (", ", ": ")
# The line ending (a file whose every line break is CRLF stays CRLF) and whether the last line
# of the file ends with a line break.
NEWLINE = "\n"
FINAL_NEWLINE = True


def detect_style(text):
    """Sets INDENT, SEPARATORS, NEWLINE and FINAL_NEWLINE from the text of the file. A file on 1
    line stays on 1 line (compact when it has no space after its colons); otherwise the leading
    blanks of the first indented line are the indentation (a tab, 2 spaces, 4 spaces, or whatever
    the file uses)."""
    global INDENT, SEPARATORS, NEWLINE, FINAL_NEWLINE
    INDENT, SEPARATORS = 2, (", ", ": ")
    NEWLINE, FINAL_NEWLINE = "\n", True
    body = text.strip()
    if body == "":
        return
    if "\n" in text and text.count("\r\n") == text.count("\n"):
        NEWLINE = "\r\n"
    FINAL_NEWLINE = text.endswith("\n")
    lines = body.split("\n")
    if len(lines) == 1:
        INDENT = None
        SEPARATORS = (",", ":") if re.search(r'":[^ ]', body) and '": ' not in body else (", ", ": ")
        return
    for ln in lines[1:]:
        m = re.match(r"([ \t]+)\S", ln)
        if m:
            INDENT = m.group(1)
            return
    INDENT = 0


def load(path):
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
        text = raw.decode("utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise Stop(UNPARSEABLE, "cannot read %s (%s)" % (path, exc))
    if text.strip() == "":
        return {}
    try:
        data = json.loads(text, parse_constant=reject_constant, parse_float=reject_float)
    except ValueError as exc:
        raise Stop(UNPARSEABLE, "%s is not valid JSON (%s)" % (path, exc))
    except RecursionError:
        raise Stop(UNSUPPORTED, "%s is nested too deeply to change" % path)
    if not isinstance(data, dict):
        raise Stop(UNSUPPORTED, "%s does not hold a JSON object" % path)
    try:
        lone = has_lone_surrogate(data)
    except RecursionError:
        raise Stop(UNSUPPORTED, "%s is nested too deeply to change" % path)
    if lone:
        raise Stop(UNSUPPORTED, "%s holds a string with a lone surrogate escape, which cannot be written back" % path)
    detect_style(text)
    return data


def reject_constant(name):
    """NaN, Infinity and -Infinity are not JSON; the file is left as it is."""
    raise Stop(UNSUPPORTED, "the file holds %s, which is not a JSON number" % name)


def reject_float(text):
    """A number too large for a float (1e999) would be written back as Infinity; refuse it."""
    value = float(text)
    if value != value or value in (float("inf"), float("-inf")):
        raise Stop(UNSUPPORTED, "the file holds the number %s, which is too large to keep" % text[:24])
    return value


def has_lone_surrogate(node):
    """True when a key or string holds a code point in 0xD800 to 0xDFFF (json joins a valid pair
    into 1 character, so one left over is alone)."""
    if isinstance(node, str):
        return any("\ud800" <= ch <= "\udfff" for ch in node)
    if isinstance(node, dict):
        return any(has_lone_surrogate(k) or has_lone_surrogate(v) for k, v in node.items())
    if isinstance(node, list):
        return any(has_lone_surrogate(v) for v in node)
    return False


def dumps(obj):
    if INDENT is None:
        text = json.dumps(obj, ensure_ascii=False, separators=SEPARATORS)
    else:
        text = json.dumps(obj, indent=INDENT, ensure_ascii=False)
    # U+2028 and U+2029 end a line in some readers; inside a JSON string they are written escaped
    text = text.replace("\u2028", "\\u2028").replace("\u2029", "\\u2029")
    if NEWLINE != "\n":
        text = text.replace("\n", NEWLINE)
    return text + (NEWLINE if FINAL_NEWLINE else "")


def emit(text):
    sys.stdout.buffer.write(text.encode("utf-8"))
    sys.stdout.flush()


def split_path(keypath):
    parts = keypath.split(".")
    if not keypath or any(p == "" for p in parts):
        raise Stop(USAGE, "bad key path %r" % keypath)
    return parts


def parse_json(text):
    try:
        return json.loads(text)
    except ValueError:
        raise Stop(USAGE, "not valid JSON: %s" % text[:60])


def cmd_get(data, keypath):
    cur = data
    for p in split_path(keypath):
        if not isinstance(cur, dict) or p not in cur:
            return ABSENT
        cur = cur[p]
    emit(json.dumps(cur, ensure_ascii=False) + "\n")
    return CHANGED


def cmd_set(data, keypath, value_json):
    parts = split_path(keypath)
    value = parse_json(value_json)
    cur = data
    for p in parts[:-1]:
        if p not in cur:
            cur[p] = {}
        if not isinstance(cur[p], dict):
            raise Stop(UNSUPPORTED, "%s is not an object, so %s cannot be set" % (p, keypath))
        cur = cur[p]
    if parts[-1] in cur and cur[parts[-1]] == value and type(cur[parts[-1]]) is type(value):
        return UNCHANGED
    cur[parts[-1]] = value
    emit(dumps(data))
    return CHANGED


def cmd_unset(data, keypath):
    parts = split_path(keypath)
    chain = [data]
    for p in parts[:-1]:
        nxt = chain[-1].get(p) if isinstance(chain[-1], dict) else None
        if not isinstance(nxt, dict):
            return UNCHANGED
        chain.append(nxt)
    if parts[-1] not in chain[-1]:
        return UNCHANGED
    del chain[-1][parts[-1]]
    for i in range(len(parts) - 1, 0, -1):
        if chain[i] == {}:
            del chain[i - 1][parts[i - 1]]
        else:
            break
    emit(dumps(data))
    return CHANGED


# Conductor's own hook command, in exactly 2 forms. The current one: the python3 path tested with
# -x, the script tested with -f and -r, then the python3 path in quotes, -I -B and the script path
# in quotes again. The one the delivered 0.4.0 build wrote: the same without the -x test.
GUARDED_NEW = re.compile(r'^\[ ! -x "([^"]+)" \] \|\| \[ ! -f "([^"]+)" \] \|\| \[ ! -r "\2" \] \|\| "\1" -I -B "\2"(?: .*)?$', re.S)
GUARDED_R = re.compile(r'^\[ ! -f "([^"]+)" \] \|\| \[ ! -r "\1" \] \|\| "[^"]+" -I -B "\1"(?: .*)?$', re.S)


def guarded_script(command, root):
    """The script of a command in Conductor's own guarded form when that script is a file
    under ROOT/conductor/hooks/ (and the path has no .. part), else None. A command that
    only names a path there is a user's own hook."""
    if not isinstance(command, str):
        return None
    m = GUARDED_NEW.match(command)
    script = m.group(2) if m else None
    if script is None:
        m = GUARDED_R.match(command)
        script = m.group(1) if m else None
    if script is None:
        return None
    base = root.rstrip("/") + "/conductor/hooks/"
    if script.startswith(base) and ".." not in script.split("/"):
        return script
    return None


def is_ours(command, root, recorded):
    """True for a command in the install record, or in Conductor's own guarded form whose
    script is a file under ROOT/conductor/hooks/. A command that only names a path there is
    a user's own hook and is never ours."""
    if not isinstance(command, str):
        return False
    return command in recorded or guarded_script(command, root) is not None


def hook_groups(data):
    hooks = data.get("hooks")
    if hooks is None:
        return None
    if not isinstance(hooks, dict):
        raise Stop(UNSUPPORTED, "hooks in the settings file is not an object")
    for event, groups in hooks.items():
        if not isinstance(groups, list):
            raise Stop(UNSUPPORTED, "hooks.%s in the settings file is not a list" % event)
    return hooks


def ours_in(hooks, root, recorded):
    found = []
    for event, groups in (hooks or {}).items():
        for g in groups:
            if not (isinstance(g, dict) and isinstance(g.get("hooks"), list)):
                continue
            for h in g["hooks"]:
                if isinstance(h, dict) and is_ours(h.get("command"), root, recorded):
                    found.append((event, g.get("matcher", ""), h.get("command"), h.get("timeout")))
    return found


def settle_event(hooks, event, kept, keep):
    """Puts the groups left in an event back. An event that ends up with no group goes, unless
    it was an empty list of the user's before Conductor wired it (KEEP): that one stays empty."""
    if kept:
        hooks[event] = kept
    elif hooks[event]:
        if event in keep:
            hooks[event] = []
        else:
            del hooks[event]


def strip_ours(hooks, root, recorded, keep=()):
    """Remove every Conductor entry; drop the groups and events that this empties."""
    for event in list(hooks.keys()):
        kept = []
        for g in hooks[event]:
            if isinstance(g, dict) and isinstance(g.get("hooks"), list):
                inner = [h for h in g["hooks"]
                         if not (isinstance(h, dict) and is_ours(h.get("command"), root, recorded))]
                if len(inner) != len(g["hooks"]):
                    if not inner:
                        continue
                    g = dict(g)
                    g["hooks"] = inner
            kept.append(g)
        settle_event(hooks, event, kept, keep)


def read_spec(path):
    entries = []
    if path in ("", "-"):
        return entries
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            f = line.split("\t")
            if len(f) < 6:
                raise Stop(USAGE, "bad hook line %r" % line[:60])
            entries.append({"id": f[0], "event": f[1], "matcher": f[2], "path": f[3], "args": f[4],
                            "timeout": int(f[5])})
    return entries


def read_record_entries(path):
    """The entries of an install record's hook list (a JSON list), or [] when there is none."""
    if path in ("", "-") or not os.path.exists(path):
        return []
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return []
    return [e for e in data if isinstance(e, dict) and isinstance(e.get("command"), str)] \
        if isinstance(data, list) else []


def read_record(path):
    return [e["command"] for e in read_record_entries(path)]


def hooks_empty_before(entries):
    """True when the record says the user's "hooks" object was empty before Conductor wired anything."""
    return any(e.get("hooks_empty_before") is True for e in entries)


def empty_events(entries):
    """The events the record says were an empty list of the user's before Conductor wired them."""
    return set(e["event"] for e in entries if e.get("empty_before") is True and isinstance(e.get("event"), str))


def hook_command(py, path, args):
    """The settings command of 1 hook: guarded against a missing or not executable python3 and a
    missing or unreadable script, isolated python."""
    return '[ ! -x "%s" ] || [ ! -f "%s" ] || [ ! -r "%s" ] || "%s" -I -B "%s"' % (py, path, path, py, path) \
        + (" " + args if args else "")


def flat(text):
    """TEXT with each line break and tab turned into a space, so that a field stays on its line."""
    return re.sub(r"[\r\n\t]", " ", text if isinstance(text, str) else "")


def script_name(command, root):
    """The file name of the script a Conductor command runs; for any other command its first 60
    characters."""
    script = guarded_script(command, root)
    if script is not None:
        return script.rsplit("/", 1)[-1]
    return flat(command)[:60]


def write_removed(path, rows, root):
    """1 row per line into the REMOVED file: the event, the matcher and the script name of an
    entry that was removed, separated by tabs (a row is (event, matcher, command)). The same row
    is written once. Nothing is written when no file was asked for."""
    if path in ("", "-"):
        return
    seen = []
    for event, matcher, command in rows:
        row = (flat(event), flat(matcher), script_name(command, root))
        if row not in seen:
            seen.append(row)
    with open(path, "w", encoding="utf-8") as fh:
        for row in seen:
            fh.write("\t".join(row) + "\n")


def match_wanted(wanted, event, matcher, command, root):
    """The wanted entry that an existing Conductor entry of that event stands for, not taken yet:
    the same command and matcher; else the same script (an older guard form of it) under the same
    matcher; else the same script under any matcher (you narrowed it, and your matcher stays)."""
    script = guarded_script(command, root)
    for w in wanted:
        if not w["taken"] and w["event"] == event and w["matcher"] == matcher and w["command"] == command:
            return w
    if script is not None:
        for same_matcher in (True, False):
            for w in wanted:
                if w["taken"] or w["event"] != event or w["path"] != script:
                    continue
                if same_matcher and w["matcher"] != matcher:
                    continue
                return w
    return None


def cmd_wire(data, spec_path, root, py, record_path, removed_path="-"):
    entries = read_spec(spec_path)
    old = read_record_entries(record_path)
    recorded = [e["command"] for e in old]
    hooks = hook_groups(data)
    original = copy.deepcopy(data)
    keep = empty_events(old)
    # a "hooks" object of yours that was empty before Conductor wired anything stays when the last
    # entry leaves; the record carries that on every entry
    hooks_empty = original.get("hooks") == {} or hooks_empty_before(old)
    for event, groups in (hooks or {}).items():
        if groups == []:
            keep.add(event)
    wanted = []
    for e in entries:
        wanted.append({"id": e["id"], "event": e["event"], "matcher": e["matcher"], "path": e["path"],
                       "command": hook_command(py, e["path"], e["args"]), "timeout": e["timeout"],
                       "taken": False, "hook": None})
    removed = []
    if hooks is None:
        hooks = {}
    # an entry of Conductor that is there and still wanted stays where it is, with its timeout
    # and the other hooks of its group; one that is not wanted any more goes
    for event in list(hooks.keys()):
        kept = []
        for g in hooks[event]:
            if isinstance(g, dict) and isinstance(g.get("hooks"), list):
                inner = []
                for h in g["hooks"]:
                    if isinstance(h, dict) and is_ours(h.get("command"), root, recorded):
                        w = match_wanted(wanted, event, g.get("matcher", ""), h["command"], root)
                        if w is None:
                            removed.append((event, g.get("matcher", ""), h["command"]))
                            continue
                        w["taken"], w["hook"], w["now"] = True, h, g.get("matcher", "")
                        h["command"] = w["command"]
                        if "timeout" not in h:
                            h["timeout"] = w["timeout"]
                    inner.append(h)
                if len(inner) != len(g["hooks"]):
                    if not inner:
                        continue
                    g = dict(g)
                    g["hooks"] = inner
            kept.append(g)
        settle_event(hooks, event, kept, keep)
    groups = []
    for w in wanted:
        if w["taken"]:
            continue
        w["hook"] = {"type": "command", "command": w["command"], "timeout": w["timeout"]}
        for g in groups:
            if g[0] == w["event"] and g[1] == w["matcher"]:
                g[2].append(w["hook"])
                break
        else:
            groups.append((w["event"], w["matcher"], [w["hook"]]))
    for ev, matcher, inner in groups:
        hooks.setdefault(ev, []).append({"matcher": matcher, "hooks": inner})
    record = []
    for w in wanted:
        r = {"id": w["id"], "event": w["event"], "matcher": w.get("now", w["matcher"]), "command": w["command"],
             "timeout": w["hook"].get("timeout", w["timeout"])}
        if w["event"] in keep:
            r["empty_before"] = True
        if hooks_empty:
            r["hooks_empty_before"] = True
        record.append(r)
    if record_path not in ("", "-"):
        with open(record_path, "w", encoding="utf-8") as fh:
            json.dump(record, fh)
    write_removed(removed_path, removed, root)
    if hooks or hooks_empty:
        data["hooks"] = hooks
    elif "hooks" in data:
        del data["hooks"]
    if data == original:
        return UNCHANGED
    emit(dumps(data))
    return CHANGED


def cmd_unwire(data, root, record_path, removed_path="-"):
    old = read_record_entries(record_path)
    recorded = [e["command"] for e in old]
    hooks = hook_groups(data)
    write_removed(removed_path, [], root)
    found = ours_in(hooks, root, recorded) if hooks is not None else []
    if not found:
        return UNCHANGED
    write_removed(removed_path, [(f[0], f[1], f[2]) for f in found], root)
    strip_ours(hooks, root, recorded, empty_events(old))
    if hooks or hooks_empty_before(old):
        data["hooks"] = hooks
    else:
        del data["hooks"]
    emit(dumps(data))
    return CHANGED


def dangling(command, root):
    """True only for a command Conductor wrote (the guarded form, see guarded_script) whose
    script does not exist. A user's own hook, whatever it names, is never dangling."""
    script = guarded_script(command, root)
    return script is not None and not os.path.isfile(script)


def cmd_prune(data, root, removed_path="-", record_path="-"):
    hooks = hook_groups(data)
    write_removed(removed_path, [], root)
    if hooks is None:
        return UNCHANGED
    old = read_record_entries(record_path)
    keep = empty_events(old)
    changed = False
    gone = []
    for event in list(hooks.keys()):
        kept = []
        for g in hooks[event]:
            if isinstance(g, dict) and isinstance(g.get("hooks"), list):
                inner = [h for h in g["hooks"]
                         if not (isinstance(h, dict) and dangling(h.get("command"), root))]
                if len(inner) != len(g["hooks"]):
                    changed = True
                    gone += [(event, g.get("matcher", ""), h["command"]) for h in g["hooks"] if h not in inner]
                    if not inner:
                        continue
                    g = dict(g)
                    g["hooks"] = inner
            kept.append(g)
        settle_event(hooks, event, kept, keep)
    if not changed:
        return UNCHANGED
    write_removed(removed_path, gone, root)
    if hooks or hooks_empty_before(old):
        data["hooks"] = hooks
    else:
        del data["hooks"]
    emit(dumps(data))
    return CHANGED


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(__doc__)
        return USAGE
    path, cmd, args = argv[1], argv[2], argv[3:]
    try:
        data = load(path)
        if cmd == "check":
            hook_groups(data)
            return CHANGED
        if cmd == "empty":
            return CHANGED if data == {} else UNCHANGED
        if cmd == "get" and len(args) == 1:
            return cmd_get(data, args[0])
        if cmd == "set" and len(args) == 2:
            return cmd_set(data, args[0], args[1])
        if cmd == "unset" and len(args) == 1:
            return cmd_unset(data, args[0])
        if cmd == "wire" and len(args) in (4, 5):
            return cmd_wire(data, *args)
        if cmd == "unwire" and len(args) in (2, 3):
            return cmd_unwire(data, *args)
        if cmd == "prune" and len(args) in (1, 2, 3):
            return cmd_prune(data, *args)
    except Stop as exc:
        sys.stderr.write("settings_merge.py: %s\n" % exc.message)
        return exc.code
    except UnicodeEncodeError:
        sys.stderr.write("settings_merge.py: a value cannot be written as UTF-8\n")
        return UNSUPPORTED
    sys.stderr.write("settings_merge.py: bad command line: %s\n" % " ".join(argv[2:]))
    return USAGE


if __name__ == "__main__":
    sys.exit(main(sys.argv))
