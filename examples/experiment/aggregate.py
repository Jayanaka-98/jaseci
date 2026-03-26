"""Aggregate results from multiple experiment runs."""

import glob
import json


def load_runs(pattern):
    """Load all runs from a JSONL file."""
    matches = glob.glob(pattern)
    if not matches:
        return []
    runs = []
    for path in matches:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line:
                    runs.append(json.loads(line))
    return runs


def stats(values):
    """Compute mean, min, max for a list of numbers."""
    if not values:
        return {"mean": 0, "min": 0, "max": 0, "n": 0}
    return {
        "mean": sum(values) / len(values),
        "min": min(values),
        "max": max(values),
        "n": len(values),
    }


def print_section(label, runs):
    n = len(runs)
    successes = sum(1 for r in runs if r.get("success", False))
    failures = n - successes

    wall = stats([r["wall_clock_ms"] for r in runs])
    api_calls = stats([r["llm_api_calls"] for r in runs])
    latency = stats([r["total_llm_latency_ms"] for r in runs])
    prompt = stats([r["prompt_tokens"] for r in runs])
    completion = stats([r["completion_tokens"] for r in runs])
    total = stats([r["total_tokens"] for r in runs])

    # Cost calculation (gpt-4o-mini pricing)
    costs = []
    for r in runs:
        c = (
            r["prompt_tokens"] * 0.15 / 1_000_000
            + r["completion_tokens"] * 0.60 / 1_000_000
        )
        costs.append(c)
    cost = stats(costs)

    print(f"\n  {label}")
    print(f"  {'─' * 50}")
    print(f"  Runs:              {n}")
    print(f"  Success rate:      {successes}/{n} ({successes / n * 100:.0f}%)")
    if failures > 0:
        print(f"  Failures:          {failures}")
    print("")
    print(f"  {'Metric':<24} {'Mean':>10} {'Min':>10} {'Max':>10}")
    print(f"  {'─' * 54}")
    print(
        f"  {'Wall clock (ms)':<24} {wall['mean']:>10.0f} {wall['min']:>10.0f} {wall['max']:>10.0f}"
    )
    print(
        f"  {'LLM API calls':<24} {api_calls['mean']:>10.1f} {api_calls['min']:>10.0f} {api_calls['max']:>10.0f}"
    )
    print(
        f"  {'LLM latency (ms)':<24} {latency['mean']:>10.0f} {latency['min']:>10.0f} {latency['max']:>10.0f}"
    )
    print(
        f"  {'Prompt tokens':<24} {prompt['mean']:>10.0f} {prompt['min']:>10.0f} {prompt['max']:>10.0f}"
    )
    print(
        f"  {'Completion tokens':<24} {completion['mean']:>10.0f} {completion['min']:>10.0f} {completion['max']:>10.0f}"
    )
    print(
        f"  {'Total tokens':<24} {total['mean']:>10.0f} {total['min']:>10.0f} {total['max']:>10.0f}"
    )
    print(
        f"  {'Cost ($, gpt-4o-mini)':<24} {cost['mean'] * 1000:>10.4f}m {cost['min'] * 1000:>10.4f}m {cost['max'] * 1000:>10.4f}m"
    )

    return {
        "success_rate": successes / n if n > 0 else 0,
        "avg_wall_ms": wall["mean"],
        "avg_prompt": prompt["mean"],
        "avg_completion": completion["mean"],
        "avg_total": total["mean"],
        "avg_cost": cost["mean"],
    }


def main():
    baseline_runs = load_runs("baseline*_runs.jsonl")
    osp_runs = load_runs("osp*_runs.jsonl")

    if not baseline_runs and not osp_runs:
        print("No run data found. Run the experiments first.")
        return

    sep = "=" * 60
    print(f"\n{sep}")
    print("  AGGREGATE COMPARISON")
    print(f"{sep}")

    b_stats = {}
    o_stats = {}
    if baseline_runs:
        b_stats = print_section("BASELINE (skill-in-prompt + tools)", baseline_runs)
    if osp_runs:
        o_stats = print_section("OSP + byLLM (scoped calls)", osp_runs)

    if b_stats and o_stats:
        print(f"\n  {'─' * 50}")
        print("  COMPARISON (Baseline vs OSP)")
        print(f"  {'─' * 50}")
        print(
            f"  Success rate:     {b_stats['success_rate'] * 100:.0f}% vs {o_stats['success_rate'] * 100:.0f}%"
        )

        if o_stats["avg_prompt"] > 0:
            print(
                f"  Prompt tokens:    {b_stats['avg_prompt']:.0f} vs {o_stats['avg_prompt']:.0f}  ({b_stats['avg_prompt'] / o_stats['avg_prompt']:.1f}x)"
            )
        if o_stats["avg_total"] > 0:
            print(
                f"  Total tokens:     {b_stats['avg_total']:.0f} vs {o_stats['avg_total']:.0f}  ({b_stats['avg_total'] / o_stats['avg_total']:.1f}x)"
            )
        if o_stats["avg_cost"] > 0:
            savings = (
                (1 - o_stats["avg_cost"] / b_stats["avg_cost"]) * 100
                if b_stats["avg_cost"] > 0
                else 0
            )
            print(
                f"  Avg cost:         ${b_stats['avg_cost'] * 1000:.4f}m vs ${o_stats['avg_cost'] * 1000:.4f}m  ({savings:.0f}% savings)"
            )
        if o_stats["avg_wall_ms"] > 0:
            ratio = b_stats["avg_wall_ms"] / o_stats["avg_wall_ms"]
            faster = "faster" if ratio > 1 else "slower"
            print(
                f"  Avg wall clock:   {b_stats['avg_wall_ms']:.0f}ms vs {o_stats['avg_wall_ms']:.0f}ms  (OSP {ratio:.1f}x {faster})"
            )

    print(f"\n{sep}\n")

    # Write aggregate JSON
    with open("aggregate_results.json", "w") as f:
        json.dump(
            {
                "baseline": b_stats,
                "osp": o_stats,
                "baseline_runs": len(baseline_runs),
                "osp_runs": len(osp_runs),
            },
            f,
            indent=2,
        )


if __name__ == "__main__":
    main()
