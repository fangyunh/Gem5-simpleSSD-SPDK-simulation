# NVMeVirt + Real-CPU Simulation Plan

**Status:** Draft — awaiting decisions before any code is written.
**Author:** Claude (with Fangyun).
**Date drafted:** 2026-05-17.

---

## 0. Why we are doing this

Our gem5 + SimpleSSD multi-core measurements plateau at ~1 M aggregate IOPS regardless of core count or cache configuration (4c/8c/etc.). The bottleneck is a **simulation artifact** (slow simulated CPU + single-arbiter `CoherentXBar` membus serializing all CPU memory accesses), not a real-hardware behavior. On real CPUs `bdev_null` scales to **14 M IOPS / core** (linear to 113 M aggregate at 8c). So we cannot study real multi-core scaling under our gem5 setup.

NVMeVirt is a kernel module that emulates a complete NVMe PCIe device backed by reserved host RAM. SPDK attaches to it via `vfio-pci` exactly like a physical NVMe device, but the "device" is software we can extend. Running SPDK on real host CPUs against NVMeVirt lets us measure realistic multi-core scaling with a programmable SSD model. SimpleSSD's per-stage timing remains the source of truth for accuracy; we port its NAND/FTL/HIL constants into NVMeVirt's latency hooks.

This document specifies what we will build, what one-time root operations are required, and the design decisions Fangyun must answer before any code is written.

---

## 1. Goals (alignment with the gem5 measurement we already have)

