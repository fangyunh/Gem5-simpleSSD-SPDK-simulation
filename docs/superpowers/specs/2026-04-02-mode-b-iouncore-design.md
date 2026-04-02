# Mode B IO-Uncore Design Specification

**Date:** 2026-04-02
**Status:** Approved
**Scope:** Cooperative IO-Uncore (Mode B) for SimpleSSD + gem5 + SPDK simulation

---

## 1. Overview

Mode B extends the existing Mode A (transparent IO-Uncore) with two cooperative mechanisms that require minimal SPDK driver changes:

1. **Poll-lite completion** — SPDK reads a hardware hint register before touching the DRAM CQ, eliminating wasted empty-queue scanning cycles
2. **Mailbox submission** — SPDK writes compact 24B command descriptors to an MMIO mailbox instead of building full 64B SQEs in DRAM, eliminating DRAM writes on the submit path

Mode B is a strict superset of Mode A. All Mode A mechanisms (CQE staging buffer with N/T flush thresholds, SQ collection threshold guard) continue to operate underneath.

### Control Flow

One config knob, one binary:

```
driver_phase1.sh --uncore-mode N  →  fast_ssd.cfg UncoreMode=N  →  SimpleSSD controller
                                                                         ↓
                                                         BAR0+0x2008 capability register
                                                                         ↓
                                                        SPDK probes at init, auto-adapts
```

- `--uncore-mode 0` → baseline (no uncore, capability = 0)
- `--uncore-mode 1` → Mode A (transparent, capability = 1, SPDK uses standard path)
- `--uncore-mode 2` → Mode B (cooperative, capability = 2, SPDK activates mailbox + poll-lite)

---

## 2. Register Map

All registers are in BAR0 space, above the standard NVMe register region.

| Offset | Size | Access | Name | Description |
|--------|------|--------|------|-------------|
| `0x2000` | 8B | RO | `UNCORE_STATUS` | Combined status register. Bits [31:0] = SQ credits available. Bits [63:32] = CQ completions ready (global hint across all CQs). |
| `0x2008` | 4B | RO | `UNCORE_CAP` | Capability advertisement. `0` = no uncore, `1` = Mode A, `2` = Mode B. |
| `0x2010` | 4B | RO | `UNCORE_CREDITS_MAX` | Maximum SQ credit pool size. Read once at init by SPDK. |
| `0x2100 + qid*32` | 24B | WO | `UNCORE_MAILBOX[qid]` | Per-queue compact SQE mailbox. Written as 3 × 8B MMIO writes. Triggers ingestion on 3rd write. |

### UNCORE_STATUS register layout (8 bytes)

```
 63                              32 31                               0
+----------------------------------+----------------------------------+
|     CQ completions ready (u32)   |     SQ credits available (u32)   |
+----------------------------------+----------------------------------+
```

SPDK reads this register once at the start of each poll/submit cycle. One MMIO read provides both "should I poll CQ?" and "can I submit more?".

---

## 3. Capability Discovery

During NVMe controller initialization in SPDK (`nvme_pcie_ctrlr_construct` or `nvme_pcie_ctrlr_enable`):

1. Read `BAR0 + 0x2008` → `UNCORE_CAP`
2. If `UNCORE_CAP == 2`:
   - Set `ctrlr->iouncore_mode_b = true`
   - Read `BAR0 + 0x2010` → `UNCORE_CREDITS_MAX`, store as `ctrlr->iouncore_credits_max`
   - Initialize credit tracking: `ctrlr->iouncore_credits = credits_max`
3. If `UNCORE_CAP < 2`: standard NVMe path (baseline or Mode A — both transparent to SPDK)

On the SimpleSSD side, the capability register value is set in `Controller::init()` based on `uncoreCfg.mode`.

---

## 4. Poll-Lite Completion Path

### Current flow (baseline / Mode A)

```
nvme_pcie_qpair_process_completions():
    while true:
        read CQE from DRAM CQ at current head index
        check phase bit — if no new CQE, break
        process CQE, advance head, ring CQ doorbell
```

