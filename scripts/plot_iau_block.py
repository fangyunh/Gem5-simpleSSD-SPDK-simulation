#!/usr/bin/env python3
"""
IAU block diagram for paper Section 3.1 (Figure F2).

A schematic, not a data plot. It shows the IAU design as it is actually
realized in RTL (RTL_design/src/*.v, synthesized for Section 3.4), placed in
its system context:

  (i)   Placement. IAU sits on the CPU die beside the IMC and the PCIe root
        complex, between the CPU cores running SPDK and the off-die NVMe SSD.
  (ii)  Internal structure (the synthesized modules). Three hot-path engines
        (SQ Engine, CQ Engine, Doorbell Coalescer) over a shared SRAM, with a
        Credit Manager for backpressure and an MMIO Decoder for BAR0 routing.
        The BAR0 host interface of each engine is annotated (mailbox 0x3000,
        status/hint 0x2000, doorbell 0x1000).
  (iii) The DRAM compatibility mirror. SQ/CQ rings stay in DRAM; the uncore
        mirrors them in batches rather than replacing them (a design feature,
        dashed, not measured in Section 4).

The three blue engines are the paper's contribution; the grey blocks are
shared support. Module set matches RTL_design/src: sq_engine, cq_engine,
db_coalescer, credit_manager, sram_arbiter, mmio_decoder (stat_counters,
telemetry only, is omitted for clarity).

Style matches scripts/plot_cycle_breakdown.py: serif font, grey palette with
one blue accent, black edges, 300 dpi PNG. Text is kept deliberately sparse;
the caption in the paper carries the prose.

Usage
-----
    conda run -n llm python scripts/plot_iau_block.py
    # writes figures/iau_block.png
"""

from __future__ import annotations

import argparse
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, Rectangle, Circle
from matplotlib.lines import Line2D


# ---- palette (shared with plot_cycle_breakdown.py) -------------------------
GREY_DARK = "#3f3f3f"
GREY_MED = "#707070"
GREY_LIGHT = "#a8a8a8"
GREY_LIGHTER = "#cccccc"
ACCENT = "#2b5f8a"

FILL_DIE = "#fbfbfb"
FILL_CORES = "#e9e9e9"
FILL_IAU = "#eaf1f8"
FILL_ENGINE = "#d6e3f1"   # hot-path engines (accent tint)
FILL_SUPPORT = "#e7e7e7"  # shared support blocks (grey)
FILL_SRAM = "#dedede"
FILL_PERIPH = "#e9e9e9"
FILL_DEVICE = "#dcdcdc"
FILL_RING = "#ededed"

TEXT = "#1a1a1a"


def configure_style() -> None:
    plt.rcParams.update({
        "font.family": "serif",
        "font.serif": ["Times New Roman", "Times", "DejaVu Serif"],
        "font.size": 8,
        "pdf.fonttype": 42,
        "ps.fonttype": 42,
    })


def rbox(ax, x, y, w, h, *, fill, edge, lw=1.0, ls="solid", round_size=1.3, z=1):
    p = FancyBboxPatch(
        (x, y), w, h,
        boxstyle=f"round,pad=0,rounding_size={round_size}",
        linewidth=lw, edgecolor=edge, facecolor=fill, linestyle=ls,
        mutation_aspect=1.0, zorder=z,
    )
    ax.add_patch(p)
    return p


def sbox(ax, x, y, w, h, *, fill, edge, lw=1.0, z=1):
    p = Rectangle((x, y), w, h, linewidth=lw, edgecolor=edge,
                  facecolor=fill, zorder=z)
    ax.add_patch(p)
    return p


def label(ax, x, y, s, *, size=8, color=TEXT, weight="normal", style="normal",
          ha="center", va="center", rot=0, z=5):
    ax.text(x, y, s, fontsize=size, color=color, fontweight=weight,
            fontstyle=style, ha=ha, va=va, rotation=rot, zorder=z)


def arrow(ax, p0, p1, *, color, lw=1.4, ls="solid", astyle="-|>", z=4):
    ax.annotate(
        "", xy=p1, xytext=p0,
        arrowprops=dict(arrowstyle=astyle, color=color, lw=lw, linestyle=ls,
                        shrinkA=0, shrinkB=0, mutation_scale=7.5),
        zorder=z,
    )


