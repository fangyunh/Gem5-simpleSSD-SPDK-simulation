# IO-Uncore Paper — Pre-submission Implementation TODO

**Target venue:** IEEE Computer Architecture Letters (CAL) — 4-page double-column position paper
**Plan-mode artifact:** `docs/PAPER_CHAPTER_PLAN.md`
**Last updated:** 2026-05-09

This file consolidates everything that must land in the repository **before the
paper can be submitted with defensible evidence**. Each item has a file path,
estimated effort, blocking dependencies, and a verification step.

---

## (0) Context for a new agent — read this section first

### (0.1) What this research is

This project proposes an **IO-Uncore**: a hardware engine integrated into the
CPU's I/O chiplet that takes over NVMe queue execution from software. The
motivation is that AI retrieval workloads (vector search, RAG, recommendation)
will soon drive NVMe SSDs at 10–100 M IOPS per device, while host CPU software
stacks (SPDK, io_uring) cap at ~4 M IOPS per core because every I/O traverses
DRAM-resident queues, MMIO doorbells, and a polling loop. The IO-Uncore
relocates the NVMe queue state machines into private SRAM next to the PCIe
root complex, eliminating the per-I/O DRAM and MMIO costs that bound software.

The architectural argument mirrors the on-die memory-controller integration of
the early 2000s (AMD K8 / Intel Nehalem): the I/O chiplet should absorb queue
execution the same way the chiplet absorbed memory control then.

### (0.2) The simulation stack (three layers)

```
HOST  -->  gem5.opt (full-system X86 simulator)
              |
              +-- Linux 5.4.49 guest kernel (vmlinux-5.4.49)
              |
              +-- SimpleSSD NVMe device model
              |     +-- nvme.UncoreMode = 0/1/2 toggles the device-side
              |         IO-Uncore (CQ batching, doorbell aggregation,
              |         hint register at BAR0+0x2000)
              |
              +-- diod (host-side 9p file server, child of gem5)
                    |
                    +-- exposes the workspace as /mnt/9p in guest
                    |
              In-guest:
                    +-- spdk_nvme_perf (workload driver, calls SPDK lib)
                          +-- SPDK NVMe library (Mode 2B host patch lives here)
```

The whole stack lives in this repository — there are no external services. A
single run boots Linux inside gem5, mounts the host workspace via 9p, runs
`spdk_nvme_perf` against the simulated SimpleSSD device, writes a CSV, and
exits.

### (0.3) Where the implementation lives (directory map)

```
SimpleSSD_Gem5_simulation/
├── SimpleSSD-FullSystem/         # gem5 source tree (forked for SimpleSSD)
│   ├── build/X86/gem5.opt        # the simulator binary (~1 GB)
│   └── src/dev/storage/
│       ├── nvme_interface.cc     # gem5-side NVMe device wrapper
│       └── simplessd/hil/nvme/
│           ├── controller.cc     # *** device-side IO-Uncore IS HERE ***
│           ├── controller.hh     #     (UncoreMode enum, batching state machine)
│           └── config.cc/hh      #     (UncoreMode/CQBatchN/CQBatchT/DBBatchB knobs)
│
├── spdk/                         # SPDK source tree
│   └── lib/nvme/
│       ├── nvme_pcie_internal.h  # *** Mode 2B host patch +8 LOC ***
│       ├── nvme_pcie.c           # *** Mode 2B host patch +22 LOC ***
│       ├── nvme_pcie_common.c    # *** Mode 2B host patch +15 LOC ***
│       └── nvme_qpair.c          # SPDK per-stage instrumentation (cycle_breakdown CSV)
│
├── docker_artifacts/
│   ├── guest_spdk_nvme_perf      # the rebuilt SPDK binary (after Item 2)
│   └── guest_openssl11/          # OpenSSL libs the guest needs at runtime
│
├── scripts/
│   ├── boot_gem5.sh                  # start/stop/status the gem5 daemon (shared)
│   ├── console_gem5.sh               # serial console attach (shared)
│   ├── build_spdk_docker.sh          # Docker SPDK rebuild (shared)
│   ├── build_guest_kernel_vfio.sh    # custom guest kernel (shared)
│   ├── bake_disk_image.sh            # NEEDS sudo — DO NOT USE; virtio-9p makes it unnecessary
│   ├── resize_disk_image.sh          # NEEDS sudo — DO NOT USE
│   ├── scripts_manual.md             # top-level scripts index — READ THIS
│   ├── phase1_4k/                    # 4 KB random-read evaluation (this paper's §2 + §4)
│   │   ├── README.md                 # full inventory + workflows
│   │   ├── driver_phase1.sh          # PRIMARY entry point for single-core sweeps
│   │   ├── driver_phase1_multicore.sh # multi-core entry point (auto-only, 9p-only) — 2026-05-09
│   │   ├── phase1_run.sh             # in-guest single-core runner
│   │   ├── phase1_run_multicore_gem5.sh # in-guest multi-core runner — 2026-05-09
│   │   ├── phase1_run_multicore.sh   # DEPRECATED 2026-05-09 — real-hardware only
│   │   ├── driver_bdev.sh            # bdev malloc/null baseline driver
│   │   ├── phase1_bdev.sh            # bdev sweep body
│   │   ├── run_sweep_baseline.sh     # sequential (IO_SIZE,QD) sweep wrapper
│   │   ├── extract_phase1_results.sh # NEEDS sudo — DO NOT USE
│   │   ├── apply_ssd_profile.py      # SSD profile patcher
│   │   ├── summarize_phase1.py       # CSV inspector
│   │   ├── plot_io_breakdown.py      # Figure 2 generator (with State_Dealloc split)
│   │   ├── plot_bracket.py           # Figure 3 generator
│   │   ├── plot_p99_vs_cqbatchn.py   # Figure 4 generator
│   │   ├── plot_phase1.py            # IOPS/latency curves
│   │   ├── plot_multicore_gem5.py    # per-core invariance plot — 2026-05-09
│   │   ├── plot_multicore.py         # DEPRECATED 2026-05-09 — host-PMU
│   │   └── plot_bdev.py              # bdev baseline plot
│   └── bigann/                       # BigANN trace capture/replay (paper §4.1) — implemented 2026-05-09
│       ├── README.md                 # full inventory + workflow
│       ├── trace_to_binary.py        # CSV → 16-bytes/entry .bin converter
│       ├── phase1_trace_replay.sh    # in-guest runner (mirrors phase1_run.sh)
│       ├── driver_phase1_trace.sh    # host driver, auto-only, 9p-only
│       └── plot_trace_vs_synthetic.py # synthetic vs trace cycles/IO comparison
│
├── assets/
│   ├── x86-ubuntu.img            # 16 GB Ubuntu 18.04 disk image (the guest)
│   └── vmlinux-5.4.49            # custom kernel (vfio + virtio-9p built-in)
│
├── results/
│   ├── phase1_runs/<tag>/        # per-run output (CSVs land here)
│   └── phase1_qd*_iouncore*/     # earlier runs (pre-retune; 75K IOPS regime)
│
├── logs/
│   ├── gem5.out                  # gem5 stdout (the primary debug log)
│   ├── gem5.pid                  # PID of running gem5
│   └── driver_phase1_<tag>.log   # combined driver + guest log
│
├── docs/
│   ├── PAPER_CHAPTER_PLAN.md     # *** read first — what the paper claims ***
│   ├── PAPER_IMPL_TODO.md        # this file
│   ├── PROJECT_CONTEXT.md        # comprehensive simulator onboarding
│   ├── AGENT_HANDOFF_PROMPT.md   # the prompt this agent is operating under
│   ├── IO Uncore design plan.md  # research proposal (for background)
│   ├── IOUncore_discussion.md    # adversarial review of the proposal
│   ├── IO-Uncore RTL Design Specification — Phase 3 Silicon Feasibility.md
│   └── standard_4KB16KB_read.pdf # earlier-data report; for figure-style reference
│
├── fast_ssd.cfg                  # baseline SimpleSSD config (~75K IOPS)
├── fast_ssd_highiops.cfg         # *** retuned high-IOPS config — use this ***
├── CLAUDE.md                     # project commands and conventions
└── plots/                        # generated figures
```

