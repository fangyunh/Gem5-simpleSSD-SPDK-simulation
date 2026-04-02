# Mode B IO-Uncore Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement cooperative IO-Uncore Mode B with poll-lite completion and mailbox submission in the SimpleSSD + gem5 + SPDK simulation framework.

**Architecture:** Mode B is a strict superset of Mode A. It adds three mechanisms: (1) BAR0 registers for capability discovery, combined status, and per-queue mailboxes; (2) poll-lite completion where SPDK reads a hint register before touching DRAM CQ; (3) mailbox submission where SPDK writes compact 24B descriptors instead of full 64B SQEs. All changes are incremental — each layer is independently testable.

**Tech Stack:** SimpleSSD C++ (controller internals), SPDK C (NVMe PCIe transport), gem5 full-system simulator, bash scripts.

**Design Spec:** `docs/superpowers/specs/2026-04-02-mode-b-iouncore-design.md`

---

## Critical Pre-Requisite: BAR0 Size

The current BAR0 is only 8KB (0x2000 bytes) in `NVMe.py:100`. Our uncore registers start at offset 0x2000 and the mailbox region extends to ~0x2300. BAR0 must be enlarged **before any register work**. This is handled in Task 1.

## Worktree

All work happens in the worktree at `~/.config/superpowers/worktrees/SimpleSSD_Gem5_simulation/mode-b-iouncore` on branch `feature/mode-b-iouncore`.

---

## Layer 1: Registers and Capability Discovery

**Model: Opus**

### Task 1: Enlarge BAR0 and add uncore register routing in nvme_interface.cc

**Files:**
- Modify: `SimpleSSD-FullSystem/src/dev/storage/NVMe.py:100`
- Modify: `SimpleSSD-FullSystem/src/dev/storage/nvme_interface.cc:290-312` (read path), `332-361` (write path)
- Modify: `SimpleSSD-FullSystem/src/dev/storage/simplessd/hil/nvme/def.hh:103` (add UNCORE_REG_BEGIN constant)

Currently, `nvme_interface.cc` routes BAR0 accesses as:
- Offset `0x0000–0x0FFF` → `controller->readRegister()` / `controller->writeRegister()`
- Offset `0x1000+` (doorbell region) → `ringCQHeadDoorbell()` / `ringSQTailDoorbell()` for writes; zeroed for reads

We need a third routing region for uncore registers at `0x2000–0x2FFF`.

- [ ] **Step 1: Increase BAR0 size from 8KB to 16KB**

In `SimpleSSD-FullSystem/src/dev/storage/NVMe.py:100`:

```python
# Change from:
BAR0Size = '8192B'  # 8KB (512 queue pairs)
# To:
BAR0Size = '16384B'  # 16KB: 4KB ctrl regs + 4KB doorbells + 8KB uncore registers
```

- [ ] **Step 2: Add UNCORE_REG_BEGIN constant**

In `SimpleSSD-FullSystem/src/dev/storage/simplessd/hil/nvme/def.hh`, after `REG_DOORBELL_BEGIN = 0x1000` (line 103), add:

```cpp
  REG_DOORBELL_BEGIN = 0x1000,
  REG_UNCORE_BEGIN   = 0x2000   //!< Mode B IO-Uncore register region start
```

Note: this changes the last enum value from `REG_DOORBELL_BEGIN = 0x1000` (no comma) to having a comma. Verify the enum syntax.

- [ ] **Step 3: Add uncore register routing in nvme_interface.cc read path**

In `SimpleSSD-FullSystem/src/dev/storage/nvme_interface.cc`, the read handler at line 290 currently has:

```cpp
if (addr >= registerTableBaseAddress &&
    addr + size <= registerTableBaseAddress + registerTableSize) {
  int offset = addr - registerTableBaseAddress;

  if (offset >= SimpleSSD::HIL::NVMe::REG_DOORBELL_BEGIN) {
    // Read on doorbell register is vendor specific
    memset(buffer, 0, size);
  }
  else {
    pController->readRegister(offset, size, buffer, end);
  }
}
```

Change to:

```cpp
if (addr >= registerTableBaseAddress &&
    addr + size <= registerTableBaseAddress + registerTableSize) {
  int offset = addr - registerTableBaseAddress;

  if (offset >= SimpleSSD::HIL::NVMe::REG_UNCORE_BEGIN) {
    // IO-Uncore register region (Mode B)
    pController->readRegister(offset, size, buffer, end);
  }
  else if (offset >= SimpleSSD::HIL::NVMe::REG_DOORBELL_BEGIN) {
    // Read on doorbell register is vendor specific
    memset(buffer, 0, size);
  }
  else {
    pController->readRegister(offset, size, buffer, end);
  }
}
```

- [ ] **Step 4: Add uncore register routing in nvme_interface.cc write path**

In `SimpleSSD-FullSystem/src/dev/storage/nvme_interface.cc`, the write handler at line 332 currently has:

```cpp
if (addr >= registerTableBaseAddress &&
    addr + size <= registerTableBaseAddress + registerTableSize) {
  int offset = addr - registerTableBaseAddress;

  if (offset >= SimpleSSD::HIL::NVMe::REG_DOORBELL_BEGIN) {
    // ... doorbell dispatch ...
  }
  else {
    pController->writeRegister(offset, size, buffer, end);
  }
}
```

Change to:

```cpp
if (addr >= registerTableBaseAddress &&
    addr + size <= registerTableBaseAddress + registerTableSize) {
  int offset = addr - registerTableBaseAddress;

  if (offset >= SimpleSSD::HIL::NVMe::REG_UNCORE_BEGIN) {
    // IO-Uncore register region (Mode B) — mailbox writes
    pController->writeRegister(offset, size, buffer, end);
  }
  else if (offset >= SimpleSSD::HIL::NVMe::REG_DOORBELL_BEGIN) {
    // ... doorbell dispatch (unchanged) ...
  }
  else {
    pController->writeRegister(offset, size, buffer, end);
  }
}
```

- [ ] **Step 5: Commit**

```bash
git add SimpleSSD-FullSystem/src/dev/storage/NVMe.py \
        SimpleSSD-FullSystem/src/dev/storage/nvme_interface.cc \
        SimpleSSD-FullSystem/src/dev/storage/simplessd/hil/nvme/def.hh
git commit -m "Enlarge BAR0 to 16KB and route uncore register region"
```

---

### Task 2: Add UncoreCreditsMax config parameter

**Model: Opus**

**Files:**
- Modify: `SimpleSSD-FullSystem/src/dev/storage/simplessd/hil/nvme/config.hh:54-59` (enum + member)
- Modify: `SimpleSSD-FullSystem/src/dev/storage/simplessd/hil/nvme/config.cc:48-52` (name), `70-75` (default), `180-200` (parsing), `272-283` (readUint)
- Modify: `fast_ssd.cfg:130` (add parameter)

- [ ] **Step 1: Add config enum key**

In `config.hh`, change the enum at lines 54-59 from:

```cpp
  // --- I/O Uncore knobs ---
  NVME_UNCORE_MODE,        //!< UncoreMode: 0=disabled, 1=Mode A, 2=Mode B
  NVME_UNCORE_CQ_BATCH_N,  //!< CQBatchN: flush staging buffer after N CQEs
  NVME_UNCORE_CQ_BATCH_T,  //!< CQBatchT: flush timeout in picoseconds
  NVME_UNCORE_DB_BATCH_B   //!< DBBatchB: min SQEs visible before SQ collection
} NVME_CONFIG;
```

