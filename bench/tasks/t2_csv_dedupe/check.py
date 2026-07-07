import csv
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
out_path = os.path.join(here, "contacts_deduped.csv")

if not os.path.exists(out_path):
    print("FAIL: contacts_deduped.csv not found")
    sys.exit(1)

with open(out_path, newline="") as f:
    rows = list(csv.DictReader(f))

emails_seen = [r["email"].lower() for r in rows]
expected_emails = ["alice@example.com", "bob@example.com", "carol@example.com", "dave@example.com"]

if emails_seen == expected_emails:
    print("PASS")
    sys.exit(0)
else:
    print("FAIL")
    print("expected emails in order:", expected_emails)
    print("got:", emails_seen)
    sys.exit(1)
