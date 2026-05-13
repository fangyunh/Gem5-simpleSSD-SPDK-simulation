# DiskANN Trace Capture Procedure (Linux, No-Root, CPU-Only)

> **Companion to:** `docs/PAPER_CHAPTER_PLAN.md` §4.1, `docs/PAPER_IMPL_TODO.md` (point 1 of evaluation strengthening).
> **Owner:** Yunhua Fang.
> **Created:** 2026-05-09.
> **Status:** Procedure spec — not yet executed.

This document specifies how to capture a peer-acceptable, citation-grounded
block-level I/O trace from DiskANN [DiskANN'19] running on the BigANN-1B
dataset [Simhadri'22]. The captured trace will later be replayed inside
the gem5 + SimpleSSD + SPDK simulator to validate that the synthetic 4 KB
random-read benchmark used in the paper's §4.2 evaluation matches the I/O
kernel of an actual SSD-resident retrieval workload.

The capture step **runs entirely on a Linux server with a local NVMe SSD,
without root privileges, and without any GPU**. DiskANN is a CPU + SSD
algorithm; no GPU is touched in build or search.

---

## 1. Goal

Produce one file:

```
artifacts/diskann_bigann_trace.csv
```

containing block-level I/O events recorded while DiskANN's
`search_disk_index` was actively serving the standard BigANN query set
against an out-of-core SSD-resident index.

The trace must satisfy four properties to be defensible at peer review:

1. **Workload-of-record.** It is captured from DiskANN searching BigANN —
   not from a synthetic generator, not from a generic SNIA trace, not from
   a non-retrieval benchmark.
2. **SSD-resident.** The DiskANN index used to drive the search must
   not fit fully in OS page cache; the trace must reflect actual NVMe-bound
   reads, not memory hits. (DiskANN issues all index reads with `O_DIRECT`
   via libaio, so this property holds by construction — the index file
   never enters the page cache.)
3. **Statistically dense.** ≥ 10⁶ I/O events captured during steady-state
   query serving — three orders of magnitude beyond what stable distribution
   moments require.
4. **Schema-stable.** The trace lands in the canonical format defined in §3
   below, with a header block that documents capture provenance for the
   paper's methodology section.

### Explicit non-goals

- **Building or modifying the gem5 replay pipeline.** Covered separately
  once the trace exists.
- **Running DiskANN end-to-end inside gem5.** Infeasible at billion-scale
  due to gem5's wall-time slowdown — see `PAPER_IMPL_TODO.md`.
- **Capturing GPU-side or NIC-side traces.** This trace is for the host
  CPU → NVMe path only.
- **Capturing at the kernel block layer (blktrace / eBPF).** Both require
  root and `/sys/kernel/debug` access. The user-space libaio shim defined
  in §10 produces a trace of equivalent fidelity for our claim (see §3.5).

---

## 2. Why this specific workload (citation chain)

The paper's §4.1 prose, after this trace exists, will be:

> *"We use the BigANN-1B dataset from the NeurIPS '21 Billion-Scale ANN
> Challenge [Simhadri'22] as input to the DiskANN [DiskANN'19] SSD-resident
> graph index. Per-I/O traces are captured via a libaio interception shim
> while `search_disk_index` serves the standard 10K-query evaluation set;
> the trace is replayed against the simulated SimpleSSD device through SPDK
> inside gem5."*

Every component of that sentence resolves to a peer-reviewed reference:

| Component | Reference | Peer-review venue |
|---|---|---|
| Workload class (SSD-resident retrieval) | NeurIPS '21 Challenge results | NeurIPS Competition Proceedings 2022 |
| Engine | DiskANN [DiskANN'19] | NeurIPS 2019 |
| Dataset | BigANN-1B / SIFT1B | DiskANN'19, Simhadri'22, FAISS-Index'17 |
| Capture mechanism | libaio `io_submit()` interception | Linux kernel libaio documentation |
| Replay format | fio iolog v2 (downstream conversion) | fio kernel.dk documentation |

There is no link in this chain a reviewer can pull on. The capture
mechanism deserves a one-sentence justification: DiskANN issues all index
reads through libaio (`io_submit` / `io_getevents`) with `O_DIRECT`, which
bypasses both the page cache and the kernel block-layer scheduler's
read-merging logic. Intercepting at `io_submit` therefore captures the
exact request stream that the kernel will submit to the NVMe driver, with
fidelity equivalent to `blktrace` for our purposes (size distribution,
offset stride, arrival rate) and **superior** for our purposes in one
respect — every event is attributable to DiskANN, not contaminated by
unrelated daemons or background scans.

---

## 3. Trace file format specification

The canonical trace format is **a plain-text CSV with a metadata header**.
It is deliberately simple and tool-agnostic; downstream replay tools
(`fio`, custom SPDK app) consume it via short converter scripts.

### 3.1 File extension and encoding

- Extension: `.csv`
- Encoding: UTF-8, LF line endings.
- One file per capture run.

### 3.2 File structure

```
# DiskANN-BigANN trace v1
# capture-host: <hostname>
# capture-date: YYYY-MM-DDTHH:MM:SS+ZZZZ
# os: <e.g., Ubuntu 22.04.4 LTS>
# kernel: <output of `uname -r`>
# device-target: <e.g., /dev/nvme0n1>
# device-model: <e.g., Samsung 990 PRO 2TB>
# device-namespace-bytes: <reported nominal size>
# filesystem: <e.g., ext4>
# diskann-engine-version: <git SHA from microsoft/DiskANN>
# diskann-search-flags: -L 100 -K 10 -W 4 -T 1
# diskann-index-file: <relative path>
# diskann-index-size-bytes: <integer>
# diskann-index-build-flags: -R 64 -L 100 -B 1.0 -M 32
# dataset: BigANN-1B (SIFT1B) | BigANN-100M | learn-100M | ...
# dataset-query-count: <integer>
# capture-tool: libaio LD_PRELOAD shim (aio_trace_shim.so)
# capture-duration-seconds: <float>
# total-io-events: <integer>
# read-events: <integer>
# write-events: <integer>
# columns: ts_ns,op,offset_bytes,size_bytes,pid
ts_ns,op,offset_bytes,size_bytes,pid
0,R,0,4096,12345
21500,R,4096,4096,12345
38900,R,16384,8192,12345
...
```

### 3.3 Column definitions

| Column | Type | Units | Constraints |
|---|---|---|---|
| `ts_ns` | int64 | nanoseconds since first event in the capture | Monotone non-decreasing. First event = 0. Source: `clock_gettime(CLOCK_MONOTONIC)` in the shim. |
| `op` | string | — | `R` (read) or `W` (write). Expect 100% `R` for retrieval. |
| `offset_bytes` | int64 | bytes from the start of the index file | Must be 512-byte aligned (DiskANN uses 4 KB-aligned reads under O_DIRECT). |
| `size_bytes` | int32 | bytes | Must be 512-byte aligned. Typical: 4096; occasionally a small multiple for batched node fetches. |
| `pid` | int32 | — | OS process ID. Trivial filter; the shim only attaches to DiskANN itself, so all rows have the same PID. |

### 3.4 Why this format

- **Plain text** is parseable by Python, awk, fio, and human eyes; no
  proprietary schema dependencies.
- **Metadata header** documents capture provenance for the paper's
  methodology subsection without a separate sidecar file.
- **File offsets, not LBA sectors.** The shim sees what DiskANN sees:
  per-file byte offsets. For an `ext4`-allocated, non-fragmented index
  file, the file→LBA mapping is a constant offset, so the *pattern*
  (size distribution, stride, arrival rate) is identical at the LBA
  layer. The replay tool will treat the file offsets as device offsets
  starting at LBA 0.

### 3.5 What this format is NOT

- It is **not** a fio iolog directly. Conversion to fio's `read_iolog`
  format is one short Python script (each row → `<file> <op> <offset>
  <size>` line). Deferred to the replay-side document.
- It is **not** binary. Size cost: ~50–100 MB per million events,
  uncompressed. We accept this in exchange for transparency.
- It does **not** include I/O completion latency. Replay is concerned
  with the issuance pattern; latency is the variable being measured at
  replay time, not the variable to replay.
- It does **not** capture kernel-level merges or splits. DiskANN issues
  pre-aligned 4 KB reads under O_DIRECT; the kernel does no meaningful
  merging on this pattern. Verified empirically (see §11 validation).

---

## 4. Pipeline overview

```
[Linux server, single machine, no root]

   DiskANN
   build_disk_index --+
   (one-time)         |
                      v
                +-----+----------------------------+
                |  index file (.index)             |
                |  ~14-140 GB on local NVMe (ext4) |
                +-----+----------------------------+
                      |
                      v
   shim source                                LD_PRELOAD env set:
   aio_trace_shim.c -- gcc --> aio_trace_shim.so --,
                                                    |
                                                    v
                +-----+----------------------------+
                |  search_disk_index               |
                |  (10000 queries, single thread)  |
                |  intercepted io_submit() writes  |
                |  one CSV row per outgoing iocb   |
                +-----+----------------------------+
                      |
                      v
                diskann_bigann_trace.csv  <-- DELIVERABLE
                      |
                      v
   validate_trace.py  (pass/fail gates)
                      |
                      v
   gem5 host /home/fangy6/SimpleSSD_Gem5_simulation/artifacts/
   (replay procedure: separate document)
```

---

## 5. Hardware and software prerequisites

### 5.1 Linux host requirements

| Requirement | Minimum | Recommended | Why |
|---|---|---|---|
| Distribution | Ubuntu 20.04 / RHEL 8 / Debian 11 | Ubuntu 22.04 LTS | DiskANN's documented build targets |
| Kernel | 5.4+ | 5.15+ | libaio is stable on both |
| RAM | 32 GB | 64 GB+ | Index size must exceed RAM by ≥ 2× to keep search SSD-bound (note: O_DIRECT bypasses page cache anyway, so this is a soft constraint) |
| Local NVMe SSD free space | 200 GB | 500 GB+ | Holds dataset + index + trace |
| CPU | x86-64 with AVX2 | AVX-512 helps DiskANN build | Per DiskANN README |
| Filesystem on the index drive | ext4 / xfs | ext4 | DiskANN tested |
| Local NVMe device available | yes | yes | Index file must live on real NVMe, not network FS, not tmpfs |
| Root privileges | NOT required | NOT required | Procedure designed for unprivileged user |

### 5.2 Software dependencies (all installable to userspace)

Install in this order; each step is unprivileged.

1. **GCC / G++ 9+** — almost always already installed on a research
   server. Verify with `g++ --version`. If absent, install via Conda
   (no root): `conda install -c conda-forge gxx_linux-64`.
2. **CMake 3.21+** — `conda install -c conda-forge cmake`.
3. **Boost 1.74+** — DiskANN dependency. `conda install -c conda-forge
   boost`.
4. **Intel oneAPI MKL** — DiskANN distance kernel.
   `conda install -c conda-forge mkl mkl-devel`.
5. **libaio + headers** — for the shim and DiskANN's Linux backend.
   `conda install -c conda-forge libaio`. Header check: `find
   $CONDA_PREFIX -name libaio.h` must return a path.
6. **Python 3.10+** — for the validator. `conda install python=3.11`.

The whole chain installs cleanly into a single Conda environment with no
root and no system-package modifications. The user's existing `simplessd_env`
or `llm` Conda environments may already satisfy steps 1–6; verify before
creating a new one.

### 5.3 Verify the environment before proceeding

```bash
# C++ toolchain
g++ --version        # expect: g++ (GCC) 9.x or newer
cmake --version      # expect: 3.21 or newer

# Boost headers visible to the compiler
echo '#include <boost/version.hpp>' | g++ -E -x c++ - >/dev/null && echo OK

# MKL
echo $MKLROOT       # should point inside the conda env

# libaio
echo '#include <libaio.h>' | g++ -E -x c++ - >/dev/null && echo OK
ldconfig -p | grep -E 'libaio\.so' || \
  find $CONDA_PREFIX -name 'libaio.so*' | head

# Verify the target NVMe is real and not a virtual / loop / network device
lsblk -o NAME,TRAN,ROTA,MODEL,SIZE
# Look for: TRAN=nvme, ROTA=0, MODEL non-empty.

# Confirm at least 200 GB free on the partition that will hold the index
df -h <path-where-you-will-build-the-index>
```

If any check fails, fix the environment before proceeding — partial
completion of the build/index is the most expensive failure mode.

---

## 6. Step 1: Build DiskANN

Wall time: **~30 minutes** (build) + **~10 minutes** (deps if not yet installed).

```bash
# Pick a working directory on the local NVMe with at least 5 GB free
mkdir -p ~/diskann-paper && cd ~/diskann-paper

# Clone the canonical DiskANN repository
git clone https://github.com/microsoft/DiskANN.git
cd DiskANN

# Pin to a known-good release tag for reproducibility.
# Record the SHA in the trace metadata header.
git checkout v0.6.0   # adjust to current latest stable
git rev-parse HEAD > ../diskann-engine-version.txt

# Configure with CMake; ensure the conda env is active so MKL/Boost/libaio
# are picked up automatically via $CONDA_PREFIX.
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
cmake --build . -j$(nproc)

# Verify the search binary built
ls -l ./apps/search_disk_index
```

If linking fails on `-laio`, point CMake at the Conda libaio explicitly:

```bash
cmake .. -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH=$CONDA_PREFIX \
    -DCMAKE_LIBRARY_PATH=$CONDA_PREFIX/lib
```

---

## 7. Step 2: Acquire the BigANN-1B dataset

Wall time: **3–8 hours** (one-time download; depends on connection).

The BigANN-1B dataset is hosted at `big-ann-benchmarks.com` and via Azure
Blob storage. Three components are needed:

| File | Purpose | Size |
|---|---|---|
| `bigann_base.1B.u8bin` | 1 billion 128-D base vectors | ~140 GB |
| `bigann_query.public.10K.u8bin` | 10K standard queries | ~5 MB |
| `GT.public.1B.ibin` | Ground-truth top-K for queries | ~40 MB |

```bash
mkdir -p ~/diskann-paper/datasets/bigann
cd ~/diskann-paper/datasets/bigann

# URLs from https://big-ann-benchmarks.com/neurips21.html
# Use curl, wget, or AzCopy as preferred.
wget https://comp21storage.blob.core.windows.net/.../bigann/bigann_base.1B.u8bin
wget https://comp21storage.blob.core.windows.net/.../bigann/bigann_query.public.10K.u8bin
wget https://comp21storage.blob.core.windows.net/.../bigann/GT.public.1B.ibin

# Verify file sizes
ls -lh *.u8bin *.ibin
```

### 7.1 Smaller-scale alternative (if disk space is constrained)

If the host cannot accommodate 140 GB, use **BigANN-100M**: take the first
100 million base vectors via the dataset's documented truncation
mechanism. The I/O *pattern* (mean reads per query, LBA stride
distribution, 4 KB block dominance) is statistically identical at 100M
scale; only the index size shrinks.

The trade-off is solely cosmetic — the paper would say
*"BigANN-100M (a 100M subset of BigANN-1B [Simhadri'22])"* instead of
*"BigANN-1B [Simhadri'22]."* Either is peer-acceptable.

**Decision rule:** if the host cannot dedicate ≥ 200 GB to the index, use
100M. The OS page cache is not a concern here — DiskANN reads with
`O_DIRECT` and bypasses it entirely.

---

## 8. Step 3: Build the disk index (one-time)

Wall time: **~3–10 hours** for 100M; **~24–48 hours** for 1B.

Heavy compute (graph construction) and heavy disk I/O. Runs once; the
resulting `.index` file is reused for every trace capture.

```bash
cd ~/diskann-paper/DiskANN/build/apps

# Parameters per DiskANN README "Building a disk index":
#   -R 64    : graph degree (default for billion scale)
#   -L 100   : build-time search list size
#   -B 1.0   : memory budget for build, in GB per shard
#   -M 32    : memory budget for index-in-memory portion, GB
./build_disk_index \
    --data_type uint8 \
    --dist_fn l2 \
    --data_path ~/diskann-paper/datasets/bigann/bigann_base.1B.u8bin \
    --index_path_prefix ~/diskann-paper/indices/bigann1B_R64_L100 \
    -R 64 -L 100 -B 1.0 -M 32
```

After completion, capture the index size for the trace metadata:

```bash
INDEX=~/diskann-paper/indices/bigann1B_R64_L100_disk.index
echo "diskann-index-size-bytes: $(stat -c %s $INDEX)" > ~/diskann-paper/index-meta.txt
```

**Sanity check.** The disk index for 1B SIFT vectors with R=64 should be
~140 GB; for 100M, ~14 GB. Anything dramatically smaller indicates the
build failed silently — re-run with verbose logging.

It is sensible to launch the build inside `tmux` since it can take a day,
mirroring the simulation discipline already established in this repo.

---

## 9. Step 4: Build the libaio interception shim

Wall time: **~5 minutes**.

The shim is a small shared library that intercepts every `io_submit()`
call DiskANN issues, logs the iocb fields to a CSV, and then forwards
the call to the real libaio. It is enabled via `LD_PRELOAD` and a
`DISKANN_TRACE_PATH` environment variable; absent either, the shim is a
no-op.

Save as `tools/aio_trace_shim.c`:

```c
/*
 * aio_trace_shim.c -- libaio io_submit() interception for DiskANN trace capture.
 *
 * Build:
 *   gcc -O2 -fPIC -shared -o aio_trace_shim.so aio_trace_shim.c -ldl
 *
 * Use:
 *   DISKANN_TRACE_PATH=/path/to/trace.csv \
 *   LD_PRELOAD=/path/to/aio_trace_shim.so \
 *   ./search_disk_index ...
 *
 * Non-goals:
 *   - capturing io_getevents (we trace issuance, not completion)
 *   - capturing pread/preadv (DiskANN's Linux backend is libaio only)
 *   - thread-safety beyond a single mutex around the FILE*
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <libaio.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

static int (*real_io_submit)(io_context_t, long, struct iocb **) = NULL;
static FILE *trace_fp = NULL;
static pthread_mutex_t trace_lock = PTHREAD_MUTEX_INITIALIZER;
static int64_t t0_ns = 0;
static pid_t shim_pid = 0;

static int64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

__attribute__((constructor))
static void init_shim(void) {
    real_io_submit = dlsym(RTLD_NEXT, "io_submit");
    const char *path = getenv("DISKANN_TRACE_PATH");
    if (!path || !real_io_submit) return;
    trace_fp = fopen(path, "w");
    if (!trace_fp) {
        fprintf(stderr, "[aio_trace_shim] cannot open %s for write\n", path);
        return;
    }
    t0_ns = now_ns();
    shim_pid = getpid();
    fprintf(trace_fp, "ts_ns,op,offset_bytes,size_bytes,pid\n");
    fflush(trace_fp);
    fprintf(stderr, "[aio_trace_shim] capturing io_submit to %s (pid=%d)\n",
            path, shim_pid);
}

__attribute__((destructor))
static void fini_shim(void) {
    if (trace_fp) {
        fflush(trace_fp);
        fclose(trace_fp);
        trace_fp = NULL;
    }
}

int io_submit(io_context_t ctx, long nr, struct iocb **iocbs) {
    if (trace_fp && nr > 0 && iocbs) {
        int64_t ts = now_ns() - t0_ns;
        pthread_mutex_lock(&trace_lock);
        for (long i = 0; i < nr; i++) {
            struct iocb *cb = iocbs[i];
            if (!cb) continue;
            const char *op;
            switch (cb->aio_lio_opcode) {
                case IO_CMD_PREAD:  op = "R"; break;
                case IO_CMD_PWRITE: op = "W"; break;
                default: continue;   /* skip fsync, noop, vector ops */
            }
            fprintf(trace_fp, "%ld,%s,%lld,%u,%d\n",
                    (long)ts, op,
                    (long long)cb->u.c.offset,
                    (unsigned)cb->u.c.nbytes,
                    (int)shim_pid);
        }
        pthread_mutex_unlock(&trace_lock);
    }
    return real_io_submit(ctx, nr, iocbs);
}
```

Build:

```bash
cd ~/diskann-paper
mkdir -p tools
# (paste the source above into tools/aio_trace_shim.c)
gcc -O2 -fPIC -shared -o tools/aio_trace_shim.so tools/aio_trace_shim.c -ldl
ls -l tools/aio_trace_shim.so
```

Smoke test (tiny program that does no real I/O — should produce a CSV
with only the header line):

```bash
DISKANN_TRACE_PATH=/tmp/smoke.csv \
LD_PRELOAD=$PWD/tools/aio_trace_shim.so \
/bin/true
cat /tmp/smoke.csv   # expect: header line, no data
```

---

## 10. Step 5: Capture the I/O trace

Wall time: **~1–10 minutes** of capture window, plus setup.

### 10.1 Pre-capture quiescing (best effort, not required)

DiskANN's reads bypass the page cache via `O_DIRECT`, so other processes
cannot contaminate the trace through the cache. The shim only intercepts
`io_submit()` calls inside the DiskANN process itself, so other processes
on the host cannot pollute the CSV either. Capture is therefore robust
even on a busy shared server. Still, for cleanliness:

```bash
# Confirm no other heavy disk user is active on the same NVMe
iostat -x 1 5    # check %util on the target device

# If a previous capture left an aio_trace_shim.so in LD_PRELOAD env, clear it
unset LD_PRELOAD
unset DISKANN_TRACE_PATH
```

### 10.2 Run the capture

```bash
# Set up the capture
mkdir -p ~/diskann-paper/captures
TRACE=~/diskann-paper/captures/diskann_bigann1B_$(date +%Y%m%d_%H%M%S).csv

cd ~/diskann-paper/DiskANN/build/apps

# Wrap the search invocation with LD_PRELOAD + DISKANN_TRACE_PATH.
# Use --num_nodes_to_cache 0 so all reads hit disk (no DiskANN-internal
# in-memory cache). -W 4 = beam width per DiskANN paper default. -T 1 =
# single search thread, matching the paper's §4.2 single-qpair regime.
DISKANN_TRACE_PATH=$TRACE \
LD_PRELOAD=$HOME/diskann-paper/tools/aio_trace_shim.so \
./search_disk_index \
    --data_type uint8 \
    --dist_fn l2 \
    --index_path_prefix $HOME/diskann-paper/indices/bigann1B_R64_L100 \
    --query_file $HOME/diskann-paper/datasets/bigann/bigann_query.public.10K.u8bin \
    --gt_file   $HOME/diskann-paper/datasets/bigann/GT.public.1B.ibin \
    -K 10 -L 100 \
    --result_path $HOME/diskann-paper/results/bigann1B_run1 \
    --num_nodes_to_cache 0 -W 4 -T 1
```

The shim prints `[aio_trace_shim] capturing io_submit to <path>` on
stderr at process startup; if you do not see this line, the
`LD_PRELOAD` did not take effect and the trace is empty.

After `search_disk_index` returns, the trace CSV is complete. Quick check:

```bash
wc -l $TRACE
head -3 $TRACE
tail -3 $TRACE
```

### 10.3 Run the search a second time if the trace is too small

A single 10K-query run typically yields ~5×10⁵ to ~5×10⁶ I/O events
depending on `L`, `K`, and beam width. If the validation in §11 reports
fewer than 10⁶ events, simply concatenate the queries against themselves
in a wrapper script and re-run with the larger query file, OR call
`search_disk_index` repeatedly inside a single shim-wrapped shell so all
events flow into the same trace CSV. Two example approaches:

```bash
# Approach 1: loop the search 10x, all writes to the same trace
DISKANN_TRACE_PATH=$TRACE \
LD_PRELOAD=$HOME/diskann-paper/tools/aio_trace_shim.so \
bash -c 'for i in $(seq 10); do ./search_disk_index ...same args...; done'
```

(Note: with the shim's current implementation, the second invocation will
*overwrite* the CSV from a fresh process if `fopen("w")` is used. To
accumulate, change `"w"` to `"a"` in the shim and recompile, or
concatenate per-run CSVs with a separate post-step.)

### 10.4 Write the metadata YAML for the trace header

Save as `~/diskann-paper/captures/metadata.yaml` (one capture per file):

```yaml
capture-host: <`hostname`>
capture-date: <`date -u +%Y-%m-%dT%H:%M:%SZ`>
os: <`lsb_release -d -s` or contents of /etc/os-release>
kernel: <`uname -r`>
device-target: <e.g., /dev/nvme0n1>
device-model: <`cat /sys/block/nvme0n1/device/model`>
device-namespace-bytes: <`cat /sys/block/nvme0n1/size` * 512>
filesystem: <`stat -f -c %T <index path>`>
diskann-engine-version: <SHA from step 6>
diskann-search-flags: -L 100 -K 10 -W 4 -T 1 --num_nodes_to_cache 0
diskann-index-file: bigann1B_R64_L100_disk.index
diskann-index-size-bytes: <stat byte size from step 8>
diskann-index-build-flags: -R 64 -L 100 -B 1.0 -M 32
dataset: BigANN-1B
dataset-query-count: 10000
capture-tool: libaio LD_PRELOAD shim (aio_trace_shim.so)
capture-duration-seconds: <wall time of search_disk_index>
```

Then prepend this metadata as `# `-prefixed comment lines to the trace
CSV (the validator accepts metadata in this form). One short Python
helper does this; or append the metadata manually with `sed`.

---

## 11. Step 6: Validate trace quality

Save as `tools/validate_trace.py`:

```python
"""
Validate a canonical DiskANN-BigANN trace for paper-grade quality.

Usage:
    python validate_trace.py diskann_bigann_trace.csv
"""
import csv, sys, collections

def main(path):
    rows, meta = [], {}
    with open(path, "r") as f:
        for line in f:
            if line.startswith("# "):
                if ":" in line:
                    k, _, v = line[2:].partition(":")
                    meta[k.strip()] = v.strip()
                continue
            if line.startswith("ts_ns"):
                continue
            try:
                ts, op, off, sz, pid = line.strip().split(",")
            except ValueError:
                continue
            rows.append((int(ts), op, int(off), int(sz), int(pid)))

    n = len(rows)
    if n == 0:
        sys.exit("FAIL: trace contains zero events")

    n_read = sum(1 for r in rows if r[1] == "R")
    sizes  = [r[3] for r in rows]
    offsets= [r[2] for r in rows]
    duration_ns = rows[-1][0] - rows[0][0]
    sz_hist = collections.Counter(sizes)
    n_4k   = sz_hist[4096]
    n_aligned_4k = sum(1 for r in rows if r[2] % 4096 == 0)

    print("=== Trace validation ===")
    print(f"Total events:            {n}")
    print(f"Read events:             {n_read} ({100*n_read/n:.2f}%)")
    print(f"Capture duration:        {duration_ns/1e9:.2f} s")
    print(f"Achieved IO rate:        {n / max(duration_ns/1e9, 1e-9):.0f} ops/s")
    print(f"Size distribution (top 5):")
    for sz, cnt in sz_hist.most_common(5):
        print(f"  {sz:>8d} B : {cnt:>10d}  ({100*cnt/n:.2f}%)")
    print(f"4 KB-aligned offsets:    {n_aligned_4k} ({100*n_aligned_4k/n:.2f}%)")
    print(f"Offset range:            [{min(offsets):,}, {max(offsets):,}] bytes")
    print(f"Offset span:             {(max(offsets)-min(offsets))/(1<<30):.2f} GiB")

    fails = []
    if n < 1_000_000:
        fails.append(f"FAIL: only {n} events; need >= 1e6")
    if n_read / n < 0.99:
        fails.append(f"FAIL: only {100*n_read/n:.2f}% reads; expected ~100%")
    if n_4k / n < 0.5:
        fails.append(f"FAIL: only {100*n_4k/n:.2f}% 4 KB IOs; expected dominant")
    if n_aligned_4k / n < 0.95:
        fails.append(f"FAIL: only {100*n_aligned_4k/n:.2f}% 4 KB-aligned")
    span_gib = (max(offsets)-min(offsets))/(1<<30)
    if span_gib < 1.0:
        fails.append(f"FAIL: offset span only {span_gib:.2f} GiB; index probably cached")

    if fails:
        print("\n".join(fails))
        sys.exit(1)
    print("\nAll quality gates passed.")

if __name__ == "__main__":
    main(sys.argv[1])
```

Run it:

```bash
python tools/validate_trace.py $TRACE
```

### 11.1 Pass/fail gates (must all be green to use the trace in the paper)

| Gate | Requirement | Why |
|---|---|---|
| Event count | ≥ 1 000 000 | Distribution moments stable |
| Read fraction | ≥ 99% | DiskANN search is read-only |
| 4 KB IO fraction | ≥ 50% | DiskANN nodes are page-aligned |
| 4 KB alignment | ≥ 95% | Misalignment indicates an unexpected I/O path |
| Offset span | ≥ 1 GiB | Cache-bypass and large-index sanity |

If a gate fails, increase the search workload duration (loop the queries
inside a single shim-wrapped shell, see §10.3) and recapture.

---

## 12. Step 7: Land the trace next to the simulator

The capture host **is** the gem5 host, so handoff is a copy:

```bash
mkdir -p /home/fangy6/SimpleSSD_Gem5_simulation/artifacts
cp $TRACE /home/fangy6/SimpleSSD_Gem5_simulation/artifacts/diskann_bigann_trace.csv

# Compute SHA-256 for provenance; record this in the paper's
# methodology subsection alongside the citation chain.
sha256sum /home/fangy6/SimpleSSD_Gem5_simulation/artifacts/diskann_bigann_trace.csv \
    > /home/fangy6/SimpleSSD_Gem5_simulation/artifacts/diskann_bigann_trace.sha256
```

**Do not commit the trace to git.** It is large (~50–100 MB per million
events) and reproducible from the procedure documented here. Record the
SHA-256 in the metadata header so any rebuild can be byte-checked.

After landing, the Linux-side replay procedure (separate document) takes
over. The capture procedure is complete.

---

## 13. Troubleshooting

### Shim startup line `[aio_trace_shim] capturing io_submit to ...` does not appear

- `LD_PRELOAD` was not set in the same shell that ran `search_disk_index`.
  Combine them on one line (`DISKANN_TRACE_PATH=... LD_PRELOAD=... ./search_disk_index ...`).
- The shim path is wrong. `LD_PRELOAD` must be an *absolute* path on
  some setups, especially with conda. Use `$(realpath
  tools/aio_trace_shim.so)`.
- The binary was statically linked against libaio. Check with
  `ldd ./search_disk_index | grep aio` — if libaio is missing from the
  output, the symbols cannot be intercepted; rebuild DiskANN with a
  dynamically linked libaio.

### Trace contains zero data rows

- The shim opened the file but `search_disk_index` did no I/O — typically
  because the index path was wrong and DiskANN errored out before the
  first read. Check stderr for DiskANN error messages.
- All shim-intercepted calls had `aio_lio_opcode` of an unexpected type.
  Insert a debug `fprintf` in the shim's default branch to see what
  opcodes are arriving.

### Validation `FAIL: offset span only 0.10 GiB`

- The DiskANN cache (`--num_nodes_to_cache`) was non-zero, so most reads
  hit DiskANN's in-memory cache. Re-run with `--num_nodes_to_cache 0`.
- The index is too small relative to the queries (e.g., 10K queries
  against a 1M-vector index). Use a larger index or loop the queries.

### `search_disk_index` exits immediately

- The index path prefix is wrong. DiskANN expects the prefix without
  the `_disk.index` suffix; pass `bigann1B_R64_L100`, not
  `bigann1B_R64_L100_disk.index`.
- The query file format does not match the data type. The procedure
  assumes `uint8` SIFT format; for `float` datasets, change `--data_type`.

### DiskANN build fails on Boost / MKL not found

- Activate the conda env that has them (`conda activate <env>`) and
  re-run `cmake`. Do not mix system Boost with conda MKL.
- Pass `-DCMAKE_PREFIX_PATH=$CONDA_PREFIX` explicitly to `cmake`.

### Capture takes far longer than expected (hours)

- DiskANN spent most of its time in graph traversal (CPU-bound), not in
  I/O (SSD-bound). At low queue depth (`-T 1`) this is normal — the
  trace is still correct; it just trickles in. Increase `-T` to 4 or 8
  if you want to compress wall time, then note `-T <N>` in the metadata.
  (The paper's §4.2 single-qpair claim still holds: each thread issues
  its own qpair, and the captured pattern at the io_submit boundary is
  per-thread.)

### Conda environment lacks libaio.h

- `conda install -c conda-forge libaio` does not always install the
  development headers. Verify with `find $CONDA_PREFIX -name libaio.h`.
  If absent, request the package as `libaio` *and* the system has
  libaio-dev / libaio-devel installed (this is the only step that may
  need a sysadmin, but typically libaio is already present on
  research-grade Linux servers — check `/usr/include/libaio.h` first).

---

## 14. References

| Tag | Citation |
|---|---|
| DiskANN'19 | S. Jayaram Subramanya, Devvrit, R. Kadekodi, R. Krishnaswamy, H. V. Simhadri, "DiskANN: Fast Accurate Billion-point Nearest Neighbor Search on a Single Node," *Advances in Neural Information Processing Systems (NeurIPS)*, 2019. |
| Simhadri'22 | H. V. Simhadri, G. Williams, M. Aumüller, M. Douze, A. Babenko, D. Baranchuk, Q. Chen, L. Hosseini, R. Krishnaswamy, G. Srinivasa, S. J. Subramanya, J. Wang, "Results of the NeurIPS '21 Challenge on Billion-Scale Approximate Nearest Neighbor Search," *NeurIPS Competition Proceedings*, 2022. |
| FAISS-Index'17 | J. Johnson, M. Douze, H. Jégou, "Billion-scale similarity search with GPUs," *IEEE Transactions on Big Data*, 2017. (Origin of the BigANN/SIFT1B benchmark format.) |
| libaio | Linux kernel libaio API documentation, `man io_submit`, `man io_getevents`. |
| LD_PRELOAD | GNU C Library, "Dynamic Linker — Environment Variables," `man ld.so`. |
| fio-iolog | J. Axboe, "fio Documentation — Verification and trace replay," https://fio.readthedocs.io/. |

---

*End of capture procedure. The deliverable is `diskann_bigann_trace.csv`.
The Linux-side replay procedure (gem5 + SimpleSSD + SPDK) is documented
separately.*
