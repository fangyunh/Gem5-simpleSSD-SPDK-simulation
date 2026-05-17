#!/usr/bin/env bash
# run_vcd_power.sh — Per-config: gate-sim → VCD → OpenSTA activity-aware power.
# Run from RTL_design/ directory.
set -euo pipefail

STA=$HOME/tools/OpenSTA/build/sta
LIB_V=(
    lib/asap7sc7p5t_SIMPLE_RVT_TT_201020.v
    lib/asap7sc7p5t_INVBUF_RVT_TT_201020.v
    lib/asap7sc7p5t_SEQ_RVT_TT_220101.v
)
CFG=("16 64" "16 128" "64 64" "64 128")

for c in "${CFG[@]}"; do
    read -r NQ QD <<< "$c"
    TAG="${NQ}_${QD}"
    echo "=== Gate sim + VCD power: NQ=$NQ QD=$QD ==="

    iverilog -g2005 -o /tmp/gate_sim_${TAG} \
        tb/tb_gate_stim.v \
        netlists/io_uncore_${TAG}.v \
        "${LIB_V[@]}" \
        src/sram_blackbox.v 2>/dev/null

    # Output VCD into /tmp; cd there so tb_gate_stim.vcd is written next to the exe.
    (cd /tmp && rm -f tb_gate_stim.vcd && vvp gate_sim_${TAG} 2>&1 | tail -2 && mv tb_gate_stim.vcd gate_sim_${TAG}.vcd)

    NQ=$NQ QD=$QD VCD=/tmp/gate_sim_${TAG}.vcd \
        "$STA" -no_init -no_splash -exit synth/sta/run_sta_vcd.tcl 2>/dev/null \
        | grep -E "Annotated|Power-VCD complete" || true
done

echo ""
echo "=== Activity-aware power summary ==="
printf "%-14s %12s %12s %12s\n" "Config" "Total_mW" "Switching_mW" "Annotated_pct"
for c in "${CFG[@]}"; do
    read -r NQ QD <<< "$c"
    TAG="${NQ}_${QD}"
    TOT=$(awk '/^Total/ {print $5}' reports/sta_${TAG}_power_vcd.rpt | head -1)
    SW=$(awk '/^Total/ {print $3}' reports/sta_${TAG}_power_vcd.rpt | head -1)
    printf "%-14s %12s %12s\n" "NQ=${NQ}_QD=${QD}" \
        "$(python3 -c "print(f'{${TOT}*1000:.3f}')")" \
        "$(python3 -c "print(f'{${SW}*1000:.3f}')")"
done
