import ast
import importlib.util
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))

CALLS = {
    "util_a.py": [
        ("clamp", (15, 0, 10), 10),
        ("clamp", (-3, 0, 10), 0),
        ("is_even", (4,), True),
        ("is_even", (7,), False),
    ],
    "util_b.py": [
        ("initials", ("grace brewster hopper",), "GBH"),
        ("shout", ("stop",), "STOP!"),
    ],
    "util_c.py": [
        ("mean", ([2, 4, 6],), 4.0),
        ("spread", ([3, 9, 5],), 6),
    ],
    "util_d.py": [
        ("chunk", ([1, 2, 3, 4, 5], 2), [[1, 2], [3, 4], [5]]),
        ("flatten", ([[1], [2, 3]],), [1, 2, 3]),
    ],
    "util_e.py": [
        ("pad_id", (42, 5), "00042"),
        ("split_pair", ("key = value",), ("key", "value")),
    ],
}

failures = []
for fname, calls in CALLS.items():
    path = os.path.join(here, fname)
    try:
        with open(path) as f:
            src = f.read()
        tree = ast.parse(src)
    except (OSError, SyntaxError) as e:
        failures.append(f"{fname}: cannot parse: {e}")
        continue
    funcs = [n for n in tree.body if isinstance(n, ast.FunctionDef)]
    if len(funcs) != 2:
        failures.append(f"{fname}: expected 2 top-level functions, found {len(funcs)}")
    for fn in funcs:
        doc = ast.get_docstring(fn)
        if not doc or not doc.strip():
            failures.append(f"{fname}: {fn.name} has no docstring")
        elif "\n" in doc.strip():
            failures.append(f"{fname}: {fn.name} docstring is longer than 1 line")
    spec = importlib.util.spec_from_file_location(fname[:-3], path)
    mod = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(mod)
    except Exception as e:
        failures.append(f"{fname}: import failed: {e}")
        continue
    for name, args, want in calls:
        try:
            got = getattr(mod, name)(*args)
        except Exception as e:
            failures.append(f"{fname}: {name}{args} raised {e}")
            continue
        if got != want:
            failures.append(f"{fname}: {name}{args} returned {got!r}, expected {want!r}")

if failures:
    print("FAIL")
    for line in failures:
        print(" -", line)
    sys.exit(1)
print("PASS")
sys.exit(0)
