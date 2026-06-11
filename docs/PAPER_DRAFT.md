# IAU Paper Draft

> **Working title.** *IAU: Assisting the CPU Core for Next-Generation Multi-Million IOPS NVMe Devices*
> **Venue.** IEEE Computer Architecture Letters (CAL).
> **Companion file.** `docs/PAPER_OUTLINE.md` holds the section-by-section content brief, the per-paragraph logic chain, and the writing-style guardrails. Edit the outline first when scope changes; edit this file when committing finalized prose.
> **Format conventions.** Each paragraph is a single physical line with no soft wraps, so it copies cleanly into LaTeX. The prose does not use em-dashes, colons, or parentheses as parenthetical separators. Compound-modifier hyphens remain in use. Citation keys are in square brackets and resolve against `docs/paper.bib` and the lit-review primer in `docs/LITERATURE_REVIEW.md`.

---

## §1. Introduction

### P1. Device supply trend and the under-explored CPU consumer

\IEEEPARstart{M}{odern} AI retrieval pipelines impose new demands on the storage subsystem. Workloads such as billion-scale approximate nearest neighbor search over NAND-resident indices~\cite{diskann-github} and retrieval-augmented generation, in which retrieval already dominates serving cost~\cite{RAGX}, exhibit small random reads of 4 to 16 KB at multi-million IOPS rates. Device-side roadmaps have moved aggressively along two complementary axes, namely multi-device PCIe aggregation that places many high-IOPS NVMe drives behind a single CPU, and continuing per-device latency reductions under PCIe Gen5/Gen6 and emerging storage-class memory. Micron reported a single-server demonstration sustaining 230M IOPS across 44 Gen6 SSDs~\cite{meredith2025micron230m}, and NVIDIA's StorageNext initiative further frames this push as a precondition for keeping GenAI workloads fed~\cite{newburn2025storagenext}. The open question is therefore no longer whether devices can supply MIOPS but which compute substrate can consume them. Most existing research has concentrated on the GPU side~\cite{NVDIABaM}, where streaming-multiprocessor parallelism naturally absorbs the IOPS. However, such designs benefit only GPU-resident consumers and require application rewrites. The CPU consumption path, which still handles control planes, retrieval orchestration, multi-agent collaboration, and the vast majority of general-purpose I/O, remains structurally under-explored at this regime.

### P2. The host CPU wall
At multi-million-IOPS rates, user-space polled frameworks such as SPDK~\cite{Yang2017SPDKAD} and kernel-side polled paths such as io\_uring~\cite{axboe2019iouring} with SQPOLL already eliminate the syscall, interrupt, and scheduler costs that dominated earlier kernel-driven NVMe. However, a residual per-I/O cost remains that no further driver work can lift. On real Gen4 NVMe arrays running SPDK, massive available cycles from CPU cores must be dedicated to I/O submission and reaping to sustain tens-of-millions IOPS for actual application work~\cite{Haas2023WhatMN}. The cost is intrinsic to the NVMe queue execution model, in which every I/O requires PRP-list construction from a DRAM-resident submission-queue entry (SQE), a tracker for the per-I/O command-identifier lifecycle, and a coherence-paying poll on a DMA-invalidated completion cacheline. Two compounding components therefore set the per-I/O budget. The first is a control-plane instruction count that no driver can eliminate. The second is the memory hierarchy and signaling-fabric overhead from DRAM-resident queue metadata, DMA-invalidated completion cachelines, and MMIO ordering serialization. Because both components apply to every I/O and cannot be reduced by software, every additional IOPS demanded adds a fixed number of CPU cycles to the I/O path. At multi-million-IOPS rates this fixed cost grows large enough to consume a majority of the available CPU cycles. This is the host CPU wall.

### P3. IAU proposal and contributions

