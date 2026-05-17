# IAU Paper Draft

> **Working title.** *IAU: Assisting the CPU Core for Next-Generation Multi-Million IOPS NVMe Devices*
> **Venue.** IEEE Computer Architecture Letters (CAL).
> **Companion file.** `docs/PAPER_OUTLINE.md` holds the section-by-section content brief, the per-paragraph logic chain, and the writing-style guardrails. Edit the outline first when scope changes; edit this file when committing finalized prose.
> **Format conventions.** Each paragraph is a single physical line with no soft wraps, so it copies cleanly into LaTeX. The prose does not use em-dashes, colons, or parentheses as parenthetical separators. Compound-modifier hyphens remain in use. Citation keys are in square brackets and resolve against `docs/paper.bib` and the lit-review primer in `docs/LITERATURE_REVIEW.md`.

---

## §1. Introduction

### P1. Device supply trend and the under-explored CPU consumer

\IEEEPARstart{M}{odern} AI retrieval pipelines impose new demands on the storage subsystem. Workloads such as billion-scale approximate nearest neighbor search over NAND-resident indices~\cite{diskann-github} and retrieval-augmented generation, in which retrieval already dominates serving cost~\cite{RAGX}, exhibit small random reads of 4 to 16 KB at multi-million IOPS rates. Device-side roadmaps have moved aggressively to meet this demand. Micron reported a single-server demonstration sustaining 230M IOPS across 44 Gen6 SSDs~\cite{meredith2025micron230m}. NVIDIA's StorageNext initiative further frames this push as a precondition for keeping GenAI workloads fed~\cite{newburn2025storagenext}. The open question is therefore no longer whether devices can supply MIOPS but which compute substrate can consume them. Most existing research has concentrated on the GPU side~\cite{NVDIABaM}, where streaming-multiprocessor parallelism naturally absorbs the IOPS. However, such designs benefit only GPU-resident consumers and require application rewrites. The CPU consumption path, which still handles control planes, retrieval orchestration, multi-agent collaboration, and the vast majority of general-purpose I/O, remains structurally under-explored at this regime.

### P2. The host CPU wall
At multi-million-IOPS rates, user-space polled frameworks such as SPDK~\cite{Yang2017SPDKAD} and kernel-side polled paths such as io\_uring~\cite{axboe2019iouring} with SQPOLL already eliminate the syscall, interrupt, and scheduler costs that dominated earlier kernel-driven NVMe. However, a residual per-I/O cost remains that no further driver work can lift. On real Gen4 NVMe arrays running SPDK, massive available cycles from CPU cores must be dedicated to I/O submission and reaping to sustain tens-of-millions IOPS for actual application work~\cite{Haas2023WhatMN}. The cost is intrinsic to the NVMe queue execution model, in which every I/O requires PRP-list construction from a DRAM-resident submission-queue entry (SQE), a tracker for the per-I/O command-identifier lifecycle, and a coherence-paying poll on a DMA-invalidated completion cacheline. Two compounding components therefore set the per-I/O budget. The first is a control-plane instruction count that no driver can eliminate. The second is the memory hierarchy and signaling-fabric overhead from DRAM-resident queue metadata, DMA-invalidated completion cachelines, and MMIO ordering serialization. Because both components apply to every I/O and cannot be reduced by software, every additional IOPS demanded adds a fixed number of CPU cycles to the I/O path. At multi-million-IOPS rates this fixed cost grows large enough to consume a majority of the available CPU cycles. This is the host CPU wall.

### P3. IAU proposal and contributions