To:

```cpp
  // --- I/O Uncore knobs ---
  NVME_UNCORE_MODE,           //!< UncoreMode: 0=disabled, 1=Mode A, 2=Mode B
  NVME_UNCORE_CQ_BATCH_N,    //!< CQBatchN: flush staging buffer after N CQEs
  NVME_UNCORE_CQ_BATCH_T,    //!< CQBatchT: flush timeout in picoseconds
  NVME_UNCORE_DB_BATCH_B,    //!< DBBatchB: min SQEs visible before SQ collection
  NVME_UNCORE_CREDITS_MAX    //!< UncoreCreditsMax: SQ credit pool (Mode B)
} NVME_CONFIG;
```

- [ ] **Step 2: Add member variable**

In `config.hh`, after line 84 (`uint32_t uncoreDBBatchB;`), add:

```cpp
  uint32_t uncoreCreditsMax;  //!< Default: 64
```

- [ ] **Step 3: Add config name constant**

In `config.cc`, after line 52 (`const char NAME_UNCORE_DB_BATCH_B[]`), add:

```cpp
const char NAME_UNCORE_CREDITS_MAX[] = "UncoreCreditsMax";
```

- [ ] **Step 4: Set default value**

In `config.cc`, after line 75 (`uncoreDBBatchB = 4;`), add:

```cpp
  uncoreCreditsMax = 64;
```

- [ ] **Step 5: Add parsing in setConfig()**

In `config.cc`, after the `MATCH_NAME(NAME_UNCORE_DB_BATCH_B)` block (around line 200), before the `else { ret = false; }` block, add:

```cpp
  else if (MATCH_NAME(NAME_UNCORE_CREDITS_MAX)) {
    uncoreCreditsMax = (uint32_t)strtoul(value, nullptr, 10);
    if (uncoreCreditsMax == 0) {
      panic("UncoreCreditsMax must be >= 1");
    }
  }
```

- [ ] **Step 6: Add readUint case**

In `config.cc`, after the `NVME_UNCORE_DB_BATCH_B` case (line 283), add:

```cpp
    case NVME_UNCORE_CREDITS_MAX:
      ret = uncoreCreditsMax;
      break;
```

- [ ] **Step 7: Add parameter to fast_ssd.cfg**

In `fast_ssd.cfg`, after line 130 (`DBBatchB = 4`), add:

```ini
# UncoreCreditsMax: maximum in-flight compact SQEs before backpressure (Mode B)
UncoreCreditsMax = 64
```

- [ ] **Step 8: Commit**

```bash
git add SimpleSSD-FullSystem/src/dev/storage/simplessd/hil/nvme/config.hh \
        SimpleSSD-FullSystem/src/dev/storage/simplessd/hil/nvme/config.cc \
        fast_ssd.cfg
git commit -m "Add UncoreCreditsMax config parameter for Mode B credit pool"
```

---

### Task 3: Add Mode B register offsets, data structures, and status/capability register handlers

**Model: Opus**

**Files:**
- Modify: `SimpleSSD-FullSystem/src/dev/storage/simplessd/hil/nvme/controller.hh:37,55-60,72-83,158-178`
- Modify: `SimpleSSD-FullSystem/src/dev/storage/simplessd/hil/nvme/controller.cc:35-37,125-141,197-258`

- [ ] **Step 1: Replace UNCORE_HINT_REG_OFFSET with register map constants**

In `controller.cc`, replace lines 35-37:

```cpp
// BAR0 byte offset of the Mode B I/O Uncore readiness hint register.
// The NVMe doorbell region is at 0x1000+; 0x2000 is past any doorbell entry.
#define UNCORE_HINT_REG_OFFSET  0x2000
```

With:

```cpp
// BAR0 byte offsets for Mode B IO-Uncore registers.
// The NVMe doorbell region is at 0x1000–0x1FFF; uncore starts at 0x2000.
#define UNCORE_STATUS_OFFSET      0x2000  // 8B RO: [63:32]=CQ hint, [31:0]=SQ credits
#define UNCORE_CAP_OFFSET         0x2008  // 4B RO: 0=none, 1=Mode A, 2=Mode B
#define UNCORE_CREDITS_MAX_OFFSET 0x2010  // 4B RO: max credit pool size
#define UNCORE_MAILBOX_BASE       0x2100  // WO: per-queue 24B compact SQE mailbox
#define UNCORE_MAILBOX_STRIDE     32      // bytes between queue mailbox slots
```

- [ ] **Step 2: Add UncoreCreditsMax to UncoreConfig struct**

In `controller.hh`, change the UncoreConfig struct (lines 55-60) from:

```cpp
struct UncoreConfig {
  UncoreMode mode     = UNCORE_MODE_DISABLED;
  uint32_t   cqBatchN = 8;        //!< Flush staging buffer when N CQEs pending
  uint64_t   cqBatchT = 4000000;  //!< Flush timeout in picoseconds
  uint32_t   dbBatchB = 4;        //!< Min SQEs visible before SQ collection
};
```

To:

```cpp
struct UncoreConfig {
  UncoreMode mode       = UNCORE_MODE_DISABLED;
  uint32_t   cqBatchN   = 8;        //!< Flush staging buffer when N CQEs pending
  uint64_t   cqBatchT   = 4000000;  //!< Flush timeout in picoseconds
  uint32_t   dbBatchB   = 4;        //!< Min SQEs visible before SQ collection
  uint32_t   creditsMax = 64;       //!< Mode B: max in-flight compact SQEs
};
```

- [ ] **Step 3: Add Mode B fields to UncoreStats**

In `controller.hh`, extend the UncoreStats struct (lines 72-83) to add Mode B counters after line 82:

```cpp
struct UncoreStats {
  // --- Mode A counters (existing) ---
  uint64_t sqesVisible       = 0;
  uint64_t collectDeferred   = 0;
  uint64_t collectAllowed    = 0;
  uint64_t cqesGenerated     = 0;
  uint64_t cqesAdminBypassed = 0;
  uint64_t cqesPublished     = 0;
  uint64_t flushByCount      = 0;
  uint64_t flushByTimeout    = 0;
  uint64_t flushByShutdown   = 0;
  uint64_t flushDepthHist[64] = {};

  // --- Mode B counters ---
  // Metric 1: Mailbox submissions
  uint64_t mailboxSubmissions  = 0;  //!< Compact SQEs received via mailbox
  uint64_t standardSubmissions = 0;  //!< SQEs received via DRAM SQ DMA

  // Metric 2: PRP expansions
  uint64_t prpSimpleExpansions = 0;  //!< PRP1/PRP2 only (transfer <= 8KB)
  uint64_t prpListExpansions   = 0;  //!< Full PRP list built (transfer > 8KB)

  // Metric 3: Credit stalls
  uint64_t creditStalls = 0;         //!< Status reads where credits == 0

  // Metric 4: Hint register reads
  uint64_t hintReadsTotal    = 0;    //!< Total UNCORE_STATUS reads
  uint64_t hintReadsEmpty    = 0;    //!< Reads with CQ hint == 0
  uint64_t hintReadsNonEmpty = 0;    //!< Reads with CQ hint > 0

  // Metric 5: Submission batching efficiency
  uint64_t mailboxBurstTotal    = 0;   //!< Total mailbox submission bursts
  uint64_t mailboxBurstSqeTotal = 0;   //!< Total SQEs across all bursts
  uint64_t mailboxBurstHist[64] = {};  //!< Histogram: SQEs per burst

  // Metric 6: Per-I/O cycle breakdown (running sums for averaging)
  uint64_t tsSubmitLatencySum      = 0;  //!< Sum of (T_submit_exit - T_submit_enter)
  uint64_t tsBackendLatencySum     = 0;  //!< Sum of (T_io_complete - T_submit_exit)
  uint64_t tsCompletionLatencySum  = 0;  //!< Sum of (T_cqe_visible - T_io_complete)
  uint64_t tsTotalLatencySum       = 0;  //!< Sum of (T_cqe_visible - T_submit_enter)
  uint64_t tsIoCount               = 0;  //!< Number of I/Os with valid timestamps
};
```

