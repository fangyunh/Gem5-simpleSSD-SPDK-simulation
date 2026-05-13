#!/usr/bin/env bash
# =============================================================================
# smoke_9p_check.sh -- pre-flight: confirm virtio-9p actually exposes guest
# writes to the host *before* committing to a multi-hour paper sweep.
#
# Why this exists. Past runs hit two distinct problems that can both look like
# "9p is broken":
#   1. A pre-2026-05-09 path-split bug where the driver wrote metadata.json to
#      results/phase1_runs/<tag>/ but the in-guest runner wrote CSVs to
#      results/<tag>/. The CSVs WERE on the host, just not where you looked.
#   2. The known gem5-hang-at-exit quirk (PAPER_IMPL_TODO.md §0.6) makes the
#      tmux session look stuck *after* CSVs have already been written. People
#      then run extract_phase1_results.sh out of habit even though data is
#      already on the host.
#
# This script launches the smallest possible driver run and watches two
# pass markers in parallel:
#   (a) "/mnt/9p mounted" appears in the host-side driver log
#   (b) phase1_results.csv appears on the HOST filesystem with at least the
#       header line (i.e. the in-guest runner reached the file write and the
#       9p server propagated it back to the host)
#
# As soon as both are green, the script stops gem5, kills the tmux session,
# and exits 0. If either marker doesn't appear within the timeout, it exits
# non-zero and dumps a diagnostic so you know whether to fix 9p or fall back
# to the bake+extract workflow.
#
# Wall-time expectation:
#   * quiescent server: ~60 min gem5 boot + a few minutes for first CSV write
#   * with BigANN contention: 90-120 min total (set timeouts accordingly)
#
# Override via env:
#   SMOKE_MOUNT_TIMEOUT  seconds to wait for /mnt/9p mount marker (default 5400)
#   SMOKE_WRITE_TIMEOUT  seconds to wait for host CSV after mount (default 600)
#   SMOKE_KEEP_RUNNING   if 1, do NOT stop gem5 on pass; let the smoke run
#                        complete and produce a data point (default 0)
# =============================================================================

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)
SHARED_SCRIPTS_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

TAG="smoke_9p_check_$(date +%Y%m%d_%H%M%S)"
DRIVER_LOG="$ROOT_DIR/logs/driver_phase1_${TAG}.log"
EXPECTED_CSV="$ROOT_DIR/results/phase1_runs/${TAG}/core0_qp1/phase1_results.csv"
GEM5_OUT="$ROOT_DIR/logs/gem5.out"

MOUNT_WAIT_S=${SMOKE_MOUNT_TIMEOUT:-5400}   # 90 min default
WRITE_WAIT_S=${SMOKE_WRITE_TIMEOUT:-600}    # 10 min default
KEEP_RUNNING=${SMOKE_KEEP_RUNNING:-0}

cleanup() {
    if [ "$KEEP_RUNNING" -eq 1 ] && [ "${SMOKE_PASSED:-0}" -eq 1 ]; then
        echo "[smoke] SMOKE_KEEP_RUNNING=1; leaving gem5 + tmux session alive."
        echo "[smoke] When ready: ./scripts/boot_gem5.sh stop && tmux kill-session -t phase1_auto"
        return
    fi
    echo "[smoke] cleaning up..."
    "$SHARED_SCRIPTS_DIR/boot_gem5.sh" stop >/dev/null 2>&1 || true
    if command -v tmux >/dev/null 2>&1; then
        tmux kill-session -t phase1_auto 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Quick pre-flight: nothing should be using the same tmux session
if tmux has-session -t phase1_auto 2>/dev/null; then
    echo "[smoke] FAIL: tmux session 'phase1_auto' already exists. Stop it first:"
    echo "         tmux kill-session -t phase1_auto"
    exit 2
fi

# Confirm the SPDK binary has the State_Dealloc split (regression check)
if ! strings "$ROOT_DIR/docker_artifacts/guest_spdk_nvme_perf" | \
        grep -q state_dealloc_library_ns 2>/dev/null; then
    echo "[smoke] WARN: guest_spdk_nvme_perf is older than the State_Dealloc split."
    echo "         Re-run scripts/build_spdk_docker.sh to refresh, then retry."
    echo "         Continuing anyway -- 9p test is independent of the SPDK build."
fi

echo "==================== smoke_9p_check ===================="
echo "  Tag         : $TAG"
echo "  Expected CSV: $EXPECTED_CSV"
echo "  Driver log  : $DRIVER_LOG"
echo "  Mount wait  : ${MOUNT_WAIT_S}s"
echo "  Write wait  : ${WRITE_WAIT_S}s after mount"
echo "  Keep running on pass: $KEEP_RUNNING"
echo "========================================================="

# Launch the smallest sensible run: 1 QD point, 1 second steady-state, Mode 0.
# This reaches phase1_run.sh quickly once gem5 boots; if 9p works, the CSV
# header will appear on the host within seconds of phase1_run.sh starting.
echo "[smoke] launching minimal driver invocation..."
SSD_CFG=fast_ssd_highiops.cfg \
    "$SCRIPT_DIR/driver_phase1.sh" --auto \
    --qd "16" --ios "4096" --qpairs "1" \
    --repeats 1 --steady-time 1 --uncore-mode 0 \
    --tag "$TAG" --auto-stop 1 --no-tail \
    >/dev/null 2>&1 &
DRIVER_PID=$!
echo "[smoke] driver running in background; pid=$DRIVER_PID"

START=$(date +%s)
MOUNT_OK=0
WRITE_OK=0
LAST_HEARTBEAT=0

while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START))

    # Pass criterion (a): /mnt/9p mount marker
    if [ "$MOUNT_OK" -eq 0 ] && [ -f "$DRIVER_LOG" ] && \
       grep -q "/mnt/9p mounted" "$DRIVER_LOG" 2>/dev/null; then
        MOUNT_OK=1
        MOUNT_LINE=$(grep "/mnt/9p mounted" "$DRIVER_LOG" | head -1)
        echo "[smoke] [+${ELAPSED}s] PASS (a): 9p mount succeeded"
        echo "          line: $MOUNT_LINE"
    fi

    # Pass criterion (b): host-visible CSV with at least the header line
    if [ "$MOUNT_OK" -eq 1 ] && [ "$WRITE_OK" -eq 0 ] && [ -s "$EXPECTED_CSV" ]; then
        WRITE_OK=1
        LINES=$(wc -l < "$EXPECTED_CSV")
        echo "[smoke] [+${ELAPSED}s] PASS (b): host-visible CSV at $EXPECTED_CSV"
        echo "          lines: $LINES"
        echo "          header (first 100 chars): $(head -1 "$EXPECTED_CSV" | head -c 100)..."
        break
    fi

    # Heartbeat every 60s so the operator sees progress
    if [ $((ELAPSED - LAST_HEARTBEAT)) -ge 60 ]; then
        LAST_HEARTBEAT=$ELAPSED
        STATE="booting / awaiting 9p mount"
        if [ "$MOUNT_OK" -eq 1 ]; then
            STATE="9p mount confirmed; awaiting CSV write on host"
        fi
        printf "[smoke] [+%ds] still waiting (%s)\n" "$ELAPSED" "$STATE"
        if [ -f "$DRIVER_LOG" ]; then
            LATEST=$(tail -1 "$DRIVER_LOG" 2>/dev/null | cut -c1-100)
            [ -n "$LATEST" ] && echo "          driver-log tail: $LATEST"
        fi
    fi

    # Failure criterion: mount marker never appeared
    if [ "$MOUNT_OK" -eq 0 ] && [ "$ELAPSED" -ge "$MOUNT_WAIT_S" ]; then
        echo ""
        echo "==================== SMOKE TEST FAILED ===================="
        echo "  Reason     : no '/mnt/9p mounted' marker after ${MOUNT_WAIT_S}s."
        echo "  Likely cause:"
        echo "    - gem5 still booting (try larger SMOKE_MOUNT_TIMEOUT)"
        echo "    - diod failed to start on host (check 'pgrep -af diod')"
        echo "    - 9p kernel module missing in guest (rebuild kernel?)"
        echo "  Last 15 lines of driver log:"
        tail -15 "$DRIVER_LOG" 2>/dev/null | sed 's/^/    /'
        echo "==========================================================="
        exit 1
    fi

    # Failure criterion: mount worked but writes never propagated
    if [ "$MOUNT_OK" -eq 1 ] && [ "$WRITE_OK" -eq 0 ] && \
       [ "$ELAPSED" -ge $((MOUNT_WAIT_S + WRITE_WAIT_S)) ]; then
        echo ""
        echo "==================== SMOKE TEST FAILED ===================="
        echo "  Reason     : 9p mounted but no host-visible CSV after ${WRITE_WAIT_S}s post-mount."
        echo "  Likely cause:"
        echo "    - in-guest runner wrote to a non-9p path (path-split bug regressed?)"
        echo "    - readfile env-var substitution did not produce OUTPUT_ROOT=/mnt/9p/results/phase1_runs"
        echo "    - guest filesystem cache holding writes (unlikely with O_SYNC, but check)"
        echo "  Diagnostic commands to run:"
        echo "    grep OUTPUT_ROOT logs/phase1_readfile_${TAG}.sh"
        echo "    ls /home/fangy6/SimpleSSD_Gem5_simulation/results/phase1_runs/$TAG/"
        echo "    ls /home/fangy6/SimpleSSD_Gem5_simulation/results/  # in case path-split regressed"
        echo "  Last 15 lines of driver log:"
        tail -15 "$DRIVER_LOG" 2>/dev/null | sed 's/^/    /'
        echo "==========================================================="
        exit 1
    fi

    sleep 5
done

# Both pass markers green
SMOKE_PASSED=1

echo ""
echo "==================== SMOKE TEST PASSED ===================="
echo "  9p mount        : OK"
echo "  Host CSV exists : $EXPECTED_CSV"
echo "  Wall time       : ${ELAPSED}s"
echo ""
echo "Verdict: virtio-9p is propagating in-guest writes to the host."
echo "The full paper sweep does NOT need extract_phase1_results.sh."
echo ""
if [ "$KEEP_RUNNING" -eq 1 ]; then
    echo "SMOKE_KEEP_RUNNING=1 -> leaving gem5 alive to finish the smoke run."
    echo "It will produce one data row at $EXPECTED_CSV in ~25 min."
    echo "Stop manually when done:"
    echo "  ./scripts/boot_gem5.sh stop"
    echo "  tmux kill-session -t phase1_auto"
else
    echo "Stopping the smoke run now to free the system for the real sweep."
    echo "(Set SMOKE_KEEP_RUNNING=1 if you want a data row from this smoke.)"
fi
echo ""
echo "Next step: launch the real paper sweep, e.g."
echo "  for MODE in 0 1 2; do"
echo "    SSD_CFG=fast_ssd_highiops.cfg \\"
echo "      ./scripts/phase1_4k/driver_phase1.sh --auto \\"
echo "      --qd \"16 32 64 128\" --ios \"4096\" --qpairs \"1\" \\"
echo "      --repeats 1 --steady-time 5 --uncore-mode \${MODE} \\"
echo "      --tag paper_qdsweep_mode\${MODE}"
echo "  done"
echo "==========================================================="

exit 0