### (0.4) Where to find help (read order)

If you get confused, read in this order:

1. **`docs/PAPER_CHAPTER_PLAN.md`** — the paper's intent, the four figures'
   specifications, and the INSIGHT collection. Tells you *what claim* each
   piece of data anchors. Read top to §3 thoroughly.
2. **`docs/PROJECT_CONTEXT.md`** — the simulator's onboarding doc. §1 (goals),
   §3 (directory layout), §6 (source-level fixes), §13 (CSV schema and how to
   interpret it). Read this whenever a CSV column or a sim parameter is
   unclear.
3. **`CLAUDE.md`** — project-level commands (gem5 build, disk image bake,
   driver invocation). Read when you need to run something.
4. **`scripts/scripts_manual.md`** — per-script reference and the canonical
   end-to-end workflow.
5. **`docs/AGENT_HANDOFF_PROMPT.md`** — the operating prompt; lists tasks,
   guardrails, and red flags. Read once at session start.
6. **This file (`docs/PAPER_IMPL_TODO.md`)** — the task list (sections (1)
   through (6) below).

If something looks like a simulator bug, also consult `docs/PROJECT_CONTEXT.md
§6` (source-level fixes already applied) and `§14` (debugging reference,
common failure modes).

### (0.5) Goals — what "done" looks like

The agent's mission is to produce four figures and one final report:

| Output | Lives at | Anchors which paper claim |
|---|---|---|
| **Figure 2** — per-IO software cost decomposition | `plots/fig2_io_stage_breakdown.{png,pdf}` | §2.1 — "where do CPU cycles per I/O actually go?" |
| **Figure 3** — cycles/IO + DRAM bytes/IO bracket vs qpairs across SPDK / Mode 2A / Mode 2B | `plots/fig3_bracket.{png,pdf}` | §4.2 — "Mode 2A is lower bound, Mode 2B is upper bound" |
| **Figure 4** — p99 latency vs CQ batch parameter | `plots/fig4_p99_vs_cqbatchn.{png,pdf}` | §4.3 — "batching does not regress SLO" |
| **Final report** | `docs/EXPERIMENT_RESULTS.md` | summary table + side-by-side regime comparison |

All four require **at least the single-core sweep** (item 3 below) running on
the **retuned high-IOPS config** (item 1) with the **rebuilt SPDK** (item 2).
The dual-core invariance sentence (one extra line in §4.2) requires item (4)
to be fixed first.

---

## (0.6) Operating discipline — read carefully, this is where agents fail

These five conventions are not negotiable.

### NO sudo, ever

This agent runs on a Linux server **without root privileges**. The entire
workflow is designed around `virtio-9p` sharing so no operation needs root.
Specifically, **never invoke**:

- `sudo` (any command)
- `scripts/bake_disk_image.sh` (would require sudo)
- `scripts/phase1_4k/extract_phase1_results.sh` (would require sudo, and is unnecessary
  because results land directly on the host workspace via 9p)
- `scripts/resize_disk_image.sh` (would require sudo)

Concrete consequences:
- **SPDK rebuild does NOT need a disk image bake.** The guest reads
  `guest_spdk_nvme_perf` from `/mnt/9p/docker_artifacts/` (which is the host
  workspace). Just rebuild SPDK in user-space, copy the binary into
  `docker_artifacts/`, and the next gem5 launch picks it up automatically.
- **Results extraction is automatic.** Each run's CSVs land at
  `results/phase1_runs/<tag>/core<N>_qp<Q>/phase1_results.csv` on the host
  filesystem in real time during the run.
- **Edits to `phase1_run.sh` take effect immediately.** Because the guest
  pulls the script content via the readfile mechanism on each boot, just
  save the file and re-launch.

If you encounter any step that *seems* to need root, that is a bug in the
workflow — STOP and report it; do not work around it with `sudo`.

### Always launch sims via `tmux`

### Always launch sims via `tmux`

A single sweep can take 5–20 hours of wall time. SSH disconnects, terminal
closes, agent timeouts — all of those will kill an unwatched gem5 instance and
waste the run. **Every long-running command goes through `tmux`.**

```bash
# Launch a run:
tmux new -d -s sweep_baseline                    # detached session
tmux send -t sweep_baseline "SSD_CFG=fast_ssd_highiops.cfg \
  ./scripts/phase1_4k/driver_phase1.sh --auto \
  --qd '16 32 64 128' --ios '4096' --qpairs '1' \
  --repeats 3 --steady-time 5 --uncore-mode 0 \
  --tag run_baseline" Enter

# Watch progress (read-only; agent attaches occasionally):
tmux capture-pane -t sweep_baseline -p | tail -30

# Confirm it's still alive:
./scripts/boot_gem5.sh status
```

Never run gem5 from a bare shell. If you need an interactive guest console,
use `./scripts/console_gem5.sh` in a separate tmux pane.

### Do NOT poll the log frequently

A gem5 sim makes very slow simulated-time progress (~1000–5000× wall
slowdown). New lines on `logs/gem5.out` may appear only every 10–30 minutes
during steady-state. **Polling every minute is wasted work and burns tokens.**

The right cadence:

| Phase | Polling interval |
|---|---|
| Right after launch (verify gem5 booted) | check once at +5 min |
| Mid-run (waiting for completion) | every 15–30 min |
| If you see "PHASE1_RUNSCRIPT_DONE" or the SPDK statistics block in the tmux | check every 1–2 min until gem5 is gone |

Use `Bash(run_in_background)` or sleep-and-poll with a long interval, not
short busy loops.

### gem5 does NOT always auto-stop after a sweep completes — watch for this

A known operational quirk: `driver_phase1.sh --auto` is *supposed* to stop
gem5 after the readfile script prints `PHASE1_RUNSCRIPT_DONE`. In practice,
**gem5 sometimes hangs and does not exit on its own.** The `phase1_auto` tmux
session shows the workload finishing (IOPS / latency stats printed by
`spdk_nvme_perf`, the "Saving to: ..." line, etc.), then the session sits idle
with gem5 still alive.

How to detect that the sim is *actually done* (not just slow):

1. `tmux capture-pane -t <session> -p | tail -50` — look for either of:
   - The literal string `PHASE1_RUNSCRIPT_DONE`
   - The SPDK summary block with `IOPS`, `MiB/s`, `Average`, `min`, `max`
     latency in microseconds
   - The driver's `[hh:mm:ss] Detected readfile script completion. Stopping gem5...`
2. If either marker has been visible for more than ~3 minutes AND gem5 is
   still alive (`./scripts/boot_gem5.sh status` says "running"), it is hanging.

When that happens, stop gem5 manually:

```bash
./scripts/boot_gem5.sh stop          # graceful stop by PID file
./scripts/boot_gem5.sh status        # confirm gone
tmux kill-session -t <session_name>  # close the tmux
```

No extract step needed. With virtio-9p (default), results have already
been written to `results/phase1_runs/<tag>/` on the host workspace by
the time the workload finishes. The gem5 hang only blocks `m5 exit`,
not the CSV writes that happened earlier.

**Do NOT** `kill -9` the gem5 process. It leaves `diod` orphaned and may
require a reboot. Always use `boot_gem5.sh stop`.

### Never run two gem5 instances in parallel

gem5 is single-threaded but greedy. Two concurrent gem5 processes thrash the
host's cores and slow each other down. Run sweeps **strictly sequentially**:
finish baseline, then Mode A, then Mode B.

---

## At-a-glance dependency graph

```
       (1) fast_ssd_highiops.cfg                  [DRAFTED — review needed]
                          |
                          v
       (2) Verify >=10 M IOPS at QD=128           [GATING]
                          |
                          v
       (3) SPDK Mode 2B host patch                [PATCHED — needs rebuild]
                          |
                          v
       Re-bake disk image with patched SPDK
                          |
                          v
       (4) Multi-core script gem5 port            [BROKEN — needs rewrite]   *
                          |                          (* gates the dual-core
                          v                            invariance claim only)
       Three-regime sweep: UncoreMode = 0/1/2 -> Fig 2 + Fig 3 + Fig 4
                          |
                          v
       (5) DONE 2026-05-09: split State_Dealloc instrumentation
                          |
                          v
       (6) REQUIRED; partially DONE 2026-05-09: RTL synthesis evidence for §4.4
                          |  (4-config Yosys + ASAP7; cell counts + SRAM area
                          |   already in RTL_design/reports/. W and GHz are
                          |   companion-paper scope, not blocking IEEE CAL.)
                          v
                    -> SUBMISSION READY
```

