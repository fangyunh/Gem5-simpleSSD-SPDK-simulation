#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Multi-core driver for Phase 1 evaluation -- auto-only, virtio-9p only.
# ==============================================================================
#
# Companion to scripts/phase1_4k/driver_phase1.sh. This driver runs ONLY the multi-core
# in-guest script (scripts/phase1_4k/phase1_run_multicore_gem5.sh) so a single command
# from the host launches gem5, mounts the workspace via 9p, runs the
# multi-core sweep, and stops gem5 when PHASE1_RUNSCRIPT_DONE is observed.
#
# It does not support manual / non-9p / non-readfile workflows -- those live
# in driver_phase1.sh. If you want single-core data or any of the alternate
# paths, use that script.
#
# Example:
#   SSD_CFG=fast_ssd_highiops.cfg ./scripts/phase1_4k/driver_phase1_multicore.sh \
#       --auto --core-counts "1 2" --qd 128 --ios 4096 \
#       --repeats 1 --steady-time 5 --uncore-mode 0 --tag verify_multicore
#
# Output lands at:
#   results/phase1_runs/<tag>/core_count<N>_qp<Q>/phase1_results.csv
# Plot afterwards with:
#   conda run -n llm python scripts/phase1_4k/plot_multicore_gem5.py \
#       --results results/phase1_runs --qd 128 --io-size 4096

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)
SHARED_SCRIPTS_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

# --- defaults ---
AUTO=0
AUTO_STOP=1
TAIL_LOG=0
SESSION_NAME="phase1_multicore_auto"

CORE_COUNTS_LIST="1 2"
QPAIRS_LIST="1"
QD_LIST="128"
IO_SIZES="4096"
REPEATS=1
STEADY_TIME=5
RUN_TAG="multicore_$(date +%Y%m%d_%H%M%S)"

PCI_ADDR="0000:00:05.0"
PCI_CHECK=0
PERF_ENABLE=1
SKIP_SETUP=0
HUGEMEM_MB=2048

# IO-Uncore knobs (UncoreMode patched into SSD config; SPDK_UNCORE_MODE_B
# exported in-guest by phase1_run_multicore_gem5.sh when UNCORE_MODE=2)
UNCORE_MODE=0
CQ_BATCH_N=8
CQ_BATCH_T=4000000
DB_BATCH_B=4

# virtio-9p host share (always on for this driver)
HOST_SHARE="$ROOT_DIR"

# gem5 boot args
KERNEL="$ROOT_DIR/assets/vmlinux-5.4.49"
DISK_IMAGE="$ROOT_DIR/assets/x86-ubuntu.img"
MEM_SIZE="4GB"
SSD_CONFIG=""    # if empty, falls back to ${SSD_CFG} env or fast_ssd.cfg
CHECKPOINT_DIR="$ROOT_DIR/results/checkpoints"

CONSOLE_HOST="localhost"
CONSOLE_PORT=3456

# Guest-side paths (inside gem5)
GUEST_OUTPUT_ROOT="/mnt/9p/results/phase1_runs"
GUEST_REPO="/mnt/9p"
GUEST_REPO_CANDIDATES="/mnt/9p /mnt/9p/SimpleSSD_Gem5_simulation /root/SimpleSSD_Gem5_simulation"

