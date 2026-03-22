# SimpleSSD + gem5 + SPDK Full-System Simulation — Project Context

**Last updated: 2026-03-19**
**Purpose of this file:** Complete onboarding document for a new agent or engineer. Covers
goals, architecture, all source-level fixes, current status, known problems, and exact
commands to continue work.

---

## 1. Project Goal

Run a repeatable full-system NVMe SSD performance simulation using:

- **gem5** (full-system X86 simulator) running a real Linux 5.4.49 kernel
- **SimpleSSD** (gem5 plugin implementing a faithful NVMe SSD model)
- **SPDK** (`spdk_nvme_perf`) running inside the guest to drive NVMe I/O

### 1.1 Current Workload — Phase 1 (Random Read IOPS Sweep)

The active experiment is a **4KB and 16KB random-read** IOPS sweep driven by
`spdk_nvme_perf`. The sweep covers:

| Parameter | Values |
|---|---|
| Queue depth (QD) | 16, 32, 64, 128 |
| I/O size | 4096 B, 16384 B |
| Queue pairs | 1 (single-core, core 0) |
| Access pattern | Random read (`-w randread`) |
| Measurement window | 30 s steady-state per point |

Results are collected as CSV files under `results/phase1_runs/<tag>/` and plotted
automatically by `scripts/plot_phase1.py`.

The goal of this phase is to establish a baseline IOPS vs. queue depth curve for the
SimpleSSD NVMe model, verify that the full simulation stack is functionally correct
end-to-end, and confirm that SPDK can reach the SSD at realistic throughputs inside gem5.

### 1.2 Research Direction — CPU Bottleneck at Ultra-High IOPS

The longer-term research question is: **at what NVMe throughput does the host CPU become
the bottleneck, and what is the exact CPU cost per I/O?**

The plan is to progressively tune the SimpleSSD configuration (`fast_ssd.cfg`) to reduce
simulated NAND latency — shrinking channel count, page latency, and queue service times —
until the SSD can sustain **tens of millions of IOPS**. At that point, the limiting factor
shifts from storage latency to CPU cycles spent in the NVMe driver stack (doorbell writes,
CQE polling, DMA completion handling inside SPDK).

Key metrics to track in this regime:
- `Cycles_Per_IO` — CPU cycles consumed per completed I/O (from perf stat or SimpleSSD counters)
- `Submit_Logic_ns`, `Completion_Logic_ns`, `Doorbell_ns`, `CQE_Detect_ns` — per-stage
  CPU time breakdown from SimpleSSD's internal debug counters
- IOPS saturation point as a function of QD and I/O size
- Whether the bottleneck is in the NVMe driver polling loop, DMA engine, or interrupt handling

This makes gem5 + SimpleSSD ideal for the study: the simulation exposes cycle-accurate
CPU microarchitecture events that are invisible in real hardware profiling.

---

## 2. Repository

**GitHub:** `https://github.com/fangyunh/Gem5-simpleSSD-SPDK-simulation.git`
**Local workspace root:** `/home/fangyunh/Documents/SimpleSSD_Gem5_simulation`
**Default branch:** `main` (HEAD: `894583b3`)

Key recent commits (newest first):
```
894583b3  spdk updates
e4ab92b0  driver_phase1: TAIL_LOG=0 default; heartbeat status in monitoring loop
eb14c219  driver_phase1: detect unexpected gem5 death in monitoring loop
32358ddd  boot_gem5: use setsid for full session detachment; raise nice to 19
ee13049d  Add upload_large_files.sh for remote server reproduction
e871d0f0  python2 build fix
```

---

## 3. Directory Layout

```
SimpleSSD_Gem5_simulation/
├── SimpleSSD-FullSystem/     # gem5 source (forked for SimpleSSD integration)
│   └── build/X86/gem5.opt   # compiled binary (973 MB, built 2026-03-19)
├── assets/
│   ├── x86-ubuntu.img        # guest disk image (16 GB, Ubuntu 18.04)
│   ├── vmlinux-5.4.49        # kernel with vfio/virtio-9p built-in (24 MB)
│   └── linux-stable/         # kernel source (reference)
├── docker_artifacts/
│   ├── guest_spdk_nvme_perf  # SPDK binary compiled for guest glibc 2.27 (6.9 MB)
│   └── guest_openssl11/      # OpenSSL 1.1.1 shared libs for guest runtime
├── scripts/
│   ├── driver_phase1.sh      # PRIMARY: orchestrates entire simulation run
│   ├── boot_gem5.sh          # start/stop/status gem5 daemon
│   ├── phase1_run.sh         # runs inside guest via readfile
│   ├── plot_phase1.py        # plots results CSVs
│   ├── plot_multicore.py
│   └── ...
├── fast_ssd.cfg              # SimpleSSD NVMe model configuration
├── upload_large_files.sh     # rsync large binaries to remote server
├── results/
│   └── phase1_runs/<tag>/    # per-run CSV results
└── logs/
    ├── gem5.out              # raw gem5 simulation output (primary debug log)
    ├── gem5.pid              # PID of running gem5 process
    └── driver_phase1_<tag>.log  # driver + guest log (combined)
```

