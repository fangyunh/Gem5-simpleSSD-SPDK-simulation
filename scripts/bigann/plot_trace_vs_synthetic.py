"""Compare DiskANN/BigANN trace replay vs synthetic 4 KB random read.

Reads two phase1_results.csv files -- one from a trace-replay sweep
(scripts/bigann/driver_phase1_trace.sh) and one from a synthetic sweep
(scripts/phase1_4k/driver_phase1.sh) -- and produces a side-by-side bar
chart anchoring the §4.1 "trace-equivalent" claim:

    cycles/IO and IOPS on the same SimpleSSD device, same SPDK build,
    same UncoreMode, same QD/qpairs -- only the workload generator
    differs (synthetic random vs replayed BigANN trace).

If the two cycles/IO numbers agree within ~10%, the synthetic 4 KB random
read benchmark is justified as a workload-equivalent proxy.

Output: plots/trace_vs_synthetic.{png,pdf}
"""
from __future__ import annotations

import argparse
import csv
import glob
import os
import sys
from collections import defaultdict
from typing import Dict, List, Optional, Tuple

import matplotlib as mpl
import matplotlib.pyplot as plt

PLOTS_DIR = "plots"
CPU_GHZ = 5.3

NAMED_STAGES = [
    "Submit_Preamble_ns",
    "Tracker_Alloc_ns",
    "Addr_Xlate_ns",
    "Cmd_Construct_ns",
    "Fence_ns",
    "Doorbell_ns",
    "CQE_Detect_ns",
    "Tracker_Lookup_ns",
    "State_Dealloc_Library_ns",
    "State_Dealloc_Callback_ns",
]

STAGE_PALETTE = list(mpl.colormaps["tab20"].colors[:len(NAMED_STAGES) - 1]) + ["#d62728"]
OTHER_COLOR = "#bbbbbb"


def load_csv(path: str, qd: int, io_size: int) -> Optional[Dict[str, float]]:
    """Load and average one or more rows from a single phase1_results.csv,
    matching the (qd, io_size) filter."""
    if not os.path.isfile(path):
        return None

    rows = []
    with open(path) as f:
        reader = csv.DictReader(f)
        if not reader.fieldnames:
            return None
        has_split = "State_Dealloc_Library_ns" in reader.fieldnames
        for row in reader:
            try:
                if int(row["IO_Size"]) != io_size:
                    continue
                if int(row["QD"]) != qd:
                    continue
                rec: Dict[str, float] = {}
                for k in (["IOPS", "Submit_Logic_ns", "Completion_Logic_ns",
                           "Submit_Preamble_ns", "Tracker_Alloc_ns", "Addr_Xlate_ns",
                           "Cmd_Construct_ns", "Fence_ns", "Doorbell_ns",
                           "CQE_Detect_ns", "Tracker_Lookup_ns"]):
                    rec[k] = float(row[k])
                if has_split:
                    rec["State_Dealloc_Library_ns"]  = float(row["State_Dealloc_Library_ns"])
                    rec["State_Dealloc_Callback_ns"] = float(row["State_Dealloc_Callback_ns"])
                else:
                    rec["State_Dealloc_Library_ns"]  = float(row.get("State_Dealloc_ns", 0))
                    rec["State_Dealloc_Callback_ns"] = 0.0
                rows.append(rec)
            except (KeyError, ValueError):
                continue

    if not rows:
        return None

    avg: Dict[str, float] = {}
    for k in rows[0].keys():
        avg[k] = sum(r[k] for r in rows) / len(rows)
    avg["software_path_ns"] = avg["Submit_Logic_ns"] + avg["Completion_Logic_ns"]
    avg["Other_SPDK_ns"] = max(0.0, avg["software_path_ns"] - sum(avg[s] for s in NAMED_STAGES))
    return avg


def find_first_csv(results_root: str, tag_glob: str) -> Optional[str]:
    pattern = os.path.join(results_root, tag_glob, "core*_qp*", "phase1_results.csv")
    matches = sorted(glob.glob(pattern))
    return matches[0] if matches else None


