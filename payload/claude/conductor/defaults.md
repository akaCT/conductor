<!--
Conductor defaults. This file is yours: Conductor writes it once and never replaces it.
A fresh copy of the shipped defaults sits beside it as defaults.default.md.
Format: 1 setting per line, no indentation, no trailing text.
A house rule reads `name: on` or `name: off`.
The block-mode line reads `hook_block_mode: off` (the other value is on).
The list of project folders starts with a line reading `project_homes:` and then
has 1 line per folder: a dash, a space and an absolute path, such as `- /work/app`.
Leave the list empty for none.
The doctrine follows the rules marked on and applies none marked off.
-->

# Conductor defaults

## House rules
no_long_dashes: off
numerals_only: off
agent_time_estimates: on
option_cap_3: on
never_commit_secret: on
document_set_consistency: on
migration_preflight: on

What each rule means:
- no_long_dashes: write with commas, colons and periods instead of long dashes.
- numerals_only: write every number as a numeral, never spelled out.
- agent_time_estimates: estimate work in agent time (how long agents take), not in human weeks.
- option_cap_3: offer at most 3 options per decision, 1 marked recommended.
- never_commit_secret: never commit keys, tokens or env values; flag an exposed one.
- document_set_consistency: when editing 1 document in a related set, check the rest of the set for drift in names, numbers and claims.
- migration_preflight: before a database migration, check the connection, look for duplicate functions and make the migration safe to re-run.

## Hooks
hook_block_mode: off

## Project homes
project_homes:
