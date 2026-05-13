from __future__ import annotations

import argparse
import os
import re
from glob import glob
from typing import Dict, Iterable, List, Tuple

import csv
import matplotlib.pyplot as plt


def save_plot(fig, path: str) -> bool:
    try:
        fig.set_constrained_layout(True)
        fig.savefig(path, dpi=160, bbox_inches="tight", pad_inches=0.2)
        return True
    except Exception:
        return False
    finally:
        plt.close(fig)


def _unique_values(rows: List[Dict[str, float]], key: str) -> List[float]:
    return sorted({row[key] for row in rows if key in row})


def _group_mean(rows: List[Dict[str, float]], keys: List[str], value_key: str) -> List[Dict[str, float]]:
    buckets: Dict[Tuple[float, ...], List[float]] = {}
    for row in rows:
        try:
            key = tuple(row[k] for k in keys)
            val = float(row[value_key])
        except (KeyError, TypeError, ValueError):
            continue
        buckets.setdefault(key, []).append(val)

    results: List[Dict[str, float]] = []
    for key, vals in buckets.items():
        out = {k: v for k, v in zip(keys, key)}
        out[value_key] = sum(vals) / len(vals) if vals else 0.0
        results.append(out)
    return results


def lineplot(rows: List[Dict[str, float]], x: str, y: str, hue: str,
             title: str, ylabel: str, path: str) -> str | None:
    if not rows or y not in rows[0]:
        return None
    fig, ax = plt.subplots(figsize=(7.5, 4.5))
    if hue in rows[0]:
        for hv in _unique_values(rows, hue):
            sub_rows = [r for r in rows if r.get(hue) == hv]
            agg = _group_mean(sub_rows, [x], y)
            agg_sorted = sorted(agg, key=lambda r: r[x])
            ax.plot([r[x] for r in agg_sorted], [r[y] for r in agg_sorted], marker="o", label=f"{hue}={hv}")
        ax.legend(title=hue)
    else:
        agg = _group_mean(rows, [x], y)
        agg_sorted = sorted(agg, key=lambda r: r[x])
        ax.plot([r[x] for r in agg_sorted], [r[y] for r in agg_sorted], marker="o")
    ax.set_title(title)
    ax.set_xlabel(x)
    ax.set_ylabel(ylabel)
    ax.grid(True, alpha=0.6)
    if save_plot(fig, path):
        return path
    return None


def lineplot_melt(rows: List[Dict[str, float]], x: str, y_vars: List[str], hue: str,
                  title: str, ylabel: str, path: str) -> str | None:
    valid_y = [c for c in y_vars if rows and c in rows[0]]
    if not valid_y:
        return None
    fig, ax = plt.subplots(figsize=(7.5, 4.5))
    hue_vals = _unique_values(rows, hue) if hue in rows[0] else [None]

    for metric in valid_y:
        for hv in hue_vals:
            if hv is None:
                sub_rows = rows
                label = f"{metric}"
            else:
                sub_rows = [r for r in rows if r.get(hue) == hv]
                label = f"{metric} ({hue}={hv})"
            agg = _group_mean(sub_rows, [x], metric)
            agg_sorted = sorted(agg, key=lambda r: r[x])
            ax.plot([r[x] for r in agg_sorted], [r[metric] for r in agg_sorted], marker="o", label=label)
    ax.legend()
    ax.set_title(title)
    ax.set_xlabel(x)
    ax.set_ylabel(ylabel)
    ax.grid(True, alpha=0.6)
    if save_plot(fig, path):
        return path
    return None


