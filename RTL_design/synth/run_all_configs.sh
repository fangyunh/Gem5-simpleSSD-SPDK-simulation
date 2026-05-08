#!/usr/bin/env bash
# run_all_configs.sh — Sweep all 4 IO-Uncore synthesis configurations with Yosys + ASAP7
# Run from RTL_design/ directory
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
RTL_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$RTL_DIR"

echo "=== IO-Uncore Yosys Synthesis Sweep ==="
echo "Working dir: $RTL_DIR"
echo ""

# Four configurations from the spec
CONFIGS=(
    "16 64"    # Config A: gem5 match
    "64 64"    # Config B: scale queues
    "16 128"   # Config C: scale depth
    "64 128"   # Config D: production
)

for cfg in "${CONFIGS[@]}"; do
    read -r NQ QD <<< "$cfg"
    echo "--- Synthesizing NQ=$NQ QD=$QD ---"
    NQ=$NQ QD=$QD yosys -c synth/run_synth_yosys.tcl \
        2>&1 | tee reports/yosys_log_${NQ}_${QD}.log | tail -5
    echo ""
done

echo "=== All configurations synthesized ==="
echo "Reports:"
ls -la reports/stat_*.rpt 2>/dev/null || echo "(no reports — check for errors)"
