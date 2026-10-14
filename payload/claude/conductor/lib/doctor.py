#!/usr/bin/env python3
"""Conductor doctor and install-record helpers. Python 3.9, standard library only.

  doctor.py [doctor]        print what this install looks like: reads files and the
                            environment and asks claude and codex for their version
                            numbers; makes no network call, never prints a key
  doctor.py record-info     key=value lines about the install record (for the launcher)
  doctor.py update-preview  what an update would change, read from the text of a
                            fetched installer without running any of it
  doctor.py record-sha      record the sha256 of the installer an update ran

report.py imports this module, so the bug report and the doctor read the same facts.
Exit codes: 0 (warnings do not fail the doctor), 1 when its own inputs cannot be read
(the facts file, or an install record that exists but cannot be parsed), 2 usage error.
"""
import argparse
import hashlib
import json
import os
import re
import shlex
import stat
import subprocess
import sys
import tempfile
import textwrap

MAX_READ = 5 * 1024 * 1024
HOOK_NAMES = (
    ("session-start-pointer", "pointer"),
    ("checkpoint-nudge", "nudge"),
    ("usage-split-check", "usage-split"),
    ("project-home-check", "project-home"),
    ("contract-check", "contract"),
)
SEATS = (("conductor", "opus"), ("builder", "sonnet"), ("scout", "haiku"),
         ("critic", "sonnet"), ("architect", "opus"), ("judge", ""))
KNOWN_ALIASES = ("opus", "sonnet", "haiku", "fable", "inherit")
ALIAS_FLOOR = {
    "opus": ("Opus 5.5", "floor_opus_pin"),
    "sonnet": ("Sonnet 5.5", "floor_sonnet_pin"),
    "haiku": ("Haiku 5.5", "floor_haiku55"),
    "fable": ("Fable 5.1", "floor_fable"),
}
PIN_MODELS = {"opus": "claude-opus-5-5", "sonnet": "claude-sonnet-5-5"}
EFFORTS = ("low", "medium", "high", "xhigh")
TABLE_KEYS = {
    "bedrock": ("bedrock",),
    "vertex": ("vertex", "agent-platform", "google-cloud-agent-platform"),
    "foundry": ("foundry",),
    "anthropic-aws": ("anthropic-aws", "claude-platform-on-aws", "aws-claude-platform"),
    "mantle": ("mantle", "bedrock-mantle"),
}
OVERRIDE_ENV = ("CLAUDE_CODE_SUBAGENT_MODEL", "ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL",
                "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL")
MANAGED_SETTINGS = {
    "darwin": "/Library/Application Support/ClaudeCode/managed-settings.json",
    "linux": "/etc/claude-code/managed-settings.json",
}

SECRET_RES = [re.compile(p) for p in (
    r"-----BEGIN [A-Z ]*PRIVATE KEY-----",
    r"sk-[A-Za-z0-9_-]{16,}",
    r"[sr]k_live_[A-Za-z0-9]+",
    r"gh[pousr]_[A-Za-z0-9]{16,}",
    r"github_pat_[A-Za-z0-9_]{16,}",
    r"xox[baprs]-[A-Za-z0-9-]{8,}",
    r"AKIA[0-9A-Z]{16}",
    r"eyJ[A-Za-z0-9_-]{4,}\.eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]+",
    r"AIza[0-9A-Za-z_-]{30,}",
    r"[A-Za-z0-9+/_=-]{40,}",
)]
# C0 and C1 controls, plus the invisible format characters that can reorder or hide
# printed text: the Arabic letter mark, zero width marks, bidirectional embeddings and
# isolates, the word joiner family, the line and paragraph separators, the byte order
# mark and the tag characters (U+E0000 to U+E007F). The installer's sanitize_text and
# ledger-append strip the same set.
CTRL_RE = re.compile("[\x00-\x08\x0b-\x1f\x7f\x80-\x9f\u061c\u200b-\u200f\u2028-\u202e\u2060-\u2069\ufeff\U000e0000-\U000e007f]")
SAFE_VALUE_RE = re.compile(r"^[A-Za-z0-9._:\[\]-]{1,80}$")
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
PIN_COMMAND = ("curl --proto '=https' --tlsv1.2 -fsSL https://conductorskill.com/install.sh"
               " | bash -s -- --apply-effort-pins")


# The hook kill switch. The hooks read CONDUCTOR_HOOKS by the same rule (hooks_off in
# payload/claude/conductor/hooks/hooklib.py); tests/test-review-fixes.sh runs both on the same
# list of values.
OFF_VALUES = ("off", "0", "false")


def hooks_switch_off(env):
    return str(env.get("CONDUCTOR_HOOKS", "")).strip().lower() in OFF_VALUES


def hooks_switch_set(env):
    """True when CONDUCTOR_HOOKS holds a value that is not blank."""
    return str(env.get("CONDUCTOR_HOOKS", "")).strip() != ""


class FactsError(Exception):
    pass


# ---------------------------------------------------------------- small helpers

def clean(text, limit=300):
    """Text taken from a file: drop C0 and C1 control characters (newline and tab stay out
    too, since this is for 1 line), and cap the length."""
    text = CTRL_RE.sub("", str(text)).replace("\n", " ").replace("\t", " ")
    return text[:limit]


def looks_secret(value):
    return isinstance(value, str) and any(r.search(value) for r in SECRET_RES)


def looks_path(value):
    return isinstance(value, str) and ("/" in value or "\\" in value or value.startswith("~"))


def display_value(value):
    """A value from the user's files, safe to print: never a key, never free text."""
    if value is None:
        return "not set"
    if not isinstance(value, str):
        value = json.dumps(value) if isinstance(value, (int, float, bool)) else "set"
    if looks_secret(value):
        return "key present"
    if SAFE_VALUE_RE.match(value):
        return value
    return "set (not shown)"


def read_text(path, limit=MAX_READ):
    """(text, state) with state ok, missing or unreadable. Refuses a non-regular file."""
    try:
        st = os.stat(path)
    except FileNotFoundError:
        return None, "missing"
    except OSError:
        return None, "unreadable"
    if not stat.S_ISREG(st.st_mode):
        return None, "unreadable"
    try:
        with open(path, "rb") as fh:
            data = fh.read(limit + 1)
    except OSError:
        return None, "unreadable"
    if len(data) > limit:
        return None, "unreadable"
    try:
        return data.decode("utf-8"), "ok"
    except UnicodeDecodeError:
        return None, "unreadable"


def read_json(path):
    text, state = read_text(path)
    if state != "ok":
        return None, state
    try:
        return json.loads(text), "ok"
    except ValueError:
        return None, "unparseable"


def vtuple(version):
    if not isinstance(version, str) or not VERSION_RE.match(version):
        return None
    return tuple(int(p) for p in version.split("."))


