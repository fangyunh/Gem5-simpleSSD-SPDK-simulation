#!/usr/bin/env python3
"""
Queue-depth sweep for paper Section 4.2 (Figure F3, fig:qd_sweep): IOPS
versus queue depth, vanilla SPDK baseline vs IAU, on the DiskANN BigANN
trace replay, 1 core / 1 qpair.

This is the headline results figure. The load-bearing visual is the flat IAU
IOPS curve: IAU saturates the host core at ~1.102 M IOPS for every queue
depth, well above the baseline that only inches from 763 K to 804 K across an
8x queue-depth increase, identifying IAU as a new CPU-bound ceiling.

Only IOPS is plotted. Cycles/IO is the exact inverse of IOPS (clock / IOPS),
so a second axis would duplicate the same two curves, and its IAU line would
overlap the baseline IOPS line and invite misreading; the per-stage cycle
story already lives in fig:iau_breakdown. The cycles/IO equivalents are still
printed to stdout for the prose in Section 4.

Data sources (the admissible BigANN trace runs; all QD rows)
------------------------------------------------------------
  vanilla SPDK baseline:
      results/bigann_trace_1c1qp/paper_trace_mode0_20260510/core0_qp1/phase1_results.csv
  IAU:
      results/bigann_trace_1c1qp/paper_trace_mode2_20260510/core0_qp1/phase1_results.csv

The transparent-IAU ablation (mode 1) is deliberately not plotted, per the
Section 4 outline: its shallow-QD dip is a one-sentence ablation, not a curve.

Methodology
-----------
Cycles per I/O is derived at the host clock, not read from a hardware
counter (the CSV Cycles/Instructions columns are 0 under AtomicSimpleCPU).
At saturation the single host core is ~100% busy on the I/O path, so

    cycles/IO = HOST_HZ / IOPS

with HOST_HZ = 2 GHz, the gem5 AtomicSimpleCPU clock used throughout the
evaluation. This is the same per-IO budget Section 4.1 reports (baseline
2e9 / 819,253 = 2,441 cycles/IO at QD=128).

Style matches scripts/plot_cycle_breakdown.py and scripts/plot_iau_breakdown.py:
serif, grey palette with one accent (#2b5f8a), 300 dpi PNG + vector PDF.

Usage
-----
    conda run -n llm python scripts/plot_qd_sweep.py
    # writes figures/qd_sweep.pdf and figures/qd_sweep.png
"""

from __future__ import annotations

import argparse
import csv
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


BASELINE_CSV = ("results/bigann_trace_1c1qp/paper_trace_mode0_20260510/"
                "core0_qp1/phase1_results.csv")
IAU_CSV = ("results/bigann_trace_1c1qp/paper_trace_mode2_20260510/"
           "core0_qp1/phase1_results.csv")
HOST_HZ = 2.0e9

GREY_DARK = "#3f3f3f"
GREY_LIGHT = "#a8a8a8"
GREY_LIGHTER = "#cccccc"
ACCENT = "#2b5f8a"


def configure_style() -> None:
    plt.rcParams.update({
        "font.family": "serif",
        "font.serif": ["Times New Roman", "Times", "DejaVu Serif"],
        "font.size": 9,
        "axes.labelsize": 9,
        "xtick.labelsize": 8,
        "ytick.labelsize": 8,
        "legend.fontsize": 7.0,
        "axes.linewidth": 0.8,
        "axes.spines.top": False,
        "xtick.major.width": 0.8,
        "ytick.major.width": 0.8,
        "xtick.direction": "out",
        "pdf.fonttype": 42,
        "ps.fonttype": 42,
    })


def load_sweep(csv_path: Path) -> tuple[list[int], list[float], list[float]]:
    qds: list[int] = []
    iops: list[float] = []
    cyc: list[float] = []
    with csv_path.open(newline="") as f:
        for row in csv.DictReader(f):
            if not row.get("QD") or not row.get("IOPS"):
                continue
            qd = int(row["QD"])
            rate = float(row["IOPS"])
            qds.append(qd)
            iops.append(rate / 1e6)
            cyc.append(HOST_HZ / rate)
    order = sorted(range(len(qds)), key=lambda i: qds[i])
    return ([qds[i] for i in order],
            [iops[i] for i in order],
            [cyc[i] for i in order])


def plot(repo_root: Path, out_prefix: Path) -> None:
    configure_style()

    qd, base_iops, base_cyc = load_sweep(repo_root / BASELINE_CSV)
    _, iau_iops, iau_cyc = load_sweep(repo_root / IAU_CSV)

    fig, ax_iops = plt.subplots(figsize=(3.4, 2.5))

    # IOPS only. Cycles/IO is omitted because it is the exact inverse of IOPS
    # (clock / IOPS), so plotting it duplicates the same curves and its IAU
    # line overlaps the baseline IOPS line; the per-stage cycle story already
    # lives in fig:iau_breakdown.
    ax_iops.plot(qd, iau_iops, color=ACCENT, marker="s", markersize=5,
                 linewidth=1.6, label="IAU", zorder=4)
    ax_iops.plot(qd, base_iops, color=GREY_DARK, marker="o", markersize=5,
                 linewidth=1.6, label="Baseline", zorder=4)

    ax_iops.set_xscale("log", base=2)
    ax_iops.set_xticks(qd)
    ax_iops.set_xticklabels([str(q) for q in qd])
    ax_iops.set_xlim(qd[0] / 1.3, qd[-1] * 1.3)
    ax_iops.set_xlabel("Queue depth")

    ax_iops.set_ylabel("IOPS (millions)")
    # Axis zoomed to the data region (not zero-based) so the 1.35x gap is
    # visible instead of compressed against a zero baseline.
    ax_iops.set_ylim(0.70, 1.20)
    ax_iops.spines["right"].set_visible(False)
    ax_iops.yaxis.grid(True, linestyle=":", linewidth=0.5, color=GREY_LIGHTER)
    ax_iops.set_axisbelow(True)

    # Legend below the plot, one row, identifying each line.
    ax_iops.legend(loc="upper center", bbox_to_anchor=(0.5, -0.30),
                   frameon=False, ncol=2, handlelength=1.8,
                   handletextpad=0.5, columnspacing=2.0)

    fig.tight_layout()
    out_prefix.parent.mkdir(parents=True, exist_ok=True)
    pdf_path = out_prefix.with_suffix(".pdf")
    png_path = out_prefix.with_suffix(".png")
    fig.savefig(pdf_path, bbox_inches="tight", pad_inches=0.05)
    fig.savefig(png_path, dpi=300, bbox_inches="tight", pad_inches=0.05)
    plt.close(fig)

    print(f"wrote {pdf_path}")
    print(f"wrote {png_path}")
    for q, bi, ii, bc, ic in zip(qd, base_iops, iau_iops, base_cyc, iau_cyc):
        print(f"  QD={q:<4d} baseline {bi:.3f} M / {bc:6.0f} cyc   "
              f"IAU {ii:.3f} M / {ic:6.0f} cyc   lift {ii / bi:.3f}x")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out", default="figures/qd_sweep",
        help="Output path prefix without extension "
             "(default: figures/qd_sweep)",
    )
    args = parser.parse_args()
    repo_root = Path(__file__).resolve().parent.parent
    plot(repo_root, repo_root / args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
