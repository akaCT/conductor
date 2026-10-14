import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
sections = {"Added": [], "Fixed": [], "Changed": []}
with open(os.path.join(here, "commits.txt")) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        prefix, _, rest = line.partition(":")
        rest = rest.strip()
        if prefix == "feat":
            sections["Added"].append(rest)
        elif prefix == "fix":
            sections["Fixed"].append(rest)
        else:
            sections["Changed"].append(rest)

path = os.path.join(here, "changelog.md")
if not os.path.exists(path):
    print("FAIL: changelog.md not found")
    sys.exit(1)
with open(path) as f:
    lines = [ln.strip() for ln in f if ln.strip()]

expected = []
for name in ["Added", "Fixed", "Changed"]:
    expected.append("## " + name)
    expected.extend("- " + s for s in sections[name])

if lines == expected:
    print("PASS")
    sys.exit(0)
print("FAIL")
print("expected:", expected)
print("got:", lines)
sys.exit(1)
