#!/usr/bin/env python3
"""release-check.py - the release check. Prints 1 line per check (PASS, FAIL or SKIP) and
exits 1 when any check fails. Python 3.9, standard library only. No network access.

  release-check.py --leak-base FILE [--repo DIR] [--verbatim-sources FILE]
                   [--verbatim-root DIR] [--export-manifest FILE] [--private-files FILE]
                   [--derived-works FILE] [--installer FILE]... [--build-date YYYY-MM-DD]
                   [--allow FILE] [--all-files] [--final]

Checks: the build is in sync; the version agrees in every place; no banned claim string in the
README, the changelog, the notices, the files under .github, payload and release, the other
top-level text files, the installer text or the site text; no cost lead in the README opening
and the installer opening; no "Conductor v2" in the README, changelog, installer text or site
text; no private token or secret shape in install.sh or any payload file; no run of 8 words shared with
a listed private source (and the source list exists and does not overlap the export's copy
sources); no private skill file in the payload; the third-party notices name each derived work;
the dated files are fresh; the size caps hold; the release record and the changelog entry
carry their fields.

--leak-base FILE      the base leak list (1 regex per line, # comments); required
--verbatim-sources    the private source list (1 path per line); a missing or empty list fails
--verbatim-root       what relative paths in the lists are relative to (default: the folder
                      that holds the list)
--export-manifest     an export manifest; a listed private path that is also a copy source fails
--private-files       paths (or sha256 values) of private and partner files that must not ship
--derived-works       names the third-party notices must mention, 1 per line
--installer FILE      another installer to scan (repeatable)
--all-files           run the leak scan and the verbatim check over every file `git ls-files`
                      lists, not only install.sh, the payload and the site text. Files under
                      site/ are reported on their own lines (leak-scan-site, verbatim-site)
                      because the site copy is decided separately. Needs a git checkout.
--allow FILE          literal strings (1 per line, # comments) that may hold a leak-scan hit: a
                      hit is dropped only when the matched text sits inside an allowed string
                      on that line. The check prints how many hits were allowed, never the strings.
--build-date          the date the age checks count from (default: today)
--final               a SKIP counts as a failure, a placeholder in the record is a failure and
                      the changelog's installer sha256 line must equal the sha256 of install.sh
                      or say the checksum is given beside the installer file

The doctrine size is an estimate: characters divided by 3.2, rounded up; not a tokenizer.
Exit codes: 0 every check passed (or skipped without --final); 1 a check failed; 2 usage error.
"""
import datetime
import hashlib
import json
import math
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import export  # noqa: E402  (the same secret shapes and leak list reader as the export tool)

EMIT_RE = re.compile(r"^emit_[A-Za-z0-9_]+\(\) \{ cat <<'(CONDUCTOR_EOF_[A-Z0-9_]+)'$")
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
DATE_RE = re.compile(r"\b(\d{4})-(\d{2})-(\d{2})\b")
BANNED = [("60-80", r"60[-\u2013\u2014]80"), ("3-5x", r"3[-\u2013\u2014]5x"), ("Copilot", r"copilot"),
          ("Gemini", r"gemini"), ("Antigravity", r"antigravity")]
COST_RE = re.compile(r"\b(cheaper|cheap|cost less|savings|save money|save tokens)\b", re.IGNORECASE)
V2_RE = re.compile(r"Conductor v2|Conductor 2|v2 release", re.IGNORECASE)
TOKEN_DIVISOR = 3.2
DOCTRINE_CAP = 2500
DESCRIPTION_CAP = 300
HANDOFF_CAP = 8192
PLACEHOLDER_RE = re.compile(r"<filled[^>]*>")
SHA_GIVEN_BESIDE = "given beside the installer file"
PUBLISHED_TOP = ("CHANGELOG.md", "THIRD-PARTY-NOTICES.md", "SPEC.md", "LICENSE")
PUBLISHED_DIRS = (".github", "payload", "release")
ORIGINAL_RE = re.compile(r"\boriginal\s+work\b", re.IGNORECASE)
NO_UPSTREAM_RE = re.compile(r"\bno\s+upstream\b", re.IGNORECASE)
RECORD_HEADINGS = [
    ("commit", r"^##\s+Commit"), ("installer sha256", r"^##\s+Installer sha256"),
    ("version strings", r"^##\s+Version strings"), ("Codex model map", r"^##\s+Codex model map"),
    ("gates", r"^##\s+Gates"), ("bench run ids", r"^##\s+Bench run ids"), ("test runs", r"^##\s+Test runs"),
    ("review tier", r"^##\s+Review tier"), ("approver", r"^##\s+Approver"), ("cso report", r"^##\s+cso report"),
    ("tokenizer", r"^##\s+Tokenizer"), ("update fetch rules", r"^##\s+Update fetch rules"),
    ("tag v0.3.0", r"^##\s+Tag v0\.3\.0"), ("main protection", r"^##\s+Main protection"),
    ("registrar lock", r"^##\s+Registrar lock"), ("2FA", r"^##\s+2-factor"),
]


