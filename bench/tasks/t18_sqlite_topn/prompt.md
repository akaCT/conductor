# Task

Write a Python script named `topn.py` in this directory that reads
`orders.csv` (columns: id,customer,amount), loads it into an in-memory SQLite
database with the standard library `sqlite3`, and uses an SQL query to find
the 3 customers with the highest total amount.

Print 1 line per customer, highest total first, in the format
`customer total` where total has exactly 2 decimals (for example
`acme 250.74`).

Only create `topn.py` and run it.
