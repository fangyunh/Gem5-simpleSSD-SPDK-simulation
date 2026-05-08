# I/O Uncore for massive CPU I/O support

## Motivation

**The Rise of Data-Intensive AI Workloads:** Modern AI applications, such as large language models (LLMs), AI agents, and vector databases, require massive, fine-grained access to datasets that far exceed the physical capacity of host DRAM or GPU memory. This forces systems to rely heavily on NVMe storage to handle millions of sparse, small-block reads (e.g., 512 bytes to 4KB) simultaneously.

**The Device-Host Utilization Gap:** Next-generation "Storage-Next" SSDs are evolving to deliver tens to hundreds of millions of random IOPS per device. However, modern host processors face a hard architectural ceiling, typically capping at 0.5 to 1.5 million small-block IOPS per CPU core, which leaves the massive parallelism of modern SSDs stranded behind host-side bottlenecks.

**The Inadequacy of Software-Driven I/O:** Even when utilizing highly optimized, kernel-bypass software frameworks like SPDK or asynchronous interfaces like io_uring to eliminate system calls, fundamental hardware overheads persist. Software-driven NVMe queue execution is crippled by per-I/O Memory-Mapped I/O (MMIO) doorbells, Completion Queue (CQ) polling of device-written cachelines, and DRAM metadata churn at submission and completion stage, which continuously cost 700 to 1200 CPU cycles per I/O operation.

**Thermal and Economic Unsustainability:** Attempting to bridge the IOPS gap by dedicating dozens of CPU cores to full-core busy polling is practically unscalable. Sustaining tens of millions of IOPS purely in software can consume 100 to 200 Watts of host processor power just for I/O management—often exceeding the power consumption of the storage devices themselves.

**Limitations of Current Accelerators (DPUs and GDS):** Existing hardware offloads do not solve the local, fine-grained control path problem. While GPUDirect Storage (GDS) successfully bypasses the CPU for the data path, the CPU still manages the control path, creating a severe bottleneck for small-block inferencing IOPS. Similarly, Data Processing Units (DPUs) are excellent for networked multi-tenancy, but routing direct-attached local NVMe traffic through them introduces additional PCIe hops, complex topology constraints, and 20 to 40 Watts of extra System-on-a-Chip (SoC) power overhead.

**The Collapse of Historical Caching Economics:** The combination of GPU processing speeds and scalable Storage-Next SSDs fundamentally changes system economics. Calibrated models demonstrate that the classical "Five-Minute Rule" for keeping data in DRAM has collapsed to a "Five-Second Rule". This paradigm shift proves that NAND flash must now be treated as an active, high-throughput tier of the memory hierarchy, making the elimination of host-side execution overheads an absolute necessity rather than an optional optimization.

## Problem Statement

Therefore, the primary problem this research aims to solve is the systemic inefficiency of the host-side I/O path. We seek to eliminate this bottleneck by evaluating the physical relocation of the I/O execution plane into a dedicated CPU "IO-Uncore" utilizing private SRAM , and by allowing accelerators to autonomously manage both the data and control paths. By definitively decoupling IOPS scaling from CPU core limits, this research provides the architectural foundation necessary to fully exploit CPU capabilities under high IOPS environment, redefining the traditional memory hierarchy and collapsing the historical data caching threshold from minutes to seconds.

## Architecting the Host-Integrated IO-Uncore

To definitively decouple IOPS scaling from CPU core counts without incurring the latency and power penalties of external DPUs, the execution plane for I/O must be physically relocated into the CPU uncore. This architectural shift perfectly mirrors the historical integration of the memory controller into the CPU die—a watershed design evolution that successfully eliminated the latency and power choke of the external front-side bus (FSB). By embedding an "IO-Uncore" directly within the CPU's I/O chiplet, adjacent to the PCIe and DDR controllers, the system achieves single-digit nanosecond communication latencies and sub-picojoule per bit energy consumption.

## **Methodology: Core Functionalities of the I/O Uncore**