- [ ] **Step 4: Add Mode B member variables to Controller class**

In `controller.hh`, after the existing uncore member variables (after line 178, `Event uncoreFlushEvent;`), add:

```cpp
  // --- Mode B: mailbox and credit state ---

  //! SQ credit counter — decremented on mailbox ingestion, replenished on CQE.
  uint32_t uncoreCredits;

  //! Per-queue mailbox staging latch: accumulates 3×8B writes into 24B.
  struct MailboxLatch {
    uint8_t  data[24];     //!< Accumulated compact SQE bytes
    uint8_t  writeCount;   //!< How many 8B writes received (0, 1, 2, or 3)
    MailboxLatch() : writeCount(0) { memset(data, 0, sizeof(data)); }
    void reset() { writeCount = 0; memset(data, 0, sizeof(data)); }
  };
  std::vector<MailboxLatch> uncoreMailboxLatches;  //!< One per I/O queue (sized to sqsize)

  //! Per-queue command ID counter for mailbox-submitted commands.
  std::vector<uint16_t> uncoreMailboxCid;

  //! Burst tracking: counts consecutive mailbox writes between status reads.
  uint32_t uncoreCurrentBurst;
  uint16_t uncoreLastMailboxQid;  //!< Queue of last mailbox write (-1 = none)

  //! Per-command timestamps for Metric 6.
  struct UncoreTimestamp {
    uint64_t submitEnter  = 0;  //!< T_submit_enter
    uint64_t submitExit   = 0;  //!< T_submit_exit
    uint64_t ioComplete   = 0;  //!< T_io_complete
    uint64_t cqeVisible   = 0;  //!< T_cqe_visible
  };
  //! Flat array indexed by (qid * max_cid + cid). Sized in constructor.
  std::vector<UncoreTimestamp> uncoreTimestamps;

  //! Controller-internal PRP list storage for mailbox-expanded SQEs.
  //! Each entry holds a PRP list for one in-flight command.
  std::vector<std::vector<uint64_t>> uncorePrpLists;
```

- [ ] **Step 5: Initialize Mode B state in constructor**

In `controller.cc`, after line 136 (`uncoreFlushEvent = allocate(...);`), add:

```cpp
  // --- Mode B initialization ---
  uncoreCfg.creditsMax = (uint32_t)conf.readUint(CONFIG_NVME, NVME_UNCORE_CREDITS_MAX);
  uncoreCredits = uncoreCfg.creditsMax;
  uncoreMailboxLatches.resize(sqsize);
  uncoreMailboxCid.assign(sqsize, 0);
  uncoreCurrentBurst = 0;
  uncoreLastMailboxQid = 0xFFFF;
  // Timestamp tracking: sized for max concurrent commands per queue
  uncoreTimestamps.resize(sqsize * uncoreCfg.creditsMax);
  uncorePrpLists.resize(sqsize * uncoreCfg.creditsMax);
```

- [ ] **Step 6: Add read handler for uncore registers**

In `controller.cc`, in the `readRegister()` function (lines 197-258), the current code does `memcpy(buffer, registers.data + offset, size)` at line 202, then a switch on offset. The problem is that `registers.data` is only 64 bytes — offsets >= 0x2000 would be out of bounds.

Add a guard **before** line 202. Replace the beginning of `readRegister()`:

```cpp
void Controller::readRegister(uint64_t offset, uint64_t size, uint8_t *buffer,
                              uint64_t &) {
  // Handle IO-Uncore register reads (offset >= 0x2000)
  if (offset >= UNCORE_STATUS_OFFSET) {
    memset(buffer, 0, size);

    if (offset == UNCORE_STATUS_OFFSET && size == 8) {
      // UNCORE_STATUS: [63:32] = CQ hint, [31:0] = SQ credits
      uint64_t status = ((uint64_t)uncoreHintReady << 32) | (uint64_t)uncoreCredits;
      memcpy(buffer, &status, 8);

      uncoreStats.hintReadsTotal++;
      if (uncoreHintReady == 0) {
        uncoreStats.hintReadsEmpty++;
      } else {
        uncoreStats.hintReadsNonEmpty++;
      }
      if (uncoreCredits == 0) {
        uncoreStats.creditStalls++;
      }

      // A status read ends any ongoing mailbox burst
      if (uncoreCurrentBurst > 0) {
        uncoreStats.mailboxBurstTotal++;
        uncoreStats.mailboxBurstSqeTotal += uncoreCurrentBurst;
        uncoreStats.mailboxBurstHist[
            (uncoreCurrentBurst < 64) ? uncoreCurrentBurst : 63]++;
        uncoreCurrentBurst = 0;
      }

      debugprint(LOG_HIL_NVME,
                 "UNCORE  | READ  | STATUS credits=%u hint=%u",
                 uncoreCredits, uncoreHintReady);
    }
    else if (offset == UNCORE_CAP_OFFSET && size == 4) {
      uint32_t cap = (uint32_t)uncoreCfg.mode;
      memcpy(buffer, &cap, 4);
      debugprint(LOG_HIL_NVME, "UNCORE  | READ  | CAP mode=%u", cap);
    }
    else if (offset == UNCORE_CREDITS_MAX_OFFSET && size == 4) {
      uint32_t cm = uncoreCfg.creditsMax;
      memcpy(buffer, &cm, 4);
      debugprint(LOG_HIL_NVME, "UNCORE  | READ  | CREDITS_MAX %u", cm);
    }
    else {
      debugprint(LOG_HIL_NVME,
                 "UNCORE  | READ  | unknown offset=0x%" PRIx64 " size=%" PRIu64,
                 offset, size);
    }
    return;
  }

  // --- Standard NVMe register reads (original code below) ---
  registers.interruptMaskSet = interruptMask;
  registers.interruptMaskClear = interruptMask;

  memcpy(buffer, registers.data + offset, size);
  // ... rest of existing switch statement ...
```

- [ ] **Step 7: Verify baseline still works**

Build gem5 and run a quick smoke test with `UncoreMode=0` to confirm the BAR0 enlargement doesn't break baseline:

```bash
cd SimpleSSD-FullSystem && scons build/X86/gem5.opt -j$(nproc)
```

Then run:
```bash
./scripts/driver_phase1.sh --auto --uncore-mode 0 --qd "16" --ios "4096" --repeats 1 --steady-time 10 --tag mode_b_baseline_check
```

