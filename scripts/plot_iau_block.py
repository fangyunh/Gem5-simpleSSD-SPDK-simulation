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
  (iii) The DRAM rings as backup. SQ/CQ rings stay in DRAM as a lazily-synced
        backup; the host's fast path talks to the uncore directly, not through
        them (a design feature, dashed, not measured in Section 4).

The three blue engines are the paper's contribution; the grey blocks are
shared support. Module set matches RTL_design/src: sq_engine, cq_engine,
db_coalescer, credit_manager, sram_arbiter, mmio_decoder (stat_counters,
telemetry only, is omitted for clarity).

The CPU cores, IMC, PCIe RC, DRAM, and NVMe SSD are drawn small on purpose so
the IAU block carries most of the figure and its in-block text stays legible
once the figure is scaled into a column. Style matches
scripts/plot_cycle_breakdown.py: serif font, grey palette with one blue
accent, black edges, 300 dpi PNG.

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


def arrow(ax, p0, p1, *, color, lw=1.4, ls="solid", astyle="-|>", z=4,
          mscale=8.5):
    ax.annotate(
        "", xy=p1, xytext=p0,
        arrowprops=dict(arrowstyle=astyle, color=color, lw=lw, linestyle=ls,
                        shrinkA=0, shrinkB=0, mutation_scale=mscale),
        zorder=z,
    )


def stepmark(ax, x, y, n, *, r=1.35, z=7):
    """Light numbered badge marking one beat of the per-I/O dataflow.

    White fill + thin accent ring + accent numeral, so it annotates the
    diagram without competing with the block titles.
    """
    ax.add_patch(Circle((x, y), r, facecolor="white", edgecolor=ACCENT,
                         linewidth=1.0, zorder=z))
    label(ax, x, y, str(n), size=6.6, color=ACCENT, weight="bold", z=z + 1)


def engine(ax, x, y, w, h, name, note, addr):
    """Hot-path engine block (accent tint). Title bold; note/addr enlarged."""
    sbox(ax, x, y, w, h, fill=FILL_ENGINE, edge=ACCENT, lw=1.2, z=3)
    cx = x + w / 2
    label(ax, cx, y + h - 3.4, name, size=9.4, weight="bold", z=4)
    if note:
        label(ax, cx, y + h / 2 - 0.4, note, size=8.4, color=GREY_DARK, z=4)
    if addr:
        label(ax, cx, y + 2.2, addr, size=8.0, color=GREY_MED, style="italic",
              z=4)


def support(ax, x, y, w, h, name, note):
    """Shared support block (grey). Title bold; note enlarged."""
    sbox(ax, x, y, w, h, fill=FILL_SUPPORT, edge=GREY_DARK, lw=1.1, z=3)
    cx = x + w / 2
    label(ax, cx, y + h - 3.4, name, size=9.0, weight="bold", z=4)
    if note:
        label(ax, cx, y + 2.6, note, size=8.4, color=GREY_DARK, z=4)


