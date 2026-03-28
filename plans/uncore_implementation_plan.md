# I/O Uncore — Detailed Step-by-Step Implementation Plan

**Last updated:** 2025-07-10
**Scope:** gem5-internal prototype. Mode A (transparent, no SPDK changes) + Mode B
(SPDK cooperative poll-lite hint path).  
**Goal:** Simulate a hardware I/O uncore that sits between the PCIe endpoint and the
NVMe controller core, batching SQ doorbell wake-ups and CQ publication events to reduce
host-CPU overhead (fewer MMIO writes, fewer CQ scans, fewer interrupts) while keeping
tail latency within a configurable guardrail.

---

## Background: What We Are Modelling and Why

In a real NVMe storage controller, an "uncore" is a small microcontroller (typically a
low-power Cortex-M class core) that decouples the PCIe endpoint from the main NVMe
processing pipeline.  It performs two functions that become bottlenecks at ultra-high IOPS:

1. **SQ doorbell coalescing** — the host CPU writes the SQ tail doorbell one or more
   times per I/O.  At tens-of-millions-of-IOPS these MMIO writes consume a non-trivial
   fraction of host PCIe bandwidth and CPU cycles.  The uncore absorbs a burst of
   doorbell writes and signals the controller core only once per batch, reducing the PCIe
   MMIO traffic and the controller's scheduling overhead.

2. **CQ publication batching** — the controller finishes I/Os and generates CQEs.
   Without batching, each CQE is DMA-written to host DRAM and triggers an MSI-X
   interrupt individually.  At high IOPS this floods the host interrupt controller.
   The uncore holds completed CQEs in a small staging buffer and publishes them en masse
   (either when N CQEs accumulate or after T nanoseconds), turning N interrupts into one.

In our gem5 simulation, all of this is pure software state: there is no real MMIO, no
real DMA.  We model the uncore by inserting batching gates at the right points in the
SimpleSSD C++ code path.  The guest CPU (running SPDK inside Linux) perceives the effect
through:
- `CQE_Detect_ns` increasing (latency to see the phase-bit flip goes up by at most T ns)
- `Scans_Per_Completion` dropping (fewer empty CQ polls per useful completion — Mode B)
- `MMIO_Writes_Per_IO` dropping (doorbell batching — Mode A Gate 1)
- `p50_Latency` and `p99_Latency` capturing the end-to-end impact

The key invariant: **CQE phase bits are only flipped by `CQueue::setData()`, which runs
inside `completion()`.  Before `setData` runs, the host guest cannot see the completion.
The uncore gates when `setData` is called, not what it writes.**

---

## Repository Paths Quick Reference

| Symbol | Path |
|---|---|
| `controller.cc` | `SimpleSSD-FullSystem/src/dev/storage/simplessd/hil/nvme/controller.cc` |
| `controller.hh` | `SimpleSSD-FullSystem/src/dev/storage/simplessd/hil/nvme/controller.hh` |
| `config.hh` | `SimpleSSD-FullSystem/src/dev/storage/simplessd/hil/nvme/config.hh` |
| `config.cc` | `SimpleSSD-FullSystem/src/dev/storage/simplessd/hil/nvme/config.cc` |
| `nvme_interface.cc` | `SimpleSSD-FullSystem/src/dev/storage/nvme_interface.cc` |
| `nvme_pcie_internal.h` | `spdk/lib/nvme/nvme_pcie_internal.h` |
| `nvme_pcie_common.c` | `spdk/lib/nvme/nvme_pcie_common.c` |
| `perf.c` | `spdk/app/spdk_nvme_perf/perf.c` |
| `driver_phase1.sh` | `scripts/driver_phase1.sh` |
| `phase1_run.sh` | `scripts/phase1_run.sh` |
| `fast_ssd.cfg` | `fast_ssd.cfg` |

---

## Phase 0 — Baseline Freeze (Day 1)

Before any code changes, record a clean baseline that all Mode A / Mode B runs will be
compared against.

### Step 0.1 — Run and tag the reference baseline

```bash
cd /home/fangy6/SimpleSSD_Gem5_simulation
tmux new -s baseline
bash scripts/driver_phase1.sh \
  --auto \
  --qd "16 32 64 128" \
  --ios "4096 16384" \
  --repeats 3 \
  --steady-time 30 \
  --tag baseline_v1
```

Wait for completion.  Results land in `results/phase1_runs/baseline_v1/`.  This is the
reference set.  Do not delete or modify it.

### Step 0.2 — Record the baseline fingerprint

After the run, extract key numbers and save them in the table below.  Fill it in
manually from `results/phase1_runs/baseline_v1/0_1/phase1_results.csv`:

| QD | IO_Size | IOPS | p50_µs | p99_µs | Scans/IO | MMIO_Writes/IO |
|---|---|---|---|---|---|---|
| 16 | 4096 | ___ | ___ | ___ | ___ | ___ |
| 32 | 4096 | ___ | ___ | ___ | ___ | ___ |
| 64 | 4096 | ___ | ___ | ___ | ___ | ___ |
| 128 | 4096 | ___ | ___ | ___ | ___ | ___ |
| 16 | 16384 | ___ | ___ | ___ | ___ | ___ |
| 32 | 16384 | ___ | ___ | ___ | ___ | ___ |
| 64 | 16384 | ___ | ___ | ___ | ___ | ___ |
| 128 | 16384 | ___ | ___ | ___ | ___ | ___ |

### Step 0.3 — Git checkpoint

```bash
git add results/phase1_runs/baseline_v1
git commit -m "baseline_v1: reference matrix before IO-uncore changes"
```

---

## Phase 1 — Config Plumbing (Days 2–3)

Add the four new knobs to the SimpleSSD NVMe config parser.  No functional controller
change yet — this just makes the knobs readable from `fast_ssd.cfg`.

### Step 1.1 — Add enum keys to `config.hh`

File: `SimpleSSD-FullSystem/src/dev/storage/simplessd/hil/nvme/config.hh`

In the `NVME_CONFIG` enum, after `NVME_USE_COW_DISK`, add:

```cpp
// --- I/O Uncore knobs ---
// UncoreMode: 0 = disabled, 1 = Mode A, 2 = Mode B
NVME_UNCORE_MODE,
// CQBatchN: flush CQ staging buffer when this many CQEs are pending
NVME_UNCORE_CQ_BATCH_N,
// CQBatchT: flush timeout in picoseconds (same unit as all timing in fast_ssd.cfg)
NVME_UNCORE_CQ_BATCH_T,
// DBBatchB: gate SQ collection until at least this many SQEs are visible
NVME_UNCORE_DB_BATCH_B,
```

