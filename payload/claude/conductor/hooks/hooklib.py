#!/usr/bin/env python3
"""Conductor hook standard (shared by the 5 hooks and checkpoint-record).

Rules every hook gets by calling main():
  - python3 standard library only
  - CONDUCTOR_HOOKS=off (also 0 or false, in any case) exits 0 before stdin is read
  - empty, oversized, non-JSON or unknown-event input exits 0 with no output
  - any error or a run past the time limit exits 0 with no output (fail open)
  - CONDUCTOR_DEBUG=1 appends 1 line per run to {config dir}/conductor/logs/
    hook-trace.log: hook name, event name from the known set (else "unknown"),
    exit code, milliseconds and a code from feedback-codes.txt. Never input text,
    never an exception message. The file is cut from its oldest end to 100,000 bytes.
  - a transcript is read from its last 2 MB only

Run as `python3 hooklib.py checkpoint ...` it is also the checkpoint helper of the
handoff skill (see the end of this file).

The config dir is the folder 2 levels above this file
({config dir}/conductor/hooks/hooklib.py), so no hook needs an environment value.
Hook text is a statement of fact built from fixed words and validated values;
nothing read from a checkpoint is ever printed.
"""
import hashlib
import json
import math
import os
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time

KNOWN_EVENTS = frozenset([
    "SessionStart", "SessionEnd", "UserPromptSubmit", "UserPromptExpansion",
    "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest",
    "PermissionDenied", "Notification", "SubagentStart", "SubagentStop", "Stop",
    "StopFailure", "TeammateIdle", "TaskCreated", "TaskCompleted", "PreCompact",
    "PostCompact", "ConfigChange", "InstructionsLoaded", "CwdChanged",
    "FileChanged", "WorktreeCreate", "WorktreeRemove", "Elicitation",
    "ElicitationResult", "Setup", "MessageDisplay",
])

# Must match payload/feedback-codes.txt (tests/test-hooks.sh checks both ways).
CODES = (
    "H001", "H002", "H003", "H004", "H005", "H006", "H007", "H008", "H009",
    "C001", "C002", "C003", "C004", "C005", "L001", "L002", "L003", "L004",
)

MAX_STDIN = 4 * 1024 * 1024
TAIL_BYTES = 2 * 1024 * 1024
TRACE_CAP = 100000
INJECT_TOKENS = 800
TIME_LIMIT_SECONDS = 2
GIT_TIMEOUT_SECONDS = 1.5
ACTIVE_DAYS = 14
MAX_CHECKPOINT_BYTES = 1024 * 1024

NAME_RE = re.compile(r"CURRENT(-[A-Za-z0-9_-]{1,64})?\.md")
COMMIT_RE = re.compile(r"[0-9a-f]{40}")
SESSION_RE = re.compile(r"[A-Za-z0-9_-]{1,64}")
HOOK_NAME_RE = re.compile(r"[a-z0-9-]{1,40}")
ALIASES = ("opus", "sonnet", "haiku", "fable")


class HookTimeout(BaseException):
    pass


class Stop(Exception):
    """Leave the run quietly (nothing to say)."""


class Ctx(object):
    def __init__(self, hook):
        self.hook = hook
        self.code = None
        self.config = config_dir()

    def note(self, code):
        """Remember the first error code of the run (only listed codes count)."""
        if code in CODES and self.code is None:
            self.code = code


def config_dir():
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.dirname(os.path.dirname(here))


# ---------------------------------------------------------------- main loop

def _on_alarm(signum, frame):
    raise HookTimeout()


# The kill switch. conductor doctor reads CONDUCTOR_HOOKS by the same rule
# (payload/claude/conductor/lib/doctor.py, hooks_switch_off); tests/test-review-fixes.sh
# runs both on the same list of values.
OFF_VALUES = ("off", "0", "false")


def hooks_off():
    """True when CONDUCTOR_HOOKS asks every Conductor hook to stay silent."""
    return os.environ.get("CONDUCTOR_HOOKS", "").strip().lower() in OFF_VALUES


