# SimpleSSD + gem5 + SPDK — NVMe Performance & IO-Uncore Study

Full-system NVMe SSD performance simulation that combines:

- **gem5** (X86 full-system simulator) — the host CPU, DRAM, and OS environment
- **SimpleSSD** (HIL/ICL/FTL/NAND model attached as a PCIe NVMe device)
- **SPDK** (`spdk_nvme_perf` running inside the simulated guest as the workload generator)

The research goal is to measure CPU cycles per I/O on a realistic NVMe path and
identify the point at which the host CPU — not the SSD — becomes the bottleneck
as IOPS scale toward the millions. Findings motivate an **IO-Uncore** hardware
offload block whose RTL design lives under [`RTL_design/`](RTL_design/) and is
synthesized against the ASAP7 7 nm predictive PDK with Yosys.

```
   Host (real machine)
   └── gem5.opt
         ├── X86 O3CPU @ ~1 GHz, 4 GB DRAM
         ├── SimpleSSD NVMe model (3 controller cores @ 400 MHz, PCIe Gen2 x4)
         ├── Linux 5.4.49 guest
         └── diod (host-side 9p server, child of gem5)
                └── exposes the workspace at /mnt/9p inside the guest

   Guest workflow:  mount /mnt/9p  →  bind NVMe to SPDK  →  spdk_nvme_perf sweep
                                                          └── results land
                                                              directly on host
```

Two parallel work streams live in this repo:

1. **Phase 1/2 — full-system simulation** (gem5 + SimpleSSD + SPDK).
2. **Phase 3 — IO-Uncore RTL** (ASAP7 / Yosys synthesis under `RTL_design/`).

For deeper architectural context see `docs/PROJECT_CONTEXT.md` (high-level
onboarding) and `scripts/scripts_manual.md` (script reference + end-to-end
workflow).

---

## Quick set-up

### 1. Clone the repo

```bash
git clone https://github.com/fangyunh/Gem5-simpleSSD-SPDK-simulation.git
cd Gem5-simpleSSD-SPDK-simulation
```

### 2. Fetch the assets

`assets/` is gitignored because it holds large binaries. Create the directory
and download two files into it:

```bash
mkdir -p assets

# Guest kernel (~24 MB) — gem5 stock kernel
wget -O assets/vmlinux-5.4.49 \
  http://dist.gem5.org/dist/v21-2/kernels/x86/static/vmlinux-5.4.49
```
Guest disk image (Ubuntu 18.04 LTS, ~16 GB raw) — gem5-resources
Access the "https://resources.gem5.org/resources/x86-ubuntu-18.04-img?database=gem5-resources&version=1.0.0" to download the image and placed under assets/ folder.

#### About the kernel `.config`

The repo does **not** include a stand-alone `.config` for the guest kernel. Two
cases:

- **Stock workflow (bake + extract, no 9p)** — the gem5 dist `vmlinux-5.4.49`
  above works as-is. No rebuild needed.
- **9p-mount workflow (current default)** — needs a kernel with VFIO + UIO +
  virtio-9p enabled. The stock vmlinux from gem5.org does **not** have these.
  Rebuild it with `scripts/build_guest_kernel_vfio.sh`, which downloads the
  matching kernel source and flips the required toggles
  (`IOMMU_API`, `INTEL_IOMMU`, `VFIO`, `VFIO_PCI`, `NET_9P`, `9P_FS`,
  `HUGETLBFS`, …; full list is in the script):
  ```bash
  ./scripts/build_guest_kernel_vfio.sh           # builds & overwrites assets/vmlinux-5.4.49
  ./scripts/build_guest_kernel_vfio.sh --config /path/to/.config  # use your own
  ```
  The locally-built vmlinux on the original development machine was compiled
  without `CONFIG_IKCONFIG=y`, so its embedded config can't be recovered.
  The build script encodes the required deltas explicitly, which is the
  authoritative source for the configuration.

### 3. Compile gem5 (with SimpleSSD)

```bash
# Python 2.7 + SCons 3.x are required to build gem5
conda create -n simplessd_env python=2.7 -y
conda run -n simplessd_env pip install scons==3.1.2 ply six

cd SimpleSSD-FullSystem
conda run -n simplessd_env \
  env LD_LIBRARY_PATH=$CONDA_PREFIX/lib:${LD_LIBRARY_PATH:-} \
  scons -j$(nproc) build/X86/gem5.opt
cd ..
```

This produces `SimpleSSD-FullSystem/build/X86/gem5.opt` (~1.1 GB, ~30 min).
SimpleSSD is statically linked into the binary — no separate build step.

### 4. Bake the disk image (only if scripts or binaries changed)

```bash
# Optional: grow the image first
sudo ./scripts/resize_disk_image.sh --disk-image ./assets/x86-ubuntu.img --size 8G

# Sync the repo into /root/SimpleSSD_Gem5_simulation inside the guest
sudo ./scripts/bake_disk_image.sh \
  --disk-image ./assets/x86-ubuntu.img \
  --src-repo . \
  --dst-path /root/SimpleSSD_Gem5_simulation
```

### 5. Run a simulation

Always launch from inside `tmux` — runs take hours and gem5 is detached
(`setsid` + `nohup`) so it survives SSH disconnects.

