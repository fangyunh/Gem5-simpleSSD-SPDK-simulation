# SimpleSSD + gem5 + SPDK Phase 1 Project Context

## Motivation
We are building a repeatable full-system simulation workflow to evaluate SSD performance using gem5 + SimpleSSD + SPDK. The goal is to run a Phase 1 experiment suite (random read) in a controlled environment, collect performance data, and extract results reliably from a disk image.

## High-level Goals
- Boot gem5 full-system with SimpleSSD NVMe model and a Linux guest.
- Run SPDK workloads (spdk_nvme_perf) for Phase 1 sweeps.
- Capture performance metrics and logs in the guest.
- Extract results back to the host with minimal manual steps.
- Make the workflow robust (preflight checks, clear errors, consistent artifacts).

## Current Workflow Overview
### A) virtio-9p + readfile mode (preferred, no baking/extraction)
1. Ensure gem5 binary exists (`SimpleSSD-FullSystem/build/X86/gem5.opt`).
2. Run `driver_phase1.sh --auto` with `--use-readfile 1 --auto-9p 1` and host share path.
3. Guest mounts `/mnt/9p`, runs `scripts/phase1_run.sh` through readfile, and writes outputs to `/mnt/9p/results/<RUN_TAG>`.
4. Results are directly visible on host under `results/<RUN_TAG>`.

### B) baked-image mode (legacy fallback)
1. Build SPDK artifacts in Docker.
2. Bake artifacts and repo into guest disk image.
3. Run gem5 + phase1.
4. Extract results from disk image.

## Key Repos/Paths
- Workspace root: /home/fangyunh/Documents/SimpleSSD_Gem5_simulation
- gem5: SimpleSSD-FullSystem/
- SPDK: spdk/
- Scripts: scripts/
- Results (host): results/phase1_runs/
- Docker artifacts: docker_artifacts/

## Important Scripts
- scripts/build_spdk_docker.sh
  - Builds spdk_nvme_perf in Ubuntu 18.04 container.
  - Outputs: docker_artifacts/guest_spdk_nvme_perf and guest_openssl11.
- scripts/bake_disk_image.sh
  - Bakes repo and artifacts into guest disk image.
  - Defaults to use docker_artifacts outputs.
- scripts/driver_phase1.sh
  - Orchestrates gem5 run; now defaults to readfile mode.
  - Writes metadata and combined logs on host.
- scripts/phase1_run.sh
  - Runs SPDK setup (hugepages) and spdk_nvme_perf sweep in guest.
  - Now uses -l core list; falls back to --no-huge if no hugepages.
- scripts/extract_phase1_results.sh
  - Mounts disk image and copies results back to host.

## Command Flow (virtio-9p + readfile)
Use this as the default full-system simulation flow.

1. **(One-time) Ensure gem5 binary is built**
  ```bash
  cd /home/fangyunh/Documents/SimpleSSD_Gem5_simulation/SimpleSSD-FullSystem
  source "$HOME/miniconda3/etc/profile.d/conda.sh"
  conda activate simplessd_env
  scons build/X86/gem5.opt -j"$(nproc)"
  ```

2. **Run full workflow (recommended single command)**
  ```bash
  cd /home/fangyunh/Documents/SimpleSSD_Gem5_simulation
  ./scripts/driver_phase1.sh \
    --auto \
    --use-readfile 1 \
    --auto-9p 1 \
    --host-share /home/fangyunh/Documents/SimpleSSD_Gem5_simulation \
    --tag phase1_smoke
  ```

3. **Check run completion and outputs**
  ```bash
  cd /home/fangyunh/Documents/SimpleSSD_Gem5_simulation
  ls -lah results/phase1_smoke
  ls -1t logs/driver_phase1_*.log | head -n 1
  ```

### Do I need to run boot_gem5.sh first?
- **For normal runs: No.** `driver_phase1.sh --auto` already starts/stops console/boot flow.
- **For precheck/debug only:** you can manually run `scripts/boot_gem5.sh start|status|stop` before a full run.

