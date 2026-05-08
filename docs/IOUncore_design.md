# I/O Uncore for massive CPU I/O support

## Motivation

The Rise of Data-Intensive AI Workloads: Modern AI applications, such as large language models (LLMs), AI agents, and vector databases, require massive, fine-grained access to datasets that far exceed the physical capacity of host DRAM or GPU memory. This forces systems to rely heavily on NVMe storage to handle millions of sparse, small-block reads (e.g., 512 bytes to 4KB) simultaneously.

The Device-Host Utilization Gap: Next-generation "Storage-Next" SSDs are evolving to deliver tens to hundreds of millions of random IOPS per device. However, modern host processors face a hard architectural ceiling, typically capping at 0.5 to 1.5 million small-block IOPS per CPU core, which leaves the massive parallelism of modern SSDs stranded behind host-side bottlenecks.

The Inadequacy of Software-Driven I/O: Even when utilizing highly optimized, kernel-bypass software frameworks like SPDK or asynchronous interfaces like io_uring to eliminate system calls, fundamental hardware overheads persist. Software-driven NVMe queue execution is crippled by per-I/O Memory-Mapped I/O (MMIO) doorbells, Completion Queue (CQ) polling of device-written cachelines, and DRAM metadata churn at submission and completion stage, which continuously cost 700 to 1200 CPU cycles per I/O operation.

Thermal and Economic Unsustainability: Attempting to bridge the IOPS gap by dedicating dozens of CPU cores to full-core busy polling is practically unscalable. Sustaining tens of millions of IOPS purely in software can consume 100 to 200 Watts of host processor power just for I/O management—often exceeding the power consumption of the storage devices themselves.

Limitations of Current Accelerators (DPUs and GDS): Existing hardware offloads do not solve the local, fine-grained control path problem. While GPUDirect Storage (GDS) successfully bypasses the CPU for the data path, the CPU still manages the control path, creating a severe bottleneck for small-block inferencing IOPS. Similarly, Data Processing Units (DPUs) are excellent for networked multi-tenancy, but routing direct-attached local NVMe traffic through them introduces additional PCIe hops, complex topology constraints, and 20 to 40 Watts of extra System-on-a-Chip (SoC) power overhead.

The Collapse of Historical Caching Economics: The combination of GPU processing speeds and scalable Storage-Next SSDs fundamentally changes system economics. Calibrated models demonstrate that the classical "Five-Minute Rule" for keeping data in DRAM has collapsed to a "Five-Second Rule". This paradigm shift proves that NAND flash must now be treated as an active, high-throughput tier of the memory hierarchy, making the elimination of host-side execution overheads an absolute necessity rather than an optional optimization.
Problem Statement

Therefore, the primary problem this research aims to solve is the systemic inefficiency of the host-side I/O path. We seek to eliminate this bottleneck by evaluating the physical relocation of the I/O execution plane into a dedicated CPU "IO-Uncore" utilizing private SRAM , and by allowing accelerators to autonomously manage both the data and control paths. By definitively decoupling IOPS scaling from CPU core limits, this research provides the architectural foundation necessary to fully exploit CPU capabilities under high IOPS environment, redefining the traditional memory hierarchy and collapsing the historical data caching threshold from minutes to seconds.

## Architecting the Host-Integrated IO-Uncore

To definitively decouple IOPS scaling from CPU core counts without incurring the latency and power penalties of external DPUs, the execution plane for I/O must be physically relocated into the CPU uncore. This architectural shift perfectly mirrors the historical integration of the memory controller into the CPU die—a watershed design evolution that successfully eliminated the latency and power choke of the external front-side bus (FSB). By embedding an "IO-Uncore" directly within the CPU's I/O chiplet, adjacent to the PCIe and DDR controllers, the system achieves single-digit nanosecond communication latencies and sub-picojoule per bit energy consumption.

### Methodology: 

Core Functionalities of the I/O Uncore
To effectively decouple IOPS scaling from CPU cores, the I/O uncore methodology delegates specific hot-path responsibilities to dedicated hardware state machines. These functionalities are logically structured in order of their operational impact on system overhead :


