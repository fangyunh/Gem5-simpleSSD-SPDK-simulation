#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Multi-step driver for the BigANN/DiskANN trace replay -- auto-only, 9p-only.
# ============================================================================
#
# Sibling of scripts/phase1_4k/driver_phase1_multicore.sh. From a single host
# command this driver:
#   1. Patches fast_ssd_highiops.cfg with --uncore-mode N (just like the
#      single-core driver).
#   2. Generates a readfile that mounts /mnt/9p, finds the repo, and invokes
#      scripts/bigann/phase1_trace_replay.sh.
#   3. Boots gem5 in tmux, attaches console, watches for PHASE1_RUNSCRIPT_DONE,
#      auto-stops gem5 when the sweep completes.
#
# Output lands at:
#   results/phase1_runs/<tag>/core0_qp<Q>/phase1_results.csv
#
# Example:
#   SSD_CFG=fast_ssd_highiops.cfg ./scripts/bigann/driver_phase1_trace.sh \
#       --auto --qd 128 --steady-time 1 --uncore-mode 0 --tag paper_trace_mode0
#
# Plot afterwards with:
#   conda run -n llm python scripts/bigann/plot_trace_vs_synthetic.py
# ============================================================================

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
ROOT_DIR=$(cd "$ROOT_DIR/.." && pwd)
SHARED_SCRIPTS_DIR=$(cd "$SCRIPT_DIR/../" && pwd)

# --- defaults ---
AUTO=0
AUTO_STOP=1
TAIL_LOG=0
SESSION_NAME="phase1_trace_auto"

QPAIRS_LIST="1"
QD_LIST="128"
IO_SIZES="4096"
REPEATS=1
STEADY_TIME=1
# Multi-host-core support (2026-05-15): space-separated list of host CPU
# counts to sweep, e.g. "1 6 8".  Each entry boots gem5 with that many guest
# CPUs and runs spdk_nvme_perf on a mask spanning all of them.  Default 1
# preserves prior single-core behavior.
CORE_COUNTS_LIST="1"

# Host CPU model + caches (2026-05-15): switch to TimingSimpleCPU + L1/L2
# caches to model multi-core scaling realistically.  Default keeps the fast
# AtomicSimpleCPU, no caches.  See docs/TIMING_CACHES_PREP_PLAN.md.
CPU_TYPE="AtomicSimpleCPU"
ENABLE_CACHES=0
ENABLE_L2_CACHE=1
# Checkpoint+switch (option 3): take a checkpoint right before workload (phase 1
# atomic boot, fast) then in a follow-up run restore with TimingSimpleCPU+caches
# to measure under the realistic timing model without paying the multi-CPU
# timing-mode boot tax.  See docs/TIMING_CACHES_PREP_PLAN.md §7.
TAKE_CHECKPOINT=0
CHECKPOINT_RESTORE_N=""
# When CHECKPOINT_RESTORE_N is set and RESTORE_WITH_CPU differs from CPU_TYPE,
# gem5 boots its devices with CPU_TYPE (must match the checkpoint's CPU) and
# switches to RESTORE_WITH_CPU on restore.  Typical use: CPU_TYPE=AtomicSimpleCPU,
# RESTORE_WITH_CPU=TimingSimpleCPU.
RESTORE_WITH_CPU=""
RUN_TAG="trace_$(date +%Y%m%d_%H%M%S)"

PCI_ADDR="0000:00:05.0"
PCI_CHECK=0
PERF_ENABLE=1
SKIP_SETUP=0
HUGEMEM_MB=2048

# IO-Uncore knobs
UNCORE_MODE=0
CQ_BATCH_N=8
CQ_BATCH_T=4000000
DB_BATCH_B=4

HOST_SHARE="$ROOT_DIR"

KERNEL="$ROOT_DIR/assets/vmlinux-5.4.49"
DISK_IMAGE="$ROOT_DIR/assets/x86-ubuntu.img"
MEM_SIZE="4GB"
SSD_CONFIG=""    # falls back to ${SSD_CFG} env or fast_ssd.cfg
CHECKPOINT_DIR="$ROOT_DIR/results/checkpoints"

CONSOLE_HOST="localhost"
CONSOLE_PORT=3456

# Trace path on the host (the in-guest readfile re-roots this under /mnt/9p)
TRACE_FILE_HOST="$ROOT_DIR/artifacts/bigann/diskann_bigann_trace.bin"
TRACE_FILE_GUEST_DEFAULT="/mnt/9p/artifacts/bigann/diskann_bigann_trace.bin"

GUEST_OUTPUT_ROOT="/mnt/9p/results/phase1_runs"
GUEST_REPO="/mnt/9p"
GUEST_REPO_CANDIDATES="/mnt/9p /mnt/9p/SimpleSSD_Gem5_simulation /root/SimpleSSD_Gem5_simulation"

usage() {
    cat <<EOF
Usage: $0 [options]

Options (auto mode only):
  --auto                  Boot + run trace replay + auto-stop
  --auto-stop 0|1         Auto-stop gem5 when sweep completes (default: $AUTO_STOP)

  --qpairs "list"         Per-thread qpairs (default: "$QPAIRS_LIST")
  --core-counts "list"    Host CPU counts to sweep (default: "$CORE_COUNTS_LIST")
                          Each value N boots gem5 with N guest CPUs and runs
                          spdk_nvme_perf with -c <(1<<N)-1> covering them.
  --cpu-type TYPE         Guest CPU model (default: $CPU_TYPE).
                          Common: AtomicSimpleCPU (fast) | TimingSimpleCPU
                          (realistic memory timing — use with --caches).
  --caches 0|1            Enable per-CPU L1I+L1D + shared L2 (default: $ENABLE_CACHES).
                          Only meaningful with --cpu-type TimingSimpleCPU.
  --l2 0|1                Enable shared L2 cache (default: $ENABLE_L2_CACHE).
                          Set to 0 to run L1-only (workaround for the
                          multi-CPU+L2+TimingSimpleCPU bad_function_call
                          crash; see docs/TIMING_CACHES_PREP_PLAN.md).
  --qd "list"             Queue depths (default: "$QD_LIST")
  --ios "list"            IO sizes (default: "$IO_SIZES")
  --repeats N             Repeats per data point (default: $REPEATS)
  --steady-time N         Seconds of steady-state per point (default: $STEADY_TIME)
  --tag NAME              Run tag (default: timestamped)

  --uncore-mode N         UncoreMode 0|1|2 (default: $UNCORE_MODE)
  --cq-batch-n N          CQ batch threshold (default: $CQ_BATCH_N)
  --cq-batch-t N          CQ batch timeout in ps (default: $CQ_BATCH_T)
  --db-batch-b N          Doorbell batch SQE threshold (default: $DB_BATCH_B)

  --trace PATH            Host-side trace .bin file (default: $TRACE_FILE_HOST)
                          Must be under \$ROOT_DIR so virtio-9p exposes it
                          inside the guest.
  --pci-addr ADDR         SimpleSSD PCI address (default: $PCI_ADDR)
  --hugemem-mb N          Hugepage MB (default: $HUGEMEM_MB)
  --skip-setup 0|1        Skip SPDK setup.sh (default: $SKIP_SETUP)
  --perf-enable 0|1       Try perf inside guest (auto-disabled if absent)

  --ssd-config PATH       SSD config file (default: \$SSD_CFG env, else fast_ssd.cfg)
  --kernel PATH           gem5 kernel
  --disk-image PATH       gem5 disk image
  --mem-size SIZE         gem5 memory size

  --session-name NAME     tmux session name (default: $SESSION_NAME)
  --no-tail               Do not tail the combined log

Example:
  SSD_CFG=fast_ssd_highiops.cfg $0 --auto \\
      --qd 128 --steady-time 1 --uncore-mode 0 --tag paper_trace_mode0
EOF
}

TMUX_BIN="${TMUX_BIN:-}"
if [ -z "$TMUX_BIN" ]; then
    if [ -x /usr/bin/tmux ]; then
        TMUX_BIN="/usr/bin/tmux"
    else
        TMUX_BIN="$(command -v tmux || true)"
    fi
