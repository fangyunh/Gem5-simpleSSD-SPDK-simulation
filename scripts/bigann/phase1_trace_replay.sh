#!/bin/bash
# ============================================================================
# phase1_trace_replay.sh -- in-guest runner for the BigANN/DiskANN trace replay
#
# Mirrors scripts/phase1_4k/phase1_run.sh's structure (sysfs PCI auto-detect,
# perf auto-disable, cycle_breakdown.csv aggregation, UNCORE_MODE plumbing,
# State_Dealloc split columns) but invokes spdk_nvme_perf with --trace-file
# instead of -w randread. The trace pulls IOs from the captured DiskANN /
# BigANN trace at artifacts/bigann/diskann_bigann_trace.bin.
#
# This is the in-guest companion to scripts/bigann/driver_phase1_trace.sh.
# Drive it via that driver; do not invoke directly from the host.
# ============================================================================

# --- CONFIGURATION (override via env) ---
PCI_ADDR=${PCI_ADDR:-"0000:00:05.0"}
QPAIRS=${QPAIRS:-1}
QPAIRS_LIST=(${QPAIRS_LIST:-$QPAIRS})

QUEUE_DEPTHS=(${QUEUE_DEPTHS_LIST:-${QUEUE_DEPTHS:-128}})
IO_SIZES=(${IO_SIZES_LIST:-${IO_SIZES:-4096}})
REPEATS=${REPEATS:-1}
STEADY_TIME=${STEADY_TIME:-1}

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=${ROOT_DIR:-"$(cd "$SCRIPT_DIR/../.." && pwd)"}
OUTPUT_ROOT=${OUTPUT_ROOT:-"$ROOT_DIR/results/phase1_runs"}
RUN_TAG=${RUN_TAG:-"trace_$(date +%Y%m%d_%H%M%S)"}
OUTPUT_BASE=${OUTPUT_BASE:-"$OUTPUT_ROOT/$RUN_TAG"}

SPDK_DIR=${SPDK_DIR:-"$ROOT_DIR/spdk"}
if [ -x "$ROOT_DIR/docker_artifacts/guest_spdk_nvme_perf" ]; then
    SPDK_PERF_BIN=${SPDK_PERF_BIN:-"$ROOT_DIR/docker_artifacts/guest_spdk_nvme_perf"}
else
    SPDK_PERF_BIN=${SPDK_PERF_BIN:-"$SPDK_DIR/build/bin/spdk_nvme_perf"}
fi

# Trace binary path (must exist before this script runs)
TRACE_FILE=${TRACE_FILE:-"$ROOT_DIR/artifacts/bigann/diskann_bigann_trace.bin"}

HUGEMEM_MB=${HUGEMEM_MB:-2048}
SKIP_SETUP=${SKIP_SETUP:-0}
NO_HUGE=${NO_HUGE:-0}

# IO-Uncore plumbing (mirror phase1_run.sh)
UNCORE_MODE=${UNCORE_MODE:-0}
if [ "${UNCORE_MODE}" = "2" ]; then
    export SPDK_UNCORE_MODE_B=1
    echo "PHASE1_TRACE_INFO: UNCORE_MODE=2 -> exporting SPDK_UNCORE_MODE_B=1"
else
    unset SPDK_UNCORE_MODE_B
fi

# Inside the gem5 guest the workload runs as root.
if [ "$EUID" -ne 0 ]; then
    echo "phase1_trace_replay.sh must run as root inside the gem5 guest." >&2
    exit 1
fi

PERF_ENABLE=${PERF_ENABLE:-1}
if [ "$PERF_ENABLE" -eq 1 ] && ! command -v perf >/dev/null 2>&1; then
    echo "perf not found (expected inside gem5 guest); disabling host-PMU collection."
    PERF_ENABLE=0
fi

for bin in python3; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "Missing dependency: $bin"
        exit 1
    fi
done

if [ ! -f "$TRACE_FILE" ]; then
    echo "TRACE_FILE not found: $TRACE_FILE"
    echo "Run scripts/bigann/trace_to_binary.py on the host first."
    exit 1
fi

