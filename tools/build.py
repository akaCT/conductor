#!/usr/bin/env python3
"""build.py - generate install.sh and the Codex agent files from payload/.

Single source of truth: payload/components.json (version, release facts,
component catalog, file catalog) plus the files it lists. Nothing else decides
what ships.

  python3 tools/build.py                  validate, generate, write install.sh
  python3 tools/build.py --check          build in memory; exit 1 naming every
                                          file that differs from the committed copy
  python3 tools/build.py --payload DIR --out FILE
                                          fixture build (tests): payload root DIR,
                                          installer written to FILE (--out is
                                          required with --payload)
  python3 tools/build.py --record-release append the payload hashes of the current
                                          version to installer/prior-hashes.txt
                                          (idempotent), then rebuild

Generated, deterministic, byte-identical on repeat:
  <payload>/codex/agents/<name>.toml      from each Claude agent except the judge
  <payload>/claude/conductor/lib/facts.json
                                          from components.json (facts, update,
                                          report, version)
  <payload>/claude/skills/conductor/VERSION and
  <payload>/codex/skills/conductor/VERSION
  install.sh                              installer/src/*.sh in name order, with the
                                          single line #@@PAYLOAD@@ replaced by the
                                          generated block (release facts, component
                                          and file tables, prior hashes, embedded
                                          helpers, 1 emit_<id> function per file)

Refuses (exit 1, naming the entry or file): an invalid components.json; a payload
file that is not UTF-8, holds a NUL byte, lacks exactly 1 trailing newline or
contains its own embed delimiter line; a version mismatch; an installer whose last
statement is not the single line main "$@" placed after every function.

Exit codes: 0 ok, 1 build failure or drift, 2 usage error.
Python 3.9 standard library only.
"""
import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
from pathlib import Path

try:
    import tomllib  # Python 3.11 and newer
except ImportError:  # 3.9 and 3.10: a minimal parser (below) checks the TOML instead
    tomllib = None

TOOLS_DIR = Path(__file__).resolve().parent
REPO = TOOLS_DIR.parent
DEFAULT_PAYLOAD = REPO / "payload"
INSTALLER_DIR = REPO / "installer"
DEFAULT_OUT = REPO / "install.sh"

PLACEHOLDER = "#@@PAYLOAD@@"
FACTS_REL = "claude/conductor/lib/facts.json"
VERSION_RELS = ("claude/skills/conductor/VERSION", "codex/skills/conductor/VERSION")

ID_RE = re.compile(r"^[a-z0-9_]+$")
SEMVER_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$")
FLOOR_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
ENV_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")
NEEDS_RE = re.compile(r"^[a-z0-9_.+-]+$")
HOST_RE = re.compile(r"^[A-Za-z0-9.-]+$")
URLPATH_RE = re.compile(r"^/[A-Za-z0-9._/@+-]*$")
REPO_RE = re.compile(r"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$")
SELECT_RE = re.compile(r"^([a-z_]+)=([A-Za-z0-9_.-]+)$")
MODE_RE = re.compile(r"^[0-7]{3}$")
EVENT_RE = re.compile(r"^[A-Za-z]+$")
ALIAS_RE = re.compile(r"^[A-Za-z0-9._-]+$")
MODEL_ID_RE = re.compile(r"^[A-Za-z0-9._/:-]+$")
CTRL_RE = re.compile(r"[\x00-\x1f\x7f]")
MARKER_RE = re.compile(r"BEGIN CONDUCTOR \(managed\) v([0-9][0-9A-Za-z.\-]*)")
PRIOR_RE = re.compile(r"^[0-9a-f]{64}  [0-9][0-9A-Za-z.\-]*  (claude|codex):[^\s]+$")

POLICIES = ("replace", "agent", "create-only", "doctrine-block")
HARNESSES = ("claude", "codex")
ROOTS = ("agents_skills",)
EFFORTS = ("low", "medium", "high", "xhigh")
TOP_KEYS = ("version", "update", "report", "facts", "codex_models", "codex_effort",
            "components", "files")
FACT_KEYS = ("floor_opus_pin", "floor_sonnet_pin", "floor_haiku55", "floor_fable",
             "floor_per_call_effort", "provider_vars", "provider_block_vars")
COMPONENT_KEYS = ("default", "describe", "needs", "requires", "kind")
FILE_KEYS = ("id", "src", "harness", "dest", "component", "policy", "mode", "select",
             "also", "root", "wire")
WIRE_KEYS = ("event", "matcher", "args", "timeout")
CODEX_WRITE_TOOLS = ("Edit", "Write", "NotebookEdit")


class BuildError(Exception):
    """A build failure; .lines holds 1 message per problem."""

    def __init__(self, lines):
        Exception.__init__(self, "\n".join(lines))
        self.lines = list(lines)


class Problems:
    def __init__(self):
        self.items = []

    def add(self, msg):
        self.items.append(msg)

    def raise_if(self):
        if self.items:
            raise BuildError(self.items)


def display(rel):
    """How a payload file is named in messages (stable for tests)."""
    return "payload/" + rel


def sq(value):
    """Single-quote a string for bash."""
    return "'" + value.replace("'", "'\\''") + "'"


# ---------------------------------------------------------------- components.json

def load_components(payload_root):
    path = payload_root / "components.json"
    if not path.is_file():
        raise BuildError(["payload/components.json: not found"])
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (ValueError, UnicodeDecodeError) as exc:
        raise BuildError(["payload/components.json: not valid JSON: %s" % exc])


