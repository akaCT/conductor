#!/usr/bin/env python3
"""export.py - copy a product's files from private sources into its public repository
on a local branch, with private content removed, and refuse to write anything that still
carries private content. Python 3.9, standard library only. No network access.

  export.py PRODUCT --check     --root DIR --leak-base FILE [--dest DIR] [--manifest FILE]
  export.py PRODUCT --apply     --root DIR --leak-base FILE [--dest DIR] [--manifest FILE]
                                [--prune] [--no-post]
  export.py PRODUCT --reconcile --root DIR [--only PORTABLE_SRC] [--manifest FILE]
  export.py --status [PRODUCT]  --root DIR
  export.py --list              --root DIR
  export.py --help

--root is the private root that holds the sources, products/PRODUCT.manifest and
products/PRODUCT.lock; it has no default. --leak-base names the base leak list (1 regex per
line, # comments); the lists, the manifests and the sources stay outside the public repo.

Exit codes: 0 in sync or applied; 1 content problem (drift, a leak, a marker error, a
missing source, a rewrite rule that matches nothing, a failed post command); 2 refused (bad
arguments, bad manifest, unsafe path, dirty destination). The tool never commits and never
pushes.

Manifest (1 directive per line; # starts a comment):
  product NAME                       required, must equal the PRODUCT argument
  dest PATH                          required unless --dest is given; ~ is expanded
  branch NAME                        the local branch apply writes on (main, master refused)
  copy SRC -> DST
  copy-tree SRCDIR -> DSTDIR [exclude=GLOB,GLOB]
  portable SRC -> DST [tracks=T;T]   SRC under products/PRODUCT/src/; T is PATH or PATH#HEADING
  rewrite REGEX => REPLACEMENT [in=DSTGLOB]   (spaces around =>)
  leak REGEX
  allow REGEX in=DSTGLOB             in= is required
  post COMMAND                       run with sh -c in dest after apply
"""
import fnmatch
import hashlib
import json
import os
import posixpath
import re
import subprocess
import sys
import tempfile
import time