def main(hook, handlers):
    """Run 1 hook. handlers maps an event name to fn(event_dict, ctx) -> dict or None."""
    if hooks_off():
        sys.exit(0)
    start = time.time()
    ctx = Ctx(hook)
    event = "unknown"
    out = None
    try:
        if hasattr(signal, "SIGALRM"):
            signal.signal(signal.SIGALRM, _on_alarm)
            signal.alarm(TIME_LIMIT_SECONDS)
        raw = sys.stdin.buffer.read(MAX_STDIN + 1)
        if not raw or len(raw) > MAX_STDIN:
            ctx.note("H001")
            raise Stop()
        try:
            ev = json.loads(raw.decode("utf-8"))
        except Exception:
            ctx.note("H001")
            raise Stop()
        if not isinstance(ev, dict):
            ctx.note("H001")
            raise Stop()
        name = ev.get("hook_event_name")
        if isinstance(name, str) and name in KNOWN_EVENTS:
            event = name
        else:
            ctx.note("H002")
            raise Stop()
        fn = handlers.get(event)
        if fn is not None:
            out = fn(ev, ctx)
    except Stop:
        out = None
    except HookTimeout:
        ctx.note("H004")
        out = None
    except BaseException as exc:  # fail open on anything, keep no message
        if isinstance(exc, (KeyboardInterrupt, SystemExit)):
            out = None
        else:
            ctx.note("H003")
            out = None
    finally:
        if hasattr(signal, "SIGALRM"):
            try:
                signal.alarm(0)
            except Exception:
                pass
    if isinstance(out, dict):
        try:
            sys.stdout.write(json.dumps(out, ensure_ascii=True))
            sys.stdout.write("\n")
            sys.stdout.flush()
        except Exception:
            pass
    if os.environ.get("CONDUCTOR_DEBUG", "") == "1":
        try:
            write_trace(ctx, event, int((time.time() - start) * 1000))
        except Exception:
            pass
    sys.exit(0)


def write_trace(ctx, event, ms):
    hook = ctx.hook if HOOK_NAME_RE.fullmatch(ctx.hook or "") else "unknown"
    code = ctx.code if ctx.code in CODES else "none"
    ev = event if event in KNOWN_EVENTS else "unknown"
    logs = os.path.join(ctx.config, "conductor", "logs")
    if os.path.islink(logs):
        return
    os.makedirs(logs, mode=0o700, exist_ok=True)
    path = os.path.join(logs, "hook-trace.log")
    line = "hook=%s event=%s rc=0 ms=%d code=%s\n" % (hook, ev, ms, code)
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        os.write(fd, line.encode("ascii"))
    finally:
        os.close(fd)
    if os.path.getsize(path) > TRACE_CAP:
        with open(path, "rb") as f:
            data = f.read()
        data = data[-TRACE_CAP:]
        nl = data.find(b"\n")
        data = data[nl + 1:] if nl >= 0 else b""
        atomic_write_bytes(path, data, 0o600)


# ---------------------------------------------------------------- small utils

def atomic_write_bytes(path, data, mode):
    d = os.path.dirname(path)
    tmp = os.path.join(d, ".conductor-tmp.%d" % os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_EXCL, 0o600)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def sanitize(text, limit=200):
    """Printable ASCII only, so a path or name cannot carry control characters."""
    s = "".join(c if 32 <= ord(c) < 127 else "?" for c in str(text))
    return s[:limit]


def est_tokens(text):
    return int(math.ceil(len(text) / 3.2))


def fit_lines(lines, max_tokens=INJECT_TOKENS):
    """Drop trailing lines until the text fits the injection cap."""
    lines = list(lines)
    while len(lines) > 1 and est_tokens("\n".join(lines)) > max_tokens:
        lines.pop()
    text = "\n".join(lines)
    if est_tokens(text) > max_tokens:
        text = text[: int(max_tokens * 3.2)]
    return text


def context_output(event, lines):
    return {"hookSpecificOutput": {"hookEventName": event,
                                    "additionalContext": fit_lines(lines)}}


def soft_message(lines):
    return {"systemMessage": fit_lines(lines)}


