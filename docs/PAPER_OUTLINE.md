# IAU Paper Outline — Section-by-Section Guideline

> **Working title.** *IAU: Assisting the CPU Core for Next-Generation Multi-Million IOPS NVMe Devices*
> **Venue.** IEEE Computer Architecture Letters (CAL) — 4 pages of text + 1 page of references.
> **Audience.** Computer-architecture reviewers familiar with NVMe, the host I/O stack (SPDK / io_uring), and prior accelerator placements (GPU-direct storage, DPU/IPU, in-storage compute, CXL).
> **Purpose of this file.** A locked-in skeleton that both author and AI collaborator can update by editing in place. Each section specifies (i) *what content to write*, (ii) *which evidence anchors each claim*, and (iii) *the explicit logic chain that connects the paragraphs*. Citation keys reference `docs/LITERATURE_REVIEW.md`.
> **Status.** Draft v0, 2026-05-14. Pending author review.

---

## Page-budget reality check (target = 4 text pages, 2-column CAL)

| Section | Target length | Why |
|---|---|---|
| §1 Introduction | ~0.9 page | Motivation + contributions. Needs to do the heavy lifting of positioning. |
| §2 Background | ~0.5 page | Just enough NVMe and SPDK mechanics to make §3 readable. Keep tight. |
| §3 IAU Design | ~1.4 page | The core contribution; gets the most space. |
| §4 Evaluation | ~1.0 page | Measured + projected numbers, plus one sensitivity story. |
| §5 Conclusion | ~0.2 page | One paragraph, no figures. |
| **Sum** | ~4.0 pages | Leaves margin for one wide figure. |

Figures budget (max 4 in CAL): (F1) Per-IO cycle decomposition stacked bar, baseline vs IAU. (F2) IAU block diagram in the uncore. (F3) IOPS / cycles-per-IO vs queue-depth across modes. (F4) Sensitivity / scaling plot.

---

## Writing-style guardrails (apply to every paragraph in `PAPER_DRAFT.md`)

These rules are author-imposed to keep the prose in a recognizable academic register. They apply to the paper draft. Outline notes (this file) may relax them where clarity benefits.

1. Do not use em-dashes "—" as a parenthetical separator. Replace them with full sentences joined by transition words such as "however", "therefore", "moreover", "in particular", "consequently", "rather", or with comma-flanked relative clauses.
2. Do not use colons ":" to introduce lists or examples mid-sentence. Reformulate as two sentences or as a comma-introduced restrictive clause.
3. Do not use parentheses "()" for asides, definitions, or numerical clarifications. Integrate the content into the surrounding sentence, or break it out as a second sentence.
4. Compound modifier hyphens such as "on-die", "100M-IOPS-class", "multi-million" remain in use. The rule above targets the em-dash specifically.
5. Each paragraph in `PAPER_DRAFT.md` is written as a single physical line with no soft wraps, so it copies cleanly into the manuscript.
6. Maintain academic style throughout. Avoid first-person plural rhetorical flourishes unless reporting authorial action ("we measure", "we propose").
7. Avoid hard-to-understand abstractions that obstruct the reader. Replace dense jargon such as "per-I/O floor", "structural ceiling", "execution-truth", "saturation point" with the concrete behavior the term describes, for example "every additional IOPS demanded adds a fixed number of CPU cycles to the I/O path" or "doubling the IOPS demand doubles the CPU cycles consumed by the I/O path". A useful test is whether a reader who has only read §1 can understand the sentence on first pass; if not, rewrite in plainer terms. When a coined term is genuinely needed for the rest of the paper, define it in the same sentence it first appears.

---

## §1. Introduction

### 1.1 What to write (content brief)

A five-paragraph introduction that argues the thesis: *at multi-million-IOPS scale, the host CPU is the structural bottleneck, and the natural fix is to move per-IO queue execution into the CPU uncore.* Each paragraph plays a specific role in the argument; do not blend roles across paragraphs.

**Paragraph 1 — Device supply trend and the under-explored CPU consumer (~8 sentences).**
- Open with the AI retrieval workload class. Name billion-scale ANN over NAND-resident indices and retrieval-augmented generation, citing `diskann`, `spann_neurips21`, and `ragx_isca25`. Identify the access pattern as small random reads of 4 to 16 KB at multi-million IOPS rates.
- Anchor the device-side roadmap with two named sources to stay within P1's word budget. Kioxia's 100M-IOPS-class FMS 2025 prototype provides the single-vendor anchor (`kioxia_fms2025`). Micron's recently disclosed 230M-IOPS single-server demonstration over 44 Gen6 SSDs provides the multi-vendor anchor (`Meredith25`, citation key to be added; URL is the Micron Technology Blog SC25 entry). NVIDIA's StorageNext rationale (`Newburn25`) is held for §5 if word budget permits; it is not load-bearing in §1.
- Pivot the argument from supply to consumption. State that the open question is no longer whether devices can supply MIOPS but which compute substrate can consume them.
- Acknowledge the GPU-side research line as the studied consumer, citing `bam_asplos23` and `gids_vldb24`. Frame this honestly. Streaming-multiprocessor parallelism naturally absorbs the IOPS, yet such designs serve only GPU-resident consumers and require application rewrites.
- Close with the gap claim that motivates the paper, and **pre-distinguish the kind of CPU work the paper is about**. The CPU consumption path remains structurally under-explored at this regime even though it still handles control planes, retrieval orchestration, RAG-as-a-service serving, and the vast majority of general-purpose I/O. By "CPU consumption" we specifically mean the on-die CPU that acts as the NVMe initiator, **regardless of whether that die is the host x86 or an accelerator-attached SoC reached over PCIe**; §1 ¶3 returns to this distinction when it addresses off-die offload responses.
- Note for downstream paragraphs. P1 now carries the GPU-initiated work as the studied alternative consumer rather than as a critique target. P3 is correspondingly narrowed to off-die CPU-side responses (DPU, IPU, FPGA NVMe controllers) and is reframed so that IAU is **composable with** those designs rather than competing with them, since the on-die initiator bottleneck reappears wherever the consumer CPU lives.

**Paragraph 2 — The host CPU wall, evidenced from the external literature (~6 sentences).**
- Open with the per-I/O cycle-budget framing so the bridge from ¶1 is not abrupt. At multi-million-IOPS rates, the per-I/O cycle budget on a modern host CPU under user-space polled frameworks (SPDK) and kernel-side polled paths (io_uring with SQPOLL) is no longer dominated by the syscall, interrupt, and scheduler costs of earlier kernel-driven NVMe; what remains is a residual per-I/O cost that no further driver work can lift. No citation is needed for this framing; it is the standard view of modern NVMe software.
- Anchor the magnitude with **two peer-reviewed measurements**, deliberately not our own simulation and not vendor marketing. First, on a 64-core server driving eight Gen4 NVMe SSDs at 12 M IOPS under SPDK, **the I/O path itself consumes ~6,500 of the ~13,000 CPU cycles available per I/O at this rate**, leaving only the other half for actual application work (cite `haas_vldb23`). State the setting explicitly (64 cores, 8 SSDs, 12 M IOPS) so the reader is not left wondering "half of how many cores on what CPU"; per-I/O cycle accounting is more legible than per-core fractions and matches the vocabulary used in §2.3 and §4. Second, optimized kernel-NVMe paths such as i10 confirm that this residue is not driver bloat, since they approach SPDK-class latency yet still pay the same per-I/O architectural costs in a different layer (cite `i10_atc19`). The two anchors are complementary — Haas gives the quantitative magnitude, i10 gives the architectural unavoidability — and together they triangulate the wall without requiring the cross-API ratio source (`spdk_modern_apis`), which would duplicate the Haas finding. We deliberately do not cite SPDK vendor marketing benchmarks; their reported per-IO budgets (~270–400 cycles/IO on 21-SSD synthetic benchmarks) are unrepresentative of realistic workloads and would invite the false rebuttal that no hardware help is needed.
- Specific structural-cause claim, replacing the older vague "structural" wording. The cost is **intrinsic to the NVMe queue execution model**, in which every I/O requires PRP-list construction from a DRAM-resident submission-queue entry, tracker and state-deallocation bookkeeping for the per-I/O command-identifier lifecycle, and a coherence-paying poll on a DMA-invalidated completion cacheline. These costs combine two compounding components, namely a control-plane instruction count that no leaner driver can eliminate together with memory-hierarchy and signaling-fabric effects arising from DRAM-resident queue metadata, DMA-invalidated cachelines, and MMIO ordering serialization.
- Close by **naming the wall** so ¶3 can refer back to it cleanly. This combination constitutes the host CPU wall, a per-I/O floor that scales with IOPS and cannot be reduced by software alone. The simulator-side per-stage decomposition is **not mentioned in ¶2**; it is deferred to §2.3, which carries the simulation evidence on its own without needing a forward-reference sentence in the introduction.

**Paragraph 3 — MOVED to §2.2 Para B on 2026-05-16. The remaining content in this section is historical and kept only for context; do NOT draft an §1 P3 prose paragraph from it.**

The detailed acknowledge-and-qualify treatment of DPUs / IPUs and FPGA NVMe host controllers, plus the scope-mismatch closer, now lives in §2.2 Para B (see §2 outline below). §1 itself drops to **three paragraphs**: P1 (device supply trend), P2 (host CPU wall), and a renumbered P3 = former P4 (IAU proposal + contributions). The new P3 opens with a **single-sentence forward reference** to §2.2 Para B that preserves the contrastive scope-mismatch closer for a reader who reads §1 alone:

> "Existing hardware proposals discussed in §2 close this wall only inside specific deployments — DPU offload for disaggregated storage and FPGA NVMe controllers for fabric-replaced hosts — and the general-purpose server with direct-attached NVMe at multi-million-IOPS rates remains unaddressed."

That sentence is followed immediately by the IAU proposal sentences (see "Paragraph 4 — IAU proposal..." below, which is now P3 in the actual paper structure). The §2.2 Para B brief carries all the reasoning that used to live in this section — the "acknowledge in good faith, qualify in the same sentence" pattern, the citations (`bluefield3`, `nvme_host_accel`, `nvmecha`, `directnvm`), and the prohibition on cost-migration framing. Consult §2.2 Para B in this outline before drafting the corresponding §2 prose in `PAPER_DRAFT.md`.

Why this move: §2 is the natural home for the survey content. Keeping it in §1 made the introduction a 4-paragraph survey + proposal structure, while §2 stayed at 3 paragraphs; the new layout gives §1 a tighter 3-paragraph arc (problem → wall → proposal) and gives §2 the room for a proper "state of the art + measurement" structure that a CAL background section should have.

---

**Historical content (the original §1 P3 brief, preserved for reference; do not act on it):**

P3 was previously merged with the IAU proposal; the proposal moved to P4 on 2026-05-16. P3's job is now narrow and singular: survey the off-host hardware responses, show what each one does address, and show where the gap remains. P3 does NOT propose IAU, name the four BAR0 primitives, or carry the IMC analogy — those live in P4.

The logic chain inside this paragraph is locked. Follow it strictly when revising the prose, because changing the order rebuilds the reviewer attack surface that the current ordering closes:

1. **Bridge from P2's wall.** Say plainly that the wall has motivated a body of hardware work that aims to move I/O execution off the host CPU. This sets up the rest of the paragraph as a discussion of related work the reviewer expects, rather than as a vendor list dropped without setup.
2. **Acknowledge each external category in good faith, then qualify it in the *same* sentence.** This is the key change. Do not dismiss these designs by saying they "target adjacent problems"; instead, name what they do address and then state what they leave on the table.
   - DPUs and IPUs such as BlueField and Mount Evans take some of the storage and network stack off the host by running NVMe-over-Fabrics initiators and infrastructure services on a separate Arm SoC (cite `bluefield3`); this helps when storage is disaggregated, but it leaves direct-attached NVMe on the host CPU unchanged.
   - FPGA NVMe host controllers such as NVMeHA, NVMeCHA, and DirectNVM go further by running the entire NVMe initiator in fabric (cite `nvme_host_accel`, `nvmecha`, `directnvm`); this eliminates per-I/O CPU work in CPU-constrained appliances and embedded systems, but it requires the host's general-purpose stack to be replaced wholesale, which is not viable on servers that continue to run POSIX, io_uring, and SPDK.
3. **Close the DPU/FPGA rebuttal with scope mismatch, NOT with a cost-migration claim.** The correct sentence is: "in each case, the design closes the wall only inside the deployment it was built for, namely disaggregated storage for DPU offload and fabric-replaced hosts for FPGA controllers, and the general-purpose server driving direct-attached NVMe at multi-million-IOPS rates remains unaddressed by both categories." Do not claim the wall "migrates to the DPU's CPU" or "reappears on the FPGA's CPU" — these claims are technically wrong for two of the three deployment modes and a careful reviewer will catch them. For BlueField in SNAP mode the host still does NVMe queue execution against the SNAP-emulated controller, so the wall stays on the host. For NVMeHA / NVMeCHA / DirectNVM the per-I/O queue work is done in FPGA *fabric*, not on any CPU, so there is no "CPU" for the wall to reappear on. The only mode where cost migration is correct is app-on-DPU, and that mode is impractical for general-purpose multi-tenant servers — so the scope-mismatch framing covers all three cases cleanly, while cost-migration covers only one. See the analysis written into git history around 2026-05-16.

P3 ends with the scope-mismatch sentence. Do NOT reintroduce a proposal step, a compatibility-mirror sentence, or the IMC analogy here — those steps were intentionally moved to P4 so that P3 reads as a clean related-work paragraph and P4 reads as a clean proposal-and-contributions paragraph.

Why the logic chain matters: the reviewer attack we are most exposed to is "you ignored or mischaracterized DPUs/FPGAs." The current ordering (bridge → acknowledge + qualify in the same sentence → scope-mismatch closer) converts that attack into "they address part of the wall in their deployment, and the part they leave is what P4 fills." Versions of the paragraph that dismissed the external designs ("target adjacent problems", "do not target our problem") were re-opening that attack — see git history of this file.

**Paragraph 4 — IAU proposal and contributions summary (~6 sentences across two short sub-paragraphs). After the 2026-05-16 restructure this is now the third (final) paragraph of §1. The first sentence of this paragraph carries the one-line forward reference to §2.2 Para B (quoted in the P3-MOVED block above); the IAU proposal sentences follow immediately after that reference.**

P4 has two jobs and only two jobs: (a) introduce IAU concretely as the design that fills the gap P3 just identified, and (b) summarize, in two or three sentences, what the rest of the paper proves about IAU and what it leaves open for follow-up work. Detailed per-stage timing breakdowns, BAR0 addressing, and numeric IOPS lift values do NOT belong here; they belong in §2.3, §3, and §4 where the reader has the context to interpret them. This is a CAL paper with a 4-page budget, and P4 is the place to compress, not to enumerate.

1. **Open with the IAU proposal in two sentences.** First sentence names IAU, expands the abbreviation, places it on-die beside the integrated memory controller and PCIe root complex, and states the high-level function (executes the per-I/O NVMe fast path in hardware). Second sentence states the compatibility property in one breath: IAU offloads the per-I/O submission, tracking, and completion work into hardware while preserving the DRAM-resident NVMe queues as a compatibility mirror, so existing I/O paradigms continue to observe a compliant controller. The four BAR0 primitives, the mailbox compact-descriptor format, the SRAM-private execution path, and the io_uring/SPDK enablement details are NOT named here — they live in §3. Sample text already in the draft: "To directly address the host CPU bottleneck, we propose IAU, an I/O Assistant Uncore that sits beside the integrated memory controller and PCIe root complex and executes the per-I/O NVMe fast path in hardware. IAU offloads the per-I/O submission, tracking, and completion work into hardware while preserving the DRAM-resident NVMe queues as a compatibility mirror, so existing I/O paradigms continue to observe a compliant controller." Do not write "located on-die with" — "on-die uncore" is already a tautology and the phrasing reads awkward.
2. **Then a short contributions summary, three sentences, that names platform + best-case improvement + footprint + future work.** This replaces the older four-bullet enumeration (C1 measurement / C2 architecture / C3 modes / C4 evaluation). Avoid "first / second / third" enumeration markers. **Defer the calibration / validity discussion (cycles-per-IO comparison to real-hardware SPDK numbers, SPDK single-qpair citation, AtomicSimpleCPU caveats, NVMeVirt/FEMU methodology defense) entirely to §4 (revised 2026-05-16).** The Introduction's job is now narrow: name the platform and state the headline improvement against the SPDK baseline as a ratio + percentage. Do NOT cite `Yang2017SPDKAD` / Haas / NVMeVirt / FEMU in P4; those belong in §4.1 methodology paragraph and §4.4 threats-to-validity. Do NOT carry the absolute baseline IOPS (0.82 M) or absolute IAU IOPS (1.10 M); those are §4. Do NOT name "mode 0 / mode 1 / mode 2" — simulator codenames. Do NOT name "Storage-Next-class" — project-internal jargon; use "multi-million-IOPS NVMe device model" in the proposal paragraph but the contributions paragraph can also omit the device descriptor since the platform is already named. Cover the three moves below in order, each in one sentence.
   - **Platform + best-case improvement.** State the platform (gem5 + SimpleSSD + SPDK simulator) and the **peak best-case** improvement across our data, expressed as IOPS ratio and cycles/IO percentage reduction. The data peak is **BigANN trace replay at QD=16: 1.44× IOPS and ~30% fewer cycles per I/O** vs the unmodified SPDK baseline; the same lift is reproduced on a synthetic 4 KB random read workload. Sample text in current draft: "On a full-system gem5, SimpleSSD, and SPDK simulator, IAU delivers up to 1.44× IOPS and ~30% fewer cycles per I/O over an unmodified SPDK baseline on a DiskANN BigANN trace replay, with the same lift reproduced on a synthetic 4 KB random read workload." The "up to" qualifier is load-bearing: the peak is at QD=16, the ratio drops to 1.35× at QD=128. Do NOT replace "~30%" with a more precise number unless the §4 table cites the same one; "up to 1.44×" + "~30%" is the cleanest peak-headline framing.
   - **What we synthesize (the silicon plausibility).** RTL synthesis at ASAP7 7nm across four queue-resource configurations (16 / 64 QPs × QD 64 / 128) yields an uncore-scale footprint of 30 K to 93 K standard cells, 0.1 to 0.9 mm² of on-die SRAM, and 14 to 49 mW of post-synthesis logic power at 1 GHz. These three numbers (cells, SRAM, power) ARE allowed in P4 — they are the silicon-feasibility anchor that justifies "uncore" placement. Do NOT cite post-synthesis Fmax in P4: the SYNTHESIS_RESULTS.md log itself flags the 150–204 MHz post-synthesis Fmax as a lower bound pending P&R buffer insertion, and quoting it in P4 without that caveat would invite a "your design doesn't meet timing" attack. Place-and-route (silicon µm² area, routed timing closure, post-CTS power) is out of scope for this paper.
   - **What we leave open.** Even at the lifted ceiling, residual host-side polling remains the bottleneck, and one additional NVMe-compliant offload primitive — a hardware completion-callback dispatcher — is identified in the design and explicitly deferred to future work. This sentence is load-bearing: it tells the reviewer where the paper stops and signals that the authors understand the next step. Do NOT phrase this as "mode 2 becomes the new saturation point" — same naming reason as above. State it as "residual host-side polling" so the language matches §2.1.
