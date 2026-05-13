"""Generate §2 Figure 2: per-IO software-stage breakdown across QD values.

Produces a horizontal stacked-bar chart showing how SPDK's per-IO software path
decomposes into named stages (Submit_Preamble, Tracker_Alloc, ..., State_Dealloc)
plus an "Other SPDK overhead" bucket capturing unaccounted Submit+Completion time.

State_Dealloc is rendered as two adjacent segments:
  * State_Dealloc_Library — pre+post callback library teardown (HW-elidable)
  * State_Dealloc_Callback — application cb_fn execution (kept on CPU)
This split is the §2.1 honest-accounting decomposition described in
docs/PAPER_CHAPTER_PLAN.md.

Inputs: phase1_results.csv files under results/phase1_*/core*_qp*/.
Output: plots/io_stage_breakdown.{png,pdf}

Re-run after retuning fast_ssd.cfg to >=10M IOPS to regenerate Figure 2 for the paper.
Stdlib-only (csv + matplotlib) to avoid pandas/numpy version mismatches.
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
CPU_GHZ = 5.3  # match plot_phase1.py for cycle conversion

SUBMIT_STAGES = [
    "Submit_Preamble_ns",
    "Tracker_Alloc_ns",
    "Addr_Xlate_ns",
    "Cmd_Construct_ns",
    "Fence_ns",
    "Doorbell_ns",
]
# Completion stages: State_Dealloc is split into Library + Callback.
# The legacy State_Dealloc_ns column is kept in the CSV for backward
# compatibility but is NOT plotted (would double-count the library
# pre-callback portion).
COMPLETION_STAGES = [
    "CQE_Detect_ns",
    "Tracker_Lookup_ns",
    "State_Dealloc_Library_ns",
    "State_Dealloc_Callback_ns",
]
NAMED_STAGES = SUBMIT_STAGES + COMPLETION_STAGES

# Colours: tab20 for the regular stages, but Callback gets a distinct
# warning colour so the reader sees it as the non-elidable cycles.
STAGE_PALETTE = list(mpl.colormaps["tab20"].colors[:len(NAMED_STAGES) - 1]) + ["#d62728"]
OTHER_COLOR = "#bbbbbb"


def load_runs(result_dirs: List[str], io_size: int) -> List[Dict[str, float]]:
    """Read named columns from phase1 CSVs into a list of dicts (one per row).

    CSVs from before the State_Dealloc split (no Library/Callback columns)
    are loaded with a fallback: the legacy State_Dealloc_ns is treated as
    100% library, 0 callback. A warning is emitted so the operator knows
    those rows under-report the callback portion.
    """
    out: List[Dict[str, float]] = []
    base_cols = ["QD", "Qpairs", "IO_Size", "Run_ID", "IOPS",
                 "Submit_Logic_ns", "Completion_Logic_ns"]
    optional_cols = {"State_Dealloc_Library_ns", "State_Dealloc_Callback_ns"}
    warned_paths: set = set()
    for d in result_dirs:
        for csv_path in glob.glob(os.path.join(d, "**/phase1_results.csv"), recursive=True):
            with open(csv_path) as f:
                reader = csv.DictReader(f)
                fieldnames = set(reader.fieldnames or [])
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


def aggregate_by_qd(rows: List[Dict[str, float]]) -> List[Tuple[float, Dict[str, float]]]:
    """Group rows by QD; return list of (qd, mean-row) sorted ascending."""
    by_qd: Dict[float, List[Dict[str, float]]] = defaultdict(list)
    for r in rows:
        by_qd[r["QD"]].append(r)

    result: List[Tuple[float, Dict[str, float]]] = []
    for qd in sorted(by_qd):
        bucket = by_qd[qd]
        mean: Dict[str, float] = {}
        for col in (["Submit_Logic_ns", "Completion_Logic_ns", "IOPS"] + NAMED_STAGES):
            mean[col] = sum(r[col] for r in bucket) / len(bucket)
        mean["software_path_ns"] = mean["Submit_Logic_ns"] + mean["Completion_Logic_ns"]
        named_sum = sum(mean[s] for s in NAMED_STAGES)
        mean["Other_SPDK_ns"] = max(0.0, mean["software_path_ns"] - named_sum)
        result.append((qd, mean))
    return result


def plot_breakdown(rows: List[Tuple[float, Dict[str, float]]],
                   out_path: str, io_size: int) -> None:
    if not rows:
        sys.exit(f"No rows with IO_Size={io_size}")

    fig, ax = plt.subplots(figsize=(8.5, max(2.5, 0.7 * len(rows) + 1.5)))
    ax.grid(True, axis="x", linestyle="--", alpha=0.4)
    ax.set_axisbelow(True)

    y = list(range(len(rows)))
    left = [0.0] * len(rows)

    for stage, color in zip(NAMED_STAGES, STAGE_PALETTE):
        vals = [r[1][stage] for r in rows]
        ax.barh(y, vals, left=left, color=color, edgecolor="white",
                linewidth=0.5, label=stage.replace("_ns", ""))
        left = [l + v for l, v in zip(left, vals)]

    other = [r[1]["Other_SPDK_ns"] for r in rows]
    ax.barh(y, other, left=left, color=OTHER_COLOR, edgecolor="white",
            linewidth=0.5, label="Other SPDK overhead", hatch="//")

    ax.set_yticks(y)
    ax.set_yticklabels([f"QD={int(qd)}" for qd, _ in rows])
    ax.invert_yaxis()
    ax.set_xlabel(f"Software path (ns/IO)  --  cycles/IO at {CPU_GHZ} GHz CPU")
    ax.set_title(f"Per-IO software cost decomposition  ({io_size}B random read, SPDK)")

    max_left = 0.0
    for yi, (qd, row) in enumerate(rows):
        total = row["software_path_ns"]
        cycles_5g = total * CPU_GHZ
        iops = row["IOPS"]
        ax.text(total + 25, yi,
                f"{total:.0f} ns  ({cycles_5g:.0f} cyc)  --  {iops:,.0f} IOPS",
                va="center", fontsize=8, color="#333333")
        max_left = max(max_left, total)

    ax.legend(loc="lower right", ncol=2, fontsize=8, frameon=True)
    ax.set_xlim(0, max(max_left * 1.55, 1500))
    plt.tight_layout()

    os.makedirs(PLOTS_DIR, exist_ok=True)
    fig.savefig(out_path + ".png", dpi=180)
    fig.savefig(out_path + ".pdf")
    print(f"wrote {out_path}.png and {out_path}.pdf")


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--results", nargs="+",
                   default=["results/phase1_qd16_iouncore",
                            "results/phase1_qd128_iouncore",
                            "results/phase1_qd128_iouncoreB",
                            "results/phase1_runs"],
                   help="Directories under results/ to scan for phase1_results.csv")
    p.add_argument("--io-size", type=int, default=4096)
    p.add_argument("--out", default=os.path.join(PLOTS_DIR, "io_stage_breakdown"))
    args = p.parse_args()

    rows = load_runs(args.results, args.io_size)
    if not rows:
        sys.exit("No populated phase1_results.csv rows found at the requested IO_Size.")
    agg = aggregate_by_qd(rows)
    plot_breakdown(agg, args.out, io_size=args.io_size)


if __name__ == "__main__":
    main()
