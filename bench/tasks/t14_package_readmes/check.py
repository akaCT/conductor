import ast
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
failures = []
for folder in ["pkg_alpha", "pkg_beta", "pkg_gamma", "pkg_delta"]:
    with open(os.path.join(here, folder, "core.py")) as f:
        tree = ast.parse(f.read())
    public = [n.name for n in tree.body if isinstance(n, ast.FunctionDef) and not n.name.startswith("_")]
    private = [n.name for n in tree.body if isinstance(n, ast.FunctionDef) and n.name.startswith("_")]
    path = os.path.join(here, folder, "README.md")
    if not os.path.exists(path):
        failures.append(f"{folder}/README.md not found")
        continue
    with open(path) as f:
        text = f.read()
    first = text.lstrip().splitlines()[0] if text.strip() else ""
    if not first.startswith("# ") or folder not in first:
        failures.append(f"{folder}/README.md: first line must be a level 1 heading with {folder}")
    bullets = [ln.strip() for ln in text.splitlines() if ln.strip().startswith(("- ", "* "))]
    for name in public:
        if not any(("`" + name) in b for b in bullets):
            failures.append(f"{folder}/README.md: no bullet starting with `{name}`")
    for name in private:
        if name in text:
            failures.append(f"{folder}/README.md: mentions private function {name}")

if failures:
    print("FAIL")
    for line in failures:
        print(" -", line)
    sys.exit(1)
print("PASS")
sys.exit(0)
