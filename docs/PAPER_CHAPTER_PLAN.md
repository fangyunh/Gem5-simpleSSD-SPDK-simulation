# IAU Paper — Chapter Plan + INSIGHT Collection

> **Plan-mode artifact.** Produced via `/ars-plan` Socratic dialogue, 2026-05-08 → 2026-05-09.
> **Target venue:** IEEE Computer Architecture Letters (CAL).
> **Format:** 4 pages double-column + ~1 page references, IEEE numerical citation.
> **Companion files:** `docs/PAPER_IMPL_TODO.md` (pre-submission action items),
> `fast_ssd_highiops.cfg` (high-IOPS sim config),
> `spdk/lib/nvme/{nvme_pcie_internal.h, nvme_pcie.c, nvme_pcie_common.c}` (Mode 2B host patch).

---

## 0. Paper meta

| Field | Value |
|---|---|
| Working title | *IAU: Assisting the CPU Core for Next-Generation Multi-Million IOPS NVMe Devices* (renamed 2026-05-11 through five candidates: "IO-Uncore" → "TileIO" → "MUSE Stack Engine" → "MUNA Assistant" → "UIA: Uncore I/O Assistant" → final **IAU: I/O Assistant Uncore**. Each iteration fixed one issue: TileIO dropped vendor-specific "tile"; MUSE's "Stack/Storage Engine" added a hardware-noun redundant with "uncore"; MUNA mis-framed the assistant relationship as serving NVMe instead of the CPU; UIA fixed the framing but put the abstract role-noun "Assistant" at the head; IAU keeps the I/O-Assistant framing but puts the concrete architectural noun "Uncore" at the head, paralleling existing CPU-floorplan terminology (Memory Controller, PCIe Root Complex, I/O Assistant Uncore).) |
| Thesis framing | **Hybrid: Workload → Wall → Placement** |
| Memorable opening line (§1 ¶1 close) | *"AI retrieval workloads are turning NAND into an active memory tier, but the host CPU is the wall."* |
| Memorable closing line (§6 close) | *"The uncore is the placement that scales."* |
| Scope | **Three mechanisms only** — SRAM-resident SQ/CQ execution, doorbell aggregation, completion suppression |
| Software contract | Both **Mode 2A** (transparent, zero SPDK changes) and **Mode 2B** (poll-lite, ~45 LOC SPDK patch) — bracket the achievable savings |
| Out-of-scope (mention as future work) | DMA orchestration, hardware QoS, telemetry engine, IOMMU assist |
| Total reference count | 25 (10 must-cite, 11 should-cite, 4 context) — exceeds the original 22 budget by 3; trim at final draft if needed |
| Total figure count | 4 + 1 table |

---

## 1. Reference list (consolidated, IEEE numerical)

References are pre-numbered in the order they will likely appear in the paper. **Re-number when drafting.**

### Must-cite (10) — non-negotiable

| # | Tag | Reference | Section deployment |
|---|---|---|---|
| [1] | B1 | KIOXIA, "Demonstration of ultra-high IOPS SSD emulation for GPU-storage direct connected AI applications," KIOXIA blog post, FMS 2025; Tom's Hardware coverage of KIOXIA × NVIDIA 100M-IOPS roadmap, 2025. | §1 ¶1 (workload regime motivation) |
| [2] | A2/B4 | R. Mahapatra, H. Santhanam, C. Priebe, H. Xu, H. Esmaeilzadeh, "In-Storage Acceleration of Retrieval Augmented Generation as a Service," ISCA 2025. | §1 ¶1 (61% retrieval cost), §5 ¶3 (in-storage placement) |
| [3] | C1 | D. Didona, J. Pfefferle, N. Ioannou, B. Metzler, A. Trivedi, "Understanding Modern Storage APIs: A Systematic Study of libaio, SPDK, and io_uring," SYSTOR 2022. | §1 ¶2 (software ceiling), §2 (cycles/IO baseline), §5 ¶1 |
| [4] | F3 | C. N. Keltcher, K. J. McGrath, A. Ahmed, P. Conway, "The AMD Opteron Processor for Multiprocessor Servers," IEEE Micro 23(2), 2003. | §1 ¶3 (historical analogy), §3 (placement argument) |
| [5] | A1 | Z. Qureshi, V. S. Mailthody, I. Gelado, S. W. Min, A. Masood, J. Park, J. Xiong, C. J. Newburn, D. Vainbrand, I.-H. Chung, M. Garland, W. Dally, W.-M. Hwu, "GPU-Initiated On-Demand High-Throughput Storage Access in the BaM System Architecture," ASPLOS 2023. | §1 ¶1 (GPU-direct storage — the consumer that motivates the 100 M-IOPS roadmap), §5 ¶2 (GPU-side placement) |
| [6] | A3 | Xilinx (AMD), "NVMe Host Accelerator v1.0," LogiCORE IP Product Brief PB058, Feb 2019. | §5 ¶4 (FPGA appliance prior art — load-bearing differentiation) |
| [7] | B2 | S. Jayaram Subramanya, Devvrit, R. Kadekodi, R. Krishnaswamy, H. V. Simhadri, "DiskANN: Fast Accurate Billion-point Nearest Neighbor Search on a Single Node," NeurIPS 2019. | §1 ¶1 (workload class), §4.1 (workload-equivalent microbenchmark) |
| [8] | E1 | R. Appuswamy, G. Graefe, R. Borovica-Gajic, A. Ailamaki, "The Five-Minute Rule 30 Years Later and Its Impact on the Storage Hierarchy," CACM 62(11), 2019. | §1 ¶3 (caching economics framing) |
| [9] | F1 | NVIDIA, "BlueField-3 DPU Programmable Data Center Infrastructure on a Chip," datasheet, 2023. | §5 ¶4 (external DPU comparison) |
| [10] | D1 | NVM Express Inc., "NVM Express Base Specification, Revision 2.0d," 2024 (esp. §5 Doorbell Buffer Config command / shadow doorbell). | §3 (NVMe semantics), §5 ¶5 (Shadow Doorbell differentiation) |

### Should-cite (11)

| # | Tag | Reference | Section deployment |
|---|---|---|---|
| [11] | A4 | Y. Qiu et al., "A High-Performance and Scalable NVMe Controller Featuring Hardware Acceleration," 2021; *NVMeCHA* GitHub repository. | §5 ¶4 |
| [12] | A5 | DirectNVM (TECS 2021), hardware-accelerated NVMe SSDs for embedded computing. | §5 ¶4 |
| [13] | B3 | Q. Chen et al., "SPANN: Highly-efficient Billion-scale Approximate Nearest Neighbor Search," NeurIPS 2021. | §1 ¶1 (alternative ANN) |
| [14] | C2 | A. Klimovic, H. Litz, C. Kozyrakis et al., "ReFlex: Remote Flash ≈ Local Flash," ASPLOS 2017. | §5 ¶1 |
| [15] | F2 | Intel, "Volume Management Device Technical Document," 2021. | §3.1 (on-die NVMe-touching precedent), §5 ¶4 |
| [16] | G1 | RM-SSD (HPCA/IEEE conference paper) — in-storage computing for recommendation inference. | §5 ¶3 |
| [17] | H1 | NVM Express Base Specification 2.0d (formal). | §3 (technical reference) |
| [18] | H2 | I. Yang, B. Walker, J. Harris, P. Wang et al., SPDK project documentation. | §2.1, §4.1 |
| [19] | A6 | J. Park, V. S. Mailthody, Z. Qureshi, W.-M. Hwu, "Accelerating Sampling and Aggregation Operations in GNN Frameworks with GPU Initiated Direct Storage Accesses (GIDS)," VLDB 2024. | §1 ¶1 (broadens GPU-direct storage motivation alongside [5]), §5 ¶2 (analogous GPU-side placement) |
| [20] | M1 | S.-H. Kim, J. Shim, E. Lee, S. Jeong, I. Kang, J. Kim, "NVMeVirt: A Versatile Software-defined Virtual NVMe Device," USENIX FAST 2023. | §4.1 (statistical aggregate SSD timing model — Path E's methodological precedent). |
| [21] | M2 | H. Li, M. Hao, M. H. Tong, S. Sundararaman, M. Bjørling, H. S. Gunawi, "The Case of FEMU: Cheap, Accurate, Scalable and Extensible Flash Emulator," USENIX FAST 2018. | §4.1 (aggregate-timing flash emulation precedent — pairs with [20] to defend Path E methodology). |

### Context-only (4) — cite if word budget permits

| # | Tag | Reference | Section deployment |
|---|---|---|---|
| [22] | B5 | Samsung Memory-Semantic CXL SSD / SkyByte (2025) — CXL-attached SSD design. | §5 ¶3 (CXL alternative) |
| [23] | C3 | G. Lee et al., "A Low-latency Kernel I/O Stack for Ultra-Low Latency SSDs," USENIX ATC 2019. | §5 ¶1 |
| [24] | E2 | J. Gray, G. Putzolu, "The 5 Minute Rule for Trading Memory for Disc Accesses," SIGMOD 1987. | §1 ¶3 (lineage anchor) |
| [25] | G2 | A. Barbalace et al., or Liao group survey — computational storage TECS. | §5 ¶3 |

---

## 2. Section-by-section plan

### §1 — Introduction (~3/4 page, ~500 words, no figure)

**Purpose.** Convert reader from "another storage paper" to "I need §2." Workload→Wall→Placement chain in three paragraphs, then contributions.

**Locked structure.**

```
¶1  HOOK + WORKLOAD     [1][2][5]                     ~120 words
       ends with: "AI retrieval workloads are turning NAND into
       an active memory tier, but the host CPU is the wall."
       — [5] BaM is cited here as the GPU-initiated-storage consumer
       that links the [1] 100 M-IOPS device roadmap to the [2] retrieval
       workload — without it the AI workload→fast-SSD chain has a gap.
¶2  WALL                [3][18]                       ~120 words
¶3  PLACEMENT + ANALOGY [4][8]                        ~140 words
       ends with: "We close the wall where the memory-controller
       wall was closed: in the CPU uncore."
¶4  CONTRIBUTIONS                                     ~120 words
```

**Contribution list (locked order — design-led).**

1. **A IAU architecture** for relocating NVMe queue execution into the CPU uncore, with three mechanisms (SRAM-resident SQ/CQ, doorbell aggregation, CQ suppression) and a dual software contract: a transparent mode (2A) requiring no SPDK changes, and a poll-lite mode (2B) requiring a ~45-line SPDK patch.
2. **A measurement-based characterization** of the per-IO software overhead in SPDK on a high-IOPS gem5+SimpleSSD configuration sustaining ≥10 M IOPS at QD=128, decomposed into per-stage costs scaling with queue-pair count.
3. **A bracket evaluation** showing Mode 2A reduces cycles/IO and DRAM bytes/IO under unmodified SPDK (lower bound), and Mode 2B further eliminates multi-queue scanning overhead with a minimal patch (upper bound).

**References used:** [1] [2] [3] [4] [5] [8] [18] (7 of 25 — [5] added 2026-05-11 to close the AI-workload → 100 M-IOPS → GPU-consumer chain)

---

### §2 — The Host I/O Wall (~5/4 page, ~750 words, **Figure 2**)

**Purpose.** Quantify the floor with measured data. Bridge to §3 by ending on "the natural fix is hardware."

**Locked structure.**

```
§2.1  Per-IO Cost Decomposition (~250 words + FIG 2)  cycles/IO breakdown
§2.2  Why Software Cannot Close This Gap (~400 words) memory-hierarchy floor +
                                                       per-instruction floor +
                                                       multi-queue scanning O(qpairs)
§2.3  Bridge sentence (~50 words)                     "The natural fix is to give
                                                       it that hardware."
```

**Anchor statistic:** *"96.5% of poll calls return zero useful completions"*
(derived from `Completions_Per_Call = 0.0353` in `phase1_qd128_iouncoreB`).
**Use this number verbatim in §2.1 prose.**

**Dominant per-stage costs at QD=128 (legacy data, pre-split; refresh after high-IOPS sweep with split-instrumented SPDK):**

| Stage | ns/IO | % of SW path | What CPU is doing | HW-elidable? |
|---|---:|---:|---|---|
| State_Dealloc_Library | TBD (≈280 expected) | TBD | Tracker free, CID push, free-list splice, qpair stat increment | **Yes** — IAU manages tracker state in SRAM-resident structures |
| State_Dealloc_Callback | TBD (≈40 expected) | TBD | Application `cb_fn(cb_arg, cpl)` — workload-specific completion handler | **No** — application code, stays on CPU |
| State_Dealloc (legacy ∑) | 322 | 28.5% | Sum of the two rows above (pre-split column, kept for backward compatibility) | partially |
| Addr_Xlate | 184 | 16.3% | Page-walk + PRP list construction | Yes |
| Submit_Preamble | 73 | 6.5% | Function entry + qpair lookup | Yes |
| Tracker_Alloc | 69 | 6.1% | CID allocation from pool free-list | Yes |
| Cmd_Construct | 51 | 4.5% | NVMe SQE filling | Yes |
| CQE_Detect | 20 | 1.8% | DRAM phase-bit poll | Yes |
| Tracker_Lookup | 11 | 1.0% | CID-to-tracker lookup | Yes |
| Fence | 1.8 | 0.2% | sfence before doorbell | Yes |
| Doorbell | 1.1 | 0.1% | MMIO write | Yes |
| **Other SPDK overhead** | **396** | **35.1%** | Internal book-keeping | Yes |
| **TOTAL** | **1,129** | 100% | **≈1,129 cycles at 1 GHz / ≈5,983 cycles at 5.3 GHz** | — |

**State_Dealloc split rationale.** The legacy `State_Dealloc` stage bundled
two structurally different things: SPDK library teardown (tracker free,
CID push, free-list splice — pure NVMe-library bookkeeping) and the
application's `cb_fn()` callback (workload-defined; for `spdk_nvme_perf`
this is a histogram update, for DiskANN it is a beam-search step
trigger). Hardware can absorb the library portion but cannot eliminate
application code. Reporting both as one stage would let §4 credit
hardware for cycles it fundamentally cannot reach. The split, applied to
`spdk/lib/nvme/{nvme_pcie_common.c, nvme_qpair.c, nvme_internal.h}` on
2026-05-09, emits two new CSV columns
(`State_Dealloc_Library_ns`, `State_Dealloc_Callback_ns`) and is
documented in `docs/PAPER_IMPL_TODO.md` §5. The legacy
`State_Dealloc_ns` column is preserved unchanged so analysis scripts
and prior data continue to work.

**Two independent floors that hardware breaks:**
1. **Memory-hierarchy floor** ≥240 ns/IO (3 DRAM round-trips; measured directly via DRAM bytes/IO).
2. **Multi-queue scanning** O(qpairs) per useful completion (measured directly via Figure 3's qpair sweep).

*(Energy/Joules are intentionally out of scope in §2. Per-IO energy is essentially cycles/IO scaled by a per-instruction-energy constant — it adds attack surface without adding new information beyond what the cycles/IO and DRAM bytes/IO measurements already prove. Power feasibility for the proposed hardware is covered in §4.4 from RTL synthesis.)*

**Figure 2.** Stacked horizontal bar chart (current draft at `plots/io_stage_breakdown.{png,pdf}`). Two bars: QD=16, QD=128. Stacked stages = the 8 elidable named ones (Submit_Preamble through State_Dealloc_Library) + the application-callback segment rendered in a distinct red colour to visually separate hardware-elidable from kept cycles + "Other SPDK overhead." Labels: total ns/IO + cycles at 5.3 GHz + IOPS. **Regenerate after high-IOPS sweep with `scripts/phase1_4k/plot_io_breakdown.py`** (the script's `NAMED_STAGES` list and palette already reflect the split as of 2026-05-09).

**References used:** [3] (anchored cycles/IO), [18] (SPDK programming model)

---

### §3 — IAU Architecture (~5/4 page, ~750 words, **Figure 1**)

**Purpose.** Make the design concrete enough that an architect can reason about it. Most important section for IEEE CAL reviewers.

**Locked structure.**

```
§3.0  Bridge from §2 (~50 words)               "give it that hardware"
§3.1  On-Die Placement (~150 words + FIG 1)    block diagram + tile granularity
§3.2  Three Mechanisms (~400 words ~130 each)
       §3.2.1  SRAM-Resident SQ/CQ Execution
       §3.2.2  Doorbell Aggregation
       §3.2.3  Completion Suppression
§3.3  SRAM Sizing (~75 words)                  329 KB - 2.6 MB per tile (RTL-grounded)
§3.4  Software Contract (~75 words)            Mode 2A / Mode 2B contracts
```

**Figure 1 (system view).** CPU package showing cores + LLC on one side and the uncore chiplet (PCIe root complex + integrated memory controller + **IAU highlighted**) on the other, connected by the inter-chiplet fabric, with the NVMe SSD attached via PCIe. The figure annotates the chiplet as the "SoC/I/O tile (Intel) / IOD (AMD)" to ground the otherwise-abstract term *uncore* in shipping silicon. Two arrow flows: (a) Mode 2A — host polls DRAM CQ, IAU observes; (b) Mode 2B — host reads on-chiplet readiness register, skips DRAM when 0. **Mechanism-internal block diagram deferred to follow-up RTL paper.**

**§3.1 — placement granularity (use verbatim, ~30 words):**

> *"One IAU block is integrated per CPU uncore, shared by every core
> in the package. This placement matches existing on-uncore resources
> (integrated memory controller, PCIe root complex, Intel VMD [15]) and
> reflects the historical pattern of host-side I/O integration: shared
> at the uncore (chiplet) or socket level, never per-core. The uncore
> here is the physical chiplet that vendors today ship as the SoC/I/O
> tile (Intel Meteor Lake / Lunar Lake / Arrow Lake) or the I/O Die
> (AMD Zen 2--5); we use the academic term \emph{uncore} throughout to
> stay vendor-neutral."*

This single sentence pre-empts the obvious "why not per-core?" reviewer question by anchoring the granularity decision in existing CPU floorplan precedent. The historical analogy of §1 ¶3 (K8/Opteron memory controller integration [4]) **also requires shared placement** — the IMC was shared across all cores in the package; per-core uncore would break the analogy.

**§3.4 — concrete numbers (use verbatim):**

> *"Mode 2A requires no software changes. Mode 2B requires a host-side patch
> of ~45 lines across three SPDK files; the hot-path edit is 8 lines in one
> polling function (`nvme_pcie_qpair_process_completions`), with the
> remainder being one-time BAR mapping and one struct field. The patch is
> dormant when the env var `SPDK_UNCORE_MODE_B` is unset, preserving
> byte-equivalent runtime behaviour to vanilla SPDK."*

**§3.3 — SRAM sizing argument (use verbatim, anchored to `RTL_design/reports/sram_sizing.json`):**

> *"Each active QP requires ~8 KB of private SRAM (a 4 KB SQ slot + 4 KB CQ
> slot) plus per-IO PRP-list and metadata storage scaling with the queue
> depth. We size four points spanning the design space: 16 QP / QD 64
> needs 329 KB total SRAM (0.11 mm² at ASAP7 7 nm bitcell density);
> 64 QP / QD 64 needs 1.3 MB (0.44 mm²); 16 QP / QD 128 needs 657 KB
> (0.22 mm²); the 64 QP / QD 128 production point needs 2.6 MB (0.87
> mm²). All four fit comfortably within published 7 nm CPU L3 slice
> envelopes (Intel Sapphire Rapids LLC slice = 1.875 MB / ~3-4 mm²; AMD
> Zen 4 L3 slice = 4 MB), with the production tile occupying under half
> of a single LLC slice."*

**References used:** [4] (analogy), [10] (NVMe semantics), [15] (Intel VMD precedent)

---

### §4 — Evaluation (~1 page, ~600 words, **Figures 3 + 4**)

**Purpose.** Demonstrate the Mode 2A (lower bound) / Mode 2B (upper bound) bracket via measured simulation data.

**Locked structure.**

```
§4.1  Methodology (~150 words)
       gem5 + SimpleSSD + SPDK; fast_ssd_highiops.cfg sustaining >=10 M IOPS;
       4 KB random read; reused pinned huge-pages; cite [7] DiskANN for class.
       SSD-side timing uses a statistical aggregate model (NVMeVirt-style
       [20], FEMU-style [21]) -- the per-stage HIL/ICL/FTL/PAL pipeline is
       bypassed for I/O commands while CQE publication still flows through
       the cycle-accurate NVMe controller, preserving every IAU
       mechanism (CQ batching, BAR0+0x2000 hint, MSI-X aggregation,
       doorbells). Admin commands still use the full pipeline. Defending
       this choice with [20][21] forestalls Reviewer 2 "did you invent
       this?" attacks: the same aggregate-timing pattern is used by
       NVMeVirt [Kim FAST '23] and FEMU [Li FAST '18], both peer-reviewed
       SSD-emulation precedents.
       Steady-state: 5 s per data point (3 repeats; deterministic simulation
       eliminates physical noise sources that motivate longer windows on
       real hardware -- see verbatim sentence below).
§4.2  Per-IO Cost Reduction (~200 words + FIG 3)
       Mode 2A vs SPDK and Mode 2B vs SPDK:
       cycles/IO and DRAM bytes/IO across qpairs in {1, 4, 16, 64}.
       Cycles/IO is computed from the elidable stages only --
       Submit_Logic_ns + (Completion_Logic_ns - State_Dealloc_Callback_ns)
       -- so the savings claim does not credit IAU for application
       callback cycles. The callback is reported alongside as a separate
       constant offset (~40 ns) that all three regimes carry equally.

       Per-core invariance footnote (one extra sentence):
       cycles/IO at QD=128 is also measured at 1-core and 2-core core
       counts via scripts/phase1_run_multicore_gem5.sh and shown to
       agree within ~10%. This anchors the §3.1 "shared at chiplet
       level, not per-core" placement decision: per-core cycles/IO does
       not change with multi-core load, so a single shared tile suffices
       and the per-core variant has no measurement-grounded benefit.
       Plot: plots/multicore_invariance.{png,pdf}.
§4.3  Latency Trade Curves (~150 words + FIG 4)
       p99 latency vs CQ_BATCH_N at fixed CQ_BATCH_T;
       validates batching does not regress SLO.
§4.4  Sizing + RTL Feasibility (~100 words)
       SRAM working set + ASAP7 7 nm gate-level synthesis (Yosys, 4
       configurations) anchors per-tile area against published 7 nm CPU
       L3 slices. Power and frequency closure are companion-paper scope.
```

**Figure 3 (the bracket figure).** Twin y-axes: cycles/IO (left), DRAM bytes/IO (right). x-axis: qpairs ∈ {1, 4, 16, 64}. Three lines per axis: SPDK baseline (red), Mode 2A (blue), Mode 2B (green). **This is the figure that lives or dies on Mode 2B implementation completing.**

**Figure 4 (latency trade).** y-axis: p99 latency (µs). x-axis: CQ_BATCH_N ∈ {1, 4, 16, 64}. Two lines: Mode 2A, Mode 2B. Horizontal annotation line: "deployment-acceptable p99 budget."

**§4.1 — methodology defense for short steady-state (use verbatim):**

> *"We use 5 s of steady-state per measurement after a 1 s warmup.
> Deterministic simulation eliminates physical noise sources --
> thermal throttling, DVFS, SMI, garbage collection, wear leveling --
> that motivate longer windows on real hardware. At ≥10 M IOPS,
> 5 s yields 5 × 10⁷ IO samples per data point, three orders of
> magnitude beyond the requirements for stable mean and 99th-
> percentile estimates."*

**§4.4 — RTL-grounded silicon feasibility (use verbatim):**

> *"We synthesize IAU (SQ Engine, CQ Engine, Doorbell Coalescer,
> Credit Manager, SRAM Arbiter, Stat Counters) in ASAP7 7 nm with Yosys
> for four (queue-pairs, queue-depth) configurations: 16/64, 64/64,
> 16/128, and 64/128 (production). The production tile produces a
> gate-level netlist of 58,783 ASAP7 standard cells (9,729 sequential
> elements). Per-tile SRAM is sized analytically from the queue working
> set (private SQ + CQ + PRP + metadata regions) and ranges from 329 KB
> at 16 QP / QD 64 (0.11 mm² at ASAP7 bitcell density) to 2.6 MB at the
> 64 QP / QD 128 production point (0.87 mm²). Both extremes fit
> comfortably inside published 7 nm CPU-die IP block envelopes — a
> Sapphire Rapids LLC slice is 1.875 MB / ~3-4 mm² [cite]; the
> production IAU block occupies less than half of one such slice.
> Per-tile dynamic power and critical-path frequency are extracted in
> a companion paper via OpenROAD; the synthesis flow at this paper's
> submission time confirms area and gate count, which suffices for the
> on-die feasibility argument."*

**§4.4 — RTL evidence inventory (where the numbers above come from):**

| Number | File | Provenance |
|---|---|---|
| 58,783 cells / 9,729 DFFs (production) | `RTL_design/reports/stat_64_128.rpt` | Yosys synthesis against ASAP7 7 nm 7.5T standard cells |
| 4 configs synthesized (16/64, 64/64, 16/128, 64/128) | `RTL_design/reports/stat_*.rpt` + `netlists/io_uncore_*.v` | Same |
| SRAM budget 329 KB → 2.6 MB | `RTL_design/reports/sram_sizing.json` | Analytical from queue working set; verified against ASAP7 bitcell density |
| SRAM area 0.11 mm² → 0.87 mm² | Same | Same |
| Sapphire Rapids LLC slice anchor | Intel datasheet [cite] | Published vendor disclosure |
| Per-tile W and GHz | **pending** — companion paper | OpenROAD flow extension; not required for the IEEE CAL submission's on-die-feasibility claim, which is anchored on area + cell count alone |

**Pre-submission action items (gating §4):**
- (1) Verify `fast_ssd_highiops.cfg` sustains ≥10 M IOPS at QD=128 (PAPER_IMPL_TODO §1)
- (2) Rebuild SPDK with Mode 2B patch (PAPER_IMPL_TODO §2). **DONE** 2026-05-09 (Docker rebuild; Mode 2B + State_Dealloc split both armed).
- (3) Run three-regime sweep at `UncoreMode ∈ {0, 1, 2}` (PAPER_IMPL_TODO §3) — populates split columns in `phase1_results.csv`.
- (4) **DONE** 2026-05-09: split `State_Dealloc_ns` instrumentation. Code change: `spdk/lib/nvme/{nvme_internal.h, nvme_pcie_common.c, nvme_qpair.c}`, `scripts/phase1_4k/phase1_run.sh`, `scripts/phase1_4k/plot_io_breakdown.py`. Re-run sweep needed to populate the new columns; legacy column preserved for back-compat.

**References used:** [3] (cycles/IO baseline), [7] (workload class), [4] (CPU SRAM density precedent — informally), [20] NVMeVirt + [21] FEMU (Path E aggregate-timing methodology defense — §4.1).

---

### §5 — Related Work (~1/2 page, ~300 words, **Table 1**)

**Purpose.** Pre-empt every "isn't this just X?" objection. NVMeHA paragraph is **load-bearing**.

**Locked structure (5 paragraphs + table).**

```
¶1  Software stacks                       [3][14][18]    ~40 words
¶2  GPU-orchestrated queues               [5][19]        ~50 words
       BaM [5] is the canonical GPU-initiated I/O system; GIDS [19] extends
       the pattern to GNN sampling/aggregation. Both place queue execution
       on the GPU side, which IAU differs from by placing it in the
       CPU uncore (see Table 1 row for "GPU streaming multiprocessor").
¶3  In-storage acceleration               [2][16]        ~50 words
¶4  External / FPGA accelerators ⚠ MOST DANGEROUS   [6][9][11][12]   ~80 words
¶5  NVMe protocol features                [10]           ~40 words
TABLE 1 caption                                          ~40 words
```

**Table 1 — Placement Taxonomy (the differentiation visual).**

| Where queue execution lives | Existing example | What's free | Latency tier | Software contract |
|---|---|---|---|---|
| Host CPU software polling | SPDK / io_uring [3] | — | DRAM (~80 ns) | unchanged |
| GPU streaming multiprocessor | BaM [5] | CPU when GPU consumes | GPU-PCIe (~µs) | GPU library rewritten |
| External DPU / FPGA appliance | BlueField-3 [9], NVMeHA [6] | CPU at PCIe-hop cost | PCIe (~500 ns) | Replaces host I/O |
| Inside the SSD | RAGX [2], RM-SSD [16] | Per-device, vendor-specific | Inside device | Vendor API |
| **CPU uncore chiplet (this work)** | **— novel placement —** | **CPU + GPU + uncore** | **On-die uncore (~5 ns)** | **Mode 2A unchanged / 2B ~45 LOC patch** |

**¶4 NVMeHA defense (use verbatim):**

> *"AMD's NVMe Host Accelerator IP [6] offloads doorbell and command-construction to a discrete FPGA fabric, suiting appliance workloads where the host CPU is bypassed entirely; IAU differs in placement (in the CPU uncore, no PCIe hop), scope (full SRAM-resident queue execution and completion suppression, not just doorbells), and consumer model (it augments general-purpose host software via a readiness-register interface compatible with unmodified SPDK)."*

**References used:** [2] [3] [5] [6] [9] [10] [11] [12] [14] [16] [18] [19] (12 refs in §5 alone — appropriate density; [19] GIDS added 2026-05-11 alongside [5] BaM)

---

### §6 — Conclusion (~1/4 page, ~150 words, no figure)

**Locked draft (use verbatim or lightly edit):**

> *"NVMe queue execution belongs in the CPU uncore. Software stacks
> have hit a memory-hierarchy floor that batching cannot lift; GPU-
> orchestrated, in-storage, and external-DPU offloads each free one
> consumer at the cost of cycles, fabric hops, or vendor lock-in. We
> have shown that relocating queue execution into the host uncore
> — three mechanisms, ~45 lines of host-side cooperation, ~3–11 MB of
> private SRAM per block — eliminates the per-IO overheads that bound
> software while remaining transparent to applications. As 100 M-IOPS-
> class NVMe devices ship for AI workloads, the uncore is the
> placement that scales. ASAP7 7 nm synthesis confirms the per-block
> area envelope; full PPA closure is in progress as silicon-feasibility
> follow-up work."*

**Closing line:** *"The uncore is the placement that scales."*

**Optional limitation bullet (add only if word count permits, ~30 words):**

> *"As a shared resource, each IAU block is bounded by SRAM port
> bandwidth and aggregate PCIe throughput; workloads exceeding ~30–40 M
> IOPS per block saturate it. Multi-block integration (one block per
> uncore chiplet in multi-socket or chiplet-disaggregated parts) is the
> natural scaling path, deferred to follow-up work."*

---

## 3. INSIGHT collection (28 tagged insights)

> Each INSIGHT is a load-bearing decision from the planning dialogue. Format: `tag — rule — section deployment`.

### Strategic / framing
- **`thesis_framing`** — Hybrid Workload→Wall→Placement chain in three §1 paragraphs. — All sections.
- **`venue_constraint`** — IEEE CAL forces (a) ≥1 figure of measured data, (b) concrete architectural block diagram, (c) numerical citations, (d) defendable quantitative claims. No pure vision allowed. — All sections.
- **`paper_structure`** — 6 sections, 4 figures + 1 table, ~22 references, ~3.5 pages text + 0.5 page refs. — Master structure.
- **`novelty_framing`** — Novelty is **on-die placement + combinatorial mechanism integration**, not any single mechanism in isolation. — §1, §5.
- **`reference_priority_list`** — 10 must-cite refs anchor 4 critical defensive moves: BaM/RAGX positioning, Kioxia 100M-IOPS grounding, Shadow-Doorbell defense, K8/IMC analogy. — All sections.

### Stress-test defenses (Q1–Q5)
- **`Q1_CXL_defense`** — CXL is fabric tier (50–150 ns); NVMe hot loop needs single-digit ns. Wrong tier. — §5 ¶4.
- **`Q2_NVMeHA_defense`** — NVMeHA: discrete FPGA, doorbell-only, replaces host. IAU: in the CPU uncore, full execution offload, augments host. Three orthogonal differences. — §5 ¶4 (load-bearing paragraph).
- **`Q3_simfidelity_defense`** — Option A locked: retune `fast_ssd_highiops.cfg` to ≥10 M IOPS. — §4.1.
- **`Q4_RAGX_defense`** — Three-layer co-existence: in-SSD + on-GPU + on-uncore at three orthogonal administrative boundaries. Not competitive; complementary. — §5 ¶3.
- **`§2.2_scope_locked`** — §2 makes a cycles/IO + DRAM bytes/IO argument only. **Energy/Joules are out of scope in §2.** The third "per-instruction energy floor" originally drafted has been retired (2026-05-09) — it added attack surface without adding new information beyond cycles/IO. Hardware-side power feasibility lives entirely in §4.4 (RTL-grounded). The "50×" CACM-derived ratio is no longer a paper claim. — §2.2.

### §1 Introduction
- **`§1_memorable_line`** — Workload-wall sentence anchors ¶1 close; placement-centric sentence anchors ¶3 close. Both reopen in §6. — §1, §6.
- **`§1_contribution_order`** — C-B (design) leads as least-deflatable; C-A (characterization) second; C-C (bracket eval) third. Sets reviewer anchor on design. — §1 ¶4.
- **`§1_reference_load`** — §1 alone burns 6 of 22 refs. Front-loaded but appropriate for IEEE CAL motivation. — §1.

### §2 The Host I/O Wall
- **`§2_anchor_stat`** — *"96.5% of polls return zero useful completions"* (derived from `Completions_Per_Call = 0.0353`). Sharpest one-number motivation. **Quote verbatim.** — §2.1.
- **`§2_dominant_stages`** — At QD=128 steady-state (legacy data): Addr_Xlate (184 ns) + State_Dealloc (322 ns) + Other (396 ns) = 80% of cost. Doorbell + Fence are <0.3% combined. Combined-overhead story is strong; doorbell-only story is weak. After the State_Dealloc split, the elidable portion shrinks by the callback contribution (~30–40 ns expected) but the dominance argument holds. **Refresh table after split-aware sweep.** — §2.1.
- **`§2_state_dealloc_caveat`** — `State_Dealloc_ns` previously bundled SPDK library teardown with the application callback. **DONE 2026-05-09**: split into `State_Dealloc_Library_ns` (HW-elidable) and `State_Dealloc_Callback_ns` (kept on CPU). Plot script and CSV pipeline updated; legacy column retained for back-compat. The split eliminates the most likely Reviewer 2 attack on §2.1's dominance claim. — §2.1; PAPER_IMPL_TODO §5.
- **`§2_three_floors`** — Three independent floors: memory-hierarchy (~240 ns/IO), per-instruction energy (~80 pJ × instr-count), multi-queue scanning (O(qpairs)). The case for hardware lives on the union of all three. — §2.2.

### §3 IAU Architecture
- **`§3_scoping`** — Mechanism internals (RTL block diagram, FSM detail, SRAM banking) **deliberately deferred to follow-up RTL paper**. CAL paper focuses on placement + measurement. — §3.
- **`§3_figure_choice`** — Figure 1 = system view (Option A), not mechanism view. Reader sees placement in one glance. — §3.1.
- **`§3.4_patch_size_concrete`** — *"Mode B requires ≈45 lines across 3 SPDK files; hot-path edit is 8 lines in one polling function."* Replace with measured `git diff --stat` once patch lands and is rebuilt. — §3.4.
- **`§3.1_placement_granularity`** — **One IAU block per uncore chiplet, shared by all cores in the package.** Not per-core. Anchored in (a) existing CPU floorplan precedent (IMC, PCIe RC, VMD all live in the uncore and are shared), (b) the K8/Opteron historical analogy [4] which was *shared at package level*, (c) silicon economics (per-core ~200 MB total vs shared ~6–40 MB total). Per-core would break the historical analogy and has no precedent on shipping CPUs. The uncore chiplet is the physical die Intel labels SoC/I/O tile and AMD labels IOD; the paper uses *uncore* as the vendor-neutral academic term. — §3.1.
- **`§6_tile_saturation_limitation`** — Per-tile cap (~30–40 M IOPS aggregate). Workloads exceeding this need additional tiles. Multi-tile composition is the scaling path; deferred to follow-up work. Mention as a one-line limitation in §6 if word budget allows. — §6.

### §4 Evaluation
- **`§4_eval_status`** — All three regimes are *plannable*; only baseline + Mode A are *currently measurable*. Mode B requires SPDK rebuild + re-bake + re-run after the patch landed. — §4.
- **`§4.4_sram_sizing`** — Three-step argument: (a) analytical model from queue working set (in `RTL_design/reports/sram_sizing.json`), (b) ASAP7 7 nm Yosys synthesis for 4 configs (in `RTL_design/reports/stat_*.rpt` + `netlists/io_uncore_*.v`), (c) anchor against published Intel/AMD 7 nm CPU L3 slice envelopes. The "(c) RTL synthesis as confirmation" step is now anchored on REAL synthesis output, not a forthcoming-follow-up promise. Power (W) and frequency (GHz) closure remain companion-paper scope. — §4.4.
- **`§4.1_steady_state_window`** — gem5 is deterministic; physical noise sources motivating 30 s windows on real hardware do not exist. **5 s steady-state at ≥10 M IOPS = 5 × 10⁷ samples per data point, three orders of magnitude beyond what means and p99 require.** Use 3 s for verify, 5 s for the paper. Defend explicitly in §4.1 prose so reviewers do not flag the short window. — §4.1.

### §5 Related Work
- **`§5_NVMeHA_priority`** — ¶4 (FPGA/DPU) gets ~80/300 words = 27% of §5 word budget. NVMeHA is the most dangerous prior art because it ships as silicon-adjacent IP from a major CPU vendor. — §5 ¶4.
- **`§5_table_anchor`** — Table 1 is the differentiation visual. Placement-tier latency column (DRAM → GPU-PCIe → PCIe → in-device → uncore) is what *visibly* shows novelty. — §5 caption.

### Implementation gates
- **`mode_2B_host_gap`** — Device-side Mode B is implemented (BAR0+0x2000 hint register exposed in `simplessd/hil/nvme/controller.cc`); host-side SPDK patch was missing. **Now applied** (`spdk/lib/nvme/{nvme_pcie_internal.h, nvme_pcie.c, nvme_pcie_common.c}`, +45 LOC). — §3.4, §4.
- **`implementation_pre_submission`** — Three required steps before §4 has data: (a) retune sim, (b) rebuild SPDK + re-bake, (c) re-run sweep at all three `UncoreMode` values. — PAPER_IMPL_TODO §1–§3.
- **`device_ceiling_risk`** — Without device-config retune, evaluation stays in SSD-bottleneck regime (~75K IOPS) and does not match motivation regime (10–100M IOPS). **Publication-blocker if unfixed.** — §4.1.

### Research foundation
- **`research_foundation_strong`** — Proposal + adversarial-review discussion + working sim infrastructure + measured per-stage data. No deep-research pre-pass needed. — All.

---

## 4. Reading guide — what to do next, in order

**Drafting prep (before opening LaTeX):**
1. Read this file end-to-end.
2. Read `docs/PAPER_IMPL_TODO.md` and schedule the three implementation gates (sim retune verify → SPDK rebuild → three-regime sweep).
3. Skim each must-cite reference [1]–[10] and pull the BibTeX into a `paper.bib` file.

**Implementation phase (gating data collection):**
4. Run `SSD_CFG=fast_ssd_highiops.cfg ./scripts/phase1_4k/driver_phase1.sh ... --tag verify_highiops` and confirm IOPS ≥ 10 M at QD=128. Tune if not.
5. Rebuild SPDK with the Mode 2B patch (`cd spdk && make` in the Docker container) and re-bake the disk image.
6. Run the three-regime sweep at `UncoreMode ∈ {0, 1, 2}`, ~5 hours wall.
7. Regenerate `plots/io_stage_breakdown.{png,pdf}` via `python scripts/phase1_4k/plot_io_breakdown.py`.
8. Generate Figure 3 (cycles/IO bracket) and Figure 4 (latency trade) — use `scripts/phase1_4k/plot_phase1.py` as a starting point; adapt for three-regime overlay.

**Drafting phase (after data is in):**
9. Draft §3 first — it's the most concrete and leverages the design specs you already have.
10. Draft §2 second using §2.1 dominant-stages table and the Figure 2 you just regenerated.
11. Draft §1 third (motivation tightens once you know which numbers §2 carries).
12. Draft §5 fourth — the table is already designed; the prose is short.
13. Draft §4 fifth — needs the data. Use §4.4 wording verbatim if RTL is still pending.
14. Draft §6 last. Single paragraph. The closing line is locked.

**Polish phase:**
15. Run citation check: every claim must trace to a reference or to your own measurement.
16. Ensure ≤2 em dashes per page, no throat-clearing openers, varied paragraph lengths (anti-AI-tics from `academic-paper/references/writing_quality_check.md`).
17. Final word count check: target ~3.5 pages text + 0.5 page references = exactly 4 page CAL limit.

**Submission:**
18. Write a 200-word cover letter highlighting (a) the placement novelty, (b) the bracket evaluation, (c) the K8/IMC historical analogy that grounds the inevitability claim.
19. Submit to IEEE CAL.

---

*End of plan-mode artifact. The next session of work is implementation/drafting, not planning.*