def check_rel_path(value, what, problems):
    if not isinstance(value, str) or not value:
        problems.add("%s: must be a non-empty string" % what)
        return False
    bad = None
    if CTRL_RE.search(value):
        bad = "holds a control character"
    elif "\\" in value:
        bad = "holds a backslash"
    elif value.startswith("/"):
        bad = "is an absolute path"
    elif ".." in value:
        bad = "holds '..'"
    elif value.endswith("/"):
        bad = "ends with '/'"
    if bad:
        problems.add("%s: path '%s' %s" % (what, value, bad))
        return False
    return True


def validate_structure(comp, problems):
    if not isinstance(comp, dict):
        problems.add("payload/components.json: the top level must be an object")
        return
    for key in TOP_KEYS:
        if key not in comp:
            problems.add("payload/components.json: missing key '%s'" % key)
    for key in comp:
        if key not in TOP_KEYS:
            problems.add("payload/components.json: unknown top-level key '%s'" % key)
    if problems.items:
        return

    if not isinstance(comp["version"], str) or not SEMVER_RE.match(comp["version"]):
        problems.add("components.json version: '%s' is not a version like 0.4.0" % (comp["version"],))

    upd = comp["update"]
    if not (isinstance(upd, dict) and set(upd) == {"host", "path"}
            and isinstance(upd["host"], str) and HOST_RE.match(upd["host"])
            and isinstance(upd["path"], str) and URLPATH_RE.match(upd["path"])):
        problems.add("components.json update: needs 'host' (a host name) and 'path' (starting with /)")
    rep = comp["report"]
    if not (isinstance(rep, dict) and set(rep) == {"repo"}
            and isinstance(rep["repo"], str) and REPO_RE.match(rep["repo"])):
        problems.add("components.json report: needs 'repo' as owner/name")

    facts = comp["facts"]
    if not isinstance(facts, dict):
        problems.add("components.json facts: must be an object")
    else:
        for key in FACT_KEYS:
            if key not in facts:
                problems.add("components.json facts: missing '%s'" % key)
        for key in ("floor_opus_pin", "floor_sonnet_pin", "floor_haiku55", "floor_fable",
                    "floor_per_call_effort"):
            if key in facts and not (isinstance(facts[key], str) and FLOOR_RE.match(facts[key])):
                problems.add("components.json facts.%s: '%s' is not a version like 2.1.280" % (key, facts[key]))
        for key in ("provider_vars", "provider_block_vars"):
            if key in facts:
                val = facts[key]
                if not (isinstance(val, list) and val
                        and all(isinstance(v, str) and ENV_RE.match(v) for v in val)):
                    problems.add("components.json facts.%s: needs a non-empty list of variable names" % key)
        if "codex_map_checked_on" in facts and not (isinstance(facts["codex_map_checked_on"], str)
                                                    and DATE_RE.match(facts["codex_map_checked_on"])):
            problems.add("components.json facts.codex_map_checked_on: '%s' is not a date like 2026-10-14"
                         % (facts["codex_map_checked_on"],))

    models = comp["codex_models"]
    if not isinstance(models, dict):
        problems.add("components.json codex_models: must be an object")
    else:
        for alias, model in models.items():
            if not (ALIAS_RE.match(alias) and isinstance(model, str) and MODEL_ID_RE.match(model)):
                problems.add("components.json codex_models: bad entry '%s'" % alias)
    effort = comp["codex_effort"]
    if not isinstance(effort, dict):
        problems.add("components.json codex_effort: must be an object")
    else:
        for seat, val in effort.items():
            if not (ALIAS_RE.match(seat) and isinstance(val, str) and ALIAS_RE.match(val)):
                problems.add("components.json codex_effort: bad entry '%s'" % seat)

    comps = comp["components"]
    if not isinstance(comps, dict) or not comps:
        problems.add("components.json components: must be a non-empty object")
        comps = {}
    for cid, c in comps.items():
        label = "component '%s'" % cid
        if not ID_RE.match(cid):
            problems.add("%s: name must match [a-z0-9_]+" % label)
        if not isinstance(c, dict):
            problems.add("%s: must be an object" % label)
            continue
        for key in c:
            if key not in COMPONENT_KEYS:
                problems.add("%s: unknown key '%s'" % (label, key))
        if not isinstance(c.get("default"), bool):
            problems.add("%s: 'default' must be true or false" % label)
        desc = c.get("describe")
        if not (isinstance(desc, str) and desc and not CTRL_RE.search(desc)):
            problems.add("%s: 'describe' must be a 1-line string" % label)
        for key in ("needs", "requires"):
            val = c.get(key, [])
            if not (isinstance(val, list) and all(isinstance(v, str) and NEEDS_RE.match(v) for v in val)):
                problems.add("%s: '%s' must be a list of names" % (label, key))
        kind = c.get("kind", "")
        if not (isinstance(kind, str) and (kind == "" or ID_RE.match(kind))):
            problems.add("%s: 'kind' must match [a-z0-9_]+" % label)
    for cid, c in comps.items():
        if isinstance(c, dict) and isinstance(c.get("requires", []), list):
            for req in c.get("requires", []):
                if isinstance(req, str) and req not in comps:
                    problems.add("component '%s': requires unknown component '%s'" % (cid, req))

    files = comp["files"]
    if not isinstance(files, list):
        problems.add("components.json files: must be a list")
        return
    ids = {}
    dest_groups = {}
    for i, f in enumerate(files):
        fid = f.get("id") if isinstance(f, dict) else None
        label = "files[%d]" % i + (" (id '%s')" % fid if isinstance(fid, str) else "")
        if not isinstance(f, dict):
            problems.add("%s: must be an object" % label)
            continue
        for key in f:
            if key not in FILE_KEYS:
                problems.add("%s: unknown key '%s'" % (label, key))
        if not (isinstance(fid, str) and ID_RE.match(fid)):
            problems.add("%s: id must match [a-z0-9_]+" % label)
        elif fid in ids:
            problems.add("%s: duplicate id '%s' (also files[%d])" % (label, fid, ids[fid]))
        else:
            ids[fid] = i
        src_ok = check_rel_path(f.get("src"), label + " src", problems)
        dest_ok = check_rel_path(f.get("dest"), label + " dest", problems)
        harness = f.get("harness")
        if harness not in HARNESSES:
            problems.add("%s: unknown harness '%s' (allowed: claude, codex)" % (label, harness))
        if f.get("component") not in comps:
            problems.add("%s: unknown component '%s'" % (label, f.get("component")))
        if f.get("policy") not in POLICIES:
            problems.add("%s: unknown policy '%s' (allowed: %s)" % (label, f.get("policy"), ", ".join(POLICIES)))
        if "mode" in f and not (isinstance(f["mode"], str) and MODE_RE.match(f["mode"])):
            problems.add("%s: mode must be 3 octal digits like 755" % label)
        if "root" in f:
            if f["root"] not in ROOTS:
                problems.add("%s: unknown root '%s' (allowed: agents_skills)" % (label, f["root"]))
            elif harness != "codex":
                problems.add("%s: root agents_skills belongs to codex files only" % label)
        if "select" in f and not (isinstance(f["select"], str) and SELECT_RE.match(f["select"])):
            problems.add("%s: select must look like KEY=VALUE" % label)
        if "also" in f:
            if f.get("policy") != "create-only":
                problems.add("%s: 'also' needs policy create-only" % label)
            check_rel_path(f["also"], label + " also", problems)
        if "wire" in f:
            if harness != "claude":
                problems.add("%s: wire is allowed on claude files only" % label)
            wires = f["wire"]
            if not isinstance(wires, list) or not wires:
                problems.add("%s: wire must be a non-empty list" % label)
                wires = []
            for j, w in enumerate(wires):
                wlabel = "%s wire[%d]" % (label, j)
                if not isinstance(w, dict):
                    problems.add("%s: must be an object" % wlabel)
                    continue
                for key in w:
                    if key not in WIRE_KEYS:
                        problems.add("%s: unknown key '%s'" % (wlabel, key))
                if not (isinstance(w.get("event"), str) and EVENT_RE.match(w["event"])):
                    problems.add("%s: 'event' must be a hook event name" % wlabel)
                for key in ("matcher", "args"):
                    val = w.get(key, "")
                    if not (isinstance(val, str) and not CTRL_RE.search(val)):
                        problems.add("%s: '%s' must be a 1-line string" % (wlabel, key))
                tmo = w.get("timeout")
                if not (isinstance(tmo, int) and not isinstance(tmo, bool) and 1 <= tmo <= 600):
                    problems.add("%s: 'timeout' must be a whole number of seconds from 1 to 600" % wlabel)
        if src_ok and dest_ok and harness in HARNESSES:
            key = (harness, f.get("root", ""), f["dest"])
            dest_groups.setdefault(key, []).append((label, f))
            if "also" in f and isinstance(f["also"], str):
                dest_groups.setdefault((harness, f.get("root", ""), f["also"]), []).append((label + " also", f))
    for key, group in dest_groups.items():
        if len(group) < 2:
            continue
        names = ", ".join(g[0] for g in group)
        selects = [g[1].get("select") for g in group if g[1].get("select")]
        keys = set(s.split("=")[0] for s in selects)
        vals = [s.split("=")[1] for s in selects]
        if len(selects) != len(group) or len(keys) != 1 or len(set(vals)) != len(vals):
            problems.add("dest '%s' is used by %s; sharing a dest needs select entries with the same key and different values"
                         % (key[2], names))