def load_results(csv_path: str) -> List[Dict[str, float]]:
    rename_map = {
        "QD": "Queue Depth",
        "IO_Size": "IO Size (Bytes)",
        "IOPS": "IOPS",
        "p50_Latency": "p50 Latency (us)",
        "p99_Latency": "p99 Latency (us)",
        "p99.9_Latency": "p99.9 Latency (us)",
        "Cycles_Per_IO": "Cycles per IO",
        "Instr_Per_IO": "Instructions per IO",
        "LLC_Misses_Per_IO": "LLC Misses per IO",
        "Dram_Read_Bytes_Per_IO": "DRAM Read Bytes per IO",
        "Dram_Write_Bytes_Per_IO": "DRAM Write Bytes per IO",
        "Energy_Per_IO": "Energy per IO (J)",
    }

    rows: List[Dict[str, float]] = []
    with open(csv_path, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for raw in reader:
            out: Dict[str, float] = {}
            for k, v in raw.items():
                name = rename_map.get(k, k)
                if k == "Completions_Per_Poll_Hist":
                    continue
                try:
                    out[name] = float(v) if v not in (None, "") else 0.0
                except (ValueError, TypeError):
                    out[name] = 0.0
            rows.append(out)
    return rows


def load_histograms(hist_dir: str) -> List[Dict[str, float]]:
    rows: List[Dict[str, float]] = []
    pattern = re.compile(r"hist_s(\d+)_q(\d+)_r(\d+)\.csv$")
    for path in sorted(glob(os.path.join(hist_dir, "hist_s*_q*_r*.csv"))):
        name = os.path.basename(path)
        m = pattern.search(name)
        if not m:
            continue
        io_size = int(m.group(1))
        qd = int(m.group(2))
        run = int(m.group(3))
        with open(path, "r", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            for row in reader:
                try:
                    rows.append({
                        "IO Size (Bytes)": float(io_size),
                        "Queue Depth": float(qd),
                        "Run": float(run),
                        "start_us": float(row.get("start_us", 0) or 0),
                        "end_us": float(row.get("end_us", 0) or 0),
                        "count": float(row.get("count", 0) or 0),
                    })
                except (TypeError, ValueError):
                    continue
    return rows


def plot_histograms(hist_rows: List[Dict[str, float]], out_dir: str) -> List[Tuple[str, str]]:
    plots: List[Tuple[str, str]] = []
    os.makedirs(out_dir, exist_ok=True)

    if not hist_rows:
        return plots

    # Prepare midpoints and aggregate counts
    overall_counts: Dict[float, float] = {}
    agg_counts: Dict[Tuple[float, float, float], float] = {}

    for row in hist_rows:
        mid = (row["start_us"] + row["end_us"]) / 2.0
        overall_counts[mid] = overall_counts.get(mid, 0.0) + row["count"]
        key = (row["IO Size (Bytes)"], row["Queue Depth"], mid)
        agg_counts[key] = agg_counts.get(key, 0.0) + row["count"]

    # Overall aggregate
    if overall_counts:
        total = sum(overall_counts.values()) or 1.0
        mids = sorted(overall_counts.keys())
        pct = [(overall_counts[m] / total) * 100.0 for m in mids]
        fig, ax = plt.subplots(figsize=(7.5, 4.5))
        ax.plot(mids, pct, marker="o")
        ax.set_title("Latency Histogram (All Runs)")
        ax.set_xlabel("Latency (us)")
        ax.set_ylabel("Percent of IOs (%)")
        ax.grid(True, alpha=0.6)
        path = os.path.join(out_dir, "hist_overall.png")
        if save_plot(fig, path):
            plots.append((path, "Overall latency distribution across all runs."))

    # Per IO size, hue by QD
    io_sizes = sorted({k[0] for k in agg_counts.keys()})
    for io_size in io_sizes:
        qds = sorted({k[1] for k in agg_counts.keys() if k[0] == io_size})
        fig, ax = plt.subplots(figsize=(7.5, 4.5))
        for qd in qds:
            mids = sorted({k[2] for k in agg_counts.keys() if k[0] == io_size and k[1] == qd})
            counts = [agg_counts[(io_size, qd, m)] for m in mids]
            total = sum(counts) or 1.0
            pct = [(c / total) * 100.0 for c in counts]
            ax.plot(mids, pct, marker="o", label=f"QD={int(qd)}")
        ax.legend(title="Queue Depth")
        ax.set_title(f"Latency Histogram (IO Size {int(io_size)}B)")
        ax.set_xlabel("Latency (us)")
        ax.set_ylabel("Percent of IOs (%)")
        ax.grid(True, alpha=0.6)
        path = os.path.join(out_dir, f"hist_io_{int(io_size)}.png")
        if save_plot(fig, path):
            plots.append((path, f"Latency distribution for {int(io_size)}B by queue depth."))

    return plots


def plot_one(csv_path: str, out_dir: str, hist_dir: str, make_plots: bool = True) -> str:
    os.makedirs(out_dir, exist_ok=True)
    rows = load_results(csv_path)

    qd_col = "Queue Depth"
    size_col = "IO Size (Bytes)"
    plots: List[Tuple[str, str]] = []

    # Aggregate repeats
    agg = rows

    # Throughput & Latency
    if make_plots:
        plots.append((
            lineplot(agg, qd_col, "IOPS", size_col, "IOPS vs Queue Depth (malloc bdev)", "IOPS",
                     os.path.join(out_dir, "iops_vs_qd.png")),
            "Throughput saturation vs queue depth."
        ))
        plots.append((
            lineplot_melt(agg, qd_col, ["p50 Latency (us)", "p99 Latency (us)", "p99.9 Latency (us)"], size_col,
                          "Latency Percentiles (malloc bdev)", "Latency (us)",
                          os.path.join(out_dir, "latency_vs_qd.png")),
            "Latency tail behavior of the in-memory path."
        ))

    # CPU & Memory cost
    if make_plots:
        plots.append((
            lineplot(agg, qd_col, "Cycles per IO", size_col, "Cycles per IO", "Cycles",
                     os.path.join(out_dir, "cycles_per_io.png")),
            "CPU cycle cost per IO."
        ))
        plots.append((
            lineplot(agg, qd_col, "Instructions per IO", size_col, "Instructions per IO", "Instructions",
                     os.path.join(out_dir, "instr_per_io.png")),
            "Instruction cost per IO."
        ))
        plots.append((
            lineplot(agg, qd_col, "LLC Misses per IO", size_col, "LLC Misses per IO", "Misses",
                     os.path.join(out_dir, "llc_misses_per_io.png")),
            "Cache pressure per IO."
        ))
        plots.append((
            lineplot_melt(agg, qd_col, ["DRAM Read Bytes per IO", "DRAM Write Bytes per IO"], size_col,
                          "DRAM Traffic per IO", "Bytes",
                          os.path.join(out_dir, "dram_bw_per_io.png")),
            "Memory traffic per IO."
        ))
        plots.append((
            lineplot(agg, qd_col, "Energy per IO (J)", size_col, "Energy per IO", "Joules",
                     os.path.join(out_dir, "energy_per_io.png")),
            "Energy cost per IO (if available)."
        ))

    # Histograms
    hist_plots: List[Tuple[str, str]] = []
    hist_rows = load_histograms(hist_dir)
    if make_plots and hist_rows:
        hist_plots = plot_histograms(hist_rows, os.path.join(out_dir, "histograms"))

    # Report title context
    run_name = os.path.basename(os.path.dirname(csv_path))
    report_path = os.path.join(out_dir, "report.md")
    with open(report_path, "w", encoding="utf-8") as f:
        f.write("# Phase 1 bdev Datasheet\n\n")
        f.write(f"Source CSV: {csv_path}\n\n")
        f.write(f"Run: {run_name}\n\n")
        f.write("Generated from malloc bdev results. This report focuses on CPU and memory-path behavior.\n\n")

        for path, desc in plots + hist_plots:
            if path and os.path.exists(path):
                rel = os.path.relpath(path, out_dir)
                f.write(f"### {os.path.basename(path).replace('.png', '').replace('_', ' ').title()}\n\n")
                f.write(f"![Plot]({rel})\n\n")
                f.write(f"**Insight:** {desc}\n\n")
                f.write("---\n\n")

    return report_path


def main() -> None:
    parser = argparse.ArgumentParser(description="Plot bdev malloc phase1 results")
    parser.add_argument("--root", default="results/bdev_data", help="Root directory with run outputs")
    parser.add_argument("--csv", default="", help="Input results CSV (optional)")
    parser.add_argument("--out-root", default="", help="Root output directory (optional)")
    parser.add_argument("--hist-root", default="", help="Root histogram directory (optional)")
    parser.add_argument("--no-plots", action="store_true", help="Skip plot generation")
    args = parser.parse_args()

    csv_paths: List[str] = []
    if args.csv:
        if os.path.exists(args.csv):
            csv_paths = [args.csv]
        else:
            raise FileNotFoundError(f"CSV not found: {args.csv}")
    else:
        csv_paths = sorted(glob(os.path.join(args.root, "**", "phase1_bdev_results.csv"), recursive=True))
        if not csv_paths:
            raise FileNotFoundError(f"No CSVs found under: {args.root}")

    report_paths: List[str] = []
    for csv_path in csv_paths:
        base_dir = os.path.dirname(csv_path)
        if args.out_root:
            rel_dir = os.path.relpath(base_dir, args.root)
            out_dir = os.path.join(args.out_root, rel_dir, "plots")
        else:
            out_dir = os.path.join(base_dir, "plots")

        if args.hist_root:
            rel_dir = os.path.relpath(base_dir, args.root)
            hist_dir = os.path.join(args.hist_root, rel_dir, "histograms")
        else:
            hist_dir = os.path.join(base_dir, "histograms")

        print(f"Processing {csv_path}")
        if args.no_plots:
            report_paths.append(plot_one(csv_path, out_dir, hist_dir, make_plots=not args.no_plots))
        else:
            report_paths.append(plot_one(csv_path, out_dir, hist_dir))

    print("Reports generated:")
    for path in report_paths:
        print(f"- {path}")


if __name__ == "__main__":
    plt.style.use("seaborn-v0_8-whitegrid")
    main()
