# 4 KB random-read evaluation scripts (Phase 1)

All scripts that drive, run, and plot the 4 KB random-read sweep used in
the IO-Uncore paper's §2 (Figure 2 per-IO breakdown) and §4 (Figure 3
bracket, Figure 4 latency trade-off) live here.

For BigANN trace capture/replay scripts (the §4.1 workload-equivalent
data point) see `../bigann/`.

For shared infrastructure (gem5 boot/stop/console, SPDK Docker rebuild,
disk image management) see the parent `scripts/` directory.

## Inventory

### Host-side drivers

| Script | Role |
|---|---|
| `driver_phase1.sh` | Single-core / single-qpair sweep launcher. PRIMARY entry point. Supports the full `--cores / --qpairs / --qd / --ios / --uncore-mode` matrix. |
| `driver_phase1_multicore.sh` | Multi-core invariance launcher. Runs `phase1_run_multicore_gem5.sh` inside gem5 with a spanning core mask per `--core-counts` value. Auto-only, virtio-9p only. |
| `driver_bdev.sh` | bdev malloc/null baseline launcher (sanity checks SPDK independent of SimpleSSD). |
| `run_sweep_baseline.sh` | Convenience wrapper that invokes `driver_phase1.sh` for every (IO_SIZE, QD) combination sequentially. |

### In-guest runners (executed inside the gem5 guest)

| Script | Role |
|---|---|
| `phase1_run.sh` | Single-core sweep body. Configures hugepages, binds NVMe to SPDK, runs `spdk_nvme_perf`, aggregates `cycle_breakdown.csv` into `phase1_results.csv`. Honors `UNCORE_MODE` → `SPDK_UNCORE_MODE_B`. |
| `phase1_run_multicore_gem5.sh` | Multi-core sweep body. Builds spanning core mask `(1<<N)-1` per regime; emits the State_Dealloc split columns. |
| `phase1_run_multicore.sh` | **DEPRECATED 2026-05-09** (real-hardware-only; host-PMU reads, 5.3 GHz core filter, hard-coded PCI). Kept on disk for historical reference; do NOT invoke. |
| `phase1_bdev.sh` | bdev sweep body (uses SPDK's bdev_perf). |
| `extract_phase1_results.sh` | Mounts the gem5 disk image to copy results out. **DEPRECATED 2026-05-09** (needs sudo; virtio-9p mode writes results directly to the host workspace). Kept for the rare non-9p configuration. |

### Plot / analysis scripts

| Script | Output |
|---|---|
| `plot_io_breakdown.py` | Figure 2 — per-IO software-stage stacked bars (with State_Dealloc Library/Callback split) → `plots/io_stage_breakdown.{png,pdf}` |
| `plot_phase1.py` | Phase 1 IOPS / latency curves |
| `plot_bracket.py` | Figure 3 — cycles/IO + DRAM bytes/IO bracket vs qpairs across SPDK / Mode 2A / Mode 2B |
| `plot_p99_vs_cqbatchn.py` | Figure 4 — p99 latency vs CQ batch parameter |
| `plot_multicore_gem5.py` | Per-core invariance figure (stacked bars + flatness curve) → `plots/multicore_invariance.{png,pdf}` |
| `plot_multicore.py` | **DEPRECATED 2026-05-09** (consumes host-PMU columns gem5 doesn't populate). Use `plot_multicore_gem5.py` instead. |
| `plot_bdev.py` | bdev baseline plot |
| `summarize_phase1.py` | CSV inspector / quick stats |

### Helpers

| Script | Role |
|---|---|
| `apply_ssd_profile.py` | Applies a named SSD profile (e.g., `fast_ssd_highiops`) to `fast_ssd.cfg` — convenience wrapper for the in-config sed substitutions the drivers do automatically. |

## Typical workflows

```bash
# Single-core sweep (current PRIMARY path)
SSD_CFG=fast_ssd_highiops.cfg ./scripts/phase1_4k/driver_phase1.sh --auto \
  --qd "16 32 64 128" --ios 4096 --qpairs 1 \
  --repeats 1 --steady-time 5 --uncore-mode 0 \
  --tag phase1_paper_qdsweep_mode0

# Multi-core invariance (one overnight session)
SSD_CFG=fast_ssd_highiops.cfg ./scripts/phase1_4k/driver_phase1_multicore.sh \
  --auto --core-counts "1 2" \
  --qd 128 --ios 4096 --qpairs 1 \
  --repeats 1 --steady-time 5 --uncore-mode 0 \
  --tag verify_multicore

# Plot Figure 2 (per-IO breakdown with State_Dealloc split)
conda run -n llm python scripts/phase1_4k/plot_io_breakdown.py \
  --results results/phase1_runs --io-size 4096 \
  --out plots/io_stage_breakdown
```

For per-script flag references, run any driver with `--help`.