def format_age(seconds):
    s = max(0, int(seconds))
    if s < 60:
        return "under 1 minute"
    if s < 7200:
        n = s // 60
        return "%d minute%s" % (n, "" if n == 1 else "s")
    if s < 172800:
        n = s // 3600
        return "%d hour%s" % (n, "" if n == 1 else "s")
    n = s // 86400
    return "%d days" % n


_ISO_RE = re.compile(
    r"(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d{1,9})?)?)?"
    r"[ ]?(Z|[+-]\d{2}:?\d{2})?")


def parse_iso(text):
    """ISO date or time to epoch seconds (UTC when no offset); None when invalid."""
    if not isinstance(text, str):
        return None
    m = _ISO_RE.fullmatch(text.strip())
    if not m:
        return None
    try:
        import calendar
        y, mo, d = int(m.group(1)), int(m.group(2)), int(m.group(3))
        hh = int(m.group(4) or 0)
        mi = int(m.group(5) or 0)
        ss = int(m.group(6) or 0)
        if not (1970 <= y <= 2200 and 1 <= mo <= 12 and 1 <= d <= 31
                and hh < 24 and mi < 60 and ss < 61):
            return None
        epoch = calendar.timegm((y, mo, d, hh, mi, ss, 0, 0, 0))
        tz = m.group(7)
        if tz and tz != "Z":
            sign = 1 if tz[0] == "+" else -1
            digits = tz[1:].replace(":", "")
            epoch -= sign * (int(digits[:2]) * 3600 + int(digits[2:]) * 60)
        return float(epoch)
    except Exception:
        return None


def iso_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def sid_key(session_id):
    sid = session_id if isinstance(session_id, str) and session_id else "none"
    return hashlib.sha256(sid.encode("utf-8", "replace")).hexdigest()[:16]


# ---------------------------------------------------------------- state files

def state_dir(ctx):
    return os.path.join(ctx.config, "conductor", "state")


def state_path(ctx, prefix, session_id):
    return os.path.join(state_dir(ctx), "%s-%s.json" % (prefix, sid_key(session_id)))


def load_json_file(path, ctx=None):
    try:
        st = os.lstat(path)
        if not stat.S_ISREG(st.st_mode) or st.st_size > 1024 * 1024:
            return {}
        with open(path, "rb") as f:
            data = json.loads(f.read().decode("utf-8"))
        return data if isinstance(data, dict) else {}
    except FileNotFoundError:
        return {}
    except Exception:
        if ctx is not None:
            ctx.note("H006")
        return {}


def save_json_file(path, data, ctx=None):
    try:
        d = os.path.dirname(path)
        os.makedirs(d, mode=0o700, exist_ok=True)
        if os.path.islink(d) or os.path.islink(path):
            return False
        atomic_write_bytes(path, json.dumps(data, sort_keys=True).encode("utf-8"), 0o600)
        return True
    except Exception:
        if ctx is not None:
            ctx.note("H006")
        return False


# ---------------------------------------------------------------- transcript

def read_tail(path, limit=TAIL_BYTES):
    """The last `limit` bytes of a regular file, cut to whole lines."""
    st = os.stat(path)
    if not stat.S_ISREG(st.st_mode):
        raise OSError("not a regular file")
    off = max(0, st.st_size - limit)
    with open(path, "rb") as f:
        f.seek(off)
        data = f.read(limit)
    if off > 0:
        nl = data.find(b"\n")
        data = data[nl + 1:] if nl >= 0 else b""
    return data


def transcript_entries(path):
    """Parsed JSON lines from the tail of a transcript. Raises OSError when unreadable."""
    data = read_tail(path)
    out = []
    for raw in data.split(b"\n"):
        raw = raw.strip()
        if not raw or raw[:1] != b"{":
            continue
        try:
            e = json.loads(raw.decode("utf-8", "replace"))
        except Exception:
            continue
        if isinstance(e, dict):
            out.append(e)
    return out


def _blocks(msg):
    content = msg.get("content") if isinstance(msg, dict) else None
    if isinstance(content, list):
        return [b for b in content if isinstance(b, dict)]
    return []


