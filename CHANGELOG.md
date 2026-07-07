# Changelog

All notable changes to Conductor are documented here. Dates reflect when the
work landed in this repo, per `SPEC.md`'s status line.

## 0.3.0 (2026-07-04, oracle tier added 2026-07-05/06)

- Economy / write-less ladder: doctrine (mirrored to the Codex adapter) and
  all four agents absorbed a write-less economy ladder, tightening output
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
- Credits two ideas reimplemented from public behavior (no code copied) in
  `THIRD-PARTY-NOTICES.md`: Ponytail's minimal-code-first decision ladder,
  and Honey's terse-output/compact-handoff discipline (plus the `bench/`
  harness layout, never shipped by the installer).

## 0.2.0 (2026-07-03)

- UNIVERSAL milestone: Claude Code and Codex CLI adapters shipped together
  in the installer for the first time.
- Landing page taken through 5 deep EBI rounds plus an 80% reframe of the
  headline savings claim.
- Final 2-critic panel findings fixed and regression-tested: the FAQ
  blast-radius claim, invocation-token accounting, a skill-dir `rm -rf`
  risk, and a backup TOCTOU race.
- Remaining as of this release (unaffected by 0.3.0): real domain + repo
  (CT gates), deploy, a Copilot fast-follow, and a Gemini / Antigravity
  re-sweep in 2-4 weeks.