def version_ge(a, b):
    ta, tb = vtuple(a), vtuple(b)
    return ta is not None and tb is not None and ta >= tb


def parse_frontmatter(text):
    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        return None
    out = {}
    for ln in lines[1:]:
        if ln.strip() == "---":
            return out
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$", ln)
        if m:
            val = m.group(2).strip()
            if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
                val = val[1:-1]
            out[m.group(1)] = val
    return None


# ---------------------------------------------------------------- facts and roots

def load_facts(path):
    obj, state = read_json(path)
    if state != "ok" or not isinstance(obj, dict) or not isinstance(obj.get("facts"), dict):
        raise FactsError("Conductor's own facts file cannot be read (%s): %s" % (state, clean(path)))
    return obj


def default_roots(env, self_root, overrides):
    home = env.get("HOME") or os.path.expanduser("~")
    claude = overrides.get("claude") or env.get("CLAUDE_DIR") or env.get("CLAUDE_CONFIG_DIR") or os.path.join(home, ".claude")
    codex = overrides.get("codex") or env.get("CODEX_DIR") or env.get("CODEX_HOME") or os.path.join(home, ".codex")
    agents = overrides.get("agents") or env.get("AGENTS_SKILLS_DIR") or os.path.join(home, ".agents")
    if self_root and not overrides.get("claude") and not overrides.get("codex"):
        obj, state = read_json(os.path.join(self_root, "conductor", ".install-manifest"))
        if state == "ok" and isinstance(obj, dict):
            if obj.get("harness") == "codex":
                codex = self_root
            else:
                claude = self_root
    return {"claude": claude, "codex": codex, "agents": agents}


def read_record(root, harness):
    """The install record of 1 root: ('v04', dict), ('v030', info), ('unreadable', None) or ('none', None)."""
    mpath = os.path.join(root, "conductor", ".install-manifest")
    if os.path.lexists(mpath):
        obj, state = read_json(mpath)
        if state == "ok" and isinstance(obj, dict):
            return "v04", obj
        return "unreadable", None
    old = os.path.join(root, "skills", "conductor", ".install-manifest") if harness == "claude" \
        else os.path.join(root, ".conductor-manifest")
    text, state = read_text(old)
    if state == "ok":
        first = text.split("\n", 1)[0]
        m = re.match(r"^# conductor install manifest v([0-9][0-9A-Za-z.\-]*)", first)
        entries = [ln for ln in text.split("\n") if ln and not ln.startswith("#")]
        return "v030", {"version": m.group(1) if m else "0.3.0", "entries": len(entries)}
    return "none", None


def pick_record(claude_rec, codex_rec):
    """The record the launcher acts on: a readable 0.4 record (Claude first), else unreadable,
    else an old one, else none."""
    recs = [("claude",) + claude_rec, ("codex",) + codex_rec]
    for h, kind, data in recs:
        if kind == "v04":
            return h, kind, data
    for h, kind, data in recs:
        if kind == "unreadable":
            return h, kind, data
    for h, kind, data in recs:
        if kind == "v030":
            return h, kind, data
    return "", "none", None


# ---------------------------------------------------------------- the install picture

def settings_files(claude_root, cwd, managed_override):
    """(label, path) for the user, project, local and managed settings files."""
    out = [("user", os.path.join(claude_root, "settings.json")),
           ("project", os.path.join(cwd, ".claude", "settings.json")),
           ("local", os.path.join(cwd, ".claude", "settings.local.json"))]
    if managed_override:
        out.append(("managed", managed_override))
    else:
        managed = MANAGED_SETTINGS.get("darwin" if sys.platform == "darwin" else "linux" if sys.platform.startswith("linux") else "")
        if managed:
            out.append(("managed", managed))
    return out


