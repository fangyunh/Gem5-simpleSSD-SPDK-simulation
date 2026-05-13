"""Generate the §4.2 multi-core invariance figure.

Shows that the per-IO software-stage breakdown (cycles/IO via SPDK's
nvme_io_cycle instrumentation) is approximately constant across core
counts -- which is the architectural anchor for the §3.1 "shared at I/O
chiplet level, not per-core" placement decision.

Replaces scripts/plot_multicore.py, which depends on host PMU columns
(Cycles, LLC_Misses, ...) that gem5 does not populate. This script reads
the State_Dealloc-split per-stage columns emitted by
phase1_run_multicore_gem5.sh and renders both a stacked-bar breakdown
(one bar per core count) and a flatness check on the total cycles/IO.

Inputs:  phase1_results.csv files under results/phase1_runs/<tag>/core_count*_qp*/
Output:  plots/multicore_invariance.{png,pdf}
"""

from __future__ import annotations

import argparse
import csv
import glob
import os
import sys
from collections import defaultdict
from typing import Dict, List, Tuple

import matplotlib as mpl
import matplotlib.pyplot as plt

PLOTS_DIR = "plots"
CPU_GHZ = 5.3

SUBMIT_STAGES = [
    "Submit_Preamble_ns",
    "Tracker_Alloc_ns",
    "Addr_Xlate_ns",
    "Cmd_Construct_ns",
    "Fence_ns",
    "Doorbell_ns",
]
COMPLETION_STAGES = [
    "CQE_Detect_ns",
    "Tracker_Lookup_ns",
    "State_Dealloc_Library_ns",
    "State_Dealloc_Callback_ns",
]
NAMED_STAGES = SUBMIT_STAGES + COMPLETION_STAGES
STAGE_PALETTE = list(mpl.colormaps["tab20"].colors[:len(NAMED_STAGES) - 1]) + ["#d62728"]
OTHER_COLOR = "#bbbbbb"


def load_runs(result_dirs: List[str], qd: int, io_size: int) -> List[Dict[str, float]]:
    """Read multi-core CSVs into per-row dicts, filtered by (QD, IO_Size)."""
    out: List[Dict[str, float]] = []
    base_cols = ["QD", "Qpairs", "IO_Size", "Run_ID", "Core_Count", "IOPS",
                 "Submit_Logic_ns", "Completion_Logic_ns"]
    optional_cols = {"State_Dealloc_Library_ns", "State_Dealloc_Callback_ns"}
    warned_paths: set = set()
    for d in result_dirs:
        for csv_path in glob.glob(os.path.join(d, "**/phase1_results.csv"), recursive=True):
            with open(csv_path) as f:
                reader = csv.DictReader(f)
                fieldnames = set(reader.fieldnames or [])
                if "Core_Count" not in fieldnames:
                    continue   # skip single-core CSVs
                pre_split_csv = not optional_cols.issubset(fieldnames)
                if pre_split_csv and csv_path not in warned_paths:
                    print(f"[warn] {csv_path} predates State_Dealloc split; "
                          f"treating legacy State_Dealloc_ns as 100% library.",
                          file=sys.stderr)
                    warned_paths.add(csv_path)
                for row in reader:
                    if not row.get("QD"):
                        continue
                    try:
                        if int(row["IO_Size"]) != io_size:
                            continue
                        if int(row["QD"]) != qd:
                            continue
                        rec: Dict[str, float] = {}
                        for k in base_cols + SUBMIT_STAGES + ["CQE_Detect_ns",
                                                              "Tracker_Lookup_ns"]:
                            rec[k] = float(row[k])
                        if pre_split_csv:
                            rec["State_Dealloc_Library_ns"] = float(row["State_Dealloc_ns"])
                            rec["State_Dealloc_Callback_ns"] = 0.0
                        else:
                            rec["State_Dealloc_Library_ns"] = float(row["State_Dealloc_Library_ns"])
                            rec["State_Dealloc_Callback_ns"] = float(row["State_Dealloc_Callback_ns"])
                        rec["__source__"] = os.path.relpath(csv_path)
                        out.append(rec)
                    except (KeyError, ValueError) as e:
                        print(f"[skip row] {csv_path}: {e}", file=sys.stderr)
    return out