3. **Optionally close with the IMC analogy in one sentence**, if word budget permits. This applies to NVMe the same placement-based fix the industry used when the off-die memory controller became a similar bottleneck two decades ago (cite `opteron_imc`, `five_minute_rule_30`). The analogy was previously the last sentence of P3 (when P3 carried the proposal); it now belongs in P4 because it is a comment on the proposed design, not on external accelerators. If P4 is over budget, drop the IMC sentence — §3.1 can carry it instead. Current draft has the analogy dropped.

Why this compression matters: a contributions paragraph in a 4-page CAL introduction has to read like a promise list (what the paper delivers, in summary form), not like an abstract-in-the-introduction (where every result is restated with its number). Reviewers skim P4 to learn whether the paper's claims are within the page budget; they will read the actual values in §2.3 and §4. Putting the values in both places duplicates content and burns word budget that P3 needs for the related-work qualifications.

### 1.2 Logic chain (how the paragraphs deliver the argument)

**Restructure note (2026-05-16):** §1 now has **three paragraphs**, not four. The former P3 (external accelerators) moved to §2.2 Para B. The former P4 (IAU proposal + contributions) is now §1 P3 and opens with a single-sentence forward reference to §2.2 Para B before the proposal sentences.

```
P1: device supply trend exists
    GPU consumer is studied
    CPU consumer is under-explored          ─► "the open question is CPU consumption,
                                                regardless of which die hosts the initiator"
                                          │
                                          ▼
P2: CPU consumption hits the host CPU wall ─► "even SPDK leaves only ~6,500 cycles/IO
    (evidenced by two peer-reviewed anchors,     for application work at 12 M IOPS, and
    Haas VLDB 2023 + i10 ATC 2019)               the residue is intrinsic to the NVMe
                                                queue execution model rather than driver
                                                bloat — control-plane instruction count
                                                + memory-hierarchy / signaling-fabric"
                                          │
                                          ▼
P3: our proposal and contributions summary  ─► [opens with §2 forward reference]
    (formerly P4; the §2.2-Para-B forward       "Existing hardware proposals discussed
    reference replaces what used to be P3.       in §2 close this wall only inside
    Detailed DPU/FPGA acknowledge-and-qualify    specific deployments — DPU offload for
    discussion is in §2.2 Para B.)               disaggregated storage and FPGA NVMe
                                                controllers for fabric-replaced hosts —
                                                and the general-purpose server with
                                                direct-attached NVMe at multi-million-
                                                IOPS rates remains unaddressed."
                                                [then the proposal sentences:]
                                                "We propose IAU, an on-die I/O Uncore
                                                that executes the NVMe fast path in
                                                hardware while DRAM rings remain a
                                                compatibility mirror. On a full-system
                                                gem5 + SimpleSSD + SPDK simulator, IAU
                                                delivers up to 1.44× IOPS and ~30%
                                                fewer cycles/IO over an unmodified
                                                SPDK baseline on a DiskANN BigANN trace
                                                replay, reproduced on a synthetic 4 KB
                                                random read workload. Synthesis at
                                                ASAP7 7nm gives an uncore-scale
                                                footprint (30-93 K cells, 0.1-0.9 mm²
                                                SRAM, 14-49 mW logic). Residual host-
                                                side polling is the new bottleneck and
                                                a HW completion-callback dispatcher is
                                                deferred to future work."

(Validity discussion - cycles/IO calibration against published SPDK measurements,
AtomicSimpleCPU caveats, NVMeVirt/FEMU methodology defense - moved entirely
to §4.1 and §4.4 on 2026-05-16. P4 now only states platform + headline ratio.)
```

Each transition is mandatory.
- P1 to P2. Without P2, P1 is a demand statement with no consequence. P2 supplies the host CPU wall, using two complementary peer-reviewed anchors — Haas VLDB 2023 for the quantitative magnitude (on a 64-core, 8-SSD Gen4 server under SPDK at 12 M IOPS, the I/O path itself consumes ~6,500 of the ~13,000 cycles available per I/O) and i10 ATC 2019 for the architectural unavoidability (kernel optimization cannot close the gap) — and characterizes the residue as intrinsic to the NVMe queue execution model rather than as software bloat. P2 opens by introducing the per-I/O cycle-budget framing under modern SPDK / io_uring before stating the wall, so the bridge from P1's "CPU consumption path is under-explored" is gradual rather than abrupt.
- **P2 to P3 (restructured 2026-05-16).** P2 ends by naming the host CPU wall. After the restructure, §1's P3 is now the *proposal* paragraph (formerly P4), so the bridge is not into a related-work paragraph but into a one-sentence forward reference plus the IAU proposal. The opening sentence of §1 P3 is "Existing hardware proposals discussed in §2 close this wall only inside specific deployments — DPU offload for disaggregated storage and FPGA NVMe controllers for fabric-replaced hosts — and the general-purpose server with direct-attached NVMe at multi-million-IOPS rates remains unaddressed." This sentence does the same scope-mismatch closer the former P3 used to do, in one sentence, so that a reader of §1 alone still sees the gap clearly. The detailed acknowledge-and-qualify treatment of DPUs / IPUs and FPGA NVMe host controllers now lives in §2.2 Para B; do not re-derive it in §1. **Historical-note (do not act on):** the older form of this paragraph was a related-work paragraph that immediately followed P2 with "this wall has motivated several lines of hardware work..." That paragraph is now §2.2 Para B and starts with the same bridge sentence; see §2 outline for the full brief. P3 then acknowledges each external category in good faith and qualifies it in the same sentence: DPU/IPU help when storage is disaggregated (NVMe-oF) but leave direct-attached NVMe on the host unchanged, and FPGA NVMe controllers eliminate per-I/O CPU work in fabric but require the host stack to be replaced wholesale (which is not viable on servers running POSIX, io_uring, and SPDK). P3 then closes with a scope-mismatch sentence: in each case, the design closes the wall only inside the deployment it was built for, and the general-purpose server with direct-attached NVMe at MIOPS rates remains unaddressed. P3 stops there. The IAU proposal, the compatibility-mirror statement, and the IMC analogy were previously in this paragraph but were moved to P4 on 2026-05-16; P3 is now a clean related-work paragraph and P4 is a clean proposal-plus-contributions paragraph. The "acknowledge in good faith, qualify in the same sentence" pattern is deliberate: earlier drafts that dismissed external designs as targeting "adjacent problems" re-opened the reviewer attack "you mischaracterize what BlueField/NVMeHA are for", and the qualify-in-same-sentence form forecloses it without conceding ground. Earlier drafts also used a cost-migration sentence ("the wall reappears on the DPU's / FPGA's CPU") that was technically wrong for two of three deployment modes (BlueField SNAP keeps the wall on the host; FPGA NVMe controllers run the queue in fabric not on a CPU); the scope-mismatch sentence above covers all three cases cleanly and is the form used now.
- **Inside §1 P3 (proposal + contributions, renumbered 2026-05-16; was P4).** The paragraph opens with the one-sentence forward reference to §2.2 Para B (quoted above in the P2 → P3 bridge), then directly states the proposal: "to directly address the host CPU bottleneck, we propose IAU…". The reader has just been told the gap is the general-purpose server with direct-attached NVMe at MIOPS rates, and the proposal sentence is the design that fills it. After the two proposal sentences, P3 pivots to a three-sentence contributions summary that names (1) platform + peak best-case improvement against the SPDK baseline (1.44× IOPS / ~30% cycles/IO reduction on BigANN at QD=16, reproduced on synthetic 4 KB random read), (2) ASAP7 7nm RTL footprint (30-93 K cells, 0.1-0.9 mm² SRAM, 14-49 mW logic), and (3) what we leave open (residual host-side polling at the lifted ceiling, a hardware completion-callback dispatcher deferred to future work). What stays deferred from §1 P3 (revised 2026-05-16): absolute baseline IOPS (0.82 M) and absolute IAU IOPS (1.10 M) go to §4.2/§4.3; cycles/IO calibration against published SPDK single-qpair measurements goes to §4.1 methodology and §4.4 threats-to-validity; per-stage nanosecond breakdowns (337 / 218 / 295 ns) go to §2.3; the full QD-sweep curve goes to §4; post-synthesis Fmax stays out of the paper entirely (see §3.4 "what NOT to put"). The Introduction's job is now narrow: state the platform and the headline ratio + percentage, defer all validity discussion to §4. The "what we leave open" sentence — residual host-side polling at the lifted ceiling and the one deferred mechanism — is load-bearing because it signals to reviewers that the paper is honest about where it stops.

### 1.3 Evidence anchors (must be cited inside §1)

