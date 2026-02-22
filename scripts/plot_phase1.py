
from __future__ import annotations

import argparse
import os
import re
from typing import Dict, List, Tuple

import matplotlib as mpl
import pandas as pd
import seaborn as sns
import matplotlib.pyplot as plt
import numpy as np


PLOTS_DIR = "plots"

# High-contrast palette
sns.set_theme(style="whitegrid")
sns.set_palette(mpl.colormaps["tab10"].colors)

LINE_COLORS = [
    "#1f77b4",  # blue
    "#d62728",  # red
    "#2ca02c",  # green
    "#000000",  # black
]

# Approx CPU frequency for cycle conversion (adjust if needed)
CPU_GHZ = 5.3


def parse_hist(hist_str: str) -> Dict[str, float]:
    """Parse "0:123, 1:456, 32+:789" into a dict."""
    if not isinstance(hist_str, str) or not hist_str.strip():
        return {}
    parts = [p.strip() for p in hist_str.split(",") if p.strip()]
    out: Dict[str, float] = {}
    for p in parts:
        m = re.match(r"^(\d+\+?):\s*([0-9eE+.-]+)$", p)
        if not m:
            continue
        key, val = m.group(1), m.group(2)
        try:
            out[key] = float(val)
        except ValueError:
            continue
    return out


def bucket_hist_simplified(hist: Dict[str, float]) -> Dict[str, float]:
    buckets = {
        "Empty (0)": 0.0,
        "Single (1)": 0.0,
        "2-4": 0.0,
        "5-8": 0.0,
        "9-16": 0.0,
        "17+": 0.0,
    }
    
    for k, v in hist.items():
        if k.endswith("+"):
            buckets["17+"] += v
            continue
        try:
            i = int(k)
        except ValueError:
            continue
            
        if i == 0:
            buckets["Empty (0)"] += v
        elif i == 1:
            buckets["Single (1)"] += v
        elif 2 <= i <= 4:
            buckets["2-4"] += v
        elif 5 <= i <= 8:
            buckets["5-8"] += v
        elif 9 <= i <= 16:
            buckets["9-16"] += v
        else:
            buckets["17+"] += v
    return buckets


def save_plot(fig, path: str) -> None:
    fig.set_constrained_layout(True)
    fig.savefig(path, dpi=160, bbox_inches="tight", pad_inches=0.2)
    plt.close(fig)


def lineplot(df: pd.DataFrame, x: str, y: str, hue: str,
             title: str, ylabel: str, filename: str) -> str:
    fig, ax = plt.subplots(figsize=(7.5, 4.5))
    
    # Check if y exists and has data
    if y not in df.columns or df[y].isnull().all():
        print(f"Skipping {filename}: Column '{y}' missing or empty.")
        plt.close(fig)
        return None

    levels = sorted(df[hue].dropna().unique())
    palette = {lvl: LINE_COLORS[i % len(LINE_COLORS)] for i, lvl in enumerate(levels)}

    sns.lineplot(
        data=df, x=x, y=y, hue=hue, style=hue, palette=palette,
        markers=True, dashes=True, errorbar=None, ax=ax
    )

    ax.set_title(title)
    ax.set_xlabel(x)
    ax.set_ylabel(ylabel)
    ax.grid(True, alpha=0.6, color="0.7", linewidth=0.8)

    out_path = os.path.join(PLOTS_DIR, filename)
    save_plot(fig, out_path)
    return out_path


def lineplot_melt(df: pd.DataFrame, x: str, y_vars: List[str], hue: str, title: str, ylabel: str, filename: str) -> str:
    fig, ax = plt.subplots(figsize=(7.5, 4.5))
    
    valid_y = [c for c in y_vars if c in df.columns]
    if not valid_y:
        print(f"Skipping {filename}: No valid columns found in {y_vars}")
        plt.close(fig)
        return None

    melted = df.melt(id_vars=[x, hue], value_vars=valid_y, var_name="Metric", value_name="Value")
    
    sns.lineplot(data=melted, x=x, y="Value", hue="Metric", style=hue, 
                 markers=True, dashes=False, markersize=7, errorbar="sd", ax=ax)
    
    ax.set_title(title)
    ax.set_xlabel(x)
    ax.set_ylabel(ylabel)
    ax.grid(True, alpha=0.6, color="0.7", linewidth=0.8)
    out_path = os.path.join(PLOTS_DIR, filename)
    save_plot(fig, out_path)
    return out_path


