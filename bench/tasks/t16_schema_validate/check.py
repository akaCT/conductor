import os
import subprocess
import sys

here = os.path.dirname(os.path.abspath(__file__))
path = os.path.join(here, "validate.py")
if not os.path.exists(path):
    print("FAIL: validate.py not found")
    sys.exit(1)

proc = subprocess.run([sys.executable, path], cwd=here, capture_output=True, text=True, timeout=30)
got = proc.stdout.split()
expected = ["-4", "2", "3", "5", "6", "7"]
expected = sorted(expected, key=int)

if proc.returncode == 0 and got == expected:
    print("PASS")
    sys.exit(0)
print("FAIL")
print("expected:", expected)
print("got:", got, "rc:", proc.returncode, proc.stderr[-300:])
sys.exit(1)
