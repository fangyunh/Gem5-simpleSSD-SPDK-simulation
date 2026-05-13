# IO-Uncore RTL Design Specification — Phase 3 Silicon Feasibility

**Date:** 2026-04-13
**Status:** Draft
**Scope:** RTL design, synthesis, and PPA analysis for the IO-Uncore hot-path control logic
**Prior phases:** Phase 1 (baseline measurement), Phase 2 (Mode A + Mode B gem5 simulation)

---

## 1. Overview and Goals

Phase 3 proves that the IO-Uncore hot-path control logic is physically realizable in silicon, computationally inexpensive, and fits within a practical power/area envelope for integration into a CPU I/O chiplet.

This spec covers the **first sub-project**: SQ Engine, CQ Engine, and Doorbell Coalescer — the three components whose behavioral correctness was validated in Phase 2 gem5 simulation (Mode A + Mode B). The DMA Sequencer and Hardware Scheduler are deferred to a follow-up sub-project.

### Goals

1. **Synthesizable RTL** for the three hot-path engines in Verilog
2. **PPA numbers** (Power, Performance, Area) at ASAP7 7nm across four parameterized configurations
3. **SRAM sizing analysis** with per-component breakdown and scaling curves
4. **Self-checking verification** testbenches covering all steady-state and boundary-condition scenarios
5. **Paper deliverables**: 3 tables + 4 figures for the Phase 3 section

### Success Criteria (from Phase 3 design doc)

- Sustain 30-40M IOPS per tile without excessively complex SRAM architecture
- Fit within 10-15 W power envelope per tile
- Energy efficiency in tens-of-nanojoules per I/O
- Add no more than 200 ns latency to the host-to-storage datapath
- Total area small relative to a CPU I/O tile (~40 mm^2)

### Deferred to Follow-Up Sub-Projects

- DMA Sequencer (token-based issue with backpressure)
- Hardware Scheduler (weighted round-robin / deficit fair queuing)
- IOMMU Assist (I/O-TLB, page-walk cache)
- Gate-level simulation and formal verification

---

## 2. Technology Choices

### 2.1 Target Node: ASAP7 (7nm)

**Choice:** ASAP7 predictive PDK from Arizona State University (free academic license).

**Why ASAP7 over FreePDK-45:**

1. **Paper credibility:** The IO-Uncore is proposed for integration into modern CPU I/O chiplets. AMD's I/O die uses 6nm; Intel's I/O tile uses mature 7nm-class nodes. ASAP7 at 7nm directly matches the target deployment node. Reviewers at architecture/VLSI venues expect sub-10nm for new proposals.
2. **SRAM models:** ASAP7 publishes high-density (HD) SRAM bitcell dimensions (0.027 um^2/bit), enabling the analytical SRAM area estimation that is central to the paper's feasibility argument.
3. **Comparable published data:** Area/power numbers from ASAP7 synthesis are directly comparable to published CPU uncore figures (LLC slices, interconnect tiles), enabling the comparison table in the paper.
4. **Academic accessibility:** Free, well-documented, widely used in published research — reviewers can reproduce results.

**Library files needed:**
- `asap7sc7p5t_AO_RVT_TT_nldm_211120.db` — typical-typical corner timing/power
- `asap7sc7p5t.sdb` — symbol library
- `dw_foundation.sldb` — DesignWare synthetic library

**Corner:** TT (typical-typical) for nominal results. Optionally SS (slow-slow) for worst-case timing margin.

### 2.2 Target Clock Frequency: 1 GHz

**Why 1 GHz:**

- The IO-Uncore sits in the CPU's I/O chiplet domain, adjacent to PCIe and DDR controllers. In real CPUs, this domain runs at 1-2 GHz (Intel uncore ~1.5-2.5 GHz, AMD I/O die ~1-1.5 GHz), significantly below the 3-5 GHz core clock.
- At 1 GHz, each I/O gets ~25 cycles at 40M IOPS — sufficient budget for the pipelined SQ/CQ engines (6 cycles typical, 38 cycles worst case).
- Matches the gem5 system clock domain (1 GHz default) where the NVMe device model already resides.
- Single clock domain — no clock domain crossing (CDC) logic needed, simplifying both RTL and verification.

**Note:** The gem5 CPU clock should be updated from the default 2 GHz to 5 GHz to match modern CPU specifications. This is a separate action item for the simulation configuration.

### 2.3 HDL: Verilog-2001

Synthesizable subset of Verilog-2001. SystemVerilog features used only in testbenches (not in synthesizable RTL) to ensure maximum tool compatibility.

---

## 3. Top-Level Architecture

### 3.1 Approach: Modular Engines with Shared SRAM

Three independent engines (SQ Engine, CQ Engine, Doorbell Coalescer) each with their own FSMs, connected to shared SRAM banks through a lightweight round-robin arbiter. A thin top-level module handles MMIO decode and routes transactions to the correct engine.

**Why modular over monolithic:**
- Each engine is independently parameterizable, testable, and synthesizable
- Directly maps to the Mode B behavior validated in Phase 2 simulation
- Concurrent SQ submit + CQ complete in the same cycle (no pipeline stall)
- Clean module boundaries make self-checking testbenches straightforward
- Slight area overhead vs. monolithic is negligible; shared SRAM arbiter adds at most 1 cycle contention

**Why shared SRAM over per-engine private SRAM:**
- Dynamic sharing avoids wasting SRAM when workload is asymmetric (submit-heavy vs. complete-heavy)
- Fewer SRAM instances reduces peripheral circuit overhead
- Reflects how real I/O chiplets are designed
- SRAM arbiter is a simple round-robin — an interesting design point for the paper

### 3.2 Block Diagram

```
 Host CPU Core (5 GHz)
 ┌──────────────────────────────────────────────────────────────────┐
 │  SPDK (userspace)                                               │
 │  ┌──────────────┐  ┌──────────────┐  ┌───────────────────────┐  │
 │  │ Mailbox Write │  │ Status Read  │  │ CQ Doorbell / Admin   │  │
 │  │ (3x8B MMIO)  │  │ (1x8B MMIO)  │  │ (standard NVMe)       │  │
 │  └──────┬───────┘  └──────┬───────┘  └──────────┬────────────┘  │
 └─────────┼─────────────────┼─────────────────────┼───────────────┘
           │                 │                     │
 ══════════╪═════════════════╪═════════════════════╪════ PCIe BAR0
           │                 │                     │
 ┌─────────▼─────────────────▼─────────────────────▼───────────────┐
 │                    MMIO Decoder                                  │
 │       (Address decode: 0x0000-0x0FFF -> NVMe std regs           │
 │        0x1000-0x1FFF -> Doorbells,  0x2000+ -> Uncore)          │
 └──────┬──────────────────┬──────────────────┬────────────────────┘
        │                  │                  │
        v                  v                  v
 ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐
 │  SQ Engine   │  │  CQ Engine   │  │ Doorbell         │
 │              │  │              │  │ Coalescer         │
 │ - Mailbox    │  │ - CQE batch  │  │                  │
 │   latch      │  │   buffer     │  │ - Per-queue      │
 │ - SQE decode │  │ - N/T flush  │  │   counter        │
 │ - PRP expand │  │ - Hint reg   │  │ - Timer flush    │
 │ - CID assign │  │   generate   │  │ - Count thresh.  │
 └──────┬───────┘  └──────┬───────┘  └────────┬─────────┘
        │                  │                    │
        v                  v                    v
 ┌─────────────────────────────────────────────────────────────────┐
 │                     SRAM Arbiter                                 │
 │          (Round-robin, 3 requestors, 1-cycle latency)           │
 └────────────────────────────┬────────────────────────────────────┘
                              │
                    ┌─────────v─────────┐
                    │   SRAM Banks      │
                    │                   │
                    │  SQ Buffers       │  <- 64B x QD x NQ
                    │  CQ Buffers       │  <- 16B x QD x NQ
                    │  Metadata         │  <- pointers, credits
                    │  PRP Lists        │  <- 8B x pages x NQ
                    └───────────────────┘

 Shared resources (directly accessible by all engines):
 ┌──────────────────┐  ┌──────────────────┐
 │ Credit Manager   │  │ Stat Counters    │
 │ - Pool counter   │  │ - 6 metric groups│
 │ - Dec on submit  │  │ - Self-checking  │
 │ - Inc on complete│  │   export port    │
 └──────────────────┘  └──────────────────┘
```

### 3.3 Module Inventory

| Module | Verilog File | Key Parameters | Description |
|--------|-------------|----------------|-------------|
| `io_uncore_top` | `io_uncore_top.v` | `NUM_QUEUES`, `QUEUE_DEPTH`, `CREDITS_MAX` | Top-level wrapper, instantiates all sub-modules |
| `mmio_decoder` | `mmio_decoder.v` | `ADDR_WIDTH`, `DATA_WIDTH` | Address decode, routes MMIO reads/writes to engines |
| `sq_engine` | `sq_engine.v` | `NUM_QUEUES`, `QUEUE_DEPTH`, `SQE_WIDTH=512` | Mailbox ingestion, SQE decode, PRP expansion |
| `cq_engine` | `cq_engine.v` | `NUM_QUEUES`, `QUEUE_DEPTH`, `BATCH_N`, `BATCH_T` | CQE batching, N/T flush, hint register |
| `db_coalescer` | `db_coalescer.v` | `NUM_QUEUES`, `COALESCE_COUNT`, `TIMEOUT_CYCLES` | Doorbell aggregation with count/timer triggers |
| `sram_arbiter` | `sram_arbiter.v` | `NUM_REQUESTORS=3`, `SRAM_ADDR_WIDTH`, `DATA_WIDTH=128` | Round-robin SRAM access arbitration. Data bus is 128 bits (widest requestor = CQ Engine at 128b; SQ Engine pads to 128b or uses two 64b beats). |
| `credit_manager` | `credit_manager.v` | `CREDITS_MAX`, `NUM_QUEUES` | Global credit pool with dec/inc interface |
| `stat_counters` | `stat_counters.v` | `NUM_COUNTERS` | Metric accumulation and export |

### 3.4 Top-Level Design Decisions

- **Clock domain:** Single 1 GHz clock (matches I/O chiplet domain, no CDC needed)
- **SRAM access:** Single-port SRAM banks with round-robin arbiter (sufficient at 1 GHz for 40M IOPS)
- **Data widths:** 64-bit MMIO data bus, 512-bit internal SQE bus (one SQE per SRAM read)
- **Parameterization:** All queue counts/depths are Verilog `parameter` — synthesize multiple configs from the same source

---

## 4. SQ Engine — Mailbox Ingestion FSM

The SQ Engine is the most complex module. It receives compact 24-byte SQE descriptors via the MMIO mailbox interface (3 sequential 8-byte writes), decodes them into full 64-byte NVMe SQEs, expands PRP entries for the DMA address list, and injects the result into the SRAM SQ buffer.

### 4.0 Command composition

According to RTL spec, the 24 bytes arrive in three 8-byte chunks and contain exactly this:

- **Bytes 0-1:** Opcode (e.g., "I am a Read command") and flags.
- **Bytes 2-3:** Namespace ID (NSID) (Which virtual drive to talk to).
- **Bytes 4-11:** Starting LBA (The exact sector on the disk we want to read).
- **Bytes 12-13:** Number of Logical Blocks (NLB) (How many sectors to read).
- **Bytes 14-15:** Queue Pair ID (Which queue this belongs to).
- **Bytes 16-23:** Host Buffer Address (The physical memory address in host DRAM where the SSD should put the data).