In the `Config` class private section, after `useCopyOnWriteDisk`, add:

```cpp
uint32_t uncoreMode;       //!< Default: 0 (disabled)
uint32_t uncoreCQBatchN;   //!< Default: 8
uint64_t uncoreCQBatchT;   //!< Default: 4000000 ps (= 4 µs)
uint32_t uncoreDBBatchB;   //!< Default: 4
```

### Step 1.2 — Initialize defaults in `Config::Config()` in `config.cc`

At the end of the constructor body, after `useCopyOnWriteDisk = false;`, add:

```cpp
uncoreMode     = 0;
uncoreCQBatchN = 8;
uncoreCQBatchT = 4000000;   // 4 µs in picoseconds
uncoreDBBatchB = 4;
```

### Step 1.3 — Add string-name constants in `config.cc`

After the `const char NAME_USE_COW_DISK[]` declaration, add:

```cpp
const char NAME_UNCORE_MODE[]       = "UncoreMode";
const char NAME_UNCORE_CQ_BATCH_N[] = "CQBatchN";
const char NAME_UNCORE_CQ_BATCH_T[] = "CQBatchT";
const char NAME_UNCORE_DB_BATCH_B[] = "DBBatchB";
```

### Step 1.4 — Add parsing in `Config::setConfig()` in `config.cc`

Inside `setConfig()`, immediately before the final `else { ret = false; }` block, add:

```cpp
else if (MATCH_NAME(NAME_UNCORE_MODE)) {
  uncoreMode = (uint32_t)strtoul(value, nullptr, 10);
  if (uncoreMode > 2) {
    panic("UncoreMode must be 0 (disabled), 1 (Mode A), or 2 (Mode B)");
  }
}
else if (MATCH_NAME(NAME_UNCORE_CQ_BATCH_N)) {
  uncoreCQBatchN = (uint32_t)strtoul(value, nullptr, 10);
  if (uncoreCQBatchN == 0) {
    panic("CQBatchN must be >= 1");
  }
}
else if (MATCH_NAME(NAME_UNCORE_CQ_BATCH_T)) {
  uncoreCQBatchT = strtoull(value, nullptr, 10);
}
else if (MATCH_NAME(NAME_UNCORE_DB_BATCH_B)) {
  uncoreDBBatchB = (uint32_t)strtoul(value, nullptr, 10);
  if (uncoreDBBatchB == 0) {
    panic("DBBatchB must be >= 1");
  }
}
```

### Step 1.5 — Add read accessors in `Config::readUint()` in `config.cc`

Inside the `switch (idx)` of `readUint`, before the closing `}`, add:

```cpp
case NVME_UNCORE_MODE:
  ret = uncoreMode;
  break;
case NVME_UNCORE_CQ_BATCH_N:
  ret = uncoreCQBatchN;
  break;
case NVME_UNCORE_CQ_BATCH_T:
  ret = uncoreCQBatchT;
  break;
case NVME_UNCORE_DB_BATCH_B:
  ret = uncoreDBBatchB;
  break;
```

### Step 1.6 — Add config stanzas to `fast_ssd.cfg`

At the bottom of the `[nvme]` section, add:

```ini
; --- I/O Uncore knobs ---
; UncoreMode: 0=disabled, 1=Mode A (transparent), 2=Mode B (Mode A + SPDK hint)
UncoreMode     = 0
; CQBatchN: publish CQEs to host after this many are buffered
CQBatchN       = 8
; CQBatchT: publish CQEs to host after this timeout (picoseconds)
; 4000000 = 4 µs  (must be << typical IO latency ~84 µs)
CQBatchT       = 4000000
; DBBatchB: defer SQ command collection until at least this many SQEs are visible
DBBatchB       = 4
```

### Step 1.7 — Build check (config only)

```bash
cd SimpleSSD-FullSystem
conda run -n simplessd_env \
  env LD_LIBRARY_PATH="$(conda run -n simplessd_env python -c \
    'import sys,os; print(os.path.join(sys.prefix,"lib"))')" \
  scons -j$(nproc) build/X86/gem5.opt 2>&1 | tail -20
```

Expected: clean build.  Fix any typos before proceeding.

---

## Phase 2 — Controller Data Structures (Days 3–4)

Add all uncore state to `controller.hh`.  No behavior changes in `controller.cc` yet.

### Step 2.1 — Add the UncoreMode enum in `controller.hh`

Before the `class Controller` declaration, add:

```cpp
typedef enum {
  UNCORE_MODE_DISABLED = 0,
  UNCORE_MODE_A        = 1,
  UNCORE_MODE_B        = 2,
} UncoreMode;
```

### Step 2.2 — Add the UncoreConfig struct in `controller.hh`

After the `UncoreMode` enum:

```cpp
struct UncoreConfig {
  UncoreMode mode       = UNCORE_MODE_DISABLED;
  uint32_t   cqBatchN   = 8;
  uint64_t   cqBatchT   = 4000000;   // picoseconds
  uint32_t   dbBatchB   = 4;
};
```

### Step 2.3 — Add the CQE staging entry struct in `controller.hh`

```cpp
struct UncoreCQPendingEntry {
  CQEntryWrapper wrapper;    // complete CQE and metadata
  uint64_t       arrivedAt;  // getTick() when submit() was called
};
```

### Step 2.4 — Add the UncoreStats struct in `controller.hh`

```cpp
struct UncoreStats {
  uint64_t sqesVisible          = 0;
  uint64_t collectDeferred      = 0;
  uint64_t collectAllowed       = 0;
  uint64_t cqesGenerated        = 0;  // I/O CQEs entering staging buffer
  uint64_t cqesAdminBypassed    = 0;  // Admin CQEs that went directly to lCQFIFO
  uint64_t cqesPublished        = 0;
  uint64_t flushByCount         = 0;
  uint64_t flushByTimeout       = 0;
  uint64_t flushByShutdown      = 0;
  uint64_t flushDepthHist[64]   = {};
};
```

### Step 2.5 — Add private members to the `Controller` class in `controller.hh`

In the `private:` section (after the `conf` member), add:

```cpp
// --- I/O Uncore ---
UncoreConfig  uncoreCfg;
UncoreStats   uncoreStats;

// Flat staging buffer for CQEs that have not yet been published to host CQ memory.
// Populated when uncoreCfg.mode != UNCORE_MODE_DISABLED.
std::vector<UncoreCQPendingEntry> uncorePendingCQE;

// Per-SQueue SQE visibility counters (sized to sqsize in constructor).
// Used by Gate 1 to track accumulated pending work across work() ticks.
std::vector<uint32_t> uncoreDbAccumPerQ;

// Mode B readiness hint (4-byte vendored register at BAR0+0x2000).
// 0 = no CQEs pending from host's perspective; N = N CQEs pending.
uint32_t uncoreHintReady;

// Whether uncoreFlushEvent is currently scheduled (prevents double-schedule).
bool uncoreFlushScheduled;

// Timeout-driven flush event (fired T ps after the first CQE enters the buffer).
Event uncoreFlushEvent;
```

