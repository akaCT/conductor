#!/usr/bin/env python3
"""Conductor bench: figures, run record and rendered page.

This module holds everything that turns raw run streams into numbers:

  parse_stream      1 stream-json run -> tool call counts, result, outcome
  usage_figures     tokens by model class and dollars from the result's modelUsage
  wilson, compare_arms
                    pass-rate intervals and the overlap rule (REQ-EVAL-001.4)
  build_record      the run record (REQ-EVAL-001.1)
  render_md         the page that goes with the record

run.py calls build_record and render_md at the end of a run. Run on its own,

  python3 src/report.py [path/to/RUN-<id>.json]

re-renders the page of the newest (or the named) record. rederive.py, the
second seat, does not import this file: it recomputes the same figures with its
own code and compares.

Stdlib only.
"""
from __future__ import annotations

import hashlib
import json
import math
import os
import re
import sys
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parent.parent
TASKS_DIR = BENCH_DIR / "tasks"
PRICES_PATH = BENCH_DIR / "prices.json"

SCHEMA = "conductor-bench-run/1"
# The version of the bench itself (runner, scoring and task protocol). Raise it
# when a change could move a figure; every run record carries it.
BENCH_VERSION = "1"
ARMS = ("a", "b", "c")
ARM_TEXT = {
    "a": "without Conductor",
    "b": "with Conductor at default effort (effort pins declined)",
    "c": "with Conductor and the effort pins",
}
DISPATCH_TOOLS = ("Agent", "Task")
CLASSES = ("opus", "sonnet", "haiku", "fable", "other")
TOKEN_KEYS = ("input", "output", "cache_read", "cache_write")
OUTCOMES = ("passed", "failed", "error")
Z95 = 1.959964
FULL_TASKS = 20
FULL_RUNS = 3
UNIT = (
    "1 bench task run to its end, in US dollars at the dated list prices of "
    "the price table in this record"
)


def task_key(task_id: str):
    """t2 before t10: order task ids by their number."""
    m = re.match(r"t(\d+)", task_id)
    return (int(m.group(1)) if m else 10**9, task_id)


def results_dir() -> Path:
    return Path(os.environ.get("BENCH_RESULTS_DIR") or (BENCH_DIR / "results"))


# ---------------------------------------------------------------------------
# Tasks: the frozen set and a hash of each task folder.
# ---------------------------------------------------------------------------


def hash_task_dir(path: Path) -> str:
    """sha256 over every file in the folder: relative path and content hash,
    sorted by path. Editor and Python cache files are left out."""
    h = hashlib.sha256()
    files = []
    for root, dirs, names in os.walk(path):
        dirs[:] = [d for d in dirs if d != "__pycache__"]
        for n in names:
            if n == ".DS_Store" or n.endswith(".pyc"):
                continue
            full = Path(root) / n
            files.append((full.relative_to(path).as_posix(), full))
    for rel, full in sorted(files):
        h.update(rel.encode("utf-8") + b"\0")
        h.update(hashlib.sha256(full.read_bytes()).hexdigest().encode("ascii") + b"\n")
    return h.hexdigest()


def describe_tasks(task_ids) -> list:
    out = []
    for tid in sorted(task_ids, key=task_key):
        meta = json.loads((TASKS_DIR / tid / "meta.json").read_text())
        out.append(
            {
                "id": tid,
                "category": meta.get("category", ""),
                "hash": hash_task_dir(TASKS_DIR / tid),
            }
        )
    return out


def task_set_hash(task_set: list) -> str:
    h = hashlib.sha256()
    for t in sorted(task_set, key=lambda t: t["id"]):
        h.update((t["id"] + ":" + t["hash"] + "\n").encode("utf-8"))
    return h.hexdigest()


# ---------------------------------------------------------------------------
# Streams: delegation counts, result, outcome.
# ---------------------------------------------------------------------------


