# Agent Handoff Prompt — IO-Uncore Paper Experiments

> **Audience:** a fresh AI coding agent (Claude Code, Cursor, Cline, Aider, Codex, etc.) being asked to complete the experimental/evaluation work for the IO-Uncore IEEE CAL paper.
>
> **Author:** plan-mode dialogue artifact, 2026-05-09.
>
> **How to use this file:**
> 1. Skim §A (Pre-flight checklist) and confirm the items.
> 2. Open a new agent session in this repository.
> 3. Copy §B (the actual handoff prompt) into the session. Tell the agent to read the context files listed.
> 4. Let it work; reply only when it surfaces a red flag from §D.

---

## A. Pre-flight checklist (do this BEFORE launching the agent)

Confirm each of these is true before you delegate. The agent cannot recover from these gaps cleanly because they involve out-of-repo state.

- [ ] `tmux` installed on the host (sims run in detached tmux; agents can't watch terminals overnight).
- [ ] **The agent is operating WITHOUT sudo / root access.** Every workflow described below uses the virtio-9p sharing path so no disk-image baking or root-mounted extraction is ever required. If a step appears to need root, that is a bug — do not work around it with sudo.
- [ ] `conda` envs `simplessd_env` (Python 2.7, for gem5 build) and `llm` (Python 3 + matplotlib, for plots) both work — confirm with:
      ```
      conda run -n simplessd_env python --version       # 2.7.x
      conda run -n llm python -c 'import matplotlib; print(matplotlib.__version__)'
      ```
- [ ] SPDK build environment is functional in user-space (DPDK headers reachable via `pkg-config` or in the `spdk/dpdk/` submodule). Test `cd spdk && ./configure --help` returns without error.
- [ ] Disk image `assets/x86-ubuntu.img` exists and was previously baked once (one-time setup the user did with sudo). The agent will NOT need to re-bake.
- [ ] `diod` is reachable in the user's $PATH OR a per-user/static binary is in the workspace. `which diod` should resolve.
- [ ] At least 100 GB of free disk space available to the user (gem5 binary + sweep results).
- [ ] At least 16 GB RAM and 8+ idle CPU cores available to the user (gem5 is greedy — `boot_gem5.sh` already pins to non-critical cores via `taskset`).

---

## B. The handoff prompt (copy-paste into a fresh agent)

> Begin copy-paste below.

```
You are continuing the experimental phase of an academic paper project.
The paper is targeted at IEEE Computer Architecture Letters (CAL): a
4-page double-column position paper proposing an "IO-Uncore" — a CPU
I/O-chiplet-resident hardware engine that takes over NVMe queue
execution from software, motivated by AI retrieval workloads needing
10–100 M IOPS.

The PLANNING phase is complete. The DESIGN/CONFIG/PATCH work is
complete. What remains is EVIDENCE COLLECTION via the gem5 + SimpleSSD
+ SPDK simulation stack already in this repository.

YOUR JOB: produce the simulation data that anchors the paper's §2 and
§4 figures, by executing the three-regime sweep described in
docs/PAPER_IMPL_TODO.md. You should not redesign anything; you should
not edit the paper or the chapter plan; you should not re-architect
the simulator. You are running and validating experiments.

────────────────────────────────────────────────────────────────────
CONTEXT — READ THESE FILES IN ORDER, BEFORE TAKING ANY ACTION
────────────────────────────────────────────────────────────────────

  1. docs/PAPER_CHAPTER_PLAN.md
       Master plan-mode artifact. Skim §0 paper meta, §2 (chapter plan
       with figure specs), and §3 INSIGHT collection. Pay special
       attention to §4 Evaluation — that is what your data will fill.

  2. docs/PAPER_IMPL_TODO.md
       The implementation work plan. This is your primary task list.
       It has a dependency graph (§ At-a-glance), per-item file paths,
       commands to run, time estimates, and verification steps. You
       will execute items (1) through (5) from this file, in order.

  3. docs/PROJECT_CONTEXT.md
       Onboarding for the simulation infrastructure. Sections 1–7
       explain what gem5/SimpleSSD/SPDK are doing, what fast_ssd.cfg
       configures, and what the result CSVs mean. §13 explains how
       to read the per-run cycle_breakdown CSVs.

  4. CLAUDE.md
       Project-level instructions. Build commands, key constraints
       (esp. "Disk image must be baked before each run"), and the
       three-layer gem5 detachment story.

  5. scripts/scripts_manual.md
       Script reference: which shell scripts do what, the end-to-end
       workflow from baking the image to running a sweep to extracting
       results.

  6. fast_ssd_highiops.cfg (root)
       The retuned SimpleSSD config you will run against. Compare to
       fast_ssd.cfg to understand what was changed and why.

  7. spdk/lib/nvme/{nvme_pcie_internal.h, nvme_pcie.c,
                    nvme_pcie_common.c}
       The Mode 2B host patch (45 LOC across 3 files). You do NOT
       modify these. You DO need to rebuild SPDK so the patch takes
       effect in the guest binary.

────────────────────────────────────────────────────────────────────
TASK PLAN — execute in order; checkpoint after each
────────────────────────────────────────────────────────────────────

  TASK 1. Verify high-IOPS regime (PAPER_IMPL_TODO §1)
  ----------------------------------------------------
    Goal: prove fast_ssd_highiops.cfg sustains >=10 M IOPS at QD=128
    4 KB random read on the current Mode-disabled (UncoreMode=0)
    baseline, so the rest of the sweep is in the right regime.

    Run a smoke-test sweep at QD=128 only, UncoreMode=0:
      cd /home/fangy6/SimpleSSD_Gem5_simulation
      tmux new -d -s verify_highiops
      tmux send -t verify_highiops 'SSD_CFG=fast_ssd_highiops.cfg \
        ./scripts/phase1_4k/driver_phase1.sh --auto --qd "128" --ios "4096" \
        --qpairs "1" --repeats 1 --steady-time 3 --uncore-mode 0 \
        --tag verify_highiops' Enter

    NOTE: --steady-time 3 (not 30). gem5 is deterministic; 3 s at >=10 M
    IOPS gives 30 M IO samples, far beyond what means or p99 require.

    Wait for completion (gem5 takes ~30–90 min wall for 30 s steady-
    state; monitor logs/gem5.out and logs/driver_phase1_verify_highiops.log).
    Do NOT poll aggressively — check every 10 minutes.

    On completion:
      Results land DIRECTLY on the host workspace via the virtio-9p
      share. No extraction step required. The driver writes to
      results/phase1_runs/verify_highiops/core0_qp1/phase1_results.csv
      automatically.

    Verification: read that CSV and confirm IOPS column >= 10000000 (10 M).

    SUCCESS  -> proceed to TASK 2.
    FAILURE  -> STOP and report to the user. Do NOT iterate on the
                config without permission. The user wrote the config;
                if it under-performs they need to know.

  TASK 2. Rebuild SPDK with Mode 2B patch (PAPER_IMPL_TODO §2)
  ------------------------------------------------------------
    Goal: produce a guest_spdk_nvme_perf binary whose
    nvme_pcie_qpair_process_completions early-exits when the BAR0+0x2000
    hint register reads zero AND env var SPDK_UNCORE_MODE_B=1.

    Build commands depend on whether the user has the SPDK Docker
    container set up. Try in this order:

    Option A — if there's a Dockerfile or build script:
      ls docker/ docker_artifacts/ 2>&1 | head
      # follow whatever produced docker_artifacts/guest_spdk_nvme_perf
      # originally; check git log for clues.

    Option B — native build inside spdk/:
      cd spdk
      ./configure --without-isal --without-uring  # match guest stack
      make -j$(nproc)
      cp build/bin/spdk_nvme_perf ../docker_artifacts/guest_spdk_nvme_perf

    Verification:
      strings docker_artifacts/guest_spdk_nvme_perf | grep -c "IO-Uncore Mode 2B"
      # Must print >= 1 (the NOTICELOG and/or WARNLOG strings).

    If the SPDK build fails for environmental reasons (missing DPDK
    headers, glibc version mismatch, SSSE3 instructions), STOP and
    report. The original guest_spdk_nvme_perf was built in a Docker
    container specifically to avoid SSSE3 and target glibc 2.27 — do
    NOT ship a binary that violates those constraints, the gem5 guest
    will SIGILL.

  TASK 3. (NOT NEEDED — virtio-9p mode handles SPDK binary updates)
  ------------------------------------------------------------------
    DO NOT run bake_disk_image.sh. Disk-image baking would require
    sudo, which this agent does not have. It is also unnecessary.

    Why: phase1_run.sh resolves the SPDK binary as
        $ROOT_DIR/docker_artifacts/guest_spdk_nvme_perf
    where ROOT_DIR is the workspace root. With virtio-9p sharing
    (AUTO_VIO_9P=1, default in driver_phase1.sh), ROOT_DIR inside
    the gem5 guest is /mnt/9p, which maps to the host workspace.
    Therefore: copying the rebuilt binary into
    docker_artifacts/guest_spdk_nvme_perf on the host is sufficient;
    the next gem5 launch will pick it up automatically.

    Skip this task entirely. Proceed to TASK 4.

  TASK 4. Plumb SPDK_UNCORE_MODE_B env var through phase1_run.sh
  ---------------------------------------------------------------
    Read scripts/phase1_4k/phase1_run.sh and locate the spdk_nvme_perf invocation.
    Currently it does NOT export SPDK_UNCORE_MODE_B. Add a guarded
    export so it activates only when --uncore-mode 2:

      # In phase1_run.sh, before the spdk_nvme_perf call:
      if [ "${UNCORE_MODE:-0}" = "2" ]; then
        export SPDK_UNCORE_MODE_B=1
      else
        unset SPDK_UNCORE_MODE_B
      fi

    Verify by reading the modified script back. NO re-baking needed:
    phase1_run.sh runs from /mnt/9p (the virtio-9p mount of the host
    workspace), so the next gem5 launch sees the edited script
    automatically.

  TASK 5. Three-regime sweep (PAPER_IMPL_TODO §3)
  ------------------------------------------------
    Three sweeps; each runs ~1.5–2 hours wall (4 QDs × 3 repeats × 30 s
    steady-state × ~20× gem5 slowdown × overhead).

    TAG_BASE=phase1_paper_$(date +%Y%m%d)

    # SPDK baseline (UncoreMode=0)
    tmux new -d -s sweep_baseline
    tmux send -t sweep_baseline "SSD_CFG=fast_ssd_highiops.cfg \
      ./scripts/phase1_4k/driver_phase1.sh --auto \
      --qd '16 32 64 128' --ios '4096' --qpairs '1' \
      --repeats 3 --steady-time 5 --uncore-mode 0 \
      --tag ${TAG_BASE}_baseline" Enter

    # Wait for completion. Check every 15 min:
    #   ./scripts/boot_gem5.sh status
    #   tail -1 logs/driver_phase1_${TAG_BASE}_baseline.log

    # When baseline done, NO extract step needed — results are already
    # at results/phase1_runs/${TAG_BASE}_baseline/ on the host
    # workspace via the virtio-9p mount.

    # Repeat with --uncore-mode 1 (Mode A) and tag ${TAG_BASE}_modeA.
    # Repeat with --uncore-mode 2 (Mode B) and tag ${TAG_BASE}_modeB.

    Sequential, not parallel — gem5 runs are CPU-greedy and don't
    coexist well.

  TASK 5b. (Optional but recommended) Fix the multi-core script
  --------------------------------------------------------------
    PRECONDITION: TASK 5 completed; you have single-core baseline +
    Mode A + Mode B data.

    The existing scripts/phase1_run_multicore.sh is BROKEN against the
    gem5 stack — it was written for real-hardware measurement and:
      * filters cores at exactly 5300 MHz (gem5 simulates 1–2 GHz)
      * reads host PMU events that gem5 does not expose
      * uses a hard-coded PCI address that does not match SimpleSSD
      * does not invoke through driver_phase1.sh / boot_gem5.sh
      * does not plumb --uncore-mode through

    See docs/PAPER_IMPL_TODO.md item (4) for the full breakage
    inventory and the required-fix specification.

    Write a NEW script scripts/phase1_run_multicore_gem5.sh that:
      - mirrors phase1_run.sh's structure (in-guest via 9p)
      - takes --cores N, derives --core-mask 0x((1<<N)-1)
      - propagates UNCORE_MODE through to the cfg-patch step
      - drops all host-PMU metric extraction; uses SPDK
        per-stage instrumentation only
      - emits phase1_results.csv with an added Cores column

    Also rewrite scripts/phase1_4k/plot_multicore.py to plot Submit_Logic_ns +
    Completion_Logic_ns × CPU_GHZ as the cycles/IO proxy (mirror
    plot_io_breakdown.py's approach).

    Verify with --cores "1 2" --qpairs "1" --qd "128" --steady-time 5
    --uncore-mode 0. Per-core cycles/IO should be roughly invariant
    (within ~10%) — that is the scaling-claim evidence.

    If the rewrite proves harder than ~half a day, STOP and report.
    The single-core data is the paper's primary contribution; the
    multi-core sentence is a defensive add-on, not a blocker.

  TASK 6. Multi-qpair sweep (for Figure 3)
  ----------------------------------------
    After the QD sweep, run a qpair-scaling sweep at fixed QD=128 to
    expose the multi-queue scanning amplification — which is the most
    important argument for Mode 2B over Mode 2A.

    For each uncore-mode N in {0, 1, 2}:
      SSD_CFG=fast_ssd_highiops.cfg ./scripts/phase1_4k/driver_phase1.sh --auto \
        --qd "128" --ios "4096" --qpairs "1 4 16 64" \
        --repeats 3 --steady-time 5 --uncore-mode N \
        --tag ${TAG_BASE}_qpsweep_modeN

  TASK 7. Generate the four paper figures
  ----------------------------------------
    Figure 2 (per-stage breakdown), already has a script:
      conda run -n llm python scripts/phase1_4k/plot_io_breakdown.py \
        --results results/phase1_runs --io-size 4096 \
        --out plots/fig2_io_stage_breakdown
      # Use the *_baseline tag CSVs as input; the breakdown should
      # show much smaller per-stage costs than the pre-retune data.

    Figure 3 (cycles/IO + DRAM bytes/IO bracket vs qpairs):
      Adapt scripts/phase1_4k/plot_phase1.py or write a new script
      scripts/phase1_4k/plot_bracket.py that reads three tags (baseline, modeA,
      modeB) and overlays:
        - left y: cycles/IO (computed from Submit_Logic_ns +
          Completion_Logic_ns × cpu_ghz)
        - right y: Dram_Read_Bytes_Per_IO + Dram_Write_Bytes_Per_IO
          (note: 0 in gem5 — fall back to Other_SPDK_ns × proxy or
          extract from controller stats; ASK USER if unclear)
        - x: qpairs
        - 3 line styles per axis: baseline, modeA, modeB
      Save to plots/fig3_bracket.{png,pdf}.

    Figure 4 (p99 latency vs CQ_BATCH_N):
      This requires a parameter sweep over CQBatchN, which is in
      fast_ssd_highiops.cfg, NOT in driver_phase1.sh. You must:
        - Programmatically rewrite the CQBatchN = N line in
          fast_ssd_highiops.cfg before each run, then run.
        - Cycle through N in {1, 4, 16, 64} for both modes A and B.
      Save to plots/fig4_p99_vs_cqbatchn.{png,pdf}.

    Figure 1 (system block diagram) — you do NOT generate this. It is
    a hand-drawn architectural figure for the paper. Skip it.

  TASK 8. Final report (write to docs/EXPERIMENT_RESULTS.md)
  ----------------------------------------------------------
    A new file. Include:
      - Verification of TASK 1 (achieved IOPS at QD=128)
      - SPDK rebuild verification (TASK 2 strings output)
      - For each regime: peak IOPS, mean cycles/IO at QD=128, mean
        DRAM bytes/IO, mean p99 latency
      - Side-by-side table: SPDK baseline vs Mode 2A vs Mode 2B
      - Side-by-side bracket reduction: percent improvement of 2A and
        2B over baseline for cycles/IO, DRAM bytes/IO, p99
      - List of generated figure files
      - Anything that surprised you or that the user should examine
        before drafting the paper

────────────────────────────────────────────────────────────────────
OPERATING DISCIPLINE — these conventions are not optional
────────────────────────────────────────────────────────────────────

  Always launch sims via tmux. A sweep takes 5-20 hours; a bare-shell
  launch will die on disconnect. Use:
      tmux new -d -s <name>
      tmux send -t <name> "<command>" Enter
  Read with: tmux capture-pane -t <name> -p | tail -50

  Do NOT poll the log frequently. gem5 progresses slowly; new
  gem5.out lines may appear only every 10-30 minutes. Polling every
  minute wastes tokens and provides no information. Cadence:
    - Right after launch:       check once at +5 min (gem5 booted?)
    - Mid-run:                  every 15-30 min
    - After completion markers: every 1-2 min until gem5 stops

  KNOWN QUIRK: gem5 does not always auto-stop after a sweep completes.
  driver_phase1.sh --auto is *supposed* to stop gem5 once the readfile
  script prints PHASE1_RUNSCRIPT_DONE, but in practice gem5 sometimes
  hangs and stays alive. The tmux session looks finished (SPDK
  printed its IOPS/latency block, output saved to /mnt/9p/results/...),
  but ./scripts/boot_gem5.sh status still says "running".

  How to handle this:
    1. tmux capture-pane -t <session> -p | tail -50
    2. Look for ANY of:
         - PHASE1_RUNSCRIPT_DONE
         - the SPDK summary block (IOPS, MiB/s, Average, min, max)
         - "Detected readfile script completion. Stopping gem5..."
    3. If a marker has been visible for >3 min AND gem5 is alive,
       it is hanging. Stop it manually:
         ./scripts/boot_gem5.sh stop
         ./scripts/boot_gem5.sh status   # confirm gone
         tmux kill-session -t <session>
       Do NOT kill -9 gem5 directly; it orphans diod.
    4. No extract step needed: results are already at
         results/phase1_runs/<tag>/   (on the host workspace)
       because virtio-9p wrote them directly during the run.

  The CSV is already valid at this point — the gem5 hang does not
  corrupt data; SPDK already flushed its outputs before the hang.

  Never run two gem5 instances in parallel. They fight for cores and
  slow each other down. Finish one regime, then start the next.

────────────────────────────────────────────────────────────────────
RED FLAGS — STOP AND ASK THE USER IF ANY OCCUR
────────────────────────────────────────────────────────────────────

  - Verify run shows IOPS < 10 M at QD=128. Do NOT iterate on the
    config without explicit user confirmation; the high-IOPS config
    was reasoned through carefully and changing it is a paper-wide
    decision, not an agent decision.
  - SPDK build fails for environmental reasons. Do NOT silently fall
    back to the old binary; the patch is non-optional.
  - Disk-image bake fails partway. Do NOT delete the image to retry;
    the user has data on it.
  - Mode 2B run shows IDENTICAL cycles/IO and identical scans-per-
    completion to Mode 2A. This means either (a) the SPDK_UNCORE_MODE_B
    env var did not propagate, (b) the patch did not link in, or
    (c) the device-side hint register is always returning non-zero.
    Investigate, but do NOT modify the patch — report findings.
  - Any panic in gem5.out: `tail -50 logs/gem5.out` and report.
  - Disk space drops below 20 GB free.
  - Wall time per regime exceeds 4 hours (something is wrong with the
    config or instrumentation).

────────────────────────────────────────────────────────────────────
SCOPE GUARDRAILS — DO NOT DO ANY OF THE FOLLOWING
────────────────────────────────────────────────────────────────────

  - ⚠ DO NOT INVOKE sudo OR ANY ROOT-REQUIRING COMMAND. The agent runs
    on a Linux server WITHOUT root privileges. The entire workflow is
    designed to be sudo-free via virtio-9p sharing. Specifically:
      - DO NOT run scripts/bake_disk_image.sh
      - DO NOT run scripts/extract_phase1_results.sh
      - DO NOT run scripts/resize_disk_image.sh
      - DO NOT prefix any command with "sudo"
    These are all unnecessary. Results land directly on the host
    workspace via /mnt/9p. The SPDK binary is read directly from
    docker_artifacts/ via /mnt/9p. If you find yourself needing root
    for any reason, STOP and report — that is a workflow bug, not
    something to bypass.
  - Do not edit docs/PAPER_CHAPTER_PLAN.md or docs/PAPER_IMPL_TODO.md.
  - Do not modify spdk/lib/nvme/nvme_pcie*.{c,h}.
  - Do not modify SimpleSSD source (SimpleSSD-FullSystem/src/).
  - Do not edit fast_ssd_highiops.cfg unless TASK 1 fails AND the user
    has confirmed the change.
  - Do not invoke scripts/phase1_run_multicore.sh as it is — it is
    BROKEN against the gem5 stack. See PAPER_IMPL_TODO §(4). If you
    need multi-core data, write the gem5-compatible variant per TASK 5b.
  - Do not write the actual paper text. The chapter plan is for the
    user to execute; you are providing data only.
  - Do not run RTL synthesis (PAPER_IMPL_TODO item 6). That requires
    Synopsys Design Compiler and is out of scope for this agent.
  - Do not commit or push to git unless explicitly asked.

────────────────────────────────────────────────────────────────────
PROGRESS REPORTING
────────────────────────────────────────────────────────────────────

  After each TASK completes, write a one-paragraph status update.
  After all TASKs complete, write the final report at
  docs/EXPERIMENT_RESULTS.md.

  At any red flag, stop work and write the situation to the user
  before doing anything else.

End of handoff prompt.
```

> End copy-paste.

---

## C. Files to provide / point the agent at

The handoff prompt above already tells the agent which files to read. For convenience, here is the priority-ordered list:

| # | File | Why the agent needs it | Read order |
|---|---|---|---|
| 1 | `docs/PAPER_CHAPTER_PLAN.md` | Master strategic context — what the paper is, what evidence is required | First |
| 2 | `docs/PAPER_IMPL_TODO.md` | Primary task list with exact commands and verification steps | Second |
| 3 | `docs/PROJECT_CONTEXT.md` | Simulator onboarding — what each component does, how to read CSVs | Third |
| 4 | `CLAUDE.md` | Build commands, key constraints, gem5 detachment story | Fourth |
| 5 | `scripts/scripts_manual.md` | Script reference for which command does what | Fifth |
| 6 | `fast_ssd_highiops.cfg` | The retuned SimpleSSD config to run against | When starting Task 1 |
| 7 | `spdk/lib/nvme/nvme_pcie_internal.h` (+22 LOC patch) | To know what was patched and why | When starting Task 2 |
| 8 | `spdk/lib/nvme/nvme_pcie.c` (+22 LOC patch) | The BAR mapping site | When starting Task 2 |
| 9 | `spdk/lib/nvme/nvme_pcie_common.c` (+15 LOC patch) | The hot-path early-exit | When starting Task 2 |
| 10 | `scripts/phase1_4k/driver_phase1.sh` | How to invoke a sweep with mode toggling | When starting Task 5 |
| 11 | `scripts/phase1_4k/phase1_run.sh` | The in-guest workload driver (needs Task 4 patch) | When starting Task 4 |
| 12 | `scripts/phase1_4k/plot_io_breakdown.py` | Figure 2 generator template | When starting Task 7 |
| 13 | `results/phase1_qd128_iouncoreB/core0_qp1/phase1_results.csv` | Reference baseline CSV format the agent should produce | For format awareness |

If your agent platform supports `@file` references or attachments, attach 1–6 explicitly. The rest the agent can read on demand from the working directory.

---

## D. What "done" looks like

The agent should not declare done until ALL of the following exist:

1. `results/phase1_runs/<TAG>_baseline/` directory with valid `phase1_results.csv` showing IOPS ≥ 10 M
2. `results/phase1_runs/<TAG>_modeA/` directory with measurably lower cycles/IO than baseline
3. `results/phase1_runs/<TAG>_modeB/` directory with measurably lower scanning ratio (Scans_Per_Completion) than Mode A — this is **the critical verification that Mode B host patch is actually firing**
4. (Multi-qpair) Three more `_qpsweep_mode{0,1,2}` directories
5. `plots/fig2_io_stage_breakdown.{png,pdf}` regenerated against new data
6. `plots/fig3_bracket.{png,pdf}` showing three-line bracket
7. `plots/fig4_p99_vs_cqbatchn.{png,pdf}` showing latency-vs-batch trade
8. `docs/EXPERIMENT_RESULTS.md` with the final summary table

If item 3 fails (Mode B looks identical to Mode A), the SPDK patch did not activate at runtime. Treat this as a red flag; do not let the agent paper over it.

---

## E. Rough cost estimate

| Resource | Rough budget |
|---|---|
| Wall time | ~12–24 hours of mostly-idle waiting punctuated by ~1 h of agent work |
| Agent tokens (large model) | ~$15–40 depending on agent verbosity and how much it reads/re-reads context |
| Host CPU × hours | ~30–60 core-hours (gem5 is single-threaded but greedy) |
| Disk usage | ~20–40 GB results + log accumulation |
| Sudo prompts | 4–6 (image bakes + result extracts) |

If you delegate to a fully-autonomous setup (e.g., Claude Code with `--dangerously-skip-permissions` in a sandbox), expect the agent to need long polling cycles between gem5 launches; some agent harnesses handle this via background-task primitives or cron-style wakeups, others handle it poorly. Watch for runaway polling.

---

## F. Iterating on this prompt

If the agent gets stuck or surfaces an unexpected obstacle, edit this file and re-launch the agent with the updated version. Common adjustments:

- **Tighten scope:** if the agent is over-exploring, add to §"SCOPE GUARDRAILS"
- **Add gotcha:** if the agent hits a known infrastructure issue, document it in §"RED FLAGS"
- **Adjust task sequence:** if it turns out, e.g., the multi-qpair sweep should come before the QD sweep, swap them in §"TASK PLAN"
- **Add new context file:** if a doc the agent needs isn't listed, add it to §"CONTEXT — READ THESE FILES IN ORDER"

---

*End of agent handoff prompt artifact.*