class Results:
    def __init__(self, final):
        self.final = final
        self.failed = False
        self.lines = []

    def add(self, state, name, detail=""):
        if state == "SKIP" and self.final:
            state = "FAIL"
            detail = "not run (%s)" % detail
        if state == "FAIL":
            self.failed = True
        line = "%s %s" % (state, name)
        if detail:
            line += ": " + detail
        self.lines.append(line)
        sys.stdout.write(line + "\n")


def brief(items, limit=5):
    items = list(items)
    text = "; ".join(items[:limit])
    if len(items) > limit:
        text += "; (+%d more)" % (len(items) - limit)
    return text


def read_text(path):
    try:
        with open(path, "rb") as fh:
            return fh.read().decode("utf-8")
    except (OSError, UnicodeDecodeError):
        return None


def files_under(folder, suffixes=None):
    found = []
    for base, dirs, files in os.walk(folder):
        dirs[:] = sorted(d for d in dirs if d not in ("__pycache__", ".git", "node_modules"))
        for f in sorted(files):
            if f.endswith(".pyc") or f == ".DS_Store":
                continue
            if suffixes is None or f.endswith(suffixes):
                found.append(os.path.join(base, f))
    return found


def installer_parts(text):
    """(text without the embedded payload bodies and the #@@ data lines, the opening text)."""
    lines = text.split("\n")
    kept = []
    i = 0
    while i < len(lines):
        m = EMIT_RE.match(lines[i])
        if m:
            j = i + 1
            while j < len(lines) and lines[j] != m.group(1):
                j += 1
            i = j + 1
            continue
        if not lines[i].startswith("#@@"):
            kept.append(lines[i])
        i += 1
    opening = []
    for ln in kept:
        opening.append(ln)
        if ln.strip() == "set -u":
            break
    body = "\n".join(kept)
    for name in ("banner", "usage"):
        m = re.search(r"^%s\(\) \{\n(.*?)^\}$" % name, body, re.DOTALL | re.MULTILINE)
        if m:
            opening.append(m.group(1))
    return "\n".join(kept), "\n".join(opening)


def components_version(repo):
    try:
        with open(os.path.join(repo, "payload", "components.json"), encoding="utf-8") as fh:
            return json.load(fh).get("version")
    except (OSError, ValueError):
        return None


def line_of(text, pos):
    return text.count("\n", 0, pos) + 1


# ---------------------------------------------------------------- checks

def check_build(r, repo):
    script = os.path.join(repo, "tools", "build.py")
    if not os.path.isfile(script):
        r.add("FAIL", "build-sync", "tools/build.py is missing")
        return
    res = subprocess.run([sys.executable, "-B", script, "--check"], cwd=repo, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, universal_newlines=True)
    first = (res.stdout.strip().split("\n") or [""])[0]
    if res.returncode == 0:
        r.add("PASS", "build-sync", first)
    else:
        r.add("FAIL", "build-sync", brief(l for l in res.stdout.strip().split("\n") if l.strip()))


