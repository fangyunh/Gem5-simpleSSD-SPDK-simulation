#!/usr/bin/env bash
set -euo pipefail

# Example usage (fully automatic):
#   ./scripts/driver_phase1.sh --auto \
#     --cores "2" \
#     --qpairs "1" \
#     --qd "16 32" \
#     --ios "4096 16384" \
#     --repeats 2 \
#     --tag phase1_smoke
#
# Workflow (auto mode):
#   - Boot gem5, open console, run phase1 inside guest, tail logs here.
#
# Notes:
# - All output is piped into a single log file and tailed in this terminal.
# - Hyperparameters are passed via environment variables to phase1_run.sh.
# - A metadata sidecar JSON is written under results/phase1_runs/<run_tag>/.

ORIGINAL_ARGC=$#
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

BOOT=0
CONSOLE=0
RUN_PHASE1=0
STOP=0
AUTO=0
AUTO_STOP=0
USE_READFILE=1

CORES="1"
CORE_MASKS=""
QPAIRS="1"
QD_LIST="16 32 64 128"
IO_SIZES="4096 16384"
REPEATS=1
STEADY_TIME=30
RUN_TAG="phase1_run_$(date +%Y%m%d_%H%M%S)"

# phase1-specific toggles
PCI_ADDR="0000:02:00.0"
PCI_CHECK=0
PERF_ENABLE=1
SKIP_SETUP=1
HUGEMEM_MB=2048

# host share for virtio-9p (readfile mode)
VIO_9P=0
HOST_SHARE="$ROOT_DIR"

# gem5 boot args (for metadata only; overrides boot_gem5.sh if set)
KERNEL="$ROOT_DIR/assets/vmlinux-5.4.49"
DISK_IMAGE="$ROOT_DIR/assets/x86-ubuntu.img"
MEM_SIZE="4GB"
SSD_CONFIG="$ROOT_DIR/fast_ssd.cfg"
CHECKPOINT_DIR="$ROOT_DIR/results/checkpoints"

# gem5 console
CONSOLE_HOST="localhost"
CONSOLE_PORT=3456

# auto mode controls
SESSION_NAME="phase1_auto"
GUEST_WAIT=20
GUEST_CWD=""
TAIL_LOG=1
GUEST_OUTPUT_ROOT="results/phase1_runs"
GUEST_REPO="/root/SimpleSSD_Gem5_simulation"
GUEST_REPO_CANDIDATES="/root/SimpleSSD_Gem5_simulation /home/root/SimpleSSD_Gem5_simulation /home/ubuntu/SimpleSSD_Gem5_simulation /mnt/host/SimpleSSD_Gem5_simulation /mnt/9p/SimpleSSD_Gem5_simulation"
WAIT_FOR_REGEX="login:|# "
WAIT_TIMEOUT=600
WAIT_INTERVAL=2

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --auto                 Boot + console + run phase1 automatically (tmux)
  --auto-stop 0|1         Auto-stop gem5 when phase1 completes (default: $AUTO_STOP)
  --boot                 Boot gem5 (host-side)
  --console              Open gem5 console (host-side)
  --run-phase1           Print and run the guest phase1 command (prints only)
  --stop                 Stop gem5 (host-side)

  --cores "list"          Space-separated core IDs (default: "$CORES")
  --core-masks "list"     Optional masks per core (default: empty)
  --qpairs "list"         Space-separated qpairs list (default: "$QPAIRS")
  --qd "list"             Space-separated queue depths (default: "$QD_LIST")
  --ios "list"            Space-separated IO sizes (default: "$IO_SIZES")
  --repeats N             Repeats per point (default: $REPEATS)
  --steady-time N         Steady time seconds (default: $STEADY_TIME)
  --tag NAME              Run tag (default: $RUN_TAG)

  --pci-addr ADDR         PCI address (default: $PCI_ADDR)
  --pci-check 0|1         Enable PCI validation (default: $PCI_CHECK)
  --perf-enable 0|1       Enable perf counters (default: $PERF_ENABLE)
  --skip-setup 0|1        Skip SPDK setup.sh (default: $SKIP_SETUP)
  --hugemem-mb N          Hugepage MB (default: $HUGEMEM_MB)
  --vio-9p 0|1            Enable virtio-9p share (default: $VIO_9P)
  --host-share PATH       Host path to share via virtio-9p (default: $HOST_SHARE)

  --kernel PATH           Kernel path for metadata/boot override
  --disk-image PATH       Disk image path for metadata/boot override
  --mem-size SIZE         Memory size for metadata/boot override
  --ssd-config PATH       SSD config path for metadata/boot override
  --checkpoint-dir PATH   Checkpoint dir for metadata/boot override

  --console-host HOST     Console host (default: $CONSOLE_HOST)
  --console-port PORT     Console port (default: $CONSOLE_PORT)
  --session-name NAME     tmux session name (default: $SESSION_NAME)
  --guest-wait N          Seconds to wait before sending guest commands (default: $GUEST_WAIT)
  --guest-cwd PATH        Optional guest cwd before running phase1
  --guest-output-root P   Guest output root (default: $GUEST_OUTPUT_ROOT)
  --guest-repo PATH       Guest repo path (default: $GUEST_REPO)
  --guest-repo-candidates "list"  Space-separated probe paths for repo
  --wait-for REGEX        Wait for console log regex before sending commands
  --wait-timeout N        Max seconds to wait for regex (default: $WAIT_TIMEOUT)
  --use-readfile 0|1      Use gem5 readfile script (default: $USE_READFILE)
  --no-tail               Do not tail the combined log