### Step 2.6 — Add public method declarations to `Controller` in `controller.hh`

After `void completion();`, add:

```cpp
void     uncoreFlushCQBuffer(bool isShutdown = false);
uint32_t getUncoreHintReady() const { return uncoreHintReady; }
```

### Step 2.7 — Build check

Build again.  Should compile cleanly.  The declared-but-not-yet-defined
`uncoreFlushCQBuffer` will not cause a linker error until it is called.

---

## Phase 3 — Constructor Initialization (Day 4)

### Step 3.1 — Add the hint register offset constant in `controller.cc`

After the `#define BOOLEAN_STRING` line at the top of `controller.cc`, add:

```cpp
// BAR0 byte offset of the Mode B readiness hint register.
// The NVMe doorbell region starts at REG_DOORBELL_BEGIN (0x1000) and with
// MaxIOSQueue=16 occupies only ~136 bytes.  0x2000 is safely past it.
#define UNCORE_HINT_REG_OFFSET  0x2000
```

### Step 3.2 — Initialize uncore state in `Controller::Controller()`

After the line `requestInterval = workInterval / maxRequest;`, add:

```cpp
// --- I/O Uncore initialization ---
uncoreCfg.mode     = (UncoreMode)conf.readUint(CONFIG_NVME, NVME_UNCORE_MODE);
uncoreCfg.cqBatchN = (uint32_t)conf.readUint(CONFIG_NVME, NVME_UNCORE_CQ_BATCH_N);
uncoreCfg.cqBatchT = conf.readUint(CONFIG_NVME, NVME_UNCORE_CQ_BATCH_T);
uncoreCfg.dbBatchB = (uint32_t)conf.readUint(CONFIG_NVME, NVME_UNCORE_DB_BATCH_B);

uncoreHintReady      = 0;
uncoreFlushScheduled = false;
uncorePendingCQE.clear();
uncoreDbAccumPerQ.assign(sqsize, 0);

uncoreFlushEvent = allocate([this](uint64_t) { uncoreFlushCQBuffer(false); });

debugprint(LOG_HIL_NVME,
           "UNCORE  | mode=%u cqBatchN=%u cqBatchT=%" PRIu64 " dbBatchB=%u",
           (uint32_t)uncoreCfg.mode, uncoreCfg.cqBatchN,
           uncoreCfg.cqBatchT, uncoreCfg.dbBatchB);
```

The `allocate([this](uint64_t){ ... })` pattern is identical to how `workEvent`,
`requestEvent`, and `completionEvent` are registered in the same constructor.

### Step 3.3 — Build and verify the UNCORE log line appears

Set `UncoreMode = 1` in `fast_ssd.cfg`.  Run a short simulation and grep:

```bash
grep "UNCORE" logs/gem5.out
```

Expected output: `UNCORE  | mode=1 cqBatchN=8 cqBatchT=4000000 dbBatchB=4`.

---

## Phase 4 — Mode A Gate 1: SQ Collection Guard (Days 5–6)

Gate 1 sits at the top of `collectSQueue()`.  It counts how many SQEs are currently
visible across all I/O submission queues.  If fewer than `dbBatchB` are visible, the
DMA-read cycle is skipped and work is deferred to the next `workInterval` tick.

The admin queue (sqID == 0) is always exempt from the threshold — it must never be
delayed.

### Step 4.1 — Insert the guard at the top of `collectSQueue()` in `controller.cc`

The function signature is:
```cpp
void Controller::collectSQueue(DMAFunction &func, void *context) {
```

Immediately after the opening `{`, insert:

```cpp
  // --- I/O Uncore: Gate 1 — SQ collection threshold guard ---
  if (uncoreCfg.mode != UNCORE_MODE_DISABLED) {
    // If the admin queue has work, always allow collection regardless of threshold.
    bool adminHasWork = (ppSQueue[0] && ppSQueue[0]->getItemCount() > 0);

    // Count pending SQEs across all I/O queues (skip admin, sqID 0).
    uint32_t totalIOVisible = 0;
    for (uint16_t i = 1; i < sqsize; i++) {
      if (ppSQueue[i]) {
        totalIOVisible += ppSQueue[i]->getItemCount();
      }
    }
    uncoreStats.sqesVisible += totalIOVisible;

    if (!adminHasWork && totalIOVisible < uncoreCfg.dbBatchB) {
      // Not enough commands have accumulated.
      // Call func immediately (signals "no work this cycle") and return.
      // The work() event will reschedule at the next workInterval.
      uncoreStats.collectDeferred++;
      func(getTick(), context);
      return;
    }
    uncoreStats.collectAllowed++;
  }
  // --- End Gate 1 ---
  // Existing arbitration logic (round-robin / WRR) follows unchanged.
```

### Step 4.2 — Why `getItemCount()` is the right signal

`SQueue::getItemCount()` returns `(tail - head + size) % size`.  The `tail` is updated
immediately by `ringSQTailDoorbell()` when SPDK writes the MMIO doorbell.  The `head`
advances when `checkQueue()` DMA-reads a 64-byte SQE.  So `getItemCount()` is exactly
the number of SQEs the host has submitted but the controller has not yet read.

At `dbBatchB = 1`, `totalIOVisible >= 1` any time there is any pending work, which is
equivalent to the unguarded baseline.  At `dbBatchB = 4`, the controller waits until 4
SQEs are visible before starting a DMA-read burst, reducing per-SQE DMA setup overhead.

### Step 4.3 — Smoke test with DBBatchB=1 (no-op threshold)

```bash
# Edit fast_ssd.cfg: UncoreMode=1, DBBatchB=1, CQBatchN=1
bash scripts/driver_phase1.sh --auto --qd 16 --ios 4096 --repeats 1 \
  --steady-time 10 --tag gate1_noop_smoke
```

Expected: IOPS within ±3% of baseline_v1 at QD=16.  Any larger deviation indicates a
bug in the `func(getTick(), context)` early-return path.

---

## Phase 5 — Mode A Gate 2: CQE Staging in `submit()` (Days 6–7)

Gate 2 intercepts non-admin CQEs before they enter `lCQFIFO`, diverting them to the
staging buffer.  Admin CQEs (cqID == 0) always bypass the buffer and go directly to the
existing path.

### Step 5.1 — Locate the insertion point in `submit()` in `controller.cc`

