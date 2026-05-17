# IAU Literature Review — Context Primer

> **Audience.** A fresh AI agent (or new collaborator) picking up the IAU paper without prior conversation history.
> **Purpose.** Ground every prior-art claim the paper makes in a single document so the agent can write or defend §1 / §2 / §5 prose without re-running a literature search. Each entry states *what the work is*, *what it claims*, *how it differs from IAU*, and *where IAU's draft deploys it*.
> **Source of truth for citation keys.** `docs/paper.bib` (committed) for must/should/context refs [1]–[25]; `docs/PAPER_CHAPTER_PLAN.md` §1.3 ("Lit-review additions") for [26]–[33] which are pending-bibtex but already named in the consolidated reference list.
> **Companion docs.** `PAPER_CHAPTER_PLAN.md` (locked chapter plan and INSIGHT collection), `paper.tex` (current draft), `Research Plan Architecting a Host-Integrated IO Uncore.pdf` (the motivation source whose argument the paper re-traces).
> **Last refresh.** 2026-05-14 — synchronized with the third-pass §1 redesign.

---

## 0. How IAU is positioned (the one-paragraph briefing)

The IAU paper argues that at multi-million-IOPS scale, the *host CPU* is the structural bottleneck for AI retrieval workloads (billion-scale ANN, RAG over corpora that don't fit in HBM/DRAM, multi-agent reasoning), not the device. Even kernel-bypass user-space stacks (SPDK, io_uring) still burn ~700–1200 cycles/IO on MMIO doorbells, completion-queue (CQ) polling of device-written cachelines, ordering fences, and DRAM-resident queue metadata. Existing offloads — GPU-initiated NVMe (BaM lineage), external DPUs/IPUs (BlueField-3, Mount Evans), and FPGA NVMe host controllers (NVMeHA, NVMeCHA, DirectNVM) — *bypass* the host rather than fix it: they relocate per-IO work to a different die across a PCIe link and retain the DRAM-mirrored queue model that produced the wall. The novel placement IAU occupies is **on-die, in-uncore, initiator-side**: an NVMe queue-execution block co-located with the integrated memory controller (IMC) and PCIe root complex on the same silicon as the host cores. The historical existence-proof for placement-based fixes is the IMC itself (K8/Opteron, 2003), and the cost-benefit framing is anchored by the five-minute-rule retrospective which places microsecond-class storage in the on-die-integration regime.

Reviewers' three most likely attacks and where IAU pre-empts them:
1. *"You ignored DPUs / IPUs"* → §1 ¶3 names BlueField-3 (and Mount Evans if needed) and critiques them structurally (off-die PCIe crossing retained).
2. *"You ignored FPGA NVMe controllers"* → §1 ¶3 names NVMeHA, NVMeCHA, DirectNVM in the same external-offload bucket; §5 ¶4 (NVMeHA defense paragraph) gives the load-bearing differentiation paragraph against the Xilinx/AMD product.
3. *"Isn't this just CXL-attached SSD / RAGX / Shadow Doorbell?"* → §5 ¶3 (CXL is wrong latency tier ~50–150 ns), §5 ¶3 (RAGX is in-storage, complementary at a different boundary), §5 ¶5 (Shadow Doorbell is a per-MMIO write reduction, not a full execution offload).

---

## 1. AI retrieval workload motivation (§1 ¶1)

### `diskann` — DiskANN: Fast Accurate Billion-point Nearest Neighbor Search on a Single Node (NeurIPS 2019)

Subramanya, Devvrit, Kadekodi, Krishnaswamy, Simhadri.

**What it is.** The canonical billion-scale ANN system that holds the index on SSD and treats NAND as the primary substrate for vector retrieval. Demonstrates that a single node with NVMe SSDs can serve billion-point nearest-neighbor search with sub-10 ms recall@1, breaking the "ANN must fit in DRAM" assumption.

**Why IAU cites it.** It is the workload-class anchor for §1 ¶1 (small random reads against a NAND-resident index) and the source of the workload-equivalent microbenchmark pattern §4.1 uses (pinned huge-page buffer pools, reused DMA targets, ANN-style access traces).

**How IAU differs.** DiskANN is an algorithm/system co-design at the application layer; IAU is a hardware placement claim at the queue-execution layer. They compose: DiskANN drives the *demand* for MIOPS that IAU's hardware satisfies.

**Deployment in paper.** §1 ¶1 (workload class), §4.1 (microbenchmark trace pattern).

---

### `spann_neurips21` — SPANN: Highly-Efficient Billion-scale Approximate Nearest Neighbor Search (NeurIPS 2021)

Chen et al.

**What it is.** A complementary billion-scale ANN system that uses a different posting-list / centroid structure than DiskANN. Same workload class — vector retrieval over NAND — different algorithm.

**Why IAU cites it.** Reinforces the workload-class generality argument: DiskANN is not a one-off. Cited alongside DiskANN in §1 ¶1 so reviewers can't dismiss the workload claim as DiskANN-specific.

**Deployment in paper.** §1 ¶1.

---

### `ragx_isca25` — In-Storage Acceleration of Retrieval Augmented Generation as a Service (ISCA 2025)

Mahapatra, Santhanam, Priebe, Xu, Esmaeilzadeh.

**What it is.** ISCA 2025 paper that measures RAG serving on real hardware and identifies that **~61% of end-to-end RAG cost is retrieval** (vector search + payload fetch from SSD), with the model-inference portion already accelerated. Proposes in-SSD acceleration of the retrieval pipeline.

**Why IAU cites it.** Two roles. (a) **§1 ¶1 motivation:** quantifies the workload-side pressure on NVMe — retrieval dominates cost, so accelerating it matters. (b) **§5 ¶3 placement comparison:** RAGX places acceleration *inside the SSD* (per-device, vendor-specific firmware/RTL); IAU places it *in the host uncore* (per-CPU, OS-visible). These are at orthogonal administrative boundaries and are complementary, not competitive.

**How IAU differs.** RAGX is in-device, vendor-locked, and bounded to one SSD's compute. IAU is in-host, vendor-neutral, and consumes queue traffic from many SSDs through a single shared block. The Q4_RAGX_defense INSIGHT in PAPER_CHAPTER_PLAN.md formalizes the three-layer co-existence story (in-SSD + on-GPU + on-uncore at three different boundaries).

**Deployment in paper.** §1 ¶1, §5 ¶3.

---

### `[31] Jiang et al. — RAGO: System-level Optimization for Retrieval-Augmented Generation Serving (2025)` *(pending bib commit)*

**What it is.** RAG serving optimization paper from 2025, named in PAPER_CHAPTER_PLAN.md §1.3 as the retrieval-pipeline workload reference paired with RAGX.

**Why IAU cites it.** Reinforces RAG as a system-level workload class that drives storage-side IOPS demand. Currently *not load-bearing* in the third-pass §1 (which uses RAGX + DiskANN + SPANN to anchor the workload class) and may be deferred to §5 if word budget permits.

**Deployment in paper.** Originally §1 ¶1 in second-pass plan; dropped from §1 in third pass, available for §5 if reviewers ask for more workload-side citations.

---

### `[30] T. Zhang et al. — From Minutes to Seconds: Redefining the Five-Minute Rule for AI-Era Memory Hierarchies (arXiv:2511.03944, 2025)` *(pending bib commit)*

**What it is.** A 2025 paper extending the Gray–Putzolu / Appuswamy five-minute-rule analysis to AI-era workloads, showing the DRAM-caching break-even threshold has collapsed from minutes to seconds.

**Why IAU cites it.** It is an *economic* witness for the opportunity claim in §1 ¶1: combined with workload-side reuse intervals (seconds-scale, per AI retrieval), the analysis says NAND legitimately operates as an active memory tier, not as a passive cold store.

**Status in current draft.** **Dropped from §1 in the third-pass redesign.** The third pass establishes the active-tier claim directly via workload demand (retrieval pipelines hit indices that no longer fit in DRAM) + device-side capability (storage-next + saturated Gen5), rather than via an external economic threshold argument. Restorable to §1 ¶1 (or §5) if reviewers ask "where is your cost-benefit justification?"

**Deployment in paper.** Originally §1 ¶1 second pass; currently unused in third-pass §1.

---

### `five_minute_rule_30` — The Five-Minute Rule 30 Years Later and Its Impact on the Storage Hierarchy (CACM 62(11), 2019)

Appuswamy, Graefe, Borovica-Gajic, Ailamaki.

**What it is.** Thirty-year retrospective on the Gray–Putzolu (1987) five-minute rule for trading memory for disk accesses. Re-derives the break-even threshold for modern hardware and finds that microsecond-class storage (i.e., NVMe SSDs) belongs in an on-die-integration regime distinct from network-attached or block-attached storage.

**Why IAU cites it.** Anchors the §1 ¶3 claim that the cost–benefit framing for NVMe integration is not a vibes-based vendor argument — it has been independently re-derived for modern hardware. Paired with the K8/Opteron IMC analogy (`opteron_imc`) to give §1 ¶3 two independent existence-proofs that placement-based fixes are the natural resolution to integration walls.

**How IAU differs.** Appuswamy et al. argue the regime boundary in cost-benefit terms; IAU operationalizes it with a concrete on-die queue-execution mechanism + measurements.

**Deployment in paper.** §1 ¶3.

---

### `five_minute_rule_1987` — The 5 Minute Rule for Trading Memory for Disc Accesses (SIGMOD 1987)

Gray, Putzolu.

**What it is.** The original five-minute-rule paper. Foundational lineage citation.

**Why IAU cites it.** Lineage anchor for the cost-benefit framing in §1 ¶3. Context-only (cite if word budget permits — typically a footnote-grade citation alongside `five_minute_rule_30`).

**Deployment in paper.** §1 ¶3 (lineage).

---

## 2. Storage-next NVMe / device-side roadmap (§1 ¶1)

### `kioxia_fms2025` — Demonstration of Ultra-High IOPS SSD Emulation for GPU-Storage Direct Connected AI Applications (KIOXIA blog, Flash Memory Summit 2025)

KIOXIA Corporation.

**What it is.** KIOXIA's public roadmap announcement, paired with NVIDIA storage-next coverage, of a 100M-IOPS-class NVMe SSD demonstrator targeted at GPU-direct storage for AI workloads. The blog and accompanying press coverage (Tom's Hardware, blocksandfiles.com) ground the per-device IOPS roadmap claim in vendor disclosure rather than vendor-neutral speculation.

