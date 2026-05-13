#!/bin/bash

# ==============================================================================
# SPDK Phase 1 Multi-core Automation Script -- gem5-compatible
# ==============================================================================
#
# Replaces scripts/phase1_run_multicore.sh, which targets real hardware and
# fails inside the gem5+SimpleSSD guest (host-PMU reads, 5.3 GHz core filter,
# wrong PCI address, no UncoreMode plumbing). See docs/PAPER_IMPL_TODO.md §4
# for the rationale.
#
# This variant:
#   * Runs INSIDE the gem5 guest (mounted /mnt/9p workspace).
#   * Auto-detects the SimpleSSD NVMe PCI address via sysfs (defaults to
#     0000:00:05.0 if a single NVMe class device is present).
#   * Auto-disables `perf` when not available (gem5 has no hardware PMU);
#     all per-IO accounting comes from SPDK's nvme_io_cycle instrumentation
#     (cycle_breakdown.csv) the same way the single-core path does.
#   * Iterates over CORE_COUNTS, building a spanning core mask per iteration
#     so a single spdk_nvme_perf invocation spreads across N cores
#     cooperatively (this is the regime the §4.2 per-core invariance claim
#     tests).
#   * Plumbs UNCORE_MODE through to fast_ssd_highiops.cfg AND exports
#     SPDK_UNCORE_MODE_B=1 when UNCORE_MODE=2.
#   * Emits the State_Dealloc split columns introduced 2026-05-09
#     (PAPER_IMPL_TODO §5).
#
# Output schema:
#   results/phase1_runs/<tag>/core_count<N>_qp<Q>/phase1_results.csv
# Each row is one (Core_Count, QD, IO_Size, Run_ID) combination.

# --- CONFIGURATION (override via env) ---
PCI_ADDR=${PCI_ADDR:-"0000:00:05.0"}
QPAIRS=${QPAIRS:-1}
QPAIRS_LIST=(${QPAIRS_LIST:-$QPAIRS})

# Cores as space-separated list of core counts. e.g. "1 2 4" runs three
# regimes: 1-core, 2-core, 4-core. The mask for N cores is (1<<N)-1, so
# the workload always pins to cores [0..N-1] of the gem5 guest.
# CORE_COUNTS_LIST follows the _LIST naming used by phase1_run.sh so the
# driver can export consistently across both runners.
CORE_COUNTS=(${CORE_COUNTS_LIST:-${CORE_COUNTS:-"1 2"}})

QUEUE_DEPTHS=(${QUEUE_DEPTHS_LIST:-${QUEUE_DEPTHS:-128}})
IO_SIZES=(${IO_SIZES_LIST:-${IO_SIZES:-4096}})
REPEATS=${REPEATS:-1}
STEADY_TIME=${STEADY_TIME:-5}

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=${ROOT_DIR:-"$(cd "$SCRIPT_DIR/../.." && pwd)"}
OUTPUT_ROOT=${OUTPUT_ROOT:-"$ROOT_DIR/results/phase1_runs"}
RUN_TAG=${RUN_TAG:-"multicore_$(date +%Y%m%d_%H%M%S)"}
OUTPUT_BASE=${OUTPUT_BASE:-"$OUTPUT_ROOT/$RUN_TAG"}

SPDK_DIR=${SPDK_DIR:-"$ROOT_DIR/spdk"}
if [ -x "$ROOT_DIR/docker_artifacts/guest_spdk_nvme_perf" ]; then
    SPDK_PERF_BIN=${SPDK_PERF_BIN:-"$ROOT_DIR/docker_artifacts/guest_spdk_nvme_perf"}
else
    SPDK_PERF_BIN=${SPDK_PERF_BIN:-"$SPDK_DIR/build/bin/spdk_nvme_perf"}
fi
HUGEMEM_MB=${HUGEMEM_MB:-2048}
SKIP_SETUP=${SKIP_SETUP:-0}
NO_HUGE=${NO_HUGE:-0}

# IO-Uncore Mode plumbing (mirror phase1_run.sh)
UNCORE_MODE=${UNCORE_MODE:-0}
if [ "${UNCORE_MODE}" = "2" ]; then
    export SPDK_UNCORE_MODE_B=1
    echo "PHASE1_MC_INFO: UNCORE_MODE=2 -> exporting SPDK_UNCORE_MODE_B=1"
