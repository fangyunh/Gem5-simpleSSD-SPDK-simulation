# Multi-Host-Core Preparation Plan

**Date:** 2026-05-15
**Goal:** Run BigANN trace replay with `N ∈ {6, 8}` host CPUs, each owning 1 qpair, at QD=128 under Mode 2 + Mech #1/#2/#4. SSD ceiling lowered to 8 MIOPS so the device becomes the bottleneck near 6–8 cores.

---

## 1. Why this is the next experiment

The qp=1 QD=128 single-core run hits **1.1 M IOPS** in Mode 2 — the host CPU is the bottleneck (~900 ns per IO of SW stack). The earlier qpairs-with-1-core sweep showed **adding qpairs to a single core reduces throughput** because polling fanout grows O(qpairs). The way out is **scale cores instead**: each core polls only its own qpair, so per-core fanout stays O(1), and aggregate throughput should scale near-linearly until something else binds.

Likely binding ceilings:
- **8 MIOPS SSD** (32 ch × 250K each, set this session). At 1.1 M per core, **~7 cores saturate**.
- **PCIe Gen5×16** ≈ 13 MIOPS at 4 KB — well above 8 MIOPS, not binding.
- **SimpleSSD HIL bookkeeping** is bypassed by Path-E; CoreCount=1 still hard-limit per `project_simulator_iops_ceiling.md`.

---

## 2. What changed today

### 2.1 cfg: lower SSD ceiling 32 → 8 MIOPS

`fast_ssd_highiops.cfg:204`:
```
FastPathTmaxPerChannel = 250000   (was 1000000)
```
`FastPathLmin = 1 µs` and `pal.Channel = 32` unchanged → per-IO pipeline latency the same, only per-channel rate cap reduced. Aggregate ceiling = 32 × 250K = 8 MIOPS.

### 2.2 boot script: thread `NUM_CPUS` to gem5

`scripts/boot_gem5.sh`:
- New env var `NUM_CPUS=${NUM_CPUS:-1}` at the top (default 1, backward compatible).
- New GEM5_ARGS line `--num-cpus="$NUM_CPUS"`.

gem5's `fs.py` and `configs/common/Options.py` already implement `--num-cpus N` (instantiates N O3CPU objects, scales LAPIC/IO-APIC, MSI-X), so no gem5-source change is needed.

### 2.3 bigann driver: accept `--core-counts`

`scripts/bigann/driver_phase1_trace.sh`:
- New CLI flag `--core-counts "list"` with default `"1"`.
- `patch_ssd_config()` now validates `max_core × max_qpairs_per_core ≤ MaxIOCQueue`.
- Passes the max value of `CORE_COUNTS_LIST` as `NUM_CPUS` to `boot_gem5.sh`.
- Exports `CORE_COUNTS_LIST` into the readfile so the guest sees the same list.
- Metadata.json now records `core_counts`.

### 2.4 bigann replay: loop over core counts, build mask, name dirs

`scripts/bigann/phase1_trace_replay.sh`:
- New outer loop `for CORE_COUNT in "${CORE_COUNTS[@]}"`.
- Per-iteration `CORE_MASK = (1 << CORE_COUNT) - 1` → `0x1, 0x3f, 0xff, …`.
- Result directory naming:
  - `core0_qp${QPAIRS}` when CORE_COUNT == 1 (legacy compat with single-core plotters).
  - `core_count${CORE_COUNT}_qp${QPAIRS}` when CORE_COUNT > 1.
- `spdk_nvme_perf` invocation now uses `-c "$CORE_MASK"` (was hard-coded `-c 0x1`).
- Two new columns added to the CSV schema: `Core_Count`, `Core_Mask`.

### 2.5 No new debug logs

Existing instrumentation already covers per-qid visibility for smoke verification:
- `[DBG_SQ_CREATE] sqid=N` — every SQ creation
- `[DBG_MBX_INJ] qid=N cid=K` — every mailbox write per qpair
- `[DBG_FCR_POP/REC] qid=N` — Mech #1 free-CID activity per qpair
- `[DBG_FP_ENQ] cqID=N sqID=N` — Path-E fast-path enqueues per qpair
- SPDK-side `UNCORE-Q | qid=N sq_tdbl=… mailbox_slot=…` on qpair construct

With `-P 1` per `-c <mask of N cores>`, SPDK's `nvme_pcie_perf` assigns one qpair per worker thread (one per core in the mask), so qid 1..N maps 1:1 to host cores. The above logs are sufficient to verify multi-host-CPU correctness.

### 2.6 What is NOT changed