Examples:
  $0 --auto --cores "2" --qpairs "1" --qd "16" --ios "4096" --repeats 1 --tag phase1_smoke
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto) AUTO=1; shift ;;
    --auto-stop) AUTO_STOP="$2"; shift 2 ;;
    --boot) BOOT=1; shift ;;
    --console) CONSOLE=1; shift ;;
    --run-phase1) RUN_PHASE1=1; shift ;;
    --stop) STOP=1; shift ;;
    --cores) CORES="$2"; shift 2 ;;
    --core-masks) CORE_MASKS="$2"; shift 2 ;;
    --qpairs) QPAIRS="$2"; shift 2 ;;
    --qd) QD_LIST="$2"; shift 2 ;;
    --ios) IO_SIZES="$2"; shift 2 ;;
    --repeats) REPEATS="$2"; shift 2 ;;
    --steady-time) STEADY_TIME="$2"; shift 2 ;;
    --tag) RUN_TAG="$2"; shift 2 ;;
    --pci-addr) PCI_ADDR="$2"; shift 2 ;;
    --pci-check) PCI_CHECK="$2"; shift 2 ;;
    --perf-enable) PERF_ENABLE="$2"; shift 2 ;;
    --skip-setup) SKIP_SETUP="$2"; shift 2 ;;
    --hugemem-mb) HUGEMEM_MB="$2"; shift 2 ;;
    --vio-9p) VIO_9P="$2"; shift 2 ;;
    --host-share) HOST_SHARE="$2"; shift 2 ;;
    --kernel) KERNEL="$2"; shift 2 ;;
    --disk-image) DISK_IMAGE="$2"; shift 2 ;;
    --mem-size) MEM_SIZE="$2"; shift 2 ;;
    --ssd-config) SSD_CONFIG="$2"; shift 2 ;;
    --checkpoint-dir) CHECKPOINT_DIR="$2"; shift 2 ;;
    --console-host) CONSOLE_HOST="$2"; shift 2 ;;
    --console-port) CONSOLE_PORT="$2"; shift 2 ;;
    --session-name) SESSION_NAME="$2"; shift 2 ;;
    --guest-wait) GUEST_WAIT="$2"; shift 2 ;;
    --guest-cwd) GUEST_CWD="$2"; shift 2 ;;
    --guest-output-root) GUEST_OUTPUT_ROOT="$2"; shift 2 ;;
    --guest-repo) GUEST_REPO="$2"; shift 2 ;;
    --guest-repo-candidates) GUEST_REPO_CANDIDATES="$2"; shift 2 ;;
    --wait-for) WAIT_FOR_REGEX="$2"; shift 2 ;;
    --wait-timeout) WAIT_TIMEOUT="$2"; shift 2 ;;
    --use-readfile) USE_READFILE="$2"; shift 2 ;;
    --no-tail) TAIL_LOG=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

