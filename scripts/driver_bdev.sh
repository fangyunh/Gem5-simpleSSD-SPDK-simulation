#!/usr/bin/env bash
set -euo pipefail

# Example usage (fully automatic):
#   ./scripts/driver_bdev.sh --auto \
#     --cores "2" \
#     --qpairs "1" \
#     --qd "16 32" \
#     --ios "4096 16384" \
#     --repeats 2 \
#     --tag bdev_smoke
#
# Workflow (auto mode):
#   - Boot gem5, open console, run bdev sweep inside guest, tail logs here.
#
# Notes:
# - All output is piped into a single log file and tailed in this terminal.
# - Hyperparameters are passed via environment variables to phase1_bdev.sh.
# - Results are written under results/bdev_data/<run_tag>/ on the guest.

ORIGINAL_ARGC=$#
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

BOOT=0
CONSOLE=0
RUN_BDEV=0
STOP=0
AUTO=0
AUTO_STOP=1

CORES="1"
CORE_MASKS=""
QPAIRS="1"
QD_LIST="16 32 64 128"
IO_SIZES="4096 16384"
REPEATS=1
STEADY_TIME=30
RUN_TAG="bdev_run_$(date +%Y%m%d_%H%M%S)"

# bdev-specific toggles
PERF_ENABLE=1
SKIP_SETUP=0
NO_HUGE=0
HUGEMEM_MB=2048

# gem5 console
CONSOLE_HOST="localhost"
CONSOLE_PORT=3456

# auto mode controls
SESSION_NAME="bdev_auto"
GUEST_WAIT=20
GUEST_CWD=""
TAIL_LOG=1

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --auto                 Boot + console + run bdev automatically (tmux)
  --auto-stop 0|1         Auto-stop gem5 when bdev completes (default: $AUTO_STOP)
  --boot                 Boot gem5 (host-side)
  --console              Open gem5 console (host-side)
  --run-bdev             Print and run the guest bdev command (prints only)
  --stop                 Stop gem5 (host-side)

  --cores "list"          Space-separated core IDs (default: "$CORES")
  --core-masks "list"     Optional masks per core (default: empty)
  --qpairs "list"         Space-separated qpairs list (default: "$QPAIRS")
  --qd "list"             Space-separated queue depths (default: "$QD_LIST")
  --ios "list"            Space-separated IO sizes (default: "$IO_SIZES")
  --repeats N             Repeats per point (default: $REPEATS)
  --steady-time N         Steady time seconds (default: $STEADY_TIME)
  --tag NAME              Run tag (default: $RUN_TAG)

  --perf-enable 0|1       Enable perf counters (default: $PERF_ENABLE)
  --skip-setup 0|1        Skip SPDK setup.sh (default: $SKIP_SETUP)
  --no-huge 0|1           Use non-hugepage buffers (default: $NO_HUGE)
  --hugemem-mb N          Hugepage MB (default: $HUGEMEM_MB)

  --console-host HOST     Console host (default: $CONSOLE_HOST)
  --console-port PORT     Console port (default: $CONSOLE_PORT)
  --session-name NAME     tmux session name (default: $SESSION_NAME)
  --guest-wait N          Seconds to wait before sending guest commands (default: $GUEST_WAIT)
  --guest-cwd PATH        Optional guest cwd before running bdev
  --no-tail               Do not tail the combined log

Examples:
  $0 --auto --cores "2" --qpairs "1" --qd "16" --ios "4096" --repeats 1 --tag bdev_smoke
  $0 --boot --console
  $0 --run-bdev --cores "2" --qpairs "1" --qd "16" --ios "4096" --repeats 1 --tag bdev_smoke
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto) AUTO=1; shift ;;
    --auto-stop) AUTO_STOP="$2"; shift 2 ;;
    --boot) BOOT=1; shift ;;
    --console) CONSOLE=1; shift ;;
    --run-bdev) RUN_BDEV=1; shift ;;
    --stop) STOP=1; shift ;;
    --cores) CORES="$2"; shift 2 ;;
    --core-masks) CORE_MASKS="$2"; shift 2 ;;
    --qpairs) QPAIRS="$2"; shift 2 ;;
    --qd) QD_LIST="$2"; shift 2 ;;
    --ios) IO_SIZES="$2"; shift 2 ;;
    --repeats) REPEATS="$2"; shift 2 ;;
    --steady-time) STEADY_TIME="$2"; shift 2 ;;
    --tag) RUN_TAG="$2"; shift 2 ;;
    --perf-enable) PERF_ENABLE="$2"; shift 2 ;;
    --skip-setup) SKIP_SETUP="$2"; shift 2 ;;
    --no-huge) NO_HUGE="$2"; shift 2 ;;
    --hugemem-mb) HUGEMEM_MB="$2"; shift 2 ;;
    --console-host) CONSOLE_HOST="$2"; shift 2 ;;
    --console-port) CONSOLE_PORT="$2"; shift 2 ;;
    --session-name) SESSION_NAME="$2"; shift 2 ;;
    --guest-wait) GUEST_WAIT="$2"; shift 2 ;;
    --guest-cwd) GUEST_CWD="$2"; shift 2 ;;
    --no-tail) TAIL_LOG=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

if [ "$ORIGINAL_ARGC" -eq 0 ]; then
  AUTO=1
