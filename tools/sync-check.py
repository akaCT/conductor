#!/usr/bin/env python3
"""sync-check.py - thin wrapper around `python3 tools/build.py --check`.

Kept so the old habit still works: run it from a checkout after editing
payload/ or installer/. Exit 0 when install.sh and every generated file match a
fresh build, 1 on any drift or build failure. It is never shipped by the
installer.
"""
import subprocess
import sys
from pathlib import Path

BUILD = Path(__file__).resolve().parent / "build.py"

if __name__ == "__main__":
    sys.exit(1 if subprocess.call([sys.executable, str(BUILD), "--check"] + sys.argv[1:]) else 0)