if [ "$ORIGINAL_ARGC" -eq 0 ]; then
  AUTO=1
fi

LOG_DIR_HOST="$ROOT_DIR/logs"
LOG_FILE="$LOG_DIR_HOST/driver_phase1_${RUN_TAG}.log"
META_DIR="$ROOT_DIR/results/phase1_runs/$RUN_TAG"
META_FILE="$META_DIR/metadata.json"

write_metadata() {
  mkdir -p "$META_DIR"
  cat > "$META_FILE" <<EOF
{
  "run_tag": "$RUN_TAG",
  "cores": "$CORES",
  "core_masks": "$CORE_MASKS",
  "qpairs": "$QPAIRS",
  "qd_list": "$QD_LIST",
  "io_sizes": "$IO_SIZES",
  "repeats": $REPEATS,
  "steady_time": $STEADY_TIME,
  "pci_addr": "$PCI_ADDR",
  "pci_check": $PCI_CHECK,
  "perf_enable": $PERF_ENABLE,
  "skip_setup": $SKIP_SETUP,
  "hugemem_mb": $HUGEMEM_MB,
  "vio_9p": $VIO_9P,
  "host_share": "$HOST_SHARE",
  "gem5": {
    "kernel": "$KERNEL",
    "disk_image": "$DISK_IMAGE",
    "mem_size": "$MEM_SIZE",
    "ssd_config": "$SSD_CONFIG",
    "checkpoint_dir": "$CHECKPOINT_DIR"
  }
}
EOF
}

write_log_header() {
  mkdir -p "$LOG_DIR_HOST"
  {
    echo "========================================================"
    echo "driver_phase1.sh auto run"
    echo "timestamp: $(date -Is)"
    echo "run_tag: $RUN_TAG"
    echo "cores: $CORES"
    echo "core_masks: $CORE_MASKS"
    echo "qpairs: $QPAIRS"
    echo "qd_list: $QD_LIST"
    echo "io_sizes: $IO_SIZES"
    echo "repeats: $REPEATS"
    echo "steady_time: $STEADY_TIME"
    echo "pci_addr: $PCI_ADDR"
    echo "pci_check: $PCI_CHECK"
    echo "perf_enable: $PERF_ENABLE"
    echo "skip_setup: $SKIP_SETUP"
    echo "hugemem_mb: $HUGEMEM_MB"
    echo "vio_9p: $VIO_9P"
    echo "host_share: $HOST_SHARE"
    echo "session_name: $SESSION_NAME"
    echo "console: ${CONSOLE_HOST}:${CONSOLE_PORT}"
    echo "guest_wait: $GUEST_WAIT"
    echo "guest_cwd: ${GUEST_CWD:-<unset>}"
    echo "wait_for_regex: ${WAIT_FOR_REGEX:-<unset>}"
    echo "wait_timeout: $WAIT_TIMEOUT"
    echo "use_readfile: $USE_READFILE"
    echo "guest_repo: $GUEST_REPO"
    echo "guest_repo_candidates: $GUEST_REPO_CANDIDATES"
    echo "metadata_file: $META_FILE"
    echo "log_file: $LOG_FILE"
    echo "========================================================"
  } | tee -a "$LOG_FILE"
}

wait_for_console() {
  local regex="$1"
  local timeout="$2"
  local waited=0
  local target="$SESSION_NAME:0.1"

  while [ "$waited" -lt "$timeout" ]; do
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
      if tmux capture-pane -pt "$target" -S -2000 | grep -E -q "$regex"; then
        return 0
      fi
    fi
    sleep "$WAIT_INTERVAL"
    waited=$((waited + WAIT_INTERVAL))
  done
  return 1
}