To effectively decouple IOPS scaling from CPU cores, the I/O uncore methodology delegates specific hot-path responsibilities to dedicated hardware state machines. These functionalities are logically structured in order of their operational impact on system overhead :

1. **SRAM-Resident SQ/CQ Execution:** The foundational principle of the architecture is to execute NVMe Submission Queue (SQ) and Completion Queue (CQ) control logic entirely from uncore-private SRAM. By keeping head/tail pointers and per-queue metadata off the host DRAM, the uncore eliminates the coherence traffic, polling overhead, and metadata bandwidth that typically dominate software execution at scale.
2. **Doorbell Aggregation and CQ Suppression:** The uncore replaces per-I/O MMIO doorbells with batched, rate-controlled signaling to mitigate PCIe fabric congestion. Concurrently, CQ suppression accumulates completions within the SRAM and exposes them to host DRAM only in defined batches, drastically reducing CQ cacheline churn and pointer coherence traffic without relying on empty polling iterations.
3. **DMA Orchestration and Pipelining:** Once queue management overhead is removed, the uncore translates SQEs into deeply pipelined DMA operations. This hardware sequencer utilizes token-based issue mechanisms with explicit backpressure, natively supporting deep Scatter-Gather Lists (SGL) and handling both cache-bypass and cache-facing streams.
4. **Hardware QoS and Fairness:** Because software-based schedulers are too coarse to operate effectively at ultra-high IOPS, the I/O uncore enforces per-queue and per-tenant scheduling quotas directly in hardware. Utilizing mechanisms like weighted Round Robin (RR) or Deficit Fair Queuing (DFQ), it ensures strict multi-tenant fairness at line rate, independent of the host CPU.
5. **Telemetry and Observability:** To validate performance and fairness, an integrated telemetry engine collects per-flow counters, latency histograms, and usable IOPS data directly in hardware. This visibility is crucial for dynamically tuning batching policies and monitoring energy efficiency at scale.
6. **IOMMU Assist:** As a secondary optimization for environments utilizing pinned huge-page buffers, the uncore provides opportunistic address translation assistance through large I/O-TLBs, lookahead prefetching, and page-walk caching, effectively minimizing translation stalls.

## **Hardware Responsibilities and SRAM Sizing**

The host-integrated I/O uncore is fundamentally designed to absorb the hot-path work of NVMe queue semantics using simplistic hardware state machines and highly localized, private Static Random-Access Memory (SRAM). Private SRAM is selected over shared Last-Level Cache (LLC) or host DRAM because it completely avoids cache coherence traffic, provides deterministic latency, and consumes orders of magnitude less energy per access.

The critical hardware responsibilities assigned to the IO-Uncore include a dedicated NVMe Queue Engine that executes Submission Queue (SQ) and Completion Queue (CQ) logic entirely in hardware, moving head and tail pointers and per-queue metadata out of host DRAM. A Hardware Doorbell Aggregator replaces per-I/O MMIO doorbells with batched, rate-controlled signaling, substantially reducing the device-facing doorbell frequency. Simultaneously, a CQ Suppression mechanism accumulates completions in SRAM and exposes them to host DRAM only in defined batches. This drastically reduces CQ cacheline churn and the associated pointer coherence traffic that currently cripples software polling loops. Furthermore, the architecture includes a DMA Orchestrator capable of translating SQEs into deeply pipelined DMA operations with explicit backpressure, optimizing both cache-bypass and cache-facing streams. To ensure multi-tenant stability, the IO-Uncore enforces hardware-level Quality of Service (QoS) and fairness through per-cgroup quotas using weighted Round Robin or Deficit Fair Queuing at line rate, while an integrated telemetry engine collects per-flow latency histograms to validate performance.