| Claim | Evidence anchor |
|---|---|
| MIOPS demand from AI retrieval | `diskann`, `spann_neurips21`, `ragx_isca25` |
| 100M-IOPS device prototype, Kioxia anchor | `kioxia_fms2025` |
| 230M-IOPS single-server demonstration, Micron anchor | `Meredith25`, Micron Technology Blog SC25 entry, citation key to be added to `paper.bib` |
| GPU-initiated NVMe as the studied alternative consumer | `bam_asplos23`, `gids_vldb24` |
| On a 64-core server driving 8 Gen4 NVMe SSDs at 12 M IOPS under SPDK, the I/O path consumes ~6,500 of the ~13,000 CPU cycles available per I/O, leaving the other half for application work | `haas_vldb23` (Haas et al., VLDB 2023, "What Modern NVMe Storage Can Do, And How To Exploit It") — **add to `paper.bib`** |
| Kernel-side ultra-low-latency NVMe path retains the same per-I/O architectural costs | `i10_atc19` (Lee et al., AIOS / Async I/O Stack, USENIX ATC 2019) |
| Cross-API SPDK vs io_uring vs libaio characterization, ~10× kernel-side overhead | `spdk_modern_apis` (Didona et al., SYSTOR 2022) — **not cited in §1 ¶2**; the Haas anchor already contains the io_uring/libaio ~10× ratio, so citing both would duplicate the same empirical claim. Retained in `paper.bib` for §2 and §5 use. |
| SPDK vendor marketing benchmarks (10.39M / 120M IOPS) | **Deliberately NOT cited in §1 P2.** Per-IO numbers from those posts are unrepresentative of realistic workloads and invite the false rebuttal "software is already fine." See literature review for the deprecation rationale. |
| DPU/IPU primary goal is infrastructure offload + NVMe-oF | **Moved to §2.3 evidence anchors on 2026-05-16.** §1 P3 keeps a one-sentence forward reference; the full citation lives in §2.2 Para B. Anchor: `bluefield3` |
| FPGA NVMe host controllers target CPU-less appliances and embedded systems | **Moved to §2.3 evidence anchors on 2026-05-16.** §1 P3 keeps a one-sentence forward reference; the full citation lives in §2.2 Para B. Anchors: `nvme_host_accel`, `nvmecha`, `directnvm` |
| Scope mismatch closer (in §1 P3 as one sentence) | (argument; the detailed acknowledge-and-qualify framing lives in §2.2 Para B, not §1) |
| IMC placement-fix analogy | `opteron_imc`, `five_minute_rule_30` |
| Our own measurement (Mode 0 saturation, Mode 2 lift, BigANN replay) | **Deferred to §2.3 / §4** — not used as motivation in §1. Sources: `paper_qdsweep_mode0/1/2_20260510`, `paper_trace_mode0/2_20260510`, `mq_trace_sweep_qd128_mode2_v4` |

---

## §2. Background

### 2.1 What to write (content brief)

§2 is reformatted (2026-05-16) into **three numbered subsections** (§2.1 / §2.2 / §2.3) instead of three unbroken paragraphs. The change does two things at once: it (a) absorbs the detailed DPU / FPGA discussion that previously lived in §1 P3 so §1 can compress to three paragraphs (P1, P2, P4-renumbered-as-P3), and (b) lets the empirical cycle-breakdown stand as its own bridge subsection between literature background and §3's design.

The overall job of §2 is unchanged: make §3 readable without relitigating §1's motivation. Total page budget for §2 is **~0.7 columns of body text plus one stacked-bar figure** (kept tight to leave §3 the largest section).

**§2.1 The NVMe queue execution model (~6 sentences, no figure).**
- Define the data structures: per-controller submission queues (SQ) and completion queues (CQ), each a ring buffer in host DRAM with head/tail pointers; one SQ doorbell and one CQ doorbell per queue, mapped into BAR0.
- Describe the I/O lifecycle in one sentence: host formats a 64-byte SQE (incl. PRP/SGL list for the data buffer) → writes it into the SQ ring → MMIOs the SQ tail doorbell → device DMAs the SQE, executes the command, DMAs the data, writes a 16-byte CQE into the CQ ring, asserts the phase bit, optionally fires MSI-X → host polls (or interrupts on) the CQ, observes the new phase bit, completes the request, MMIOs the CQ head doorbell.
- Identify the *per-IO recurring costs* explicitly, labeling them so later subsections and §3 can refer back without re-naming them: **(a)** MMIO doorbell writes are uncacheable-WC and serialize; **(b)** CQ polling reads device-written cachelines that are perpetually invalidated by DMA; **(c)** DRAM-resident SQ/CQ metadata (head/tail, phase, credits) consumes memory bandwidth proportional to IOPS; **(d)** ordering fences and the PCIe posted-write ordering rules force serialization.
- Close with a one-sentence signal that every move in §3 maps to one of (a)–(d), and that §2.3 will quantify which of (a)–(d) carries the biggest per-IO cost under SPDK.

**§2.2 The state of the art at multi-MIOPS scale (~9 sentences in two short paragraphs, no figure).**

This is a single subsection with two paragraphs (Para A on poll-mode software, Para B on external hardware). It is **not** split into §2.2 / §2.3 because (i) the two together act as one "what exists today" survey and (ii) keeping it as one subsection saves a header line in the page budget.

*Para A — Poll-mode software (~4 sentences).*
- State the framing: SPDK is not chosen because it is easy to beat; it is chosen because it is the *best-case software baseline* — user-space polling, hugepage-resident buffers, no syscalls, no interrupts.
- One-sentence consequence: any residual cost observed under SPDK reflects fundamental host-side execution costs, not Linux/driver inefficiency.
- One-sentence caveat naming io\_uring with SQPOLL as qualitatively identical at the MIOPS regime, treated as a cross-check; cite `i10_atc19` for the kernel-side ultra-low-latency stack that confirms the per-IO architectural cost is not driver bloat.
- One transition sentence: even with the best poll-mode software, every IO still pays (a)–(d) from §2.1. The natural next question is whether existing hardware approaches close that gap.

*Para B — External hardware approaches (~5 sentences, lifted and tightened from former §1 P3).*
- Open with the bridge that this paragraph used to play in §1: "the wall has motivated several lines of hardware work that aim to move I/O execution off the host CPU." This sentence is mandatory so the reader does not read the paragraph as a vendor list dropped without setup.
- DPUs and IPUs such as BlueField and Mount Evans take some of the storage and network stack off the host by running NVMe-over-Fabrics initiators and infrastructure services on a separate Arm SoC (cite `bluefield3`); this helps when storage is disaggregated, but it leaves direct-attached NVMe on the host CPU unchanged.
- FPGA NVMe host controllers such as NVMeHA, NVMeCHA, and DirectNVM go further by running the entire NVMe initiator in fabric (cite `nvme_host_accel`, `nvmecha`, `directnvm`); this eliminates per-I/O CPU work in CPU-constrained appliances and embedded systems, but it requires the host's general-purpose stack to be replaced wholesale, which is not viable on servers that continue to run POSIX, io\_uring, and SPDK.
- **Close with scope-mismatch, not cost-migration.** "In each case, the design closes the wall only inside the deployment it was built for, namely disaggregated storage for DPU offload and fabric-replaced hosts for FPGA controllers, and the general-purpose server driving direct-attached NVMe at multi-million-IOPS rates remains unaddressed by both categories." Do **not** claim the wall "migrates to the DPU's CPU" or "reappears on the FPGA's CPU" — those claims are technically wrong for two of the three deployment modes (BlueField SNAP keeps the wall on the host; NVMeHA/NVMeCHA/DirectNVM run the queue in fabric not on any CPU) and a careful reviewer will catch them. The scope-mismatch framing covers all three cases cleanly. This entire qualify-in-the-same-sentence pattern was iterated to its current form on 2026-05-16; see git history of this file for the reasoning.

*Note for §1 P3 (now P3-renumbered).* When this paragraph moved here, §1 lost its DPU/FPGA paragraph. §1 P4 picks up the gap with a one-sentence forward reference ("existing hardware proposals discussed in §2 close this wall only inside specific deployments; the general-purpose server with direct-attached NVMe remains unaddressed"); the detailed acknowledge-and-qualify treatment lives only here in §2.2 Para B.

**§2.3 Per-IO cost characterization on the simulator (~5 sentences + 1 stacked-bar figure).**

This subsection carries the simulation evidence that motivates §3's design moves. It is intentionally its own subsection rather than folded into §2.2 because (i) it is our own gem5 measurement, not background literature, and (ii) the stacked-bar figure is the visual bridge from §2 background to §3 design — a reader who jumps from §3 back to "where do these numbers come from" lands here cleanly.

- **Open by stating the role of this subsection.** §1 P2 established, from peer-reviewed external measurements, that the host CPU is the structural bottleneck at MIOPS scale; §2.3 now quantifies *which stages within the per-IO budget consume that bottleneck* under a controlled gem5 + SimpleSSD + SPDK measurement.
- **Present the measured per-IO decomposition** at QD=128 as a stacked bar (Fig.~\ref{fig:cycle_breakdown}, generated by `scripts/plot_cycle_breakdown.py`): PRP-list construction ~337 ns, tracker bookkeeping ~218 ns, state dealloc ~295 ns, polling+doorbell+ordering ~370 ns, other ~140 ns; total ~1.36 µs per IO. **Data-anchor update (2026-05-16, resolved):** the `paper_qdsweep_mode0_20260510` tag and the current `results/rand4k_1c1qp/rand4k_mode0_20260510/` directory are the **same runs** (the folder was moved and renamed; underlying simulation outputs are identical), so the breakdown numbers above are valid as-is. The IOPS saturation curve (776 K @ QD=16 → 819 K @ QD=128 ≈ 0.82 M peak) is sourced from `results/rand4k_1c1qp/rand4k_mode0_20260510/core0_qp1/phase1_results.csv`.
- **State the saturation-shape finding alongside the decomposition.** Single-core IOPS saturates at ~0.82 M and the saturation point is essentially flat across QD, confirming the cost is per-IO structural rather than per-batch amortized.
- **Classify the stages as elidable vs intrinsic.** PRP construction, tracker alloc/dealloc, doorbell-MMIO, fence-induced serialization, and the CQ scan are elidable in hardware; payload DMA is not. This sentence is the explicit bridge to §3: §3 elides exactly the elidable stages while preserving NVMe semantics.
- **One sentence on calibration positioning.** This budget places each per-IO stage at hundreds of nanoseconds on a 2 GHz simulated AtomicSimpleCPU (no L1/L2 caches modeled), placing total cycles/IO in the same order of magnitude as the published single-qpair single-drive SPDK figures (cite `Yang2017SPDKAD` and the §4.1 methodology discussion); the full calibration discussion and AtomicSimpleCPU caveats live in §4.1 and §4.4 so §2.3 does not relitigate them.

