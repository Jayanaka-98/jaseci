#!/usr/bin/env bash
#
# Run both experiments N times and aggregate results.
# Usage: conda activate jac-main && bash run_multi.sh [N]
#
set -euo pipefail
cd "$(dirname "$0")"

N=${1:-5}

echo "============================================"
echo "  byLLM+OSP vs Baseline — ${N} runs each"
echo "============================================"
echo "Model: $(grep default_model jac.toml | head -1)"
echo ""

if [ -z "${OPENAI_API_KEY:-}" ]; then
    echo "ERROR: OPENAI_API_KEY not set."
    exit 1
fi

# Clear previous run data
rm -f *_runs.jsonl *_results.json
rm -rf __pycache__

for i in $(seq 1 "$N"); do
    echo "────────────────────────────────────────"
    echo "  Run $i/$N — BASELINE"
    echo "────────────────────────────────────────"
    rm -rf __pycache__
    RUN_ID=$i jac run baseline.jac 2>&1 || true
    echo ""

    echo "────────────────────────────────────────"
    echo "  Run $i/$N — OSP + byLLM"
    echo "────────────────────────────────────────"
    rm -rf __pycache__
    RUN_ID=$i jac run osp.jac 2>&1 || true
    echo ""
done

echo ""
echo "============================================"
echo "  AGGREGATE RESULTS ($N runs)"
echo "============================================"
python3 aggregate.py "$N"
