"""Generate Figure 4: p99 latency vs CQ_BATCH_N for Mode 2A and Mode 2B.

Sweep over CQBatchN ∈ {1, 4, 16, 64} at fixed QD=128, qp=1, IO=4 KiB random read,
run separately for --uncore-mode 1 (Mode A) and --uncore-mode 2 (Mode B).

Inputs : results/phase1_runs/<tag>/**/phase1_results.csv
         where <tag> looks like  <prefix>_cqbatchN_mode{1|2}
Output : plots/fig4_p99_vs_cqbatchn.{png,pdf}

Stdlib-only.
"""

from __future__ import annotations

import argparse
import csv
import glob
import os
import re
import sys
from collections import defaultdict
from typing import Dict, List

import matplotlib.pyplot as plt

PLOTS_DIR = "plots"

REGIMES = [
    ("modeA", "Mode 2A (CQ batching)", "tab:orange", "s", "--"),
    ("modeB", "Mode 2B (poll-lite)",   "tab:green",  "^", "-."),
]


def parse_cqbatch(tag: str) -> int:
    m = re.search(r"cqbatch(\d+)", tag)
    return int(m.group(1)) if m else -1


def load_runs(results_root: str, prefix: str, mode_suffix: str,
              io_size: int, qd: int) -> Dict[int, Dict[str, float]]:
    """Return {cqbatch_n: mean_p99_us} for every matching tag dir."""
    out: Dict[int, List[float]] = defaultdict(list)
    pattern = os.path.join(results_root, f"{prefix}_cqbatch*_{mode_suffix}", "**/phase1_results.csv")
    for csv_path in glob.glob(pattern, recursive=True):
        # Tag dir is two levels above the csv (<tag>/<core_qp>/phase1_results.csv).
        parts = csv_path.split(os.sep)
        try:
            tag_dir = parts[parts.index(os.path.basename(results_root)) + 1]
        except (ValueError, IndexError):
            tag_dir = os.path.basename(os.path.dirname(os.path.dirname(csv_path)))
        n = parse_cqbatch(tag_dir)
        if n < 0:
            print(f"[skip] cannot parse cqbatchN from {tag_dir}", file=sys.stderr)
            continue
        with open(csv_path) as f:
            for row in csv.DictReader(f):
                if not row.get("QD"):
                    continue
                try:
                    if int(row["IO_Size"]) != io_size:
                        continue
                    if int(row["QD"]) != qd:
                        continue
                    p99 = float(row["p99_Latency"])
                    out[n].append(p99)
                except (KeyError, ValueError) as e:
                    print(f"[skip row] {csv_path}: {e}", file=sys.stderr)

    agg: Dict[int, Dict[str, float]] = {}
    for n, samples in out.items():
        agg[n] = {
            "p99_mean": sum(samples) / len(samples),
            "p99_min": min(samples),
            "p99_max": max(samples),
            "samples": float(len(samples)),
        }
    return agg


def plot(by_regime: Dict[str, Dict[int, Dict[str, float]]],
         out_path: str, qd: int, io_size: int) -> None:
    fig, ax = plt.subplots(figsize=(7.0, 4.2))
    for key, label, color, marker, linestyle in REGIMES:
        runs = by_regime.get(key, {})
        if not runs:
            print(f"[warn] no data for {key}", file=sys.stderr)
            continue
        ns = sorted(runs)
        means = [runs[n]["p99_mean"] for n in ns]
        ax.plot(ns, means, color=color, marker=marker, linestyle=linestyle,
                linewidth=2.0, label=label)

    ax.set_xscale("log", base=2)
    ax.set_xlabel("CQ_BATCH_N (CQ batch threshold, log2)")
    ax.set_ylabel("p99 read latency (us)")
    ax.set_title(f"p99 latency vs CQ_BATCH_N  (QD={qd}, qp=1, {io_size}B random read)")
    ax.grid(True, which="both", linestyle="--", alpha=0.3)
    ax.legend(loc="upper left", frameon=True, fontsize=9)
    plt.tight_layout()

    os.makedirs(PLOTS_DIR, exist_ok=True)
    fig.savefig(out_path + ".png", dpi=180)
    fig.savefig(out_path + ".pdf")
    print(f"wrote {out_path}.png and {out_path}.pdf")


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--results-root", default="results/phase1_runs")
    p.add_argument("--tag-prefix", default="phase1_paper_20260509",
                   help="Tag prefix; full pattern is <prefix>_cqbatch<N>_mode{1|2}")
    p.add_argument("--io-size", type=int, default=4096)
    p.add_argument("--qd", type=int, default=128)
    p.add_argument("--out", default=os.path.join(PLOTS_DIR, "fig4_p99_vs_cqbatchn"))
    args = p.parse_args()

    by_regime = {
        "modeA": load_runs(args.results_root, args.tag_prefix, "mode1", args.io_size, args.qd),
        "modeB": load_runs(args.results_root, args.tag_prefix, "mode2", args.io_size, args.qd),
    }
    if not any(by_regime.values()):
        sys.exit(f"No data under {args.results_root}/{args.tag_prefix}_cqbatch*_mode{{1,2}}/")
    plot(by_regime, args.out, qd=args.qd, io_size=args.io_size)


if __name__ == "__main__":
    main()
