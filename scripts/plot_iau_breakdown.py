#!/usr/bin/env python3
"""
Per-stage offload-vs-residual comparison for paper Section 4.2 (Figure F4,
fig:iau_breakdown): vanilla SPDK baseline vs IAU on the BigANN trace replay
at QD=128, 1 core / 1 qpair.

Design (grouped per-stage pairs, author decision 2026-06-11, replacing the
offload-overlay draft of the same day)
--------------------------------------------------------------------------
Five groups along the x-axis, one per lifecycle stage; within each group a
vanilla-SPDK bar (grey) sits beside an IAU bar (accent), y-axis is per-IO
time in ns, values annotated above each bar. The side-by-side pairs show
the offload-vs-residual split that Sections 3.1 and 3.2 forward-reference:
the grey-to-accent drop in each group is what IAU absorbed, the surviving
accent height is the application residual. Totals are not drawn (that
comparison is fig:qd_sweep's job); the LaTeX caption states the workload
and the QD=128 totals.

Data sources (the two admissible BigANN runs; QD=128 rows)
----------------------------------------------------------
  vanilla SPDK baseline:
      results/bigann_trace_1c1qp/paper_trace_mode0_20260510/core0_qp1/phase1_results.csv
  IAU:
      results/bigann_trace_1c1qp/paper_trace_mode2_20260510/core0_qp1/phase1_results.csv

Methodology
-----------
Only the QD=128 row is plotted, for the same reason plot_cycle_breakdown.py
records: at low QD several instrumented columns carry device-side wait that
batching masks at higher QD, so QD=128 is the column where the per-stage
numbers represent per-IO CPU work rather than wait.

Unlike plot_cycle_breakdown.py, whose QD=128 stage values descend from an
earlier five-stage estimate (its "SQ doorbell + ordering" / "completion
polling" split of a legacy poll+DB bucket is not traceable to CSV columns),
every value here is computed at runtime from the CSVs:

  1. SQE + PRP-list build   = Submit_Preamble + Addr_Xlate + Cmd_Construct
  2. Tracker allocation     = Tracker_Alloc
  3. SQ doorbell + ordering = Fence + Doorbell
  4. Completion polling     = CQE_Detect + uninstrumented remainder
  5. Tracker dealloc + callback = Tracker_Lookup + State_Dealloc

where the uninstrumented remainder is (1e9 / IOPS) minus the sum of all
instrumented stage columns, i.e. the poll-loop and run-loop framework time
the per-stage instrumentation does not attribute. Folding it into stage 4 is
the same judgment the F1 script applies; here it is explicit and recomputed
from the CSVs. Each column's total therefore equals the measured per-IO
budget exactly (baseline 1e9/803,840 IOPS = 1244 ns; IAU 1e9/1,101,905 IOPS
= 908 ns; -27% at QD=128). The paper's headline ~30% / 1.44x figures are the
QD=16 point and live in prose, not in this figure.

Stage 1 includes Cmd_Construct, which rises slightly under IAU (57 -> 65 ns,
the SQE encode replaced by the compact-descriptor build); the group still
falls because the PRP expansion (Addr_Xlate 357 -> 157 ns) moves on-die.
Stage 3 is ~3 ns in both columns because SPDK already amortizes doorbells at
QD=128 (MMIO_Writes_Per_IO ~ 0.016); the Doorbell Coalescer's benefit is
fewer PCIe transactions, not host cycles, exactly as Section 3.2 states.

No cross-figure number comparison with fig:cycle_breakdown is valid: that
figure is the rand4k workload, this one is the BigANN trace replay.

Style matches scripts/plot_cycle_breakdown.py: serif, grey palette with one
accent (#2b5f8a), black edges, 300 dpi PNG + vector PDF.

Usage
-----
    conda run -n llm python scripts/plot_iau_breakdown.py
    # writes figures/iau_breakdown.pdf and figures/iau_breakdown.png
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
QD = 128

INSTRUMENTED_COLS = [
    "Submit_Preamble_ns", "Tracker_Alloc_ns", "Addr_Xlate_ns",
    "Cmd_Construct_ns", "Fence_ns", "Doorbell_ns",
    "CQE_Detect_ns", "Tracker_Lookup_ns", "State_Dealloc_ns",
]

# Lifecycle order, left to right. "__remainder__" is the uninstrumented
# per-IO budget remainder (see module docstring).
STAGES = [
    ("SQE + PRP\nbuild",
     ["Submit_Preamble_ns", "Addr_Xlate_ns", "Cmd_Construct_ns"]),
    ("Tracker\nalloc.", ["Tracker_Alloc_ns"]),
    ("Doorbell\n+ ordering", ["Fence_ns", "Doorbell_ns"]),
    ("Completion\npolling", ["CQE_Detect_ns", "__remainder__"]),
    ("Dealloc +\ncallback",
     ["Tracker_Lookup_ns", "State_Dealloc_ns"]),
]

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
        "legend.fontsize": 7.5,
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


def load_qd_row(csv_path: Path, qd: int) -> dict[str, float]:
    with csv_path.open(newline="") as f:
        for row in csv.DictReader(f):
            if row.get("QD") and int(row["QD"]) == qd:
                return {k: float(v) for k, v in row.items()
                        if k and v and k != "Completions_Per_Poll_Hist"
                        and not k.startswith("Trace_")}
    raise SystemExit(f"no QD={qd} row in {csv_path}")


def stage_values(row: dict[str, float]) -> tuple[list[float], float]:
    budget = 1e9 / row["IOPS"]
    remainder = budget - sum(row[c] for c in INSTRUMENTED_COLS)
    values = [
        sum(remainder if c == "__remainder__" else row[c] for c in cols)
        for _, cols in STAGES
    ]
    return values, budget


def plot(repo_root: Path, out_prefix: Path) -> None:
    configure_style()

    base, base_total = stage_values(load_qd_row(repo_root / BASELINE_CSV, QD))
    iau, iau_total = stage_values(load_qd_row(repo_root / IAU_CSV, QD))
    pct = 100.0 * (base_total - iau_total) / base_total

    fig, ax = plt.subplots(figsize=(3.4, 2.5))

    n = len(STAGES)
    xs = list(range(n))
    width = 0.36
    off = width / 2 + 0.01

    for x, b, r in zip(xs, base, iau):
        ax.bar(x - off, b, width, color=GREY_LIGHT, edgecolor="black",
               linewidth=0.6, zorder=3)
        ax.bar(x + off, r, width, color=ACCENT, edgecolor="black",
               linewidth=0.6, zorder=3)

    ax.set_xticks(xs)
    ax.set_xticklabels([name for name, _ in STAGES], fontsize=6.5)
    ax.set_xlim(-0.6, n - 0.4)
    ax.set_ylim(0, max(base) * 1.18)
    ax.set_ylabel("Per-IO cost (ns)")
    ax.yaxis.grid(True, linestyle=":", linewidth=0.5, color=GREY_LIGHTER)
    ax.set_axisbelow(True)
    ax.tick_params(axis="x", length=0)
    # no on-figure total: the totals comparison is fig:qd_sweep's job and
    # the caption states the workload and QD=128 totals

    handles = [
        Patch(facecolor=GREY_LIGHT, edgecolor="black", linewidth=0.6,
              label="vanilla SPDK"),
        Patch(facecolor=ACCENT, edgecolor="black", linewidth=0.6,
              label="IAU"),
    ]
    ax.legend(handles=handles, loc="upper right", frameon=False,
              handlelength=1.6, handletextpad=0.5, borderaxespad=0.2)

    fig.tight_layout()
    out_prefix.parent.mkdir(parents=True, exist_ok=True)
    pdf_path = out_prefix.with_suffix(".pdf")
    png_path = out_prefix.with_suffix(".png")
    fig.savefig(pdf_path, bbox_inches="tight", pad_inches=0.05)
    fig.savefig(png_path, dpi=300, bbox_inches="tight", pad_inches=0.05)
    plt.close(fig)

    print(f"wrote {pdf_path}")
    print(f"wrote {png_path}")
    print(f"baseline total {base_total:.1f} ns/IO, IAU total "
          f"{iau_total:.1f} ns/IO, reduction {pct:.1f}% at QD={QD}")
    for (name, _), b, r in zip(STAGES, base, iau):
        print(f"  {name:32s} {b:7.1f} -> {r:7.1f} ns")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out", default="figures/iau_breakdown",
        help="Output path prefix without extension "
             "(default: figures/iau_breakdown)",
    )
    args = parser.parse_args()
    repo_root = Path(__file__).resolve().parent.parent
    plot(repo_root, (repo_root / args.out).resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