# ---------------------------------------------------------------- payload files

def check_content(data, disp, problems):
    """UTF-8, no NUL, exactly 1 trailing newline."""
    try:
        data.decode("utf-8")
    except UnicodeDecodeError as exc:
        problems.add("%s: not valid UTF-8 (%s)" % (disp, exc.reason))
        return False
    if b"\x00" in data:
        problems.add("%s: contains a NUL byte" % disp)
        return False
    trailing = len(data) - len(data.rstrip(b"\n"))
    if trailing != 1:
        problems.add("%s: must end in exactly 1 trailing newline (found %d)" % (disp, trailing))
        return False
    return True


def read_source(payload_root, rel, problems):
    path = payload_root / rel
    disp = display(rel)
    if path.is_symlink() or not path.is_file():
        problems.add("%s: missing, or not a regular file" % disp)
        return None
    data = path.read_bytes()
    return data if check_content(data, disp, problems) else None


def parse_frontmatter(text):
    lines = text.split("\n")
    if not lines or lines[0] != "---":
        return None
    for k in range(1, len(lines)):
        if lines[k] == "---":
            fm = {}
            for ln in lines[1:k]:
                m = re.match(r"^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$", ln)
                if m:
                    val = m.group(2).strip()
                    if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
                        val = val[1:-1]
                    fm[m.group(1)] = val
            return fm, "\n".join(lines[k + 1:])
    return None


def agent_entries(files):
    return [f for f in files
            if f.get("harness") == "claude" and isinstance(f.get("dest"), str)
            and re.match(r"^agents/[^/]+\.md$", f["dest"])]


# ---------------------------------------------------------------- Codex TOML

def toml_escape(value):
    return value.replace("\\", "\\\\").replace('"', '\\"')


def toml_unescape(value):
    def repl(m):
        ch = m.group(1)
        if ch not in ('\\', '"'):
            raise ValueError("unexpected escape \\%s" % ch)
        return ch
    return re.sub(r"\\(.)", repl, value, flags=re.S)


