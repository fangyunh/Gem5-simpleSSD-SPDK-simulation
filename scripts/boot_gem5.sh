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
# Number of guest CPUs (default 1 for backward compat).  Set by drivers that
# want multi-host-core gem5 boots (e.g. driver_phase1_trace.sh --num-cpus N).
NUM_CPUS=${NUM_CPUS:-1}

# Host CPU model (default AtomicSimpleCPU for fast simulation, no caches).
# Set to TimingSimpleCPU for realistic memory-timing model that allows multi-
# host-CPU memory accesses to overlap.  Requires ENABLE_CACHES=1 to make
# scaling meaningful (otherwise every fetch/load still hits the shared
# membus and serializes).  See docs/TIMING_CACHES_PREP_PLAN.md.
CPU_TYPE=${CPU_TYPE:-AtomicSimpleCPU}

# Enable L1I/L1D per CPU + shared L2.  When ENABLE_CACHES=1, gem5 args get
# --caches appended.  ENABLE_L2_CACHE=1 (default) additionally appends --l2cache.
# Default sizes from Options.py: L1I 32 kB, L1D 64 kB, L2 2 MB.  No effect on
# AtomicSimpleCPU (which is wired direct to the membus in our cfg) — set
# CPU_TYPE=TimingSimpleCPU to actually use the caches.
#
# Note: at NUM_CPUS>=4 + TimingSimpleCPU + --l2cache + SimpleSSD this gem5
# build hits a "bad_function_call" during SMP bring-up (empty std::function
# in the power-state callback path).  Workaround: ENABLE_L2_CACHE=0 to run
# L1-only.  Tracked in docs/TIMING_CACHES_PREP_PLAN.md.
ENABLE_CACHES=${ENABLE_CACHES:-0}
ENABLE_L2_CACHE=${ENABLE_L2_CACHE:-1}
VIO_9P=${VIO_9P:-0}
HOST_SHARE=${HOST_SHARE:-""}
VIO_9P_SET_ROOT=${VIO_9P_SET_ROOT:-0}

LOG_DIR=${LOG_DIR:-"$ROOT_DIR/logs"}
PID_FILE=${PID_FILE:-"$LOG_DIR/gem5.pid"}
LOG_FILE=${LOG_FILE:-"$LOG_DIR/gem5.out"}
GEM5_OUTDIR=${GEM5_OUTDIR:-"$GEM5_DIR/m5out"}

CHECKPOINT_DIR=${CHECKPOINT_DIR:-"$ROOT_DIR/results/checkpoints"}
CHECKPOINT_RESTORE=${CHECKPOINT_RESTORE:-""}
# When restoring from a checkpoint taken under one CPU model, optionally
# switch to a different CPU model on restore (e.g., atomic-mode boot →
# TimingSimpleCPU+caches for the workload).  See TIMING_CACHES_PREP_PLAN §7.3.
RESTORE_WITH_CPU=${RESTORE_WITH_CPU:-""}
READFILE_SCRIPT=${READFILE_SCRIPT:-""}

mkdir -p "$LOG_DIR"

resolve_path() {
  local p="$1"
  if command -v readlink >/dev/null 2>&1; then
    readlink -f "$p" 2>/dev/null || echo "$p"
  else
    echo "$p"
  fi
}