fi

LOG_DIR_HOST="$ROOT_DIR/logs"
LOG_FILE="$LOG_DIR_HOST/driver_bdev_${RUN_TAG}.log"

write_log_header() {
  mkdir -p "$LOG_DIR_HOST"
  {
    echo "========================================================"
    echo "driver_bdev.sh auto run"
    echo "timestamp: $(date -Is)"
    echo "run_tag: $RUN_TAG"
    echo "cores: $CORES"
    echo "core_masks: $CORE_MASKS"
    echo "qpairs: $QPAIRS"
    echo "qd_list: $QD_LIST"
    echo "io_sizes: $IO_SIZES"
    echo "repeats: $REPEATS"
    echo "steady_time: $STEADY_TIME"
    echo "perf_enable: $PERF_ENABLE"
    echo "skip_setup: $SKIP_SETUP"
    echo "no_huge: $NO_HUGE"
    echo "hugemem_mb: $HUGEMEM_MB"
    echo "session_name: $SESSION_NAME"
    echo "console: ${CONSOLE_HOST}:${CONSOLE_PORT}"
    echo "guest_wait: $GUEST_WAIT"
    echo "guest_cwd: ${GUEST_CWD:-<unset>}"
    echo "log_file: $LOG_FILE"
    echo "========================================================"
  } | tee -a "$LOG_FILE"
}

send_guest_cmds() {
  local target="$SESSION_NAME:0.1"
  if [ -n "$GUEST_CWD" ]; then
    tmux send-keys -t "$target" "cd $GUEST_CWD" C-m
  fi
  tmux send-keys -t "$target" "export CORE_IDS=\"$CORES\"" C-m
  tmux send-keys -t "$target" "export CORE_MASKS=\"$CORE_MASKS\"" C-m
  tmux send-keys -t "$target" "export QPAIRS_LIST=\"$QPAIRS\"" C-m
  tmux send-keys -t "$target" "export QUEUE_DEPTHS=($QD_LIST)" C-m
  tmux send-keys -t "$target" "export IO_SIZES=($IO_SIZES)" C-m
  tmux send-keys -t "$target" "export REPEATS=$REPEATS" C-m
  tmux send-keys -t "$target" "export STEADY_TIME=$STEADY_TIME" C-m
  tmux send-keys -t "$target" "export RUN_TAG=\"$RUN_TAG\"" C-m
  tmux send-keys -t "$target" "export PERF_ENABLE=$PERF_ENABLE" C-m
  tmux send-keys -t "$target" "export SKIP_SETUP=$SKIP_SETUP" C-m
  tmux send-keys -t "$target" "export NO_HUGE=$NO_HUGE" C-m
  tmux send-keys -t "$target" "export HUGEMEM_MB=$HUGEMEM_MB" C-m
  tmux send-keys -t "$target" "./scripts/phase1_bdev.sh" C-m
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

  write_log_header

  tmux new-session -d -s "$SESSION_NAME" -n boot "bash -lc \"$SCRIPT_DIR/boot_gem5.sh start; echo 'boot_gem5.sh exited'; exec bash\""
  tmux pipe-pane -t "$SESSION_NAME:0.0" -o "cat >> '$LOG_FILE'"

  tmux set-option -t "$SESSION_NAME" remain-on-exit on

  tmux split-window -t "$SESSION_NAME:0.0" -v "bash -lc \"while true; do $SCRIPT_DIR/console_gem5.sh $CONSOLE_PORT $CONSOLE_HOST && break; echo 'console exited, retrying in 2s'; sleep 2; done; exec bash\""
  tmux pipe-pane -t "$SESSION_NAME:0.1" -o "cat >> '$LOG_FILE'"

  echo "Auto mode: tmux session '$SESSION_NAME' created." | tee -a "$LOG_FILE"
  echo "Tailing combined log in this terminal." | tee -a "$LOG_FILE"

  (
    sleep "$GUEST_WAIT"
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
      send_guest_cmds
      echo "Guest commands sent." >> "$LOG_FILE"
    else
      echo "ERROR: tmux session missing; guest commands not sent." >> "$LOG_FILE"
    fi
  ) &

  if [ "$AUTO_STOP" -eq 1 ]; then
    if [ "$TAIL_LOG" -eq 1 ]; then
      tail -f "$LOG_FILE" &
      TAIL_PID=$!
    fi

    while true; do
      if grep -q "Phase 1 (bdev) Complete" "$LOG_FILE"; then
        echo "Detected bdev completion. Stopping gem5..." >> "$LOG_FILE"
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
  "$SCRIPT_DIR/boot_gem5.sh" start
fi

if [ "$CONSOLE" -eq 1 ]; then
  "$SCRIPT_DIR/console_gem5.sh" "$CONSOLE_PORT" "$CONSOLE_HOST"
fi

if [ "$RUN_BDEV" -eq 1 ]; then
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
export PERF_ENABLE=$PERF_ENABLE
export SKIP_SETUP=$SKIP_SETUP
export NO_HUGE=$NO_HUGE
export HUGEMEM_MB=$HUGEMEM_MB

./scripts/phase1_bdev.sh
EOF
fi

if [ "$STOP" -eq 1 ]; then
  "$SCRIPT_DIR/boot_gem5.sh" stop
fi
