#!/usr/bin/env bash
# ============================================================================
# run_workload_sweep.sh -- sequential BigANN write-only + rw50 sweep.
#
# Runs 4 gem5 trace-replay runs STRICTLY SEQUENTIALLY (the driver patches
# fast_ssd_highiops.cfg in place, so runs must not overlap). After each run,
# relocate results/phase1_runs/<tag> into its per-workload folder.
#
# Intended to run inside a dedicated outer tmux session:
#   tmux new-session -d -s iau_workload_sweep \
#       'scripts/bigann/run_workload_sweep.sh 2>&1 | tee -a logs/workload_sweep.log'
# ============================================================================
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"
export SSD_CFG=fast_ssd_highiops.cfg
DRIVER="scripts/bigann/driver_phase1_trace.sh"
DATE_TAG="${DATE_TAG:-20260624}"
QD="16 32 64 128"
STEADY=1

# Columns: workload  trace_bin  mode  dest_dir
RUNS=(
  "write artifacts/bigann/diskann_bigann_trace_write.bin 0 results/bigann_write_1c1qp"
  "write artifacts/bigann/diskann_bigann_trace_write.bin 2 results/bigann_write_1c1qp"
  "rw50  artifacts/bigann/diskann_bigann_trace_rw50.bin  0 results/bigann_rw50_1c1qp"
  "rw50  artifacts/bigann/diskann_bigann_trace_rw50.bin  2 results/bigann_rw50_1c1qp"
)

echo "=== workload sweep start $(date -u +%FT%TZ) ==="
for spec in "${RUNS[@]}"; do
  read -r WL BIN MODE DEST <<<"$spec"
  TAG="bigann_${WL}_mode${MODE}_${DATE_TAG}"
  SESSION="iau_run_${WL}_m${MODE}"
  echo "--- [$(date -u +%FT%TZ)] RUN $TAG (trace=$BIN mode=$MODE) ---"

  if [ ! -f "$BIN" ]; then echo "FATAL: missing trace $BIN"; exit 1; fi
  # Clean any stale inner session / prior output for an idempotent restart.
  env -u LD_LIBRARY_PATH tmux kill-session -t "$SESSION" 2>/dev/null || true
  rm -rf "results/phase1_runs/$TAG"

  # Absolute trace path so the driver's host->guest re-rooting maps it to
  # /mnt/9p/... (a relative path would leave the guest path unrooted).
  "$DRIVER" --auto --trace "$ROOT_DIR/$BIN" --uncore-mode "$MODE" \
      --qd "$QD" --steady-time "$STEADY" \
      --tag "$TAG" --session-name "$SESSION"
  RC=$?
  echo "--- driver exit rc=$RC for $TAG ---"

  SRC="results/phase1_runs/$TAG"
  CSV="$SRC/core0_qp1/phase1_results.csv"
  if [ ! -f "$CSV" ]; then
    echo "ERROR: no results CSV for $TAG ($CSV). Aborting sweep."; exit 2
  fi
  ROWS=$(($(wc -l < "$CSV") - 1))
  ERRS=$(grep -c . "$SRC/core0_qp1/phase1_errors.log" 2>/dev/null || echo 0)
  echo "RESULT $TAG: data_rows=$ROWS error_lines=$ERRS"
  mkdir -p "$DEST"
  rm -rf "$DEST/$TAG"
  mv "$SRC" "$DEST/$TAG"
  echo "RELOCATED -> $DEST/$TAG"
done
echo "=== workload sweep complete $(date -u +%FT%TZ) ==="
echo "WORKLOAD_SWEEP_DONE"
