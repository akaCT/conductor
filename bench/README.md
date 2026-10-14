# Conductor bench

A bench that measures what Conductor does to delegation and to cost, in 3 arms
on the same 20 tasks:

- arm `a`: without Conductor
- arm `b`: with Conductor at default effort (installed with the effort pins declined)
- arm `c`: with Conductor and the effort pins

It reports, per arm: how often the model delegates (the delegation rate), how
many tokens each class of model used, what that cost in US dollars at dated
list prices, and how many tasks passed, with 95 percent intervals. It lives in
`bench/` and is never installed by `install.sh`.

Nothing here is a promise. A figure is a measurement from a run record (its
run id, its n, its date and its price table), and a claim about savings,
plan length or quality needs a real-mode run record behind it.

## Run it in mock mode (no claude call, no cost)

Mock mode writes synthetic streams in the same shape as a real run, so the
whole pipeline runs end to end. It calls nothing and installs nothing.

```bash
cd bench
BENCH_MOCK=1 RUNS=2 python3 src/run.py
python3 src/report.py
python3 src/rederive.py "$(ls -t results/RUN-*.json | head -1)"
head -5 results/RUN-*.md
```

Every mock record and page starts with the line `MOCK DATA` and says it is
not evidence. Mock figures are cited nowhere.

## Run it for real

A real run needs a Claude Code config folder that is already signed in, given
explicitly. There is no default, so a real run can never start by accident in
your everyday profile.

1. Make a separate folder and sign in once:
   `CLAUDE_CONFIG_DIR=/path/to/bench-profile claude`
2. Run a cheap smoke run first (2 tasks, 1 run each, 6 runs in all):

```bash
cd bench
export BENCH_CONFIG_DIR=/path/to/bench-profile
export BENCH_MODEL=<model id>        # required, passed as --model on every arm
BENCH_TASKS=t1,t7 RUNS=1 python3 src/run.py
```

3. Read the dollar figure per run in the page, then decide on a full run
   (20 tasks x 3 arms x 3 runs = 180 runs, `RUNS=3 python3 src/run.py`).

What the runner does to the folder:

- It refuses `~/.claude` (your default profile) unless `BENCH_ALLOW_DEFAULT=1`.
- It refuses a folder with no sign-in record. It checks that the file exists
  and never opens, prints or copies any credential file.
- It refuses to start when Conductor is already installed in the folder.
- It refuses to start when arms `a` and `b` would not run at default effort,
  and says which: `settings.json` sets an effort level (a top-level
  `effortLevel`, a `modelSettings` entry or `env.CLAUDE_CODE_EFFORT_LEVEL`), or
  `CLAUDE_CODE_EFFORT_LEVEL` is set in your shell. A `settings.json` that does
  not parse is refused too. Only the parsed file counts: a note that mentions
  the word does not.