def plot_completions_log_scale(agg_hist: Dict[str, float], title: str, filename: str) -> str:
    fig, ax = plt.subplots(figsize=(10, 5))
    order = ["Empty (0)", "Single (1)", "2-4", "5-8", "9-16", "17+"]
    vals = [agg_hist.get(k, 0.0) for k in order]
    colors = ["#7f7f7f"] + sns.color_palette("Blues", n_colors=len(order)-1)
    
    bars = ax.bar(order, vals, color=colors, edgecolor="black", alpha=0.8)
    
    ax.set_yscale("log")
    ax.set_title(title)
    ax.set_xlabel("Completions per Poll (Bucket)")
    ax.set_ylabel("Count (Log Scale)")
    ax.grid(True, axis="y", alpha=0.3, which="both")
    
    total = sum(vals)
    for bar, val in zip(bars, vals):
        if total > 0:
            pct = 100 * val / total
            height = bar.get_height()
            if height > 0:
                ax.text(bar.get_x() + bar.get_width()/2., height * 1.1,
                        f"{pct:.1f}%", ha='center', va='bottom', fontsize=9, fontweight='bold')
    
    out_path = os.path.join(PLOTS_DIR, filename)
    save_plot(fig, out_path)
    return out_path


def plot_completions_stacked_by_qd(df: pd.DataFrame, qd_col: str, hist_col: str, title: str, filename: str):
    rows = []
    buckets = ["Empty (0)", "Single (1)", "2-4", "5-8", "9-16", "17+"]
    
    for _, row in df.iterrows():
        raw_hist = parse_hist(str(row[hist_col]))
        b_hist = bucket_hist_simplified(raw_hist)
        total = sum(b_hist.values())
        if total > 0:
            norm_hist = {k: (v / total) * 100 for k, v in b_hist.items()}
        else:
            norm_hist = {k: 0.0 for k in buckets}
        new_row = {qd_col: row[qd_col], "IO Size": row["IO Size (Bytes)"]}
        new_row.update(norm_hist)
        rows.append(new_row)
        
    plot_df = pd.DataFrame(rows)
    plot_df = plot_df.groupby([qd_col]).mean(numeric_only=True).reset_index()

    fig, ax = plt.subplots(figsize=(8, 5))
    x = plot_df[qd_col].astype(str)
    bottom = np.zeros(len(plot_df))
    colors = ["#d9d9d9"] + sns.color_palette("viridis", n_colors=len(buckets)-1)

    for i, bucket in enumerate(buckets):
        vals = plot_df[bucket].values
        ax.bar(x, vals, bottom=bottom, label=bucket, color=colors[i], edgecolor="white", width=0.6)
        bottom += vals
        
    ax.set_title(title)
    ax.set_xlabel("Queue Depth")
    ax.set_ylabel("Percentage of Polls (%)")
    ax.legend(title="Completions Found", bbox_to_anchor=(1.05, 1), loc='upper left')
    ax.grid(False, axis="x")
    ax.grid(True, axis="y", alpha=0.3)
    ax.set_ylim(0, 100)
    
    out_path = os.path.join(PLOTS_DIR, filename)
    save_plot(fig, out_path)
    return out_path


