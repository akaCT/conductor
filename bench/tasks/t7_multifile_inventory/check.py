import json
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
out_path = os.path.join(here, "inventory.json")

if not os.path.exists(out_path):
    print("FAIL: inventory.json not found")
    sys.exit(1)

with open(out_path) as f:
    try:
        data = json.load(f)
    except json.JSONDecodeError as e:
        print(f"FAIL: inventory.json is not valid JSON: {e}")
        sys.exit(1)

if not isinstance(data, list):
    print("FAIL: inventory.json must be a JSON array")
    sys.exit(1)

expected_pairs = [
    ("mod_auth.py", "hash_password"),
    ("mod_auth.py", "verify_token"),
    ("mod_billing.py", "apply_discount"),
    ("mod_billing.py", "issue_refund"),
    ("mod_billing.py", "next_invoice_number"),
    ("mod_reports.py", "build_monthly_summary"),
    ("mod_reports.py", "export_csv"),
    ("mod_search.py", "index_document"),
    ("mod_search.py", "query"),
]

got_pairs = []
for entry in data:
    if not all(k in entry for k in ("module", "function", "summary")):
        print(f"FAIL: entry missing required keys: {entry}")
        sys.exit(1)
    got_pairs.append((entry["module"], entry["function"]))

missing = [p for p in expected_pairs if p not in got_pairs]
extra = [p for p in got_pairs if p not in expected_pairs]

if missing:
    print("FAIL: missing entries:", missing)
if extra:
    print("FAIL: unexpected entries:", extra)

if missing or extra:
    sys.exit(1)

if got_pairs != expected_pairs:
    print("FAIL: entries present but not correctly ordered")
    print("expected order:", expected_pairs)
    print("got order:", got_pairs)
    sys.exit(1)

print("PASS")
sys.exit(0)