Expected: simulation completes, baseline IOPS match prior runs.

- [ ] **Step 8: Commit**

```bash
git add SimpleSSD-FullSystem/src/dev/storage/simplessd/hil/nvme/controller.hh \
        SimpleSSD-FullSystem/src/dev/storage/simplessd/hil/nvme/controller.cc
git commit -m "Add Mode B register map, data structures, and read handlers for status/cap/credits"
```

---

### Task 4: Add capability probe in SPDK controller init

**Model: Opus**

**Files:**
- Modify: `spdk/lib/nvme/nvme_pcie_internal.h:28-78` (add fields to nvme_pcie_ctrlr)
- Modify: `spdk/lib/nvme/nvme_pcie.c:911-1001` (probe in construct)

- [ ] **Step 1: Add uncore fields and defines to nvme_pcie_internal.h**

In `spdk/lib/nvme/nvme_pcie_internal.h`, before the closing `};` of `struct nvme_pcie_ctrlr` (line 78), add:

```c
	/* IO-Uncore Mode B support */
	bool iouncore_mode_b;           /* true if controller advertises Mode B */
	uint32_t iouncore_credits_max;  /* max SQ credits (from UNCORE_CREDITS_MAX reg) */
```

Also, after the `#define NVME_PCIE_MIN_ADMIN_QUEUE_SIZE` (line 25), add the register offset defines:

```c
/* IO-Uncore BAR0 register offsets */
#define IOUNCORE_STATUS_OFFSET      0x2000
#define IOUNCORE_CAP_OFFSET         0x2008
#define IOUNCORE_CREDITS_MAX_OFFSET 0x2010
#define IOUNCORE_MAILBOX_BASE       0x2100
#define IOUNCORE_MAILBOX_STRIDE     32
```

- [ ] **Step 2: Add capability probe in nvme_pcie_ctrlr_construct**

In `spdk/lib/nvme/nvme_pcie.c`, in `nvme_pcie_ctrlr_construct()`, after the BAR allocation succeeds (`nvme_pcie_ctrlr_allocate_bars`, around line 959) and before `return &pctrlr->ctrlr;` (line 1001), add:

```c
	/* Probe IO-Uncore capability */
	pctrlr->iouncore_mode_b = false;
	pctrlr->iouncore_credits_max = 0;
	{
		volatile uint32_t *cap_reg = (volatile uint32_t *)
			((uintptr_t)pctrlr->regs + IOUNCORE_CAP_OFFSET);
		uint32_t cap_val = *cap_reg;

		if (cap_val == 2) {
			volatile uint32_t *credits_reg = (volatile uint32_t *)
				((uintptr_t)pctrlr->regs + IOUNCORE_CREDITS_MAX_OFFSET);
			pctrlr->iouncore_mode_b = true;
			pctrlr->iouncore_credits_max = *credits_reg;
			SPDK_NOTICELOG("IO-Uncore Mode B detected: credits_max=%u\n",
				       pctrlr->iouncore_credits_max);
		} else {
			SPDK_NOTICELOG("IO-Uncore capability=%u (Mode B not active)\n", cap_val);
		}
	}
```

- [ ] **Step 3: Verify probe works with Mode A and baseline**

Build SPDK in docker, bake into disk image, run with `--uncore-mode 1`. Check `gem5.out` for the `IO-Uncore capability=1 (Mode B not active)` log line. Then run with `--uncore-mode 2` and check for `IO-Uncore Mode B detected: credits_max=64`.

- [ ] **Step 4: Commit**

```bash
git add spdk/lib/nvme/nvme_pcie_internal.h spdk/lib/nvme/nvme_pcie.c
git commit -m "Add IO-Uncore capability probe in SPDK controller init"
```

---

## Layer 2: Poll-Lite Completion

**Model: Opus**

### Task 5: Wire uncoreHintReady into UNCORE_STATUS and add poll-lite in SPDK

**Files:**
- Modify: `spdk/lib/nvme/nvme_pcie_common.c:893-970` (process_completions)
- Modify: `SimpleSSD-FullSystem/src/dev/storage/simplessd/hil/nvme/controller.cc` (completion() function, ~line 1851 where uncoreHintReady is updated)

The UNCORE_STATUS read handler was already added in Task 3 Step 6. The `uncoreHintReady` is already maintained by Mode A's `uncoreFlushCQBuffer()` at line 1990. We just need the SPDK side.

- [ ] **Step 1: Add poll-lite early return in process_completions**

In `spdk/lib/nvme/nvme_pcie_common.c`, in `nvme_pcie_qpair_process_completions()` (line 894), after the `poll_start = nvme_io_cycle_rdtsc();` at line 913, and after the `NVME_QPAIR_CONNECTING` check block (ends around line 938), but **before** the admin queue lock at line 940, add:

```c
	/* IO-Uncore Mode B: poll-lite — check hint before touching DRAM CQ */
	if (!nvme_qpair_is_admin_queue(qpair)) {
		struct nvme_pcie_ctrlr *pctrlr = nvme_pcie_ctrlr(ctrlr);
		if (pctrlr->iouncore_mode_b) {
			volatile uint64_t *status_reg = (volatile uint64_t *)
				((uintptr_t)pctrlr->regs + IOUNCORE_STATUS_OFFSET);
			uint64_t status_val = *status_reg;
			uint32_t cq_ready = (uint32_t)(status_val >> 32);

			if (cq_ready == 0) {
				/* No completions pending — skip DRAM CQ entirely */
				return 0;
			}
			/* Fall through: completions available, drain normally */
		}
	}
```

Note: Admin queue bypasses poll-lite (it uses the standard path) because admin CQEs bypass the staging buffer in Mode A/B.

- [ ] **Step 2: Verify hint updates on CQE DMA completion**

In `controller.cc`, find the `completion()` function (around line 1819). Verify that `uncoreHintReady` is decremented as CQEs are drained from `lCQFIFO` to host memory. The existing code at approximately line 1851 should already have:

```cpp
uncoreHintReady = (uint32_t)lCQFIFO.size();
```

If this line exists and executes after each CQE DMA write, no changes needed. If not present in the completion DMA callback path, add it.

- [ ] **Step 3: Build and test poll-lite**

Build gem5 + SPDK. Run with `--uncore-mode 2`:

```bash
./scripts/driver_phase1.sh --auto --uncore-mode 2 --qd "16" --ios "4096" --repeats 1 --steady-time 10 --tag mode_b_polllite
```

Expected: simulation completes. In stats output, `hintReadsTotal` > 0, `hintReadsEmpty` > 0 (shows polls were eliminated), IOPS should be comparable or slightly better than Mode A.

- [ ] **Step 4: Commit**

```bash
git add spdk/lib/nvme/nvme_pcie_common.c \
        SimpleSSD-FullSystem/src/dev/storage/simplessd/hil/nvme/controller.cc
git commit -m "Add poll-lite completion: SPDK checks hint register before CQ drain"
```

---

## Layer 3: Mailbox Submission

**Model: Opus**

### Task 6: Add mailbox write handler in SimpleSSD controller

**Files:**
- Modify: `SimpleSSD-FullSystem/src/dev/storage/simplessd/hil/nvme/controller.cc:260-462` (writeRegister), and add new private method

