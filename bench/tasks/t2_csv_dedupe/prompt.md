# Task

Write a Python script named `dedupe.py` in this directory that reads
`contacts.csv` (columns: name,email) and writes `contacts_deduped.csv` with
duplicate rows removed, keeping the FIRST occurrence of each unique email
(case-insensitive comparison on the email column). Preserve the header row
and the original column order. Preserve the relative order of the remaining
rows.

Only create `dedupe.py` and run it so `contacts_deduped.csv` exists.
