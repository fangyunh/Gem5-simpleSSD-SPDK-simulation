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

The primary experiment ("Phase 1") is a random-read IOPS sweep over queue depths
`[16, 32, 64, 128]` and I/O sizes `[4096, 16384]` bytes. Results are written as CSV files
on the host and plotted automatically.

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
Host Linux (28-core, 62 GB RAM)
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

The SSD is a ~512 GB NVMe drive modeled with:

```
Channel = 8,  Package = 4         → 32 packages total
Die = 2,  Plane = 2,  Block = 512,  Page = 512,  PageSize = 16384 B
Total capacity = 8×4×2×2×512×512×16384 ≈ 512 GB
EnableMultiPlaneOperation = 1
```

SimpleSSD runs 3 internal virtual CPUs (HIL, ICL, FTL) at 400 MHz each.
These contribute significantly to simulation time.

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

## 9. Resource Usage and Server Safety

gem5 is a **normal unprivileged user process**. A crash cannot affect the host OS, kernel,
or other users' work in any way.

| Resource | gem5 usage | Notes |
|---|---|---|
| RAM | ~7 GB | 4 GB guest DRAM + ~1 GB binary + ~1 GB SimpleSSD state. Well within 50 GB. |
| CPU priority | nice -n 19 | Absolute lowest. Only runs when nothing else wants CPU. |
| CPU cores | 0 to (nproc-9) | Reserves ≥8 cores for OS + other users on a shared server. |
| Disk I/O | Minimal after boot | All NVMe storage I/O is simulated in-memory. |

---

## 10. Current Status (2026-03-19)

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
| `x86-ubuntu.img` upload | rsync running to tzhang1.ecse.rpi.edu, ~24% complete, resumable |

### ❌ Not Yet Done

| Item | Detail |
|---|---|
| Remote conda + gem5 build | After upload completes |
| First successful Phase 1 CSV output | No end-to-end run has completed yet |

---

## 11. Next Steps (in order)

1. **Wait for `upload_large_files.sh` to finish** — all 4 files must arrive on remote.
2. **On remote server:** create conda env, rebuild gem5 from source (§5.1).
3. **Run simulation in tmux** using the minimal command in §8.
4. **If it crashes:** read the tmux window output and/or `tail -50 logs/gem5.out` for
   the panic message, then apply a targeted fix.
5. **If it succeeds:** collect `results/phase1_runs/smoke_test_v1/*.csv`.

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

## 13. Phase 1 Results CSV Format

Written to `results/phase1_runs/<tag>/phase1_results.csv`. Key columns:

| Column | Description |
|---|---|
| QD | Queue depth per queue pair |
| Qpairs | Number of NVMe queue pairs |
| IO_Size | I/O size in bytes |
| Run_ID | Repeat index |
| IOPS | Total IOPS from `spdk_nvme_perf` Total line |
| p50/p99/p99.9_Latency | Latency percentiles in µs |
| Cycles_Per_IO | Host CPU cycles per I/O (perf stat) |
| Submit_Logic_ns / Completion_Logic_ns / ... | SimpleSSD internal timing breakdowns |

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
