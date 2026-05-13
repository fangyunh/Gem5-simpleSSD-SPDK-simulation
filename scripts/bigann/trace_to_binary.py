"""Convert the canonical DiskANN-BigANN trace CSV to the packed binary format
that the patched spdk_nvme_perf reads via --trace-file.

Format (16 bytes per entry, little-endian; matches struct perf_trace_entry in
spdk/app/spdk_nvme_perf/perf.c):

    uint64_t offset_bytes
    uint32_t size_bytes
    uint8_t  op       ('R' = 0x52, 'W' = 0x57)
    uint8_t  pad[3]   (zero)

The binary format is what gets fed into the gem5 guest via 9p; parsing CSV
inside the simulated guest would take many minutes of simulated time and is
unnecessary because the conversion is a pure byte-rewrite.

Usage:
    python scripts/bigann/trace_to_binary.py \\
        --input  artifacts/bigann/diskann_bigann_trace.csv \\
        --output artifacts/bigann/diskann_bigann_trace.bin
"""
from __future__ import annotations

import argparse
import csv
import os
import struct
import sys


ENTRY_FMT = "<Q I B 3s"  # 16 bytes
ENTRY_SIZE = struct.calcsize(ENTRY_FMT)
assert ENTRY_SIZE == 16, ENTRY_SIZE
PAD = b"\x00\x00\x00"


def convert(input_path: str, output_path: str, max_rows: int | None = None) -> dict:
    n_total = 0
    n_read = 0
    n_write = 0
    sizes = {}
    aligned_4k = 0
    min_off = None
    max_off = 0

    with open(input_path, "r") as fin, open(output_path, "wb") as fout:
        reader = csv.reader(line for line in fin if not line.startswith("#"))
        header = next(reader, None)
        if not header or "ts_ns" not in header[0]:
            sys.exit(f"unexpected header: {header!r}")

        col_op = header.index("op")
        col_off = header.index("offset_bytes")
        col_size = header.index("size_bytes")

        for row in reader:
            if max_rows and n_total >= max_rows:
                break
            try:
                op = row[col_op].strip()
                offset = int(row[col_off])
                size = int(row[col_size])
            except (IndexError, ValueError):
                continue

            op_byte = op.encode("ascii")[:1] or b"R"
            fout.write(struct.pack(ENTRY_FMT, offset, size, op_byte[0], PAD))

            n_total += 1
            if op == "R":
                n_read += 1
            elif op == "W":
                n_write += 1
            sizes[size] = sizes.get(size, 0) + 1
            if offset % 4096 == 0:
                aligned_4k += 1
            if min_off is None or offset < min_off:
                min_off = offset
            if offset > max_off:
                max_off = offset

    out_size = os.path.getsize(output_path)

    return {
        "n_total": n_total,
        "n_read": n_read,
        "n_write": n_write,
        "size_distribution": sizes,
        "aligned_4k": aligned_4k,
        "offset_min": min_off or 0,
        "offset_max": max_off,
        "output_bytes": out_size,
    }


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--input",  required=True, help="canonical CSV trace from DISKANN_TRACE_CAPTURE")
    p.add_argument("--output", required=True, help="path to write packed binary")
    p.add_argument("--max-rows", type=int, default=None,
                   help="cap conversion at N rows (for testing); default: all rows")
    args = p.parse_args()

    if not os.path.isfile(args.input):
        sys.exit(f"input not found: {args.input}")
    os.makedirs(os.path.dirname(args.output) or ".", exist_ok=True)

    stats = convert(args.input, args.output, args.max_rows)

    print(f"=== trace_to_binary: {args.input} -> {args.output} ===")
    print(f"  entries written : {stats['n_total']:,}")
    print(f"  reads / writes  : {stats['n_read']:,} / {stats['n_write']:,}")
    print(f"  output bytes    : {stats['output_bytes']:,}")
    print(f"  4 KB-aligned    : {stats['aligned_4k']:,} "
          f"({100*stats['aligned_4k']/max(stats['n_total'],1):.2f}%)")
    print(f"  offset range    : [{stats['offset_min']:,}, {stats['offset_max']:,}] bytes "
          f"({(stats['offset_max']-stats['offset_min'])/(1<<30):.2f} GiB span)")
    print(f"  size histogram  :")
    for sz, cnt in sorted(stats["size_distribution"].items(), key=lambda kv: -kv[1])[:5]:
        print(f"    {sz:>8d} B : {cnt:>10,d} ({100*cnt/max(stats['n_total'],1):.2f}%)")


if __name__ == "__main__":
    main()