def is_real_prompt(msg):
    if not isinstance(msg, dict):
        return False
    content = msg.get("content")
    if isinstance(content, str):
        return True
    blocks = _blocks(msg)
    kinds = [b.get("type") for b in blocks]
    return "text" in kinds and "tool_result" not in kinds


def context_tokens(entries):
    """Context use at the last assistant message that reports usage; None if none."""
    last = None
    for e in entries:
        if e.get("isSidechain") or e.get("type") != "assistant":
            continue
        usage = (e.get("message") or {}).get("usage") if isinstance(e.get("message"), dict) else None
        if not isinstance(usage, dict):
            continue
        total = 0
        for k in ("input_tokens", "cache_creation_input_tokens",
                  "cache_read_input_tokens", "output_tokens"):
            v = usage.get(k)
            if isinstance(v, int) and not isinstance(v, bool) and v >= 0:
                total += v
        last = total
    return last


def tool_uses(entry):
    """tool_use blocks of an assistant entry."""
    if entry.get("type") != "assistant":
        return []
    return [b for b in _blocks(entry.get("message")) if b.get("type") == "tool_use"]


# ---------------------------------------------------------------- defaults file

def defaults_lines(ctx):
    path = os.path.join(ctx.config, "conductor", "defaults.md")
    try:
        st = os.stat(path)
        if not stat.S_ISREG(st.st_mode):
            return []
        with open(path, "rb") as f:
            text = f.read(65536).decode("utf-8", "replace")
    except FileNotFoundError:
        return []
    except Exception:
        ctx.note("H008")
        return []
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    return [ln for ln in text.splitlines() if not ln.lstrip().startswith("#")]


def defaults_switch(lines, key):
    """'on' or 'off' for `key: value` on its own line; None when absent."""
    pat = re.compile(r"^" + re.escape(key) + r":[ \t]*(on|off)[ \t]*$", re.I)
    for ln in lines:
        m = pat.match(ln)
        if m:
            return m.group(1).lower()
    return None


def defaults_list(lines, key):
    """Items of a bare `key:` line followed by `- item` lines; `key: []` is empty."""
    items = []
    inside = False
    for ln in lines:
        if not inside:
            if re.match(r"^" + re.escape(key) + r":[ \t]*\[\][ \t]*$", ln):
                return items
            if re.match(r"^" + re.escape(key) + r":[ \t]*$", ln):
                inside = True
            continue
        m = re.match(r"^[ \t]*-[ \t]+(.+?)[ \t]*$", ln)
        if m:
            v = m.group(1).strip().strip("'\"")
            if v:
                items.append(v)
            if len(items) >= 50:
                break
        elif ln.strip() == "":
            continue
        else:
            break
    return items


# ---------------------------------------------------------------- agent files

def agent_alias_from_text(text):
    low = str(text).lower()
    for a in ALIASES:
        if a in low:
            return a
    if low in ("inherit", ""):
        return "inherit"
    return "other"


def agent_model(ctx, cwd, agent_type):
    """Model alias in the frontmatter of a pinned agent file; None when there is none."""
    if not isinstance(agent_type, str) or not SESSION_RE.fullmatch(agent_type):
        return None
    folders = [os.path.join(ctx.config, "agents")]
    if isinstance(cwd, str) and cwd.startswith("/"):
        folders.append(os.path.join(cwd, ".claude", "agents"))
    for folder in folders:
        path = os.path.join(folder, agent_type + ".md")
        try:
            st = os.lstat(path)
            if not stat.S_ISREG(st.st_mode):
                continue
            with open(path, "rb") as f:
                head = f.read(4096).decode("utf-8", "replace").split("\n")[:40]
        except Exception:
            continue
        if not head or head[0].strip() != "---":
            continue
        for ln in head[1:]:
            if ln.strip() == "---":
                break
            m = re.match(r"^model:[ \t]*(\S+)", ln)
            if m:
                return agent_alias_from_text(m.group(1))
    return None


# ---------------------------------------------------------------- checkpoints

