#!/usr/bin/env python3
"""
Completion-poll efficiency for paper Section 4.2 (new figure,
fig:poll_efficiency): how many host completion polls the driver spends, and
what fraction are idle scans of an empty completion queue, vanilla SPDK
baseline vs IAU, on the BigANN read trace replay, 1 core / 1 qpair.

Why this figure
---------------
The headline IOPS/cycle numbers are a black box: they say the host does less
per I/O but not where. This figure names the completion-side mechanism. The
driver calls spdk_nvme_qpair_process_completions() in a tight loop; each call
that reaches the completion-queue scan is one "poll". The measured
Completions_Per_Poll histogram shows the baseline burns the overwhelming
majority of its polls scanning an EMPTY queue (bucket 0), because with no
on-die hint it must scan blindly, while IAU's hint-gated poll-lite path skips
those empty scans entirely and every surviving poll drains a full completion
batch. The 128-entry batch ceiling is SPDK's NVME_MAX_COMPLETIONS reap cap
(nvme_pcie_common.c), not an IAU parameter; the IAU result is that it reaches
that cap on every poll while the baseline mostly reaps nothing.

Read-only by construction: on the write and mixed traces the completion rate
per NAND channel is lower, so IAU harvests smaller (non-saturating) batches
(~15 completions/poll, not 128). The idle-poll-elimination story is cleanest
and strongest on the read trace, which is what this figure plots. The op-mix
breadth result lives in fig:qd_sweep_opmix instead.

Data sources (the admissible BigANN read run; all QD rows)
----------------------------------------------------------
  vanilla SPDK baseline:
      results/bigann_trace_1c1qp/paper_trace_mode0_20260510/core0_qp1/phase1_results.csv
  IAU:
      results/bigann_trace_1c1qp/paper_trace_mode2_20260510/core0_qp1/phase1_results.csv

Each row carries a Polls count and a Completions_Per_Poll_Hist string of the
form "0:212820, 1:0, ..., 32+:6280". Bucket 0 is an idle poll (the scan found
no ready CQE); every other bucket is a productive poll. Productive polls are
computed as Polls minus the bucket-0 count so the two segments always sum to
the measured poll total.

Style matches scripts/plot_iau_breakdown.py: serif, grey palette with one
accent (#2b5f8a), black edges, 300 dpi PNG + vector PDF.

Usage
-----
    conda run -n llm python scripts/plot_poll_efficiency.py
    # writes figures/poll_efficiency.pdf and figures/poll_efficiency.png
"""

from __future__ import annotations

import argparse
import csv
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Patch


BASELINE_CSV = ("results/bigann_trace_1c1qp/paper_trace_mode0_20260510/"
                "core0_qp1/phase1_results.csv")
IAU_CSV = ("results/bigann_trace_1c1qp/paper_trace_mode2_20260510/"
           "core0_qp1/phase1_results.csv")
QDS = [16, 32, 64, 128]

GREY_DARK = "#3f3f3f"
GREY_LIGHT = "#a8a8a8"
GREY_LIGHTER = "#cccccc"
ACCENT = "#2b5f8a"
ACCENT_LIGHT = "#9db8d0"


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
        "axes.spines.right": False,
        "xtick.major.width": 0.8,
        "ytick.major.width": 0.8,
        "xtick.direction": "out",
        "hatch.linewidth": 0.6,
        "pdf.fonttype": 42,
        "ps.fonttype": 42,
    })


def empty_polls(hist: str) -> int:
    """Bucket-0 count (idle scans that found no ready completion)."""
    for token in hist.split(","):
        key, _, val = token.strip().partition(":")
        if key == "0":
            return int(val)
    return 0


def load_polls(csv_path: Path) -> dict[int, tuple[float, float]]:
    """QD -> (idle_polls, productive_polls) in thousands."""
    out: dict[int, tuple[float, float]] = {}
    with csv_path.open(newline="") as f:
        for row in csv.DictReader(f):
            if not row.get("QD") or not row.get("Polls"):
                continue
            qd = int(row["QD"])
            total = float(row["Polls"])
            idle = float(empty_polls(row.get("Completions_Per_Poll_Hist", "")))
            productive = max(total - idle, 0.0)
            out[qd] = (idle / 1e3, productive / 1e3)
    return out


