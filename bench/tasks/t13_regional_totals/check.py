import csv
import os
import sys
from decimal import Decimal

here = os.path.dirname(os.path.abspath(__file__))
regions = ["north", "south", "east", "west"]

expected = [["region", "units", "revenue"]]
all_units = 0
all_rev = Decimal("0")
for region in regions:
    units = 0
    rev = Decimal("0")
    with open(os.path.join(here, f"sales_{region}.csv"), newline="") as f:
        for row in csv.DictReader(f):
            units += int(row["units"])
            rev += int(row["units"]) * Decimal(row["price"])
    expected.append([region, str(units), f"{rev:.2f}"])
    all_units += units
    all_rev += rev
expected.append(["ALL", str(all_units), f"{all_rev:.2f}"])

path = os.path.join(here, "totals.csv")
if not os.path.exists(path):
    print("FAIL: totals.csv not found")
    sys.exit(1)
with open(path, newline="") as f:
    got = [[c.strip() for c in row] for row in csv.reader(f) if row]

if got == expected:
    print("PASS")
    sys.exit(0)
print("FAIL")
print("expected:", expected)
print("got:", got)
sys.exit(1)