*SRAM-Resident SQ/CQ Execution*: The foundational principle of the architecture is to execute NVMe Submission Queue (SQ) and Completion Queue (CQ) control logic entirely from uncore-private SRAM. By keeping head/tail pointers and per-queue metadata off the host DRAM, the uncore eliminates the coherence traffic, polling overhead, and metadata bandwidth that typically dominate software execution at scale.

*Doorbell Aggregation and CQ Suppression*: The uncore replaces per-I/O MMIO doorbells with batched, rate-controlled signaling to mitigate PCIe fabric congestion. Concurrently, CQ suppression accumulates completions within the SRAM and exposes them to host DRAM only in defined batches, drastically reducing CQ cacheline churn and pointer coherence traffic without relying on empty polling iterations.
DMA Orchestration and Pipelining: Once queue management overhead is removed, the uncore translates SQEs into deeply pipelined DMA operations. This hardware sequencer utilizes token-based issue mechanisms with explicit backpressure, natively supporting deep Scatter-Gather Lists (SGL) and handling both cache-bypass and cache-facing streams.

*Hardware QoS and Fairness*: Because software-based schedulers are too coarse to operate effectively at ultra-high IOPS, the I/O uncore enforces per-queue and per-tenant scheduling quotas directly in hardware. Utilizing mechanisms like weighted Round Robin (RR) or Deficit Fair Queuing (DFQ), it ensures strict multi-tenant fairness at line rate, independent of the host CPU.

*Telemetry and Observability*: To validate performance and fairness, an integrated telemetry engine collects per-flow counters, latency histograms, and usable IOPS data directly in hardware. This visibility is crucial for dynamically tuning batching policies and monitoring energy efficiency at scale.

*IOMMU Assist*: As a secondary optimization for environments utilizing pinned huge-page buffers, the uncore provides opportunistic address translation assistance through large I/O-TLBs, lookahead prefetching, and page-walk caching, effectively minimizing translation stalls.

## Hardware Responsibilities and SRAM Sizing
The host-integrated I/O uncore is fundamentally designed to absorb the hot-path work of NVMe queue semantics using simplistic hardware state machines and highly localized, private Static Random-Access Memory (SRAM). Private SRAM is selected over shared Last-Level Cache (LLC) or host DRAM because it completely avoids cache coherence traffic, provides deterministic latency, and consumes orders of magnitude less energy per access.

The critical hardware responsibilities assigned to the IO-Uncore include a dedicated NVMe Queue Engine that executes Submission Queue (SQ) and Completion Queue (CQ) logic entirely in hardware, moving head and tail pointers and per-queue metadata out of host DRAM. A Hardware Doorbell Aggregator replaces per-I/O MMIO doorbells with batched, rate-controlled signaling, substantially reducing the device-facing doorbell frequency. Simultaneously, a CQ Suppression mechanism accumulates completions in SRAM and exposes them to host DRAM only in defined batches. This drastically reduces CQ cacheline churn and the associated pointer coherence traffic that currently cripples software polling loops. Furthermore, the architecture includes a DMA Orchestrator capable of translating SQEs into deeply pipelined DMA operations with explicit backpressure, optimizing both cache-bypass and cache-facing streams. To ensure multi-tenant stability, the IO-Uncore enforces hardware-level Quality of Service (QoS) and fairness through per-cgroup quotas using weighted Round Robin or Deficit Fair Queuing at line rate, while an integrated telemetry engine collects per-flow latency histograms to validate performance.

SRAM sizing within the uncore is dictated by the active queue working sets rather than the total configured queue depth of the SSDs. Architectural models establish a requirement of approximately 8 KB of SRAM per actively polling Queue Pair (QP), segmented symmetrically into 4 KB for the SQ and 4 KB for the CQ. Accounting for an additional 2 MB per uncore tile for shared structures like the I/O Translation Lookaside Buffer (I/O-TLB), FIFOs, and schedulers, a single uncore tile requires roughly 3 to 11 MB of SRAM to comfortably support 10 to 80 million IOPS. For environments requiring extreme performance headroom, the SRAM allocation can scale up to 16 to 32 MB per tile.

## Evaluation
### Phase 1: 