### Mode B flow

```
nvme_pcie_qpair_process_completions():
    if ctrlr->iouncore_mode_b:
        status = mmio_read_8B(BAR0 + 0x2000)
        cq_ready = status >> 32
        if cq_ready == 0:
            return 0    // skip DRAM CQ entirely — no completions available
        // fall through: completions ready, drain normally

    while true:
        read CQE from DRAM CQ at current head index
        check phase bit — if no new CQE, break
        process CQE, advance head, ring CQ doorbell
```

### Key design points

- The hint is a **global** count (total CQEs ready across all CQs), matching the existing `uncoreHintReady` implementation.
- When hint > 0, SPDK reads the DRAM CQ normally to get actual CQE data. The hint only eliminates empty polls.
- The CQ doorbell write path is unchanged.
- Mode A's CQE staging buffer (N/T thresholds) still operates underneath. Mode B adds the software-side shortcut to avoid polling when the batch hasn't flushed yet.
- When hint says 0, SPDK returns immediately with "0 completions processed." The SPDK reactor loop continues other work and comes back later. No spinning.

---

## 5. Mailbox Submission Path

### Compact SQE Format (24 bytes)

```
Byte offset   Size   Field
[0:1]         2B     opcode (8b) + flags (8b: fuse, SGL, etc.)
[2:3]         2B     namespace ID (truncated to 16-bit, sufficient for ≤65535 namespaces)
[4:11]        8B     starting LBA (full 64-bit)
[12:13]       2B     block count (NLB field)
[14:15]       2B     queue pair ID (which SQ this targets)
[16:23]       8B     DMA buffer physical address (explicit, from SPDK hugepage pool)
```

### SPDK submission flow (Mode B)

```
nvme_pcie_qpair_submit_request():
    if ctrlr->iouncore_mode_b:
        // 1. Check credits (may reuse status from recent poll, or read fresh)
        status = mmio_read_8B(BAR0 + 0x2000)
        sq_credits = status & 0xFFFFFFFF
        if sq_credits == 0:
            return -EAGAIN   // backpressure — caller retries later

        // 2. Build compact 24B descriptor from NVMe command
        compact_sqe = build_compact(cmd, qpair->id, phys_addr)

        // 3. Write to per-queue mailbox (3 × 8B MMIO writes)
        mmio_write_8B(BAR0 + 0x2100 + qid*32 + 0,  compact_sqe[0:7])
        mmio_write_8B(BAR0 + 0x2100 + qid*32 + 8,  compact_sqe[8:15])
        mmio_write_8B(BAR0 + 0x2100 + qid*32 + 16, compact_sqe[16:23])
        return 0

    // else: standard path (build 64B SQE in DRAM + doorbell)
```

### SimpleSSD controller mailbox ingestion

When a write hits `BAR0 + 0x2100 + qid*32`:

1. **Accumulate:** Controller stores bytes into a per-queue 24B staging latch. A per-queue write counter tracks which of the 3 writes has arrived.
2. **Trigger on 3rd write:** When all 24 bytes are received:
   - Assign command ID from per-queue counter
   - Expand to full 64B NVMe SQE:
     - Set opcode, NSID (expand to 32-bit), LBA, NLB
     - Compute PRP entries from `buffer_addr` + `block_count` × LBA size:
       - Transfer ≤ 4KB → PRP1 = buffer_addr, PRP2 = 0
       - Transfer ≤ 8KB → PRP1 = buffer_addr, PRP2 = buffer_addr + 4096
       - Transfer > 8KB → PRP1 = buffer_addr, build PRP List in controller-internal memory with entries for each 4KB page, PRP2 = internal pointer to that list
   - Inject the expanded SQE directly into the internal processing pipeline (bypasses DRAM SQ DMA read entirely)
   - Decrement credit counter
3. **Reset:** Clear staging latch, reset write counter for that queue

### Credit-based flow control