---

## (1) High-IOPS SimpleSSD configuration

**File:** `fast_ssd_highiops.cfg` (root of repo) — **DRAFTED**, awaiting review/run.

**What it changes vs `fast_ssd.cfg`:**

| Parameter | fast_ssd.cfg | fast_ssd_highiops.cfg | Rationale |
|---|---|---|---|
| `pal.Channel` | 8 | **32** | 4× parallel buses |
| `pal.LSBRead` | 45 µs | **1 µs** | XL-FLASH-class array sense |
| `pal.MSBRead` | 65 µs | **2 µs** | XL-FLASH-class |
| `pal.LSBWrite` | 500 µs | 50 µs | proportional |
| `pal.MSBWrite` | 1300 µs | 100 µs | proportional |
| `pal.Erase` | 3.5 ms | 1 ms | proportional |
| `pal.DMASpeed` | 400 MT/s | **1600 MT/s** | NV-DDR3 mode 5 |
| `pal.DMAWidth` | 8 bit | **16 bit** | wider NAND bus |
| `nvme.WorkInterval` | 1 µs | **200 ns** | 5× faster controller |
| `nvme.MaxRequestCount` | 8 | **32** | 4× dispatch parallelism |
| `nvme.UncoreMode` | 2 | 2 (preserved) | Mode B default |
| Other | — | preserved | — |

**Theoretical ceiling:** 32 channels × ~2× per-channel pipelining ÷ ~3 µs/IO ≈ 20 M IOPS sustained at QD=128 4 KB random read.

**Verification (gating step (2)):**
```bash
SSD_CFG=fast_ssd_highiops.cfg ./scripts/phase1_4k/driver_phase1.sh --auto \
  --qd "128" --ios "4096" --repeats 1 --steady-time 3 \
  --uncore-mode 0 --tag verify_highiops
# Results write directly to results/phase1_runs/verify_highiops/
# via virtio-9p; NO extract step needed (no sudo needed).
# REQUIRED: phase1_results.csv shows IOPS >= 10000000 at QD=128
```

**Note on steady-state duration.** gem5 is deterministic — physical noise
sources (thermal, DVFS, SMI, garbage collection, wear leveling) that motivate
30+ s windows on real hardware do not exist here. At 10 M IOPS, 3 s of
steady-state yields 30 M IO samples per data point — three orders of magnitude
beyond what means and p99 require. 30 s is overkill for verification AND for
the paper's evaluation. **Use --steady-time 3 for verify, 5 for the final
sweep.**

If IOPS < 10 M, iterate on the parameters (more channels, lower latency, or
faster DMA bus) until the threshold is met. **Do not proceed to sweeps until
the regime is right** — every cycle/IO measurement below 10 M IOPS is in the
SSD-bottleneck regime and inadmissible for the paper's argument.

**Estimated effort:** 1 verify run (~15–60 min wall time depending on warmup) + 1–2 tuning iterations = ~half a day to a day.

---

## (2) SPDK Mode 2B host patch — **APPLIED**