def stepmark(ax, x, y, n, *, r=1.15, z=7):
    """Light numbered badge marking one beat of the per-I/O dataflow.

    White fill + thin accent ring + accent numeral, so it annotates the
    diagram without competing with the block titles.
    """
    ax.add_patch(Circle((x, y), r, facecolor="white", edgecolor=ACCENT,
                         linewidth=1.0, zorder=z))
    label(ax, x, y, str(n), size=5.8, color=ACCENT, weight="bold", z=z + 1)


def engine(ax, x, y, w, h, name, note, addr):
    """Hot-path engine block (accent tint)."""
    sbox(ax, x, y, w, h, fill=FILL_ENGINE, edge=ACCENT, lw=1.1, z=3)
    cx = x + w / 2
    label(ax, cx, y + h - 2.6, name, size=7.4, weight="bold", z=4)
    if note:
        label(ax, cx, y + h / 2 - 0.4, note, size=5.0, color=GREY_DARK, z=4)
    if addr:
        label(ax, cx, y + 1.7, addr, size=5.0, color=GREY_MED, style="italic",
              z=4)


def support(ax, x, y, w, h, name, note):
    """Shared support block (grey)."""
    sbox(ax, x, y, w, h, fill=FILL_SUPPORT, edge=GREY_DARK, lw=1.0, z=3)
    cx = x + w / 2
    label(ax, cx, y + h - 2.6, name, size=7.0, weight="bold", z=4)
    if note:
        label(ax, cx, y + 2.0, note, size=5.0, color=GREY_DARK, z=4)


