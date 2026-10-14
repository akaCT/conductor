# Changelog

All notable changes to Conductor are documented here. A release is dated at its
tag; an entry marked unreleased has no date yet.

## 0.4.0 (unreleased: dated at the tag)

What changed:
- Every agent file now carries a model alias and an `effort` value. A fifth seat, the judge, is part of the core install, with the tools Read, Grep and Glob only. The installer asks which judge rung you are on: rung 1 (`fable`) or rung 3 (`sonnet` in a fresh context). Rung 2, a judge from another lab, comes in a later release.
- The installer can offer a per-model effort pin in your settings, 1 key at a time, only on a recent enough Claude Code on the first-party API, backed up first, and printed instead of written when there is no terminal or no python3.
- The doctrine block was rewritten as rules and "check" instructions in 13 sections. Model versions and dates moved out of it into `model-notes.md`.
- The `/conductor` skill has reflect-and-land for long prompts and a thinking-partner mode for open ones, sets model and effort on every dispatch, and ends with a usage split that invents no counts.
- New in core: a start-and-close contract for continuity, 3 runbooks (reflect-and-land, execution-discipline, review-ladder), a review-ladder Workflow template, a defaults file you own, the `conductor` launcher with `doctor`, `update` and `report`.
- New in the full tier: a handoff skill, a ledger template and 5 hooks, each asked for by name. Hooks never block by default.
- The installer has an `update` command and a `--dry-run`, `--status` and `--uninstall` that read an install manifest in each root.
- Codex model ids moved to a single map, checked against the vendor list on the release date; `conductor doctor` prints each Codex agent's model id and the date the map was checked. Codex gets the new doctrine, agents and skill, and no hooks.
- Removed: the optional oracle tier, and the headline savings figures. Those figures came from synthesized test data (labeled MOCK DATA), not from measurement, and are not claimed.
- Credits are in `THIRD-PARTY-NOTICES.md`.

Upgrade notes from 0.3.0:
- Run the installer again. It recognizes a 0.3.0 install from its manifests and marker, replaces unchanged Conductor files, and removes the old manifests.
- A Conductor file you changed is kept and named. Run with `--replace-modified` to replace it; a backup is made first.
- The doctrine block in `CLAUDE.md` and `AGENTS.md` is replaced between its markers. Your own text outside the markers is not touched.
- If 0.3.0 set your default model or patched `CLAUDE.md`, uninstall still names that change as 0.3.0's.
- The critic agent no longer holds WebFetch, and the judge is new. Check any agent file you edited.
- Codex users: the 0.3.0 model ids point at models that have been retired for some sign-ins. This release replaces them.

Why effort matters, in plain words: in Claude Code, Opus 5.5 and Sonnet 5.5 start at medium effort, and a top-level `effortLevel` in user settings does not reach Opus 5.5. A worker agent with no effort of its own inherits the session's. Conductor pins effort in each agent file, offers a per-model pin in settings with your consent, and tells the session to set effort on each dispatch. Higher effort can use more of your plan's usage. No claim is made about its effect on quality or plan length.

Installer sha256: given beside the installer file

## 0.3.0 (2026-07-04, oracle tier added 2026-07-05/06)

- Economy / write-less ladder: doctrine (mirrored to the Codex adapter) and
  all 4 agents absorbed a write-less economy ladder, tightening output
  discipline across the kit.
- Compact returns: the `/conductor` / `$conductor` skills adopted a compact
  columnar-JSON returns convention with a declared row count, with a
  non-negotiable carve-out: auth, money, migrations, and destructive or
  irreversible operations always stay plain JSON with full warnings, and any
  worker that is unsure stays plain too.
- Oracle tier: added an optional, explicitly-gated escalation above the
  conductor's own tier for setups that have a rarer, more expensive model
  available. It never holds a seat and is never the session default; it is
  reached only via a named gate (flagship synthesis, genuine invention after
  a plateau, an irreversible call, an unconfirmed unanimous panel, or a
  stall after the rest of the escalation ladder). No-op for setups without
  such a tier.
- No new agents or files; same install footprint as 0.2.0.
- Credits 2 ideas reimplemented from public behavior (no code copied) in
  `THIRD-PARTY-NOTICES.md`: Ponytail's minimal-code-first decision ladder,
  and Honey's terse-output/compact-handoff discipline (plus the `bench/`
  harness layout, never shipped by the installer).

## 0.2.0 (2026-07-03)

- UNIVERSAL milestone: Claude Code and Codex CLI adapters shipped together
  in the installer for the first time.
- Landing page taken through 5 deep EBI rounds plus a reframe of the
  headline claim.
- Final 2-critic panel findings fixed and regression-tested: the FAQ
  blast-radius claim, invocation-token accounting, a skill-dir `rm -rf`
  risk, and a backup TOCTOU race.
- Remaining as of this release (unaffected by 0.3.0): real domain and repo,
  and deploy.