def parse_stream(lines) -> dict:
    """Read the lines of 1 stream-json run.

    A tool call is a tool_use block in an assistant event. It is top level when
    the event has no parent_tool_use_id and nested when it has a parent_tool_use_id (a subagent
    made it). Only top level calls count. A block seen twice (the same id)
    counts once. A dispatch is a top level call to Agent or Task."""
    top = {}
    nested = set()
    anon = 0
    result = None
    outcome = None
    init = None
    for raw in lines:
        raw = raw.strip()
        if not raw:
            continue
        try:
            ev = json.loads(raw)
        except ValueError:
            continue
        if not isinstance(ev, dict):
            continue
        kind = ev.get("type")
        if kind == "assistant":
            content = (ev.get("message") or {}).get("content")
            if not isinstance(content, list):
                continue
            parent = ev.get("parent_tool_use_id")
            for block in content:
                if not isinstance(block, dict) or block.get("type") != "tool_use":
                    continue
                tid = block.get("id")
                if not tid:
                    anon += 1
                    tid = "anon-%d" % anon
                if parent:
                    nested.add(tid)
                elif tid not in top:
                    top[tid] = block.get("name")
        elif kind == "result":
            result = ev
        elif kind == "bench_outcome":
            outcome = ev
        elif kind == "system" and ev.get("subtype") == "init":
            init = ev
    return {
        "tool_calls": len(top),
        "dispatches": sum(1 for n in top.values() if n in DISPATCH_TOOLS),
        "nested_tool_calls": len(nested),
        "result": result,
        "outcome": outcome,
        "init": init,
    }


# ---------------------------------------------------------------------------
# Tokens and dollars.
# ---------------------------------------------------------------------------


def load_prices(path: Path = PRICES_PATH) -> dict:
    return json.loads(Path(path).read_text())


def model_class(model_id: str) -> str:
    m = model_id.lower()
    for cls in ("haiku", "sonnet", "opus", "fable"):
        if cls in m:
            return cls
    return "other"


def price_row(price_table: dict, model_id: str):
    mid = re.sub(r"\[.*\]$", "", model_id.strip())
    for row in price_table["rows"]:
        if mid == row["id"] or re.fullmatch(re.escape(row["id"]) + r"-\d{8}", mid):
            return row
    return None


def empty_tokens() -> dict:
    return {c: {k: 0 for k in TOKEN_KEYS} for c in CLASSES}


def add_tokens(into: dict, other: dict) -> None:
    for c in CLASSES:
        for k in TOKEN_KEYS:
            into[c][k] += other[c][k]


def _int(x) -> int:
    try:
        return int(x or 0)
    except (TypeError, ValueError):
        return 0


def usage_figures(result, price_table: dict) -> dict:
    """Tokens by model class and dollars from a result event's modelUsage.
    modelUsage is a map from model id to that model's token counts, so a
    subagent that ran on a cheaper model is counted under its own class."""
    tokens = empty_tokens()
    cost = 0.0
    unpriced = []
    model_usage = (result or {}).get("modelUsage")
    if not isinstance(model_usage, dict) or not model_usage:
        reported = float((result or {}).get("total_cost_usd") or 0.0)
        return {
            "tokens": tokens,
            "cost_usd": 0.0,
            "reported_cost_usd": round(reported, 6),
            "usage_missing": True,
            "unpriced_models": [],
        }
    reported_sum = 0.0
    for mid in sorted(model_usage):
        u = model_usage[mid] or {}
        counts = {
            "input": _int(u.get("inputTokens")),
            "output": _int(u.get("outputTokens")),
            "cache_read": _int(u.get("cacheReadInputTokens")),
            "cache_write": _int(u.get("cacheCreationInputTokens")),
        }
        cls = model_class(mid)
        for k in TOKEN_KEYS:
            tokens[cls][k] += counts[k]
        try:
            reported_sum += float(u.get("costUSD") or 0.0)
        except (TypeError, ValueError):
            pass
        row = price_row(price_table, mid)
        if row is None:
            unpriced.append(mid)
            continue
        cost += sum(counts[k] * float(row[k]) for k in TOKEN_KEYS) / 1_000_000
    reported = (result or {}).get("total_cost_usd")
    reported = float(reported) if reported is not None else reported_sum
    return {
        "tokens": tokens,
        "cost_usd": round(cost, 6),
        "reported_cost_usd": round(reported, 6),
        "usage_missing": False,
        "unpriced_models": unpriced,
    }


def run_figures(parsed: dict, price_table: dict) -> dict:
    outcome = (parsed["outcome"] or {}).get("outcome")
    if outcome not in OUTCOMES:
        outcome = "error"
    fig = usage_figures(parsed["result"], price_table)
    session = (parsed["result"] or {}).get("session_id") or (parsed["init"] or {}).get(
        "session_id"
    )
    return {
        "outcome": outcome,
        "tool_calls": parsed["tool_calls"],
        "dispatches": parsed["dispatches"],
        "nested_tool_calls": parsed["nested_tool_calls"],
        "tokens": fig["tokens"],
        "cost_usd": fig["cost_usd"],
        "reported_cost_usd": fig["reported_cost_usd"],
        "usage_missing": fig["usage_missing"],
        "unpriced_models": fig["unpriced_models"],
        "session_id": session,
    }