**Files modified (in this repo's `spdk/` tree):**

| File | Lines added | What |
|---|---:|---|
| `spdk/lib/nvme/nvme_pcie_internal.h` | 8 | Adds `volatile uint32_t *uncore_hint_reg` to `struct nvme_pcie_ctrlr` |
| `spdk/lib/nvme/nvme_pcie.c` | 22 | One-time BAR0+0x2000 mapping in `nvme_pcie_ctrlr_allocate_bars`, gated by env var `SPDK_UNCORE_MODE_B=1` |
| `spdk/lib/nvme/nvme_pcie_common.c` | 15 | Hot-path early-exit in `nvme_pcie_qpair_process_completions` for I/O qpairs when hint reads 0 |
| **TOTAL** | **45 LOC, 3 files** | hot-path edit = 8 lines |

**Behavioural contract:**
- `SPDK_UNCORE_MODE_B` unset → patch is **dormant**, byte-equivalent to vanilla SPDK at runtime.
- `SPDK_UNCORE_MODE_B=1` and BAR0 ≥ 0x2004 → patch maps the hint register and the polling fast path early-exits when the hint reads 0.
- Admin queue (`qpair->id == 0`) **always** falls through to normal CQ scan — keeps controller commands responsive.
- Reads are uncached `volatile uint32_t` accesses; load-acquire-safe on x86 for aligned 4-byte access.

**Action required to take effect — sudo-free path via virtio-9p:**
```bash
# Build SPDK in user-space (no Docker / no sudo required if DPDK
# headers are reachable; the spdk/dpdk submodule is bundled).
cd /home/fangy6/SimpleSSD_Gem5_simulation/spdk
./configure
make -j$(nproc)

# Copy the rebuilt nvme_perf binary into docker_artifacts/.
# This is the path phase1_run.sh resolves at $ROOT_DIR/docker_artifacts/
# inside the guest; with virtio-9p mounted at /mnt/9p, ROOT_DIR=/mnt/9p
# so the guest sees the new binary on the next launch.
cp build/bin/spdk_nvme_perf ../docker_artifacts/guest_spdk_nvme_perf

# DO NOT run bake_disk_image.sh. Disk-image baking is unnecessary
# in the virtio-9p workflow and requires sudo.
```

**Verification:**
```bash
strings docker_artifacts/guest_spdk_nvme_perf | grep -c "IO-Uncore Mode 2B"
# REQUIRED: prints 1 or 2 (the NOTICELOG and WARNLOG strings)
```

**Estimated effort:** ~5 min rebuild. No bake step. No sudo.

---

## (3) Three-regime evaluation sweep

**Driver:** `scripts/phase1_4k/driver_phase1.sh` already supports `--uncore-mode N`.

**Three runs required for Figure 3 + Figure 4:**

```bash
TAG_BASE=phase1_paper_$(date +%Y%m%d)

# Regime A: SPDK baseline (no uncore)
SSD_CFG=fast_ssd_highiops.cfg ./scripts/phase1_4k/driver_phase1.sh --auto \
  --qd "16 32 64 128" --ios "4096" --qpairs "1" \
  --repeats 3 --steady-time 5 --uncore-mode 0 \
  --tag ${TAG_BASE}_baseline

# Regime B: Mode A (transparent CQ batching)
SSD_CFG=fast_ssd_highiops.cfg ./scripts/phase1_4k/driver_phase1.sh --auto \
  --qd "16 32 64 128" --ios "4096" --qpairs "1" \
  --repeats 3 --steady-time 5 --uncore-mode 1 \
  --tag ${TAG_BASE}_modeA

# Regime C: Mode B (poll-lite — requires patched SPDK in disk image
#                   AND env SPDK_UNCORE_MODE_B=1 propagated through
#                   phase1_run.sh to the spdk_nvme_perf invocation)
SSD_CFG=fast_ssd_highiops.cfg ./scripts/phase1_4k/driver_phase1.sh --auto \
  --qd "16 32 64 128" --ios "4096" --qpairs "1" \
  --repeats 3 --steady-time 5 --uncore-mode 2 \
  --tag ${TAG_BASE}_modeB
```

**Action item — driver flag plumbing:** verify that `phase1_run.sh` exports
`SPDK_UNCORE_MODE_B=1` to the `spdk_nvme_perf` process when `--uncore-mode 2`
is passed. If not, add an `export SPDK_UNCORE_MODE_B=1` clause guarded by
the `UNCORE_MODE` value before the `spdk_nvme_perf` invocation.

**Plot generation:**
```bash
conda run -n llm python scripts/phase1_4k/plot_io_breakdown.py \
  --results results/phase1_runs --io-size 4096 \
  --out plots/fig2_io_stage_breakdown
# (You will likely also want a new plot script for Fig 3 = cycles/IO vs qpairs
#  bracket curves; the existing plot_phase1.py already produces multi-regime
#  curves and can be adapted.)
```

**Multi-qpair sweep for Figure 3 (additionally):**
After single-qpair establishes the baseline, sweep qpairs ∈ {1, 4, 16, 64} at fixed QD=128 to expose the multi-queue scanning amplification — that is the strongest argument for Mode 2B over Mode 2A.

**Estimated effort:** 3 regimes × 4 QDs × 5 s steady-state × 3 repeats. At
the high-IOPS event rate gem5 slowdown is ~3000–5000× wall vs simulated, so
expect ~4–7 h per regime, ~12–20 h total. Plus extract + plot (~30 min).
**Plan ~1 day for the data collection if running sequentially.**

---

## (4) Multi-core simulation script — **REWRITTEN 2026-05-09; data collection still pending**

**Status:** the broken `scripts/phase1_4k/phase1_run_multicore.sh` is **superseded**
by a gem5-aware replacement, `scripts/phase1_4k/phase1_run_multicore_gem5.sh`. The
broken script and the broken `scripts/phase1_4k/plot_multicore.py` are kept on disk
for now (do not invoke them) but no longer block the §4.2 per-core
invariance claim. **What IS still pending: actually running the new script
inside gem5 to collect the dual-core data point and regenerating the
plot.** That is one overnight gem5 session away.

**The five real-hardware bugs in the legacy script** (kept here as a
reference for why the old script must not be invoked):

| Issue | Symptom | Why |
|---|---|---|
| `get_53ghz_cores()` filters cores at exactly 5300 MHz | Empty core list, script aborts | gem5 simulates a 1–2 GHz CPU; no 5.3 GHz cores |
| Reads host PMU events (`uncore_imc_free_running/data_*`, `cpu_core/cycles/`) via `perf stat` | All metrics return 0 / `<not supported>` | gem5 guest has **no hardware PMU** |
| Hard-coded PCI address `0000:03:00.0` | Cannot find NVMe device | gem5 SimpleSSD lives at `0000:00:05.0` |
| Does not invoke through `driver_phase1.sh` / `boot_gem5.sh` / readfile path | gem5 is never started | Script assumes SPDK is already running on host hardware |
| No `--uncore-mode` plumbing | Can't toggle UncoreMode 0/1/2 | Was written before the IO-Uncore knobs existed |

### What the rewrite does (all five bugs fixed)

`scripts/phase1_4k/phase1_run_multicore_gem5.sh`:

1. **Runs inside the gem5 guest**, mirroring `phase1_run.sh`: same
   sysfs-based NVMe auto-detection (default `0000:00:05.0`), same
   docker-built `guest_spdk_nvme_perf` resolution, same `/mnt/9p`-aware
   `OUTPUT_ROOT` defaulting to `results/phase1_runs/<tag>/`.
2. **Builds a spanning core mask per iteration** from `CORE_COUNTS`
   (e.g., `CORE_COUNTS="1 2 4"` runs three regimes; for N cores the
   mask is `(1<<N)-1`, pinning the workload to cores `[0..N-1]`). One
   `spdk_nvme_perf` invocation per regime, so the workload truly
   spreads across cores cooperatively rather than being run serially
   per core.
3. **Plumbs `UNCORE_MODE`** the same way `phase1_run.sh` does: exports
   `SPDK_UNCORE_MODE_B=1` when `UNCORE_MODE=2`, leaves the SPDK patch
   dormant otherwise. The cfg-patching itself remains the responsibility
   of `driver_phase1.sh`.
4. **Auto-disables `perf`** when not present (gem5 has no `perf` by
   default); cycles/IO comes entirely from SPDK's `nvme_io_cycle`
   instrumentation. Host-PMU columns are emitted as zeros for schema
   parity with the single-core CSV but are not used by the new plot.
5. **Emits the State_Dealloc split columns** (`State_Dealloc_Library_ns`,
   `State_Dealloc_Callback_ns`, `State_Dealloc_Total_ns`) introduced
   2026-05-09. CSV header also adds a `Core_Count` column and a
   `Core_Mask` column.
6. **Output path:** `results/phase1_runs/<tag>/core_count<N>_qp<Q>/phase1_results.csv`
   — one CSV per (CORE_COUNT, QPAIRS) pair, mirroring the single-core
   `core<ID>_qp<Q>` layout.

### Plot-side rewrite

`scripts/phase1_4k/plot_multicore_gem5.py` (replaces `plot_multicore.py`):
- Drops all host-PMU columns; uses `Submit_Logic_ns + Completion_Logic_ns`
  with `× 5.3 GHz` as the cycles/IO measurement, mirroring
  `plot_io_breakdown.py`.
- Two-panel figure: stacked-bar per-stage breakdown by core count on the
  left; flatness check (`Δ vs 1-core in %`) on the right. The flatness
  curve is the visual anchor for §4.2's "per-core cycles/IO is invariant
  under multi-core load" sentence.
- Output: `plots/multicore_invariance.{png,pdf}`.

### Driver

`scripts/phase1_4k/driver_phase1_multicore.sh` is the dedicated multi-core entry
point (added 2026-05-09). It is a focused, auto-only, virtio-9p-only
sibling of `driver_phase1.sh` that:
- Generates a multi-core-specific readfile (mounts `/mnt/9p`, finds the
  repo, exports `CORE_COUNTS_LIST` + the rest of the tuning knobs,
  invokes `./scripts/phase1_run_multicore_gem5.sh`).
- Patches the SSD config for `UncoreMode` / `CQBatchN` / etc. exactly
  the way the single-core driver does, so the IO-Uncore knobs apply
  identically.
- Watches for `PHASE1_RUNSCRIPT_DONE` and auto-stops gem5 + the tmux
  session when the sweep completes.

The single-core `driver_phase1.sh` is unchanged; the two drivers
coexist. No manual guest-side step is needed.

### Verification target (one overnight gem5 session)

```bash
SSD_CFG=fast_ssd_highiops.cfg ./scripts/phase1_4k/driver_phase1_multicore.sh \
    --auto --core-counts "1 2" \
    --qd 128 --ios 4096 --qpairs 1 \
    --repeats 1 --steady-time 5 \
    --uncore-mode 0 --tag verify_multicore
# Expected:
#   * results/phase1_runs/verify_multicore/core_count1_qp1/phase1_results.csv
#   * results/phase1_runs/verify_multicore/core_count2_qp1/phase1_results.csv
#   * |cycles/IO(2-core) - cycles/IO(1-core)| / cycles/IO(1-core) < 10%
#     -- the invariance gate the paper cites.
# Then plot:
#   conda run -n llm python scripts/phase1_4k/plot_multicore_gem5.py \
#       --results results/phase1_runs --qd 128 --io-size 4096
```

### Why this matters (unchanged from prior version)

The paper's §4.2 "cycles/IO reduction is per-core, not aggregate"
sentence — which defends the §3.1 shared-at-chiplet placement decision
against a per-core-uncore alternative — needs at least one dual-core
data point. With the rewritten script, the data is **one gem5 night
away**, not blocked by infrastructure.

**Files added 2026-05-09:**
- `scripts/phase1_4k/driver_phase1_multicore.sh`    (host-side driver, auto-only, 9p-only)
- `scripts/phase1_4k/phase1_run_multicore_gem5.sh`  (in-guest sweep runner)
- `scripts/phase1_4k/plot_multicore_gem5.py`        (per-stage-instrumentation plot)

**Files left in place but DEPRECATED (do NOT invoke):**
- `scripts/phase1_4k/phase1_run_multicore.sh`       (real-hardware-only)
- `scripts/phase1_4k/plot_multicore.py`             (consumes host-PMU columns)

---

## (5) Split `State_Dealloc_ns` instrumentation — **DONE 2026-05-09**

**Why:** the legacy `State_Dealloc_ns` measurement bundled SPDK library
teardown with the application's `cb_fn(cb_arg, ...)` callback. Hardware
can elide the former but not the latter; reporting both as one stage
would credit the IO-Uncore for application cycles it cannot reach. The
split makes the §2.1 dominance argument honest.

**Resulting columns:**
- `State_Dealloc_Library_ns` — pre-callback library work (TAILQ_REMOVE,
  qd--, error-injection check, `_nvme_free_request`) plus post-callback
  library work (`tr->req = NULL`, `TAILQ_INSERT_HEAD` into free_tr).
  Hardware-elidable.
- `State_Dealloc_Callback_ns` — `cb_fn(cb_arg, cpl)` execution only.
  Kept on CPU regardless of IO-Uncore.
- `State_Dealloc_Total_ns` — sum of the two; equivalent to what the
  combined stage would have measured if it had been instrumented end-
  to-end (which the legacy column was not — it stopped at
  `t_dealloc_pre_end`, missing both the callback and the post-callback
  library work).
- `State_Dealloc_ns` — **legacy** column preserved unchanged so analysis
  scripts and prior CSVs continue to work. Equals the pre-callback
  library window only; do not use for new analysis.

**Files modified:**
- `spdk/lib/nvme/nvme_internal.h` — added `t_callback_start`,
  `t_callback_end`, `t_dealloc_post_end` fields to `struct nvme_request`
  in the "completion path timestamps" block; the existing `memset`
  in `nvme_request_clear` (bounded by `offsetof(payload_size)`) zeros
  them on every allocation.
- `spdk/lib/nvme/nvme_pcie_common.c` — `nvme_pcie_qpair_complete_tracker`
  now inlines the body of `nvme_complete_request` so it can stamp
  `t_callback_start` (after `_nvme_free_request`) and `t_callback_end`
  (after `cb_fn` returns) at exactly the right boundaries.
  `t_dealloc_post_end` is stamped after the `TAILQ_INSERT_HEAD` into
  `free_tr`. The non-PCIe `nvme_complete_request` helper in
  `nvme_internal.h` is unchanged — only the PCIe-specific call site
  needed inlining.
- `spdk/lib/nvme/nvme_qpair.c` — added the three new fields to
  `struct io_cycle_breakdown`; `nvme_io_cycle_record` copies them from
  `req`; `nvme_io_cycle_dump` emits three new CSV columns
  (`state_dealloc_library_ns`, `state_dealloc_callback_ns`,
  `state_dealloc_total_ns`) while keeping the legacy
  `state_dealloc_ns` column unchanged.
- `scripts/phase1_4k/phase1_run.sh` — Python aggregator pulls the three new
  columns from `cycle_breakdown.csv`; `phase1_results.csv` header gains
  `State_Dealloc_Library_ns`, `State_Dealloc_Callback_ns`,
  `State_Dealloc_Total_ns`.
- `scripts/phase1_4k/plot_io_breakdown.py` — Figure 2 now stacks
  `State_Dealloc_Library` and `State_Dealloc_Callback` separately, with
  the callback rendered in red (`#d62728`) so the visual makes the
  hardware-elidable / kept boundary obvious. Loader auto-detects
  pre-split CSVs and treats the legacy column as 100% library, with a
  warning, so prior data still plots.

**Race caveats (same as existing instrumentation).** The new probes use
the same `req->t_*` write-then-read pattern as the legacy probes. After
`_nvme_free_request`, `req` is on the qpair's free pool and may be
reallocated by an IO submitted inside `cb_fn`. If reused, the post-
callback stamps land on the new request's memory and `nvme_io_cycle_record`'s
`if (req->t_start == 0 || req->t_end == 0) return;` filter discards
the row, producing clean dropouts rather than corrupt averages. At
moderate QD on `spdk_nvme_perf` the dropout rate is well below the
signal level needed for paper-grade aggregates.

**Verification target after rebuild + sweep:**
```bash
# Inside the guest CSV under results/phase1_runs/<tag>/core0_qp1/cycle_breakdown.csv
head -1 cycle_breakdown.csv | tr ',' '\n' | grep -E "callback|state_dealloc"
# expected: state_dealloc_ns + state_dealloc_library_ns + state_dealloc_callback_ns + state_dealloc_total_ns
```

**Build status (2026-05-09):** code committed locally; SPDK Docker
rebuild from TASK 2 of the overnight session was completed *before*
this split was applied. **Re-run `scripts/build_spdk_docker.sh`** before
the next sweep so `guest_spdk_nvme_perf` includes the split probes.

**Paper integration:** §2.1 dominant-stages table and §4.2 cycles/IO
formula in `docs/PAPER_CHAPTER_PLAN.md` updated to reference the split
columns. See the "State_Dealloc split rationale" paragraph and the
revised §4.2 prose for the verbatim wording the paper will use.

---

## (6) RTL synthesis evidence for §4.4 — **REQUIRED; partially DONE 2026-05-09**

**Why required (no longer optional):** the paper's energy/power discussion has been narrowed (2026-05-09 scope-lock — see `PAPER_CHAPTER_PLAN.md` §2.2 commentary and the `§2.2_scope_locked` INSIGHT) so that §4.4 is now the *only* place where power feasibility is argued. Without an RTL anchor, §4.4 has no basis for the "fits with or on the CPU die" claim. The CACM-derived "50×" software-energy claim is **dropped** from the paper.

**What's required for §4.4:**
- Per-tile total cell count + cell area (mm²)
- Per-tile SRAM area (mm²)
- A comparison anchor against published 7 nm CPU-die IP (Sapphire Rapids LLC slice 1.875 MB / ~3-4 mm², AMD Zen 4 L3 slice 4 MB)

**Optional for the IEEE CAL submission, but desirable for a companion paper:**
- Per-tile dynamic power (W) at representative activity factor
- Critical-path frequency (GHz) closing at the 1 GHz I/O-tile clock domain

### Status (2026-05-09)

The synthesis flow is **set up and producing artifacts** under `RTL_design/`.
What's actually completed:

| Artifact | Location | Status |
|---|---|---|
| Yosys + ASAP7 7 nm (7.5T cell library) flow | `RTL_design/synth/run_synth_yosys.tcl`, `RTL_design/lib/` | ✅ working |
| Gate-level netlists for 4 configs | `RTL_design/netlists/io_uncore_{16,64}_{64,128}.v` | ✅ all 4 synthesize |
| Cell-count statistics per config | `RTL_design/reports/stat_{NQ}_{QD}.rpt` | ✅ |
| SRAM working-set sizing | `RTL_design/reports/sram_sizing.json` | ✅ JSON with kb + mm² for 4 design points |
| Critical-path frequency / STA | OpenSTA on the synthesized netlists | ⏳ not yet run |
| Dynamic power | OpenROAD power analysis | ⏳ not yet run |

### Numbers landed in §4.4 (sourced from `RTL_design/reports/`)

| Config | NQ | QD | Total cells | DFFs | SRAM size | SRAM area |
|---|---|---|---|---|---|---|
| A | 16 | 64  | 20,297 | 3,477 | 329 KB  | 0.11 mm² |
| B | 64 | 64  | 57,875 | 9,595 | 1.32 MB | 0.44 mm² |
| C | 16 | 128 | 20,549 | 3,515 | 657 KB  | 0.22 mm² |
| **D (production)** | **64** | **128** | **58,783** | **9,729** | **2.63 MB** | **0.87 mm²** |

The production point (D) sits comfortably under a Sapphire Rapids LLC slice (1.875 MB / ~3-4 mm²), establishing the on-die feasibility claim from area alone — power and frequency strengthen the argument but are not load-bearing for IEEE CAL submission.

### What still belongs in the companion paper (not gating IEEE CAL)

- OpenROAD power analysis to land per-tile dynamic + leakage W
- OpenSTA timing closure at 1 GHz to confirm the I/O-tile clock-domain claim
- Per-stage power decomposition (SQ vs CQ vs Doorbell vs Credit Manager)
- Place-and-route to validate routability at the chosen aspect ratio

**Estimated remaining effort for the IEEE CAL submission**: zero — the area + cell-count numbers required for §4.4 are already in `RTL_design/reports/`. Companion-paper work (W, GHz) is a separate ~1-2 weeks effort.

---

## Summary timeline

| Item | Status | Wall time | Blocking? |
|---|---|---|---|
| (1) `fast_ssd_highiops.cfg` | Drafted | half-day verify | Yes |
| (2) SPDK Mode 2B patch | **Applied to source; rebuilt 2026-05-09** | ~90 s Docker rebuild | Yes |
| (3) Three-regime sweep (single-core) | Pending | ~1 full day | Yes |
| (4) Multi-core script gem5 port | **REWRITTEN 2026-05-09** (driver + runner + plot in `scripts/phase1_4k/`) | ~3 h gem5 night to populate data | For the per-core invariance sentence (§4.2) |
| (5) State_Dealloc split | **DONE 2026-05-09** (code + plot + paper docs) | re-run sweep needed | Yes (closes the §2.1 honest-accounting attack) |
| (6) RTL synthesis | **REQUIRED; partially DONE 2026-05-09** (4-config Yosys synthesis + cell counts + SRAM area in `RTL_design/`) | zero further effort for IEEE CAL submission | Yes — §4.4 has no anchor without RTL after the 2026-05-09 scope-lock |

**Critical path to submission:** items (1) → verify → (2) rebuild → (3) sweep → plots → write. Expect **2–3 days of focused work** to reach a submittable evidence base, plus ~1 week of writing.

---

## Mapping to paper sections

| Item | Affects paper section | Anchors which claim |
|---|---|---|
| (1) high-IOPS config | §4.1 Methodology | "evaluation regime matches motivation regime" |
| (2) SPDK patch | §3.4 Software contract | "Mode B requires ≈45 LOC, 3 files; hot path = 8 lines" |
| (3) sweep (single-core) | §4.2 + §4.3 | bracket figure (Fig 3) + latency trade (Fig 4) |
| (4) multi-core script fix + 2-core run | §4.2 (one extra sentence) | "per-core cycles/IO is invariant under multi-core load" |
| (5) instrumentation split | §2.1 + §4.2 | honest cycles/IO accounting |
| (6) RTL evidence | §4.4 | feasibility headline |

---

## File inventory of plan-mode deliverables

```
docs/PAPER_CHAPTER_PLAN.md             # consolidated chapter plan + INSIGHTs
docs/PAPER_IMPL_TODO.md                # this file
fast_ssd_highiops.cfg                  # high-IOPS SimpleSSD config
spdk/lib/nvme/nvme_pcie_internal.h     # +8 LOC: uncore_hint_reg field
spdk/lib/nvme/nvme_pcie.c              # +22 LOC: BAR0+0x2000 mapping
spdk/lib/nvme/nvme_pcie_common.c       # +15 LOC: hot-path early exit
scripts/phase1_4k/plot_io_breakdown.py # Figure 2 generator (already in repo)
plots/io_stage_breakdown.{png,pdf}     # current Fig 2 (regenerate after item 3)
```