*Commodity Hardware Measurement and Counterfactual Modeling
Objective and Rationale*

The primary goal of Phase 1 is to establish the fundamental architectural motivation for the IO-Uncore by quantitatively identifying exactly where host-side execution costs are expended in contemporary systems. The core objective is to isolate and measure the per-I/O overheads—specifically NVMe queue execution, polling, Memory-Mapped I/O (MMIO) doorbells, and DRAM metadata traffic—that fundamentally limit system scalability.

Crucially, this phase intentionally utilizes the Storage Performance Development Kit (SPDK) as the primary software baseline. Because SPDK operates entirely in the user space and bypasses the Linux kernel, system calls, and interrupt scheduling, it represents the theoretical best-case scenario for software-driven NVMe queue execution. Any latency or overhead measured within this SPDK environment is therefore definitively attributable to hardware execution costs rather than software inefficiencies, providing a rigorous justification for hardware-level intervention.

*Experimental Setup*

- Simulation Framework: The experiments are conducted based on Gem5 full system simulation. By preparing the Linux kernel supporting SPDK and a simulated disk image based on SimpleSSD, the simulation precisely reflects the overhead at each step on the I/O path.
Thread Isolation: Polling threads are strictly pinned to dedicated CPU cores to eliminate context-switching noise and ensure pristine CPU cycle measurements.

- Workload Characteristics: The simulated tasks mimic embedding-heavy pipelines (such as vector databases or AI retrieval systems). This is achieved using highly concurrent random read operations, specifically targeting 4KB and 16KB block sizes to represent standard AI embedding fetches.

- Experimental Workflow and Tasks The experimental workflow is designed to map the boundaries of host-side execution through systematic parameter sweeps.

- Execution Phases: Each task execution consists of a 10 to 30-second warm-up period, followed by a 30 to 60-second steady-state measurement window. To ensure statistical validity, all runs are repeated multiple times to report mean metrics and standard deviations.

- Parameter Sweeps: To isolate specific scaling bottlenecks, the workflow sweeps one independent variable at a time while holding the others constant. The key variables swept include:
*Queue Depth (QD)*: e.g., 16, 32, 64, 128 (to control in-flight concurrency).
*Queue Pairs*: e.g., 1, 4, 16, 64 (to scale multi-queue scanning pressure).
*Block Size*: 4KB versus 16KB (to alter the ratio of payload to metadata).
*Poller Cores*: 1, 2, and 4 cores (to capture how CPU consumption scales linearly with IOPS).
*Metrics and Telemetry Collection During the steady-state measurement windows*, a highly targeted set of metrics is collected and normalized per completed I/O operation to map the exact cost of the storage control path.
*CPU Cost*: Total CPU cycles per I/O, instructions per I/O, and total CPU utilization per poller thread.
*Polling and Scanning Intensity*: The number of completion-check polling calls required to drain a single completion. This critical metric quantifies the wasted CPU cycles spent scanning empty queues.
DRAM Traffic Overhead: Total DRAM read and write bytes per I/O. By subtracting the actual data payload size, researchers can estimate the precise DRAM metadata churn generated purely by queue management.
Doorbell Activity: The frequency of MMIO doorbell updates per I/O, which dictates PCIe fabric congestion.
*Throughput and Tail Latency*: Baseline IOPS alongside granular high-percentile tail latencies (p50, p99, p99.9).
Counterfactual Modeling (Outcome) The final task of Phase 1 is to synthesize the collected empirical data into a counterfactual mathematical model. The performance is treated as the baseline. The latter optimized design will compare with it.

### Phase 2: Virtual Prototype Validation
*1. Objective and Rationale*

While Phase 1 establishes the theoretical motivation through counterfactual modeling, Phase 2 is designed to empirically validate that these modeled host-side savings materialize under actual software execution. The primary goal is to prove behavioral fidelity: demonstrating that moving NVMe queue semantics into simulated SRAM, alongside doorbell aggregation and Completion Queue (CQ) suppression, directly translates to reduced CPU cycles and DRAM metadata traffic without violating latency targets. This phase isolates the architectural effects of the uncore before committing to the complexity of silicon synthesis.

*2. Experimental Setup*