# ---------------------------------------------------------------------------
# Statistics: Wilson interval and the overlap rule.
# ---------------------------------------------------------------------------


def wilson(x: int, n: int, z: float = Z95):
    """Wilson score interval for x passes in n runs, rounded to 4 places."""
    if n <= 0:
        return None
    p = x / n
    z2 = z * z
    denom = 1 + z2 / n
    centre = (p + z2 / (2 * n)) / denom
    half = z * math.sqrt(p * (1 - p) / n + z2 / (4 * n * n)) / denom
    return (round(max(0.0, centre - half), 4), round(min(1.0, centre + half), 4))


def compare_arms(arm1: str, x1: int, n1: int, arm2: str, x2: int, n2: int) -> dict:
    """The only sentence the record may say about 2 arms' pass rates. Where the
    95 percent intervals overlap it says so and calls nothing real."""
    pair = "%s vs %s" % (arm1, arm2)
    if n1 <= 0 or n2 <= 0:
        return {
            "pair": pair,
            "overlap": None,
            "verdict": "%s: not compared (an arm has no runs)" % pair,
        }
    lo1, hi1 = wilson(x1, n1)
    lo2, hi2 = wilson(x2, n2)
    overlap = not (hi1 < lo2 or hi2 < lo1)
    if overlap:
        verdict = "%s: not distinguishable at n=%d and n=%d (the 95 percent intervals overlap)" % (
            pair,
            n1,
            n2,
        )
    else:
        higher = arm1 if x1 / n1 > x2 / n2 else arm2
        verdict = (
            "%s: the pass rates differ and arm %s is higher "
            "(the 95 percent intervals do not overlap, n=%d and n=%d)" % (pair, higher, n1, n2)
        )
    return {"pair": pair, "overlap": overlap, "verdict": verdict}


# ---------------------------------------------------------------------------
# Figures and the record.
# ---------------------------------------------------------------------------


def run_key(task_id: str, arm: str, n: int) -> str:
    return "%s|%s|%d" % (task_id, arm, n)


def _bucket() -> dict:
    return {
        "runs": 0,
        "passed": 0,
        "failed": 0,
        "errors": 0,
        "tool_calls": 0,
        "dispatches": 0,
        "tokens": empty_tokens(),
        "cost_usd": 0.0,
        "reported_cost_usd": 0.0,
        "unpriced_models": [],
    }


def _add_run(b: dict, r: dict) -> None:
    b["runs"] += 1
    if r["outcome"] == "passed":
        b["passed"] += 1
    elif r["outcome"] == "failed":
        b["failed"] += 1
    else:
        b["errors"] += 1
    b["tool_calls"] += r["tool_calls"]
    b["dispatches"] += r["dispatches"]
    add_tokens(b["tokens"], r["tokens"])
    b["cost_usd"] += r["cost_usd"]
    b["reported_cost_usd"] += r["reported_cost_usd"]
    for m in r["unpriced_models"]:
        if m not in b["unpriced_models"]:
            b["unpriced_models"].append(m)


def _finish(b: dict, per_arm: bool) -> dict:
    b["cost_usd"] = round(b["cost_usd"], 6)
    b["reported_cost_usd"] = round(b["reported_cost_usd"], 6)
    b["unpriced_models"] = sorted(b["unpriced_models"])
    b["delegation_rate"] = (
        round(b["dispatches"] / b["tool_calls"], 4) if b["tool_calls"] else None
    )
    if per_arm:
        n = b["runs"]
        b["pass_rate"] = round(b["passed"] / n, 4) if n else None
        iv = wilson(b["passed"], n)
        b["wilson95"] = list(iv) if iv else None
        b["cost_per_run_usd"] = round(b["cost_usd"] / n, 6) if n else None
        b["cost_per_passed_run_usd"] = (
            round(b["cost_usd"] / b["passed"], 6) if b["passed"] else None
        )
    return b