send_guest_cmds() {
  local target="$SESSION_NAME:0.1"
  if [ -n "$GUEST_CWD" ]; then
    tmux send-keys -t "$target" "cd $GUEST_CWD" C-m
  fi
  tmux send-keys -t "$target" "if [ -d '$GUEST_REPO' ] && [ -f '$GUEST_REPO/scripts/phase1_run.sh' ]; then cd '$GUEST_REPO'; else for p in $GUEST_REPO_CANDIDATES; do if [ -f \"\$p/scripts/phase1_run.sh\" ]; then cd \"\$p\"; break; fi; done; fi" C-m
  tmux send-keys -t "$target" "export CORE_IDS=\"$CORES\"" C-m
  tmux send-keys -t "$target" "export CORE_MASKS=\"$CORE_MASKS\"" C-m
  tmux send-keys -t "$target" "export QPAIRS_LIST=\"$QPAIRS\"" C-m
  tmux send-keys -t "$target" "export QUEUE_DEPTHS_LIST=\"$QD_LIST\"" C-m
  tmux send-keys -t "$target" "export IO_SIZES_LIST=\"$IO_SIZES\"" C-m
  tmux send-keys -t "$target" "export REPEATS=$REPEATS" C-m
  tmux send-keys -t "$target" "export STEADY_TIME=$STEADY_TIME" C-m
  tmux send-keys -t "$target" "export RUN_TAG=\"$RUN_TAG\"" C-m
  tmux send-keys -t "$target" "export OUTPUT_ROOT=\"$GUEST_OUTPUT_ROOT\"" C-m
  tmux send-keys -t "$target" "export PCI_ADDR=\"$PCI_ADDR\"" C-m
  tmux send-keys -t "$target" "export PCI_CHECK=$PCI_CHECK" C-m
  tmux send-keys -t "$target" "export PERF_ENABLE=$PERF_ENABLE" C-m
  tmux send-keys -t "$target" "export SKIP_SETUP=$SKIP_SETUP" C-m
  tmux send-keys -t "$target" "export HUGEMEM_MB=$HUGEMEM_MB" C-m
  tmux send-keys -t "$target" "./scripts/phase1_run.sh" C-m
}