### 2.2 Logic chain

```
§2.1 NVMe queue execution model ──► defines the per-IO recurring costs (a)-(d) that §3 must
                                    eliminate; the four labels are reused by name in §3
                              │
                              ▼
§2.2 State of the art at MIOPS ──► (Para A) poll-mode software (SPDK + io_uring) is the
                                    best-case software baseline; the residue under SPDK is
                                    not driver bloat.
                                   (Para B) external hardware (DPU/IPU, FPGA NVMe controllers)
                                    each close the wall only inside their own deployment;
                                    the general-purpose server with direct-attached NVMe at
                                    MIOPS rates remains unaddressed.
                              │
                              ▼
§2.3 Per-IO cost characterization ──► our gem5+SimpleSSD+SPDK measurement quantifies WHICH
                                       stages of (a)-(d) carry the cost; the stacked-bar figure
                                       is the visual bridge from §2 background to §3 design.
                                       Total cycles/IO are calibrated against published SPDK
                                       single-qpair anchors (Yang2017SPDKAD) — full calibration
                                       defended in §4.1 / §4.4, not relitigated here.
```

Each transition is mandatory:
- §2.1 → §2.2 Para A. The (a)–(d) labels in §2.1 are what Para A says "even the best software still pays." Without the labels in §2.1, Para A's framing has no anchor.
- §2.2 Para A → Para B. The transition sentence at the end of Para A ("the natural next question is whether existing hardware approaches close that gap") is what makes Para B read as a survey rather than a vendor list.
- §2.2 Para B → §2.3. Para B's scope-mismatch closer ("general-purpose server with direct-attached NVMe at MIOPS rates remains unaddressed") is what §2.3 then quantifies: on exactly that platform, where do the cycles go?
- §2.3 → §3. §2.3 ends with the elidable-vs-intrinsic classification, which is the sentence §3.1 picks up to introduce IAU's design moves.

### 2.3 Evidence anchors

| Claim | Evidence anchor |
|---|---|
| NVMe semantics + queue execution model | `nvme_spec_2_0d`, `nvme_spec_formal` |
| SPDK as best-case poll-mode software baseline | `spdk_docs`, `Yang2017SPDKAD` |
| io\_uring SQPOLL qualitative parity / kernel-side ultra-low-latency stack | `i10_atc19` |
| DPU/IPU primary goal is infrastructure offload + NVMe-oF (not local-NVMe per-IO acceleration). Moved from §1 to §2.2 Para B on 2026-05-16 | `bluefield3` |
| FPGA NVMe host controllers target CPU-less appliances / embedded systems where the host is too constrained to drive NVMe in software. Moved from §1 to §2.2 Para B on 2026-05-16 | `nvme_host_accel`, `nvmecha`, `directnvm` |
| Scope mismatch (do NOT use cost-migration framing) | (argument, derived from the two anchors above) |
| Per-IO cycle decomposition (PRP ~337 / tracker ~218 / dealloc ~295 / polling+DB ~370 / other ~140 ns) + ~0.82 M IOPS saturation flat across QD | `results/rand4k_1c1qp/rand4k_mode0_20260510/core0_qp1/phase1_results.csv` (this directory is the renamed/moved location of the older `paper_qdsweep_mode0_20260510` runs; underlying simulation outputs are identical, so the breakdown numbers are valid as-is). Cross-checked qualitatively against `results/bigann_trace_1c1qp/paper_trace_mode0_20260510/`. Plot rendered by `scripts/plot_cycle_breakdown.py`. |
| Total cycles/IO calibration against real-hardware SPDK single-qpair single-drive | `Yang2017SPDKAD` (the full calibration argument lives in §4.1 / §4.4, not here) |

### 2.4 What NOT to put in §2

- **No related-work taxonomy as a separate §RW.** CAL has no room. The DPU/IPU + FPGA discussion lives compressed in §2.2 Para B; do not promote it to its own subsection.
- **No motivation re-statement.** The "wall" claim was made in §1; §2 only supplies the mechanics needed to read §3.
- **No PCIe internals** beyond the (a)–(d) labels and the posted-write / ordering one-liner.
- **No mode-0/1/2 naming, no "mailbox-assisted" naming.** Those are simulator-internal codenames. In §2.3 the baseline is "the unmodified SPDK baseline" or "vanilla SPDK"; the IAU comparison is reserved for §3 and §4.
- **No post-synthesis Fmax.** Synthesis numbers do not appear in §2 at all; they live in §3.5 and §4.4. §2 is software/measurement, not silicon.
- **No re-derivation of the cycles/IO calibration argument.** §2.3 may *mention* the calibration in one sentence with a forward reference to §4.1, but the full discussion (AtomicSimpleCPU vs OoO, single-qpair anchor selection, NVMeVirt/FEMU methodology defense) lives in §4.1 and §4.4. Putting it in §2.3 burns page budget that §3 needs.

---

## §3. IAU: A Host-Integrated I/O Uncore

### 3.1 What to write (content brief)

The longest section of the paper. Five subsections, each tightly scoped. Goal: a reader who has only read §1–§2 should, by the end of §3, be able to (a) draw the block diagram from memory, (b) explain why each mechanism exists in terms of the §2.1 cost list (a)–(d), and (c) believe the design is NVMe-compliant.

**§3.1 Placement and principle (~7 sentences).**
- State the placement: an I/O Uncore block (IAU) co-located with the IMC and PCIe root complex on the CPU die, shared across cores within a chiplet (precedent: VMD already lives there for PCIe enumeration; cite `intel_vmd`).
- State the principle: **architectural truth ≠ execution truth.** Software and the NVMe spec continue to observe DRAM-resident SQ/CQ rings, MSI-X interrupts, and standard head/tail semantics. The uncore privately executes the hot path from SRAM-resident state and updates DRAM rings *in batches* purely as a compatibility mirror.
- One-sentence implication: POSIX / io_uring / SPDK are unchanged; only the NVMe driver (or SPDK NVMe library) needs to know IAU exists, and only at queue-setup time.
- **State the application / protocol boundary explicitly (one sentence, added 2026-05-17 in response to the §2.3 "why isn't the IAU residual zero?" question).** IAU offloads the *NVMe-protocol portion* of every per-IO stage — the 64-byte SQE encoding, the PRP / SGL list construction, the command-ID lifecycle and CQE parse, the SQ and CQ ring slot management, and the doorbell-MMIO ordering. IAU does **not** absorb the *application portion* of any stage — the compact mailbox descriptor that describes the I/O (LBA, length, target buffer pointer), the in-flight handle that carries the user callback pointer and user context, the mailbox-MMIO notification that wakes the uncore, the callback execution itself, and the return of the data buffer to the application-side mempool — because those operations belong to the application and would change application semantics if moved off-CPU. This boundary is what the non-zero IAU residuals on Fig.~\ref{fig:cycle_breakdown} represent, and §3.3 walks through each mechanism's offload-vs-residual split in the same terms.
- Figure F2 belongs here: block diagram showing IAU sitting between SPDK library and PCIe root complex, with private SRAM, the four sub-blocks, and the DRAM mirror.

**§3.2 The three-mode continuum (~10 sentences).**
- Frame the modes as three *operating points on one architecture*, not three architectures. This pre-empts the reviewer attack "you have three designs; pick one."
- **Mode A — Shadowed Rings (transparent).** SPDK is unchanged. Software writes SQEs to DRAM and polls DRAM CQs as usual. The uncore observes SQ writes/doorbells, executes queue semantics in SRAM, and batches DRAM-visible CQE/pointer updates. *Demonstrates: a lower bound of the architecture under unmodified software.*
- **Mode B — Mailbox + Mechanisms (poll-lite).** SPDK is patched at one isolated function (~45 LOC) to (i) write a compact 24-byte SQE descriptor into an uncore mailbox region (BAR0+0x3000) for the I/O fast-path, (ii) read a per-queue free-CID slot via MMIO instead of maintaining a software free-tracker list, (iii) read a per-queue in-flight counter, and (iv) consult a typed "readiness hint" register before scanning the DRAM CQ. *Demonstrates: the upper bound achievable under minimal SPDK enablement.*
- **Mode C — Logical Rings in SRAM (future / ceiling).** DRAM rings updated only at quiescence / debug / interrupt-per-batch points. *Demonstrates: the silicon-sizing ceiling; not the primary experimental target of this paper.*
- One-sentence claim: keeping all three modes is what avoids an all-or-nothing reviewer attack — the architecture remains valuable even under zero application changes.

**§3.3 Mechanisms inside Mode B (~12 sentences, one per mechanism, plus a wire-format note).**

*Cross-cutting note (added 2026-05-17).* Every mechanism description below should name two things together, namely what the mechanism removes from the host (the NVMe-protocol portion) and what stays on the host as a residual (the application-level portion that cannot be moved off-CPU without changing application semantics). The §3.1 application/protocol-boundary principle establishes the framing; each mechanism in §3.3 then makes the split concrete. This is what answers the "why isn't IAU's residual zero?" reading of Fig.~\ref{fig:cycle_breakdown}.

