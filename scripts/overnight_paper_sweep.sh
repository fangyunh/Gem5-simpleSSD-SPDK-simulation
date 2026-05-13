#!/usr/bin/env bash
# Sequential overnight runner: 3 synthetic modes + 3 BigANN-trace modes.
# Cannot parallelise (shared SSD cfg, tmux session, pid file, m5out, port 3456).
#
# Usage:
#   nohup ./scripts/overnight_paper_sweep.sh > logs/overnight_$(date +%Y%m%d).log 2>&1 &
#   disown
#
# Or just run in tmux:
#   tmux new -s overnight './scripts/overnight_paper_sweep.sh'

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$ROOT_DIR"

# IMPORTANT: driver_phase1.sh reads SSD_CONFIG (env) or --ssd-config (flag).
# Earlier versions of this script exported SSD_CFG, which the driver IGNORES,
# silently falling back to fast_ssd.cfg (the baseline 400 MHz cfg). That bug
# caused the 2026-05-09 overnight run to use stale settings.
# We now both export SSD_CONFIG with an absolute path AND pass --ssd-config
# explicitly on every driver invocation, so the cfg is unambiguous.
export SSD_CONFIG="$ROOT_DIR/fast_ssd_highiops.cfg"
SSD_CONFIG_FLAG=(--ssd-config "$SSD_CONFIG")
DATE=$(date +%Y%m%d)

# Fail-fast sanity: cfg must exist and contain every high-IOPS knob.
# Each grep below is a checkpoint; missing any of them means someone
# accidentally reverted the cfg, and we refuse to run rather than
# silently use bad settings.
if [ ! -f "$SSD_CONFIG" ]; then
  echo "FATAL: $SSD_CONFIG missing" >&2
  exit 2
fi
# NOTE: '|' is used as the pattern/description delimiter (NOT ':') because
# the regex patterns contain ':' inside [[:space:]]. Earlier ':' delimiter
# caused "${chk%%:*}" to truncate at the first colon inside the pattern.
for chk in \
    '^FastPathEnabled[[:space:]]*=[[:space:]]*1|NVMeVirt-style fast path enabled (Path E)' \
    '^FastPathLmin[[:space:]]*=[[:space:]]*1000000|FastPathLmin=1 us' \
    '^FastPathTmaxPerChannel[[:space:]]*=[[:space:]]*1000000|FastPathTmaxPerChannel=1 M IOPS' \
    '^FastPathChannelPolicy[[:space:]]*=[[:space:]]*1|FastPathChannelPolicy=LBA-hash' \
    '^ClockSpeed = 32000000000|32 GHz controller-CPU' \
    '^HILCoreCount = 1|HILCoreCount=1' \
    '^ICLCoreCount = 4|ICLCoreCount=4' \
    '^FTLCoreCount = 4|FTLCoreCount=4' \
    '^PCIEGeneration = 4|PCIe Gen5' \
    '^PCIELane = 16|PCIe x16' \
    '^AXIBusWidth = 5|AXI 1024-bit' \
    '^AXIClock = 500000000|AXI 500 MHz' \
    '^WorkInterval = 50000|WorkInterval=50 ns' \
    '^MaxRequestCount = 128|MaxRequestCount=128' \
    '^EnableReadCache = 0|ICL read cache disabled (random read workload)' \
    '^EnableReadPrefetch = 0|ICL prefetch disabled' \
    '^Channel = 32|32 NAND channels' \
    '^LSBRead = 1000000|1 us NAND read'
do
  pat="${chk%%|*}"
  desc="${chk#*|}"
  if ! grep -q "$pat" "$SSD_CONFIG"; then
    echo "FATAL: $SSD_CONFIG does not have $desc; refusing to run." >&2
    exit 2
  fi
done
echo "[$(date '+%F %T')] cfg verified ($SSD_CONFIG): all 10 high-IOPS knobs present"

run() {
  local label="$1"; shift
  echo "================================================================"
  echo "[$(date '+%F %T')] >>> START  $label"
  echo "================================================================"
  "$@"
  local rc=$?
  echo "[$(date '+%F %T')] <<< FINISH $label (rc=$rc)"
  echo
  # Defensive: make sure no stale gem5/tmux survives between runs.
  ./scripts/boot_gem5.sh stop >/dev/null 2>&1 || true
  tmux kill-session -t phase1_auto >/dev/null 2>&1 || true
  sleep 5
}

# ----- 3 synthetic 4 KB random read sweeps (paper §4.2) -----
for MODE in 0 1 2; do
  run "synthetic_mode${MODE}" \
    ./scripts/phase1_4k/driver_phase1.sh --auto \
      --qd "16 32 64 128" --ios "4096" --qpairs "1" \
      --repeats 1 --steady-time 1 --uncore-mode "$MODE" \
      --tag "paper_qdsweep_mode${MODE}_${DATE}" \
      "${SSD_CONFIG_FLAG[@]}"
done

# ----- 3 BigANN trace replays (paper §4.1) -----
for MODE in 0 1 2; do
  run "trace_mode${MODE}" \
    ./scripts/bigann/driver_phase1_trace.sh --auto \
      --qd 128 --steady-time 1 --uncore-mode "$MODE" \
      --tag "paper_trace_mode${MODE}_${DATE}" \
      "${SSD_CONFIG_FLAG[@]}"
done

echo "================================================================"
echo "[$(date '+%F %T')] All 6 sweeps done."
echo "================================================================"
ls -la results/phase1_runs/paper_*_${DATE}/core0_qp1/phase1_results.csv 2>/dev/null