| Capability | Gem5 today | NVMeVirt target | Notes |
|---|---|---|---|
| Per-IO host cycle breakdown (Submit_Preamble, Tracker_Alloc, Doorbell, CQE_Detect, …) | SPDK instrumentation under simulated CPU | **Same SPDK instrumentation** — runs unchanged on real CPU | Already implemented in our SPDK fork. No new code needed. |
| Per-stage device cycles (HIL → ICL → FTL → NAND) | SimpleSSD inside gem5 | NVMeVirt kernel-side instrumentation + new per-stage counters | ~200 LOC of new code in the kernel module. |
| Multi-core scaling (1c / 4c / 8c) | Broken in timing mode, capped at 1 M in atomic | **Native** — real CPU cores via SPDK `-m` mask | This is the main motivation. |
| Uncore mechanisms (Mode 0/1/2, Mech #1/#2/#4) | `controller.cc` in SimpleSSD | Port to NVMeVirt module | ~500-1500 LOC of C kernel code. |
| Enable/disable each mechanism at runtime | `UncoreMode` cfg + per-mech flags | `/sys/module/nvmevirt/parameters/` runtime knobs | One-shot chmod via udev rules (no sudo per run). |
| BigANN trace replay | `spdk_nvme_perf --trace-file` | Same — SPDK is identical | No change to host workload. |
| Timing model | SimpleSSD HIL/ICL/FTL + NAND (cycle-level) | Port SimpleSSD's latency equations into NVMeVirt's hooks | Most fidelity-preserving choice. |

---

## 2. Root operations (ONE TIME, batched)

Give all of these in **one root session**, then no further root is needed for the lifetime of the work. If any of these are unacceptable to the admin, the plan is dead and we should give up the NVMeVirt path.

```bash
# ── Build / install dependencies ─────────────────────────────────────────
sudo apt install -y linux-headers-$(uname -r) libelf-dev clang build-essential dwarves

# Check IOMMU + VT-d in BIOS (likely already enabled if server hosts VMs)
sudo dmesg | grep -E "IOMMU|VT-d"      # verify, no install needed

# ── Reserve memory for NVMeVirt's SSD backing (32 GB carved from total) ─
# Append to GRUB_CMDLINE_LINUX in /etc/default/grub:
#   "memmap=32G!64G intel_iommu=on iommu=pt vfio.enable_unsafe_noiommu_mode=1"
sudo update-grub
sudo reboot                              # ← single reboot, then no more

# ── Persistent hugepages for SPDK (8 GB) ────────────────────────────────
echo "vm.nr_hugepages=4096" | sudo tee /etc/sysctl.d/99-hugepages.conf
sudo sysctl --system

# ── Build and install NVMeVirt as a system module ───────────────────────
cd /opt && sudo git clone https://github.com/snu-csl/nvmevirt
cd /opt/nvmevirt
# IMPORTANT: configure to use the reserved 32G region (offset 64G, size 32G)
#   Edit Makefile/config: MEMMAP_START=0x1000000000  MEMMAP_SIZE=0x800000000
sudo make CONFIG_NVMEVIRT_NVM=y -j$(nproc)
sudo make install                        # installs to /lib/modules
sudo depmod -a
sudo modprobe nvmevirt                   # load it (appears as /dev/nvme*)

# ── Allow non-root vfio-pci access via udev ─────────────────────────────
sudo tee /etc/udev/rules.d/99-nvme-spdk.rules <<'EOF'
SUBSYSTEM=="vfio", GROUP="psx_user", MODE="0660"
SUBSYSTEM=="misc", KERNEL=="vfio", GROUP="psx_user", MODE="0660"
KERNEL=="hugepages", GROUP="psx_user", MODE="0775"
EOF
sudo udevadm control --reload-rules
sudo udevadm trigger

# ── Persist module load on boot ─────────────────────────────────────────
echo "nvmevirt" | sudo tee /etc/modules-load.d/nvmevirt.conf

# ── Module parameters (post-load) — accessible without root via sysfs ───
sudo chmod g+w /sys/module/nvmevirt/parameters/*    # one-time
```

**After this, NO root is needed per run.** SPDK + NVMeVirt + bdevperf all run as `fangy6`.

### Server context (verified 2026-05-17)

- Total RAM: **376 GB** (Intel Xeon Gold 6134 @ 3.2 GHz, 32 cores)
- Reservation of 32 GB = 8.5 % of total RAM — non-disruptive on this machine.
- Currently only ~5.8 GB in use, ~350 GB free at quiescent state.

### Absolute minimum (if the admin balks)

If the full list above is too much: the irreducible set is **(a) kernel headers, (b) GRUB cmdline change + reboot, (c) hugepages, (d) NVMeVirt install + modprobe, (e) udev rules**. Without (e) we'd need `sudo` for `setup.sh` each run, which Fangyun has stated is unacceptable → the plan dies.

### Uninstall procedure (hand to admin when experiments are done)

Only reverts the **disruptive** server-state changes (reserved RAM, pinned hugepages, auto-load module). Installed packages, the built `.ko` file, the source tree, and the udev rules are left in place — they consume only disk space, not RAM or CPU, and can be useful if we ever resume the experiments.

```bash
# ── 1. Remove the GRUB cmdline reservation (releases the 32 GB) ─────────
# Edit /etc/default/grub, locate GRUB_CMDLINE_LINUX, and remove the items we
# added during install:
#   "memmap=32G!64G intel_iommu=on iommu=pt vfio.enable_unsafe_noiommu_mode=1"
# Keep the rest of the line intact.
sudo nano /etc/default/grub
sudo update-grub

# ── 2. Stop the module from loading on next boot ────────────────────────
# (Without this, modprobe would still fire on boot and fail noisily once
#  the memmap reservation is gone.)
sudo rm /etc/modules-load.d/nvmevirt.conf

# ── 3. Release the persistent hugepages (returns 8 GB to general pool) ──
sudo rm /etc/sysctl.d/99-hugepages.conf

# ── 4. Unload the currently running module (optional; reboot also does it)
sudo rmmod nvmevirt 2>/dev/null || true

# ── 5. Reboot to release the 32 GB RAM and apply GRUB changes ───────────
sudo reboot

# After reboot, verify with: free -h
# Expected: 376 GB total RAM available (no reservation hole).
```

**Items intentionally left in place (no disruption):**
- Installed apt packages (`linux-headers`, `libelf-dev`, `clang`, etc.) — disk only
- The compiled `.ko` at `/lib/modules/$(uname -r)/extra/nvmevirt.ko` — never loaded again unless someone `modprobe`s it manually
- The source tree at `/opt/nvmevirt` — disk only
- udev rules at `/etc/udev/rules.d/99-nvme-spdk.rules` — affect device-node permissions only; no `/dev/vfio/*` exists once the module is unloaded, so the rules have no effect

Net duration: ~5 minutes hands-on + one reboot.

---

## 3. Code plan (no root once installed)

### 3.1 Source-of-truth comparison & timing model porting

We use **SimpleSSD's timing equations** because they are more detailed and we have already calibrated them in `fast_ssd_highiops.cfg`. NVMeVirt's default model is simpler.

Map from SimpleSSD → NVMeVirt:

| SimpleSSD layer | What it models | NVMeVirt location |
|---|---|---|
| HIL/NVMe | NVMe protocol cycles (cmd parse, SQE fetch, PRP walk, CQE post) | `nvme.c` — instrument in `nvmev_proc_io_cmd` |
| ICL (cache) | DRAM cache LRU + write buffer | `ssd_config.c` — add cache model, write-back logic |
| FTL | Page mapping table lookup, GC | `ftl.c` — replace simpler FTL with SimpleSSD-derived FTL |
| NAND timing | Page read/write/erase, plane-level parallelism | `nand.c` — port `fast_ssd_highiops.cfg` (`tR`, `tProg`, `tBERS`, `tCS`) |
| FastPath (Path-E) | Direct submission | New file `iouncore.c` — handles mailbox/freeCID/qdepth/hint |

Port plan (new code, ~1500-2000 LOC total):

```
nvmevirt/
├── nand.c           (modify) — replace timing table with SimpleSSD-derived
│                              constants: tR=40us, tProg=200us, tBERS=2ms,
│                              tCS=5ns; 32 channels × 4 lanes × 4 planes
├── ftl.c            (modify) — page-mapping FTL, GC threshold from cfg
├── iouncore.c       (NEW)    — BAR0 region dispatcher:
│                              0x1000-0x1FFF: standard NVMe doorbells (Mode 0)
│                              0x2000:        hint register (Mode 1, Mech #4)
│                              0x3000-0x3FFF: mailbox SQ engine (Mode 2)
│                              0x4000-0x43FF: free-CID ring (Mech #1)
│                              0x4400-0x47FF: qdepth counter (Mech #2)
├── iouncore.h       (NEW)    — uncore data structures, params
├── perf_counters.c  (NEW)    — per-stage cycle counters (rdtsc-based,
│                              one ring buffer per CPU; dumped via debugfs)
└── nvmev_main.c     (modify) — registration, parameter exposure via sysfs
```

### 3.2 Per-stage device-side cycle accounting

We add a tracepoint structure (similar to our SPDK `SPDK_IO_CYCLE`):

```c
// In nvmev/perf_counters.c
struct nvmev_io_cycle_record {
    u64 cmd_id;
    u64 ts_doorbell_seen;
    u64 ts_sqe_fetched;
    u64 ts_cmd_decoded;
    u64 ts_ftl_translated;
    u64 ts_nand_modeled;
    u64 ts_cqe_posted;
    u64 ts_msix_delivered;
    u8  mode;       // 0/1/2
    u8  mech_mask;  // bit0=Mech1, bit1=Mech2, bit2=Mech4
};
// Ring buffer per CPU, dumped via /sys/kernel/debug/nvmevirt/cycles
```

This gives us EXACTLY the per-stage data our gem5 SimpleSSD `cycle_breakdown.csv` produces today. Host-side SPDK cycle counters already exist; we just merge the two CSVs.

### 3.3 Mechanism enable/disable

Each mechanism becomes a sysfs knob (no root once `chmod g+w` is set by udev):

```bash
echo 0 > /sys/module/nvmevirt/parameters/uncore_mode       # Mode 0 (baseline)
echo 1 > /sys/module/nvmevirt/parameters/uncore_mode       # Mode 1 (Mode A)
echo 2 > /sys/module/nvmevirt/parameters/uncore_mode       # Mode 2 (Mode B)
echo 1 > /sys/module/nvmevirt/parameters/enable_mech1      # free-CID ring
echo 1 > /sys/module/nvmevirt/parameters/enable_mech2      # qdepth counter
echo 1 > /sys/module/nvmevirt/parameters/enable_mech4      # typed hint
```

SPDK side is unchanged (still uses `SPDK_UNCORE_MODE_B` env + BAR offset macros we already added).

### 3.4 Driver / sweep scripts

Reuse our existing `scripts/bigann/driver_phase1_trace.sh` with light modifications:

```
scripts/bigann/
├── driver_nvmevirt_trace.sh   (NEW, ~300 LOC) — sweeps cores × QD × mech combos
└── nvmevirt_setup.sh          (NEW, ~100 LOC) — load module with params, run SPDK setup.sh
                                                  (no sudo: relies on udev rules from §2)
```

Per-run sequence:
1. Record current config: `cat /sys/.../uncore_mode > $RESULTDIR/mode.txt`
2. `spdk_nvme_perf -c $MASK -P 1 -q 128 -t 30 --trace-file bigann.bin -o 4096 -w randread`
3. Post-process: merge SPDK cycle CSV with NVMeVirt `/sys/kernel/debug/nvmevirt/cycles`

### 3.5 Validation matrix

| Phase | Test | Pass criterion |
|---|---|---|
| **P1: NVMeVirt sanity** | Stock NVMeVirt + `spdk_nvme_identify` | Returns model `NVMeVirt` |
| **P2: Stock perf** | `spdk_nvme_perf` baseline (Mode 0, default NVMeVirt timing) | ~1-5 M IOPS per core (matches NVMeVirt paper) |
| **P3: Port SimpleSSD timing** | Run with `fast_ssd_highiops.cfg` constants | Per-IO latency within 10 % of gem5 Mode 0 at same QD |
| **P4: IO-Uncore mechanisms** | Mode 2 + all mechs | Doorbell-bypass mailbox works; free-CID ring drains; qdepth reads correct |
| **P5: Multi-core scaling** | 1c/4c/8c × QD=128 × Mode 2 BigANN | Aggregate IOPS scales near-linearly until SSD-side ceiling hits |
| **P6: Cycle breakdown** | Dump merged SPDK+NVMeVirt cycle CSV | Per-stage cycles add up to total IO latency within 5 % |

---

## 4. Critical risks & mitigations

| Risk | Severity | Mitigation |
|---|---|---|
| Kernel module crashes server when active | High | Test on a non-shared node first; use `panic_on_oops=0` |
| `memmap` reservation conflicts with existing memory layout | Med | Pick region above existing kernel/user allocations (e.g. start at 64 GB if server has ≥ 96 GB) — adjust by checking `/proc/iomem` |
| NVMeVirt + our gem5 fork BAR0 layout mismatch | Med | Standardize: SPDK macros (`nvme_pcie_internal.h`) are the SOURCE OF TRUTH; both gem5 SimpleSSD and NVMeVirt match |
| Per-stage cycle counters interfere with hot path | Low | Per-CPU lockless ring buffer; `rdtsc` is ~10 ns |
| BigANN trace file (19 MB) needs to be accessible to SPDK | None | Already works — local filesystem |
| Difference vs gem5 — how to compare? | Med-High | Run BOTH side-by-side at 1c, document per-stage offset; cite gem5 for cycle accuracy, NVMeVirt for scaling |

---

## 5. Effort estimate

| Task | Days |
|---|---|
| One-time root setup (after admin time is granted) | 0.5 |
| NVMeVirt build + sanity (stock) | 0.5 |
| Port SimpleSSD NAND/FTL constants | 1 |
| Add IO-Uncore mechanisms (mailbox, free-CID, qdepth, hint) | 4-6 |
| Per-stage device cycle counters + debugfs export | 2 |
| Driver scripts + post-processing | 1 |
| Validation (P1-P6) + tuning | 3-5 |
| Sweep runs (1c/4c/8c × Mode 0/1/2 × Mech combos) | 0.5 (each run is seconds-to-minutes) |
| **Total** | **~12-16 days** |

vs. gem5 status quo: each timing-mode 4c/8c run was 12-20h+ wall and most failed.

---

## 6. Final paper story (with both sources)

- **Single-core cycle attribution**: gem5 1c TimingSimpleCPU + caches (we already have this data: 430 K IOPS, per-stage CSV). Reviewers like cycle-accurate sim for microarchitecture analysis.
- **Multi-core scaling + uncore lift**: NVMeVirt on real CPUs (this plan). Reviewers like real-CPU data for systems-level claims.
- **Honest framing**: "We use gem5 for cycle-level single-core analysis where simulator fidelity is paramount, and NVMeVirt + real CPUs for multi-core scaling experiments where the simulator's multi-CPU artifacts would obscure the actual host-stack behavior."

---

## 7. Design decisions Fangyun must answer before any code is written

Please reply inline under each `Answer:` block below.

### 7.1 Admin / root list

Will the admin grant the root list in §2 (specifically the GRUB cmdline + reboot)? This is the biggest gate. If no, this plan dies.

> **My concern**: The reboot is the hardest part on a shared server. If the admin will only grant non-disruptive operations (module install, hugepages, udev), we lose the `memmap=` reserved RAM and have to fall back to a smaller, dynamic-allocation NVMeVirt config (~4 GB instead of 32 GB), which limits how much trace data can be replayed in steady state. Smaller backing also means more wrap-around on randread (writes/reads hit the same physical pages repeatedly), which changes cache locality results.

Answer:

```
(your reply here)
```

### 7.2 Reserved memory region

Where can the 32 GB memory reservation live? Need to know server total RAM and whether `64 G+32 G` is safe.

> **My concern**: We need a region that does not overlap with kernel/initrd/firmware reserved zones. Standard practice is to leave the bottom 4 GB alone, reserve in the high-physical-address area. Server has X GB of RAM — if X < 96, we cannot reserve 32 GB at offset 64 GB and need a smaller window. Also need to check `/proc/iomem` for any pre-existing reservations.

> **Required from server**: total RAM, output of `cat /proc/iomem | head -50`, and confirmation no other user is reserving high memory.

Answer:

```
(your reply here)
```

### 7.3 FTL fidelity level

Port the full SimpleSSD FTL or just the NAND timing constants?

- **Full FTL port** (page-mapping table + GC + wear leveling): ~1 week more work. Lets us see GC-induced latency tail.
- **Constants only** (NAND tR/tProg/tBERS, channel/lane/plane counts): ~1 day. Loses GC effects but our BigANN trace is read-mostly, so this is acceptable for the first cut.

> **My concern**: Our BigANN trace is `randread` — no writes, no GC. So full FTL adds ~zero fidelity for this trace. If we plan to do mixed read/write or randwrite traces in a follow-up, full FTL becomes valuable.

> **My recommendation**: **Constants-only first**, then revisit if we add write workloads. This shaves a week of port time and we can always extend later.

Answer:

```
(your reply here)
```

### 7.4 Per-stage device cycles: tracepoint vs always-on rings

How to capture device-side per-stage cycles?

- **Linux tracepoints** (ftrace-friendly, zero overhead when off): standard kernel mechanism; users enable via `echo 1 > /sys/kernel/tracing/events/nvmevirt/enable`.
- **Always-on rdtsc rings**: per-CPU lockless ring buffer; ~1 % overhead but always available; dumped via debugfs.

> **My concern**: Tracepoints are cleaner and lower-overhead, but require building NVMeVirt against `CONFIG_TRACEPOINTS=y` in the running kernel (almost always true on stock Linux). Always-on rings are simpler to implement (~100 LOC) and let us correlate per-IO across all our runs without remembering to enable tracing.

> **My recommendation**: **Always-on rdtsc rings** — matches what our SPDK side already does (every IO is timestamped). Same paradigm, easier to merge data.

Answer:

```
(your reply here)
```

### 7.5 Workload coverage

Which sweep matrix should the validation runs cover?

- Minimal: 1c/4c/8c × QD=128 × Mode 0/1/2 × Mech-all (= 9 runs, ~30 min total wall)
- Extended: 1c/2c/4c/6c/8c × QD={16,32,64,128} × Mode 0/1/2 × every Mech combination (= ~720 runs, ~5 h wall)

> **My concern**: Wall time isn't the issue (each run is seconds with real CPU). Statistical noise is — with NVMeVirt we'll see real-hardware jitter. 3 repeats per point is probably right. Extended matrix gives us paper-quality curves; minimal is good for sanity check.

> **My recommendation**: Extended matrix with **3 repeats**, run overnight. Still fits in <10 h.

Answer:

```
(your reply here)
```

### 7.6 BAR0 layout: keep SimpleSSD's, or follow NVMeVirt convention?

Our gem5 SimpleSSD uses:
- 0x1000-0x1FFF: doorbells
- 0x2000: hint register
- 0x3000-0x3FFF: mailbox SQ engine
- 0x4000-0x43FF: free-CID ring
- 0x4400-0x47FF: qdepth counter

These match our SPDK macros in `nvme_pcie_internal.h`. NVMeVirt is BAR0 layout-flexible — we can keep ours.

> **My concern**: None — we already standardized on this. NVMeVirt is the new node, it adapts.

> **My recommendation**: **Keep our existing layout.** SPDK macros are the source of truth.

Answer:

```
(confirm or adjust)
```

### 7.7 Reproducibility / Docker

Should we package the NVMeVirt build + SimpleSSD constants in a Dockerfile for future reproducibility?

> **My concern**: NVMeVirt is a kernel module — can't be Dockerized for runtime. But the BUILD environment (kernel headers, compiler, our patches) can be a Dockerfile so future researchers can rebuild on their kernel. Also good for paper artifact submission.

> **My recommendation**: **Yes, Dockerfile for the build environment only.** Build inside Docker → produces `.ko` file → admin installs it. Same as how we did `guest_spdk_nvme_perf`.

Answer:

```
(your reply here)
```

### 7.8 Comparison run with gem5

After NVMeVirt works at 1c, do we want to run a comparison sweep on gem5 1c with identical parameters to verify the NVMeVirt model matches?

> **My concern**: Yes — we need this for the paper's methodology section ("we validate NVMeVirt against gem5 at 1c, within 10 % per-stage; multi-core results then come from NVMeVirt"). Costs ~1 day of gem5 1c sweeps (which we have working). Without this, reviewers will ask "is NVMeVirt's latency model right?".

> **My recommendation**: **Yes**, plan for this validation sweep before claiming results.

Answer:

```
(your reply here)
```

---

## 8. Open questions I do not yet have an answer to

1. **Can NVMeVirt expose multiple namespaces simultaneously?** — If yes, we could test per-namespace queue isolation. If no, we run multiple NVMeVirt instances (probably not supported by the module).
2. **Does NVMeVirt support MSI-X multi-vector for >1 queue?** — Required for multi-core SPDK runs where each core has its own qpair.
3. **What CPU model is the server?** — Affects per-core upper bound and per-IO cycle baselines. AMD vs Intel matters for L3 sharing.
4. **Is there any chance the server is hosting other users' production workloads?** — A kernel module crash here is catastrophic for them. We need to know the blast radius.

These are reconnaissance items. Some you can answer; others I can probe non-destructively before the root list is granted (e.g., `lscpu`, `free -h`, `cat /proc/iomem`).

---

## 9. Go/no-go gate

If §7.1 (root list approval) is **NO**, we stop here and finalize the paper with the data we have (gem5 atomic+caches + bdev_null upper bound). If §7.1 is **YES**, I begin with §3.1 the same day.
