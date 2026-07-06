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
Next-generation NVMe SSDs now supply random IOPS in the tens to hundreds of millions through internal device parallelism, and AI retrieval workloads such as billion-scale nearest-neighbor search and retrieval-augmented generation are turning NAND into an actively read memory tier. The open question is no longer whether devices can supply these rates but which compute substrate can consume them. On the host CPU path that drives direct-attached NVMe, every I/O still pays an irreducible control-plane cost, namely building a submission entry and its PRP list, managing a per-command tracker, ringing a doorbell, and taking a coherence miss to poll for completion, that no deeper batching can amortize, so the CPU saturates well before the device. We propose IAU, an I/O Assistant Uncore placed beside the integrated memory controller and PCIe root complex that executes the NVMe-protocol portion of submission, tracking, and completion in hardware through three hot-path engines over a shared SRAM. On a full-system gem5 and SimpleSSD simulation driving an unmodified SPDK workload over a DiskANN BigANN trace replay, IAU raises single-core throughput by up to 1.44$\times$ and removes roughly 30\% of the cycles per I/O. Because this lift is per-core, a fixed IOPS aggregate is then served by proportionally fewer host cores, returning the freed cycles to the retrieval and agent compute that the regime exists to serve. ASAP7 7~nm synthesis across four queue-resource configurations places one tile at 0.1 to 0.9~mm$^2$ of SRAM, 30K to 93K standard cells, and 14 to 49~mW of logic, an uncore-scale footprint under 2.5\% of a server I/O tile.

\end{abstract}
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
\begin{IEEEkeywords}
SSD, CPU uncore, AI retrieval, million-IOPS storage, full-system simulation, SPDK.
\end{IEEEkeywords}

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
\section{Introduction}

\IEEEPARstart{M}{odern} AI retrieval pipelines impose new demands on the storage subsystem. Workloads such as billion-scale approximate nearest neighbor search over NAND-resident indices~\cite{diskann-github} and retrieval-augmented generation, in which retrieval already dominates serving cost~\cite{RAGX}, exhibit small random reads of 4 to 16 KB at multi-million IOPS rates. Device roadmaps advance on two axes: multi-device PCIe aggregation behind a single CPU, and per-device latency reductions under PCIe Gen5/Gen6 and storage-class memory. Micron reported a single-server demonstration sustaining 230M IOPS across 44 Gen6 SSDs~\cite{meredith2025micron230m}. The open question is therefore no longer whether NVMe devices can supply MIOPS but which processing unit can consume them. Most existing research has concentrated on the GPU side~\cite{NVDIABaM}, where streaming-multiprocessor parallelism naturally absorbs the IOPS. However, such designs benefit only GPU-resident consumers and require application rewrites. The CPU consumption path, which still handles control planes, retrieval orchestration, multi-agent collaboration, and the vast majority of general-purpose I/O, remains structurally under-explored at this regime.

At multi-million-IOPS rates, user-space polled frameworks such as SPDK~\cite{Yang2017SPDKAD} and kernel-side polled paths such as io\_uring~\cite{axboe2019iouring} with SQPOLL already eliminate the syscall, interrupt, and scheduler costs that dominated earlier kernel-driven NVMe. A residual per-I/O cost remains that no further driver work can lift: even on production Gen4 NVMe under SPDK, a large fraction of CPU cycles is spent on I/O submission and reaping rather than on application work~\cite{Haas2023WhatMN}. This cost is intrinsic to the NVMe queue-execution model and splits into two irreducible parts. The first one is the control-plane instruction count the CPU spends building each SQE, PRP list, and tracker. The second one is the memory subsystem and fabric side overhead of DRAM-resident queues, polled-completion cache-coherence traffic, and MMIO ordering. Because both apply to every I/O and cannot be reduced by software, each additional IOPS adds a fixed number of CPU cycles, and at multi-million-IOPS rates this fixed cost grows large enough to consume the majority of available CPU cycles. This is the host CPU wall. 