Notice what is **missing**:

1. **Command ID (CID):** The CPU doesn't assign this anymore.
2. **PRP Lists / Pointers:** The CPU doesn't calculate the complex memory page boundaries anymore.
3. **Reserved zero-padding:** Wasted space is removed to save PCIe bandwidth.

### 4.1 State Machine

```
                      reset
                        |
                        v
                ┌───────────────┐
                │    S_IDLE     │<──────────────────────────────────┐
                │               │                                  │
                │ Wait for MMIO │                                  │
                │ write to      │                                  │
                │ mailbox region│                                  │
                └───────┬───────┘                                  │
                        │                                          │
                mmio_wr_valid &&                                   │
                addr in [MAILBOX_BASE,                             │
                         MAILBOX_BASE + NQ * STRIDE)               │
                        │                                          │
                        v                                          │
                ┌───────────────┐                                  │
                │  S_LATCH_0    │  Store bytes [0:7]               │
                │               │  Extract queue_id from addr      │
                │  1st 8B write │  write_count[qid] <- 1           │
                └───────┬───────┘                                  │
                        │                                          │
                mmio_wr_valid && same qid                          │
                        │                                          │
                        v                                          │
                ┌───────────────┐                                  │
                │  S_LATCH_1    │  Store bytes [8:15]              │
                │               │  write_count[qid] <- 2           │
                │  2nd 8B write │                                  │
                └───────┬───────┘                                  │
                        │                                          │
                mmio_wr_valid && same qid                          │
                        │                                          │
                        v                                          │
                ┌───────────────┐                                  │
                │  S_DECODE     │  All 24B received                │
                │               │  Parse compact SQE:              │
                │  Parse fields │  - opcode, flags [0:1]           │
                │  (1 cycle)    │  - nsid [2:3]                    │
                │               │  - lba [4:11]                    │
                │               │  - nlb [12:13]                   │
                │               │  - qpair_id [14:15]              │
                │               │  - buf_addr [16:23]              │
                │               │  Assign CID from counter 
                │               |  Check credit to see if queue full
                └───────┬───────┘                                  │
                        │                                          │
                        v                                          │
                ┌───────────────┐                                  │
                │  S_PRP_CALC   │  Compute transfer_size =         │
                │               │    (nlb+1) * lba_size            │
                │  PRP decision │                                  │
                │  (1 cycle)    │  Branch on transfer_size:        │
                └──┬────┬───┬──┘    <=4KB    <=8KB    >8KB        │
                   │    │   │                                      │
        ┌──────────┘    │   └──────────┐                           │
        v               v              v                           │
 ┌──────────────┐ ┌────────────┐ ┌──────────────┐                 │
 │ S_PRP_SIMPLE │ │ S_PRP_DUAL │ │ S_PRP_LIST   │                 │
 │              │ │            │ │              │                 │
 │ PRP1=buf     │ │ PRP1=buf   │ │ PRP1=buf     │                 │
 │ PRP2=0       │ │ PRP2=buf+4K│ │ Loop: write  │                 │
 │ (1 cycle)    │ │ (1 cycle)  │ │ PRP entries  │                 │
 │              │ │            │ │ to SRAM      │                 │
 └──────┬───────┘ └──────┬─────┘ │ (N cycles,   │                 │
        │                │       │  N=num_pages) │                 │
        │                │       └──────┬───────┘                 │
        └────────┬───────┘──────────────┘                          │
                 │                                                 │
                 v                                                 │
         ┌───────────────┐                                         │
         │  S_INJECT     │  Build full 64B SQE                    │
         │               │  Write to SQ SRAM buffer               │
         │  Write SQE to │  Decrement credit counter              │
         │  SRAM + signal│  Assert sq_ready signal                │
         │  (1 cycle)    │  Increment stat counters               │
         │               │  Record T_submit_exit timestamp        │
         └───────┬───────┘                                         │
                 │                                                 │
                 └─────────────────────────────────────────────────┘
                            back to S_IDLE
```

#### 24-Bytes to 64-Bytes:

1. CPU sends the 24-byte "ingredients list" to the `sq_engine`.
2. Our hardware automatically assigns a free CID using a simple hardware counter (`CID assign`).
3. Our hardware looks at the **Host Buffer Address** (DRAM) and does the page boundary math instantly in silicon (`S_PRP_CALC` state).
4. Our hardware takes the ingredients, the CID, and the PRPs, maps them to the exact bit-offsets defined by the NVMe 2.0 specification, pads the rest with zeros, and drops the perfect 64-byte struct into the SRAM.

#### The 6-Cycle 4KB Read Trace

**State 0: `S_IDLE` (The Baseline)**

- **What is happening:** The FSM is resting, monitoring the `mmio_wr_valid` signal from the `mmio_decoder`. It is waiting for the CPU to start a submission.

**Cycle 1: `S_LATCH_0` (The First Write)**

- **Trigger:** The CPU's first 8-byte MMIO write hits the mailbox.
- **Action:** The hardware stores bytes [0:7] into a temporary register (a flip-flop) dedicated to that specific Queue ID. It also extracts the Queue ID from the memory address so it knows which queue is submitting.

**Cycle 2: `S_LATCH_1` (The Second Write)**

- **Trigger:** The CPU sends the second 8-byte write for the same Queue ID.
- **Action:** The hardware stores bytes into the next segment of the latch.

**Cycle 3: `S_DECODE` (The Final Write & Parse)**

- **Trigger:** The CPU sends the third and final 8-byte write. All 24 bytes of the compact command are now inside the hardware.
- **Action:** In this single nanosecond, several things happen in parallel:
  1. The hardware parses all the fields (Opcode, Namespace ID, Logical Block Address, etc.).
  2. It automatically assigns a unique Command ID (CID) using its internal hardware counter.
  3. **Crucial Check:** It checks the `credit_manager`. If `credits == 0`, the pipeline is full, and the FSM stalls right here to prevent overflowing the system. Assuming credits are available, it moves on.

**Cycle 4: `S_PRP_CALC` (The Math Phase)**

- **Action:** The hardware calculates the total size of the data transfer. It multiplies the Number of Logical Blocks (NLB + 1) by the Block Size (usually 4KB).
- **Decision:** Because the host requested exactly one 4KB block, the transfer size is <= 4KB. The FSM immediately branches to the `S_PRP_SIMPLE` state.

**Cycle 5: `S_PRP_SIMPLE` (The Easy Pointer)**

- **Action:** Since the data fits perfectly inside a single 4KB memory page, the hardware takes the Host Buffer Address (provided by the CPU in the 24-byte command) and maps it directly to the `PRP1` field. It sets `PRP2` to `0` because a second page isn't needed.

**Cycle 6: `S_INJECT` (Building and Dispatching)**

- **Action:** The hardware concatenates everything—the parsed fields, the newly generated CID, and the PRP pointers—into the final, NVMe-compliant 64-byte SQE.
- **Memory Write:** It sends a request (`sram_req`) to the `sram_arbiter`. Once granted, it drops the 64-byte SQE into the SRAM SQ Buffer.
- **Signaling:** In the same cycle, it fires a pulse to decrement the credit pool (`credit_dec`), increments the telemetry counters (`stat_mailbox_sub`), and asserts `sq_ready` to tell the downstream DMA sequencer that a command is ready to be fetched.
- **End:** The FSM loops immediately back to `S_IDLE`.

### 4.2 Cycle Budget

| Scenario | States traversed | Total cycles |
|----------|-----------------|-------------|
| 4KB transfer (typical) | LATCH x3 + DECODE + PRP_CALC + PRP_SIMPLE + INJECT | **6 cycles** |
| 8KB transfer | LATCH x3 + DECODE + PRP_CALC + PRP_DUAL + INJECT | **6 cycles** |
| 128KB transfer (worst case) | LATCH x3 + DECODE + PRP_CALC + PRP_LIST(31) + INJECT | **38 cycles** |

At 1 GHz / 40M IOPS = 25 cycles per I/O average. The typical 4KB path (6 cycles) leaves 19 cycles of headroom. Even the worst-case 128KB path (38 cycles) is rare and amortized across mostly 4KB I/Os.

### 4.3 I/O Ports

| Port | Direction | Width | Description |
|------|-----------|-------|-------------|
| `mmio_wr_valid` | in | 1 | MMIO write strobe from decoder |
| `mmio_wr_addr` | in | 16 | BAR0 offset address |
| `mmio_wr_data` | in | 64 | 8B MMIO write data |
| `sram_req` | out | 1 | SRAM write request to arbiter |
| `sram_addr` | out | SRAM_AW | SRAM write address |
| `sram_wdata` | out | 64 | SRAM write data |
| `sram_grant` | in | 1 | SRAM access granted by arbiter |
| `credit_avail` | in | 1 | Credits > 0 from credit manager |
| `credit_dec` | out | 1 | Decrement credit pulse |
| `sq_ready` | out | 1 | New SQE available in SRAM (to NVMe backend) |
| `sq_qid` | out | log2(NQ) | Queue ID of ready SQE |
| `stat_mailbox_sub` | out | 1 | Pulse: mailbox submission completed |
| `stat_prp_simple` | out | 1 | Pulse: PRP simple expansion (<=8KB) |
| `stat_prp_list` | out | 1 | Pulse: PRP list expansion (>8KB) |

### 4.4 Key Design Points

- **Per-queue latch registers:** Each queue has its own 24B staging latch (in flip-flops, not SRAM — only 24B x NQ, small enough). This allows interleaved writes from different queues without blocking.
- **Credit check at S_DECODE:** If credits = 0 when the 3rd write arrives, the FSM stalls at S_DECODE until a credit is replenished. The MMIO write is held (backpressure to PCIe).
- **PRP list loop:** S_PRP_LIST iterates once per 4KB page, writing each PRP entry to SRAM. For 128KB transfer = 31 entries = 31 SRAM writes. This is the worst-case latency path.
- **Multi-queue concurrency:** Only one queue's SQE is being processed at a time (single FSM). At 6 cycles per 4KB I/O and 25-cycle budget, this supports ~4 queues submitting every cycle — sufficient for 16-64 QP at 40M IOPS.
- **CID assignment:** Per-queue free-running counter, wraps at QUEUE_DEPTH. Matches the CID assignment logic in the Mode B simulation (controller.cc).

---

## 5. CQ Engine — Batched Completion FSM

The CQ Engine accumulates 16-Bytes CQEs from the NVMe backend in SRAM batch buffers and flushes them to host DRAM in batches, controlled by count threshold (N) and timeout (T) triggers. It also maintains the hint_ready counter that drives the poll-lite completion path.

### 5.1 State Machine

