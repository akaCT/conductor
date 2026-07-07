> NOTE (2026-07-03): superseded by the live index.html. v2 reframed the hero to "Same work. Up to 80% less plan usage." and added Codex positioning; this file is the original v1 copy brief, kept for history.

# Conductor landing page - canonical copy + direction

Voice: confident, technical, a little irreverent. Short lines. No hype words, no
em/en dashes. Talks to a Claude Code power user who feels their weekly limit.
Install domain: `conductorskill.com` (was a placeholder in this v1 brief; resolved 2026-07-06).

Design: dark terminal-premium. Near-black canvas, one accent (electric/amber or
green-on-black terminal), mono for code + labels, a clean humanist sans for prose.
Real terminal motifs (prompt glyphs, blinking cursor, a live "usage split"
readout). Restraint over decoration. Award-bar polish: precise spacing, one
tasteful motion idea done well, fast, responsive, accessible.

---

## HERO (number + live demo)

Eyebrow: `for Claude Code`

H1: **Your Claude plan, 3-5x longer.**

Subhead: Conductor turns every session into an orchestrator. Your expensive model
plans and judges. Cheaper models do the labor. One command, and every session
starts delegating.

Primary CTA (the hero visual is this, live-styled terminal with a copy button):
```
curl -fsSL https://conductorskill.com/install.sh | bash
```
Copy button label: `copy`  ->  on click: `copied`

Secondary link: `how it works ↓`

Hero side/under visual - an animated "usage split" readout that types out:
```
> /conductor add pagination to the users API + tests

  Planning on your primary model...
  Dispatching wave (parallel):
    builder  · sonnet   writing endpoint + tests
    builder  · sonnet   updating the client
    scout    · haiku    mapping call sites
  Verifying: 2 critic · sonnet  (correctness, reproduce)

  Primary: plan + adjudication + synthesis
  Dispatched: 2 builder (sonnet), 1 scout (haiku), 2 critic (sonnet)
```
Small caption under it: `You did the thinking. They did the typing.`

---

## PROBLEM (tension, one screen)

Kicker: **Your best model is doing your worst work.**

Body: Every grep, every boilerplate edit, every test file runs on your most
expensive model and counts against your weekly limit at the highest rate. You are
paying top-tier prices to do bottom-tier work. The fix is not a cheaper model. It
is the right model for each job.

---

## HOW IT WORKS (You conduct. Cheaper models play.)

Three beats, ideally a simple diagram (one conductor node fanning out to worker nodes):

1. **You conduct.** The session's primary model does only what expensive reasoning
   is for: intent, decomposition, routing, judgment, synthesis.
2. **The crew plays.** builders (sonnet) write the code, scouts (haiku) gather
   facts, critics (sonnet) review, all in parallel.
3. **Your plan stretches.** Weekly limits weight usage by per-token cost, and the
   labor is the bulk of the tokens. Move it down a tier and your plan goes further.

---

## THE CREW (four cards, mono headers)

- **builder** · sonnet - features, fixes, refactors, tests, scripts, drafts.
- **scout** · haiku - greps, inventories, config dumps, status checks. Read-only.
- **critic** · sonnet - adversarial review panels that try to break the work.
- **architect** · opus - deep design for epics. Used sparingly.

Footnote: models are pinned per agent, so a dispatch can never silently burn your
primary model. `sonnet`/`haiku`/`opus` resolve to whatever your plan provides.

---

## WHAT YOU GET (feature grid)

- **Every session delegates by default.** A managed block in your CLAUDE.md, so it
  is always on, not a thing you have to remember.
- **`/conductor` for the big jobs.** The full loop: recon, plan, parallel dispatch,
  verification rounds, synthesis.
- **Verification built in.** Critic panels refute the work before you ship it.
- **Safe installer.** Backs up everything it touches, idempotent, one-command
  uninstall. It never clobbers a file without a recoverable backup.

---

## THE MATH (honest, not hyped)

Short block. Weekly plan limits (or your API bill) weight usage by per-token cost.
On build-heavy work the execution tokens dwarf the orchestration tokens, so routing
the labor to cheaper tiers commonly stretches a plan 3-5x. Less if your session
default is already a cheap model, more if you delegate aggressively. No magic, just
routing.

---

## INSTALL (repeat CTA + requirements)

```
curl -fsSL https://conductorskill.com/install.sh | bash
```
Then open a new session and run: `/conductor <your objective>`

Requirements: Claude Code with the `sonnet` and `haiku` tiers (any paid plan).
`opus` is used only by the architect agent for epics; no Opus, skip it, the rest
works. Uninstall anytime:
```
curl -fsSL https://conductorskill.com/install.sh | bash -s -- --uninstall
```

---

## FAQ (tight)

- **Is it safe to edit my CLAUDE.md?** Yes. Conductor writes its block between
  managed markers, backs the file up first, and `--uninstall` removes exactly that
  block and nothing else.
- **Will it change the quality of my results?** No. The same powerful model still
  does all the thinking and judging. Cheaper models just do the labor, under its
  direction, and it verifies the work.
- **Does it work on my plan?** Any paid Claude Code plan with sonnet and haiku. No
  Opus needed for the core.
- **Do I have to learn a workflow?** No. Install it and keep working. It delegates
  on its own. Use `/conductor` when you want the full loop on a big task.

---

## FOOTER

Conductor - you conduct, cheaper models play.
Links: GitHub, install, license (MIT). Small print: not affiliated with
Anthropic; "Claude" and "Claude Code" are theirs.

## CTA repetition
Primary install command appears at least 3 times: hero, mid-page (after How It
Works or The Math), and the Install section. Sticky top-bar "install" button that
smooth-scrolls to the hero command is a plus.