def compute_figures(runs: dict) -> dict:
    """runs maps a run key (task|arm|n) to run_figures(); returns the part of
    the record that rederive.py recomputes."""
    per_task = {}
    per_arm = {a: _bucket() for a in ARMS}
    for key in sorted(runs):
        task_id, arm, _n = key.rsplit("|", 2)
        r = runs[key]
        _add_run(per_arm.setdefault(arm, _bucket()), r)
        _add_run(per_task.setdefault(task_id, {}).setdefault(arm, _bucket()), r)
    for tid in per_task:
        for arm in per_task[tid]:
            _finish(per_task[tid][arm], False)
    for arm in per_arm:
        _finish(per_arm[arm], True)
    comparisons = []
    for i, a1 in enumerate(ARMS):
        for a2 in ARMS[i + 1 :]:
            comparisons.append(
                compare_arms(
                    a1,
                    per_arm[a1]["passed"],
                    per_arm[a1]["runs"],
                    a2,
                    per_arm[a2]["passed"],
                    per_arm[a2]["runs"],
                )
            )
    return {
        "raw_files": len(runs),
        "runs": runs,
        "per_task": per_task,
        "per_arm": per_arm,
        "comparisons": comparisons,
    }


def labels_for(mock: bool, smoke: bool, invalid: bool = False) -> list:
    out = []
    if invalid:
        out.append("INVALID RUN")
    if mock:
        out.append("MOCK DATA")
    if smoke:
        out.append("SMOKE RUN: not scored")
    return out


def load_raw_runs(raw_dir: Path, price_table: dict) -> tuple:
    """Read every .jsonl under raw_dir. Returns (runs, mock) where runs maps a
    run key to run_figures() and mock is True when any run was synthesized."""
    runs = {}
    mock = False
    for path in sorted(Path(raw_dir).glob("*.jsonl")):
        with open(path) as f:
            parsed = parse_stream(f)
        oc = parsed["outcome"]
        if not oc:
            continue
        key = run_key(oc["task_id"], oc["arm"], int(oc["run"]))
        runs[key] = run_figures(parsed, price_table)
        if oc.get("mock"):
            mock = True
    return runs, mock


def build_record(
    *,
    run_id: str,
    created_utc: str,
    model: str,
    raw_dir: Path,
    task_set: list,
    not_run: list,
    price_table: dict,
    environment: dict,
    restore_check: dict,
    invalid_reasons: list = None,
) -> dict:
    runs, mock = load_raw_runs(raw_dir, price_table)
    # A run is invalid when an uninstall failed or the restore check failed: the
    # folder is not what it was, so the figures are not evidence.
    reasons = list(invalid_reasons or [])
    if restore_check.get("checked") and not restore_check.get("ok"):
        reasons.append("restore check failed: " + restore_check.get("detail", ""))
    valid = not reasons
    task_ids = sorted({k.split("|")[0] for k in runs})
    run_numbers = [int(k.rsplit("|", 1)[1]) for k in runs]
    runs_per_task = max(run_numbers) if run_numbers else 0
    arms_seen = sorted({k.split("|")[1] for k in runs})
    smoke = len(task_ids) < FULL_TASKS or runs_per_task < FULL_RUNS
    labels = labels_for(mock, smoke, not valid)
    figures = compute_figures(runs)
    return {
        "labels": labels,
        "schema": SCHEMA,
        "run_id": run_id,
        "created_utc": created_utc,
        "mode": "mock" if mock else "real",
        "smoke": smoke,
        "valid": valid,
        "invalid_reasons": reasons,
        "scored": (not mock) and (not smoke) and valid,
        "model": model,
        "unit": UNIT,
        "n": {
            "tasks": len(task_ids),
            "runs_per_task": runs_per_task,
            "arms": len(arms_seen),
            "runs_total": len(runs),
        },
        "arms": {a: ARM_TEXT[a] for a in ARMS},
        "task_set": task_set,
        "task_set_hash": task_set_hash(task_set),
        "not_run": not_run,
        "price_table": price_table,
        "environment": environment,
        "restore_check": restore_check,
        "figures": figures,
    }


# ---------------------------------------------------------------------------
# The page.
# ---------------------------------------------------------------------------


def _pct(x) -> str:
    return "n/a" if x is None else "%.1f%%" % (100 * x)


def _usd(x) -> str:
    return "n/a" if x is None else "$%.4f" % x


def _tok(n: int) -> str:
    return "{:,}".format(n)


def _rate(b: dict) -> str:
    if not b["tool_calls"]:
        return "%d / %d (n/a)" % (b["dispatches"], b["tool_calls"])
    return "%d / %d (%s)" % (b["dispatches"], b["tool_calls"], _pct(b["delegation_rate"]))