Existing hardware proposals discussed in \S\ref{sec:background} close this wall only inside specific deployments, namely DPU offload for disaggregated storage and FPGA NVMe controllers for fabric-replaced hosts, and the general-purpose server driving direct-attached NVMe at multi-million-IOPS rates remains unaddressed. To directly address the host CPU bottleneck on that platform, we propose IAU, an I/O Assistant Uncore that sits beside the integrated memory controller and PCIe root complex and executes the per-I/O NVMe fast path in hardware. IAU offloads the per-I/O submission, tracking, and completion work into hardware while preserving the DRAM-resident NVMe queues as a compatibility mirror, so existing I/O paradigms continue to observe a compliant controller. On a full-system Gem5~\cite{binkert2011gem5} with SimpleSSD~\cite{jung2017simplessd} simulator, IAU delivers up to 1.44$\times$ IOPS and roughly 30\% fewer cycles per I/O over an unmodified SPDK baseline on a DiskANN trace replay~\cite{diskann-github}, with the same lift reproduced on a synthetic 4 KB random read workload. We synthesize IAU at ASAP7 7nm~\cite{clark2016asap7} across four queue-resource configurations and report an uncore-scale footprint of 30K to 93K standard cells, 0.1 to 0.9 $mm^2$ of on-die SRAM, and 14 to 49 mW of post-synthesis logic power at 1 GHz. Residual host-side polling remains the bottleneck at this lifted ceiling, motivating a hardware completion-callback dispatcher that we identify and defer to future work.

---

## §2. Background
\label{sec:background}

### 2.1 NVMe queue execution model
\label{sec:background-mech}

NVMe exposes its control plane through ring buffers placed in host DRAM and a small set of memory-mapped doorbells on the device. Each controller maintains one administrative queue pair together with a configurable set of I/O submission queues and completion queues, every ring carrying its own head and tail pointers in DRAM, and one submission-queue doorbell and one completion-queue doorbell per queue mapped into BAR0 of the device's MMIO window~\cite{nvme-spec}. An I/O begins when the host formats a 64-byte submission-queue entry (SQE) that carries the opcode, the logical block address, and a PRP or SGL list locating the data buffer, writes the SQE into the submission ring, and issues an MMIO store to the submission-queue tail doorbell that hands the entry to the device. The device then DMAs the SQE, executes the command against the namespace, DMAs the data payload into the host buffer, writes a 16-byte completion-queue entry (CQE) into the completion ring, flips a phase bit on that CQE, and optionally fires an MSI-X interrupt; the host either polls the completion ring for the phase change or wakes on the interrupt, services the completion, and issues a second MMIO store to the completion-queue head doorbell to release the slot. Four recurring costs are paid on this path by every I/O regardless of how thin the software stack is. The first cost is doorbell traffic, where ring writes target uncacheable write-combining memory and serialize against pending stores in the outgoing posted-write queue. The second cost is completion polling, where each probe reads a cacheline that the device's DMA writes have perpetually invalidated and pays a coherence miss on every observation. The third cost is metadata bandwidth, where the DRAM-resident ring head, tail, phase, and credit fields are read and written once per I/O and so consume memory bandwidth proportional to delivered IOPS. The fourth cost is ordering serialization, where PCIe posted-write ordering rules and the architectural memory fences required around doorbell rings and completion observations force serialization between adjacent I/O operations. Every design move in \S\ref{sec:design} maps to one of these four costs, and \S\ref{sec:background-cycles} quantifies which of them carries the largest fraction of the per-IO budget under an unmodified SPDK baseline.

### 2.2 The state of the art at multi-million-IOPS scale
\label{sec:background-sota}

This per-IO cost floor is what makes SPDK the right baseline to study, not because SPDK is easy to beat but because it is already the best-case software path at the regime in question. SPDK pins each I/O thread to a hugepage-resident memory pool, drives the NVMe queues from user space, and replaces the kernel block layer with a direct PRP-driven datapath that emits no syscalls, takes no interrupts, and visits no scheduler~\cite{Yang2017SPDKAD}. Any residual cost observed under SPDK therefore reflects the per-IO cost of the queue execution model laid out in \S\ref{sec:background-mech}, not Linux block-layer overhead or driver bloat. The kernel-side ultra-low-latency I/O path explored by i10 confirms this view from the opposite direction, since even aggressive kernel optimization closes the latency gap with SPDK while still paying the same per-IO architectural costs in a different layer~\cite{i10-atc19}. We use SPDK as the primary baseline throughout the paper and io\_uring with SQPOLL as a qualitative cross-check, because both stacks exhibit the same per-IO saturation behavior at the multi-million-IOPS regime and the wall they cannot lift is the same; the natural next question is whether existing hardware approaches close that gap.

