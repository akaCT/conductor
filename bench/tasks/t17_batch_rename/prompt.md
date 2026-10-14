# Task

The folder `photos/` holds files named like `IMG_0042.jpg` (the prefix `IMG_`,
4 digits, and the extension `.jpg`).

Write a bash script named `rename.sh` in this directory. Run from the folder
that holds `photos/`, it must create a folder `trip/` and copy every `.jpg`
file of `photos/` into it with new names `trip-001.jpg`, `trip-002.jpg` and so
on (3 digits), numbered in ascending order of the original 4 digit number. The
files in `photos/` stay where they are. It must work for any number of files
from 1 to 999.

Only create `rename.sh`. Do not run it yourself; the check script runs it.