Existing hardware proposals discussed in \S\ref{sec:background} close this wall only inside specific deployments, namely DPU offload for disaggregated storage and FPGA NVMe controllers for fabric-replaced hosts, and the general-purpose server driving direct-attached NVMe at multi-million-IOPS rates remains unaddressed. To directly address the host CPU bottleneck on that platform, we propose IAU, an I/O Assistant Uncore that sits beside the integrated memory controller and PCIe root complex and executes the per-I/O NVMe fast path in hardware. IAU offloads the per-I/O submission, tracking, and completion work into hardware while preserving the DRAM-resident NVMe queues as a compatibility mirror, so existing I/O paradigms continue to observe a compliant controller. On a full-system Gem5~\cite{binkert2011gem5} with SimpleSSD~\cite{jung2017simplessd} simulator, IAU delivers up to 1.44$\times$ IOPS and roughly 30\% fewer cycles per I/O over an unmodified SPDK baseline on a DiskANN trace replay~\cite{diskann-github}, with the same lift reproduced on a synthetic 4 KB random read workload. We synthesize IAU at ASAP7 7nm~\cite{clark2016asap7} across four queue-resource configurations and report an uncore-scale footprint of 30K to 93K standard cells, 0.1 to 0.9 $mm^2$ of on-die SRAM, and 14 to 49 mW of post-synthesis logic power at 1 GHz. Residual host-side polling remains the bottleneck at this lifted ceiling, motivating a hardware completion-callback dispatcher that we identify and defer to future work.

---

## §2. Background
\label{sec:background}

### 2.1 NVMe queue execution model
\label{sec:background-mech}

NVMe exposes its control plane through ring buffers placed in host DRAM and a small set of memory-mapped doorbells on the device. Each controller maintains one administrative queue pair together with a configurable set of I/O submission queues and completion queues, with every ring carrying its own head and tail pointers in DRAM. One submission-queue doorbell and one completion-queue doorbell per queue are mapped into BAR0 of the device's MMIO window~\cite{nvme-spec}. An I/O begins when the host formats a 64-byte submission-queue entry (SQE) that carries the opcode, the logical block address, and a PRP or SGL list locating the data buffer, writes the SQE into the submission ring, and issues an MMIO store to the submission-queue tail doorbell that hands the entry to the device. The device then fetches the SQE via DMA, executes the command against the namespace, transfers the data payload into the host buffer over DMA, writes a 16-byte completion-queue entry (CQE) into the completion ring, flips a phase bit on that CQE, and optionally fires an MSI-X interrupt. The host either polls the completion ring for the phase change or wakes on the interrupt, services the completion, and issues a second MMIO store to the completion-queue head doorbell to release the slot. Four recurring costs are paid on this path by every I/O regardless of how thin the software stack is. The first cost is doorbell traffic, where each I/O issues an MMIO store to BAR0 that drains through the CPU's posted-write path and cannot be coalesced with prior cacheable stores to the ring. The second cost is completion polling, where each new CQE the device DMAs into the CQ ring forces the polling cacheline through a coherence transition on the host core, paying an LLC- or memory-side miss per completion at saturation. The third cost is queue-state coherence traffic, where each I/O writes one SQE cacheline that the device must pull from the host's cache hierarchy and one CQE cacheline that the device writes back into it, paying a cache-line round-trip per I/O regardless of payload size. The fourth cost is ordering serialization, where the architectural fence between each SQE write and its doorbell store, and between each completion observation and the CQ head doorbell update, prevents the CPU from pipelining adjacent submissions or completions through its store buffer. These four costs together set the per-IO cost floor that any approach to the multi-million-IOPS regime must contend with.

### 2.2 The state of the art at multi-million-IOPS scale
\label{sec:background-sota}

This per-IO cost floor is what makes SPDK the right baseline to study, not because SPDK is easy to beat but because it is already the best-case software path at the regime in question. SPDK pins each I/O thread to a hugepage-resident memory pool, drives the NVMe queues from user space, and replaces the kernel block layer with a direct PRP-driven datapath that emits no syscalls, takes no interrupts, and visits no scheduler~\cite{Yang2017SPDKAD}. Any residual cost observed under SPDK therefore reflects the per-IO cost of the queue execution model laid out in \S\ref{sec:background-mech}, not Linux block-layer overhead or driver bloat. The kernel-side ultra-low-latency I/O path explored by i10 confirms this view from the opposite direction, since even aggressive kernel optimization closes the latency gap with SPDK while still paying the same per-IO architectural costs in a different layer~\cite{i10-atc19}. We use SPDK as the primary baseline throughout the paper and io\_uring with SQPOLL as a qualitative cross-check, because both stacks exhibit the same per-IO saturation behavior at the multi-million-IOPS regime and the wall they cannot lift is the same. The natural next question is whether existing hardware approaches close that gap.

