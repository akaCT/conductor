import json
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
names = ["req_web.txt", "req_api.txt", "req_worker.txt", "req_batch.txt", "req_tools.txt"]
seen = {}
for name in names:
    with open(os.path.join(here, name)) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            pkg, _, ver = line.partition("==")
            seen.setdefault(pkg, set()).add(ver)
expected = {p: sorted(v) for p, v in sorted(seen.items()) if len(v) > 1}

path = os.path.join(here, "conflicts.json")
if not os.path.exists(path):
    print("FAIL: conflicts.json not found")
    sys.exit(1)
try:
    with open(path) as f:
        got = json.load(f)
except json.JSONDecodeError as e:
    print(f"FAIL: conflicts.json is not valid JSON: {e}")
    sys.exit(1)

if got == expected and list(got.keys()) == list(expected.keys()):
    print("PASS")
    sys.exit(0)
print("FAIL")
print("expected:", expected)
print("got:", got)
sys.exit(1)