usage() {
    cat <<EOF
Usage: $0 [options]

Options (auto mode only):
  --auto                  Boot + run multi-core sweep + auto-stop on completion
  --auto-stop 0|1         Auto-stop gem5 when sweep completes (default: $AUTO_STOP)

  --core-counts "list"    Space-separated core counts to test (default: "$CORE_COUNTS_LIST")
                          Each iteration runs spdk_nvme_perf with mask (1<<N)-1.
  --qpairs "list"         Per-thread qpairs (default: "$QPAIRS_LIST")
  --qd "list"             Queue depths (default: "$QD_LIST")
  --ios "list"            IO sizes (default: "$IO_SIZES")
  --repeats N             Repeats per data point (default: $REPEATS)
  --steady-time N         Seconds of steady-state per point (default: $STEADY_TIME)
  --tag NAME              Run tag (default: timestamped)

  --uncore-mode N         UncoreMode 0|1|2 (default: $UNCORE_MODE)
  --cq-batch-n N          CQ batch threshold (default: $CQ_BATCH_N)
  --cq-batch-t N          CQ batch timeout in ps (default: $CQ_BATCH_T)
  --db-batch-b N          Doorbell batch SQE threshold (default: $DB_BATCH_B)

  --pci-addr ADDR         SimpleSSD PCI address (default: $PCI_ADDR)
  --hugemem-mb N          Hugepage MB inside guest (default: $HUGEMEM_MB)
  --skip-setup 0|1        Skip SPDK setup.sh inside guest (default: $SKIP_SETUP)
  --perf-enable 0|1       Try perf inside guest (auto-disabled if absent)

  --ssd-config PATH       SSD config file (default: \$SSD_CFG env, or fast_ssd.cfg)
  --kernel PATH           gem5 kernel
  --disk-image PATH       gem5 disk image
  --mem-size SIZE         gem5 memory size

  --session-name NAME     tmux session name (default: $SESSION_NAME)
  --no-tail               Do not tail the combined log in this terminal

Example:
  SSD_CFG=fast_ssd_highiops.cfg $0 --auto --core-counts "1 2" \\
      --qd 128 --ios 4096 --repeats 1 --steady-time 5 \\
      --uncore-mode 0 --tag verify_multicore
EOF
}

# tmux helper (avoid conda libtinfo mismatch)
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

# Parse CLI
while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto) AUTO=1; shift ;;
        --auto-stop) AUTO_STOP="$2"; shift 2 ;;
        --core-counts) CORE_COUNTS_LIST="$2"; shift 2 ;;
        --qpairs) QPAIRS_LIST="$2"; shift 2 ;;
        --qd) QD_LIST="$2"; shift 2 ;;
        --ios) IO_SIZES="$2"; shift 2 ;;
        --repeats) REPEATS="$2"; shift 2 ;;
        --steady-time) STEADY_TIME="$2"; shift 2 ;;
        --tag) RUN_TAG="$2"; shift 2 ;;
        --uncore-mode) UNCORE_MODE="$2"; shift 2 ;;
        --cq-batch-n) CQ_BATCH_N="$2"; shift 2 ;;
        --cq-batch-t) CQ_BATCH_T="$2"; shift 2 ;;
        --db-batch-b) DB_BATCH_B="$2"; shift 2 ;;
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

# Resolve SSD_CONFIG (CLI > $SSD_CFG env > fast_ssd.cfg)
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

LOG_DIR_HOST="$ROOT_DIR/logs"
mkdir -p "$LOG_DIR_HOST"
LOG_FILE="$LOG_DIR_HOST/driver_phase1_multicore_${RUN_TAG}.log"
: > "$LOG_FILE"