def plot_compare(synthetic: Dict[str, float], trace: Dict[str, float],
                 out_path: str, qd: int, io_size: int) -> None:
    fig, (ax_bar, ax_iops) = plt.subplots(1, 2, figsize=(11, 4),
                                          gridspec_kw={"width_ratios": [3, 1]})

    # Left: stacked-bar per-stage breakdown, two bars (synthetic vs trace)
    labels = ["Synthetic\n(4 KB random)", "Trace replay\n(BigANN/DiskANN)"]
    x = list(range(2))
    bottoms = [0.0, 0.0]
    for stage, color in zip(NAMED_STAGES, STAGE_PALETTE):
        vals = [synthetic[stage], trace[stage]]
        ax_bar.bar(x, vals, bottom=bottoms, color=color, edgecolor="white",
                   linewidth=0.5, label=stage.replace("_ns", ""))
        bottoms = [bo + v for bo, v in zip(bottoms, vals)]
    other = [synthetic["Other_SPDK_ns"], trace["Other_SPDK_ns"]]
    ax_bar.bar(x, other, bottom=bottoms, color=OTHER_COLOR, edgecolor="white",
               linewidth=0.5, label="Other SPDK overhead", hatch="//")

    ax_bar.set_xticks(x)
    ax_bar.set_xticklabels(labels)
    ax_bar.set_ylabel(f"Per-IO software path (ns)  --  cycles at {CPU_GHZ} GHz")
    ax_bar.set_title(f"Synthetic vs Trace cycles/IO  (QD={qd}, {io_size} B)")
    ax_bar.legend(loc="upper right", ncol=2, fontsize=7, frameon=True)

    for i, (label, rec) in enumerate(zip(labels, [synthetic, trace])):
        total = rec["software_path_ns"]
        cycles = total * CPU_GHZ
        ax_bar.text(i, total + 30, f"{total:.0f} ns\n({cycles:.0f} cyc)",
                    ha="center", va="bottom", fontsize=8, color="#333333")

    pct_diff = 100 * (trace["software_path_ns"] - synthetic["software_path_ns"]) / synthetic["software_path_ns"]
    ax_bar.text(0.5, -0.18, f"trace vs synthetic: {pct_diff:+.1f}%",
                transform=ax_bar.transAxes, ha="center", fontsize=9,
                color=("#2ca02c" if abs(pct_diff) < 10 else "#d62728"))

    # Right: IOPS comparison
    iops_vals = [synthetic["IOPS"], trace["IOPS"]]
    ax_iops.bar(x, iops_vals, color=["#1f77b4", "#d62728"])
    ax_iops.set_xticks(x)
    ax_iops.set_xticklabels(["Synth", "Trace"], fontsize=8)
    ax_iops.set_ylabel("IOPS")
    ax_iops.set_title("IOPS")
    for i, v in enumerate(iops_vals):
        ax_iops.text(i, v, f"{v:,.0f}", ha="center", va="bottom", fontsize=8)

    plt.tight_layout()
    os.makedirs(PLOTS_DIR, exist_ok=True)
    fig.savefig(out_path + ".png", dpi=180)
    fig.savefig(out_path + ".pdf")
    print(f"wrote {out_path}.png and {out_path}.pdf")
    print(f"\nVerdict (cycles/IO):")
    print(f"  synthetic : {synthetic['software_path_ns']:.1f} ns/IO")
    print(f"  trace     : {trace['software_path_ns']:.1f} ns/IO")
    print(f"  delta     : {pct_diff:+.1f}%  ({'within ±10% — paper claim holds' if abs(pct_diff) < 10 else 'exceeds ±10% — investigate'})")


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--results", default="results/phase1_runs",
                   help="Directory under which both sweep tags live")
    p.add_argument("--synthetic-tag", default="paper_qdsweep_mode0",
                   help="Run tag for the synthetic 4 KB random read sweep")
    p.add_argument("--trace-tag", default="paper_trace_mode0",
                   help="Run tag for the trace-replay sweep")
    p.add_argument("--qd", type=int, default=128)
    p.add_argument("--io-size", type=int, default=4096)
    p.add_argument("--out", default=os.path.join(PLOTS_DIR, "trace_vs_synthetic"))
    args = p.parse_args()

    syn_csv = find_first_csv(args.results, args.synthetic_tag)
    tr_csv  = find_first_csv(args.results, args.trace_tag)

    if not syn_csv:
        sys.exit(f"No synthetic-sweep phase1_results.csv under {args.results}/{args.synthetic_tag}")
    if not tr_csv:
        sys.exit(f"No trace-replay phase1_results.csv under {args.results}/{args.trace_tag}")

    synthetic = load_csv(syn_csv, args.qd, args.io_size)
    trace = load_csv(tr_csv, args.qd, args.io_size)

    if not synthetic:
        sys.exit(f"No matching (QD={args.qd}, IO={args.io_size}) row in {syn_csv}")
    if not trace:
        sys.exit(f"No matching (QD={args.qd}, IO={args.io_size}) row in {tr_csv}")

    plot_compare(synthetic, trace, args.out, qd=args.qd, io_size=args.io_size)


if __name__ == "__main__":
    main()
