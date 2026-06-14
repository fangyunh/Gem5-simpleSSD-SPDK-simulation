\documentclass[lettersize,journal,9pt]{IEEEtran}
\usepackage{amsmath,amsfonts}
\usepackage{algorithmic}
\usepackage{caption}
\usepackage{algorithm}
\usepackage{array}
\usepackage{orcidlink}
\usepackage[caption=false,font=normalsize,labelfont=sf,textfont=sf]{subfig}
\usepackage{textcomp}
\usepackage{stfloats}
\usepackage{url}
\usepackage{verbatim}
\usepackage{pifont}
\usepackage{graphicx}
\usepackage{booktabs}
\usepackage{bm}
\usepackage{cite}
\hyphenation{op-tical net-works semi-conduc-tor IEEE-Xplore}
\def\BibTeX{{\rm B\kern-.05em{\sc i\kern-.025em b}\kern-.08em
    T\kern-.1667em\lower.7ex\hbox{E}\kern-.125emX}}
\usepackage{balance}
\newcommand{\bigding}[1]{\scalebox{1.2}{\ding{#1}}}


\begin{document}
\title{IAU: Assisting the CPU for Next-Generation Multi-Million IOPS SSD}

\author{Yunhua Fang\orcidlink{0009-0009-4718-8825}, Rui Xie\orcidlink{0000-0003-3177-5071}, 
        Asad Ul Haq\orcidlink{0009-0003-7975-0102}, Linsen Ma\orcidlink{0009-0000-8535-7911}, 
        Kaoutar El Maghraoui\orcidlink{0000-0002-1967-8749},\\ Naigang Wang\orcidlink{0000-0001-7664-0061}, 
        Meng Wang\orcidlink{0000-0003-0928-9691}, Liu Liu\orcidlink{0000-0003-0792-8146}, Tong Zhang\orcidlink{0009-0009-8005-0043}

%\thanks{Received}
\thanks{Yunhua Fang, Rui Xie, Asad Ul Haq, Linsen Ma, Meng Wang, Liu Liu, and Tong Zhang are with the Rensselaer Polytechnic Institute, Troy, NY 12180 USA.}
\thanks{Kaoutar El Maghraoui and Naigang Wang are with IBM T.J. Watson Research Center, Yorktown Heights, NY 10598 USA.}
}

% The paper headers
% \markboth{IEEE COMPUTER ARCHITECTURE LETTERS,~Vol.~12, No.~6, February~2024}%
% {Shell \MakeLowercase{\textit{et al.}}: A Sample Article Using IEEEtran.cls for IEEE Journals}

% 1) Wrap your license text in a \parbox or minipage, so line breaks work:
% \IEEEpubid{%
%   \makebox[\textwidth]{%    % span both columns
%     \begin{minipage}{\textwidth}
%       \centering            % or \raggedright if you prefer flush-left
%       \small
%       This work is licensed under a Creative Commons 
%       Attribution-NonCommercial-NoDerivatives 4.0 License.\\
%       For more information, see:
%       https://creativecommons.org/licenses/by-nc-nd/4.0/
%     \end{minipage}%
%   }%
% }
% \IEEEpubid{This work is licensed under a Creative Commons Attribution-NonCommercial-NoDerivatives 4.0 License. For more information, see \\ https://creativecommons.org/licenses/by-nc-nd/4.0/}
% Remember, if you use this you must call \IEEEpubidadjcol in the second
% column for its text to clear the IEEEpubid mark.

\maketitle
\thispagestyle{empty}
\pagestyle{empty}
\IEEEpubidadjcol
\begin{abstract}
Next-generation NVMe SSDs are pushing per-device random IOPS into the tens to hundreds of millions through internal device parallelism. At the same time, Large Language Model workloads such as retrieval-augmented inference and agentic automation are scaling memory-resident state past the volatile memory capacity. These two trends converge to make NAND a viable active memory tier. However, the host CPU does not scale with them. Every I/O still requires the CPU to construct a submission entry, ring a doorbell, poll for completion, and update tracker metadata, so at multi-million-IOPS rates the CPU saturates well before the device does. We propose IAU, an I/O assistant uncore in the CPU's I/O chiplet that executes NVMe queues from uncore-private SRAM, aggregates doorbells, and answers completion polls from uncore SRAM. IAU is exposed through two software contracts: a transparent mode with no SPDK changes, and a poll-lite mode with a small SPDK patch. On cycle-level system simulator gem5 + SimpleSSD at $\ge$ 10 M IOPS and QD=128, IAU reduces per-I/O cycles by `[TBD]` and DRAM bytes per I/O by `[TBD]` while holding p99 latency within `[TBD]` of baseline; ASAP7 7 nm synthesis places one tile at `[TBD]` mm² SRAM and `[TBD]` standard cells of logic, within published L3-slice envelopes.

\end{abstract}
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
\begin{IEEEkeywords}
SSD, CPU uncore, AI retrieval, million-IOPS storage, full-system simulation, SPDK.
\end{IEEEkeywords}


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
\section{Introduction}

\IEEEPARstart{M}{odern} AI retrieval pipelines impose new demands on the storage subsystem. Workloads such as billion-scale approximate nearest neighbor search over NAND-resident indices~\cite{diskann-github} and retrieval-augmented generation, in which retrieval already dominates serving cost~\cite{RAGX}, exhibit small random reads of 4 to 16 KB at multi-million IOPS rates. Device-side roadmaps have moved aggressively along two complementary axes: multi-device PCIe aggregation that places many high-IOPS NVMe drives behind a single CPU and continuing per-device latency reductions under PCIe Gen5/Gen6 and emerging storage-class memory. Micron reported a single-server demonstration sustaining 230M IOPS across 44 Gen6 SSDs~\cite{meredith2025micron230m}, and NVIDIA's StorageNext initiative further frames this push as a precondition for keeping GenAI workloads fed~\cite{newburn2025storagenext}. The open question is therefore no longer whether devices can supply MIOPS but which compute substrate can consume them. Most existing research has concentrated on the GPU side~\cite{NVDIABaM}, where streaming-multiprocessor parallelism naturally absorbs the IOPS. However, such designs benefit only GPU-resident consumers and require application rewrites. The CPU consumption path, which still handles control planes, retrieval orchestration, multi-agent collaboration, and the vast majority of general-purpose I/O, remains structurally under-explored at this regime.

At multi-million-IOPS rates, user-space polled frameworks such as SPDK~\cite{Yang2017SPDKAD} and kernel-side polled paths such as io\_uring~\cite{axboe2019iouring} with SQPOLL already eliminate the syscall, interrupt, and scheduler costs that dominated earlier kernel-driven NVMe. However, a residual per-I/O cost remains that no further driver work can lift. On real Gen4 NVMe arrays running SPDK, massive available cycles from CPU cores must be dedicated to I/O submission and reaping to sustain tens-of-millions IOPS for actual application work~\cite{Haas2023WhatMN}. The cost is intrinsic to the NVMe queue execution model, in which every I/O requires PRP-list construction from a DRAM-resident entry, a tracker for the per-I/O command-identifier lifecycle, and a coherence-paying poll on a DMA-invalidated completion cacheline. Two compounding components therefore set the per-I/O budget. The first is a control-plane instruction count that no driver can eliminate. The second is the memory hierarchy and signaling-fabric overhead from DRAM-resident queue metadata, DMA-invalidated completion cachelines, and MMIO ordering serialization. Because both components apply to every I/O and cannot be reduced by software, every additional IOPS demanded adds a fixed number of CPU cycles to the I/O path. At multi-million-IOPS rates this fixed cost grows large enough to consume a majority of the available CPU cycles. This is the host CPU wall. 

\begin{comment}

The wall has motivated several lines of hardware work that aim to move I/O execution off the host CPU. DPUs such as NVIDIA BlueField take some of the storage and network stack off the host by running NVMe-over-Fabrics initiators and infrastructure services on a separate Arm SoC~\cite{nvidia2026bluefield4}. It helps when storage is disaggregated, but it leaves direct-attached NVMe on the host CPU unchanged. FPGA NVMe host controllers such as AMD NVMeHA go further by running the entire NVMe initiator in fabric~\cite{amd_nvmeha_pb058}. It eliminates per-I/O CPU work in CPU-constrained appliances and embedded systems, but it requires the host's general-purpose stack to be replaced wholesale, which is not viable on servers that continue to run io\_uring, and SPDK. In each case, the design closes the wall only inside the deployment it was built for, but the general-purpose server driving direct-attached NVMe at multi-million IOPS rates remains unaddressed by both categories.
\end{comment}

Existing hardware proposals, such as DPU offload for disaggregated storage and FPGA NVMe controllers for fabric-replaced hosts, close this wall inside specific deployments, but the general-purpose server driving direct-attached NVMe at multi-million IOPS rates remains unaddressed. To directly address the host CPU bottleneck, we propose IAU, an I/O Assistant Uncore that sits beside the integrated memory controller and PCIe root complex and executes the per-I/O NVMe fast path in hardware. IAU offloads the per-I/O submission, tracking, and completion work into hardware while preserving the DRAM-resident NVMe queues, so existing I/O paradigms continue to observe a compliant controller. On a full-system Gem5~\cite{binkert2011gem5} with SimpleSSD~\cite{jung2017simplessd} simulator,
IAU delivers up to 1.44$\times$ IOPS and ~30\% fewer cycles per I/O over an unmodified SPDK baseline on a DiskANN trace replay~\cite{diskann-github}. We synthesize IAU at ASAP7 7nm~\cite{clark2016asap7} across four queue-resource configurations and report an uncore-scale footprint of 30K to 93K standard cells, 0.1 to 0.9 $mm^2$ of on-die SRAM, and 14 to 49 mW of post-synthesis logic power at 1 GHz. Residual host-side polling remains the bottleneck at this lifted ceiling, motivating a hardware completion-callback dispatcher that can be addressed in future work.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
\section{Background}

\subsection{NVMe Queue Execution}
\label{subsec:NVMEQE}
NVMe exposes its control plane through ring buffers placed in host DRAM and a small set of memory-mapped doorbells on the device. Each controller maintains one administrative queue pair together with a configurable set of I/O submission queues and completion queues, with every ring carrying its own head and tail pointers in DRAM. One submission-queue doorbell and one completion-queue doorbell per queue are mapped into BAR0 of the device's MMIO window~\cite{Haas2023WhatMN}. An I/O begins when the host formats a 64-byte submission-queue entry (SQE) that carries the opcode, the logical block address, and a PRP or SGL list locating the data buffer, writes the SQE into the submission ring, and issues an MMIO store to the submission-queue tail doorbell that hands the entry to the device. The device then fetches the SQE via DMA, executes the command against the namespace, transfers the data payload into the host buffer over DMA, writes a 16-byte completion-queue entry (CQE) into the completion ring, flips a phase bit on that CQE, and optionally fires an MSI-X interrupt. The host either polls the completion ring for the phase change or wakes on the interrupt, services the completion, and issues a second MMIO store to the completion-queue head doorbell to release the slot. Four recurring costs are paid on this path by every I/O. The first cost is doorbell traffic, where each I/O issues an MMIO store to BAR0 that drains through the CPU's posted-write path and cannot be coalesced with prior cacheable stores to the ring. The second cost is completion polling, where each new CQE the device DMAs into the CQ ring forces the polling cacheline through a coherence transition on the host core, paying an LLC- or memory-side miss per completion at saturation. The third cost is queue-state coherence traffic, where each I/O writes one SQE cacheline that the device must pull from the host's cache hierarchy and one CQE cacheline that the device writes back into it, paying a cacheline round-trip per I/O regardless of payload size. The fourth cost is ordering serialization, where the architectural fence between each SQE write and its doorbell store, and between each completion observation and the CQ head doorbell update, prevents the CPU from pipelining adjacent submissions or completions through its store buffer. These four costs together set the per-IO cost floor that any approach to the multi-million IOPS regime must contend with.

\begin{comment}
    

\subsection{Multi-million IOPS Scale}
\label{subsec:MMIOPS}
This per-IO cost floor is what makes SPDK the right I/O paradigm to study because it is already the best-case software path at the regime~\cite{Yang2017SPDKAD}. SPDK pins each I/O thread to a hugepage-resident memory pool, drives the NVMe queues from user space, and replaces the kernel block layer with a direct PRP-driven datapath that emits no syscalls and no interrupts. Any residual cost observed under SPDK therefore reflects the per-IO cost of the queue execution model. The kernel-side ultra-low-latency I/O path explored by i10 confirms this view from the opposite direction, since even aggressive kernel optimization closes the latency gap with SPDK while still paying the same per-IO architectural costs in a different layer~\cite{AIOS-19}. We use SPDK as the primary baseline throughout the paper because it exhibits the per-IO saturation behavior at the multi-million IOPS regime. The natural next question is whether existing hardware approaches close that gap.

Several lines of hardware work aim to move I/O execution off the host CPU. For example, DPUs such as NVIDIA BlueField take some of the storage and network stack off the host by running NVMe-over-Fabrics initiators, infrastructure services, and software-defined networking on a separate Arm SoC located on the network-facing side of the server~\cite{nvidia2026bluefield4}. This is the natural fit when storage is disaggregated and accessed over a fabric, but it leaves direct-attached NVMe on the host CPU unchanged. FPGA NVMe host controllers such as AMD NVMeHA go further by running the entire NVMe initiator in fabric and exposing a fixed-function block interface to the application~\cite{amd_nvmeha_pb058}. This eliminates per-I/O CPU work in CPU-constrained appliances and embedded systems, but it requires the host's general-purpose stack to be replaced wholesale and so is not viable on servers that continue to run io\_uring and SPDK. In each case, the design closes the wall only inside the deployment it was built for, namely disaggregated storage on the DPU side and fabric-replaced hosts on the FPGA side, and the general-purpose server driving direct-attached NVMe at multi-million-IOPS rates remains unaddressed by both categories.
\end{comment}
yh
\subsection{Per-IO Cost Characterization}
\label{subsec:perio}

\begin{figure}[t]
\centering
\includegraphics[width=\columnwidth]{img/cycle_breakdown.png}
\caption{SPDK per-IO cost decomposition for 4~KB random reads at QD=128 on a single host core and a single queue pair.}
\label{fig:cycle_breakdown}
\end{figure}

While \S\ref{subsec:MMIOPS} identified the four per-IO costs that any host driver must pay, the question of how those costs distribute across the actual stages of the SPDK fast path needs to be figured out. We instrument a full-system gem5~\cite{binkert2011gem5} simulation running the unmodified \texttt{spdk\_nvme\_perf} workload against SimpleSSD~\cite{jung2017simplessd} configured as a multi-million IOPS NVMe device model, and drive 4~KB random reads from a single host core through a single queue pair at queue depths from 16 to 128. We decompose the per-IO budget into the six lifecycle stages an NVMe I/O traverses from start to end: SQE and PRP-list construction, tracker allocation, the submission-queue doorbell write together with its ordering fence, completion polling on the CQ phase bit, the completion handler that fires the callback and releases the tracker, and the completion-queue doorbell write together with the final buffer cleanup.

Figure~\ref{fig:cycle_breakdown} shows the resulting breakdown of SPDK per-IO cost under different queue depths on a 2~GHz simulated host. Single-core IOPS saturate near 0.8~M throughout the sweep, rising only from 776~K at QD=16 to 819~K at QD=128. A 5\% lift across an 8$\times$ queue-depth increase that establishes the cost as per-IO structural rather than per-batch amortized. The submission-side work and the completion handler together dominate the host budget, with completion polling and the two doorbell stages contributing the remainder. Mapping these stages to their architectural origins, the dominant submission-side work and completion handler embody the control-plane instruction count that the introduction identified as the first compounding component, namely the bookkeeping work of building the SQE and its PRP list, managing the tracker lifecycle, and parsing the CQE, while the queue-state coherence traffic that the same SQE and CQE round-trips would additionally impose on a cache-based host is not captured by the simulated host and is revisited in the evaluation as a reason the measured budget is conservative. The doorbell stages embody the MMIO posted-write cost paired with the ordering fence that the protocol forces between SQE write and doorbell store, and completion polling embodies the cache-line coherence transition that the device's CQE DMA imposes on the host. The total cycles per I/O under this baseline sit in the same order of magnitude as published single-core, single-qpair SPDK measurements on production NVMe hardware~\cite{Yang2017SPDKAD}. Because the total per-IO budget does not shrink with queue depth, no purely software-side approach that relies on deeper batching can lower it, and any meaningful reduction in cycles per I/O must therefore eliminate work from the per-IO critical path itself.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
\section{I/O Assistant Uncore}

\subsection{Placement}
\label{sec:iau-placement}
IAU sits on the CPU die as an on-die I/O assistant block co-located with the integrated memory controller and the PCIe root complex, shared across the cores within a chiplet. Placement of NVMe-touching logic inside the uncore has precedent, since Intel's Volume Management Device already resides there to perform PCIe enumeration and namespace registration~\cite{intel_vmd_techdoc_2023}. IAU focuses on per-IO queue execution.

For compatibility, upper stacks such as POSIX, io\_uring, and SPDK application interfaces are unchanged by this separation. Only the NVMe driver, or in user-space deployments the SPDK NVMe library, needs to be aware of IAU. Therefore, its reach is confined to the NVMe-protocol portion of each per-IO stage, while the application portion remains on the CPU. The NVMe-protocol portion comprises the 64-byte SQE encoding, the PRP and SGL list construction, the command-identifier lifecycle, the CQE parse, the management of submission and completion ring slots, and the doorbell-MMIO ordering. The application portion comprises the compact descriptor that names each I/O by logical block address, length, and buffer pointer, the in-flight handle that carries the user callback pointer and user context, the mailbox MMIO notification that wakes the uncore, the callback execution itself, and the return of the data buffer to the application-side memory pool. The NVMe-protocol portion offload is what frees the host of the per-IO cost floor.ß




\subsection{Hot-path engines}
\label{sec:iau-mechanisms}

\begin{figure}[t]
\centering
\includegraphics[width=\columnwidth]{img/iau_block.png}
\caption{The IAU sits beside the IMC and PCIe root complex on the CPU die. Three hot-path engines (SQ Engine, CQ Engine, Doorbell Coalescer) execute the NVMe fast path over a shared SRAM, with the Credit Manager and MMIO decoder as support blocks.}
\label{fig:iau_block}
\end{figure}

IAU executes the per-IO hot path with three engines over a shared SRAM, supported by a Credit Manager for backpressure and a thin MMIO decoder that routes BAR0 accesses. One I/O traverses the engines in the order Fig.~\ref{fig:iau_block} numbers them. At \bigding{172} the host posts a compact descriptor to the per-queue mailbox, at \bigding{173} the SQ Engine builds the 64-byte SQE while assigning the command identifier and expanding the PRP list on-die, and at \bigding{174} the Doorbell Coalescer folds the device-facing doorbell into a batched notification. At \bigding{175} the command issues to the SSD over PCIe and its completion returns over the same link, at \bigding{176} the CQ Engine batches the CQE and raises a completion-readiness hint, and at \bigding{177} the host polls a single status register that carries both the hint and the available submission credits. The host sees these engines through three BAR0-mapped primitives, namely a mailbox region at \texttt{0x3000} served by the SQ Engine, a doorbell region at \texttt{0x1000} served by the Doorbell Coalescer, and one \texttt{UNCORE\_STATUS} register at \texttt{0x2000} whose high half carries the CQ Engine's completion hint and whose low half carries the Credit Manager's available credits.

The SQ Engine removes the submission-side costs. The 24-byte descriptor, posted as three 8-byte MMIO writes, names the opcode and flags, the namespace, the starting logical block address, the block count, the queue pair, and the data-buffer address; the command identifier and the PRP list are deliberately absent, since the engine assigns the identifier from an internal per-queue counter and expands the PRP entries on-die for transfers up to 128~KB. The host thereby sheds the SQE encoding, the PRP-list construction, and the command-identifier and tracker bookkeeping that dominate the queue-state cost. The SQ tail doorbell and the ordering fence between SQE write and doorbell store are also saved because the mailbox write itself hands the descriptor to the engine atomically. What stays on the host is the application portion, namely the descriptor build, one mailbox write per I/O, and a small in-flight handle holding the user callback pointer and context.

The CQ Engine removes the completion-side costs. It collects 16-byte CQEs into per-queue SRAM and publishes them to the host's DRAM completion ring in batches under a count-or-timer policy. The host therefore reaps a whole batch of completions per scan, rather than taking a coherence miss on the ring cacheline for each CQE the device delivers. The engine also exposes a completion-readiness hint, a small read-only field in the \texttt{UNCORE\_STATUS} register that holds the number of pending CQEs and the queueing delay of the oldest one. The host reads that one on-die register before it touches the ring. It skips the scan only when no CQEs are pending and that head-of-line delay is still under a fixed bound, which avoids the coherence-paying poll on an empty ring. In multi-queue deployments the same hint lets the host pass over rings that hold nothing. 

The Doorbell Coalescer aggregates the remaining device-facing doorbells, the completion-queue head and admin-queue writes, into batched notifications under the same count-or-timer policy. Its benefit is fewer PCIe transactions toward the SSD rather than fewer host cycles. The Credit Manager maintains a global credit pool that is debited at submission and replenished at completion, stalling the SQ Engine when credits run out so that backpressure reaches the host without any per-IO software counter, and the host reads the credit count and the completion hint in the same status-register access.


\subsection{SRAM sizing and silicon plausibility}
\label{sec:iau-sram}
The engines share one SRAM through a round-robin arbiter that holds the in-flight SQEs, the CQE batches, and the PRP lists. Reshaping the per-IO submission and completion paths this far raises the question of whether the controller is still a compliant NVMe device.

IAU preserves the NVMe contract that the OS, drivers, and tooling rely on. On the completion side, the CQ Engine publishes completion-queue entries to the DRAM ring at bounded intervals, and the host issues the CQ head doorbell only after consuming them, so the DRAM-visible completion protocol is unchanged. On the submission side, the mailbox is a performance side channel that bypasses the SQE write rather than replacing the standard SQE path, which remains available for the admin queue and for any command that does not use the mailbox. IAU is also architecturally distinct from the NVMe Doorbell Buffer Config feature at admin opcode 0x7C, which only relocates doorbell values into a DRAM shadow buffer to cut MMIO traps. That feature builds no SQEs, expands no PRP lists, and assigns no command identifiers, which is exactly the per-IO protocol work the SQ and CQ Engines absorb. Because the DRAM rings stay authoritative whether or not the mailbox path is in use, the SPDK NVMe library can be configured at queue-setup time to bypass the mailbox and issue every submission through the standard SQE path. IAU's fail-safe is therefore a static deployability choice rather than a runtime detection or recovery path. A design this aggressive is only useful if it is also buildable, which the next subsection settles by sizing the shared SRAM and reporting the ASAP7 synthesis.

The shared SRAM carries roughly 80 bytes of control state per queue pair, covering live ring pointers, CQE batch counters, and count-or-timer state, plus a per-tile region for the credit pool and the buffer-pool descriptor table; the PRP-list region is the capacity-dominant term for workloads with multi-page transfers. For the AI retrieval target regime, where all transfers fit a single 4~KB host page and PRP-list storage is unnecessary, per-tile SRAM across the four synthesized configurations, covering 16 or 64 queue pairs at queue depth 64 or 128, ranges from 81~KB to 644~KB. For general-purpose workloads that include multi-page transfers, the PRP-list region accounts for roughly 75\% of capacity and per-tile SRAM grows from 329~KB at 16 queue pairs and queue depth 64 to 2.6~MB at 64 queue pairs and queue depth 128. The synthesized configurations cover up to 64 queue pairs per tile; deployments requiring thousands of simultaneously active queue pairs would adopt hierarchical multiplexing or tile replication rather than extending a single tile.

RTL synthesis at ASAP7 7nm across the four configurations yields 30K to 93K standard cells, 0.1 to 0.9~mm$^2$ of on-die SRAM, and 14 to 49~mW of post-synthesis logic power at 1~GHz; place-and-route, routed timing closure, and post-CTS power remain orthogonal future work, and the post-synthesis Fmax is excluded from this paper as a pre-placement lower bound. The same engine behaviors that produce this footprint are exercised at system-side throughput in the full-system gem5, SimpleSSD, and SPDK evaluation that follows.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
\section{Evaluation}
\label{sec:eval}

\subsection{Methodology}
\label{sec:eval-method}

We evaluate IAU on a full-system gem5~\cite{binkert2011gem5} x86 simulation running the unmodified \texttt{spdk\_nvme\_perf} workload against a SimpleSSD~\cite{jung2017simplessd} device. To keep the host CPU the binding constraint at the multi-million-IOPS regime, SimpleSSD uses an aggregate-timing fast path with an aggregate ceiling near 8~M IOPS, about ten times the single-queue host rate, following the device-modeling precedent of NVMeVirt~\cite{nvmevirt_fast23} and FEMU~\cite{femu_fast18} while keeping completion publication cycle-accurate. The host is a gem5 \texttt{AtomicSimpleCPU} at 2~GHz with no caches and \texttt{mem\_mode=atomic}, driving a single queue pair at queue depths from 16 to 128 over two workloads, synthetic 4~KB random reads and a DiskANN BigANN trace replay~\cite{diskann-github}. We report IOPS, cycles per I/O at the host clock, per-stage nanoseconds per I/O, and the completion-poll and per-mechanism correctness counters. The simplified host is what makes the sweep tractable, and because the vanilla SPDK baseline and IAU run under the identical model the host-side savings ratio cancels the host-model bias; the baseline budget of about 2{,}440 cycles per I/O at 2~GHz scales to about 3{,}660 at 3~GHz, inside the realistic 1{,}500 to 4{,}000 range for single-queue SPDK on production NVMe~\cite{Yang2017SPDKAD}.

\subsection{IAU results}
\label{sec:eval-results}

Section~\ref{subsec:perio} established that the vanilla SPDK baseline saturates near 0.82~M IOPS with a per-I/O budget flat across queue depth, and this section measures how much of that budget IAU removes. At QD=128 on 4~KB random reads, IAU sustains 1.106~M IOPS against the 0.819~M baseline, a 1.35$\times$ lift that cuts the per-I/O budget from about 2{,}440 to 1{,}810 cycles, and the DiskANN BigANN trace reproduces this at 1.102~M against its own 0.804~M baseline, a 1.37$\times$ lift on a non-synthetic access pattern.

\begin{figure}[t]
\centering
\includegraphics[width=\columnwidth]{img/iau_breakdown.png}
\caption{Per-IO budget for the DiskANN BigANN trace at QD=128, vanilla SPDK baseline versus IAU. Each bar stacks the six NVMe lifecycle stages in temporal order. The submission-side stages account for essentially all of the recovered budget, while the completion handler survives as the residual that the deferred completion-callback dispatcher would target.}
\label{fig:iau_breakdown}
\end{figure}

Figure~\ref{fig:iau_breakdown} attributes the saving to the submission side. The SQ Engine's on-die SQE and PRP-list construction collapses the dominant stages, with address translation falling from 357 to 157~ns and tracker allocation from 236 to 221~ns on the BigANN trace, while the completion handler survives nearly intact because the host still runs the user callback and the larger completion saving awaits the deferred dispatcher of \S\ref{sec:iau-mechanisms}. The completion-poll counters confirm that the completion-side coherence cost of \S\ref{subsec:NVMEQE} is removed. At QD=128 the baseline issues 223{,}698 \texttt{process\_completions} calls of which about 97\% return zero completions, whereas under IAU the count collapses to 8{,}646 with no empty polls and 128 completions per call, since the CQ Engine's readiness hint replaces the empty ring scan with a single on-die status-register read.

\begin{figure}[t]
\centering
\includegraphics[width=\columnwidth]{img/qd_sweep.png}
\caption{IOPS versus queue depth for the vanilla SPDK baseline and IAU on 4~KB random reads. IAU's IOPS stays flat across the sweep, marking a new CPU-bound ceiling well above the baseline and well below the device aggregate.}
\label{fig:qd_sweep}
\end{figure}

Two further results fix the design boundary. A transparent-IAU ablation that activates the uncore behind an unmodified SPDK reaches only 0.808~M IOPS at QD=128, about 0.99$\times$ the baseline, because batching completions alone cannot move a submission-dominated budget; the lift therefore requires the small host-side mailbox enablement of \S\ref{sec:iau-placement} rather than a fully transparent design. As Figure~\ref{fig:qd_sweep} shows, IAU's throughput is essentially flat at roughly 1.106~M IOPS for every queue depth, equivalently a per-I/O budget near 1{,}810 cycles, marking a new CPU-bound ceiling well below the 8~M device aggregate that the deferred completion-callback dispatcher is left to close. IAU is flat because the CQ Engine's hint already reaps a full completion batch per poll at every queue depth, leaving the host compute-bound on the per-I/O residual from QD=16 onward, so IAU delivers peak throughput at the shallow queue depths that also minimize latency, whereas the baseline must deepen its queue to approach its lower ceiling.

\subsection{Robustness and threats to validity}
\label{sec:eval-threats}

The lift is sustained across the whole sweep, running 1.43, 1.38, 1.36, 1.35$\times$ on 4~KB random reads and 1.44, 1.40, 1.38, 1.37$\times$ on the BigANN trace from QD=16 to QD=128, always above 1.0 and largest at shallow depth where each I/O's per-stage saving matters most; the peak 1.44$\times$ at BigANN QD=16 is the up-to figure quoted in the introduction. Across the sweep the uncore counters balance, with \texttt{mailbox\_submissions}, \texttt{free\_cid\_pops}, and \texttt{cqes\_published} equal and no starvations or oversize fallbacks, so no I/O is dropped or misrouted.

Four modeling choices bound these results. The \texttt{AtomicSimpleCPU} host captures per-I/O instruction count and DRAM latency but not coherence or out-of-order execution, so the absolute cycle counts are not a specific-CPU match; the load-bearing claim is the same-simulator baseline-to-IAU delta and its BigANN reproduction, and the measured lift is plausibly a lower bound because the coherence and DMA-invalidation costs IAU additionally removes are unmodeled here. The device's 8~M aggregate ceiling sits about ten times above the observed rates, so it neither gates nor contaminates the baseline. The evaluated mailbox model implements the single-page fast path that the 4~KB and 16~KB target workload exercises, while the synthesized RTL of \S\ref{sec:iau-sram} covers full PRP expansion to 128~KB, so the architecture is not narrower than what was built. Finally, the DRAM compatibility mirror is a design feature not implemented in the evaluated model, so the reported savings come entirely from the mailbox engine, the hardware CID ring, and the typed hint rather than from any modeled DRAM-traffic change, and all results are single-core and single-queue-pair, leaving multi-queue-pair scaling an open gap.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
\section{Conclusion}


\bibliographystyle{IEEEtran}
\bibliography{reference} 

\vfill

\end{document}