```
                      reset
                        |
                        v
                ┌───────────────┐
                │   C_IDLE      │<─────────────────────────────────┐
                │               │                                  │
                │ Wait for CQE  │                                  │
                │ from NVMe     │                                  │
                │ backend       │                                  │
                └───────┬───────┘                                  │
                        │                                          │
                cqe_valid                                          │
                (backend completed an I/O)                         │
                        │                                          │
                        v                                          │
                ┌───────────────┐                                  │
                │  C_ENQUEUE    │  Write 16B CQE to SRAM           │
                │               │  CQ buffer at [qid][cq_tail]    │
                │  Store CQE in │  Increment cq_tail[qid]         │
                │  SRAM batch   │  Increment batch_count[qid]     │
                │  buffer       │  Start timer if batch_count==1  │
                │  (1 cycle)    │  Replenish credit (+1)          │
                │               │  Update hint_ready counter (+1) │
                └───────┬───────┘                                  │
                        │                                          │
                        v                                          │
                ┌───────────────┐                                  │
                │  C_CHECK      │                                  │
                │               │  Two flush triggers:             │
                │  Evaluate     │  - batch_count[qid] >= N         │
                │  flush cond.  │    (count threshold)             │
                │  (1 cycle)    │  - timer[qid] expired            │
                │               │    (timeout threshold T)         │
                └──┬─────────┬──┘                                  │
                   │         │                                     │
          neither  │         │  either trigger fires               │
                   │         │                                     │
                   v         v                                     │
             back to   ┌───────────────┐                           │
             C_IDLE    │  C_FLUSH      │  Read CQEs from SRAM     │
                       │               │  Issue DMA write to host  │
                       │  DMA write    │  DRAM CQ ring             │
                       │  CQEs to host │  (N cycles for N CQEs,   │
                       │  DRAM CQ      │   1 SRAM read per CQE)   │
                       └───────┬───────┘                           │
                               │                                   │
                               v                                   │
                       ┌───────────────┐                           │
                       │  C_WRITEBACK  │  Update host-visible      │
                       │               │  CQ head pointer          │
                       │  Update host  │  Decrement hint_ready     │
                       │  CQ pointers  │    by flush count         │
                       │  (1 cycle)    │  Reset batch_count[qid]   │
                       │               │  Reset timer[qid]         │
                       │               │  Record T_cqe_visible     │
                       └───────┬───────┘                           │
                               │                                   │
                               └───────────────────────────────────┘
                                        back to C_IDLE
```

### 5.2 Cycle Budget

| Scenario | States traversed | Total cycles |
|----------|-----------------|-------------|
| Enqueue, no flush | C_ENQUEUE + C_CHECK | **2 cycles** |
| Batch flush (N CQEs) | C_ENQUEUE + C_CHECK + C_FLUSH(N) + C_WRITEBACK | **N + 3 cycles** |
| Example: N=8 batch flush | | **11 cycles** |

### 5.3 UNCORE_STATUS Hint Register

```
 63                              32 31                               0
+----------------------------------+----------------------------------+
|     hint_ready (CQEs pending)    |     sq_credits (available)       |
+----------------------------------+----------------------------------+
  ^ Incremented in C_ENQUEUE          ^ Managed by Credit Manager
  v Decremented in C_WRITEBACK          (dec on SQ submit,
    (by flush count)                     inc on CQE enqueue)
```

SPDK reads this register once per poll cycle:
- `hint_ready == 0` → skip CQ entirely (poll-lite saves ~200 cycles of empty scanning)
- `hint_ready > 0` → drain DRAM CQ normally
- `sq_credits == 0` → backpressure, retry submission later
- `sq_credits > 0` → submit via mailbox

### 5.4 I/O Ports

| Port | Direction | Width | Description |
|------|-----------|-------|-------------|
| `cqe_valid` | in | 1 | CQE ready from NVMe backend |
| `cqe_data` | in | 128 | 16B CQE (status, CID, SQ head, etc.) |
| `cqe_qid` | in | log2(NQ) | Target CQ ID |
| `sram_req` | out | 1 | SRAM access request |
| `sram_addr` | out | SRAM_AW | SRAM read/write address |
| `sram_wdata` | out | 128 | CQE data to write |
| `sram_rdata` | in | 128 | CQE data read (during flush) |
| `sram_grant` | in | 1 | SRAM access granted |
| `credit_inc` | out | 1 | Credit replenishment pulse |
| `hint_ready` | out | 32 | Current pending CQE count (for UNCORE_STATUS[63:32]) |
| `dma_wr_req` | out | 1 | DMA write request to host DRAM |
| `dma_wr_addr` | out | 64 | Host DRAM CQ ring address |
| `dma_wr_data` | out | 128 | CQE data for DMA |
| `stat_cqe_enqueued` | out | 1 | Pulse: CQE enqueued to batch buffer |
| `stat_batch_flush` | out | 1 | Pulse: batch flush triggered |

### 5.5 Key Design Points

- **Per-queue state in flip-flops:** cq_tail pointer, batch_count, timer value — small (< 64 bits per queue), kept in registers for single-cycle access. CQE data goes to SRAM.
- **Dual flush triggers:** Count threshold (BATCH_N, e.g. 8) for throughput. Timeout (BATCH_T, e.g. 1000 cycles = 1 us at 1 GHz) for latency bound. Whichever fires first.
- Batching
  - Less Transaction Layer Packet (TLP) overheads (**bus benefit**): Header of a TLP has 12 to 16 Bytes cost. Batching submit save 8 TLPs to only 1TLP.
  - Cacheline write benefit (**memory benefit**): DRAM and LLC are managed in 64-byte cachelines. Single CQE (16-byte) causes write amplification, but 8 CQE batch (128-byte) are exactly 2 cachelines.
  - Amortizing the software poll (**CPU benefit**): CPU polls for 8 CQE for only 1 software handle.


- **hint_ready counter:** Combinational output from per-queue batch_count sum. SPDK reads it via UNCORE_STATUS register — no SRAM access needed for poll-lite.
- **Credit replenishment:** Happens in C_ENQUEUE (immediately when CQE arrives), not at flush time. This matches the Mode B simulation behavior — credits represent "I/O pipeline capacity" not "CQ buffer space."
- **Timer implementation:** Free-running down-counter per queue, loaded with BATCH_T on first CQE arrival, fires when reaching zero. Reset on flush. All timers tick from the same global cycle counter — only the comparison logic is per-queue.

---

## 6. Doorbell Coalescer FSM

The Doorbell Coalescer aggregates per-I/O doorbell writes into batched device notifications, reducing PCIe fabric congestion. In standard NVMe, SPDK writes a doorbell for every SQE submitted and every CQE consumed. The coalescer batches multiple updates into one.

### 6.1 State Machine

```
                      reset
                        |
                        v
                ┌───────────────┐
                │   D_IDLE      │<─────────────────────────────────┐
                │               │                                  │
                │ Per-queue     │  All queues monitored in         │
                │ doorbell      │  parallel via per-queue          │
                │ monitors      │  registers (no FSM per queue)    │
                └───────┬───────┘                                  │
                        │                                          │
                db_write_valid                                     │
                (doorbell MMIO write from MMIO decoder)            │
                        │                                          │
                        v                                          │
                ┌───────────────┐                                  │
                │  D_ACCUMULATE │  Per-queue logic:                │
                │               │  db_pending[qid] <-              │
                │  Update queue │    new_tail - last_sent_tail     │
                │  state        │  db_count[qid] += 1              │
                │  (1 cycle)    │  Start timer if db_count==1      │
                │               │  Store latest tail value         │
                └───────┬───────┘                                  │
                        │                                          │
                        v                                          │
                ┌───────────────┐                                  │
                │  D_EVAL       │  Two coalescing triggers:        │
                │               │  - db_count[qid] >= B            │
                │  Check flush  │    (batch size threshold)        │
                │  condition    │  - timer[qid] expired            │
                │  (1 cycle)    │    (coalescing timeout)          │
                └──┬─────────┬──┘                                  │
                   │         │                                     │
          neither  │         │  either trigger                     │
                   │         │                                     │
                   v         v                                     │
             back to   ┌───────────────┐                           │
             D_IDLE    │  D_SEND       │  Send single coalesced   │
                       │               │  doorbell to NVMe device │
                       │  Issue merged │  with latest tail value  │
                       │  doorbell     │  Reset db_count[qid]     │
                       │  (1 cycle)    │  Reset timer[qid]        │
                       └───────┬───────┘                           │
                               │                                   │
                               └───────────────────────────────────┘
```

### 6.2 Cycle Budget

| Scenario | Total cycles |
|----------|-------------|
| Coalescing (no send) | **2 cycles** (accumulate + eval) |
| Send coalesced doorbell | **3 cycles** (accumulate + eval + send) |

### 6.3 Coalescing Example (B=4)

```
DB writes:  | DB1 | DB2 | DB3 | DB4 | DB5 | DB6 | DB7 | DB8 |

Without coalescer (baseline):
Device DBs: | DB1 | DB2 | DB3 | DB4 | DB5 | DB6 | DB7 | DB8 |  = 8 PCIe writes

With coalescer (B=4):
Device DBs: |                   | DB4 |                   | DB8 |  = 2 PCIe writes
                                  ^                         ^
                            count=4, flush           count=4, flush
                            sends tail=4             sends tail=8

Result: 75% reduction in device-facing doorbell traffic
```

### 6.4 I/O Ports

| Port | Direction | Width | Description |
|------|-----------|-------|-------------|
| `db_wr_valid` | in | 1 | Doorbell write from MMIO decoder |
| `db_wr_qid` | in | log2(NQ) | Queue ID from doorbell address |
| `db_wr_tail` | in | 16 | New tail pointer value |
| `db_wr_is_sq` | in | 1 | 1=SQ tail doorbell, 0=CQ head doorbell |
| `dev_db_valid` | out | 1 | Coalesced doorbell ready for device |
| `dev_db_qid` | out | log2(NQ) | Queue ID for coalesced doorbell |
| `dev_db_tail` | out | 16 | Coalesced tail value (latest) |
| `dev_db_is_sq` | out | 1 | SQ or CQ doorbell type |
| `stat_db_received` | out | 1 | Pulse: doorbell write received |
| `stat_db_coalesced` | out | 1 | Pulse: coalesced doorbell sent to device |

### 6.5 Key Design Points

- **No SRAM needed:** All per-queue state (latest_tail, last_sent_tail, db_count, timer) fits in flip-flops. At 16 queues x ~80 bits = 1280 bits total. Even at 64 queues = 5120 bits — trivial in registers.
- **Parallel queue monitoring:** Unlike SQ/CQ engines, the coalescer doesn't serialize across queues. Each queue's counter and timer run independently in parallel — implemented as register arrays indexed by qid.
- **Mode B interaction:** In Mode B, SQ doorbells are mostly eliminated (mailbox bypasses them). The coalescer still handles CQ head doorbells and any admin queue doorbells that use the standard path.
- **Timer sharing:** All per-queue timers tick from the same global cycle counter. Only the comparison logic is per-queue — one comparator per queue, not one counter per queue.
- **Coalescing parameters:** `COALESCE_COUNT` (B) and `TIMEOUT_CYCLES` are Verilog parameters, allowing synthesis at different operating points.

---

## 7. SRAM Layout and Sizing Analysis

### 7.1 SRAM Address Map