Virtual Hardware Environment: The prototype utilizes a QEMU virtual PCIe Physical Function (PF) rather than a full ASIC implementation. This QEMU environment hosts an internal "uncore engine" thread responsible for observing Submission Queue (SQ) writes, scheduling I/O work, generating completions, and exposing them back to the host in controlled batches.
Backing Model: The storage work is initially driven by a synthetic completion model with a configurable latency distribution to validate mechanisms cleanly, with options to scale to a file-backed block device for added realism.

*3. Different modes*

Mode A:

Shadowed Rings (Default; Transparent to Software) Software (kernel NVMe or SPDK) writes SQEs to DRAM and polls DRAM CQs as usual. The uncore observes SQ writes, doorbells, and CQ DMA writes, and executes queue semantics in SRAM. DRAM-visible SQ/CQ pointers and CQEs are updated in batches for compatibility. 
What this mode demonstrates.

Zero application changes. No mandatory SPDK library changes. 
Lower-bound benefit from reduced DRAM-visible pointer execution, CQ cacheline churn, and MMIO ordering—even when SPDK continues to poll DRAM. This mode anchors the drop-in deployability story. 

Mode B:

Mailbox / Assisted Submission (Optional Enablement) Software submits SQEs via a lightweight mailbox or shadow interface to the uncore. The uncore synthesizes NVMe-compliant SQEs into DRAM rings as needed.

What this mode demonstrates:
Further reduction in DRAM writes on the submission path. 
Cleaner batching and backpressure control. 
A stepping stone for environments willing to accept minimal driver/library enablement. This mode is optional and primarily a performance/efficiency knob, not a requirement.


Mode C:

Logical Rings in SRAM (Maximum Suppression). The uncore maintains logical SQ/CQ rings entirely in SRAM. DRAM rings are updated only at bounded synchronization points (e.g., on interrupts, quiescence, or debugging). 

What this mode demonstrates：
Upper-bound efficiency when software cooperates (e.g., poll‑lite SPDK or interrupt‑per‑batch).
Elimination of DRAM-driven execution and scanning.

*4. Evaluated Interaction Modes* 

To provide a comprehensive evaluation envelope, the prototype evaluates two distinct software interaction modes:

Mode A (Transparent Mode): Operates with zero modifications to the SPDK applications or the SPDK NVMe library. Software continues to poll DRAM CQs as usual, while the uncore proxy alters the frequency of DRAM-visible state updates. This demonstrates the absolute lower bound of benefits achieved purely through batched hardware exposure.

Mode B (Poll-lite Mode): Implements minimal patching to the SPDK NVMe library, enabling it to check a lightweight uncore "readiness bitmap" before touching the DRAM CQ. This demonstrates the theoretical upper bound of host savings by entirely eliminating the overhead of scanning empty queues.

*5. Experimental Workflow and Tasks* 

The workflow mirrors Phase 1 to allow for direct comparative analysis, but adds uncore-specific parameter sweeps:
Baseline Workloads: Execution of 4KB random reads (mimicking embedding fetches) at fixed queue depths and queue pair counts. Done in phase 1

Batching Sweeps: Systematic variation of uncore batching parameters, specifically sweeping the completion batch count (CQ_BATCH_N), completion timeout (CQ_BATCH_T), and doorbell aggregation size (DB_BATCH_B).

Mode Comparison: Direct comparative runs of Mode A versus Mode B under identical batching configurations to map the delta between transparent and cooperative software models.

*6. Metrics and Telemetry Collection* 

This phase collects both the foundational system metrics from Phase 1 and new, prototype-specific diagnostics:
Foundational Metrics: Total CPU cycles per I/O, DRAM read/write bytes per I/O, MMIO doorbells per I/O, and strict tail latencies (p50, p99, p99.9) .

Uncore Diagnostics: Average CQ publish batch size (effective N), average doorbell aggregation size (effective B), and the readiness bitmap hit rate specifically for Mode B.

*7. Success Criteria and Outcomes* 

Phase 2 is deemed successful if the virtual prototype generates clear latency-throughput trade curves proving that the batching parameters reduce CPU cycles per I/O and DRAM metadata traffic at comparable baseline latencies. Furthermore, Mode B must show substantially larger reductions in scanning overhead as queue pairs scale, effectively validating the Phase 1 counterfactual models and justifying progression to the hardware RTL stage.