def stage_breakdown_bar(df: pd.DataFrame, io_size: int, title: str, filename: str) -> str:
    stages = [
        "Submit Logic (ns)",
        "Polling/Device Wait (ns)",
        "Completion Logic (ns)",
    ]

    subset = df[df["IO Size (Bytes)"] == io_size].copy()
    if subset.empty:
        fig, ax = plt.subplots(figsize=(7.5, 3.0))
        ax.set_title(title)
        ax.text(0.5, 0.5, "No data", ha="center", va="center")
        ax.axis("off")
        out_path = os.path.join(PLOTS_DIR, filename)
        save_plot(fig, out_path)
        return out_path

    means_ns = subset.groupby("Queue Depth")[["Submit Logic (ns)", "Completion Logic (ns)", "Cycles per IO"]].mean().reset_index()

    means_ns["Polling/Device Wait (ns)"] = means_ns.apply(
        lambda r: max(0.0, (r["Cycles per IO"] / CPU_GHZ) - r["Submit Logic (ns)"] - r["Completion Logic (ns)"]),
        axis=1,
    )
    means_ns["Total"] = means_ns[stages].sum(axis=1)
    for stage in stages:
        means_ns[stage] = means_ns.apply(
            lambda r: (100.0 * r[stage] / r["Total"]) if r["Total"] > 0 else 0.0, axis=1
        )

    fig, ax = plt.subplots(figsize=(7.5, 3.0))
    x = means_ns["Queue Depth"].astype(str)
    bottom = np.zeros(len(means_ns))
    colors = ["#1f77b4", "#2ca02c", "#d62728"]
    for stage, color in zip(stages, colors):
        vals = means_ns[stage].values
        bars = ax.bar(x, vals, bottom=bottom, color=color, label=stage, edgecolor="white", width=0.6)
        for bar, val, btm in zip(bars, vals, bottom):
            if val >= 5:
                ax.text(
                    bar.get_x() + bar.get_width() / 2,
                    btm + val / 2,
                    f"{val:.1f}%",
                    ha="center",
                    va="center",
                    fontsize=8,
                    color="white",
                    fontweight="bold",
                )
        bottom += vals

    ax.set_title(title)
    ax.set_xlabel("Queue Depth")
    ax.set_ylabel("Percentage of Total (%)")
    ax.set_ylim(0, 100)
    ax.grid(True, axis="y", alpha=0.3)
    ax.legend(loc="upper left", bbox_to_anchor=(1.02, 1.0), fontsize=8, frameon=False)

    out_path = os.path.join(PLOTS_DIR, filename)
    save_plot(fig, out_path)
    return out_path


