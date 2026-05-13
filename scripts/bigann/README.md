# BigANN trace benchmark scripts

Replay the captured DiskANN/BigANN trace through the simulated SimpleSSD
device to anchor the §4.1 *workload-equivalent* claim in the IO-Uncore
paper. The pair compares directly against the synthetic 4 KB random
read sweep (`scripts/phase1_4k/`) using the **same** SPDK build, the
**same** SimpleSSD device, the **same** State_Dealloc-split
instrumentation — only the workload generator differs.

## What's here

| File | Role |
|---|---|
| `trace_to_binary.py` | Convert canonical trace CSV (`docs/DISKANN_TRACE_CAPTURE.md` format) to packed 16-bytes/entry binary. Run on the host before each capture-source change. |
| `phase1_trace_replay.sh` | In-guest runner. Mirrors `scripts/phase1_4k/phase1_run.sh` structure but invokes `spdk_nvme_perf --trace-file <bin>` so the workload generator pulls IOs from the trace instead of issuing random IOs. Drive via the host driver below; not for direct invocation. |
| `driver_phase1_trace.sh` | Host driver — auto-only, virtio-9p only. One command launches gem5, mounts `/mnt/9p`, runs the in-guest replay, watches for `PHASE1_RUNSCRIPT_DONE`, auto-stops gem5. Mirrors `scripts/phase1_4k/driver_phase1_multicore.sh`. |
| `plot_trace_vs_synthetic.py` | Side-by-side bar chart: synthetic vs trace cycles/IO at the same QD/qpairs. Anchors the §4.1 prose. |
| `README.md` | This file. |

## Trace data location

```
artifacts/bigann/
├── diskann_bigann_trace.csv      # canonical CSV (44 MB, 1.23 M events)
├── diskann_bigann_trace.bin      # packed binary (19 MB), what the SPDK app reads
└── diskann_bigann_trace.sha256
```

The `.bin` is generated from the `.csv` via `trace_to_binary.py`. Both live
under the project workspace so virtio-9p exposes them inside the gem5 guest
as `/mnt/9p/artifacts/bigann/...`.

## Underlying SPDK patch

`spdk/app/spdk_nvme_perf/perf.c` was extended with a `--trace-file <path>`
long option (val 276):

| Source location | Change |
|---|---|
| globals (after `g_workload_type`) | `struct perf_trace_entry`, `g_trace_path`, `g_trace_entries`, `g_trace_count`, `g_trace_idx`, `load_trace_file()` |
| `submit_single_io()` | If `g_trace_entries` is non-NULL, pull next entry from trace; otherwise existing zipf/random/sequential paths fire as before |
| arg-parse table + switch | `PERF_TRACE_FILE` define + `case` arm |
| `parse_args()` epilogue | Calls `load_trace_file()` once after option parsing succeeds; forces `g_rw_percentage = 100` since the trace is read-only |

The patch is dormant when `--trace-file` is unset, so the same
`docker_artifacts/guest_spdk_nvme_perf` binary handles both the synthetic
4 KB random-read sweep AND the trace-replay sweep — no rebuild needed
between modes.

To refresh the binary after any further edit to the SPDK source tree:
```bash
scripts/build_spdk_docker.sh   # ~90 s
```

## End-to-end workflow (one command)

After the SPDK rebuild and after the BigANN host capture has produced the
trace files at `artifacts/bigann/`, run **one command** for each
UncoreMode:

```bash
# Mode 0 (baseline / no IO-Uncore)
SSD_CFG=fast_ssd_highiops.cfg ./scripts/bigann/driver_phase1_trace.sh \
    --auto --qd 128 --steady-time 1 --uncore-mode 0 \
    --tag paper_trace_mode0

# Mode 2A (transparent CQ batching)
SSD_CFG=fast_ssd_highiops.cfg ./scripts/bigann/driver_phase1_trace.sh \
    --auto --qd 128 --steady-time 1 --uncore-mode 1 \
    --tag paper_trace_mode1

# Mode 2B (poll-lite host patch)
SSD_CFG=fast_ssd_highiops.cfg ./scripts/bigann/driver_phase1_trace.sh \
    --auto --qd 128 --steady-time 1 --uncore-mode 2 \
    --tag paper_trace_mode2
```

The driver patches the cfg, generates a readfile, launches gem5 in tmux,
mounts virtio-9p inside the guest, runs `phase1_trace_replay.sh`, and
auto-stops gem5 on `PHASE1_RUNSCRIPT_DONE`. No manual guest-side step.

## Output structure

Identical schema to the synthetic sweep, with two extra columns documenting
the trace source:

```
results/phase1_runs/<tag>/core0_qp1/
├── phase1_results.csv     # one row per (IO_SIZE, QD, RUN_ID); same 34 columns
│                          # as scripts/phase1_4k/ runs PLUS Trace_Source +
│                          # Trace_Entries
├── phase1_errors.log
└── logs/
    ├── run_s4096_q128_r1.log
    └── cycle_breakdown_s4096_q128_r1.csv   # per-IO timing incl. State_Dealloc split
```

## Plot the comparison

```bash
conda run -n llm python scripts/bigann/plot_trace_vs_synthetic.py \
    --results results/phase1_runs \
    --synthetic-tag paper_qdsweep_mode0 \
    --trace-tag    paper_trace_mode0 \
    --qd 128 --io-size 4096
# → plots/trace_vs_synthetic.{png,pdf}
```

The script prints a verdict line:

```
Verdict (cycles/IO):
  synthetic : ... ns/IO
  trace     : ... ns/IO
  delta     : ±X.X%  (within ±10% — paper claim holds | exceeds ±10% — investigate)
```

If the delta is within ~10%, §4.1 can claim the synthetic 4 KB random
read benchmark is workload-equivalent to a real DiskANN/BigANN trace.

## Wall-time expectation

Same regime as `phase1_4k/`: ~60 min Linux boot + ~10–25 min per data
point at `--steady-time 1` on a quiescent server. One Mode = ~90 min.
Three Modes ≈ 4–5 h, fits one overnight session next to the synthetic
sweep.

## Cross-references

- Capture procedure: `docs/DISKANN_TRACE_CAPTURE.md`
- Paper integration: `docs/PAPER_CHAPTER_PLAN.md` §4.1 ("trace-equivalent" prose)
- Synthetic sweep companion: `scripts/phase1_4k/`
- Shared infra: `scripts/boot_gem5.sh`, `scripts/console_gem5.sh`, `scripts/build_spdk_docker.sh`
