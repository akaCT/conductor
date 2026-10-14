# Task

This directory has 4 service config files: `svc_auth.json`, `svc_billing.json`,
`svc_search.json`, `svc_notify.json`. Each holds an object with the keys
"service", "port", "timeout_s" and "features" (a list of strings).

Read all 4 files and write a single file `fleet.json` in this directory. It
must be a JSON object with exactly these keys:
- "services": an object keyed by service name; each value is an object with
  the keys "port" and "timeout_s" copied from that service's file
- "all_features": the sorted list of distinct feature names across all 4 files
- "port_conflicts": the sorted list of port numbers used by more than 1
  service (an empty list when there are none)

Only create `fleet.json`.