The wall has motivated several lines of hardware work that aim to move I/O execution off the host CPU, and two main responses have emerged. DPUs and IPUs such as NVIDIA BlueField and Intel Mount Evans take some of the storage and network stack off the host by running NVMe-over-Fabrics initiators, infrastructure services, and software-defined networking on a separate Arm SoC located on the network-facing side of the server~\cite{nvidia2026bluefield4}, which is the natural fit when storage is disaggregated and accessed over a fabric but which leaves direct-attached NVMe on the host CPU unchanged. FPGA NVMe host controllers such as AMD NVMeHA and the related NVMeCHA and DirectNVM designs go further by running the entire NVMe initiator in fabric and exposing a fixed-function block interface to the application~\cite{amd_nvmeha_pb058,nvmecha,directnvm}, which eliminates per-I/O CPU work in CPU-constrained appliances and embedded systems but requires the host's general-purpose stack to be replaced wholesale and so is not viable on servers that continue to run POSIX, io\_uring, and SPDK. In each case the design closes the wall only inside the deployment it was built for, namely disaggregated storage on the DPU side and fabric-replaced hosts on the FPGA side, and the general-purpose server driving direct-attached NVMe at multi-million-IOPS rates remains unaddressed by both categories.

### 2.3 Per-IO cost characterization
\label{sec:background-cycles}

\begin{figure}[t]
\centering
\includegraphics[width=\columnwidth]{figures/cycle_breakdown.pdf}
\caption{Per-IO cost decomposition at QD=128 on a single host core and a single queue pair, comparing an unmodified SPDK baseline against IAU. Stages are stacked in I/O lifecycle order from bottom to top, from submission preparation through completion cleanup. SQE and PRP-list construction, tracker allocation and deallocation, and the surrounding callback work are largely absorbed by hardware that owns the queue execution; completion polling remains at the same per-IO cost in both configurations and is the residual host-side bottleneck after the offload, motivating the hardware completion-callback dispatcher deferred to future work.}
\label{fig:cycle_breakdown}
\end{figure}

While \S\ref{sec:background-mech} identified the four per-IO costs that any host driver must pay, the question of how those costs distribute across the actual stages of the SPDK fast path is one we answer empirically. We instrument a full-system gem5~\cite{binkert2011gem5} simulation running the unmodified \texttt{spdk\_nvme\_perf} workload against SimpleSSD~\cite{jung2017simplessd} configured as a multi-million-IOPS NVMe device model, drive 4~KB random reads from a single host core through a single queue pair at queue depths up to 128, and decompose the per-IO budget into the six lifecycle stages an NVMe I/O traverses from start to end, namely SQE and PRP-list construction, tracker allocation, the submission-queue doorbell write together with its ordering fence, completion polling on the CQ phase bit, the completion handler that fires the callback and releases the tracker, and the completion-queue doorbell write together with the final buffer cleanup. Figure~\ref{fig:cycle_breakdown} shows the resulting breakdown at QD=128 on a 2~GHz simulated host. Single-core IOPS saturate at roughly 0.82~M, rising only from 776~K at QD=16 to 819~K at QD=128, which confirms that the cost is per-IO structural rather than per-batch amortized and that the saturation point is essentially flat across queue depth. The submission-side stages, the completion-handler stage, and the doorbell MMIO together carry the bulk of the host budget and are elidable by hardware that owns the queue execution, while completion polling remains data-plane intrinsic because it observes a coherence-paying status word regardless of which agent produced it. The total cycles per I/O under this baseline sit in the same order of magnitude as published single-core, single-qpair SPDK measurements on production NVMe hardware~\cite{Yang2017SPDKAD}, and the full calibration argument together with its threats to validity is given in \S\ref{sec:eval-method} and \S\ref{sec:eval-threats}.

---

## §3. IAU: A Host-Integrated I/O Uncore

*Pending draft.*

---

## §4. Evaluation

*Pending draft.*

---

## §5. Conclusion

*Pending draft.*