- Before any claude run it asks the installer's dry run (`--dry-run --core
  --apply-effort-pins`, which changes nothing) whether arm `c` can be pinned. If
  the dry run would write no pin (an old Claude Code, another provider or
  address, no python3), the run stops there with the installer's own words, so
  no arm is paid for and then wasted.
- Before the first install it copies `settings.json` and `CLAUDE.md` to
  `results/backup-<run id>/` (folder mode 700, files mode 600). `settings.json`
  can hold keys, so treat `backup-*` and `raw/` as private, and delete the
  backup once you have checked the restore.
- Arm `a` runs with Conductor not installed. For arms `b` and `c` it runs this
  repo's `install.sh --core` into the folder without asking anything (`c` adds
  `--apply-effort-pins`), runs the arm, and uninstalls afterward, also when a
  run fails or the runner is interrupted (SIGINT or SIGTERM). Arm `c` stops
  with an error if the installer wrote no pin, and arm `b` stops if it wrote a pin.
- After the last uninstall it checks that `settings.json` and `CLAUDE.md` are
  back byte for byte and that no Conductor install is left (no install record,
  no skill folder, no payload folders). If not, it prints a `FAIL restore
  check` line, keeps the backup and exits 1.
- An uninstall that fails (it exits non-zero, or leaves Conductor behind) is
  fatal. The run stops at that arm, prints the command that removes Conductor
  by hand, exits 1 and marks its record `INVALID RUN`: the record says
  `"valid": false` with the reasons, `scored` is false, and the page opens with
  the label and says it is not evidence. A failed restore check marks the
  record the same way.
- If your `settings.json` writes an object on 1 line, the uninstall may write
  it back spread over several lines. The restore check then reports FAIL with
  "same JSON content, different formatting". Spread such an object over
  several lines first.
- The uninstall leaves a `conductor/` folder (backups and your `defaults.md`),
  but no install record, so a later run is not refused. Those backups can hold
  copies of your `settings.json`.
- Arm `a` is "without Conductor" only if the folder's own `CLAUDE.md` holds no
  delegation rules. The runner prints a note when the folder has such a file.
- Claude and the installer get an environment built from an allowlist: `PATH`,
  `HOME`, `LANG`, `TERM`, `TMPDIR`, `USER` and `SHELL`, plus `CLAUDE_CONFIG_DIR`
  for claude and the installer's own folder variables. Nothing else from your
  shell reaches them: no token, no cloud key, no provider variable such as
  `ANTHROPIC_BASE_URL` or `ANTHROPIC_API_KEY`. The runs use the sign-in record
  in the config folder. The model's Bash tool can still read what your user
  can read, including that folder.
- When the installed `claude --help` lists `--strict-mcp-config`, every run
  gets it with an empty MCP config, so the arms do not see the MCP servers and
  connectors of the account (they add tools and tokens, and differ from
  machine to machine). The record says whether the flag was available. When
  it was not, the arms may see those servers.

Each task runs in a fresh temp folder with the fixture files only. The check
script is copied in after the run ends, so the model never sees it. Each run is
`claude -p --output-format stream-json --verbose --model <id>` with the task
prompt on stdin, `--permission-mode acceptEdits` and `--allowedTools
Bash,Edit,Write` (override with `BENCH_PERMISSION_MODE` and
`BENCH_ALLOWED_TOOLS`), and `WebFetch` and `WebSearch` disallowed. That lets
the model run shell commands without asking, in a temp folder, as you. Use a
machine and an account you are content to run unattended agents on.

### Environment variables

| variable | meaning |
|---|---|
| `BENCH_MOCK=1` | synthesize every run; nothing is called or installed |
| `RUNS` | runs per task per arm (default 3) |
| `BENCH_TASKS` | comma separated ids or id prefixes, for a smoke run (default: all 20) |
| `BENCH_MODEL` | model id passed as `--model` on every arm; required in real mode, no default there |
| `BENCH_CONFIG_DIR` | real mode only, required: the signed-in config folder |
| `BENCH_ALLOW_DEFAULT=1` | allow `~/.claude` as the config folder |
| `BENCH_TASK_TIMEOUT_S` | per run limit in seconds (default 300); a run that hits it is an error |
| `BENCH_RESULTS_DIR` | where results go (default `bench/results`) |
| `BENCH_INSTALLER` | the `install.sh` used for arms `b` and `c` (default: this repo's) |
| `BENCH_RUN_ID` | fix the run id (default: UTC time, mode and 4 random hex) |

## What a run leaves

Under `results/` (ignored by git, except `results/example/`, where a labeled
example may be committed: a mock record, which starts with `MOCK DATA`):

- `RUN-<run id>.json`: the run record. It holds the task set (each task id
  with a hash of its folder), the 3 arms, n, tokens by model class, the price
  table with its source and date, dollars per task and per arm, pass rates with
  95 percent intervals, delegation rates with numerator and denominator, the
  run ids (1 session id per run) and the restore check. The environment block
  names the commit the bench ran from, the installer sha256, the Claude Code
  version, the Conductor version, the bench version, the environment allowlist
  and whether `--strict-mcp-config` was used. `valid` is false (with
  `invalid_reasons`) for an `INVALID RUN`.
- `RUN-<run id>.md`: the same record as a page.
- `raw/<run id>/<task>__<arm>__<n>.jsonl`: the raw stream of every run, plus
  1 last line of type `bench_outcome` with the task, arm, run number and the
  pass, fail or error result, so each file stands alone.
- `backup-<run id>/`: the backup of `settings.json` and `CLAUDE.md` (real
  mode), private like `raw/`.

A page starts with `MOCK DATA` for a mock run, and with `SMOKE RUN: not scored`
for any run of fewer than 20 tasks or fewer than 3 runs per task. A smoke run
checks the pipeline and never feeds the 1.0.0 gate. A page with several labels
shows each on its own line.

## How the figures are made

- **Delegation rate** of an arm: dispatch tool calls (`Agent` or `Task`) over
  all tool calls, summed over its runs, counting only the top level
  conversation. A call made inside a subagent has a `parent_tool_use_id` and is
  not counted. The page shows the 2 counts, not just the ratio.
- **Tokens by model class**: from the `modelUsage` of each run's result, grouped
  by the family in the model id (`opus`, `sonnet`, `haiku`, `fable`, `other`),
  as input, output, cache read and cache write. A subagent that ran on a
  cheaper model is counted under its own class. The roles inside Conductor
  (builder, scout, critic) cannot be told apart from per-model usage, so the
  classes are model families.
- **Dollars**: the tokens times the rates in `prices.json`, which copies the
  public Anthropic pricing page (the source URL and the date it was read are
  in the file and in every record). The CLI's own `total_cost_usd` is kept
  beside it as the reported figure. A model with no row is left out of the
  dollars and listed, so the dollar figure is then a lower bound.
- **Pass rate**: passed over all runs of the arm. A run that died before its
  check (a crash, a timeout, a limit, an error result) is an error and counts
  as not passed. A task that was not run is listed with its reason.
- **Intervals and differences**: a Wilson score interval at 95 percent for each
  pass rate, treating every run as an independent trial. 2 arms are called
  different only where their intervals do not overlap. Where they overlap, the
  record says `not distinguishable at n=...`. No difference in delegation
  rate or cost is claimed: those are reported as counts and dollars only.

## Second seat

```bash
python3 src/rederive.py results/RUN-<run id>.json
```

It recomputes every figure from the raw streams with its own code (it imports
nothing from the runner or the reporter), re-hashes the task folders, and
prints `AGREE` or a list of differences. A task folder edited after the run
shows up as a difference, which is how the task set stays frozen. The second
seat signs the run in the release record; the tool only does the arithmetic.

## The task set

20 tasks in `tasks/`, each with a `meta.json` (id, category, `success_cmd`,
budget note), a `prompt.md` and its fixtures. The check script of a task
(`check.py` or `check.sh`) is what decides pass or fail.

| tasks | what |
|---|---|
| `t1` to `t4` | small code tasks in 1 file |
| `t5`, `t6`, `t19` | read fixture files and answer in the final reply (the check reads the reply) |
| `t7`, `t8`, `t9` to `t14`, `t20` | several files with independent parts: they reward delegation |
| `t15` to `t18` | small scripts: classify commits, validate records, rename files, query with SQL |

t1 to t8 come from 0.3.0. t9 to t20 were written for this release. The set is
frozen by the hashes in each run record: `rederive.py` names any task folder
edited after a run, so do not edit a task after its first scored run; add a
new task id instead. A task set owned by a person is still to come, with a
second person re-keying the checks of 5 tasks. Until then treat results on
this set as a first look.

## Cost note

The unit is US dollars per bench task run to its end, at the list prices of
the price table dated in the record (`prices.json`, read on 2026-10-13). The
figures are measured from the token counts `claude` reports for your runs and
priced at that table. They are not promised, and they are not a forecast for
your own use: they depend on the model, on how much the model reads, and on how
often it delegates.

To plan a full run, run the smoke run first and multiply its dollars per run by
180. Raising `RUNS` multiplies the cost in step.

## Limits

- The tasks have had no outside review and the results no outside
  replication yet.
- Runs of the same task are not independent in the strict sense, so the
  intervals are optimistic.
- The arms run in sequence (all of `a`, then `b`, then `c`) on a single
  machine, so a change in the service or the model between them looks like an
  arm effect.
- Haiku 5.5 is priced by prompt length on the source page; the table uses the
  rate for prompts up to 100,000 tokens.
- Pass or fail is only what the check script sees; it says nothing about code
  quality.
- The config folder's own plugins, hooks and settings are the same for every
  arm and are not isolated. Use a fresh signed-in folder.