This is the most complex task. The mailbox write handler accumulates 3×8B MMIO writes per compact SQE, then expands to a full 64B NVMe SQE and injects it into the processing pipeline.

- [ ] **Step 1: Add mailbox write handler in writeRegister()**

In `controller.cc`, in `writeRegister()` (starts at line 260), add a guard at the beginning of the function, before the existing `if (size == 4)` block. After the existing `uint64_t uiTemp64;` variable declaration, add:

```cpp
  // Handle IO-Uncore mailbox writes (offset >= 0x2100)
  if (offset >= UNCORE_MAILBOX_BASE && uncoreCfg.mode == UNCORE_MODE_B) {
    uint32_t mailboxOffset = offset - UNCORE_MAILBOX_BASE;
    uint16_t qid = mailboxOffset / UNCORE_MAILBOX_STRIDE;
    uint32_t byteOffset = mailboxOffset % UNCORE_MAILBOX_STRIDE;

    if (qid == 0 || qid >= sqsize || byteOffset + size > 24) {
      debugprint(LOG_HIL_NVME,
                 "UNCORE  | WRITE | MAILBOX bad qid=%u byteOff=%u size=%" PRIu64,
                 qid, byteOffset, size);
      return;
    }

    MailboxLatch &latch = uncoreMailboxLatches[qid];
    memcpy(latch.data + byteOffset, buffer, size);
    latch.writeCount++;

    if (latch.writeCount >= 3) {
      uncoreIngestMailbox(qid, latch);
      latch.reset();
    }
    return;
  }
```

- [ ] **Step 2: Add uncoreIngestMailbox() method declaration**

In `controller.hh`, in the private section (before `bool checkQueue(...)` at line 180), add:

```cpp
  //! Ingest a complete 24B compact SQE from the Mode B mailbox.
  void uncoreIngestMailbox(uint16_t qid, const MailboxLatch &latch);
```

- [ ] **Step 3: Implement uncoreIngestMailbox() with PRP expansion**

In `controller.cc`, add a new function before `uncoreFlushCQBuffer()` (before line 1940):

```cpp
// ---------------------------------------------------------------------------
// I/O Uncore: Mode B mailbox ingestion
// ---------------------------------------------------------------------------

void Controller::uncoreIngestMailbox(uint16_t qid, const MailboxLatch &latch) {
  // Parse compact SQE (24 bytes)
  uint8_t  opcode    = latch.data[0];
  uint8_t  flags     = latch.data[1];
  uint16_t nsid16;   memcpy(&nsid16,   latch.data + 2,  2);
  uint64_t lba;      memcpy(&lba,      latch.data + 4,  8);
  uint16_t nlb;      memcpy(&nlb,      latch.data + 12, 2);
  uint16_t qpairId;  memcpy(&qpairId,  latch.data + 14, 2);
  uint64_t bufAddr;  memcpy(&bufAddr,  latch.data + 16, 8);

  // Record T_submit_enter
  uint64_t now = getTick();

  // Assign command ID
  uint16_t cid = uncoreMailboxCid[qid]++;
  if (uncoreMailboxCid[qid] >= uncoreCfg.creditsMax) {
    uncoreMailboxCid[qid] = 0;
  }

  // Record timestamp
  uint32_t tsIdx = qid * uncoreCfg.creditsMax + cid;
  if (tsIdx < uncoreTimestamps.size()) {
    uncoreTimestamps[tsIdx] = UncoreTimestamp{};
    uncoreTimestamps[tsIdx].submitEnter = now;
  }

  // Build full 64B NVMe SQE
  SQEntry sqe = {};
  sqe.dword0.opcode = opcode;
  sqe.dword0.fuse   = (flags >> 0) & 0x3;
  sqe.dword0.cid    = cid;
  sqe.namespaceID   = (uint32_t)nsid16;

  // LBA goes into CDW10/CDW11
  sqe.dword10 = (uint32_t)(lba & 0xFFFFFFFF);
  sqe.dword11 = (uint32_t)(lba >> 32);
  // NLB goes into CDW12 (lower 16 bits)
  sqe.dword12 = (uint32_t)nlb;

  // PRP expansion
  uint64_t lbaSize = 512;  // TODO: read from namespace config if needed
  uint64_t transferSize = (uint64_t)(nlb + 1) * lbaSize;
  uint64_t pageSize = 4096;

  if (transferSize <= pageSize) {
    sqe.data1 = bufAddr;      // PRP1
    sqe.data2 = 0;            // PRP2 unused
    uncoreStats.prpSimpleExpansions++;
  }
  else if (transferSize <= 2 * pageSize) {
    sqe.data1 = bufAddr;
    sqe.data2 = bufAddr + pageSize;
    uncoreStats.prpSimpleExpansions++;
  }
  else {
    // Full PRP list
    sqe.data1 = bufAddr;  // PRP1 = first page
    uint32_t numPrpEntries = (uint32_t)((transferSize - pageSize + pageSize - 1) / pageSize);
    auto &prpList = uncorePrpLists[tsIdx];
    prpList.resize(numPrpEntries);
    for (uint32_t i = 0; i < numPrpEntries; i++) {
      prpList[i] = bufAddr + (uint64_t)(i + 1) * pageSize;
    }
    // PRP2 points to the PRP list in controller-internal memory
    // For SimpleSSD simulation, we store the list and reference it by index
    sqe.data2 = (uint64_t)(uintptr_t)prpList.data();
    uncoreStats.prpListExpansions++;
  }

  // Record T_submit_exit
  if (tsIdx < uncoreTimestamps.size()) {
    uncoreTimestamps[tsIdx].submitExit = getTick();
  }

  // Decrement credit
  if (uncoreCredits > 0) {
    uncoreCredits--;
  }

  // Update burst tracking
  if (uncoreLastMailboxQid == qid) {
    uncoreCurrentBurst++;
  } else {
    // Different queue — end previous burst if any
    if (uncoreCurrentBurst > 0) {
      uncoreStats.mailboxBurstTotal++;
      uncoreStats.mailboxBurstSqeTotal += uncoreCurrentBurst;
      uncoreStats.mailboxBurstHist[
          (uncoreCurrentBurst < 64) ? uncoreCurrentBurst : 63]++;
    }
    uncoreCurrentBurst = 1;
    uncoreLastMailboxQid = qid;
  }

  uncoreStats.mailboxSubmissions++;

  debugprint(LOG_HIL_NVME,
             "UNCORE  | MAILBOX | qid=%u cid=%u opc=0x%02x lba=%" PRIu64
             " nlb=%u buf=0x%" PRIx64 " xfer=%" PRIu64,
             qid, cid, opcode, lba, nlb, bufAddr, transferSize);

  // Inject SQE into lSQFIFO — the same FIFO that checkQueue's DMA callback
  // (doRead lambda in checkQueue(), controller.cc:1714) pushes into after
  // reading an SQE from host DRAM. This bypasses the DMA read entirely.
  if (ppSQueue[qid]) {
    uint16_t cqID = ppSQueue[qid]->getCQID();
    uint16_t sqHead = ppSQueue[qid]->getHead();
    lSQFIFO.push_back(SQEntryWrapper(sqe, qid, cqID, sqHead, sqHead));

    // Trigger the controller work loop to process the SQE
    work();
  }
}
```

