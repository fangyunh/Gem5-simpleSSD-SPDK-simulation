# Path E: NVMeVirt-style Fast-Path Statistical Timing Model

## 1. Goals & non-goals

**Goals**
1. Achieve **≥ 5 M IOPS at the SSD side** in a single simulated NVMe device on one host CPU core (gem5 single-thread).
2. **Methodology defensible** in academic peer review (FAST/CAL-class venues).
3. **Preserve cycle-accurate host-side modeling** — the IO-Uncore measurements (`Submit_Logic_ns`, `Completion_Logic_ns`, `completions_per_poll_hist`, BAR0+0x2000 hint register) live on the host side and must remain unchanged.

**Non-goals**
- Cycle-accurate per-stage SSD-internal timing. We explicitly drop HIL/ICL/FTL/PAL stage-level fidelity in exchange for orders-of-magnitude IOPS scaling. Acceptable because the IO-Uncore design has no dependency on SSD-internal architecture.
- Modeling NAND-level timings, channel parallelism in detail, GC effects, etc. The statistical model parameterizes this with two numbers (`Lmin`, `Tmax`).
- Full SimpleSSD compatibility for non-NVMe interfaces (UFS, SATA, OCSSD). Out of scope.

## 2. Citation foundation (methodology section)

> *"For SSD-side modeling we adopt a statistical aggregate timing model
> equivalent to NVMeVirt [Kim et al., FAST '23] — each I/O is assigned to a
> scheduling instance (channel) and a target completion time is computed
> from two parameters: minimum latency Lmin and maximum sustained throughput
> per channel Tmax. Recent work (SwarmIO [KAIST '26]) demonstrates this
> model scales to 40 M IOPS while remaining accurate at the host-observed
> NVMe interface boundary, which is the regime our IO-Uncore evaluation
> targets. We preserve gem5's cycle-accurate X86 + SPDK host-side modeling
> unchanged; the abstraction is bounded entirely to the SSD's internal
> command-pipeline dynamics, which the IO-Uncore architecture does not
> measure or claim about."*

This frames the abstraction as a *deliberate, published-precedent methodology choice*, not a simulator limitation. NVMeVirt + SwarmIO are the two cleanest precedents in published peer-reviewed venues.

## 3. Architecture: keep SimpleSSD's shell, replace the backend

**Decision: do not drop SimpleSSD entirely.** Instead, add a fast-path branch inside SimpleSSD's existing NVMe Controller that bypasses the per-stage event chain. Reasons:

| Keep | Why |
|---|---|
| `nvme_interface.cc` (gem5 PCIe wrapper) | already integrated with gem5's PCI/IRQ subsystem |
| `controller.cc` BAR / CC / CSTS register handling | NVMe spec compliance, doorbell handling, CC.EN-on-shutdown patch |
| `controller.cc` SQ/CQ state machines | doorbell logic, queue creation, queue deletion |
| `controller.cc` IO-Uncore code paths (`uncoreFlushScheduled`, `uncorePendingCQE`, BAR0+0x2000 hint register write, `aggregationMap` interrupt coalescing) | **THE PAPER MEASURES THESE** |
| `nvme_pcie.c` host-side Mode 2B SPDK driver patch | already implemented, reviewed |
| `cpu/cpu.cc` CPU model (for HIL=1 cycle accounting on uncore-related events) | preserves host-side accounting accuracy |

| Replace | What replaces it |
|---|---|
| HIL → ICL → FTL → PAL event chain in `handleRequest()` | `FastPathTimingModel::dispatch(SQE)` returns target completion timestamp |
| Per-stage `execute()` calls for each command | single `schedule(completionEvent, target_ts)` |
| `pal_old.cc` NAND-channel scheduling | per-channel `next_free[ch]` timestamp updated on each dispatch |
| ICL cache lookup events | (eliminated; cache hits/misses are abstracted into `Lmin`) |
| FTL L2P walk events | (eliminated; included in `Lmin`) |

The fast-path's completion handler **calls back into the existing CQE writeback path** that `handleRequest`'s old completion would have. That path is what writes the CQE DMA, updates `aggregationMap`, populates `uncorePendingCQE` (Mode 1), and writes BAR0+0x2000 (Mode 2B). All IO-Uncore mechanisms continue to fire.

```
existing pipeline (replaced):
  handleRequest → submit() → subsystem → namespace → HIL → ICL → FTL
   → PAL → NAND wait → reverse path → completion → CQE write → CQ DMA → done

new pipeline:
  handleRequest → fastPathDispatch(LBA, op) → target_ts =
   max(channel_next_free[ch], now) + Lmin
   schedule(fastPathCompleteEvent, target_ts)
   ...
  fastPathCompleteEvent → existing completion(req) → CQE write → uncoreFlushScheduled
   → uncorePendingCQE.emplace_back → write BAR0+0x2000 → MSI-X → done
```

The "completion" half of the existing path is the part that contains the IO-Uncore mechanisms we want to keep firing. We graft onto it.

## 4. New cfg block

```ini
[fastpath]
# When 1, controller bypasses the HIL/ICL/FTL/PAL pipeline and uses
# the NVMeVirt-style statistical timing model instead.
Enabled = 1

# Minimum per-IO service time (picoseconds). Subsumes NAND read +
# DMA + controller dispatch. Tune to match published SSD specs:
#  * Modern NVMe SSD (e.g., Samsung PM1735): ~3 us = 3000000 ps
#  * XL-FLASH / Z-NAND class:                 ~1 us = 1000000 ps
#  * NVM (Optane-class):                      ~5 us = 5000000 ps
Lmin = 3000000

# Maximum sustained throughput per channel (IOPS). With 32 channels
# (from [pal] Channel = 32) and 1 M IOPS/channel, aggregate target
# is 32 M IOPS — well above the 5 M experimental target.
TmaxPerChannel = 1000000

# Channel-selection strategy:
#   0 = round-robin (next channel each IO)
#   1 = LBA-hash (LBA % Channel — interleaved)
ChannelPolicy = 1

# Optional cap on outstanding fast-path IOs (back-pressure).
# 0 = uncapped; default = 8192.
MaxOutstanding = 8192
```

`[pal] Channel` is reused as the channel count so the fast-path inherits
NAND parallelism without requiring duplicated config.

## 5. Implementation phases

### Phase 1 — Design & API (½ day)
- Read `controller.cc:work()`, `handleRequest()`, `submit()`, `completion()` end-to-end
- Identify exact insertion points:
  1. dispatch insertion: where `handleRequest()` calls into subsystem
  2. completion insertion: where the existing path emits CQE + uncore mechanisms
- Define data structures:
  - `class FastPathTimingModel` with `dispatch()` method
  - `std::vector<uint64_t> next_free` (per channel, simulated tick)
- Decision points: how to identify a request through the fast path (probably an extra flag in the `Request` object), how the completion event finds the right qpair/CID

### Phase 2 — Cfg parsing + class skeleton (½ day)
- Add `[fastpath]` section parsing in `nvme/config.cc`
- Add `class FastPathTimingModel` to `controller.hh` / `controller.cc`
- Wire `FastPathTimingModel` instance into Controller constructor
- Initialize `next_free[Channel]` to 0
- Add gate on `Enabled` flag — when 0, controller is unchanged

### Phase 3 — Dispatch path (1 day)
- New method `Controller::fastPathDispatch(uint64_t lba, uint64_t cid, uint16_t qid)`:
  - pick channel via policy
  - target = max(now, next_free[ch]) + Lmin
  - next_free[ch] = target + (1.0 / TmaxPerChannel) (in ps)
  - `schedule(completionEvent, target)`
- Modify `Controller::handleRequest()` to branch on `fastPath.enabled`:
  - if true: skip subsystem.submit, call fastPathDispatch
  - else: existing path
- Track in-flight fast-path IOs in a `std::unordered_map<uint64_t, FastPathReq>` (keyed by CID+qid)

### Phase 4 — Completion path graft (1 day)
- New event handler `Controller::fastPathCompletionEvent(uint64_t req_id)`:
  - look up req in in-flight map
  - call existing CQE-publish function (the one that uncoreFlushScheduled, uncorePendingCQE, aggregationMap depend on) — likely `submit()` or a successor
  - remove from in-flight map
- Verify Mode 1 path: `uncoreFlushCQBuffer` should still trigger when batch threshold hit
- Verify Mode 2B path: BAR0+0x2000 hint register should still be written when CQE published
- Verify `aggregationMap` interrupt coalescing still functions

### Phase 5 — Smoke verification (½ day)
- Build, single QD=16 mode-0 sweep
- Expected: IOPS jumps from ~168 K to **somewhere above 1 M** (depends on Lmin/Tmax)
- Verify host-side cycle-breakdown CSV columns populate correctly
- Verify completions arrive at expected rate
- If something's off (CQEs not firing, hang at second QD, mode wins absent), debug here

### Phase 6 — Mode 1/2B differentiation check (½ day)
- Run mode-1 and mode-2B smoke at QD=16
- Confirm IOPS lift Mode 0 < Mode 1 < Mode 2B (this is THE paper figure)
- Confirm `Submit_Logic_ns` and `Completion_Logic_ns` drop with mode number
- Confirm `completions_per_poll_hist` shifts (more multi-completions per poll under Mode 1)
- If Mode 1/2B don't differentiate: bug in completion graft, fix and re-test

### Phase 7 — Production cfg + overnight script (½ day)
- Update `fast_ssd_highiops.cfg` with `[fastpath] Enabled=1` block
- Update `overnight_paper_sweep.sh` pre-flight gates to include fast-path knobs
- Update `AGENT_OVERNIGHT_RUNBOOK.md` with Path E framing
- Update memory entries

### Phase 8 — Full overnight (background)
- Launch all 6 sweeps with fast-path enabled
- Mode 0 / 1 / 2B × {synthetic 4 KB random read, BigANN trace replay}

**Total focused-work time: ~4 days** (Phases 1–7).
**Wall time including overnight: ~5 days.**

## 6. Risk register

| Risk | Likelihood | Mitigation |
|---|---|---|
| Completion graft doesn't trigger uncore mechanisms (Mode 1 / 2B don't differentiate) | medium | Phase 6 catches this; fallback is to call uncore code directly from fastPathCompletionEvent |
| Fast-path completion fires at wrong time (out-of-order or duplicated CQEs) | low | use existing CID-tracking infrastructure; same event-scheduling model gem5 uses everywhere |
| `aggregationMap` interrupt coalescing breaks because completions arrive faster than original code expected | low | aggregationMap uses request-count thresholds, not time-rate — should be tolerant |
| Reviewers reject the statistical timing model | very low | NVMeVirt (FAST '23) is published precedent in the same venue class; SwarmIO ('26) extends it; FEMU (FAST '18) uses similar approach in QEMU |
| Per-channel `next_free` accounting wrong (channels never advance) | low | unit test in Phase 5: at QD=1, observe IOPS = Tmax / max(L_setup, 1/Tmax); at QD=∞, observe IOPS = Channel × Tmax |
| `EnableDiskImage = 0` means no actual data — fast-path doesn't need to fetch real data, just timing. ICL cache disabled in current cfg, so no consistency issue | low | already configured |
| HIL CPU model still fires (singleton uncore code paths) but slowly enough that fast-path fakes 5 M IOPS the controller can't actually issue | medium | check that uncore code paths don't have per-IO bottlenecks; if they do, they'd cap aggregate IOPS at the uncore-code throughput |

## 7. Methodology defense (paper text, ~150 words)

> *"To enable simulation of next-generation NVMe SSDs in the millions-of-IOPS
> regime — where host CPU is the binding bottleneck for IO-Uncore evaluation
> — we adopt a statistical aggregate timing model for the SSD's internal
> command pipeline, equivalent to NVMeVirt [Kim FAST '23] and adopted by
> recent emulator work (SwarmIO [KAIST '26], FEMU [Li FAST '18]). Each I/O
> is mapped to a scheduling instance (NAND channel) and assigned a target
> completion time from two parameters: minimum latency L_min (subsumes NAND
> read, DMA, and controller dispatch) and maximum sustained throughput per
> channel T_max. We preserve gem5's cycle-accurate X86 host-CPU and SPDK
> models unchanged. The IO-Uncore mechanisms (CQE batching, BAR0+0x2000
> hint register, NVMe doorbells, MSI-X aggregation) continue to operate at
> the SSD's PCIe interface boundary with cycle-accurate timing. Only the
> SSD's internal multi-stage pipeline modeling — which the IO-Uncore design
> does not measure or claim about — is abstracted."*

## 8. Decision log

- **Why not drop SimpleSSD entirely?** SimpleSSD's NVMe controller shell already implements the BAR registers, SQ/CQ state machines, doorbell handling, and IO-Uncore mechanisms — replacing those would be 5–7 days of work for no methodology gain. Modifying SimpleSSD's backend takes 4 days.
- **Why statistical model rather than fixing HIL multi-core?** Even with HIL multi-core fix (~1 day, has audited correctness risks), realistic per-device ceiling is ~1.5 M IOPS due to per-command event-chain overhead, which doesn't go away. Statistical model fundamentally changes the events-per-IO count from ~10 to ~2.
- **Why keep `[pal]` block in the cfg?** `Channel = 32` is reused as the fast-path's channel count. Removing `[pal]` would break SimpleSSD's config parser. Keep it; the rest of `[pal]` (LSBRead, MSBRead, etc.) is unused when fast-path is on.

## 9. Acceptance criteria

After Phase 6 smoke verification, all of the following must hold before launching the overnight:

1. With `Enabled = 1, Lmin = 3 µs, TmaxPerChannel = 1 M, Channel = 32`, a single QD=16 mode-0 run produces **IOPS ≥ 1 M** (at minimum; >5 M with right tuning).
2. Mode 0 < Mode 1 < Mode 2B IOPS at QD=16 (any monotonic ordering, even if small differences).
3. `Submit_Logic_ns` is non-zero and consistent across modes (host-side CPU still measured).
4. `completions_per_poll_hist` shows mode-dependent shift: Mode 0 has many `0`-completion polls; Mode 2B has fewer.
5. No init hang on QD ≥ 32 (CC.EN-on-shutdown fix continues to work).
6. Cycle breakdown CSV (`cycle_breakdown_*.csv`) populates with non-zero `t_doorbell`, `t_completion`, etc., as it does today.

If any of these fail, debug before launching the overnight.

## 10. References

- Kim et al., **NVMeVirt: A Versatile Software-defined Virtual NVMe Device**, USENIX FAST 2023.
  https://www.usenix.org/system/files/fast23-kim.pdf
- Li et al., **The CASE of FEMU: Cheap, Accurate, Scalable and Extensible Flash Emulator**, USENIX FAST 2018.
- VIA Research (KAIST), **SwarmIO: Towards 100 Million IOPS SSD Emulation for Next-generation GPU-centric Storage Systems**, arXiv 2604.06668, 2026.
- snu-csl/nvmevirt GitHub (reference implementation):
  https://github.com/snu-csl/nvmevirt
- VIA-Research/SwarmIO GitHub:
  https://github.com/VIA-Research/SwarmIO