def minimal_toml_parse(text):
    """Parse only what make_toml writes: key = "x" lines and key = \"\"\" blocks."""
    out = {}
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        if not line:
            i += 1
            continue
        m = re.match(r'^([a-z_]+) = """$', line)
        if m:
            j = i + 1
            buf = []
            while j < len(lines) and lines[j] != '"""':
                buf.append(lines[j])
                j += 1
            if j >= len(lines):
                raise ValueError("unterminated multi-line string")
            out[m.group(1)] = toml_unescape("\n".join(buf)) + "\n"
            i = j + 1
            continue
        m = re.match(r'^([a-z_]+) = "((?:[^"\\]|\\.)*)"$', line)
        if not m:
            raise ValueError("unparseable line %r" % line[:60])
        out[m.group(1)] = toml_unescape(m.group(2))
        i += 1
    return out


def make_toml(name, label, fm, body, models, efforts, problems):
    """Return the TOML text for 1 Claude agent, or None after recording problems."""
    desc = fm.get("description", "")
    alias = fm.get("model", "")
    model = models.get(alias)
    if model is None:
        problems.add("%s: model alias '%s' is not in codex_models (add it, or the build cannot map it)" % (label, alias))
        return None
    body = body.replace(" (Skill tool)", "")
    body = body.replace("Agent tool", "spawn_agent tool")
    # A Claude agent file says which effort it runs at. A Codex agent file has an effort only
    # when components.json names one for the seat, so say that, and not the Claude value.
    if efforts.get(name):
        said = "you run at %s" % efforts[name]
    else:
        said = "your effort is whatever your Codex session or config sets"
    body = re.sub(r"(?<=Effort: )you run at (?:low|medium|high|xhigh)(?=\.)", said, body)
    body = body.lstrip("\n").rstrip("\n")
    if '"""' in body:
        problems.add("%s: the body contains a triple quote, which TOML cannot hold here" % label)
        return None
    for what, text in (("description", desc), ("body", body.replace("\n", "").replace("\t", ""))):
        if CTRL_RE.search(text):
            problems.add("%s: the %s holds a control character" % (label, what))
            return None
    tools = [t.strip() for t in fm.get("tools", "").strip("[]").split(",") if t.strip()]
    readonly = "tools" in fm and not any(t in CODEX_WRITE_TOOLS for t in tools)
    expected = {"name": name, "description": desc, "model": model}
    lines = ['name = "%s"' % toml_escape(name),
             'description = "%s"' % toml_escape(desc),
             'model = "%s"' % toml_escape(model)]
    if efforts.get(name):
        lines.append('model_reasoning_effort = "%s"' % toml_escape(efforts[name]))
        expected["model_reasoning_effort"] = efforts[name]
    if readonly:
        lines.append('sandbox_mode = "read-only"')
        expected["sandbox_mode"] = "read-only"
    lines.append('developer_instructions = """')
    lines.append(toml_escape(body))
    lines.append('"""')
    expected["developer_instructions"] = body + "\n"
    text = "\n".join(lines) + "\n"
    try:
        if minimal_toml_parse(text) != expected:
            raise ValueError("round trip differs")
        if tomllib is not None and tomllib.loads(text) != expected:
            raise ValueError("tomllib round trip differs")
    except ValueError as exc:
        problems.add("%s: generated TOML is not valid (%s)" % (label, exc))
        return None
    return text


# ---------------------------------------------------------------- installer pieces

class Embed:
    def __init__(self, func, delim, disp, data):
        self.func = func
        self.delim = delim
        self.disp = disp
        self.data = data  # bytes, exactly the file


def case_fn(name, entries, default='printf \'%s\' \'\''):
    lines = ["%s() {" % name, '  case "$1" in']
    for key, val in entries:
        lines.append("    %s) printf '%%s' %s ;;" % (key, sq(val)))
    lines.append("    *) %s ;;" % default)
    lines.append("  esac")
    lines.append("}")
    return "\n".join(lines) + "\n"