Existing hardware proposals close this wall only inside specific deployments: DPU offload targets disaggregated storage, FPGA NVMe controllers target fabric-replaced hosts, and on-die accelerators such as Intel DSA~\cite{intel_vmd_techdoc_2023} already sit in the uncore but offload generic memory-to-memory movement rather than the NVMe queue protocol, leaving untouched the per-I/O submission and completion work that constitutes the wall. The general-purpose server driving direct-attached NVMe at multi-million IOPS rates therefore remains unaddressed. To directly address the host CPU bottleneck, we propose IAU, an I/O Assistant Uncore that sits beside the integrated memory controller and PCIe root complex and executes the per-I/O NVMe fast path in hardware. IAU offloads the per-I/O submission, tracking, and completion work into hardware while preserving the DRAM-resident NVMe queues as a backup, so existing I/O paradigms continue to observe a compliant controller. On a full-system Gem5~\cite{binkert2011gem5} with SimpleSSD~\cite{jung2017simplessd} simulator,
IAU delivers up to 1.44$\times$ IOPS and ~30\% fewer cycles per I/O over an unmodified SPDK baseline on a DiskANN trace replay~\cite{diskann-github}. Because this saving is per-core, a fixed IOPS aggregate is served by a correspondingly smaller fraction of host cores, returning the freed cycles to the retrieval orchestration and multi-agent work that motivates the regime. We synthesize IAU at ASAP7 7nm~\cite{clark2016asap7} across four queue-resource configurations and report an uncore-scale footprint of 30K to 93K standard cells, 0.1 to 0.9~mm$^2$ of on-die SRAM, and 14 to 49~mW of post-synthesis logic power at 1~GHz.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
\section{Background}

\subsection{NVMe Queue Execution}
\label{subsec:NVMEQE}
NVMe exposes its control plane through submission and completion rings in host DRAM and per-queue doorbells in the device's BAR0 MMIO window~\cite{Haas2023WhatMN}. An I/O begins when the host writes a 64-byte submission-queue entry (SQE) holding the opcode, logical block address, and a PRP or SGL list into the submission ring and rings the SQ tail doorbell. The device DMA-fetches the SQE, DMAs the payload into the host buffer, and writes a 16-byte completion-queue entry (CQE) with a flipped phase bit, and the host polls that phase bit and rings the CQ head doorbell to release the slot. Four recurring costs are paid on this path by every I/O. Doorbell traffic is the MMIO store to BAR0 that drains through the CPU's posted-write path and cannot be coalesced with the cacheable ring stores. Completion polling forces the polling cacheline through a coherence transition for each CQE the device delivers, an LLC or memory-side miss per completion at saturation. Queue-state coherence traffic is the SQE cacheline the device pulls from the host cache and the CQE cacheline it writes back, a round-trip per I/O regardless of payload size. Ordering serialization is the fence between each SQE write and its doorbell store, and between each completion observation and the CQ head doorbell, which prevents the CPU from pipelining adjacent submissions or completions through its store buffer. These four costs together set the per-IO cost floor that any approach to the multi-million-IOPS regime must contend with.

\subsection{Per-IO Cost Characterization}

\begin{figure}[t]
\centering
\includegraphics[width=\columnwidth]{img/cycle_breakdown.png}
\caption{Vanilla SPDK per-IO cost decomposition for 4~KB random reads at QD=128 on a single host core and a single queue pair.}
\label{fig:cycle_breakdown}
\end{figure}

To see how the per-IO costs of \S\ref{subsec:NVMEQE} distribute across the SPDK fast path, we instrument a full-system gem5~\cite{binkert2011gem5} simulation running the unmodified \texttt{spdk\_nvme\_perf} workload against SimpleSSD~\cite{jung2017simplessd} configured as a multi-million IOPS NVMe device model, and drive 4~KB random reads from a single host core through a single queue pair at queue depths from 16 to 128. We decompose the per-IO budget into the six lifecycle stages an NVMe I/O traverses from start to end: SQE and PRP-list construction, tracker allocation, the submission-queue doorbell write together with its ordering fence, completion polling on the CQ phase bit, the completion handler that fires the callback and releases the tracker, and the completion-queue doorbell write together with the final buffer cleanup.

