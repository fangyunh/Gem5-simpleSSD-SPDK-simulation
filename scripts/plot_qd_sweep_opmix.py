#!/usr/bin/env python3
"""
Op-mix robustness for paper Section 4.3 (new figure, fig:qd_sweep_opmix): IOPS
versus queue depth, vanilla SPDK baseline vs IAU, for two op-mixes of the
BigANN trace replay -- read-only and 50/50 read-write -- 1 core / 1 qpair.

Why this figure
---------------
fig:qd_sweep shows the read result alone. This companion shows the IAU
speedup is not a read-only artifact: replaying the identical BigANN address
stream with the operation byte changed, IAU still lifts the mixed op stream
above its baseline. The load-bearing visual is that both IAU curves (solid)
sit clearly above both baseline curves (dashed). The read IAU curve reaches
the highest ceiling (~1.10 M IOPS); the mixed IAU curve sits lower
(~0.89-0.98 M). The smaller mixed multiplier (1.12-1.18x vs 1.37-1.44x read)
is the point Section 4 explains: read completions arrive in dense batches the
IAU completion path reaps whole, while any write in the stream spaces those
completions out, so the mixed workload is reaped in small batches and gains
less.

Write-only is intentionally NOT drawn. It lands almost exactly on the mixed
50/50 curve (they differ only in the third significant figure at every queue
depth), so a third line would overlap the mixed line and add clutter with no
information. That write and 50/50 mixed coincide is itself the finding: a
single write in the stream already collapses the completion pattern onto the
write-like regime, so the mix does not sit halfway between read and write. The
stdout summary still prints all three op-mixes for the prose.

Data sources (the admissible BigANN op-mix runs; all QD rows)
-------------------------------------------------------------
  read   baseline: results/bigann_trace_1c1qp/paper_trace_mode0_20260510/core0_qp1/phase1_results.csv
  read   IAU:      results/bigann_trace_1c1qp/paper_trace_mode2_20260510/core0_qp1/phase1_results.csv
  rw50   baseline: results/bigann_rw50_1c1qp/bigann_rw50_mode0_20260624/core0_qp1/phase1_results.csv
  rw50   IAU:      results/bigann_rw50_1c1qp/bigann_rw50_mode2_20260624/core0_qp1/phase1_results.csv

The write and rw50 datasets were admitted 2026-07-06 (see CLAUDE.md); they
reuse the canonical read trace's offset/size stream with only the op byte
flipped, so op-mix is the sole independent variable.

Encoding: workload by color (read = accent, mixed = dark grey), mode by line
style (IAU = solid + filled marker, baseline = dashed + open marker). Style
otherwise matches scripts/plot_qd_sweep.py: serif, grey palette with one
accent (#2b5f8a), 300 dpi PNG + vector PDF.

Usage
-----
    conda run -n llm python scripts/plot_qd_sweep_opmix.py
    # writes figures/qd_sweep_opmix.pdf and figures/qd_sweep_opmix.png
"""

from __future__ import annotations

import argparse
import csv
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D


GREY_DARK = "#3f3f3f"
GREY_LIGHT = "#a8a8a8"
GREY_LIGHTER = "#cccccc"
ACCENT = "#2b5f8a"
HOST_HZ = 2.0e9

# (label, colour, baseline csv, IAU csv, marker)
#
# Write-only is intentionally omitted: it lands almost exactly on the Mixed
# 50/50 curve (both baseline and IAU differ only in the third significant
# figure), so drawing it adds a redundant overlapping line without adding
# information. The write == mix coincidence is the finding, not a curve worth
# plotting twice; the two retained curves give the clean read-vs-mixed view.
WORKLOADS = [
    ("Read", ACCENT,
     "results/bigann_trace_1c1qp/paper_trace_mode0_20260510/core0_qp1/phase1_results.csv",
     "results/bigann_trace_1c1qp/paper_trace_mode2_20260510/core0_qp1/phase1_results.csv",
     "s"),
    ("Mixed 50/50", GREY_DARK,
     "results/bigann_rw50_1c1qp/bigann_rw50_mode0_20260624/core0_qp1/phase1_results.csv",
     "results/bigann_rw50_1c1qp/bigann_rw50_mode2_20260624/core0_qp1/phase1_results.csv",
     "o"),
]