- **Pool size:** Configured via `UncoreCreditsMax` (default 64). Exposed read-only at `BAR0 + 0x2010`.
- **Decrement:** On each successful mailbox ingestion (3rd write triggers decrement).
- **Replenishment:** When a CQE is generated in `Controller::submit()`, before the CQE enters the staging buffer, the credit counter is incremented.
- **Visibility:** Current credit count is always available in the lower 32 bits of `UNCORE_STATUS` register.

---

## 6. PRP List Expansion

The uncore supports full PRP List generation to handle arbitrary I/O sizes (required for advanced workloads like BigANN with larger reads).

**Algorithm:**

```
transfer_size = block_count * lba_size    // e.g., 4096 * 32 = 128KB
page_size = 4096                          // NVMe memory page size

if transfer_size <= page_size:
    PRP1 = buffer_addr
    PRP2 = 0

else if transfer_size <= 2 * page_size:
    PRP1 = buffer_addr
    PRP2 = buffer_addr + page_size

else:
    PRP1 = buffer_addr
    num_prp_entries = ceil((transfer_size - page_size) / page_size)
    allocate PRP List in controller-internal SRAM (num_prp_entries × 8B)
    for i in 0..num_prp_entries-1:
        prp_list[i] = buffer_addr + (i+1) * page_size
    PRP2 = internal_pointer_to_prp_list
```

**Assumption:** SPDK DMA buffers are allocated from hugepages (2MB), so the physical addresses are contiguous. The PRP List entries are sequential page-aligned addresses derived from a single base address.

---

## 7. Metrics and Telemetry

All 6 metric categories, implemented as counters in `UncoreStats` and exported via `getStatList()`/`getStatValues()`.

### Metric 1: Mailbox Submissions

| Counter | Description |
|---------|-------------|
| `mailboxSubmissions` | Compact SQEs received via mailbox (Mode B submit path) |
| `standardSubmissions` | SQEs received via DRAM SQ DMA (baseline/Mode A path) |

### Metric 2: PRP Expansions

| Counter | Description |
|---------|-------------|
| `prpSimpleExpansions` | I/Os where PRP1/PRP2 sufficed (transfer ≤ 8KB) |
| `prpListExpansions` | I/Os where a full PRP List was generated (transfer > 8KB) |

### Metric 3: Credit Stalls

| Counter | Description |
|---------|-------------|
| `creditStalls` | Times SPDK read credits = 0 from status register (backpressure events) |

Note: This is tracked on the SimpleSSD side by counting status register reads where credits = 0.

### Metric 4: Hint Register Reads

| Counter | Description |
|---------|-------------|
| `hintReadsTotal` | Total reads of UNCORE_STATUS register |
| `hintReadsEmpty` | Reads where CQ hint = 0 (eliminated empty polls) |
| `hintReadsNonEmpty` | Reads where CQ hint > 0 (proceeded to CQ drain) |

### Metric 5: Submission Batching Efficiency

| Counter / Structure | Description |
|---------------------|-------------|
| `mailboxBurstTotal` | Total mailbox submission bursts |
| `mailboxBurstSqeTotal` | Total SQEs across all bursts (for computing average) |
| `mailboxBurstHist[64]` | Histogram: consecutive mailbox writes per burst (bucket = count, capped at 63) |

A "burst" is a sequence of consecutive mailbox writes to the same queue with no intervening completion polls. The burst counter resets when a status register read occurs or a different queue is accessed.

### Metric 6: End-to-End Per-I/O Cycle Breakdown

Per-command timestamp tracking via a ring buffer indexed by `(qid, cid)`:

| Timestamp | Event | Capture Point |
|-----------|-------|---------------|
| `T_submit_enter` | Mailbox write received (Mode B) or SQ DMA read begins (baseline/A) | `writeRegister()` mailbox handler or `collectSQueue()` |
| `T_submit_exit` | Full SQE injected into pipeline | End of mailbox ingestion or SQ DMA callback |
| `T_io_complete` | Backend (NAND model) signals done | `Controller::submit()` entry |
| `T_cqe_visible` | CQE flushed to host DRAM | `uncoreFlushCQBuffer()` or direct lCQFIFO insertion |