class Checkpoint(object):
    pass


def parse_header(data):
    """The 4 header values from the first 12 lines. Values are raw: validate before use."""
    lines = data.decode("utf-8", "replace").split("\n")[:12]
    found = {}
    pat = re.compile(r"^(Status|Session|Pinned commit|Updated):[ \t]*(.*?)[ \t\r]*$")
    for ln in lines:
        m = pat.match(ln)
        if m and m.group(1) not in found:
            found[m.group(1)] = m.group(2)
    return found


def scan_checkpoints(cwd, now):
    """(list of Checkpoint, count of links not read) for {cwd}/handoffs.

    A checkpoint reached through a link, or a handoffs folder that is a link, is
    never read. Only validated values are kept on the objects.
    """
    items = []
    links = 0
    if not isinstance(cwd, str) or not cwd.startswith("/"):
        return items, links
    root = os.path.realpath(cwd)
    hdir = os.path.join(root, "handoffs")
    try:
        st = os.lstat(hdir)
    except OSError:
        return items, links
    if stat.S_ISLNK(st.st_mode):
        return items, 1
    if not stat.S_ISDIR(st.st_mode):
        return items, links
    try:
        names = sorted(os.listdir(hdir))[:200]
    except OSError:
        return items, links
    for n in names:
        if not (n.startswith("CURRENT") and n.endswith(".md")):
            continue
        p = os.path.join(hdir, n)
        try:
            lst = os.lstat(p)
        except OSError:
            continue
        if stat.S_ISLNK(lst.st_mode):
            links += 1
            continue
        if not stat.S_ISREG(lst.st_mode):
            continue
        cp = read_checkpoint(p, n, lst, now)
        if cp is not None:
            items.append(cp)
    return items, links


def read_checkpoint(path, name, lst, now):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_size > MAX_CHECKPOINT_BYTES:
            small = False
            data = b""
        else:
            small = True
            data = os.read(fd, MAX_CHECKPOINT_BYTES)
    finally:
        os.close(fd)
    cp = Checkpoint()
    cp.name = name
    cp.printable = bool(NAME_RE.fullmatch(name))
    cp.path = path
    cp.mtime = lst.st_mtime
    cp.sha = hashlib.sha256(data).hexdigest() if small else None
    hdr = parse_header(data[:4096]) if small else {}
    cp.status = hdr.get("Status") if hdr.get("Status") in ("ACTIVE", "DONE") else None
    sess = hdr.get("Session")
    cp.session_present = sess is not None
    cp.session = sess if sess is not None and SESSION_RE.fullmatch(sess) else None
    pin = hdr.get("Pinned commit")
    if pin is None:
        cp.pinned = None
    elif pin == "none" or COMMIT_RE.fullmatch(pin):
        cp.pinned = pin
    else:
        cp.pinned = "invalid"
    cp.updated = parse_iso(hdr.get("Updated"))
    cp.age = None
    cp.active = False
    if cp.updated is not None:
        age = now - cp.updated
        if age >= -86400:
            cp.age = max(0.0, age)
            cp.active = (cp.status == "ACTIVE" and age <= ACTIVE_DAYS * 86400)
    return cp


def record_path(config):
    return os.path.join(config, "conductor", "state", "checkpoint-record.json")


def load_record(config, ctx=None):
    data = load_json_file(record_path(config), ctx)
    ents = data.get("entries")
    return ents if isinstance(ents, dict) else {}


def origin_of(entries, cp):
    """own, 'own from unverified' or unverified (rule PR-6), from the write record."""
    ent = entries.get(cp.path)
    if not isinstance(ent, dict) or cp.sha is None:
        return "unverified"
    if ent.get("sha256") != cp.sha:
        return "unverified"
    if ent.get("lineage") == "from-unverified":
        return "own from unverified"
    if ent.get("lineage") == "own":
        return "own"
    return "unverified"