---

## 4. Architecture

### 4.1 Simulation Stack

```
Host Linux
  └── gem5.opt  [setsid, nice -n 19, taskset to cores 0..(nproc-9)]
        ├── Simulated X86 O3CPU @ ~1GHz
        ├── Simulated 4 GB guest DRAM
        ├── SimpleSSD NVMe model  [3 virtual CPUs: HIL/ICL/FTL @ 400 MHz]
        │     └── NAND flash timing model (fast_ssd.cfg)
        ├── Linux 5.4.49 guest kernel (vmlinux-5.4.49)
        └── diod  [host 9p file server, child of gem5]
              └── exposes HOST_SHARE (= workspace root) as /mnt/9p in guest
```

### 4.2 Workflow (virtio-9p + readfile — the ONLY supported mode)

1. `driver_phase1.sh --auto` is invoked on the host inside a `tmux` session.
2. Driver generates a readfile script (`logs/phase1_readfile_<tag>.sh`) and starts gem5
   via `boot_gem5.sh start`.
3. gem5 boots Linux. After boot, gem5 reads the readfile script and runs it in the guest
   as root.
4. The readfile script:
   - Mounts the 9p share at `/mnt/9p`.
   - Runs `phase1_run.sh` to configure hugepages, bind NVMe device to SPDK, and
     execute `spdk_nvme_perf` sweep.
   - Writes CSV results to `/mnt/9p/results/phase1_runs/<tag>/` (visible on host
     immediately at `results/phase1_runs/<tag>/`).
   - Prints `PHASE1_RUNSCRIPT_DONE` and calls `m5 exit` to halt gem5.
5. Driver detects completion, calls `boot_gem5.sh stop`, and exits.

### 4.3 How gem5 is Detached from the Terminal

Three-layer isolation prevents VS Code / SSH disconnect from killing gem5:

| Mechanism | What it does |
|---|---|
| `setsid` | Creates a brand-new kernel session for gem5 + all children (including diod). No terminal-lifecycle signal (SIGHUP, SIGTERM from session teardown) can reach them. **This is the critical fix.** |
| `nohup` | Belt-and-suspenders, explicitly ignores SIGHUP. |
| `disown` | Removes gem5 from bash's job table. |

Additionally: `nice -n 19` (lowest CPU priority) + `taskset` (cores 0 to nproc-9, reserving
at least 8 cores for OS/other users) protect the host from CPU saturation.

---

## 5. Build Information

### 5.1 gem5 Binary

| Item | Value |
|---|---|
| Path | `SimpleSSD-FullSystem/build/X86/gem5.opt` |
| Size | 973 MB |
| Built | 2026-03-19 10:31 |
| Build system | SCons 3.1.2 |
| Python | 2.7.15 (conda env `simplessd_env`) |

**Rebuild command** (required on remote server or if source changes):
```bash
cd /home/fangyunh/Documents/SimpleSSD_Gem5_simulation/SimpleSSD-FullSystem
conda run -n simplessd_env \
  env LD_LIBRARY_PATH="$(conda run -n simplessd_env python -c \
    'import sys,os; print(os.path.join(sys.prefix,"lib"))')" \
  scons -j$(nproc) build/X86/gem5.opt
```

The `LD_LIBRARY_PATH` passthrough is required because the `marshal` helper binary
inside SCons links against `libpython2.7.so.1.0` which is in the conda env's `lib/`,
not on the system path.

### 5.2 Conda Environment (`simplessd_env`)

```
Python  2.7.15
SCons   3.1.2
PLY     3.11
six     1.16.0
```

