#!/usr/bin/env bash
# run_fmax.sh — Bisect OpenSTA clock period to find Fmax (WNS >= 0) per config.
# Usage: bash synth/sta/run_fmax.sh
# Writes reports/fmax.csv
set -euo pipefail

STA=$HOME/tools/OpenSTA/build/sta
TCL=synth/sta/run_sta.tcl
CFG=("16 64" "16 128" "64 64" "64 128")

# Probe a single period; print WNS in ps to stdout.
probe() {
    local nq=$1 qd=$2 period=$3
    NQ=$nq QD=$qd CLK_PERIOD_PS=$period \
        "$STA" -no_init -no_splash -exit "$TCL" 2>/dev/null > /tmp/sta_probe.log
    awk '/^wns max/ {print $3}' reports/sta_${nq}_${qd}_wns.rpt
}

echo "config,period_ps_meeting,fmax_MHz" > reports/fmax.csv
for c in "${CFG[@]}"; do
    read -r NQ QD <<< "$c"
    echo "=== Fmax bisection NQ=$NQ QD=$QD ==="

    # Find a period that meets — start at 10 ns, scale up if needed
    lo=10000
    wns=$(probe $NQ $QD $lo)
    echo "  period=${lo} ps  wns=${wns} ps"
    while awk -v w="$wns" 'BEGIN{exit !(w<0)}'; do
        lo=$(awk -v p="$lo" 'BEGIN{printf "%.0f", p*1.5}')
        if [ "$lo" -gt 100000 ]; then echo "  FAIL: design needs > 100 ns period"; break; fi
        wns=$(probe $NQ $QD $lo)
        echo "  period=${lo} ps  wns=${wns} ps"
    done

    # Bisection: lo meets, hi violates
    hi=1000
    # Refine: 12 iterations gives <25 ps resolution from any starting range
    for i in $(seq 1 12); do
        mid=$(( (lo + hi) / 2 ))
        if [ $(( lo - hi )) -lt 50 ]; then break; fi
        wns=$(probe $NQ $QD $mid)
        echo "  period=${mid} ps  wns=${wns} ps"
        if awk -v w="$wns" 'BEGIN{exit !(w<0)}'; then
            hi=$mid
        else
            lo=$mid
        fi
    done

    fmax=$(awk -v p="$lo" 'BEGIN{printf "%.1f", 1000000.0/p}')
    echo "  FMAX: ${fmax} MHz at period ${lo} ps"
    echo "NQ=${NQ}_QD=${QD},${lo},${fmax}" >> reports/fmax.csv
done

echo ""
echo "=== Fmax summary ==="
column -t -s, reports/fmax.csv
