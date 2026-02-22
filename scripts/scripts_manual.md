# Scripts Manual

This document summarizes each shell script in this folder and provides a complete end-to-end workflow for running Phase 1 in gem5 full-system mode.

## Script Purpose (Shell Scripts)

- bake_disk_image.sh
  - Mounts the gem5 disk image and copies the host repo into the guest image under /root/SimpleSSD_Gem5_simulation.
  - Requires root/sudo.

- boot_gem5.sh
  - Starts, stops, or checks status of the gem5 full-system simulation on the host.
  - Accepts environment overrides for kernel, disk image, SSD config, checkpoints, and readfile script.

- console_gem5.sh
  - Opens a host-side console to the gem5 serial port using nc or telnet.

- driver_bdev.sh
  - Orchestrates a bdev malloc/null performance sweep inside the gem5 guest.
  - Boots gem5, attaches a console, injects commands, and captures logs (auto mode).

- driver_phase1.sh
  - Orchestrates the full Phase 1 random read workload inside the gem5 guest.
  - Supports readfile mode (boot-time script) and console injection mode.

- extract_phase1_results.sh
  - Mounts the gem5 disk image and copies results from the guest back to the host.
  - Requires root/sudo.

- phase1_bdev.sh
  - Runs the bdevperf malloc-mode sweep in the guest.
  - Produces phase1-style CSV output under results/bdev_data/.

- phase1_run.sh
  - Runs the Phase 1 random read sweep against the NVMe/SimpleSSD device in the guest.
  - Produces phase1_results.csv under results/phase1_runs/.

- phase1_run_multicore.sh
  - Runs Phase 1 across multiple cores in the guest with a predefined multicore sweep.

## End-to-End Workflow (Baked Image)

This workflow assumes you have root/sudo access and want to avoid host file sharing.

1) Bake the repo into the disk image (root required)

- From the repo root (SimpleSSD_Gem5_simulation/):

  sudo ./scripts/bake_disk_image.sh \
    --disk-image ./assets/x86-ubuntu.img \
    --src-repo . \
    --dst-path /root/SimpleSSD_Gem5_simulation

2) Run the Phase 1 smoke test in gem5

- From the repo root:

  ./scripts/driver_phase1.sh --auto \
    --qd "16" \
    --ios "4096" \
    --repeats 1 \
    --steady-time 10 \
    --tag phase1_smoke

3) Extract results from the disk image (root required)

- From the repo root:

  sudo ./scripts/extract_phase1_results.sh \
    --disk-image ./assets/x86-ubuntu.img \
    --run-tag phase1_smoke

- Results will be copied into ./results/phase1_runs/phase1_smoke/ on the host.

4) Scale up the sweep

- Adjust parameters in driver_phase1.sh or override via CLI:

  ./scripts/driver_phase1.sh --auto \
    --cores "1" \
    --qpairs "1" \
    --qd "16 32 64 128" \
    --ios "4096 16384" \
    --repeats 3 \
    --steady-time 30 \
    --tag phase1_full

5) Extract results for the full run (root required)

  sudo ./scripts/extract_phase1_results.sh \
    --disk-image ./assets/x86-ubuntu.img \
    --run-tag phase1_full

## Notes

- Use readfile mode (default) for deterministic, boot-time execution.
- If the repo or SPDK binaries change, re-run bake_disk_image.sh before the next run.
- If you want to run the bdev-only sweep instead, use driver_bdev.sh and then extract results from results/bdev_data/ inside the guest image.