- Source code under `SimpleSSD-FullSystem/src/dev/storage/` — no edits. The host-multi-CPU audit (see this session's chat) found gem5's global event queue serializes all device-side state mutations, so all 5 historic `HILCoreCount > 1` hazards (`uncoreFlushScheduled`, `uncorePendingCQE`, `aggregationMap`, `shutdownReserved`, `lSQFIFO`) are non-issues under `HILCoreCount = 1` + N host CPUs.
- gem5.opt binary — no rebuild needed.
- SPDK guest binary — no rebuild needed; `-c <mask>` is a runtime flag.
- CQ batching (`CQBatchN=8`, `CQBatchT=4µs`) — left at defaults. With 1 qpair per core, polling fanout is O(1) per core, so the batching tradeoff doesn't matter the same way it did in single-core multi-qpair runs.

---

## 3. Verification gates (smoke first)

### 3.1 Smoke command (2 cores, short)

```bash
SSD_CFG=fast_ssd_highiops.cfg ./scripts/bigann/driver_phase1_trace.sh --auto \
  --core-counts "2" --qpairs "1" --qd "32" --ios "4096" \
  --steady-time 1 --repeats 1 --uncore-mode 2 \
  --tag mc_trace_smoke_c2_qd32
```

Pass criteria after `PHASE1_RUNSCRIPT_DONE`:

1. **Banner present**: `[CORES] running core_count=2 mask=0x3` in driver log.
2. **gem5 booted with 2 CPUs**: `grep "Allowing 2 CPUs" logs/driver_phase1_trace_*.log` (kernel boot message).
3. **All qids exercised**: `grep -oE "DBG_MBX_INJ\] qid=[0-9]+" logs/gem5.out | sort -u | head` shows `qid=1, qid=2`.
4. **CSV row written**: `results/phase1_runs/mc_trace_smoke_c2_qd32/core_count2_qp1/phase1_results.csv` has 2 lines (header + 1 data row).
5. **Per-stage timings reasonable**: `Addr_Xlate_ns ≈ 70`, `Tracker_Alloc_ns < 100` (mailbox + Mech #1 active).
6. **Throughput sanity**: ~2 M IOPS expected (2× qp=1 baseline at modest QD).

### 3.2 Failure modes

| Symptom | Likely cause |
|---|---|
| Driver aborts `cores*qpairs > MaxIOCQueue` | Bump `MaxIOCQueue` in cfg or shrink the sweep. |
| gem5 boots only 1 CPU | `NUM_CPUS` didn't thread; check the readfile `NUM_CPUS=$_NUM_CPUS` substitution. |
| Only qid=1 in `[DBG_MBX_INJ]` | SPDK `-P 1` distributes 1 qpair globally instead of 1 per core. Fix: pass `-P $CORE_COUNT` not `-P $QPAIRS=1` (need to verify). |
| Crash on AP startup | Multi-CPU x86 boot path issue; check IOAPIC config in fs.py. |

### 3.3 Important subtlety to verify in smoke

In SPDK `spdk_nvme_perf`, the `-c <mask>` flag pins **worker threads** to the masked cores, and `-P N` is the **total qpair count** distributed across all workers. The bigann replay currently invokes `-c "$CORE_MASK" -P "$QPAIRS"`. To get "1 qpair per core × N cores", the right invocation is **`-P $CORE_COUNT`** (with `$QPAIRS=1` semantically meaning per-core qpair count). The smoke needs to verify this — if the smoke shows only 1 active qid out of N expected, change the replay's `-P "$QPAIRS"` to `-P $((CORE_COUNT * QPAIRS))`.

---

## 4. Production sweeps (after smoke passes)

```bash
# 6 cores × 1 qpair per core
SSD_CFG=fast_ssd_highiops.cfg ./scripts/bigann/driver_phase1_trace.sh --auto \
  --core-counts "6" --qpairs "1" --qd "128" --ios "4096" \
  --steady-time 1 --repeats 1 --uncore-mode 2 \
  --tag mc_trace_sweep_c6_qd128_mode2

# 8 cores × 1 qpair per core
SSD_CFG=fast_ssd_highiops.cfg ./scripts/bigann/driver_phase1_trace.sh --auto \
  --core-counts "8" --qpairs "1" --qd "128" --ios "4096" \
  --steady-time 1 --repeats 1 --uncore-mode 2 \
  --tag mc_trace_sweep_c8_qd128_mode2
```

Expected IOPS (with 8 MIOPS SSD ceiling):

| Cores | Predicted IOPS | Binding |
|---|---:|---|
| 1 | 1.1 M | CPU |
| 6 | 6.6 M | CPU (SSD has 1.4 M slack) |
| 7 | ~7.7 M (near SSD knee) | mixed |
| **8** | **~8 M** | **SSD** |

If the 8-core curve plateaus near 8 MIOPS while 6-core curve scales linearly, the paper has a clean "we shifted the bottleneck from CPU to device with Mode 2 + multi-core" story.

---

## 5. Risk register

- **HILCoreCount must stay 1** in the cfg. The audit confirmed host-multi-CPU is safe, but raising HIL CoreCount would re-introduce the 5 known hazards. Don't change it.
- **DPDK / hugepage memory** at 2 GB should handle 8 cores × 1 qpair × ~256 KB/thread ≈ 2 MB. Plenty of headroom; no change.
- **Boot wall-clock scales** with CPU count in gem5 (more APs to bring up). Expect ~70–90 min Linux SMP boot for 8 CPUs (vs ~50 min for 1 CPU).
- **Per-point Python parse step** in the replay script is the dominant wall-clock cost (~1.5 h per point on the gem5-simulated guest CPU for 600 K rows of `cycle_breakdown.csv`). One point per sweep, so expect ~3 h replay + 1 h Python per data point. Tag two sweeps for ~7–8 h each.
