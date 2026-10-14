import json
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
names = ["app_web.log", "app_api.log", "app_worker.log", "app_batch.log"]

expected = {}
for name in names:
    errors = warnings = 0
    first = None
    with open(os.path.join(here, name)) as f:
        for line in f:
            parts = line.rstrip("\n").split(" ", 3)
            if len(parts) < 4:
                continue
            if parts[2] == "ERROR":
                errors += 1
                if first is None:
                    first = parts[3]
            elif parts[2] == "WARN":
                warnings += 1
    expected[name] = {"errors": errors, "warnings": warnings, "first_error": first}

path = os.path.join(here, "triage.json")
if not os.path.exists(path):
    print("FAIL: triage.json not found")
    sys.exit(1)
try:
    with open(path) as f:
        got = json.load(f)
except json.JSONDecodeError as e:
    print(f"FAIL: triage.json is not valid JSON: {e}")
    sys.exit(1)

if got == expected:
    print("PASS")
    sys.exit(0)
print("FAIL")
print("expected:", expected)
print("got:", got)
sys.exit(1)
