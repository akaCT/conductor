import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
out_path = os.path.join(here, "emails.txt")

if not os.path.exists(out_path):
    print("FAIL: emails.txt not found")
    sys.exit(1)

with open(out_path) as f:
    got = [line.strip().lower() for line in f if line.strip()]

expected = sorted(
    {
        "zed@example.com",
        "anna@example.com",
        "mike.jones@example.org",
        "ops@internal.test",
    }
)

if got == expected:
    print("PASS")
    sys.exit(0)
else:
    print("FAIL")
    print("expected:", expected)
    print("got:", got)
    sys.exit(1)
