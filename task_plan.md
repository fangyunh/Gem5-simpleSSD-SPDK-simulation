# Task Plan: Capture DiskANN-BigANN I/O Trace

**Source procedure:** `docs/DISKANN_TRACE_CAPTURE.md`
**Deliverable:** `/home/fangy6/SimpleSSD_Gem5_simulation/artifacts/diskann_bigann_trace.csv`
**Owner:** Yunhua Fang
**Started:** 2026-05-09

## Goal
Produce a peer-acceptable, citation-grounded block-level NVMe I/O trace from DiskANN's
`search_disk_index` running on BigANN, suitable for replay inside the gem5 + SimpleSSD + SPDK
simulator. The trace must pass the §11 validation gates (≥1e6 events, ≥99% reads, ≥50%
4-KB IOs, ≥95% 4-KB-aligned, ≥1 GiB offset span).

## Host facts (verified 2026-05-09)
- Ubuntu 22.04.5, kernel 5.15.0-173-generic, 32 cores, 376 GB RAM
- /home on `/dev/nvme0n1` (Intel SSDPE2KE064T8, 5.8 TB), 2.4 TB free
- Existing conda envs: base, llm, simplessd_env, spdk
- g++ 11.4 (system), cmake 3.22.1 (system), python 3.13 (base)

## Working directories
- DiskANN repo + builds + datasets: `/home/fangy6/diskann-paper/` (all on local NVMe)
- Final trace output: `/home/fangy6/SimpleSSD_Gem5_simulation/artifacts/diskann_bigann_trace.csv`
- Conda env name: `diskann`

## Phases

### Phase 1: Conda environment for DiskANN (status: complete)
Created env `diskann` with python 3.11, gxx_linux-64, cmake, boost, mkl, mkl-devel, libaio.
MKLROOT persisted via `conda env config vars`. §5.3 checklist passed.

### Phase 2: Build DiskANN (§6) (status: complete)
Repo cloned; SHA `df225d32` (tag `0.7.0` — last C++ release before Rust port).
cmake configured with `-DOMP_PATH`, `-DMKL_PATH`, `-DMKL_INCLUDE_PATH=$CONDA_PREFIX/...`
plus `-DCMAKE_POLICY_VERSION_MINIMUM=3.5` (CMake 4 compatibility).
Built `search_disk_index` (975 KB) and `build_disk_index` (1.9 MB) at
`/home/fangy6/diskann-paper/DiskANN/build/apps/`.

### Phase 3: Build the libaio interception shim (§9) (status: complete)
`aio_trace_shim.so` at `/home/fangy6/diskann-paper/tools/aio_trace_shim.so`. Smoke
test with `/bin/true` produces a header-only CSV — confirms LD_PRELOAD path and
constructor fire correctly.
Mod from §9 source: dlsym(RTLD_NEXT, io_submit) is now LAZY (called inside the wrapper)
not eager (in __constructor__), to dodge a load-order issue when LD_PRELOAD'd against
processes that load libaio after the shim. Also added optional `DISKANN_TRACE_APPEND=1`
env var so a multi-run capture can be done without recompiling (per §10.3 footnote).

### Phase 4: Decision checkpoint — 1B vs 100M (status: complete)
User confirmed 100M scale via AskUserQuestion. Logged in decisions.
Per §7.1, both BigANN-1B and BigANN-100M are peer-acceptable. Trade-off:
- 1B: 140 GB download (3–8 h) + ~24–48 h index build, paper sentence cites Simhadri'22 directly.
- 100M: 14 GB index after build, ~3–10 h, paper sentence says "100M subset of BigANN-1B".
Default: **100M** (faster path to a passing trace; doc says I/O *pattern* is statistically
identical). Will pause here for user override if they want 1B.

### Phase 5: Acquire dataset (§7) (status: complete)
- Doc URLs are template placeholders (`...`); used canonical filenames from
  `harsha-simhadri/big-ann-benchmarks` (`base.1B.u8bin`, `query.public.10K.u8bin`,
  `GT.public.1B.ibin`) on `https://dl.fbaipublicfiles.com/billion-scale-ann-benchmarks/bigann/`.
