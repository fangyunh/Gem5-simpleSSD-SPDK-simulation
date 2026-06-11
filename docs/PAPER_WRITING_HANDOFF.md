# Paper Writing Handoff Prompt — IAU Paper §3-§5

> **Use this file when:** you are opening a new AI session to continue writing the IAU paper after §1 and §2 are already drafted.
>
> **Companion file:** `docs/AGENT_HANDOFF_PROMPT.md` covers experiment running. This file covers paper *writing*. They are independent; do not mix them.
>
> **How to use:**
> 1. Open a fresh AI session in this repository.
> 2. Paste section **B** below into the session as the first message.
> 3. The agent will read the listed context files, confirm understanding, and wait for your next request before producing prose.
>
> **Date written:** 2026-05-22. If the draft has advanced significantly past §2 by the time you reuse this file, regenerate it to reflect what is current.

---

## A. Quick state-of-the-paper summary (read this yourself, do not paste)

- **Venue.** IEEE Computer Architecture Letters (CAL). 4 pages of text + 1 page of references.
- **Working title.** *IAU: Assisting the CPU Core for Next-Generation Multi-Million IOPS NVMe Devices.*
- **Done.**
  - §1 Introduction, three paragraphs (P1 device-supply trend, P2 host CPU wall, P3 IAU proposal + contributions).
  - §2 Background, three subsections (§2.1 NVMe queue execution model + four per-IO costs, §2.2 state of the art at MIOPS scale across two paragraphs, §2.3 per-IO cost characterization on the simulator with one stacked-bar figure).
  - `scripts/plot_cycle_breakdown.py` rendering `figures/cycle_breakdown.{pdf,png}` (vanilla SPDK QD=16 vs QD=128, six lifecycle stages, no IAU columns).
- **Pending.**
  - §3 IAU: A Host-Integrated I/O Uncore (five subsections, the longest section in the paper).
  - §4 Evaluation (four subsections + Figure F1 cycle breakdown re-rendered with IAU, Figure F3 IOPS/cycles vs QD across modes, Figure F4 sensitivity).
  - §5 Conclusion (one paragraph).
- **Locked decisions that survive across sessions.**
  - §2.3 figure stays SPDK-only (QD=16 vs QD=128). The IAU-vs-SPDK cycle comparison is in §4 on the DiskANN BigANN trace replay, not the synthetic 4 KB workload.
  - The §2.1 four per-IO costs are named: **doorbell traffic**, **completion polling**, **queue-state coherence traffic**, **ordering serialization**. §3 mechanism descriptions must refer back to these names. The older `(a)-(d)` UC-WC / DMA-invalidated / DRAM-metadata / ordering-fences labels are retired.
  - Headline numbers from §1 P3 contributions paragraph: "up to 1.44× IOPS and roughly 30% fewer cycles per I/O" on BigANN. Reproduced on synthetic 4 KB random read. ASAP7 7nm footprint: 30K–93K cells, 0.1–0.9 mm² SRAM, 14–49 mW logic at 1 GHz.
  - Simulator caveat — host CPU is gem5 `AtomicSimpleCPU` @ 2 GHz, no L1/L2, `mem_mode=atomic`. SSD-side uses `fast_ssd_highiops.cfg` with FastPathEnabled=1 (NVMeVirt-style aggregate-timing fast path). These are admitted explicitly in §4.1 and §4.4; the §3 prose does not have to mention them.
  - Do **not** quote post-synthesis Fmax. The synthesis log flags it as a lower bound pending place-and-route; citing it would invite a "does not meet timing" attack.
  - Do **not** use "Mode 0 / Mode 1 / Mode 2" codenames in prose. Those are simulator-internal. Use "vanilla SPDK baseline" and "IAU" instead.

---

## B. The handoff prompt (paste this verbatim into a fresh AI session)

> Begin copy-paste below the line.