fi
tmux_cmd() {
    if [ -z "$TMUX_BIN" ]; then return 127; fi
    env -u LD_LIBRARY_PATH "$TMUX_BIN" "$@"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto) AUTO=1; shift ;;
        --auto-stop) AUTO_STOP="$2"; shift 2 ;;
        --qpairs) QPAIRS_LIST="$2"; shift 2 ;;
        --core-counts) CORE_COUNTS_LIST="$2"; shift 2 ;;
        --cpu-type) CPU_TYPE="$2"; shift 2 ;;
        --caches) ENABLE_CACHES="$2"; shift 2 ;;
        --l2) ENABLE_L2_CACHE="$2"; shift 2 ;;
        --take-checkpoint) TAKE_CHECKPOINT="$2"; shift 2 ;;
        --restore-checkpoint) CHECKPOINT_RESTORE_N="$2"; shift 2 ;;
        --restore-with-cpu) RESTORE_WITH_CPU="$2"; shift 2 ;;
        --qd) QD_LIST="$2"; shift 2 ;;
        --ios) IO_SIZES="$2"; shift 2 ;;
        --repeats) REPEATS="$2"; shift 2 ;;
        --steady-time) STEADY_TIME="$2"; shift 2 ;;
        --tag) RUN_TAG="$2"; shift 2 ;;
        --uncore-mode) UNCORE_MODE="$2"; shift 2 ;;
        --cq-batch-n) CQ_BATCH_N="$2"; shift 2 ;;
        --cq-batch-t) CQ_BATCH_T="$2"; shift 2 ;;
        --db-batch-b) DB_BATCH_B="$2"; shift 2 ;;
        --trace) TRACE_FILE_HOST="$2"; shift 2 ;;
        --pci-addr) PCI_ADDR="$2"; shift 2 ;;
        --hugemem-mb) HUGEMEM_MB="$2"; shift 2 ;;
        --skip-setup) SKIP_SETUP="$2"; shift 2 ;;
        --perf-enable) PERF_ENABLE="$2"; shift 2 ;;
        --ssd-config) SSD_CONFIG="$2"; shift 2 ;;
        --kernel) KERNEL="$2"; shift 2 ;;
        --disk-image) DISK_IMAGE="$2"; shift 2 ;;
        --mem-size) MEM_SIZE="$2"; shift 2 ;;
        --session-name) SESSION_NAME="$2"; shift 2 ;;
        --no-tail) TAIL_LOG=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

if [ "$AUTO" -ne 1 ]; then
    echo "This driver is auto-only. Pass --auto." >&2
    usage
    exit 1
fi

