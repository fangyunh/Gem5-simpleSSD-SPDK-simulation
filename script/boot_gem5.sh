#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="/home/fangyunh/Documents/SimpleSSD_Gem5_simulation"
GEM5_DIR="$ROOT_DIR/SimpleSSD-FullSystem"
CONDA_BASE="$HOME/miniconda3"
ENV_NAME="simplessd_env"

KERNEL="$ROOT_DIR/assets/vmlinux-5.4.49"
DISK_IMAGE="$ROOT_DIR/assets/x86-ubuntu.img"
SSD_CONFIG="$ROOT_DIR/fast_ssd.cfg"
MEM_SIZE="4GB"
ROOT_DEV="/dev/hda1"

LOG_DIR="$ROOT_DIR/logs"
PID_FILE="$LOG_DIR/gem5.pid"
LOG_FILE="$LOG_DIR/gem5.out"

mkdir -p "$LOG_DIR"

start_gem5() {
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "gem5 already running (pid $(cat "$PID_FILE"))"
    exit 0
  fi

  # Activate conda and set libpython path for gem5
  # shellcheck source=/dev/null
  source "$CONDA_BASE/etc/profile.d/conda.sh"
  conda activate "$ENV_NAME"
  export LD_LIBRARY_PATH="$CONDA_PREFIX/lib:${LD_LIBRARY_PATH:-}"

  cd "$GEM5_DIR"

  nohup ./build/X86/gem5.opt --listener-mode=on configs/example/fs.py \
    --kernel="$KERNEL" \
    --disk-image="$DISK_IMAGE" \
    --mem-size="$MEM_SIZE" \
    --root-device="$ROOT_DEV" \
    --ssd-interface=nvme \
    --ssd-config="$SSD_CONFIG" \
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