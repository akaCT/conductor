# Task

This directory has 4 log files: `app_web.log`, `app_api.log`, `app_worker.log`,
`app_batch.log`. Every line has the form `DATE TIME LEVEL message` where LEVEL
is INFO, WARN or ERROR.

Read all 4 files and write a single file `triage.json` in this directory. It
must be a JSON object keyed by log file name (all 4 names). Each value is an
object with exactly these keys:
- "errors": the number of ERROR lines in that file
- "warnings": the number of WARN lines in that file
- "first_error": the message text (everything after the level) of the first
  ERROR line in that file, or null when the file has no ERROR line

Only create `triage.json`.