def check_versions(r, repo):
    want = components_version(repo)
    if not want or not VERSION_RE.match(want):
        r.add("FAIL", "versions", "payload/components.json has no valid version")
        return
    found = [("payload/components.json", want)]

    def first_line(rel):
        t = read_text(os.path.join(repo, rel))
        return t.strip().split("\n")[0].strip() if t and t.strip() else None

    for rel in ("payload/claude/skills/conductor/VERSION", "payload/codex/skills/conductor/VERSION"):
        found.append((rel, first_line(rel)))
    try:
        with open(os.path.join(repo, "payload/claude/conductor/lib/facts.json"), encoding="utf-8") as fh:
            found.append(("payload/claude/conductor/lib/facts.json", json.load(fh).get("version")))
    except (OSError, ValueError):
        found.append(("payload/claude/conductor/lib/facts.json", None))
    inst = read_text(os.path.join(repo, "install.sh"))
    if inst is None:
        found.append(("install.sh", None))
    else:
        vers = re.findall(r'^CONDUCTOR_VERSION="([^"]*)"$', inst, re.MULTILINE)
        found.append(("install.sh CONDUCTOR_VERSION", vers[0] if len(vers) == 1 else None))
        for m in re.finditer(r'^BEGIN_MARKER="(.*)"$', inst, re.MULTILINE):
            lit = re.search(r"\(managed\) v([0-9][0-9A-Za-z.\-]*) ", m.group(1))
            if lit:
                found.append(("install.sh BEGIN_MARKER", lit.group(1)))
            elif "v${CONDUCTOR_VERSION}" not in m.group(1):
                found.append(("install.sh BEGIN_MARKER", None))
    for f in files_under(os.path.join(repo, "payload")):
        t = read_text(f)
        for m in re.finditer(r"BEGIN CONDUCTOR \(managed\) v([0-9][0-9A-Za-z.\-]*)", t or ""):
            found.append((os.path.relpath(f, repo) + " marker", m.group(1)))
    cl = read_text(os.path.join(repo, "CHANGELOG.md"))
    top = re.search(r"^##\s+v?([0-9]+\.[0-9]+\.[0-9]+)", cl or "", re.MULTILINE)
    found.append(("CHANGELOG.md top heading", top.group(1) if top else None))
    bad = ["%s=%s" % (n, v if v else "missing") for n, v in found if v != want]
    if bad:
        r.add("FAIL", "versions", "expected %s; %s" % (want, brief(bad)))
    else:
        r.add("PASS", "versions", "%d places agree on %s" % (len(found), want))


def scan_regex(text, regex):
    return [(line_of(text, m.start()), m.group(0)) for m in regex.finditer(text)]


def published_text(repo):
    """(relative path, text) of the published text files the README scan does not already
    read: the changelog, the notices, SPEC.md and LICENSE, and every file under .github,
    payload and release. site/ is read separately and bench/, tests/ and tools/ are not
    published text."""
    paths = [os.path.join(repo, name) for name in PUBLISHED_TOP]
    for folder in PUBLISHED_DIRS:
        paths += files_under(os.path.join(repo, folder))
    found = []
    for path in paths:
        text = read_text(path)
        if text is not None:
            found.append((os.path.relpath(path, repo), text))
    return found


def tracked_files(repo):
    """The paths `git ls-files` lists in repo (relative, sorted). Refused outside a git checkout."""
    try:
        res = subprocess.run(["git", "-C", repo, "ls-files", "-z"], stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE)
    except OSError:
        raise export.Refused("--all-files needs git on the PATH")
    if res.returncode != 0:
        raise export.Refused("--all-files needs a git checkout: git ls-files failed in %s" % repo)
    names = [n for n in res.stdout.decode("utf-8", "replace").split("\0") if n]
    return sorted(names)


def under_site(rel):
    return rel == "site" or rel.startswith("site/")


def check_text_scans(r, repo, installers):
    readme = read_text(os.path.join(repo, "README.md")) or ""
    changelog = read_text(os.path.join(repo, "CHANGELOG.md")) or ""
    inst_all = []
    for path in [os.path.join(repo, "install.sh")] + installers:
        t = read_text(path)
        if t is not None:
            inst_all.append((os.path.basename(path) if path != os.path.join(repo, "install.sh") else "install.sh",) + installer_parts(t))
    site = []
    for f in files_under(os.path.join(repo, "site"), (".html", ".md", ".txt", ".xml", ".json")):
        t = read_text(f)
        if t is not None:
            site.append((os.path.relpath(f, repo), t))
    published = published_text(repo)
    shipped = [("README.md", readme)] + [(n, body) for n, body, _ in inst_all] + published + site
    hits = []
    for name, text in shipped:
        for label, pat in BANNED:
            for ln, _ in scan_regex(text, re.compile(pat, re.IGNORECASE)):
                hits.append("%s:%d %s" % (name, ln, label))
    r.add("FAIL" if hits else "PASS", "banned-strings",
          brief(hits) if hits else "0 matches in the README, %d other published text files, the installer text and the site text" % len(published))

    opening = [("README.md first 20 lines", "\n".join(readme.split("\n")[:20]))] + [("%s opening text" % n, op) for n, _, op in inst_all]
    hits = ["%s:%d %s" % (name, ln, w) for name, text in opening for ln, w in scan_regex(text, COST_RE)]
    r.add("FAIL" if hits else "PASS", "cost-words", brief(hits) if hits else "0 matches in the README opening and the installer opening text")

    v2 = [("README.md", readme), ("CHANGELOG.md", changelog)] + [(n, body) for n, body, _ in inst_all] + site
    hits = ["%s:%d %s" % (name, ln, w) for name, text in v2 for ln, w in scan_regex(text, V2_RE)]
    r.add("FAIL" if hits else "PASS", "v2-strings", brief(hits) if hits else "0 matches for Conductor v2, Conductor 2 and v2 release")