def generated_block(comp, embeds, changelog_lines):
    version = comp["version"]
    facts = comp["facts"]
    comps = comp["components"]
    files = comp["files"]
    out = []
    w = out.append
    w("# " + "=" * 69)
    w("# GENERATED by tools/build.py from payload/components.json. Do not edit.")
    w("# Rebuild with: python3 tools/build.py")
    w("# " + "=" * 69)
    w("")
    w("# ---- release facts (single source: payload/components.json) ----")
    w("CONDUCTOR_VERSION=%s" % json.dumps(version))
    w('BEGIN_MARKER="<!-- BEGIN CONDUCTOR (managed) v${CONDUCTOR_VERSION} - ${CONDUCTOR_URL} -->"')
    w('END_MARKER="<!-- END CONDUCTOR (managed) -->"')
    w("readonly FLOOR_OPUS_PIN=%s" % sq(facts["floor_opus_pin"]))
    w("readonly FLOOR_SONNET_PIN=%s" % sq(facts["floor_sonnet_pin"]))
    w("readonly FLOOR_HAIKU55=%s" % sq(facts["floor_haiku55"]))
    w("readonly FLOOR_FABLE=%s" % sq(facts["floor_fable"]))
    w("readonly FLOOR_PER_CALL_EFFORT=%s" % sq(facts["floor_per_call_effort"]))
    w("readonly PROVIDER_VARS=%s" % sq(" ".join(facts["provider_vars"])))
    w("readonly PROVIDER_BLOCK_VARS=%s" % sq(" ".join(facts["provider_block_vars"])))
    w("readonly UPDATE_HOST=%s" % sq(comp["update"]["host"]))
    w("readonly UPDATE_PATH=%s" % sq(comp["update"]["path"]))
    w("readonly REPORT_REPO=%s" % sq(comp["report"]["repo"]))
    w("")
    w("# ---- component table (bash 3.2 safe: case functions, no arrays) ----")
    w("# component_default ID      1 or 0")
    w("# component_describe ID     1 line of text")
    w("# component_needs ID        space-separated tools the component needs")
    w("# component_requires ID     space-separated components that must come with it")
    w("# component_kind ID         empty, or hook")
    w("COMPONENT_IDS=%s" % sq(" ".join(comps)))
    out.append(case_fn("component_default", [(k, "1" if v["default"] else "0") for k, v in comps.items()], "printf '0'"))
    out.append(case_fn("component_describe", [(k, v["describe"]) for k, v in comps.items()]))
    out.append(case_fn("component_needs", [(k, " ".join(v.get("needs", []))) for k, v in comps.items() if v.get("needs")]))
    out.append(case_fn("component_requires", [(k, " ".join(v.get("requires", []))) for k, v in comps.items() if v.get("requires")]))
    out.append(case_fn("component_kind", [(k, v["kind"]) for k, v in comps.items() if v.get("kind")]))
    w("# ---- file table ----")
    w("# file_src ID  file_harness ID  file_dest ID  file_component ID  file_policy ID")
    w("# file_mode ID (default 644)  file_also ID  file_root ID (empty, or agents_skills)")
    w("# file_select ID (empty, or KEY=VALUE)  file_wire_count ID")
    w("# file_wire ID N FIELD  (N counts from 1; FIELD is event, matcher, args or timeout)")
    w("# payload_emit ID  writes the payload file bytes to stdout")
    w("FILE_IDS=%s" % sq(" ".join(f["id"] for f in files)))
    out.append(case_fn("file_src", [(f["id"], f["src"]) for f in files]))
    out.append(case_fn("file_harness", [(f["id"], f["harness"]) for f in files]))
    out.append(case_fn("file_dest", [(f["id"], f["dest"]) for f in files]))
    out.append(case_fn("file_component", [(f["id"], f["component"]) for f in files]))
    out.append(case_fn("file_policy", [(f["id"], f["policy"]) for f in files]))
    out.append(case_fn("file_mode", [(f["id"], f.get("mode", "644")) for f in files], "printf '644'"))
    out.append(case_fn("file_also", [(f["id"], f["also"]) for f in files if f.get("also")]))
    out.append(case_fn("file_root", [(f["id"], f["root"]) for f in files if f.get("root")]))
    out.append(case_fn("file_select", [(f["id"], f["select"]) for f in files if f.get("select")]))
    out.append(case_fn("file_wire_count", [(f["id"], str(len(f["wire"]))) for f in files if f.get("wire")], "printf '0'"))
    wire_entries = []
    for f in files:
        for n, wire in enumerate(f.get("wire", []), 1):
            wire_entries.append(("%s:%d:event" % (f["id"], n), wire["event"]))
            wire_entries.append(("%s:%d:matcher" % (f["id"], n), wire.get("matcher", "")))
            wire_entries.append(("%s:%d:args" % (f["id"], n), wire.get("args", "")))
            wire_entries.append(("%s:%d:timeout" % (f["id"], n), str(wire["timeout"])))
    wire_fn = case_fn("file_wire", wire_entries).replace('case "$1" in', 'case "$1:$2:$3" in')
    out.append(wire_fn)
    disp_lines = ["payload_emit() {", '  case "$1" in']
    for e in embeds:
        disp_lines.append("    %s) %s ;;" % (e.func[len("emit_"):], e.func))
    disp_lines += ["    *) return 1 ;;", "  esac", "}"]
    out.append("\n".join(disp_lines) + "\n")
    out.append(data_blocks(files, embeds, changelog_lines))
    return "\n".join(out) + "\n"


def data_blocks(files, embeds, changelog_lines):
    """Comment blocks that `conductor update` reads from the fetched installer as text,
    without running any of it (L1b, REQ-UPD-002). Every line starts with #@@.

    #@@FILE|id|harness|dest|policy|component|root|select|also|sha256 (- for empty),
    1 line per payload file, sha256 of the exact bytes the installer writes; and the
    changelog as #@@| lines. An Installer sha256 line is left out of the embedded
    changelog: a file cannot name its own hash."""
    sha = {}
    for e in embeds:
        sha[e.func[len("emit_"):]] = hashlib.sha256(e.data).hexdigest()
    lines = ["# ---- data blocks read by `conductor update` (comments; nothing here runs) ----",
             "#@@FILES-BEGIN"]
    for f in files:
        lines.append("#@@FILE|%s|%s|%s|%s|%s|%s|%s|%s|%s" % (
            f["id"], f["harness"], f["dest"], f["policy"], f["component"],
            f.get("root", "-"), f.get("select", "-"), f.get("also", "-"), sha.get(f["id"], "-")))
    lines.append("#@@FILES-END")
    lines.append("#@@CHANGELOG-BEGIN")
    for ln in changelog_lines:
        lines.append("#@@| " + ln if ln else "#@@|")
    lines.append("#@@CHANGELOG-END")
    return "\n".join(lines) + "\n"


CHANGELOG_BEGIN = "#@@CHANGELOG-BEGIN"
CHANGELOG_END = "#@@CHANGELOG-END"


def changelog_for_embed(repo_root, existing_install):
    """The CHANGELOG.md lines to embed. A tree without CHANGELOG.md (the copies the
    tests make of tools, installer and payload) keeps the block its install.sh holds."""
    path = repo_root / "CHANGELOG.md"
    if path.is_file():
        text = path.read_text(encoding="utf-8")
        return [ln.rstrip("\r") for ln in text.split("\n")
                if not re.match(r"^\s*Installer sha256:", ln)][:-1 if text.endswith("\n") else None]
    kept = []
    if existing_install.is_file():
        inside = False
        for ln in existing_install.read_text(encoding="utf-8", errors="replace").split("\n"):
            if ln == CHANGELOG_END:
                break
            if inside and ln.startswith("#@@|"):
                kept.append(ln[len("#@@| "):])
            if ln == CHANGELOG_BEGIN:
                inside = True
    return kept