The wall has motivated several lines of hardware work that aim to move I/O execution off the host CPU, and two main responses have emerged. DPUs and IPUs such as NVIDIA BlueField and Intel Mount Evans take some of the storage and network stack off the host by running NVMe-over-Fabrics initiators, infrastructure services, and software-defined networking on a separate Arm SoC located on the network-facing side of the server~\cite{nvidia2026bluefield4}. This is the natural fit when storage is disaggregated and accessed over a fabric, but it leaves direct-attached NVMe on the host CPU unchanged. FPGA NVMe host controllers such as AMD NVMeHA and the related NVMeCHA and DirectNVM designs go further by running the entire NVMe initiator in fabric and exposing a fixed-function block interface to the application~\cite{amd_nvmeha_pb058,nvmecha,directnvm}. This eliminates per-I/O CPU work in CPU-constrained appliances and embedded systems, but it requires the host's general-purpose stack to be replaced wholesale and so is not viable on servers that continue to run POSIX, io\_uring, and SPDK. In each case the design closes the wall only inside the deployment it was built for, namely disaggregated storage on the DPU side and fabric-replaced hosts on the FPGA side, and the general-purpose server driving direct-attached NVMe at multi-million-IOPS rates remains unaddressed by both categories.

### 2.3 Per-IO cost characterization
\label{sec:background-cycles}

\begin{figure}[t]
\centering
\includegraphics[width=\columnwidth]{figures/cycle_breakdown.pdf}
\caption{Per-IO cost decomposition for 4~KB random reads on a single host core and a single queue pair, comparing vanilla SPDK at QD=16 and QD=128. Each bar stacks the six lifecycle stages of an NVMe I/O in temporal order from bottom to top.}
\label{fig:cycle_breakdown}
\end{figure}

The four per-IO costs above describe what any host driver must pay, but how those costs distribute across the actual stages of the SPDK fast path is a question we answer empirically. We instrument a full-system gem5~\cite{binkert2011gem5} simulation running the unmodified \texttt{spdk\_nvme\_perf} workload against SimpleSSD~\cite{jung2017simplessd} configured as a multi-million-IOPS NVMe device model, and drive 4~KB random reads from a single host core through a single queue pair at queue depths from 16 to 128. The configuration models a device whose per-stage latency stays below the host's per-IO software cost, so that the host CPU rather than the storage media is the binding bottleneck of the measurement. We decompose the per-IO budget into the six lifecycle stages an NVMe I/O traverses from start to end, namely SQE and PRP-list construction, tracker allocation, the submission-queue doorbell write together with its ordering fence, completion polling on the CQ phase bit, the completion handler that fires the callback and releases the tracker, and the completion-queue doorbell write together with the final buffer cleanup.

Figure~\ref{fig:cycle_breakdown} shows the resulting breakdown at QD=16 and QD=128 on a 2~GHz simulated host. Single-core IOPS saturate near 0.8~M throughout the sweep, rising only from 776~K at QD=16 to 819~K at QD=128, a 5\% lift across an 8$\times$ queue-depth increase, and the two bars sit within the same 5\% of each other in total height, establishing the cost as per-IO structural rather than per-batch amortized. The submission-side work and the completion handler together dominate the host budget, with completion polling and the two doorbell stages contributing the remainder. Mapping these stages back to the architectural costs identified above, the submission-side work and the completion handler embody the queue-state coherence traffic that every SQE and CQE round-trip pays, the doorbell stages embody the MMIO posted-write cost paired with the ordering fence that the protocol forces between SQE write and doorbell store, and completion polling embodies the cache-line coherence transition that the device's CQE DMA imposes on the host. The total cycles per I/O under this baseline sit in the same order of magnitude as published single-core, single-qpair SPDK measurements on production NVMe hardware~\cite{Yang2017SPDKAD}.

