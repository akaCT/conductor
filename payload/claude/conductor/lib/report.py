#!/usr/bin/env python3
"""conductor report: a bug report you read and send yourself. Python 3.9, standard library only.

The report holds the 10 bug fields and nothing else: version, method, runtime, provider,
seats, judge rung, hooks, error codes, config roots (as tokens) and file counts. Each value
must match its allowed set or a strict pattern, else it is reported as "other"; a value
that looks like a path or a key drops its field and the report says so. The whole bundle
is shown, written to a local file, and only after a yes opened in your browser as a
prefilled new-issue address (no shell, no label). Conductor makes no network call itself.
"""
import argparse
import os
import re
import subprocess
import sys
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
sys.dont_write_bytecode = True  # no __pycache__ folder inside the config folder
import doctor  # noqa: E402  (the same reader the doctor uses)

MAX_URL = 4000
TITLE = "Conductor bug report"
SHORT_BODY = ("The full report was written to a local file on my machine. "
              "I will paste it below.")
PROVIDERS = ("first-party", "bedrock", "vertex", "foundry", "anthropic-aws", "mantle",
             "custom-base-url", "host-managed", "unknown")
SEAT_NAMES = tuple(s for s, _ in doctor.SEATS)
SOURCES = ("agent file", "settings pin", "inherited")
EXPECTED_RE = re.compile(r"^(Opus|Sonnet|Haiku|Fable) [0-9]+(\.[0-9]+)?$")
EXPECTED_WORDS = ("unknown", "not stated", "older model")
HOOK_BUG_NAMES = tuple(n for _, n in doctor.HOOK_NAMES)
COMPONENT_NAMES = ("core", "full", "hook_pointer", "hook_nudge", "hook_usage_split",
                   "hook_project_home", "hook_contract")
METHODS = ("installer", "plugin", "manual")
CODE_RE = re.compile(r"^[A-Z][0-9]{3}$")


class Bundle:
    def __init__(self):
        self.dropped = []

    def pick(self, field, raw, allowed=None, pattern=None):
        """A value from the user's files, or 'other'. A path-shaped or key-shaped value
        drops the field's value ('dropped' is then noted in the bundle)."""
        if not isinstance(raw, str):
            return "other"
        if doctor.looks_path(raw) or doctor.looks_secret(raw):
            if field not in self.dropped:
                self.dropped.append(field)
            return "other"
        if allowed is not None and raw in allowed:
            return raw
        if pattern is not None and pattern.match(raw):
            return raw
        return "other"


def count_value(b, field, raw):
    if isinstance(raw, bool) or not isinstance(raw, int) or raw < 0 or raw > 99999:
        return "other"
    return str(raw)


def make_bundle(info):
    """(text, dropped field names) for an installed config. Nothing outside the 10 bug
    fields is read into it."""
    b = Bundle()
    rec = info["record"] if info["record_kind"] == "v04" and isinstance(info["record"], dict) else {}
    lines = ["Conductor bug report (made by conductor report)"]

    raw_version = None
    if info["record_kind"] in ("v04", "v030") and isinstance(info["record"], dict):
        raw_version = info["record"].get("version")
    version = b.pick("version", raw_version, pattern=doctor.VERSION_RE)
    lines.append("version: %s" % version)

    method = b.pick("method", rec.get("method"), allowed=METHODS) if rec else ("installer" if info["record_kind"] == "v030" else "other")
    comps = rec.get("components") if isinstance(rec.get("components"), list) else []
    tier = "full" if "full" in comps else "core"
    lines.append("method: %s, %s" % (method, tier))

    claude = info["claude_version"] if info["claude_version"] else ("not found" if info["claude_version_raw"] is None else "other")
    codex = info["codex_version"] if info["codex_version"] else ("not found" if info["codex_version_raw"] is None else "other")
    py = b.pick("runtime", info["python_version"], pattern=doctor.VERSION_RE)
    lines.append("runtime: claude %s; codex %s; python3 %s" % (claude, codex, py))

    lines.append("provider: %s" % b.pick("provider", info["provider"], allowed=PROVIDERS))

    lines.append("seats:")
    for s in info["seats"]:
        name = s["seat"]
        alias = s["alias"] if s["alias_state"] in ("file", "seat map") else "missing"
        alias_v = b.pick("seats", alias, allowed=doctor.KNOWN_ALIASES)
        expected = b.pick("seats", s["expected"], allowed=EXPECTED_WORDS, pattern=EXPECTED_RE)
        source = b.pick("seats", s["source"], allowed=SOURCES)
        lines.append("- %s: %s, %s, %s" % (name, alias_v, expected, source))

    rung = info["judge"]["rung"]
    lines.append("judge_rung: %s" % (str(rung) if rung in (1, 2, 3) else "other"))

    wired = [n for n in info["hooks_wired"] if n in HOOK_BUG_NAMES]
    lines.append("hooks: %s; hooks running: %s" % (", ".join(wired) if wired else "none",
                                                    "off" if info["kill_switch"] == "off" else "on"))

    codes = [c for c in info["error_codes"] if CODE_RE.match(c)]
    lines.append("error_codes: %s" % (", ".join(codes) if codes else "none"))

    tokens = []
    if info["claude_present"]:
        tokens.append("{claude-dir}")
    if info["codex_present"]:
        tokens.append("{codex-dir}")
    if os.path.isdir(info["roots"]["agents"]):
        tokens.append("{agents-dir}")
    lines.append("roots: %s" % (", ".join(tokens) if tokens else "none"))

    lines.append("counts:")
    counts = info["files"]["counts"]
    other = {"written": 0, "kept": 0, "modified": 0}
    for comp in sorted(counts):
        c = counts[comp]
        if comp in COMPONENT_NAMES:
            lines.append("- %s: written %s, kept %s, modified %s" % (
                comp, count_value(b, "counts", c["written"]), count_value(b, "counts", c["kept"]),
                count_value(b, "counts", c["modified"])))
        else:
            for k in other:
                other[k] += c[k]
    if any(other.values()):
        lines.append("- other: written %s, kept %s, modified %s" % (
            count_value(b, "counts", other["written"]), count_value(b, "counts", other["kept"]),
            count_value(b, "counts", other["modified"])))
    if not counts:
        lines.append("- none recorded")

    if b.dropped:
        lines.append("dropped (looked like a path or a key): %s" % ", ".join(b.dropped))
    return "\n".join(lines) + "\n", b.dropped