SRAM sizing within the uncore is dictated by the active queue working sets rather than the total configured queue depth of the SSDs. Architectural models establish a requirement of approximately 8 KB of SRAM per actively polling Queue Pair (QP), segmented symmetrically into 4 KB for the SQ and 4 KB for the CQ. Accounting for an additional 2 MB per uncore tile for shared structures like the I/O Translation Lookaside Buffer (I/O-TLB), FIFOs, and schedulers, a single uncore tile requires roughly 3 to 11 MB of SRAM to comfortably support 10 to 80 million IOPS. For environments requiring extreme performance headroom, the SRAM allocation can scale up to 16 to 32 MB per tile.

## Evaluation

### Phase 1: Commodity Hardware Measurement and Counterfactual Modeling

**Objective and Rationale** 

The primary goal of Phase 1 is to establish the fundamental architectural motivation for the IO-Uncore by **quantitatively identifying exactly where host-side execution costs are expended in contemporary systems**. The core objective is to isolate and measure the per-I/O overheads—specifically NVMe queue execution, polling, Memory-Mapped I/O (MMIO) doorbells, and DRAM metadata traffic—that fundamentally limit system scalability.

Crucially, this phase intentionally utilizes the Storage Performance Development Kit (SPDK) as the primary software baseline. Because SPDK operates entirely in the user space and bypasses the Linux kernel, system calls, and interrupt scheduling, it represents the theoretical best-case scenario for software-driven NVMe queue execution. Any latency or overhead measured within this SPDK environment is therefore definitively attributable to hardware execution costs rather than software inefficiencies, providing a rigorous justification for hardware-level intervention .

**Experimental Setup**

- **Hardware Platform:** A commodity workstation, server, or laptop is sufficient — any Intel/AMD system with at least one NVMe SSD slot. Prefer AC power and a performance-mode CPU governor (disable aggressive power saving for repeatability).
- **Storage Device:** A single commodity NVMe SSD (consumer or enterprise). High-end devices are not required; reproducibility matters more than peak IOPS.
- **Software Stack (primary):** SPDK as the reference baseline using `spdk_nvme_perf` or `bdevperf`. The fio SPDK plugin is an optional later addition. The Linux kernel NVMe / io_uring stack is treated only as a secondary cross-check (see "Optional Cross-Check" below).
- **Thread Isolation:** Polling threads are strictly pinned to dedicated CPU cores. CPU frequency scaling is disabled or recorded; near-zero context switches are verified on the poller cores.
- **Workload Characteristics:** Highly concurrent random reads at 4 KB and 16 KB block sizes representing AI embedding fetches, run against reused, pinned huge-page buffer pools to mirror the embedding-pipeline target regime.

**Experimental Workflow and Tasks** The experimental workflow is designed to map the boundaries of host-side execution through systematic parameter sweeps.

- **Execution Phases:** Each task execution consists of a 10 to 30-second warm-up period, followed by a 30 to 60-second steady-state measurement window. All runs are repeated at least three times to report mean and standard deviation.
- **Parameter Sweeps (one variable at a time):**
  - **Queue Depth (QD):** 16, 32, 64, 128 — controls in-flight concurrency.
  - **Queue Pairs:** 1, 4, 16, 64 — scales multi-queue scanning pressure.
  - **Block Size:** 4 KB vs 16 KB — alters payload-to-metadata ratio.
  - **Poller Cores:** 1, 2, 4 — captures linear CPU-vs-IOPS scaling.

**Metrics and Telemetry Collection** All metrics are collected during the steady-state window and normalized per completed I/O. The set is partitioned into a *must-have* minimum and *nice-to-have* extensions.

*Must-have (minimum publishable set):*

- **IOPS and Latency:** Throughput plus p50, p99, p99.9 latency (a coarse histogram is acceptable in Phase 1).
- **CPU Cost:** cycles/IO, instructions/IO, and CPU utilization per poller thread, collected via `perf stat` around the pinned benchmark process.
- **Polling / Scanning Intensity:** completion-check calls per second; completions drained per call (average and distribution); derived `polls per completion`. This isolates wasted CPU spent scanning empty queues. Collect via lightweight counters inside `spdk_nvme_qpair_process_completions()` (preferred) or via `perf record/report` sampling attribution.
- **DRAM Traffic:** read bytes/IO and write bytes/IO; metadata estimate ≈ max(0, total DRAM bytes/IO − payload bytes/IO). Use Intel PCM (`pcm-memory`) or platform IMC PMU counters via `perf`.
- **Doorbell Activity:** doorbells/IO via a software counter at the doorbell-write site in the SPDK NVMe library (preferred), or PCIe posted-write counters as a lower-fidelity proxy.

