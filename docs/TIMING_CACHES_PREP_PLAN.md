# TimingSimpleCPU + Caches Multi-Core Prep Plan

**Date:** 2026-05-15
**Goal:** Re-run the host-multi-core sweep (1c / 4c / 8c × 1 qpair × QD=128 × Mode 2 × BigANN) under a realistic memory hierarchy so aggregate IOPS actually scales with cores. The current AtomicSimpleCPU + no-caches build clamps aggregate IOPS at ~1 M because every instruction fetch and load goes through a single shared `CoherentXBar`. Switching to TimingSimpleCPU + L1/L2 caches removes that artifact.

---

## 1. Why this change

Verified from `m5out/config.ini` of the prior 8c run:
- All 8 CPUs are `AtomicSimpleCPU @ 2 GHz`.
- No L1I/L1D/L2 caches — `dcache_port` / `icache_port` on every CPU connect *directly* to `system.membus` slave ports.
- `system.membus` is a `CoherentXBar` with `forward_latency=4` + `frontend_latency=3` = 7 ns per access at 1 GHz, shared by all 16 CPU ports.
- mem_mode = atomic.

Result: every instruction fetch and every load on every CPU competes for one arbiter; aggregate throughput pinned at the membus's atomic-mode service rate, not at any host-CPU compute or device limit.

**Fix:** TimingSimpleCPU requires `mem_mode=timing` (gem5 picks this up automatically from `TimingSimpleCPU.memory_mode()`). With `--caches --l2cache`:
- Per-CPU L1I (32 kB) + L1D (64 kB).
- Shared L2 (2 MB).
- Hot SPDK polling-loop code lives in L1I; per-qpair state lives in L1D/L2.
- Membus only sees cold misses + DMA + MMIO.

---

## 2. Source/script changes (already landed)

### 2.1 `scripts/boot_gem5.sh`

New env vars:
- `CPU_TYPE=${CPU_TYPE:-AtomicSimpleCPU}` — passed as `--cpu-type` to gem5.
- `ENABLE_CACHES=${ENABLE_CACHES:-0}` — when `1`, appends `--caches --l2cache`.

Default behavior unchanged for backward compatibility with the atomic-mode sweeps already on disk.

### 2.2 `scripts/bigann/driver_phase1_trace.sh`

New CLI flags:
- `--cpu-type TYPE` (default `AtomicSimpleCPU`).
- `--caches 0|1` (default `0`).

Both flow through to the readfile/boot env, are recorded in `metadata.json`, and surface in the launch banner.

### 2.3 No other script edits needed

`phase1_trace_replay.sh` runs entirely inside the guest — the CPU model is transparent to it. The Linux kernel sees 8 CPUs the same way regardless of the underlying gem5 CPU model.

---

## 3. Costs & predictions

### 3.1 Wall-clock

Approximate slowdown vs AtomicSimpleCPU + no caches at the same workload:

| Stage | Atomic-mode wall | Timing+caches wall (predicted) |
|---|---:|---:|
| Linux SMP boot (8 CPUs) | ~50–60 min | **5–10×** = ~5–10 h |
| Replay (1 sim-sec, QD=128) | ~1 h | **5–10×** = ~5–10 h |
| Python post-processing | ~1.5 h | unchanged (host-side) |

Single-core 1c sweep estimated: ~12–25 h wall.
Multi-core 4c/8c: similar per replay since each core does less work but membus has less contention.

**Realistic budget for the full plan:** ~3–7 wall-days.

### 3.2 Expected IOPS

Per-core IOPS will DROP from current atomic-mode numbers because the timing CPU models real memory stalls:

| Config | Atomic+nocache (current) | Timing+caches (predicted) |
|---|---:|---:|
| 1c × QD=128 | 1.10 M | 0.4–0.7 M |
| 4c × QD=128 | (not measured) | 1.5–2.5 M aggregate (≈ 3.5×) |
| 8c × QD=128 | 0.99 M | 2.5–4 M aggregate (≈ 6×) |

Per-core IOPS lower than today, but **aggregate scales near-linearly** until the device-MMIO ceiling intervenes (probably around 3–5 M aggregate).

### 3.3 What the paper gets

- **Multi-core scaling demonstration**: aggregate throughput grows with cores in a realistic memory hierarchy. Counterpoint to the atomic-mode "limit study."
- **Confirms IO-Uncore design isn't the bottleneck**: even at 8 cores the device + uncore handle the offered load.
- **Mode 2 lift stays %**: the 34 % single-core Mode 0 → Mode 2 improvement should remain similar in absolute % terms under TimingSimpleCPU.