# Resolve SSD_CONFIG
if [ -z "$SSD_CONFIG" ]; then
    if [ -n "${SSD_CFG:-}" ]; then
        case "$SSD_CFG" in
            /*) SSD_CONFIG="$SSD_CFG" ;;
            *)  SSD_CONFIG="$ROOT_DIR/$SSD_CFG" ;;
        esac
    else
        SSD_CONFIG="$ROOT_DIR/fast_ssd.cfg"
    fi
fi
if [ ! -f "$SSD_CONFIG" ]; then
    echo "ERROR: SSD config not found: $SSD_CONFIG" >&2
    exit 1
fi

# Verify trace exists on host BEFORE booting gem5
if [ ! -f "$TRACE_FILE_HOST" ]; then
    echo "ERROR: trace file not found: $TRACE_FILE_HOST" >&2
    echo "Run: python3 scripts/bigann/trace_to_binary.py \\" >&2
    echo "         --input artifacts/bigann/diskann_bigann_trace.csv \\" >&2
    echo "         --output artifacts/bigann/diskann_bigann_trace.bin" >&2
    exit 1
fi

# Map the host trace path to its guest 9p path: /mnt/9p mirrors $ROOT_DIR
TRACE_FILE_GUEST="${TRACE_FILE_HOST/$ROOT_DIR/\/mnt\/9p}"

LOG_DIR_HOST="$ROOT_DIR/logs"
mkdir -p "$LOG_DIR_HOST"
LOG_FILE="$LOG_DIR_HOST/driver_phase1_trace_${RUN_TAG}.log"
: > "$LOG_FILE"

patch_ssd_config() {
    sed -i -E \
        -e "s|^(UncoreMode)[[:space:]]*=.*|\1     = $UNCORE_MODE|" \
        -e "s|^(CQBatchN)[[:space:]]*=.*|\1       = $CQ_BATCH_N|" \
        -e "s|^(CQBatchT)[[:space:]]*=.*|\1       = $CQ_BATCH_T|" \
        -e "s|^(DBBatchB)[[:space:]]*=.*|\1       = $DB_BATCH_B|" \
        "$SSD_CONFIG"
    echo "Patched $SSD_CONFIG: UncoreMode=$UNCORE_MODE CQBatchN=$CQ_BATCH_N CQBatchT=$CQ_BATCH_T DBBatchB=$DB_BATCH_B" \
        | tee -a "$LOG_FILE"

    # --- Multi-qpair + multi-core validation (2026-05-15) ----------------------
    # With CORE_COUNTS_LIST sweeping host CPU counts, the total qpair pressure on
    # the device is max_core * max_qpairs_per_core.  Must be <= MaxIOCQueue.
    local max_io_cq
    max_io_cq=$(awk -F= '/^[[:space:]]*MaxIOCQueue[[:space:]]*=/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' "$SSD_CONFIG")
    if [ -n "$max_io_cq" ]; then
        local max_qp=1 q max_cc=1 c
        for q in $QPAIRS_LIST; do
            [ "$q" -gt "$max_qp" ] && max_qp="$q"
        done
        for c in $CORE_COUNTS_LIST; do
            [ "$c" -gt "$max_cc" ] && max_cc="$c"
        done
        local needed=$(( max_cc * max_qp ))
        echo "[QPAIR] cfg=$SSD_CONFIG MaxIOCQueue=$max_io_cq qpairs_list=\"$QPAIRS_LIST\" core_counts_list=\"$CORE_COUNTS_LIST\" max_per_core=$max_qp max_cores=$max_cc total_needed=$needed uncore_mode=$UNCORE_MODE" | tee -a "$LOG_FILE"
        if [ "$needed" -gt "$max_io_cq" ]; then
            echo "ERROR: max_cores*max(qpairs_per_core) = $max_cc*$max_qp = $needed exceeds cfg MaxIOCQueue=$max_io_cq." | tee -a "$LOG_FILE" >&2
            exit 2
        fi
    fi
}

write_metadata() {
    local meta_dir="$ROOT_DIR/results/phase1_runs/$RUN_TAG"
    mkdir -p "$meta_dir"
    cat > "$meta_dir/metadata.json" <<EOF
{
  "driver":         "driver_phase1_trace.sh",
  "run_tag":        "$RUN_TAG",
  "trace_host":     "$TRACE_FILE_HOST",
  "trace_guest":    "$TRACE_FILE_GUEST",
  "trace_size_bytes": $(stat -c %s "$TRACE_FILE_HOST"),
  "qpairs":         "$QPAIRS_LIST",
  "core_counts":    "$CORE_COUNTS_LIST",
  "cpu_type":       "$CPU_TYPE",
  "enable_caches":  $ENABLE_CACHES,
  "enable_l2_cache": $ENABLE_L2_CACHE,
  "queue_depths":   "$QD_LIST",
  "io_sizes":       "$IO_SIZES",
  "repeats":        $REPEATS,
  "steady_time":    $STEADY_TIME,
  "uncore_mode":    $UNCORE_MODE,
  "cq_batch_n":     $CQ_BATCH_N,
  "cq_batch_t":     $CQ_BATCH_T,
  "db_batch_b":     $DB_BATCH_B,
  "ssd_config":     "$SSD_CONFIG",
  "kernel":         "$KERNEL",
  "disk_image":     "$DISK_IMAGE",
  "mem_size":       "$MEM_SIZE",
  "guest_runner":   "scripts/bigann/phase1_trace_replay.sh",
  "host_share":     "$HOST_SHARE",
  "started_at":     "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    echo "Metadata: $meta_dir/metadata.json" | tee -a "$LOG_FILE"
}

write_readfile_script() {
    local script_path="$LOG_DIR_HOST/phase1_trace_readfile_${RUN_TAG}.sh"
    cat > "$script_path" <<'EOF'
#!/bin/sh
LOG_FILE="/tmp/phase1_trace_readfile.log"
REPO_HINT="__REPO_HINT__"
REPO_CANDIDATES="__REPO_CANDIDATES__"
HOST_SHARE="__HOST_SHARE__"
{
  echo "PHASE1_TRACE_RUNSCRIPT_START"
  echo "PHASE1_TRACE_INFO: uname=$(uname -a)"

  if [ -n "$HOST_SHARE" ]; then
    mkdir -p /mnt/9p
    if mountpoint -q /mnt/9p 2>/dev/null; then
      echo "PHASE1_TRACE_INFO: /mnt/9p already mounted"
    else
      mount_ok=0
      for aname_arg in "aname=$HOST_SHARE" "aname=/" ""; do
        if [ -n "$aname_arg" ]; then
          mount_opts="trans=virtio,version=9p2000.L,$aname_arg"
        else
          mount_opts="trans=virtio,version=9p2000.L"
        fi
        if mount -t 9p -o "$mount_opts" gem5 /mnt/9p 2>/dev/null; then
          echo "PHASE1_TRACE_INFO: /mnt/9p mounted with $mount_opts"
          mount_ok=1
          break
        fi
      done
      [ "$mount_ok" -eq 0 ] && echo "PHASE1_TRACE_WARN: failed to mount /mnt/9p"
    fi
  fi

  find_repo() {
    for p in "$REPO_HINT" $REPO_CANDIDATES; do
      if [ -d "$p" ] && [ -f "$p/scripts/bigann/phase1_trace_replay.sh" ]; then
        echo "$p"; return 0
      fi
    done
    found=$(find / -maxdepth 6 -path "*/scripts/bigann/phase1_trace_replay.sh" 2>/dev/null | head -n1)
    if [ -n "$found" ]; then
      echo "$(dirname "$(dirname "$(dirname "$found")")")"
      return 0
    fi
    return 1
  }

  REPO_PATH="$(find_repo)"
  if [ -z "$REPO_PATH" ]; then
    echo "PHASE1_TRACE_RUNSCRIPT_ERROR: phase1_trace_replay.sh not found"
    exit 1
  fi
  echo "PHASE1_TRACE_REPO: $REPO_PATH"
  cd "$REPO_PATH" || exit 1

  mkdir -p /etc/security/limits.d
  echo '* - memlock unlimited' > /etc/security/limits.d/99-memlock.conf
  ulimit -l unlimited 2>/dev/null || true

  export QPAIRS_LIST="__QPAIRS__"
  export CORE_COUNTS_LIST="__CORE_COUNTS__"
  export QUEUE_DEPTHS_LIST="__QD_LIST__"
  export IO_SIZES_LIST="__IO_SIZES__"
  export REPEATS=__REPEATS__
  export STEADY_TIME=__STEADY_TIME__
  export RUN_TAG="__RUN_TAG__"
  export OUTPUT_ROOT="__OUTPUT_ROOT__"
  export PCI_ADDR="__PCI_ADDR__"
  export PCI_CHECK=__PCI_CHECK__
  export PERF_ENABLE=__PERF_ENABLE__
  export SKIP_SETUP=__SKIP_SETUP__
  export HUGEMEM_MB=__HUGEMEM_MB__
  export UNCORE_MODE=__UNCORE_MODE__
  export TRACE_FILE="__TRACE_FILE_GUEST__"
  export NUMBER_IOS_CAP=__NUMBER_IOS_CAP__
  export TAKE_CHECKPOINT=__TAKE_CHECKPOINT__

  ./scripts/bigann/phase1_trace_replay.sh
  echo "PHASE1_TRACE_INFO: output_root=$OUTPUT_ROOT"
  ls -la "$OUTPUT_ROOT/$RUN_TAG" 2>/dev/null | sed 's/^/  /'
  sync
  sleep 2
  echo "PHASE1_RUNSCRIPT_DONE"
} 2>&1 | tee "$LOG_FILE"

