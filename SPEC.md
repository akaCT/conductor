# Conductor - design spec

Date: 2026-07-04
Status: v0.3.0 economy absorption DONE (2026-07-04); no new agents or files, same install footprint as v0.2.0. Domain (conductorskill.com) and MIT LICENSE wired 2026-07-06. Prior milestone v2 UNIVERSAL DONE + verified (2026-07-03): Claude Code + Codex adapters shipped in installer v0.2.0; landing page through 5 deep EBI rounds + the 80% reframe; final 2-critic panel findings (FAQ blast-radius claim, invocation tokens, skill-dir rm -rf, backup TOCTOU) all fixed and regression-tested. Still remaining from that milestone (unaffected by v0.3.0): repo creation (CT gates), deploy, Copilot fast-follow, Gemini/Antigravity re-sweep in 2-4 weeks.

## What it is

Conductor turns every Claude Code or Codex session into an orchestrator. The
session's primary (expensive) model spends its tokens only on judgment work:
intent, decomposition, routing, dispatch contracts, adjudication, synthesis, and
talking to the user. Cheaper pinned models (sonnet/GPT-5.4 builders, haiku/mini
scouts) do the labor. Because weekly plan limits weight usage by per-token cost,
and execution tokens dominate orchestration tokens, routing the labor down cuts
plan burn noticeably (headline: usually 60-80% less, the same fact as a plan
lasting 3-5x longer, hedged on the page for users whose default is already
cheap). Claude Code and Codex CLI are supported now; Copilot is a fast-follow;
Gemini / Antigravity support is deferred pending that product's transition.

**v0.3.0**: doctrine (mirrored to Codex) and all four agents absorbed a
write-less economy ladder, and the `/conductor` / `$conductor` skills adopted
a compact-returns convention (columnar JSON, declared row count) with a
non-negotiable carve-out for auth, money, migrations, and destructive
operations, which stay plain JSON with full warnings. Two ideas (Ponytail,
Honey) are credited in `THIRD-PARTY-NOTICES.md`: reimplemented from their
public behavior, no code copied.

## Decisions (locked with the user)

- Name: **Conductor** (metaphor: one conductor, an orchestra of cheaper models).
- Install: **one-command curl installer** (also the landing-page CTA).
- "Every session delegates" mechanism: **a marked doctrine block appended to
  `~/.claude/CLAUDE.md`** (idempotent, backed up). This is how the original
  author's setup works and the only mechanism that is always-on and general.
- v1 scope: **core kit** - 4 agents + doctrine + `/conductor` skill + installer.
  EBI / expert skills are used *if present*, skipped gracefully if not.
- Harness scope: **Claude Code + Codex CLI** ship together. Copilot is a
  fast-follow; Gemini / Antigravity support is deferred pending that product's
  transition.
- Installer **offers** to set the default model in settings.json, default OFF.
- Agent names stay plain (`builder`/`scout`/`critic`/`architect`); the installer
  handles collisions by backing up and prompting.
- Domain: **conductorskill.com** (wired into `install.sh`'s `CONDUCTOR_URL`,
  README.md, and site/index.html as of 2026-07-06).

## What ships (installed layout)

```
~/.claude/
  agents/{builder,scout,critic,architect}.md   # models pinned in frontmatter
  skills/conductor/{SKILL.md,VERSION}          # /conductor loop
  CLAUDE.md                                     # doctrine block between markers

~/.codex/                                       # when Codex CLI is detected
  AGENTS.md                                     # doctrine block between markers
  agents/*.toml                                 # same crew, pinned to GPT-5.4/mini/GPT-5.5

~/.agents/skills/conductor/                     # the loop for Codex, invoked as $conductor
```

Repo layout (this dir):
```
conductor/
  install.sh          # self-contained installer (payloads embedded as heredocs)
  payload/            # human-readable source mirror of what install.sh writes
    doctrine.md
    agents/*.md
    skills/conductor/{SKILL.md,VERSION}
  SPEC.md  README.md
  site/               # landing page (built after the kit is approved)
```

## Installer behavior (safety is the product)

- Backs up `CLAUDE.md` and any colliding agent before editing (suffix `.bak.<ts>`).
- Writes the doctrine between `<!-- BEGIN CONDUCTOR (managed) ... -->` /
  `<!-- END CONDUCTOR (managed) -->`; re-running replaces, never duplicates.
- Reads y/n from `/dev/tty` so it stays interactive under `curl | bash`;
  `CONDUCTOR_YES=1` or no tty -> safe defaults.
- Writes a manifest; `--uninstall` reverses everything and strips the block.
- Verified on bash 3.2 (macOS default): install, idempotent re-run, collision
  backup, content preservation, uninstall.

## Generalization from the source setup

Stripped: private fleet names, product/brand names, private skill names, the
memory/AAR plumbing, and account-specific dollar prices. Parameterized: model
tiers -> generic `sonnet`/`haiku`/`opus` aliases. Degrades gracefully when a tier
or an improvement/expert skill is absent.

## Open items

1. ~~Domain / `CONDUCTOR_URL`~~ DONE: conductorskill.com wired 2026-07-06.
2. Repo creation deferred until the user approves. When the public git repo is
   created, `.gitignore` must exclude `*.bak` files (the kit's rollback
   convention).
3. ~~Kit's own `LICENSE` file~~ DONE: MIT `LICENSE` added 2026-07-06
   (`THIRD-PARTY-NOTICES.md` already existed for third-party attributions).
4. SessionStart reinforcement hook: evaluated for v0.3.0, deferred to the
   next release. Recommendation: give it its own emit function and mirror
   `payload/`/`~/.claude/hooks/` so it inherits sync-check discipline.
