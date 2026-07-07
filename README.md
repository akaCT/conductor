# Conductor

[![Website](https://img.shields.io/badge/website-conductorskill.com-22ff88?style=flat-square)](https://conductorskill.com)
[![GitHub stars](https://img.shields.io/github/stars/akaCT/conductor?style=social)](https://github.com/akaCT/conductor/stargazers)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](./LICENSE)

Current version: 0.3.0. See [CHANGELOG.md](CHANGELOG.md) for release history.

**Every Claude Code or Codex session becomes an orchestrator. You conduct; cheaper models play.**

Conductor makes your session's expensive model do only what expensive reasoning is
for - understanding intent, decomposing work, routing, judgment, and synthesis -
and delegates the actual labor (writing code, running greps, drafting, reviewing)
to cheaper pinned models. Because weekly plan limits weight usage by per-token
cost, and execution tokens dwarf orchestration tokens, this cuts your plan burn
substantially: usually **60-80% less** for build-heavy work (the same fact as
stretching a plan 3-5x longer), less if your default model is already a cheap
one. Works on Claude Code today; Codex CLI support ships in this release too.

## Install

```bash
curl -fsSL https://conductorskill.com/install.sh | bash
```

Then open a **new** session and hand it something real:

```
/conductor add pagination to the users API and cover it with tests
```

It plans on your primary model, dispatches the work to `sonnet` builders and
`haiku` scouts in parallel, verifies with a `critic` panel, and reports back with
a one-line usage split so you can see where the tokens went.

Uninstall anytime:

```bash
curl -fsSL https://conductorskill.com/install.sh | bash -s -- --uninstall
```

## What it installs

Into `~/.claude/`:

| Path | What |
|---|---|
| `agents/builder.md` | sonnet - all hands-on implementation work |
| `agents/scout.md` | haiku - cheap recon (greps, inventories, status checks) |
| `agents/critic.md` | sonnet - adversarial review / verification panels |
| `agents/architect.md` | opus - deep design for epics (used sparingly) |
| `skills/conductor/SKILL.md` | the `/conductor` orchestration loop |
| `CLAUDE.md` | a marked, idempotent doctrine block that makes **every** session delegate by default, and every agent write less |

Into `~/.codex/` and `~/.agents/`, when Codex CLI is detected:

| Path | What |
|---|---|
| `~/.codex/AGENTS.md` | a marked, idempotent doctrine block for Codex sessions |
| `~/.codex/agents/*.toml` | the same crew (builder, scout, critic, architect), pinned to GPT-5.4 / GPT-5.4-mini / GPT-5.5 |
| `~/.agents/skills/conductor/` | the orchestration loop for Codex sessions, invoked as `$conductor` (or from `/skills`) |

The models (`sonnet`/`haiku`/`opus` on Claude Code; GPT-5.4/GPT-5.4-mini/GPT-5.5
on Codex) are aliases that resolve to whatever your plan provides, so the same
kit works whether your primary model is Opus, GPT-5.5, or anything else you run
as your session default.

## Safe by design

- Backs up `CLAUDE.md` and any agent it would replace before touching them.
- Writes its doctrine between `<!-- BEGIN CONDUCTOR (managed) -->` markers, so
  re-running updates the block instead of duplicating it, and `--uninstall`
  removes exactly that block and nothing else.
- Records a manifest so uninstall cleanly reverses the install.
- Stays interactive under `curl | bash`; set `CONDUCTOR_YES=1` for unattended.

## Requirements

- Claude Code with access to the `sonnet` and `haiku` model tiers (any paid plan).
  `opus` is used only by the `architect` agent for epic-scale design; if your
  plan has no Opus, skip that agent - everything else still works.
- Codex CLI with GPT-5.4 and GPT-5.4-mini. GPT-5.5 is used only by the
  `architect` agent for epic-scale design.
- Copilot support is a fast-follow. Gemini / Antigravity support is deferred
  pending that product's transition.
- Optional: an improvement skill such as `ebi-process` and any domain-expert
  skills. Conductor uses them if present and skips them if not.
- Per-agent model pinning requires a current CLI: Claude Code mid-2026 or
  later, or Codex CLI with custom agents support.

## How it works

Two parts:

1. **Always-on doctrine** (the `CLAUDE.md` block): every session reads it and
   behaves as a project manager - it delegates instead of doing the labor itself.
   It also carries a write-less economy ladder so every agent (and the loop's
   own reports) defaults to terser output - fewer wasted tokens on either side
   of the delegation.
2. **The `/conductor` skill**: invoke it to run the full structured loop (recon
   -> plan -> parallel dispatch -> verify -> synthesize) on a big objective.
   Routine returns come back as compact columnar JSON with a declared row
   count; anything touching auth, credentials, money, migrations, deletions,
   or anything else destructive or irreversible still returns plain JSON, and
   when a worker is unsure it stays plain.

## Uninstall / files

Everything installed is tracked in `~/.claude/skills/conductor/.install-manifest`.
Backups from an install run carry a `.bak.<timestamp>` suffix and are left in
place after uninstall.

## Wear the badge

Conductor cutting your burn? Add the badge. It points people back here:

[![Conducted with Conductor](https://img.shields.io/badge/conducted%20with-Conductor-22ff88?style=flat-square)](https://conductorskill.com)

```markdown
[![Conducted with Conductor](https://img.shields.io/badge/conducted%20with-Conductor-22ff88?style=flat-square)](https://conductorskill.com)
```

## License

MIT (see LICENSE). Third-party attributions (ideas reimplemented,
no code copied) are in `THIRD-PARTY-NOTICES.md`.