Create on a new machine:
```bash
conda create -n simplessd_env python=2.7 -y
conda run -n simplessd_env pip install scons==3.1.2 ply six
```

### 5.3 Guest Kernel

- **Version:** Linux 5.4.49
- **Config:** includes `VFIO`, `VIRTIO_9P`, `VIRTIO_PCI` built-in (not modules)
- **File:** `assets/vmlinux-5.4.49` (24 MB)
- **Why custom:** stock kernel does not have virtio-9p or VFIO built-in; both are
  required for the 9p share mount and the NVMe model to function.

---

## 6. Source-Level Fixes Applied

All fixes are committed to `origin/main`. Do NOT revert them.

### 6.1 `src/dev/storage/nvme_interface.cc` — panic → warn

**Problem:** gem5 panicked and exited on every run with:
```
panic: nvme_interface: PCI config write to unimplemented offset: 0x98 size: 2
```
SPDK writes to PCIe Slot Control registers during initialization. SimpleSSD did not
implement these registers and called `panic()`.

**Fix:** Changed `panic(...)` to `warn(...)` for unimplemented PCI config writes so
simulation continues. Verified working — `gem5.out` now shows:
```
warn: nvme_interface: Ignoring PCI config write to unimplemented offset: 0x98 size: 2
```
and the simulation proceeds to full NVMe I/O.

### 6.2 `src/arch/isa_parser.py` — incorrect Python 2→3 string join

**Problem:** Build failed with gem5 generating malformed C++ flag initialization code.
The instruction flag constructor produced `flags[] = true;IsFloating` instead of
`flags[IsFloating] = true;`.

**Root cause:** `string.join(flag_list, post + pre)` (Python 2 syntax) was incorrectly
converted to `post + pre.join(flag_list)` instead of `(post + pre).join(flag_list)`.

**Fix (line ~1401):**
```python
code = pre + (post + pre).join(flag_list) + post
```

### 6.3 `src/python/m5/util/grammar.py` — old-style class instantiation

**Problem:** Build failed: `TypeError: unbound method instance() must be called with
LRParser instance as first argument`.

**Fix:** Used `new.instance(ply.yacc.LRParser, inst_dict)` for Python 2 old-style class
with `__new__` fallback for Python 3.

### 6.4 `src/python/m5/util/__init__.py` — Python 2 unicode in `make_version_list`

**Problem:** `isinstance(v, (str, bytes))` failed on Python 2 unicode strings from
SCons version variables.

**Fix:** Changed to `hasattr(v, 'split')` which works for `str`, `unicode`, and `bytes`
across Python 2 and 3.

---

## 7. SimpleSSD Configuration (`fast_ssd.cfg`)

### 7.1 What SSD Are We Simulating?

The configuration models a **Samsung 970 EVO-class NVMe SSD** with realistic MLC V-NAND
timing. Key attributes:

| Attribute | Value | Notes |
|---|---|---|
| **Form factor** | M.2 NVMe | PCIe Gen3 x4 interface (Gen2 x4 in config for gem5 compatibility) |
| **Raw capacity** | 512 GB | 8ch × 4way × 2die × 2plane × 512blk × 512pg × 16KB |
| **Usable capacity** | ~410 GB | 25% over-provisioning (OverProvisioningRatio=0.25) |
| **NAND type** | MLC (2-bit) | NANDType=1. LSB + MSB pages, no CSB |
| **NAND timing** | LSB read: 45 µs, MSB read: 65 µs | Realistic Samsung V-NAND MLC values |
| **NAND write** | LSB: 500 µs, MSB: 1300 µs | |
| **Block erase** | 3.5 ms | |
| **DMA interface** | 400 MT/s, 8-bit (ONFi 3.x mode 7) | Per-channel NAND bus |
| **Controller CPU** | 400 MHz, 3 cores (HIL+ICL+FTL) | Models ARM-class embedded processor |
| **Host interface** | PCIe Gen2 × 4 lanes = 2 GB/s | SimpleSSD models Gen0/1/2 only |
| **Internal bus** | AXI 128-bit @ 250 MHz = 4 GB/s | PCIe endpoint ↔ NVMe controller |
| **DRAM cache** | 512 MiB, 8-way set-associative | LRU eviction, read+write caching |
| **FTL** | Page-level mapping, CWDP allocation | Channel→Way→Die→Plane striping |
| **FillRatio** | 0.5 | 50% of LBAs pre-filled so reads hit NAND |

### 7.2 NAND Parallelism Structure

