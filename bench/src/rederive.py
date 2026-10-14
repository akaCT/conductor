#!/usr/bin/env python3
"""Second seat for a bench run record (REQ-EVAL-001.3).

  python3 src/rederive.py results/RUN-<run id>.json

Recomputes every figure of the record from the raw streams under
results/raw/<run id>/ and compares. Prints AGREE (exit 0), or a list of the
differences (exit 1). It also hashes the task folders again, so a task edited
after the run shows up as a difference.

This file shares no code with run.py or report.py on purpose: a second
implementation that reads the same streams is what makes agreement mean
something. Its inputs are the record (for the price table, the task list and
the claimed figures) and the raw streams. Per-run dollar figures are rounded to
6 decimals before they are summed, as in the record.

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

HERE = Path(__file__).resolve().parent
TASKS = Path(os.environ.get("BENCH_TASKS_DIR") or (HERE.parent / "tasks"))
CLASSES = ("opus", "sonnet", "haiku", "fable", "other")
TOKENS = ("input", "output", "cache_read", "cache_write")
USAGE_FIELDS = {
    "input": "inputTokens",
    "output": "outputTokens",
    "cache_read": "cacheReadInputTokens",
    "cache_write": "cacheCreationInputTokens",
}


def read_stream(path):
    """-> (top level tool_use {id: name}, nested ids, result event, outcome event,
    session id of the init event)"""
    top, nested, result, outcome, init_sid = {}, set(), None, None, None
    n_anon = 0
    for line in path.read_text().splitlines():
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if not isinstance(ev, dict):
            continue
        t = ev.get("type")
        if t == "result":
            result = ev
        elif t == "bench_outcome":
            outcome = ev
        elif t == "system" and ev.get("subtype") == "init":
            init_sid = ev.get("session_id")
        elif t == "assistant":
            blocks = (ev.get("message") or {}).get("content")
            for blk in blocks if isinstance(blocks, list) else []:
                if not (isinstance(blk, dict) and blk.get("type") == "tool_use"):
                    continue
                n_anon += 1
                tid = blk.get("id") or "anon-%d" % n_anon
                if ev.get("parent_tool_use_id"):
                    nested.add(tid)
                else:
                    top.setdefault(tid, blk.get("name"))
    return top, nested, result, outcome, init_sid


def family(model_id):
    low = model_id.lower()
    for fam in ("haiku", "sonnet", "opus", "fable"):
        if fam in low:
            return fam
    return "other"


def find_price(rows, model_id):
    mid = re.sub(r"\[[^\]]*\]$", "", model_id.strip())
    for row in rows:
        if mid == row["id"]:
            return row
        if mid.startswith(row["id"] + "-") and re.fullmatch(r"\d{8}", mid[len(row["id"]) + 1 :]):
            return row
    return None


def zero_tokens():
    return dict((c, dict((k, 0) for k in TOKENS)) for c in CLASSES)


def num(x):
    try:
        return int(x or 0)
    except (TypeError, ValueError):
        return 0


def one_run(path, rows):
    top, nested, result, outcome, init_sid = read_stream(path)
    tokens = zero_tokens()
    cost = 0.0
    unpriced = []
    usage = (result or {}).get("modelUsage")
    missing = not (isinstance(usage, dict) and usage)
    reported = 0.0
    if not missing:
        listed = 0.0
        for mid in sorted(usage):
            u = usage[mid] or {}
            fam = family(mid)
            amounts = dict((k, num(u.get(USAGE_FIELDS[k]))) for k in TOKENS)
            for k in TOKENS:
                tokens[fam][k] += amounts[k]
            try:
                listed += float(u.get("costUSD") or 0.0)
            except (TypeError, ValueError):
                pass
            row = find_price(rows, mid)
            if row is None:
                unpriced.append(mid)
            else:
                cost += sum(amounts[k] * row[k] for k in TOKENS) / 1e6
        reported = float(result["total_cost_usd"]) if result.get("total_cost_usd") is not None else listed
    elif result is not None and result.get("total_cost_usd") is not None:
        reported = float(result["total_cost_usd"])
    oc = (outcome or {}).get("outcome")
    return {
        "outcome": oc if oc in ("passed", "failed", "error") else "error",
        "tool_calls": len(top),
        "dispatches": len([n for n in top.values() if n in ("Agent", "Task")]),
        "nested_tool_calls": len(nested),
        "tokens": tokens,
        "cost_usd": round(cost, 6),
        "reported_cost_usd": round(reported, 6),
        "usage_missing": missing,
        "unpriced_models": sorted(unpriced),
        "session_id": (result or {}).get("session_id") or init_sid,
    }


def tally(run_list):
    """Aggregate a list of per-run figures."""
    out = {
        "runs": len(run_list),
        "passed": sum(1 for r in run_list if r["outcome"] == "passed"),
        "failed": sum(1 for r in run_list if r["outcome"] == "failed"),
        "errors": sum(1 for r in run_list if r["outcome"] == "error"),
        "tool_calls": sum(r["tool_calls"] for r in run_list),
        "dispatches": sum(r["dispatches"] for r in run_list),
        "tokens": zero_tokens(),
        "cost_usd": round(sum(r["cost_usd"] for r in run_list), 6),
        "reported_cost_usd": round(sum(r["reported_cost_usd"] for r in run_list), 6),
        "unpriced_models": sorted(set(m for r in run_list for m in r["unpriced_models"])),
    }
    for r in run_list:
        for c in CLASSES:
            for k in TOKENS:
                out["tokens"][c][k] += r["tokens"][c][k]
    out["delegation_rate"] = round(out["dispatches"] / out["tool_calls"], 4) if out["tool_calls"] else None
    return out


def wilson_bounds(k, n):
    """Closed form of the Wilson score interval at 95 percent."""
    if n <= 0:
        return None
    z = 1.959964
    p = k / n
    root = z * math.sqrt(z * z + 4 * n * p * (1 - p))
    lo = (2 * n * p + z * z - root) / (2 * (n + z * z))
    hi = (2 * n * p + z * z + root) / (2 * (n + z * z))
    return [round(max(0.0, lo), 4), round(min(1.0, hi), 4)]


def task_folder_hash(folder):
    parts = []
    for p in folder.rglob("*"):
        if not p.is_file() or p.name == ".DS_Store" or p.suffix == ".pyc" or "__pycache__" in p.parts:
            continue
        parts.append((p.relative_to(folder).as_posix(), hashlib.sha256(p.read_bytes()).hexdigest()))
    parts.sort()
    return hashlib.sha256(b"".join(a.encode() + b"\0" + b.encode() + b"\n" for a, b in parts)).hexdigest()


def tolerance(path):
    last = re.sub(r"\[\d+\]$", "", path.rsplit(".", 1)[-1])
    if "cost" in last:
        return 2e-6
    if last in ("pass_rate", "delegation_rate", "wilson95"):
        return 1.5e-4
    return 1e-9


def compare(path, claimed, mine, out):
    if isinstance(mine, dict) and isinstance(claimed, dict):
        for key in sorted(set(mine) | set(claimed)):
            sub = path + "." + str(key) if path else str(key)
            if key not in claimed:
                out.append("%s: missing in the record (rederived %r)" % (sub, mine[key]))
            elif key not in mine:
                out.append("%s: in the record but not in the raw streams (record %r)" % (sub, claimed[key]))
            else:
                compare(sub, claimed[key], mine[key], out)
    elif isinstance(mine, list) and isinstance(claimed, list):
        if len(mine) != len(claimed):
            out.append("%s: record has %d items, rederived %d" % (path, len(claimed), len(mine)))
        else:
            for i, (c, m) in enumerate(zip(claimed, mine)):
                compare("%s[%d]" % (path, i), c, m, out)
    elif isinstance(mine, (int, float)) and isinstance(claimed, (int, float)) and not isinstance(mine, bool) and not isinstance(claimed, bool):
        if abs(claimed - mine) > tolerance(path):
            out.append("%s: record %r, rederived %r" % (path, claimed, mine))
    elif claimed != mine:
        out.append("%s: record %r, rederived %r" % (path, claimed, mine))


def main(argv):
    if len(argv) != 2:
        print("usage: python3 rederive.py results/RUN-<run id>.json", file=sys.stderr)
        return 2
    rec_path = Path(argv[1])
    try:
        rec = json.loads(rec_path.read_text())
        raw_dir = rec_path.parent / "raw" / rec["run_id"]
        rows = rec["price_table"]["rows"]
        _ = rec["figures"]["per_arm"]  # a record without figures is not a record
    except OSError as e:
        print("rederive.py: cannot read %s: %s" % (rec_path, e.strerror or e), file=sys.stderr)
        return 2
    except (ValueError, KeyError, TypeError) as e:
        print("rederive.py: cannot read %s as a bench run record (%s: %s)" % (rec_path, type(e).__name__, e), file=sys.stderr)
        return 2
    diffs = []
    if not raw_dir.is_dir():
        print("DIFFERENCES (1):\n  raw streams not found at %s" % raw_dir)
        return 1

    runs, mock = {}, False
    for path in sorted(raw_dir.glob("*.jsonl")):
        oc = read_stream(path)[3]
        if not oc:
            continue
        runs["%s|%s|%d" % (oc["task_id"], oc["arm"], int(oc["run"]))] = one_run(path, rows)
        mock = mock or bool(oc.get("mock"))

    task_ids = sorted(set(k.split("|")[0] for k in runs))
    arms = sorted(set(k.split("|")[1] for k in runs))
    per_run = max([int(k.rsplit("|", 1)[1]) for k in runs] or [0])
    smoke = len(task_ids) < 20 or per_run < 3

    per_arm = {}
    for a in ("a", "b", "c"):
        mine = [r for k, r in runs.items() if k.split("|")[1] == a]
        t = tally(mine)
        n = t["runs"]
        t["pass_rate"] = round(t["passed"] / n, 4) if n else None
        t["wilson95"] = wilson_bounds(t["passed"], n)
        t["cost_per_run_usd"] = round(t["cost_usd"] / n, 6) if n else None
        t["cost_per_passed_run_usd"] = round(t["cost_usd"] / t["passed"], 6) if t["passed"] else None
        per_arm[a] = t
    per_task = {}
    for tid in task_ids:
        per_task[tid] = {}
        for a in arms:
            mine = [r for k, r in runs.items() if k.split("|")[0] == tid and k.split("|")[1] == a]
            if mine:
                per_task[tid][a] = tally(mine)

    claimed_fig = rec["figures"]
    mine_fig = {"raw_files": len(runs), "runs": runs, "per_task": per_task, "per_arm": per_arm}
    claim_part = dict((k, claimed_fig.get(k)) for k in mine_fig)
    compare("figures", claim_part, mine_fig, diffs)

    # The comparison sentences: overlap flag and the arm said to be higher.
    pairs = [("a", "b"), ("a", "c"), ("b", "c")]
    said = dict((c.get("pair"), c) for c in claimed_fig.get("comparisons", []))
    for x, y in pairs:
        name = "%s vs %s" % (x, y)
        c = said.get(name)
        if c is None:
            diffs.append("figures.comparisons: no entry for %s" % name)
            continue
        px, py = per_arm[x], per_arm[y]
        if px["runs"] == 0 or py["runs"] == 0:
            continue
        overlap = not (px["wilson95"][1] < py["wilson95"][0] or py["wilson95"][1] < px["wilson95"][0])
        text = c.get("verdict", "")
        if bool(c.get("overlap")) != overlap:
            diffs.append("figures.comparisons[%s].overlap: record %r, rederived %r" % (name, c.get("overlap"), overlap))
        if overlap and ("differ" in text or "higher" in text or "real" in text):
            diffs.append("figures.comparisons[%s]: names a difference where the intervals overlap: %r" % (name, text))
        if not overlap:
            win = x if px["passed"] / px["runs"] > py["passed"] / py["runs"] else y
            if ("arm %s is higher" % win) not in text:
                diffs.append("figures.comparisons[%s]: should name arm %s as higher: %r" % (name, win, text))

    # Header facts.
    compare("n", rec.get("n"), {"tasks": len(task_ids), "runs_per_task": per_run, "arms": len(arms), "runs_total": len(runs)}, diffs)
    # A run is valid unless it lists invalid reasons or its restore check failed.
    # Records written before the mark existed have neither field and stay valid.
    restore_failed = bool((rec.get("restore_check") or {}).get("checked")) and not (rec.get("restore_check") or {}).get("ok")
    valid = not rec.get("invalid_reasons") and not restore_failed
    want_labels = (["INVALID RUN"] if not valid else []) + (["MOCK DATA"] if mock else []) + (["SMOKE RUN: not scored"] if smoke else [])
    compare("labels", rec.get("labels"), want_labels, diffs)
    compare("valid", rec.get("valid", True), valid, diffs)
    compare("mode", rec.get("mode"), "mock" if mock else "real", diffs)
    compare("smoke", rec.get("smoke"), smoke, diffs)
    compare("scored", rec.get("scored"), (not mock) and (not smoke) and valid, diffs)

    # Task folders.
    seen_ids = sorted(t["id"] for t in rec.get("task_set", []))
    if seen_ids != task_ids:
        diffs.append("task_set: record lists %s, the raw streams cover %s" % (seen_ids, task_ids))
    lines = []
    for t in sorted(rec.get("task_set", []), key=lambda t: t["id"]):
        folder = TASKS / t["id"]
        if not folder.is_dir():
            diffs.append("task_set.%s: task folder not found at %s" % (t["id"], folder))
            continue
        h = task_folder_hash(folder)
        if h != t["hash"]:
            diffs.append("task_set.%s.hash: record %s, folder now %s (the task changed after the run)" % (t["id"], t["hash"][:16], h[:16]))
        lines.append(t["id"] + ":" + t["hash"] + "\n")
    if hashlib.sha256("".join(lines).encode()).hexdigest() != rec.get("task_set_hash"):
        diffs.append("task_set_hash: does not match the hashes listed in task_set")

    if diffs:
        print("DIFFERENCES (%d):" % len(diffs))
        for d in diffs:
            print("  " + d)
        return 1
    print("AGREE")
    print(
        "rederived from %d raw streams: %d tasks, %d arms, n=%d per task per arm; "
        "pass rates, intervals, delegation counts, tokens by class, dollars, labels and task hashes match."
        % (len(runs), len(task_ids), len(arms), per_run)
    )
    if not valid:
        print("INVALID RUN: the record marks this run invalid, so there is nothing to sign.")
    elif mock:
        print("MOCK DATA: this record was synthesized, so there is nothing to sign.")
    elif smoke:
        print("SMOKE RUN: not scored, so this agreement signs nothing toward the 1.0.0 gate.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
