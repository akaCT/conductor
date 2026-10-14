# Release record: Conductor 0.4.0

This record is filled in as the release is built. A heading with a value in angle
brackets is not filled yet. The release check (tools/release-check.py) reads it.
It names no account and no private path.

## Commit

Commit: the head of the `release/0.4.0` branch, the release pull request. It is 1 commit on `main` at
41ad889 whose tree is the tested build tree; this record is the only file written after the tests.

## Installer sha256

Installer sha256: 3403a6b01c0c58f7ef7ec5973a79564da8a73ad0477e6c9f52c10f3da5979696 (the install.sh in this commit;
published beside the installer file and on the release page at the go).

## Version strings

Version in payload/components.json: 0.4.0
Version in the 2 VERSION files: 0.4.0
Version in the installer and the doctrine marker: 0.4.0
Version in the changelog heading: 0.4.0

## Codex model map

Vendor model list: https://learn.chatgpt.com/docs/models
Map ids re-checked on: 2026-10-14 (the older address https://developers.openai.com/codex/models redirects to the page above).

| Conductor alias | Codex seat | Codex model id | Why this model |
|---|---|---|---|
| `opus` | architect | `gpt-6-astra` | The vendor lists it as "Our most capable model for complex work across code, apps, and research." |
| `sonnet` | builder, critic | `gpt-6.1-sol` | The vendor lists it as "Near-Astra performance for complex work at a lower cost than Astra." (Plus, Pro, Business, Enterprise and Edu at launch). GPT-6 Sol is named only as a replacement "when available", with no entry of its own. |
| `haiku` | scout | `gpt-6-luna` | The vendor lists it as its most efficient model for focused, high-volume tasks. |

- Retired for ChatGPT sign-in users and absent from the map: the GPT-5.4 and GPT-5.4 mini ids (retired 2026-08-31) and the GPT-5.5 id (retired 2026-10-14).
- Availability depends on the rollout, the sign-in method and the client. Enterprise and Edu accounts may need an administrator to enable a model first.
- Codex effort: the vendor page names no `model_reasoning_effort` key and no accepted values, so `codex_effort` is empty, the generated agent files carry no effort key, and the doctor shows each Codex agent as "not pinned".


## Haiku environment value

The Haiku env value (`ANTHROPIC_DEFAULT_HAIKU_MODEL`) was not observed to work on a real runtime in the window 2.1.289 to 2.1.292; the window was dropped on 2026-10-12. The vendor page says to use v2.1.293 or later with Haiku 5.5. The installer never writes the value at any version. Below 2.1.293 on the Anthropic API it prints that Haiku 5.5 needs v2.1.293 and that `claude update` fixes it. A value an earlier Conductor install recorded is offered for removal at 2.1.293 or later.

## Gates (R-25)

### Gate 1: clean install, its re-run and the live checks in a test profile

Evidence: the release gates script ran the installer in a throwaway config folder on 2026-10-14: a clean
install exits 0 and a re-run changes 0 files. The script passed 26 of 26 checks across gates 1, 2
and 3 and support check B-2 (bash 3.2; with no python3 the installer puts in the core only, says why
and leaves settings.json byte for byte as it was).
The live half ran in a spare signed-in config folder on Claude Code 2.1.299 in a clean process
environment, recorded in `ops/live-proof/L-02.md`: row 1, effort high on Opus 5.5 and Sonnet 5.5
(2 of 2), re-read with `ANTHROPIC_BASE_URL` set to the vendor's own address; row 2, each of the 5
seats names its mapped model (5 of 5); row 3, the pointer line over a fixture checkpoint; row 4, the
judge holds no shell tool. The uninstall in that folder put settings.json back byte for byte. The
live checks ran on the candidate before the last 2 fix rounds; those rounds changed install
messages, linked-folder handling and ledger-append, which the test suite and the gates script
cover, not the effort pins or the seat map.

### Gate 2: upgrade from 0.3.0 in a throwaway config folder

Evidence: the real 0.3.0 installer (the fixture, byte for byte the installer at tag v0.3.0), then
0.4.0 over it, in a throwaway config folder: exit 0, 1 doctrine block in CLAUDE.md and 1 in
AGENTS.md (the gates script run above).

### Gate 3: uninstall in a throwaway config folder

Evidence: uninstall after the clean install and after the upgrade leaves only `conductor/backups/`
and the user's `conductor/defaults.md`, plus an empty Codex skills folder that the uninstall names
when it keeps it (the gates script run above).

### Gate 4: tier 4 review with the cso security pass

Evidence: tier 4, 4 rounds, each seat in a fresh context reading a named commit, never a working tree.

| Round | Seats (model, effort) | Verdicts | Findings | What followed |
|---|---|---|---|---|
| 1 | correctness and edge cases (Sonnet 5.5 xhigh); intent fit re-derived from the PRD (Opus 5.5 xhigh); security, cso method (Sonnet 5.5 xhigh); judge, Fable 5.1 xhigh | 3 ship with fixes, 1 do not ship | 1 BLOCKER, 16 MAJOR, 44 MINOR, 16 NIT | the release branch cut fresh from `main` (the BLOCKER), 3 fix lanes |
| 2 | the same 4 seats, each answering the others' findings with evidence | 4 do not ship before the fixes | 6 MAJOR, 5 MINOR, 2 NIT | folded into the same fix lanes |
| 3 | re-check of every fixed item: Opus 5.5 xhigh critic and the security seat | 2 ship with fixes | 59 fixed, 11 partly; new: 4 MAJOR, 13 MINOR, 9 NIT | 1 fix lane for the MAJORs, each with a test that fails before the fix |
| 4 | re-check of those fixes only: Opus 5.5 xhigh critic, a different model from their author | ship with fixes | 6 of 7 fixed, 1 partly; 0 BLOCKER, 0 MAJOR; 5 MINOR, 5 NIT, 2 of them security | the security seat ruled ship on the 2 security items (1 MINOR in model, 1 NIT out of model) and found 2 MINOR and 3 NIT more, none blocking; the helper's header now states what its check covers; the rest recorded for a later release |

The full test suite passed at every integration point. Findings not fixed in this release are recorded
with a disposition in the maintainer's deferred ledger.

### Gate 5: leak scan and verbatim scan clean

Evidence: `tools/release-check.py` with `--all-files` and `--final`, the private-files list (the
path and sha256 of every partner-only file and of the private build's installer), the derived-works
list, the export manifest and a reviewed allow list (test canaries and synthetic test data), run on
2026-10-14 over the tested build tree.
- Shipped kit (install.sh and the payload): leak scan PASS, verbatim scan PASS, private files absent,
  derived works named in the notices.
- Every other tracked file outside `site/`: leak scan PASS. The verbatim scan reports 6 test files
  that share 8 consecutive words with the maintainer's private harness: an environment assignment, a
  regex list, checkpoint section names, and the 0.3.0 installer fixture, which is public at tag
  v0.3.0. Reviewed: none is copied prose; accepted.
- `site/` holds `main`'s words in this release, as decided: its banned-strings lines (the 2 old headline figures)
  and the form placeholder address are the owner's decision in the separate site pull request.

### Gate 6: the product owner's go

Evidence: <filled at the go by the owner>

## Bench run ids

Bench run ids: no scored run for 0.4.0 (the scored bench is the 1.0 gate). 2 smoke runs, labeled
`SMOKE RUN: not scored` in their records: RUN-20261014T053511Z-real-4af4 and
RUN-20261014T152654Z-real-819c (2 tasks, 3 arms, 1 run each; 6 of 6 passed; a second reader
re-derived both and agreed).

## Test runs

Test runs: 2026-10-14 on the tested build tree, macOS with /bin/bash 3.2: `tests/run.sh` 643 passed,
0 failed; the release gates script 26 of 26; `tools/build.py --check` in sync.

## Review tier

Review tier: 4 (see gate 4).

## Approver

Approver: <filled at the go by the owner>

## cso report

The cso report for the scope in the release plan, with each finding closed with
evidence or accepted in writing: the security seat (cso method, Sonnet 5.5 xhigh) reviewed the
candidate in round 1 (4 MAJOR, 9 MINOR, 4 NIT), answered the other seats in round 2, re-checked
its fixed items in round 3 (16 fixed, 3 partly, 1 new MAJOR, fixed and re-checked in round 4), and
ruled on the round 4 security items: verdict ship, no secret, privilege or data-exposure defect.
Every MAJOR is closed by a test that fails before its fix. The open MINOR and NIT items (the
ledger helper's place check judges folder names on the real path only; some hidden-text
characters pass the text cleaning) are accepted in writing in the maintainer's deferred ledger
for a later release, and the helper's header states the limit.

## Tokenizer

The size caps are measured with: estimate, characters divided by 3.2, rounded up; not a tokenizer.
The doctrine block figure is reported by tools/release-check.py.

## Update fetch rules

The fetch rules of conductor update were built in bash 3.2: yes.
Where a rule cannot be met in bash 3.2, update prints the reinstall command and fetches
nothing. That is the case when python3 3.9 or later is missing, because the preview is
read out of the fetched file without running it.

## Tag v0.3.0

Tag v0.3.0 at b9bd18bfda85ae06a8bedf0cd97ffb302932958e
Tag for this release: <filled at the go by the owner>
The previous installer served from its tag: <filled at the go by the owner>

## Main protection read-out

Read-out dated on the day of the go, showing main protected against force push and deletion: <filled at the go by the owner>

## Registrar lock and auto-renew

Registrar lock and auto-renew for the install domain: <filled at the go by the owner>

## 2-factor sign-in

Hardware-key 2FA on the owner's GitHub and registrar accounts: <filled at the go by the owner>