```
Address
0x0000  ┌─────────────────────────────────────────────┐
        │  SQ Buffers                                 │
        │  Full 64B SQEs after mailbox expansion      │
        │  Size = NQ x QD x 64 bytes                  │
        │  Indexed: base + (qid x QD + sq_idx) x 64  │
SQ_END  ├─────────────────────────────────────────────┤
        │  CQ Buffers                                 │
        │  16B CQEs in per-queue batch rings          │
        │  Size = NQ x QD x 16 bytes                  │
        │  Indexed: base + (qid x QD + cq_idx) x 16  │
CQ_END  ├─────────────────────────────────────────────┤
        │  PRP Lists                                  │
        │  For transfers > 8KB, 8B per 4KB page       │
        │  Size = NQ x QD x MAX_PRP_ENTRIES x 8 bytes │
        │  (MAX_PRP_ENTRIES = max_transfer/4KB - 1)   │
PRP_END ├─────────────────────────────────────────────┤
        │  Metadata                                   │
        │  Per-queue: head/tail, phase, CID, base addr│
        │  Size = NQ x 64 bytes                       │
META_END└─────────────────────────────────────────────┘
```

### 7.2 Sizing Formula

```
Parameters:
  NQ  = Number of queue pairs         (16 or 64)
  QD  = Queue depth per pair           (64 or 128)
  LBA = LBA size in bytes              (4096)
  MT  = Max transfer size in bytes     (131072 = 128KB)
  MPE = Max PRP entries = MT/4KB - 1   (31)

SQ Buffers:    NQ x QD x 64 B
CQ Buffers:    NQ x QD x 16 B
PRP Lists:     NQ x QD x MPE x 8 B
Metadata:      NQ x 64 B
─────────────────────────────────────
Total SRAM:    NQ x (QD x (64 + 16 + MPE x 8) + 64)
```

### 7.3 Concrete Sizing for Paper Configurations

| Component | Config A (16QP/QD64) | Config B (64QP/QD64) | Config C (16QP/QD128) | Config D (64QP/QD128) |
|-----------|---------------------|---------------------|----------------------|----------------------|
| SQ Buffers | 64 KB | 256 KB | 128 KB | 512 KB |
| CQ Buffers | 16 KB | 64 KB | 32 KB | 128 KB |
| PRP Lists | 248 KB | 992 KB | 496 KB | 1,984 KB |
| Metadata | 1 KB | 4 KB | 1 KB | 4 KB |
| **Total SRAM** | **329 KB** | **1,316 KB** | **657 KB** | **2,628 KB** |
| 4KB-only variant (no PRP) | 81 KB | 324 KB | 161 KB | 644 KB |

### 7.4 SRAM Area Estimation Methodology (Hybrid Approach)

**Step 1: Logic Area (from Synopsys DC)**
- Synthesize all Verilog modules with ASAP7 standard cells
- SRAM modeled as register arrays in RTL — DC gives overestimated logic area
- Extract pure logic area = total DC area minus register array area (DC reports breakdown of sequential vs. combinational cells)

**Step 2: SRAM Area (analytical model)**
- ASAP7 HD (high-density) SRAM bitcell: **0.027 um^2/bit**
- SRAM area = total_bits x bitcell_area x overhead_factor
- Overhead factor accounts for:
  - Row/column decoders (~15%)
  - Sense amplifiers (~10%)
  - Peripheral circuits (~10%)
  - Routing/spacing (~15%)
- Typical overhead_factor = **1.5x** (conservative)

**Step 3: Total Die Area**
- Total = Logic area (from DC) + SRAM area (analytical)
- Report as: "X mm^2 logic + Y mm^2 SRAM = Z mm^2 total"

### 7.5 Area Estimates

| Config | SRAM bits | SRAM area (mm^2) | Notes |
|--------|-----------|-------------------|-------|
| A (16QP/QD64) | 2,695,168 | ~0.109 | Matches gem5 simulation config |
| B (64QP/QD64) | 10,780,672 | ~0.437 | Production queue count |
| C (16QP/QD128) | 5,382,144 | ~0.218 | Deep queue depth |
| D (64QP/QD128) | 21,528,576 | ~0.872 | Full production scale |

**Reference:** Apple M2 CPU die = 223 mm^2, Intel Sapphire Rapids I/O tile = ~40 mm^2. Even Config D at ~1 mm^2 total is < 2.5% of a typical I/O tile.

### 7.6 Paper Recommendation

Present both "4KB-only" and "full PRP" variants side by side:
- **4KB-only** (81-644 KB, ~0.033-0.261 mm^2): The compelling story for AI/embedding workloads where all I/Os are small random reads
- **Full PRP** (329-2,628 KB, ~0.109-0.872 mm^2): Shows generality for mixed workloads with larger transfers

PRP lists dominate SRAM (~75%). For the primary AI use case, they're unnecessary — this is a strong point for the paper.

### 7.7 Flip-Flop Budget (NOT in SRAM)

Small per-queue state kept in registers for single-cycle access:
- Doorbell Coalescer: ~80 bits x NQ (latest_tail, last_sent_tail, db_count, timer)
- CQ Engine: ~64 bits x NQ (cq_tail, batch_count, timer_value)
- SQ Engine: ~200 bits x NQ (24B mailbox latch + write_count + CID counter)
- Total at 64 queues: ~22 Kbits — negligible compared to SRAM

---

## 8. Credit Manager

The Credit Manager maintains a global credit pool that enforces backpressure between the SQ submission path and the CQ completion path.

### 8.1 Behavior

- **Pool size:** Configurable via `CREDITS_MAX` parameter (default 64)
- **Decrement:** SQ Engine asserts `credit_dec` when a mailbox SQE is injected (S_INJECT state)
- **Increment:** CQ Engine asserts `credit_inc` when a CQE is enqueued (C_ENQUEUE state)
- **Visibility:** Current credit count exposed as UNCORE_STATUS[31:0] — combinational output, no latency
- **Stall:** When credits = 0, SQ Engine stalls at S_DECODE (backpressure to PCIe)

### 8.2 Implementation

Simple up/down counter with saturation:
- Increment and decrement can happen in the same cycle (credit_inc && credit_dec → no change)
- Saturates at 0 (no underflow) and CREDITS_MAX (no overflow)
- Single register: `reg [log2(CREDITS_MAX):0] credits`

### 8.3 Ports

| Port | Direction | Width | Description |
|------|-----------|-------|-------------|
| `credit_dec` | in | 1 | Decrement pulse from SQ Engine |
| `credit_inc` | in | 1 | Increment pulse from CQ Engine |
| `credit_avail` | out | 1 | Credits > 0 (to SQ Engine) |
| `credit_count` | out | 32 | Current count (for UNCORE_STATUS[31:0]) |
| `stat_credit_stall` | out | 1 | Pulse: credit_dec attempted when credits = 0 |

---

## 9. Stat Counters

The Stat Counters module accumulates telemetry pulses from all engines and provides a register-read interface for exporting metrics.

### 9.1 Metrics Tracked

| # | Counter | Source | Description |
|---|---------|--------|-------------|
| 1 | `mailbox_submissions` | SQ Engine | Compact SQEs received via mailbox |
| 2 | `prp_simple_expansions` | SQ Engine | I/Os where PRP1/PRP2 sufficed (<=8KB) |
| 3 | `prp_list_expansions` | SQ Engine | I/Os where full PRP list generated (>8KB) |
| 4 | `credit_stalls` | Credit Manager | Times submission stalled on zero credits |
| 5 | `hint_reads_total` | MMIO Decoder | Total reads of UNCORE_STATUS register |
| 6 | `hint_reads_empty` | MMIO Decoder | Reads where hint_ready = 0 |
| 7 | `cqe_enqueued` | CQ Engine | CQEs enqueued to batch buffer |
| 8 | `batch_flushes` | CQ Engine | Batch flush events |
| 9 | `db_received` | DB Coalescer | Doorbell writes received |
| 10 | `db_coalesced` | DB Coalescer | Coalesced doorbells sent to device |

### 9.2 Implementation

Array of 64-bit saturating counters. Each counter increments on its corresponding pulse input. Read interface: address selects counter index, data output returns 64-bit count. Reset clears all counters.

---

## 10. Verification Plan

### 10.1 Strategy: Self-Checking Directed Testbenches

**Why not UVM:** This is a feasibility study, not a tapeout. The RTL serves two purposes: (1) prove the control logic is synthesizable and meets timing at 1 GHz, (2) generate credible PPA numbers. The behavioral correctness of the IO-Uncore algorithms has already been validated through Phase 1 baseline measurements and Phase 2 Mode A + Mode B gem5 full-system simulation with real SPDK workloads across hundreds of hours of simulation.

The RTL testbenches verify that the hardware implementation of these already-proven algorithms is faithful to the spec. This is a much narrower verification scope than proving a novel algorithm correct from scratch.

**What we explicitly defer (future work):** Random stimulus (UVM), formal property checking, gate-level simulation. These are warranted for tapeout but not for a feasibility PPA study.

### 10.2 Reviewer Defense Rationale

For the paper and potential rebuttal:

> "The IO-Uncore control logic was first validated at the behavioral level through full-system simulation (Phase 2, Section X), where real NVMe workloads exercised the mailbox submission, credit flow control, and CQ batching paths end-to-end. The RTL implementation was then verified against the same behavioral specification using directed self-checking testbenches covering all steady-state and boundary-condition scenarios. Functional equivalence between the simulation model and the synthesized RTL was confirmed by comparing per-I/O cycle counts and queue state transitions across matching workload traces."

### 10.3 Testbench Architecture

```
┌────────────────────────────────────────────────────────────────┐
│                      tb_<module>.v                              │
│                                                                │
│  ┌────────────────┐    ┌────────────────┐    ┌──────────────┐  │
│  │  Stimulus      │───>│  DUT           │───>│  Checker     │  │
│  │  Generator     │    │  (module under │    │              │  │
│  │                │    │   test)        │    │  - Expected  │  │
│  │  - Task-based  │    │               │    │    values    │  │
│  │  - Reads from  │    │               │    │  - Auto      │  │
│  │    test vectors│    │               │    │    compare   │  │
│  │  - Configurable│    │               │    │  - PASS/FAIL │  │
│  └────────────────┘    └────────────────┘    └──────────────┘  │
│                                                                │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  Monitor / Logger                                        │  │
│  │  - Cycle-accurate trace output (VCD for waveform debug)  │  │
│  │  - Per-test summary: cycles, SRAM accesses, state visits │  │
│  │  - Compare against gem5 simulation golden traces         │  │
│  └──────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────┘

Execution: iverilog + vvp (open source) or VCS (if available)
Waveform debug: GTKWave (open source) or DVE/Verdi (Synopsys)
```

### 10.4 Test Cases

#### TB1: SQ Engine (`tb_sq_engine.v`) — 7 tests

| Test | Scenario | Checks |
|------|----------|--------|
| T1.1 | Single 4KB mailbox submission | 3 MMIO writes -> full state traversal. SQE in SRAM matches expected fields. Credit decremented. sq_ready asserted 1 cycle. |
| T1.2 | 8KB submission (dual PRP) | PRP1=buf_addr, PRP2=buf_addr+4096. State visits S_PRP_DUAL. |
| T1.3 | 128KB submission (PRP list) | 31 PRP entries written to SRAM. S_PRP_LIST iterated 31 times. Total 38 cycles. All PRP addresses page-aligned and sequential. |
| T1.4 | Back-to-back burst (8 commands) | 8 consecutive submissions to same queue. Each gets unique CID (0-7). All 8 SQEs in SRAM. Credits decremented by 8. |
| T1.5 | Credit exhaustion stall | Set credits=1, submit 2 commands. First completes, second stalls at S_DECODE. Replenish 1 credit -> second proceeds. No data corruption. |
| T1.6 | Multi-queue interleave | Alternate mailbox writes between QID 0 and QID 1. Per-queue latches are independent, no cross-contamination. |
| T1.7 | CID wraparound | Submit QD commands (64), verify CID cycles 0->63. Submit one more -> CID wraps to 0. |

