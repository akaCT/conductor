import subprocess
import sys
import os

here = os.path.dirname(os.path.abspath(__file__))
result = subprocess.run(
    [sys.executable, os.path.join(here, "buggy.py")],
    capture_output=True,
    text=True,
    timeout=10,
)
lines = result.stdout.strip().splitlines()

expected = []
for i in range(1, 31):
    if i % 15 == 0:
        expected.append("FizzBuzz")
    elif i % 3 == 0:
        expected.append("Fizz")
    elif i % 5 == 0:
        expected.append("Buzz")
    else:
        expected.append(str(i))

if lines == expected:
    print("PASS")
    sys.exit(0)
else:
    print("FAIL")
    print("expected:", expected)
    print("got:", lines)
    sys.exit(1)
