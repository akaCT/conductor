# Conductor Benchmark

A small, self-benchmarked comparison of stock headless `claude -p` (baseline
arm) against the same command with conductor installed into a sandbox config
directory (conductor arm), across 8 author-written tasks. This lives at
`bench/` in the repo and is never shipped by `install.sh`.

## How to run: mock mode

Mock mode synthesizes deterministic, plausible result JSON without invoking
the `claude` CLI at all. It proves the pipeline (task discovery, result
capture, tier-split reporting) renders end to end, and is the only mode that
should run automatically or in CI.

```bash
cd /Users/ct/dev/conductor/bench
BENCH_MOCK=1 RUNS=2 python3 src/run.py
python3 src/report.py
cat results/results.md
```

Optional: pass `BENCH_BASELINE_MODEL=<model-id>` to control which mock model
label appears in the baseline arm's rows (defaults to `claude-sonnet-5` if
unset in mock mode only; real mode requires it explicitly, see below).

## How to run: real mode

Real mode invokes the actual `claude` CLI for every task x arm x run and
costs real money. Read the HONEST LIMITS and REAL-RUN COST ESTIMATE sections
below before running it.

```bash
cd /Users/ct/dev/conductor/bench
export BENCH_BASELINE_MODEL=claude-sonnet-5   # required, see note below
export RUNS=2                                  # default is 2 if unset
python3 src/run.py
python3 src/report.py
cat results/results.md
```

Every invocation of `run.py` clears `results/raw/*.json` before writing new
results (set `BENCH_KEEP_RAW=1` to accumulate instead). This means a mock
demo run and a later real run never silently mix in the same
`results.md`; each `run.py` call produces a clean, self-consistent report.

`run.py` prepares the conductor sandbox once per invocation: it runs
`/Users/ct/dev/conductor/install.sh` with `CLAUDE_DIR` pointed at a fresh
temp directory and `CONDUCTOR_YES=1` (non-interactive), then points every
conductor-arm `claude` invocation at that same directory via
`CLAUDE_CONFIG_DIR`. These are two different environment variables for two
different programs: `install.sh` reads `CLAUDE_DIR` to decide where to
write, the `claude` binary reads `CLAUDE_CONFIG_DIR` to decide where to
read from at runtime. Both must resolve to the same path, which `run.py`
handles internally; you do not need to set either one yourself.

A bare `claude -p` without `--model` silently inherits whatever model is
configured in the caller's own `settings.json`. That makes a baseline run
unreproducible across machines and sessions, so `run.py` refuses to start a
real run without `BENCH_BASELINE_MODEL` set explicitly, and always passes
`--model` on every invocation of both arms.

## Methodology

- 8 tasks, each in its own directory under `tasks/`, each with a
  `meta.json` (id, category, success_cmd, budget note) and a `prompt.md`.
  - `t1`-`t4`: small, self-contained code tasks (fix a bug, transform a
    CSV, extract emails via regex, count words in bash). Each has a
    `success_cmd` that runs a real check against the task's own output
    files and exits 0 on pass.
  - `t5`-`t6`: research/summarize tasks. The model reads a fixture file
    and replies in its final text (no file write). `success_cmd` is a
    keyword-presence grep over that captured final text.
  - `t7`-`t8`: multi-file tasks (4 fixture files each) that reward
    delegating reads or edits across files rather than working serially.
- Two arms per task: `baseline` (stock `claude -p ... --model <id>`) and
  `conductor` (same command, `CLAUDE_CONFIG_DIR` pointed at a sandbox with
  conductor installed). `RUNS` repetitions of each (default 2) to average
  out run-to-run variance, though 2 runs is not enough to report real
  statistical confidence, see HONEST LIMITS.
- `run.py` captures the CLI's final JSON object per run
  (`--output-format json`) and writes it to
  `results/raw/<task>-<arm>-<n>.json`. It never parses transcripts; every
  number in the report comes from the CLI's own final JSON.
- `report.py` reads all raw files, groups tokens by tier (a `modelUsage`
  key containing "haiku" -> haiku tier, "sonnet" -> sonnet tier, else
  "main"), and computes a MODELED cost from the `PRICING` constants in
  `report.py` alongside the CLI's own REPORTED cost
  (`total_cost_usd` / `modelUsage[*].costUSD`), reported as two separate
  columns so neither is mistaken for the other.

## Pricing provenance

The `PRICING` dict in `src/report.py` (USD per million tokens, input then
output) is CT's standing cost anchor table:

| tier | input | output |
|---|---|---|
| fable | $10.00 | $50.00 |
| opus | $5.00 | $25.00 |
| sonnet | $3.00 | $15.00 |
| haiku | $1.00 | $5.00 |

This table is a point-in-time snapshot, not a live price feed. If Anthropic
changes pricing, the modeled-cost column will drift from the CLI's own
reported cost, which is exactly why both are shown side by side.

## HONEST LIMITS

- This is a self-benchmark: the author of conductor wrote all 8 tasks, the
  runner, and the report. There is no external or adversarial task set.
- 8 tasks and 2 runs each is a small sample. It is enough to prove the
  harness works and to catch large, obvious differences; it is not enough
  to report a statistically confident win rate or a tight confidence
  interval on token savings.
- No external replication. Nobody outside this session has run these
  numbers on their own machine or account.
- Results depend heavily on which model and which Claude plan the caller
  is on, and on conductor's install state and skill set at run time. A
  number generated today on one account's plan is not a universal claim.
- `bench/` is repo-side tooling. It is not installed by `install.sh` and
  ships to nobody as part of the conductor kit; it exists only to let CT
  (or a curious reader building from source) run this comparison locally.
- Mock mode proves the pipeline renders, not that conductor saves tokens
  or money in the real world. Never quote mock numbers as real-world
  results; `results.md` is labeled MOCK DATA whenever any mock run
  contributed to it.

## REAL-RUN COST ESTIMATE

Arithmetic, not a vendor quote. 8 tasks x 2 arms x 2 runs = 32 total
`claude -p` invocations. Using a rough per-call budget of 3,500 combined
input+output tokens (a mix of the t1-t4 small-code budgets, t5-t6
summarize budgets, and t7-t8 multi-file budgets noted in each task's
`meta.json`), at a 60/40 input/output split:

```
baseline arm (16 calls, all priced at sonnet: $3/$15 per MTok in/out):
  16 calls x 3,500 tokens = 56,000 tokens
  input  33,600 tokens -> (33,600 / 1e6) * $3  = $0.10
  output 22,400 tokens -> (22,400 / 1e6) * $15 = $0.34
  baseline arm total ~= $0.44

conductor arm (16 calls, ~15% token inflation from delegation overhead,
  85% of tokens at sonnet rate + 15% at haiku rate: $1/$5 per MTok):
  16 calls x 3,500 tokens x 1.15 = 64,400 tokens
  input  38,640 tokens: 85% sonnet ($3) + 15% haiku ($1) -> ~$0.11
  output 25,760 tokens: 85% sonnet ($15) + 15% haiku ($5) -> ~$0.34
  conductor arm total ~= $0.45

full real run (both arms, RUNS=2): ~$0.89, call it under $1
```

This is a rough planning estimate, not a bound. Research tasks (t5, t6)
that generate longer final-text replies, or multi-file tasks (t7, t8) that
trigger more subagent turns in the conductor arm, can push actual spend
above this estimate; raising `RUNS` above 2 multiplies it linearly.
