import ast
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
files = ["service_a.py", "service_b.py", "service_c.py", "service_d.py"]

failures = []

for fname in files:
    path = os.path.join(here, fname)
    with open(path) as f:
        content = f.read()

    if "get_user_region" in content:
        failures.append(f"{fname}: still contains get_user_region")

    if "get_user_locale" not in content:
        failures.append(f"{fname}: missing get_user_locale")

    try:
        ast.parse(content)
    except SyntaxError as e:
        failures.append(f"{fname}: syntax error: {e}")

if failures:
    print("FAIL")
    for line in failures:
        print(" -", line)
    sys.exit(1)
else:
    print("PASS")
    sys.exit(0)
