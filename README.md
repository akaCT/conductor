# Conductor

[![Website](https://img.shields.io/badge/website-conductorskill.com-22ff88?style=flat-square)](https://conductorskill.com)
[![GitHub stars](https://img.shields.io/github/stars/akaCT/conductor?style=social)](https://github.com/akaCT/conductor/stargazers)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](./LICENSE)

Current version: 0.4.0. See [CHANGELOG.md](CHANGELOG.md) for release history.

Conductor is a set of files you install into Claude Code or Codex CLI. It adds a doctrine
block to your main session's instructions, worker agents that each name a model and an
effort level in their own file, a `/conductor` skill, and a plain-file checkpoint format for
handing work from one session to the next.

## What Conductor is, and is not

It is:
- a short always-on doctrine for your main session, kept between markers in `CLAUDE.md` or `AGENTS.md`;
- a crew of agents with an explicit model and effort per seat: builder, scout, critic, architect and judge;
- the `/conductor` skill (`$conductor` on Codex): reflect-and-land for long prompts, a thinking-partner mode for open ones, dispatch contracts, a review ladder and a close with a usage split;
- 3 runbooks, a defaults file you own, a review-ladder Workflow template and dated model notes;
- an installer with an `update` command, plus `conductor doctor` and `conductor report`;
- with the full tier, a handoff skill, a ledger template and 5 optional hooks you accept one by one.

It is not:
- a runtime, daemon or swarm manager: it is files, agents and a few hooks;
- a memory system or knowledge graph: continuity is plain-file checkpoints;
- a replacement for Claude Code's own Workflows or for process kits: it sets the model and effort of each worker and leaves the process to you;
- a sandbox: a scope line in a contract is an instruction, not a permission;
- an autopilot for money, production, outbound messages or deletions: those come back to you.

## Install

```bash
curl --proto '=https' --tlsv1.2 -fsSL https://conductorskill.com/install.sh | bash
```

To add the full tier, pass `--full` through bash: `... | bash -s -- --full`. To see every
action first, add `--dry-run`. Nothing outside Conductor's own files changes without your
yes: a prompt answer, a flag, or a name in `CONDUCTOR_COMPONENTS`. Run under `curl | bash`,
the installer still asks its questions on your terminal. With no terminal at all, the
installer asks nothing. It adds only what a flag or `CONDUCTOR_COMPONENTS` names (a hook it
adds is wired into your settings, and each one is printed) and keeps what its install record
already holds. Effort pins are printed, not written, and no default model is set.

Open a new session and hand it something real:

```
/conductor add pagination to the users API and cover it with tests
```

## The launcher

The installer writes a launcher inside your Claude folder and prints this line for you to
copy into your shell profile:

```bash
alias conductor="$HOME/.claude/conductor/bin/conductor"
```

Nothing is put on your PATH for you. After the alias:

- `conductor doctor` prints what your install will do: which model each seat expects, where each seat's effort comes from, which hooks are wired, and what is off for your setup. It reads files and the environment, asks `claude` and `codex` for their version numbers, and sends nothing.
- `conductor update` moves an install to the newest release in place and keeps files you changed. `conductor update --check` only says whether a newer release exists.
- `conductor report` builds a bug report from a short list of fields, shows you all of it, and opens a prefilled GitHub issue that you read and send yourself.

## Effort, in plain words

Effort is how long a model thinks before it answers or acts. In Claude Code, Opus 5.5 and
Sonnet 5.5 start at medium effort. A top-level `effortLevel` in your user settings does not
reach Opus 5.5; the setting that does is a per-model pin under `modelSettings`. A worker
agent with no effort of its own inherits the session's effort. So a default setup can run
the conductor and its workers at medium without you knowing.

Conductor changes this in 3 places, each with your yes where it touches your settings:
every agent file it ships carries an `effort` line; the installer explains this and offers a
per-model pin, 1 key at a time, backed up first; and the skill tells the session to set model
and effort on each dispatch. Higher effort can use more of your plan's usage. Conductor makes
no claim about what effort does to quality or to how long a plan lasts.

## Update, uninstall, and what is installed

Update with `conductor update`, or run the installer again. Uninstall:

```bash
curl --proto '=https' --tlsv1.2 -fsSL https://conductorskill.com/install.sh | bash -s -- --uninstall
```

Every install writes a manifest at `conductor/.install-manifest` in each root it touched.
Uninstall reverses what the manifest lists and leaves your own files alone. Backups go to
`conductor/backups/` inside the same root and are kept.

Claude Code, into your Claude folder (default `~/.claude/`): 5 agents (`builder`, `scout`,
`critic`, `architect`, `judge`), the `/conductor` skill, the doctrine block in `CLAUDE.md`,
3 runbooks, a review-ladder Workflow template, `model-notes.md`, `defaults.md`, the launcher
and the doctor. The full tier adds the handoff skill, a ledger template and the hooks.

Codex CLI, when it is detected: a doctrine block in `~/.codex/AGENTS.md`, 4 agents in
`~/.codex/agents/` (the judge is Claude-only), and the skill in `~/.agents/skills/conductor/`,
used as `$conductor`. Codex gets no hooks and no effort fixer, and `conductor doctor` reports
each Codex agent's model id and shows its effort as not pinned.

## Plans and setups

- Opus available (the default): the seat map in the doctrine applies as written.
- No Opus on your plan: the installer cannot read your plan, so this is documented, not detected. Use a Sonnet conductor and skip the architect. You get a different-model tier 2 reviewer only if your account has the Fable 5.1 judge or you bring a model from another lab yourself.
- A cloud provider or a custom base URL: aliases can resolve to older models there. The installer writes no model id and no pin, and the doctor prints the model each alias is expected to reach.
- Codex: doctrine, agents and the loop, as above.

The judge is the most independent view you have. Rung 1 is the `fable` alias, offered when you
say your account has it and your Claude Code is recent enough. Rung 3 is `sonnet` at xhigh in a
fresh context, a weaker view because it is the same lab. Rung 2, a judge from another lab, comes in
a later release. The installer asks which rung you are on and keeps your answer on update.

## Codex model ids

The Codex agent files take their model ids from a single map in `payload/components.json`. It was
checked against the vendor's model list on the release date, recorded in the release record.
Model ids retire, so run `conductor doctor` after a Codex update: it prints each agent's model id
and the date the map was checked.

The builder and critic use `gpt-6.1-sol`. The vendor lists it for Plus, Pro, Business, Enterprise
and Edu at launch; Enterprise and Edu need an administrator to turn it on. Free and Go are not on
that list. If you sign in with Free or Go, set builder and critic to `gpt-6-luna`: change the
`model` line in `~/.codex/agents/builder.toml` and `~/.codex/agents/critic.toml`. The doctor sends
nothing and cannot see your plan, so it does not tell you when a model is unavailable to you.

## What is collected

Nothing is collected, and Conductor sends nothing about you anywhere. Only 1 command reaches
the network: `conductor update` (and `conductor update --check`) downloads the newest installer
from `https://raw.githubusercontent.com/akaCT/conductor/main/install.sh`. That address is fixed
in the launcher, the fetch uses HTTPS only, and it refuses a redirect to any other host. The
request carries no data about you or your install. `conductor report` builds a report from a
fixed list of fields (versions, seat aliases, hook names, counts; never prompts, code, paths,
names or keys), shows you all of it, and opens an issue in your browser that you read and send.

## Turning the hooks off

Hooks run unless `CONDUCTOR_HOOKS=off` is set in Claude Code's environment. Set it there
(`0` and `false` work too, in any letter case) and every hook Conductor wired does nothing
for that session. Unset it to turn them back on. `conductor doctor` prints the state: off, set
but not an off value (hooks still run), or not set. A hook whose script is missing or
unreadable does nothing too.

## Requirements

- Claude Code with the `sonnet` and `haiku` aliases. Claude Code 2.1.293 or later is required for Haiku 5.5; below that the installer says so and leaves the Haiku setting alone. The effort pins are offered from 2.1.280 (Opus 5.5) and 2.1.284 (Sonnet 5.5), each only with your yes.
- python3 (3.9 or later) for the full tier, the hooks, settings pins, the doctor and `conductor update`. Without it, the core files still install.
- Optional: an improvement skill such as `ebi-process` and any domain-expert skills. Conductor uses them when present and skips them when not.

## License

MIT (see LICENSE). Third-party attributions are in `THIRD-PARTY-NOTICES.md`.