```cpp
void Controller::submit(CQEntryWrapper &entry) {
  CQueue *pQueue = ppCQueue[entry.cqID];
  if (pQueue == NULL) {
    panic("nvme_ctrl: Completion Queue not created! CQID %d", entry.cqID);
  }
  entry.submitAt = getTick();   // <-- insert after this line
  // existing: insert into lCQFIFO ...
```

### Step 5.2 — Insert the staging gate after `entry.submitAt = getTick();`

```cpp
  // --- I/O Uncore: Gate 2 — CQE staging buffer ---
  if (uncoreCfg.mode != UNCORE_MODE_DISABLED) {
    if (entry.cqID != 0) {
      // Non-admin CQE: redirect to staging buffer.
      UncoreCQPendingEntry pend;
      pend.wrapper   = entry;
      pend.arrivedAt = entry.submitAt;
      uncorePendingCQE.push_back(pend);
      uncoreStats.cqesGenerated++;

      if ((uint32_t)uncorePendingCQE.size() >= uncoreCfg.cqBatchN) {
        // Count threshold reached — flush now.
        uncoreFlushCQBuffer(false);
      }
      else if (!uncoreFlushScheduled) {
        // Arm the timeout flush.
        uncoreFlushScheduled = true;
        schedule(uncoreFlushEvent, entry.submitAt + uncoreCfg.cqBatchT);
      }
      return;  // Do NOT fall through to the existing lCQFIFO path.
    }
    else {
      // Admin CQE (cqID==0): always immediate — bypass staging buffer, but count it.
      uncoreStats.cqesAdminBypassed++;
    }
  }
  // --- End Gate 2 ---
  // Fall through to original lCQFIFO path for: admin CQEs, or disabled mode.
```

The existing `lCQFIFO.insert()` and `reserveCompletion()` calls below remain completely
unchanged — they are only reached for admin CQEs and when uncore is disabled.

---

## Phase 6 — Mode A Gate 3: Flush Function (Days 7–8)

### Step 6.1 — Implement `uncoreFlushCQBuffer()` in `controller.cc`

Add this function before `void Controller::getStatList(...)`:

```cpp
void Controller::uncoreFlushCQBuffer(bool isShutdown) {
  if (uncorePendingCQE.empty()) {
    if (uncoreFlushScheduled) {
      deschedule(uncoreFlushEvent);
      uncoreFlushScheduled = false;
    }
    return;
  }

  uint64_t depth = (uint64_t)uncorePendingCQE.size();

  // Record flush depth histogram (bucket capped at 63)
  uncoreStats.flushDepthHist[(depth < 64) ? depth : 63]++;

  // Record trigger type
  if (isShutdown) {
    uncoreStats.flushByShutdown++;
  } else if (depth >= (uint64_t)uncoreCfg.cqBatchN) {
    uncoreStats.flushByCount++;
  } else {
    uncoreStats.flushByTimeout++;
  }

  // Move staged CQEs into lCQFIFO, preserving submitAt sort order
  for (auto &pe : uncorePendingCQE) {
    CQEntryWrapper &entry = pe.wrapper;
    auto iter = lCQFIFO.begin();
    for (; iter != lCQFIFO.end(); iter++) {
      if (iter->submitAt > entry.submitAt) {
        break;
      }
    }
    lCQFIFO.insert(iter, entry);
    uncoreStats.cqesPublished++;
  }
  uncorePendingCQE.clear();

  // Cancel timeout if it was pending
  if (uncoreFlushScheduled) {
    deschedule(uncoreFlushEvent);
    uncoreFlushScheduled = false;
  }

  // Update Mode B hint: N entries now in lCQFIFO, none in staging buffer
  uncoreHintReady = (uint32_t)lCQFIFO.size();

  // Hand off to existing DMA-write pipeline
  reserveCompletion();
}
```

### Step 6.2 — Update the Mode B hint after each CQ drain in `completion()`

In `completion()`, in the `send` lambda (right before `reserveCompletion()` is called
and before `delete pData;`), add:

```cpp
      // Update Mode B hint: staging buffer is already empty at this point
      // (staged CQEs moved to lCQFIFO by flush); update to reflect what is
      // still left in lCQFIFO after this drain cycle.
      uncoreHintReady = (uint32_t)lCQFIFO.size();
```

This is conservative: it may briefly over-report pending CQEs (safe — SPDK will scan
and find nothing, which is harmless), but will accurately reflect 0 when both sources
are empty.

### Step 6.3 — Force-drain on shutdown in `work()`

In `work()`, inside the `if (shutdownReserved)` block, before `lSQFIFO.clear();`, add:

```cpp
    // I/O Uncore: force-drain staging buffer so SPDK sees all CQEs before shutdown
    if (!uncorePendingCQE.empty()) {
      uncoreFlushCQBuffer(true);
    }
```

### Step 6.4 — Functional test at CQBatchN=1 (immediate flush, no latency impact)

```bash
# fast_ssd.cfg: UncoreMode=1, CQBatchN=1, CQBatchT=4000000, DBBatchB=1
bash scripts/driver_phase1.sh --auto --qd 32 --ios 4096 --repeats 2 \
  --steady-time 15 --tag mode_a_n1_b1_smoke
```

Expected: IOPS and p99 within ±2% of baseline.  Any regression means the flush pipeline
has a double-call to `reserveCompletion()` or double-schedule of `completionEvent`.
Add a temporary assertion: `assert(!isScheduled(completionEvent))` before
`reserveCompletion()` in `uncoreFlushCQBuffer()` to catch this.

### Step 6.5 — Full Mode A test with real batching

```bash
# fast_ssd.cfg: UncoreMode=1, CQBatchN=8, CQBatchT=4000000, DBBatchB=4
bash scripts/driver_phase1.sh --auto \
  --qd "16 32 64 128" --ios "4096 16384" --repeats 3 --steady-time 30 \
  --tag mode_a_n8_t4us_b4_v1
```

Expected changes vs baseline:
- `CQE_Detect_ns` increases by up to ~4 µs (one `CQBatchT` period).
- `Scans_Per_Completion` decreases because published batches are larger.
- `MMIO_Writes_Per_IO` may decrease slightly at high QD (Gate 1 effect).
- `IOPS` equal to or slightly above baseline (more pipelining in controller).
- `p99_Latency` ≤ `baseline_p99 + 5 µs` (guardrail target).

---

## Phase 7 — Stats Export (Day 8)

Export uncore counters into `m5out/stats.txt` so they are visible alongside the rest of
the SimpleSSD statistics.

### Step 7.1 — Override `getStatList()` in `controller.cc`

Replace the existing single-line delegate:

```cpp
void Controller::getStatList(std::vector<Stats> &list, std::string prefix) {
  pSubsystem->getStatList(list, prefix);
}
```

With:

```cpp
void Controller::getStatList(std::vector<Stats> &list, std::string prefix) {
  if (uncoreCfg.mode != UNCORE_MODE_DISABLED) {
    std::string p = prefix + "uncore.";
    list.push_back({p + "sqes_visible",         "SQEs visible to Gate 1 over all work cycles"});
    list.push_back({p + "collect_deferred",     "Gate 1 deferrals (not enough SQEs)"});
    list.push_back({p + "collect_allowed",      "Gate 1 pass-throughs"});
    list.push_back({p + "cqes_generated",       "I/O CQEs entering staging buffer"});
    list.push_back({p + "cqes_admin_bypassed",  "Admin CQEs bypassing staging (always immediate)"});
    list.push_back({p + "cqes_published",       "CQEs written to host CQ via flush"});
    list.push_back({p + "flush_by_count",       "Flushes triggered by count threshold N"});
    list.push_back({p + "flush_by_timeout",     "Flushes triggered by timeout T"});
    list.push_back({p + "flush_by_shutdown",    "Force-drain flushes on shutdown"});
    for (int i = 0; i < 64; i++) {
      list.push_back({p + "flush_depth_hist_" + std::to_string(i),
                      "Flush depth histogram bucket " + std::to_string(i)});
    }
  }
  pSubsystem->getStatList(list, prefix);
}
```

### Step 7.2 — Override `getStatValues()` and `resetStatValues()` in `controller.cc`

```cpp
void Controller::getStatValues(std::vector<double> &values) {
  if (uncoreCfg.mode != UNCORE_MODE_DISABLED) {
    values.push_back((double)uncoreStats.sqesVisible);
    values.push_back((double)uncoreStats.collectDeferred);
    values.push_back((double)uncoreStats.collectAllowed);
    values.push_back((double)uncoreStats.cqesGenerated);
    values.push_back((double)uncoreStats.cqesAdminBypassed);
    values.push_back((double)uncoreStats.cqesPublished);
    values.push_back((double)uncoreStats.flushByCount);
    values.push_back((double)uncoreStats.flushByTimeout);
    values.push_back((double)uncoreStats.flushByShutdown);
    for (int i = 0; i < 64; i++) {
      values.push_back((double)uncoreStats.flushDepthHist[i]);
    }
  }
  pSubsystem->getStatValues(values);
}

void Controller::resetStatValues() {
  uncoreStats = UncoreStats{};   // zero-initializes all fields
  pSubsystem->resetStatValues();
}
```

**Critical constraint:** the identical `if (uncoreCfg.mode != UNCORE_MODE_DISABLED)` guard
must appear in both `getStatList` and `getStatValues`, and both must add the same number
of entries in exactly the same order.  gem5 maps them positionally.  Verify by adding a
debug assert at simulation end: `assert(list.size() == values.size())`.

### Step 7.3 — Verify stats appear

After a Mode A run:

```bash
grep uncore SimpleSSD-FullSystem/m5out/stats.txt
```

Expected: lines like `system.pc.nvme.uncore.cqes_generated   <N>`.

---

## Phase 8 — Script Integration (Days 9–10)

### Step 8.1 — Add CLI flags to `driver_phase1.sh`

In the argument parsing loop (`while [ $# -gt 0 ]`), after `--steady-time`, add:

```bash
    --uncore-mode)  UNCORE_MODE="${2:-0}"; shift 2 ;;
    --cq-batch-n)   CQ_BATCH_N="${2:-8}"; shift 2 ;;
    --cq-batch-t)   CQ_BATCH_T="${2:-4000000}"; shift 2 ;;
    --db-batch-b)   DB_BATCH_B="${2:-4}"; shift 2 ;;
```

At the top of the script with the other defaults:

```bash
UNCORE_MODE="${UNCORE_MODE:-0}"
CQ_BATCH_N="${CQ_BATCH_N:-8}"
CQ_BATCH_T="${CQ_BATCH_T:-4000000}"
DB_BATCH_B="${DB_BATCH_B:-4}"
```

### Step 8.2 — Patch `fast_ssd.cfg` before starting gem5

In the section that prepares the run environment (before calling `boot_gem5.sh start`),
add:

```bash
CFG="$SCRIPT_DIR/../fast_ssd.cfg"
sed -i "s/^UncoreMode\s*=.*/UncoreMode     = $UNCORE_MODE/" "$CFG"
sed -i "s/^CQBatchN\s*=.*/CQBatchN       = $CQ_BATCH_N/"   "$CFG"
sed -i "s/^CQBatchT\s*=.*/CQBatchT       = $CQ_BATCH_T/"   "$CFG"
sed -i "s/^DBBatchB\s*=.*/DBBatchB       = $DB_BATCH_B/"   "$CFG"
```

This bakes the experiment parameters into the config file at runtime, which is the
cleanest way to pass them into the gem5 simulation without modifying the gem5 launch
command or adding a new gem5 option.

### Step 8.3 — Add uncore fields to the metadata sidecar JSON

