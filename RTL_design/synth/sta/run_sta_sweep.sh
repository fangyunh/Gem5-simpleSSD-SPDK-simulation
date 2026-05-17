#!/usr/bin/env bash
# run_sta_sweep.sh — Run OpenSTA on all 4 IO-Uncore configs.
# Reports go to reports/sta_<NQ>_<QD>_*.rpt.
# Must be run from RTL_design/ directory.
set -euo pipefail

STA=$HOME/tools/OpenSTA/build/sta
CFG=("16 64" "16 128" "64 64" "64 128")

echo "=== OpenSTA sweep ==="
for c in "${CFG[@]}"; do
    read -r NQ QD <<< "$c"
    echo "--- NQ=$NQ QD=$QD ---"

    # Strip parameter overrides from sram_macro inst, in case netlist was regenerated
    python3 - "netlists/io_uncore_${NQ}_${QD}.v" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
pat = re.compile(r"sram_macro\s*#\(\s*\.ADDR_WIDTH\([^)]*\),\s*\.DATA_WIDTH\([^)]*\),\s*\.DEPTH\([^)]*\)\s*\)", re.DOTALL)
if pat.search(s):
    s = pat.sub("sram_macro", s)
    open(p, 'w').write(s)
PY

    NQ=$NQ QD=$QD "$STA" -no_init -no_splash -exit synth/sta/run_sta.tcl \
        2> /dev/null \
        | grep -E "InstanceCount|STA complete" || true
done
echo ""
echo "=== Per-config summary ==="
printf "%-10s %12s %12s %12s %12s\n" "Config" "WNS_ps" "TNS_ps" "Total_mW" "Leak_uW"
for c in "${CFG[@]}"; do
    read -r NQ QD <<< "$c"
    WNS=$(awk '/wns max/ {print $3}' reports/sta_${NQ}_${QD}_wns.rpt)
    TNS=$(awk '/tns max/ {print $3}' reports/sta_${NQ}_${QD}_tns.rpt)
    TOT=$(awk '/^Total/ {print $5}' reports/sta_${NQ}_${QD}_power.rpt | head -1)
    LEAK=$(awk '/^Total/ {print $4}' reports/sta_${NQ}_${QD}_power.rpt | head -1)
    printf "%-10s %12s %12s %12s %12s\n" "NQ=${NQ}_QD=${QD}" "$WNS" "$TNS" "$(python3 -c "print(f'{${TOT}*1000:.3f}')" 2>/dev/null || echo '?')" "$(python3 -c "print(f'{${LEAK}*1e6:.4f}')" 2>/dev/null || echo '?')"
done
