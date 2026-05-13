"""Summarize one or more phase1_results.csv files.

Prints, per (QD, Qpairs, IO_Size) row:
  IOPS, p50/p99/p99.9 latency (us), Submit_Logic_ns + Completion_Logic_ns,
  cycles_per_io @ 5.3 GHz proxy, Scans_Per_Completion.

Stdlib-only.
"""

from __future__ import annotations

import argparse
import csv
import glob
import os
import sys
from typing import List

CPU_GHZ = 5.3


def summarize(csv_paths: List[str]) -> None:
    rows = []
    for p in csv_paths:
        with open(p) as f:
            for row in csv.DictReader(f):
                if not row.get("QD"):
                    continue
                try:
                    rec = dict(row)
                    rec["__src__"] = p
                    rows.append(rec)
                except Exception as e:
                    print(f"[skip] {p}: {e}", file=sys.stderr)
    if not rows:
        print("No populated rows found.")
        return

    print(f"{'tag':<40} {'QD':>4} {'qp':>3} {'IO':>5} {'IOPS':>11} "
          f"{'p50_us':>7} {'p99_us':>7} {'p99.9_us':>8} {'sw_ns':>7} {'cyc/IO':>7} {'scans':>6}")
    for r in rows:
        try:
            iops = float(r["IOPS"])
            sw = float(r["Submit_Logic_ns"]) + float(r["Completion_Logic_ns"])
            cyc = sw * CPU_GHZ
            tag = os.path.relpath(r["__src__"], "results/phase1_runs")
            tag = tag.split("/")[0] if "/" in tag else tag
            print(f"{tag[:40]:<40} "
                  f"{int(float(r['QD'])):>4} "
                  f"{int(float(r['Qpairs'])):>3} "
                  f"{int(float(r['IO_Size'])):>5} "
                  f"{iops:>11,.0f} "
                  f"{float(r['p50_Latency']):>7.2f} "
                  f"{float(r['p99_Latency']):>7.2f} "
                  f"{float(r['p99.9_Latency']):>8.2f} "
                  f"{sw:>7.0f} "
                  f"{cyc:>7.0f} "
                  f"{float(r['Scans_Per_Completion']):>6.2f}")
        except (KeyError, ValueError) as e:
            print(f"[skip row] {r.get('__src__', '?')}: {e}", file=sys.stderr)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("paths", nargs="+",
                   help="CSV files OR result-tag directories to scan recursively")
    args = p.parse_args()
    csvs: List[str] = []
    for path in args.paths:
        if os.path.isdir(path):
            csvs.extend(sorted(glob.glob(os.path.join(path, "**/phase1_results.csv"), recursive=True)))
        elif os.path.isfile(path):
            csvs.append(path)
        else:
            print(f"[skip] not found: {path}", file=sys.stderr)
    if not csvs:
        sys.exit("No CSVs found.")
    summarize(csvs)


if __name__ == "__main__":
    main()