SECRET_SHAPES = [
    ("a private key header", r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    ("an sk- key", r"sk-[A-Za-z0-9_-]{20,}"),
    ("an sk_live_ key", r"sk_live_[A-Za-z0-9]+"),
    ("an rk_live_ key", r"rk_live_[A-Za-z0-9]+"),
    ("a ghp_ token", r"ghp_[A-Za-z0-9]{16,}"),
    ("a github_pat_ token", r"github_pat_[A-Za-z0-9_]{16,}"),
    ("a Slack token", r"xox[baprs]-[A-Za-z0-9-]{8,}"),
    ("an AWS access key id", r"AKIA[0-9A-Z]{16}"),
    ("a JWT", r"eyJ[A-Za-z0-9_-]{4,}\.eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]+"),
    ("a harness-only marker that is not alone on its line", r"harness-only:"),
]
SKIP_NAMES = {"__pycache__", ".DS_Store", ".git"}
MARKER_RE = re.compile(r"^\s*(?:#|//)?\s*<!-- harness-only:(start|end) -->\s*$")
PROTECTED_BRANCHES = ("main", "master")
DIRECTIVES = ("product", "dest", "branch", "copy", "copy-tree", "portable", "rewrite", "leak", "allow", "post")


class Refused(Exception):
    """A refusal: bad arguments, a bad manifest, an unsafe path, a dirty destination (exit 2)."""


def out(text=""):
    sys.stdout.write(text + "\n")


# ---------------------------------------------------------------- paths

def bad_rel(path):
    """Why a manifest path is refused, or None."""
    if not path:
        return "empty path"
    if path.startswith("/") or re.match(r"^[A-Za-z]:", path):
        return "absolute path"
    if path.startswith("~"):
        return "path starts with ~"
    if "\\" in path:
        return "backslash in path"
    if ".." in path.split("/"):
        return "'..' in path"
    if path.rstrip("/") != path or posixpath.normpath(path) != path:
        return "path is not in its plain form"
    return None


def under(base, path):
    base = os.path.realpath(base)
    path = os.path.realpath(path)
    return path == base or path.startswith(base + os.sep)


def no_symlink_below(base, rel):
    """Refuse when any component of base/rel that exists is a symlink (base itself may be one)."""
    cur = base
    for part in rel.split("/"):
        cur = os.path.join(cur, part)
        if os.path.islink(cur):
            return cur
        if not os.path.lexists(cur):
            break
    return None


# ---------------------------------------------------------------- manifest

class Manifest:
    def __init__(self):
        self.product = None
        self.dest = None
        self.branch = None
        self.files = []      # ("copy"|"copy-tree"|"portable", src, dst, options dict, lineno)
        self.rewrites = []   # (regex text, compiled, replacement, in glob or None, lineno)
        self.leaks = []      # (regex text, compiled, lineno)
        self.allows = []     # (regex text, compiled, glob, lineno)
        self.posts = []
        self.file_directives = 0


def parse_manifest(path, product):
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().split("\n")
    except OSError as exc:
        raise Refused("cannot read the manifest %s: %s" % (path, exc.strerror))
    except UnicodeDecodeError:
        raise Refused("the manifest is not UTF-8: %s" % path)
    m = Manifest()
    seen_dst = set()
    for no, raw in enumerate(lines, 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = re.split(r"\s+", line, maxsplit=1)
        word = parts[0]
        rest = parts[1].strip() if len(parts) > 1 else ""

        def fail(msg):
            raise Refused("manifest line %d: %s" % (no, msg))

        if word not in DIRECTIVES:
            fail("unknown directive %r" % word)
        if word == "product":
            if rest != product:
                fail("product is %r but the command names %r" % (rest, product))
            m.product = rest
        elif word == "dest":
            if not rest or re.search(r"\s", rest):
                fail("dest needs 1 path without spaces")
            m.dest = rest
        elif word == "branch":
            if not rest or re.search(r"\s", rest):
                fail("branch needs 1 name")
            if rest in PROTECTED_BRANCHES:
                fail("branch %s is refused: the tool never writes on %s" % (rest, rest))
            m.branch = rest
        elif word in ("copy", "copy-tree", "portable"):
            if word == "portable":
                mt = re.match(r"^(\S+)\s+->\s+(\S+)(?:\s+tracks=(.*))?$", rest)
            else:
                mt = re.match(r"^(\S+)\s+->\s+(\S+)(?:\s+(exclude=\S+))?$", rest)
            if not mt:
                fail("%s needs: SRC -> DST%s" % (word, " [tracks=...]" if word == "portable" else " [exclude=...]" if word == "copy-tree" else ""))
            src, dst = mt.group(1), mt.group(2)
            if word == "copy-tree":
                src, dst = src.rstrip("/"), dst.rstrip("/")
            for label, p in (("source", src), ("destination", dst)):
                why = bad_rel(p)
                if why:
                    fail("%s %s: %s" % (label, p, why))
            opts = {}
            if word == "copy-tree" and mt.group(3):
                opts["exclude"] = [g for g in mt.group(3)[len("exclude="):].split(",") if g]
            if word == "portable":
                if not src.startswith("products/%s/src/" % product):
                    fail("portable source must be under products/%s/src/" % product)
                tracks = [t.strip() for t in (mt.group(3) or "").split(";") if t.strip()]
                for t in tracks:
                    why = bad_rel(t.split("#", 1)[0])
                    if why:
                        fail("tracks entry %s: %s" % (t, why))
                opts["tracks"] = tracks
            if word != "copy-tree":
                if dst in seen_dst:
                    fail("duplicate destination %s" % dst)
                seen_dst.add(dst)
            m.files.append((word, src, dst, opts, no))
            m.file_directives += 1
        elif word == "rewrite":
            mw = re.match(r"^(.*?)\s+=>\s+(.*)$", rest)
            if not mw:
                fail("rewrite needs: REGEX => REPLACEMENT [in=DSTGLOB]")
            pat, repl = mw.group(1), mw.group(2)
            glob = None
            mi = re.search(r"\s+in=(\S+)$", repl)
            if mi:
                glob = mi.group(1)
                repl = repl[:mi.start()]
            try:
                comp = re.compile(pat, re.MULTILINE)
            except re.error as exc:
                fail("rewrite pattern is not a regular expression: %s" % exc)
            m.rewrites.append((pat, comp, repl, glob, no))
        elif word == "leak":
            try:
                m.leaks.append((rest, re.compile(rest, re.IGNORECASE), no))
            except re.error as exc:
                fail("leak pattern is not a regular expression: %s" % exc)
        elif word == "allow":
            mt = re.match(r"^(.*?)\s+in=(\S+)$", rest)
            if not mt:
                fail("allow needs in=DSTGLOB: nothing can be allowed everywhere")
            try:
                m.allows.append((mt.group(1), re.compile(mt.group(1), re.IGNORECASE), mt.group(2), no))
            except re.error as exc:
                fail("allow pattern is not a regular expression: %s" % exc)
        elif word == "post":
            if not rest:
                fail("post needs a command")
            m.posts.append(rest)
    if m.product is None:
        raise Refused("the manifest has no product line")
    if not m.file_directives:
        raise Refused("the manifest has no copy, copy-tree or portable line")
    return m


def load_leak_base(path):
    pats = []
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().split("\n")
    except OSError as exc:
        raise Refused("cannot read the base leak list %s: %s" % (path, exc.strerror))
    except UnicodeDecodeError:
        raise Refused("the base leak list is not UTF-8: %s" % path)
    for no, raw in enumerate(lines, 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        try:
            pats.append((line, re.compile(line, re.IGNORECASE)))
        except re.error as exc:
            raise Refused("base leak list line %d is not a regular expression: %s" % (no, exc))
    return pats


# ---------------------------------------------------------------- lock

def lock_path(manifest_path, product):
    return os.path.join(os.path.dirname(os.path.abspath(manifest_path)), product + ".lock")


def read_lock(path):
    empty = {"harness_commit": "unknown", "reconciled": "", "tracks": {}, "written": []}
    if not os.path.exists(path):
        return empty
    try:
        with open(path, encoding="utf-8") as fh:
            obj = json.load(fh)
    except (OSError, ValueError):
        raise Refused("the lock file cannot be read: %s" % path)
    if not isinstance(obj, dict):
        raise Refused("the lock file is not a JSON object: %s" % path)
    for key, default in empty.items():
        obj.setdefault(key, default)
    if not isinstance(obj["tracks"], dict) or not isinstance(obj["written"], list):
        raise Refused("the lock file has the wrong shape: %s" % path)
    return obj


def write_atomic(path, data, mode=None):
    folder = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(prefix=".export-tmp-", dir=folder)
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
        if mode is not None:
            os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def write_lock(path, lock):
    text = json.dumps(lock, indent=2, sort_keys=True) + "\n"
    write_atomic(path, text.encode("utf-8"), 0o644)


# ---------------------------------------------------------------- plan and pipeline

class Output:
    def __init__(self, dst, src_abs, executable, portable_src=None):
        self.dst = dst
        self.src_abs = src_abs
        self.executable = executable
        self.portable_src = portable_src
        self.data = None
        self.binary = False


def plan_outputs(m, root, problems):
    """The list of Output for the manifest. Missing sources go to problems; unsafe paths refuse."""
    outputs = []
    seen = {}
    for kind, src, dst, opts, no in m.files:
        if kind in ("copy", "portable"):
            pairs = [(src, dst)]
            link = no_symlink_below(root, src)
            if link:
                raise Refused("manifest line %d: the source path goes through a symbolic link: %s" % (no, src))
            full = os.path.join(root, src)
            if not os.path.isfile(full):
                problems.append("missing source: %s" % src)
                continue
        else:
            link = no_symlink_below(root, src)
            if link:
                raise Refused("manifest line %d: the source path goes through a symbolic link: %s" % (no, src))
            base = os.path.join(root, src)
            if not os.path.isdir(base):
                problems.append("missing source: %s" % src)
                continue
            pairs = []
            for folder, dirs, files in os.walk(base):
                dirs[:] = sorted(d for d in dirs if d not in SKIP_NAMES)
                for d in list(dirs):
                    if os.path.islink(os.path.join(folder, d)):
                        raise Refused("manifest line %d: a symbolic link inside the source tree: %s" % (no, os.path.join(folder, d)[len(root) + 1:]))
                for f in sorted(files):
                    full = os.path.join(folder, f)
                    rel = os.path.relpath(full, base).replace(os.sep, "/")
                    if f in SKIP_NAMES or f.endswith(".pyc"):
                        continue
                    if os.path.islink(full):
                        raise Refused("manifest line %d: a symbolic link inside the source tree: %s" % (no, full[len(root) + 1:]))
                    if any(fnmatch.fnmatch(rel, g) for g in opts.get("exclude", [])):
                        continue
                    pairs.append((src + "/" + rel, dst + "/" + rel))
        for s, d in pairs:
            if d in seen:
                raise Refused("manifest line %d: duplicate destination %s (also line %d)" % (no, d, seen[d]))
            seen[d] = no
            full = os.path.join(root, s)
            executable = bool(os.stat(full).st_mode & 0o111)
            outputs.append(Output(d, full, executable, s if kind == "portable" else None))
    return outputs


def strip_markers(text, dst, problems):
    lines = text.split("\n")
    kept = []
    start = None
    for no, line in enumerate(lines, 1):
        mt = MARKER_RE.match(line)
        if mt is None:
            if start is None:
                kept.append(line)
            continue
        if mt.group(1) == "start":
            if start is not None:
                problems.append("marker error: %s:%d: a harness-only block starts inside the one that began on line %d" % (dst, no, start))
                return None
            start = no
        else:
            if start is None:
                problems.append("marker error: %s:%d: a harness-only block ends but none was started" % (dst, no))
                return None
            start = None
    if start is not None:
        problems.append("marker error: %s:%d: a harness-only block starts and never ends" % (dst, start))
        return None
    return "\n".join(kept)


def run_pipeline(m, root, leak_base):
    """(outputs, problems, notes). Reads sources; writes nothing."""
    problems = []
    notes = []
    outputs = plan_outputs(m, root, problems)
    rewrite_hits = [0] * len(m.rewrites)
    for o in outputs:
        with open(o.src_abs, "rb") as fh:
            raw = fh.read()
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            o.data = raw
            o.binary = True
            notes.append("binary (not scanned): %s" % o.dst)
            continue
        text = strip_markers(text, o.dst, problems)
        if text is None:
            continue
        for i, (pat, comp, repl, glob, no) in enumerate(m.rewrites):
            if glob is not None and not fnmatch.fnmatchcase(o.dst, glob):
                continue
            try:
                text, n = comp.subn(repl, text)
            except (re.error, IndexError) as exc:
                raise Refused("manifest line %d: the rewrite rule cannot be applied: %s" % (no, exc))
            rewrite_hits[i] += n
        o.data = text.encode("utf-8")
        scan_leaks(o.dst, text, m, leak_base, problems)
    for i, (pat, comp, repl, glob, no) in enumerate(m.rewrites):
        if rewrite_hits[i] == 0:
            where = " for outputs matching %s" % glob if glob else ""
            problems.append("rewrite rule matches nothing%s: manifest line %d: %s" % (where, no, pat))
    return outputs, problems, notes


def scan_leaks(dst, text, m, leak_base, problems):
    checks = []
    for pat, comp in leak_base:
        checks.append(("pattern \"%s\"" % pat, comp, False))
    for pat, comp, no in m.leaks:
        checks.append(("pattern \"%s\"" % pat, comp, False))
    for name, pat in SECRET_SHAPES:
        checks.append(("secret shape: %s" % name, re.compile(pat, re.IGNORECASE), True))
    allows = [(comp, glob) for pat, comp, glob, no in m.allows if fnmatch.fnmatchcase(dst, glob)]
    for no, line in enumerate(text.split("\n"), 1):
        for label, comp, secret in checks:
            for mt in comp.finditer(line):
                if any(a.search(mt.group(0)) for a, g in allows):
                    continue
                problems.append("leak: %s:%d: %s" % (dst, no, label))
                break


# ---------------------------------------------------------------- tracked sources

def read_heading_section(text, heading):
    """The lines of the markdown section whose heading text equals HEADING, or None."""
    lines = text.split("\n")
    fence = False
    start = None
    level = 0
    for i, line in enumerate(lines):
        if re.match(r"^\s*(```|~~~)", line):
            fence = not fence
            continue
        if fence:
            continue
        mt = re.match(r"^(#{1,6})\s+(.*?)\s*#*\s*$", line)
        if not mt:
            continue
        lvl = len(mt.group(1))
        if start is None:
            if mt.group(2).strip() == heading:
                start, level = i, lvl
        elif lvl <= level:
            return lines[start:i]
    return lines[start:] if start is not None else None


def tracked_hash(root, entry):
    """('ok', 'sha256:...') or ('missing', None) or ('heading', None)."""
    path, _, heading = entry.partition("#")
    full = os.path.join(root, path)
    if no_symlink_below(root, path) or not os.path.isfile(full):
        return "missing", None
    with open(full, "rb") as fh:
        raw = fh.read()
    if not heading:
        return "ok", "sha256:" + hashlib.sha256(raw).hexdigest()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return "heading", None
    sec = read_heading_section(text, heading)
    if sec is None:
        return "heading", None
    return "ok", "sha256:" + hashlib.sha256("\n".join(sec).encode("utf-8")).hexdigest()


def source_drift(m, root, lock):
    """(lines, counts) for the tracks entries against the lock."""
    lines = []
    counts = {"moved": 0, "never": 0, "heading": 0, "missing": 0}
    for kind, src, dst, opts, no in m.files:
        if kind != "portable":
            continue
        for t in opts.get("tracks", []):
            state, digest = tracked_hash(root, t)
            if state == "missing":
                counts["missing"] += 1
                lines.append("tracked source not found: %s" % t)
                continue
            if state == "heading":
                counts["heading"] += 1
                lines.append("tracked heading not found: %s" % t)
                continue
            have = lock["tracks"].get(src, {}).get(t)
            if have is None:
                counts["never"] += 1
                lines.append("source never reconciled: %s" % t)
            elif have != digest:
                counts["moved"] += 1
                lines.append("source moved: %s (generalized in %s; see: git diff %s -- %s)"
                             % (t, src, lock.get("harness_commit", "unknown"), t.split("#", 1)[0]))
    return lines, counts


# ---------------------------------------------------------------- destination

def git(dest, *args):
    env = dict(os.environ)
    env["GIT_TERMINAL_PROMPT"] = "0"
    cmd = ["git", "-c", "core.hooksPath=/dev/null", "-C", dest] + list(args)
    res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, universal_newlines=True)
    return res.returncode, res.stdout.strip(), res.stderr.strip()


def check_dest_paths(dest, outputs):
    """Refuse a DST that is, or sits below, a symbolic link, or escapes dest."""
    for o in outputs:
        link = no_symlink_below(dest, o.dst)
        if link:
            raise Refused("the destination path goes through a symbolic link: %s" % o.dst)
        cur = os.path.join(dest, o.dst)
        probe = cur
        while not os.path.lexists(probe):
            probe = os.path.dirname(probe)
        if not under(dest, probe):
            raise Refused("the destination path escapes the destination: %s" % o.dst)


def file_is(path, data, mode):
    """True when path is a regular file holding exactly data with exactly that mode."""
    if not os.path.isfile(path) or (os.stat(path).st_mode & 0o777) != mode:
        return False
    with open(path, "rb") as fh:
        return fh.read() == data


def compare(dest, outputs, lock):
    """(drift lines, orphan lines)"""
    drift = []
    for o in outputs:
        path = os.path.join(dest, o.dst)
        if not os.path.isfile(path):
            drift.append("missing in dest: %s" % o.dst)
            continue
        with open(path, "rb") as fh:
            if fh.read() != o.data:
                drift.append("content differs: %s" % o.dst)
                continue
        if bool(os.stat(path).st_mode & 0o100) != o.executable:
            drift.append("executable bit differs: %s" % o.dst)
    produced = set(o.dst for o in outputs)
    orphans = []
    for w in lock["written"]:
        if isinstance(w, str) and w not in produced and not bad_rel(w) and os.path.isfile(os.path.join(dest, w)):
            orphans.append("orphan in dest: %s" % w)
    return drift, orphans


def summary(n_files, drift, orphans, counts):
    moved = counts["moved"] + counts["never"] + counts["heading"] + counts["missing"]
    if not drift and not orphans and not moved:
        return "in sync: %d files" % n_files
    return "drift: %d of %d files, %d source(s) moved, %d orphan(s)" % (len(drift), n_files, moved, len(orphans))


# ---------------------------------------------------------------- modes

def resolve_dest(args, m):
    raw = args["dest"] or m.dest
    if not raw:
        raise Refused("no destination: the manifest has no dest line and --dest was not given")
    return os.path.abspath(os.path.expanduser(raw))


def load(args):
    root = args["root"]
    if not root:
        raise Refused("--root is required: there is no default private root")
    root = os.path.abspath(os.path.expanduser(root))
    if not os.path.isdir(root):
        raise Refused("--root is not a folder: %s" % root)
    product = args["product"]
    mpath = args["manifest"] or os.path.join(root, "products", product + ".manifest")
    m = parse_manifest(mpath, product)
    return root, mpath, m


def mode_check(args):
    root, mpath, m = load(args)
    if not args["leak_base"]:
        raise Refused("--leak-base FILE is required")
    base = load_leak_base(args["leak_base"])
    dest = resolve_dest(args, m)
    lock = read_lock(lock_path(mpath, m.product))
    outputs, problems, notes = run_pipeline(m, root, base)
    for n in notes:
        out(n)
    if problems:
        for p in problems:
            out(p)
        return 1
    if os.path.isdir(dest):
        check_dest_paths(dest, outputs)
        drift, orphans = compare(dest, outputs, lock)
    else:
        drift, orphans = ["missing in dest: %s" % o.dst for o in outputs], []
    for d in drift:
        out(d)
    for o in orphans:
        out(o)
    lines, counts = source_drift(m, root, lock)
    for ln in lines:
        out(ln)
    out(summary(len(outputs), drift, orphans, counts))
    return 0 if not drift and not orphans and not lines else 1


def mode_apply(args):
    root, mpath, m = load(args)
    if not args["leak_base"]:
        raise Refused("--leak-base FILE is required")
    base = load_leak_base(args["leak_base"])
    dest = resolve_dest(args, m)
    lpath = lock_path(mpath, m.product)
    lock = read_lock(lpath)
    outputs, problems, notes = run_pipeline(m, root, base)
    for n in notes:
        out(n)
    if problems:
        for p in problems:
            out(p)
        out("nothing was written")
        return 1
    if not os.path.isdir(dest):
        raise Refused("the destination folder does not exist: %s" % dest)
    check_dest_paths(dest, outputs)
    rc, inside, _ = git(dest, "rev-parse", "--is-inside-work-tree")
    in_git = rc == 0 and inside == "true"
    if in_git:
        top_rc, top, _ = git(dest, "rev-parse", "--show-toplevel")
        if top_rc == 0 and os.path.realpath(top) != os.path.realpath(dest):
            raise Refused("the destination is a folder inside a larger repository; point dest at the repository root")
        rc, status, _ = git(dest, "status", "--porcelain", "--untracked-files=no")
        if rc != 0:
            raise Refused("cannot read the git status of the destination")
        if status:
            raise Refused("the destination has uncommitted changes to tracked files; commit or discard them first")
        written = set(w for w in lock["written"] if isinstance(w, str))
        for o in outputs:
            if os.path.lexists(os.path.join(dest, o.dst)) and o.dst not in written:
                rc, _, _ = git(dest, "ls-files", "--error-unmatch", "--", o.dst)
                if rc != 0:
                    raise Refused("a target path exists and is not tracked: %s" % o.dst)
        rc, cur, _ = git(dest, "symbolic-ref", "--short", "-q", "HEAD")
        if rc != 0 or not cur:
            raise Refused("cannot tell which branch the destination is on")
        if m.branch:
            rc, _, _ = git(dest, "check-ref-format", "--branch", m.branch)
            if rc != 0:
                raise Refused("the branch name is not valid: %s" % m.branch)
            if cur != m.branch:
                rc, _, _ = git(dest, "rev-parse", "--verify", "--quiet", "refs/heads/" + m.branch)
                sw = ["switch", m.branch] if rc == 0 else ["switch", "-c", m.branch]
                rc, _, err = git(dest, *sw)
                if rc != 0:
                    raise Refused("cannot switch the destination to branch %s: %s" % (m.branch, err))
                out("branch: %s" % m.branch)
        elif cur in PROTECTED_BRANCHES:
            raise Refused("the destination is on %s and the manifest names no branch to write on" % cur)
    for o in outputs:
        path = os.path.join(dest, o.dst)
        want = 0o755 if o.executable else 0o644
        if file_is(path, o.data, want):
            continue
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if no_symlink_below(dest, o.dst):
            raise Refused("the destination path goes through a symbolic link: %s" % o.dst)
        write_atomic(path, o.data, want)
        out("wrote: %s" % o.dst)
    produced = set(o.dst for o in outputs)
    if args["prune"]:
        for w in list(lock["written"]):
            if isinstance(w, str) and w not in produced and not bad_rel(w):
                path = os.path.join(dest, w)
                if os.path.isfile(path) and not os.path.islink(path) and under(dest, path):
                    os.unlink(path)
                    out("pruned: %s" % w)
    # a stale file stays on the list until it is pruned, so a later --prune can still find it
    stale = [w for w in lock["written"] if isinstance(w, str) and w not in produced and not bad_rel(w)
             and os.path.isfile(os.path.join(dest, w))]
    lock["written"] = sorted(produced | set(stale))
    write_lock(lpath, lock)
    if not args["no_post"]:
        for cmd in m.posts:
            res = subprocess.run(["sh", "-c", cmd], cwd=dest, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
            if res.returncode != 0:
                out("post command failed (%d): %s" % (res.returncode, cmd))
                out(res.stdout.rstrip("\n"))
                return 1
    drift, orphans = compare(dest, outputs, lock)
    for d in drift:
        out(d)
    for o in orphans:
        out(o)
    lines, counts = source_drift(m, root, lock)
    for ln in lines:
        out(ln)
    out(summary(len(outputs), drift, orphans, counts))
    return 0


def harness_commit(root):
    try:
        res = subprocess.run(["git", "-C", root, "rev-parse", "--short", "HEAD"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True)
        if res.returncode == 0 and res.stdout.strip():
            return res.stdout.strip()
    except OSError:
        pass
    return "unknown"


def mode_reconcile(args):
    root, mpath, m = load(args)
    lpath = lock_path(mpath, m.product)
    lock = read_lock(lpath)
    only = args["only"]
    todo = []
    for kind, src, dst, opts, no in m.files:
        if kind == "portable" and (only is None or only == src):
            todo.append((src, opts.get("tracks", [])))
    if only is not None and not any(src == only for src, _ in todo):
        raise Refused("--only %s is not a portable source in the manifest" % only)
    new_tracks = {}
    bad = []
    for src, tracks in todo:
        for t in tracks:
            state, digest = tracked_hash(root, t)
            if state != "ok":
                bad.append("tracked %s not found: %s" % ("heading" if state == "heading" else "source", t))
            else:
                new_tracks.setdefault(src, {})[t] = digest
    if bad:
        for b in bad:
            out(b)
        out("nothing was stamped")
        return 1
    if only is None:
        lock["tracks"] = new_tracks
    else:
        lock["tracks"][only] = new_tracks.get(only, {})
    lock["harness_commit"] = harness_commit(root)
    lock["reconciled"] = time.strftime("%Y-%m-%d")
    write_lock(lpath, lock)
    for src, tracks in todo:
        for t in tracks:
            out("reconciled: %s (in %s)" % (t, src))
    if not any(tracks for _, tracks in todo):
        out("nothing to reconcile: no tracks entries")
    return 0


def manifests_in(root):
    folder = os.path.join(root, "products")
    try:
        names = sorted(n[:-len(".manifest")] for n in os.listdir(folder) if n.endswith(".manifest"))
    except OSError:
        names = []
    return names


def mode_status(args):
    root = args["root"]
    if not root:
        raise Refused("--root is required: there is no default private root")
    root = os.path.abspath(os.path.expanduser(root))
    names = [args["product"]] if args["product"] else manifests_in(root)
    for name in names:
        mpath = args["manifest"] if (args["manifest"] and args["product"]) else os.path.join(root, "products", name + ".manifest")
        try:
            m = parse_manifest(mpath, name)
            lock = read_lock(lock_path(mpath, name))
            lines, counts = source_drift(m, root, lock)
        except Refused as exc:
            out("product-drift: %s: manifest error: %s" % (name, exc))
            continue
        parts = []
        if counts["moved"]:
            parts.append("%d source(s) moved since %s" % (counts["moved"], lock.get("reconciled") or "the last reconcile"))
        if counts["never"]:
            parts.append("%d never reconciled" % counts["never"])
        if counts["heading"] or counts["missing"]:
            parts.append("%d tracked heading(s) or file(s) not found" % (counts["heading"] + counts["missing"]))
        if parts:
            out("product-drift: %s: %s (run export.sh %s --check)" % (name, "; ".join(parts), name))
    return 0


def mode_list(args):
    root = args["root"]
    if not root:
        raise Refused("--root is required: there is no default private root")
    root = os.path.abspath(os.path.expanduser(root))
    for name in manifests_in(root):
        mpath = os.path.join(root, "products", name + ".manifest")
        try:
            m = parse_manifest(mpath, name)
            out("%s  %s  %d file directives" % (name, m.dest or "(no dest)", m.file_directives))
        except Refused as exc:
            out("%s  (manifest error: %s)" % (name, exc))
    return 0


# ---------------------------------------------------------------- command line

def parse_args(argv):
    args = {"product": None, "mode": None, "root": None, "dest": None, "manifest": None, "leak_base": None,
            "only": None, "prune": False, "no_post": False}
    valued = {"--root": "root", "--dest": "dest", "--manifest": "manifest", "--leak-base": "leak_base", "--only": "only"}
    modes = ("--check", "--apply", "--reconcile", "--status", "--list", "--help")
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in valued:
            if i + 1 >= len(argv):
                raise Refused("%s needs a value" % a)
            args[valued[a]] = argv[i + 1]
            i += 2
            continue
        if a in modes:
            if args["mode"] is not None:
                raise Refused("give exactly 1 mode")
            args["mode"] = a[2:]
        elif a == "-h":
            args["mode"] = "help"
        elif a == "--prune":
            args["prune"] = True
        elif a == "--no-post":
            args["no_post"] = True
        elif a.startswith("-"):
            raise Refused("unknown option: %s" % a)
        elif args["product"] is None:
            args["product"] = a
        else:
            raise Refused("unexpected argument: %s" % a)
        i += 1
    if args["mode"] is None:
        raise Refused("give a mode: --check, --apply, --reconcile, --status, --list or --help")
    if args["mode"] in ("check", "apply", "reconcile") and not args["product"]:
        raise Refused("--%s needs a product name" % args["mode"])
    if args["mode"] == "list" and args["product"]:
        raise Refused("--list takes no product name")
    if args["product"] and not re.match(r"^[A-Za-z0-9][A-Za-z0-9._-]*$", args["product"]):
        raise Refused("the product name is not a plain name: %s" % args["product"])
    if args["only"] is not None and args["mode"] != "reconcile":
        raise Refused("--only belongs to --reconcile")
    if (args["prune"] or args["no_post"]) and args["mode"] != "apply":
        raise Refused("--prune and --no-post belong to --apply")
    return args


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    try:
        args = parse_args(argv)
        if args["mode"] == "help":
            sys.stdout.write(__doc__)
            return 0
        return {"check": mode_check, "apply": mode_apply, "reconcile": mode_reconcile,
                "status": mode_status, "list": mode_list}[args["mode"]](args)
    except Refused as exc:
        sys.stderr.write("refused: %s\n" % exc)
        return 2


if __name__ == "__main__":
    sys.exit(main())