**Derived metrics (accumulated as running sums, exported as averages):**

| Metric | Formula | What it measures |
|--------|---------|-----------------|
| Submit latency | `T_submit_exit - T_submit_enter` | Mailbox expansion + PRP build (Mode B) vs DMA read cost (baseline) |
| Backend latency | `T_io_complete - T_submit_exit` | NAND model time — constant across modes, serves as sanity check |
| Completion visibility latency | `T_cqe_visible - T_io_complete` | CQE batching delay from staging buffer |
| Total controller-side latency | `T_cqe_visible - T_submit_enter` | End-to-end through controller |

Storage: `struct UncoreTimestamp { uint64_t t[4]; }` per in-flight command, in a flat array sized to `UncoreCreditsMax × num_queues`.

---

## 8. Configuration

### fast_ssd.cfg additions

One new parameter in the `[nvme]` section:

```ini
UncoreCreditsMax = 64
```

Existing parameters and their Mode B semantics:

| Parameter | Mode A meaning | Mode B meaning |
|-----------|---------------|---------------|
| `UncoreMode` | 0=off, 1=Mode A | 2=Mode B |
| `CQBatchN` | CQE flush count threshold | Same (still controls staging buffer) |
| `CQBatchT` | CQE flush timeout (ps) | Same |
| `DBBatchB` | SQ collection threshold | Same (Mode A gate still active as fallback for admin queue path) |
| `UncoreCreditsMax` | N/A | SQ credit pool size for backpressure |

### driver_phase1.sh additions

- New CLI flag: `--uncore-credits N` (default 64)
- Sed-patched into `fast_ssd.cfg` as `UncoreCreditsMax = N`
- Added to JSON metadata output

---

## 9. File Changes

### SimpleSSD Controller (C++)

| File | Changes |
|------|---------|
| `hil/nvme/config.hh` | Add `NVME_UNCORE_CREDITS_MAX` config key |
| `hil/nvme/config.cc` | Parse `UncoreCreditsMax`, default 64 |
| `hil/nvme/controller.hh` | Add: mailbox staging latch struct, credit counter, per-command timestamp ring, 6 new metric groups in `UncoreStats`, BAR0 offset constants (`UNCORE_STATUS_OFFSET=0x2000`, `UNCORE_CAP_OFFSET=0x2008`, `UNCORE_CREDITS_MAX_OFFSET=0x2010`, `UNCORE_MAILBOX_BASE=0x2100`, `UNCORE_MAILBOX_STRIDE=32`) |
| `hil/nvme/controller.cc` | Extend `readRegister()` for 0x2000/0x2008/0x2010. Add `writeRegister()` handler for 0x2100+ mailbox region. Mailbox ingestion + PRP expansion logic. Credit decrement on submit, replenishment on completion. Timestamp capture at 4 boundary points. Extend `getStatList()`/`getStatValues()` for all new metrics. |

### SPDK NVMe PCIe Transport (C)

| File | Changes |
|------|---------|
| `lib/nvme/nvme_pcie_common.h` | Add `iouncore_mode_b` flag, `iouncore_credits_max` to controller struct. Add BAR0 offset defines. Add compact SQE struct. |
| `lib/nvme/nvme_pcie_common.c` | In `process_completions()`: hint register read + early return. In submit path: credit check + compact SQE build + mailbox MMIO writes. |
| `lib/nvme/nvme_pcie.c` | In controller init: capability register probe, credits_max read, flag setup. |

### Scripts & Config

| File | Changes |
|------|---------|
| `fast_ssd.cfg` | Add `UncoreCreditsMax = 64` |
| `scripts/driver_phase1.sh` | Add `--uncore-credits` flag, sed-patch, JSON metadata |

### Build

| File | Changes |
|------|---------|
| `build_spdk_docker.sh` | Rebuild with patched SPDK sources |

---