*Nice-to-have (strengthens attribution):*

- LLC-load-misses/IO (or MPKI).
- PCIe traffic counters (posted writes as an MMIO proxy).
- Package power via RAPL → joules/IO (host-side energy).
- Context-switches/sec on poller cores (should be near-zero).

**Sanity Checks**

- Verify near-zero context switches on poller cores.
- Confirm IOPS is stable within the measurement window.
- Confirm CPU frequency stability or record actual frequency.
- Confirm QD and qpair counts are actually applied.
- Watch for thermal throttling (laptops), background OS activity, mismatched SPDK hugepage configuration.

**Counterfactual Modeling (Outcome)** Synthesize the measured data into a counterfactual model that re-projects host-side cost under three hypothesized changes:

- CQ completion tracking moved into SRAM, with DRAM-visible CQ updates batched.
- SQ/CQ head/tail updates SRAM-resident, with DRAM pointers updated only at bounded intervals.
- Doorbell MMIO aggregated rather than issued per I/O.

The model applies even when queues are typically non-empty: the modeled benefit comes from eliminating per-I/O DRAM-visible pointer execution, cacheline churn, and MMIO ordering — not from the existence of empty polling iterations. Report modeled improvements as cycles/IO reduction, DRAM metadata bytes/IO reduction, doorbells/IO reduction, and implied IOPS-per-core increase.

**Phase 1 Outputs (3–5 Anchor Plots / Tables)**

1. cycles/IO vs qpairs — multi-queue overhead scaling.
2. DRAM bytes/IO vs qpairs — payload vs metadata estimate.
3. doorbells/IO vs qpairs and QD.
4. polls per completion (or completions per poll-call) vs qpairs.
5. *(optional)* joules/IO vs IOPS — host-side energy.

**Additional Phase 1 Experiments (Recommended)** These strengthen attribution and reviewer confidence beyond the core claim.

- **Multi-Device Scaling (2–4 SSDs):** Show host overhead scales with aggregate IOPS, not just one device. Vary qpairs proportionally; report cycles/IO, DRAM bytes/IO, doorbells/IO, and total poller cores required.
- **NUMA / Locality Sensitivity (server-class only):** Run with poller cores and hugepages co-located with the SSD vs cross-NUMA-node. Report p99 latency shifts and cycles/IO sensitivity, demonstrating the fragility of software polling.
- **Interrupt vs Polling Baseline:** A lower-IOPS run with interrupts enabled (where feasible). Anchors the narrative that polling is the best-case software baseline; interrupt-driven NVMe collapses at high IOPS.
- **Buffer-Model Sensitivity:** Reused pinned huge-pages vs fragmented allocation. Validates the embedding-pipeline regime assumption and shows robustness of the metadata-bytes/IO estimate.
- **Negative Control (separate scanning from raw IOPS):** Throttle to a fixed total IOPS target and vary qpairs only. Expectation: cycles/IO and scans/completion rise with qpairs even when total IOPS is held constant — proves multi-queue scanning, not raw IOPS, drives the overhead.

**Metric Sufficiency Check** By the end of Phase 1, the metrics must answer quantitatively:

1. Where do CPU cycles per I/O go (polling/scanning vs other work)?
2. How much DRAM traffic per I/O is metadata vs payload?
3. How do costs scale with qpairs, QD, and device count?
4. How many cores are required as aggregate IOPS increases?

If any of these cannot be answered, add instrumentation until they can.