**Important note for the implementer:** The SQE injection pushes directly into `lSQFIFO` (a `std::list<SQEntryWrapper>`) — the same FIFO that `checkQueue()` uses after its DMA read callback (see `controller.cc:1714`). The `SQEntryWrapper` constructor takes `(SQEntry, sqID, cqID, sqHead, sqUID)`. After pushing, call `work()` to trigger the controller's work loop. Also verify that `lSQFIFO` is accessible (it's a private member of Controller) — since `uncoreIngestMailbox` is a Controller method, this is fine.

- [ ] **Step 4: Add credit replenishment on CQE generation**

In `controller.cc`, in the `submit()` function (around line 1745, the Gate 2 block), add credit replenishment when a CQE is generated in Mode B. Before the `uncorePendingCQE.emplace_back(entry, entry.submitAt);` line (approximately line 1749), add:

```cpp
    // Mode B: replenish one SQ credit and record T_io_complete
    if (uncoreCfg.mode == UNCORE_MODE_B) {
      uncoreCredits++;

      // Record T_io_complete timestamp
      uint16_t cqeCid = entry.entry.dword3.commandID;
      uint16_t cqeQid = entry.sqID;  // SQ that originated this I/O
      uint32_t tsIdx = cqeQid * uncoreCfg.creditsMax + cqeCid;
      if (tsIdx < uncoreTimestamps.size() &&
          uncoreTimestamps[tsIdx].submitEnter != 0) {
        uncoreTimestamps[tsIdx].ioComplete = getTick();
      }
    }
```

- [ ] **Step 5: Record T_cqe_visible in uncoreFlushCQBuffer**

In `controller.cc`, in `uncoreFlushCQBuffer()` (line 1943), inside the loop that moves CQEs to `lCQFIFO` (around line 1970-1979), after `lCQFIFO.insert(iter, entry);`, add timestamp recording:

```cpp
    // Record T_cqe_visible for Metric 6
    if (uncoreCfg.mode == UNCORE_MODE_B) {
      uint16_t cqeCid = entry.entry.dword3.commandID;
      uint16_t cqeQid = entry.sqID;
      uint32_t tsIdx = cqeQid * uncoreCfg.creditsMax + cqeCid;
      if (tsIdx < uncoreTimestamps.size() &&
          uncoreTimestamps[tsIdx].submitEnter != 0) {
        auto &ts = uncoreTimestamps[tsIdx];
        ts.cqeVisible = getTick();
        // Accumulate into running sums
        uncoreStats.tsSubmitLatencySum +=
            (ts.submitExit - ts.submitEnter);
        uncoreStats.tsBackendLatencySum +=
            (ts.ioComplete - ts.submitExit);
        uncoreStats.tsCompletionLatencySum +=
            (ts.cqeVisible - ts.ioComplete);
        uncoreStats.tsTotalLatencySum +=
            (ts.cqeVisible - ts.submitEnter);
        uncoreStats.tsIoCount++;
        // Reset for reuse
        ts = UncoreTimestamp{};
      }
    }
```

- [ ] **Step 6: Track standardSubmissions in collectSQueue**

In `controller.cc`, in `collectSQueue()` (line 1417), after the Gate 1 pass-through at line 1440 (`uncoreStats.collectAllowed++`), add:

```cpp
    // Count standard submissions for Metric 1
    uncoreStats.standardSubmissions += totalIOVisible;
```

- [ ] **Step 7: Commit**

```bash
git add SimpleSSD-FullSystem/src/dev/storage/simplessd/hil/nvme/controller.hh \
        SimpleSSD-FullSystem/src/dev/storage/simplessd/hil/nvme/controller.cc
git commit -m "Add mailbox write handler with PRP expansion and credit flow control"
```

---

### Task 7: Add mailbox submission path in SPDK

**Model: Opus**

**Files:**
- Modify: `spdk/lib/nvme/nvme_pcie_internal.h` (add compact SQE struct)
- Modify: `spdk/lib/nvme/nvme_pcie_common.c:1735-1822` (submit_request)

- [ ] **Step 1: Add compact SQE struct to nvme_pcie_internal.h**

In `spdk/lib/nvme/nvme_pcie_internal.h`, after the IO-Uncore register offset defines added in Task 4, add:

```c
/* IO-Uncore compact SQE (24 bytes) for Mode B mailbox submission */
struct iouncore_compact_sqe {
	uint8_t  opcode;       /* NVMe opcode */
	uint8_t  flags;        /* fuse + SGL flags */
	uint16_t nsid;         /* namespace ID (truncated to 16-bit) */
	uint64_t lba;          /* starting LBA */
	uint16_t nlb;          /* number of logical blocks (NLB) */
	uint16_t qpair_id;    /* which SQ this targets */
	uint64_t buffer_addr;  /* DMA buffer physical address */
} __attribute__((packed));
```

- [ ] **Step 2: Add mailbox submission path in submit_request**

In `spdk/lib/nvme/nvme_pcie_common.c`, in `nvme_pcie_qpair_submit_request()` (line 1736), after the tracker allocation and setup (after `req->cmd.psdt = SPDK_NVME_PSDT_PRP;` at line 1770), but **before** the payload building block (`if (req->payload_size != 0)` at line 1772), add the Mode B mailbox path:

```c
	/* IO-Uncore Mode B: submit via compact mailbox instead of DRAM SQ */
	{
		struct nvme_pcie_ctrlr *pctrlr = nvme_pcie_ctrlr(ctrlr);
		if (pctrlr->iouncore_mode_b && !nvme_qpair_is_admin_queue(qpair)) {
			/* Check credits via status register */
			volatile uint64_t *status_reg = (volatile uint64_t *)
				((uintptr_t)pctrlr->regs + IOUNCORE_STATUS_OFFSET);
			uint64_t status_val = *status_reg;
			uint32_t sq_credits = (uint32_t)(status_val & 0xFFFFFFFF);

			if (sq_credits == 0) {
				/* Backpressure — return tracker, let caller retry */
				TAILQ_REMOVE(&pqpair->outstanding_tr, tr, tq_list);
				pqpair->qpair.queue_depth--;
				TAILQ_INSERT_HEAD(&pqpair->free_tr, tr, tq_list);
				tr->req = NULL;
				pqpair->stat->queued_requests++;
				rc = -EAGAIN;
				goto exit;
			}

			/* Build compact SQE from NVMe command */
			struct iouncore_compact_sqe compact;
			compact.opcode = req->cmd.opc;
			compact.flags  = (req->cmd.fuse & 0x3);
			compact.nsid   = (uint16_t)(req->cmd.nsid & 0xFFFF);
			compact.lba    = ((uint64_t)req->cmd.cdw11 << 32) | req->cmd.cdw10;
			compact.nlb    = (uint16_t)(req->cmd.cdw12 & 0xFFFF);
			compact.qpair_id = qpair->id;

			/* Get physical address of the DMA buffer */
			if (req->payload_size != 0 && req->payload.contig_or_cb_arg != NULL) {
				compact.buffer_addr = spdk_vtophys(
					req->payload.contig_or_cb_arg + req->payload_offset,
					NULL);
			} else {
				compact.buffer_addr = 0;
			}

			/* Write 24B to per-queue mailbox via 3×8B MMIO writes */
			uint64_t mailbox_base = IOUNCORE_MAILBOX_BASE +
				(uint64_t)qpair->id * IOUNCORE_MAILBOX_STRIDE;
			volatile uint64_t *mb0 = (volatile uint64_t *)
				((uintptr_t)pctrlr->regs + mailbox_base);
			volatile uint64_t *mb1 = (volatile uint64_t *)
				((uintptr_t)pctrlr->regs + mailbox_base + 8);
			volatile uint64_t *mb2 = (volatile uint64_t *)
				((uintptr_t)pctrlr->regs + mailbox_base + 16);

			uint64_t w0, w1, w2;
			memcpy(&w0, (uint8_t *)&compact + 0, 8);
			memcpy(&w1, (uint8_t *)&compact + 8, 8);
			memcpy(&w2, (uint8_t *)&compact + 16, 8);
			*mb0 = w0;
			*mb1 = w1;
			*mb2 = w2;

			req->t_sqe_copy = nvme_io_cycle_rdtsc();
			req->t_cmd_end = req->t_sqe_copy;
			req->t_doorbell = req->t_sqe_copy;

			/* Skip normal DRAM SQ copy + doorbell — go directly to exit */
			rc = 0;
			goto exit;
		}
	}
```

