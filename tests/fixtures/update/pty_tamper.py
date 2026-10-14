#!/usr/bin/env python3
"""Fixture helper for tests/test-update.sh (REQ-UPD-002.9).

  pty_tamper.py TMPDIR CMD...

Runs CMD on a pseudo terminal. When the update prompt appears it appends a line to the
fetched installer (TMPDIR/conductor-update.*/installer.sh), the way a file could change
between the preview and the yes, then types y. Prints what CMD wrote and exits with its
status (124 on a timeout). Python 3.9, standard library only.
"""
import glob
import os
import pty
import select
import signal
import sys
import time

tmpdir = sys.argv[1]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[2], sys.argv[2:])
out = b""
deadline = time.time() + 30
tampered = False
timed_out = False
while True:
    left = deadline - time.time()
    if left <= 0:
        timed_out = True
        os.kill(pid, signal.SIGKILL)
        break
    ready, _, _ = select.select([fd], [], [], min(left, 1))
    if not ready:
        continue
    try:
        data = os.read(fd, 4096)
    except OSError:
        break
    if not data:
        break
    out += data
    if not tampered and b"Apply this update?" in out:
        files = glob.glob(os.path.join(tmpdir, "conductor-update.*", "installer.sh"))
        for path in files:
            with open(path, "ab") as fh:
                fh.write(b"\n# changed after the preview\n")
        tampered = True
        os.write(fd, b"y\n")
_, status = os.waitpid(pid, 0)
sys.stdout.write(out.decode("utf-8", "replace").replace("\r\n", "\n"))
sys.stdout.write("\n[tampered: %s]\n" % ("yes" if tampered and files else "no"))
if timed_out:
    sys.exit(124)
sys.exit(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 1)