**Optional Cross-Check: Kernel NVMe / io_uring** Phase 1 is SPDK-first by design. As an optional cross-check, run an equivalent fio/io_uring workload (with SQPOLL if available) at comparable IO size and QD, and compare qualitative trends (cycles/IO scaling with qpairs, DRAM metadata bytes/IO). Not required for the main claim, but preempts the critique "this is only SPDK."

### Phase 2: Virtual Prototype Validation

**1. Objective and Rationale**

While Phase 1 establishes the theoretical motivation through counterfactual modeling, Phase 2 is designed to empirically validate that these modeled host-side savings materialize under actual software execution. The primary goal is to prove behavioral fidelity: **demonstrating that moving NVMe queue semantics into simulated SRAM, alongside doorbell aggregation and Completion Queue (CQ) suppression, directly translates to reduced CPU cycles and DRAM metadata traffic without violating latency targets.** This phase isolates the architectural effects of the uncore before committing to the complexity of silicon synthesis.

Phase 2 is **required**, not optional. Without it, the evaluation would rest solely on Phase 1's modeling assumptions. Phase 2 provides concrete evidence that (a) the mechanism is implementable, (b) unmodified applications benefit, and (c) the batching/readiness trade-offs behave as predicted under real software.

**2. Design Goal for the Prototype (Keep It Minimal)**

The prototype implements only what is required to validate the core thesis:

- **SRAM-resident semantics:** Keep SQ/CQ head/tail and bookkeeping in private state; batch DRAM-visible updates.
- **Doorbell aggregation:** Reduce device-facing doorbell frequency via count/time policies.
- **CQ suppression:** Expose completions to software in batches via count/time policies.

A full NVMe controller, full PCIe DMA engine, or IOMMU behavior is **explicitly out of scope** for the prototype. The proxy is allowed to be a timing-abstracted execution engine.

**3. Architectural Ring-Handling Modes (A / B / C)**

These three modes describe how DRAM-visible NVMe rings are maintained for architectural correctness while execution moves into the uncore. They are *not* three different architectures, but three compatibility/performance points along a continuum on the same architecture.

> **Research focus clarification.** This work does *not* study all three modes equally:
> - **Mode A (Shadowed Rings)** is the **primary** focus of the research and evaluation — it demonstrates substantial benefits with unchanged applications and frameworks.
> - **Mode B (Mailbox / Assisted Submission)** is **optional**, used sparingly to illustrate incremental gains with minimal enablement.
> - **Mode C (Logical Rings in SRAM)** is treated as an **architectural upper bound** and a guide for silicon sizing, *not* as a primary experimental target.
>
> Regardless of mode, the I/O uncore executes queue semantics in SRAM. The modes differ only in how aggressively DRAM rings are updated and exposed to software.

**Mode A — Shadowed Rings (Default; Transparent to Software).**
Software (kernel NVMe or SPDK) writes SQEs to DRAM and polls DRAM CQs as usual. The uncore observes SQ writes, doorbells, and CQ DMA writes, and executes queue semantics in SRAM. DRAM-visible SQ/CQ pointers and CQEs are updated in batches for compatibility.

*What this mode demonstrates:* Zero application changes; no mandatory SPDK library changes; lower-bound benefit from reduced DRAM-visible pointer execution, CQ cacheline churn, and MMIO ordering — even when SPDK continues to poll DRAM. Anchors the drop-in deployability story.

**Mode B — Mailbox / Assisted Submission (Optional Enablement).**
Software submits SQEs via a lightweight mailbox or shadow interface to the uncore. The uncore synthesizes NVMe-compliant SQEs into DRAM rings as needed.

*What this mode demonstrates:* Further reduction in DRAM writes on the submission path; cleaner batching and backpressure control; a stepping stone for environments willing to accept minimal driver/library enablement. Optional and primarily a performance/efficiency knob, not a requirement.

**Mode C — Logical Rings in SRAM (Maximum Suppression).**
The uncore maintains logical SQ/CQ rings entirely in SRAM. DRAM rings are updated only at bounded synchronization points (interrupts, quiescence, debugging).

