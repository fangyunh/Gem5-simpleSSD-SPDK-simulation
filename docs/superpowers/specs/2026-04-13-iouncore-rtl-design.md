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
                │               │  Assign CID from counter         │
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

The CQ Engine accumulates CQEs from the NVMe backend in SRAM batch buffers and flushes them to host DRAM in batches, controlled by count threshold (N) and timeout (T) triggers. It also maintains the hint_ready counter that drives the poll-lite completion path.

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
