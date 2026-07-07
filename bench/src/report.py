#!/usr/bin/env python3
"""Conductor benchmark reporter.

Reads bench/results/raw/*.json (written by run.py), aggregates tokens by
model tier (main / sonnet / haiku, parsed from modelUsage keys), computes a
modeled cost from the PRICING constants below alongside the CLI's own
reported costUSD, and writes bench/results/results.md with per-task and
aggregate tables plus wall time and success rate.

Stdlib only. No third-party imports.
"""
from __future__ import annotations

import json
import sys
from collections import defaultdict
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parent.parent
RAW_DIR = BENCH_DIR / "results" / "raw"
OUT_PATH = BENCH_DIR / "results" / "results.md"

# Single constants block. USD per MTok (million tokens), (input, output).
# Provenance: CT's standing cost anchors (claude-api reference, verified
# 2026-07-02). These are the MODELED rates used for the "modeled cost"
# column; the CLI's own total_cost_usd / modelUsage[*].costUSD is captured
# and reported side by side as the "reported cost" column so the two never
# get silently conflated.
PRICING = {
    "fable": (10.0, 50.0),
    "opus": (5.0, 25.0),
    "sonnet": (3.0, 15.0),
    "haiku": (1.0, 5.0),
}


def tier_for_model(model_id: str) -> str:
    """Classify a modelUsage key into a DISPLAY tier by substring match:
    contains "haiku" -> haiku, contains "sonnet" -> sonnet, else main. This
    matches the bench spec's 3-column split exactly; opus/fable main-model
    runs fall into "main" for the token-count columns, since the per-task
    table only ever has 3 token columns (main/sonnet/haiku).

    This is deliberately separate from pricing_tier_for_model below: display
    grouping and cost-rate lookup are different concerns. A main-model run
    on opus or fable still needs to be priced at opus/fable rates, not
    silently priced as sonnet just because it shares the "main" display
    column with sonnet-baseline runs would not."""
    m = model_id.lower()
    if "haiku" in m:
        return "haiku"
    if "sonnet" in m:
        return "sonnet"
    return "main"


def pricing_tier_for_model(model_id: str) -> str:
    """Classify a modelUsage key into a PRICING tier (a key in PRICING).
    Checked independently of tier_for_model so an opus or fable main model
    is billed at its own rate, not folded into the sonnet rate just because
    it shares the "main" display column. Falls back to "sonnet" only if the
    model id matches none of the four known families (unrecognized model)."""
    m = model_id.lower()
    for tier in ("haiku", "sonnet", "opus", "fable"):
        if tier in m:
            return tier
    return "sonnet"


def modeled_cost_usd(model_id: str, input_tokens: int, output_tokens: int) -> float:
    tier = pricing_tier_for_model(model_id)
    in_rate, out_rate = PRICING[tier]
    return (input_tokens / 1_000_000) * in_rate + (output_tokens / 1_000_000) * out_rate


def load_raw_results() -> list[dict]:
    if not RAW_DIR.is_dir():
        return []
    results = []
    for path in sorted(RAW_DIR.glob("*.json")):
        with open(path) as f:
            try:
                data = json.load(f)
            except json.JSONDecodeError:
                continue
        data["_raw_path"] = str(path)
        results.append(data)
    return results


def tier_breakdown(result: dict) -> dict[str, dict[str, int]]:
    """Return {tier: {input_tokens, output_tokens}} from modelUsage, falling
    back to the aggregate usage block attributed entirely to 'main' if
    modelUsage is absent (e.g. an older CLI version or a failed run)."""
    breakdown: dict[str, dict[str, int]] = defaultdict(
        lambda: {"input_tokens": 0, "output_tokens": 0}
    )
    model_usage = result.get("modelUsage")
    if model_usage:
        for model_id, usage in model_usage.items():
            tier = tier_for_model(model_id)
            breakdown[tier]["input_tokens"] += usage.get("inputTokens", 0)
            breakdown[tier]["output_tokens"] += usage.get("outputTokens", 0)
    else:
        usage = result.get("usage", {})
        breakdown["main"]["input_tokens"] += usage.get("input_tokens", 0)
        breakdown["main"]["output_tokens"] += usage.get("output_tokens", 0)
    return dict(breakdown)