echo "PHASE1_TRACE_RUNSCRIPT_LOG_BEGIN"
cat "$LOG_FILE"
echo "PHASE1_TRACE_RUNSCRIPT_LOG_END"

if command -v m5 >/dev/null 2>&1; then
  m5 exit
fi
EOF

    sed -i \
        -e "s|__REPO_HINT__|$GUEST_REPO|g" \
        -e "s|__REPO_CANDIDATES__|$GUEST_REPO_CANDIDATES|g" \
        -e "s|__HOST_SHARE__|$HOST_SHARE|g" \
        -e "s|__QPAIRS__|$QPAIRS_LIST|g" \
        -e "s|__CORE_COUNTS__|$CORE_COUNTS_LIST|g" \
        -e "s|__QD_LIST__|$QD_LIST|g" \
        -e "s|__IO_SIZES__|$IO_SIZES|g" \
        -e "s|__REPEATS__|$REPEATS|g" \
        -e "s|__STEADY_TIME__|$STEADY_TIME|g" \
        -e "s|__NUMBER_IOS_CAP__|${NUMBER_IOS_CAP:-0}|g" \
        -e "s|__RUN_TAG__|$RUN_TAG|g" \
        -e "s|__OUTPUT_ROOT__|$GUEST_OUTPUT_ROOT|g" \
        -e "s|__PCI_ADDR__|$PCI_ADDR|g" \
        -e "s|__PCI_CHECK__|$PCI_CHECK|g" \
        -e "s|__PERF_ENABLE__|$PERF_ENABLE|g" \
        -e "s|__SKIP_SETUP__|$SKIP_SETUP|g" \
        -e "s|__HUGEMEM_MB__|$HUGEMEM_MB|g" \
        -e "s|__UNCORE_MODE__|$UNCORE_MODE|g" \
        -e "s|__TRACE_FILE_GUEST__|$TRACE_FILE_GUEST|g" \
        -e "s|__TAKE_CHECKPOINT__|$TAKE_CHECKPOINT|g" \
        "$script_path"

    chmod +x "$script_path"
    echo "$script_path"
}

