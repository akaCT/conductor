import ast
import os
import shutil
import subprocess
import sys
import tempfile

here = os.path.dirname(os.path.abspath(__file__))
MODULES = ["m_stack", "m_slug", "m_ranges", "m_money"]

# 1 broken copy of each module. Each test file must fail against it.
MUTANTS = {
    "m_stack": ("return self._items[-1]", "return self._items[0]"),
    "m_slug": ('return text.strip("-")', "return text"),
    "m_ranges": ("for start, end in sorted(ranges):", "for start, end in ranges:"),
    "m_money": ("{cents % 100:02d}", "{cents % 100}"),
}


def run_tests(workdir, mod):
    return subprocess.run(
        [sys.executable, "-m", "unittest", "test_" + mod],
        cwd=workdir, capture_output=True, text=True, timeout=60,
    )


failures = []
for mod in MODULES:
    test_path = os.path.join(here, "test_" + mod + ".py")
    if not os.path.exists(test_path):
        failures.append(f"test_{mod}.py not found")
        continue
    with open(test_path) as f:
        src = f.read()
    try:
        tree = ast.parse(src)
    except SyntaxError as e:
        failures.append(f"test_{mod}.py: syntax error: {e}")
        continue
    count = 0
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name.startswith("test"):
            count += 1
    if count < 3:
        failures.append(f"test_{mod}.py: {count} test methods, need at least 3")
    if run_tests(here, mod).returncode != 0:
        failures.append(f"test_{mod}.py: fails against the real module")
        continue
    old, new = MUTANTS[mod]
    with open(os.path.join(here, mod + ".py")) as f:
        orig = f.read()
    if old not in orig:
        failures.append(f"{mod}.py was changed; the mutant cannot be made")
        continue
    tmp = tempfile.mkdtemp(prefix="t12-mutant-")
    try:
        shutil.copy(test_path, tmp)
        with open(os.path.join(tmp, mod + ".py"), "w") as f:
            f.write(orig.replace(old, new, 1))
        if run_tests(tmp, mod).returncode == 0:
            failures.append(f"test_{mod}.py still passes against a broken {mod}.py")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

if failures:
    print("FAIL")
    for line in failures:
        print(" -", line)
    sys.exit(1)
print("PASS")
sys.exit(0)