def covered(line, match, allow):
    """True when the matched text sits inside 1 occurrence of an allowed literal string."""
    for lit in allow:
        pos = line.find(lit)
        while pos != -1:
            if pos <= match.start() and match.end() <= pos + len(lit):
                return True
            pos = line.find(lit, pos + 1)
    return False


def leak_scan(repo, checks, targets, allow):
    """(hits, allowed, scanned) of the leak checks over the target paths."""
    hits = []
    allowed = 0
    scanned = 0
    for path in targets:
        text = read_text(path)
        if text is None:
            continue
        scanned += 1
        rel = os.path.relpath(path, repo) if path.startswith(repo + os.sep) else path
        for no, line in enumerate(text.split("\n"), 1):
            flagged = False
            for label, comp in checks:
                for m in comp.finditer(line):
                    if covered(line, m, allow):
                        allowed += 1
                        continue
                    hits.append("%s:%d %s" % (rel, no, label))
                    flagged = True
                    break
                if flagged:
                    break
    return hits, allowed, scanned


def check_leaks(r, repo, leak_base, installers, allow=(), all_files=False):
    base = export.load_leak_base(leak_base)
    checks = [("pattern \"%s\"" % pat, comp) for pat, comp in base]
    checks += [("secret shape: %s" % name, re.compile(pat, re.IGNORECASE)) for name, pat in export.SECRET_SHAPES]
    note = ""
    if all_files:
        tracked = [os.path.join(repo, n) for n in tracked_files(repo)]
        inst = os.path.join(repo, "install.sh")
        targets = [inst] + installers + [p for p in tracked
                                         if p != inst and not under_site(os.path.relpath(p, repo))]
        site = [p for p in tracked if under_site(os.path.relpath(p, repo))]
        what = "every tracked file outside site/"
    else:
        targets = [os.path.join(repo, "install.sh")] + installers + files_under(os.path.join(repo, "payload"))
        site = []
        what = "install.sh and the payload"
    hits, allowed, scanned = leak_scan(repo, checks, targets, allow)
    note = " (%d allowed by --allow)" % allowed if allow else ""
    r.add("FAIL" if hits else "PASS", "leak-scan", brief(hits) if hits else "0 hits in %d files (%s)%s" % (scanned, what, note))
    if all_files:
        hits, allowed, scanned = leak_scan(repo, checks, site, allow)
        note = " (%d allowed by --allow)" % allowed if allow else ""
        r.add("FAIL" if hits else "PASS", "leak-scan-site", brief(hits) if hits else "0 hits in %d site files%s" % (scanned, note))


WORD_RE = re.compile(r"[a-z0-9]+(?:'[a-z]+)?")


def words_of(text):
    return WORD_RE.findall(text.lower().replace("’", "'"))


def read_list(path):
    text = read_text(path)
    if text is None:
        return None
    return [ln.strip() for ln in text.split("\n") if ln.strip() and not ln.strip().startswith("#")]


