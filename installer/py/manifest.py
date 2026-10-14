#!/usr/bin/env python3
"""Conductor installer helper: read and write the install manifest.

The installer runs it as "$PY" "$tmp" MANIFEST COMMAND [ARGS] from a mode 600
temp copy. Python 3.9 standard library only. Every write goes through a temp
file in the manifest's folder and an atomic rename, so an interrupted write
leaves the previous complete manifest in place. A write that changes nothing
(apart from the update time) writes nothing.

Commands (MANIFEST is the path of conductor/.install-manifest):
  init KEY=VALUE...          create the manifest when it is absent; never
                             changes an existing one
  set KEY JSON               set a top-level key to a JSON value
  get KEY                    print a value: text as is, a list of text 1 item
                             per line, anything else as JSON; null prints nothing
  add-file DEST ROOT SHA256 POLICY COMPONENT ID
                             add or replace a file entry (ROOT is - or a root key)
  add-files FILE             add or replace the file entries listed in FILE, 1 per
                             line, tab separated as list-files shows them (ROOT -
                             for none); 1 write for all
  set-many KEY JSON ...      set several top-level keys in 1 write
  rm-file DEST ROOT          drop a file entry
  list-files                 dest, root, sha256, policy, component, id (tab separated)
  pin-record KEY VALUE PREV PRESENT
                             record a settings key Conductor changed; the first
                             recorded previous value is kept on later calls
  pin-forget KEY             drop a pin record
  list-pins                  key, value, previous, previous_present (tab separated)
  list-add KEY TEXT          add TEXT to a list of text at a top-level key
  list-del KEY TEXT          remove TEXT from it
  hooks-set FILE             replace the hooks list with the JSON list in FILE
  list-hooks                 id, event, matcher, command, timeout (tab separated)
  sub-set KEY SUBKEY JSON    set a key inside an object value (legacy_030)
  check                      exit 0 when the file parses as a Conductor manifest

Exit codes: 0 ok, 2 usage or no manifest, 3 manifest unreadable.
"""
import datetime
import json
import os
import sys
import tempfile

SCHEMA = 1
KEY_ORDER = [
    "schema", "product", "method", "version", "source_url", "installed_at",
    "updated_at", "installer_sha256", "harness", "components", "launcher",
    "python3", "files", "doctrine_block", "doctrine_file", "hooks_wired", "hooks", "pins",
    "env_written", "judge_rung", "legacy_030", "shared_with", "agents_skills_existed",
]
ENTRY_LISTS = ("files", "hooks", "pins")


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def default_manifest():
    return {
        "schema": SCHEMA,
        "product": "conductor",
        "method": "installer",
        "version": "",
        "source_url": "",
        "installed_at": now(),
        "updated_at": now(),
        "installer_sha256": None,
        "harness": "claude",
        "components": ["core"],
        "launcher": None,
        "python3": None,
        "files": [],
        "doctrine_block": False,
        "hooks_wired": False,
        "hooks": [],
        "pins": [],
        "env_written": [],
        "judge_rung": None,
        "legacy_030": {
            "claude_md_patched": False,
            "codex_agents_md_patched": False,
            "settings_model_set": None,
        },
        "shared_with": [],
    }


def dumps(m):
    """1 key per line; every file, hook and pin entry on a line of its own, so a
    shell without python can read it with grep and sed."""
    keys = [k for k in KEY_ORDER if k in m] + [k for k in m if k not in KEY_ORDER]
    out = ["{"]
    for i, k in enumerate(keys):
        comma = "," if i < len(keys) - 1 else ""
        v = m[k]
        if k in ENTRY_LISTS and isinstance(v, list) and v:
            out.append('  "%s": [' % k)
            for j, e in enumerate(v):
                out.append("    " + json.dumps(e, ensure_ascii=False) + ("," if j < len(v) - 1 else ""))
            out.append("  ]" + comma)
        else:
            out.append("  %s: %s%s" % (json.dumps(k), json.dumps(v, ensure_ascii=False), comma))
    out.append("}")
    return "\n".join(out) + "\n"


class Unreadable(Exception):
    pass


def load(path):
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise Unreadable(str(exc))
    try:
        m = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as exc:
        raise Unreadable("not valid JSON: %s" % exc)
    if not isinstance(m, dict) or m.get("schema") != SCHEMA or m.get("product") != "conductor":
        raise Unreadable("not a Conductor manifest")
    for k in ENTRY_LISTS:
        if k in m and not isinstance(m[k], list):
            raise Unreadable("%s is not a list" % k)
    return m


def write_atomic(path, text):
    folder = os.path.dirname(path) or "."
    os.makedirs(folder, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".manifest-tmp.", dir=folder)  # mode 600
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def strip_time(m):
    return {k: v for k, v in m.items() if k != "updated_at"}


def save(path, m, orig):
    if orig is not None and strip_time(m) == strip_time(orig):
        return
    if orig is not None:
        m["updated_at"] = now()
    write_atomic(path, dumps(m))


def parse_json(text):
    try:
        return json.loads(text)
    except ValueError:
        sys.stderr.write("manifest.py: not valid JSON: %s\n" % text[:60])
        sys.exit(2)


def root_key(value):
    return None if value in ("", "-") else value


