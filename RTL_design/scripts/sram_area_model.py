#!/usr/bin/env python3
"""sram_area_model.py — Analytical SRAM area estimation for IO-Uncore.

Computes per-component SRAM sizes and estimates silicon area using
ASAP7 HD bitcell density (0.027 um^2/bit) with 1.5x overhead factor.
"""

import sys
import json

# ASAP7 parameters
BITCELL_AREA_UM2 = 0.027   # um^2 per bit (HD bitcell)
OVERHEAD_FACTOR  = 1.5      # decoders, sense amps, peripherals, routing
LBA_SIZE         = 4096     # bytes
MAX_TRANSFER     = 131072   # 128KB
MAX_PRP_ENTRIES  = (MAX_TRANSFER // LBA_SIZE) - 1  # 31

CONFIGS = [
    {"name": "A", "nq": 16, "qd":  64, "label": "16QP/QD64"},
    {"name": "B", "nq": 64, "qd":  64, "label": "64QP/QD64"},
    {"name": "C", "nq": 16, "qd": 128, "label": "16QP/QD128"},
    {"name": "D", "nq": 64, "qd": 128, "label": "64QP/QD128"},
]


def compute_sram(nq: int, qd: int) -> dict:
    sq_bytes  = nq * qd * 64
    cq_bytes  = nq * qd * 16
    prp_bytes = nq * qd * MAX_PRP_ENTRIES * 8
    meta_bytes = nq * 64
    total_bytes = sq_bytes + cq_bytes + prp_bytes + meta_bytes
    no_prp_bytes = sq_bytes + cq_bytes + meta_bytes

    total_bits = total_bytes * 8
    no_prp_bits = no_prp_bytes * 8
    area_mm2 = total_bits * BITCELL_AREA_UM2 * OVERHEAD_FACTOR / 1e6
    area_no_prp_mm2 = no_prp_bits * BITCELL_AREA_UM2 * OVERHEAD_FACTOR / 1e6

    return {
        "sq_kb":      sq_bytes / 1024,
        "cq_kb":      cq_bytes / 1024,
        "prp_kb":     prp_bytes / 1024,
        "meta_kb":    meta_bytes / 1024,
        "total_kb":   total_bytes / 1024,
        "no_prp_kb":  no_prp_bytes / 1024,
        "total_bits":    total_bits,
        "area_mm2":      round(area_mm2, 4),
        "area_no_prp_mm2": round(area_no_prp_mm2, 4),
    }


def main():
    print("=" * 70)
    print("IO-Uncore SRAM Area Estimation (ASAP7 7nm)")
    print(f"Bitcell: {BITCELL_AREA_UM2} um^2/bit, Overhead: {OVERHEAD_FACTOR}x")
    print("=" * 70)
    print()

    header = f"{'Config':<12} {'SQ':>8} {'CQ':>8} {'PRP':>8} {'Meta':>8} {'Total':>10} {'4KB-only':>10} {'Area':>10} {'4KB Area':>10}"
    print(header)
    print(f"{'':12} {'(KB)':>8} {'(KB)':>8} {'(KB)':>8} {'(KB)':>8} {'(KB)':>10} {'(KB)':>10} {'(mm2)':>10} {'(mm2)':>10}")
    print("-" * len(header))

    results = []
    for cfg in CONFIGS:
        r = compute_sram(cfg["nq"], cfg["qd"])
        r["name"] = cfg["name"]
        r["label"] = cfg["label"]
        r["nq"] = cfg["nq"]
        r["qd"] = cfg["qd"]
        results.append(r)
        print(f"{cfg['name']+' '+cfg['label']:<12} {r['sq_kb']:>8.0f} {r['cq_kb']:>8.0f} "
              f"{r['prp_kb']:>8.0f} {r['meta_kb']:>8.0f} {r['total_kb']:>10.0f} "
              f"{r['no_prp_kb']:>10.0f} {r['area_mm2']:>10.4f} {r['area_no_prp_mm2']:>10.4f}")

    print()
    print("Reference: Intel Sapphire Rapids I/O tile ~40 mm^2")
    print(f"Config D total: {results[3]['area_mm2']:.3f} mm^2 = "
          f"{results[3]['area_mm2']/40*100:.1f}% of I/O tile")

    # Save JSON for plot_ppa.py
    with open("reports/sram_sizing.json", "w") as f:
        json.dump(results, f, indent=2)
    print(f"\nResults saved to reports/sram_sizing.json")


if __name__ == "__main__":
    main()