## Scripts Not Used in virtio-9p + readfile Mode
When using virtio-9p + readfile end-to-end, these are typically not needed:

- `scripts/bake_disk_image.sh` (no repo/artifact baking required)
- `scripts/extract_phase1_results.sh` (no post-run image mount/extraction required)
- `scripts/resize_disk_image.sh` (usually unnecessary for 9p workflow)
- `scripts/console_gem5.sh` (not required in readfile auto mode; useful only for interactive debugging)

Conditionally optional in this mode:
- `scripts/boot_gem5.sh` (optional precheck/debug; `driver_phase1.sh --auto` handles boot)

## Major Changes Made
### Robustness and Correctness
- Added preflight checks for repo presence in disk image.
- Added GEM5_DISABLE_COW option to avoid losing results with COW overlays.
- Improved extraction warnings when results are missing.
- Added dependency checks for libssl, libfuse, libaio, and glibc mismatch.

### SPDK Build Fixes (Docker)
- Build SPDK in Ubuntu 18.04 to match guest glibc 2.27.
- Unified output under docker_artifacts/.
- Export OpenSSL 1.1.1 libs for guest runtime.
- Patched DPDK build to allow disabling SSE4.1/4.2 and avoid SSE intrinsics when disabled.

### DPDK/CPU ISA Workarounds
- DPDK requires SSE4.1/4.2; gem5 CPU lacks SSE4.1.
- Disabled SSE4.1/4.2 in DPDK build.
- Added fallback implementations when SSE4.1/4.2 are unavailable.

### Phase 1 Execution Fixes
- Default core switched to 0 to match single-core guest.
- spdk_nvme_perf uses -l core list instead of deprecated -c coremask.
- Added online CPU validation; fallback to core 0.
- If hugepages are missing, add --no-huge automatically.
- Default SKIP_SETUP=0 to run spdk/scripts/setup.sh in guest.

### Readfile Mode
- Readfile mode is now the default for driver_phase1.sh.
- Readfile script logs include PHASE1_RUNSCRIPT_LOG_BEGIN/END markers.
- Readfile script exits gem5 via m5 exit after completion.

## Phase 1 Results CSV Format
The columns are consistent with the SPDK I/O framework and the surrounding perf instrumentation. The layout is reasonable: it starts with workload parameters, then throughput and CPU/uncore counters, then derived per-IO metrics, then latency and SPDK poller stats, and finally optional SimpleSSD debug timing breakdowns. This ordering matches how phase1_run.sh constructs each row and how the logs are interpreted.

