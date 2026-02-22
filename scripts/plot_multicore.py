#!/usr/bin/env python3
import argparse
import csv
import re
import os
from typing import List

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import seaborn as sns


def parse_per_core_values(cell) -> List[float]:
    if cell is None:
        return []
    if isinstance(cell, (int, float, np.integer, np.floating)):
        if np.isnan(cell):
            return []
        return [float(cell)]
    text = str(cell).strip()
    if "\\n" in text or "\\r" in text:
        text = text.replace("\\r", "\r").replace("\\n", "\n")
    if not text:
        return []
    values: List[float] = []
    for line in text.splitlines():
        parts = [p.strip() for p in line.split(",") if p.strip()]
        for part in parts:
            try:
                values.append(float(part))
            except ValueError:
                continue
    return values


def per_core_mean(cell) -> float:
    values = parse_per_core_values(cell)
    if not values:
        return np.nan
    return float(np.mean(values))


def read_multicore_csv(path: str) -> pd.DataFrame:
    with open(path, "r", encoding="utf-8") as f:
        lines = [line.rstrip("\n") for line in f]

    if not lines:
        raise ValueError("Empty CSV file")

    header = next(csv.reader([lines[0]], delimiter=",", quotechar='"'))
    header_len = len(header)

    row_lines: List[str] = []
    row_start_re = re.compile(r"^\d+,")

    for line in lines[1:]:
        if not line:
            continue
        if row_start_re.match(line):
            row_lines.append(line)
        else:
            if not row_lines:
                continue
            row_lines[-1] += "\\n" + line

    data_rows: List[List[str]] = []
    for row_text in row_lines:
        row = next(csv.reader([row_text], delimiter=",", quotechar='"'))
        if len(row) < header_len:
            row.extend([""] * (header_len - len(row)))
        data_rows.append(row)

    df = pd.DataFrame(data_rows, columns=header)

    numeric_cols = [
        "QD",
        "Qpairs",
        "IO_Size",
        "Run_ID",
        "Core_Count",
        "IOPS",
        "Cycles",
        "Instructions",
        "LLC_Misses",
        "Dram_Read_Bytes",
        "Dram_Write_Bytes",
        "Energy_Joules",
        "Cycles_Per_IO",
        "Instr_Per_IO",
        "LLC_Misses_Per_IO",
        "Dram_Read_Bytes_Per_IO",
        "Dram_Write_Bytes_Per_IO",
        "Energy_Per_IO",
        "Polls",
        "Completions",
        "Scans_Per_Completion",
        "Completions_Per_Call",
        "MMIO_Writes_Per_IO",
        "Submit_Logic_ns",
        "Polling_Wait_ns",
        "Completion_Logic_ns",
        "Total_IO_ns",
    ]

    for col in numeric_cols:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors="coerce")

    if "p50_Latency" in df.columns:
        df["p50_Latency_mean"] = df["p50_Latency"].apply(per_core_mean)
    if "p99_Latency" in df.columns:
        df["p99_Latency_mean"] = df["p99_Latency"].apply(per_core_mean)
    if "p99.9_Latency" in df.columns:
        df["p99.9_Latency_mean"] = df["p99.9_Latency"].apply(per_core_mean)

    return df