```
You are continuing the writing phase of an academic paper. The paper is
targeted at IEEE Computer Architecture Letters (CAL) — a 4-page double-
column letter proposing an on-die I/O Assistant Uncore (IAU) that
offloads the per-I/O NVMe fast path into a CPU-die hardware block,
motivated by AI retrieval workloads needing multi-million IOPS from
the host CPU.

The DESIGN and EXPERIMENT phases are complete. §1 (Introduction) and §2
(Background) prose are drafted and have already been through several
revision passes. §3 (IAU design), §4 (Evaluation), and §5 (Conclusion)
are pending draft.

YOUR JOB: discuss with me about the §3, §4, and §5 outline documented in docs/PAPER_OUTLINE.md at first. Then, prose into docs/PAPER_DRAFT.md in
the format and register established by §1 and §2.  Do not redesign
the architecture, rename mechanisms, change the headline numbers, or
re-litigate methodology choices that the outline already settled before we discuss. You may need to revise the outline after our discussion.

────────────────────────────────────────────────────────────────────
CONTEXT — READ THESE FILES IN ORDER BEFORE WRITING ANYTHING
────────────────────────────────────────────────────────────────────

1. docs/PAPER_OUTLINE.md
   The section-by-section content brief. Resynchronized 2026-05-22.
   For each section it specifies (i) what to write, (ii) the
   evidence anchors for each claim, and (iii) the logic chain that
   ties the paragraphs together. §3 and §4 briefs are the load-
   bearing ones for your job. The "writing-style guardrails" block
   near the top is non-negotiable.

2. docs/PAPER_DRAFT.md
   The current paper draft. §1 and §2 are complete. Match this
   register exactly when drafting §3-§5: each paragraph is a single
   physical line, no soft wraps; no em-dashes, no colons, no
   parentheses as parenthetical separators; LaTeX cite keys in
   \cite{...} form that already resolve against docs/paper.bib.

3. docs/PROJECT_CONTEXT.md
   Comprehensive engineering context. Useful when §3 mechanism
   descriptions need to be accurate to the simulator implementation
   (e.g., the four BAR0 primitives — mailbox SQ engine, HW free-CID
   ring, HW queue-depth counter, typed hint register — and their
   actual register addresses and wire formats).

4. docs/LITERATURE_REVIEW.md
   Citation reasoning. When you need to add a citation to §3/§4/§5,
   check that the cite key (i) exists in docs/paper.bib and (ii) is
   the one the literature review recommends for that claim. Do not
   invent new cite keys.

5. docs/paper.bib
   The actual BibTeX database. If a cite key you want to use is not
   in this file, STOP and ask the user — do not add bib entries on
   your own; the user maintains this file.

6. docs/IO Uncore design plan.md  and
   docs/IO-Uncore RTL Design Specification — Phase 3 Silicon Feasibility.md
   The architectural specification and the Phase 3 RTL specification.
   §3 design prose must agree with these on register layout (BAR0
   offsets), mailbox-descriptor wire format, and SRAM sizing. If you
   see a conflict between these and PAPER_OUTLINE.md, flag it to the
   user — do not silently resolve it in either direction.

7. scripts/plot_cycle_breakdown.py
   The §2.3 figure generator. Its docstring documents how the per-
   stage breakdown is calibrated and why raw QD=16 CSV columns are
   NOT plotted directly. §4 prose that quotes per-stage values must
   stay consistent with this file. When §4 adds an IAU comparison
   figure, write a new plot script (do not overwrite this one);
   suggested location: scripts/plot_iau_vs_spdk_bigann.py.

8. RTL_design/SYNTHESIS_RESULTS.md
   ASAP7 7nm synthesis results. The §3.5 / §4 / §1 P3 numbers come
   from here: 30-93 K standard cells, 0.1-0.9 mm² SRAM, 14-49 mW
   logic at 1 GHz. Do NOT quote post-synthesis Fmax in any section
   of the paper — the file itself flags Fmax as a lower bound
   pending place-and-route.

────────────────────────────────────────────────────────────────────
WRITING DISCIPLINE (these rules override your defaults)
────────────────────────────────────────────────────────────────────

Style:
 - No em-dashes "—". Replace with full sentences joined by
   transitions (however, therefore, moreover, in particular,
   consequently, rather), or with comma-flanked relative clauses.
 - No colons ":" introducing lists or examples mid-sentence.
   Reformulate as two sentences or as a restrictive clause.
 - No parentheses "()" for asides, definitions, or numerical
   clarifications. Integrate into the sentence or break out.
 - Compound-modifier hyphens (on-die, 100M-IOPS-class, multi-
   million) remain in use; the em-dash rule does NOT touch these.
 - Each paragraph in PAPER_DRAFT.md is a single physical line, no
   soft wraps.
 - Academic register. No first-person flourishes unless reporting
   authorial action ("we measure", "we propose").
 - When you coin a term needed elsewhere, define it in the same
   sentence it first appears.

Content discipline:
 - Do NOT use "Mode 0 / Mode 1 / Mode 2" codenames in prose. Use
   "vanilla SPDK baseline" and "IAU" instead. §3 may refer to
   sub-mechanisms by the names the outline gives (Mailbox SQ engine,
   HW free-CID ring, HW queue-depth counter, typed hint register,
   HW completion-callback dispatcher — the last one is deferred to
   future work).
 - Do NOT quote post-synthesis Fmax anywhere.
 - Do NOT introduce new headline numbers. The locked values are:
   * SPDK saturates at ~0.82 M IOPS single-core single-qpair
     (776 K @ QD=16 → 819 K @ QD=128).
   * IAU lift on BigANN: up to 1.44× IOPS at QD=16, ~1.35× at
     QD=128, ~30% fewer cycles per I/O.
   * IAU lift reproduced on synthetic 4 KB random read.
   * ASAP7 7nm RTL: 30-93 K cells, 0.1-0.9 mm² SRAM, 14-49 mW
     logic at 1 GHz across four queue-resource configurations.
 - Do NOT promise future work in §5 beyond what the outline
   sanctions: HW completion-callback dispatcher (Mech #3), place-
   and-route closure, OoO host-model validation against real
   Skylake/Ice-Lake hardware, QoS at line rate, IOMMU assist,
   kernel-NVMe/io_uring cross-stack validation. Do not list "RTL
   synthesis area/frequency/energy" as future work — those are
   reported in this paper.
 - Each §3 mechanism description should name both what the
   mechanism removes from the host (the NVMe-protocol portion) and
   what stays on the host as a residual (the application-level
   portion that cannot be moved off-CPU without changing
   application semantics). This is the "application/protocol
   boundary" rule documented in PAPER_OUTLINE.md §3.1.

Process:
 - Before writing each section, re-read its content brief in
   PAPER_OUTLINE.md and the corresponding evidence-anchor table.
   The outline is the source of truth; if the outline contradicts
   your impression of what should be written, follow the outline
   and surface the contradiction to the user.
 - Write one subsection at a time. After each subsection, pause and
   wait for review before continuing to the next. Do NOT batch §3 +
   §4 + §5 in one turn.
 - Each subsection: write the outlined number of sentences, no
   more. Cite using existing keys from docs/paper.bib. Mark any
   needed-but-missing cite key as TODO and ask before adding to
   paper.bib.
 - Update PAPER_DRAFT.md in place, replacing the corresponding
   "*Pending draft.*" stub with the new prose.
 - Do NOT touch §1 or §2 prose. If you notice a §1/§2 issue while
   drafting §3, flag it in a separate message — do not edit those
   sections without explicit user approval.

────────────────────────────────────────────────────────────────────
WHAT TO DO NOW
────────────────────────────────────────────────────────────────────

1. Read the six PAPER_DRAFT.md / PAPER_OUTLINE.md / PROJECT_CONTEXT.md
   / LITERATURE_REVIEW.md / paper.bib / scripts/plot_cycle_breakdown.py
   files listed above (and RTL_design/SYNTHESIS_RESULTS.md if §3 or §4
   needs synthesis numbers).
2. Confirm back to the user, in 5 short bullet points:
   (i) what state §1 and §2 are in,
   (ii) which §3 subsection you intend to draft first,
   (iii) which figures you will need to create (and which already
        exist),
   (iv) any contradictions you noticed between PAPER_OUTLINE.md and
        PAPER_DRAFT.md, the design plan, or paper.bib,
   (v) any missing cite keys you'd need to add.
3. WAIT for the user to confirm before drafting prose. Do not
   produce §3.1 in the same turn as the confirmation message.

If a confirmation step would force you to ask three or more
clarifying questions, stop and ask just the most blocking one.
```