def embed_text(e):
    """The emit function for 1 embedded file as (code before, bytes, code after)."""
    return ("%s() { cat <<'%s'\n" % (e.func, e.delim), e.data.decode("utf-8"), "%s\n}\n\n" % e.delim)


# ---------------------------------------------------------------- the build

class Result:
    pass


def build(payload_root, installer_dir):
    problems = Problems()
    comp = load_components(payload_root)
    validate_structure(comp, problems)
    problems.raise_if()
    files = comp["files"]
    version = comp["version"]

    agents = agent_entries(files)
    toml_rels = {}
    for a in agents:
        if a["dest"] != "agents/judge.md":
            name = a["dest"][len("agents/"):-len(".md")]
            toml_rels["codex/agents/%s.toml" % name] = a
    gen_rels = set(toml_rels) | {FACTS_REL} | set(VERSION_RELS)

    contents = {}
    for f in files:
        src = f["src"]
        if src in gen_rels or src in contents:
            continue
        data = read_source(payload_root, src, problems)
        if data is not None:
            contents[src] = data

    # Claude agent files: model and effort pinned, aliases mappable (REQ-EFF-001, REQ-CDX-001)
    generated = {}
    models = comp["codex_models"]
    efforts = comp["codex_effort"]
    seen_names = {}
    for a in agents:
        disp = display(a["src"])
        data = contents.get(a["src"])
        if data is None:
            continue
        parsed = parse_frontmatter(data.decode("utf-8"))
        if parsed is None:
            problems.add("%s: no frontmatter block" % disp)
            continue
        fm, body = parsed
        if "model" not in fm:
            problems.add("%s: agent file has no model: line" % disp)
        if "effort" not in fm:
            problems.add("%s: agent file has no effort: line (REQ-EFF-001)" % disp)
        elif fm["effort"] not in EFFORTS:
            problems.add("%s: effort: %s is not allowed (use low, medium, high or xhigh; never max)" % (disp, fm["effort"]))
        if a["dest"] == "agents/judge.md":
            continue
        name = a["dest"][len("agents/"):-len(".md")]
        if name in seen_names:
            problems.add("%s: produces the same Codex file as %s" % (disp, seen_names[name]))
            continue
        seen_names[name] = disp
        for key in ("name", "description", "model"):
            if key not in fm:
                problems.add("%s: agent file has no %s: line" % (disp, key))
        if fm.get("name", name) != name:
            problems.add("%s: name: %s does not match the file name %s" % (disp, fm.get("name"), name))
        if all(k in fm for k in ("name", "description", "model")):
            text = make_toml(name, disp, fm, body, models, efforts, problems)
            if text is not None:
                generated["codex/agents/%s.toml" % name] = text.encode("utf-8")

    facts_obj = {"version": version, "update": comp["update"], "report": comp["report"], "facts": comp["facts"]}
    generated[FACTS_REL] = (json.dumps(facts_obj, indent=2, sort_keys=True) + "\n").encode("utf-8")
    for rel in VERSION_RELS:
        generated[rel] = (version + "\n").encode("utf-8")
    for rel, data in generated.items():
        check_content(data, display(rel), problems)
        contents[rel] = data
    for f in files:
        if f["src"] in gen_rels and f["src"] not in generated and f["src"] not in contents:
            problems.add("%s: this path is generated but could not be built (see the messages above)" % display(f["src"]))

    # files under payload/ that components.json does not list would never ship
    if payload_root.is_dir():
        for p in sorted(payload_root.rglob("*")):
            if not p.is_file() and not p.is_symlink():
                continue
            rel = p.relative_to(payload_root).as_posix()
            if rel == "components.json" or any(part.startswith(".") for part in rel.split("/")):
                continue
            if rel not in contents and rel not in gen_rels:
                problems.add("%s: not listed in components.json (it would never ship)" % display(rel))

    # installer fragments, embedded helpers, prior hashes
    frag_dir = installer_dir / "src"
    fragments = []
    for p in sorted(frag_dir.glob("*.sh")):
        data = p.read_bytes()
        disp = "installer/src/" + p.name
        if check_fragment(data, disp, problems):
            fragments.append((p.name, disp, data.decode("utf-8")))
    if not fragments:
        problems.add("installer/src: no fragments found")
    placeholder_hits = sum(1 for _, _, t in fragments for ln in t.split("\n") if ln == PLACEHOLDER)
    if fragments and placeholder_hits != 1:
        problems.add("installer/src: the line %s must appear exactly once (found %d)" % (PLACEHOLDER, placeholder_hits))
    for _, disp, text in fragments:
        for ln in text.split("\n"):
            if re.match(r"^\s*(readonly\s+)?CONDUCTOR_VERSION=", ln):
                problems.add("%s: must not set CONDUCTOR_VERSION (the build owns it)" % disp)
            if ln.strip() in ("BEGIN_MARKER=", "END_MARKER=") or re.match(r"^\s*(BEGIN|END)_MARKER=", ln):
                problems.add("%s: must not set %s (the build owns it)" % (disp, ln.split("=")[0].strip()))

    helper_embeds = []
    py_dir = installer_dir / "py"
    for p in sorted(py_dir.glob("*.py")) if py_dir.is_dir() else []:
        data = p.read_bytes()
        disp = "installer/py/" + p.name
        if check_content(data, disp, problems):
            stem = re.sub(r"[^a-z0-9_]", "_", p.stem.lower())
            helper_embeds.append(Embed("emit_py_" + stem, "CONDUCTOR_EOF_PY_" + stem.upper(), disp, data))
    prior_path = installer_dir / "prior-hashes.txt"
    prior_lines = []
    if prior_path.is_file():
        for n, ln in enumerate(prior_path.read_text(encoding="utf-8").split("\n"), 1):
            if ln == "" or ln.startswith("#"):
                continue
            if not PRIOR_RE.match(ln):
                problems.add("installer/prior-hashes.txt line %d: expected 'sha256  version  harness:dest'" % n)
            prior_lines.append(ln)
    prior_data = ("\n".join(prior_lines) + "\n").encode("utf-8") if prior_lines else b""
    prior_embed = Embed("emit_prior_hashes", "CONDUCTOR_EOF_PRIOR_HASHES", "installer/prior-hashes.txt", prior_data)

    file_embeds = []
    for f in files:
        data = contents.get(f["src"])
        if data is None:
            continue
        file_embeds.append(Embed("emit_" + f["id"], "CONDUCTOR_EOF_" + f["id"].upper(), display(f["src"]), data))
    problems.raise_if()

    all_embeds = file_embeds + helper_embeds + [prior_embed]
    names = {}
    delims = {}
    for e in all_embeds:
        if e.func in names:
            problems.add("%s: function name %s is already used by %s" % (e.disp, e.func, names[e.func]))
        if e.delim in delims:
            problems.add("%s: delimiter %s is already used by %s" % (e.disp, e.delim, delims[e.delim]))
        names[e.func] = e.disp
        delims[e.delim] = e.disp
        if e.data and e.delim in e.data.decode("utf-8").split("\n"):
            problems.add("%s: contains its own embed delimiter line %s" % (e.disp, e.delim))
    for e in all_embeds:
        for _, disp, text in fragments:
            if e.delim in text.split("\n"):
                problems.add("%s: holds the delimiter line %s" % (disp, e.delim))
    for f in files:
        if f["policy"] != "doctrine-block" or f["src"] not in contents:
            continue
        for m in MARKER_RE.finditer(contents[f["src"]].decode("utf-8")):
            if m.group(1) != version:
                problems.add("%s: doctrine marker v%s does not match components.json version %s"
                             % (display(f["src"]), m.group(1), version))
    problems.raise_if()

    # assemble: ("code", text) and ("embed", text) segments
    segments = []
    block = generated_block(comp, file_embeds,
                            changelog_for_embed(installer_dir.parent, installer_dir.parent / "install.sh"))
    payload_parts = [("code", block)]
    for e in file_embeds + helper_embeds + [prior_embed]:
        before, body, after = embed_text(e)
        payload_parts.append(("code", before))
        if body:
            payload_parts.append(("embed", body))
        payload_parts.append(("code", after))
    for _, disp, text in fragments:
        if PLACEHOLDER in text.split("\n"):
            lines = text.split("\n")
            idx = lines.index(PLACEHOLDER)
            head = "\n".join(lines[:idx]) + ("\n" if idx else "")
            tail = "\n".join(lines[idx + 1:])
            if head:
                segments.append(("code", head))
            segments.extend(payload_parts)
            if tail:
                segments.append(("code", tail))
        else:
            segments.append(("code", text))
    text = "".join(t for _, t in segments)

    final_checks(version, segments, text, problems)
    problems.raise_if()

    res = Result()
    res.comp = comp
    res.version = version
    res.generated = generated
    res.contents = contents
    res.embeds = all_embeds
    res.file_embeds = file_embeds
    res.install_bytes = text.encode("utf-8")
    res.prior_lines = prior_lines
    return res