def aggregate_by_cores(rows: List[Dict[str, float]]) -> List[Tuple[int, Dict[str, float]]]:
    by_n: Dict[int, List[Dict[str, float]]] = defaultdict(list)
    for r in rows:
        by_n[int(r["Core_Count"])].append(r)
    result: List[Tuple[int, Dict[str, float]]] = []
    for n in sorted(by_n):
        bucket = by_n[n]
        mean: Dict[str, float] = {}
        for col in (["Submit_Logic_ns", "Completion_Logic_ns", "IOPS"] + NAMED_STAGES):
            mean[col] = sum(r[col] for r in bucket) / len(bucket)
        mean["software_path_ns"] = mean["Submit_Logic_ns"] + mean["Completion_Logic_ns"]
        named_sum = sum(mean[s] for s in NAMED_STAGES)
        mean["Other_SPDK_ns"] = max(0.0, mean["software_path_ns"] - named_sum)
        result.append((n, mean))
    return result


def plot_invariance(rows: List[Tuple[int, Dict[str, float]]], out_path: str,
                    qd: int, io_size: int) -> None:
    if not rows:
        sys.exit(f"No multi-core rows with QD={qd}, IO_Size={io_size}")

    fig, (ax_bar, ax_line) = plt.subplots(
        1, 2, figsize=(11, max(2.8, 0.6 * len(rows) + 2.2)),
        gridspec_kw={"width_ratios": [3, 1]})

    # Left panel: stacked-bar per-stage breakdown by core count
    ax_bar.grid(True, axis="x", linestyle="--", alpha=0.4)
    ax_bar.set_axisbelow(True)
    y = list(range(len(rows)))
    left = [0.0] * len(rows)
    for stage, color in zip(NAMED_STAGES, STAGE_PALETTE):
        vals = [r[1][stage] for r in rows]
        ax_bar.barh(y, vals, left=left, color=color, edgecolor="white",
                    linewidth=0.5, label=stage.replace("_ns", ""))
        left = [l + v for l, v in zip(left, vals)]
    other = [r[1]["Other_SPDK_ns"] for r in rows]
    ax_bar.barh(y, other, left=left, color=OTHER_COLOR, edgecolor="white",
                linewidth=0.5, label="Other SPDK overhead", hatch="//")
    ax_bar.set_yticks(y)
    ax_bar.set_yticklabels([f"{n}-core" for n, _ in rows])
    ax_bar.invert_yaxis()
    ax_bar.set_xlabel(f"Per-IO software path (ns)  --  cycles at {CPU_GHZ} GHz")
    ax_bar.set_title(f"Per-core breakdown vs core count  ({io_size} B random read, QD={qd})")
    max_left = 0.0
    for yi, (n, row) in enumerate(rows):
        total = row["software_path_ns"]
        cycles_5g = total * CPU_GHZ
        ax_bar.text(total + 25, yi,
                    f"{total:.0f} ns ({cycles_5g:.0f} cyc)",
                    va="center", fontsize=8, color="#333333")
        max_left = max(max_left, total)
    ax_bar.legend(loc="lower right", ncol=2, fontsize=7, frameon=True)
    ax_bar.set_xlim(0, max(max_left * 1.55, 1500))

    # Right panel: flatness check on total cycles/IO
    counts = [n for n, _ in rows]
    totals = [r[1]["software_path_ns"] for r in rows]
    ref = totals[0] if totals else 1.0
    pct = [100.0 * (t - ref) / ref for t in totals]
    ax_line.axhline(0.0, color="#888888", linestyle="--", linewidth=0.8)
    ax_line.plot(counts, pct, marker="o", color="#1f77b4", linewidth=1.6)
    ax_line.set_xticks(counts)
    ax_line.set_xlabel("Cores")
    ax_line.set_ylabel(f"Δ vs {counts[0]}-core (%)")
    ax_line.set_title("Per-core cycles/IO\nflatness")
    pad = max(5.0, max(abs(p) for p in pct) * 1.4) if pct else 5.0
    ax_line.set_ylim(-pad, pad)
    ax_line.grid(True, linestyle="--", alpha=0.4)

    plt.tight_layout()
    os.makedirs(PLOTS_DIR, exist_ok=True)
    fig.savefig(out_path + ".png", dpi=180)
    fig.savefig(out_path + ".pdf")
    print(f"wrote {out_path}.png and {out_path}.pdf")


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--results", nargs="+",
                   default=["results/phase1_runs"],
                   help="Directories under results/ to scan for multi-core CSVs")
    p.add_argument("--qd", type=int, default=128)
    p.add_argument("--io-size", type=int, default=4096)
    p.add_argument("--out", default=os.path.join(PLOTS_DIR, "multicore_invariance"))
    args = p.parse_args()

    rows = load_runs(args.results, args.qd, args.io_size)
    if not rows:
        sys.exit("No multi-core phase1_results.csv rows found at the requested QD/IO_Size.")
    agg = aggregate_by_cores(rows)
    plot_invariance(agg, args.out, qd=args.qd, io_size=args.io_size)


if __name__ == "__main__":
    main()