### Phase 3: RTL and Silicon Feasibility
*1. Objective and Rationale* 

While Phases 1 and 2 focus on establishing and validating the architectural motivation, the primary goal of Phase 3 is to prove the physical silicon feasibility of the IO-Uncore. This phase aims to definitively demonstrate that the hot-path control logic is computationally inexpensive, fast, and realistically buildable in silicon. The evaluation strictly shifts to validating hardware cost, power efficiency, and timing delays, explicitly avoiding the re-justification of the architectural concepts already proven in the earlier phases.

*2. Scope of HDL/RTL Design*

To maintain a highly targeted and manageable evaluation, the Register-Transfer Level (RTL) design scope is deliberately minimal, focusing exclusively on the hot-path control logic. Full implementations of NVMe controllers, the PCIe stack, and the IOMMU are explicitly out of scope, as they do not represent the core bottleneck being solved. The targeted RTL components include:
Submission Queue (SQ) Engine: Hardware logic for managing head/tail updates, credit tracking, and the SQE decode pipeline.
Completion Queue (CQ) Engine: Logic for handling completion enqueues, moderation state, and the batched writeback interface.
Doorbell Coalescer: Finite state machines (FSMs), counters, and timers dedicated to doorbell aggregation.

DMA Sequencer: An abstracted sequencer utilizing token-based issue mechanisms and explicit backpressure.

Hardware Scheduler: Lightweight scheduling logic (e.g., weighted round-robin or deficit fair queuing) to ensure multi-tenant fairness at line rate.

*3. Experimental Workflow and Tasks* 

The workflow mirrors standard ASIC front-end design processes to generate realistic hardware estimates:
SRAM Banking Analysis: Because the IO-Uncore is fundamentally an SRAM-dominated architecture, physical feasibility hinges heavily on SRAM bandwidth limits. Researchers must calculate the expected SRAM accesses per I/O operation (e.g., pointer updates and FIFO pushes/pops) and multiply this by the target throughput (e.g., 30 to 40 million IOPS per tile) to carefully select the required SRAM bank count and port configuration.

Logic Synthesis: The RTL code is synthesized using standard-cell libraries targeting mature manufacturing nodes, such as 12nm, 7nm, or 6nm. Industry-standard synthesis tools (e.g., Synopsys Design Compiler or Fusion Compiler) are employed alongside compiled SRAM macros to capture highly realistic area and power estimates.
Power and Activity Estimation: To determine dynamic power consumption, researchers use execution traces or analytic toggle models generated during the Phase 1 and 2 workloads. Tools like PrimeTime PX process Switching Activity Interchange Format (SAIF) or Value Change Dump (VCD) files from long-running simulations to accurately estimate power dissipation.

*4. Metrics and PPA (Power, Performance, Area) Collection*

This phase abandons software metrics in favor of standard physical design metrics to quantify the hardware overhead:
Area: Total silicon area breakdown, explicitly distinguishing between the footprint of the logic gates and the SRAM arrays.
Performance (Latency and Frequency): The maximum sustainable clock frequency and the absolute added datapath latency, measured strictly in nanoseconds.

Power and Energy: Total dynamic power consumption under load and the normalized energy consumed per individual I/O operation, measured in nanojoules per I/O (nJ/I/O).

Throughput Limits: The theoretical maximum sustainable IOPS dictated by SRAM port limitations and logic path delays.

*5. Success Criteria and Outcomes*

Phase 3 is considered successful if the synthesized ASIC implementation can comfortably sustain the target throughput of 30 to 40 million IOPS per tile without requiring an excessively complex or highly ported SRAM architecture. Furthermore, the design must fit within a stringent power envelope of 10 to 15 Watts per tile, operate with an energy efficiency in the tens-of-nanojoules per I/O range, and add no more than 200 nanoseconds of latency to the host-to-storage datapath. Achieving these rigorous metrics will definitively prove that the IO-Uncore is a highly efficient, low-risk addition suitable for integration into future CPU I/O chiplets.
