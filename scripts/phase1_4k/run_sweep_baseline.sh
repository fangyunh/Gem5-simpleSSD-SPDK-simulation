#!/usr/bin/env bash
# =============================================================================
# run_sweep.sh — Sequential pipeline for Phase 1 simulation sweeps
#
# Runs driver_phase1.sh for every (IO_SIZE, QD) combination one at a time,
# ensuring each run starts from a clean state (gem5 stopped, phase1_auto
# tmux session killed).
#
# Usage:
#   bash scripts/run_sweep.sh [OPTIONS]
#
# Examples:
#   bash scripts/run_sweep.sh --ios "4096 16384" --qd "16 32 64 128"
#   bash scripts/run_sweep.sh --ios "4096" --qd "16 32" --steady-time 10
#   bash scripts/run_sweep.sh --ios "4096 16384" --qd "16 32 64 128" --repeats 3
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHARED_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---- Defaults ----
IO_SIZES="4096 16384"
QD_LIST="64 128"
REPEATS=1
STEADY_TIME=30
TAG_PREFIX="phase1"
EXTRA_ARGS=""

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --ios "list"          Space-separated IO sizes in bytes (default: "$IO_SIZES")
  --qd "list"           Space-separated queue depths     (default: "$QD_LIST")
  --repeats N           Repeats per point                (default: $REPEATS)
  --steady-time N       Steady-state seconds per run     (default: $STEADY_TIME)
  --tag-prefix PREFIX   Prefix for auto-generated tags   (default: $TAG_PREFIX)
  --extra "ARGS"        Extra args passed to driver_phase1.sh verbatim
  -h|--help             Show this help
EOF
  exit 0
}

# ---- Parse args ----
while [ $# -gt 0 ]; do
  case "$1" in
    --ios)         IO_SIZES="$2";    shift 2 ;;
    --qd)          QD_LIST="$2";     shift 2 ;;
    --repeats)     REPEATS="$2";     shift 2 ;;
    --steady-time) STEADY_TIME="$2"; shift 2 ;;
    --tag-prefix)  TAG_PREFIX="$2";  shift 2 ;;
    --extra)       EXTRA_ARGS="$2";  shift 2 ;;
    -h|--help)     usage ;;
    *)             echo "Unknown option: $1"; usage ;;
  esac
done

# Convert IO size in bytes to human label for tag names
io_label() {
  local bytes="$1"
  if   [ "$bytes" -ge 1048576 ]; then echo "$(( bytes / 1048576 ))mb"
  elif [ "$bytes" -ge 1024 ];    then echo "$(( bytes / 1024 ))kb"
  else                                echo "${bytes}b"
  fi
}

# ---- Build run list ----
declare -a RUNS=()
for ios in $IO_SIZES; do
  for qd in $QD_LIST; do
    label="$(io_label "$ios")"
    tag="${TAG_PREFIX}_qd${qd}_${label}"
    RUNS+=("${ios}:${qd}:${tag}")
  done
done

TOTAL=${#RUNS[@]}
echo "========================================================"
echo " Phase 1 Sweep Pipeline"
echo " IO sizes : $IO_SIZES"
echo " QD list  : $QD_LIST"
echo " Repeats  : $REPEATS"
echo " Steady   : ${STEADY_TIME}s"
echo " Runs     : $TOTAL"
echo "========================================================"
for i in "${!RUNS[@]}"; do
  IFS=: read -r ios qd tag <<< "${RUNS[$i]}"
  printf "  [%d/%d] IO=%s QD=%s tag=%s\n" "$((i+1))" "$TOTAL" "$ios" "$qd" "$tag"
done
echo "========================================================"
echo ""

PASS=0
FAIL=0
SKIP=0

for i in "${!RUNS[@]}"; do
  IFS=: read -r ios qd tag <<< "${RUNS[$i]}"
  RUN_NUM=$((i+1))

  echo ""
  echo "========================================================"
  echo " [$RUN_NUM/$TOTAL] IO_SIZE=$ios  QD=$qd  tag=$tag"
  echo " Started: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "========================================================"

  # ---- 1. Ensure clean state ----
  # Kill any leftover phase1_auto tmux session
  if tmux has-session -t phase1_auto 2>/dev/null; then
    echo "  Killing stale tmux session 'phase1_auto'..."
    tmux kill-session -t phase1_auto 2>/dev/null || true
    sleep 2
  fi

  # Stop gem5 if still running
  if "$SHARED_SCRIPTS_DIR/boot_gem5.sh" status 2>&1 | grep -q "running"; then
    echo "  Stopping leftover gem5..."
    "$SHARED_SCRIPTS_DIR/boot_gem5.sh" stop 2>&1 || true
    sleep 3
  fi

  # Clean stale PID file
  rm -f "$BASE_DIR/logs/gem5.pid"

  # ---- 2. Run the simulation ----
  echo "  Launching driver_phase1.sh ..."
  set +e
  bash "$SCRIPT_DIR/driver_phase1.sh" \
    --auto \
    --qd "$qd" \
    --ios "$ios" \
    --repeats "$REPEATS" \
    --steady-time "$STEADY_TIME" \
    --tag "$tag" \
    --auto-stop 1 \
    $EXTRA_ARGS \
    2>&1
  RC=$?
  set -e

  # ---- 3. Post-run cleanup ----
  # Give gem5 a moment to finish writing
  sleep 5

  # Stop gem5 if auto-stop didn't catch it
  if "$SHARED_SCRIPTS_DIR/boot_gem5.sh" status 2>&1 | grep -q "running"; then
    echo "  Post-run: stopping gem5..."
    "$SHARED_SCRIPTS_DIR/boot_gem5.sh" stop 2>&1 || true
    sleep 3
  fi

  # Kill phase1_auto session
  if tmux has-session -t phase1_auto 2>/dev/null; then
    tmux kill-session -t phase1_auto 2>/dev/null || true
  fi

  # ---- 4. Check results ----
  RESULT_CSV=""
  # Look for results in the tag directory
  for candidate in \
    "$BASE_DIR/results/${tag}/core0_qp1/phase1_results.csv" \
    "$BASE_DIR/results/phase1_runs/${tag}/core0_qp1/phase1_results.csv"; do
    if [ -f "$candidate" ] && [ -s "$candidate" ]; then
      RESULT_CSV="$candidate"
      break
    fi
  done

  if [ -n "$RESULT_CSV" ]; then
    LINES=$(wc -l < "$RESULT_CSV")
    if [ "$LINES" -gt 1 ]; then
      echo "  PASS — Results: $RESULT_CSV ($((LINES-1)) data rows)"
      PASS=$((PASS+1))
    else
      echo "  FAIL — Result file exists but has no data rows: $RESULT_CSV"
      FAIL=$((FAIL+1))
    fi
  else
    if [ $RC -ne 0 ]; then
      echo "  FAIL — driver exited with rc=$RC and no result CSV found"
      FAIL=$((FAIL+1))
    else
      echo "  WARN — driver exited rc=0 but no result CSV found for tag=$tag"
      FAIL=$((FAIL+1))
    fi
  fi

  echo "  Finished: $(date '+%Y-%m-%d %H:%M:%S')"
  echo ""
done

echo "========================================================"
echo " Sweep Complete"
echo " Total: $TOTAL  |  Pass: $PASS  |  Fail: $FAIL"
echo " Finished: $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================================"
