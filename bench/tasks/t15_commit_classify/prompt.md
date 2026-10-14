# Task

Write a Python script named `classify.py` in this directory that reads
`commits.txt` (1 commit subject per line, each starting with a prefix and a
colon) and writes `changelog.md`.

`changelog.md` has these 3 sections, in this order, each a level 2 heading
followed by a bullet list (`- text`) of the subjects with the prefix removed,
in the order they appear in `commits.txt`:
- `## Added` for the `feat` prefix
- `## Fixed` for the `fix` prefix
- `## Changed` for every other prefix

Only create `classify.py` and run it so `changelog.md` exists.