def plot(out_png: Path) -> None:
    configure_style()

    # Smaller figure than the content would suggest, so that when the PNG is
    # scaled into a paper column the in-block text is not shrunk into oblivion.
    fig, ax = plt.subplots(figsize=(5.6, 3.7))
    ax.set_xlim(0, 100)
    ax.set_ylim(0, 66)
    ax.set_aspect("equal")
    ax.axis("off")

    # ---- CPU die boundary --------------------------------------------------
    rbox(ax, 1, 4, 74, 58, fill=FILL_DIE, edge=GREY_MED, lw=1.1,
         ls=(0, (5, 3)), round_size=2.0, z=1)
    label(ax, 4, 59.4, "CPU die", size=8.0, color=GREY_MED, ha="left",
          style="italic", z=3)

    # ---- CPU cores (kept small, but wide enough for "(SPDK)") --------------
    rbox(ax, 3, 18, 9.5, 31, fill=FILL_CORES, edge=GREY_DARK, lw=1.0, z=2)
    label(ax, 7.75, 33.5, "CPU\ncores\n(SPDK)", size=8.6, weight="bold")

    # ---- IAU container (enlarged: this is the contribution) ----------------
    rbox(ax, 17, 8, 44.5, 51, fill=FILL_IAU, edge=ACCENT, lw=1.9,
         round_size=1.8, z=2)
    label(ax, 39.25, 55.4, "IAU", size=13.5, weight="bold", color=ACCENT)

    # MMIO decoder: host-facing left bar (BAR0 routing)
    sbox(ax, 18.5, 12, 4.5, 41, fill=FILL_SUPPORT, edge=GREY_DARK, lw=1.0, z=3)
    label(ax, 20.75, 32.5, "MMIO decoder", size=8.2, weight="bold", rot=90,
          z=4)

    # three hot-path engines + credit manager (2x2)
    engine(ax, 25, 38, 17, 13, "SQ Engine", "SQE + PRP\n+ CID", "0x3000")
    engine(ax, 43, 38, 17, 13, "Doorbell\nCoalescer", "coalesce", "0x1000")
    engine(ax, 25, 23, 17, 13, "CQ Engine", "batch + hint", "0x2000")
    support(ax, 43, 23, 17, 13, "Credit\nManager", "backpressure")

    # shared SRAM substrate (via round-robin arbiter)
    sbox(ax, 25, 12, 35, 9.5, fill=FILL_SRAM, edge=GREY_DARK, lw=1.0, z=3)
    label(ax, 42.5, 18.5, "Shared SRAM  (via arbiter)", size=8.4,
          weight="bold", color=GREY_DARK, z=4)
    label(ax, 42.5, 14.4, "SQ / CQ buffers, PRP lists", size=8.0,
          color=GREY_DARK, z=4)

    # ---- on-die peripherals (widened so their labels fit the blocks) -------
    rbox(ax, 67, 38, 7, 12, fill=FILL_PERIPH, edge=GREY_DARK, lw=1.0, z=2)
    label(ax, 70.5, 44, "IMC", size=8.4, weight="bold")
    rbox(ax, 67, 13, 7, 12, fill=FILL_PERIPH, edge=GREY_DARK, lw=1.0, z=2)
    label(ax, 70.5, 19, "PCIe\nRC", size=8.4, weight="bold")

    # ---- off-die: DRAM + NVMe (shrunk to free width for IAU + peripherals) -
    rbox(ax, 79.5, 37, 12, 19, fill="#ffffff", edge=GREY_DARK, lw=1.1, z=2)
    label(ax, 85.5, 52.8, "DRAM", size=9.0, weight="bold")
    sbox(ax, 81, 46.4, 9, 4.0, fill=FILL_RING, edge=GREY_DARK, lw=0.8, z=3)
    label(ax, 85.5, 48.4, "SQ ring", size=7.8, z=4)
    sbox(ax, 81, 39.8, 9, 4.0, fill=FILL_RING, edge=GREY_DARK, lw=0.8, z=3)
    label(ax, 85.5, 41.8, "CQ ring", size=7.8, z=4)

    rbox(ax, 79.5, 12, 12, 18, fill=FILL_DEVICE, edge=GREY_DARK, lw=1.1, z=2)
    label(ax, 85.5, 21, "NVMe\nSSD", size=9.0, weight="bold")

    # ---- arrows (spanning the widened gaps so every step reads clearly) -----
    # host I/O path (accent): submit via mailbox, poll the status/hint register
    arrow(ax, (12.7, 43), (18.3, 43), color=ACCENT, lw=1.9, mscale=11)
    arrow(ax, (18.3, 30), (12.7, 30), color=ACCENT, lw=1.9, mscale=11)

    # uncore -> IMC -> DRAM (lazy backup sync to the DRAM rings, dashed)
    arrow(ax, (61.7, 44), (66.8, 44), color=GREY_DARK, lw=1.4, mscale=11)
    arrow(ax, (74.2, 45), (79.1, 45.5), color=GREY_DARK, lw=1.4,
          ls=(0, (4, 2)), mscale=11)

    # uncore <-> PCIe RC <-> device: commands/DMA out, completions back
    arrow(ax, (61.7, 21), (66.8, 21), color=GREY_DARK, lw=1.5,
          astyle="<|-|>", mscale=13)
    arrow(ax, (74.2, 20.5), (79.1, 20.5), color=GREY_DARK, lw=1.5,
          astyle="<|-|>", mscale=13)

    # ---- per-I/O dataflow order (light badges) -----------------------------
    # 1 submit -> 2 SQ Engine builds SQE -> 3 doorbell coalesced ->
    # 4 issue over PCIe -> 5 CQ Engine batches completions -> 6 host polls
    stepmark(ax, 15.0, 43.0, 1)
    stepmark(ax, 26.0, 49.6, 2)
    stepmark(ax, 44.0, 49.6, 3)
    stepmark(ax, 64.3, 23.2, 4)
    stepmark(ax, 26.0, 34.6, 5)
    stepmark(ax, 15.0, 30.0, 6)

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