def live_commit(ctx, cwd):
    """HEAD of the repository at cwd; None when unavailable. The only git command in Conductor."""
    try:
        env = dict((k, v) for k, v in os.environ.items() if not k.startswith("GIT_"))
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        p = subprocess.run(
            ["git", "--no-optional-locks", "-c", "core.fsmonitor=false",
             "-c", "core.hooksPath=/dev/null", "rev-parse", "--verify", "HEAD"],
            cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, timeout=GIT_TIMEOUT_SECONDS)
        out = p.stdout.decode("ascii", "replace").strip()
        if p.returncode == 0 and COMMIT_RE.fullmatch(out):
            return out
    except subprocess.TimeoutExpired:
        ctx.note("H007")
    except Exception:
        ctx.note("H007")
    return None


# ---------------------------------------------------------------- checkpoint CLI
# The handoff skill writes, reads and closes checkpoints through this CLI, which
# keeps the write record the pointer hook reads (rule PR-6). It refuses a symbolic
# link, a file that is not a regular file and a real path outside the project root,
# says so, and leaves the target unchanged. Exit codes: 0 done, 2 refused, 3 draft
# headers missing or invalid, 4 secret-shaped string found, 5 another session's
# checkpoint would be overwritten, 6 bad arguments or an invalid name.

MAX_DRAFT = 200 * 1024

CLI_USAGE = """checkpoint commands (python3 hooklib.py checkpoint ...):
  write --session ID [--project DIR] [--from-unverified] [--allow-secret-shaped] < draft
  read NAME [--project DIR]
  list [--project DIR]
  close --session ID [--project DIR]
"""

SECRET_PATTERNS = [
    ("an access key id", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("a private key block", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("an API key", re.compile(r"\bsk-[A-Za-z0-9_-]{20,}")),
    ("a source host token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}")),
    ("a chat token", re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}")),
    ("a cloud key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}")),
    ("a signed token", re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}")),
    ("a credential assignment", re.compile(
        r"(?i)\b(api[_-]?key|secret|token|passwd|password)\b[\"']?\s*[:=]\s*[\"']?[A-Za-z0-9/+_.-]{16,}")),
]


def fail(code, text, rc):
    sys.stderr.write("checkpoint-record: %s\n" % text)
    sys.stderr.write("code %s\n" % code)
    sys.exit(rc)


def project_root(arg):
    root = os.path.realpath(arg or os.getcwd())
    if not os.path.isdir(root):
        fail("C004", "the project folder does not exist", 6)
    return root


def handoffs_dir(root, create):
    hdir = os.path.join(root, "handoffs")
    try:
        st = os.lstat(hdir)
    except FileNotFoundError:
        if not create:
            return None
        os.mkdir(hdir, 0o755)
        st = os.lstat(hdir)
    if stat.S_ISLNK(st.st_mode):
        fail("C001", "handoffs is a symbolic link; refused, nothing was read or written", 2)
    if not stat.S_ISDIR(st.st_mode):
        fail("C001", "handoffs is not a folder; refused, nothing was read or written", 2)
    if not os.path.realpath(hdir).startswith(root.rstrip("/") + "/"):
        fail("C001", "handoffs resolves outside the project; refused", 2)
    return hdir


def check_target(root, path):
    """Refuse a link, a non-regular file or a real path outside the project."""
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return None
    if stat.S_ISLNK(st.st_mode):
        fail("C001", "the checkpoint is a symbolic link; refused, nothing was read or written", 2)
    if not stat.S_ISREG(st.st_mode):
        fail("C001", "the checkpoint is not a regular file; refused, nothing was read or written", 2)
    if not os.path.realpath(path).startswith(root.rstrip("/") + "/"):
        fail("C001", "the checkpoint resolves outside the project; refused", 2)
    return st


def read_bytes(path, limit):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        return os.read(fd, limit)
    finally:
        os.close(fd)


def valid_session(sid):
    if not sid or not SESSION_RE.fullmatch(sid):
        fail("C004", "the session id must be 1 to 64 letters, digits, hyphens or underscores", 6)
    return sid


def header_of(data):
    return parse_header(data[:4096])


def scan_secrets(text):
    hits = []
    for i, line in enumerate(text.split("\n"), 1):
        for label, pat in SECRET_PATTERNS:
            if pat.search(line):
                hits.append((i, label))
                break
    return hits