- Saved bandwidth via HTTP-range download: only first 12,800,000,008 bytes (8-byte header +
  100M × 128 of u8 vectors) instead of the full 128 GB, matching big-ann-benchmarks'
  `crop_nb` recipe. 4 minutes at 51 MB/s.
- Header patched in-place: `npts: 1,000,000,000 → 100,000,000` via `tools/patch_header.py`.
- Files at `/home/fangy6/diskann-paper/datasets/bigann/`:
  - base.1B.u8bin.crop_nb_100000000 (12.8 GB, 100M × 128 u8)
  - query.public.10K.u8bin (1.28 MB)
  - GT.public.1B.ibin (8 MB, 1B-scale GT — kept for reference)
  - bigann-100M.gt (8 MB, 100M-scale GT — used by search)

### Phase 6: Build the disk index (§8) (status: complete)
Built 2026-05-09 16:11–20:02 UTC (3h 51m wall, 13850 s indexing time).
Sharded into 3 sub-shards (62M / 67M / 69M with 2× replication for routing), each
graph-built independently then merged. Final disk index 39 GB (`bigann100M_R64_L100_disk.index`)
— larger than doc's "~14 GB" rough estimate but consistent with R=64 layout
(full vectors + adjacency lists at 4 bytes × 64 + page padding).
Index size recorded to `~/diskann-paper/index-meta.txt`: 40,960,004,096 bytes.

### Phase 7: Run the capture (§10) (status: complete)
First run produced 1,225,846 events in 72.6 s wall — already over the 10⁶ gate, so no
loop needed. Search stats from DiskANN: 137.76 QPS, 7058 µs mean latency, 122.58 IOs/query,
67.33% Recall@10. The shim startup banner appeared as expected. Trace at
`~/diskann-paper/captures/diskann_bigann100M_20260509_200328.csv` (46 MB).

### Phase 8: Validate (§11) (status: complete)
All five gates passed:
- Total events: 1,225,846 (≥ 10⁶)
- Read fraction: 100.00% (≥ 99%)
- 4 KB IO fraction: 100.00% (≥ 50%)
- 4 KB-aligned offsets: 100.00% (≥ 95%)
- Offset span: 38.15 GiB (≥ 1 GiB)

### Phase 9: Write metadata header + land in artifacts (§10.4 + §12) (status: complete)
Built the metadata block from live host facts (hostname, kernel, lsb_release,
/sys/block/nvme0n1 fields, ext4 from `findmnt`) plus engine SHA + index size + counts
derived directly from the trace. Wrote 24 `# `-prefixed lines, then concatenated the raw
CSV. Final deliverable:
- `artifacts/diskann_bigann_trace.csv` — 46,105,534 bytes
- `artifacts/diskann_bigann_trace.sha256` — `470bfdd1d5e545652a33fa51d26bbc75fa60094601cef7cb717d53a0fb64d522`

## Decisions log
- 2026-05-09: Default to BigANN-100M scale (per §7.1, peer-acceptable; saves ~5–10×
  wall-time vs 1B). Will revisit if user requests 1B.
- 2026-05-09: Build directory on /home (LVM-backed nvme0n1) since /home has 2.4 TB free
  and is on real NVMe (TRAN=nvme, ROTA=0). NVMe target: `/dev/nvme0n1` (Intel SSDPE2KE064T8).
- 2026-05-09: Used DiskANN tag `0.7.0` (no `v` prefix). Doc said `v0.6.0` but that tag
  doesn't exist; tags `v0.45+` are all Rust-port releases without C++ CMake. Tag `0.7.0`
  (SHA `df225d32`) is the newest C++ release per the doc's apps/search_disk_index target.

## Errors encountered
| Phase | Error | Attempt | Resolution |
|-------|-------|---------|------------|
| 2 | Doc tag `v0.6.0` doesn't exist; latest `v0.51.0` is a Rust port with no top-level CMakeLists.txt | 1 | Use `0.7.0` instead (last C++ release, tag scheme is no-`v`-prefix). |