Figure~\ref{fig:cycle_breakdown} shows the resulting breakdown of SPDK per-IO cost under different queue depths on a 2~GHz simulated host. Single-core IOPS saturate near 0.8~M throughout the sweep, rising only from 776~K at QD=16 to 819~K at QD=128, a 5\% lift across an 8$\times$ queue-depth increase that establishes the cost as per-IO structural rather than per-batch amortized. The submission-side work and the completion handler together dominate the host budget, with completion polling and the two doorbell stages contributing the remainder. Each maps to an architectural origin: the dominant submission work and completion handler are the control-plane instruction count, the two doorbell stages the MMIO posted-write and ordering cost, and completion polling the completion-coherence miss. The queue-state coherence round-trip that the same SQE and CQE writes would impose on a cache-based host is not captured by the cacheless simulated host, so the measured budget understates the cost a cache-based host would pay. The total cycles per I/O sit in the same order of magnitude as published single-core, single-qpair SPDK measurements on production NVMe~\cite{Yang2017SPDKAD}. Because the per-IO budget does not shrink with queue depth, no software approach that relies on deeper batching can lower it, and any meaningful reduction must eliminate work from the per-IO critical path itself.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
\section{I/O Assistant Uncore}

\subsection{Placement}
\label{sec:iau-placement}
IAU sits on the CPU die as an on-die I/O assistant block co-located with the integrated memory controller and the PCIe root complex, shared across the cores within a chiplet. Placement of NVMe-touching logic inside the uncore has precedent, since Intel's Volume Management Device already resides there to perform PCIe enumeration and namespace registration~\cite{intel_vmd_techdoc_2023}. IAU focuses on per-IO queue execution.

For compatibility, the POSIX, io\_uring, and SPDK application interfaces are unchanged; only the NVMe driver, or in user-space deployments the SPDK NVMe library, is aware of IAU. Its reach is therefore confined to the NVMe-protocol portion of each per-IO stage, namely the SQE encoding, PRP/SGL construction, command-identifier lifecycle, CQE parse, ring-slot management, and doorbell ordering. What stays on the host is the application portion: a compact descriptor naming each I/O by address, length, and buffer pointer, an in-flight handle holding the user callback and context, one mailbox write to wake the uncore, the callback execution, and the buffer return. Offloading the protocol portion is what frees the host of the per-IO cost floor.

\subsection{Hot-path Engines}
\label{sec:iau-mechanisms}

\begin{figure}[t]
\centering
\includegraphics[width=\columnwidth]{img/iau_block.png}
\caption{The IAU sits beside the IMC and PCIe root complex on the CPU die. Three hot-path engines (SQ Engine, CQ Engine, Doorbell Coalescer) execute the NVMe fast path over a shared SRAM, with the Credit Manager and MMIO decoder as support blocks.}
\label{fig:iau_block}
\end{figure}

IAU executes the per-IO hot path with three engines over a shared SRAM, supported by a Credit Manager for backpressure and a thin MMIO decoder that routes BAR0 accesses. One I/O traverses the engines in the order Fig.~\ref{fig:iau_block} numbers them. At \bigding{172} the host posts a compact descriptor to the per-queue mailbox, at \bigding{173} the SQ Engine builds the 64-byte SQE while assigning the command identifier and expanding the PRP list on-die, and at \bigding{174} the Doorbell Coalescer folds the device-facing doorbell into a batched notification. At \bigding{175} the command issues to the SSD over PCIe and its completion returns over the same link, at \bigding{176} the CQ Engine batches the CQE and raises a completion-readiness hint, and at \bigding{177} the host polls a single status register that carries both the hint and the available submission credits. The host sees these engines through three BAR0-mapped primitives, namely a mailbox region at \texttt{0x3000} served by the SQ Engine, a doorbell region at \texttt{0x1000} served by the Doorbell Coalescer, and one \texttt{UNCORE\_STATUS} register at \texttt{0x2000} whose high half carries the CQ Engine's completion hint and whose low half carries the Credit Manager's available credits.

