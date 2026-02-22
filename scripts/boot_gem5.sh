#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=${ROOT_DIR:-"$(cd "$SCRIPT_DIR/.." && pwd)"}
GEM5_DIR=${GEM5_DIR:-"$ROOT_DIR/SimpleSSD-FullSystem"}
CONDA_BASE=${CONDA_BASE:-"$HOME/miniconda3"}
ENV_NAME=${ENV_NAME:-"simplessd_env"}

KERNEL=${KERNEL:-"$ROOT_DIR/assets/vmlinux-5.4.49"}
DISK_IMAGE=${DISK_IMAGE:-"$ROOT_DIR/assets/x86-ubuntu.img"}
SSD_CONFIG=${SSD_CONFIG:-"$ROOT_DIR/fast_ssd.cfg"}
MEM_SIZE=${MEM_SIZE:-"4GB"}
ROOT_DEV=${ROOT_DEV:-"/dev/hda1"}
VIO_9P=${VIO_9P:-0}
HOST_SHARE=${HOST_SHARE:-""}

LOG_DIR=${LOG_DIR:-"$ROOT_DIR/logs"}
PID_FILE=${PID_FILE:-"$LOG_DIR/gem5.pid"}
LOG_FILE=${LOG_FILE:-"$LOG_DIR/gem5.out"}

CHECKPOINT_DIR=${CHECKPOINT_DIR:-"$ROOT_DIR/results/checkpoints"}
CHECKPOINT_RESTORE=${CHECKPOINT_RESTORE:-""}
READFILE_SCRIPT=${READFILE_SCRIPT:-""}

mkdir -p "$LOG_DIR"

start_gem5() {
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "gem5 already running (pid $(cat "$PID_FILE"))"
    exit 0
  fi

  # Activate conda and set libpython path for gem5
  # Some conda deactivate hooks use unset vars; guard with set +u.
  # shellcheck source=/dev/null
  set +u
  if [ -f "$CONDA_BASE/etc/profile.d/conda.sh" ]; then
    source "$CONDA_BASE/etc/profile.d/conda.sh"
    conda activate "$ENV_NAME"
    export LD_LIBRARY_PATH="$CONDA_PREFIX/lib:${LD_LIBRARY_PATH:-}"
  else
    echo "Warning: conda.sh not found at $CONDA_BASE/etc/profile.d/conda.sh"
  fi
  set -u

  cd "$GEM5_DIR"

  mkdir -p "$CHECKPOINT_DIR"

  GEM5_ARGS=(
    --listener-mode=on
    configs/example/fs.py
    --kernel="$KERNEL"
    --disk-image="$DISK_IMAGE"
    --mem-size="$MEM_SIZE"
    --root-device="$ROOT_DEV"
    --ssd-interface=nvme
    --ssd-config="$SSD_CONFIG"
    --checkpoint-dir="$CHECKPOINT_DIR"
  )

  if [ "$VIO_9P" -eq 1 ]; then
    if ! command -v diod >/dev/null 2>&1; then
      echo "ERROR: diod not found in PATH; required for --vio-9p." >&2
      exit 1
    fi
    GEM5_ARGS+=(--vio-9p)
    if [ -n "$HOST_SHARE" ]; then
      GEM5_ARGS+=(--param "VirtIO9p.root=$HOST_SHARE")
    fi
  fi

  if [ -n "$READFILE_SCRIPT" ]; then
    GEM5_ARGS+=(--script="$READFILE_SCRIPT")
  fi

  if [ -n "$CHECKPOINT_RESTORE" ]; then
    GEM5_ARGS+=(--checkpoint-restore="$CHECKPOINT_RESTORE")
  fi

  nohup ./build/X86/gem5.opt "${GEM5_ARGS[@]}" \
    > "$LOG_FILE" 2>&1 &

  echo $! > "$PID_FILE"
  echo "gem5 started (pid $(cat "$PID_FILE"))"
  echo "log: $LOG_FILE"
}

stop_gem5() {
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    kill "$(cat "$PID_FILE")"
    echo "gem5 stopped (pid $(cat "$PID_FILE"))"
  else
    echo "gem5 not running"
  fi
  rm -f "$PID_FILE"
}

status_gem5() {
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "gem5 running (pid $(cat "$PID_FILE"))"
  else
    echo "gem5 not running"
  fi
}

restart_gem5() {
  stop_gem5
  start_gem5
}

case "${1:-start}" in
  start)
    start_gem5
    ;;
  stop)
    stop_gem5
    ;;
  restart)
    restart_gem5
    ;;
  status)
    status_gem5
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status}"
    exit 1
    ;;
esac


# Start gem5 in background (default)
#./boot_gem5.sh start

# Check status
# ./boot_gem5.sh status

# Restart (stop + start)
# ./boot_gem5.sh restart

# Stop
# ./boot_gem5.sh stop