```
SSD
├── Channel 0..7  (8 channels, fully independent buses)
│   ├── Package/Way 0..3  (4 packages per channel, way-interleaved)
│   │   ├── Die 0..1  (2 dies per package, die-interleaved)
│   │   │   ├── Plane 0..1  (2 planes per die, multi-plane ops enabled)
│   │   │   │   ├── Block 0..511  (512 blocks per plane)
│   │   │   │   │   └── Page 0..511  (512 pages per block, 16 KB each)
```

- **Total NAND targets:** 8 × 4 × 2 × 2 = 128 parallel units
- **Total pages:** 33,554,432
- **SuperblockSize = C** → superblocks span all channels (striping)
- **PageAllocation = CWDP** → addresses are interleaved Channel → Way → Die → Plane

### 7.3 Per-IO NAND Timing Breakdown (16 KB page read)

All SimpleSSD timing is in **picoseconds**.

| Stage | Duration | Description |
|---|---|---|
| dma0 (command transfer) | 16.7 ns | 7 read-cycle commands over 400 MT/s bus |
| LSB cell sensing | 45 µs | NAND array read for lower page |
| MSB cell sensing | 65 µs | NAND array read for upper page (slower) |
| dma1 (data-out transfer) | 39.1 µs | 16 KB page data over 400 MT/s × 8-bit bus |
| **Total (LSB page)** | **~84 µs** | dma0 + LSBRead + dma1 |
| **Total (MSB page)** | **~104 µs** | dma0 + MSBRead + dma1 |

With 8 independent channels, theoretical peak random read IOPS ≈ 8 / 84 µs ≈ **95K IOPS**.
At QD=16, expect ~30–50K IOPS due to queueing and controller overhead.

### 7.4 Controller Processing Pipeline

SimpleSSD models the SSD controller as a 3-stage pipeline, each with a dedicated CPU core
running at 400 MHz:

| Core | Role | WorkInterval |
|---|---|---|
| **HIL** (Host Interface Layer) | NVMe command parsing, doorbell processing, CQE posting | 1 µs |
| **ICL** (Internal Cache Layer) | DRAM cache lookup, read/write caching, prefetch | 1 µs |
| **FTL** (Flash Translation Layer) | Logical→physical mapping, GC, wear leveling | 1 µs |

Each core wakes every WorkInterval (1 µs) and processes up to MaxRequestCount (8) requests.
This means an IO traverses at least 3 WorkInterval boundaries (~1.5 µs average wait each),
adding ~4.5 µs of controller scheduling overhead on top of NAND timing.

### 7.5 Config Units Reference

All timing values in `fast_ssd.cfg` are in **picoseconds** (1 ps = 10⁻¹² s), matching
SimpleSSD's internal simulation tick. Common conversions:

| Config value | Actual time |
|---|---|
| 1,000 | 1 ns |
| 1,000,000 | 1 µs |
| 1,000,000,000 | 1 ms |
| 45,000,000 | 45 µs (LSBRead) |
| 3,500,000,000 | 3.5 ms (Erase) |

---

## 8. Script Details

### `scripts/driver_phase1.sh` — PRIMARY ENTRY POINT

Defaults (already correct, do not need to be specified on the command line):
```
USE_READFILE  = 1   readfile mode on
AUTO_VIO_9P   = 1   auto-enable virtio-9p when readfile=1
VIO_9P        = 0   (auto-promoted to 1 by AUTO_VIO_9P logic)
HOST_SHARE    = <workspace root>
CORES         = "0"
QD_LIST       = "16 32 64 128"
IO_SIZES      = "4096 16384"
REPEATS       = 1
STEADY_TIME   = 30  seconds per measurement point
MEM_SIZE      = "4GB"
TAIL_LOG      = 0   gem5.out NOT streamed; view separately with tail -f
AUTO_STOP     = 1   driver stops gem5 automatically when phase1 completes
```

**Minimal run command (no redundant flags needed):**
```bash
cd /path/to/SimpleSSD_Gem5_simulation
bash scripts/driver_phase1.sh \
  --auto \
  --qd 16 --ios 4096 --repeats 1 --steady-time 2 \
  --tag smoke_test_v1
```