def read_singlecore_csv(path: str) -> pd.DataFrame:
    df = pd.read_csv(path)

    numeric_cols = [
        "QD",
        "Qpairs",
        "IO_Size",
        "Run_ID",
        "Core_Count",
        "IOPS",
        "Cycles",
        "Instructions",
        "LLC_Misses",
        "Dram_Read_Bytes",
        "Dram_Write_Bytes",
        "Energy_Joules",
        "Cycles_Per_IO",
        "Instr_Per_IO",
        "LLC_Misses_Per_IO",
        "Dram_Read_Bytes_Per_IO",
        "Dram_Write_Bytes_Per_IO",
        "Energy_Per_IO",
        "Polls",
        "Completions",
        "Scans_Per_Completion",
        "Completions_Per_Call",
        "MMIO_Writes_Per_IO",
        "Submit_Logic_ns",
        "Polling_Wait_ns",
        "Completion_Logic_ns",
        "Total_IO_ns",
    ]

    for col in numeric_cols:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors="coerce")

    if "Core_Count" not in df.columns:
        df["Core_Count"] = 1

    if "p50_Latency" in df.columns:
        df["p50_Latency_mean"] = df["p50_Latency"].apply(per_core_mean)
    if "p99_Latency" in df.columns:
        df["p99_Latency_mean"] = df["p99_Latency"].apply(per_core_mean)
    if "p99.9_Latency" in df.columns:
        df["p99.9_Latency_mean"] = df["p99.9_Latency"].apply(per_core_mean)

    return df


def plot_iops(df: pd.DataFrame, out_dir: str) -> None:
    for io_size in sorted(df["IO_Size"].dropna().unique()):
        subset = df[df["IO_Size"] == io_size]
        if subset.empty:
            continue
        plt.figure(figsize=(8, 5))
        sns.lineplot(data=subset, x="QD", y="IOPS", hue="Core_Count", marker="o")
        plt.title(f"IOPS vs QD (IO_Size={int(io_size)} bytes)")
        plt.xlabel("QD (per qpair)")
        plt.ylabel("IOPS")
        plt.grid(True, alpha=0.3)
        plt.tight_layout()
        plt.savefig(os.path.join(out_dir, f"iops_io{int(io_size)}.png"), dpi=200)
        plt.close()


def plot_latency(df: pd.DataFrame, out_dir: str) -> None:
    if not {"p50_Latency_mean", "p99_Latency_mean", "p99.9_Latency_mean"}.issubset(df.columns):
        return

    for io_size in sorted(df["IO_Size"].dropna().unique()):
        subset = df[df["IO_Size"] == io_size]
        if subset.empty:
            continue
        fig, axes = plt.subplots(1, 3, figsize=(15, 4), sharex=True)
        sns.lineplot(data=subset, x="QD", y="p50_Latency_mean", hue="Core_Count", marker="o", ax=axes[0])
        sns.lineplot(data=subset, x="QD", y="p99_Latency_mean", hue="Core_Count", marker="o", ax=axes[1])
        sns.lineplot(data=subset, x="QD", y="p99.9_Latency_mean", hue="Core_Count", marker="o", ax=axes[2])

        axes[0].set_title("p50 Latency (mean over cores)")
        axes[1].set_title("p99 Latency (mean over cores)")
        axes[2].set_title("p99.9 Latency (mean over cores)")

        for ax in axes:
            ax.set_xlabel("QD (per qpair)")
            ax.set_ylabel("Latency (us)")
            ax.grid(True, alpha=0.3)

        handles, labels = axes[0].get_legend_handles_labels()
        for ax in axes:
            ax.get_legend().remove()
        fig.legend(handles, labels, loc="upper center", ncol=len(labels))
        fig.suptitle(f"Latency vs QD (IO_Size={int(io_size)} bytes)")
        plt.tight_layout(rect=[0, 0, 1, 0.92])
        plt.savefig(os.path.join(out_dir, f"latency_io{int(io_size)}.png"), dpi=200)
        plt.close()