def configure_style() -> None:
    plt.rcParams.update({
        "font.family": "serif",
        "font.serif": ["Times New Roman", "Times", "DejaVu Serif"],
        "font.size": 9,
        "axes.labelsize": 9,
        "xtick.labelsize": 8,
        "ytick.labelsize": 8,
        "legend.fontsize": 6.5,
        "axes.linewidth": 0.8,
        "axes.spines.top": False,
        "xtick.major.width": 0.8,
        "ytick.major.width": 0.8,
        "xtick.direction": "out",
        "pdf.fonttype": 42,
        "ps.fonttype": 42,
    })


def load_sweep(csv_path: Path) -> tuple[list[int], list[float]]:
    qds: list[int] = []
    iops: list[float] = []
    with csv_path.open(newline="") as f:
        for row in csv.DictReader(f):
            if not row.get("QD") or not row.get("IOPS"):
                continue
            qds.append(int(row["QD"]))
            iops.append(float(row["IOPS"]) / 1e6)
    order = sorted(range(len(qds)), key=lambda i: qds[i])
    return [qds[i] for i in order], [iops[i] for i in order]


def plot(repo_root: Path, out_prefix: Path) -> None:
    configure_style()

    fig, ax = plt.subplots(figsize=(3.4, 2.6))

    qd_ref: list[int] = []
    summary: list[str] = []
    for label, colour, base_csv, iau_csv, marker in WORKLOADS:
        qd, base_iops = load_sweep(repo_root / base_csv)
        _, iau_iops = load_sweep(repo_root / iau_csv)
        qd_ref = qd

        ax.plot(qd, iau_iops, color=colour, marker=marker, markersize=4.5,
                linewidth=1.5, linestyle="-", zorder=4)
        ax.plot(qd, base_iops, color=colour, marker=marker, markersize=4.5,
                markerfacecolor="white", linewidth=1.3, linestyle="--",
                zorder=3)

        for q, bi, ii in zip(qd, base_iops, iau_iops):
            summary.append(f"  {label:<12s} QD={q:<4d} baseline {bi:.3f} M   "
                           f"IAU {ii:.3f} M   lift {ii / bi:.3f}x")

    ax.set_xscale("log", base=2)
    ax.set_xticks(qd_ref)
    ax.set_xticklabels([str(q) for q in qd_ref])
    ax.set_xlim(qd_ref[0] / 1.3, qd_ref[-1] * 1.3)
    ax.set_xlabel("Queue depth")

    ax.set_ylabel("IOPS (millions)")
    ax.set_ylim(0.70, 1.20)
    ax.spines["right"].set_visible(False)
    ax.yaxis.grid(True, linestyle=":", linewidth=0.5, color=GREY_LIGHTER)
    ax.set_axisbelow(True)

    # Two-part legend: workload colour, then mode line style.
    workload_handles = [
        Line2D([0], [0], color=c, marker=m, markersize=4.5, linewidth=1.5,
               label=lbl)
        for lbl, c, _, _, m in WORKLOADS
    ]
    mode_handles = [
        Line2D([0], [0], color=GREY_DARK, linewidth=1.5, linestyle="-",
               label="IAU"),
        Line2D([0], [0], color=GREY_DARK, linewidth=1.3, linestyle="--",
               label="Baseline"),
    ]
    ax.legend(handles=workload_handles + mode_handles, loc="upper center",
              bbox_to_anchor=(0.5, -0.28), frameon=False, ncol=4,
              handlelength=1.6, handletextpad=0.4, columnspacing=1.0)

    fig.tight_layout()
    out_prefix.parent.mkdir(parents=True, exist_ok=True)
    pdf_path = out_prefix.with_suffix(".pdf")
    png_path = out_prefix.with_suffix(".png")
    fig.savefig(pdf_path, bbox_inches="tight", pad_inches=0.05)
    fig.savefig(png_path, dpi=300, bbox_inches="tight", pad_inches=0.05)
    plt.close(fig)

    print(f"wrote {pdf_path}")
    print(f"wrote {png_path}")
    for line in summary:
        print(line)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out", default="figures/qd_sweep_opmix",
        help="Output path prefix without extension "
             "(default: figures/qd_sweep_opmix)",
    )
    args = parser.parse_args()
    repo_root = Path(__file__).resolve().parent.parent
    plot(repo_root, (repo_root / args.out).resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
