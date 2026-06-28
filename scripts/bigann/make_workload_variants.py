"""Derive write-only and 50/50 read/write trace CSVs from the canonical
DiskANN-BigANN read trace. Only the `op` column changes; ts_ns/offset/size/pid
are preserved verbatim so op-mix is the single isolated variable.

  write : every data row op -> W
  rw50  : data rows alternate R (even index) / W (odd index) -> exactly 50/50

Usage:
  python scripts/bigann/make_workload_variants.py \\
      --input artifacts/bigann/diskann_bigann_trace.csv \\
      --outdir artifacts/bigann
"""
from __future__ import annotations
import argparse, csv, os, sys


def _read_header_and_cols(path):
    comments, header = [], None
    with open(path, "r") as f:
        for line in f:
            if line.startswith("#"):
                comments.append(line.rstrip("\n"))
                continue
            header = line.rstrip("\n")
            break
    if header is None or "ts_ns" not in header.split(",")[0]:
        sys.exit(f"unexpected header in {path!r}: {header!r}")
    cols = header.split(",")
    return comments, header, cols.index("op")


def convert(input_path, out_path, mode, extra_comment):
    comments, header, col_op = _read_header_and_cols(input_path)
    n_total = n_r = n_w = 0
    with open(input_path, "r") as fin, open(out_path, "w", newline="") as fout:
        w = csv.writer(fout)
        for c in comments:
            fout.write(c + "\n")
        fout.write(extra_comment + "\n")
        fout.write(header + "\n")
        reader = csv.reader(line for line in fin if not line.startswith("#"))
        next(reader, None)  # skip header (already written)
        for row in reader:
            if not row:
                continue
            if mode == "write":
                op = "W"
            else:  # rw50: even data-row index -> R, odd -> W
                op = "R" if (n_total % 2 == 0) else "W"
            row[col_op] = op
            w.writerow(row)
            n_total += 1
            n_r += op == "R"
            n_w += op == "W"
    return n_total, n_r, n_w


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--input", required=True)
    p.add_argument("--outdir", required=True)
    args = p.parse_args()
    base = "diskann_bigann_trace"
    jobs = [
        ("write", f"{base}_write.csv", "# variant: write-only (op forced W); derived from diskann_bigann_trace.csv"),
        ("rw50",  f"{base}_rw50.csv",  "# variant: 50/50 read/write (alternating R/W by row index); derived from diskann_bigann_trace.csv"),
    ]
    for mode, fname, comment in jobs:
        out = os.path.join(args.outdir, fname)
        n, nr, nw = convert(args.input, out, mode, comment)
        print(f"[{mode}] {out}: total={n:,} R={nr:,} ({100*nr/max(n,1):.1f}%) "
              f"W={nw:,} ({100*nw/max(n,1):.1f}%)")


if __name__ == "__main__":
    main()
