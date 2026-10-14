#!/usr/bin/env python3
"""Fixture helper for tests/test-report.sh and tests/test-update.sh: finds outbound-call
code (REQ-DATA-001.2). Prints 1 line per hit: FILE:LINE:TEXT. Python 3.9 stdlib only.

  bash files   a command-position curl, wget, nc, ncat, netcat, ssh, scp, sftp, telnet or
               ftp (comment lines and here-document text are skipped), or /dev/tcp, /dev/udp
  python files an import of a network module, a call named urlopen, or a subprocess/os.system
               call that names curl, wget or nc
"""
import ast
import re
import sys

BASH_CALL = re.compile(r"(^|[;&|`]|\$\(|\bthen\b|\bdo\b|\belse\b)\s*(curl|wget|nc|ncat|netcat|ssh|scp|sftp|telnet|ftp)(\s|$)")
BASH_DEV = re.compile(r"/dev/(tcp|udp)/")
HEREDOC = re.compile(r"<<-?\s*[\"']?([A-Za-z_][A-Za-z0-9_]*)[\"']?")
NET_MODULES = {"socket", "urllib.request", "http.client", "http.server", "ftplib", "smtplib", "telnetlib",
               "xmlrpc.client", "requests", "httpx", "webbrowser", "asyncio"}


def scan_bash(path):
    hits = []
    delim = None
    with open(path, encoding="utf-8", errors="replace") as fh:
        for n, line in enumerate(fh, 1):
            text = line.rstrip("\n")
            if delim is not None:
                if text.strip() == delim:
                    delim = None
                continue
            m = HEREDOC.search(text)
            if m:
                delim = m.group(1)
            if text.lstrip().startswith("#"):
                continue
            if BASH_CALL.search(text) or BASH_DEV.search(text):
                hits.append("%s:%d:%s" % (path, n, text.strip()))
    return hits


def scan_python(path):
    hits = []
    src = open(path, encoding="utf-8", errors="replace").read()
    lines = src.split("\n")
    try:
        tree = ast.parse(src)
    except SyntaxError:
        return ["%s:1:python file does not parse" % path]
    for node in ast.walk(tree):
        names = []
        if isinstance(node, ast.Import):
            names = [a.name for a in node.names]
        elif isinstance(node, ast.ImportFrom) and node.module:
            names = [node.module] + ["%s.%s" % (node.module, a.name) for a in node.names]
        if any(n in NET_MODULES or n.split(".")[0] in ("socket", "requests", "httpx", "ftplib", "smtplib", "telnetlib", "webbrowser")
               for n in names):
            hits.append("%s:%d:%s" % (path, node.lineno, lines[node.lineno - 1].strip()))
        if isinstance(node, ast.Call):
            fn = node.func
            fname = fn.attr if isinstance(fn, ast.Attribute) else (fn.id if isinstance(fn, ast.Name) else "")
            if fname == "urlopen":
                hits.append("%s:%d:%s" % (path, node.lineno, lines[node.lineno - 1].strip()))
            if fname in ("run", "Popen", "call", "check_call", "check_output", "system", "popen", "execvp", "execv"):
                consts = [c.value for c in ast.walk(node) if isinstance(c, ast.Constant) and isinstance(c.value, str)]
                if any(c.split(" ")[0] in ("curl", "wget", "nc", "ncat", "ssh", "scp") for c in consts):
                    hits.append("%s:%d:%s" % (path, node.lineno, lines[node.lineno - 1].strip()))
    return hits


def main():
    hits = []
    for path in sys.argv[1:]:
        with open(path, encoding="utf-8", errors="replace") as fh:
            first = fh.readline()
        if path.endswith(".py") or (first.startswith("#!") and "python" in first):
            hits += scan_python(path)
        else:
            hits += scan_bash(path)
    for h in hits:
        print(h)
    return 0


if __name__ == "__main__":
    sys.exit(main())