```bash
# Smoke test (quick sanity check)
./scripts/driver_phase1.sh --auto \
  --qd "16" --ios "4096" --repeats 1 --steady-time 10 --tag phase1_smoke

# Full sweep
./scripts/driver_phase1.sh --auto \
  --cores "1" --qpairs "1" \
  --qd "16 32 64 128" --ios "4096 16384" \
  --repeats 3 --steady-time 30 --tag phase1_full

# Live monitoring
tail -f logs/gem5.out                  # raw gem5 output
./scripts/console_gem5.sh              # interactive guest serial console
```

Results stream straight to `results/phase1_runs/<tag>/` via the 9p mount. To
copy results out of the disk image after a non-9p run:

```bash
sudo ./scripts/extract_phase1_results.sh \
  --disk-image ./assets/x86-ubuntu.img --run-tag phase1_smoke
```

### 6. Plot results

```bash
python3 scripts/plot_phase1.py        # IOPS / latency curves
python3 scripts/plot_multicore.py     # multi-core sweep
python3 scripts/plot_bdev.py          # bdev malloc/null baseline
```

See `scripts/scripts_manual.md` for every flag and the end-to-end workflow.

---

## RTL synthesis (IO-Uncore, ASAP7 + Yosys)

All Phase 3 work lives under `RTL_design/`.

```
RTL_design/
├── src/         # Verilog: io_uncore_top, sq_engine, cq_engine,
│                #          db_coalescer, mmio_decoder, sram_arbiter[_synth],
│                #          sram_blackbox, credit_manager, stat_counters
├── tb/          # Per-module testbenches (icarus verilog)
├── lib/         # ASAP7 standard-cell Liberty files + trimmed variants
├── synth/       # Yosys flow: run_synth_yosys.tcl, run_all_configs.sh, SDC
├── scripts/     # parse_reports.py, sram_area_model.py, plot_ppa.py, ...
├── reports/     # stat_<NQ>_<QD>.rpt + yosys logs (regenerated)
├── netlists/    # Synthesized gate-level Verilog (regenerated)
└── setup_instructions.md, ASAP7_SETUP_LOG.md, ASAP7_PDK_Setup_instruction.txt
```

### Prerequisites

- **Yosys 0.64+** — `sudo apt install yosys` (or build from source)
- **Icarus Verilog** — `sudo apt install iverilog gtkwave` (RTL simulation)
- **ASAP7 standard-cell libs** — already checked in under `RTL_design/lib/`
  (Liberty `.lib` for AO/OA/SIMPLE/SEQ/INVBUF cell families, RVT TT corner)

No commercial Synopsys/Cadence tools are needed for the default flow; Design
Compiler is documented in `RTL_design/setup_instructions.md` as an optional
alternative.

### Run the synthesis sweep

```bash
cd RTL_design
bash synth/run_all_configs.sh
```

The script sweeps four `(NUM_QUEUES, QUEUE_DEPTH)` configurations from the
spec (`16/64`, `64/64`, `16/128`, `64/128`) and emits per-config
`reports/stat_<NQ>_<QD>.rpt`, `reports/yosys_log_*.log`, and
`netlists/io_uncore_<NQ>_<QD>.v`.

### Run the testbenches

```bash
cd RTL_design/tb
iverilog -g2012 -o tb_out ../src/<module>.v tb_<module>.v && vvp tb_out
```

### Generate paper figures (PPA + SRAM area)

```bash
cd RTL_design
python3 scripts/parse_reports.py            # stat_*.rpt -> machine-readable
python3 scripts/sram_area_model.py          # analytical SRAM area in mm^2
python3 scripts/plot_ppa.py                 # PDF figures for the paper
```

---

## Key constraints (please read before running)

- **virtio-9p (`diod`) must be installed on the host.** The default workflow
  mounts the host workspace inside the guest at `/mnt/9p`; no other file-share
  mode is wired up.
- **SPDK binary**: use `docker_artifacts/guest_spdk_nvme_perf` (built in an
  `ubuntu:18.04` Docker container for glibc 2.27 compatibility, with no SSSE3
  instructions that would crash on gem5's simulated CPU).
- **Conda is required at run-time** — `boot_gem5.sh` auto-detects it to find
  `libpython` for gem5's Python scripting interface.
- Re-run `bake_disk_image.sh` after any change to `scripts/phase1_run.sh`,
  `docker_artifacts/`, or `fast_ssd.cfg`.
- Never `kill -9` the gem5 process. Use `./scripts/boot_gem5.sh stop`.

---

## Repository layout

```
.
├── assets/                      # gitignored: vmlinux + disk image (download)
├── docker_artifacts/            # guest_spdk_nvme_perf + openssl 1.1 libs
├── docs/                        # PROJECT_CONTEXT.md and design notes
├── fast_ssd.cfg                 # SimpleSSD knobs (NAND/PCIe/CPU/cache)
├── patches/                     # patches applied to upstream sources
├── plans/                       # (legacy) per-phase plan markdown
├── RTL_design/                  # Phase 3 IO-Uncore RTL + synthesis
├── scripts/                     # gem5 driver, kernel build, disk bake, plots
├── SimpleSSD-FullSystem/        # gem5 with SimpleSSD device model
├── spdk/                        # vendored SPDK (used inside the guest)
└── upload_large_files.sh        # rsync helper for fresh remote machines
```