write_readfile_script() {
  local script_path="$LOG_DIR_HOST/phase1_readfile_${RUN_TAG}.sh"
  cat > "$script_path" <<'EOF'
#!/bin/sh
LOG_FILE="/tmp/phase1_readfile.log"
REPO_HINT="__REPO_HINT__"
REPO_CANDIDATES="__REPO_CANDIDATES__"
HOST_SHARE="__HOST_SHARE__"
{
  echo "PHASE1_RUNSCRIPT_START"
  echo "PHASE1_RUNSCRIPT_INFO: uname=$(uname -a)"
  echo "PHASE1_RUNSCRIPT_INFO: pwd=$(pwd)"
  echo "PHASE1_RUNSCRIPT_INFO: mounts:"
  mount | sed 's/^/  /'
  echo "PHASE1_RUNSCRIPT_INFO: ls /"
  ls -la / | sed 's/^/  /'
  echo "PHASE1_RUNSCRIPT_INFO: ls /mnt"
  ls -la /mnt 2>/dev/null | sed 's/^/  /'

  if [ -n "$HOST_SHARE" ] && [ -d /mnt/9p ] && ! mountpoint -q /mnt/9p 2>/dev/null; then
    mount -t 9p -o trans=virtio,version=9p2000.L,aname="$HOST_SHARE" gem5 /mnt/9p 2>/dev/null || true
  fi

  find_repo() {
    for p in "$REPO_HINT" $REPO_CANDIDATES; do
      if [ -d "$p" ] && [ -f "$p/scripts/phase1_run.sh" ]; then
        echo "$p"
        return 0
      fi
    done
    # Fallback: scan for the script within a shallow depth
    found=$(find / -maxdepth 6 -path "*/scripts/phase1_run.sh" 2>/dev/null | head -n1)
    if [ -n "$found" ]; then
      echo "$(dirname "$(dirname "$found")")"
      return 0
    fi
    return 1
  }

  REPO_PATH="$(find_repo)"
  if [ -z "$REPO_PATH" ]; then
    echo "PHASE1_RUNSCRIPT_ERROR: repo not found"
    echo "Checked: $REPO_HINT $REPO_CANDIDATES"
    exit 1
  fi

  echo "PHASE1_RUNSCRIPT_REPO: $REPO_PATH"
  cd "$REPO_PATH" || exit 1
export CORE_IDS="__CORE_IDS__"
export CORE_MASKS="__CORE_MASKS__"
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
  ./scripts/phase1_run.sh
  echo "PHASE1_RUNSCRIPT_DONE"
} 2>&1 | tee "$LOG_FILE"

echo "PHASE1_RUNSCRIPT_LOG_BEGIN"
cat "$LOG_FILE"
echo "PHASE1_RUNSCRIPT_LOG_END"

if command -v m5 >/dev/null 2>&1; then
  m5 exit
fi
EOF

  sed -i \
    -e "s|__REPO_HINT__|$GUEST_REPO|g" \
    -e "s|__REPO_CANDIDATES__|$GUEST_REPO_CANDIDATES|g" \
    -e "s|__HOST_SHARE__|$HOST_SHARE|g" \
    -e "s|__CORE_IDS__|$CORES|g" \
    -e "s|__CORE_MASKS__|$CORE_MASKS|g" \
    -e "s|__QPAIRS__|$QPAIRS|g" \
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
    "$script_path"

  if [ ! -s "$script_path" ]; then
    echo "ERROR: readfile script is empty: $script_path" >&2
    exit 1
  fi
  chmod +x "$script_path"
  echo "$script_path"
}

