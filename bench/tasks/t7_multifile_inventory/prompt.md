# Task

This directory has 4 module files: `mod_auth.py`, `mod_billing.py`,
`mod_reports.py`, `mod_search.py`. Each defines one or more functions with a
docstring.

Read all 4 files and write a single file `inventory.json` in this directory
listing every top-level function across all 4 modules. `inventory.json` must
be a JSON array of objects, each with keys:
- "module": the file name (e.g. "mod_auth.py")
- "function": the function name
- "summary": a short (under 15 words) summary of what the function does,
  derived from its docstring

Order entries by module name alphabetically, then by function name
alphabetically within a module. Only create `inventory.json`.