# --- patch SSD config for IO-Uncore knobs ---
patch_ssd_config() {
    sed -i -E \
        -e "s|^(UncoreMode)[[:space:]]*=.*|\1     = $UNCORE_MODE|" \
        -e "s|^(CQBatchN)[[:space:]]*=.*|\1       = $CQ_BATCH_N|" \
        -e "s|^(CQBatchT)[[:space:]]*=.*|\1       = $CQ_BATCH_T|" \
        -e "s|^(DBBatchB)[[:space:]]*=.*|\1       = $DB_BATCH_B|" \
        "$SSD_CONFIG"
    echo "Patched $SSD_CONFIG: UncoreMode=$UNCORE_MODE CQBatchN=$CQ_BATCH_N CQBatchT=$CQ_BATCH_T DBBatchB=$DB_BATCH_B" \
        | tee -a "$LOG_FILE"

    # --- Multi-qpair validation (2026-05-14) -----------------------------------
    local max_io_cq
    max_io_cq=$(awk -F= '/^[[:space:]]*MaxIOCQueue[[:space:]]*=/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' "$SSD_CONFIG")
    if [ -n "$max_io_cq" ]; then
        local max_cores=1 max_qp=1 c q
        for c in $CORE_COUNTS_LIST; do
            [ "$c" -gt "$max_cores" ] && max_cores="$c"
        done
        for q in $QPAIRS_LIST; do
            [ "$q" -gt "$max_qp" ] && max_qp="$q"
        done
        local needed=$(( max_cores * max_qp ))
        echo "[QPAIR] cfg=$SSD_CONFIG MaxIOCQueue=$max_io_cq cores_list=\"$CORE_COUNTS_LIST\" qpairs_list=\"$QPAIRS_LIST\" max_total_needed=$needed" | tee -a "$LOG_FILE"
        if [ "$needed" -gt "$max_io_cq" ]; then
            echo "ERROR: max_cores * max_qpairs_per_core = $max_cores * $max_qp = $needed exceeds cfg MaxIOCQueue=$max_io_cq." | tee -a "$LOG_FILE" >&2
            exit 2
        fi
    fi
}