In the JSON metadata block (written alongside each run's CSV), add:

```bash
  "uncore_mode":  $UNCORE_MODE,
  "cq_batch_n":   $CQ_BATCH_N,
  "cq_batch_t":   $CQ_BATCH_T,
  "db_batch_b":   $DB_BATCH_B,
```

### Step 8.4 — Run tag naming convention

| Pattern | Config |
|---|---|
| `baseline_v*` | UncoreMode=0 |
| `modeA_nN_tTps_bB_v*` | UncoreMode=1, CQBatchN=N, CQBatchT=T ps, DBBatchB=B |
| `modeB_nN_tTps_bB_v*` | UncoreMode=2, same parameters |

Example full run command:

```bash
bash scripts/driver_phase1.sh --auto \
  --qd "16 32 64 128" --ios "4096 16384" --repeats 3 --steady-time 30 \
  --uncore-mode 1 --cq-batch-n 8 --cq-batch-t 4000000 --db-batch-b 4 \
  --tag modeA_n8_t4us_b4_v1
```

---

## Phase 9 — Mode B: gem5-Side Hint Register (Days 11–12)

Mode B adds a 4-byte vendor-specific readiness hint register at BAR0 offset `0x2000`.
The gem5 NVMe device exposes it as a readable register.  SPDK reads it before each CQ
scan — if the value is zero, no scan is performed.

### Step 9.1 — Add the hint register offset constant to `nvme_interface.cc`

Near the top of `nvme_interface.cc`, after the existing includes, add:

```cpp
// BAR0 byte offset of the Mode B I/O Uncore readiness hint register.
// Vendor-specific; sits past the doorbell region (which ends before 0x2000).
#define UNCORE_HINT_REG_OFFSET  0x2000
```

### Step 9.2 — Add BAR0 read handling for the hint register in `NVMeInterface::read()`

Find the block:

```cpp
  if (addr >= registerTableBaseAddress &&
      addr + size <= registerTableBaseAddress + registerTableSize) {
    int offset = addr - registerTableBaseAddress;
    if (offset >= SimpleSSD::HIL::NVMe::REG_DOORBELL_BEGIN) {
      memset(buffer, 0, size);
    }
    else {
      pController->readRegister(offset, size, buffer, end);
    }
  }
```

Replace with:

```cpp
  if (addr >= registerTableBaseAddress &&
      addr + size <= registerTableBaseAddress + registerTableSize) {
    int offset = addr - registerTableBaseAddress;

    if (offset == UNCORE_HINT_REG_OFFSET && size == sizeof(uint32_t)) {
      // Mode B readiness hint: fast vendor register read (zero PCIe latency).
      uint32_t hint = pController->getUncoreHintReady();
      memcpy(buffer, &hint, sizeof(uint32_t));
      end = begin;
    }
    else if (offset >= SimpleSSD::HIL::NVMe::REG_DOORBELL_BEGIN) {
      memset(buffer, 0, size);
    }
    else {
      pController->readRegister(offset, size, buffer, end);
    }
  }
```

**Why zero PCIe latency?**  The hint register is a fast flip-flop in the embedded
controller register file.  Modeling PCIe read latency here would add noise to the
Doorbell_ns measurement without research value.  The hint semantics are conservative
(a stale non-zero hint just causes a harmless wasted CQ scan), so zero latency is safe.

---

## Phase 10 — Mode B: SPDK Hint Path (Days 13–15)

### Step 10.1 — Add hint fields to `nvme_pcie_qpair` in `nvme_pcie_internal.h`

In `struct nvme_pcie_qpair`, after the `volatile uint32_t *cq_hdbl;` field, add:

```c
  /* Mode B I/O Uncore cooperative hint register.
   * Points to BAR0 + 0x2000 in the gem5 NVMe device.
   * NULL when Mode B is not enabled.
   * Value 0 = no CQEs pending host-visible; N = N CQEs pending. */
  volatile uint32_t *uncore_cq_hint_reg;
  uint64_t           uncore_hint_hits;    /* scan skips due to hint==0 */
  uint64_t           uncore_hint_misses;  /* scans where hint was non-zero */
```

### Step 10.2 — Initialize the hint pointer in `nvme_pcie_qpair_construct()` in `nvme_pcie_common.c`

At the end of `nvme_pcie_qpair_construct()`, before `return 0;`, add:

```c
  /* Mode B hint register initialization.
   * Enabled by setting env var SPDK_UNCORE_HINT=1.
   * BAR0 doorbell base (pctrlr->doorbell_base) points to byte offset 0x1000.
   * The hint register is at byte offset 0x2000 = 0x1000 + 0x1000.
   * Since doorbell_base is a (volatile uint32_t*), advance by 0x400 words. */
  pqpair->uncore_cq_hint_reg = NULL;
  pqpair->uncore_hint_hits   = 0;
  pqpair->uncore_hint_misses = 0;
  {
    const char *env = getenv("SPDK_UNCORE_HINT");
    if (env && atoi(env) == 1) {
      pqpair->uncore_cq_hint_reg = pctrlr->doorbell_base + 0x400;
      NVME_QPAIR_INFOLOG(qpair, "Mode B hint register at %p\n",
                         (void *)pqpair->uncore_cq_hint_reg);
    }
  }
```

Using an environment variable keeps the binary backward-compatible: the stock binary
shipped in `docker_artifacts/` will never activate the hint path even if
`uncore_cq_hint_reg` were accidentally non-null (it won't be with env var not set).

### Step 10.3 — Add the hint gate in `nvme_pcie_qpair_process_completions()` in `nvme_pcie_common.c`

Find the function.  The CQ scan loop begins after a `poll_start` timestamp read.
Immediately before that loop, add:

```c
  /* Mode B hint: skip CQ scan if device reports 0 pending CQEs */
  if (pqpair->uncore_cq_hint_reg != NULL) {
    uint32_t hint = spdk_mmio_read_4(pqpair->uncore_cq_hint_reg);
    if (hint == 0) {
      pqpair->stat->idle_polls++;
      pqpair->uncore_hint_hits++;
      return 0;
    }
    pqpair->uncore_hint_misses++;
  }
```

`spdk_mmio_read_4()` is in `spdk/include/spdk/mmio.h` (already included via
`nvme_internal.h`).  It does a single 4-byte volatile read with a compiler barrier —
exactly the same as doorbell writes.

**Correctness guarantee:** If the hint says 0 but a CQE was posted between the hint read
and the scan, the CQE will be seen on the next poll iteration (within ~1 µs).  This is
the same eventual-consistency model used by NVMe interrupt coalescing and is
NVMe-spec-compliant for polling drivers.

### Step 10.4 — Add hint counters to the perf stats dump in `perf.c`

In `nvme_dump_pcie_statistics()`, after printing `sq_mmio_doorbell_updates`, add:

```c
    /* Mode B hint stats — summed across qpairs */
    uint64_t hint_hits = 0, hint_misses = 0;
    /* Iterate over active qpairs to sum per-qpair counters.
     * Access via the ns's ctrlr, same pattern used for other per-qpair stats. */
    // (Exact iteration code depends on how perf.c walks qpairs — copy the
    //  pattern from the existing loop that prints per-qpair completions_hist.)
    printf("uncore_hint_hits:          %" PRIu64 "\n", hint_hits);
    printf("uncore_hint_misses:        %" PRIu64 "\n", hint_misses);
```

### Step 10.5 — Add CSV parse lines to `phase1_run.sh`

In the CSV construction block, after the `sq_mmio_doorbell` parse:

```bash
HINT_HITS=$(  grep "uncore_hint_hits:"   "$SPDK_OUT" | awk '{print $2}' || echo 0)
HINT_MISSES=$(grep "uncore_hint_misses:" "$SPDK_OUT"  | awk '{print $2}' || echo 0)
```

Add them as two new columns in the CSV row (backward compatible; base value is 0 for
non-Mode-B runs).

### Step 10.6 — Select the correct SPDK binary based on mode in `phase1_run.sh`

```bash
if [ "${UNCORE_MODE:-0}" -ge 2 ]; then
  SPDK_BIN="/mnt/9p/docker_artifacts/guest_spdk_nvme_perf_mode_b"
  export SPDK_UNCORE_HINT=1
else
  SPDK_BIN="/mnt/9p/docker_artifacts/guest_spdk_nvme_perf"
fi
```

### Step 10.7 — Rebuild the SPDK guest binary for Mode B

```bash
cd spdk
./configure --with-nvme-pcie
make -j$(nproc) app/spdk_nvme_perf/perf
cp build/bin/spdk_nvme_perf \
   ../docker_artifacts/guest_spdk_nvme_perf_mode_b
```

This produces a second binary that is identical to the stock binary in all paths except
the addition of the hint pointer initialization and the five-line hint gate.  The stock
binary at `docker_artifacts/guest_spdk_nvme_perf` is untouched.

---

## Phase 11 — Full Rebuild and Integration Verification (Day 16)

### Step 11.1 — Rebuild gem5

```bash
cd SimpleSSD-FullSystem
conda run -n simplessd_env \
  env LD_LIBRARY_PATH="$(conda run -n simplessd_env python -c \
    'import sys,os; print(os.path.join(sys.prefix,"lib"))')" \
  scons -j$(nproc) build/X86/gem5.opt 2>&1 | tail -30
```

### Step 11.2 — Regression: disabled mode must match baseline

```bash
bash scripts/driver_phase1.sh --auto --qd "16 32" --ios 4096 \
  --repeats 2 --steady-time 15 --uncore-mode 0 --tag regression_disabled
```

Pass criteria: IOPS within ±2% of baseline_v1 for same (QD, IO_Size).
Any larger deviation means the `UNCORE_MODE_DISABLED` guard is leaking into the hot path.

### Step 11.3 — Verify no lost completions

After each Mode A run, verify:
- `Completions` in CSV ≈ `IOPS × STEADY_TIME` (within integer rounding).
- `m5out/stats.txt` entry `system.pc.nvme.command_count` ≈ CSV Completions.
- No `panic:` in `gem5.out`.
- Driver exits cleanly (detects `PHASE1_RUNSCRIPT_DONE`).

### Step 11.4 — Verify no deadlock on shutdown

Run a short experiment (--steady-time 2) multiple times and confirm the driver always
exits.  Any hang here indicates that the shutdown drain path (Phase 6 Step 6.3) is
incomplete.

### Step 11.5 — Mode B smoke test

```bash
bash scripts/driver_phase1.sh --auto --qd 32 --ios 4096 \
  --repeats 1 --steady-time 10 --uncore-mode 2 \
  --cq-batch-n 8 --cq-batch-t 4000000 --db-batch-b 4 \
  --tag mode_b_smoke
```

Verify in the CSV: `HINT_HITS > 0`.  If zero, the hint pointer was not initialized —
check the `SPDK_UNCORE_HINT` env var is being exported and the pointer arithmetic using
`doorbell_base + 0x400` yields the correct address (validate against `gem5.out` BAR0
address printed during NVMe initialization).

---

## Phase 12 — Performance A/B Experiment Matrix (Days 17–21)

### Step 12.1 — Sweep CQBatchN (T fixed, B=1)

```bash
for N in 1 2 4 8 16 32; do
  bash scripts/driver_phase1.sh --auto \
    --qd "16 32 64 128" --ios "4096 16384" --repeats 3 --steady-time 30 \
    --uncore-mode 1 --cq-batch-n $N --cq-batch-t 4000000 --db-batch-b 1 \
    --tag "modeA_n${N}_t4us_b1_v1"
done
```

Plot: `CQE_Detect_ns`, `Scans_Per_Completion`, `p99_Latency` vs N.

### Step 12.2 — Sweep CQBatchT (N fixed high, B=1)

```bash
for T in 1000 10000 100000 1000000 4000000 10000000; do
  bash scripts/driver_phase1.sh --auto \
    --qd "16 32 64 128" --ios 4096 --repeats 3 --steady-time 30 \
    --uncore-mode 1 --cq-batch-n 64 --cq-batch-t $T --db-batch-b 1 \
    --tag "modeA_n64_t${T}ps_b1_v1"
done
```

Plot: `CQE_Detect_ns`, `Scans_Per_Completion`, `p99_Latency` vs T.

### Step 12.3 — Sweep DBBatchB (N=8, T=4µs)

```bash
for B in 1 2 4 8 16; do
  bash scripts/driver_phase1.sh --auto \
    --qd "64 128" --ios 4096 --repeats 3 --steady-time 30 \
    --uncore-mode 1 --cq-batch-n 8 --cq-batch-t 4000000 --db-batch-b $B \
    --tag "modeA_n8_t4us_b${B}_v1"
done
```

Plot: `MMIO_Writes_Per_IO`, `IOPS`, `p99_Latency` vs B.

### Step 12.4 — Mode A vs Mode B comparison

Using the best parameters from Steps 12.1-12.3:

```bash
bash scripts/driver_phase1.sh --auto \
  --qd "16 32 64 128" --ios "4096 16384" --repeats 3 --steady-time 30 \
  --uncore-mode 2 --cq-batch-n 8 --cq-batch-t 4000000 --db-batch-b 4 \
  --tag modeB_best_v1
```

Compare `HINT_HITS / (HINT_HITS + HINT_MISSES)` ratio vs additional `Scans_Per_Completion`
reduction on top of Mode A.

### Step 12.5 — Latency guardrail analysis

For each run, compute and enforce:

```python
GUARDRAIL_US = 10   # p99 must not increase by more than 10 µs vs baseline

df['p99_overhead_us'] = df['p99_Latency'] - baseline_p99_lookup(df)
df['guardrail_pass']  = df['p99_overhead_us'] <= GUARDRAIL_US
```

Flag any (N, T, B) combination that violates the guardrail.

---

## Phase 13 — CPU Bottleneck Regime (Days 22–28, Optional but Recommended)

This phase addresses the core research question: at what IOPS does the host CPU become
the bottleneck, and how much does the uncore reduce that bottleneck load?

### Step 13.1 — Create a "turbo" SSD config (`fast_ssd_turbo.cfg`)

Copy `fast_ssd.cfg` and reduce NAND latency to sub-microsecond:

```ini
; --- Turbo override: near-zero NAND latency ---
LSBRead      = 1000       ; 1 ns
MSBRead      = 1000       ; 1 ns
LSBProgram   = 1000
MSBProgram   = 1000
Erase        = 1000
WorkInterval = 1000       ; 1 ns (controller nearly always awake)
MaxRequestCount = 64
```

With these settings, `p50_Latency` drops to ~1 µs (pure PCIe + driver overhead), and
the CPU becomes the bottleneck at moderate QD.

Add `--ssd-cfg <path>` support to `driver_phase1.sh` if not already present, to allow
selecting the turbo config without overwriting the reference config.

### Step 13.2 — Find the CPU saturation point

Run a QD sweep with the turbo config at baseline (UncoreMode=0):

```bash
bash scripts/driver_phase1.sh --auto \
  --qd "1 2 4 8 16 32 64 128 256 512" --ios 4096 \
  --repeats 2 --steady-time 30 --uncore-mode 0 \
  --tag turbo_baseline_v1
```

Plot IOPS vs QD.  The saturation QD is where IOPS stops increasing — this is the CPU
bottleneck point.

### Step 13.3 — Measure uncore benefit at the bottleneck QD

```bash
SAT_QD=<saturation QD from step 13.2>
bash scripts/driver_phase1.sh --auto \
  --qd $SAT_QD --ios 4096 --repeats 5 --steady-time 60 \
  --uncore-mode 1 --cq-batch-n 8 --cq-batch-t 1000000 --db-batch-b 4 \
  --tag turbo_modeA_best_v1
```

At the CPU bottleneck, Mode A batching should free CPU cycles that were previously
wasted on per-CQE interrupt handling and empty polling, resulting in measurably higher
IOPS beyond the baseline saturation point.  This is the primary quantitative result of
the project.

---

## Verification Checklist

### Correctness

- [ ] `UncoreMode=0` run IOPS and latency are within ±2% of `baseline_v1`.
- [ ] `UncoreMode=1, CQBatchN=1, DBBatchB=1` is within ±2% of baseline (zero batching).
- [ ] No CQEs lost: `Completions == IOPS × STEADY_TIME` for all runs.
- [ ] No `panic:` in `gem5.out` for any mode.
- [ ] `PHASE1_RUNSCRIPT_DONE` always detected; driver always exits cleanly.
- [ ] Admin queue commands (SQ/CQ create, Identify) complete in < 1 ms regardless of
      `CQBatchN` (admin bypass in Gate 2 is working).
- [ ] `m5out/stats.txt` has `uncore.cqes_generated == uncore.cqes_published` at run end
      (no CQEs left in the staging buffer after shutdown drain).

### Performance

- [ ] At `CQBatchN=8, CQBatchT=4µs`: `p99_Latency` increase ≤ 5 µs vs baseline.
- [ ] `Scans_Per_Completion` decreases monotonically as N or T increases.
- [ ] `MMIO_Writes_Per_IO` decreases as `DBBatchB` increases.
- [ ] Mode B `HINT_HITS / (HINT_HITS + HINT_MISSES)` > 50% at QD ≥ 32.
- [ ] Turbo-SSD: Mode A achieves higher IOPS than baseline at the CPU saturation QD.

### Stats Integrity

- [ ] `getStatList` and `getStatValues` produce equal-length vectors.
- [ ] All 73 uncore stat entries appear in `m5out/stats.txt` when `UncoreMode ≠ 0`.
- [ ] `resetStatValues()` zeroes all uncore counters (verify by adding a post-reset
      check after a warm-start reset cycle if needed).

### SPDK Binary Compatibility

- [ ] Original `guest_spdk_nvme_perf` binary works without `SPDK_UNCORE_HINT` set.
- [ ] `guest_spdk_nvme_perf_mode_b` binary produces `HINT_HITS = 0` when gem5 runs
      with `UncoreMode=1` (hint register reads zero because nothing is batched
      differently from Mode B's perspective — regression guard).

---

## Dependency Graph

```
Phase 0  (baseline freeze)
    │
    ▼
Phase 1  (config.hh / config.cc / fast_ssd.cfg)
    │
    ▼
Phase 2  (controller.hh: enums, structs, members)
    │
    ▼
Phase 3  (controller.cc: constructor init, uncoreFlushEvent)
    │
    ├────────────────────┐
    ▼                    ▼
Phase 4               Phase 5
(Gate 1:            (Gate 2:
collectSQueue)       submit)
                         │
                         ▼
                     Phase 6
                     (Gate 3:
                  uncoreFlushCQBuffer)
                         │
                         ▼
                     Phase 7
                   (stats export)
                         │
                         ▼
                     Phase 8
                 (script integration)
                         │
               ┌─────────┴──────────┐
               ▼                    ▼
           Phase 9             Phase 10
      (gem5 hint reg      (SPDK hint path +
       in nvme_interface)    rebuild binary)
               │                    │
               └─────────┬──────────┘
                         ▼
                     Phase 11
              (full rebuild + verification)
                         │
                         ▼
                     Phase 12
                 (A/B experiment matrix)
                         │
                         ▼
                     Phase 13
              (CPU bottleneck regime)
```

Phases 4 and 5 can be developed independently (Gate 1 in collectSQueue, Gate 2 in
submit) and merged before Phase 6.

Phases 9 and 10 are also independent and can be developed in parallel in separate
branches; both must be complete before Phase 11 can verify the Mode B end-to-end path.

---

## Risk Register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Phase-bit flip seen by SPDK before hint is updated to non-zero | Low | Correctness: missed completion until next poll | Ensure `uncoreHintReady` is set to `lCQFIFO.size()` AFTER `pQueue->setData()` returns in `uncoreFlushCQBuffer`, not before |
| Double `schedule(completionEvent)` after flush | Medium | gem5 assertion failure / panic | Guard: check `isScheduled(completionEvent)` inside `reserveCompletion()` (already done by existing code — verify it handles re-entrant calls) |
| `getStatList` / `getStatValues` count mismatch after edit | Medium | `stats.txt` indexing crash | Add `assert(listSize == valuesSize)` in a debug build; both functions must have identical `if (mode != DISABLED)` guard |
| Shutdown deadlock: pending CQEs block `m5 exit` | Low | Simulation hangs indefinitely | Force-drain in `work()` shutdown path (Phase 6.3) + driver watchdog already exits after `GEM5_DEATH_TIMEOUT` |
| SPDK hint pointer arithmetic error | Medium | Mode B shows zero hits, no benefit observed | Print resolved pointer in `NVME_QPAIR_INFOLOG`; cross-reference with gem5.out BAR0 address map |
| Turbo config causes ICL/FTL queue growth to OOM | Low | gem5 host memory exhaustion | Monitor `gem5.out` for queue depth warnings; reduce `MaxRequestCount` if queues grow unbounded |
| Baseline `dbBatchB > 1` accidentally delays admin commands | Low | Admin timeout / NVMe initialization failure | Admin queue (sqID=0) is excluded from the Gate 1 threshold check (Phase 4.3 `adminHasWork` guard) |

---

*End of plan.*  
*All relative paths are from workspace root `/home/fangy6/SimpleSSD_Gem5_simulation`.*