**Why IAU cites it.** Provides the **device-side** half of the §1 ¶1 opportunity claim: per-device random IOPS is being pushed from today's millions toward tens-of-millions, with public roadmaps already at 100M. Without a vendor anchor, the "100M IOPS class" claim looks speculative.

**Deployment in paper.** §1 ¶1.

---

### `[32] Micron 230M-IOPS GP-series enterprise SSD announcement (2025)` *(pending bib commit)*

**What it is.** Micron's 230M-IOPS enterprise NVMe SSD announcement (GP-series), 2025.

**Why IAU cites it.** Second device-side anchor paired with `kioxia_fms2025`. Currently not load-bearing in the third-pass §1 (which uses Kioxia alone) — restorable if reviewers want multi-vendor evidence.

**Deployment in paper.** Originally §1 ¶1 second pass; available for §5 if needed.

---

### `[33] C. J. Newburn — StorageNext: eliminating the memory wall for GenAI and LLM workloads (NVIDIA initiative, 2025)` *(pending bib commit)*

**What it is.** NVIDIA "StorageNext" initiative framing: storage subsystem must scale to MIOPS to keep GenAI / LLM training and serving fed.

**Why IAU cites it.** Vendor-stated rationale for the device-side push — useful as a why-not-just-faster-DRAM rebuttal. Currently dropped from third-pass §1 because the workload + device-side claims are already supported by Kioxia + RAGX + DiskANN.