def detect_claude_version(env):
    try:
        res = subprocess.run(["claude", "--version"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             timeout=5, env=env, universal_newlines=True)
    except (OSError, subprocess.SubprocessError):
        return None, None
    first = (res.stdout or "").strip().split("\n", 1)[0]
    m = re.match(r"^([0-9]+\.[0-9]+\.[0-9]+)( \(Claude Code\))?$", first)
    return (m.group(1) if m else None), first


def detect_codex_version(env):
    try:
        res = subprocess.run(["codex", "--version"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             timeout=5, env=env, universal_newlines=True)
    except (OSError, subprocess.SubprocessError):
        return None, None
    first = (res.stdout or "").strip().split("\n", 1)[0]
    m = re.match(r"^(?:codex-cli )?([0-9]+\.[0-9]+\.[0-9]+)$", first)
    return (m.group(1) if m else None), first


def detect_provider(env, settings, facts):
    """(provider, set_by). The first-party API only when no provider variable, no base URL
    and no host-managed switch is set (an empty string is unset)."""
    pvars = list(facts["facts"].get("provider_vars", []))
    bvars = list(facts["facts"].get("provider_block_vars", []))

    def nonempty(v):
        return v is not None and str(v) != ""

    def custom_base_url(v):
        # The vendor's own address (any letter case, 1 optional trailing slash) is
        # first-party, the same rule the installer's provider gate uses.
        if not nonempty(v):
            return False
        u = str(v).lower()
        if u.endswith("/"):
            u = u[:-1]
        return u != "https://api.anthropic.com"

    def name_of(var):
        return var[len("CLAUDE_CODE_USE_"):].lower().replace("_", "-") if var.startswith("CLAUDE_CODE_USE_") else var.lower()

    managed = nonempty(env.get("CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST"))
    for var in pvars:
        if nonempty(env.get(var)):
            return name_of(var), var
    settings_unreadable = False
    for label, state, obj in settings:
        if state in ("unreadable", "unparseable"):
            settings_unreadable = True
            continue
        if state != "ok" or not isinstance(obj, dict) or managed:
            continue
        block = obj.get("env")
        if isinstance(block, dict):
            for var in pvars:
                if nonempty(block.get(var)):
                    return name_of(var), var
    if managed:
        return "host-managed", "CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST"
    if custom_base_url(env.get("ANTHROPIC_BASE_URL")):
        return "custom-base-url", "ANTHROPIC_BASE_URL"
    for label, state, obj in settings:
        if state == "ok" and isinstance(obj, dict) and isinstance(obj.get("env"), dict) \
                and custom_base_url(obj["env"].get("ANTHROPIC_BASE_URL")):
            return "custom-base-url", "ANTHROPIC_BASE_URL"
    if settings_unreadable:
        return "unknown", ""
    return "first-party", ""


def expected_model(alias, provider, cc_version, facts):
    """(label for the bundle, text for the doctor)."""
    if alias not in ALIAS_FLOOR:
        return "unknown", "unknown"
    label, floor_key = ALIAS_FLOOR[alias]
    vendor = facts["facts"].get("vendor_alias_table") or facts.get("vendor_alias_table")
    if provider != "first-party":
        if provider in TABLE_KEYS and isinstance(vendor, dict):
            for key in TABLE_KEYS[provider]:
                row = vendor.get(key) or vendor.get(key.replace("-", "_"))
                if isinstance(row, dict) and isinstance(row.get(alias), str) and row[alias].strip():
                    return row[alias].strip(), "%s (%s table)" % (row[alias].strip(), provider)
        if provider == "unknown":
            return "unknown", "unknown (the provider could not be identified)"
        return "unknown", "unknown on %s (no table entry)" % provider
    if isinstance(vendor, dict) and isinstance(vendor.get("first-party"), dict) \
            and isinstance(vendor["first-party"].get(alias), str):
        v = vendor["first-party"][alias].strip()
        return v, v
    floor = facts["facts"].get(floor_key)
    if cc_version is None:
        return "unknown", "%s if Claude Code is %s or later" % (label, floor)
    if version_ge(cc_version, floor):
        return label, label
    return "older model", "an older model (Claude Code below %s)" % floor


def default_effort_applies(info, alias):
    """True when a seat on this alias, with no pin and no effort variable, runs at the model's
    default effort (medium on Opus 5.5 and Sonnet 5.5): the runtime meets the alias's floor and
    the provider is first-party. Not claimed for any other alias or when an effort is set
    outside the user pins."""
    if alias not in PIN_MODELS or info["provider"] != "first-party":
        return False
    if info["effort_env"] or info["effort_elsewhere"]:
        return False
    floor = info["facts"]["facts"].get(ALIAS_FLOOR[alias][1])
    return bool(info["claude_version"]) and version_ge(info["claude_version"], floor)


def collect(args, env=None, cwd=None):
    """Everything the doctor and the bug report need, as plain data."""
    env = dict(os.environ if env is None else env)
    cwd = cwd or os.getcwd()
    facts = load_facts(args.facts)
    roots = default_roots(env, args.self_root, {"claude": args.claude_dir, "codex": args.codex_dir, "agents": args.agents_dir})
    info = {"facts": facts, "roots": roots, "env": env, "warnings": [], "unreadable": []}
    claude_rec = read_record(roots["claude"], "claude")
    codex_rec = read_record(roots["codex"], "codex")
    info["claude_rec"] = claude_rec
    info["codex_rec"] = codex_rec
    harness, kind, data = pick_record(claude_rec, codex_rec)
    info["record_harness"], info["record_kind"], info["record"] = harness, kind, data
    info["claude_present"] = claude_rec[0] != "none" or os.path.isdir(roots["claude"])
    info["codex_present"] = codex_rec[0] != "none" or os.path.isdir(roots["codex"])
    # A Codex-only install has no Claude folder: the Claude sections (seats, judge,
    # hooks, CLAUDE.md) have nothing to check, and saying "missing" would be wrong.
    info["claude_side"] = info["claude_present"]
    info["installed"] = claude_rec[0] != "none" or codex_rec[0] != "none"
    for h, rec in (("claude", claude_rec), ("codex", codex_rec)):
        if rec[0] == "unreadable":
            info["unreadable"].append("%s install record" % h)
    if not info["installed"]:
        return info

    settings = []
    for label, path in settings_files(roots["claude"], cwd, args.managed_settings):
        obj, state = read_json(path)
        settings.append((label, state, obj))
        if label == "user" and state in ("unreadable", "unparseable"):
            info["warnings"].append("The user settings file is not valid JSON or cannot be read. "
                                    "Conductor did not read or change it.")
    info["settings"] = settings
    user = next(((s, o) for lbl, s, o in settings if lbl == "user"), ("missing", None))
    info["user_settings_state"] = user[0]
    info["user_settings"] = user[1] if user[0] == "ok" and isinstance(user[1], dict) else {}

    info["claude_version"], info["claude_version_raw"] = detect_claude_version(env)
    info["codex_version"], info["codex_version_raw"] = detect_codex_version(env)
    info["python_version"] = "%d.%d.%d" % sys.version_info[:3]
    info["provider"], info["provider_set_by"] = detect_provider(env, settings, facts)

    # seats
    pins = {}
    ms = info["user_settings"].get("modelSettings") if isinstance(info["user_settings"], dict) else None
    for alias, model_id in PIN_MODELS.items():
        val = ms.get(model_id, {}).get("effortLevel") if isinstance(ms, dict) and isinstance(ms.get(model_id), dict) else None
        if isinstance(val, str) and val in EFFORTS:
            pins[alias] = val
    info["pins"] = pins
    effort_env = env.get("CLAUDE_CODE_EFFORT_LEVEL", "")
    info["effort_env"] = effort_env
    seats = []
    for seat, default_alias in (SEATS if info["claude_side"] else ()):
        entry = {"seat": seat, "alias": default_alias, "alias_state": "seat map", "effort": None,
                 "source": "inherited", "file_state": "n/a"}
        if seat != "conductor":
            path = os.path.join(roots["claude"], "agents", seat + ".md")
            text, state = read_text(path)
            entry["file_state"] = state
            fm = parse_frontmatter(text) if state == "ok" else None
            if state == "ok" and fm is None:
                entry["file_state"] = "unreadable"
            if fm is not None:
                entry["alias"] = fm.get("model", "")
                entry["alias_state"] = "file"
                eff = fm.get("effort", "")
                if eff in EFFORTS:
                    entry["effort"] = eff
                    entry["source"] = "agent file"
            else:
                entry["alias"] = default_alias if seat != "judge" else ""
                entry["alias_state"] = "missing" if entry["file_state"] == "missing" else "unreadable"
        if entry["source"] == "inherited" and entry["alias"] in pins:
            entry["effort"] = pins[entry["alias"]]
            entry["source"] = "settings pin"
        entry["expected"], entry["expected_text"] = expected_model(entry["alias"], info["provider"], info["claude_version"], facts)
        seats.append(entry)
    info["seats"] = seats

    # overrides
    overrides = []
    env_blocks = []
    for label, state, obj in settings:
        if state == "ok" and isinstance(obj, dict) and isinstance(obj.get("env"), dict):
            env_blocks.append((label, obj["env"]))
    effort_elsewhere = False
    for var in OVERRIDE_ENV + ("CLAUDE_CODE_EFFORT_LEVEL",):
        if env.get(var):
            overrides.append("%s is set in the environment: %s" % (var, display_value(env[var])))
        for label, block in env_blocks:
            if block.get(var):
                overrides.append("%s is set in the %s settings env block: %s" % (var, label, display_value(block[var])))
                if var == "CLAUDE_CODE_EFFORT_LEVEL":
                    effort_elsewhere = True
    for label, state, obj in settings:
        if state == "ok" and isinstance(obj, dict):
            if obj.get("model") not in (None, ""):
                overrides.append("settings (%s) set the default model: %s" % (label, display_value(obj["model"])))
            if label != "user" and isinstance(obj.get("effortLevel"), str):
                overrides.append("%s settings set effortLevel %s; it applies to every model" % (label, display_value(obj["effortLevel"])))
                effort_elsewhere = True
    info["overrides"] = overrides
    # an effort set outside the user pins (a settings env block, or project, local or managed
    # settings) is not the model default, so the doctor does not claim the default for it
    info["effort_elsewhere"] = effort_elsewhere
    for entry in seats:
        entry["runs_at_default"] = (entry["effort"] is None and default_effort_applies(info, entry["alias"]))

    ul = info["user_settings"]
    top = ul.get("effortLevel") if isinstance(ul, dict) else None
    info["top_effort_warning"] = False
    if info["user_settings_state"] == "ok" and isinstance(top, str) and top:
        missing = [a for a in PIN_MODELS if a not in pins]
        if missing:
            info["top_effort_warning"] = True

    # judge
    rec = info["record"] if info["record_kind"] == "v04" else {}
    judge_file = os.path.join(roots["claude"], "agents", "judge.md")
    jseat = next((s for s in seats if s["seat"] == "judge"),
                 {"alias": "", "alias_state": "n/a", "file_state": "n/a"})
    rung = rec.get("judge_rung") if isinstance(rec, dict) else None
    if rung not in (1, 2, 3):
        rung = {"fable": 1, "sonnet": 3}.get(jseat["alias"]) if jseat["alias_state"] == "file" else None
    info["judge"] = {"rung": rung, "present": jseat["file_state"] == "ok", "alias": jseat["alias"],
                     "state": jseat["file_state"]}

    # the python3 the hooks run with, as the install record has it
    hook_py = rec.get("python3") if isinstance(rec, dict) else None
    info["hook_python_state"] = None
    if info["claude_side"] and isinstance(hook_py, str) and os.path.isabs(hook_py):
        if not os.path.isfile(hook_py):
            info["hook_python_state"] = "missing"
        elif not os.access(hook_py, os.X_OK):
            info["hook_python_state"] = "not executable"

    # hooks
    wired = {}
    commands = []
    hooks_obj = ul.get("hooks") if isinstance(ul, dict) else None
    if isinstance(hooks_obj, dict):
        for event, groups in hooks_obj.items():
            if not isinstance(groups, list):
                continue
            for g in groups:
                for h in (g.get("hooks", []) if isinstance(g, dict) else []):
                    cmd = h.get("command") if isinstance(h, dict) else None
                    if isinstance(cmd, str):
                        commands.append((str(event), cmd))
    own = os.path.realpath(os.path.join(roots["claude"], "conductor", "hooks"))
    elsewhere = set()
    for event, cmd in commands:
        for stem, name in HOOK_NAMES:
            m = re.search(r"([^\s\"']*conductor/hooks/%s\.py)" % re.escape(stem), cmd)
            if m:
                wired.setdefault(name, []).append(event)
                if os.path.dirname(os.path.realpath(m.group(1))) != own:
                    elsewhere.add(name)
    info["hooks_wired"] = [n for _, n in HOOK_NAMES if n in wired]
    info["hook_duplicates"] = []
    for n, events in wired.items():
        for ev in set(events):
            if events.count(ev) > 1:
                info["hook_duplicates"].append("%s (%s)" % (n, ev))
    info["hooks_elsewhere"] = sorted(elsewhere)
    # a wired command that names a Conductor script that is not there: the guard
    # in the command makes it do nothing, but the entry is stale
    missing_scripts = []
    for event, cmd in commands:
        try:
            tokens = shlex.split(cmd)
        except ValueError:
            continue
        for t in tokens:
            if "/conductor/" in t and t.endswith(".py") and not os.path.isfile(t) and t not in missing_scripts:
                missing_scripts.append(t)
    info["hooks_missing_scripts"] = missing_scripts
    info["kill_switch"] = "off" if hooks_switch_off(env) else "on"
    info["kill_switch_set"] = hooks_switch_set(env)
    info["debug_on"] = env.get("CONDUCTOR_DEBUG", "") == "1"

    # doctrine block
    if info["claude_side"]:
        doctrine_file = os.path.join(roots["claude"], "CLAUDE.md")
    else:
        doctrine_file = os.path.join(roots["codex"], "AGENTS.md")
    claude_md, cstate = read_text(doctrine_file)
    begins = re.findall(r"<!-- BEGIN CONDUCTOR \(managed\) v([0-9][0-9A-Za-z.\-]*) ", claude_md or "")
    ends = len(re.findall(r"<!-- END CONDUCTOR \(managed\) -->", claude_md or ""))
    info["doctrine"] = {"state": cstate, "begins": begins, "ends": ends,
                        "file": "CLAUDE.md" if info["claude_side"] else "AGENTS.md"}

    # files
    info["files"] = {"recorded": 0, "missing": 0, "changed": 0, "changed_names": [], "counts": {}}
    if info["record_kind"] == "v04" and isinstance(rec.get("files"), list):
        for f in rec["files"]:
            if not isinstance(f, dict) or not isinstance(f.get("dest"), str):
                continue
            comp = f.get("component") if isinstance(f.get("component"), str) else "unknown"
            c = info["files"]["counts"].setdefault(comp, {"written": 0, "kept": 0, "modified": 0})
            c["written"] += 1
            if f.get("policy") == "create-only":
                c["kept"] += 1
            info["files"]["recorded"] += 1
            dest = f["dest"]
            if dest.startswith("/") or ".." in dest.split("/"):
                continue
            base = roots["agents"] if f.get("root") == "agents_skills" else roots[info["record_harness"]]
            path = os.path.join(base, dest)
            if not os.path.isfile(path):
                info["files"]["missing"] += 1
                continue
            sha = file_sha256(path)
            if sha and isinstance(f.get("sha256"), str) and sha != f["sha256"] and f.get("policy") != "create-only":
                info["files"]["changed"] += 1
                c["modified"] += 1
                info["files"]["changed_names"].append(dest)

    # duplicates
    dups = []
    if claude_rec[0] == "v04" and os.path.isfile(os.path.join(roots["claude"], "skills", "conductor", ".install-manifest")):
        dups.append("an old 0.3.0 install record sits beside the 0.4 record in the Claude folder")
    if len(begins) > 1:
        dups.append("the Conductor block appears %d times in CLAUDE.md" % len(begins))
    if info["hooks_elsewhere"]:
        dups.append("hook entries point at a Conductor folder other than this one")
    info["duplicates"] = dups

    # codex
    codex_agents = []
    if codex_rec[0] != "none":
        for name in ("builder", "scout", "critic", "architect"):
            text, state = read_text(os.path.join(roots["codex"], "agents", name + ".toml"))
            effort = None
            model = None
            if state == "ok":
                m = re.search(r'(?m)^\s*model_reasoning_effort\s*=\s*"([^"]*)"', text)
                effort = m.group(1) if m else None
                m = re.search(r'(?m)^\s*model\s*=\s*"([^"]*)"', text)
                model = m.group(1) if m else None
            codex_agents.append({"name": name, "state": state, "effort": effort, "model": model})
        override, ostate = read_text(os.path.join(roots["codex"], "AGENTS.override.md"))
        info["codex_override_nonempty"] = ostate == "ok" and bool(override.strip())
    else:
        info["codex_override_nonempty"] = False
    info["codex_agents"] = codex_agents

    # error codes from the debug trace
    info["error_codes"] = read_error_codes(roots["claude"])
    return info


def file_sha256(path):
    try:
        h = hashlib.sha256()
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(65536), b""):
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return None


def read_error_codes(claude_root):
    """Codes of the debug trace that appear in the installed feedback-codes.txt; nothing
    else is taken from the trace. Empty unless CONDUCTOR_DEBUG=1 wrote one."""
    text, state = read_text(os.path.join(claude_root, "conductor", "feedback-codes.txt"))
    allowed = set()
    if state == "ok":
        for ln in text.split("\n"):
            code = ln.split("\t", 1)[0].strip()
            if re.match(r"^[A-Z][0-9]{3}$", code):
                allowed.add(code)
    found = []
    logs = os.path.join(claude_root, "conductor", "logs")
    try:
        names = sorted(os.listdir(logs))
    except OSError:
        return []
    for name in names:
        path = os.path.join(logs, name)
        if os.path.islink(path) or not os.path.isfile(path):
            continue
        try:
            with open(path, "rb") as fh:
                fh.seek(0, os.SEEK_END)
                size = fh.tell()
                fh.seek(max(0, size - 200000))
                data = fh.read().decode("utf-8", "replace")
        except OSError:
            continue
        for tok in re.findall(r"(?<![A-Za-z0-9])[A-Z][0-9]{3}(?![A-Za-z0-9])", data):
            if tok in allowed:
                found.append(tok)
    return found[-10:]


# ---------------------------------------------------------------- doctor text

def render(info):
    L = []
    w = L.append
    roots = info["roots"]
    rec = info["record"] if info["record_kind"] == "v04" else {}
    w("Conductor doctor")
    w("This check reads files and the environment, and asks claude and codex")
    w("for their version numbers. It sends nothing.")
    w('Model lines say "expected": a file check cannot see what a session runs on.')
    w("")
    if not info["installed"]:
        w("No Conductor install found.")
        w("To install it, run:")
        w("  curl --proto '=https' --tlsv1.2 -fsSL https://conductorskill.com/install.sh | bash")
        w("")
        w("This output holds local paths. To share a problem, run: conductor report")
        return L
    w("Install")
    if info["record_kind"] == "v04":
        w("  Version: %s" % display_value(rec.get("version")))
        w("  Method: %s" % display_value(rec.get("method")))
        comps = [display_value(c) for c in rec.get("components", []) if isinstance(c, str)] if isinstance(rec.get("components"), list) else []
        w("  Components: %s" % (", ".join(comps) if comps else "not recorded"))
        launcher = rec.get("launcher")
        if isinstance(launcher, str) and launcher and not launcher.startswith("/") and ".." not in launcher.split("/"):
            w("  Launcher: %s" % clean(os.path.join(roots[info["record_harness"]], launcher)))
        else:
            w("  Launcher: not recorded")
        py = rec.get("python3")
        py_state = " (%s)" % info["hook_python_state"] if info.get("hook_python_state") else ""
        w("  python3 for hooks: %s%s" % (clean(py) if isinstance(py, str) and py else "not recorded", py_state))
    elif info["record_kind"] == "v030":
        w("  Version: %s (old install record)" % display_value(rec_version(info)))
        w("  Method: installer (0.3.0)")
    elif info["record_kind"] == "unreadable":
        w("  Install record: unreadable")
    w("  Claude folder: %s" % (clean(roots["claude"]) if info["claude_present"] else "not found"))
    w("  Codex folder: %s" % (clean(roots["codex"]) if info["codex_present"] else "not found"))
    if not info["claude_side"]:
        w("  Claude Code: not installed here (Codex only)")
    d = info["doctrine"]
    if d["state"] != "ok":
        w("  Doctrine block: %s" % ("%s is %s" % (d["file"], d["state"])))
    elif len(d["begins"]) == 1 and d["ends"] == 1:
        w("  Doctrine block: present, v%s" % clean(d["begins"][0]))
    elif not d["begins"]:
        w("  Doctrine block: missing from CLAUDE.md")
    else:
        w("  Doctrine block: %d found (expected 1)" % len(d["begins"]))
    f = info["files"]
    if f["recorded"]:
        w("  Files: %d recorded, %d missing, %d changed by you" % (f["recorded"], f["missing"], f["changed"]))
        for name in f["changed_names"][:10]:
            w("    changed: %s" % clean(name))
    w("  Duplicate installs: %s" % ("none" if not info["duplicates"] else "found"))
    for dup in info["duplicates"]:
        w("    %s" % dup)
    w("")
    w("Runtime")
    facts = info["facts"]["facts"]
    cc = info["claude_version"]
    if cc:
        w("  Claude Code: %s" % cc)
    else:
        w("  Claude Code: version not found (is claude on your PATH?)")
    for label, key in (("Opus 5.5 effort pin", "floor_opus_pin"), ("Sonnet 5.5 effort pin", "floor_sonnet_pin"),
                       ("Haiku 5.5", "floor_haiku55"), ("Per-call effort", "floor_per_call_effort"),
                       ("Fable 5.1 (judge rung 1)", "floor_fable")):
        floor = facts.get(key)
        state = "unknown" if not cc else ("met" if version_ge(cc, floor) else "not met")
        w("    %s needs %s: %s" % (label, floor, state))
    w("  python3 running the doctor: %s" % info["python_version"])
    prov = info["provider"]
    by = " (set by %s)" % info["provider_set_by"] if info["provider_set_by"] else ""
    w("  Provider: %s%s" % (prov, by))
    if prov != "first-party":
        w("    Aliases can resolve to older models on this provider.")
    w("")
    if not info["claude_side"]:
        w("Seats, judge and hooks are not checked: there is no Claude folder (Codex only).")
        render_codex_agents(info, w)
        finish_render(info, w)
        return L
    w("Seats (agent files in the Claude folder)")
    for s in info["seats"]:
        for ln in format_seat(s, info):
            w(ln)
    w("")
    w("Overrides found")
    if info["overrides"]:
        for o in info["overrides"]:
            w("  %s" % o)
    else:
        w("  none")
    w("")
    w("Judge")
    j = info["judge"]
    w("  Rung: %s" % (j["rung"] if j["rung"] else "unknown"))
    if j["present"]:
        w("  Judge file: present")
        w("  Judge gates: available")
    else:
        w("  Judge file: %s" % ("missing" if j["state"] == "missing" else "unreadable"))
        w("  Judge gates: unavailable (the judge file is missing)")
    w("")
    w("Hooks")
    w("  Wired: %s" % (", ".join(info["hooks_wired"]) if info["hooks_wired"] else "none"))
    if info["kill_switch"] == "off":
        w("  Kill switch CONDUCTOR_HOOKS: off (every Conductor hook stays silent)")
    elif info["kill_switch_set"]:
        w("  Kill switch CONDUCTOR_HOOKS: set, hooks still run")
    else:
        w("  Kill switch CONDUCTOR_HOOKS: not set (wired hooks run)")
    w("  Debug trace CONDUCTOR_DEBUG: %s" % ("on" if info["debug_on"] else "off"))
    for dup in info["hook_duplicates"]:
        w("  Duplicate hook entry: %s" % dup)
    for path in info["hooks_missing_scripts"]:
        w("  Script not found: %s" % clean(path))
    render_codex_agents(info, w)
    finish_render(info, w)
    return L


def render_codex_agents(info, w):
    if info["codex_agents"]:
        w("")
        w("Codex agents")
        checked = info["facts"]["facts"].get("codex_map_checked_on")
        if isinstance(checked, str) and DATE_RE.match(checked):
            w("  Model map checked on %s" % checked)
        else:
            w("  Model map check date: not recorded")
        for a in info["codex_agents"]:
            if a["state"] != "ok":
                w("  %s: %s" % (a["name"], "agent file " + a["state"]))
                continue
            if a["model"]:
                model = ", model %s" % ("set (not shown)" if looks_secret(a["model"]) else clean(a["model"], 80))
            else:
                model = ", model not found in the agent file"
            if a["effort"]:
                w("  %s: effort %s (found in the agent file)%s" % (a["name"], display_value(a["effort"]), model))
            else:
                w("  %s: effort not pinned%s" % (a["name"], model))


def finish_render(info, w):
    warns = warnings_list(info)
    w("")
    w("Warnings")
    if warns:
        for t in warns:
            for ln in textwrap.wrap(t, width=78, initial_indent="  - ", subsequent_indent="    ",
                                    break_on_hyphens=False, break_long_words=False):
                w(ln)
    else:
        w("  none")
    w("")
    w("This output holds local paths. To share a problem, run: conductor report")


def rec_version(info):
    data = info["record"]
    return data.get("version") if isinstance(data, dict) else None


def format_seat(s, info):
    """The 2 lines of a seat: its alias and expected model, then where its effort comes from."""
    seat = s["seat"]
    if s["alias_state"] in ("missing", "unreadable"):
        what = "agent file is %s" % s["alias_state"]
        if seat == "judge":
            what += " (judge gates unavailable)"
        return ["  %s: %s" % (seat, what)]
    alias = s["alias"]
    if alias in KNOWN_ALIASES:
        a = alias
    else:
        a = 'custom model "%s"' % display_value(alias) if alias else "no model line"
    eff = s["effort"]
    if eff:
        effort = "effort %s (%s)" % (eff, s["source"])
    elif s.get("runs_at_default"):
        effort = ("effort inherited from the session; no pin is set, so it runs at the model's "
                  "default, medium (%s)" % ALIAS_FLOOR[alias][0])
    else:
        effort = "effort inherited from the session"
    if info["effort_env"]:
        effort += "; overridden by CLAUDE_CODE_EFFORT_LEVEL"
    return ["  %s: %s, expected %s" % (seat, a, s["expected_text"]), "    %s" % effort]


def warnings_list(info):
    warns = list(info["warnings"])
    if info["record_kind"] == "v030":
        warns.append("This is a 0.3.0 install. Run the 0.4.0 installer to upgrade it.")
    for name in info["unreadable"]:
        warns.append("The %s cannot be read. Run the installer again to repair it." % (
            name[0].upper() + name[1:]))
    if info["top_effort_warning"]:
        warns.append("Your user settings set effortLevel at the top level. That value does not "
                     "reach Opus 5.5 or Sonnet 5.5. Set the per-model pin under modelSettings instead.")
    shown = []
    for s in info["seats"]:
        if s.get("runs_at_default") and s["alias"] not in shown:
            shown.append(s["alias"])
            who = "the conductor" if s["seat"] == "conductor" else "the %s agent" % s["seat"]
            warns.append("No effort pin is set for %s, so %s runs at the model's default, medium. To "
                         "pin it, run the installer again with --apply-effort-pins: %s"
                         % (ALIAS_FLOOR[s["alias"]][0], who, PIN_COMMAND))
    if info["hook_python_state"]:
        py = info["record"].get("python3") if isinstance(info["record"], dict) else None
        warns.append("The python3 recorded for the hooks (%s) is missing or not executable. Every "
                     "wired hook that uses it fails until it is replaced. Run the installer again "
                     "to record a working python3." % clean(py))
    if info["installed"] and not info["claude_version"]:
        warns.append("Claude Code's version was not found, so the floors above are unknown.")
    d = info["doctrine"]
    if info["record_kind"] == "v04" and d["state"] == "ok" and not d["begins"]:
        warns.append("The Conductor block is missing from %s. Run the installer again." % d["file"])
    if info["claude_side"] and info["record_kind"] == "v04" and not info["judge"]["present"]:
        warns.append("The judge agent file is missing. Run the installer again to restore it.")
    rung, jalias = info["judge"]["rung"], info["judge"]["alias"]
    if info["judge"]["present"] and rung == 1 and jalias != "fable":
        warns.append("The record says judge rung 1 but the judge file does not use fable.")
    if info["judge"]["present"] and rung == 3 and jalias != "sonnet":
        warns.append("The record says judge rung 3 but the judge file does not use sonnet.")
    for s in info["seats"]:
        if s["seat"] != "conductor" and s["alias_state"] == "missing" and s["seat"] != "judge":
            warns.append("The %s agent file is missing." % s["seat"])
    for path in info["hooks_missing_scripts"]:
        warns.append("A hook entry in settings.json points at %s, which is not there. The entry "
                     "does nothing. Run the installer again, or remove the entry." % clean(path))
    if info["codex_override_nonempty"]:
        warns.append("AGENTS.override.md in the Codex folder is not empty, so the Conductor "
                     "block there will not take effect until it is merged.")
    if info["effort_env"]:
        warns.append("CLAUDE_CODE_EFFORT_LEVEL is set and wins over every agent file and pin.")
    if info["provider"] != "first-party":
        warns.append("Provider is %s: no model id was written, and aliases may resolve "
                     "to older models." % info["provider"])
    return warns


# ---------------------------------------------------------------- record-info, record-sha

def self_harness(self_root):
    """claude or codex when the folder this launcher sits in holds an install record, else
    nothing (the launcher runs from a temporary folder)."""
    if not self_root:
        return ""
    obj, state = read_json(os.path.join(self_root, "conductor", ".install-manifest"))
    if state != "ok" or not isinstance(obj, dict):
        return ""
    return "codex" if obj.get("harness") == "codex" else "claude"


def cmd_record_info(args):
    facts = load_facts(args.facts)
    roots = default_roots(os.environ, args.self_root, {"claude": args.claude_dir, "codex": args.codex_dir, "agents": args.agents_dir})
    harness, kind, data = pick_record(read_record(roots["claude"], "claude"), read_record(roots["codex"], "codex"))
    out = []
    if kind == "none":
        out.append("state=none")
    elif kind == "v030":
        out.append("state=old")
    elif kind == "unreadable":
        out.append("state=unreadable")
    else:
        version = data.get("version") if isinstance(data.get("version"), str) and VERSION_RE.match(data.get("version")) else ""
        method = data.get("method") if data.get("method") in ("installer", "plugin", "manual") else ""
        host = ""
        src = data.get("source_url")
        if isinstance(src, str) and src:
            m = re.match(r"^https?://([A-Za-z0-9.-]+)(?::[0-9]+)?(?:/|$)", src)
            host = m.group(1).lower() if m else "invalid"
        comps = [c for c in data.get("components", []) if isinstance(c, str) and re.match(r"^[a-z0-9_]+$", c) and c != "core"] \
            if isinstance(data.get("components"), list) else []
        out += ["state=ok", "version=%s" % version, "method=%s" % method, "source_host=%s" % host,
                "components=%s" % ",".join(comps), "self_harness=%s" % self_harness(args.self_root)]
    sys.stdout.write("\n".join(out) + "\n")
    return 0


def cmd_record_sha(args):
    sha = (args.sha or "").lower()
    if not SHA_RE.match(sha):
        sys.stderr.write("record-sha: not a sha256\n")
        return 2
    roots = default_roots(os.environ, args.self_root, {"claude": args.claude_dir, "codex": args.codex_dir, "agents": args.agents_dir})
    done = 0
    for harness in ("claude", "codex"):
        path = os.path.join(roots[harness], "conductor", ".install-manifest")
        obj, state = read_json(path)
        if state != "ok" or not isinstance(obj, dict):
            continue
        obj["installer_sha256"] = sha
        mode = stat.S_IMODE(os.stat(path).st_mode)
        fd, tmp = tempfile.mkstemp(prefix=".manifest-tmp-", dir=os.path.dirname(path))
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write(json.dumps(obj, indent=2) + "\n")
                fh.flush()
                os.fsync(fh.fileno())
            os.chmod(tmp, mode)
            os.replace(tmp, path)
        except BaseException:
            if os.path.exists(tmp):
                os.unlink(tmp)
            raise
        done += 1
    return 0 if done else 1


# ---------------------------------------------------------------- update-preview

FILE_FIELDS = ("id", "harness", "dest", "policy", "component", "root", "select", "also", "sha256")
FILE_PATTERNS = {
    "id": re.compile(r"^[a-z0-9_]+$"),
    "harness": re.compile(r"^(claude|codex)$"),
    "dest": re.compile(r"^[A-Za-z0-9._/@+ -]+$"),
    "policy": re.compile(r"^(replace|agent|create-only|doctrine-block)$"),
    "component": re.compile(r"^[a-z0-9_]+$"),
    "root": re.compile(r"^(-|agents_skills)$"),
    "select": re.compile(r"^(-|[a-z_]+=[A-Za-z0-9_.-]+)$"),
    "also": re.compile(r"^(-|[A-Za-z0-9._/@+ -]+)$"),
    "sha256": re.compile(r"^(-|[0-9a-f]{64})$"),
}


def parse_installer(text):
    """(files, changelog lines, skipped) from the data blocks of a fetched installer."""
    files, log, skipped = [], [], 0
    lines = text.replace("\r", "").split("\n")
    mode = None
    for ln in lines:
        if ln == "#@@FILES-BEGIN":
            mode = "files"
        elif ln == "#@@FILES-END":
            mode = None
        elif ln == "#@@CHANGELOG-BEGIN":
            mode = "log"
        elif ln == "#@@CHANGELOG-END":
            mode = None
        elif mode == "files" and ln.startswith("#@@FILE|"):
            parts = ln[len("#@@FILE|"):].split("|")
            ok = len(parts) == len(FILE_FIELDS)
            rec = {}
            if ok:
                for key, val in zip(FILE_FIELDS, parts):
                    if not FILE_PATTERNS[key].match(val):
                        ok = False
                        break
                    rec[key] = val
            if ok and (rec["dest"].startswith("/") or ".." in rec["dest"].split("/")):
                ok = False
            if ok:
                files.append(rec)
            else:
                skipped += 1
        elif mode == "log" and ln.startswith("#@@|"):
            log.append(ln[len("#@@|"):][1:] if ln[len("#@@|"):].startswith(" ") else ln[len("#@@|"):])
    return files, log, skipped


def changelog_between(log, installed, available):
    """Sections '## X.Y.Z' of the changelog with installed < X.Y.Z <= available."""
    lo, hi = vtuple(installed), vtuple(available)
    out, keep = [], False
    for ln in log:
        m = re.match(r"^##\s+v?([0-9]+\.[0-9]+\.[0-9]+)", ln)
        if m:
            v = vtuple(m.group(1))
            keep = v is not None and lo is not None and hi is not None and lo < v <= hi
        if keep:
            out.append(ln)
    while out and not out[-1].strip():
        out.pop()
    return out


def show_group(title, names, w):
    w("")
    w("%s (%d)" % (title, len(names)))
    for n in names[:25]:
        w("  %s" % clean(n))
    if len(names) > 25:
        w("  ... and %d more" % (len(names) - 25))


def is_launcher_set(dest):
    """The files of the Claude core that the installer also writes into the Codex root."""
    return dest == "conductor/bin/conductor" or dest == "conductor/feedback-codes.txt" \
        or (dest.startswith("conductor/lib/") and "/" not in dest[len("conductor/lib/"):])


def cmd_update_preview(args):
    text, state = read_text(args.installer)
    if state != "ok":
        sys.stderr.write("update-preview: the fetched file cannot be read\n")
        return 1
    facts = load_facts(args.facts)
    files, log, skipped = parse_installer(text)
    if not files:
        sys.stderr.write("update-preview: the fetched file lists no payload files\n")
        return 1
    env = dict(os.environ)
    roots = default_roots(env, args.self_root, {"claude": args.claude_dir, "codex": args.codex_dir, "agents": args.agents_dir})
    records = {"claude": read_record(roots["claude"], "claude"), "codex": read_record(roots["codex"], "codex")}
    rung = 3
    for h in ("claude", "codex"):
        kind, data = records[h]
        if kind == "v04" and data.get("judge_rung") in (1, 3):
            rung = data["judge_rung"]
            break
    w = print_line
    ch = changelog_between(log, args.installed, args.available)
    w("")
    w("What changed (from the changelog inside the fetched file)")
    if ch:
        shown = 0
        for ln in ch:
            for piece in textwrap.wrap(clean(ln, 400), width=76, subsequent_indent="    ") or [""]:
                w("  " + piece)
                shown += 1
            if shown >= 120:
                w("  ... more entries are in CHANGELOG.md")
                break
    else:
        w("  The fetched file carries no changelog entry for this version.")

    chosen = []
    for f in files:
        sel = f["select"]
        if sel != "-":
            key, val = sel.split("=", 1)
            if key == "judge_rung" and val != str(rung):
                continue
        chosen.append(f)
        # The installer also puts the launcher set into the Codex root, with no file
        # row of its own; the preview lists those copies so they are neither missing
        # from the plan nor shown as files to remove.
        if f["harness"] == "claude" and f["component"] == "core" and is_launcher_set(f["dest"]):
            copy = dict(f)
            copy["harness"] = "codex"
            copy["root"] = "-"
            copy["also"] = "-"
            chosen.append(copy)
    replace, keep, add, remove, current = [], [], [], [], 0
    recorded = {}
    for h in ("claude", "codex"):
        kind, data = records[h]
        if kind == "v04" and isinstance(data.get("files"), list):
            for e in data["files"]:
                if isinstance(e, dict) and isinstance(e.get("dest"), str):
                    recorded[(h, e["dest"])] = e
    have_record = any(records[h][0] == "v04" and isinstance(records[h][1].get("files"), list) for h in records)
    have_comps = set()
    for h in ("claude", "codex"):
        kind, data = records[h]
        if kind == "v04" and isinstance(data.get("components"), list):
            have_comps.update(c for c in data["components"] if isinstance(c, str))
    new_keys = set()
    for f in chosen:
        h = f["harness"]
        base = roots["agents"] if f["root"] == "agents_skills" else roots[h]
        key = (h, f["dest"])
        new_keys.add(key)
        if f["also"] != "-":
            new_keys.add((h, f["also"]))
        # the update writes only what the install already holds: a component it
        # does not hold is offered by name, and a harness whose folder is not
        # there is skipped, as the installer skips it
        if f["component"] != "core" and f["component"] not in have_comps:
            continue
        if not os.path.isdir(roots[h]):
            continue
        path = os.path.join(base, f["dest"])
        disk = file_sha256(path) if os.path.isfile(path) else None
        entry = recorded.get(key)
        if f["policy"] == "doctrine-block":
            replace.append(f["dest"] + " (the Conductor block only)")
        elif f["policy"] == "create-only":
            if disk is None:
                add.append(f["dest"])
            else:
                keep.append(f["dest"] + " (yours to edit; never overwritten)")
        elif entry is None:
            if disk is None:
                add.append(f["dest"])
            else:
                replace.append(f["dest"] + " (not in your install record)")
        elif disk is None:
            add.append(f["dest"] + " (missing now)")
        elif disk != entry.get("sha256"):
            keep.append(f["dest"] + " (you changed it)")
        elif disk != f["sha256"]:
            replace.append(f["dest"])
        else:
            current += 1
    for key, entry in sorted(recorded.items()):
        if key in new_keys:
            continue
        h, dest = key
        if dest.startswith("/") or ".." in dest.split("/"):
            continue
        base = roots[h]
        path = os.path.join(base, dest)
        disk = file_sha256(path) if os.path.isfile(path) else None
        if disk is None:
            continue
        if disk == entry.get("sha256"):
            remove.append(dest)
        else:
            keep.append(dest + " (no longer shipped, but you changed it)")
    if not have_record:
        w("")
        w("Your install record has no file list. Files you have not changed are")
        w("replaced; files you changed are kept by the installer.")
    new_comps = sorted(set(f["component"] for f in chosen) - have_comps - {"core"})
    if new_comps:
        w("")
        for ln in textwrap.wrap("New optional components in this release: %s. The installer asks about each "
                                "by name; the update turns none of them on." % ", ".join(new_comps), width=78):
            w(ln)
    show_group("Files to replace", replace, w)
    show_group("Files to keep", keep, w)
    show_group("Files to add", add, w)
    show_group("Files to remove (no longer shipped)", remove, w)
    w("")
    w("Files already current: %d" % current)
    if skipped:
        w("Lines of the file list that could not be read and were skipped: %d" % skipped)
    return 0


def print_line(text=""):
    sys.stdout.write(text + "\n")


# ---------------------------------------------------------------- command line

def common_args(ap):
    """The options the doctor and the report share."""
    ap.add_argument("--self-root", default="")
    ap.add_argument("--facts", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "facts.json"))
    ap.add_argument("--claude-dir", default="")
    ap.add_argument("--codex-dir", default="")
    ap.add_argument("--agents-dir", default="")
    ap.add_argument("--managed-settings", default="")


def build_parser():
    ap = argparse.ArgumentParser(prog="doctor.py", description="Conductor doctor and install-record helpers.")
    ap.add_argument("command", nargs="?", default="doctor", choices=("doctor", "record-info", "update-preview", "record-sha"))
    common_args(ap)
    ap.add_argument("--installer", default="")
    ap.add_argument("--installed", default="")
    ap.add_argument("--available", default="")
    ap.add_argument("--sha", default="")
    return ap


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        if args.command == "record-info":
            return cmd_record_info(args)
        if args.command == "record-sha":
            return cmd_record_sha(args)
        if args.command == "update-preview":
            return cmd_update_preview(args)
        info = collect(args)
    except FactsError as exc:
        sys.stderr.write("Conductor doctor: %s\n" % exc)
        return 1
    for line in render(info):
        print_line(line)
    return 1 if info["unreadable"] else 0


if __name__ == "__main__":
    sys.exit(main())