The SQ Engine removes the submission-side costs. The 24-byte descriptor, posted as three 8-byte MMIO writes, names the opcode and flags, the namespace, the starting logical block address, the block count, the queue pair, and the data-buffer address; the command identifier and the PRP list are deliberately absent, since the engine assigns the identifier from an internal per-queue counter and expands the PRP entries on-die for transfers up to 128~KB. The host thereby sheds the SQE encoding, the PRP-list construction, and the command-identifier and tracker bookkeeping that dominate the queue-state cost. The SQ tail doorbell and the ordering fence between SQE write and doorbell store are also saved because the mailbox write itself hands the descriptor to the engine atomically.

The CQ Engine removes the completion-side costs. It collects 16-byte CQEs into per-queue SRAM and publishes them to the host's DRAM completion ring in batches under a count-or-timer policy. The host therefore reaps a whole batch of completions per scan, rather than taking a coherence miss on the ring cacheline for each CQE the device delivers. The engine also exposes a completion-readiness hint, a small read-only field in the \texttt{UNCORE\_STATUS} register that holds the number of pending CQEs and the queueing delay of the oldest one. The host reads that one on-die register before it touches the ring. It skips the scan only when no CQEs are pending and that head-of-line delay is still under a fixed bound, which avoids the coherence-paying poll on an empty ring. In multi-queue deployments the same hint lets the host pass over rings that hold nothing. 

The Doorbell Coalescer aggregates the remaining device-facing doorbells, the completion-queue head and admin-queue writes, into batched notifications under the same count-or-timer policy. Its benefit is fewer PCIe transactions toward the SSD rather than fewer host cycles. The Credit Manager maintains a global credit pool that is debited at submission and replenished at completion, stalling the SQ Engine when credits run out so that backpressure reaches the host without any per-IO software counter, and the host reads the credit count and the completion hint in the same status-register access.

Together, the engines move the NVMe-protocol portion of every per-IO stage off the host, so the per-IO control-plane work that builds the host CPU wall collapses onto the small application residual that remains.

\subsection{SRAM Sizing and Silicon Plausibility}
\label{sec:iau-sram}
The three engines share one SRAM through a round-robin arbiter, and its capacity is set by how many NVMe commands a single tile keeps in flight, which is the queue-pair count $N_Q$ multiplied by the per-queue depth $Q_D$. Each outstanding command reserves a 64-byte slot for its on-die expanded SQE and a 16-byte slot for its CQE, while transfers that span more than one page additionally reserve a PRP-list region of 8 bytes for every 4~KB page beyond the first, reaching 31 entries at the 128~KB maximum transfer. A further 64 bytes per queue pair hold the live ring pointers, the phase bit, the command-identifier base, and the count-or-timer state. Total SRAM is therefore $N_Q\,[\,Q_D(64+16+8M)+64\,]$ bytes, where $M$ is the maximum PRP-entry count.

In the AI-retrieval regime every transfer fits a single 4~KB host page, so the SQ Engine emits one PRP pointer with the second set to zero and the PRP-list region is never allocated. Per-tile SRAM in this regime ranges from 81~KB to 644~KB across the four synthesized configurations, which cover 16 or 64 queue pairs at queue depth 64 or 128. General-purpose workloads that also issue transfers larger than one page restore the PRP-list region, and per-tile SRAM then grows from 329~KB at 16 queue pairs and queue depth 64 to 2.6~MB at 64 queue pairs and queue depth 128. These are realistic operating points, not a padded worst case: they span the queue counts and depths a multi-million-IOPS SPDK deployment provisions. Because per-tile SRAM grows linearly in $N_Q$, scaling to more queue pairs and the cores that drive them is a sizing choice rather than a redesign, sampled here up to 64 queue pairs per tile.

