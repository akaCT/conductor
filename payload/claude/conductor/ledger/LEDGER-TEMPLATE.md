# Deferred findings ledger

Rules:

1. Anything broken, missing or out of date that a session spots and leaves unrepaired needs a row here before that session hands back.
2. Each row carries 1 disposition: ASK (needs a decision from the owner), DO-NEXT (the next session should do it), WONTFIX (decided not to fix, with the reason), BLOCKED (waiting on something outside this project).
3. Append only. Never edit or delete a row. Add rows with `ledger-append`, which takes a lock so 2 sessions can write at once.
4. A row's status stays open until a later row closes it with evidence (a command output, a file path or a commit id). A claim with no evidence leaves it open.
5. Name a secret by where it lives, never by its value.

| Id | Date | Disposition | Status | Finding | Evidence |
|---|---|---|---|---|---|