- *Mailbox SQ engine* — replaces the 64-byte SQE + PRP-list construction + doorbell MMIO with three 8-byte MMIO writes per IO carrying a 24-byte compact descriptor (opcode/flags/cid/nsid/slba/nlb/control). The uncore expands the PRP-list on-die from a pre-registered buffer pool descriptor; this removes the ~337 ns PRP cost and the per-IO doorbell. **Residual on host:** the application still has to *describe* the I/O (LBA, length, target buffer pointer) into the compact mailbox descriptor and still pays one mailbox-MMIO write per IO that wakes the uncore; this residual is application-level and is what stages 1 and 3 in Fig.~\ref{fig:cycle_breakdown} show under IAU. Bullets the wire format briefly (one table row per word). *Falls back to standard 64-byte SQE for admin queue, multi-page transfers, and non-read/write opcodes — preserves NVMe completeness.*
- *Mech #1: Hardware free-CID ring* — replaces the SPDK doubly-linked free-tracker list (`TAILQ_REMOVE` + `TAILQ_INSERT_TAIL` per IO) with one MMIO read that returns the next free CID. The uncore re-recycles CIDs on CQE flush. Removes the ~218 ns tracker bookkeeping cost. **Residual on host:** the application still has to keep a small in-flight handle that carries the user callback pointer and user context, because the callback runs on the host CPU; the uncore manages only the NVMe-protocol command-ID and PRP-table slot.
- *Mech #2: HW queue-depth counter* — exposes the current in-flight count via one MMIO read, replacing software counter maintenance. Small but ~tens of ns; closes a backpressure-correctness loop without per-IO software cost.
- *Mech #4: Typed hint register* — `(count:16, age_units:16)` at BAR0+0x2000. SPDK's polling loop reads one word; when `count==0 && age_units<threshold` SPDK skips the full DRAM CQ scan. Removes most of the ~370 ns polling cost in multi-queue regimes (the cost of "scan many empty queues to find one ready one"). **Residual on host:** the host still has to be *signalled* that completions are available, since the callback runs on the host; the typed hint reduces the polling cost but does not eliminate it, and stage 4 of Fig.~\ref{fig:cycle_breakdown} accordingly stays at the same height in both bars. This is why Mech #3 is the natural next step.
- *Mech #3: HW completion-callback dispatcher* — **deferred.** Mentioned as the path that crosses from control-plane to data-plane offload; not implemented in this paper. The flat Mode 2 IOPS curve across QD identifies Mode 2 as a new CPU-bound ceiling, naming the residual gap to the device ceiling as the future-work envelope for Mech #3. We deliberately do not put a number on that envelope; quantifying it requires implementation and is left as future work.
- *CQ suppression and doorbell aggregation are properties of the uncore, not separate mechanisms* — they are how the uncore *implements* §3.1's "DRAM rings as compatibility mirror." Mention once and move on.