else
    unset SPDK_UNCORE_MODE_B
fi

# Inside the gem5 guest the workload runs as root (the guest is rooted by
# default). On the host -- where this script must NEVER be invoked
# directly -- root is not available and spdk_nvme_perf cannot bind to the
# kernel-managed NVMe. The check below guards against accidental host
# invocation.
if [ "$EUID" -ne 0 ]; then
    echo "phase1_run_multicore_gem5.sh must run as root inside the gem5 guest."
    echo "If you are seeing this on the host, you launched the wrong script."
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

# Auto-detect SimpleSSD NVMe via sysfs (Class 0x010802 = NVMe controller)
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

# Hugepage setup (idempotent)
hugepages_total() {
    awk '/HugePages_Total/ {print $2}' /proc/meminfo 2>/dev/null
}

if [ "$SKIP_SETUP" -eq 0 ]; then
    if [ -x "$SPDK_DIR/scripts/setup.sh" ]; then
        echo "Running SPDK setup with HUGEMEM=${HUGEMEM_MB}MB..."
        HUGEMEM="$HUGEMEM_MB" "$SPDK_DIR/scripts/setup.sh" || {
            echo "SPDK setup failed; trying NO_HUGE fallback."
            NO_HUGE=1
        }
    else
        echo "SPDK setup script not found at $SPDK_DIR/scripts/setup.sh -- continuing without it."
    fi
fi

# Build perf event list (Cycles + Instructions + LLC) -- gem5 will return 0
# / <not supported> for these but we keep the column for schema parity with
# the single-core CSV.
if [ "$PERF_ENABLE" -eq 1 ]; then
    PERF_EVENTS="cycles,instructions,LLC-load-misses"
else
    PERF_EVENTS=""
fi

mkdir -p "$OUTPUT_BASE"