def modeled_cost_for_result(result: dict) -> float:
    """Total modeled cost for one result, priced per actual model id (not
    per display tier) so an opus/fable main model bills at its own rate
    instead of the sonnet rate its "main" display column would imply."""
    model_usage = result.get("modelUsage")
    if model_usage:
        total = 0.0
        for model_id, usage in model_usage.items():
            total += modeled_cost_usd(
                model_id, usage.get("inputTokens", 0), usage.get("outputTokens", 0)
            )
        return total
    usage = result.get("usage", {})
    # No modelUsage means no way to know which model was actually used from
    # this result alone; fall back to the "main" model recorded on the
    # result itself if present, else price at sonnet as a documented default.
    model_id = result.get("model", "")
    return modeled_cost_usd(
        model_id, usage.get("input_tokens", 0), usage.get("output_tokens", 0)
    )


def reported_cost_usd(result: dict) -> float:
    if "total_cost_usd" in result:
        return float(result["total_cost_usd"])
    model_usage = result.get("modelUsage", {})
    return sum(u.get("costUSD", 0.0) for u in model_usage.values())


def fmt_usd(x: float) -> str:
    return f"${x:.4f}"


def fmt_tokens(n: int) -> str:
    return f"{n:,}"


def build_report(results: list[dict]) -> str:
    lines: list[str] = []
    lines.append("# Conductor Benchmark Results")
    lines.append("")

    if not results:
        lines.append("No results found. Run src/run.py first.")
        return "\n".join(lines) + "\n"

    any_mock = any(r.get("is_mock") for r in results)
    if any_mock:
        lines.append(
            "MOCK DATA: these results were synthesized by run.py "
            "(BENCH_MOCK=1), not produced by real claude invocations. "
            "Numbers below prove the pipeline renders end to end; they are "
            "not evidence of real-world token or cost differences."
        )
        lines.append("")

    # Group by task then arm.
    by_task: dict[str, dict[str, list[dict]]] = defaultdict(lambda: defaultdict(list))
    for r in results:
        task_id = r.get("task_id", "unknown")
        arm = r.get("arm", "unknown")
        by_task[task_id][arm].append(r)

    lines.append("## Per-task results")
    lines.append("")
    header = (
        "| task | arm | runs | success rate | avg wall time (s) | "
        "main tokens (in/out) | sonnet tokens (in/out) | haiku tokens (in/out) | "
        "modeled cost | reported cost |"
    )
    sep = "|---|---|---|---|---|---|---|---|---|---|"
    lines.append(header)
    lines.append(sep)

    agg_by_arm: dict[str, dict] = defaultdict(
        lambda: {
            "runs": 0,
            "successes": 0,
            "wall_time_total": 0.0,
            "tier_tokens": defaultdict(lambda: {"input_tokens": 0, "output_tokens": 0}),
            "modeled_cost_total": 0.0,
            "reported_cost_total": 0.0,
        }
    )

    for task_id in sorted(by_task):
        for arm in sorted(by_task[task_id]):
            runs = by_task[task_id][arm]
            n_runs = len(runs)
            n_success = sum(1 for r in runs if r.get("success"))
            success_rate = f"{n_success}/{n_runs}"

            wall_times = [
                r.get("wall_time_s", (r.get("duration_ms", 0) or 0) / 1000.0)
                for r in runs
            ]
            avg_wall = sum(wall_times) / len(wall_times) if wall_times else 0.0

            tier_totals: dict[str, dict[str, int]] = defaultdict(
                lambda: {"input_tokens": 0, "output_tokens": 0}
            )
            modeled_total = 0.0
            reported_total = 0.0

            for r in runs:
                breakdown = tier_breakdown(r)
                for tier, toks in breakdown.items():
                    tier_totals[tier]["input_tokens"] += toks["input_tokens"]
                    tier_totals[tier]["output_tokens"] += toks["output_tokens"]
                # Cost is priced per actual model id (modeled_cost_for_result),
                # not per display tier: an opus/fable main model must bill at
                # its own rate even though its tokens display under "main".
                modeled_total += modeled_cost_for_result(r)
                reported_total += reported_cost_usd(r)

                agg = agg_by_arm[arm]
                agg["runs"] += 1
                if r.get("success"):
                    agg["successes"] += 1

            agg_by_arm[arm]["wall_time_total"] += sum(wall_times)
            agg_by_arm[arm]["modeled_cost_total"] += modeled_total
            agg_by_arm[arm]["reported_cost_total"] += reported_total
            for tier, toks in tier_totals.items():
                agg_by_arm[arm]["tier_tokens"][tier]["input_tokens"] += toks["input_tokens"]
                agg_by_arm[arm]["tier_tokens"][tier]["output_tokens"] += toks["output_tokens"]

            def tier_cell(tier: str) -> str:
                t = tier_totals.get(tier, {"input_tokens": 0, "output_tokens": 0})
                return f"{fmt_tokens(t['input_tokens'])}/{fmt_tokens(t['output_tokens'])}"

            lines.append(
                f"| {task_id} | {arm} | {n_runs} | {success_rate} | "
                f"{avg_wall:.1f} | {tier_cell('main')} | {tier_cell('sonnet')} | "
                f"{tier_cell('haiku')} | {fmt_usd(modeled_total)} | "
                f"{fmt_usd(reported_total)} |"
            )

    lines.append("")
    lines.append("## Aggregate by arm")
    lines.append("")
    agg_header = (
        "| arm | total runs | success rate | total wall time (s) | "
        "main tokens (in/out) | sonnet tokens (in/out) | haiku tokens (in/out) | "
        "total modeled cost | total reported cost |"
    )
    agg_sep = "|---|---|---|---|---|---|---|---|---|"
    lines.append(agg_header)
    lines.append(agg_sep)

    for arm in sorted(agg_by_arm):
        agg = agg_by_arm[arm]
        success_rate = f"{agg['successes']}/{agg['runs']}"

        def agg_tier_cell(tier: str) -> str:
            t = agg["tier_tokens"].get(tier, {"input_tokens": 0, "output_tokens": 0})
            return f"{fmt_tokens(t['input_tokens'])}/{fmt_tokens(t['output_tokens'])}"

        lines.append(
            f"| {arm} | {agg['runs']} | {success_rate} | "
            f"{agg['wall_time_total']:.1f} | {agg_tier_cell('main')} | "
            f"{agg_tier_cell('sonnet')} | {agg_tier_cell('haiku')} | "
            f"{fmt_usd(agg['modeled_cost_total'])} | "
            f"{fmt_usd(agg['reported_cost_total'])} |"
        )

    lines.append("")
    lines.append("## Pricing used for modeled cost (USD per MTok, in/out)")
    lines.append("")
    lines.append("| tier | input | output |")
    lines.append("|---|---|---|")
    for tier, (in_rate, out_rate) in PRICING.items():
        lines.append(f"| {tier} | ${in_rate:.2f} | ${out_rate:.2f} |")
    lines.append("")
    lines.append(
        "Modeled cost applies the table above to captured token counts. "
        "Reported cost is the claude CLI's own total_cost_usd / "
        "modelUsage[*].costUSD, unmodified. They can differ (e.g. cache "
        "discounts, pricing changes since this table was last updated); "
        "both are shown so neither is mistaken for the other."
    )
    lines.append("")

    return "\n".join(lines) + "\n"


def main() -> int:
    results = load_raw_results()
    report = build_report(results)
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(OUT_PATH, "w") as f:
        f.write(report)
    print(f"[report.py] wrote {OUT_PATH} from {len(results)} raw result files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