def validate_draft(text, sid):
    hdr = parse_header(text.encode("utf-8")[:4096])
    if hdr.get("Status") not in ("ACTIVE", "DONE"):
        fail("C002", "the draft needs a first-lines header 'Status: ACTIVE' or 'Status: DONE'", 3)
    if hdr.get("Session") != sid:
        fail("C002", "the draft needs a header 'Session:' equal to the session id given", 3)
    pin = hdr.get("Pinned commit")
    if pin is None or not (pin == "none" or COMMIT_RE.fullmatch(pin)):
        fail("C002", "the draft needs a header 'Pinned commit:' with a 40-character commit id or none", 3)
    if "Updated" not in hdr:
        fail("C002", "the draft needs a header line 'Updated:' (the tool stamps the time)", 3)
    return hdr


def stamp_updated(text):
    lines = text.split("\n")
    for i, ln in enumerate(lines[:12]):
        if re.match(r"^Updated:", ln):
            lines[i] = "Updated: " + iso_now()
            break
    return "\n".join(lines)


def choose_name(root, hdir, sid):
    cur = os.path.join(hdir, "CURRENT.md")
    st = check_target(root, cur)
    if st is None:
        return "CURRENT.md"
    other = header_of(read_bytes(cur, 4096)).get("Session")
    if other == sid:
        return "CURRENT.md"
    qualified = "CURRENT-" + sid + ".md"
    q = os.path.join(hdir, qualified)
    if check_target(root, q) is not None:
        if header_of(read_bytes(q, 4096)).get("Session") != sid:
            fail("C005", "a checkpoint for another session already has that name; not overwritten", 5)
    return qualified


def commit_file(root, hdir, name, text, from_unverified):
    if not NAME_RE.fullmatch(name):
        fail("C004", "the checkpoint name is not valid", 6)
    path = os.path.join(hdir, name)
    check_target(root, path)
    data = text.encode("utf-8")
    fd, tmp = tempfile.mkstemp(prefix=".conductor-tmp.", dir=hdir)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)
    record(root, path, hashlib.sha256(data).hexdigest(), from_unverified)
    return path


def record(root, path, sha, from_unverified):
    rpath = record_path(config_dir())
    data = load_json_file(rpath)
    ents = data.get("entries")
    if not isinstance(ents, dict):
        ents = {}
    prior = ents.get(path) if isinstance(ents.get(path), dict) else {}
    sticky = prior.get("lineage") == "from-unverified"
    ents[path] = {
        "sha256": sha,
        "lineage": "from-unverified" if (from_unverified or sticky) else "own",
        "written": int(time.time()),
    }
    if len(ents) > 200:
        keep = sorted(ents.items(), key=lambda kv: kv[1].get("written", 0))[-200:]
        ents = dict(keep)
    if not save_json_file(rpath, {"schema": 1, "entries": ents}):
        fail("C001", "the write record could not be saved", 2)


def args_of(argv, flags, valued):
    out = {"_": []}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in flags:
            out[a] = True
        elif a in valued and i + 1 < len(argv):
            i += 1
            out[a] = argv[i]
        elif a.startswith("-"):
            fail("C004", "unknown option %s" % sanitize(a, 40), 6)
        else:
            out["_"].append(a)
        i += 1
    return out


def cmd_write(argv):
    a = args_of(argv, ("--from-unverified", "--allow-secret-shaped"), ("--session", "--project"))
    sid = valid_session(a.get("--session"))
    root = project_root(a.get("--project"))
    raw = sys.stdin.buffer.read(MAX_DRAFT + 1)
    if len(raw) > MAX_DRAFT:
        fail("C002", "the draft is larger than 200 KB", 3)
    text = raw.decode("utf-8", "replace")
    validate_draft(text, sid)
    hits = scan_secrets(text)
    if hits and not a.get("--allow-secret-shaped"):
        for line_no, label in hits[:10]:
            sys.stderr.write("checkpoint-record: line %d looks like %s. Name a secret by where it lives, "
                             "never by value. Nothing was written.\n" % (line_no, label))
        fail("C003", "a secret-shaped string was found; fix the draft or repeat with --allow-secret-shaped "
             "after the user confirms", 4)
    hdir = handoffs_dir(root, True)
    name = choose_name(root, hdir, sid)
    path = commit_file(root, hdir, name, stamp_updated(text), bool(a.get("--from-unverified")))
    sys.stdout.write("wrote handoffs/%s\n" % name)
    return 0