def _stacked_stage_bar(df: pd.DataFrame,
                        io_size: int,
                        qd_col: str,
                        size_col: str,
                        stage_cols: List[str],
                        stage_labels: List[str],
                        title: str,
                        filename: str) -> str:
    subset = df[df[size_col] == io_size].copy()
    if subset.empty:
        fig, ax = plt.subplots(figsize=(7.5, 3.0))
        ax.set_title(title)
        ax.text(0.5, 0.5, "No data", ha="center", va="center")
        ax.axis("off")
        out_path = os.path.join(PLOTS_DIR, filename)
        save_plot(fig, out_path)
        return out_path

    for col in stage_cols:
        if col not in subset.columns:
            raise KeyError(f"Missing required column: {col}")

    means = subset.groupby(qd_col)[stage_cols].mean(numeric_only=True).reset_index()
    means["Total"] = means[stage_cols].sum(axis=1)
    for col in stage_cols:
        means[col + "_pct"] = means.apply(
            lambda r: (100.0 * r[col] / r["Total"]) if r["Total"] > 0 else 0.0,
            axis=1,
        )

    fig, ax = plt.subplots(figsize=(8.5, 4.5))
    x = means[qd_col].astype(str)
    bottom = np.zeros(len(means))
    colors = sns.color_palette("tab10", n_colors=len(stage_cols))

    for col, label, color in zip(stage_cols, stage_labels, colors):
        vals = means[col + "_pct"].values
        bars = ax.bar(x, vals, bottom=bottom, color=color, edgecolor="white", label=label, width=0.6)

        for bar, pct, ns_val, btm in zip(bars, vals, means[col].values, bottom):
            txt = f"{pct:.1f}% ({ns_val:.2f} ns)"
            if pct >= 8:
                ax.text(bar.get_x() + bar.get_width() / 2, btm + pct / 2,
                        txt, ha="center", va="center", fontsize=5, color="white")
            else:
                ax.text(bar.get_x() + bar.get_width() / 2, btm + pct + 0.8,
                        txt, ha="center", va="bottom", fontsize=5, color="black")

        bottom += vals

    ax.set_title(title)
    ax.set_xlabel("Queue Depth")
    ax.set_ylabel("Percentage of Stage Latency (%)")
    ax.set_ylim(0, 100)
    ax.grid(True, axis="y", alpha=0.3)
    ax.legend(loc="upper left", bbox_to_anchor=(1.02, 1.0), fontsize=8, frameon=False)

    out_path = os.path.join(PLOTS_DIR, filename)
    save_plot(fig, out_path)
    return out_path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--csv", default="phase1_results.csv", help="Input CSV file")
    parser.add_argument("--out", default=PLOTS_DIR, help="Output directory for plots")
    args = parser.parse_args()

    os.makedirs(args.out, exist_ok=True)
    df = pd.read_csv(args.csv)

    # Convert columns to numeric
    numeric_cols = [c for c in df.columns if c not in {"Completions_Per_Poll_Hist"}]
    for c in numeric_cols:
        df[c] = pd.to_numeric(df[c], errors="coerce")

    # Rename for readability
    df = df.rename(columns={
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
        "MMIO_Writes_Per_IO": "MMIO Writes per IO",
        "Scans_Per_Completion": "Scans per Completion",
        "Completions_Per_Call": "Completions per Call",
        "Submit_Logic_ns": "Submit Logic (ns)",
        "Polling_Wait_ns": "Polling/Device Wait (ns)",
        "Completion_Logic_ns": "Completion Logic (ns)",
        "Total_IO_ns": "Total IO (ns)",
    })

    qd_col = "Queue Depth"
    size_col = "IO Size (Bytes)"
    plots: List[Tuple[str, str]] = []

    # --- 1. Throughput & Latency (The Basics) ---
    plots.append((
        lineplot(df, qd_col, "IOPS", size_col, "Throughput vs Queue Depth", "IOPS", "iops_vs_qd.png"),
        "Saturation point identification."
    ))
    plots.append((
        lineplot_melt(df, qd_col, ["p50 Latency (us)", "p99 Latency (us)", "p99.9 Latency (us)"], size_col,
                      "Latency Percentiles", "Latency (us)", "latency_vs_qd.png"),
        "Tail latency characteristics."
    ))

    # --- 2. CPU Efficiency (The Cost) ---
    plots.append((
        lineplot(df, qd_col, "Cycles per IO", size_col, "CPU Cycles per IO", "Cycles", "cycles_per_io.png"),
        "Total CPU cost per IO operation. Lower is better. (total time core active)/(total IOs)"
    ))
    plots.append((
        lineplot(df, qd_col, "Instructions per IO", size_col, "Instructions per IO", "Instructions", "instr_per_io.png"),
        "Algorithmic complexity per IO. High values at low QD indicate inefficient polling loops."
    ))

    # --- 3. Memory & Cache (The Bottleck) ---
    plots.append((
        lineplot(df, qd_col, "LLC Misses per IO", size_col, "LLC Misses per IO", "Misses", "llc_misses_per_io.png"),
        "Last-Level Cache pressure. Indicates how much metadata/payload is hitting DRAM."
    ))
    plots.append((
        lineplot_melt(df, qd_col, ["DRAM Read Bytes per IO", "DRAM Write Bytes per IO"], size_col,
                      "DRAM Traffic per IO", "Bytes", "dram_bw_per_io.png"),
        "Data movement overhead. Should ideally match payload size, but often exceeds it due to descriptors."
    ))

    # --- 4. System Overheads (Energy & MMIO) ---
    plots.append((
        lineplot(df, qd_col, "Energy per IO (J)", size_col, "Energy per IO", "Joules", "energy_per_io.png"),
        "System energy cost per operation. (Note: May include idle power)."
    ))
    plots.append((
        lineplot(df, qd_col, "MMIO Writes per IO", size_col, "MMIO Writes per IO (Doorbells)", "Writes", "mmio_per_io.png"),
        "Hardware signaling cost. Values near 2.0 (SQ+CQ) indicate no batching; values < 1.0 indicate batching."
    ))

    # --- 5. Software Batching (The Logic) ---
    plots.append((
        lineplot(df, qd_col, "Scans per Completion", size_col, "Polling Scans per Completion", "Scans", "scans_per_completion.png"),
        "Wasted work metric: How many times the CPU checked an empty ring."
    ))
    plots.append((
        lineplot(df, qd_col, "Completions per Call", size_col, "Average Batch Size (Completions per Call)", "Batch Size", "batch_size.png"),
        "Average number of completions processed when work is actually found."
    ))

    # --- 6. Per-IO Stage Breakdown (Cycle-equivalent) ---
    plots.append((
        stage_breakdown_bar(df, 4096, "Per-IO Stage Breakdown (4KB)", "stage_breakdown_4k.png"),
        "\n".join([
            "Submit logic:",
            "Allocation: Getting the next free slot in the SQ.",
            "Construction: Constructing and copying the 64B SQE into the SQ.",
            "Barrier: Executing sfence (Write Memory Barrier) so SQE is visible before ringing the doorbell.",
            "MMIO write: SQ tail update.\n",
            "Polling/Device Wait: time between doorbell ring and completion observed for this IO.\n",
            "Completion logic:",
            "Detection: Reading the phase bit in the CQE.",
            "D-Cache Invalidation (Implicit): CPU stalls while fetching the CQE line from DDIO/LLC.",
            "Callback: Executing the user's completion callback.",
            "CQ Doorbell: Writing CQ head doorbell (often batched).",
        ])
    ))
    plots.append((
        stage_breakdown_bar(df, 16384, "Per-IO Stage Breakdown (16KB)", "stage_breakdown_16k.png"),
        "Stacked breakdown of per-IO time (converted to cycles) for 16KB requests."
    ))

    # --- 7. Submit/Complete Stage Breakdown (Detailed) ---
    submit_cols = [
        "Submit_Preamble_ns",
        "Tracker_Alloc_ns",
        "Addr_Xlate_ns",
        "Cmd_Construct_ns",
        "Fence_ns",
        "Doorbell_ns",
    ]
    submit_labels = [
        "Submit Preamble",
        "Tracker Alloc",
        "Addr Xlate",
        "Cmd Construct",
        "Fence",
        "Doorbell",
    ]

    complete_cols = [
        "CQE_Detect_ns",
        "Tracker_Lookup_ns",
        "State_Dealloc_ns",
    ]
    complete_labels = [
        "CQE Detect",
        "Tracker Lookup",
        "State Dealloc",
    ]

    plots.append((
        _stacked_stage_bar(
            df,
            4096,
            qd_col,
            size_col,
            submit_cols,
            submit_labels,
            "Submit Stage Breakdown (4KB)",
            "submit_stage_breakdown_4k.png",
        ),
        "Submit stage percentages and per-step latency for 4KB."
    ))
    plots.append((
        _stacked_stage_bar(
            df,
            16384,
            qd_col,
            size_col,
            submit_cols,
            submit_labels,
            "Submit Stage Breakdown (16KB)",
            "submit_stage_breakdown_16k.png",
        ),
        "Submit stage percentages and per-step latency for 16KB."
    ))

    plots.append((
        _stacked_stage_bar(
            df,
            4096,
            qd_col,
            size_col,
            complete_cols,
            complete_labels,
            "Completion Stage Breakdown (4KB)",
            "completion_stage_breakdown_4k.png",
        ),
        "Completion stage percentages and per-step latency for 4KB."
    ))
    plots.append((
        _stacked_stage_bar(
            df,
            16384,
            qd_col,
            size_col,
            complete_cols,
            complete_labels,
            "Completion Stage Breakdown (16KB)",
            "completion_stage_breakdown_16k.png",
        ),
        "Completion stage percentages and per-step latency for 16KB."
    ))

    # --- 6. Histogram Deep Dives ---
    agg_hist_total: Dict[str, float] = {}
    if "Completions_Per_Poll_Hist" in df.columns:
        for v in df["Completions_Per_Poll_Hist"]:
            raw = parse_hist(str(v))
            b_hist = bucket_hist_simplified(raw)
            for k, val in b_hist.items():
                agg_hist_total[k] = agg_hist_total.get(k, 0.0) + val
                
        plots.append((
            plot_completions_log_scale(agg_hist_total, "Aggregate Completions per Poll (Log Scale)", "completions_hist_log.png"),
            "Global distribution of polling outcomes."
        ))

        for size in df[size_col].unique():
            sub_df = df[df[size_col] == size]
            plots.append((
                plot_completions_stacked_by_qd(sub_df, qd_col, "Completions_Per_Poll_Hist", 
                                              f"Polling Efficiency vs QD (IO Size: {size})", 
                                              f"polling_efficiency_qd_{size}.png"),
                f"Stacked breakdown of polling outcomes for {size}B IO."
            ))

    # Write Report
    report_path = os.path.join(args.out, "report.md")
    with open(report_path, "w", encoding="utf-8") as f:
        f.write("# Phase 1 Comprehensive Datasheet\n\n")
        f.write("Generated from `phase1_results.csv`. This report covers Performance, CPU Efficiency, Memory Subsystem, and Signaling.\n\n")
        f.write("1 CPU core, 5.3 GHz; PCIe4 x4 = 8GB/s\n\n")
        
        for path, desc in plots:
            if path and os.path.exists(path):
                rel = os.path.relpath(path, args.out)
                f.write(f"### {os.path.basename(path).replace('.png', '').replace('_', ' ').title()}\n\n")
                f.write(f"![Plot]({rel})\n\n")
                f.write(f"**Insight:** {desc}\n\n")
                f.write("---\n\n")

    print(f"Saved {len([p for p in plots if p[0]])} plots and report to {report_path}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
