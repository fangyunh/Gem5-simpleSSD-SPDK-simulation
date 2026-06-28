"""Summarize the IAU performance gain across BigANN op-mix workloads.

Reads the baseline (UncoreMode 0) and full-IAU (UncoreMode 2) trace-replay
results for three workloads -- read (canonical), write-only, and rw50 -- and
emits results/bigann_workload_gain_summary.csv plus a printed table.

The question this answers: does the IAU IOPS gain differ by op-mix?

Notes:
- Cycles_Per_IO is 0 in these AtomicSimpleCPU runs (no HW perf counters), so
  per-IO compute cost is taken as the sum of the per-stage *_ns columns, which
  the patched spdk_nvme_perf populates directly. ns x 2 GHz ~= host cycles.
"""
from __future__ import annotations
import csv, os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# workload -> {mode -> results csv}
DATASETS = {
    "read": {
        0: "results/bigann_trace_1c1qp/paper_trace_mode0_20260510/core0_qp1/phase1_results.csv",
        2: "results/bigann_trace_1c1qp/paper_trace_mode2_20260510/core0_qp1/phase1_results.csv",
    },
    "write": {
        0: "results/bigann_write_1c1qp/bigann_write_mode0_20260624/core0_qp1/phase1_results.csv",
        2: "results/bigann_write_1c1qp/bigann_write_mode2_20260624/core0_qp1/phase1_results.csv",
    },
    "rw50": {
        0: "results/bigann_rw50_1c1qp/bigann_rw50_mode0_20260624/core0_qp1/phase1_results.csv",
        2: "results/bigann_rw50_1c1qp/bigann_rw50_mode2_20260624/core0_qp1/phase1_results.csv",
    },
}

# Per-stage ns columns whose sum approximates per-IO host CPU time.
STAGE_NS = [
    "Submit_Logic_ns", "Completion_Logic_ns",
]


def load(path):
    """QD -> row dict (CSV-correct: handles the quoted histogram column)."""
    out = {}
    with open(os.path.join(ROOT, path)) as f:
        rows = list(csv.DictReader((ln for ln in f if not ln.startswith("#"))))
    for r in rows:
        out[int(r["QD"])] = r
    return out


def stage_ns(row):
    return sum(float(row.get(c, 0) or 0) for c in STAGE_NS)


def main():
    qds = [16, 32, 64, 128]
    out_rows = []
    for wl, modes in DATASETS.items():
        b = load(modes[0])
        u = load(modes[2])
        for qd in qds:
            if qd not in b or qd not in u:
                continue
            bi, ui = float(b[qd]["IOPS"]), float(u[qd]["IOPS"])
            bns, uns = stage_ns(b[qd]), stage_ns(u[qd])
            out_rows.append({
                "workload": wl, "qd": qd,
                "baseline_iops": round(bi, 1),
                "iau_iops": round(ui, 1),
                "iops_gain": round(ui / bi, 4),
                "baseline_submit+compl_ns": round(bns, 1),
                "iau_submit+compl_ns": round(uns, 1),
                "ns_reduction_pct": round(100 * (bns - uns) / bns, 1) if bns else 0.0,
                "baseline_p99_us": float(b[qd]["p99_Latency"]),
                "iau_p99_us": float(u[qd]["p99_Latency"]),
            })

    out_path = os.path.join(ROOT, "results/bigann_workload_gain_summary.csv")
    cols = list(out_rows[0].keys())
    with open(out_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        w.writerows(out_rows)

    # Printed table.
    print(f"{'workload':<8}{'QD':>5}{'base IOPS':>13}{'IAU IOPS':>13}"
          f"{'gain':>8}{'submit+compl ns b->IAU':>26}{'p99us b->IAU':>18}")
    print("-" * 91)
    for r in out_rows:
        print(f"{r['workload']:<8}{r['qd']:>5}{r['baseline_iops']:>13,.0f}"
              f"{r['iau_iops']:>13,.0f}{r['iops_gain']:>8.3f}"
              f"{r['baseline_submit+compl_ns']:>13.0f} ->{r['iau_submit+compl_ns']:>9.0f}"
              f"{r['baseline_p99_us']:>10.1f} ->{r['iau_p99_us']:>6.1f}")

    print("\nMean IOPS gain by workload (across QD sweep):")
    for wl in DATASETS:
        gains = [r["iops_gain"] for r in out_rows if r["workload"] == wl]
        print(f"  {wl:<6} {sum(gains)/len(gains):.3f}x  "
              f"(min {min(gains):.3f}x, max {max(gains):.3f}x)")
    print(f"\nWrote {out_path}")


if __name__ == "__main__":
    main()