## 10. Implementation Order (Incremental Layering)

### Layer 1: Registers and Capability Discovery
- Add BAR0 register handlers in SimpleSSD (read for status/cap/credits_max)
- Add capability probe in SPDK controller init
- **Testable:** SPDK detects Mode B, logs it. No behavioral change yet.

### Layer 2: Poll-Lite Completion
- Add hint register read + early return in SPDK `process_completions()`
- Wire `uncoreHintReady` (already maintained) into UNCORE_STATUS upper 32 bits
- Add Metric #4 (hint read counters)
- **Testable:** Run Mode B, verify eliminated empty polls in stats. IOPS should match or slightly improve vs Mode A.

### Layer 3: Mailbox Submission
- Add mailbox write handler in SimpleSSD
- Add compact SQE build + mailbox writes in SPDK submit path
- Add PRP expansion logic (simple + full list)
- Add credit-based flow control (decrement on submit, replenish on complete)
- Add Metrics #1, #2, #3, #5
- **Testable:** Run Mode B with 4KB and 16KB reads. Verify mailbox path active, credits cycling, no DRAM SQ DMA reads.

### Layer 4: Cycle Breakdown Telemetry
- Add per-command timestamp tracking ring
- Add timestamp capture at 4 boundary points
- Add Metric #6 export
- **Testable:** Compare submit latency across baseline / Mode A / Mode B.

### Layer 5: Integration and Sweep
- Rebuild SPDK Docker image
- Re-bake disk image
- Run full parameter sweep: baseline vs Mode A vs Mode B across QD 16/32/64/128, IO sizes 4KB/16KB
- Validate all 6 metrics in output CSV

---

## 11. Model Recommendation for Implementation

### Complexity Assessment

This project involves:

- **Cross-component changes:** SimpleSSD C++ (controller internals, register handling, PRP logic) AND SPDK C (NVMe transport layer, PCIe driver). These are two separate, complex codebases with different conventions, build systems, and debugging approaches.
- **Cycle-accurate simulation semantics:** Changes to the NVMe controller interact with gem5's timing model. Subtle bugs (e.g., incorrect tick arithmetic, event scheduling order, DMA pipeline assumptions) manifest as silent data corruption or hangs that are hard to trace.
- **Hardware register protocol:** The mailbox ingestion (3-write latch), credit flow control, and PRP expansion are stateful hardware-like logic with edge cases (partial writes, credit underflow, PRP list for large transfers).
- **SPDK internals:** The PCIe transport layer is performance-critical C code with specific MMIO access patterns, memory barriers, and volatile semantics. Incorrect changes can cause guest hangs or data races.

### Recommendation: Use Opus for Layers 1-3, Sonnet for Layers 4-5

| Layer | Model | Reasoning |
|-------|-------|-----------|
| **Layer 1** (Registers + Probe) | **Opus** | Requires understanding BAR0 register dispatch in SimpleSSD AND SPDK controller init flow simultaneously. First integration point — getting this wrong blocks everything. |
| **Layer 2** (Poll-lite) | **Opus** | Modifying SPDK's hot completion path requires precision. Must correctly handle the MMIO read semantics within gem5's memory model. |
| **Layer 3** (Mailbox + PRP) | **Opus** | Most complex layer. Stateful 3-write latch, PRP list generation, credit flow control — multiple interacting state machines with edge cases. Cross-references between SPDK submit path and SimpleSSD write handler must be consistent. |
| **Layer 4** (Telemetry) | **Sonnet** | Additive instrumentation — inserting timestamp captures at known boundary points and accumulating stats. Pattern follows existing Mode A telemetry code. Lower risk. |
| **Layer 5** (Integration) | **Sonnet** | Script changes and parameter sweeps. Follows existing patterns in `driver_phase1.sh`. Mechanical. |

**Overall:** The core implementation (Layers 1-3) benefits from Opus's stronger reasoning over multi-file, stateful, hardware-like logic. Layers 4-5 are incremental additions where Sonnet is sufficient and more cost-effective.
