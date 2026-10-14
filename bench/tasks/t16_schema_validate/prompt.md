# Task

Write a Python script named `validate.py` in this directory that reads
`records.json` (a JSON array of objects) and prints the "id" of every invalid
record, 1 per line, in ascending numeric order. Print nothing for valid
records.

A record is valid only when all of these hold:
- "id" is an integer greater than 0
- "email" is a string with an "@" and at least 1 "." after the "@"
- "age" is an integer from 0 to 130 inclusive
- "tags" is a list and every item in it is a string

Only create `validate.py`. Do not run it yourself; the check script runs it.