**Deployment in paper.** §1 ¶1 in second pass; not currently used.

---

## 3. Host I/O software stacks — the wall (§1 ¶2, §2)

### `spdk_modern_apis` — Understanding Modern Storage APIs: A Systematic Study of libaio, SPDK, and io_uring (SYSTOR 2022)

Didona, Pfefferle, Ioannou, Metzler, Trivedi.

**What it is.** The canonical empirical cross-API study comparing libaio (kernel async I/O), SPDK (user-space polling), and io_uring (modern kernel polling). Measures throughput, latency, and per-IO cost across the three APIs across multiple block sizes and queue depths on real hardware. Key cross-API ratio: io_uring with SQPOLL + IOPOLL needs ~32 threads to reach the IOPS SPDK reaches with 3 threads, i.e., kernel-side stacks consume on the order of 10× more CPU per IO than SPDK.

**Why IAU cites it.** Anchors the §1 ¶2 cross-API characterization (SPDK > io_uring > libaio in CPU-efficiency, *structurally*, not due to driver bloat). Pairs with `haas_vldb23` (the 12-M-IOPS multi-SSD measurement) and `i10_atc19` (the kernel ultra-low-latency NVMe path) to triangulate the host-CPU wall from three independent peer-reviewed measurements.

**How IAU differs.** Didona et al. characterize three software stacks against each other; they do not propose hardware. IAU uses their measurement as a software-baseline reference point and adds a structural argument for why software cannot close the gap.

**Deployment in paper.** §1 ¶2 (cross-API ratio), §2 (cycles/IO baseline), §5 ¶1 (software-stack family).

**Note (2026-05-15).** The earlier "~700–1200 cycles/IO" framing has been retired. §1 P2 now uses peer-reviewed anchors only: `haas_vldb23` (real Gen4 NVMe at 12 M IOPS → ~half of cores dedicated to I/O submission/reaping even with SPDK), `spdk_modern_apis` (cross-API ratio: io_uring/libaio ≈10× more CPU than SPDK), and `i10_atc19` (kernel-side ultra-low-latency NVMe cannot close the gap). The SPDK vendor blog benchmarks (2019/2023, ~270–400 cycles/IO) were considered but **deliberately not cited** — see the deprecation note in the next entry.

---

### `haas_vldb23` — What Modern NVMe Storage Can Do, And How To Exploit It: High-Performance I/O for High-Performance Storage Engines (VLDB 2023)

Haas, Leis et al.

**What it is.** Peer-reviewed study of host-side I/O on a 64-core server with 8× Gen4 NVMe SSDs reaching ~12 M IOPS. Reports that, even with SPDK, **around half of available CPU cores must be dedicated to I/O submission and reaping** to reach this throughput, leaving only ~6,500 cycles per I/O for actual DBMS query work (out of a ~13 k cycle total budget). io_uring + libaio consume on the order of 10× more CPU per I/O than SPDK to reach the same throughput, and require many more threads to saturate the same SSDs.

**Why IAU cites it.** This is the **primary peer-reviewed anchor for §1 ¶2's host-CPU-wall claim**. It replaces the previous unverified "~700–1200 cycles/IO" placeholder with a real published measurement of structural CPU consumption at MIOPS scale on real Gen4 hardware. Pairs with `spdk_modern_apis` (cross-API ratio) and `i10_atc19` (kernel ultra-low-latency path).

**How IAU differs.** Haas et al. measure the CPU consumption of existing host-side software stacks. IAU proposes the hardware mechanism that closes the structural part of that consumption while preserving the SPDK programming contract.

**Deployment in paper.** §1 ¶2 (host-CPU wall, primary citation), §2.3 (cross-check that our own simulation per-IO budget is consistent with this peer-reviewed academic finding).

**Bib key.** `haas_vldb23` — **add to `docs/paper.bib`** (file currently deleted in working tree).

---

### `spdk_10m_2019` / `spdk_120m_2023` — SPDK vendor benchmarks (DEPRECATED FOR PAPER USE, 2026-05-15)

SPDK community / Intel.

**What it is.** Two vendor-published SPDK milestone blog posts. (i) 2019: 10.39 M IOPS single thread on 4 KB random read, Intel Xeon Platinum 8280L Cascade Lake @ 4 GHz turbo, 21× Intel SSD DC P4600 — reports a per-IO budget of ~400 cycles / 100 ns. (ii) 2023: 13.91 M IOPS single thread on 512 B IO, Intel Xeon Platinum 8480+ Sapphire Rapids — implies ~273 cycles/IO at the single-thread peak.