**What the tmux window shows while running:**
```
[14:03:21] gem5 started. Watching for completion.
  gem5 log : logs/gem5.out
  perf log : logs/driver_phase1_smoke_test_v1.log
  (Ctrl+B D to detach from tmux and leave running in background)
[14:04:21] still running | gem5.out tail: 6611650570000: HIL::NVMe: SQ 0 | ...
...
[14:47:05] Detected readfile script completion. Stopping gem5...
```

**On unexpected gem5 death** (panic, OOM, etc.): driver detects it within 5 seconds via
`kill -0 $GEM5_PID`, prints last 20 lines of `gem5.out` directly to the tmux window,
then exits cleanly. Does NOT hang.

### `scripts/boot_gem5.sh`

Manages the gem5 daemon lifecycle. Key invocation:
```bash
./scripts/boot_gem5.sh start    # called automatically by driver --auto
./scripts/boot_gem5.sh stop     # graceful stop by PID file
./scripts/boot_gem5.sh status   # check if running
```

Uses `setsid nohup nice -n 19 taskset ... & disown` for full detachment (see §4.3).

### `scripts/phase1_run.sh`

Runs inside the gem5 guest via readfile. Steps:
1. Mount 9p share → `/mnt/9p`
2. Run `spdk/scripts/setup.sh` (hugepages + NVMe unbind)
3. Run `spdk_nvme_perf` sweep with `--no-huge` fallback if hugepages unavailable
4. Write CSV → `/mnt/9p/results/phase1_runs/<tag>/`
5. Print `PHASE1_RUNSCRIPT_DONE`, call `m5 exit`

### `upload_large_files.sh`

Transfers large binaries (not in git) to the remote server via rsync with `--partial`.
**Safe to interrupt and re-run** — rsync resumes from where it left off using
block-level checksums, not byte offset.

---

## 9. Current Status (2026-03-19)

### ✅ Completed

| Item | Detail |
|---|---|
| gem5 binary built | 973 MB, 2026-03-19 10:31, all build fixes applied |
| nvme_interface fix | panic→warn confirmed in `gem5.out` |
| Simulation reaches NVMe I/O phase | `gem5.out` shows admin queues created and SQ0 doorbell |
| Process detachment (setsid) | gem5/diod survive VS Code crashes and SSH drops |
| Host protection (nice/taskset) | No more system freeze; safe for shared servers |
| Death detection in driver | Driver reports crash cause instead of hanging forever |
| All source fixes committed | origin/main is the authoritative source |
| Remote reproduction plan | `upload_large_files.sh` committed; upload in progress |

### ⏳ In Progress

| Item | Detail |
|---|---|

### ❌ Not Yet Done

| Item | Detail |
|---|---|
| Remote conda + gem5 build | After upload completes |
| First successful Phase 1 CSV output | No end-to-end run has completed yet |

---

## 11. Next Steps (in order)

1. **Run simulation in tmux** using the minimal command in §8.
2. **If it crashes:** read the tmux window output and/or `tail -50 logs/gem5.out` for
   the panic message, then apply a targeted fix.
3. **If it succeeds:** collect `results/phase1_runs/smoke_test_v1/*.csv`.

---

## 12. Remote Server Reproduction

### Server Details
- **Host:** `tzhang1.ecse.rpi.edu`
- **User:** `fangy6`
- **No root needed** — all simulation runs as normal user; diod is a system package

### Setup Commands (run after upload finishes)

```bash
ssh fangy6@tzhang1.ecse.rpi.edu

# Clone source (small — ~50 MB)
git clone https://github.com/fangyunh/Gem5-simpleSSD-SPDK-simulation.git ~/sim
cd ~/sim

# Conda env
conda create -n simplessd_env python=2.7 -y
conda run -n simplessd_env pip install scons==3.1.2 ply six

# Build gem5 (30-60 min)
cd SimpleSSD-FullSystem
conda run -n simplessd_env \
  env LD_LIBRARY_PATH="$(conda run -n simplessd_env python -c \
    'import sys,os; print(os.path.join(sys.prefix,"lib"))')" \
  scons -j$(nproc) build/X86/gem5.opt
cd ..

# Run in tmux (foreground — watch output live)
tmux new -s gem5sim
bash scripts/driver_phase1.sh \
  --auto \
  --qd 16 --ios 4096 --repeats 1 --steady-time 2 \
  --tag smoke_test_v1
# Ctrl+B D to detach; gem5 keeps running via setsid
# tmux attach -t gem5sim to reconnect
```

### Large Files Required (transferred by upload_large_files.sh)

