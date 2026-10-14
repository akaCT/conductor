#!/usr/bin/env python3
"""Start an interactive Claude Code session in a pseudo-terminal and read the screen.

Reads the model and the effort the host displays: on the startup banner ("with high effort")
or, when the banner omits it, on the status line ("high \u00b7 /effort"); with --status also the
/status screen. Standard library only.

usage: pty_read.py --config-dir DIR --model MODEL --out FILE [--cap SECONDS] [--status] [--env NAME=VALUE]

The session runs in a fresh temporary folder with a clean environment: only HOME,
USER, LOGNAME, SHELL, PATH, TERM, LANG and CLAUDE_CONFIG_DIR are passed, so an
effort variable or a provider variable in the caller's shell cannot change what
the host shows.
"""
import argparse
import fcntl
import os
import pty
import re
import select
import shutil
import signal
import struct
import sys
import tempfile
import termios
import time

ROWS, COLS = 50, 160
FAMILY = re.compile(r"(Opus|Sonnet|Haiku|Fable)\s+[\d.]+")
BANNER_EFFORT = re.compile(r"with\s+(\w+)\s+effort")
STATUS_EFFORT = re.compile(r"(\w+)\s+\u00b7\s+/effort")


class Screen:
    """A small terminal screen: the parts of VT100 and xterm a text UI needs."""

    def __init__(self, rows, cols):
        self.rows, self.cols = rows, cols
        self.grid = [[" "] * cols for _ in range(rows)]
        self.r = self.c = 0
        self.saved = (0, 0)
        self.pending = ""

    def _blank(self):
        return [" "] * self.cols

    def _lf(self):
        if self.r >= self.rows - 1:
            self.grid.pop(0)
            self.grid.append(self._blank())
        else:
            self.r += 1

    def _put(self, ch):
        if self.c >= self.cols:
            self.c = 0
            self._lf()
        self.grid[self.r][self.c] = ch
        self.c += 1

    def feed(self, data):
        text = self.pending + data.decode("utf8", "replace")
        self.pending = ""
        i, n = 0, len(text)
        csi = re.compile(r"[0-?]*[ -/]*[\x40-~]")
        osc = re.compile(r"[^\x07\x1b]*(\x07|\x1b\\)")
        while i < n:
            ch = text[i]
            if ch == "\x1b":
                if i + 1 >= n:
                    self.pending = text[i:]
                    return
                nx = text[i + 1]
                if nx == "[":
                    m = csi.match(text, i + 2)
                    if not m:
                        self.pending = text[i:]
                        return
                    self._csi(m.group(0))
                    i = m.end()
                    continue
                if nx == "]":
                    m = osc.search(text, i + 2)
                    if not m:
                        self.pending = text[i:]
                        return
                    i = m.end()
                    continue
                if nx in "()#":
                    i += 3
                    continue
                if nx == "7":
                    self.saved = (self.r, self.c)
                elif nx == "8":
                    self.r, self.c = self.saved
                i += 2
                continue
            if ch == "\n":
                self._lf()
            elif ch == "\r":
                self.c = 0
            elif ch == "\b":
                self.c = max(0, self.c - 1)
            elif ch == "\t":
                self.c = min(self.cols - 1, (self.c // 8 + 1) * 8)
            elif ch >= " ":
                self._put(ch)
            i += 1

    def _csi(self, seq):
        final, params = seq[-1], seq[:-1]
        if params[:1] in ("?", ">", "<", "=") or seq.endswith(" q"):
            return
        nums = [int(x) if x.isdigit() else 0 for x in re.split(r"[;:]", params) if x != ""]

        def p(k, d=1):
            return nums[k] if len(nums) > k and nums[k] != 0 else d

        mode = nums[0] if nums else 0
        if final == "A":
            self.r = max(0, self.r - p(0))
        elif final == "B":
            self.r = min(self.rows - 1, self.r + p(0))
        elif final == "C":
            self.c = min(self.cols - 1, self.c + p(0))
        elif final == "D":
            self.c = max(0, self.c - p(0))
        elif final == "E":
            self.r, self.c = min(self.rows - 1, self.r + p(0)), 0
        elif final == "F":
            self.r, self.c = max(0, self.r - p(0)), 0
        elif final == "G":
            self.c = min(self.cols - 1, p(0) - 1)
        elif final in "Hf":
            self.r, self.c = min(self.rows - 1, p(0) - 1), min(self.cols - 1, p(1) - 1)
        elif final == "d":
            self.r = min(self.rows - 1, p(0) - 1)
        elif final == "J":
            if mode == 0:
                self.grid[self.r][self.c:] = [" "] * (self.cols - self.c)
                for k in range(self.r + 1, self.rows):
                    self.grid[k] = self._blank()
            elif mode == 1:
                for k in range(0, self.r):
                    self.grid[k] = self._blank()
                self.grid[self.r][: self.c + 1] = [" "] * (self.c + 1)
            else:
                self.grid = [self._blank() for _ in range(self.rows)]
        elif final == "K":
            if mode == 0:
                self.grid[self.r][self.c:] = [" "] * (self.cols - self.c)
            elif mode == 1:
                self.grid[self.r][: self.c + 1] = [" "] * (self.c + 1)
            else:
                self.grid[self.r] = self._blank()
        elif final == "X":
            k = p(0)
            self.grid[self.r][self.c:self.c + k] = [" "] * min(k, self.cols - self.c)
        elif final == "L":
            for _ in range(p(0)):
                self.grid.insert(self.r, self._blank())
                self.grid.pop()
        elif final == "M":
            for _ in range(p(0)):
                self.grid.pop(self.r)
                self.grid.append(self._blank())
        elif final == "P":
            row = self.grid[self.r]
            del row[self.c:self.c + p(0)]
            row.extend([" "] * (self.cols - len(row)))
        elif final == "\x40":
            row = self.grid[self.r]
            row[self.c:self.c] = [" "] * p(0)
            del row[self.cols:]
        elif final == "s":
            self.saved = (self.r, self.c)
        elif final == "u":
            self.r, self.c = self.saved

    def text(self):
        lines = ["".join(row).rstrip() for row in self.grid]
        while lines and not lines[-1]:
            lines.pop()
        return "\n".join(lines)


def redact(text):
    """Keep the screen readable but drop the address, the session id and the local paths."""
    text = re.sub(r"[\w.+'-]+\x40[\w.-]+", "<address>", text)
    text = re.sub(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", "<session-id>", text)
    text = re.sub(r"(/private)?/(var|tmp)/\S+", "<tmp>", text)
    return text.replace(os.path.expanduser("~"), "~")


def clean_env(config_dir):
    env = {"TERM": "xterm-256color", "LANG": "en_US.UTF-8", "CLAUDE_CONFIG_DIR": config_dir}
    for k in ("HOME", "USER", "LOGNAME", "SHELL", "PATH"):
        if os.environ.get(k):
            env[k] = os.environ[k]
    return env


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--config-dir", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--cap", type=int, default=120)
    ap.add_argument("--status", action="store_true", help="also open /status and keep its screen")
    ap.add_argument("--env", action="append", default=[], metavar="NAME=VALUE",
                    help="add 1 variable to the clean environment (repeatable), for a check that needs it on purpose")
    args = ap.parse_args()
    env = clean_env(args.config_dir)
    for item in args.env:
        name, sep, value = item.partition("=")
        if not sep or not name:
            ap.error("--env wants NAME=VALUE")
        env[name] = value

    work = tempfile.mkdtemp(prefix="live-pty-")
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(work)
        os.execvpe("claude", ["claude", "--model", args.model], env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
    scr = Screen(ROWS, COLS)
    deadline = time.time() + args.cap
    shots = []

    def pump(secs):
        end = min(time.time() + secs, deadline)
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.2)
            if r:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    return False
                if not data:
                    return False
                scr.feed(data)
        return True

    def send(b):
        try:
            os.write(fd, b)
        except OSError:
            pass

    reading = None
    try:
        # First-run dialogs default to "no" or to a choice we do not want; answer each once.
        answered = set()
        calm = 0
        while time.time() < deadline and calm < 2:
            pump(2)
            text = scr.text()
            dialog = True
            if "Yes, I trust this folder" in text:
                if "trust" not in answered:
                    answered.add("trust")
                    send(b"\x1b[B")
                    pump(0.5)
                    send(b"\r")
            elif "Claude in Chrome extension detected" in text:
                if "chrome" not in answered:
                    answered.add("chrome")
                    send(b"\r")
            elif "Try the new fullscreen renderer" in text:
                if "render" not in answered:
                    answered.add("render")
                    send(b"2")
                    pump(0.5)
                    send(b"\r")
            else:
                dialog = False
            fam = FAMILY.search(text)
            eff = BANNER_EFFORT.search(text) or STATUS_EFFORT.search(text)
            if fam and eff and not dialog:
                reading = (fam.group(1), eff.group(1))
                calm += 1
            else:
                calm = 0
        shots.append(("startup screen", scr.text()))
        if args.status and reading is not None:
            send(b"/status")
            pump(1)
            send(b"\r")
            pump(5)
            shots.append(("/status screen", scr.text()))
            send(b"\x1b")
            pump(1)
        send(b"/exit\r")
        pump(2)
    finally:
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            os.waitpid(pid, 0)
        except OSError:
            pass
        shutil.rmtree(work, ignore_errors=True)

    with open(args.out, "w") as f:
        for title, body in shots:
            f.write("=== %s (requested model %s)\n%s\n\n" % (title, args.model, redact(body)))
        if reading:
            f.write("READING: host family=%s effort=%s\n" % reading)
        else:
            f.write("READING: none (the startup line was not found within %d seconds)\n" % args.cap)
    print("reading:", ("family=%s effort=%s" % reading) if reading else "none")
    return 0 if reading else 1


if __name__ == "__main__":
    sys.exit(main())