# Auto-detect SimpleSSD NVMe via sysfs (Class 0x010802)
detect_nvme_sysfs() {
    local bdf_list=()
    for dev in /sys/bus/pci/devices/*; do
        [ -r "$dev/class" ] || continue
        if grep -q "0x010802" "$dev/class" 2>/dev/null; then
            bdf_list+=("${dev##*/}")
        fi
    done
    if [ "${#bdf_list[@]}" -eq 1 ]; then
        echo "${bdf_list[0]}"
        return 0
    fi
    return 1
}
if [ -z "$PCI_ADDR" ] || [ ! -d "/sys/bus/pci/devices/$PCI_ADDR" ]; then
    AUTO_BDF=$(detect_nvme_sysfs)
    if [ -n "$AUTO_BDF" ]; then
        echo "Auto-detected NVMe at $AUTO_BDF (overriding $PCI_ADDR)."
        PCI_ADDR="$AUTO_BDF"
    fi
fi

if [ ! -x "$SPDK_PERF_BIN" ]; then
    echo "spdk_nvme_perf binary not found or not executable at $SPDK_PERF_BIN"
    exit 1
fi

hugepages_total() {
    awk '/HugePages_Total/ {print $2}' /proc/meminfo 2>/dev/null
}

if [ "$SKIP_SETUP" -eq 0 ]; then
    if [ -x "$SPDK_DIR/scripts/setup.sh" ]; then
        # -----------------------------------------------------------------------
        # Driver selection: prefer vfio-pci with noiommu over uio_pci_generic.
        # Mirrors scripts/phase1_4k/phase1_run.sh lines 141-163. Without this
        # block, SPDK's setup.sh defaults to uio_pci_generic, which rejects the
        # gem5 SimpleSSD NVMe (no IOMMU, MSI-X teardown leaves pdev->irq==0).
        # DRIVER_OVERRIDE can be pre-set in the environment to override.
        # -----------------------------------------------------------------------
        if [ -z "${DRIVER_OVERRIDE:-}" ]; then
            if [ -e /sys/module/vfio/parameters/enable_unsafe_noiommu_mode ]; then
                echo 1 > /sys/module/vfio/parameters/enable_unsafe_noiommu_mode 2>/dev/null || true
                export DRIVER_OVERRIDE=vfio-pci
                echo "SPDK driver: vfio-pci (noiommu mode enabled)"
            elif [ -d /sys/bus/pci/drivers/uio_pci_generic ]; then
                echo "SPDK driver: uio_pci_generic (VFIO not available)"
            else
                echo "Warning: neither vfio-pci nor uio_pci_generic sysfs entry found."
            fi
        else
            echo "SPDK driver: $DRIVER_OVERRIDE (pre-set)"
        fi

        echo "Running SPDK setup with HUGEMEM=${HUGEMEM_MB}MB..."
        HUGEMEM="$HUGEMEM_MB" "$SPDK_DIR/scripts/setup.sh" || {
            echo "SPDK setup failed; trying NO_HUGE fallback."
            NO_HUGE=1
        }
    fi
fi

if [ "$PERF_ENABLE" -eq 1 ]; then
    PERF_EVENTS="cycles,instructions,LLC-load-misses"
else
    PERF_EVENTS=""
fi

mkdir -p "$OUTPUT_BASE"