for CORE_COUNT in "${CORE_COUNTS[@]}"; do
    # Build spanning mask: (1 << count) - 1 → cores [0..count-1]
    if ! [[ "$CORE_COUNT" =~ ^[0-9]+$ ]] || [ "$CORE_COUNT" -lt 1 ]; then
        echo "Skipping invalid CORE_COUNT='$CORE_COUNT'"
        continue
    fi
    mask=$(( (1 << CORE_COUNT) - 1 ))
    CORE_MASK=$(printf "0x%x" "$mask")
    # CSV-form list of cores for `perf -C`
    CORE_CSV=$(seq -s, 0 $((CORE_COUNT - 1)))

    for QPAIRS in "${QPAIRS_LIST[@]}"; do
        RUN_DIR="$OUTPUT_BASE/core_count${CORE_COUNT}_qp${QPAIRS}"
        OUTPUT_FILE="$RUN_DIR/phase1_results.csv"
        LOG_DIR="$RUN_DIR/logs"
        ERROR_LOG="$RUN_DIR/phase1_errors.log"

        mkdir -p "$RUN_DIR" "$LOG_DIR"
        > "$ERROR_LOG"

        echo "QD,Qpairs,IO_Size,Run_ID,Core_Count,Core_Mask,IOPS,Cycles,Instructions,LLC_Misses,Cycles_Per_IO,Instr_Per_IO,LLC_Misses_Per_IO,p50_Latency,p99_Latency,p99.9_Latency,Polls,Completions,Scans_Per_Completion,Completions_Per_Call,MMIO_Writes_Per_IO,Completions_Per_Poll_Hist,Submit_Logic_ns,Completion_Logic_ns,Submit_Preamble_ns,Tracker_Alloc_ns,Addr_Xlate_ns,Cmd_Construct_ns,Fence_ns,Doorbell_ns,CQE_Detect_ns,Tracker_Lookup_ns,State_Dealloc_ns,State_Dealloc_Library_ns,State_Dealloc_Callback_ns,State_Dealloc_Total_ns" > "$OUTPUT_FILE"

        echo "========================================================"
        echo "Multi-core Phase 1 evaluation"
        echo "Target:    ${PCI_ADDR}"
        echo "Cores:     $CORE_COUNT  (mask $CORE_MASK, csv $CORE_CSV)"
        echo "Qpairs:    $QPAIRS  (per-thread; total = Cores * Qpairs)"
        echo "Output:    $OUTPUT_FILE"
        echo "Uncore:    Mode $UNCORE_MODE"
        echo "========================================================"

        for IO_SIZE in "${IO_SIZES[@]}"; do
            for QD in "${QUEUE_DEPTHS[@]}"; do
                for RUN_ID in $(seq 1 $REPEATS); do
                    echo -n "Running CORES=$CORE_COUNT IO_SIZE=$IO_SIZE QD=$QD Run=$RUN_ID ... "

                    RUN_LOG="$LOG_DIR/run_s${IO_SIZE}_q${QD}_c${CORE_COUNT}_r${RUN_ID}.log"
                    SPDK_EAL_ARGS=()
                    if [ "$NO_HUGE" -eq 1 ] || [ "$(hugepages_total)" -eq 0 ]; then
                        SPDK_EAL_ARGS+=(--no-huge)
                    fi
                    SPDK_CMD_RUN=("$SPDK_PERF_BIN" -r "trtype:PCIe traddr:$PCI_ADDR" \
                        -w randread -o "$IO_SIZE" -q "$QD" -t "$STEADY_TIME" \
                        -c "$CORE_MASK" -P "$QPAIRS" -L --transport-stats \
                        "${SPDK_EAL_ARGS[@]}")

                    export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:"$SPDK_DIR/build/lib"

                    CYCLE_OUT="$LOG_DIR/cycle_breakdown_s${IO_SIZE}_q${QD}_c${CORE_COUNT}_r${RUN_ID}.csv"
                    if [ "$PERF_ENABLE" -eq 1 ]; then
                        CMD_OUTPUT=$(SPDK_IO_CYCLE_ENABLE=1 SPDK_IO_CYCLE_OUT="$CYCLE_OUT" \
                            perf stat --no-scale -C "$CORE_CSV" -e "$PERF_EVENTS" -x ';' \
                            "${SPDK_CMD_RUN[@]}" 2>&1)
                    else
                        CMD_OUTPUT=$(SPDK_IO_CYCLE_ENABLE=1 SPDK_IO_CYCLE_OUT="$CYCLE_OUT" \
                            "${SPDK_CMD_RUN[@]}" 2>&1)
                    fi
                    RC=$?
                    echo "$CMD_OUTPUT" > "$RUN_LOG"

                    if [ $RC -ne 0 ] || ! echo "$CMD_OUTPUT" | grep -q "^Total"; then
                        echo "Error CORES=$CORE_COUNT IO_SIZE=$IO_SIZE QD=$QD Run=$RUN_ID (rc=$RC)" \
                            | tee -a "$ERROR_LOG"
                        echo "$RUN_LOG" >> "$ERROR_LOG"
                        continue
                    fi

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

                    echo "Done. ($IOPS IOPS)"
                    CSV_LINE="$QD,$QPAIRS,$IO_SIZE,$RUN_ID,$CORE_COUNT,$CORE_MASK,$IOPS,$CYCLES,$INSTR,$LLC,$CYC_PER_IO,$INSTR_PER_IO,$LLC_PER_IO,$P50,$P99,$P999,$POLLS,$COMPLETIONS,$SCANS_PER,$COMPLETIONS_PER,$MMIO_PER,$CPPHIST,$SUBMIT_NS,$COMPLETE_NS,$PREAMBLE_NS,$TR_ALLOC_NS,$XLATE_NS,$CMD_NS,$FENCE_NS,$DB_NS,$CQE_NS,$TR_LOOKUP_NS,$FREE_NS,$FREE_LIB_NS,$FREE_CB_NS,$FREE_TOTAL_NS"
                    echo "$CSV_LINE" >> "$OUTPUT_FILE"
                done
            done
        done
    done
done

echo "========================================================"
echo "Multi-core Phase 1 complete. Results saved under: $OUTPUT_BASE"
echo "========================================================"
echo "PHASE1_RUNSCRIPT_DONE"