#### TB2: CQ Engine (`tb_cq_engine.v`) — 6 tests

| Test | Scenario | Checks |
|------|----------|--------|
| T2.1 | Single CQE enqueue (no flush) | CQE in SRAM. batch_count=1. hint_ready=1. credit_inc pulsed. No DMA write. Timer started. |
| T2.2 | N-threshold flush (N=8) | Enqueue 8 CQEs. Flush on 8th. 8 SRAM reads -> 8 DMA writes. hint_ready returns to 0. |
| T2.3 | Timeout flush (T=1000 cycles) | Enqueue 3 CQEs, wait. After 1000 cycles, flush 3 CQEs. Verify exact flush cycle. |
| T2.4 | Hint register accuracy | Enqueue 5 CQEs across 3 queues (2+2+1). hint_ready=5. Flush queue 0 -> hint_ready=3. |
| T2.5 | Concurrent enqueue during flush | While flushing queue 0, enqueue CQE to queue 1. Queue 1 CQE not lost or delayed beyond arbiter contention. |
| T2.6 | CQ ring wraparound | Enqueue QD CQEs -> tail wraps. DMA addresses wrap correctly in host CQ ring. |

#### TB3: Doorbell Coalescer (`tb_db_coalescer.v`) — 4 tests

| Test | Scenario | Checks |
|------|----------|--------|
| T3.1 | Count-based coalescing (B=4) | 8 doorbell writes -> exactly 2 device doorbells (at write 4 and 8). Each carries latest tail. |
| T3.2 | Timer-based coalescing | 2 doorbells then wait. After timeout, 1 device doorbell with tail from 2nd write. |
| T3.3 | Multi-queue independence | Doorbells to QID 0 and QID 3 interleaved. Each queue coalesced independently. |
| T3.4 | SQ vs CQ doorbell | Mix SQ tail and CQ head doorbells. Both types coalesced independently. db_is_sq preserved. |

#### TB4: Integration (`tb_io_uncore_top.v`) — 5 tests

| Test | Scenario | Checks |
|------|----------|--------|
| T4.1 | Full I/O round-trip | Mailbox submit -> backend delay (mock) -> CQE enqueue -> batch flush -> hint read. End-to-end cycle count matches pipeline depth. |
| T4.2 | SRAM arbiter contention | Simultaneous SQ write + CQ flush. Arbiter grants round-robin. Both complete within expected cycles + 1 contention penalty. |
| T4.3 | Credit flow stress test | Fill credit pool (64 submits), drain via 64 completions. Credits cycle 64->0->64. No deadlock. |
| T4.4 | UNCORE_STATUS register | Read status at various points. [31:0]=credits, [63:32]=hint_ready. Both fields consistent. |
| T4.5 | Stat counter accuracy | Mixed workload (20 submits, 20 completes, 10 doorbells). All stat counters match expected values. |

---

## 11. Synthesis Flow and Paper Deliverables

### 11.1 Synopsys DC Setup with ASAP7

**`.synopsys_dc.setup`:**
```tcl
set_app_var target_library asap7sc7p5t_AO_RVT_TT_nldm_211120.db
set_app_var symbol_library asap7sc7p5t.sdb
set_app_var synthetic_library dw_foundation.sldb
set_app_var link_library "* $target_library $synthetic_library"
set_app_var search_path [concat $search_path ./src ./lib]
set_app_var designer "IO-Uncore Phase 3"
```

### 11.2 Synthesis Flow (per configuration)

For each config (NQ, QD) in {(16,64), (64,64), (16,128), (64,128)}:

1. **Analyze** all Verilog sources
2. **Elaborate** top module with parameter overrides: `elaborate io_uncore_top -parameters "NUM_QUEUES=NQ, QUEUE_DEPTH=QD, CREDITS_MAX=QD, BATCH_N=8, BATCH_T=1000, COALESCE_B=4"`
3. **Constrain** (timing + load) via `constraints.tcl`:
   ```tcl
   create_clock clk -period 1.0           # 1 GHz = 1 ns period
   set_clock_latency 0.05 clk             # 50 ps insertion delay
   set_input_delay 0.2 -clock clk [all_inputs]
   set_output_delay 0.2 -clock clk [all_outputs]
   set_load 0.01 [all_outputs]            # ~10 fF typical
   set_max_fanout 16 [all_inputs]
   ```
4. **Check + Compile**: `check_design`, `compile_ultra -gate_clock` (clock gating for power), `compile_ultra -incremental` (refinement)
5. **Report**:
   - `report_timing -max_paths 10` -> timing report
   - `report_area -hierarchy` -> area report
   - `report_power -analysis_effort high` -> power report
   - `report_qor` -> quality of results
6. **Export**: gate-level netlist (.v), timing constraints (.sdc), timing annotation (.sdf)

### 11.3 Power Estimation

- **Quick method:** DC's `report_power` with default 50% toggle rate (overestimates ~2x)
- **Accurate method:** Generate VCD from testbench T4.1, feed to DC:
  ```tcl
  read_vcd tb_output.vcd -strip_path tb/dut
  report_power -analysis_effort high
  ```
  VCD-based power uses realistic toggle rates from the full round-trip test.

### 11.4 Synthesis Configurations

| Config | NQ | QD | Credits | Purpose |
|--------|----|----|---------|---------|
| A (gem5 match) | 16 | 64 | 64 | Matches Phase 2 simulation. Validates RTL vs sim equivalence. |
| B (scale queues) | 64 | 64 | 64 | Production queue count. Shows area scaling with NQ. |
| C (scale depth) | 16 | 128 | 128 | Deep queue depth. Shows area scaling with QD. |
| D (production) | 64 | 128 | 128 | Full production scale. Upper bound for paper. |

### 11.5 Paper Deliverables

**Table 1: PPA Summary**

| Config | Logic Area (mm^2) | SRAM Area (mm^2) | Total (mm^2) | Freq (GHz) | Power (mW) |
|--------|-------------------|-------------------|-------------|-----------|-----------|
| A (16/64) | from DC | 0.109 | sum | >=1.0 | from DC |
| B (64/64) | from DC | 0.437 | sum | >=1.0 | from DC |
| C (16/128) | from DC | 0.218 | sum | >=1.0 | from DC |
| D (64/128) | from DC | 0.872 | sum | >=1.0 | from DC |

**Table 2: SRAM Breakdown** (Section 7.3 of this spec)

**Table 3: Comparison with Published CPU Components**

| Component | Area (mm^2) | Node | Source |
|-----------|-----------|------|--------|
| IO-Uncore Config A | ~X | 7nm | This work |
| IO-Uncore Config D | ~Y | 7nm | This work |
| Intel LLC slice (1MB) | ~1.0 | 7nm | Published data |
| AMD I/O die (per tile) | ~5 | 6nm | Published data |
| ARM CCI-550 crossbar | ~2.5 | 7nm | Published data |

Story: IO-Uncore is smaller than a single LLC slice.

**Figure 1: Area Scaling (line chart)**
- X-axis: Number of queue pairs (4, 8, 16, 32, 64, 128)
- Y-axis: Total area (mm^2)
- Lines: QD=64, QD=128; sub-lines for logic only, SRAM only, total
- Shows linear SRAM scaling, near-constant logic area

**Figure 2: Power Scaling (line chart)**
- X-axis: Target IOPS (1M, 5M, 10M, 20M, 40M)
- Y-axis: Dynamic power (mW)
- Lines: Config A, Config D
- Shows sub-watt power even at 40M IOPS

**Figure 3: Energy Efficiency (bar chart)**
- X-axis: Config (A, B, C, D)
- Y-axis: nJ per I/O
- Bars: Logic energy, SRAM energy, Total
- Reference line: CPU software path (~500 nJ/IO from Phase 1 data)
- Shows 10-100x improvement over software

**Figure 4: Timing Slack (table or bar)**
- Per-module critical path slack at 1 GHz
- Shows which module is the timing bottleneck
- If all positive, argue higher frequency achievable

---

## 12. Project Directory Structure

```
RTL_design/
├── setup_instructions.md          # existing
├── .synopsys_dc.setup             # DC configuration for ASAP7
├── src/                           # RTL source files
│   ├── io_uncore_top.v
│   ├── mmio_decoder.v
│   ├── sq_engine.v
│   ├── cq_engine.v
│   ├── db_coalescer.v
│   ├── sram_arbiter.v
│   ├── credit_manager.v
│   └── stat_counters.v
├── tb/                            # Testbenches
│   ├── tb_sq_engine.v
│   ├── tb_cq_engine.v
│   ├── tb_db_coalescer.v
│   └── tb_io_uncore_top.v
├── synth/                         # Synthesis scripts
│   ├── constraints.tcl            # Timing constraints
│   ├── run_synth.tcl              # Automated synthesis flow
│   └── run_all_configs.sh         # Sweep NQ/QD configs
├── lib/                           # ASAP7 PDK libraries
│   ├── asap7sc7p5t_*.db
│   ├── asap7sc7p5t_*.sdb
│   └── dw_foundation.sldb
├── reports/                       # Synthesis outputs
│   ├── timing_16_64.rpt
│   ├── area_16_64.rpt
│   ├── power_16_64.rpt
│   └── ...                        # per config
├── netlists/                      # Post-synthesis netlists
│   └── io_uncore_*.v
└── scripts/                       # Analysis scripts
    ├── parse_reports.py           # Extract PPA from DC reports
    ├── sram_area_model.py         # Analytical SRAM estimation
    └── plot_ppa.py                # Generate paper figures
```

---

## 13. Action Items Outside This Spec

1. **gem5 CPU clock update:** Change from default 2 GHz to 5 GHz in `boot_gem5.sh` or `fs.py` options to match modern CPU specifications. This affects Phase 1/2 simulation results — re-run baseline if needed.
2. **ASAP7 PDK acquisition:** Download from Arizona State University, verify library files load in Design Compiler.
3. **DMA Sequencer sub-project:** Follow-up spec for token-based DMA issue with backpressure.
4. **Hardware Scheduler sub-project:** Follow-up spec for weighted round-robin / deficit fair queuing.



## Review

---
  Section 1-2: Overview, Goals, and Technology Choices

  Strengths:
  - ASAP7 is a well-justified choice — the rationale (matching real I/O die nodes, published SRAM bitcell data, academic
    reproducibility) is solid.
  - 1 GHz clock is conservative and defensible. The cycle budget math (25 cycles/IO at 40M IOPS) gives comfortable
    headroom.

  Concerns:

  1. Scope reduction not fully justified. The spec defers DMA Sequencer and Hardware Scheduler to "follow-up sub-projects," but the design doc (Section 2 of the proposal) lists DMA Orchestration as methodology item #3 and QoS/Fairness as #4. Without the DMA Sequencer, you can't actually issue I/O to a real device — the SQ Engine produces SQEs in SRAM but nothing moves data. This is fine for a PPA feasibility study, but the spec should explicitly state that the synthesized design is the control plane only, and the throughput claims (30-40M IOPS) are projections based on cycle budgets, not measured end-to-end throughput.

  2. SS corner missing from requirements. The spec mentions SS (slow-slow) as optional, but any serious timing closure argument needs worst-case corner data. If a reviewer asks "does it close timing at SS/125C?", "we only ran TT" is a weak answer. Recommend running at least TT and SS.

  3. The gem5 CPU clock note (Section 2.2, line 70-71) flags that Phase 1/2 data was collected at 2 GHz, not 5 GHz. This is a significant issue — if you change the CPU clock, Phase 1/2 cycle-per-IO numbers change (fewer cycles per IO at higher clock means the software overhead per wall-clock second is higher, strengthening your argument, but the raw cycle counts stay the same). Clarify whether you're re-running Phase 1/2 or just noting this for future work.

