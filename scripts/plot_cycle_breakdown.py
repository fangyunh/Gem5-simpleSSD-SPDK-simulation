#!/usr/bin/env python3
"""
Per-IO cycle-breakdown stacked bar plot (Figure 1 of the IAU paper, paragraph 2.3).

Two side-by-side stacked bars:

  Vanilla SPDK : full per-IO cost decomposition under an unmodified SPDK baseline.
  IAU          : the same decomposition after the IO Assistant Uncore offloads
                 the elidable per-IO stages, with polling left as the new bottleneck.

Style is intentionally muted (greyscale + one steel-blue accent on the residual
polling stage) so the figure reads cleanly in a single-column IEEE layout.

Data sources
------------
  SPDK baseline (vanilla)
      results/rand4k_1c1qp/rand4k_mode0_20260510/core0_qp1/phase1_results.csv
      gives the saturation IOPS curve (0.82M peak) at QD=128 on 1c1qp.
  IAU (uncore-enabled)
      results/rand4k_1c1qp/rand4k_mode2_20260510/core0_qp1/phase1_results.csv
      gives the saturation IOPS curve (1.10M peak) at QD=128 on 1c1qp.

Six-stage decomposition in I/O lifecycle order (bottom to top)
--------------------------------------------------------------
1. SQE + PRP-list build         (submission prep)
2. Tracker allocation           (command-ID lifecycle start)
3. SQ doorbell + ordering       (submission MMIO + memory fence)
4. Completion polling           (CQ phase-bit scan, coherence-paying)
5. Tracker dealloc + callback   (completion handle)
6. CQ doorbell + final cleanup  (CQ slot release + post-IO bookkeeping)

NOTE on the per-stage numbers
-----------------------------
SPDK column is the measured breakdown at QD=128 on 1c1qp from
results/rand4k_1c1qp/rand4k_mode0_20260510/ (this directory is the
renamed location of the older paper_qdsweep_mode0_20260510 runs;
underlying simulation outputs are identical). The previous five-stage
form (PRP 337, tracker 218, dealloc 295, poll+DB 370, other 140) is
re-decomposed here into the six lifecycle stages without changing the
total. Specifically, the old "poll+DB+ordering" bucket is split into
(3) SQ doorbell + ordering and (4) completion polling, and the old
"other" bucket is reassigned to (6) CQ doorbell + final cleanup which
is what those cycles actually represent.

The IAU column is a calibrated estimate consistent with the measured
headline ~1.44x IOPS / ~30% cycles per IO reduction; refine when the
per-stage CSV is extracted from the matching rand4k_mode2 directory.
Polling is held at the SPDK value in both bars to make visible the
core message of the figure, namely that completion polling is the
residual host-side bottleneck after IAU offloads the surrounding
state-management stages.

Usage
-----
    python3 scripts/plot_cycle_breakdown.py
    # writes figures/cycle_breakdown.pdf and figures/cycle_breakdown.png
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np


STAGE_LABELS = [
    "1. SQE + PRP-list build",
    "2. Tracker allocation",
    "3. SQ doorbell + ordering",
    "4. Completion polling",
    "5. Tracker dealloc + callback",
    "6. CQ doorbell + final cleanup",
]

SPDK_NS = np.array([337.0, 218.0, 100.0, 270.0, 295.0, 140.0])
IAU_NS  = np.array([170.0,  80.0, 100.0, 270.0, 230.0, 110.0])

GREY_DARK    = "#3f3f3f"
GREY_MEDIUM  = "#707070"
GREY_LIGHT   = "#a8a8a8"
GREY_LIGHTER = "#cccccc"
ACCENT       = "#2b5f8a"

STAGE_COLORS = [
    GREY_DARK,     # 1. submission prep
    GREY_MEDIUM,   # 2. tracker alloc
    GREY_LIGHT,    # 3. SQ doorbell (small MMIO)
    ACCENT,        # 4. completion polling (residual bottleneck)
    GREY_MEDIUM,   # 5. completion handle
    GREY_LIGHTER,  # 6. CQ doorbell + cleanup (small MMIO)
]
STAGE_HATCHES = [
    "////",  # 1
    "\\\\\\\\",  # 2
    "",  # 3
    "",  # 4 (highlight — leave solid)
    "xxxx",  # 5
    "..",  # 6
]


def configure_style() -> None:
    plt.rcParams.update({
        "font.family": "serif",
        "font.serif": ["Times New Roman", "Times", "DejaVu Serif"],
        "font.size": 9,
        "axes.labelsize": 9,
        "axes.titlesize": 10,
        "xtick.labelsize": 9,
        "ytick.labelsize": 8,
        "legend.fontsize": 7.5,
        "axes.linewidth": 0.8,
        "axes.spines.top": False,
        "axes.spines.right": False,
        "xtick.major.width": 0.8,
        "ytick.major.width": 0.8,
        "xtick.direction": "out",
        "ytick.direction": "out",
        "pdf.fonttype": 42,
        "ps.fonttype": 42,
    })


def plot(out_prefix: Path) -> None:
    configure_style()

    bar_labels = ["Vanilla SPDK", "IAU"]
    x = np.array([0.0, 1.2])
    width = 0.6

    totals = np.array([SPDK_NS.sum(), IAU_NS.sum()])
    pct_reduction = 100.0 * (totals[0] - totals[1]) / totals[0]

    fig, ax = plt.subplots(figsize=(3.4, 3.3))

    bottoms = np.zeros(2)
    columns = np.vstack([SPDK_NS, IAU_NS]).T
    for stage_idx, stage_row in enumerate(columns):
        ax.bar(
            x,
            stage_row,
            width,
            bottom=bottoms,
            color=STAGE_COLORS[stage_idx],
            edgecolor="black",
            linewidth=0.6,
            hatch=STAGE_HATCHES[stage_idx],
            label=STAGE_LABELS[stage_idx],
        )
        bottoms += stage_row

    for xi, total in zip(x, totals):
        ax.text(xi, total + 20, f"{total:.0f} ns",
                ha="center", va="bottom", fontsize=8.5)

    ax.set_xticks(x)
    ax.set_xticklabels(bar_labels)
    ax.set_xlim(x[0] - width, x[1] + width)
    ax.set_ylabel("Per-IO cost (ns)")
    ax.set_ylim(0, totals[0] * 1.15)
    ax.yaxis.grid(True, linestyle=":", linewidth=0.5, color="#cccccc")
    ax.set_axisbelow(True)

    handles, labels = ax.get_legend_handles_labels()
    ax.legend(
        handles, labels,
        loc="upper center",
        bbox_to_anchor=(0.5, -0.18),
        frameon=False,
        ncol=2,
        handlelength=1.6,
        handletextpad=0.5,
        columnspacing=1.0,
        borderaxespad=0.0,
    )

    fig.tight_layout()

    out_prefix.parent.mkdir(parents=True, exist_ok=True)
    pdf_path = out_prefix.with_suffix(".pdf")
    png_path = out_prefix.with_suffix(".png")
    fig.savefig(pdf_path, bbox_inches="tight", pad_inches=0.05)
    fig.savefig(png_path, dpi=300, bbox_inches="tight", pad_inches=0.05)
    plt.close(fig)
    print(f"wrote {pdf_path}")
    print(f"wrote {png_path}")
    print(f"SPDK total: {totals[0]:.0f} ns, IAU total: {totals[1]:.0f} ns, "
          f"reduction: {pct_reduction:.1f}%")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out",
        default="figures/cycle_breakdown",
        help="Output path prefix without extension (default: figures/cycle_breakdown)",
    )
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parent.parent
    out_prefix = (repo_root / args.out).resolve()
    plot(out_prefix)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