Column details:
- QD: queue depth per queue pair for the run.
- Qpairs: number of queue pairs used by spdk_nvme_perf.
- IO_Size: IO size in bytes (spdk_nvme_perf -o).
- Run_ID: repeat index for the same QD/Qpairs/IO_Size.
- IOPS: total IO operations per second from spdk_nvme_perf "Total" line.
- Cycles: CPU cycles from perf stat (if perf enabled).
- Instructions: retired instructions from perf stat (if perf enabled).
- LLC_Misses: last-level cache misses from perf stat (if perf enabled).
- Dram_Read_Bytes: IMC read bytes from uncore perf events (if available).
- Dram_Write_Bytes: IMC write bytes from uncore perf events (if available).
- Energy_Joules: package energy in joules from power events (if available).
- Cycles_Per_IO: Cycles divided by total IOs for the run.
- Instr_Per_IO: Instructions divided by total IOs.
- LLC_Misses_Per_IO: LLC misses divided by total IOs.
- Dram_Read_Bytes_Per_IO: DRAM read bytes divided by total IOs.
- Dram_Write_Bytes_Per_IO: DRAM write bytes divided by total IOs.
- Energy_Per_IO: Energy in joules divided by total IOs.
- p50_Latency: 50th percentile latency reported by spdk_nvme_perf (typically in microseconds).
- p99_Latency: 99th percentile latency reported by spdk_nvme_perf (typically in microseconds).
- p99.9_Latency: 99.9th percentile latency reported by spdk_nvme_perf (typically in microseconds).
- Polls: total poller loop iterations collected from SPDK stats (if enabled).
- Completions: total IO completions from SPDK stats (if enabled).
- Scans_Per_Completion: poller scan iterations divided by completions.
- Completions_Per_Call: completions divided by poller calls.
- MMIO_Writes_Per_IO: MMIO write count divided by total IOs (SimpleSSD debug counters).
- Completions_Per_Poll_Hist: histogram-derived completions per poll (SimpleSSD debug counters).
- Submit_Logic_ns: time spent in submit logic (SimpleSSD debug counters).
- Completion_Logic_ns: time spent in completion logic (SimpleSSD debug counters).
- Submit_Preamble_ns: time spent in submit preamble (SimpleSSD debug counters).
- Tracker_Alloc_ns: time spent allocating trackers (SimpleSSD debug counters).
- Addr_Xlate_ns: time spent in address translation (SimpleSSD debug counters).
- Cmd_Construct_ns: time spent constructing commands (SimpleSSD debug counters).
- Fence_ns: time spent in fence handling (SimpleSSD debug counters).
- Doorbell_ns: time spent writing doorbells (SimpleSSD debug counters).
- CQE_Detect_ns: time spent detecting completion queue entries (SimpleSSD debug counters).
- Tracker_Lookup_ns: time spent looking up trackers (SimpleSSD debug counters).
- State_Dealloc_ns: time spent deallocating state (SimpleSSD debug counters).

## Current Status (As of 2026-03-17)
- SPDK Docker build succeeds and produces artifacts in docker_artifacts/.
- gem5 run is stable in readfile mode.
- Recent failure: no results extracted because console-injection mode ran before guest was ready; now readfile mode fixes this.
- New failure resolved: DPDK init failed due to missing hugepages; now setup.sh runs and --no-huge fallback exists.

## Remaining Risks / Open Items
- Ensure readfile mode is used consistently for automated runs.
- Confirm hugepages are correctly configured in the guest when using setup.sh.
- Validate performance runs complete and results are written before extraction.
- If results still missing, check readfile logs for repo path discovery and execution errors.

## How to Run (Typical)
### Preferred (virtio-9p + readfile)
1. Ensure gem5 is built (one-time).
2. Run:
  `./scripts/driver_phase1.sh --auto --use-readfile 1 --auto-9p 1 --host-share /home/fangyunh/Documents/SimpleSSD_Gem5_simulation --tag phase1_smoke`
3. Check host output under:
  `results/phase1_smoke`

### Legacy (baked-image path)
1. Build SPDK artifacts:
  `sudo ./scripts/build_spdk_docker.sh`
2. Bake into disk image:
  `sudo ./scripts/bake_disk_image.sh --disk-image ./assets/x86-ubuntu.img`
3. Run Phase 1:
  `sudo ./scripts/driver_phase1.sh --auto --use-readfile 1 --tag phase1_smoke`
4. Extract results:
  `sudo ./scripts/extract_phase1_results.sh --disk-image ./assets/x86-ubuntu.img --run-tag phase1_smoke`

## Debugging Tips
- Check host combined log: logs/driver_phase1_<tag>.log
- Look for PHASE1_RUNSCRIPT_LOG_BEGIN/END in the combined log.
- If extraction finds no results, the guest likely never ran the script.
- If DPDK init fails, check for hugepage config or --no-huge usage.

## Notes for a New Agent
- The main blocker historically was ISA mismatch (SSE4.1). This was mitigated by disabling SSE4.1/4.2 in DPDK and adding fallback code.
- gem5 CPU is single-core by default; core selection must use core 0.
- The workflow is sensitive to whether the repo is baked into the image or mounted via 9p.
- Readfile mode is now preferred to avoid race conditions during boot.