def same_entry(e, dest, root):
    return isinstance(e, dict) and e.get("dest") == dest and e.get("root") == root


def show(v):
    if v is None:
        return ""
    if isinstance(v, str):
        return v
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, list) and all(isinstance(x, str) for x in v):
        return "\n".join(v)
    return json.dumps(v, ensure_ascii=False)


def tab(*fields):
    return "\t".join("" if f is None else str(f) for f in fields)


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(__doc__)
        return 2
    path, cmd, args = argv[1], argv[2], argv[3:]
    try:
        orig = load(path)
    except Unreadable as exc:
        if cmd == "check":
            sys.stderr.write("manifest.py: %s: %s\n" % (path, exc))
        else:
            sys.stderr.write("manifest.py: manifest unreadable (%s)\n" % exc)
        return 3
    if cmd == "check":
        return 0 if orig is not None else 2
    if cmd == "init":
        if orig is not None:
            return 0
        m = default_manifest()
        for a in args:
            k, _, v = a.partition("=")
            if k in ("version", "source_url", "harness", "launcher", "python3", "installer_sha256"):
                m[k] = v or None
            elif k == "judge_rung" and v:
                m[k] = int(v)
            elif k == "components":
                m[k] = [x for x in v.split(",") if x]
        save(path, m, None)
        return 0
    if orig is None:
        sys.stderr.write("manifest.py: no manifest at %s\n" % path)
        return 2
    m = json.loads(json.dumps(orig))  # deep copy
    if cmd == "get":
        sys.stdout.write(show(m.get(args[0])) + ("\n" if m.get(args[0]) is not None else ""))
        return 0
    if cmd == "list-files":
        for e in m.get("files", []):
            sys.stdout.write(tab(e.get("dest"), e.get("root"), e.get("sha256"), e.get("policy"),
                                 e.get("component"), e.get("id")) + "\n")
        return 0
    if cmd == "list-pins":
        for e in m.get("pins", []):
            sys.stdout.write(tab(e.get("key"), json.dumps(e.get("value")), json.dumps(e.get("previous")),
                                 "1" if e.get("previous_present") else "0") + "\n")
        return 0
    if cmd == "list-hooks":
        for e in m.get("hooks", []):
            sys.stdout.write(tab(e.get("id"), e.get("event"), e.get("matcher"), e.get("command"),
                                 e.get("timeout")) + "\n")
        return 0
    if cmd == "set":
        m[args[0]] = parse_json(args[1])
    elif cmd == "sub-set":
        sub = m.get(args[0])
        if not isinstance(sub, dict):
            sub = {}
        sub[args[1]] = parse_json(args[2])
        m[args[0]] = sub
    elif cmd == "set-many":
        if len(args) % 2:
            sys.stderr.write("manifest.py: set-many needs KEY JSON pairs\n")
            return 2
        for i in range(0, len(args), 2):
            m[args[i]] = parse_json(args[i + 1])
    elif cmd in ("add-file", "add-files"):
        rows = [args[:6]]
        if cmd == "add-files":
            with open(args[0], "r", encoding="utf-8") as fh:
                rows = [ln.rstrip("\n").split("\t") for ln in fh if ln.strip()]
        files = list(m["files"])
        for row in rows:
            dest, root, sha, policy, component, fid = row[:6]
            entry = {"dest": dest, "sha256": sha, "policy": policy, "component": component, "id": fid}
            if root_key(root):
                entry["root"] = root
            for i, e in enumerate(files):
                if same_entry(e, dest, root_key(root)):
                    files[i] = entry
                    break
            else:
                files.append(entry)
        m["files"] = files
    elif cmd == "rm-file":
        m["files"] = [e for e in m["files"] if not same_entry(e, args[0], root_key(args[1]))]
    elif cmd == "pin-record":
        key, value, prev, present = args[:4]
        pins = [e for e in m["pins"] if e.get("key") != key]
        old = [e for e in m["pins"] if e.get("key") == key]
        entry = {"key": key, "value": parse_json(value),
                 "previous": parse_json(prev), "previous_present": present == "1"}
        if old:  # a re-run keeps the value from before Conductor's first change
            entry["previous"] = old[0].get("previous")
            entry["previous_present"] = old[0].get("previous_present", False)
        pins.append(entry)
        m["pins"] = pins
    elif cmd == "pin-forget":
        m["pins"] = [e for e in m["pins"] if e.get("key") != args[0]]
    elif cmd in ("list-add", "list-del"):
        cur = m.get(args[0])
        cur = list(cur) if isinstance(cur, list) else []
        if cmd == "list-add" and args[1] not in cur:
            cur.append(args[1])
        if cmd == "list-del":
            cur = [x for x in cur if x != args[1]]
        m[args[0]] = cur
    elif cmd == "hooks-set":
        try:
            with open(args[0], "r", encoding="utf-8") as fh:
                data = json.load(fh)
        except (OSError, ValueError):
            sys.stderr.write("manifest.py: cannot read the hook list from %s\n" % args[0])
            return 2
        if not isinstance(data, list):
            return 2
        m["hooks"] = data
    else:
        sys.stderr.write("manifest.py: unknown command %s\n" % cmd)
        return 2
    save(path, m, orig)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