def check_verbatim(r, repo, args, installers):
    path = args["verbatim_sources"]
    entries = read_list(path) if path else None
    if not entries:
        r.add("FAIL", "verbatim-sources", "the source list is missing or empty (%s)" % (path or "no --verbatim-sources given"))
        r.add("SKIP", "verbatim", "no source list")
        r.add("SKIP", "export-overlap", "no source list")
        return
    vroot = args["verbatim_root"] or os.path.dirname(os.path.abspath(path))
    private = {}
    missing = []
    for e in entries:
        full = e if os.path.isabs(e) else os.path.join(vroot, e)
        if os.path.isdir(full):
            paths = files_under(full)
        elif os.path.isfile(full):
            paths = [full]
        else:
            missing.append(e)
            continue
        for p in paths:
            t = read_text(p)
            if t is None:
                continue
            w = words_of(t)
            for i in range(len(w) - 7):
                private.setdefault(" ".join(w[i:i + 8]), p)
    if missing:
        r.add("FAIL", "verbatim-sources", "listed source not found: %s" % brief(missing))
        r.add("SKIP", "verbatim", "a listed source is not there")
        r.add("SKIP", "export-overlap", "a listed source is not there")
        return
    r.add("PASS", "verbatim-sources", "%d sources listed and found" % len(entries))
    shipped = []
    site_files = []
    if args["all_files"]:
        inst = os.path.join(repo, "install.sh")
        for n in tracked_files(repo):
            path_ = os.path.join(repo, n)
            if path_ == inst:
                continue
            (site_files if under_site(n) else shipped).append((n, read_text(path_)))
    else:
        for f in files_under(os.path.join(repo, "payload")):
            shipped.append((os.path.relpath(f, repo), read_text(f)))
        for name in ("README.md", "CHANGELOG.md", "THIRD-PARTY-NOTICES.md"):
            shipped.append((name, read_text(os.path.join(repo, name))))
        for f in files_under(os.path.join(repo, "site"), (".html", ".md", ".txt")):
            shipped.append((os.path.relpath(f, repo), read_text(f)))
    for path_ in [os.path.join(repo, "install.sh")] + installers:
        t = read_text(path_)
        if t is not None:
            shipped.append((os.path.basename(path_), installer_parts(t)[0]))

    def shared_hits(files):
        found = []
        for name, text in files:
            if not text:
                continue
            w = words_of(text)
            for i in range(len(w) - 7):
                src = private.get(" ".join(w[i:i + 8]))
                if src:
                    found.append("%s shares 8 consecutive words with %s" % (name, os.path.relpath(src, vroot) if src.startswith(vroot) else src))
                    break
        return found

    hits = shared_hits(shipped)
    r.add("FAIL" if hits else "PASS", "verbatim", brief(hits) if hits else "no run of 8 words shared with %d private sources" % len(entries))
    if args["all_files"]:
        hits = shared_hits(site_files)
        r.add("FAIL" if hits else "PASS", "verbatim-site", brief(hits) if hits else "no run of 8 words shared with %d private sources" % len(entries))

    mpath = args["export_manifest"]
    if not mpath:
        r.add("SKIP", "export-overlap", "no --export-manifest given")
        return
    mtext = read_text(mpath)
    if mtext is None:
        r.add("FAIL", "export-overlap", "the export manifest cannot be read: %s" % mpath)
        return
    copy_src = []
    for ln in mtext.split("\n"):
        mt = re.match(r"^\s*(copy|copy-tree|portable)\s+(\S+)\s+->", ln)
        if mt:
            copy_src.append((mt.group(1), mt.group(2).rstrip("/")))
    clash = []
    for e in entries:
        rel = os.path.relpath(e, vroot) if os.path.isabs(e) else e
        rel = rel.rstrip("/")
        for kind, src in copy_src:
            if rel == src or rel.startswith(src + "/") or src.startswith(rel + "/"):
                clash.append(e)
                break
    r.add("FAIL" if clash else "PASS", "export-overlap", ("a verbatim source is also a copy source: " + brief(clash)) if clash else "no listed source is a copy source")


def check_private_files(r, repo, path):
    entries = read_list(path) if path else None
    if entries is None:
        r.add("SKIP", "private-files", "no --private-files given" if not path else "the list cannot be read: %s" % path)
        return
    payload = os.path.join(repo, "payload")
    present = []
    hashes = {}
    rels = {}
    for f in files_under(payload):
        rel = os.path.relpath(f, payload)
        with open(f, "rb") as fh:
            hashes.setdefault(hashlib.sha256(fh.read()).hexdigest(), []).append(rel)
        rels.setdefault(rel, []).append(rel)
        parts = rel.split("/", 1)
        if len(parts) == 2:
            rels.setdefault(parts[1], []).append(rel)
    for e in entries:
        found = hashes.get(e, []) if re.match(r"^[0-9a-f]{64}$", e) else rels.get(e, [])
        for rel in found:
            if rel not in present:
                present.append(rel)
    r.add("FAIL" if present else "PASS", "private-files", ("private files in the payload: " + brief(present)) if present else "0 of %d listed files are in the payload" % len(entries))