*What this mode demonstrates:* Upper-bound efficiency when software cooperates (poll-lite SPDK or interrupt-per-batch); elimination of DRAM-driven execution and scanning. Used to illustrate the architectural ceiling and guide silicon sizing.

**4. Phase 2 Software Interaction Modes (2A / 2B)**

Orthogonal to the architectural ring modes above, Phase 2 evaluates two software-side interaction modes — both running on top of architectural Mode A — to bracket the achievable savings.

- **Mode 2A — Transparent.** Zero modifications to SPDK applications or the SPDK NVMe library. Software continues to poll DRAM CQs as usual; the uncore proxy alters only the *frequency* of DRAM-visible state updates. Demonstrates the **lower bound** of benefits achievable purely through batched hardware exposure.
- **Mode 2B — Poll-lite.** Minimal patching of the SPDK NVMe library so it checks a lightweight uncore "readiness bitmap" (or per-queue ready counter) before touching the DRAM CQ. Applications are still unchanged. Demonstrates the **upper bound** of host savings by entirely eliminating the overhead of scanning empty queues.

> Mode 2A maps onto architectural Mode A unchanged. Mode 2B is *not* the same as architectural Mode B: 2B is purely a software-side polling adaptation that exploits an uncore-provided readiness signal, not a new submission path.

**5. Implementation Approach**

Two viable paths exist; **Option A is recommended** for clarity and reproducibility.

*Option A (recommended) — QEMU virtual PCIe PF + uncore engine.*
A QEMU PCIe device exposes a small register set and queue resources. Internally, QEMU runs an "uncore engine" thread that observes SQ writes / tail updates, schedules work, generates completions, and exposes them to software in batches.

Minimal device interface (BAR registers):

- `UNC_CFG` — enable/disable, mode selection (2A vs 2B), batching knobs.
- `DB_IN[i]` — per-queue doorbell input (host writes tail updates here).
- `READY_BM` — readiness bitmap (poll-lite); bit *i* set means queue *i* has ≥ 1 completion ready.
- `READY_CNT[i]` — per-queue ready count (optional).
- `CQ_MIRROR_BASE[i]` — host address for CQ mirroring (optional).

Per-queue state inside QEMU (acts like SRAM): `sq_head`, `sq_tail_shadow`, `cq_head`, `cq_tail_shadow`, `pending_completions`, `doorbell_pending`, plus timeout timers.

*Option B (fallback) — kernel pseudo-device.* A kernel module emulates readiness/batching; faster only if kernel infrastructure is already on hand. Less portable; prefer Option A unless kernel work is already planned.

**6. Backing Model for Storage Work**

Choose one, increasing fidelity in stages:

1. **Synthetic completion model (start here):** Configurable latency distribution, no payload. Validates mechanism cleanly.
2. **File-backed block device:** Forwards to a file with injected latency; adds realism.
3. **Real SSD backing:** Forwards to a real device. Noisier; introduce only later, and only if reviewers demand "real I/O."

**7. Step-by-Step Build Plan**

1. **Minimal queue engine (no NVMe yet).** Implement N queues; host writes `DB_IN[i] = new_tail`; proxy updates `sq_tail_shadow`; proxy schedules completions after fixed latency and appends to `pending_completions`.
2. **CQ suppression (batch exposure).** Add knobs `CQ_BATCH_N` and `CQ_BATCH_T`. Publish CQEs to host-visible memory when `pending ≥ N` or timer ≥ T.
3. **Doorbell aggregation.** Add knobs `DB_BATCH_B` and `DB_BATCH_T`. Absorb host doorbells; forward/commit work only every B doorbells or on timer.
4. **Transparent path (Mode 2A).** Provide a DRAM-mirrored CQ ring visible to software so a polling loop can observe CQEs by reading the mirror.
5. **Poll-lite interface.** Maintain `READY_BM` / `READY_CNT[i]` based on pending completions; clear readiness bits when batches drain.
6. **Minimal SPDK NVMe library enablement (Mode 2B).** Patch only the polling loop to check `READY_BM` first and only touch the DRAM CQ for queues whose bit is set. Keep the patch isolated to one function; applications remain unchanged.