RTL synthesis at ASAP7 7nm across the four configurations yields 30K to 93K standard cells and 14 to 49~mW of post-synthesis logic power at 1~GHz, and the SRAM array, sized from the ASAP7 high-density bitcell at 0.027~$\mu$m$^2$ per bit under a 1.5$\times$ peripheral overhead, occupies 0.1 to 0.9~mm$^2$. This area is what makes uncore placement realistic, since even the largest configuration near 1~mm$^2$ is under 2.5\% of a server I/O tile of the Intel Sapphire Rapids class at roughly 40~mm$^2$ and well under one percent of a 223~mm$^2$ CPU die. The block therefore fits comfortably alongside the integrated memory controller and PCIe root complex. Its 14 to 49~mW of logic is well over an order of magnitude below the multi-watt draw of the server core whose I/O cycles it absorbs, so each core it frees returns to application work at a large net energy and area saving.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
\section{Evaluation}
\label{sec:eval}

\subsection{Methodology}
\label{sec:eval-method}

We evaluate IAU on a full-system gem5~\cite{binkert2011gem5} x86 simulation running the unmodified \texttt{spdk\_nvme\_perf} workload against a SimpleSSD~\cite{jung2017simplessd} device. To keep the host CPU the binding constraint at the multi-million-IOPS regime, SimpleSSD uses an aggregate-timing fast path with an aggregate ceiling near 8~M IOPS, about ten times the single-queue host rate, following the device-modeling precedent of NVMeVirt~\cite{nvmevirt_fast23} while keeping completion publication cycle-accurate. The host is a gem5 \texttt{AtomicSimpleCPU} at 2~GHz, driving a single queue pair at queue depths from 16 to 128 over a DiskANN BigANN trace replay of 1{,}225{,}846 4~KB reads~\cite{diskann-github}. We report IOPS, cycles per I/O at the host clock, per-stage nanoseconds per I/O, read-latency percentiles, and the completion-poll and per-mechanism correctness counters. The resulting baseline budget of about 2{,}490 cycles per I/O at 2~GHz sits inside the realistic range for single-queue SPDK on production NVMe~\cite{Yang2017SPDKAD}.

\subsection{Performance}
\label{sec:eval-results}
This section measures how much of that budget IAU removes on the DiskANN BigANN trace. At QD=128, IAU sustains 1.102~M IOPS against the 0.804~M baseline, a 1.37$\times$ lift that cuts the per-I/O budget from about 2{,}490 to 1{,}815 cycles.

\begin{figure}[t]
\centering
\includegraphics[width=\columnwidth]{img/iau_breakdown.png}
\caption{Per-IO budget for the DiskANN BigANN trace at QD=128, vanilla SPDK baseline versus IAU. Each bar stacks the six NVMe lifecycle stages in temporal order.}
\label{fig:iau_breakdown}
\end{figure}

Figure~\ref{fig:iau_breakdown} attributes the saving to the submission side. The SQ Engine's on-die SQE and PRP-list construction collapses the dominant stages, with address translation falling from 357 to 157~ns and tracker allocation from 236 to 221~ns on the BigANN trace, while the completion handler survives nearly intact because the host still runs the user callback. Because every offloaded stage costs a fixed amount per command with no per-byte term, this per-I/O saving is independent of transfer size. The completion-poll counters in Figure~\ref{fig:poll_efficiency} confirm that the completion-side coherence cost of \S\ref{subsec:NVMEQE} is removed. At QD=128 the baseline issues 219{,}100 \texttt{process\_completions} calls of which about 97\% return zero completions, whereas under IAU the count collapses to 8{,}609 with no empty polls and 128 completions per call, since the CQ Engine's readiness hint replaces the empty ring scan with a single on-die status-register read.

\begin{figure}[t]
\centering
\includegraphics[width=\columnwidth]{img/poll_efficiency.png}
\caption{Host completion polls per queue depth on the DiskANN BigANN read trace, vanilla SPDK baseline versus IAU. Each bar splits the polls into productive scans and idle scans of an empty completion queue.}
\label{fig:poll_efficiency}
\end{figure}