**§3.4 NVMe compliance and the fail-safe (~5 sentences).**
- One sentence on the compliance argument: DRAM rings are kept correct at bounded intervals; OS, drivers, and tooling observe standard NVMe behavior (head/tail semantics, MSI-X, error handling). Mailbox writes are a *side channel*, not a replacement.
- One sentence on debuggability: queue state remains inspectable in DRAM at quiescence; gem5 stats counters expose every uncore action one-for-one.
- One sentence on virtualization correctness: the guest-visible NVMe model is intact (this matters for review-level credibility even though we don't evaluate VMs here).
- Two sentences on the fail-safe: if the uncore stalls or is disabled, DRAM rings remain authoritative and the system falls back to standard software-driven NVMe execution. This is a deployability property, not an evaluation result.

**§3.5 SRAM sizing and silicon plausibility (~6 sentences, with one inline table).**
- Rule-of-thumb numbers: ~4 KB per active SQ, ~4 KB per active CQ, ~2 MB per tile for shared structures (DMA FIFOs, schedulers, telemetry, translation caches).
- Implication: 128–1024 active QPs map to 3–11 MB of SRAM per tile; 16–32 MB only for extreme headroom.
- One sentence on the "active vs allocated" distinction: SRAM scales with *concurrently active* QPs, not configured QPs; embedding-heavy workloads concentrate load on a few hot queues.
- One sentence on scaling caveat: thousands of hot QPs simultaneously *would* push capacity higher; the fix is hierarchical multiplexing or replication across multiple I/O tiles, not a monolithic single tile.
- One sentence pointing forward: RTL synthesis at ASAP7 7nm across four queue-resource configurations confirms an uncore-scale footprint (30-93 K standard cells, 0.1-0.9 mm² of SRAM, 14-49 mW post-synthesis logic power at 1 GHz); place-and-route (silicon µm² area, routed timing closure, post-CTS power) is left as orthogonal future work. Paper-side note: the RTL evidence is now in scope for this submission — the older "Phase 3 is future work" wording in §3.4 / §4.4 / §5 / the cross-cutting checklist has been retired (2026-05-16).

### 3.2 Logic chain

```
3.1 Placement + principle ──► establishes the architectural separation (sw sees DRAM rings,
                              uncore executes from SRAM)
                                          │
                                          ▼
3.2 Three modes as continuum ─► shows the architecture is valuable across the
                                 zero-change → minimal-change → cooperative-change axis
                                          │
                                          ▼
3.3 Mechanisms inside Mode B ──► each mechanism removes one specific §2.1 cost,
                                  with measured-cost-target traceability
                                          │
                                          ▼
3.4 NVMe compliance / fail-safe ──► forecloses correctness, virtualization, deployability attacks
                                          │
                                          ▼
3.5 SRAM sizing ──────────────► forecloses "this is unbuildable" attacks
```

The traceability matrix (must be readable from §3.3 alone):

| §2.1 cost | §3.3 mechanism that elides it | Approx. saving |
|---|---|---|
| (a) MMIO doorbell | Mailbox SQ engine (writes are part of the mailbox path, not separate doorbells) + doorbell aggregation | per-IO MMIO eliminated for I/O fast-path |
| (a) PRP-list construction | Mailbox SQ engine (on-die PRP expansion) | ~337 ns/IO |
| (b) CQ polling overhead | Typed hint register (Mech #4) + CQ suppression | majority of ~370 ns/IO in multi-queue |
| (c) DRAM ring metadata | SRAM-resident head/tail + batched DRAM mirror | DRAM bytes/IO ↓ |
| (c) Tracker bookkeeping | HW free-CID ring (Mech #1) | ~218 ns/IO |
| (d) Ordering / state dealloc | HW free-CID ring recycle on CQE flush | ~150 ns/IO (~295 → ~145) |

This table is non-negotiable: it is the load-bearing structure that makes §3 readable. It should probably appear as Table 1.

### 3.3 Evidence anchors

| Claim | Evidence anchor |
|---|---|
| On-die NVMe-touching uncore IP already exists | `intel_vmd` |
| Architectural-truth/execution-truth separation is NVMe-compliant | `nvme_spec_2_0d` |
| Aggregate-timing simulation methodology has peer-reviewed precedent (for §4) | `nvmevirt_fast23`, `femu_fast18` |

### 3.4 What NOT to put in §3

- No latency or throughput numbers. Those belong in §4. §3 is the *what and why*; §4 is the *how much*.
- RTL synthesis evidence (ASAP7 7nm cell count, SRAM area, post-synthesis logic power) IS in scope and summarized in §3.5; do not duplicate the table in §3.1–§3.4. Post-synthesis Fmax is **not** quoted in this paper (it is a lower bound pre-P&R per `RTL_design/SYNTHESIS_RESULTS.md`); P&R, routed timing closure, silicon µm² area, and post-CTS power remain out of scope and one sentence in §3.5 acknowledges that.
- No QoS / fairness mechanism. Out of scope for the 4-page version even though it is in the research plan.
- No IOMMU assist. Explicitly secondary in the research plan; cut for space.
- No DMA scheduler / prefetch detail. Subsumed into "uncore executes from SRAM" in one sentence.

---

## §4. Evaluation

### 4.1 What to write (content brief)

Four subsections. The goal is a clean answer to three reviewer questions: *(Q1) Where did the cycles go in the baseline? (Q2) Did IAU remove them as predicted? (Q3) Is the result robust or is it a single-point fluke?*

**§4.1 Methodology (~6 sentences + one bulleted setup list).**
- State the platform: gem5 full-system X86 + SimpleSSD NVMe model + SPDK `spdk_nvme_perf` inside the simulated guest. Cite `nvmevirt_fast23` and `femu_fast18` as the peer-reviewed precedent for the aggregate-timing fast-path ("Path E") used to make the SSD-side keep up with the host CPU under MIOPS; emphasize that CQE publication remains cycle-accurate so every IAU mechanism is measured faithfully.
- List the configuration: `fast_ssd_highiops.cfg`, **~8 M IOPS aggregate SimpleSSD device ceiling** (FastPathEnabled = 1, 32 channels × 250 K/channel; deliberately tuned so the SSD-side has ~10× headroom at single-core single-qpair, with the device becoming the binding constraint only near ~5-7 host cores under Mode 2 — see `memory/project_simulator_iops_ceiling.md`), **host CPU = gem5 `AtomicSimpleCPU` @ 2 GHz, no L1/L2 caches (CPU directly attached to system membus), `mem_mode=atomic`** (the gem5 default for `configs/example/fs.py`, verified from `m5out/config.ini`), single qpair, queue depth sweep {16, 32, 64, 128}, 4 KB random reads. Steady-state window: 30 s after warm-up, 3 repeats.
- Name the metrics, mapped directly to §1 P2 / §2.3: IOPS, p50/p99/p99.9 latency, total cycles/IO, instructions/IO, per-stage ns/IO (PRP, tracker, doorbell, ordering, dealloc), DRAM read/write bytes/IO, doorbells/IO, polls-per-completion, completions-per-poll.
- One sentence on instrumentation: SPDK was instrumented with per-stage timestamps; SimpleSSD/gem5 exposes per-mechanism stats counters (`mailbox_submissions`, `free_cid_pops`, `cqes_published`, `qdepth_reads`, `hint_typed_reads`, etc.).
- **Methodology framing — host CPU model choice (one paragraph, ~80 words, load-bearing for absolute-number defense).** We use `AtomicSimpleCPU` with `mem_mode=atomic` rather than a timing OoO core because the parameter sweep (4 QDs × 3 modes × 2 workloads × 3 repeats × multi-hour runs) is computationally tractable only with the simplified model; gem5 `DerivO3CPU` with realistic L1/L2 caches and timing memory is 50–200× slower per simulated second and would push a single sweep to weeks of wall-clock. The host-side savings ratio (~1.35× at QD=128) is a **same-simulator** measurement that cancels CPU-model bias because both Mode 0 and Mode 2 run under the same host model. The absolute per-IO cycle budget (~2,440 cycles/IO at 2 GHz on AtomicSimpleCPU) is **consistent with published SPDK single-core, single-qpair measurements on production NVMe hardware** [cite `Yang2017SPDKAD`]; scaled to 3 GHz, our ~3,660 cycles/IO lands in the middle of the realistic 1,500–4,000 cycles/IO range reported in SPDK community single-qpair benchmarks. Do NOT use Haas et al.'s ~6,500 cycles/IO as the anchor here (revised 2026-05-16) — that number is for 64 cores × 8 drives aggregate, where cross-core / cross-queue contention adds cycles that do not apply to our single-qpair setup. Do NOT use SPDK's "10M IOPS / one thread, ~400 cycles/IO at 4 GHz" blog numbers either — those are also aggregated across many drives on one CPU thread and are the same class of vendor-marketing aggregate that §1 P2 brief already bans. NVMeVirt (FAST'23) and FEMU (FAST'18) use the same simplification pattern (aggregate-timing device + simplified host) and are the standard methodological precedent in this regime [cite `nvmevirt_fast23`, `femu_fast18`]. An OoO host model with timing memory is named explicitly in §5 future work — but the architectural claim that the per-IO budget is offload-recoverable does not depend on this calibration, because the per-IO stages IAU eliminates (PRP construction, tracker, completion polling, doorbell ordering) are structural NVMe queue-execution work that exists on every host CPU model.
- One sentence on what we did *not* model: real PCIe link contention from concurrent devices; IOMMU translation pressure (workload assumption: reused pinned huge-page buffers, per the research plan's target regime).

**§4.2 The host CPU wall, characterized (~5 sentences + Figure F1 + Table 2).**
- Headline number: SPDK on Mode 0 saturates at ~0.82 M IOPS (776 K @ QD=16 → 819 K @ QD=128) on `paper_qdsweep_mode0_20260510`. State this in the first sentence.
- Stacked per-IO budget (this is Figure F1): a horizontal stacked bar showing PRP=337, tracker=218, state-dealloc=295, polling+doorbell+ordering=~370, other=~140 ns; total ~1220 ns/IO at QD=128.
- Scaling sentence: IOPS is approximately *flat* across QD ∈ {16, 32, 64, 128} (776 K, 800 K, 812 K, 819 K), confirming that the cost is per-IO structural, not per-batch amortized.
- One sentence on polling intensity: at QD=128, the histogram shows the overwhelming majority of `process_completions()` calls return zero — even SPDK, under perfect single-core polling, is paying for the CQ scan more often than for the work.
- One sentence on workload generality: the same baseline reproduces on a DiskANN BigANN trace replay (`paper_trace_mode0_20260510`) at 803 K @ QD=128, within 2 % of the synthetic 4 KB random sweep, so the wall is not a 4 KB-synthetic artifact.

**§4.3 IAU results — Mode A and Mode B (~7 sentences + Figure F3).**
- Result 1 (Mode 1 / Mode A, transparent): IOPS essentially flat or slightly down at QD=128 (Mode 0: 819 K vs Mode 1: 808 K, ~0.99×). State this honestly with an explanation. Under SPDK's busy polling, Mode A's batching adds tiny exposure jitter without removing the dominant per-IO costs. Mode A's value is *latency stability* and DRAM-traffic reduction, not IOPS lift. Show DRAM bytes/IO improvement here.
- Result 2 (Mode 2 + Mech #1 + #2 + #4, headline configuration on `paper_qdsweep_mode2_20260510`): **~1.106 M IOPS at QD=128, a 1.35× lift over Mode 0 (0.82 M → 1.10 M).** Per-stage decomposition at QD=128 shows Addr_Xlate 337 → 153 ns (mailbox-word build replaces full PRP-list construction), State_Dealloc 295 → 156 ns, with Submit_Preamble dropping 141 → 73 ns. Tracker_Alloc moves modestly (218 → 211 ns); the larger Tracker_Alloc savings will require Mech #3.
- Result 3 (workload generality): the same Mode 2 configuration delivers ~1.102 M IOPS at QD=128 on a DiskANN BigANN trace replay (`paper_trace_mode2_20260510`), a 1.37× lift over the trace's own Mode 0 baseline, indicating the lift is not a synthetic-workload artifact.
- Result 4 (a new CPU-bound ceiling): Mode 2 IOPS is essentially flat across QD ∈ {16, 32, 64, 128} (1.106 M, 1.106 M, 1.106 M, 1.107 M), identifying Mode 2 as a new CPU-bound saturation point. The residual gap to the ~8 M IOPS aggregate device ceiling (per `fast_ssd_highiops.cfg` FastPathTmaxPerChannel × pal.Channel) is the future-work envelope for the deferred Mech #3 (HW completion-callback dispatcher); we do not put a number on that envelope in this paper.
- Figure F3 shows IOPS and cycles/IO as functions of QD for Modes 0 / 1 / 2(+Mech124). Two-y-axis line plot. The flat Mode 2 IOPS curve is the *load-bearing* visualization for "new CPU-bound ceiling."

**§4.4 Sensitivity and scaling (~5 sentences + Figure F4).**
- Sweep over QD ∈ {16, 32, 64, 128}: the lift is **1.43× / 1.38× / 1.36× / 1.35×** on 4 KB random read and **1.45× / 1.40× / 1.38× / 1.37×** on the BigANN trace. The lift is largest at low QD (where each IO's per-stage savings matter most) and smallest at high QD (where polling overlap already amortizes some cost in Mode 0). It is *always* >1.0, forestalling "you tuned QD."
- Optional: sensitivity to CQ-batch threshold N and timer T. One curve showing a knee where p99 latency starts to rise faster than throughput improves. This calibrates the practical operating point.
- One sentence on multi-qpair behavior using `mq_trace_sweep_qd128_mode2_v4` (qp=16, 32 measured; qp=64 in progress at the time of writing): qp=16 reaches 834 K IOPS at QD=128, and qp=32 reaches 671 K IOPS, suggesting the single-qpair Mech #4 path does not yet fully cover the O(qpairs) scan cost at high qpair counts. This is an evaluation gap to acknowledge honestly rather than gloss.
- One sentence on correctness: every mechanism preserves `mailbox_submissions ≈ free_cid_pops ≈ free_cid_pushes ≈ cqes_published` across the full sweep, with `free_cid_starvations == 0` and `mailbox_oversize_fallback == 0`. Honest engineering note.
- Threats-to-validity paragraph, deliberate and explicit. **(i) Host-CPU model.** The simulated host is gem5 `AtomicSimpleCPU` @ 2 GHz with no L1/L2 caches and `mem_mode=atomic`; this model captures per-IO instruction count and DRAM-access latency but does not model cache-coherence, ILP, branch prediction, or OoO execution. Consequently, absolute per-IO cycles in our simulator (~2,440 cycles/IO at Mode 0 / ~1,810 at Mode 2 @ QD=128) are not a head-to-head match to a specific real-hardware CPU. The right reference point is **SPDK single-core, single-qpair on production NVMe hardware**, where realistic real-hardware numbers sit in the 1,500–4,000 cycles/IO range at 3 GHz (community-published SPDK benchmarks; original SPDK characterization in `Yang2017SPDKAD`). Our 2,440 cycles/IO at 2 GHz scales to ~3,660 at 3 GHz, which lands in the middle of this range, so our absolute number IS in the right regime for the workload we model. Do NOT use Haas et al. (~6,500 cycles/IO at 3 GHz Skylake-X) as the anchor for our setup (revised 2026-05-16) — Haas's measurement was 64 cores × 8 drives aggregate where cross-core/cross-queue contention adds per-IO cycles that do not apply at 1-core 1-qpair. Do NOT cite SPDK's "10 M IOPS / one thread, ~400 cycles/IO at 4 GHz" blog numbers either — those are aggregated across many drives on one CPU thread and are the same class of vendor-marketing aggregate that §1 P2 brief already bans. The load-bearing comparison is the Mode 0 → Mode 2 delta within the same simulator and the cross-workload reproduction on the BigANN trace; the ratio (~1.35× @ QD=128) cancels the host-model bias because both modes share the model. The lift our simulator measures is plausibly a **lower bound** on what real silicon would see, because IAU additionally eliminates the cache-coherence/DMA-invalidation costs that AtomicSimpleCPU does not model — on real hardware those would compound with the instruction reductions we already measure. The §4.1 methodology paragraph carries the OoO-validation future-work commitment; §5 names it as an explicit follow-up. **(ii) SSD-side model.** `fast_ssd_highiops.cfg` enables a NVMeVirt-style fast path (FastPathEnabled = 1) that bypasses the HIL/ICL/FTL/PAL per-stage event chain for I/O commands; the SSD-side aggregate ceiling is configured at 8 M IOPS, ~10× above the observed 0.82 M Mode 0 / 1.10 M Mode 2 single-qpair numbers, so the device is not masking, gating, or contaminating the baseline. Path E does not model per-NAND-channel queueing burstiness at the cell level; this affects absolute IOPS but not the Mode 0 → Mode 2 delta. Cite `nvmevirt_fast23` and `femu_fast18` for the aggregate-timing methodology defense. Do NOT re-introduce the older "SimpleSSD caps at 74 K IOPS / 5,400 cycles/IO at 400 MHz" framing — that predates FastPathEnabled and is now stale (per `memory/project_simulator_iops_ceiling.md`, refreshed 2026-05-16).

### 4.2 Logic chain

```
4.1 Methodology ──────► establishes credibility + maps to §1 ¶2 measurement claim
                                          │
                                          ▼
4.2 Wall characterized ─► answers Q1: cycles go to PRP / tracker / dealloc / polling
                                          │
                                          ▼
4.3 IAU results ────────► answers Q2: each mechanism removes exactly the predicted cost,
                                       ~1.35× headline measured at QD=128 (rand 4 KB),
                                       1.37× measured on a BigANN trace replay;
                                       Mech #3 is named as future work, not projected
                                          │
                                          ▼
4.4 Sensitivity ────────► answers Q3: not a single-point fluke, lift sustained across QD
                                       (1.35×–1.43×), workload generality on BigANN,
                                       multi-qpair scaling acknowledged as an evaluation gap
```

### 4.3 Evidence anchors

| Claim | Evidence anchor |
|---|---|
| Path E aggregate-timing methodology has peer-reviewed precedent | `nvmevirt_fast23`, `femu_fast18` |
| Baseline cycles/IO is consistent with published SPDK single-qpair measurements on production NVMe hardware | `Yang2017SPDKAD` (original SPDK characterization) — our ~2,440 cycles/IO at 2 GHz AtomicSimpleCPU scales to ~3,660 at 3 GHz, which sits in the middle of the realistic 1,500-4,000 cycles/IO range for SPDK at single-core, single-qpair, single-drive on production NVMe. Use this anchor here, in P4, and in §4.4. Do NOT cite Haas et al. ~6,500 cycles/IO — that is 64 cores × 8 drives aggregate, not single-qpair. Do NOT cite SPDK's "10 M IOPS / one thread, ~400 cycles/IO at 4 GHz" blog numbers — those are vendor-aggregate marketing numbers that §1 P2 brief already bans. |
| SSD-side device ceiling is 10× above observed host-side IOPS | `fast_ssd_highiops.cfg` FastPathEnabled=1, FastPathTmaxPerChannel=250000 × pal.Channel=32 = 8 M IOPS aggregate; observed Mode 0 = 0.82 M, Mode 2 = 1.10 M single-qpair |
| Per-stage budget | `paper_qdsweep_mode0_20260510` CSV (PROJECT_CONTEXT §2.2) |
| ~1.35× measured lift headline at QD=128 (4 KB rand) | `paper_qdsweep_mode2_20260510` CSV (PROJECT_CONTEXT §2.3) |
| 1.37× measured lift at QD=128 on BigANN trace | `paper_trace_mode2_20260510` CSV vs `paper_trace_mode0_20260510` |
| Multi-qpair preliminary data | `mq_trace_sweep_qd128_mode2_v4` (qp=16, 32) |

### 4.4 What NOT to put in §4

- No NUMA / multi-socket cross-section. Out of scope for a single-core simulator.
- RTL energy / IO is reported in §3.5 from post-synthesis ASAP7 7nm STA-power and is **not** repeated in §4; §4 is system-level IOPS / cycles only. Do not introduce mW-per-IO in the §4 tables — that would conflate post-synthesis logic power (no SRAM, no P&R) with system-level cost and overclaim the silicon evidence.
- No real-hardware comparison numbers. The whole study is simulator-based; do not invent absolute IOPS comparisons against real Optane or BlueField — those would be unfair and reviewer-bait. The relative deltas (Mode 0 → Mode 2) are the load-bearing claims.

---

## §5. Conclusion

### 5.1 What to write (content brief)

One paragraph, ~5 sentences. No new claims, no new figures.

- Sentence 1 — restate the wall: at multi-million IOPS, the host CPU is the structural bottleneck, and SPDK is the right way to measure it because it is the best-case software.
- Sentence 2 — restate the placement: the natural fix is an on-die uncore that executes per-IO queue semantics from private SRAM, with DRAM rings serving as a compatibility mirror.
- Sentence 3 — restate the result: a full-system gem5 + SimpleSSD + SPDK simulation, with four NVMe-compliant mechanisms (Mailbox SQ Engine, HW free-CID ring, HW queue-depth counter, typed hint register) and ~45 lines of SPDK changes, delivers a measured ~1.35× IOPS lift at QD=128 (0.82 M → 1.10 M on 4 KB random read, with 1.37× reproduced on a DiskANN BigANN trace), with Mode 2 itself emerging as a new CPU-bound ceiling that motivates a fifth, deferred mechanism.
- Sentence 4 — name the open work: a hardware completion-callback dispatcher (identified as the next bottleneck once IAU lifts the ceiling), place-and-route closure of the synthesized RTL (routed timing, post-CTS power, silicon µm² area), **extended-form host-side validation with an OoO core model and timing memory (gem5 `DerivO3CPU` + L1/L2 + timing `mem_mode`) to calibrate the absolute IOPS number against real Skylake/Ice-Lake-class hardware** (the §4.1 methodology paragraph promises this; §5 is where the promise is named publicly), QoS at line rate, IOMMU assist, and a kernel-NVMe/io_uring cross-stack validation are explicit follow-ups; the architecture is fail-safe under partial deployment, which makes incremental adoption realistic. Do NOT list "RTL synthesis area / frequency / energy" as future work here — those are reported in §3.5 of this paper. Do NOT use the word "preliminary" to describe the current §4 results — the ratio (1.35×) is a finished, defensible measurement, and "preliminary" framing invites the come-back-when-it's-done reviewer attack; instead the §4.1 methodology paragraph names the host-model tradeoff explicitly and §5 promises the extended validation as natural follow-up work, which is the standard CAL pattern.
- Sentence 5 — close with the framing claim: integrating I/O execution into the CPU uncore is the same architectural move the industry made for memory controllers in 2003, applied now to the next fabric-bottleneck of its era.

### 5.2 What NOT to put in §5

- No new mechanism. No new numbers. No new related work.
- No vague future-work block-list with bullet points.

---

## Cross-cutting checklist (apply before submission)

1. **Citation budget.** CAL allows ~20–25 references in practice. Prioritize: `kioxia_fms2025`, `ragx_isca25`, `diskann`, `spdk_modern_apis`, `spdk_docs`, `bam_asplos23`, `gids_vldb24`, `bluefield3`, `nvme_host_accel`, `nvmecha`, `nvme_spec_2_0d`, `opteron_imc`, `five_minute_rule_30`, `intel_vmd`, `nvmevirt_fast23`, `femu_fast18`, `i10_atc19`, `spann_neurips21`, `reflex`. Trim `[26]`–`[33]` aggressively unless reviewers ask.
2. **Every figure earns its space.** F1 (per-IO budget), F2 (block diagram), F3 (IOPS/cycles vs QD across modes), F4 (sensitivity). If any of these is weak, cut it; do not add a fifth.
3. **No claim outruns its evidence.** "~1.35× measured" is the headline (0.82 M → 1.10 M IOPS at QD=128, 4 KB random); "1.37× on BigANN trace replay" is the workload-generality witness. Mech #3 is named as future work and is **not** assigned a projected multiplier in this paper.
4. **Compliance is load-bearing — repeat it.** Reviewers will fixate on NVMe correctness; §3.4 must be unambiguous and §4 must show `mailbox_submissions ≈ free_cid_pops ≈ free_cid_pushes ≈ cqes_published` as evidence.
5. **Pre-empt the three most likely attacks** (named in `LITERATURE_REVIEW.md` §0): "you ignored DPUs/IPUs" → §2.2 Para B names BlueField/Mount Evans (moved from §1 P3 on 2026-05-16); "you ignored FPGA NVMe controllers" → §2.2 Para B names NVMeHA/NVMeCHA/DirectNVM (moved from §1 P3 on 2026-05-16); "isn't this Shadow Doorbell?" → §3.4. §1 itself preserves a one-sentence forward reference to §2.2 Para B at the top of §1 P3 (the proposal+contributions paragraph) so a reader of §1 alone still sees the scope-mismatch closer. Do not reintroduce a full DPU/FPGA discussion inside §1.
6. **Honest scope statement.** RTL synthesis at ASAP7 7nm (footprint + post-synthesis logic power) IS in scope and reported in §3.5 and P4. Place-and-route (routed timing closure, silicon µm² area, post-CTS power), QoS at line rate, IOMMU assist, and kernel-stack (kernel-NVMe / io_uring) validation are future work; do not promise them in §5. Do NOT claim post-synthesis Fmax as a paper number — `RTL_design/SYNTHESIS_RESULTS.md` flags it as a lower bound pre-P&R and quoting it would invite a "design does not meet timing" attack.

---

*End of outline v0. Edit this file directly to iterate. Each section can be revised independently as long as the §1.2 / §3.2 / §4.2 logic chains remain intact — those are the load-bearing structure of the paper.*