def plot(repo_root: Path, out_prefix: Path) -> None:
    configure_style()

    base = load_polls(repo_root / BASELINE_CSV)
    iau = load_polls(repo_root / IAU_CSV)

    fig, ax = plt.subplots(figsize=(3.4, 2.5))

    xs = list(range(len(QDS)))
    width = 0.36
    off = width / 2 + 0.01

    for x, qd in zip(xs, QDS):
        b_idle, b_prod = base[qd]
        u_idle, u_prod = iau[qd]

        # Baseline: productive (dark grey) with idle scans stacked on top
        # (light grey, hatched) -- the wasted-scan mass.
        ax.bar(x - off, b_prod, width, color=GREY_DARK, edgecolor="black",
               linewidth=0.6, zorder=3)
        ax.bar(x - off, b_idle, width, bottom=b_prod, color=GREY_LIGHTER,
               edgecolor="black", linewidth=0.6, hatch="////", zorder=3)

        # IAU: productive (accent), idle ~ 0 (light accent, hatched).
        ax.bar(x + off, u_prod, width, color=ACCENT, edgecolor="black",
               linewidth=0.6, zorder=3)
        ax.bar(x + off, u_idle, width, bottom=u_prod, color=ACCENT_LIGHT,
               edgecolor="black", linewidth=0.6, hatch="////", zorder=3)

        # Annotate the baseline idle fraction and the poll-count reduction.
        b_total = b_idle + b_prod
        u_total = u_idle + u_prod
        if b_total > 0:
            ax.text(x - off, b_total + 8, f"{100 * b_idle / b_total:.0f}%\nidle",
                    ha="center", va="bottom", fontsize=6.0, color=GREY_DARK)
        if u_total > 0:
            ax.text(x + off, u_total + 8, f"{b_total / u_total:.0f}×\nfewer",
                    ha="center", va="bottom", fontsize=6.0, color=ACCENT)

    ax.set_xticks(xs)
    ax.set_xticklabels([str(q) for q in QDS])
    ax.set_xlim(-0.6, len(QDS) - 0.4)
    ymax = max(sum(base[q]) for q in QDS)
    ax.set_ylim(0, ymax * 1.30)
    ax.set_xlabel("Queue depth")
    ax.set_ylabel("Completion polls (thousands)")
    ax.yaxis.grid(True, linestyle=":", linewidth=0.5, color=GREY_LIGHTER)
    ax.set_axisbelow(True)
    ax.tick_params(axis="x", length=0)

    handles = [
        Patch(facecolor=GREY_DARK, edgecolor="black", linewidth=0.6,
              label="Baseline"),
        Patch(facecolor=ACCENT, edgecolor="black", linewidth=0.6,
              label="IAU"),
        Patch(facecolor="white", edgecolor="black", linewidth=0.6,
              hatch="////", label="idle poll (0 cpl)"),
    ]
    ax.legend(handles=handles, loc="upper right", frameon=False,
              handlelength=1.4, handletextpad=0.5, borderaxespad=0.2,
              labelspacing=0.3)

    fig.tight_layout()
    out_prefix.parent.mkdir(parents=True, exist_ok=True)
    pdf_path = out_prefix.with_suffix(".pdf")
    png_path = out_prefix.with_suffix(".png")
    fig.savefig(pdf_path, bbox_inches="tight", pad_inches=0.05)
    fig.savefig(png_path, dpi=300, bbox_inches="tight", pad_inches=0.05)
    plt.close(fig)

    print(f"wrote {pdf_path}")
    print(f"wrote {png_path}")
    for qd in QDS:
        b_idle, b_prod = base[qd]
        u_idle, u_prod = iau[qd]
        b_total, u_total = b_idle + b_prod, u_idle + u_prod
        print(f"  QD={qd:<4d} baseline {b_total:7.1f}K polls "
              f"({100 * b_idle / b_total:4.1f}% idle)   "
              f"IAU {u_total:6.1f}K polls "
              f"({100 * u_idle / u_total:4.1f}% idle)   "
              f"{b_total / u_total:4.1f}x fewer")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out", default="figures/poll_efficiency",
        help="Output path prefix without extension "
             "(default: figures/poll_efficiency)",
    )
    args = parser.parse_args()
    repo_root = Path(__file__).resolve().parent.parent
    plot(repo_root, (repo_root / args.out).resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