def plot(out_png: Path) -> None:
    configure_style()

    fig, ax = plt.subplots(figsize=(7.2, 4.75))
    ax.set_xlim(0, 100)
    ax.set_ylim(0, 66)
    ax.set_aspect("equal")
    ax.axis("off")

    # ---- CPU die boundary --------------------------------------------------
    rbox(ax, 3, 5, 68, 56, fill=FILL_DIE, edge=GREY_MED, lw=1.1,
         ls=(0, (5, 3)), round_size=2.0, z=1)
    label(ax, 6, 58.2, "CPU die", size=7.5, color=GREY_MED, ha="left",
          style="italic", z=3)

    # ---- CPU cores ---------------------------------------------------------
    rbox(ax, 7, 22, 13, 30, fill=FILL_CORES, edge=GREY_DARK, lw=1.0, z=2)
    label(ax, 13.5, 37, "CPU\ncores\n(SPDK)", size=8.5, weight="bold")

    # ---- IAU container -----------------------------------------------------
    rbox(ax, 24, 11, 35, 46, fill=FILL_IAU, edge=ACCENT, lw=1.7,
         round_size=1.8, z=2)
    label(ax, 41.5, 54, "IAU", size=11, weight="bold", color=ACCENT)

    # MMIO decoder: host-facing left bar (BAR0 routing)
    sbox(ax, 25.5, 14, 4.2, 37, fill=FILL_SUPPORT, edge=GREY_DARK, lw=1.0, z=3)
    label(ax, 27.6, 32.5, "MMIO decoder", size=6.6, weight="bold", rot=90, z=4)

    # three hot-path engines + credit manager (2x2). Block notes kept terse;
    # the paper text expands each one.
    engine(ax, 31, 38, 12, 11, "SQ Engine", "SQE + PRP + CID", "0x3000")
    engine(ax, 45, 38, 12, 11, "Doorbell\nCoalescer", "coalesce", "0x1000")
    engine(ax, 31, 25, 12, 11, "CQ Engine", "batch + hint", "0x2000")
    support(ax, 45, 25, 12, 11, "Credit\nManager", "backpressure")

    # shared SRAM substrate (via round-robin arbiter)
    sbox(ax, 31, 14, 26, 9, fill=FILL_SRAM, edge=GREY_DARK, lw=1.0, z=3)
    label(ax, 44, 19.6, "Shared SRAM  (via arbiter)", size=6.4, weight="bold",
          color=GREY_DARK, z=4)
    label(ax, 44, 16.1, "SQ / CQ buffers, PRP lists", size=5.6,
          color=GREY_DARK, z=4)

    # ---- on-die peripherals ------------------------------------------------
    rbox(ax, 62, 40, 8, 12, fill=FILL_PERIPH, edge=GREY_DARK, lw=1.0, z=2)
    label(ax, 66, 46, "IMC", size=8, weight="bold")
    rbox(ax, 62, 15, 8, 12, fill=FILL_PERIPH, edge=GREY_DARK, lw=1.0, z=2)
    label(ax, 66, 21, "PCIe\nRC", size=8, weight="bold")

    # ---- off-die: DRAM + NVMe ---------------------------------------------
    rbox(ax, 77, 38, 21, 20, fill="#ffffff", edge=GREY_DARK, lw=1.1, z=2)
    label(ax, 87.5, 55, "DRAM", size=8.5, weight="bold")
    sbox(ax, 80, 48, 15, 4, fill=FILL_RING, edge=GREY_DARK, lw=0.8, z=3)
    label(ax, 87.5, 50, "SQ ring", size=6.6, z=4)
    sbox(ax, 80, 41, 15, 4, fill=FILL_RING, edge=GREY_DARK, lw=0.8, z=3)
    label(ax, 87.5, 43, "CQ ring", size=6.6, z=4)

    rbox(ax, 77, 12, 21, 18, fill=FILL_DEVICE, edge=GREY_DARK, lw=1.1, z=2)
    label(ax, 87.5, 21, "NVMe SSD", size=8.5, weight="bold")

    # ---- arrows ------------------------------------------------------------
    # host I/O path (accent): submit via mailbox, poll the status/hint register
    arrow(ax, (20, 41), (25.3, 41), color=ACCENT, lw=1.7)
    arrow(ax, (25.3, 30), (20, 30), color=ACCENT, lw=1.7)

    # uncore -> IMC -> DRAM (batched compatibility mirror, dashed)
    arrow(ax, (59, 44), (61.6, 45), color=GREY_DARK, lw=1.3)
    arrow(ax, (70, 45.5), (76.6, 46.5), color=GREY_DARK, lw=1.3, ls=(0, (4, 2)))

    # uncore <-> PCIe RC <-> device: commands/DMA out, completions back
    arrow(ax, (59, 22), (61.6, 21.5), color=GREY_DARK, lw=1.3, astyle="<|-|>")
    arrow(ax, (70, 20.5), (76.6, 20.5), color=GREY_DARK, lw=1.3,
          astyle="<|-|>")

    # ---- per-I/O dataflow order (light badges) -----------------------------
    # 1 submit -> 2 SQ Engine builds SQE -> 3 doorbell coalesced ->
    # 4 issue over PCIe -> 5 CQ Engine batches completions -> 6 host polls
    stepmark(ax, 22.7, 41.0, 1)
    stepmark(ax, 31.6, 48.4, 2)
    stepmark(ax, 45.6, 48.4, 3)
    stepmark(ax, 60.4, 24.2, 4)
    stepmark(ax, 31.6, 35.4, 5)
    stepmark(ax, 22.7, 30.0, 6)

    # ---- minimal legend ----------------------------------------------------
    handles = [
        Line2D([0], [0], color=ACCENT, lw=1.7, marker=">", markersize=4,
               label="host I/O path"),
        Line2D([0], [0], color=GREY_DARK, lw=1.3, linestyle=(0, (4, 2)),
               label="DRAM compatibility mirror"),
    ]
    ax.legend(handles=handles, loc="lower left", bbox_to_anchor=(0.0, -0.02),
              frameon=False, fontsize=6.6, handlelength=2.0,
              handletextpad=0.5, borderaxespad=0.2)

    fig.tight_layout(pad=0.2)
    out_png.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_png, dpi=300, bbox_inches="tight", pad_inches=0.04)
    plt.close(fig)
    print(f"wrote {out_png}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out", default="figures/iau_block.png",
        help="Output PNG path (default: figures/iau_block.png)",
    )
    args = parser.parse_args()
    repo_root = Path(__file__).resolve().parent.parent
    out_png = (repo_root / args.out).resolve()
    plot(out_png)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
