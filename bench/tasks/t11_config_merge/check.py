import json
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
names = ["svc_auth.json", "svc_billing.json", "svc_search.json", "svc_notify.json"]

services = {}
features = set()
ports = {}
for name in names:
    with open(os.path.join(here, name)) as f:
        d = json.load(f)
    services[d["service"]] = {"port": d["port"], "timeout_s": d["timeout_s"]}
    features.update(d["features"])
    ports.setdefault(d["port"], []).append(d["service"])
expected = {
    "services": services,
    "all_features": sorted(features),
    "port_conflicts": sorted(p for p, who in ports.items() if len(who) > 1),
}

path = os.path.join(here, "fleet.json")
if not os.path.exists(path):
    print("FAIL: fleet.json not found")
    sys.exit(1)
try:
    with open(path) as f:
        got = json.load(f)
except json.JSONDecodeError as e:
    print(f"FAIL: fleet.json is not valid JSON: {e}")
    sys.exit(1)

if got == expected:
    print("PASS")
    sys.exit(0)
print("FAIL")
print("expected:", expected)
print("got:", got)
sys.exit(1)