| File | Size | Destination |
|---|---|---|
| `x86-ubuntu.img` | 16 GB | `~/sim/assets/` |
| `vmlinux-5.4.49` | 24 MB | `~/sim/assets/` |
| `guest_spdk_nvme_perf` | 6.9 MB | `~/sim/docker_artifacts/` |
| `guest_openssl11/` | ~4 MB | `~/sim/docker_artifacts/` |

`gem5.opt` (973 MB) is NOT transferred — recompile from source as shown above.

---

## 13. Datasets and How to Interpret Them

The simulation produces **two complementary datasets** per run. Both are written via the
9p shared filesystem and appear under `results/` on the host immediately.

### 13.1 Summary CSV — `phase1_results.csv`

**Location:** `results/phase1_runs/<tag>/<core>_<qp>/phase1_results.csv`
**Granularity:** One row per (QD, IO_Size, Run_ID) combination — aggregated summary.
**Source:** Parsed from `spdk_nvme_perf` stdout + `perf stat` output by `phase1_run.sh`.

#### Column Reference

| # | Column | Unit | Description | How to interpret |
|---|---|---|---|---|
| 1 | `QD` | count | Queue depth per queue pair | Higher QD → more parallelism at SSD |
| 2 | `Qpairs` | count | Number of NVMe I/O queue pairs used | 1 = single-core test |
| 3 | `IO_Size` | bytes | Size of each I/O request | 4096 or 16384 typically |
| 4 | `Run_ID` | index | Repeat number (1-based) | For statistical variance across runs |
| 5 | **`IOPS`** | IO/s | Throughput reported by SPDK | **Primary performance metric** |
| 6 | `Cycles` | count | Total CPU cycles during measurement (perf stat) | 0 if perf unavailable (gem5 has no PMU) |
| 7 | `Instructions` | count | Total CPU instructions (perf stat) | 0 if perf unavailable |
| 8 | `LLC_Misses` | count | Last-level cache misses (perf stat) | 0 if perf unavailable |
| 9 | `Dram_Read_Bytes` | bytes | Host DRAM reads (perf stat) | 0 if perf unavailable |
| 10 | `Dram_Write_Bytes` | bytes | Host DRAM writes (perf stat) | 0 if perf unavailable |
| 11 | `Energy_Joules` | J | CPU energy (perf stat) | 0 if perf unavailable |
| 12 | **`Cycles_Per_IO`** | cycles/IO | CPU cost per I/O = Cycles / Completions | **Key research metric.** 0 when perf unavailable |
| 13 | `Instr_Per_IO` | instr/IO | Instructions per I/O | 0 when perf unavailable |
| 14 | `LLC_Misses_Per_IO` | misses/IO | Cache misses per I/O | 0 when perf unavailable |
| 15-17 | `Dram_*_Per_IO`, `Energy_Per_IO` | various | Per-IO derived metrics | 0 when perf unavailable |
| 18 | **`p50_Latency`** | µs | Median I/O latency | From SPDK's built-in histogram |
| 19 | **`p99_Latency`** | µs | 99th percentile latency | Tail latency indicator |
| 20 | **`p99.9_Latency`** | µs | 99.9th percentile latency | Extreme tail |
| 21 | `Polls` | count | Total CQ poll calls during measurement | High polls with few completions → CPU spinning |
| 22 | `Completions` | count | Total I/Os completed | = IOPS × measurement_time |
| 23 | `Scans_Per_Completion` | ratio | Polls / Completions | How many polls per useful completion. High = idle spinning |
| 24 | `Completions_Per_Call` | ratio | Completions / Polls | Inverse of above. Low = mostly empty polls |
| 25 | `MMIO_Writes_Per_IO` | ratio | Doorbell MMIO writes per I/O | ~2.0 expected (1 SQ + 1 CQ doorbell) |
| 26 | `Completions_Per_Poll_Hist` | string | Histogram of completions per poll call | Format: `"0:N0, 1:N1, 2:N2, ..."`. Bucket 0 = empty polls |
| 27 | **`Submit_Logic_ns`** | ns | CPU time for full submit path (avg per IO) | From SPDK instrumentation: t_start → t_doorbell |
| 28 | **`Completion_Logic_ns`** | ns | CPU time for full completion path (avg per IO) | From SPDK instrumentation: t_completion → t_end |
| 29 | `Submit_Preamble_ns` | ns | Time before SQE construction begins | Function entry overhead |
| 30 | `Tracker_Alloc_ns` | ns | NVMe tracker (CID) allocation | Memory allocation for request tracking |
| 31 | `Addr_Xlate_ns` | ns | Virtual→physical address translation | PRP/SGL list construction |
| 32 | `Cmd_Construct_ns` | ns | NVMe SQE (submission queue entry) construction | Filling the 64-byte command structure |
| 33 | `Fence_ns` | ns | Memory fence before doorbell write | Ensures SQE is visible before doorbell |
| 34 | `Doorbell_ns` | ns | Doorbell MMIO write duration | The actual PCIe MMIO write to SQ tail doorbell |
| 35 | `CQE_Detect_ns` | ns | Time to detect CQE phase bit flip | Polling the completion queue |
| 36 | `Tracker_Lookup_ns` | ns | Look up tracker by CID from CQE | Matching completion to original request |
| 37 | `State_Dealloc_ns` | ns | Deallocate tracker + callback | Freeing CID and invoking completion callback |