def check_fragment(data, disp, problems):
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        problems.add("%s: not valid UTF-8 (%s)" % (disp, exc.reason))
        return False
    if b"\x00" in data:
        problems.add("%s: contains a NUL byte" % disp)
        return False
    if not text.endswith("\n"):
        problems.add("%s: must end with a newline" % disp)
        return False
    return True


def final_checks(version, segments, text, problems):
    """Version agreement and the last-statement rule (REQ-INS-001.3, REQ-INS-001.5).

    Only lines the build or a fragment wrote count ("code"); the bodies of embedded
    payload files are data and may hold any text, including a line main "$@"."""
    if not text.startswith("#!"):
        problems.add("install.sh: the first fragment must start with a shebang line")
    code_lines = []
    pos = 0
    for kind, seg in segments:
        lines = seg.split("\n")
        if seg.endswith("\n"):
            lines = lines[:-1]
        if kind == "code":
            for k, ln in enumerate(lines):
                code_lines.append((pos + k, ln))
        pos += len(lines)
    ver_lines = [ln for _, ln in code_lines if re.match(r"^\s*(readonly\s+)?CONDUCTOR_VERSION=", ln)]
    if ver_lines != ['CONDUCTOR_VERSION="%s"' % version]:
        problems.add("install.sh: CONDUCTOR_VERSION lines %r do not match components.json version %s" % (ver_lines, version))
    begin = [ln for _, ln in code_lines if ln.startswith("BEGIN_MARKER=")]
    if begin != ['BEGIN_MARKER="<!-- BEGIN CONDUCTOR (managed) v${CONDUCTOR_VERSION} - ${CONDUCTOR_URL} -->"']:
        problems.add("install.sh: the doctrine marker line does not carry CONDUCTOR_VERSION")
    all_lines = text.split("\n")
    if all_lines and all_lines[-1] == "":
        all_lines.pop()
    if not all_lines or all_lines[-1] != 'main "$@"':
        problems.add('install.sh: the last statement must be the single line main "$@"')
        return
    mains = [n for n, ln in code_lines if re.match(r'^\s*main\s+"\$@"\s*$', ln)]
    if mains != [len(all_lines) - 1]:
        problems.add('install.sh: main "$@" must appear exactly once, on the last line (found at lines %s)'
                     % ", ".join(str(n + 1) for n in mains))