def check_notices(r, repo, derived_path):
    notices = read_text(os.path.join(repo, "THIRD-PARTY-NOTICES.md"))
    if notices is None:
        r.add("FAIL", "notices", "THIRD-PARTY-NOTICES.md is missing")
        return
    problems = []
    names = read_list(derived_path) if derived_path else None
    if names is not None:
        for n in names:
            if n.lower() not in notices.lower():
                problems.append("does not name %s" % n)
    sections = re.split(r"(?m)^#{1,6}\s+", notices)
    for f in files_under(os.path.join(repo, "payload")):
        base = os.path.basename(f)
        if not base.endswith(".workflow.js"):
            continue
        sec = next((s for s in sections if base in s), None)
        if sec is None:
            problems.append("the vendored template %s has no section" % base)
            continue
        if ORIGINAL_RE.search(sec) and NO_UPSTREAM_RE.search(sec):
            continue  # stated as original work with no upstream: not a derived work
        for label, pat in (("an upstream address", r"https?://\S+"), ("a pinned commit (40 hex digits)", r"\b[0-9a-f]{40}\b"),
                           ("a license", r"licen[cs]e"), ("local changes", r"local change|modified|changes? made")):
            if not re.search(pat, sec, re.IGNORECASE):
                problems.append("the section for %s lacks %s" % (base, label))
    if problems:
        r.add("FAIL", "notices", brief(problems))
    elif names is None:
        r.add("SKIP", "notices", "no --derived-works given (the vendored template section is complete)")
    else:
        r.add("PASS", "notices", "each derived work and the vendored template are named")


def age_days(date_text, build_date):
    m = DATE_RE.search(date_text or "")
    if not m:
        return None
    try:
        d = datetime.date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
    except ValueError:
        return None
    return (build_date - d).days


def check_dates(r, repo, build_date, version):
    rel = "payload/claude/conductor/model-notes.md"
    text = read_text(os.path.join(repo, rel))
    if text is None:
        r.add("FAIL", "model-notes-date", "%s is missing" % rel)
    else:
        m = re.search(r"verified on\s*:?\s*(\d{4}-\d{2}-\d{2})", text, re.IGNORECASE)
        age = age_days(m.group(1), build_date) if m else None
        if age is None:
            r.add("FAIL", "model-notes-date", "%s has no 'verified on' date" % rel)
        elif age > 90 or age < 0:
            r.add("FAIL", "model-notes-date", "%s was verified %d days before the build date (limit 90)" % (rel, age))
        else:
            r.add("PASS", "model-notes-date", "verified %d days before the build date" % age)
    rec_rel = "release/RECORD-%s.md" % version
    rec = read_text(os.path.join(repo, rec_rel))
    if rec is None:
        r.add("FAIL", "codex-map-date", "%s is missing" % rec_rel)
        return
    sec = re.search(r"(?ms)^##\s+Codex model map\s*$(.*?)(?=^##\s|\Z)", rec)
    dated = re.search(r"(?im)^\s*(?:check date|map ids re-checked on)\s*:\s*(.*)$", sec.group(1)) if sec else None
    age = age_days(dated.group(1), build_date) if dated else None
    if age is None:
        r.add("FAIL", "codex-map-date", "%s has no check date in its Codex model map section" % rec_rel)
    elif age > 14 or age < 0:
        r.add("FAIL", "codex-map-date", "%s: the Codex model map was checked %d days before the build date (limit 14)" % (rec_rel, age))
    else:
        r.add("PASS", "codex-map-date", "checked %d days before the build date" % age)


def description_of(text):
    m = re.match(r"^---\n(.*?)\n---\n", text, re.DOTALL)
    if not m:
        return None
    lines = m.group(1).split("\n")
    for i, ln in enumerate(lines):
        mt = re.match(r"^description:\s*(.*)$", ln)
        if not mt:
            continue
        val = mt.group(1).strip()
        if val in (">", "|", ">-", "|-"):
            parts = []
            for nxt in lines[i + 1:]:
                if nxt.startswith(" ") or nxt.startswith("\t"):
                    parts.append(nxt.strip())
                else:
                    break
            return " ".join(parts)
        if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
            val = val[1:-1]
        return val
    return None


