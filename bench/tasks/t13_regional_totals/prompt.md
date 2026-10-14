# Task

This directory has 4 sales files: `sales_north.csv`, `sales_south.csv`,
`sales_east.csv`, `sales_west.csv`. Each has the header `sku,units,price`.

Write a single file `totals.csv` in this directory with the header
`region,units,revenue` and 5 data rows, in this order: north, south, east,
west, ALL. For each region, "units" is the sum of the units column and
"revenue" is the sum of units times price, written with exactly 2 decimals.
The ALL row holds the sums over the 4 regions.

Only create `totals.csv`.