\begin{figure}[t]
\centering
\includegraphics[width=\columnwidth]{img/qd_sweep_opmix.png}
\caption{IOPS versus queue depth for the vanilla SPDK baseline and IAU on the DiskANN BigANN trace, for the read and 50/50 read-write op-mixes.}
\label{fig:qd_sweep}
\end{figure}

Figure~\ref{fig:qd_sweep} shows the read lift sustained across the whole sweep, running 1.44, 1.40, 1.38, 1.37$\times$ from QD=16 to QD=128. IAU's read throughput is essentially flat at roughly 1.102~M IOPS, a per-I/O budget near 1{,}815 cycles, because the CQ Engine's hint already reaps a full completion batch per poll at every depth, leaving the host compute-bound on the per-I/O residual from QD=16 onward. IAU thus delivers peak throughput at the shallow queue depths that also minimize latency, whereas the baseline must deepen its queue to approach its lower ceiling. At that QD=16 operating point IAU holds a p99 read latency of 19.7~$\mu$s, against 190~$\mu$s for the baseline at the QD=128 it needs to approach its own ceiling. The throughput gain therefore arrives with a near order-of-magnitude reduction in tail latency, rather than the latency penalty that offloading an I/O stage often incurs.

At the deepest queue depth the uncore returns roughly 742~million host cycles per second, a 27\% cut in cycles per I/O, for a logic budget of 14 to 49~mW, so each milliwatt of uncore reclaims on the order of tens of millions of host cycles per second.

\subsection{Operation-Mix Robustness}
\label{sec:eval-opmix}
To test whether the offload survives writes, we replay the same BigANN address stream as a 50/50 read-write mix, flipping only the operation byte so the offset and size sequence is identical to the read trace. Figure~\ref{fig:qd_sweep} adds the mixed series, and the lift persists at 1.12 to 1.18$\times$ across the sweep against 1.37 to 1.44$\times$ for the read trace. The smaller ratio is not a weaker offload, since the per-command submission and completion work still collapses through the same engines. It follows from where the two ends of the ratio sit, since the mixed baseline already sustains a higher 798~K to 835~K IOPS while its IAU ceiling is a lower 893~K to 981~K, compressing the ratio from both ends. Read completions arrive in dense bursts that let the host reap a full 128-entry batch per poll, whereas the interleaved writes in the mixed stream space completions out so the host reaps roughly 15 per poll and pays more polls per I/O. The same batching carries one honest cost, since at the deeper queue depths the mixed completion batch fills slowly and p99 latency rises above the baseline, a throughput-for-tail-latency trade a deployment can disable per queue.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
\section{Conclusion}
This paper identified the host CPU wall, the per-I/O control-plane cost that the NVMe queue-execution model imposes on every I/O and that no deeper batching can amortize, as the binding constraint that keeps a general-purpose server from consuming the multi-million-IOPS budgets that next-generation NAND now supplies. We proposed IAU, an I/O Assistant Uncore co-located with the integrated memory controller and PCIe root complex that executes the NVMe-protocol portion of submission, tracking, and completion in hardware while preserving the DRAM-resident queues, so existing io\_uring and SPDK stacks continue to observe a compliant controller. On a full-system gem5 and SimpleSSD model driving an SPDK DiskANN BigANN trace replay, IAU lifts single-core throughput by up to 1.44$\times$ and removes roughly 30\% of the cycles per I/O. Because the lift is per-core, it returns a corresponding fraction of host cores to application work at any fixed IOPS aggregate. In the future, this work will scale beyond the single-core, single-queue-pair setting to the multiple queue pairs and cores that share one tile, where shared-SRAM and Credit-Manager contention becomes the central question. A second direction follows from the operation-mix result, where the fixed count-or-timer completion policy leaves the mixed regime reaping partial batches at a tail-latency cost, so a completion policy that adapts its release threshold to the observed arrival rate is the natural next step toward extending the read gain to the mixed workload.

\bibliographystyle{IEEEtran}
\bibliography{reference} 

\vfill

\end{document}