The flat saturation curve has a direct architectural consequence. Because the total per-IO budget does not shrink with queue depth, no purely software-side approach that relies on deeper batching can lower it, and any meaningful reduction in cycles per I/O must therefore eliminate work from the per-IO critical path itself.

---

## §3. IAU: A Host-Integrated I/O Uncore
\label{sec:iau}

% TODO bib:intel_vmd --- Intel Volume Management Device reference (used in \S3.1 below).

### 3.1 Placement and principle
\label{sec:iau-placement}

IAU sits on the CPU die as an on-die I/O assistant block co-located with the integrated memory controller and the PCIe root complex, shared across the cores within a chiplet. Placement of NVMe-touching logic inside the uncore has precedent, since Intel's Volume Management Device already resides there to perform PCIe enumeration and namespace registration~\cite{intel_vmd}, and IAU extends that pattern from enumeration-only services to per-IO queue execution.

\begin{figure}[t]
\centering
\includegraphics[width=\columnwidth]{figures/iau_block.png}
\caption{IAU placement, structure, and per-IO dataflow. The uncore sits beside the IMC and PCIe root complex on the CPU die; three hot-path engines (SQ Engine, CQ Engine, Doorbell Coalescer) execute the NVMe fast path over a shared SRAM, with the Credit Manager and MMIO decoder as grey support blocks. The circled markers trace one I/O: (1) the host submits through the mailbox, (2) the SQ Engine builds the SQE with its PRP list and command ID, (3) the Doorbell Coalescer aggregates doorbells, (4) the command issues to the device over PCIe, (5) the CQ Engine batches the completion, and (6) the host polls a single status-and-hint register. The DRAM-resident SQ and CQ rings are mirrored in batches for compatibility (dashed).}
\label{fig:iau_block}
\end{figure}

Internally, IAU decouples the architectural view of the storage controller from its execution substrate, so that software and the NVMe specification continue to observe DRAM-resident submission and completion rings, standard head/tail semantics, and conventional MSI-X interrupts, while the uncore privately executes the per-IO hot path from SRAM-resident state and updates the DRAM rings in batches as a compatibility mirror. The mirror is maintained by batching completion-queue entries into DRAM under a count-or-timer policy, aggregating per-IO MMIO doorbells from the uncore to the device under the same policy, and coalescing MSI-X interrupts so that one interrupt covers many completed I/Os. These mirroring behaviors follow directly from the compatibility-mirror principle and are not separately evaluated modes of operation.

POSIX, io\_uring, and SPDK application interfaces are unchanged by this separation. Only the NVMe driver, or in user-space deployments the SPDK NVMe library, needs to be aware of IAU, and that awareness is required only at queue-setup time in order to opt into the mailbox submission path and the typed hint register. A second principle, complementary to the first, partitions every per-IO stage into an NVMe-protocol portion that IAU absorbs into hardware and an application portion that remains on the CPU because moving it off-die would change application semantics. The protocol portion comprises the 64-byte SQE encoding, the PRP and SGL list construction, the command-identifier lifecycle, the CQE parse, the management of submission and completion ring slots, and the doorbell-MMIO ordering. The application portion comprises the compact descriptor that names each I/O by logical block address, length, and buffer pointer, the in-flight handle that carries the user callback pointer and user context, the mailbox MMIO notification that wakes the uncore, the callback execution itself, and the return of the data buffer to the application-side memory pool. This boundary is what the non-zero IAU residuals on Fig.~\ref{fig:cycle_breakdown} represent, and \S\ref{sec:iau-mechanisms} walks each of the hot-path engines through this offload-and-residual split.

### 3.2 Hot-path engines
\label{sec:iau-mechanisms}

*Pending draft.*

### 3.3 NVMe compliance and the fail-safe
\label{sec:iau-compliance}

*Pending draft.*

### 3.4 SRAM sizing and silicon plausibility
\label{sec:iau-sram}

*Pending draft.*

---

## §4. Evaluation

*Pending draft.*

---

## §5. Conclusion

*Pending draft.*
