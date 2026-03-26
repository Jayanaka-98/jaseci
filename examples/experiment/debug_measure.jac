"""Quick debug: verify measure module works."""
import from measure { setup, show_results, _llm_api_calls }

with entry {
    setup();
    _llm_api_calls.append(
        {
            "model": "test",
            "prompt_tokens": 100,
            "completion_tokens": 50,
            "total_tokens": 150,
            "duration_ms": 500.0
        }
    );
    print("before show_results");
    show_results("DEBUG");
    print("after show_results");
}