**Status (2026-05-15).** **Removed from §1 P2 and §1.3 evidence anchors.** Decision reasons, recorded so future agents do not re-introduce them:

1. *Self-undermining.* Citing "10 M IOPS per thread at ~400 cycles/IO already exists on real hardware" hands the reviewer a ready-made rebuttal — *"why do you need hardware help? software is already there."* The peer-reviewed `haas_vldb23` shows this peak does not hold on realistic workloads, but the headline number sticks in the reviewer's head regardless.
2. *Workload-scope mismatch.* The vendor benchmarks use 21 SSDs in parallel + small synthetic IO + Intel vendor tuning + 4 GHz turbo. IAU's workload scope is AI retrieval (DiskANN / SPANN / RAG) at 4–16 KB random reads, with §1 P1 already anchored on `diskann`, `spann_neurips21`, `ragx_isca25`. The vendor numbers are an unrelated operating point.
3. *Not peer-reviewed.* Vendor marketing posts do not belong next to peer-reviewed anchors in §1.
4. *Makes our simulator look weak by contrast.* Our AtomicSimpleCPU @ 2 GHz model measures ~2440 cycles/IO at Mode 0 QD=128 (see [[project-host-cpu-model]]). Citing ~400 cycles/IO on real silicon next to that invites *"your simulator is 6× slower than real SPDK; your motivation is a simulator-fidelity issue."*

**What replaces them.** §1 P2 now leans on three peer-reviewed anchors only: `haas_vldb23` (real-hardware CPU-bound at 12 M IOPS on Gen4), `spdk_modern_apis` (cross-API ratio), and `i10_atc19` (kernel-side cannot close the gap). That trio is sufficient.

**If a reviewer cites the SPDK blogs against us.** The defense is in §4.4 threats-to-validity: the load-bearing comparison is the Mode 0 → Mode 2 *delta* within the same simulator and the cross-workload BigANN reproduction, not absolute IOPS or absolute cycles. The vendor-best benchmark is a different operating point with different parallelism, different SSD count, and different workload profile.

**Bib keys.** `spdk_10m_2019`, `spdk_120m_2023` — **do NOT add to `docs/paper.bib`** (kept here only so future agents can find the source URLs if needed).

---

### `spdk_docs` — SPDK Project Documentation

Yang, Walker, Harris, Wang, et al. (SPDK community)

**What it is.** The Storage Performance Development Kit (open source) — Intel-originated user-space NVMe driver with polling-based completion, hugepage memory, and userspace block-device abstractions (bdev). The empirical workhorse for IAU's evaluation: `spdk_nvme_perf` is the workload generator and `spdk/lib/nvme/{nvme_pcie_internal.h, nvme_pcie.c, nvme_pcie_common.c}` is where the Mode 2B host patch lives.