**8. Running Workloads**

Phase 2 should run at least:

- `spdk_nvme_perf` (or `bdevperf`) for controlled sweeps.
- An embedding-like microbenchmark: random 4 KB / 16 KB reads into reused, pinned huge-page buffers.

Whether using QEMU host- or guest-side, the requirement is that *application* behavior is unchanged (IO size, QD, qpair count, buffer reuse).

**9. Experiment Matrix** Keep the matrix small and interpretable; align with Phase 1 sweeps for direct comparison.

1. Fix workload (4 KB random reads), QD, and qpairs.
2. Sweep `CQ_BATCH_N ∈ {1, 4, 16, 64}` at fixed `CQ_BATCH_T`.
3. Sweep `CQ_BATCH_T ∈ {0, 2 µs, 10 µs, 50 µs}` at fixed `CQ_BATCH_N`.
4. Sweep `DB_BATCH_B` similarly.
5. Compare Mode 2A vs Mode 2B at identical knobs.

Outputs: latency–throughput trade curves and cycles/IO vs batching parameters.

**10. Metrics and Telemetry Collection** This phase collects both the Phase 1 must-have metrics (for direct comparison) and prototype-specific diagnostics:

- **Foundational (must align with Phase 1):** IOPS; p50, p99, p99.9 latency; cycles/IO; instructions/IO; polls per completion; DRAM read/write bytes per I/O; MMIO doorbells per I/O.
- **Uncore Diagnostics:** Average CQ publish batch size (effective *N*); average doorbell aggregation size (effective *B*); readiness-bitmap hit rate (Mode 2B only).

**11. Correctness Criteria (Must Always Hold)**

- Every completion corresponds to exactly one submission.
- Command ordering within a queue is preserved as required by NVMe.
- No dropped CQEs; head/tail wrap is handled correctly.
- Progress is guaranteed under low load via timeout-driven publish.

**12. Success Criteria and Outcomes** Phase 2 is successful if:

- Mode 2A shows measurable reductions in cycles/IO and DRAM metadata bytes/IO at comparable latency to the Phase 1 baseline.
- Mode 2B shows substantially larger reductions, especially as qpairs scale (validates the scanning-overhead claim).
- Trade curves show a clear p99-latency vs CPU-cost trade as `N`, `T`, `B` vary.

This validates the Phase 1 counterfactual under real software behavior and provides a rigorous lower/upper-bound envelope for the uncore's impact before silicon work begins.

**13. Additional Phase 2 Experiments (Recommended)**

- **Multi-Queue Stress.** Aggressively sweep qpairs (1 → 4 → 16 → 64 → 128) at fixed IO size and QD. Plot cycles/IO and scans/completion for Mode 2A vs Mode 2B. Goal: show poll-lite eliminates scanning-overhead growth with qpairs.
- **Multi-Device Composition.** Instantiate 2–4 virtual devices; distribute qpairs. Goal: show the uncore model composes cleanly as device count scales.
- **Backing-Model Sensitivity.** Run identical batching knobs against the synthetic generator, file-backed device, and (optionally) a real NVMe namespace. Goal: confirm the CPU/DRAM savings are not artifacts of the backing model.
- **Readiness-Interface Quality (Mode 2B).** Report bitmap hit rate and false-work rate (% of readiness checks that drain ≥ 1 completion; avg completions drained per ready queue). Goal: prove poll-lite does not add overhead or misprediction.
- **Low-Load and Burst Behavior (Timeout Correctness).** Test at low IOPS and bursty loads. Verify that the timeout `T` bounds latency without harming throughput.

### Phase 3: RTL and Silicon Feasibility

**1. Objective and Rationale** 

While Phases 1 and 2 focus on establishing and validating the architectural motivation, the primary goal of Phase 3 is to **prove the physical silicon feasibility** of the IO-Uncore. This phase aims to definitively demonstrate that the hot-path control logic is computationally inexpensive, fast, and realistically buildable in silicon. The evaluation strictly shifts to validating hardware cost, power efficiency, and timing delays, explicitly avoiding the re-justification of the architectural concepts already proven in the earlier phases.