- [ ] **Step 3: Build and test full Mode B (poll-lite + mailbox)**

Build gem5 + SPDK. Run:

```bash
./scripts/driver_phase1.sh --auto --uncore-mode 2 --qd "16" --ios "4096" --repeats 1 --steady-time 10 --tag mode_b_full
```

Expected: simulation completes. Stats show `mailboxSubmissions > 0`, `standardSubmissions == 0` (for I/O queues), `hintReadsTotal > 0`. IOPS should match or exceed Mode A.

- [ ] **Step 4: Commit**

```bash
git add spdk/lib/nvme/nvme_pcie_internal.h spdk/lib/nvme/nvme_pcie_common.c
git commit -m "Add SPDK mailbox submission path for Mode B compact SQEs"
```

---

## Layer 4: Cycle Breakdown Telemetry

**Model: Sonnet**

### Task 8: Export all Mode B metrics via getStatList/getStatValues

**Files:**
- Modify: `SimpleSSD-FullSystem/src/dev/storage/simplessd/hil/nvme/controller.cc:1998-2034`

The counters and timestamps are already being accumulated by Tasks 3, 5, 6. This task wires them into the stat export.

- [ ] **Step 1: Extend getStatList() for Mode B metrics**

In `controller.cc`, in `getStatList()` (line 1998), after the existing Mode A stat descriptors (before the closing `}`), add Mode B descriptors when mode is Mode B:

```cpp
    if (uncoreCfg.mode == UNCORE_MODE_B) {
      // Metric 1: Mailbox submissions
      list.push_back({prefix + "uncore.mailbox_submissions", "count"});
      list.push_back({prefix + "uncore.standard_submissions", "count"});
      // Metric 2: PRP expansions
      list.push_back({prefix + "uncore.prp_simple_expansions", "count"});
      list.push_back({prefix + "uncore.prp_list_expansions", "count"});
      // Metric 3: Credit stalls
      list.push_back({prefix + "uncore.credit_stalls", "count"});
      // Metric 4: Hint register reads
      list.push_back({prefix + "uncore.hint_reads_total", "count"});
      list.push_back({prefix + "uncore.hint_reads_empty", "count"});
      list.push_back({prefix + "uncore.hint_reads_nonempty", "count"});
      // Metric 5: Burst histogram
      list.push_back({prefix + "uncore.mailbox_burst_total", "count"});
      list.push_back({prefix + "uncore.mailbox_burst_sqe_total", "count"});
      for (int i = 0; i < 64; i++) {
        list.push_back({prefix + "uncore.mailbox_burst_hist_" + std::to_string(i), "count"});
      }
      // Metric 6: Cycle breakdown averages
      list.push_back({prefix + "uncore.ts_submit_latency_avg", "ps"});
      list.push_back({prefix + "uncore.ts_backend_latency_avg", "ps"});
      list.push_back({prefix + "uncore.ts_completion_latency_avg", "ps"});
      list.push_back({prefix + "uncore.ts_total_latency_avg", "ps"});
      list.push_back({prefix + "uncore.ts_io_count", "count"});
    }
```

- [ ] **Step 2: Extend getStatValues() for Mode B metrics**

In `controller.cc`, in `getStatValues()` (line 2018), after the existing Mode A values, add:

```cpp
    if (uncoreCfg.mode == UNCORE_MODE_B) {
      // Metric 1
      values.push_back((double)uncoreStats.mailboxSubmissions);
      values.push_back((double)uncoreStats.standardSubmissions);
      // Metric 2
      values.push_back((double)uncoreStats.prpSimpleExpansions);
      values.push_back((double)uncoreStats.prpListExpansions);
      // Metric 3
      values.push_back((double)uncoreStats.creditStalls);
      // Metric 4
      values.push_back((double)uncoreStats.hintReadsTotal);
      values.push_back((double)uncoreStats.hintReadsEmpty);
      values.push_back((double)uncoreStats.hintReadsNonEmpty);
      // Metric 5
      values.push_back((double)uncoreStats.mailboxBurstTotal);
      values.push_back((double)uncoreStats.mailboxBurstSqeTotal);
      for (int i = 0; i < 64; i++) {
        values.push_back((double)uncoreStats.mailboxBurstHist[i]);
      }
      // Metric 6: averages (avoid div-by-zero)
      double cnt = (double)uncoreStats.tsIoCount;
      if (cnt > 0) {
        values.push_back((double)uncoreStats.tsSubmitLatencySum / cnt);
        values.push_back((double)uncoreStats.tsBackendLatencySum / cnt);
        values.push_back((double)uncoreStats.tsCompletionLatencySum / cnt);
        values.push_back((double)uncoreStats.tsTotalLatencySum / cnt);
      } else {
        values.push_back(0.0);
        values.push_back(0.0);
        values.push_back(0.0);
        values.push_back(0.0);
      }
      values.push_back(cnt);
    }
```

- [ ] **Step 3: Build and verify stats appear**

Build gem5, run a Mode B simulation, check that the new stats appear in the output.

- [ ] **Step 4: Commit**

```bash
git add SimpleSSD-FullSystem/src/dev/storage/simplessd/hil/nvme/controller.cc
git commit -m "Export all Mode B metrics (6 categories) via stat system"
```

---

### Task 9: Add T_submit_enter/T_submit_exit timestamps for baseline and Mode A

**Model: Sonnet**

**Files:**
- Modify: `SimpleSSD-FullSystem/src/dev/storage/simplessd/hil/nvme/controller.cc` (collectSQueue and submit functions)

Mode B timestamps were already added in Task 6. For the cycle breakdown to be comparable across modes, baseline and Mode A also need `T_submit_enter` (at SQ DMA start) and `T_submit_exit` (at SQ DMA complete). This makes Metric 6 work for all three modes.

- [ ] **Step 1: Record T_submit_enter at collectSQueue entry**

In `controller.cc`, in `collectSQueue()` (line 1417), at the point where SQ DMA is about to begin (after Gate 1 passes), record the timestamp. The exact location depends on where the DMA read callback for each SQE fires — find the DMA read initiation point and record `submitEnter` there.