#### Important Notes

- **Columns 6–17 are all zero** when running inside gem5 because gem5's simulated CPU
  has no hardware PMU. The `perf stat` wrapper gracefully falls back to reporting zeros.
  These columns become meaningful on real hardware or with gem5's optional PMU model.
- **p50 ≈ p99** is expected when NAND FillRatio was 0.0 (empty SSD) because every IO
  follows the same code path with deterministic timing. With FillRatio > 0, MSB vs LSB
  page reads introduce latency variance.
- **The gap between Submit_Logic_ns + Completion_Logic_ns and p50_Latency** is the
  **device processing time** (doorbell → completion interrupt). This is where NAND access,
  controller pipeline, and PCIe DMA happen — it's the SSD's contribution to latency.

### 13.2 Per-IO Cycle Breakdown CSV — `cycle_breakdown_s<size>_q<qd>_r<run>.csv`

**Location:** `results/phase1_runs/<tag>/<core>_<qp>/logs/cycle_breakdown_*.csv`
**Granularity:** One row per individual I/O operation — fine-grained per-request detail.
**Source:** SPDK instrumentation ring buffer (`spdk/lib/nvme/nvme_qpair.c`), dumped on
exit via `atexit(nvme_io_cycle_dump)`. Uses `rdtsc` timestamps converted to nanoseconds.

#### Column Reference

| # | Column | Unit | Description | How to interpret |
|---|---|---|---|---|
| 1 | `cid` | ID | NVMe command ID (CID) | Identifies the request in the NVMe queue |
| 2 | `qid` | ID | NVMe queue pair ID | 0 = admin queue, typically all on qid 0 for single-qpair tests |
| 3 | **`t_start`** | ticks | rdtsc timestamp at IO submit entry | Absolute tick count; use differences, not raw values |
| 4 | `t_sqe_copy` | ticks | After SQE copied to submission ring | |
| 5 | **`t_doorbell`** | ticks | After doorbell MMIO write | End of software submit path |
| 6 | **`t_completion`** | ticks | CQE detected (phase bit flipped) | End of device processing; start of software completion |
| 7 | **`t_end`** | ticks | After completion callback returns | End of full IO lifecycle |
| 8 | `t_poll_cycles` | ticks | Cumulative cycles spent polling for this IO | Between doorbell and completion detection |
| 9 | `submit_ns` | ns | **t_start → t_doorbell** | Total software submit overhead |
| 10 | `completion_ns` | ns | **t_completion → t_end** | Total software completion overhead |
| 11 | `submit_preamble_ns` | ns | Function entry overhead | |
| 12 | `tracker_alloc_ns` | ns | CID allocation | |
| 13 | `addr_xlate_ns` | ns | Address translation (PRP list) | |
| 14 | `cmd_construct_ns` | ns | SQE construction | |
| 15 | `fence_ns` | ns | Memory barrier | |
| 16 | `doorbell_ns` | ns | Doorbell MMIO write | |
| 17 | `cqe_detect_ns` | ns | CQE detection | |
| 18 | `tracker_lookup_ns` | ns | CID lookup from CQE | |
| 19 | `state_dealloc_ns` | ns | Tracker deallocation + callback | |

#### Derived Metrics (compute from raw columns)