start_gem5() {
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "gem5 already running (pid $(cat "$PID_FILE"))"
    exit 0
  fi

  if [ -s "$LOG_FILE" ]; then
    cp -p "$LOG_FILE" "${LOG_FILE}.prev"
  fi

  # Activate conda and set libpython path for gem5.
  # Some conda hooks use unset vars; guard with set +u.
  # shellcheck source=/dev/null
  set +u
  set +e
  if [ -f "$CONDA_BASE/etc/profile.d/conda.sh" ]; then
    source "$CONDA_BASE/etc/profile.d/conda.sh"
    conda activate "$ENV_NAME" >/dev/null 2>&1
    if [ $? -eq 0 ] && [ -n "${CONDA_PREFIX:-}" ]; then
      export LD_LIBRARY_PATH="$CONDA_PREFIX/lib:${LD_LIBRARY_PATH:-}"
    else
      echo "Warning: conda env '$ENV_NAME' not found; continuing without conda."
    fi
  else
    echo "Warning: conda.sh not found at $CONDA_BASE/etc/profile.d/conda.sh"
  fi
  set -e
  set -u

  KERNEL=$(resolve_path "$KERNEL")
  DISK_IMAGE=$(resolve_path "$DISK_IMAGE")
  SSD_CONFIG=$(resolve_path "$SSD_CONFIG")
  CHECKPOINT_DIR=$(resolve_path "$CHECKPOINT_DIR")
  GEM5_OUTDIR=$(resolve_path "$GEM5_OUTDIR")

  cd "$GEM5_DIR"

  mkdir -p "$CHECKPOINT_DIR"
  mkdir -p "$GEM5_OUTDIR"

  GEM5_ARGS=(
    --outdir="$GEM5_OUTDIR"
    --listener-mode=on
    configs/example/fs.py
    --kernel="$KERNEL"
    --disk-image="$DISK_IMAGE"
    --mem-size="$MEM_SIZE"
    --num-cpus="$NUM_CPUS"
    --cpu-type="$CPU_TYPE"
    --root-device="$ROOT_DEV"
    --ssd-interface=nvme
    --ssd-config="$SSD_CONFIG"
    --checkpoint-dir="$CHECKPOINT_DIR"
  )
  if [ "$ENABLE_CACHES" -eq 1 ]; then
    GEM5_ARGS+=(--caches)
    if [ "$ENABLE_L2_CACHE" -eq 1 ]; then
      GEM5_ARGS+=(--l2cache)
    fi
  fi

  if [ "$VIO_9P" -eq 1 ]; then
    if ! command -v diod >/dev/null 2>&1; then
      echo "Warning: diod not found in PATH; disabling --vio-9p." >&2
      VIO_9P=0
    else
      GEM5_ARGS+=(--vio-9p)
      if [ "$VIO_9P_SET_ROOT" -eq 1 ] && [ -n "$HOST_SHARE" ]; then
        GEM5_ARGS+=(--param "system.pc.viopci.vio.root=\"$HOST_SHARE\"")
      fi
    fi
  fi

  if [ -n "$READFILE_SCRIPT" ]; then
    GEM5_ARGS+=(--script="$READFILE_SCRIPT")
  fi

  if [ -n "$CHECKPOINT_RESTORE" ]; then
    GEM5_ARGS+=(--checkpoint-restore="$CHECKPOINT_RESTORE")
    if [ -n "$RESTORE_WITH_CPU" ]; then
      GEM5_ARGS+=(--restore-with-cpu="$RESTORE_WITH_CPU")
    fi
  fi

  if [ ! -x "./build/X86/gem5.opt" ]; then
    echo "ERROR: gem5 binary not found at $GEM5_DIR/build/X86/gem5.opt" >&2
    echo "Build it first:" >&2
    echo "  (cd $GEM5_DIR && scons build/X86/gem5.opt -j\$(nproc))" >&2
    exit 1
  fi

  # Three-layer detachment from the terminal session so that VS Code crashes,
  # SSH disconnects, or any PTY hangup can NEVER kill gem5 or diod:
  #
  #   setsid  -- puts gem5 (and all its children, including diod) into a BRAND
  #              NEW kernel session, completely severing it from the launching
  #              terminal's session/process-group.  The kernel can no longer
  #              reach it with any session-lifecycle signal (SIGHUP, SIGTERM
  #              from login-session teardown).  This is the critical fix:
  #              nohup+disown alone still leave the process in the original
  #              session so systemd/PAM/kernel can send SIGTERM on logout.
  #
  #   nohup   -- makes the process explicitly ignore SIGHUP as a belt-and-
  #              suspenders measure (belt = setsid; suspenders = nohup).
  #
  #   disown  -- removes gem5 from bash's job table so bash won't track it.
  #
  # nice -n 19: absolute lowest scheduling priority (0..19 scale, higher=nicer).
  #   gem5 gets CPU only when nothing else wants it.  Safe for shared servers.
  #   On a dedicated machine you can lower this to -n 10 if speed matters more.
  #
  # taskset: pin gem5 + diod to cores 0..(nproc-9), reserving 8 cores for
  #   the OS / other users.  Falls back gracefully on small machines.
  _NPROC=$(nproc 2>/dev/null || echo 4)
  if [ "$_NPROC" -gt 20 ]; then
    _TASKSET_PREFIX="taskset -c 0-$((${_NPROC} - 9))"
  elif [ "$_NPROC" -gt 8 ]; then
    _TASKSET_PREFIX="taskset -c 0-$((${_NPROC} - 4))"
  else
    _TASKSET_PREFIX=""
  fi

  setsid nohup $_TASKSET_PREFIX nice -n 19 ./build/X86/gem5.opt "${GEM5_ARGS[@]}" \
    > "$LOG_FILE" 2>&1 &
  GEM5_PID=$!
  echo "$GEM5_PID" > "$PID_FILE"
  # disown: belt-and-suspenders removal from bash job table.
  disown "$GEM5_PID" 2>/dev/null || true
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