# Trace replay schema: same as the multi-core variant minus the Core_Count
# column. Adds a Trace_Source column documenting which trace was replayed.
for QPAIRS in "${QPAIRS_LIST[@]}"; do
    RUN_DIR="$OUTPUT_BASE/core0_qp${QPAIRS}"
    OUTPUT_FILE="$RUN_DIR/phase1_results.csv"
    LOG_DIR="$RUN_DIR/logs"
    ERROR_LOG="$RUN_DIR/phase1_errors.log"

    mkdir -p "$RUN_DIR" "$LOG_DIR"
    > "$ERROR_LOG"

    echo "QD,Qpairs,IO_Size,Run_ID,IOPS,Cycles,Instructions,LLC_Misses,Cycles_Per_IO,Instr_Per_IO,LLC_Misses_Per_IO,p50_Latency,p99_Latency,p99.9_Latency,Polls,Completions,Scans_Per_Completion,Completions_Per_Call,MMIO_Writes_Per_IO,Completions_Per_Poll_Hist,Submit_Logic_ns,Completion_Logic_ns,Submit_Preamble_ns,Tracker_Alloc_ns,Addr_Xlate_ns,Cmd_Construct_ns,Fence_ns,Doorbell_ns,CQE_Detect_ns,Tracker_Lookup_ns,State_Dealloc_ns,State_Dealloc_Library_ns,State_Dealloc_Callback_ns,State_Dealloc_Total_ns,Trace_Source,Trace_Entries" > "$OUTPUT_FILE"

    echo "========================================================"
    echo "BigANN/DiskANN trace replay"
    echo "Target:    ${PCI_ADDR}"
    echo "Qpairs:    $QPAIRS"
    echo "Trace:     $TRACE_FILE  ($(stat -c %s "$TRACE_FILE") bytes / $(($(stat -c %s "$TRACE_FILE")/16)) entries)"
    echo "Output:    $OUTPUT_FILE"
    echo "Uncore:    Mode $UNCORE_MODE"
    echo "QD list:   ${QUEUE_DEPTHS[*]}"
    echo "IO sizes:  ${IO_SIZES[*]}"
    echo "Repeats:   $REPEATS"
    echo "========================================================"

    # Binary fingerprint: logged once so failures can be correlated with
    # the exact binary in use (md5sum + mtime + size).  If a build is stale
    # or the wrong path is picked up, this is the first line to check.
    echo "[fingerprint] spdk_nvme_perf = $SPDK_PERF_BIN"
    echo "[fingerprint] size           = $(stat -c %s "$SPDK_PERF_BIN" 2>/dev/null) bytes"
    echo "[fingerprint] mtime          = $(stat -c %y "$SPDK_PERF_BIN" 2>/dev/null)"
    echo "[fingerprint] md5            = $(md5sum "$SPDK_PERF_BIN" 2>/dev/null | awk '{print $1}')"
    echo "[fingerprint] SPDK_UNCORE_MODE_B = ${SPDK_UNCORE_MODE_B:-unset}"
    echo "========================================================"

    for IO_SIZE in "${IO_SIZES[@]}"; do
        for QD in "${QUEUE_DEPTHS[@]}"; do
            for RUN_ID in $(seq 1 $REPEATS); do
                echo -n "Replaying IO_SIZE=$IO_SIZE QD=$QD Run=$RUN_ID ... "

                RUN_LOG="$LOG_DIR/run_s${IO_SIZE}_q${QD}_r${RUN_ID}.log"
                SPDK_EAL_ARGS=()
                if [ "$NO_HUGE" -eq 1 ] || [ "$(hugepages_total)" -eq 0 ]; then
                    SPDK_EAL_ARGS+=(--no-huge)
                fi
                # -w randread is still required by perf.c's argument
                # validation, but the --trace-file path overrides the
                # workload generator -- the trace decides offset/op.
                SPDK_CMD_RUN=("$SPDK_PERF_BIN" -r "trtype:PCIe traddr:$PCI_ADDR" \
                    -w randread -o "$IO_SIZE" -q "$QD" -t "$STEADY_TIME" \
                    -c 0x1 -P "$QPAIRS" -L --transport-stats \
                    --trace-file "$TRACE_FILE" \
                    "${SPDK_EAL_ARGS[@]}")

                export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:"$SPDK_DIR/build/lib"

                CYCLE_OUT="$LOG_DIR/cycle_breakdown_s${IO_SIZE}_q${QD}_r${RUN_ID}.csv"
                if [ "$PERF_ENABLE" -eq 1 ]; then
                    CMD_OUTPUT=$(SPDK_IO_CYCLE_ENABLE=1 SPDK_IO_CYCLE_OUT="$CYCLE_OUT" \
                        perf stat --no-scale -C 0 -e "$PERF_EVENTS" -x ';' \
                        "${SPDK_CMD_RUN[@]}" 2>&1)
                else
                    CMD_OUTPUT=$(SPDK_IO_CYCLE_ENABLE=1 SPDK_IO_CYCLE_OUT="$CYCLE_OUT" \
                        "${SPDK_CMD_RUN[@]}" 2>&1)
                fi
                RC=$?
                echo "$CMD_OUTPUT" > "$RUN_LOG"

                if [ $RC -ne 0 ] || ! echo "$CMD_OUTPUT" | grep -q "^Total"; then
                    echo "Error IO_SIZE=$IO_SIZE QD=$QD Run=$RUN_ID (rc=$RC)" \
                        | tee -a "$ERROR_LOG"
                    echo "$RUN_LOG" >> "$ERROR_LOG"
                    # Forensics: dump the command, exit code, and the run log
                    # tail so we don't have to ssh in and cat individual files.
                    # Both go to stdout (captured by driver_phase1_trace_*.log)
                    # AND to the per-tag error log (for `grep -r Error results/`).
                    {
                        echo "=== forensics for QD=$QD IO=$IO_SIZE Run=$RUN_ID rc=$RC ==="
                        echo "--- command (raw) ---"
                        printf '%q ' "${SPDK_CMD_RUN[@]}"; echo
                        echo "--- run log: $RUN_LOG ($(wc -l < "$RUN_LOG" 2>/dev/null) lines) ---"
                        echo "--- last 25 lines of run log ---"
                        tail -25 "$RUN_LOG" 2>/dev/null
                        echo "--- error markers grep ---"
                        grep -E "ERROR|FAIL|panic|init_ns_worker_ctx|Cannot|Unable|Connect failed" "$RUN_LOG" 2>/dev/null | head -10
                        echo "--- cycle CSV exists? ---"
                        ls -la "$CYCLE_OUT" 2>/dev/null || echo "(missing)"
                        echo "--- dmesg tail (last 15) ---"
                        dmesg 2>/dev/null | tail -15 || echo "(dmesg unavailable)"
                        echo "=== end forensics QD=$QD ==="
                    } | tee -a "$ERROR_LOG"
                    continue
                fi
                # Success heartbeat — visible in driver log without waiting
                # for the entire QD sweep to finish.
                _IOPS_PEEK=$(echo "$CMD_OUTPUT" | grep "^Total" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]/) {print $i; exit}}')
                echo "OK (IOPS=${_IOPS_PEEK:-?})"

                IOPS=$(echo "$CMD_OUTPUT" | grep "^Total" | \
                    awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]/) {print $i; exit}}')
                CYCLES=$(echo "$CMD_OUTPUT" | grep -E 'cpu_core/cycles/|,cycles' | \
                    awk -F';' '{print $1}' | sed 's/<not supported>/0/g' | tr -d ', ' | tail -n1)
                INSTR=$(echo "$CMD_OUTPUT" | grep -E 'cpu_core/instructions/|,instructions' | \
                    awk -F';' '{print $1}' | sed 's/<not supported>/0/g' | tr -d ', ' | tail -n1)
                LLC=$(echo "$CMD_OUTPUT" | grep -E 'cpu_core/LLC-load-misses/|,LLC-load-misses' | \
                    awk -F';' '{print $1}' | sed 's/<not supported>/0/g' | tr -d ', ' | tail -n1)

                P50=$(echo "$CMD_OUTPUT" | grep "50.00000%" | awk '{print $3}' | sed 's/us//')
                P99=$(echo "$CMD_OUTPUT" | grep "99.00000%" | awk '{print $3}' | sed 's/us//')
                P999=$(echo "$CMD_OUTPUT" | grep "99.90000%" | awk '{print $3}' | sed 's/us//')

                PCIE_STATS_LINE=$(echo "$CMD_OUTPUT" | grep "pcie_stats:" | tail -n1)
                if [ -n "$PCIE_STATS_LINE" ]; then
                    POLLS=$(echo "$PCIE_STATS_LINE" | sed -n 's/.*polls=\([0-9]*\).*/\1/p')
                    COMPLETIONS=$(echo "$PCIE_STATS_LINE" | sed -n 's/.*completions=\([0-9]*\).*/\1/p')
                    SQ_MMIO=$(echo "$PCIE_STATS_LINE" | sed -n 's/.*sq_mmio=\([0-9]*\).*/\1/p')
                    CQ_MMIO=$(echo "$PCIE_STATS_LINE" | sed -n 's/.*cq_mmio=\([0-9]*\).*/\1/p')
                else
                    POLLS=0; COMPLETIONS=0; SQ_MMIO=0; CQ_MMIO=0
                fi

                COMPLETION_CALLS=$(echo "$CMD_OUTPUT" | grep -m1 "completion_calls:" | \
                    awk '{print $2}' | tr -d ',')
                COMPLETION_CALLS=${COMPLETION_CALLS:-$POLLS}

                CPPHIST=$(echo "$CMD_OUTPUT" | grep "completions_per_poll_hist:" | \
                    sed 's/^[^:]*://;s/^ *//;s/ *$//')
                CPPHIST="\"$CPPHIST\""

                SCANS_PER=$(awk -v calls="${COMPLETION_CALLS}" -v comps="${COMPLETIONS}" \
                    'BEGIN{print (comps>0)?calls/comps:0}')
                COMPLETIONS_PER=$(awk -v calls="${COMPLETION_CALLS}" -v comps="${COMPLETIONS}" \
                    'BEGIN{print (calls>0)?comps/calls:0}')

                TOTAL_IOS=$(awk -v iops="${IOPS}" -v t="${STEADY_TIME}" 'BEGIN{print iops*t}')
                CYC_PER_IO=$(awk -v a="${CYCLES}" -v t="${TOTAL_IOS}" \
                    'BEGIN{print (t>0)?a/t:0}')
                INSTR_PER_IO=$(awk -v a="${INSTR}" -v t="${TOTAL_IOS}" \
                    'BEGIN{print (t>0)?a/t:0}')
                LLC_PER_IO=$(awk -v a="${LLC}" -v t="${TOTAL_IOS}" \
                    'BEGIN{print (t>0)?a/t:0}')
                MMIO_PER=$(awk -v a="${SQ_MMIO}" -v b="${CQ_MMIO}" -v t="${TOTAL_IOS}" \
                    'BEGIN{print (t>0)?(a+b)/t:0}')

                if [ -f "$CYCLE_OUT" ]; then
                    read SUBMIT_NS COMPLETE_NS PREAMBLE_NS TR_ALLOC_NS XLATE_NS \
                         CMD_NS FENCE_NS DB_NS CQE_NS TR_LOOKUP_NS \
                         FREE_NS FREE_LIB_NS FREE_CB_NS FREE_TOTAL_NS <<EOF