run_auto() {
    if [ -z "$TMUX_BIN" ]; then
        echo "tmux not found." >&2
        exit 1
    fi
    if tmux_cmd has-session -t "$SESSION_NAME" 2>/dev/null; then
        echo "tmux session already exists: $SESSION_NAME" >&2
        exit 1
    fi

    patch_ssd_config
    write_metadata
    {
        echo "===================================================="
        echo "BigANN/DiskANN trace replay driver"
        echo "  run_tag      : $RUN_TAG"
        echo "  trace        : $TRACE_FILE_HOST"
        echo "                 ($(stat -c %s "$TRACE_FILE_HOST") bytes / $(($(stat -c %s "$TRACE_FILE_HOST")/16)) entries)"
        echo "  trace (guest): $TRACE_FILE_GUEST"
        echo "  qd / ios     : $QD_LIST / $IO_SIZES"
        echo "  qpairs       : $QPAIRS_LIST"
        echo "  steady_time  : $STEADY_TIME"
        echo "  uncore_mode  : $UNCORE_MODE"
        echo "  ssd_config   : $SSD_CONFIG"
        echo "  output_host  : $ROOT_DIR/results/phase1_runs/$RUN_TAG/"
        echo "===================================================="
    } | tee -a "$LOG_FILE"

    READFILE_SCRIPT=$(write_readfile_script)
    echo "Readfile: $READFILE_SCRIPT" | tee -a "$LOG_FILE"

    # Pick the max core count from CORE_COUNTS_LIST so gem5 boots with enough
    # guest CPUs to cover any -c <mask> the replay script will use.
    _NUM_CPUS=1
    for _c in $CORE_COUNTS_LIST; do
        if [ "$_c" -gt "$_NUM_CPUS" ]; then _NUM_CPUS="$_c"; fi
    done
    echo "[CORES] booting gem5 with NUM_CPUS=$_NUM_CPUS (covers core_counts=\"$CORE_COUNTS_LIST\") cpu_type=$CPU_TYPE caches=$ENABLE_CACHES l2=$ENABLE_L2_CACHE" | tee -a "$LOG_FILE"

    tmux_cmd new-session -d -s "$SESSION_NAME" -n boot \
        "bash -lc \"KERNEL=$KERNEL DISK_IMAGE=$DISK_IMAGE MEM_SIZE=$MEM_SIZE SSD_CONFIG=$SSD_CONFIG CHECKPOINT_DIR=$CHECKPOINT_DIR CHECKPOINT_RESTORE='$CHECKPOINT_RESTORE_N' RESTORE_WITH_CPU='$RESTORE_WITH_CPU' READFILE_SCRIPT=$READFILE_SCRIPT VIO_9P=1 VIO_9P_SET_ROOT=1 HOST_SHARE='$HOST_SHARE' NUM_CPUS=$_NUM_CPUS CPU_TYPE='$CPU_TYPE' ENABLE_CACHES=$ENABLE_CACHES ENABLE_L2_CACHE=$ENABLE_L2_CACHE TAKE_CHECKPOINT=$TAKE_CHECKPOINT $SHARED_SCRIPTS_DIR/boot_gem5.sh start; echo 'boot_gem5.sh exited'; exec bash\""
    tmux_cmd pipe-pane -t "$SESSION_NAME:0.0" -o "cat >> '$LOG_FILE'"
    tmux_cmd set-option -t "$SESSION_NAME" remain-on-exit on

    tmux_cmd split-window -t "$SESSION_NAME:0.0" -v \
        "bash -lc \"while true; do PORT=$CONSOLE_PORT; DETECTED=\\\$(grep -oE 'Listening for connections on port [0-9]+' '$ROOT_DIR/logs/gem5.out' 2>/dev/null | tail -n1 | awk '{print \\\$NF}'); if [ -n \\\"\\\$DETECTED\\\" ]; then PORT=\\\$DETECTED; fi; $SHARED_SCRIPTS_DIR/console_gem5.sh \\\"\\\$PORT\\\" $CONSOLE_HOST && break; echo 'console exited, retrying in 2s'; sleep 2; done; exec bash\""
    tmux_cmd pipe-pane -t "$SESSION_NAME:0.1" -o "cat >> '$LOG_FILE'"

    echo "Auto mode: tmux session '$SESSION_NAME' created." | tee -a "$LOG_FILE"
    trap '' HUP

    if [ "$AUTO_STOP" -ne 1 ]; then
        echo "Auto-stop disabled; gem5 will run until you stop it manually." | tee -a "$LOG_FILE"
        return 0
    fi

    [ "$TAIL_LOG" -eq 1 ] && tail -f "$LOG_FILE" &
    TAIL_PID=$!

    _GEM5_PID_FILE="$LOG_DIR_HOST/gem5.pid"
    _HEARTBEAT=0
    echo "[$(date '+%H:%M:%S')] gem5 launched. Watching for completion."

    while true; do
        if grep -q "PHASE1_RUNSCRIPT_DONE" "$LOG_FILE" 2>/dev/null; then
            echo "[$(date '+%H:%M:%S')] Sweep complete. Waiting up to 120s for guest m5 exit to flush stats..."
            _STATS_WAIT=0
            _GEM5_PID_LOCAL=$(cat "$_GEM5_PID_FILE" 2>/dev/null)
            while [ "$_STATS_WAIT" -lt 120 ]; do
                if [ -n "$_GEM5_PID_LOCAL" ] && ! kill -0 "$_GEM5_PID_LOCAL" 2>/dev/null; then
                    echo "[$(date '+%H:%M:%S')] gem5 exited cleanly via m5 exit."
                    break
                fi
                sleep 2
                _STATS_WAIT=$(( _STATS_WAIT + 2 ))
            done
            if [ -n "$_GEM5_PID_LOCAL" ] && kill -0 "$_GEM5_PID_LOCAL" 2>/dev/null; then
                echo "[$(date '+%H:%M:%S')] m5 exit didn't fire within 120s; falling back to SIGTERM."
                "$SHARED_SCRIPTS_DIR/boot_gem5.sh" stop >> "$LOG_FILE" 2>&1 || true
            fi
            tmux_cmd kill-session -t "$SESSION_NAME" >> "$LOG_FILE" 2>&1 || true
            break
        fi
        if [ -f "$_GEM5_PID_FILE" ]; then
            _GEM5_PID=$(cat "$_GEM5_PID_FILE" 2>/dev/null)
            if [ -n "$_GEM5_PID" ] && [ "${_GEM5_PID_VALIDATED:-0}" -eq 0 ]; then
                if kill -0 "$_GEM5_PID" 2>/dev/null; then
                    _GEM5_PID_VALIDATED=1
                elif [ "$_HEARTBEAT" -lt 60 ]; then
                    sleep 5; continue
                fi
            fi
            if [ -n "$_GEM5_PID" ] && [ "${_GEM5_PID_VALIDATED:-0}" -eq 1 ] && ! kill -0 "$_GEM5_PID" 2>/dev/null; then
                echo "[$(date '+%H:%M:%S')] ERROR: gem5 (pid $_GEM5_PID) died unexpectedly!"
                tail -20 "$LOG_DIR_HOST/gem5.out" 2>/dev/null
                break
            fi
        fi
        _HEARTBEAT=$(( _HEARTBEAT + 5 ))
        if [ $(( _HEARTBEAT % 60 )) -eq 0 ]; then
            _LAST=$(tail -1 "$LOG_DIR_HOST/gem5.out" 2>/dev/null | cut -c1-80)
            echo "[$(date '+%H:%M:%S')] still running | gem5.out tail: $_LAST"
        fi
        sleep 5
    done
    [ -n "${TAIL_PID:-}" ] && kill "$TAIL_PID" 2>/dev/null || true
    echo "[$(date '+%H:%M:%S')] Done. Results: $ROOT_DIR/results/phase1_runs/$RUN_TAG/"
}

run_auto