---
  Section 3: Top-Level Architecture

  Strengths:
  - Modular decomposition is clean. Three engines + arbiter + credit manager + stats is a textbook decomposition.
  - The choice of shared SRAM with round-robin arbiter over per-engine private SRAM is well-reasoned (dynamic sharing,
    fewer instances).

  Concerns:

  4. Single-port SRAM with 3 requestors is a bottleneck risk. At peak load, all three engines contend for the same SRAM port. The spec says "1-cycle contention" (line 89), but consider: during a CQ flush of N=8 CQEs, the CQ Engine holds the SRAM for 8 consecutive reads. During those 8 cycles, the SQ Engine is blocked from writing new SQEs. At 40M IOPS with both paths active, this creates bursty stalls, not just 1-cycle stalls. The round-robin arbiter guarantees fairness but not low latency. Consider whether dual-port SRAM or banked SRAM (SQ and CQ in separate banks) would be more realistic. At minimum, quantify the worst-case contention scenario.

  5. SRAM data width mismatch. The arbiter is 128-bit (line 161), but SQ Engine writes 64B SQEs. That's 4 beats per SQE at 128 bits, or you need a 512-bit SRAM data bus to do single-cycle SQE writes. The spec says "512-bit internal SQE bus" (line 169) but the arbiter is 128-bit. This inconsistency needs resolution — either the arbiter is 512-bit (expensive), or SQE injection takes 4 SRAM cycles (affects the cycle budget in Section 4.2).

---
  Section 4: SQ Engine

  Strengths:
  - The FSM is well-defined with clear state transitions. The 6-cycle typical path for 4KB is efficient.
  - PRP expansion logic (simple/dual/list) correctly handles the NVMe spec's three cases.
  - Credit check at S_DECODE is the right place — early enough to avoid wasted work.

  Concerns:

  6. The "single FSM" bottleneck (line 297). Only one queue's SQE is processed at a time. The spec claims this supports ~4 queues submitting every cycle. But at 64 QP with bursty submissions, if multiple queues submit simultaneously, they serialize through the single FSM. The S_IDLE -> S_LATCH_0 transition depends on mmio_wr_valid, which is serialized by PCIe ordering anyway — so this might be fine in practice, but the argument should be made explicitly: "PCIe MMIO writes are inherently serial, so a single FSM doesn't add contention beyond what the PCIe interface already imposes."

  7. Mailbox latch per queue (line 294) — interleaving assumption. The spec says per-queue latches allow interleaved writes, but the FSM is sequential (S_LATCH_0 -> S_LATCH_1 -> S_DECODE for the same qid, lines 202-212). If the host interleaves writes to different queues mid-mailbox (write word 0 to Q0, write word 0 to Q1, write word 1 to Q0...), the FSM needs to handle this. The current FSM checks "same qid" on transitions — what happens if a different qid arrives at S_LATCH_1? Does it drop the in-progress Q0 submission? Restart? The spec doesn't define the error/preemption behavior.

  8. PRP list writes and SRAM contention. The worst-case 128KB path does 31 SRAM writes in S_PRP_LIST. During those 31 cycles, the CQ Engine is blocked from SRAM. If a CQ batch timeout fires during a PRP list expansion, you get a 31-cycle delay on completion visibility. This is likely acceptable (31 ns at 1 GHz) but should be documented as a known contention window.

---
  Section 5: CQ Engine

  Strengths:
  - Dual flush triggers (count N + timeout T) is the standard and correct approach.
  - Hint register as a combinational output avoiding SRAM access is a good optimization for poll-lite.
  - Credit replenishment at C_ENQUEUE (not at flush) matches the pipeline semantics correctly.

  Concerns:

  9. hint_ready as a sum of per-queue batch_counts (line 420). If this is combinational over 64 queues, that's a 64-input
      adder tree for 32-bit values. At 1 GHz this might be on the critical path. Consider whether hint_ready needs to be exact or approximate — a single global counter incremented/decremented atomically would be simpler and timing-friendly.

  10. C_FLUSH serializes CQE reads. Flushing N=8 CQEs takes 8 SRAM reads (one per CQE). During this time, new CQEs arriving for other queues can't be enqueued (single FSM). The spec should discuss whether a double-buffering scheme (enqueue to bank A while flushing from bank B) was considered and rejected.

  11. DMA write interface is abstract. The CQ Engine asserts dma_wr_req and expects... what? There's no DMA acknowledgment, no backpressure from the DMA path. If the host DRAM write takes multiple cycles or can stall, C_FLUSH will stall the entire CQ Engine. The interface needs at least a dma_wr_ack or dma_wr_ready signal.

---
  Section 6: Doorbell Coalescer

  Strengths:
  - Clean, simple design. No SRAM needed — all state in flip-flops.
  - Parallel per-queue monitoring is the right choice (unlike the serialized SQ/CQ engines).
  - The coalescing example (Section 6.3) clearly illustrates the 75% reduction.

  Concerns:

  12. Minor: Timer sharing (line 524). The spec says "one comparator per queue, not one counter per queue." But you still
      need per-queue state to store the start time or remaining time. The spec says per-queue timer values exist in flip-flops (line 521). This is fine — just clarifying that the "sharing" is the global tick counter, not the comparison state.

  13. No SQ doorbell in Mode B. The spec notes (line 523) that Mode B mostly eliminates SQ doorbells. This means the coalescer is primarily handling CQ head doorbells in the target use case. This raises the question: is the coalescer necessary for Mode B? It contributes to area/power but handles only CQ doorbells. Worth acknowledging in the paper — the coalescer's main value is Mode A compatibility and the generality argument.

---
  Section 7: SRAM Layout and Sizing

  Strengths:
  - The sizing analysis is thorough. The 4KB-only vs. full PRP comparison is an excellent paper insight — showing 75%
    SRAM is PRP lists that AI workloads don't need.
  - Area estimates are small relative to I/O tile area — the feasibility argument is compelling.
  - Hybrid area estimation (DC logic + analytical SRAM) is the standard academic approach.

  Concerns:

  14. PRP list allocation is per-queue, per-depth (line 569). NQ x QD x MPE x 8B means you're pre-allocating PRP list space for every possible in-flight command on every queue, even though most I/Os are 4KB and never use PRP lists. A real implementation would use a shared PRP pool. For the paper, present the worst-case pre-allocated number but note that a pool-based approach would dramatically reduce SRAM for mixed workloads.

  15. SRAM overhead factor of 1.5x (line 601). This is reasonable but cite it. Different sources give 1.3x-2.0x depending
      on SRAM macro size. At the sizes you're dealing with (hundreds of KB), the overhead tends toward the lower end because
      peripheral circuits amortize. Consider reporting a range (1.3x-1.7x) instead of a point estimate.

---
  Section 8-9: Credit Manager and Stat Counters

  These are straightforward. The credit manager is a saturating up/down counter — hard to get wrong. Stat counters are
  standard.

  16. One concern: simultaneous inc+dec on the credit counter (line 650). If both happen in the same cycle, the spec says
      "no change." This is correct but needs careful RTL — the priority encoding must handle the three cases (inc only, dec only, both) without glitches.

---
  Section 10: Verification Plan

  Strengths:
  - The reviewer defense rationale (Section 10.2) is well-crafted. Leaning on Phase 2 gem5 validation for algorithmic
    correctness and using RTL testbenches for implementation fidelity is a defensible position.
  - Test coverage is comprehensive for a feasibility study: 22 tests across 4 testbenches covering steady-state, boundary
      conditions, contention, and integration.

  Concerns:

  17. No negative/error tests. All 22 tests are happy-path or stress scenarios. There are no tests for malformed inputs (e.g., MMIO write to invalid address, doorbell write with out-of-range QID, CQE with unknown CID). For a feasibility study this is acceptable, but if a reviewer asks "what happens when software misbehaves?", you need an answer.

  18. No latency measurement tests. The success criteria require "<200 ns added latency," but no test measures end-to-end
      latency in absolute terms. T4.1 checks cycle count but doesn't validate against the 200 ns target. Add a test that asserts the round-trip cycle count < 200 (at 1 GHz, 200 ns = 200 cycles).

---
  Section 11: Synthesis Flow

  Strengths:
  - The flow is standard and well-documented. VCD-based power estimation is the right approach over default toggle rates.
  - Four configurations spanning the design space (varying NQ and QD independently) will produce good scaling curves.

  Concerns:

  19. compile_ultra -gate_clock assumes clock-gatable logic. The SQ/CQ engines are FSM-heavy with per-queue registers. Clock gating effectiveness depends on how often queues are idle. At 40M IOPS with 64 queues, most queues are active most of the time — clock gating savings may be minimal. Not a problem, just don't over-claim power savings from clock gating.

  20. No place-and-route (PnR). The spec is synthesis-only. Synthesis area estimates are typically 30-50% smaller than post-PnR due to routing overhead and placement inefficiency. The paper should state explicitly that these are pre-PnR synthesis estimates and apply a ~1.3-1.5x correction factor for the area comparison table.