def build_url(title, body, repo):
    """The prefilled new-issue address on github.com, every value percent-encoded, no labels.
    Above the cap the body shrinks to a short fixed text."""
    base = "https://github.com/%s/issues/new" % repo

    def make(t, bd):
        return "%s?title=%s&body=%s" % (base, urllib.parse.quote(t, safe=""), urllib.parse.quote(bd, safe=""))

    url = make(title, body)
    if len(url) > MAX_URL:
        url = make(title, SHORT_BODY)
    return url


def open_tty():
    """A descriptor on the controlling terminal, or None when there is none."""
    try:
        return os.open("/dev/tty", os.O_RDWR | os.O_NOCTTY)
    except OSError:
        return None


def has_terminal():
    fd = open_tty()
    if fd is None:
        return False
    os.close(fd)
    return True


def ask_yes_no(question):
    """True only for a typed yes. The default is no."""
    fd = open_tty()
    if fd is None:
        return False
    try:
        os.write(fd, ("%s [y/N]: " % question).encode("utf-8"))
        data = b""
        while not data.endswith(b"\n") and len(data) < 200:
            ch = os.read(fd, 1)
            if not ch:
                break
            data += ch
    except OSError:
        return False
    finally:
        os.close(fd)
    return data.decode("utf-8", "replace").strip().lower() in ("y", "yes")


def choose_opener(env):
    """The program that opens the address, or None. CONDUCTOR_TEST_OPENER is for the test
    suite: an absolute path to an executable file inside the sandbox that CONDUCTOR_TEST_SANDBOX
    names, with HOME inside it too."""
    test = env.get("CONDUCTOR_TEST_OPENER", "")
    if test:
        sandbox = env.get("CONDUCTOR_TEST_SANDBOX", "")
        home = env.get("HOME", "")
        ok = bool(sandbox) and os.path.isabs(test) and os.path.isfile(test) and os.access(test, os.X_OK)
        if ok:
            sb = os.path.realpath(sandbox) + os.sep
            ok = os.path.realpath(test).startswith(sb) and os.path.realpath(home).startswith(sb)
        return test if ok else None
    import shutil
    name = "open" if sys.platform == "darwin" else "xdg-open"
    return shutil.which(name)


def write_report(root, text):
    folder = os.path.join(root, "conductor")
    stamp = "%s-%d" % (time.strftime("%Y%m%d-%H%M%S"), os.getpid())
    path = os.path.join(folder, "report-%s.txt" % stamp)
    try:
        os.makedirs(folder, exist_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.chmod(path, 0o600)
        return path
    except OSError:
        return None


def main(argv=None):
    ap = argparse.ArgumentParser(prog="report.py", description="Build a bug report you read and send yourself.")
    doctor.common_args(ap)
    args = ap.parse_args(argv)
    try:
        info = doctor.collect(args)
    except doctor.FactsError as exc:
        sys.stderr.write("Conductor report: %s\n" % exc)
        return 1
    out = sys.stdout.write
    if not info["installed"]:
        out("No Conductor install found.\n")
        return 0
    text, dropped = make_bundle(info)
    out("Your report (this is everything it holds):\n\n")
    out(text)
    out("\n")
    root = info["roots"][info["record_harness"] or "claude"]
    path = write_report(root, text)
    if path:
        out("Saved to: %s\n" % path)
    else:
        out("The report could not be saved to a file.\n")
    if dropped:
        out("Some values looked like a path or a key and were left out.\n")
    out("An issue on the public Conductor repository can be read by anyone.\n")
    out("Conductor sends nothing by itself.\n")
    repo = info["facts"].get("report", {}).get("repo", "akaCT/conductor")
    url = build_url(TITLE, text, repo)
    if not has_terminal():
        out("No terminal to ask on, so nothing was opened. The report stays in the file.\n")
        return 0
    if not ask_yes_no("Open a prefilled issue?"):
        out("Nothing was opened. The report stays in the file.\n")
        return 0
    opener = choose_opener(info["env"])
    opened = False
    if opener:
        try:
            res = subprocess.run([opener, url], stdin=subprocess.DEVNULL, timeout=30)
            opened = res.returncode == 0
        except (OSError, subprocess.SubprocessError):
            opened = False
    if opened:
        out("Opened your browser on the prefilled issue. Read it, then send it or close the tab.\n")
    else:
        out("Could not open a browser. This is the address:\n%s\n" % url)
    return 0


if __name__ == "__main__":
    sys.exit(main())
