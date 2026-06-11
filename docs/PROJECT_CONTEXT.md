# SimpleSSD + gem5 + SPDK Full-System Simulation — Project Context

**Last updated:** 2026-06-07
**Audience:** A fresh AI agent (or new engineer) joining this project.
**Goal of this file:** Hand you the complete project picture — *what* it is, *where* the
implementation lives, *which file owns each topic*, *how* to run things, and *where to
look* when you need more depth than this page provides. Cross-references are
file-path + section-anchor pairs you can `Read` directly.

---

## 0. TL;DR — One screen of what this project is

We run a **full-system NVMe SSD simulation** to measure the host-CPU cost per I/O at
ultra-high IOPS and to design a hardware solution. The stack is:

- **gem5** simulates an X86 server (full-system, real Linux kernel) with the simple-CPU family. The active configuration is `AtomicSimpleCPU` @ 2 GHz, no L1/L2 caches (the CPU connects directly to the system membus), and `mem_mode=atomic`. This is the gem5 default for `configs/example/fs.py`; `boot_gem5.sh` does not override `--cpu-type` or `--cpu-clock`. Cross-checked from `SimpleSSD-FullSystem/m5out/config.ini` (2026-05-15).
- **SimpleSSD** is gem5's NVMe SSD model (HIL / ICL / FTL / PAL pipeline).
- **SPDK `spdk_nvme_perf`** runs *inside* the simulated Linux guest as the host-side
  workload, generating real NVMe traffic to the modeled SSD.

The research finding is that **the host CPU saturates at ~0.82 M IOPS** for 4 KB
random reads, far below the SSD's aggregate device ceiling (~8 M IOPS in the
high-iops config, FastPathTmaxPerChannel 250 K × 32 channels; lowered from the
earlier 1 M/channel = 32 M setting on 2026-05-15 so the device keeps ~10× headroom
over the single-core host rather than being an unrealistically fast outlier). Three
host-CPU stages dominate the per-IO budget: **PRP-list construction
(~337 ns)**, **tracker bookkeeping (~218 ns)**, and **state dealloc (~295 ns)**.

We propose an on-die **I/O-Uncore** (a CPU-uncore hardware block) that absorbs those
stages. The simulator now supports three "modes" of offload progressively eliminating
host work. **Measured (2026-05-13)** with Mode 2 + Mechanisms #1+#2+#4 enabled on the
Storage-Next-class `fast_ssd_highiops.cfg`, the host-side ceiling moves from
**~0.82 M → ~1.10 M IOPS at QD=128, a ~1.35× lift**. The lift is reproduced on a
DiskANN BigANN trace replay (**~1.37× at QD=128**) and held across QD ∈ {16, 32, 64,
128} (1.35× to 1.43×). Mode 2 is itself CPU-bound at a new higher ceiling (IOPS
nearly flat at ~1.106 M across all four QDs), motivating the deferred Mechanism #3
(completion-callback dispatcher) as future work to close more of the remaining gap to
the device ceiling.

The paper target is **IEEE Computer Architecture Letters (CAL)**.
Working title: *IAU: Assisting the CPU Core for Next-Generation Multi-Million IOPS NVMe Devices*.

---

## 1. Quick start for a new agent — Where to look when…

| If you need to… | Read first | Then |
|---|---|---|
| Understand the research question and pitch | §2 of this file, `docs/PAPER_CHAPTER_PLAN.md` | `docs/Research Plan Architecting a Host-Integrated IO Uncore.pdf` |
| Understand the simulation stack | §4 of this file | `CLAUDE.md` (root) |
| Find a specific source-level fix | §8 of this file (table) | The file/line cited |
| Understand I/O-Uncore Mode 0/1/2 + Mechs | §7 of this file | `docs/IO-Uncore RTL Design Specification — Phase 3 Silicon Feasibility.md` |
| Understand the Path-E fast-path SSD model | §7.4 of this file + `docs/PATH_E_FAST_PATH_PLAN.md` | `controller.cc` fast-path methods |
| Run a simulation | §9.4 of this file | `scripts/scripts_manual.md` |
| Build gem5 from source | §9.1 of this file | `scripts/boot_gem5.sh` |
| Rebuild the guest SPDK binary | §9.2 of this file | `scripts/build_spdk_docker.sh` |
| Interpret a CSV result | §11.1 of this file | column reference table |
| Debug a panic / hang | §13 of this file | `logs/gem5.out` |
| Understand gem5-side stats | §7.6 + §11.3 of this file | `SimpleSSD-FullSystem/m5out/stats.txt` |
| Continue an in-flight implementation plan | `docs/superpowers/plans/` directory | latest dated plan file |
| Find the paper LaTeX | `docs/paper.tex` | `docs/paper.bib` |
| Trace what `--uncore-mode N` does | §7.1 of this file | `scripts/phase1_4k/driver_phase1.sh:610` (sed override) → `phase1_run.sh:43-49` (env var export) |
| Look up an MMIO region | §7.2 of this file (BAR0 map) | `def.hh`, `controller.cc::writeRegister` |
| Check what changed since 2026-03-19 | the change log at the top of this section | git log |

---

## 2. Project Goal

### 2.1 Workload — Phase 1 (Random Read IOPS Sweep)

The active experiment is a **4 KB and 16 KB random-read** IOPS sweep driven by
`spdk_nvme_perf`. The sweep covers:

| Parameter | Values |
|---|---|
| Queue depth (QD) | 16, 32, 64, 128 |
| I/O size | 4096 B, 16384 B |
| Queue pairs | 1 (single-core, core 0) |
| Access pattern | Random read (`-w randread`) |
| Measurement window | 30 s steady-state per point (smoke runs use shorter) |

Results land as CSV files under `results/phase1_runs/<tag>/` and are plotted by
`scripts/phase1_4k/plot_phase1.py`.

### 2.2 Research direction — CPU bottleneck at ultra-high IOPS

**Question:** at what NVMe throughput does the host CPU become the bottleneck, and
what is the exact CPU cost per I/O?

**Answered (2026-05-10):** on `fast_ssd_highiops.cfg` (Storage-Next class, ~8 M IOPS
aggregate device ceiling), an unmodified SPDK polling stack saturates at **0.82 M IOPS at
QD=128 for 4 KB random reads** — ~10 % of device capability — while 97 % of its
polling calls return zero completions. The per-IO budget decomposes (CSV columns) as:

```
submit_preamble  141 ns
tracker_alloc    218 ns
addr_xlate       337 ns
cmd_construct     51 ns
fence              1.8 ns
doorbell           1.1 ns
cqe_detect        20 ns
tracker_lookup    11 ns
state_dealloc    295 ns
other            ~140 ns
────────────────────────
                ~1.22 µs / IO   ⇒ ~820 K IOPS single-thread
```

The dominant elidable costs are **PRP-list construction (~337 ns)** and
**tracker/state-dealloc bookkeeping (~218 + ~295 ns)**.

### 2.3 Proposed solution — I/O-Uncore

We design an on-die **I/O-Uncore** that relocates per-IO host stages into a
CPU-uncore-resident hardware block. The simulator models this at three progressively
deeper levels. All numbers below are **measured** on `fast_ssd_highiops.cfg`
(Storage-Next class, ~8 M IOPS aggregate device ceiling), single qpair, 4 KB random reads,
2 GHz simulated X86 AtomicSimpleCPU (no L1/L2; mem_mode=atomic). Runs: `paper_qdsweep_mode0/1/2_20260510` and bigANN trace
runs `paper_trace_mode0/2_20260510`.

| Mode | What it offloads | IOPS @ QD=128 (4 KB rand) | bigANN @ QD=128 | Lift vs Mode 0 |
|---|---|---:|---:|---:|
| **Mode 0** (baseline) | Nothing — baseline SPDK + Path-E fast-path device | 819,253 | 803,840 | 1.00× |
| **Mode 1** (transparent) | Device-side SQ-fetch gate + CQE staging buffer (SPDK untouched) | 808,403 | — | 0.99× *(small loss under polling SPDK is expected; gain is in DRAM-traffic reduction, not IOPS)* |
| **Mode 2 + Mechs #1/#2/#4** | + Mailbox SQ Engine + HW free-CID ring + HW queue-depth counter + typed hint reg | **1,106,669** | **1,101,905** | **1.35× (rand) / 1.37× (bigANN)** |

