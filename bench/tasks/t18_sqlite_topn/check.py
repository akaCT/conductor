import csv
import os
import subprocess
import sys
from decimal import Decimal

here = os.path.dirname(os.path.abspath(__file__))
totals = {}
with open(os.path.join(here, "orders.csv"), newline="") as f:
    for row in csv.DictReader(f):
        totals[row["customer"]] = totals.get(row["customer"], Decimal("0")) + Decimal(row["amount"])
top = sorted(totals.items(), key=lambda kv: (-kv[1], kv[0]))[:3]
expected = [f"{name} {total:.2f}" for name, total in top]

path = os.path.join(here, "topn.py")
if not os.path.exists(path):
    print("FAIL: topn.py not found")
    sys.exit(1)
src = open(path).read()
if "sqlite3" not in src:
    print("FAIL: topn.py does not use sqlite3")
    sys.exit(1)
proc = subprocess.run([sys.executable, path], cwd=here, capture_output=True, text=True, timeout=30)
got = [ln.strip() for ln in proc.stdout.splitlines() if ln.strip()]
if proc.returncode == 0 and got == expected:
    print("PASS")
    sys.exit(0)
print("FAIL")
print("expected:", expected)
print("got:", got, "rc:", proc.returncode, proc.stderr[-300:])
sys.exit(1)