# --- write metadata sidecar ---
write_metadata() {
    local meta_dir="$ROOT_DIR/results/phase1_runs/$RUN_TAG"
    mkdir -p "$meta_dir"
    cat > "$meta_dir/metadata.json" <<EOF
{
  "driver":         "driver_phase1_multicore.sh",
  "run_tag":        "$RUN_TAG",
  "core_counts":    "$CORE_COUNTS_LIST",
  "qpairs":         "$QPAIRS_LIST",
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
  "guest_runner":   "scripts/phase1_4k/phase1_run_multicore_gem5.sh",
  "host_share":     "$HOST_SHARE",
  "started_at":     "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    echo "Metadata: $meta_dir/metadata.json" | tee -a "$LOG_FILE"
}

# --- write the readfile gem5 will execute inside the guest ---
write_readfile_script() {
    local script_path="$LOG_DIR_HOST/phase1_multicore_readfile_${RUN_TAG}.sh"
    cat > "$script_path" <<'EOF'
#!/bin/sh
LOG_FILE="/tmp/phase1_multicore_readfile.log"
REPO_HINT="__REPO_HINT__"
REPO_CANDIDATES="__REPO_CANDIDATES__"
HOST_SHARE="__HOST_SHARE__"
{
  echo "PHASE1_MC_RUNSCRIPT_START"
  echo "PHASE1_MC_INFO: uname=$(uname -a)"
  echo "PHASE1_MC_INFO: pwd=$(pwd)"

  # Mount virtio-9p (always; this driver is 9p-only)
  if [ -n "$HOST_SHARE" ]; then
    mkdir -p /mnt/9p
    if mountpoint -q /mnt/9p 2>/dev/null; then
      echo "PHASE1_MC_INFO: /mnt/9p already mounted"
    else
      mount_ok=0
      for aname_arg in "aname=$HOST_SHARE" "aname=/" ""; do
        if [ -n "$aname_arg" ]; then
          mount_opts="trans=virtio,version=9p2000.L,$aname_arg"
        else
          mount_opts="trans=virtio,version=9p2000.L"
        fi
        if mount -t 9p -o "$mount_opts" gem5 /mnt/9p 2>/dev/null; then
          echo "PHASE1_MC_INFO: /mnt/9p mounted with $mount_opts"
          mount_ok=1
          break
        fi
      done
      [ "$mount_ok" -eq 0 ] && echo "PHASE1_MC_WARN: failed to mount /mnt/9p"
    fi
  fi

  find_repo() {
    for p in "$REPO_HINT" $REPO_CANDIDATES; do
      if [ -d "$p" ] && [ -f "$p/scripts/phase1_4k/phase1_run_multicore_gem5.sh" ]; then
        echo "$p"
        return 0
      fi
    done
    found=$(find / -maxdepth 6 -path "*/scripts/phase1_4k/phase1_run_multicore_gem5.sh" 2>/dev/null | head -n1)
    if [ -n "$found" ]; then
      echo "$(dirname "$(dirname "$found")")"
      return 0
    fi
    return 1
  }

  REPO_PATH="$(find_repo)"
  if [ -z "$REPO_PATH" ]; then
    echo "PHASE1_MC_RUNSCRIPT_ERROR: phase1_run_multicore_gem5.sh not found"
    echo "  searched: $REPO_HINT $REPO_CANDIDATES"
    exit 1
  fi

  echo "PHASE1_MC_REPO: $REPO_PATH"
  cd "$REPO_PATH" || exit 1

  # SPDK requires unlimited locked memory
  mkdir -p /etc/security/limits.d
  echo '* - memlock unlimited' > /etc/security/limits.d/99-memlock.conf
  ulimit -l unlimited 2>/dev/null || true

  export CORE_COUNTS_LIST="__CORE_COUNTS__"
  export QPAIRS_LIST="__QPAIRS__"
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

  ./scripts/phase1_4k/phase1_run_multicore_gem5.sh
  echo "PHASE1_MC_INFO: output_root=$OUTPUT_ROOT"
  ls -la "$OUTPUT_ROOT/$RUN_TAG" 2>/dev/null | sed 's/^/  /'
  sync
  sleep 2
  echo "PHASE1_RUNSCRIPT_DONE"
} 2>&1 | tee "$LOG_FILE"

echo "PHASE1_MC_RUNSCRIPT_LOG_BEGIN"
cat "$LOG_FILE"
echo "PHASE1_MC_RUNSCRIPT_LOG_END"

if command -v m5 >/dev/null 2>&1; then
  m5 exit
fi
EOF

    sed -i \
        -e "s|__REPO_HINT__|$GUEST_REPO|g" \
        -e "s|__REPO_CANDIDATES__|$GUEST_REPO_CANDIDATES|g" \
        -e "s|__HOST_SHARE__|$HOST_SHARE|g" \
        -e "s|__CORE_COUNTS__|$CORE_COUNTS_LIST|g" \
        -e "s|__QPAIRS__|$QPAIRS_LIST|g" \
        -e "s|__QD_LIST__|$QD_LIST|g" \
        -e "s|__IO_SIZES__|$IO_SIZES|g" \
        -e "s|__REPEATS__|$REPEATS|g" \
        -e "s|__STEADY_TIME__|$STEADY_TIME|g" \
        -e "s|__RUN_TAG__|$RUN_TAG|g" \
        -e "s|__OUTPUT_ROOT__|$GUEST_OUTPUT_ROOT|g" \
        -e "s|__PCI_ADDR__|$PCI_ADDR|g" \
        -e "s|__PCI_CHECK__|$PCI_CHECK|g" \
        -e "s|__PERF_ENABLE__|$PERF_ENABLE|g" \
        -e "s|__SKIP_SETUP__|$SKIP_SETUP|g" \
        -e "s|__HUGEMEM_MB__|$HUGEMEM_MB|g" \
        -e "s|__UNCORE_MODE__|$UNCORE_MODE|g" \
        "$script_path"

    chmod +x "$script_path"
    echo "$script_path"
}

# --- run_auto: launch gem5 in tmux, attach console, wait for completion ---
run_auto() {
    if [ -z "$TMUX_BIN" ]; then
        echo "tmux not found. Install tmux." >&2
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
        echo "Multi-core Phase 1 driver"
        echo "  run_tag      : $RUN_TAG"
        echo "  core_counts  : $CORE_COUNTS_LIST"
        echo "  qd / ios     : $QD_LIST / $IO_SIZES"
        echo "  qpairs       : $QPAIRS_LIST"
        echo "  repeats      : $REPEATS"
        echo "  steady_time  : $STEADY_TIME"
        echo "  uncore_mode  : $UNCORE_MODE"
        echo "  ssd_config   : $SSD_CONFIG"
        echo "  output_host  : $ROOT_DIR/results/phase1_runs/$RUN_TAG/"
        echo "  output_guest : $GUEST_OUTPUT_ROOT/$RUN_TAG/"
        echo "===================================================="
    } | tee -a "$LOG_FILE"

    READFILE_SCRIPT=$(write_readfile_script)
    echo "Readfile: $READFILE_SCRIPT" | tee -a "$LOG_FILE"

    tmux_cmd new-session -d -s "$SESSION_NAME" -n boot \
        "bash -lc \"KERNEL=$KERNEL DISK_IMAGE=$DISK_IMAGE MEM_SIZE=$MEM_SIZE SSD_CONFIG=$SSD_CONFIG CHECKPOINT_DIR=$CHECKPOINT_DIR READFILE_SCRIPT=$READFILE_SCRIPT VIO_9P=1 VIO_9P_SET_ROOT=1 HOST_SHARE='$HOST_SHARE' $SHARED_SCRIPTS_DIR/boot_gem5.sh start; echo 'boot_gem5.sh exited'; exec bash\""
    tmux_cmd pipe-pane -t "$SESSION_NAME:0.0" -o "cat >> '$LOG_FILE'"
    tmux_cmd set-option -t "$SESSION_NAME" remain-on-exit on

    tmux_cmd split-window -t "$SESSION_NAME:0.0" -v \
        "bash -lc \"while true; do PORT=$CONSOLE_PORT; DETECTED=\\\$(grep -oE 'Listening for connections on port [0-9]+' '$ROOT_DIR/logs/gem5.out' 2>/dev/null | tail -n1 | awk '{print \\\$NF}'); if [ -n \\\"\\\$DETECTED\\\" ]; then PORT=\\\$DETECTED; fi; $SHARED_SCRIPTS_DIR/console_gem5.sh \\\"\\\$PORT\\\" $CONSOLE_HOST && break; echo 'console exited, retrying in 2s'; sleep 2; done; exec bash\""
    tmux_cmd pipe-pane -t "$SESSION_NAME:0.1" -o "cat >> '$LOG_FILE'"

    echo "Auto mode: tmux session '$SESSION_NAME' created." | tee -a "$LOG_FILE"
    trap '' HUP

    if [ "$AUTO_STOP" -ne 1 ]; then
        echo "Auto-stop disabled; gem5 will run until you stop it manually." | tee -a "$LOG_FILE"
        echo "  attach: tmux attach -t $SESSION_NAME"
        echo "  stop  : $SHARED_SCRIPTS_DIR/boot_gem5.sh stop"
        return 0
    fi

    if [ "$TAIL_LOG" -eq 1 ]; then
        tail -f "$LOG_FILE" &
        TAIL_PID=$!
    fi

    _GEM5_PID_FILE="$LOG_DIR_HOST/gem5.pid"
    _HEARTBEAT=0
    echo "[$(date '+%H:%M:%S')] gem5 launched. Watching for completion."

    while true; do
        if grep -q "PHASE1_RUNSCRIPT_DONE" "$LOG_FILE" 2>/dev/null; then
            echo "[$(date '+%H:%M:%S')] Sweep complete. Stopping gem5..."
            sleep 3
            "$SHARED_SCRIPTS_DIR/boot_gem5.sh" stop >> "$LOG_FILE" 2>&1 || true
            tmux_cmd kill-session -t "$SESSION_NAME" >> "$LOG_FILE" 2>&1 || true
            break
        fi
        if [ -f "$_GEM5_PID_FILE" ]; then
            _GEM5_PID=$(cat "$_GEM5_PID_FILE" 2>/dev/null)
            if [ -n "$_GEM5_PID" ] && [ "${_GEM5_PID_VALIDATED:-0}" -eq 0 ]; then
                if kill -0 "$_GEM5_PID" 2>/dev/null; then
                    _GEM5_PID_VALIDATED=1
                elif [ "$_HEARTBEAT" -lt 60 ]; then
                    sleep 5
                    continue
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
