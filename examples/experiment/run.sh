#!/usr/bin/env bash
#
# Run both experiments and compare results.
# Usage: conda activate jac-mai && bash run.sh
#
set -euo pipefail
cd "$(dirname "$0")"

echo "============================================"
echo "  byLLM+OSP vs Skill-in-Prompt Experiment"
echo "============================================"
echo ""
echo "Model: $(grep default_model jac.toml | head -1)"
echo "Working dir: $(pwd)"
echo ""

# Ensure OPENAI_API_KEY is set
if [ -z "${OPENAI_API_KEY:-}" ]; then
    echo "ERROR: OPENAI_API_KEY not set. Export it first."
    exit 1
fi

echo "──────────────────────────────────────────"
echo "  Running BASELINE (skill-in-prompt)..."
echo "──────────────────────────────────────────"
jac run baseline.jac 2>&1 | tee baseline_output.txt
echo ""

echo "──────────────────────────────────────────"
echo "  Running OSP + byLLM (scoped calls)..."
echo "──────────────────────────────────────────"
jac run osp.jac 2>&1 | tee osp_output.txt
echo ""

# Compare if both JSON results exist
if ls baseline*_results.json 1>/dev/null 2>&1 && ls osp*_results.json 1>/dev/null 2>&1; then
    echo "──────────────────────────────────────────"
    echo "  COMPARISON"
    echo "──────────────────────────────────────────"
    python3 compare.py
fi