This is mode-independent — record for all modes when the uncore is not disabled. The command ID is not yet known at SQ collection time (it's in the SQE being read from DRAM), so record a per-queue timestamp and associate it with the CID when the SQE is parsed.

- [ ] **Step 2: Record T_submit_exit when SQE parse completes**

After the DMA callback delivers the SQE data and the controller begins processing it, record `submitExit`.

- [ ] **Step 3: Record T_io_complete and T_cqe_visible for baseline mode**

In `submit()`, for baseline mode (when `uncoreCfg.mode == UNCORE_MODE_DISABLED`), CQEs go directly to `lCQFIFO`. Record both `ioComplete` and `cqeVisible` at this point (they're the same for baseline since there's no staging delay).

- [ ] **Step 4: Commit**

```bash
git add SimpleSSD-FullSystem/src/dev/storage/simplessd/hil/nvme/controller.cc
git commit -m "Add timestamp tracking for baseline and Mode A cycle breakdown"
```

---

## Layer 5: Integration and Scripts

**Model: Sonnet**

### Task 10: Add --uncore-credits CLI flag to driver_phase1.sh

**Files:**
- Modify: `scripts/driver_phase1.sh:53-56,112-115,185-188,262-265,605-611`
- Modify: `fast_ssd.cfg` (already done in Task 2, just verify)

- [ ] **Step 1: Add UNCORE_CREDITS_MAX default**

In `scripts/driver_phase1.sh`, after the `DB_BATCH_B` default (around line 56), add:

```bash
UNCORE_CREDITS_MAX=64
```

- [ ] **Step 2: Add help text**

In the help text block (around line 115), after the `--db-batch-b` line, add:

```bash
  --uncore-credits N      Uncore credits max (Mode B, default: $UNCORE_CREDITS_MAX)
```

- [ ] **Step 3: Add argument parsing**

In the argument parsing case block (around line 188), after the `--db-batch-b` case, add:

```bash
    --uncore-credits) UNCORE_CREDITS_MAX="$2"; shift 2 ;;
```

- [ ] **Step 4: Add to JSON metadata**

In the JSON metadata output (around line 265), after the `db_batch_b` line, add:

```bash
    "uncore_credits_max": $UNCORE_CREDITS_MAX,
```

- [ ] **Step 5: Add sed patch for UncoreCreditsMax**

In the sed block that patches fast_ssd.cfg (around line 611), add a new `-e` line:

```bash
  -e "s|^(UncoreCreditsMax)[[:space:]]*=.*|\1 = $UNCORE_CREDITS_MAX|" \
```

- [ ] **Step 6: Commit**

```bash
git add scripts/driver_phase1.sh
git commit -m "Add --uncore-credits CLI flag to driver_phase1.sh"
```

---

### Task 11: Rebuild SPDK, re-bake image, and run validation sweep

**Model: Sonnet**

**Files:**
- `build_spdk_docker.sh` or equivalent SPDK build process
- Disk image at `assets/x86-ubuntu.img`

- [ ] **Step 1: Rebuild SPDK in Docker**

```bash
./scripts/build_spdk_docker.sh
```

This produces an updated `docker_artifacts/guest_spdk_nvme_perf` with Mode B support.

- [ ] **Step 2: Re-bake disk image**

```bash
sudo ./scripts/bake_disk_image.sh \
  --disk-image ./assets/x86-ubuntu.img \
  --src-repo . \
  --dst-path /root/SimpleSSD_Gem5_simulation
```

- [ ] **Step 3: Build gem5**

```bash
cd SimpleSSD-FullSystem && scons build/X86/gem5.opt -j$(nproc)
```

- [ ] **Step 4: Run baseline validation**

```bash
./scripts/driver_phase1.sh --auto --uncore-mode 0 \
  --qd "16 32" --ios "4096" --repeats 1 --steady-time 10 \
  --tag mode_b_val_baseline
```

- [ ] **Step 5: Run Mode A validation**

```bash
./scripts/driver_phase1.sh --auto --uncore-mode 1 \
  --qd "16 32" --ios "4096" --repeats 1 --steady-time 10 \
  --tag mode_b_val_modeA
```

- [ ] **Step 6: Run Mode B validation**

```bash
./scripts/driver_phase1.sh --auto --uncore-mode 2 --uncore-credits 64 \
  --qd "16 32" --ios "4096" --repeats 1 --steady-time 10 \
  --tag mode_b_val_modeB
```

- [ ] **Step 7: Verify all three modes produce valid results**

Check:
1. All simulations complete without hangs or crashes
2. Baseline produces IOPS consistent with prior runs
3. Mode A produces IOPS consistent with prior Mode A runs
4. Mode B shows `mailboxSubmissions > 0` and `hintReadsTotal > 0` in stats
5. Mode B IOPS is comparable or better than Mode A
6. Mode B cycle breakdown metrics (Metric 6) show non-zero values

- [ ] **Step 8: Commit any fixes**

```bash
git add -u
git commit -m "Fix integration issues found during validation sweep"
```

---

### Task 12: Run full parameter sweep (baseline vs Mode A vs Mode B)

**Model: Sonnet**

- [ ] **Step 1: Run full sweep**

```bash
for mode in 0 1 2; do
  mode_name="baseline"
  [ "$mode" = "1" ] && mode_name="modeA"
  [ "$mode" = "2" ] && mode_name="modeB"
  ./scripts/driver_phase1.sh --auto --uncore-mode $mode \
    --qd "16 32 64 128" --ios "4096 16384" \
    --repeats 3 --steady-time 30 \
    --tag "mode_b_sweep_${mode_name}"
done
```

- [ ] **Step 2: Extract results**

```bash
for mode_name in baseline modeA modeB; do
  sudo ./scripts/extract_phase1_results.sh \
    --disk-image ./assets/x86-ubuntu.img \
    --run-tag "mode_b_sweep_${mode_name}"
done
```

- [ ] **Step 3: Plot comparative results**

```bash
python3 scripts/plot_phase1.py  # May need updating to overlay all three modes
```

- [ ] **Step 4: Commit results**

```bash
git add results/
git commit -m "Add Mode B full parameter sweep results"
```

---

## Summary: Model Assignment Per Task

| Task | Layer | Model | Description |
|------|-------|-------|-------------|
| 1 | L1 | **Opus** | Enlarge BAR0, route uncore register region |
| 2 | L1 | **Opus** | Add UncoreCreditsMax config parameter |
| 3 | L1 | **Opus** | Register map, data structures, status/cap/credits read handlers |
| 4 | L1 | **Opus** | SPDK capability probe in controller init |
| 5 | L2 | **Opus** | Poll-lite completion (SPDK + SimpleSSD wiring) |
| 6 | L3 | **Opus** | Mailbox write handler + PRP expansion + credit flow |
| 7 | L3 | **Opus** | SPDK mailbox submission path |
| 8 | L4 | **Sonnet** | Export all Mode B metrics via stat system |
| 9 | L4 | **Sonnet** | Baseline/Mode A timestamp tracking |
| 10 | L5 | **Sonnet** | --uncore-credits CLI flag in driver_phase1.sh |
| 11 | L5 | **Sonnet** | Rebuild, re-bake, validation sweep |
| 12 | L5 | **Sonnet** | Full parameter sweep (baseline vs A vs B) |
