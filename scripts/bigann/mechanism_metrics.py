"""Tier-A mechanism metrics for the IAU paper: the CPU-side benefits that the
current IOPS/cycles/latency story does not surface.

For each workload (read/write/rw50) and QD, compare baseline (UncoreMode 0) vs
full IAU (UncoreMode 2) on:
  - Completion/poll efficiency  -> the CQ-Engine win
      Completions_Per_Call, Polls (for ~equal completions), Scans_Per_Completion
  - Address-translation offload  -> Addr_Xlate_ns per IO
  - Energy framing               -> host cycles reclaimed/s vs IAU logic power

Host model is AtomicSimpleCPU @ 2 GHz and is the binding bottleneck in the
fast-path SSD model, so cycles/IO = HOST_HZ / IOPS is the host-saturation cost.

Emits results/bigann_mechanism_metrics.csv + a printed summary.
"""
from __future__ import annotations
import csv, os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HOST_HZ = 2.0e9          # AtomicSimpleCPU @ 2 GHz (see project_host_cpu_model)
IAU_MW_LO, IAU_MW_HI = 14, 49   # ASAP7 7nm logic power @1GHz (synth results)

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


def load(path):
    with open(os.path.join(ROOT, path)) as f:
        return {int(r["QD"]): r
                for r in csv.DictReader(l for l in f if not l.startswith("#"))}


def main():
    qds = [16, 32, 64, 128]
    rows = []
    for wl, modes in DATASETS.items():
        b, u = load(modes[0]), load(modes[2])
        for qd in qds:
            if qd not in b or qd not in u:
                continue
            bi, ui = float(b[qd]["IOPS"]), float(u[qd]["IOPS"])
            cyc_b, cyc_u = HOST_HZ / bi, HOST_HZ / ui
            freed_per_s = (cyc_b - cyc_u) * ui           # host cycles reclaimed / s
            rows.append({
                "workload": wl, "qd": qd,
                "cpl_per_call_base": round(float(b[qd]["Completions_Per_Call"]), 2),
                "cpl_per_call_iau": round(float(u[qd]["Completions_Per_Call"]), 2),
                "polls_base": int(float(b[qd]["Polls"])),
                "polls_iau": int(float(u[qd]["Polls"])),
                "poll_reduction_x": round(float(b[qd]["Polls"]) / float(u[qd]["Polls"]), 1),
                "scans_per_cpl_base": round(float(b[qd]["Scans_Per_Completion"]), 4),
                "scans_per_cpl_iau": round(float(u[qd]["Scans_Per_Completion"]), 4),
                "addr_xlate_ns_base": round(float(b[qd]["Addr_Xlate_ns"]), 1),
                "addr_xlate_ns_iau": round(float(u[qd]["Addr_Xlate_ns"]), 1),
                "cyc_per_io_base": round(cyc_b, 1),
                "cyc_per_io_iau": round(cyc_u, 1),
                "host_cyc_freed_per_s": round(freed_per_s, 0),
                "freed_cyc_per_s_per_mW_lo": round(freed_per_s / IAU_MW_HI, 0),
                "freed_cyc_per_s_per_mW_hi": round(freed_per_s / IAU_MW_LO, 0),
            })

    out = os.path.join(ROOT, "results/bigann_mechanism_metrics.csv")
    with open(out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader(); w.writerows(rows)

    print("== Completion/poll efficiency (the CQ-Engine win) ==")
    print(f"{'wl':<6}{'QD':>4}{'cpl/call b->IAU':>20}{'polls b->IAU (x)':>26}"
          f"{'scans/cpl b->IAU':>20}")
    for r in rows:
        print(f"{r['workload']:<6}{r['qd']:>4}"
              f"{r['cpl_per_call_base']:>9.1f} ->{r['cpl_per_call_iau']:>7.1f}"
              f"{r['polls_base']:>13,} ->{r['polls_iau']:>8,} ({r['poll_reduction_x']:>4.0f}x)"
              f"{r['scans_per_cpl_base']:>9.4f} ->{r['scans_per_cpl_iau']:>7.4f}")

    print("\n== Address-translation offload + energy framing (per IO) ==")
    print(f"{'wl':<6}{'QD':>4}{'addr_xlate ns b->IAU':>24}{'cyc/IO b->IAU':>18}"
          f"{'host cyc freed/s':>20}")
    for r in rows:
        print(f"{r['workload']:<6}{r['qd']:>4}"
              f"{r['addr_xlate_ns_base']:>13.0f} ->{r['addr_xlate_ns_iau']:>8.0f}"
              f"{r['cyc_per_io_base']:>9.0f} ->{r['cyc_per_io_iau']:>6.0f}"
              f"{r['host_cyc_freed_per_s']:>20,.0f}")

    # Energy headline at the deepest QD per workload.
    print(f"\nEnergy framing (IAU logic = {IAU_MW_LO}-{IAU_MW_HI} mW @1GHz):")
    for wl in DATASETS:
        r = [x for x in rows if x["workload"] == wl][-1]   # QD128
        print(f"  {wl:<6} QD{r['qd']}: reclaims {r['host_cyc_freed_per_s']/1e6:,.0f}M "
              f"host cyc/s -> {r['freed_cyc_per_s_per_mW_lo']/1e3:,.0f}-"
              f"{r['freed_cyc_per_s_per_mW_hi']/1e3:,.0f} K host-cyc/s per mW of uncore")
    print(f"\nWrote {out}")


if __name__ == "__main__":
    main()