def render_md(rec: dict) -> str:
    fig = rec["figures"]
    L = []
    for label in rec["labels"]:
        L.append(label)
    if rec.get("valid") is False:
        L.append(
            "Not evidence: this run is invalid (%s). The folder was not left as it was "
            "found, so no figure here supports a claim." % "; ".join(rec.get("invalid_reasons", []))
        )
    if rec["mode"] == "mock":
        L.append(
            "Not evidence: these figures were synthesized by run.py with "
            "BENCH_MOCK=1. No claude run happened. They prove the pipeline "
            "renders and are cited nowhere."
        )
    if rec["smoke"]:
        L.append(
            "A smoke run has fewer than %d tasks or fewer than %d runs per "
            "task. It checks the pipeline, never feeds the 1.0.0 gate and "
            "supports no claim." % (FULL_TASKS, FULL_RUNS)
        )
    if rec["labels"]:
        L.append("")
    L.append("# Conductor bench run %s" % rec["run_id"])
    L.append("")
    L.append("- Date (UTC): %s" % rec["created_utc"])
    L.append("- Mode: %s" % rec["mode"])
    L.append("- Model on every arm: %s" % rec["model"])
    n = rec["n"]
    L.append(
        "- n: %d tasks x %d runs x %d arms = %d runs to their end"
        % (n["tasks"], n["runs_per_task"], n["arms"], n["runs_total"])
    )
    L.append("- Scored: %s" % ("yes" if rec["scored"] else "no"))
    L.append("- Unit: %s" % rec["unit"])
    L.append("- Task set hash: %s" % rec["task_set_hash"])
    L.append("")
    L.append("## Arms")
    L.append("")
    for a in ARMS:
        L.append("- %s: %s" % (a, rec["arms"][a]))
    L.append("")
    L.append("## Results by arm")
    L.append("")
    L.append(
        "| arm | runs | passed | failed | errors | pass rate | 95% interval | "
        "dispatches / tool calls | cost total | cost per run | cost per passed run |"
    )
    L.append("|---|---|---|---|---|---|---|---|---|---|---|")
    for a in ARMS:
        b = fig["per_arm"][a]
        iv = b["wilson95"]
        ivs = "n/a" if not iv else "%.1f%% to %.1f%%" % (100 * iv[0], 100 * iv[1])
        L.append(
            "| %s | %d | %d | %d | %d | %s | %s | %s | %s | %s | %s |"
            % (
                a,
                b["runs"],
                b["passed"],
                b["failed"],
                b["errors"],
                _pct(b["pass_rate"]),
                ivs,
                _rate(b),
                _usd(b["cost_usd"]),
                _usd(b["cost_per_run_usd"]),
                _usd(b["cost_per_passed_run_usd"]),
            )
        )
    L.append("")
    L.append(
        "A run that died before its check (a crash, a timeout or a limit) is an "
        "error and counts as not passed. Delegation rate is dispatch tool calls "
        "(Agent or Task) over all tool calls in the top level conversation; "
        "calls made inside a subagent are not counted."
    )
    L.append("")
    L.append("## Differences between arms")
    L.append("")
    for c in fig["comparisons"]:
        L.append("- " + c["verdict"])
    L.append("")
    L.append(
        "Pass rates are compared by their 95 percent Wilson intervals, treating "
        "each run as an independent trial. No difference is called real where "
        "the intervals overlap. Delegation rate and cost are reported as counts "
        "and dollars only; no difference in them is claimed."
    )
    L.append("")
    L.append("## Tokens by model class (input / output / cache read / cache write)")
    L.append("")
    L.append("| arm | " + " | ".join(CLASSES) + " |")
    L.append("|---|" + "---|" * len(CLASSES))
    for a in ARMS:
        cells = []
        for c in CLASSES:
            t = fig["per_arm"][a]["tokens"][c]
            cells.append(
                "%s / %s / %s / %s"
                % (_tok(t["input"]), _tok(t["output"]), _tok(t["cache_read"]), _tok(t["cache_write"]))
            )
        L.append("| %s | %s |" % (a, " | ".join(cells)))
    L.append("")
    unpriced = sorted({m for a in ARMS for m in fig["per_arm"][a]["unpriced_models"]})
    if unpriced:
        L.append(
            "Unpriced models (tokens counted, dollars left out, so the dollar "
            "figures are lower bounds): " + ", ".join(unpriced)
        )
        L.append("")
    missing = sum(1 for r in fig["runs"].values() if r["usage_missing"])
    if missing:
        L.append(
            "%d run(s) ended without a usage record; their tokens and dollars "
            "are counted as 0." % missing
        )
        L.append("")
    L.append("## Per task (pass / dispatches over tool calls / dollars per run)")
    L.append("")
    L.append("| task | category | a | b | c |")
    L.append("|---|---|---|---|---|")
    cats = {t["id"]: t["category"] for t in rec["task_set"]}
    for tid in sorted(fig["per_task"], key=task_key):
        cells = []
        for a in ARMS:
            b = fig["per_task"][tid].get(a)
            if not b:
                cells.append("-")
                continue
            per_run = b["cost_usd"] / b["runs"] if b["runs"] else None
            cells.append(
                "%d/%d; %d/%d; %s"
                % (b["passed"], b["runs"], b["dispatches"], b["tool_calls"], _usd(per_run))
            )
        L.append("| %s | %s | %s |" % (tid, cats.get(tid, ""), " | ".join(cells)))
    L.append("")
    L.append("## Task set (frozen: a changed task changes its hash)")
    L.append("")
    L.append("| task | category | hash (first 16) |")
    L.append("|---|---|---|")
    for t in rec["task_set"]:
        L.append("| %s | %s | %s |" % (t["id"], t["category"], t["hash"][:16]))
    L.append("")
    if rec["not_run"]:
        L.append("Not run:")
        L.append("")
        for x in rec["not_run"]:
            L.append("- %s: %s" % (x["task_id"], x["reason"]))
        L.append("")
    pt = rec["price_table"]
    L.append("## Price table")
    L.append("")
    L.append("- Source: %s" % pt["source"])
    L.append("- Read on: %s" % pt["read_on"])
    L.append("- Unit: %s" % pt["unit"])
    L.append("")
    L.append("| model id | class | input | output | cache write | cache read |")
    L.append("|---|---|---|---|---|---|")
    for r in pt["rows"]:
        L.append(
            "| %s | %s | %s | %s | %s | %s |"
            % (r["id"], r["class"], r["input"], r["output"], r["cache_write"], r["cache_read"])
        )
    L.append("")
    for note in pt["notes"]:
        L.append("- " + note)
    L.append("")
    L.append("## Run ids")
    L.append("")
    L.append(
        "Bench run id: %s. The %d per-run ids (session ids) and every figure "
        "above are in the JSON record; the raw streams are under raw/%s/."
        % (rec["run_id"], rec["n"]["runs_total"], rec["run_id"])
    )
    L.append("")
    env = rec["environment"]
    L.append("## Environment and restore check")
    L.append("")
    for k in sorted(env):
        L.append("- %s: %s" % (k, env[k]))
    rc = rec["restore_check"]
    if rc.get("checked"):
        L.append(
            "- restore check (settings.json and CLAUDE.md back byte for byte, no Conductor install left): %s%s"
            % ("PASS" if rc["ok"] else "FAIL", "" if rc["ok"] else " - " + rc.get("detail", ""))
        )
    else:
        L.append("- restore check: not applicable (%s)" % rc.get("detail", "no install was made"))
    L.append("")
    return "\n".join(L) + "\n"


def write_record(rec: dict, out_dir: Path) -> tuple:
    out_dir.mkdir(parents=True, exist_ok=True)
    jpath = out_dir / ("RUN-%s.json" % rec["run_id"])
    mpath = out_dir / ("RUN-%s.md" % rec["run_id"])
    with open(jpath, "w") as f:
        json.dump(rec, f, indent=2)
        f.write("\n")
    with open(mpath, "w") as f:
        f.write(render_md(rec))
    return jpath, mpath


def main() -> int:
    if len(sys.argv) > 1:
        jpath = Path(sys.argv[1])
    else:
        found = sorted(results_dir().glob("RUN-*.json"), key=lambda p: p.stat().st_mtime)
        if not found:
            print("[report.py] no RUN-*.json in %s; run src/run.py first" % results_dir())
            return 1
        jpath = found[-1]
    rec = json.loads(jpath.read_text())
    mpath = jpath.with_suffix(".md")
    mpath.write_text(render_md(rec))
    print("[report.py] wrote %s from %s" % (mpath, jpath))
    return 0


if __name__ == "__main__":
    sys.exit(main())