# ---------------------------------------------------------------- output and checks

def atomic_write_bytes(path, data, mode):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".build-tmp-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
        os.chmod(tmp, mode)
        os.replace(tmp, str(path))
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def write_outputs(res, payload_root, out_path):
    wrote = []
    for rel, data in sorted(res.generated.items()):
        path = payload_root / rel
        if not path.is_file() or path.read_bytes() != data:
            atomic_write_bytes(path, data, 0o644)
            wrote.append(display(rel))
    if not out_path.is_file() or out_path.read_bytes() != res.install_bytes:
        atomic_write_bytes(out_path, res.install_bytes, 0o755)
        wrote.append(out_path.name)
    return wrote


EMIT_RE = re.compile(r"^(emit_[A-Za-z0-9_]+)\(\) \{ cat <<'(CONDUCTOR_EOF_[A-Z0-9_]+)'$")


def embedded_bodies(text):
    bodies = {}
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        m = EMIT_RE.match(lines[i])
        if m:
            j = i + 1
            while j < len(lines) and lines[j] != m.group(2):
                j += 1
            bodies[m.group(1)] = "\n".join(lines[i + 1:j]) + "\n" if j > i + 1 else ""
            i = j + 1
        else:
            i += 1
    return bodies


def check_outputs(res, payload_root, out_path):
    drift = []
    for rel, data in sorted(res.generated.items()):
        path = payload_root / rel
        if not path.is_file():
            drift.append((display(rel), "is missing; run python3 tools/build.py"))
        elif path.read_bytes() != data:
            drift.append((display(rel), "differs from a fresh build"))
    committed = out_path.read_bytes() if out_path.is_file() else None
    if committed is None:
        drift.append((out_path.name, "is missing; run python3 tools/build.py"))
    elif committed != res.install_bytes:
        bodies = embedded_bodies(committed.decode("utf-8", "replace"))
        named = False
        for e in res.embeds:
            want = e.data.decode("utf-8")
            if e.func not in bodies:
                drift.append((e.disp, "is not embedded in %s" % out_path.name))
                named = True
            elif bodies[e.func] != want:
                drift.append((e.disp, "differs from the copy embedded in %s" % out_path.name))
                named = True
        drift.append((out_path.name, "differs from a fresh build%s"
                      % ("" if named else " (components.json, installer fragments or prior-hashes changed)")))
    return drift


def record_release(payload_root):
    res = build(payload_root, INSTALLER_DIR)
    prior_path = INSTALLER_DIR / "prior-hashes.txt"
    existing = prior_path.read_text(encoding="utf-8") if prior_path.is_file() else ""
    have = set(existing.split("\n"))
    added = []
    for f in res.comp["files"]:
        data = res.contents[f["src"]]
        sha = hashlib.sha256(data).hexdigest()
        dests = [f["dest"]] + ([f["also"]] if f.get("also") else [])
        for dest in dests:
            line = "%s  %s  %s:%s" % (sha, res.version, f["harness"], dest)
            if line not in have:
                have.add(line)
                added.append(line)
    if added:
        text = existing if existing.endswith("\n") or not existing else existing + "\n"
        atomic_write_bytes(prior_path, (text + "\n".join(added) + "\n").encode("utf-8"), 0o644)
    return added


def main(argv=None):
    ap = argparse.ArgumentParser(prog="build.py", description="Build install.sh and the Codex agent files from payload/.")
    ap.add_argument("--check", action="store_true", help="build in memory; exit 1 naming each file that differs")
    ap.add_argument("--payload", metavar="DIR", help="fixture payload root (needs --out)")
    ap.add_argument("--out", metavar="FILE", help="where to write the installer (default: install.sh)")
    ap.add_argument("--record-release", action="store_true",
                    help="append the current payload hashes to installer/prior-hashes.txt, then rebuild")
    args = ap.parse_args(argv)
    if args.payload and not args.out:
        ap.error("--payload needs --out so a fixture build can never overwrite install.sh")
    if args.record_release and (args.check or args.payload or args.out):
        ap.error("--record-release cannot be combined with --check, --payload or --out")
    payload_root = Path(args.payload).resolve() if args.payload else DEFAULT_PAYLOAD
    out_path = Path(args.out).resolve() if args.out else DEFAULT_OUT

    try:
        if args.record_release:
            added = record_release(payload_root)
            print("build.py: recorded %d hash line(s) in installer/prior-hashes.txt" % len(added))
        res = build(payload_root, INSTALLER_DIR)
    except BuildError as exc:
        for line in exc.lines:
            print("build.py: FAIL  %s" % line, file=sys.stderr)
        print("build.py: build failed (%d problem(s))" % len(exc.lines), file=sys.stderr)
        return 1

    if args.check:
        drift = check_outputs(res, payload_root, out_path)
        if drift:
            for name, why in drift:
                print("DRIFT  %s  %s" % (name, why))
            print("build.py --check: %d file(s) out of sync; run python3 tools/build.py" % len(drift))
            return 1
        print("OK     build is in sync: %s (%d embedded files, version %s, sha256 %s)"
              % (out_path.name, len(res.embeds), res.version, hashlib.sha256(res.install_bytes).hexdigest()[:12]))
        return 0

    wrote = write_outputs(res, payload_root, out_path)
    print("build.py: version %s, %d embedded files, %d lines; wrote %d file(s)%s"
          % (res.version, len(res.embeds), res.install_bytes.count(b"\n"), len(wrote),
             (": " + ", ".join(wrote)) if wrote else " (nothing changed)"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