def check_sizes(r, repo):
    marker_len = len("<!-- BEGIN CONDUCTOR (managed) v0.0.0 - https://conductorskill.com -->") + len("<!-- END CONDUCTOR (managed) -->") + 2
    figures, over = [], []
    for rel in ("payload/claude/doctrine.md", "payload/codex/doctrine.md"):
        t = read_text(os.path.join(repo, rel))
        if t is None:
            over.append("%s is missing" % rel)
            continue
        est = int(math.ceil((len(t) + marker_len) / TOKEN_DIVISOR))
        figures.append("%s %d" % (rel, est))
        if est > DOCTRINE_CAP:
            over.append("%s is about %d tokens (cap %d)" % (rel, est, DOCTRINE_CAP))
    r.add("FAIL" if over else "PASS", "size-doctrine", (brief(over) if over else "estimate, characters divided by 3.2, rounded up: " + "; ".join(figures)))
    bad, count = [], 0
    for f in files_under(os.path.join(repo, "payload"), "SKILL.md"):
        count += 1
        d = description_of(read_text(f) or "")
        rel = os.path.relpath(f, repo)
        if d is None:
            bad.append("%s has no description" % rel)
        elif len(d) > DESCRIPTION_CAP:
            bad.append("%s description is %d characters (cap %d)" % (rel, len(d), DESCRIPTION_CAP))
    r.add("FAIL" if bad else "PASS", "size-descriptions", brief(bad) if bad else "%d skill descriptions within %d characters" % (count, DESCRIPTION_CAP))
    handoff = os.path.join(repo, "payload/claude/skills/handoff/SKILL.md")
    t = read_text(handoff)
    if t is None:
        r.add("FAIL", "size-handoff", "payload/claude/skills/handoff/SKILL.md is missing")
    else:
        body = re.sub(r"^---\n.*?\n---\n", "", t, count=1, flags=re.DOTALL)
        n = len(body.encode("utf-8"))
        r.add("FAIL" if n > HANDOFF_CAP else "PASS", "size-handoff", "body is %d bytes (cap %d)" % (n, HANDOFF_CAP))


def check_record(r, repo, version, final):
    rel = "release/RECORD-%s.md" % version
    text = read_text(os.path.join(repo, rel))
    if text is None:
        r.add("FAIL", "record-fields", "%s is missing" % rel)
        return
    missing = [name for name, pat in RECORD_HEADINGS if not re.search(pat, text, re.MULTILINE)]
    for n in range(1, 7):
        if not re.search(r"^###\s+Gate %d\b" % n, text, re.MULTILINE):
            missing.append("gate %d" % n)
    if "estimate, characters divided by 3.2, rounded up; not a tokenizer" not in text:
        missing.append("the tokenizer statement")
    if not re.search(r"built in bash 3\.2:\s*(yes|no)", text):
        missing.append("the bash 3.2 statement")
    if "b9bd18bfda85ae06a8bedf0cd97ffb302932958e" not in text:
        missing.append("the v0.3.0 tag commit")
    if missing:
        r.add("FAIL", "record-fields", "%s lacks: %s" % (rel, brief(missing, 8)))
        return
    left = PLACEHOLDER_RE.findall(text)
    if final and left:
        r.add("FAIL", "record-fields", "%s still holds %d placeholder(s)" % (rel, len(left)))
    else:
        r.add("PASS", "record-fields", "every field is present%s" % (" (%d not filled yet)" % len(left) if left else ""))