---
  Section 12-13: Directory Structure and Action Items

  21. The gem5 re-run question (action item #1, line 934) is unresolved. Changing the CPU clock from 2 GHz to 5 GHz affects the Phase 1/2 baseline. If you re-run, Phase 1/2 numbers change. If you don't re-run, there's a consistency gap between Phase 2 simulation (2 GHz) and Phase 3 RTL (designed for real 5 GHz CPUs). Decide and document which approach you're taking.

Overall, this is a well-structured spec with solid engineering decisions. The critical issues are resolvable — most need clarification or minor design changes, not fundamental rework. Want to dig into any specific issue?







log:

  Layer 1: The CPU (Host Software)

   Host CPU Core (5 GHz)
   ┌──────────────────────────────────────────────────────────────────┐
   │  SPDK (userspace)                                               │
   │  ┌──────────────┐  ┌──────────────┐  ┌───────────────────────┐  │
   │  │ Mailbox Write │  │ Status Read  │  │ CQ Doorbell / Admin   │  │
   │  │ (3x8B MMIO)  │  │ (1x8B MMIO)  │  │ (standard NVMe)       │  │
   │  └──────┬───────┘  └──────┬───────┘  └──────────┬────────────┘  │
   └─────────┼─────────────────┼─────────────────────┼───────────────┘

  SPDK is the software running on the CPU. It talks to our IO-Uncore through three types of MMIO operations:

  1. Mailbox Write (3 x 8 bytes) — To submit one I/O command, the CPU does 3 sequential 8-byte writes. 3 x 8 = 24 bytes total. This is our compact SQE format (much smaller than the standard 64-byte NVMe SQE — the SQ Engine expands it later).

  2. Status Read (1 x 8 bytes) — The CPU reads the UNCORE_STATUS register to check: "Are there completions waiting? Do I have credits to submit more?" This is the poll-lite mechanism — one quick read instead of scanning entire CQ rings.

  3. CQ Doorbell / Admin — Standard NVMe doorbell writes. These go through the Doorbell Coalescer.

  Layer 2: PCIe BAR0 Boundary

   ══════════╪═════════════════╪═════════════════════╪════ PCIe BAR0

  This line represents the boundary between the CPU and our device. All communication crosses this line as MMIO
  reads/writes over PCIe. BAR0 (Base Address Register 0) is the memory-mapped window that the CPU uses to talk to the
  device — the CPU sees it as a range of memory addresses, but reads/writes to those addresses actually go to our
  hardware.

  Layer 3: MMIO Decoder

   ┌─────────▼─────────────────▼─────────────────────▼───────────────┐
   │                    MMIO Decoder                                  │
   │       (Address decode: 0x0000-0x0FFF -> NVMe std regs           │
   │        0x1000-0x1FFF -> Doorbells,  0x2000+ -> Uncore)          │
   └──────┬──────────────────┬──────────────────┬────────────────────┘

  The MMIO Decoder is an address router. It looks at the address of each MMIO transaction and decides where to send it:

  ┌───────────────┬───────────────────────┬─────────────────────────────────────────────────────────────────────────┐
  │ Address Range │      Destination      │                            What lives there                             │
  ├───────────────┼───────────────────────┼─────────────────────────────────────────────────────────────────────────┤
  │ 0x0000 -      │ NVMe standard         │ Controller capabilities, admin queue config (we don't implement these   │
  │ 0x0FFF        │ registers             │ in detail)                                                              │
  ├───────────────┼───────────────────────┼─────────────────────────────────────────────────────────────────────────┤
  │ 0x1000 -      │ Doorbell Coalescer    │ Standard NVMe doorbell registers                                        │
  │ 0x1FFF        │                       │                                                                         │
  ├───────────────┼───────────────────────┼─────────────────────────────────────────────────────────────────────────┤
  │ 0x2000+       │ Uncore engines        │ Mailbox writes (SQ Engine), status reads (CQ Engine hint register)      │
  └───────────────┴───────────────────────┴─────────────────────────────────────────────────────────────────────────┘

  This is purely combinational logic — no state, no SRAM. Just "if address is in range X, assert the valid signal for
  engine Y."

  Layer 4: The Three Engines

   ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐
   │  SQ Engine   │  │  CQ Engine   │  │ Doorbell         │
   │              │  │              │  │ Coalescer         │
   │ - Mailbox    │  │ - CQE batch  │  │                  │
   │   latch      │  │   buffer     │  │ - Per-queue      │
   │ - SQE decode │  │ - N/T flush  │  │   counter        │
   │ - PRP expand │  │ - Hint reg   │  │ - Timer flush    │
   │ - CID assign │  │   generate   │  │ - Count thresh.  │
   └──────┬───────┘  └──────┬───────┘  └────────┬─────────┘

  Each engine lists its internal sub-functions. Let me decode the abbreviations:

  SQ Engine:
  - Mailbox latch — holds the 24 bytes as they arrive (3 writes x 8 bytes)
  - SQE decode — parses the 24-byte compact format into fields (opcode, LBA address, buffer address, etc.)
  - PRP expand — converts the buffer address into PRP (Physical Region Page) entries that the NVMe device needs for DMA.
    We explained this in Section 3.1 already as the simple/dual/list cases.
  - CID assign — gives each command a unique Command ID so the completion can be matched back to it

  CQ Engine:
  - CQE batch buffer — accumulates completion entries in SRAM before flushing
  - N/T flush — "N" = count threshold, "T" = timeout. Two triggers for when to flush the batch. (We'll cover details in
    Section 5)
  - Hint reg generate — maintains the hint_ready counter that tells the CPU how many completions are waiting

  Doorbell Coalescer:
  - Per-queue counter — tracks how many doorbells accumulated per queue
  - Timer flush — timeout so doorbells don't get held too long
  - Count thresh. — the batch size (B) that triggers sending a coalesced doorbell

  Layer 5: SRAM Arbiter and SRAM

   ┌─────────────────────────────────────────────────────────────────┐
   │                     SRAM Arbiter                                 │
   │          (Round-robin, 3 requestors, 1-cycle latency)           │
   └────────────────────────────┬────────────────────────────────────┘
                                │
                      ┌─────────v─────────┐
                      │   SRAM Banks      │
                      │  SQ Buffers       │  <- 64B x QD x NQ
                      │  CQ Buffers       │  <- 16B x QD x NQ
                      │  Metadata         │  <- pointers, credits
                      │  PRP Lists        │  <- 8B x pages x NQ
                      └───────────────────┘

  The SRAM stores four types of data:

  - SQ Buffers — Full 64-byte SQEs after the SQ Engine expands them. Size = 64 bytes x Queue Depth x Number of Queues.
  - CQ Buffers — 16-byte CQEs waiting to be flushed. Size = 16B x QD x NQ.
  - Metadata — Per-queue head/tail pointers, phase bits, CID counters, base addresses.
  - PRP Lists — For large transfers (>8KB), the list of physical page addresses.

  Layer 6: Shared Resources

   ┌──────────────────┐  ┌──────────────────┐
   │ Credit Manager   │  │ Stat Counters    │
   │ - Pool counter   │  │ - 6 metric groups│
   │ - Dec on submit  │  │ - Self-checking  │
   │ - Inc on complete│  │   export port    │
   └──────────────────┘  └──────────────────┘

  These are not behind the SRAM arbiter — they're simple registers directly accessible by the engines:

  - Credit Manager — The up/down counter we discussed. SQ Engine decrements it when submitting, CQ Engine increments it
    when a completion arrives. This is the flow control between submission and completion paths.
  - Stat Counters — Telemetry. Counts events like "how many submissions," "how many flushes," "how many doorbells
    coalesced." Used for debugging and for the paper's performance analysis.

---
  Section 3.3: Module Inventory

  This is the mapping from architecture to actual Verilog files:

  ┌──────────────────┬──────────────────────┬─────────────────────────────────────────────────────────────┐
  │      Module      │      What it is      │                      Key thing to know                      │
  ├──────────────────┼──────────────────────┼─────────────────────────────────────────────────────────────┤
  │ io_uncore_top.v  │ Top wrapper          │ Just wires. Instantiates everything else and connects them. │
  ├──────────────────┼──────────────────────┼─────────────────────────────────────────────────────────────┤
  │ mmio_decoder.v   │ Address router       │ Combinational logic. No state.                              │
  ├──────────────────┼──────────────────────┼─────────────────────────────────────────────────────────────┤
  │ sq_engine.v      │ Submission engine    │ Most complex module. Has FSM + per-queue latches.           │
  ├──────────────────┼──────────────────────┼─────────────────────────────────────────────────────────────┤
  │ cq_engine.v      │ Completion engine    │ Second most complex. FSM + batch buffers.                   │
  ├──────────────────┼──────────────────────┼─────────────────────────────────────────────────────────────┤
  │ db_coalescer.v   │ Doorbell batcher     │ Simple. Register arrays only, no SRAM.                      │
  ├──────────────────┼──────────────────────┼─────────────────────────────────────────────────────────────┤
  │ sram_arbiter.v   │ SRAM traffic cop     │ Round-robin arbiter. 128-bit data bus.                      │
  ├──────────────────┼──────────────────────┼─────────────────────────────────────────────────────────────┤
  │ credit_manager.v │ Flow control counter │ Simplest module. One register.                              │
  ├──────────────────┼──────────────────────┼─────────────────────────────────────────────────────────────┤
  │ stat_counters.v  │ Telemetry            │ Array of 64-bit counters.                                   │
  └──────────────────┴──────────────────────┴─────────────────────────────────────────────────────────────┘

  When you write these in Verilog, the key parameter that flows through everything is NUM_QUEUES and QUEUE_DEPTH. You set
   these at the top level, and they propagate down to every sub-module via Verilog parameter — this is how you synthesize
   different configurations (Config A through D) from the same source code.

---
  Section 3.4: Top-Level Design Decisions

  Four decisions to internalize:

  1. Single clock domain (1 GHz) — Everything runs on one clock. No clock domain crossing logic. This simplifies the design enormously for a first implementation.

  2. Single-port SRAM with arbiter — One read or write per cycle. As we discussed, contention is manageable because only SQ and CQ engines actually use SRAM.

        3. Data widths: 64-bit MMIO, 512-bit internal SQE — The CPU sends 8 bytes at a time over MMIO. Internally, a full SQE is 512 bits (64 bytes). This mismatch is why the SQ Engine needs 3 latch cycles to collect the full compact SQE, and why the SRAM arbiter width (128-bit) needs careful thought. (This is actually one of the issues from the review — the
       128-bit arbiter vs 512-bit SQE width inconsistency.

  4. Parameterization — NUM_QUEUES and QUEUE_DEPTH are Verilog parameters, not hardcoded constants. This means you write the code once and synthesize it four times with different parameter values to get Configs A-D.

---
  A question before we continue: Do you understand the full data flow now? Trace it for me — if the CPU wants to submit a
   4KB read command, what path does the data take through this diagram, from the CPU all the way down to SRAM?

### 4KB Read Process

**Host Submission:** SPDK running on the 5 GHz CPU core issues three sequential 8-byte MMIO writes (24 bytes total) targeting the mailbox address space (`0x2000+`).

**MMIO Routing:** The `mmio_decoder` identifies the address range and asserts `mmio_wr_valid` to the `sq_engine`.

**SQ Latching & Decoding (Cycles 1-4):**

- The `sq_engine` FSM wakes from `S_IDLE`.
- It progresses through `S_LATCH_0` and `S_LATCH_1` to capture the first 16 bytes into per-queue flip-flops.
- On the third write, it enters `S_DECODE`, checking the `credit_manager`. Assuming credits > 0, it parses the compact SQE (opcode, LBA) and assigns a unique Command ID (CID) from a free-running counter.

**PRP Expansion (Cycle 5):** The FSM transitions to `S_PRP_CALC`. Because the transfer is 4KB, it immediately branches to `S_PRP_SIMPLE`, pointing `PRP1` directly to the buffer address and zeroing `PRP2`.

**SRAM Injection (Cycle 6):** The FSM moves to `S_INJECT`. It constructs the full 64-byte standard NVMe SQE. It requests access from the `sram_arbiter`. Once granted, it writes the 64-byte SQE to the SQ Buffer array in SRAM.

**State Updates:** Simultaneously, the `sq_engine` pulses `credit_dec` (decreasing the credit pool), pulses `stat_mailbox_sub` (updating telemetry), and asserts `sq_ready` so the downstream DMA sequencer knows a command is ready.

### Critical Vulnerabilities & Reviewer Defense

Reviewers at top-tier architecture venues are going to aggressively probe the boundary between your behavioral claims and your RTL realities. The review log at the bottom of your spec points out several critical architectural friction points that must be addressed before finalizing the RTL:

**The Bus Width Mismatch (Data vs. Arbiter)**

- **The Issue:** Your spec states the `sq_engine` writes a 512-bit (64-byte) SQE to SRAM in `S_INJECT` (1 cycle). However, the `sram_arbiter` specifies a 128-bit data width.
- **The Fix:** You cannot push 512 bits through a 128-bit bus in one cycle. You must either widen the arbiter and SRAM ports to 512-bit (expensive for area/power) or have the `sq_engine` stall in `S_INJECT` for 4 cycles to write the SQE in four 128-bit beats. The latter consumes 4 cycles of your 25-cycle budget, which is perfectly fine, but the RTL and documentation must reflect this reality.

**SRAM Port Contention (The C_FLUSH Bottleneck)**

- **The Issue:** Single-port SRAM means only one read or write per cycle. When the CQ Engine flushes a batch of 8 CQEs, it takes 8 consecutive SRAM reads. If the arbiter grants priority to the CQ engine, the SQ engine is completely blocked from writing new submissions for 8 cycles.
- **The Fix:** The round-robin arbiter will likely force interleaved access (SQ, CQ, SQ, CQ). This means an 8-CQE flush will actually take 16 cycles if the SQ engine is under heavy load. You must ensure your worst-case cycle budget accounts for this interleaved contention, or upgrade to pseudo-dual-port SRAM (one read port, one write port).

**The Missing DMA Sequencer**

- **The Issue:** By deferring the DMA Sequencer and Hardware Scheduler, Phase 3 only proves the *control plane* is synthesizable. You cannot claim end-to-end silicon latency or verified throughput without the data plane.
- **The Fix:** Frame the paper's narrative carefully. Explicitly define this RTL as the "Control Plane Uncore." Rely entirely on your gem5 Mode B simulations to validate the 30-40M IOPS throughput, and use the RTL strictly to prove that the *control overhead* of those 40M IOPS fits within 10 W and < 1 mm^2.

**The `hint_ready` Timing Risk**

- **The Issue:** Deriving `hint_ready` by combinationally adding the `batch_count` of 64 separate queues creates a deep 64-input adder tree. At 1 GHz, this combinational logic will almost certainly violate timing constraints (negative slack) during synthesis.
- **The Fix:** Make `hint_ready` a single, global 32-bit register. Increment it in `C_ENQUEUE` when any CQE arrives, and decrement it in `C_WRITEBACK` by the exact flush count. This replaces a massive adder tree with simple +1 / -N arithmetic.
---

## 13. Future-Phase Mechanisms for 2-3× CPU-Cycle Reduction

### 13.1 Motivation

Phase 3 (Mode B mailbox / submission-side offload) elides roughly **360 ns/IO** of host work (PRP-list construction, 64-byte SQE pack, doorbell ring) at QD=128 4 KB random read. Translating via Little's Law, this is **~1.4× IOPS lift over the Mode 0 baseline** (0.82 M → ~1.2 M IOPS). The remaining ~860 ns/IO is split across:

- `Tracker_Alloc` (~218 ns) — `TAILQ_REMOVE/INSERT` on SPDK's per-qpair free/outstanding tracker lists
- `State_Dealloc` (~295 ns) — symmetric TAILQ ops on completion + `queue_depth--` + application callback
- `Submit_Preamble`, `CQE_Detect`, `Tracker_Lookup`, "other SPDK overhead" — smaller residuals

To push the headline lift to **2-3×**, the natural next step is to extend the uncore into the per-IO **bookkeeping work** that flanks the data path. Four mechanisms are characterized below, ranked by leverage and ordered by feasibility.

### 13.2 Mechanism #1 — Hardware Tracker Free-List Ring  *(big win, no host API change)*

**Function.** Per qpair, the controller maintains an on-die FIFO of free Command IDs. The host pops the next free CID with one MMIO load (replaces SPDK's `TAILQ_FIRST(&free_tr)` plus `TAILQ_REMOVE/INSERT` sequence). On CQE generation, hardware automatically recycles the CID back into the FIFO; the host's `State_Dealloc` no longer touches the free list.

**Host-side savings (vs Mode B v1):**
- ~218 ns from `Tracker_Alloc` (fully eliminated; CID and tracker bookkeeping moves on-die)
- ~150 ns from `State_Dealloc` (TAILQ_REMOVE + TAILQ_INSERT_HEAD elided; the application callback remains on host)
- **Total ~370 ns/IO**, bringing per-IO budget to ~490 ns/IO ≈ **2.5× IOPS lift over Mode 0**.

**RTL footprint (estimated at ASAP7 7 nm):**

| Resource | Sizing |
|---|---|
| Free-CID FIFO storage | 16 b × QUEUE_DEPTH × NUM_QPAIRS ≈ 64 KB SRAM for 128 qpairs × 256 entries (banked alongside SQ Engine SRAM) |
| Head/tail pointer per qpair | ~10 b × 2 × 128 = ~320 B |
| Push FSM (CQE-completion side) | ~50 gates |
| Pop FSM (MMIO-read side) | ~50 gates |
| New MMIO surface | One read at `BAR0 + free_cid_offset(qid)` per submission; decoder is a one-case extension of the existing BAR0 demux |

**Cycle budget at 1 GHz.** 1 cycle to pop (the MMIO read latency dominates anyway); 1 cycle to push on CQE. Total free-list traffic per IO: 2 SRAM ops on a banked region that is independent of the SQE / CQE banks already specified — **no new arbiter contention**.

**Feasibility verdict: easily feasible.** Strictly simpler than the SQ Engine the current spec already commits to. SRAM and arbiter framework already in place. **Recommended for Phase 4.**

### 13.3 Mechanism #2 — Hardware Queue-Depth Counter  *(trivial, modest win, enables #1)*

**Function.** Expose the existing per-qpair credit counter (from §6 Credit Manager) via MMIO read. Host reads the current queue depth in 1 cycle instead of incrementing/decrementing its software shadow counter.

**Host-side savings:** ~5-10 ns/IO. Small in isolation, but **structurally required by Mechanism #1**: once the hardware owns the free-list, the host's software `qpair->queue_depth` shadow becomes stale unless it can read the authoritative counter back.

**RTL footprint.** 16 b counter per qpair × 128 qpairs = 256 B. Already implied by the existing Credit Manager (line 714 `credit_avail` signal). Adds one MMIO read decoder case.

**Feasibility verdict: trivial.** Essentially free if Mechanism #1 is built. **Recommended for Phase 4 alongside #1.**

### 13.4 Mechanism #3 — Hardware Completion-Callback Dispatcher  *(invasive, biggest residual win)*

**Function.** Today, on CQE the host: (i) scans CQ phase bit, (ii) looks up tracker by CID, (iii) reads `tr->cb_fn` and `tr->cb_arg`, (iv) calls `cb_fn(cb_arg, cpl)`. Mechanism #3 replaces (i)-(iii) with hardware: applications pre-register `(cb_fn, cb_arg)` pairs alongside each submission (extending the mailbox compact descriptor from 24 B → 40 B). On CQE, hardware writes a **completion record** `(cb_fn, cb_arg, cpl)` to a host-DRAM ring buffer. The host poll loop reads this ring and calls `cb_fn` directly — never touching the standard NVMe CQ or tracker table.

**Host-side savings:**
- ~20 ns `CQE_Detect` (no CQ phase-bit scan)
- ~11 ns `Tracker_Lookup` (no array index)
- ~50-100 ns "other SPDK overhead" (poll-loop scaffolding around CQ scanning)
- Application callback (~50-100 ns) remains on host — must run user C code
- **Total ~80-130 ns/IO**, bringing per-IO budget to ~360-410 ns/IO ≈ **3× IOPS lift over Mode 0**.

**RTL footprint:**

| Resource | Sizing |
|---|---|
| Per-tracker callback storage `(cb_fn, cb_arg)` | 16 B × QUEUE_DEPTH × NUM_QPAIRS ≈ 512 KB SRAM |
| Completion-record DMA engine | New on-die DMA path writing 24 B records into a host-resident ring buffer |
| Ring head/tail descriptors per qpair | ~64 B |
| New MMIO surface | Ring base + size registration |

**Cycle budget at 1 GHz.** 2-3 cycles to look up `(cb_fn, cb_arg)` from the tracker store; 1 cycle to enqueue the completion record into the on-die FIFO before DMA emission.

**Programming-model change.** Applications must register callbacks in advance via a new SPDK API (`spdk_nvme_register_callback_queue()`-style). This crosses the architectural boundary the current RTL spec explicitly drew (line 1368: *"Define this RTL as the Control Plane Uncore"*) — Mechanism #3 introduces a control-AND-data-plane uncore, comparable in scope to a small SmartNIC.

**Feasibility verdict: technically feasible but architecturally larger.** ~0.5-1.0 mm² additional area at 7 nm. **Future work / v2 paper scope** — not recommended for the current submission cycle.

### 13.5 Mechanism #4 — Multi-Bit Hint Register Refinement  *(easy, small win)*

**Function.** Replace the current 32-bit `hint_ready = lCQFIFO.size()` register with a typed hint:
- bits [15:0] = pending-completion count (today's value)
- bits [31:16] = oldest-completion age in 1024-cycle ticks

SPDK uses the age field to size its CQ-scan width adaptively — pre-allocating the right number of completion-record buffers and skipping calls to `nvme_complete_request` that would scan empty entries.

**Host-side savings:** ~10-20 ns/IO at QD=128 where 97% of polls are idle and SPDK's poll-loop control flow dominates.

**RTL footprint.** Trivial. The CQ Engine already tracks CQE arrival timestamps for its T-threshold flush logic; expose the age of the oldest staged CQE as 16 extra bits in the hint register. <0.01 mm².

**Feasibility verdict: trivially feasible** and mostly an SPDK-side change. **Recommended for Phase 4** — bundle with #1 and #2.

### 13.6 Cumulative Projection

| Configuration | Per-IO budget | IOPS @ QD=128 | Lift vs Mode 0 | Phase scope |
|---|---:|---:|---:|---|
| Mode B v1 (Phase 3 — this spec) | ~860 ns | 1.16 M | 1.4× | Control-plane uncore, submission-side only |
| + Mech #1 + #2 (Phase 4) | ~490 ns | 2.05 M | **2.5×** | Same scope; reuses SQ Engine SRAM and arbiter framework |
| + Mech #4 (Phase 4) | ~470 ns | 2.13 M | 2.6× | Trivial CQ Engine extension |
| + Mech #3 (Phase 5 / v2 paper) | ~370 ns | 2.64 M | **3.2×** | Control + data-plane uncore; new application API |

### 13.7 Rationale for the Selected Phase 4 Scope

Mechanisms #1, #2, and #4 are bundled because:

1. **All three are pure control-plane extensions.** They fit inside the architectural boundary the current RTL spec already drew — same SRAM model, same arbiter framework, same MMIO decoder, same FSM style.
2. **No new SPDK API.** The only host-side change is replacing `TAILQ_FIRST(&free_tr)` with one MMIO read; this is a one-line patch to `nvme_pcie_qpair_submit_request`. Applications and middleware see no change.
3. **They share infrastructure.** Mechanism #2 (queue-depth counter) is a structural dependency of Mechanism #1 (free-list ring) — once the hardware owns CID allocation it must also expose the in-flight count. Mechanism #4 (multi-bit hint) reuses the existing CQ Engine timing path.
4. **They deliver the headline 2.5× lift** the paper title implies, while preserving the spec author's explicit "Control Plane Uncore" framing (line 1368).

Mechanism #3 is deferred because it requires a new on-die DMA engine, ~0.5-1 MB additional SRAM, and a new application-facing API. Its incremental contribution (2.5× → 3.2×) is real but does not justify crossing the control-plane/data-plane boundary in this paper cycle.