**QD-sweep lift (Mode 2 / Mode 0):** 4 KB random read — 1.43× @ QD=16, 1.38× @ QD=32, 1.36× @ QD=64, 1.35× @ QD=128. BigANN trace — 1.45× / 1.40× / 1.38× / 1.37× at the same QDs. The lift is largest at low QD (where each IO's per-stage savings matter more) and smallest at high QD (where polling overlap already amortizes some cost in Mode 0).

**New CPU-bound ceiling after Mode 2.** Mode 2 IOPS is essentially flat at ~1.106 M across QD ∈ {16, 32, 64, 128}, indicating Mode 2 itself becomes the new CPU-bound saturation point. The residual gap to the ~8 M IOPS aggregate device ceiling is what motivates **Mech #3 (HW completion-callback dispatcher) as future work**. Mech #3 requires a new SPDK application API and crosses from "control-plane uncore" to "control + data-plane uncore." Its quantitative ceiling is not measured in this paper. See `docs/IO-Uncore RTL Design Specification — Phase 3 Silicon Feasibility.md` §13.

### 2.4 Paper

- **Working title:** *IAU: Assisting the CPU Core for Next-Generation Multi-Million IOPS NVMe Devices*
  (I = I/O · A = Assistant · U = Uncore)
- **Venue:** IEEE Computer Architecture Letters (CAL), 4 pp text + 1 pp refs
- **LaTeX:** `docs/paper.tex`, `docs/paper.bib`
- **Chapter plan & evidence map:** `docs/PAPER_CHAPTER_PLAN.md`
- **TODOs for the paper:** `docs/PAPER_IMPL_TODO.md`

### 2.5 Companion design docs

| Path | Contents | When to read it |
|---|---|---|
| `docs/IO Uncore design plan.md` | High-level architecture / motivation for the uncore | If you are new to the uncore concept |
| `docs/IOUncore_discussion.md` | Design discussion thread (Q&A, alternatives considered) | Background on why decisions were made |
| `docs/IO-Uncore RTL Design Specification — Phase 3 Silicon Feasibility.md` | RTL for SQ Engine + CQ Engine + Doorbell Coalescer; §13 adds the 4-mechanism feasibility roadmap | Implementing/extending RTL, or answering hardware-feasibility questions |
| `docs/PATH_E_FAST_PATH_PLAN.md` | Path-E NVMeVirt-style fast-path SSD timing plan | If you need to change Path-E or argue why the SSD-side model is valid |
| `docs/PAPER_CHAPTER_PLAN.md` | IEEE CAL paper outline + evidence map per section | Drafting / revising paper |
| `docs/PAPER_IMPL_TODO.md` | Remaining paper-implementation TODOs | Closing the paper loop |
| `docs/AGENT_HANDOFF_PROMPT.md` | Older handoff prompt template | Reference only |
| `docs/DISKANN_TRACE_CAPTURE.md` | Notes on a DiskANN trace capture experiment | Only if you touch DiskANN traces |
| `docs/superpowers/plans/2026-04-02-mode-b-iouncore.md` | Original Mode B plan (pre-mailbox) | Historical |
| `docs/superpowers/plans/2026-04-13-iouncore-rtl.md` | RTL implementation plan | Historical |
| `docs/superpowers/plans/2026-05-11-mode2-deep-offload.md` | Mode 2 v1 mailbox plan — **landed** | Reference for the current mailbox path |
| `docs/superpowers/plans/2026-05-11-cq-side-offload-mech124.md` | Mechs #1/#2/#4 plan — **landed** | Reference for the current CQ-side mechs |
| `docs/Research Plan Architecting a Host-Integrated IO Uncore.pdf` | Original research-plan PDF | Context / formal write-up |
| `docs/pb058-nvme-host-accelerator.pdf` | Prior-art hardware accelerator reference | Related work |
| `docs/standard_4KB16KB_read.pdf` | Reference IOPS curves from real hardware | Comparing measured vs real |
| `docs/phase1_results_real.csv` | A frozen CSV snapshot from a real measurement | Reference dataset |

---

## 3. Repository

- **GitHub:** `https://github.com/fangyunh/Gem5-simpleSSD-SPDK-simulation.git`
- **Local workspace root on this server:** `/home/fangy6/SimpleSSD_Gem5_simulation`
- **Default branch:** `main` (HEAD on this server: `bd907c68`)
- **Note:** the original author's dev machine path
  (`/home/fangyunh/Documents/SimpleSSD_Gem5_simulation`) is referenced in older docs.
  On this server (RPI / `tzhang1`) the workspace root is the `fangy6` path above.

Key recent commits (newest first):
```
bd907c68  Add files via upload
b463616d  Add files via upload
4eba5194  Add files via upload
75d873c0  Add documents
cf05c7b9  readme updates
```
Run `git log --oneline` for the full history; uncommitted source changes (Mode 2 +
Mechs #1/#2/#4 + Path-E) live in the working tree and are documented in §8.

---

## 4. Simulation Architecture

### 4.1 Stack diagram

```
Host Linux (the real machine)
  └── gem5.opt   [setsid + nohup + nice -n 19 + taskset, fully detached]
        ├── Simulated X86 AtomicSimpleCPU @ 2 GHz, no L1/L2 caches, mem_mode=atomic
        │   (gem5 default for configs/example/fs.py; not overridden in boot_gem5.sh;
        │    verified from m5out/config.ini)
        ├── Simulated 4 GB guest DRAM
        ├── SimpleSSD NVMe model (in-process plugin)
        │     ├── HIL / ICL / FTL controller (3 cores; clock varies per cfg)
        │     ├── Path-E fast-path timing model (NVMeVirt-style; see §7.4)
        │     ├── I/O-Uncore Mode 1 (SQ-fetch gate + CQE staging buffer)
        │     ├── I/O-Uncore Mode 2 v1 (Mailbox SQ Engine @ BAR0+0x3000)
        │     ├── Mechanism #1 (HW free-CID ring @ BAR0+0x4000)
        │     ├── Mechanism #2 (HW queue-depth counter @ BAR0+0x4400)
        │     ├── Mechanism #4 (typed hint register @ BAR0+0x2000)
        │     └── NAND flash timing model (fast_ssd_highiops.cfg by default)
        ├── Linux 5.4.49 guest kernel (vmlinux-5.4.49, vfio + virtio-9p builtin)
        └── diod  [host 9p file server, spawned as child of gem5]
              └── exposes HOST_SHARE (= workspace root) as /mnt/9p inside the guest
                    └── Guest sees fresh host files (no disk re-bake needed)
                          ├── spdk_nvme_perf  (run from /mnt/9p/docker_artifacts/)
                          ├── phase1_run.sh   (run from /mnt/9p/scripts/phase1_4k/)
                          └── results CSV     (written to /mnt/9p/results/...)
```

### 4.2 Workflow — virtio-9p + readfile (the ONLY supported mode today)

1. Driver `scripts/phase1_4k/driver_phase1.sh --auto` is invoked on the host inside a
   `tmux` session.
2. Driver generates a readfile script (`logs/phase1_readfile_<tag>.sh`) baking in
   `UNCORE_MODE`, `QD_LIST`, `IO_SIZES`, `STEADY_TIME`, etc. as `export` lines.
3. Driver `sed`-patches the cfg file's `UncoreMode = N` line in place.
4. Driver starts gem5 via `boot_gem5.sh start`. gem5 launches `diod` as a child
   process to serve 9p.
5. gem5 boots Linux. After boot, gem5 hands the readfile to the guest kernel as a
   startup script and runs it as root.
6. The readfile mounts the 9p share at `/mnt/9p`, then runs `phase1_run.sh` which:
    - configures hugepages, binds the NVMe device to SPDK,
    - exports `SPDK_UNCORE_MODE_B=1` when `UNCORE_MODE=2`,
    - runs the `spdk_nvme_perf` sweep,
    - writes CSVs directly to `/mnt/9p/results/phase1_runs/<tag>/`
      (visible on the host *immediately* as `results/phase1_runs/<tag>/`),
    - prints `PHASE1_RUNSCRIPT_DONE` and calls `m5 exit`.
7. Driver detects `PHASE1_RUNSCRIPT_DONE`, calls `boot_gem5.sh stop`, exits.

**Why 9p, not bake-into-disk-image:** the 9p share means every `phase1_run.sh` and
`docker_artifacts/guest_spdk_nvme_perf` edit on the host is *immediately* visible
inside the guest with no `sudo bake_disk_image.sh` step. The legacy
`scripts/phase1_4k/extract_phase1_results.sh` is only needed if you ever fall back
to a non-9p run (rare).

### 4.3 Why gem5 doesn't die when you log out

Three-layer isolation in `scripts/boot_gem5.sh`:

| Mechanism | Purpose |
|---|---|
| `setsid` | New kernel session; SIGHUP/SIGTERM from session teardown cannot reach gem5 or its diod child. **Critical fix — without it, an SSH disconnect killed gem5.** |
| `nohup` | Belt-and-suspenders SIGHUP ignore. |
| `disown` | Removes gem5 from bash's job table so `exit` cannot reap it. |

Additionally: `nice -n 19` (lowest CPU priority) + `taskset` (cores 0…nproc-9,
reserving 8 cores for OS/other users) so simulation never starves the host.

To stop gem5 cleanly: `./scripts/boot_gem5.sh stop`. **Do not** `kill -9` it — the
diod child can leak.

> **Caveat:** `boot_gem5.sh status` can report "not running" even when `pgrep -af
> gem5.opt` clearly finds a live process (the PID-file logic is brittle). Always
> cross-check with `pgrep` before assuming gem5 is gone.

---

## 5. Directory Layout

```
SimpleSSD_Gem5_simulation/
├── SimpleSSD-FullSystem/         # gem5 source (forked for SimpleSSD integration)
│   └── build/X86/gem5.opt        # compiled binary (~1.1 GB; mtime moves on rebuild)
│   └── src/dev/storage/
│       ├── NVMe.py               # SimObject Python config (BAR0Size = 32 KB)
│       ├── nvme_interface.cc     # gem5 device model glue (PCI cfg writes, BAR0 R/W)
│       └── simplessd/hil/nvme/
│           ├── controller.cc/.hh   # NVMe controller core — ALL Mode 1/2/Mech code
│           ├── config.cc/.hh       # cfg-key parsing — UncoreMode, FastPath*, FreeCID*
│           └── def.hh              # BAR0 offset constants (REG_DOORBELL_END, etc.)
├── assets/
│   ├── x86-ubuntu.img            # guest disk image (16 GB, Ubuntu 18.04)
│   ├── vmlinux-5.4.49            # guest kernel w/ vfio+virtio-9p built-in (24 MB)
│   └── linux-stable/             # kernel source (reference only)
├── docker_artifacts/
│   ├── guest_spdk_nvme_perf      # CURRENT guest SPDK perf binary (glibc 2.27, no SSSE3)
│   ├── guest_spdk_nvme_perf.pre_mech124_2026_05_11    # backup before Mechs landed
│   ├── guest_spdk_nvme_perf.pre_deep_offload_2026_05_11  # backup before Mode 2
│   ├── guest_spdk_nvme_perf.pre_mailbox_2026_05_11
│   ├── guest_spdk_nvme_perf.pre_patch_2026_05_09
│   ├── guest_spdk_nvme_perf.minimal_trace_2026_05_10
│   ├── guest_spdk_nvme_perf.broken_2026_05_10
│   ├── guest_openssl11/          # OpenSSL 1.1.1 shared libs for guest runtime
│   └── spdk_patches_archive/     # archived SPDK source patches per milestone
├── spdk/                         # SPDK 24.x source (custom branch with uncore patches)
│   ├── app/spdk_nvme_perf/perf.c           # workload entry
│   ├── lib/nvme/nvme_pcie.c                # BAR mapping (uncore_*_base pointers)
│   ├── lib/nvme/nvme_pcie_common.c         # submit/complete/process_completions (Mech path)
│   └── lib/nvme/nvme_pcie_internal.h       # field decls + MMIO offset macros
├── scripts/
│   ├── phase1_4k/                # PRIMARY entry-point scripts
│   │   ├── driver_phase1.sh                # orchestrates an entire run
│   │   ├── phase1_run.sh                   # runs inside guest, drives the SPDK sweep
│   │   ├── phase1_run_multicore.sh         # multi-core variant (rarely used)
│   │   ├── phase1_run_multicore_gem5.sh    # gem5-specific multi-core variant
│   │   ├── driver_phase1_multicore.sh      # multi-core driver
│   │   ├── extract_phase1_results.sh       # legacy non-9p fallback; usually NOT needed
│   │   ├── smoke_9p_check.sh               # quick sanity check for 9p mount
│   │   ├── phase1_bdev.sh / driver_bdev.sh # SPDK bdev-baseline (malloc/null) variants
│   │   ├── run_sweep_baseline.sh           # full-baseline sweep helper
│   │   ├── plot_phase1.py                  # IOPS / latency curves
│   │   ├── plot_multicore.py / plot_multicore_gem5.py    # multi-core sweeps
│   │   ├── plot_bdev.py                    # bdev-baseline plotting
│   │   ├── plot_io_breakdown.py            # per-stage cycle plots
│   │   ├── plot_bracket.py                 # bracket / error-bar variants
│   │   ├── plot_p99_vs_cqbatchn.py         # CQ-batching tail-latency plots
│   │   ├── summarize_phase1.py             # aggregate stats across runs
│   │   ├── apply_ssd_profile.py            # apply a named cfg profile (helper)
│   │   └── README.md                       # in-dir notes
│   ├── boot_gem5.sh              # start/stop/status gem5 daemon
│   ├── build_spdk_docker.sh      # rebuild guest_spdk_nvme_perf in Ubuntu 18.04 Docker
│   ├── build_guest_kernel_vfio.sh  # rebuild vmlinux-5.4.49 with vfio (rarely needed)
│   ├── bake_disk_image.sh        # bake source tree into disk image (sudo; rare in 9p mode)
│   ├── resize_disk_image.sh      # grow the disk image if it fills up
│   ├── console_gem5.sh           # interactive guest serial console
│   ├── overnight_paper_sweep.sh  # multi-mode sweep used for paper figures
│   ├── bigann/                   # BigANN workload helpers (DiskANN-related)
│   └── scripts_manual.md         # full script reference (authoritative)
├── fast_ssd.cfg                  # SimpleSSD baseline cfg (Samsung 970 EVO-class)
├── fast_ssd_highiops.cfg         # ACTIVE paper cfg (Storage-Next class) — §10
├── upload_large_files.sh         # rsync large binaries to remote server
├── docs/                         # ALL design / paper / handoff docs (see §2.5)
├── results/
│   ├── phase1_runs/<tag>/        # per-run CSV results (auto-landed via 9p)
│   └── checkpoints/              # gem5 checkpoints (rarely needed)
└── logs/
    ├── gem5.out                  # raw gem5 simulation output (primary debug log)
    ├── gem5.out.prev             # backup of previous run's gem5.out
    ├── gem5.pid                  # PID of running gem5 process
    ├── phase1_readfile_<tag>.sh  # gem5 startup script handed to the guest
    └── driver_phase1_<tag>.log   # combined driver + guest log
```

---

## 6. Build Information

### 6.1 gem5 binary

| Item | Value |
|---|---|
| Path | `SimpleSSD-FullSystem/build/X86/gem5.opt` |
| Size | ~1.1 GB |
| Last built | 2026-05-11 13:40 (this server) |
| Build system | SCons 3.1.2 |
| Python | 2.7.15 (conda env `simplessd_env`) |

**Rebuild command** (run from this server's workspace root):
```bash
cd SimpleSSD-FullSystem
conda run -n simplessd_env \
  env LD_LIBRARY_PATH="$(conda run -n simplessd_env python -c \
    'import sys,os; print(os.path.join(sys.prefix,"lib"))')" \
  scons -j$(nproc) build/X86/gem5.opt
```
The `LD_LIBRARY_PATH` passthrough is required because the `marshal` helper inside
SCons links against `libpython2.7.so.1.0` which is in the conda env's `lib/`, not on
the system path. **If you skip this step, scons "succeeds" silently without
refreshing the binary.** Always check the mtime of `build/X86/gem5.opt` after.

Rebuild takes ~30 min on `tzhang1`. Unit-test build (rare): `scons build/NULL/unittests.opt`.

### 6.2 Conda environment `simplessd_env`

```
Python  2.7.15
SCons   3.1.2
PLY     3.11
six     1.16.0
```

To create from scratch:
```bash
conda create -n simplessd_env python=2.7 -y
conda run -n simplessd_env pip install scons==3.1.2 ply six
```

### 6.3 Guest SPDK binary

| Item | Value |
|---|---|
| Path | `docker_artifacts/guest_spdk_nvme_perf` |
| Size | ~6.5 MB |
| Built in | Docker (Ubuntu 18.04, glibc 2.27, no SSSE3) |
| Source | `spdk/` directory (this repo) |

**Rebuild:**
```bash
./scripts/build_spdk_docker.sh
```
The Ubuntu 18.04 glibc 2.27 target is required: the simulated CPU in gem5 lacks
SSSE3, so any binary that uses SSSE3 instructions (newer libc, etc.) crashes with
`SIGILL` (rc=132).

Backup copies live in `docker_artifacts/guest_spdk_nvme_perf.<milestone>_<date>` —
useful when bisecting a regression. The SPDK source patches per milestone are
archived in `docker_artifacts/spdk_patches_archive/`.

### 6.4 Guest kernel

| Item | Value |
|---|---|
| Version | Linux 5.4.49 |
| File | `assets/vmlinux-5.4.49` (24 MB) |
| Required features | `VFIO`, `VIRTIO_9P`, `VIRTIO_PCI` (built-in, **not modules**) |

Rebuild script: `scripts/build_guest_kernel_vfio.sh` (rarely needed; the prebuilt
vmlinux is fine).

---

## 7. I/O-Uncore Implementation Reference

This is the most important section for new agents — the project's research
contribution lives here.

### 7.1 Mode taxonomy

Defined in `SimpleSSD-FullSystem/src/dev/storage/simplessd/hil/nvme/controller.hh`:

```cpp
typedef enum {
  UNCORE_MODE_DISABLED = 0,   // baseline — no offload
  UNCORE_MODE_A        = 1,   // transparent: SQ-fetch gate + CQE staging buffer
  UNCORE_MODE_B        = 2,   // Mode A + Mailbox SQ Engine + typed hint reg
} UncoreMode;
```

Cfg key `UncoreMode` ∈ {0, 1, 2} (validated in `config.cc:199-202`).

**Pipeline of `--uncore-mode N`:**

```
driver_phase1.sh --uncore-mode N
  └── sed -i 's/^(UncoreMode)[[:space:]]*=.*/\1 = N/' fast_ssd_highiops.cfg    (line ~610)
  └── exports UNCORE_MODE=N into the readfile script via __UNCORE_MODE__ substitution
        └── phase1_run.sh: if [ "$UNCORE_MODE" = "2" ] then export SPDK_UNCORE_MODE_B=1
              └── nvme_pcie.c: only when SPDK_UNCORE_MODE_B=1 does SPDK map
                  uncore_mailbox_base / uncore_free_cid_base / uncore_qdepth_base
                    └── otherwise SPDK falls through to vanilla TAILQ + 64B SQE path
```

So Mode 2 is **cooperatively** activated on both sides. If the SPDK side is not
opted in (env var unset), SPDK behaves exactly like vanilla SPDK regardless of what
the simulator config says.

### 7.2 BAR0 layout (32 KB total)

`NVMe.py` sets `BAR0Size = '32768B'`. Layout:

| Range | Purpose | Direction |
|---|---|---|
| `0x0000 – 0x0FFF` | Standard NVMe registers (CAP, VS, INTMS, CC, CSTS, AQA, ASQ/ACQ, …) | R/W |
| `0x1000 – 0x1FFF` | NVMe doorbells (`[REG_DOORBELL_BEGIN, REG_DOORBELL_END)`) | W |
| `0x2000 – 0x2003` | **Mech #4: typed hint register** `(count:16, age_units:16)` | R (RO) |
| `0x2004 – 0x2FFF` | Reserved | — |
| `0x3000 – 0x3FFF` | **Mode 2 v1: Mailbox region** (65 qids × 32-byte slots; used up to `0x3820`) | W |
| `0x4000 – 0x43FF` | **Mech #1: Free-CID ring read endpoints** (1 × uint32 per qid; side-effect pop) | R |
| `0x4400 – 0x47FF` | **Mech #2: Queue-depth counter read endpoints** (1 × uint32 per qid; side-effect-free) | R |
| `0x4800 – 0x7FFF` | Reserved for Mode 3 / future extensions | — |

`cqsize = MaxIOCQueue + 1 = 65` for the active cfg (`MaxIOCQueue = 64`), so the
mailbox uses `65 × 0x20 = 0x820` bytes (up to `0x3820`) and the free-CID / qdepth
regions use `65 × 4 = 0x104` bytes each. **The free-CID base moved `0x3400 → 0x4000`
and qdepth `0x3800 → 0x4400` on 2026-05-14** to give the mailbox region a full 4 KB
of headroom now that `MaxIOCQueue` grew `16 → 64` for multi-qpair work; the SPDK
macros (`nvme_pcie_internal.h`), the cfg (`FreeCIDBase = 0x4000`), and the controller
defaults moved together. The single-qpair headline runs dated `20260510` predate this
relayout, but the exact offsets are not result-determining (they only relocate the MMIO
windows), so the measured IOPS are unaffected.

> **Critical historical bug:** before `REG_DOORBELL_END = 0x2000` existed, the
> doorbell handler was a catch-all for any offset ≥ 0x1000. That misrouted every
> mailbox MMIO write as a `ringSQTailDoorbell(qid=1024)`. The fix bounds the
> doorbell window to `[0x1000, 0x2000)` in `nvme_interface.cc` and falls through to
> `writeRegister` / `readRegister` for the upper regions.

### 7.3 Mailbox wire format — compact 24-byte SQE

Host writes 3 sequential 8-byte values to `BAR0 + MailboxBase + qid * MailboxStride`:

| Offset | Bytes | Field | Encoding |
|---|---|---|---|
| `+0x00` | 8 | Word 0 | `[63:56]` opcode · `[55:48]` flags · `[47:32]` cid · `[31:0]` nsid |
| `+0x08` | 8 | Word 1 | `[63:0]` slba |
| `+0x10` | 8 | Word 2 | `[63:32]` prp1_lo32 (host data-buffer DMA address, low 32 bits; PRP2 forced 0, single-page only) · `[31:16]` nlb (0-based) · `[15:0]` control |

Controller's `handleMailboxWrite()` FSM latches each 8-byte write
(`S_LATCH_0/1/2`, 1 cycle each); after the third word lands it arms
`mailboxInjectEvent` at `tick + (MailboxDecodeCycles + MailboxInjectCycles) × 1 ns`.
On fire, `mailboxInject()` decodes the descriptor into a full `SQEntryWrapper`,
pushes it into `lSQFIFO`, and schedules `requestEvent` so `handleRequest` picks it
up via the Path-E fast-path.

**Falls back to standard 64-byte SQE path for:**
- admin qpair (`qid == 0`)
- multi-page transfers (`payload_size > ctrlr->page_size`)
- non-read / non-write opcodes

### 7.4 Source files — SimpleSSD controller side

Per-feature ownership in `SimpleSSD-FullSystem/src/dev/storage/simplessd/hil/nvme/`:

| Feature | Files / functions |
|---|---|
| **Path-E fast-path (§6.5)** | `controller.{hh,cc}`: `fastPathEnqueue`, `fastPathDispatch`, `channelNextFree[]`, `fastPathOutstanding`; `config.{hh,cc}`: `FastPathEnabled`, `FastPathLmin`, `FastPathTmaxPerChannel`, `FastPathChannelPolicy`, `FastPathMaxOutstanding` |
| **Mode 1 — SQ-fetch gate + CQE staging** | `controller.cc`: `collectSubmissionRequest` (Gate 1), `uncoreFlushCQBuffer` (Gate 2), `uncorePendingCQE` vector, `uncoreFlushScheduled` flag |
| **Mode 2 v1 — Mailbox SQ Engine** | `controller.{hh,cc}`: `handleMailboxWrite`, `mailboxInject`, `MailboxLatch` struct, `mailboxInjectEvent`; `def.hh`: `REG_DOORBELL_END = 0x2000`; `nvme_interface.cc`: doorbell-window bound + fall-through to `writeRegister/readRegister` |
| **Mech #1 — HW free-CID ring** | `controller.{hh,cc}`: `FreeCIDRing` struct, `freeCidReadNext`, `freeCidRecycle`, `freeCidRings` vector |
| **Mech #2 — HW queue-depth counter** | `controller.{hh,cc}`: `getInflightCount` (in `readRegister` for `BAR0+0x4400+qid*4`) |
| **Mech #4 — typed hint register** | `controller.{hh,cc}`: `getMultiBitHint` (`BAR0+0x2000`), `hintOldestArrivalTicks`; cfg key `HintAgeGranularityPs` |
| **BAR0 size = 32 KB** | `NVMe.py`: `BAR0Size = '32768B'` |
| **Cfg-key parsing for all of the above** | `config.cc` parse branches + `readUint` dispatch; `config.hh` enum entries + private members |

The `readRegister` dispatcher in `controller.cc` handles the new MMIO regions
**before** the generic 64-byte register-union memcpy — this is critical because
reading offsets like 0x2000 from a 64-byte union would otherwise be undefined
behavior (OOB memcpy was a real bug we fixed).

### 7.5 Source files — SPDK side

In `spdk/lib/nvme/`:

| Feature | Files / functions |
|---|---|
| **MMIO offset macros + field decls** | `nvme_pcie_internal.h`: `MAILBOX_BASE_OFFSET=0x3000`, `MAILBOX_STRIDE_BYTES=0x20`, `FREE_CID_BASE_OFFSET=0x4000`, `QDEPTH_BASE_OFFSET=0x4400` (both moved up 0xC00 on 2026-05-14 for mailbox headroom); fields `uncore_mailbox_base`, `uncore_free_cid_base`, `uncore_qdepth_base`, `uncore_hint_reg` on `nvme_pcie_ctrlr` |
| **BAR mapping (env-var gated)** | `nvme_pcie.c`: when `SPDK_UNCORE_MODE_B=1` AND BAR0 ≥ `QDEPTH_BASE_OFFSET+256`, map all three pointers; otherwise leave NULL |
| **Submit path (Mech #1)** | `nvme_pcie_common.c::nvme_pcie_qpair_submit_request`: when `uncore_free_cid_base != NULL && qpair->id != 0`, read next free CID via one MMIO load, use `pqpair->tr[hw_cid]` directly, **skip** `TAILQ_REMOVE(free_tr)` + `TAILQ_INSERT_TAIL(outstanding_tr)` + `qpair->queue_depth++` |
| **Submit path (Mode 2 mailbox)** | `nvme_pcie_common.c::nvme_pcie_qpair_submit_request`: after tracker is allocated but **before** `build_prps`, branch into the deep-offload path — skip PRP construction, emit 3 × 8-byte MMIO writes to the mailbox slot, skip the standard SQ doorbell, `goto exit` |
| **Complete path** | `nvme_pcie_common.c::nvme_pcie_qpair_complete_tracker`: in the `hw_managed` branch (Mech #1 active), skip the symmetric `TAILQ_REMOVE(outstanding_tr)` + `TAILQ_INSERT_HEAD(free_tr)` + `queue_depth--`. Hardware auto-recycled the CID via `freeCidRecycle()` when the CQE flushed. |
| **Poll path (Mech #4)** | `nvme_pcie_common.c::nvme_pcie_qpair_process_completions`: parse the hint reg as `(count:16, age_units:16)`; skip the CQ scan only when `count == 0 && age_units < 4` (4 µs age threshold). |
| **Env var gate** | `SPDK_UNCORE_MODE_B=1` exported by `phase1_run.sh:43-49` when `UNCORE_MODE=2` |

### 7.6 New gem5 stats counters

All under prefix `nvme0.controller.uncore.` in
`SimpleSSD-FullSystem/m5out/stats.txt`:

| Stat | What it counts |
|---|---|
| `sqes_visible` | Cumulative SQEs visible to Gate 1 across all work cycles |
| `collect_deferred` | Gate 1 deferrals (SQE-count threshold not met) |
| `collect_allowed` | Gate 1 pass-throughs (threshold met → fetch) |
| `cqes_generated` | I/O CQEs entering Mode 1 staging buffer |
| `cqes_admin_bypassed` | Admin CQEs that bypassed staging (immediate path) |
| `cqes_published` | CQEs flushed from staging into `lCQFIFO` (host-visible) |
| `flush_by_count` / `flush_by_timeout` / `flush_by_shutdown` | Trigger reason for each flush |
| `flush_depth_hist_<0..63>` | Histogram of CQEs per flush event |
| `mailbox_submissions` | Mode 2: third mailbox word landed → SQE injected |
| `mailbox_latch_resets` | Mid-sequence word-order violations (qid guard fired) |
| `mailbox_oversize_fallback` | Multi-page transfers rejected; SPDK fell back |
| `mailbox_decode_cycles` / `mailbox_inject_cycles` | Cumulative S_DECODE / S_INJECT cycles |
| `free_cid_pops` | Mech #1: successful free-CID pops via MMIO read |
| `free_cid_pushes` | Mech #1: CIDs recycled into the free ring on CQE flush |
| `free_cid_starvations` | Mech #1: pop on empty ring (returned 0xFFFF; host backs off) |
| `qdepth_reads` | Mech #2: MMIO reads of in-flight count |
| `hint_typed_reads` | Mech #4: reads of the typed hint register |

### 7.7 Smoke command — Mode 2 + Mechs at QD=16

```bash
./scripts/phase1_4k/driver_phase1.sh --auto \
  --core-masks "0" --qpairs "1" \
  --qd "16" --ios "4096" --repeats 1 --steady-time 5 \
  --ssd-config "$PWD/fast_ssd_highiops.cfg" \
  --uncore-mode 2 \
  --tag paper_qdsweep_mode2plus_smoke
```

**Pass criteria** (after `PHASE1_RUNSCRIPT_DONE`) — calibrated against
`paper_qdsweep_mode2_20260510`:
- `mailbox_submissions ≈ free_cid_pops ≈ free_cid_pushes ≈ cqes_published`
- `free_cid_starvations == 0`, `mailbox_oversize_fallback == 0`
- CSV `Doorbell_ns ≈ 1.1`, `Fence_ns ≈ 1.8` (SPDK still emits the unconditional
  fence/doorbell wrappers; their cost is sub-ns/IO so we leave them alone)
- CSV `Addr_Xlate_ns ~ 153 ns` at QD=128 (down from ~337 ns in Mode 0; the residual
  is the SPDK-side mailbox-word build, not PRP-list construction)
- CSV `State_Dealloc_ns ~ 156 ns` at QD=128 (down from ~295 ns in Mode 0)
- CSV `IOPS ≈ 1.10 M` at QD=16 → QD=128 (Mode 0 baseline = 776 K @ QD=16 → 819 K @ QD=128)

---

## 8. Source-Level Fixes Applied

All gem5/SimpleSSD/SPDK fixes below are in the working tree; some are committed and
some are not yet. Do NOT revert.

### 8.1 Master list

| # | File | Issue → Fix | Section |
|---|---|---|---|
| 1 | `src/dev/storage/nvme_interface.cc` | `panic()` on unimplemented PCI cfg writes → changed to `warn()` so SPDK init completes | §8.2 |
| 2 | `src/arch/isa_parser.py` ~line 1401 | Python 2→3 string join bug → `code = pre + (post + pre).join(flag_list) + post` | §8.3 |
| 3 | `src/python/m5/util/grammar.py` | Old-style class instantiation broken on Py2 → use `new.instance(...)` with Py3 `__new__` fallback | §8.4 |
| 4 | `src/python/m5/util/__init__.py` | Unicode-aware version handling → `hasattr(v, 'split')` | §8.5 |
| 5 | `controller.{hh,cc}`, `config.{hh,cc}` | Add Path-E (NVMeVirt-style fast-path SSD timing) | §7.4 + `docs/PATH_E_FAST_PATH_PLAN.md` |
| 6 | `controller.{hh,cc}`, `nvme_interface.cc`, `def.hh`, `NVMe.py` | Add Mode 1 (SQ-fetch gate + CQE staging) + Mode 2 v1 (Mailbox SQ Engine) | §7.4 + `docs/superpowers/plans/2026-05-11-mode2-deep-offload.md` |
| 7 | `controller.{hh,cc}`, `config.{hh,cc}`, `NVMe.py` | Add Mechs #1 (free-CID ring) + #2 (qdepth counter) + #4 (typed hint reg) | §7.4 + `docs/superpowers/plans/2026-05-11-cq-side-offload-mech124.md` |
| 8 | `spdk/lib/nvme/nvme_pcie.c`, `nvme_pcie_common.c`, `nvme_pcie_internal.h` | SPDK-side support for Mode 2 mailbox + Mechs #1/#2/#4; gated by `SPDK_UNCORE_MODE_B=1` | §7.5 |
| 9 | `def.hh` | Doorbell catch-all routing bug: anything ≥ 0x1000 was a doorbell → bound to `[0x1000, 0x2000)` via `REG_DOORBELL_END = 0x2000` | §7.2 |
| 10 | `controller.cc::readRegister` | OOB memcpy when reading non-standard offsets (0x2000, 0x3xxx) from a 64-byte union → early-return branches before the generic memcpy | §7.4 |
| 11 | `scripts/boot_gem5.sh` | gem5 died on SSH disconnect → `setsid nohup nice -n 19 taskset … & disown` (full session detachment) | §4.3 |

### 8.2 `nvme_interface.cc` — panic → warn (historical)

```
panic: nvme_interface: PCI config write to unimplemented offset: 0x98 size: 2
```
SPDK writes to PCIe Slot Control registers during init. Now we `warn()` and
continue; full I/O proceeds.

### 8.3 `isa_parser.py` — Python 2 join bug

`string.join(flag_list, post + pre)` (Py2 syntax) was wrongly converted to
`post + pre.join(flag_list)` (which means `post + (pre.join(flag_list))`). Correct
form:
```python
code = pre + (post + pre).join(flag_list) + post
```

### 8.4 `grammar.py` — old-style class instantiation

`TypeError: unbound method instance() must be called with LRParser instance as
first argument`. Fix uses `new.instance(ply.yacc.LRParser, inst_dict)` with a
Python 3 `__new__` fallback.

### 8.5 `m5/util/__init__.py` — Py2 unicode in `make_version_list`

`isinstance(v, (str, bytes))` returned False for Py2 unicode. Changed to
`hasattr(v, 'split')`.

---

## 9. Running Simulations

### 9.1 Minimal smoke

```bash
cd /home/fangy6/SimpleSSD_Gem5_simulation
tmux new -s smoke
./scripts/phase1_4k/driver_phase1.sh --auto \
  --qd "16" --ios "4096" --repeats 1 --steady-time 2 \
  --tag smoke_v1
```
Defaults are already correct (readfile + 9p mode). `Ctrl-B D` to detach; gem5 keeps
running via `setsid`. Re-attach with `tmux attach -t smoke`.

### 9.2 Full Phase 1 sweep

```bash
./scripts/phase1_4k/driver_phase1.sh --auto \
  --core-masks "0" --qpairs "1" \
  --qd "16 32 64 128" --ios "4096 16384" \
  --repeats 3 --steady-time 30 \
  --ssd-config "$PWD/fast_ssd_highiops.cfg" \
  --uncore-mode 0 \
  --tag phase1_full_mode0
```
Repeat with `--uncore-mode 1` and `--uncore-mode 2` for mode comparisons. Each
sweep takes a few hours.

### 9.3 Monitoring a run

```bash
tail -f logs/gem5.out                                # raw gem5 output
tail -f logs/driver_phase1_<tag>.log                 # driver + guest combined log
./scripts/console_gem5.sh                            # interactive guest serial console
pgrep -af gem5.opt                                   # ALWAYS use this for liveness check
                                                     # (boot_gem5.sh status is unreliable)
ls -la results/phase1_runs/<tag>/                    # CSVs land here as the sweep runs
```

### 9.4 Stopping gem5

```bash
./scripts/boot_gem5.sh stop
```
Do not `kill -9` — diod can leak. If you must, also `pkill diod`.

### 9.5 Plotting

```bash
python3 scripts/phase1_4k/plot_phase1.py             # IOPS / latency curves
python3 scripts/phase1_4k/plot_multicore_gem5.py     # multi-core sweep
python3 scripts/phase1_4k/plot_bdev.py               # bdev baseline
python3 scripts/phase1_4k/plot_io_breakdown.py       # per-stage cycle breakdown
python3 scripts/phase1_4k/summarize_phase1.py        # aggregate stats across runs
```

### 9.6 Disk-image bake (rarely needed)

In 9p mode the disk image only needs to contain the OS and a bootable rootfs.
Every `phase1_run.sh`, `docker_artifacts/`, and `fast_ssd*.cfg` edit is picked up
live via `/mnt/9p`. You only need to re-bake when:
- changing files that live *outside* the host workspace (e.g. kernel binary), or
- testing a non-9p fallback.

To bake:
```bash
sudo ./scripts/bake_disk_image.sh \
  --disk-image ./assets/x86-ubuntu.img \
  --src-repo . \
  --dst-path /root/SimpleSSD_Gem5_simulation
```

---

## 10. SimpleSSD Configuration Files

Two configs live at the repo root:

- `fast_ssd.cfg` — **baseline** (Samsung 970 EVO-class, MLC V-NAND timing,
  ~95 K IOPS theoretical peak).
- `fast_ssd_highiops.cfg` — **ACTIVE for the IEEE-CAL paper** (Storage-Next class,
  XL-FLASH-array sense, Gen5×16, ~8 M IOPS aggregate device ceiling =
  FastPathTmaxPerChannel 250 K × pal.Channel 32).

### 10.1 Baseline `fast_ssd.cfg` snapshot

| Attribute | Value |
|---|---|
| NAND type | MLC (2-bit), LSBRead 45 µs / MSBRead 65 µs |
| Channels × ways × dies × planes | 8 × 4 × 2 × 2 = 128 parallel units |
| DMA | 400 MT/s × 8-bit per-channel |
| Controller CPU | 400 MHz × 3 cores (HIL+ICL+FTL) |
| Host PCIe | Gen2 × 4 = 2 GB/s |
| DRAM cache | 512 MiB, 8-way set-associative, LRU |
| FillRatio | 0.5 (50% pre-filled so reads hit NAND) |

### 10.2 Highiops cfg — diffs from baseline

| Section.Key | Baseline | Highiops | Reason |
|---|---:|---:|---|
| `cpu.ClockSpeed` | 400 MHz | **32 GHz** | Modeling abstraction — see note below |
| `pal.Channel` | 8 | **32** | 4× more parallel NAND buses |
| `pal.LSBRead` | 45 µs | **1 µs** | XL-FLASH array sense |
| `pal.MSBRead` | 65 µs | **2 µs** | Same |
| `pal.DMASpeed` | 400 | **1600** | NV-DDR3 mode 5 |
| `pal.DMAWidth` | 8 | **16** | 16-bit NAND bus |
| `nvme.PCIEGeneration` | 2 (Gen3) | **4 (Gen5)** | ~63 GB/s; ~10 M IOPS PCIe-BW ceiling |
| `nvme.PCIELane` | 4 | **16** | (Gen5 ×16 = 63 GB/s) |
| `nvme.AXIBusWidth` | 2 (128b) | **5 (1024b)** | 64 GB/s sustained |
| `nvme.AXIClock` | 250 MHz | **500 MHz** | (with 1024b, 64 GB/s) |
| `nvme.WorkInterval` | 1 µs | **50 ns** | 20× faster controller dispatch |
| `nvme.MaxRequestCount` | 8 | **128** | Drain a fuller SQ per work iteration |
| `cpu.{ICL,FTL}CoreCount` | 1 | **4** | Parallelize the two stages where SimpleSSD's multi-core audit found low hazards. **HILCoreCount stays at 1** — multi-core hazards in the HIL/NVMe path are unresolved. |
| `nvme.FastPathEnabled` | 0 | **1** | §7.4; Path-E |
| `nvme.FastPathTmaxPerChannel` | n/a | **250000** | 250 K IOPS/channel × 32 channels = **8 M IOPS aggregate** device ceiling (lowered from 1 M/channel = 32 M on 2026-05-15 for a realistic ~10× host headroom) |
| `nvme.MaxIOCQueue` / `MaxIOSQueue` | 16 | **64** | Multi-qpair headroom (relayout 2026-05-14); drives `cqsize = 65` and the BAR0 region offsets in §7.2 |
| `nvme.UncoreMode` | 0 | **2** | §7.1; mailbox + hint reg active |
| `nvme.MailboxBase` / `Stride` / `Latch` / `Decode` / `InjectCycles` | n/a | **0x3000 / 0x20 / 1 / 8 / 4** | §7.3 |
| `nvme.FreeCIDBase` / `FreeCIDLatencyCycles` / `HintAgeGranularityPs` | n/a | **0x4000 / 2 / 1024000 ps** | §7.4 (Mechs #1/#2/#4); qdepth implicitly at FreeCIDBase+0x400 = 0x4400 |

> **`cpu.ClockSpeed = 32 GHz` note:** this is a **modeling abstraction** — it
> compresses the per-IO HIL/ICL/FTL cycle tables (`cpu/cpu.cc:162+`) to ~0.17 µs/IO
> so the controller stops being the binding bottleneck and the *host* becomes the
> binding bottleneck (which is the research focus). It is not a real-silicon claim.

> **Run-time override:** `driver_phase1.sh` `sed`-overrides `UncoreMode` from the
> `--uncore-mode N` CLI flag at line ~610. The static cfg default does not matter
> for mode sweeps — the CLI flag wins.

All timing values in both cfg files are **picoseconds**. Conversions:

| Cfg value | Actual time |
|---|---|
| 1,000 | 1 ns |
| 1,000,000 | 1 µs |
| 1,000,000,000 | 1 ms |

---

## 11. Datasets and How to Interpret Them

Every Phase 1 run produces two complementary datasets, both visible on the host
under `results/` immediately via 9p.

### 11.1 Summary CSV — `phase1_results.csv`

- **Location:** `results/phase1_runs/<tag>/<core>_<qp>/phase1_results.csv`
- **Granularity:** one row per `(QD, IO_Size, Run_ID)` combination
- **Source:** parsed from `spdk_nvme_perf` stdout + `perf stat` output by
  `phase1_run.sh`

| # | Column | Unit | Description |
|---|---|---|---|
| 1 | `QD` | count | Queue depth per qpair |
| 2 | `Qpairs` | count | Number of NVMe I/O queue pairs |
| 3 | `IO_Size` | bytes | I/O request size |
| 4 | `Run_ID` | index | Repeat number (1-based) |
| 5 | **`IOPS`** | IO/s | **Primary throughput metric** |
| 6–11 | `Cycles`, `Instructions`, `LLC_Misses`, `Dram_Read_Bytes`, `Dram_Write_Bytes`, `Energy_Joules` | various | `perf stat` outputs — **all zero inside gem5** (no PMU on simulated CPU) |
| 12 | **`Cycles_Per_IO`** | cyc/IO | Zero in gem5 — the key metric on real hardware |
| 18–20 | `p50_Latency`, `p99_Latency`, `p99.9_Latency` | µs | Latency percentiles from SPDK histogram |
| 21–24 | `Polls`, `Completions`, `Scans_Per_Completion`, `Completions_Per_Call` | various | Polling efficiency |
| 25 | `MMIO_Writes_Per_IO` | ratio | ~2.0 baseline (1 SQ + 1 CQ doorbell); Mode 2 reduces this |
| 26 | `Completions_Per_Poll_Hist` | string | `"0:N0, 1:N1, …"` histogram |
| 27 | **`Submit_Logic_ns`** | ns | Software submit overhead per IO |
| 28 | **`Completion_Logic_ns`** | ns | Software completion overhead per IO |
| 29–37 | `Submit_Preamble_ns`, `Tracker_Alloc_ns`, `Addr_Xlate_ns`, `Cmd_Construct_ns`, `Fence_ns`, `Doorbell_ns`, `CQE_Detect_ns`, `Tracker_Lookup_ns`, `State_Dealloc_ns` | ns | **Per-stage breakdown — THE key data** |

The 29–37 stage columns are what the paper plots show. In Mode 0 the dominant
costs are `Addr_Xlate_ns ~337`, `State_Dealloc_ns ~295`, `Tracker_Alloc_ns ~218`.
Mode 2 + Mechs targets `Addr_Xlate_ns ≈ 0`, `Doorbell_ns ≈ 0`, `Tracker_Alloc_ns
< 50 ns`, `State_Dealloc_ns ~145 ns`.

### 11.2 Per-IO Cycle Breakdown CSV — `cycle_breakdown_s<size>_q<qd>_r<run>.csv`

- **Location:** `results/phase1_runs/<tag>/<core>_<qp>/logs/cycle_breakdown_*.csv`
- **Granularity:** one row per individual I/O operation (ring buffer = 100 K)
- **Source:** SPDK instrumentation ring in `spdk/lib/nvme/nvme_qpair.c`, dumped on
  exit via `atexit(nvme_io_cycle_dump)`. Uses `rdtsc` timestamps.

Columns: `cid`, `qid`, `t_start`, `t_sqe_copy`, `t_doorbell`, `t_completion`,
`t_end`, `t_poll_cycles`, `submit_ns`, `completion_ns`, plus all nine per-stage
`*_ns` columns from the summary CSV.

Derived metrics:

| Metric | Formula | Meaning |
|---|---|---|
| **Device latency** | `(t_completion - t_doorbell) / ticks_per_ns` | Time inside the SSD model (NAND + controller + DMA). Dominant component. |
| **Total IO latency** | `(t_end - t_start) / ticks_per_ns` | End-to-end |
| **Software overhead** | `submit_ns + completion_ns` | CPU time in SPDK driver |
| **ticks_per_ns** | `(t_doorbell - t_start) / submit_ns` | **2.0** for this sim (gem5 at 2 GHz tick rate) |

**Cold-start note:** the first 1–2 rows are outliers (cache cold, TLB miss); skip
them for steady-state analysis.

### 11.3 gem5 stats — `SimpleSSD-FullSystem/m5out/stats.txt`

Generated by gem5 at simulation end (or `m5 exit`). Key counters:

| Stat | Meaning |
|---|---|
| `system.pc.nvme.command_count` | Total NVMe commands processed (≈ Completions from CSV) |
| `system.pc.nvme.bytes` | Total data transferred |
| `system.pc.nvme.busy` | Total device busy time (ps) |
| `system.pc.nvme.pal.read.count` | NAND read ops (>0 if FillRatio > 0) |
| `system.pc.nvme.pal.read.time.total` | Average NAND read time |
| `system.pc.nvme.icl.generic_cache.read.from_cache` | DRAM-cache hits |
| `system.pc.nvme.icl.generic_cache.read.request_count` | Total reads to ICL (≈ command_count) |
| `system.pc.nvme.ftl.page_mapping.gc.count` | GC events (0 for pure read workloads) |
| `nvme0.controller.uncore.*` | All §7.6 counters |

---

## 12. Debugging Reference

### 12.1 `gem5.out` milestones (in order)

```
warn: nvme_interface: Ignoring PCI config write …    → EXPECTED, §8.2 fix
[Uncore] SQ Engine mailbox enabled at BAR0+0x3000    → Mode 2 mailbox armed
… free-CID @ BAR0+0x4000, qdepth @ BAR0+0x4400       → SPDK mapped Mech #1/#2 windows
HIL::NVMe: BAR0 | WRITE | Controller Configuration   → SPDK enabling NVMe
HIL::NVMe: SQ 0 | CREATE                             → Admin queue created
HIL::NVMe: SQ 0 | Submission Queue Tail Doorbell     → First I/O submitted
PHASE1_RUNSCRIPT_DONE                                 → Guest script done (success)
panic: …                                              → Fatal error
```

### 12.2 Failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| `diod: caught SIGTERM` | Terminal PTY killed gem5's session | Fixed by `setsid` in boot_gem5.sh; rebuild if old binary |
| Driver prints `gem5 died unexpectedly` | gem5 panic or OOM | `tail -50 logs/gem5.out` |
| No CSV in `results/<tag>/` | Guest script never ran | Check `logs/driver_phase1_<tag>.log` for `PHASE1_RUNSCRIPT_LOG_BEGIN` |
| `DPDK init failed` in guest | Hugepages not configured | `phase1_run.sh` runs `setup.sh` and has `--no-huge` fallback |
| `panic: nvme_interface: PCI config write` | Old binary without §8.2 fix | Rebuild from current source |
| `rc=132` in guest | SIGILL (SSSE3 instruction on simulated CPU lacking it) | Rebuild SPDK in Docker — `scripts/build_spdk_docker.sh` |
| Driver hangs indefinitely | Was a bug; now `kill -0` death-check catches in 5s | Check `logs/gem5.pid` vs `pgrep -af gem5.opt` |
| `boot_gem5.sh status` says "not running" but `pgrep -af gem5.opt` finds it | Brittle PID-file logic | Trust `pgrep` |
| Mailbox region writes misroute as doorbells (qid out of range) | Missing `REG_DOORBELL_END` bound | §7.2 / §8 row 9 — fix is committed |
| Crash on read of `0x2000` etc. | OOB memcpy in `readRegister` | §7.4 / §8 row 10 — fix is committed |

### 12.3 Useful one-liners

```bash
# Is gem5 actually alive?
pgrep -af gem5.opt

# What stage is gem5 at?
tail -50 logs/gem5.out

# What's the latest CSV row?
ls -lt results/phase1_runs/*/*/phase1_results.csv | head -3
tail -1 results/phase1_runs/<tag>/core0_qp1/phase1_results.csv

# Verify mech counters are non-zero after a Mode 2 run
grep -E "free_cid_pops|free_cid_pushes|mailbox_submissions|cqes_published" \
  SimpleSSD-FullSystem/m5out/stats.txt

# Verify gem5 binary contains a symbol
nm -D --defined-only SimpleSSD-FullSystem/build/X86/gem5.opt \
  | grep -E "handleMailboxWrite|freeCidReadNext|getMultiBitHint"
```

---

## 13. Remote Server Reproduction (this machine)

- **Host:** `tzhang1.ecse.rpi.edu`
- **User:** `fangy6`
- **No root needed** — all simulation runs as a normal user; diod is a system package.

### Setup on a fresh machine

```bash
ssh fangy6@tzhang1.ecse.rpi.edu

# Source (small — ~50 MB)
git clone https://github.com/fangyunh/Gem5-simpleSSD-SPDK-simulation.git ~/sim
cd ~/sim

# Conda env
conda create -n simplessd_env python=2.7 -y
conda run -n simplessd_env pip install scons==3.1.2 ply six

# Build gem5 (30–60 min)
cd SimpleSSD-FullSystem
conda run -n simplessd_env \
  env LD_LIBRARY_PATH="$(conda run -n simplessd_env python -c \
    'import sys,os; print(os.path.join(sys.prefix,"lib"))')" \
  scons -j$(nproc) build/X86/gem5.opt
cd ..

# Run
tmux new -s gem5sim
bash scripts/phase1_4k/driver_phase1.sh --auto \
  --qd 16 --ios 4096 --repeats 1 --steady-time 2 \
  --tag smoke_v1
```

### Large files not in git (rsync via `upload_large_files.sh`)

| File | Size | Destination |
|---|---|---|
| `x86-ubuntu.img` | 16 GB | `~/sim/assets/` |
| `vmlinux-5.4.49` | 24 MB | `~/sim/assets/` |
| `guest_spdk_nvme_perf` | ~6.5 MB | `~/sim/docker_artifacts/` |
| `guest_openssl11/` | ~4 MB | `~/sim/docker_artifacts/` |

`gem5.opt` (~1.1 GB) is **not** transferred — recompile from source.

---

## 14. Known Issues, Caveats, Open Questions

| Topic | Status |
|---|---|
| HIL multi-core hazards | `HILCoreCount` must stay at 1. See memory `project_simplessd_multicore_audit.md` — 5 HIGH-risk hazards (`uncoreFlushScheduled`, `uncorePendingCQE`, `aggregationMap`, `shutdownReserved`, `lSQFIFO`). Do not raise. |
| `CC.EN` shutdown bug | Fix at `controller.cc:1630` — see memory `project_simplessd_shutdown_bug.md`. Without it, first QD works but every subsequent QD hangs at init state 10. |
| IOPS ceiling on baseline cfg | ~74 K IOPS at QD=16 with `fast_ssd.cfg` 1×400 MHz HIL/ICL/FTL is the real ceiling, not a bug. See memory `project_iops_ceiling.md`. The highiops cfg lifts this. |
| Simulator SSD-side ceiling | With `FastPathEnabled=1` (Path-E) the highiops cfg bypasses the per-stage HIL/ICL/FTL/PAL event chain for I/O commands, so the SSD-side ceiling is the aggregate fast-path rate **~8 M IOPS** (FastPathTmaxPerChannel 250 K × 32 channels), not the old controller-CPU-bound number. **Do NOT re-cite the stale "~5400 cycles/IO, 10 M IOPS structurally infeasible" framing** — it predates the fast path. The host is the binding bottleneck at single-core; the device becomes binding only near ~5-7 host cores. See memory `project_simulator_iops_ceiling.md`. |
| Mode 1 lift in polling SPDK | Mode 1 gives ~0.96× of Mode 0 (small loss is expected — coalescing adds latency without removing host work). Don't claim a Mode 1 win under polling. |
| Mech #3 (cb-dispatch) | Deferred — requires SPDK API change. Documented in `docs/IO-Uncore RTL Design Specification…` §13.4. |
| `boot_gem5.sh status` | Unreliable. Always cross-check with `pgrep -af gem5.opt`. |
| Disk-image bake | Only required for changes outside the host workspace (kernel binary, base rootfs). Day-to-day script/config/SPDK edits are picked up via 9p with no bake. |
| Run-tag collisions | If two runs share a tag, the readfile and result dir collide. Always use a unique tag. |

---

## 15. Glossary

| Term | Meaning |
|---|---|
| **HIL** | Host Interface Layer — NVMe command parsing, doorbell processing, CQE posting |
| **ICL** | Internal Cache Layer — DRAM cache lookup, read/write caching, prefetch |
| **FTL** | Flash Translation Layer — logical→physical mapping, GC, wear leveling |
| **PAL** | Physical Abstraction Layer — NAND timing model |
| **CQE / SQE** | Completion Queue Entry / Submission Queue Entry (NVMe terms) |
| **SQ / CQ** | Submission Queue / Completion Queue |
| **PRP** | Physical Region Page — NVMe's scatter-gather list format |
| **CID** | Command Identifier — uniquely identifies an in-flight NVMe request |
| **Tracker** | SPDK-side in-memory record of an in-flight request (mapped 1:1 to CID) |
| **Mode 0 / 1 / 2** | I/O-Uncore offload modes — see §7.1 |
| **Mech #1 / #2 / #3 / #4** | Specific CQ-side mechanisms — see §7.4 / `RTL spec §13` |
| **Path-E** | NVMeVirt-style fast-path SSD timing model — see §7.4 / `PATH_E_FAST_PATH_PLAN.md` |
| **9p / diod** | virtio-9p file-sharing protocol / its server daemon — host↔guest file share |
| **readfile** | gem5 mechanism: a host script fed to the guest at boot, run as root |
| **m5 exit** | gem5 magic instruction that halts the simulation cleanly |

---

## 16. Where to extend this file

This file is the canonical onboarding doc. When something changes:

| Change | Update |
|---|---|
| New mode or mechanism lands | §7 + §10 + §14 |
| New source-level fix | §8 master list + a brief sub-section |
| New script in `scripts/phase1_4k/` | §5 directory layout + §9 if it's a user-facing command |
| New companion doc in `docs/` | §2.5 |
| Cfg knob renamed or added | §10 diff table + `fast_ssd_highiops.cfg` |
| Pass criteria for a mode/mech change | §7.7 |
| Known issue discovered | §14 |

Keep the "Last updated" date at the top current and add a one-line entry to the
change log if the change is project-wide.

**Change log:**
- 2026-05-12 — Restructured for fresh-agent onboarding: added §1 navigation cheat
  sheet, §2.5 companion-docs index, §7 unified I/O-Uncore implementation reference,
  §15 glossary, §16 maintenance guide. Renumbered to remove §9–§11 gap.
- 2026-06-07 — Refreshed against the live source for the paper §3 writing pass.
  Corrected stale values throughout: BAR0 free-CID `0x3400 → 0x4000` and qdepth
  `0x3800 → 0x4400` (relayout 2026-05-14 for `MaxIOCQueue 16 → 64`, `cqsize 65`);
  device ceiling `32 M → 8 M` aggregate (`FastPathTmaxPerChannel 250 K × 32`);
  retired the "~5400 cycles/IO, 10 M infeasible" framing (predates Path-E). The
  mailbox wire format in §7.3 was verified accurate against `controller.cc`
  (`word0=[opcode|flags|cid|nsid]`, `word1=slba`, `word2=[prp1_lo32|nlb|control]`,
  single-page only with multi-page fallback) and left unchanged.
- 2026-05-11 — Added Path-E fast-path; Mode 1 batching; Mode 2 v1 mailbox SQ Engine
  (24 B compact SQE @ BAR0+0x3000); Mechs #1/#2/#4 (HW free-CID ring @ 0x3400,
  qdepth counter @ 0x3800, typed hint reg @ 0x2000 — these offsets moved on 2026-05-14,
  see the 2026-06-07 entry). BAR0 grew 8 KB → 16 KB → 32 KB.
- 2026-03-19 — Initial onboarding document.
