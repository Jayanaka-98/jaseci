"""Compare results from baseline and OSP experiments."""

import glob
import json


def load_result(pattern: str):
    matches = glob.glob(pattern)
    if not matches:
        return None
    with open(matches[0]) as f:
        return json.load(f)


def main():
    baseline = load_result("baseline*_results.json")
    osp = load_result("osp*_results.json")

    if not baseline or not osp:
        print("Missing result files. Run both experiments first.")
        return

    print(f"\n{'=' * 60}")
    print("  SIDE-BY-SIDE COMPARISON")
    print(f"{'=' * 60}")
    print(f"{'Metric':<28} {'Baseline':>14} {'OSP+byLLM':>14} {'Ratio':>10}")
    print(f"{'-' * 66}")

    metrics = [
        ("Wall clock (ms)", "wall_clock_ms"),
        ("LLM API calls", "llm_api_calls"),
        ("byLLM invocations", "byllm_invocations"),
        ("LLM latency (ms)", "total_llm_latency_ms"),
        ("Prompt tokens", "prompt_tokens"),
        ("Completion tokens", "completion_tokens"),
        ("Total tokens", "total_tokens"),
    ]

    for label, key in metrics:
        b = baseline.get(key, 0)
        o = osp.get(key, 0)
        ratio = f"{b / o:.1f}x" if o > 0 else "N/A"
        print(f"  {label:<26} {b:>14,.0f} {o:>14,.0f} {ratio:>10}")

    print(f"{'-' * 66}")

    # Token savings
    b_tok = baseline.get("total_tokens", 0)
    o_tok = osp.get("total_tokens", 0)
    if b_tok > 0:
        savings_pct = (1 - o_tok / b_tok) * 100
        print(f"\n  Token savings: {savings_pct:.0f}% fewer tokens with OSP+byLLM")

    b_time = baseline.get("wall_clock_ms", 0)
    o_time = osp.get("wall_clock_ms", 0)
    if b_time > 0:
        speedup = b_time / o_time if o_time > 0 else 0
        faster = "faster" if o_time < b_time else "slower"
        print(f"  Latency: OSP+byLLM is {abs(speedup):.1f}x {faster}")

    # Show per-call context growth for baseline
    print("\n  --- Baseline: per-API-call prompt token growth ---")
    for i, call in enumerate(baseline.get("per_api_call", [])):
        bar = "#" * (call["prompt_tokens"] // 100)
        print(f"    Call {i + 1:>2}: {call['prompt_tokens']:>6} tokens  {bar}")

    print("\n  --- OSP: per-API-call prompt tokens (flat) ---")
    for i, call in enumerate(osp.get("per_api_call", [])):
        bar = "#" * (call["prompt_tokens"] // 100)
        print(f"    Call {i + 1:>2}: {call['prompt_tokens']:>6} tokens  {bar}")

    print(f"\n{'=' * 60}\n")


if __name__ == "__main__":
    main()