def check_changelog(r, repo, final):
    cl = read_text(os.path.join(repo, "CHANGELOG.md"))
    if cl is None:
        r.add("FAIL", "changelog-entry", "CHANGELOG.md is missing")
        return
    parts = re.split(r"(?m)^##\s+", cl)
    if len(parts) < 2:
        r.add("FAIL", "changelog-entry", "CHANGELOG.md has no version section")
        return
    top = parts[1]
    missing = []
    if not re.search(r"upgrade", top, re.IGNORECASE):
        missing.append("upgrade notes")
    if not re.search(r"effort", top, re.IGNORECASE):
        missing.append("the effort explanation")
    m = re.search(r"^Installer sha256:\s*(.+?)\s*$", top, re.MULTILINE)
    if not m:
        missing.append("an 'Installer sha256:' line")
    elif m.group(1) == SHA_GIVEN_BESIDE:
        pass  # the checksum is published beside the installer file, so the line carries none
    elif final:
        inst = os.path.join(repo, "install.sh")
        try:
            with open(inst, "rb") as fh:
                actual = hashlib.sha256(fh.read()).hexdigest()
        except OSError:
            actual = None
        if m.group(1) != actual:
            missing.append("an installer sha256 equal to the sha256 of install.sh")
    elif not (PLACEHOLDER_RE.fullmatch(m.group(1)) or re.match(r"^[0-9a-f]{64}$", m.group(1))):
        missing.append("a sha256 value, the placeholder <filled at release> or the words '%s'" % SHA_GIVEN_BESIDE)
    if missing:
        r.add("FAIL", "changelog-entry", "the top changelog entry lacks: %s" % brief(missing))
    else:
        r.add("PASS", "changelog-entry", "upgrade notes, effort explanation and installer sha256 line are present")


# ---------------------------------------------------------------- command line

def parse_args(argv):
    args = {"repo": os.path.dirname(HERE), "leak_base": None, "verbatim_sources": None, "verbatim_root": None,
            "export_manifest": None, "private_files": None, "derived_works": None, "installers": [],
            "build_date": None, "final": False, "allow": None, "all_files": False}
    valued = {"--repo": "repo", "--leak-base": "leak_base", "--verbatim-sources": "verbatim_sources",
              "--verbatim-root": "verbatim_root", "--export-manifest": "export_manifest",
              "--private-files": "private_files", "--derived-works": "derived_works", "--build-date": "build_date",
              "--allow": "allow"}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--help", "-h"):
            sys.stdout.write(__doc__)
            sys.exit(0)
        if a == "--final":
            args["final"] = True
            i += 1
        elif a == "--all-files":
            args["all_files"] = True
            i += 1
        elif a == "--installer":
            if i + 1 >= len(argv):
                raise SystemExit(usage("--installer needs a value"))
            args["installers"].append(argv[i + 1])
            i += 2
        elif a in valued:
            if i + 1 >= len(argv):
                raise SystemExit(usage("%s needs a value" % a))
            args[valued[a]] = argv[i + 1]
            i += 2
        else:
            raise SystemExit(usage("unknown argument: %s" % a))
    if not args["leak_base"]:
        raise SystemExit(usage("--leak-base FILE is required"))
    if args["allow"] is not None:
        allow = read_list(args["allow"])
        if allow is None:
            raise SystemExit(usage("--allow file cannot be read: %s" % args["allow"]))
        args["allow"] = allow
    if args["build_date"]:
        try:
            args["build_date"] = datetime.datetime.strptime(args["build_date"], "%Y-%m-%d").date()
        except ValueError:
            raise SystemExit(usage("--build-date must look like 2026-10-12"))
    else:
        args["build_date"] = datetime.date.today()
    args["repo"] = os.path.abspath(args["repo"])
    return args


def usage(msg):
    sys.stderr.write("release-check: %s\nRun: release-check.py --help\n" % msg)
    return 2


def main(argv=None):
    args = parse_args(list(sys.argv[1:] if argv is None else argv))
    repo = args["repo"]
    r = Results(args["final"])
    version = components_version(repo) or "0.0.0"
    installers = [os.path.abspath(p) for p in args["installers"]]
    try:
        check_build(r, repo)
        check_versions(r, repo)
        check_text_scans(r, repo, installers)
        check_leaks(r, repo, args["leak_base"], installers, args["allow"] or (), args["all_files"])
        check_verbatim(r, repo, args, installers)
        check_private_files(r, repo, args["private_files"])
        check_notices(r, repo, args["derived_works"])
        check_dates(r, repo, args["build_date"], version)
        check_sizes(r, repo)
        check_record(r, repo, version, args["final"])
        check_changelog(r, repo, args["final"])
    except export.Refused as exc:
        sys.stderr.write("release-check: %s\n" % exc)
        return 2
    passes = sum(1 for l in r.lines if l.startswith("PASS"))
    fails = sum(1 for l in r.lines if l.startswith("FAIL"))
    skips = sum(1 for l in r.lines if l.startswith("SKIP"))
    sys.stdout.write("release-check: %d passed, %d failed, %d skipped\n" % (passes, fails, skips))
    return 1 if r.failed else 0


if __name__ == "__main__":
    sys.exit(main())
