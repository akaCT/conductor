#!/usr/bin/env python3
"""Conductor benchmark runner.

Iterates tasks x arms x RUNS, invokes the claude CLI (or synthesizes mock
output when BENCH_MOCK=1), and stores each run's final result JSON under
results/raw/<task>-<arm>-<n>.json.

Arms:
  baseline    stock headless claude, explicit --model from BENCH_BASELINE_MODEL
  conductor   same command, but CLAUDE_CONFIG_DIR points at a sandbox where
              this runner has already run conductor's install.sh once

Env vars:
  RUNS                  number of runs per task per arm (default 2)
  BENCH_MOCK            if "1", skip claude entirely and synthesize plausible
                         result JSON (deterministic, seeded by task id + arm)
  BENCH_BASELINE_MODEL  model id passed to --model for the baseline arm
                         (required for real runs; a bare `claude -p` without
                         --model silently inherits whatever is in the caller's
                         settings.json, which would make the baseline arm
                         unreproducible)
  BENCH_CONDUCTOR_MODEL model id passed to --model for the conductor arm
                         (defaults to BENCH_BASELINE_MODEL so the model is
                         held constant and the sandbox/skill is the only
                         variable)
  BENCH_TASK_TIMEOUT_S  per-run timeout in seconds for real runs (default 300)
  BENCH_KEEP_RAW        if "1", do not clear results/raw/ before this run.
                         Default behavior clears stale *.json result files
                         at the start of every invocation, so a mock run
                         followed by a real run (or vice versa) never
                         silently mixes both in the same results.md.

This script is stdlib-only. No third-party imports.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parent.parent
TASKS_DIR = BENCH_DIR / "tasks"
RAW_DIR = BENCH_DIR / "results" / "raw"
CONDUCTOR_ROOT = BENCH_DIR.parent  # /Users/ct/dev/conductor
INSTALL_SH = CONDUCTOR_ROOT / "install.sh"

ARMS = ("baseline", "conductor")

# Pricing dict lives in report.py (single source of truth for cost modeling).
# run.py never computes cost; it only captures what the CLI reports.


def discover_tasks() -> list[str]:
    if not TASKS_DIR.is_dir():
        return []
    return sorted(
        p.name
        for p in TASKS_DIR.iterdir()
        if p.is_dir() and (p / "meta.json").is_file()
    )


def load_meta(task_id: str) -> dict:
    with open(TASKS_DIR / task_id / "meta.json") as f:
        return json.load(f)


def load_prompt(task_id: str) -> str:
    with open(TASKS_DIR / task_id / "prompt.md") as f:
        return f.read()


# ---------------------------------------------------------------------------
# Mock mode: deterministic synthesized result JSON, same shape as the real
# `claude -p ... --output-format json` final object described in run.py's
# module docstring pin. No claude invocation happens in mock mode.
# ---------------------------------------------------------------------------


def _seeded_float(seed_text: str, low: float, high: float) -> float:
    """Deterministic pseudo-random float in [low, high), seeded by seed_text."""
    digest = hashlib.sha256(seed_text.encode("utf-8")).hexdigest()
    frac = int(digest[:8], 16) / 0xFFFFFFFF
    return low + frac * (high - low)


def synth_mock_result(task_id: str, arm: str, run_n: int, model: str) -> dict:
    """Build a plausible final-result JSON for one (task, arm, run).

    baseline: all tokens attributed to the single main model.
    conductor: ~25% main / 60% sonnet / 15% haiku, with a modest total
    token inflation (delegation overhead from subagent dispatch), matching
    the split described in the task contract.
    """
    seed = f"{task_id}:{arm}:{run_n}"

    base_input = int(_seeded_float(seed + ":in", 1200, 4200))
    base_output = int(_seeded_float(seed + ":out", 400, 1600))
    cache_read = int(_seeded_float(seed + ":cr", 0, 2000))
    cache_creation = int(_seeded_float(seed + ":cc", 0, 500))
    duration_ms = int(_seeded_float(seed + ":dur", 8000, 45000))
    num_turns = int(_seeded_float(seed + ":turns", 2, 8))

    haiku_model = "claude-haiku-4-5"
    sonnet_model = "claude-sonnet-5"

    if arm == "baseline":
        total_input = base_input
        total_output = base_output
        model_usage = {
            model: {
                "inputTokens": total_input,
                "outputTokens": total_output,
                "cacheCreationInputTokens": cache_creation,
                "cacheReadInputTokens": cache_read,
                "costUSD": 0.0,  # filled in below from PRICING-equivalent rates
            }
        }
    else:
        # conductor arm: modest total inflation from delegation overhead,
        # then split ~25% main / 60% sonnet / 15% haiku.
        inflation = 1.15
        total_input = int(base_input * inflation)
        total_output = int(base_output * inflation)

        main_in = int(total_input * 0.25)
        sonnet_in = int(total_input * 0.60)
        haiku_in = total_input - main_in - sonnet_in

        main_out = int(total_output * 0.25)
        sonnet_out = int(total_output * 0.60)
        haiku_out = total_output - main_out - sonnet_out

        model_usage = {
            model: {
                "inputTokens": main_in,
                "outputTokens": main_out,
                "cacheCreationInputTokens": int(cache_creation * 0.25),
                "cacheReadInputTokens": int(cache_read * 0.25),
                "costUSD": 0.0,
            },
            sonnet_model: {
                "inputTokens": sonnet_in,
                "outputTokens": sonnet_out,
                "cacheCreationInputTokens": int(cache_creation * 0.60),
                "cacheReadInputTokens": int(cache_read * 0.60),
                "costUSD": 0.0,
            },
            haiku_model: {
                "inputTokens": haiku_in,
                "outputTokens": haiku_out,
                "cacheCreationInputTokens": int(cache_creation * 0.15),
                "cacheReadInputTokens": int(cache_read * 0.15),
                "costUSD": 0.0,
            },
        }
        total_input = main_in + sonnet_in + haiku_in
        total_output = main_out + sonnet_out + haiku_out

    # Fill costUSD per model using the same PRICING rates report.py uses,
    # duplicated here in raw form (not imported) so run.py stays a single
    # file with zero cross-imports; report.py's PRICING is the canonical
    # copy for the report, this is only to populate a plausible mock field.
    mock_pricing = {
        "claude-sonnet-5": (3.0, 15.0),
        "claude-haiku-4-5": (1.0, 5.0),
    }
    total_cost = 0.0
    for m, usage in model_usage.items():
        in_rate, out_rate = mock_pricing.get(m, (3.0, 15.0))
        cost = (usage["inputTokens"] / 1_000_000) * in_rate + (
            usage["outputTokens"] / 1_000_000
        ) * out_rate
        usage["costUSD"] = round(cost, 6)
        total_cost += cost

    # Deterministic pass/fail: mock mode always "passes" the task gate,
    # since there is no real model output to check against the fixtures.
    # report.py records this run as mock so results.md cannot be confused
    # with a real-run success rate.
    result = {
        "total_cost_usd": round(total_cost, 6),
        "duration_ms": duration_ms,
        "num_turns": num_turns,
        "usage": {
            "input_tokens": total_input,
            "output_tokens": total_output,
            "cache_creation_input_tokens": cache_creation,
            "cache_read_input_tokens": cache_read,
        },
        "modelUsage": model_usage,
        "is_mock": True,
        "task_id": task_id,
        "arm": arm,
        "run_n": run_n,
        "model": model,
        "success": True,
        "final_text": f"[mock] synthesized reply for {task_id}/{arm}/run{run_n}",
    }
    return result


# ---------------------------------------------------------------------------
# Real mode: sandbox prep + claude CLI invocation.
# ---------------------------------------------------------------------------


def prepare_conductor_sandbox(sandbox_dir: Path) -> None:
    """Run conductor's install.sh once into a sandbox CLAUDE_DIR.

    install.sh reads CLAUDE_DIR (default $HOME/.claude) as its target and
    CONDUCTOR_YES=1 to run fully non-interactively. The claude CLI itself is
    then pointed at the same directory at invocation time via
    CLAUDE_CONFIG_DIR, which is the env var Claude Code reads to relocate its
    config root. These are two different env vars for two different
    programs (install.sh vs. the claude binary) that must resolve to the
    SAME path for the conductor arm to actually load what was installed.
    """
    sandbox_dir.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["CLAUDE_DIR"] = str(sandbox_dir)
    env["CONDUCTOR_YES"] = "1"
    proc = subprocess.run(
        ["bash", str(INSTALL_SH)],
        cwd=str(CONDUCTOR_ROOT),
        env=env,
        capture_output=True,
        text=True,
        timeout=120,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            "conductor install.sh failed while preparing the sandbox "
            f"(CLAUDE_DIR={sandbox_dir}):\n"
            f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
        )


def run_claude_real(
    task_id: str,
    arm: str,
    model: str,
    sandbox_dir: Path | None,
    timeout_s: int,
) -> dict:
    task_dir = TASKS_DIR / task_id
    prompt = load_prompt(task_id)

    with tempfile.TemporaryDirectory(prefix=f"bench-{task_id}-{arm}-") as tmp:
        work_dir = Path(tmp)
        # Copy task fixtures into an isolated working dir so a run cannot
        # leave stray output files in the checked-in tasks/ tree.
        for item in task_dir.iterdir():
            if item.name in ("meta.json", "prompt.md"):
                continue
            dest = work_dir / item.name
            if item.is_dir():
                shutil.copytree(item, dest)
            else:
                shutil.copy2(item, dest)

        env = os.environ.copy()
        if sandbox_dir is not None:
            env["CLAUDE_CONFIG_DIR"] = str(sandbox_dir)

        cmd = [
            "claude",
            "-p",
            prompt,
            "--model",
            model,
            "--output-format",
            "json",
        ]
        started = time.time()
        proc = subprocess.run(
            cmd,
            cwd=str(work_dir),
            env=env,
            capture_output=True,
            text=True,
            timeout=timeout_s,
        )
        elapsed = time.time() - started

        if proc.returncode != 0:
            return {
                "task_id": task_id,
                "arm": arm,
                "model": model,
                "success": False,
                "error": f"claude exited {proc.returncode}",
                "stderr": proc.stderr[-4000:],
                "wall_time_s": elapsed,
                "is_mock": False,
            }

        try:
            result = json.loads(proc.stdout)
        except json.JSONDecodeError as e:
            return {
                "task_id": task_id,
                "arm": arm,
                "model": model,
                "success": False,
                "error": f"could not parse claude JSON output: {e}",
                "stdout_tail": proc.stdout[-4000:],
                "wall_time_s": elapsed,
                "is_mock": False,
            }

        # Run the task's success_cmd against the working directory. Tasks
        # whose meta.json sets needs_reply_file: true (the research/
        # summarize tasks, t5/t6) have a success_cmd expecting the captured
        # final text as $1; write it to a temp file first. Driven by
        # metadata, not a hardcoded task-id prefix, so adding a new
        # research-style task later only requires setting the flag in its
        # own meta.json.
        meta = load_meta(task_id)
        success_cmd = meta["success_cmd"]
        final_text = result.get("result", result.get("final_text", ""))

        check_cmd = success_cmd
        reply_path = None
        if meta.get("needs_reply_file"):
            reply_fd, reply_path = tempfile.mkstemp(prefix="bench-reply-")
            with os.fdopen(reply_fd, "w") as rf:
                rf.write(final_text)
            check_cmd = f"{success_cmd} {reply_path}"

        try:
            check_proc = subprocess.run(
                check_cmd,
                shell=True,
                cwd=str(work_dir),
                capture_output=True,
                text=True,
                timeout=30,
            )
            task_success = check_proc.returncode == 0
            check_output = (check_proc.stdout + check_proc.stderr)[-2000:]
        finally:
            if reply_path and os.path.exists(reply_path):
                os.remove(reply_path)

        result["task_id"] = task_id
        result["arm"] = arm
        result["model"] = model
        result["success"] = task_success
        result["check_output"] = check_output
        result["wall_time_s"] = elapsed
        result["is_mock"] = False
        return result


def run_one(
    task_id: str,
    arm: str,
    run_n: int,
    model: str,
    mock: bool,
    sandbox_dir: Path | None,
    timeout_s: int,
) -> dict:
    if mock:
        return synth_mock_result(task_id, arm, run_n, model)
    return run_claude_real(task_id, arm, model, sandbox_dir, timeout_s)


def main() -> int:
    mock = os.environ.get("BENCH_MOCK", "0") == "1"
    runs = int(os.environ.get("RUNS", "2"))
    timeout_s = int(os.environ.get("BENCH_TASK_TIMEOUT_S", "300"))

    baseline_model = os.environ.get("BENCH_BASELINE_MODEL")
    if not mock and not baseline_model:
        print(
            "FATAL: BENCH_BASELINE_MODEL is required for real runs. "
            "A bare `claude -p` without --model inherits settings.json's "
            "configured model, which would make the baseline arm "
            "unreproducible. Set BENCH_BASELINE_MODEL=<model-id> and rerun.",
            file=sys.stderr,
        )
        return 2
    if mock and not baseline_model:
        baseline_model = "claude-sonnet-5"  # placeholder label for mock rows

    conductor_model = os.environ.get("BENCH_CONDUCTOR_MODEL", baseline_model)

    tasks = discover_tasks()
    if not tasks:
        print(f"FATAL: no tasks found under {TASKS_DIR}", file=sys.stderr)
        return 2

    keep_raw = os.environ.get("BENCH_KEEP_RAW", "0") == "1"
    if RAW_DIR.exists() and not keep_raw:
        stale = list(RAW_DIR.glob("*.json"))
        if stale:
            print(
                f"[run.py] clearing {len(stale)} stale result file(s) from "
                f"{RAW_DIR} (set BENCH_KEEP_RAW=1 to accumulate instead of "
                "clearing; a mix of mock and real runs in the same raw/ dir "
                "produces a results.md that mixes both without warning)"
            )
            for f in stale:
                f.unlink()
    RAW_DIR.mkdir(parents=True, exist_ok=True)

    sandbox_dir: Path | None = None
    if not mock:
        sandbox_dir = Path(tempfile.mkdtemp(prefix="conductor-bench-sandbox-"))
        print(f"[run.py] preparing conductor sandbox at {sandbox_dir}")
        prepare_conductor_sandbox(sandbox_dir)

    print(
        f"[run.py] mode={'MOCK' if mock else 'REAL'} tasks={len(tasks)} "
        f"arms={len(ARMS)} runs={runs} "
        f"baseline_model={baseline_model} conductor_model={conductor_model}"
    )

    total = len(tasks) * len(ARMS) * runs
    done = 0

    for task_id in tasks:
        for arm in ARMS:
            model = baseline_model if arm == "baseline" else conductor_model
            arm_sandbox = sandbox_dir if arm == "conductor" else None
            for run_n in range(1, runs + 1):
                result = run_one(
                    task_id, arm, run_n, model, mock, arm_sandbox, timeout_s
                )
                out_path = RAW_DIR / f"{task_id}-{arm}-{run_n}.json"
                with open(out_path, "w") as f:
                    json.dump(result, f, indent=2)
                done += 1
                status = "ok" if result.get("success") else "FAIL"
                print(
                    f"[run.py] ({done}/{total}) {task_id} {arm} run{run_n} "
                    f"-> {status} -> {out_path}"
                )

    if sandbox_dir is not None:
        shutil.rmtree(sandbox_dir, ignore_errors=True)

    print(f"[run.py] done. {done} result files written to {RAW_DIR}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