**Why IAU cites it.** (a) Programming-model reference for §3.4 (the dual software contract Mode 2A / Mode 2B is defined relative to SPDK's API). (b) §2.1 cycles/IO instrumentation cites SPDK as the path being measured. (c) §1 ¶2 names SPDK as the host-side software baseline IAU contrasts against (alongside io_uring via `i10_atc19`).

**How IAU differs.** SPDK is software. IAU is hardware that *preserves* the SPDK programming model — Mode 2A requires zero SPDK changes, Mode 2B requires ~45 lines.

**Deployment in paper.** §1 ¶2 (host-side software baseline), §2.1 (instrumentation), §3.4 (software contract), §4.1 (methodology).

---

### `i10_atc19` — A Low-latency Kernel I/O Stack for Ultra-Low Latency SSDs (USENIX ATC 2019)

Lee et al.

**What it is.** Kernel-side I/O stack optimization for ultra-low-latency NVMe. Demonstrates that kernel I/O can approach SPDK-class latency with careful design, but still pays the same architectural costs (MMIO, CQ polling, fences, metadata).

**Why IAU cites it.** Strengthens the §1 ¶2 claim that the wall is *structural* — even when the kernel is optimized to the limit, the architectural ceilings remain. Pairs with `spdk_modern_apis` to span both kernel-bypass and kernel-side stacks.

**Deployment in paper.** §1 ¶2, §5 ¶1 (alongside SPDK and ReFlex in the software-stack family).

---

### `reflex` — ReFlex: Remote Flash ≈ Local Flash (ASPLOS 2017)

Klimovic, Litz, Kozyrakis et al.

**What it is.** A dataplane OS for remote flash that demonstrates the host-side polling and dedicated-CPU-core pattern: by dedicating cores to polling and using user-space stacks, remote NVMe can approach local NVMe latency. The historical precedent for "dedicate a core to I/O polling" thinking.

**Why IAU cites it.** Useful in §5 ¶1 as a software-side dataplane precedent — IAU is the hardware analogue of "dedicate something to I/O polling," except the dedicated thing is silicon, not a CPU core.

**Deployment in paper.** §5 ¶1.

---

## 4. GPU-initiated NVMe — bypass-bucket A (§1 ¶3, §5 ¶2)

### `bam_asplos23` — GPU-Initiated On-Demand High-Throughput Storage Access in the BaM System Architecture (ASPLOS 2023)

Qureshi, Mailthody, Gelado, Min, Masood, Park, Xiong, Newburn, Vainbrand, Chung, Garland, Dally, Hwu.

**What it is.** **The** canonical GPU-direct storage system. Places NVMe submission and completion queues in GPU memory and lets GPU streaming multiprocessors issue I/O directly from device kernels, bypassing the host CPU entirely for the read path. Demonstrated on a real GPU+NVMe testbed with significant IOPS gains for GPU-resident analytics and LLM-style workloads.

**Why IAU cites it.** **Load-bearing prior art.** BaM is the system that proves an NVMe queue can be executed somewhere other than the host CPU. IAU's *placement-novelty claim* depends on distinguishing IAU from BaM clearly: BaM moves queues to the *GPU side* and helps only GPU-resident consumers; IAU moves queues to the *CPU uncore* and helps both CPU-resident and GPU-attached pipelines via the same shared block.

**How IAU differs.**
- **Where queues live**: BaM → GPU memory; IAU → CPU-uncore SRAM.
- **Who benefits**: BaM → GPU-resident consumers only; IAU → any consumer that touches NVMe (CPU apps, GPU staging via host memory, DPU-attached pipelines).
- **Software model**: BaM requires rewriting host applications to use the GPU-driven I/O library; IAU is transparent under Mode 2A and requires ~45 LOC of SPDK changes under Mode 2B.
- **Hardware substrate**: BaM uses commodity GPUs; IAU is a new uncore block, requiring silicon design but not a new compute engine.

**Deployment in paper.** §1 ¶3 (bucket A: GPU-initiated NVMe — bypasses host but only GPU-resident consumers benefit), §5 ¶2 (BaM placement row in Table 1).

---

### `gids_vldb24` — Accelerating Sampling and Aggregation Operations in GNN Frameworks with GPU-Initiated Direct Storage Accesses (GIDS) (VLDB 2024)

Park, Mailthody, Qureshi, Hwu.

**What it is.** Extension of the BaM model specifically for graph neural network (GNN) sampling and aggregation, where the access pattern is highly irregular and naturally matches GPU-direct storage.

**Why IAU cites it.** Demonstrates the **breadth of the GPU-initiated NVMe approach** — BaM is not a one-off, the model has follow-on adoption in 2024. Cited alongside BaM in §1 ¶3 and §5 ¶2 so reviewers cannot dismiss the bucket as a single point in the design space.

**How IAU differs.** Same axes as BaM (GPU-side placement, GPU-only consumers, application rewrite).

**Deployment in paper.** §1 ¶3, §5 ¶2.

---

### `[26] AGILE — First work that enables GPU threads to issue NVMe commands asynchronously (SC 2025, arXiv:2504.19365)` *(pending bib commit)*

**What it is.** 2025 GPU-initiated NVMe paper that allows asynchronous (rather than blocking) NVMe command issue from GPU threads. Reports 3.12× / 2.85× API-overhead reduction over BaM.

**Why IAU cites it.** 2024–2026 follow-on in the GPU-initiated thread; signals IAU's awareness is current. Dropped from third-pass §1 (which uses BaM + GIDS to anchor the bucket); available for §5 ¶2 if reviewers want the post-BaM lineage explicit.

**Deployment in paper.** Originally §1 ¶2 second pass; available for §5 ¶2.

---

### `[27] Tutti — GPU-centric KV cache object store on SSDs for LLM serving (2025)` *(pending bib commit, citation key + venue pending verification)*

**What it is.** 2025 GPU-centric KV-cache-on-SSD system for LLM serving. Specifically targets the LLM-serving KV-cache spill pattern.

**Why IAU cites it.** Another 2024–2026 follow-on in the GPU-initiated bucket, paired with AGILE. Same status as AGILE: dropped from third-pass §1, available for §5 ¶2.

**Deployment in paper.** Originally §1 ¶2 second pass; available for §5 ¶2.

---

### `[28] SwarmIO — 100M IOPS SSD emulation for next-generation GPU-centric storage systems (KAIST, 2026)` *(pending bib commit, citation key + venue pending verification)*

**What it is.** KAIST 2026 emulation platform for next-generation GPU-centric storage at 100M-IOPS scale. Demonstrates the device-side IOPS regime that GPU-initiated NVMe will need to consume.

**Why IAU cites it.** Marked **optional** in PAPER_CHAPTER_PLAN.md — fits the GPU-initiated 2024-26 follow-on bucket alongside AGILE and Tutti, but it is the *device-emulation* angle rather than a host-side stack. Cite only if word budget permits, primarily as a signal that 100M-IOPS emulation methodology is now a live area in the community (a corroboration of the Kioxia/Micron device-side roadmap claim).

**How IAU differs.** SwarmIO is an emulation platform for studying GPU-centric storage; IAU is a host-side hardware proposal. They sit at different layers and are not in tension.

**Deployment in paper.** Optional §5 ¶2 (GPU-lineage follow-on) or §4.1 (device-emulation precedent alongside NVMeVirt and FEMU). Most likely cut at final-draft trim.

---

## 5. External / off-die NVMe offload — bypass-bucket B (§1 ¶3, §5 ¶4)

This is the **most dangerous prior-art bucket** because some of these are commercial products from major CPU vendors. The defense lives in §5 ¶4 (NVMeHA-defense paragraph) and the Q2_NVMeHA_defense INSIGHT.

### `bluefield3` — BlueField-3 DPU: Programmable Data Center Infrastructure on a Chip (NVIDIA datasheet, 2023)

NVIDIA Corporation.

**What it is.** NVIDIA's third-generation Data Processing Unit. A separate SoC (Arm cores + accelerators + NIC + storage offload) on a PCIe card, designed to offload network and storage control work from the host CPU. Used widely in AI infrastructure (DGX, hyperscaler data planes).

**Why IAU cites it.** Concrete instance of the **external-offload** bucket: DPUs run NVMe queue logic on a separate ASIC, across a PCIe link, in a separate memory and power domain. IAU's structural critique: the off-die crossing remains, the DRAM-mirrored queue model that caused the wall is unchanged, only the chip-that-pays-the-cost moves.

**How IAU differs.**
- **Where queues execute**: BlueField → separate ASIC across PCIe; IAU → on the host CPU die's uncore, no PCIe hop.
- **Latency class**: BlueField → PCIe-hop class (~500 ns); IAU → on-die uncore class (~5 ns).
- **Software contract**: BlueField → replaces the host's I/O stack with a DPU-resident stack; IAU → preserves the SPDK programming model under Mode 2A, ~45 LOC under Mode 2B.
- **Consumer model**: BlueField is designed for general-purpose PCIe traffic (networking, storage, virtualization); IAU is tuned for the small-block random-read AI-retrieval pattern.

**Deployment in paper.** §1 ¶3 (bucket B), §5 ¶4 (Table 1 row + external-offload comparison).

---

### `[29] Intel Mount Evans IPU (Hot Chips 33 / SNIA SDC21, 2021)` *(pending bib commit)*

**What it is.** Intel's Infrastructure Processing Unit — a DPU-class ASIC distinct from BlueField, focused on NVMe/TCP initiator offload on a dedicated discrete chip.

**Why IAU cites it.** Multi-vendor evidence for the external-offload bucket — shows the pattern isn't NVIDIA-specific. Dropped from third-pass §1 (which uses BlueField alone for the bucket); available for §5 ¶4 if reviewers want second-vendor coverage.

**Deployment in paper.** Originally §1 ¶2 second pass (alongside BlueField); available for §5 ¶4.

---

### `nvme_host_accel` — NVMe Host Accelerator v1.0 (Xilinx/AMD, LogiCORE IP Product Brief PB058, Feb 2019)

Xilinx (now AMD).

**What it is.** Xilinx's commercial NVMe host accelerator IP for Zynq UltraScale+ MPSoC FPGAs. Performs doorbell signaling and command construction in FPGA fabric; targeted at appliance use cases where the host CPU is largely bypassed. **Load-bearing differentiation citation** because it ships as silicon-adjacent IP from a major CPU vendor (AMD post-acquisition).

**Why IAU cites it.** §5 ¶4's most dangerous prior-art — a real product, not a research prototype. The §5 ¶4 paragraph defends three orthogonal differences (placement, scope, consumer model) in a verbatim sentence; see PAPER_CHAPTER_PLAN.md §2 ("§5 — Related Work") for the locked text.

**How IAU differs (verbatim from §5 ¶4 defense):**
- **Placement**: NVMeHA → discrete FPGA fabric; IAU → on the CPU die's uncore, no PCIe hop.
- **Scope**: NVMeHA → doorbell and command-construction only; IAU → full SRAM-resident queue execution + completion suppression (three mechanisms).
- **Consumer model**: NVMeHA → replaces host I/O for appliance workloads; IAU → augments general-purpose host software via a readiness-register interface compatible with unmodified SPDK.

**Deployment in paper.** §1 ¶3 (named in the external-offload bucket alongside BlueField, NVMeCHA, DirectNVM), §5 ¶4 (load-bearing defense paragraph + Table 1 row).

---

### `nvmecha` — A High-Performance and Scalable NVMe Controller Featuring Hardware Acceleration (TCAD 2021)

Qiu et al., NVMeCHA project (companion GitHub repo).

**What it is.** Academic FPGA implementation of a high-performance NVMe controller with hardware-accelerated queue management. Demonstrates the feasibility of full NVMe queue management in reconfigurable fabric.

**Why IAU cites it.** Academic counterpart to NVMeHA in the FPGA-NVMe bucket. §1 ¶3 names it alongside NVMeHA and DirectNVM to span the FPGA-NVMe controller family. §5 ¶4 uses it as the "even academic FPGA-NVMe controllers stop short of in-uncore placement" data point.

**How IAU differs.** NVMeCHA is in reconfigurable FPGA fabric (off-die, vendor-neutral but not on the CPU die). IAU is on the CPU die's uncore — different silicon class.

**Deployment in paper.** §1 ¶3 (external-offload bucket), §5 ¶4.

---

### `directnvm` — DirectNVM: Hardware-Accelerated NVMe SSDs for Embedded Computing (TECS 2021)

(authors TBD — bib entry has placeholder)

**What it is.** Hardware-accelerated NVMe approach targeted at embedded systems where the host CPU is severely constrained. Different deployment context than NVMeHA/NVMeCHA but same structural category: NVMe queue logic in dedicated hardware off the main CPU die.

**Why IAU cites it.** Third entry in the FPGA-NVMe-controller bucket, completing the "this work spans research and product" framing.

**Deployment in paper.** §1 ¶3 (external-offload bucket), §5 ¶4.

---

## 6. In-storage / computational storage — alternative placement (§5 ¶3)

### `rmssd` — RM-SSD: In-Storage Computing for Recommendation Inference (HPCA / IEEE)

**What it is.** In-storage computing system that places recommendation-inference compute inside the SSD controller, near NAND.

**Why IAU cites it.** Anchors the **in-storage** placement alternative in Table 1 / §5 ¶3. Same defense as RAGX: in-storage is per-device, vendor-specific, and complementary to IAU at a different administrative boundary (inside the device vs. in the host).

**Deployment in paper.** §5 ¶3 (in-storage placement comparison), Table 1 row.

---

### `compstor_survey` — Computational Storage: A Survey (TECS)

Barbalace et al. (or equivalent survey)

**What it is.** Survey of computational-storage techniques across the literature. Useful as a single citation for the entire in-storage placement family.

**Why IAU cites it.** Context-only — cite if word budget permits to give §5 ¶3 a one-citation hand-wave to the broader computational-storage literature without enumerating individual papers.

**Deployment in paper.** §5 ¶3 (optional).

---

## 7. CXL alternative — wrong latency tier (§5 ¶3)

### `cxl_ssd` — Memory-Semantic CXL SSD (e.g., Samsung SkyByte) (Samsung Tech Briefing, 2025)

**What it is.** Memory-semantic CXL-attached SSD designs (Samsung SkyByte and similar). Places NVMe-class flash behind a CXL link, exposing it as a memory-class device with cacheline-granularity access.

**Why IAU cites it.** Pre-empts the **Q1_CXL_defense** reviewer question. CXL is the wrong *latency tier* for the IAU hot loop: CXL switching/fabric adds ~50–150 ns per access, far above the single-digit-ns budget the NVMe completion-poll path needs. CXL solves a different problem (large memory tier under cacheable semantics) and is complementary, not competitive.

**How IAU differs.** CXL is a fabric tier; IAU is an on-die uncore block. Latency budgets are 1–2 orders of magnitude apart.

**Deployment in paper.** §5 ¶3 (CXL alternative), Q1_CXL_defense in INSIGHT collection.

---

## 8. Historical placement analogies (§1 ¶3)

### `opteron_imc` — The AMD Opteron Processor for Multiprocessor Servers (IEEE Micro 23(2), 2003)

Keltcher, McGrath, Ahmed, Conway.

**What it is.** The K8/Opteron architecture paper. Documents AMD's decision to relocate the memory controller from the off-die chipset onto the CPU die, eliminating a fabric hop on every DRAM access and shifting DRAM-access latency from chipset-class to on-die-class.

**Why IAU cites it.** **Load-bearing historical analogy.** The IMC integration is the canonical existence-proof that placement-based fixes work: when a critical fabric-mediated access path dominated pipeline cost, the resolution was on-die integration, not a faster chipset. IAU is the same playbook for the I/O execution plane: when MMIO/CQ-poll/DRAM-metadata traffic dominates host cycles, the resolution is on-die integration of NVMe queue execution.

**Specifically pre-empts.** The reviewer attack "why not per-core?" — the IMC was *shared at package level* across all cores, not per-core; per-core IAU would break the analogy. This anchors the §3.1 placement-granularity decision (one IAU block per uncore chiplet, shared across cores).

**Deployment in paper.** §1 ¶3 (the IMC analogy), §3 (placement argument). Pairs with `five_minute_rule_30` for two independent existence-proofs.

---

### `intel_vmd` — Intel Volume Management Device Technical Document (Intel, 2021)

Intel Corporation.

**What it is.** Intel VMD — an existing on-die NVMe-touching uncore block that aggregates PCIe NVMe devices behind a single PCIe root port and provides driver-level enumeration. Lives in the same physical region of the CPU die (uncore) where IAU would live.

**Why IAU cites it.** Pre-empts "no CPU vendor has anything NVMe-related in the uncore today" — Intel VMD is the precedent that NVMe-touching IP already lives on the CPU die in shipping silicon. IAU extends that precedent from PCIe-enumeration scope to NVMe-queue-execution scope.

**How IAU differs.** VMD handles enumeration and surprise hot-plug; it does not execute NVMe queues. IAU executes the queues themselves.

**Deployment in paper.** §3.1 (on-die NVMe-touching precedent), §5 ¶4.

---

## 9. NVMe protocol features — Shadow Doorbell defense (§5 ¶5)

### `nvme_spec_2_0d` — NVM Express Base Specification, Revision 2.0d (NVM Express Inc., 2024)

**What it is.** The current NVMe base specification, including the Doorbell Buffer Config command (NVMe §5) that defines the **Shadow Doorbell** mechanism — a per-queue DRAM-resident shadow of doorbell values that allows the device to read doorbell state from DRAM instead of host-issued MMIO writes, reducing MMIO traffic.

**Why IAU cites it.** **Critical defense citation.** Pre-empts the reviewer attack "isn't this just Shadow Doorbell?" Shadow Doorbell is a *per-MMIO-write reduction*; IAU is a *full per-IO execution offload* (SRAM-resident SQ/CQ, doorbell aggregation, completion suppression). Shadow Doorbell still leaves DRAM-resident queues, per-IO CQ scans, and completion-cacheline coherence traffic — none of which IAU has. §5 ¶5 makes this distinction explicit.

**How IAU differs.** Shadow Doorbell reduces *one specific cost component* (per-IO MMIO writes). IAU reduces *all components* of the per-IO execution plane.

**Deployment in paper.** §3 (NVMe semantics), §5 ¶5 (Shadow Doorbell differentiation paragraph).

---

### `nvme_spec_formal` — NVM Express Base Specification (Formal Reference, NVM Express Inc., 2024)

**What it is.** Companion formal-reference citation for the NVMe spec, used when the citation context calls for a non-version-specific reference rather than the 2.0d-specific Shadow Doorbell argument.

**Why IAU cites it.** Technical reference for §3 NVMe-semantics claims.

**Deployment in paper.** §3 (technical reference).

---

## 10. Simulation methodology (§4.1)

### `nvmevirt_fast23` — NVMeVirt: A Versatile Software-Defined Virtual NVMe Device (USENIX FAST 2023)

Kim, Shim, Lee, Jeong, Kang, Kim.

**What it is.** Software-defined virtual NVMe device that emulates real NVMe controllers with statistical-aggregate SSD timing models. Demonstrates that aggregate-timing flash emulation (skipping the full HIL/ICL/FTL/PAL pipeline for non-admin I/O) produces faithful enough behavior for systems research while running orders of magnitude faster than cycle-accurate simulation.

**Why IAU cites it.** **Critical methodology defense.** IAU's simulation uses a similar aggregate-timing approach (Path E fast-path in `simplessd/hil/nvme/controller.cc`): I/O commands bypass the per-stage pipeline while admin commands still flow through it; CQE publication remains cycle-accurate so every IAU mechanism (CQ batching, BAR0+0x2000 hint, MSI-X aggregation, doorbells) is still measured faithfully. Citing NVMeVirt forestalls the Reviewer 2 attack "did you invent this aggregate-timing methodology to game your numbers?" — the answer is no, it has FAST-2023 peer-reviewed precedent.

**Deployment in paper.** §4.1 (Path E methodology defense).

---

### `femu_fast18` — The CASE of FEMU: Cheap, Accurate, Scalable and Extensible Flash Emulator (USENIX FAST 2018)

Li, Hao, Tong, Sundararaman, Bjørling, Gunawi.

**What it is.** Earlier peer-reviewed aggregate-timing flash emulator. Established the methodology and the case that statistical timing is sufficient for systems-research claims at the software/architecture level (as opposed to media-physics-level claims).

**Why IAU cites it.** Paired with NVMeVirt as a second peer-reviewed precedent for the aggregate-timing methodology. Two independent precedents are strictly more defensible than one.

**Deployment in paper.** §4.1 (Path E methodology defense, alongside NVMeVirt).

---

## 11. Cross-cutting notes for future agents

### Reference budget reality
PAPER_CHAPTER_PLAN.md §0 records the reference count as 33 (10 must / 11 should / 8 lit-review / 4 context). CAL's 4-page-text + ~1-page-refs format typically supports ~20–25 references comfortably; **at final draft an aggressive trim is required**. The trim priority (per the chapter plan) is:
1. **Preserve**: [1] Kioxia, [2] RAGX, [3] Didona SYSTOR, [4] Opteron IMC, [5] BaM, [6] NVMeHA, [10] NVMe spec 2.0d, [18] SPDK docs (and either [19] GIDS or [26] AGILE for the GPU-lineage 2024+ signal).
2. **Trim if needed**: [22]–[25] context-only block first; then second-vendor anchors ([29] Mount Evans, [32] Micron 230M, [33] Newburn StorageNext) since [1] Kioxia + [9] BlueField cover the single-vendor essentials.
3. **Migrate, don't drop**: [26]–[33] lit-review block can migrate from §1 to §5 — it is no longer load-bearing in the third-pass §1 (workload-demand + device-roadmap claims are anchored by [1], [2], [7], [13] alone), but feeds Table 1's placement-taxonomy rows.

### Placement-taxonomy bucket cheat-sheet (§5 Table 1)
| Bucket | Canonical examples | Latency tier | What changes vs. SPDK baseline |
|---|---|---|---|
| Host CPU software polling | SPDK [3], io_uring [c1] | DRAM (~80 ns) | None — this is the baseline |
| GPU streaming multiprocessor | BaM [5], GIDS [19], AGILE [26], Tutti [27], SwarmIO [28] | GPU-PCIe (~µs) | GPU library rewrite required |
| External DPU/IPU appliance | BlueField-3 [9], Mount Evans [29] | PCIe (~500 ns) | Replaces host I/O stack |
| Discrete FPGA NVMe controller | NVMeHA [6], NVMeCHA [11], DirectNVM [12] | PCIe (~500 ns) | Appliance / embedded |
| Inside the SSD | RAGX [2], RM-SSD [16] | Inside device | Per-device vendor API |
| CXL fabric tier | SkyByte / CXL SSD [22] | CXL switch (~50–150 ns) | Memory-class API |
| **CPU uncore chiplet (IAU)** | **— novel —** | **On-die uncore (~5 ns)** | **Mode 2A unchanged / 2B ~45 LOC** |

### What is *not* covered by this primer
- Per-stage SPDK instrumentation details (see PAPER_CHAPTER_PLAN.md §2 + `docs/PAPER_IMPL_TODO.md`).
- ASAP7 7 nm RTL synthesis numbers (see PAPER_CHAPTER_PLAN.md §3.3/§4.4 + `RTL_design/reports/`).
- The Path E fast-path implementation details (see `docs/PATH_E_FAST_PATH_PLAN.md` and SimpleSSD `controller.cc` audit memories).
- Multi-core SimpleSSD audit hazards (see auto-memory `[Multi-core (cores>1) audit]` in `memory/MEMORY.md`).

### When to consult the source PDFs vs. trusting this primer
- **Trust the primer** for: paragraph deployment, which bucket a work belongs to, the three orthogonal differences vs. IAU, citation key spelling.
- **Re-read the source** for: exact numerical claims (e.g., "ReFlex achieved X µs latency"), exact author names beyond first two, the precise wording of a definitional sentence to paraphrase faithfully.
- **The Research-Plan PDF** (`docs/Research Plan Architecting a Host-Integrated IO Uncore.pdf`) is the upstream argument source — when in doubt about the *paper's framing* (not the prior art), re-read its §1 Motivation and §2 Target Workload Regime.

---

*End of literature-review primer. Maintained alongside `PAPER_CHAPTER_PLAN.md`; update both when prior-art coverage shifts.*