> End copy-paste above the line.

---

## C. Optional next moves the user may direct the agent to take

After confirmation, plausible follow-up requests in order of likely sequence:

1. Draft §3.1 (Placement and principle) → review → §3.2 (Three-mode continuum) → review → §3.3 (Mechanisms inside Mode B) + traceability table → review → §3.4 (NVMe compliance and fail-safe) → §3.5 (SRAM sizing and silicon plausibility).
2. Generate Figure F2 (block diagram). The outline calls for IAU sitting between SPDK and PCIe root complex with private SRAM and the four sub-blocks; this is hand-drawn or tikz, not a plot script — discuss format with the user first.
3. Generate Figure F1 / F3 / F4 plot scripts:
   - F1 (per-IO cycle breakdown with IAU column added): clone `scripts/plot_cycle_breakdown.py` into `scripts/plot_iau_vs_spdk_bigann.py`. Use the BigANN trace data, not the synthetic 4 KB sweep.
   - F3 (IOPS and cycles/IO vs QD across vanilla SPDK and IAU): two-y-axis line plot.
   - F4 (sensitivity to CQ-batch threshold N and timer T).
4. Draft §4.1 → §4.2 → §4.3 → §4.4 in sequence, with figures rendered as each subsection is written.
5. Draft §5 in one pass, ~5 sentences.
6. Pre-submission checklist pass (item 5 of "Cross-cutting checklist" in PAPER_OUTLINE.md — the three pre-empted reviewer attacks).

---

## D. Red flags — interrupt the agent if you see any of these

- It silently invents a cite key not in `paper.bib`.
- It quotes post-synthesis Fmax anywhere.
- It uses "Mode 0 / Mode 1 / Mode 2" in §3/§4/§5 prose.
- It introduces a headline number outside the locked set (1.44× IOPS, ~30% cycles, 30-93 K cells, 0.1-0.9 mm² SRAM, 14-49 mW logic).
- It edits §1 or §2 prose without permission.
- It tries to draft §3 + §4 + §5 in one turn instead of one subsection at a time.
- It uses em-dashes, colons, or parentheses as parenthetical separators.
- It promises future work beyond the sanctioned list in §5.
- It conflates post-synthesis logic power (no SRAM, no P&R) with system-level energy in §4 tables.

---

*End of paper-writing handoff prompt.*
