"""Generate Figure 3: cycles/IO + DRAM-bytes/IO bracket vs qpairs.

Overlays three regimes (SPDK baseline / Mode 2A / Mode 2B) on a single chart:
  - left y-axis  : cycles/IO  = (Submit_Logic_ns + Completion_Logic_ns) * CPU_GHZ
  - right y-axis : DRAM bytes/IO  proxy  = Scans_Per_Completion * 16  (each CQE = 16 B)
  - x-axis       : qpairs (log scale)

The DRAM proxy is necessary because the gem5 guest has no PMU, so the
Dram_Read_Bytes_Per_IO / Dram_Write_Bytes_Per_IO columns are zero. The CQ-scan
proxy lower-bounds the per-IO DRAM traffic from completion-queue polling, which
is the dominant load that Mode 2B is designed to eliminate.

Inputs : results/phase1_runs/<tag>/**/phase1_results.csv  for three tags.
Output : plots/fig3_bracket.{png,pdf}

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

import matplotlib.pyplot as plt

PLOTS_DIR = "plots"
CPU_GHZ = 5.3                 # paper projects to a 5.3 GHz host CPU
CQE_BYTES = 16                # SPDK NVMe CQE size

REGIMES = [
    ("baseline", "SPDK baseline (Mode 0)", "tab:blue", "o", "-"),
    ("modeA",    "Mode 2A (CQ batching)",  "tab:orange", "s", "--"),
    ("modeB",    "Mode 2B (poll-lite)",    "tab:green",  "^", "-."),
]

NEEDED = ["QD", "Qpairs", "IO_Size", "Run_ID", "IOPS",
          "Submit_Logic_ns", "Completion_Logic_ns", "Scans_Per_Completion"]


def load_runs(tag_dir: str, io_size: int, qd: int) -> Dict[int, Dict[str, float]]:
    """Read all CSVs under tag_dir; return mean per (qpairs) at requested QD/IO."""
    by_qp: Dict[int, List[Dict[str, float]]] = defaultdict(list)
    for csv_path in glob.glob(os.path.join(tag_dir, "**/phase1_results.csv"), recursive=True):
        with open(csv_path) as f:
            for row in csv.DictReader(f):
                if not row.get("QD"):
                    continue
                try:
                    if int(row["IO_Size"]) != io_size:
                        continue
                    if int(row["QD"]) != qd:
                        continue
                    rec = {k: float(row[k]) for k in NEEDED}
                    by_qp[int(rec["Qpairs"])].append(rec)
                except (KeyError, ValueError) as e:
                    print(f"[skip] {csv_path}: {e}", file=sys.stderr)
    out: Dict[int, Dict[str, float]] = {}
    for qp, bucket in by_qp.items():
        agg: Dict[str, float] = {}
        for k in NEEDED:
            agg[k] = sum(r[k] for r in bucket) / len(bucket)
        agg["software_path_ns"] = agg["Submit_Logic_ns"] + agg["Completion_Logic_ns"]
        agg["cycles_per_io"] = agg["software_path_ns"] * CPU_GHZ
        agg["dram_bytes_per_io_proxy"] = agg["Scans_Per_Completion"] * CQE_BYTES
        out[qp] = agg
    return out


def plot(by_regime: Dict[str, Dict[int, Dict[str, float]]],
         out_path: str, qd: int, io_size: int) -> None:
    fig, ax_left = plt.subplots(figsize=(7.0, 4.5))
    ax_right = ax_left.twinx()

    legend_handles_left = []
    legend_handles_right = []

    for tag_key, label, color, marker, linestyle in REGIMES:
        runs = by_regime.get(tag_key, {})
        if not runs:
            print(f"[warn] no data for regime {tag_key}", file=sys.stderr)
            continue
        qps = sorted(runs)
        cycles = [runs[q]["cycles_per_io"] for q in qps]
        dram = [runs[q]["dram_bytes_per_io_proxy"] for q in qps]

        h1, = ax_left.plot(qps, cycles, color=color, marker=marker,
                           linestyle=linestyle, linewidth=2.0,
                           label=f"{label} -- cycles/IO")
        h2, = ax_right.plot(qps, dram, color=color, marker=marker,
                            linestyle=":", linewidth=1.5, alpha=0.7,
                            label=f"{label} -- DRAM B/IO (CQ-scan proxy)")
        legend_handles_left.append(h1)
        legend_handles_right.append(h2)

    ax_left.set_xscale("log", base=2)
    ax_left.set_xlabel("Number of SPDK qpairs (log2 scale)")
    ax_left.set_ylabel(f"Cycles per IO  (at {CPU_GHZ} GHz CPU projection)")
    ax_right.set_ylabel("CQ-scan DRAM bytes per IO  (Scans_Per_Completion x 16 B)")
    ax_left.grid(True, which="both", linestyle="--", alpha=0.3)
    ax_left.set_title(f"Cycles/IO + DRAM-bytes/IO bracket vs qpairs  (QD={qd}, {io_size}B random read)")

    handles = legend_handles_left + legend_handles_right
    ax_left.legend(handles=handles, loc="upper left", fontsize=7, ncol=2, frameon=True)
    plt.tight_layout()

    os.makedirs(PLOTS_DIR, exist_ok=True)
    fig.savefig(out_path + ".png", dpi=180)
    fig.savefig(out_path + ".pdf")
    print(f"wrote {out_path}.png and {out_path}.pdf")


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--results-root", default="results/phase1_runs",
                   help="Parent dir containing the per-tag run dirs")
    p.add_argument("--tag-prefix", default="phase1_paper_20260509_qpsweep",
                   help="Common prefix; appended with _mode0/_mode1/_mode2")
    p.add_argument("--io-size", type=int, default=4096)
    p.add_argument("--qd", type=int, default=128)
    p.add_argument("--out", default=os.path.join(PLOTS_DIR, "fig3_bracket"))
    args = p.parse_args()

    suffix_for = {"baseline": "_mode0", "modeA": "_mode1", "modeB": "_mode2"}
    by_regime: Dict[str, Dict[int, Dict[str, float]]] = {}
    for key, suf in suffix_for.items():
        tag_dir = os.path.join(args.results_root, args.tag_prefix + suf)
        by_regime[key] = load_runs(tag_dir, args.io_size, args.qd)

    if not any(by_regime.values()):
        sys.exit(f"No data found under {args.results_root}/{args.tag_prefix}_mode{{0,1,2}}/")
    plot(by_regime, args.out, qd=args.qd, io_size=args.io_size)


if __name__ == "__main__":
    main()
