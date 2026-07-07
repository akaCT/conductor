# Task

This directory has 4 small Python files: `service_a.py`, `service_b.py`,
`service_c.py`, `service_d.py`. Each imports and calls a function called
`get_user_region(user_id)`.

The function is being renamed to `get_user_locale(user_id)` across the whole
codebase. Update all 4 files so that:
- every reference to `get_user_region` becomes `get_user_locale`
- the files still parse as valid Python (no syntax errors)
- no other code in the files is changed

Only edit the 4 existing files; do not create new files.