| Metric | Formula | Meaning |
|---|---|---|
| **Device latency** | `(t_completion - t_doorbell) / ticks_per_ns` | Time the IO spent inside the SSD (NAND + controller + PCIe DMA). This is the **dominant** component (~99.5% of total). |
| **Total IO latency** | `(t_end - t_start) / ticks_per_ns` | End-to-end from submit call to completion callback |
| **Software overhead** | `submit_ns + completion_ns` | CPU time spent in driver code (typically <1 µs) |
| **ticks_per_ns** | Compute from `submit_ns` and tick deltas | For this sim: **2.0 ticks/ns** (gem5 2 GHz tick rate). Verify: `(t_doorbell - t_start) / submit_ns` |

#### Important Notes

- **Only the last N IOs are recorded** (ring buffer size = 100,000). For short runs, all
  IOs are captured. For longer runs, only the tail end is kept.
- **First 1–2 rows are cold-start outliers** with inflated `completion_ns` (cache warming,
  first TLB miss, etc.). Skip them for steady-state analysis.
- **The `state_dealloc_ns` column** in the first IO is often very large (~23 µs) because
  it includes the initial cache-cold penalty. Steady-state values are ~74 ns.

### 13.3 gem5 Stats — `SimpleSSD-FullSystem/m5out/stats.txt`

**Generated by:** gem5 at simulation end (or `m5 exit`).
**Key SimpleSSD counters to verify:**

| Stat | Meaning | What to check |
|---|---|---|
| `system.pc.nvme.command_count` | Total NVMe commands processed | Should ≈ Completions from CSV |
| `system.pc.nvme.bytes` | Total data transferred | Should = Completions × IO_Size |
| `system.pc.nvme.busy` | Total device busy time (ps) | Divide by command_count for per-IO device time |
| `system.pc.nvme.pal.read.count` | NAND read operations | **Must be > 0 if FillRatio > 0**. If 0, reads are hitting cache or unmapped LBAs |
| `system.pc.nvme.pal.read.time.total` | Average NAND read time | Should match LSBRead/MSBRead + DMA timing |
| `system.pc.nvme.icl.generic_cache.read.from_cache` | Cache hits | High value = reads served from DRAM cache, not NAND |
| `system.pc.nvme.icl.generic_cache.read.request_count` | Total read requests to ICL | Should ≈ command_count |
| `system.pc.nvme.dram.write.request_count` | DRAM cache fills | Each cache miss triggers a DRAM write |
| `system.pc.nvme.ftl.page_mapping.gc.count` | Garbage collection events | Should be 0 for read-only workloads |

---

## 14. Debugging Reference

### gem5.out — milestones to look for (in order)

```
warn: nvme_interface: Ignoring PCI config write ...   → EXPECTED, fix working
HIL::NVMe: BAR0 | WRITE | Controller Configuration   → SPDK enabling NVMe
HIL::NVMe: SQ 0 | CREATE                              → Admin queue created
HIL::NVMe: SQ 0 | Submission Queue Tail Doorbell      → First I/O submitted ← REACHED
PHASE1_RUNSCRIPT_DONE                                  → Guest script done (success)
diod: caught SIGTERM                                   → gem5 was killed externally (BUG — should not happen after setsid fix)
panic:                                                 → gem5 fatal error
```

### Common Failure Modes

| Symptom | Likely cause | Fix |
|---|---|---|
| `diod: caught SIGTERM` | Terminal PTY killed the process group | Fixed by `setsid` in boot_gem5.sh — rebuild if using old binary |
| Driver prints `gem5 died unexpectedly` | gem5 panic or OOM | Read last 20 lines printed to tmux, or `tail -50 logs/gem5.out` |
| No CSV in results/ | Guest script never ran | Check `logs/driver_phase1_<tag>.log` for `PHASE1_RUNSCRIPT_LOG_BEGIN` |
| `DPDK init failed` in guest | Hugepages not configured | `phase1_run.sh` runs `setup.sh` and has `--no-huge` fallback automatically |
| `panic: nvme_interface: PCI config write` | Old binary without nvme fix | Rebuild from current source (§6.1 fix is in place) |
| Driver hangs indefinitely | Should not happen anymore | Death detection loop (`kill -0` check) catches this within 5 seconds |

### Key Commands for Monitoring a Running Simulation

```bash
tail -f logs/gem5.out                          # live gem5 output
tail -f logs/driver_phase1_<tag>.log           # combined driver + guest log
./scripts/boot_gem5.sh status                  # check if gem5 is alive
cat results/phase1_runs/<tag>/*.csv            # results after completion
```