$(python3 - <<PY
import csv

path = "$CYCLE_OUT"
cols = [
    "submit_ns", "completion_ns",
    "submit_preamble_ns", "tracker_alloc_ns", "addr_xlate_ns",
    "cmd_construct_ns", "fence_ns", "doorbell_ns",
    "cqe_detect_ns", "tracker_lookup_ns", "state_dealloc_ns",
    "state_dealloc_library_ns", "state_dealloc_callback_ns", "state_dealloc_total_ns",
]
sums = {c: 0.0 for c in cols}
count = 0
with open(path, "r", encoding="utf-8") as f:
    reader = csv.DictReader(f)
    for row in reader:
        try:
            for c in cols:
                sums[c] += float(row.get(c, 0) or 0)
            count += 1
        except ValueError:
            continue
if count == 0:
    print("0 0 0 0 0 0 0 0 0 0 0 0 0 0")
else:
    print(
        f"{sums['submit_ns']/count} {sums['completion_ns']/count} "
        f"{sums['submit_preamble_ns']/count} {sums['tracker_alloc_ns']/count} {sums['addr_xlate_ns']/count} "
        f"{sums['cmd_construct_ns']/count} {sums['fence_ns']/count} {sums['doorbell_ns']/count} "
        f"{sums['cqe_detect_ns']/count} {sums['tracker_lookup_ns']/count} {sums['state_dealloc_ns']/count} "
        f"{sums['state_dealloc_library_ns']/count} {sums['state_dealloc_callback_ns']/count} {sums['state_dealloc_total_ns']/count}"
    )
PY
)
EOF
                else
                    SUBMIT_NS=0; COMPLETE_NS=0; PREAMBLE_NS=0; TR_ALLOC_NS=0
                    XLATE_NS=0; CMD_NS=0; FENCE_NS=0; DB_NS=0; CQE_NS=0
                    TR_LOOKUP_NS=0; FREE_NS=0
                    FREE_LIB_NS=0; FREE_CB_NS=0; FREE_TOTAL_NS=0
                fi

                TRACE_BASENAME=$(basename "$TRACE_FILE")
                TRACE_ENTRIES=$(($(stat -c %s "$TRACE_FILE") / 16))

                echo "Done. ($IOPS IOPS)"
                CSV_LINE="$QD,$QPAIRS,$IO_SIZE,$RUN_ID,$IOPS,$CYCLES,$INSTR,$LLC,$CYC_PER_IO,$INSTR_PER_IO,$LLC_PER_IO,$P50,$P99,$P999,$POLLS,$COMPLETIONS,$SCANS_PER,$COMPLETIONS_PER,$MMIO_PER,$CPPHIST,$SUBMIT_NS,$COMPLETE_NS,$PREAMBLE_NS,$TR_ALLOC_NS,$XLATE_NS,$CMD_NS,$FENCE_NS,$DB_NS,$CQE_NS,$TR_LOOKUP_NS,$FREE_NS,$FREE_LIB_NS,$FREE_CB_NS,$FREE_TOTAL_NS,$TRACE_BASENAME,$TRACE_ENTRIES"
                echo "$CSV_LINE" >> "$OUTPUT_FILE"
            done
        done
    done
done

echo "========================================================"
echo "Trace replay complete. Results saved under: $OUTPUT_BASE"
echo "========================================================"
echo "PHASE1_RUNSCRIPT_DONE"