run_auto() {
  if ! command -v tmux >/dev/null 2>&1; then
    echo "tmux not found. Install tmux or run with manual options." >&2
    exit 1
  fi

  if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "tmux session already exists: $SESSION_NAME" >&2
    exit 1
  fi

  write_metadata
  write_log_header

  if [ "$USE_READFILE" -eq 1 ]; then
    READFILE_SCRIPT=$(write_readfile_script)
    tmux new-session -d -s "$SESSION_NAME" -n boot "bash -lc \"KERNEL=$KERNEL DISK_IMAGE=$DISK_IMAGE MEM_SIZE=$MEM_SIZE SSD_CONFIG=$SSD_CONFIG CHECKPOINT_DIR=$CHECKPOINT_DIR READFILE_SCRIPT=$READFILE_SCRIPT VIO_9P=$VIO_9P HOST_SHARE='$HOST_SHARE' $SCRIPT_DIR/boot_gem5.sh start; echo 'boot_gem5.sh exited'; exec bash\""
  else
    tmux new-session -d -s "$SESSION_NAME" -n boot "bash -lc \"KERNEL=$KERNEL DISK_IMAGE=$DISK_IMAGE MEM_SIZE=$MEM_SIZE SSD_CONFIG=$SSD_CONFIG CHECKPOINT_DIR=$CHECKPOINT_DIR VIO_9P=$VIO_9P HOST_SHARE='$HOST_SHARE' $SCRIPT_DIR/boot_gem5.sh start; echo 'boot_gem5.sh exited'; exec bash\""
  fi
  tmux pipe-pane -t "$SESSION_NAME:0.0" -o "cat >> '$LOG_FILE'"
  tmux set-option -t "$SESSION_NAME" remain-on-exit on

  tmux split-window -t "$SESSION_NAME:0.0" -v "bash -lc \"while true; do $SCRIPT_DIR/console_gem5.sh $CONSOLE_PORT $CONSOLE_HOST && break; echo 'console exited, retrying in 2s'; sleep 2; done; exec bash\""
  tmux pipe-pane -t "$SESSION_NAME:0.1" -o "cat >> '$LOG_FILE'"

  echo "Auto mode: tmux session '$SESSION_NAME' created." | tee -a "$LOG_FILE"
  echo "Tailing combined log in this terminal." | tee -a "$LOG_FILE"

  if [ "$USE_READFILE" -eq 0 ]; then
    (
      if [ -n "$WAIT_FOR_REGEX" ]; then
        if ! wait_for_console "$WAIT_FOR_REGEX" "$WAIT_TIMEOUT"; then
          echo "WARN: wait-for regex timed out; sending commands anyway." >> "$LOG_FILE"
          sleep "$GUEST_WAIT"
        fi
      else
        sleep "$GUEST_WAIT"
      fi
      if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        send_guest_cmds
        echo "Guest commands sent." >> "$LOG_FILE"
      else
        echo "ERROR: tmux session missing; guest commands not sent." >> "$LOG_FILE"
      fi
    ) &
  else
    echo "Using gem5 readfile script; console injection disabled." >> "$LOG_FILE"
  fi

  if [ "$AUTO_STOP" -eq 1 ]; then
    if [ "$TAIL_LOG" -eq 1 ]; then
      tail -f "$LOG_FILE" &
      TAIL_PID=$!
    fi

    while true; do
      if grep -q "Phase 1 Complete" "$LOG_FILE"; then
        echo "Detected phase1 completion. Stopping gem5..." >> "$LOG_FILE"
        "$SCRIPT_DIR/boot_gem5.sh" stop >> "$LOG_FILE" 2>&1 || true
        tmux kill-session -t "$SESSION_NAME" >> "$LOG_FILE" 2>&1 || true
        break
      fi
      sleep 5
    done

    if [ -n "${TAIL_PID:-}" ]; then
      kill "$TAIL_PID" 2>/dev/null || true
    fi
  else
    if [ "$TAIL_LOG" -eq 1 ]; then
      tail -f "$LOG_FILE"
    else
      echo "Auto mode running. Log file: $LOG_FILE"
      echo "Attach: tmux attach -t $SESSION_NAME"
    fi
  fi
}

if [ "$AUTO" -eq 1 ]; then
  run_auto
  exit 0
fi

if [ "$BOOT" -eq 1 ]; then
  KERNEL="$KERNEL" DISK_IMAGE="$DISK_IMAGE" MEM_SIZE="$MEM_SIZE" SSD_CONFIG="$SSD_CONFIG" CHECKPOINT_DIR="$CHECKPOINT_DIR" \
    "$SCRIPT_DIR/boot_gem5.sh" start
fi

if [ "$CONSOLE" -eq 1 ]; then
  "$SCRIPT_DIR/console_gem5.sh" "$CONSOLE_PORT" "$CONSOLE_HOST"
fi

if [ "$RUN_PHASE1" -eq 1 ]; then
  write_metadata
  echo "Run this inside the gem5 guest shell:"
  echo
  cat <<EOF
export CORE_IDS="$CORES"
export CORE_MASKS="$CORE_MASKS"
export QPAIRS_LIST="$QPAIRS"
export QUEUE_DEPTHS=($QD_LIST)
export IO_SIZES=($IO_SIZES)
export REPEATS=$REPEATS
export STEADY_TIME=$STEADY_TIME
export RUN_TAG="$RUN_TAG"
export OUTPUT_ROOT="$GUEST_OUTPUT_ROOT"
export PCI_ADDR="$PCI_ADDR"
export PCI_CHECK=$PCI_CHECK
export PERF_ENABLE=$PERF_ENABLE
export SKIP_SETUP=$SKIP_SETUP
export HUGEMEM_MB=$HUGEMEM_MB

./scripts/phase1_run.sh
EOF
fi

if [ "$STOP" -eq 1 ]; then
  "$SCRIPT_DIR/boot_gem5.sh" stop
fi
