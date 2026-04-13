#!/usr/bin/env bash
# run_all_configs.sh — Sweep all 4 synthesis configurations
# Run from RTL_design/ directory
set -euo pipefail

DC_SHELL=${DC_SHELL:-/usr/local/syn/Y-2026.03/bin/dc_shell}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
RTL_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

cd "$RTL_DIR"

echo "=== IO-Uncore Synthesis Sweep ==="
echo "DC: $DC_SHELL"
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
    $DC_SHELL -f synth/run_synth.tcl -x "set NQ $NQ; set QD $QD" \
        2>&1 | tee reports/dc_log_${NQ}_${QD}.log
    echo ""
done

echo "=== All configurations synthesized ==="
echo "Reports in: reports/"
ls -la reports/*.rpt 2>/dev/null || echo "(no reports yet — check for errors)"