**2. Scope of HDL/RTL Design** To maintain a highly targeted and manageable evaluation, the Register-Transfer Level (RTL) design scope is deliberately minimal, focusing exclusively on the hot-path control logic. Full implementations of NVMe controllers, the PCIe stack, and the IOMMU are explicitly out of scope, as they do not represent the core bottleneck being solved. The targeted RTL components include:

- **Submission Queue (SQ) Engine:** Hardware logic for managing head/tail updates, credit tracking, and the SQE decode pipeline.
- **Completion Queue (CQ) Engine:** Logic for handling completion enqueues, moderation state, and the batched writeback interface.
- **Doorbell Coalescer:** Finite state machines (FSMs), counters, and timers dedicated to doorbell aggregation.
- **DMA Sequencer:** An abstracted sequencer utilizing token-based issue mechanisms and explicit backpressure.
- **Hardware Scheduler:** Lightweight scheduling logic (e.g., weighted round-robin or deficit fair queuing) to ensure multi-tenant fairness at line rate.

**3. Experimental Workflow and Tasks** The workflow mirrors standard ASIC front-end design processes to generate realistic hardware estimates:

- **SRAM Banking Analysis:** Because the IO-Uncore is fundamentally an SRAM-dominated architecture, physical feasibility hinges heavily on SRAM bandwidth limits. Researchers must calculate the expected SRAM accesses per I/O operation (e.g., pointer updates and FIFO pushes/pops) and multiply this by the target throughput (e.g., 30 to 40 million IOPS per tile) to carefully select the required SRAM bank count and port configuration.
- **Logic Synthesis:** The RTL code is synthesized using standard-cell libraries targeting mature manufacturing nodes, such as 12nm, 7nm, or 6nm. Industry-standard synthesis tools (e.g., Synopsys Design Compiler or Fusion Compiler) are employed alongside compiled SRAM macros to capture highly realistic area and power estimates.
- **Power and Activity Estimation:** To determine dynamic power consumption, researchers use execution traces or analytic toggle models generated during the Phase 1 and 2 workloads. Tools like PrimeTime PX process Switching Activity Interchange Format (SAIF) or Value Change Dump (VCD) files from long-running simulations to accurately estimate power dissipation.

**4. Metrics and PPA (Power, Performance, Area) Collection** This phase abandons software metrics in favor of standard physical design metrics to quantify the hardware overhead:

- **Area:** Total silicon area breakdown, explicitly distinguishing between the footprint of the logic gates and the SRAM arrays.
- **Performance (Latency and Frequency):** The maximum sustainable clock frequency and the absolute added datapath latency, measured strictly in nanoseconds.
- **Power and Energy:** Total dynamic power consumption under load and the normalized energy consumed per individual I/O operation, measured in nanojoules per I/O (nJ/I/O).
- **Throughput Limits:** The theoretical maximum sustainable IOPS dictated by SRAM port limitations and logic path delays.

**5. Success Criteria and Outcomes** Phase 3 is considered successful if the synthesized ASIC implementation can comfortably sustain the target throughput of 30 to 40 million IOPS per tile without requiring an excessively complex or highly ported SRAM architecture. Furthermore, the design must:

- Fit within a stringent power envelope of 10 to 15 Watts per tile.
- Operate with an energy efficiency in the tens-of-nanojoules per I/O range.
- Add no more than 200 nanoseconds of latency to the host-to-storage datapath (target: O(100 ns)).
- Demonstrate that **area and power scale linearly with the number of active queue pairs and total SRAM size**, with no disproportionate growth in shared logic — confirming that scaling out is achieved by adding tiles rather than monolithically expanding a single tile.

Achieving these rigorous metrics will definitively prove that the IO-Uncore is a highly efficient, low-risk addition suitable for integration into future CPU I/O chiplets.