---

## 4. Commands

### 4.1 Smoke (1c, QD=32, capped to 256 IOs)

```bash
NUMBER_IOS_CAP=256 SSD_CFG=fast_ssd_highiops.cfg \
  ./scripts/bigann/driver_phase1_trace.sh --auto \
    --core-counts "1" --qpairs "1" \
    --qd "32" --ios "4096" --steady-time 1 --repeats 1 \
    --uncore-mode 2 \
    --cpu-type TimingSimpleCPU --caches 1 \
    --tag mc_timing_smoke_c1_qd32
```

**Pass criteria:**
- `[CORES] booting gem5 with NUM_CPUS=1 ... cpu_type=TimingSimpleCPU caches=1` banner in driver log.
- gem5 cmdline contains `--cpu-type=TimingSimpleCPU --caches --l2cache`.
- Linux boots normally (`smpboot: Allowing 1 CPUs`).
- spdk_nvme_perf completes with `PHASE1_RUNSCRIPT_DONE`.
- CSV row written (`core_count1_qp1/phase1_results.csv` has 2 lines).
- IOPS in the 0.3–1 M range (sanity bound).
- m5out/config.ini shows per-CPU L1I/L1D/L2 cache sections.

### 4.2 Production sweeps (no cap, full steady-time window)

```bash
# 1 core × QD=128
SSD_CFG=fast_ssd_highiops.cfg \
  ./scripts/bigann/driver_phase1_trace.sh --auto \
    --core-counts "1" --qpairs "1" --qd "128" --ios "4096" \
    --steady-time 1 --repeats 1 --uncore-mode 2 \
    --cpu-type TimingSimpleCPU --caches 1 \
    --tag mc_timing_sweep_c1_qd128_mode2

# 4 cores
SSD_CFG=fast_ssd_highiops.cfg \
  ./scripts/bigann/driver_phase1_trace.sh --auto \
    --core-counts "4" --qpairs "1" --qd "128" --ios "4096" \
    --steady-time 1 --repeats 1 --uncore-mode 2 \
    --cpu-type TimingSimpleCPU --caches 1 \
    --tag mc_timing_sweep_c4_qd128_mode2

# 8 cores
SSD_CFG=fast_ssd_highiops.cfg \
  ./scripts/bigann/driver_phase1_trace.sh --auto \
    --core-counts "8" --qpairs "1" --qd "128" --ios "4096" \
    --steady-time 1 --repeats 1 --uncore-mode 2 \
    --cpu-type TimingSimpleCPU --caches 1 \
    --tag mc_timing_sweep_c8_qd128_mode2
```

---

## 5. Risks & failure modes

| Risk | Mitigation |
|---|---|
| Timing mode SMP boot is slow / hangs | Smoke catches this; can drop to 4c first if 8c stalls. |
| Cache + multi-CPU race in fs.py | Verified `CacheConfig.config_cache()` handles N CPUs in a loop; should be fine. |
| Wall-clock blowout: 8c run takes > 24 h | Worst case kill at PHASE1_RUNSCRIPT_DONE marker; partial CSV still useful. |
| Per-core IOPS too low to be interesting (< 100 K) | Indicates caches too small; bump `--l1d_size` / `--l2_size` via new flags. |
| MMIO ceiling at device caps aggregate IOPS | Real finding for the paper, not a bug. Document it. |

---

## 6. Execution order

1. Smoke (mc_timing_smoke_c1_qd32) — verify wiring + sanity-check per-core IOPS.
2. If smoke IOPS reasonable: launch 1c production sweep.
3. After 1c finishes: 4c sweep.
4. After 4c finishes: 8c sweep.
5. Stop gem5 cleanly between each, never touch the `claudeAI` tmux.

---

## 7. Crash observed at 4c (2026-05-15 20:20) and workaround

**1c TimingSimpleCPU + caches (L1+L2):** worked (smoke 300k IOPS; sweep 430k IOPS).

**4c TimingSimpleCPU + caches (L1+L2):** crashed with `RuntimeError: bad_function_call` from
`_m5.event.simulate()` after kernel reported `smp: Brought up 1 node, 4 CPUs`. The
gem5.out trail just before the crash:

```
warn: ClockedObject system.cpu1: More than one power state change request encountered within the same simulation tick 836193526000
warn: instruction 'wbinvd' unimplemented
warn: ClockedObject system.cpu2: More than one power state change request encountered within the same simulation tick 881128999000
warn: ClockedObject system.cpu3: More than one power state change request encountered within the same simulation tick 926049772000
warn: instruction 'fwait' unimplemented
RuntimeError: bad_function_call
```

`wbinvd`/`fwait` are benign `WarnUnimpl` (no-op + warning, fired during 1c too). The
"More than one power state change request" warnings on cpu1/2/3 are the smoking gun:
gem5's power-state framework has an empty `std::function` callback that fires
during multi-CPU bring-up with TimingSimpleCPU + caches + SimpleSSD wiring.

Only `metadata.json` was produced for the 4c run; no CSV row.

### 7.1 Workaround: drop the shared L2 (L1 only)

Hypothesis: the shared L2 + `tol2bus` + multi-master snooping in timing mode
triggers the unbound callback. L1-only keeps per-CPU caches but routes misses
straight to the membus, bypassing the suspect path.

Scripts now support this via:

- `scripts/boot_gem5.sh`: new `ENABLE_L2_CACHE=${ENABLE_L2_CACHE:-1}` env var.
  When `0`, gem5 args get `--caches` only (no `--l2cache`).
- `scripts/bigann/driver_phase1_trace.sh`: new `--l2 0|1` flag (default `1`).
  Threaded into the readfile env and recorded in `metadata.json`.

### 7.2 Rerun commands (L1-only path)

```bash
# 4c smoke (sanity, cap=256 IOs)
NUMBER_IOS_CAP=256 SSD_CFG=fast_ssd_highiops.cfg \
  ./scripts/bigann/driver_phase1_trace.sh --auto \
    --core-counts "4" --qpairs "1" \
    --qd "32" --ios "4096" --steady-time 1 --repeats 1 \
    --uncore-mode 2 \
    --cpu-type TimingSimpleCPU --caches 1 --l2 0 \
    --tag mc_timing_smoke_c4_qd32_l1only

# 4c production sweep
SSD_CFG=fast_ssd_highiops.cfg \
  ./scripts/bigann/driver_phase1_trace.sh --auto \
    --core-counts "4" --qpairs "1" --qd "128" --ios "4096" \
    --steady-time 1 --repeats 1 --uncore-mode 2 \
    --cpu-type TimingSimpleCPU --caches 1 --l2 0 \
    --tag mc_timing_sweep_c4_qd128_mode2_l1only

# 8c production sweep (after 4c passes)
SSD_CFG=fast_ssd_highiops.cfg \
  ./scripts/bigann/driver_phase1_trace.sh --auto \
    --core-counts "8" --qpairs "1" --qd "128" --ios "4096" \
    --steady-time 1 --repeats 1 --uncore-mode 2 \
    --cpu-type TimingSimpleCPU --caches 1 --l2 0 \
    --tag mc_timing_sweep_c8_qd128_mode2_l1only
```

Banner to verify: `[CORES] booting gem5 with NUM_CPUS=4 ... cpu_type=TimingSimpleCPU caches=1 l2=0`.
gem5 cmdline should contain `--caches` but NOT `--l2cache`.

### 7.3 Fallback if L1-only still crashes

If 4c crashes the same way without L2, the next steps in order of cost:

1. Boot atomic, checkpoint at workload start, restore as TimingSimpleCPU + caches
   via gem5's `--restore-with-cpu` (canonical "fast-forward then measure" pattern).
2. Reduce to 2-CPU smoke to find the lowest N that triggers the crash.
3. Rebuild gem5 with `-DGEM5_NDEBUG_FUNCTION_CALL` or a patched `PowerState::set()`
   that ignores empty callbacks.

### 7.4 Expected IOPS impact of L1-only vs L1+L2

The 1c sweep with L1+L2 produced 430 k IOPS (atomic baseline 1.1 M). Without L2,
expect:
- L1I (32 kB) holds the SPDK polling-loop hot path → still cached.
- L1D misses on per-qpair state go straight to membus → more membus contention.
- Predicted per-core drop of ~20–30 % vs L1+L2 → ~300–350 k per core at 1c.
- Aggregate scaling should still be near-linear at 4c (1.2–1.4 M) until membus
  becomes the bottleneck.
