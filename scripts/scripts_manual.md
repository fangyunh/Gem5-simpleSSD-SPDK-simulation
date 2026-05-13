# Scripts Manual

Top-level index for `scripts/`. The folder is organized into:

- **`scripts/`** (this directory) — shared infrastructure that both
  evaluation pieces use: gem5 boot/stop, console attach, SPDK Docker
  rebuild, disk-image management.
- **`scripts/phase1_4k/`** — 4 KB random-read evaluation (paper §2 Fig 2,
  §4 Fig 3 + Fig 4). See `scripts/phase1_4k/README.md` for the full
  inventory and typical workflows.
- **`scripts/bigann/`** — DiskANN + BigANN-1B trace capture/replay
  (paper §4.1 workload-realism evidence). Currently a placeholder; see
  `scripts/bigann/README.md` and `docs/DISKANN_TRACE_CAPTURE.md`.

## Shared infrastructure (this folder)

- **`boot_gem5.sh`** — Starts, stops, or checks status of the gem5
  full-system simulation. Accepts environment overrides for kernel,
  disk image, SSD config, checkpoints, and readfile script. Used by
  both 4K and BigANN drivers.
- **`console_gem5.sh`** — Opens a host-side console to the gem5 serial
  port using `nc` or `telnet`.
- **`build_spdk_docker.sh`** — Rebuilds the SSSE3-free, glibc-2.27-compatible
  `guest_spdk_nvme_perf` binary inside an Ubuntu 18.04 Docker image.
  **Re-run after any change to `spdk/lib/nvme/`** (e.g., the Mode 2B
  patch and the State_Dealloc split landed 2026-05-09).
- **`build_guest_kernel_vfio.sh`** — Builds a custom guest kernel with
  vfio + virtio-9p built in. Required only on first setup or kernel
  changes.
- **`bake_disk_image.sh`** — Mounts the gem5 disk image and copies the
  host repo into it. **Requires root/sudo.** *Not used in the default
  virtio-9p workflow.* Keep available for the rare case where 9p is
  unavailable.
- **`resize_disk_image.sh`** — Resizes the disk image. **Requires
  qemu-img and root/sudo.** Not used in the default workflow.

## 4 KB random-read evaluation (`scripts/phase1_4k/`)

See `scripts/phase1_4k/README.md` for full details. Quick reference:

| Use case | Command (from repo root) |
|---|---|
| Single-core sweep | `./scripts/phase1_4k/driver_phase1.sh --auto …` |
| Multi-core invariance | `./scripts/phase1_4k/driver_phase1_multicore.sh --auto …` |
| bdev baseline (sanity) | `./scripts/phase1_4k/driver_bdev.sh --auto …` |
| Sequential sweep | `bash scripts/phase1_4k/run_sweep_baseline.sh …` |
| Plot Figure 2 | `python scripts/phase1_4k/plot_io_breakdown.py …` |
| Plot per-core invariance | `python scripts/phase1_4k/plot_multicore_gem5.py …` |

## BigANN trace evaluation (`scripts/bigann/`)

Placeholder. See `scripts/bigann/README.md` for the planned inventory
and `docs/DISKANN_TRACE_CAPTURE.md` for the capture procedure.

## Default workflow (virtio-9p, no sudo)

The default workflow uses **virtio-9p** to share the host workspace with
the gem5 guest. No disk-image baking, no result extraction, no sudo.

```bash
# Single-core Phase 1 smoke test
./scripts/phase1_4k/driver_phase1.sh --auto \
  --qd "16" --ios "4096" --qpairs "1" \
  --repeats 1 --steady-time 5 --uncore-mode 0 \
  --tag phase1_smoke

# Multi-core invariance
SSD_CFG=fast_ssd_highiops.cfg ./scripts/phase1_4k/driver_phase1_multicore.sh \
  --auto --core-counts "1 2" \
  --qd 128 --ios 4096 --qpairs 1 \
  --repeats 1 --steady-time 5 \
  --uncore-mode 0 --tag verify_multicore

# Full sweep (paper §4 evidence collection — runs sequentially, ~hours)
SSD_CFG=fast_ssd_highiops.cfg ./scripts/phase1_4k/driver_phase1.sh --auto \
  --qd "16 32 64 128" --ios "4096" --qpairs "1" \
  --repeats 1 --steady-time 5 --uncore-mode 2 \
  --tag phase1_paper_modeB
```

Results land directly on the host workspace at
`results/phase1_runs/<tag>/core*_qp*/phase1_results.csv` (or
`core_count*_qp*/` for the multi-core variant). No extraction step.

## Legacy "baked image" workflow (root required, deprecated)

This workflow predates the virtio-9p default and is documented only for
the rare environment where 9p is unavailable. It requires root/sudo and
is incompatible with the project's no-sudo policy
(see `docs/PAPER_IMPL_TODO.md` §0.6).

```bash
# 0) Resize disk if needed (root)
./scripts/resize_disk_image.sh --disk-image ./assets/x86-ubuntu.img --size 8G

# 1) Bake the repo into the image (root)
sudo ./scripts/bake_disk_image.sh \
  --disk-image ./assets/x86-ubuntu.img \
  --src-repo . --dst-path /root/SimpleSSD_Gem5_simulation

# 2) Run inside gem5 (no sudo at runtime)
./scripts/phase1_4k/driver_phase1.sh --auto \
  --qd "16" --ios "4096" --repeats 1 --steady-time 10 \
  --tag phase1_smoke

# 3) Extract results back out of the disk image (root)
sudo ./scripts/phase1_4k/extract_phase1_results.sh \
  --disk-image ./assets/x86-ubuntu.img --run-tag phase1_smoke
```

If the repo or SPDK binaries change in this workflow, **re-bake the
image** before the next run. In the default 9p workflow this step is
unnecessary — script edits take effect on the next gem5 launch.

## Notes

- Use readfile mode (default in both drivers) for deterministic
  boot-time execution.
- If the repo is not baked into the disk image, virtio-9p (default
  `--auto-9p 1`) handles file sharing automatically. `diod` must be
  installed on the host.
- `boot_gem5.sh stop` is the **only** correct way to stop gem5 — never
  `kill -9`, which orphans `diod` and may require a reboot.
- After any change to `spdk/lib/nvme/` source, re-run
  `scripts/build_spdk_docker.sh` so `docker_artifacts/guest_spdk_nvme_perf`
  picks up the patches before the next sweep.