def plot_io_time_breakdown(df: pd.DataFrame, out_dir: str) -> None:
    for io_size in sorted(df["IO_Size"].dropna().unique()):
        subset = df[df["IO_Size"] == io_size]
        if subset.empty:
            continue
        plt.figure(figsize=(8, 5))
        if "Submit_Logic_ns" in subset.columns:
            sns.lineplot(data=subset, x="QD", y="Submit_Logic_ns", hue="Core_Count", marker="o")
        if "Polling_Wait_ns" in subset.columns:
            sns.lineplot(data=subset, x="QD", y="Polling_Wait_ns", hue="Core_Count", marker="o")
        if "Completion_Logic_ns" in subset.columns:
            sns.lineplot(data=subset, x="QD", y="Completion_Logic_ns", hue="Core_Count", marker="o")
        if "Total_IO_ns" in subset.columns:
            sns.lineplot(data=subset, x="QD", y="Total_IO_ns", hue="Core_Count", marker="o", linestyle="--")
        plt.title(f"IO Time Breakdown vs QD (IO_Size={int(io_size)} bytes)")
        plt.xlabel("QD (per qpair)")
        plt.ylabel("Time (ns)")
        plt.grid(True, alpha=0.3)
        plt.tight_layout()
        plt.savefig(os.path.join(out_dir, f"time_breakdown_io{int(io_size)}.png"), dpi=200)
        plt.close()


def plot_energy_per_io(df: pd.DataFrame, out_dir: str) -> None:
    if "Energy_Per_IO" not in df.columns:
        return
    for io_size in sorted(df["IO_Size"].dropna().unique()):
        subset = df[df["IO_Size"] == io_size]
        if subset.empty:
            continue
        plt.figure(figsize=(8, 5))
        sns.lineplot(data=subset, x="QD", y="Energy_Per_IO", hue="Core_Count", marker="o")
        plt.title(f"Energy per IO vs QD (IO_Size={int(io_size)} bytes)")
        plt.xlabel("QD (per qpair)")
        plt.ylabel("Energy per IO (J)")
        plt.grid(True, alpha=0.3)
        plt.tight_layout()
        plt.savefig(os.path.join(out_dir, f"energy_per_io{int(io_size)}.png"), dpi=200)
        plt.close()


def plot_bandwidth(df: pd.DataFrame, out_dir: str) -> None:
    if "IOPS" not in df.columns or "IO_Size" not in df.columns:
        return

    df = df.copy()
    df["Bandwidth_MBps"] = (df["IOPS"] * df["IO_Size"]) / (1024 * 1024)

    for io_size in sorted(df["IO_Size"].dropna().unique()):
        subset = df[df["IO_Size"] == io_size]
        if subset.empty:
            continue
        plt.figure(figsize=(8, 5))
        sns.lineplot(data=subset, x="QD", y="Bandwidth_MBps", hue="Core_Count", marker="o")
        plt.title(f"Bandwidth vs QD (IO_Size={int(io_size)} bytes)")
        plt.xlabel("QD (per qpair)")
        plt.ylabel("Bandwidth (MB/s)")
        plt.grid(True, alpha=0.3)
        plt.tight_layout()
        plt.savefig(os.path.join(out_dir, f"bandwidth_io{int(io_size)}.png"), dpi=200)
        plt.close()


def main() -> None:
    parser = argparse.ArgumentParser(description="Plot SPDK multi-core phase1 results")
    parser.add_argument("--input", default="phase1_multicore_results.csv", help="Path to multicore CSV")
    parser.add_argument("--single", default="phase1_results.csv", help="Optional single-core CSV to overlay")
    parser.add_argument("--out", default="multicore_plots", help="Output directory for plots")
    args = parser.parse_args()

    os.makedirs(args.out, exist_ok=True)
    df_multi = read_multicore_csv(args.input)

    df_single = None
    if args.single and os.path.exists(args.single):
        df_single = read_singlecore_csv(args.single)

    if df_single is not None:
        df = pd.concat([df_multi, df_single], ignore_index=True, sort=False)
    else:
        df = df_multi

    sns.set_theme(style="whitegrid")
    plot_iops(df, args.out)
    plot_latency(df, args.out)
    plot_io_time_breakdown(df, args.out)
    plot_energy_per_io(df, args.out)
    plot_bandwidth(df, args.out)

    print(f"Saved plots to {args.out}")


if __name__ == "__main__":
    main()