def cmd_read(argv):
    a = args_of(argv, (), ("--project",))
    if len(a["_"]) != 1:
        fail("C004", "usage: checkpoint-record read NAME", 6)
    name = a["_"][0]
    if not NAME_RE.fullmatch(name):
        fail("C004", "the checkpoint name is not valid", 6)
    root = project_root(a.get("--project"))
    hdir = handoffs_dir(root, False)
    if hdir is None:
        fail("C004", "there is no handoffs folder", 6)
    path = os.path.join(hdir, name)
    if check_target(root, path) is None:
        fail("C004", "there is no such checkpoint", 6)
    sys.stdout.write(read_bytes(path, MAX_DRAFT).decode("utf-8", "replace"))
    return 0


def cmd_list(argv):
    a = args_of(argv, (), ("--project",))
    root = project_root(a.get("--project"))
    hdir = handoffs_dir(root, False)
    if hdir is None:
        sys.stdout.write("no handoffs folder\n")
        return 0
    refused = 0
    shown = 0
    for n in sorted(os.listdir(hdir))[:200]:
        if not (n.startswith("CURRENT") and n.endswith(".md")):
            continue
        p = os.path.join(hdir, n)
        st = os.lstat(p)
        if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode):
            refused += 1
            continue
        if not NAME_RE.fullmatch(n):
            refused += 1
            continue
        h = header_of(read_bytes(p, 4096))
        status = h.get("Status") if h.get("Status") in ("ACTIVE", "DONE") else "unknown"
        upd = h.get("Updated") if parse_iso(h.get("Updated")) is not None else "unknown"
        sys.stdout.write("%s\t%s\t%s\n" % (n, status, upd))
        shown += 1
    if refused:
        sys.stdout.write("%d entr%s not listed: a link, a non-regular file or a name that is not valid\n"
                         % (refused, "y was" if refused == 1 else "ies were"))
    return 0


def cmd_close(argv):
    a = args_of(argv, (), ("--session", "--project"))
    sid = valid_session(a.get("--session"))
    root = project_root(a.get("--project"))
    hdir = handoffs_dir(root, False)
    if hdir is None:
        fail("C004", "there is no handoffs folder", 6)
    target = None
    for n in ("CURRENT.md", "CURRENT-" + sid + ".md"):
        p = os.path.join(hdir, n)
        if check_target(root, p) is not None and header_of(read_bytes(p, 4096)).get("Session") == sid:
            target = n
            break
    if target is None:
        fail("C005", "no checkpoint for this session was found", 5)
    p = os.path.join(hdir, target)
    text = read_bytes(p, MAX_DRAFT).decode("utf-8", "replace")
    lines = text.split("\n")
    for i, ln in enumerate(lines[:12]):
        if re.match(r"^Status:", ln):
            lines[i] = "Status: DONE"
            break
    new = stamp_updated("\n".join(lines))
    prior = load_record(config_dir()).get(p)
    was_unverified = isinstance(prior, dict) and prior.get("lineage") == "from-unverified"
    commit_file(root, hdir, target, new, was_unverified)
    sys.stdout.write("closed handoffs/%s\n" % target)
    return 0


def checkpoint_cli(argv):
    if not argv or argv[0] not in ("write", "read", "list", "close"):
        sys.stderr.write(CLI_USAGE)
        return 6
    fn = {"write": cmd_write, "read": cmd_read, "list": cmd_list, "close": cmd_close}[argv[0]]
    return fn(argv[1:])


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "checkpoint":
        sys.exit(checkpoint_cli(sys.argv[2:]))
    sys.exit(0)
