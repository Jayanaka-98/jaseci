"""Measurement harness for comparing byllm approaches.

Hooks into litellm CustomLogger to capture per-API-call token usage
and latency. Produces a report + JSON for comparison.
"""

import time;
import json;
import os;
import litellm;
import from litellm.integrations.custom_logger { CustomLogger }

# ── Internal state ──
glob _llm_api_calls: list = [],
     _state: dict = {"start_time": 0.0};

# ── LiteLLM callback (fires per raw API call) ──
class TokenTracker(CustomLogger) {
    def log_success_event(
        self, kwargs: dict, response_obj: object, start_time: object, end_time: object
    ) -> None {
        usage = getattr(response_obj, "usage", None);
        prompt_tokens = getattr(usage, "prompt_tokens", 0) or 0;
        completion_tokens = getattr(usage, "completion_tokens", 0) or 0;
        total_tokens = getattr(usage, "total_tokens", 0) or 0;
        duration_ms = (end_time - start_time).total_seconds() * 1000;
        _llm_api_calls.append(
            {
                "model": kwargs.get("model", "unknown"),
                "prompt_tokens": prompt_tokens,
                "completion_tokens": completion_tokens,
                "total_tokens": total_tokens,
                "duration_ms": round(duration_ms, 1)
            }
        );
    }
}

# ── Public API ──
def setup -> None {
    _llm_api_calls.clear();
    _state["start_time"] = time.time();
    litellm.callbacks = [TokenTracker()];
}

def show_results(label: str, success: bool = True) -> None {
    wall_ms = (time.time() - _state["start_time"]) * 1000;

    total_prompt = sum([c["prompt_tokens"] for c in _llm_api_calls]);
    total_completion = sum([c["completion_tokens"] for c in _llm_api_calls]);
    total_tokens = sum([c["total_tokens"] for c in _llm_api_calls]);
    total_llm_ms = sum([c["duration_ms"] for c in _llm_api_calls]);

    status = "SUCCESS" if success else "FAILED";
    sep = "=" * 60;

    print("");
    print(sep);
    print(f"  {label}  [{status}]");
    print(sep);
    print(f"  Wall clock time:      {int(wall_ms)} ms");
    print(f"  LLM API calls:        {len(_llm_api_calls)}");
    print(f"  Total LLM latency:    {int(total_llm_ms)} ms");
    print("");
    print("  --- Token Usage ---");
    print(f"  Prompt tokens:        {total_prompt}");
    print(f"  Completion tokens:    {total_completion}");
    print(f"  Total tokens:         {total_tokens}");
    print("");
    print("  --- Per LLM API Call ---");
    for (i, c) in enumerate(_llm_api_calls) {
        pt = c["prompt_tokens"];
        ct = c["completion_tokens"];
        ms = int(c["duration_ms"]);
        print(f"    [{i + 1}] {pt} in / {ct} out / {ms}ms");
    }
    print(sep);

    # Build result dict
    result = {
        "label": label,
        "success": success,
        "wall_clock_ms": round(wall_ms, 1),
        "llm_api_calls": len(_llm_api_calls),
        "total_llm_latency_ms": round(total_llm_ms, 1),
        "prompt_tokens": total_prompt,
        "completion_tokens": total_completion,
        "total_tokens": total_tokens,
        "per_api_call": list(_llm_api_calls)
    };

    # Append to a JSONL file (one JSON object per line, per run)
    run_id = os.environ.get("RUN_ID", "0");
    fname = label.lower().replace(" ", "_").replace("(", "").replace(")", "").replace(
        "+", "plus"
    );
    jsonl_path = f"{fname}_runs.jsonl";
    with open(jsonl_path, "a") as f {
        f.write(json.dumps(result));
        f.write("\n");
    }

    # Also write the single-run JSON for backwards compat
    with open(f"{fname}_results.json", "w") as f {
        json.dump(result, f, indent=2);
    }
}
