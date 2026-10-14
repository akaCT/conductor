# Task

This directory has 5 requirements files: `req_web.txt`, `req_api.txt`,
`req_worker.txt`, `req_batch.txt`, `req_tools.txt`. Every line pins a package
as `name==version`.

Read all 5 files and write a single file `conflicts.json` in this directory.
It must be a JSON object that lists only the packages pinned to more than 1
distinct version across the 5 files. Each key is the package name and each
value is the sorted list of its distinct versions (as strings). Sort the keys
alphabetically.

Only create `conflicts.json`.
