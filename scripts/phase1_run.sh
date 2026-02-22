#!/bin/bash

# ==============================================================================
# SPDK Phase 1 Automation Script
# Based on Research Plan Section 1.1 - 1.4
# ==============================================================================

# --- CONFIGURATION (Adjust these) ---
PCI_ADDR=${PCI_ADDR:-"0000:02:00.0"}  # PCI Address of the TARGET (Secondary) Drive
CORE_ID=${CORE_ID:-2}                 # CPU Core to pin the workload to
CORE_MASK=${CORE_MASK:-"0x4"}         # Hex mask for CORE_ID (used if CORE_IDS is unset)
CORE_IDS=(${CORE_IDS:-$CORE_ID})       # Space-separated list: "0 1 2"
CORE_MASKS=${CORE_MASKS:-""}          # Optional space-separated list: "0x1 0x2 0x4"

QPAIRS=${QPAIRS:-1}
QPAIRS_LIST=(${QPAIRS_LIST:-$QPAIRS})  # Space-separated list: "1 2 4"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=${ROOT_DIR:-"$(cd "$SCRIPT_DIR/.." && pwd)"}
OUTPUT_ROOT=${OUTPUT_ROOT:-"$ROOT_DIR/results/phase1_runs"}
RUN_TAG=${RUN_TAG:-"run_$(date +%Y%m%d_%H%M%S)"}
OUTPUT_BASE=${OUTPUT_BASE:-"$OUTPUT_ROOT/$RUN_TAG"}
# Path to SPDK repo (for scripts/setup.sh)
SPDK_DIR=${SPDK_DIR:-"$ROOT_DIR/spdk"}
# Path to SPDK perf binary (can be overridden via env var)
SPDK_PERF_BIN=${SPDK_PERF_BIN:-"$SPDK_DIR/build/bin/spdk_nvme_perf"}
# Hugepage memory in MB for scripts/setup.sh (override via env HUGEMEM_MB)
HUGEMEM_MB=${HUGEMEM_MB:-2048}
SKIP_SETUP=${SKIP_SETUP:-0}
# Ensure root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit
fi

# Basic dependency checks (post-OS reinstall safety net)
PCI_CHECK=${PCI_CHECK:-1}
PERF_ENABLE=${PERF_ENABLE:-1}

for bin in python3; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "Missing dependency: $bin. Please install it and retry."
        exit 1
    fi
done

if [ "$PCI_CHECK" -eq 1 ] && ! command -v lspci >/dev/null 2>&1; then
    echo "lspci not found; skipping PCI validation."
    PCI_CHECK=0
fi

if [ "$PERF_ENABLE" -eq 1 ] && ! command -v perf >/dev/null 2>&1; then
    echo "perf not found; disabling perf counters."
    PERF_ENABLE=0
fi

# Validate PCI address (auto-detect if needed)
if [ "$PCI_CHECK" -eq 1 ]; then
    if [ -z "$PCI_ADDR" ] || ! lspci -s "$PCI_ADDR" >/dev/null 2>&1; then
        NVME_LIST=$(lspci -D -nn | grep -i "Non-Volatile memory controller" || true)
        NVME_COUNT=$(echo "$NVME_LIST" | grep -c "Non-Volatile" || true)

        if [ "$NVME_COUNT" -eq 1 ]; then
            PCI_ADDR=$(echo "$NVME_LIST" | awk '{print $1}')
            echo "Auto-detected NVMe PCI address: $PCI_ADDR"
        else
            echo "PCI_ADDR is unset or invalid. Detected NVMe devices:"
            echo "$NVME_LIST"
            echo "Please set PCI_ADDR to the correct device and rerun."
            exit 1
        fi
    fi
fi

# Enable perf events
echo 0 > /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo "Warning: could not lower perf_event_paranoid"

# Run SPDK setup (hugepages + unbind NVMe/I/OAT) as recommended
if [ "$SKIP_SETUP" -eq 0 ]; then
    if [ ! -x "$SPDK_DIR/scripts/setup.sh" ]; then
        echo "SPDK setup script not found at $SPDK_DIR/scripts/setup.sh"
        exit 1
    fi

    echo "Running SPDK setup with HUGEMEM=${HUGEMEM_MB}MB..."
    HUGEMEM="$HUGEMEM_MB" "$SPDK_DIR/scripts/setup.sh" || {
        echo "SPDK setup failed."
        exit 1
    }

    # Ensure devices are rebound on exit
    _spdk_reset() {
        echo "Resetting SPDK setup (rebind devices back to kernel driver)..."
        "$SPDK_DIR/scripts/setup.sh" reset || true
    }
    trap _spdk_reset EXIT
fi

mkdir -p "$OUTPUT_BASE"

if [ -z "$PCI_ADDR" ]; then
    echo "WARNING: No PCI Address set. Using RAM Disk (Malloc) for script testing."
    echo "Please set a valid PCI_ADDR in the script to measure real hardware."
    exit 1
fi

# Verify SPDK perf binary exists and is executable. Try common fallbacks.
if [ ! -x "$SPDK_PERF_BIN" ]; then
    echo "SPDK perf binary not found or not executable at $SPDK_PERF_BIN"
    if [ -x "spdk/build/bin/spdk_nvme_perf" ]; then
        SPDK_PERF_BIN="spdk/build/bin/spdk_nvme_perf"
        echo "Using $SPDK_PERF_BIN"
    elif [ -x "spdk/build/examples/perf" ]; then
        SPDK_PERF_BIN="spdk/build/examples/perf"
        echo "Using $SPDK_PERF_BIN"
    elif [ -x "spdk/build/examples/bdevperf" ]; then
        SPDK_PERF_BIN="spdk/build/examples/bdevperf"
        echo "Using $SPDK_PERF_BIN (bdevperf)"
    else
        echo "Please build SPDK examples and/or set SPDK_PERF_BIN to the correct path."
        exit 1
    fi
fi

QUEUE_DEPTHS=(${QUEUE_DEPTHS_LIST:-"16 32 64 128"})
IO_SIZES=(${IO_SIZES_LIST:-"4096 16384"})
REPEATS=${REPEATS:-3}
WARMUP_TIME=0
STEADY_TIME=${STEADY_TIME:-30}

core_mask_from_id() {
    printf "0x%x" "$((1 << $1))"
}

read -a CORE_MASK_LIST <<< "$CORE_MASKS"

# Build perf event list once (Category B + D + E)
if [ "$PERF_ENABLE" -eq 1 ]; then
    PERF_EVENTS="cycles,instructions,LLC-load-misses"
    if perf list | grep -q "uncore_imc_free_running/data_read/"; then
        PERF_EVENTS="$PERF_EVENTS,uncore_imc_free_running/data_read/"
    fi
    if perf list | grep -q "uncore_imc_free_running/data_write/"; then
        PERF_EVENTS="$PERF_EVENTS,uncore_imc_free_running/data_write/"
    fi
    if perf list | grep -q "power/energy-pkg/"; then
        PERF_EVENTS="$PERF_EVENTS,power/energy-pkg/"
    fi
else
    PERF_EVENTS=""
fi

for CORE_IDX in "${!CORE_IDS[@]}"; do
    CORE_ID="${CORE_IDS[$CORE_IDX]}"
    if [ "${#CORE_MASK_LIST[@]}" -gt 0 ]; then
        CORE_MASK="${CORE_MASK_LIST[$CORE_IDX]:-${CORE_MASK_LIST[0]}}"
    elif [ "${#CORE_IDS[@]}" -eq 1 ] && [ -n "${CORE_MASK:-}" ]; then
        CORE_MASK="$CORE_MASK"
    else
        CORE_MASK=$(core_mask_from_id "$CORE_ID")
    fi

    for QPAIRS in "${QPAIRS_LIST[@]}"; do
        RUN_DIR="$OUTPUT_BASE/core${CORE_ID}_qp${QPAIRS}"
        OUTPUT_FILE="$RUN_DIR/phase1_results.csv"
        LOG_DIR="$RUN_DIR/logs"
        ERROR_LOG="$RUN_DIR/phase1_errors.log"

        mkdir -p "$RUN_DIR" "$LOG_DIR"
        > "$ERROR_LOG"

        # Setup Result CSV Header
        echo "QD,Qpairs,IO_Size,Run_ID,IOPS,Cycles,Instructions,LLC_Misses,Dram_Read_Bytes,Dram_Write_Bytes,Energy_Joules,Cycles_Per_IO,Instr_Per_IO,LLC_Misses_Per_IO,Dram_Read_Bytes_Per_IO,Dram_Write_Bytes_Per_IO,Energy_Per_IO,p50_Latency,p99_Latency,p99.9_Latency,Polls,Completions,Scans_Per_Completion,Completions_Per_Call,MMIO_Writes_Per_IO,Completions_Per_Poll_Hist,Submit_Logic_ns,Completion_Logic_ns,Submit_Preamble_ns,Tracker_Alloc_ns,Addr_Xlate_ns,Cmd_Construct_ns,Fence_ns,Doorbell_ns,CQE_Detect_ns,Tracker_Lookup_ns,State_Dealloc_ns" > "$OUTPUT_FILE"

        echo "========================================================"
        echo "Starting Phase 1 Evaluation"
        echo "Target: ${PCI_ADDR:-RAM_DISK_MODE}"
        echo "Core: $CORE_ID (Mask $CORE_MASK)"
        echo "Qpairs: $QPAIRS"
        echo "Saving to: $OUTPUT_FILE"
        echo "========================================================"

        for IO_SIZE in "${IO_SIZES[@]}"; do
            for QD in "${QUEUE_DEPTHS[@]}"; do
                for RUN_ID in $(seq 1 $REPEATS); do
			
                    echo -n "Running IO_SIZE=$IO_SIZE QD=$QD Run=$RUN_ID ... "

                    RUN_LOG="$LOG_DIR/run_s${IO_SIZE}_q${QD}_r${RUN_ID}.log"
                    # build SPDK commands
                    SPDK_CMD_RUN=("$SPDK_PERF_BIN" -r "trtype:PCIe traddr:$PCI_ADDR" -w randread -o "$IO_SIZE" -q "$QD" -t "$STEADY_TIME" -c "$CORE_MASK" -P "$QPAIRS" -L --transport-stats)

                    # Set LD_LIBRARY_PATH for SPDK shared libraries
                    export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:"$SPDK_DIR/build/lib"

                    # Run perf with CPU + uncore/energy events (Category B + D + E)
                    CYCLE_OUT="$LOG_DIR/cycle_breakdown_s${IO_SIZE}_q${QD}_r${RUN_ID}.csv"
                    if [ "$PERF_ENABLE" -eq 1 ]; then
                        CMD_OUTPUT=$(SPDK_IO_CYCLE_ENABLE=1 SPDK_IO_CYCLE_OUT="$CYCLE_OUT" perf stat --no-scale -C "$CORE_ID" -e "$PERF_EVENTS" -x ';' "${SPDK_CMD_RUN[@]}" 2>&1)
                    else
                        CMD_OUTPUT=$(SPDK_IO_CYCLE_ENABLE=1 SPDK_IO_CYCLE_OUT="$CYCLE_OUT" "${SPDK_CMD_RUN[@]}" 2>&1)
                    fi
                    RC=$?
                    echo "$CMD_OUTPUT" > "$RUN_LOG"

                    # If the SPDK tool failed or produced no throughput line, log error
                    if [ $RC -ne 0 ] || ! echo "$CMD_OUTPUT" | grep -q "^Total"; then
                        echo "Error on IO_SIZE=$IO_SIZE QD=$QD Run=$RUN_ID (rc=$RC). Saved output: $RUN_LOG" | tee -a "$ERROR_LOG"
                        echo "$RUN_LOG" >> "$ERROR_LOG"
                        continue
                    fi

                    # Extract IOPS from "Total" line
                    IOPS=$(echo "$CMD_OUTPUT" | grep "^Total" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]/) {print $i; exit}}')

                    # Extract perf values
                    if [ "$PERF_ENABLE" -eq 1 ]; then
                        CYCLES=$(echo "$CMD_OUTPUT" | grep -E 'cpu_core/cycles/|,cycles' | awk -F';' '{print $1}' | sed 's/<not supported>/0/g' | tr -d ',' | tr -d ' ' | tail -n1)
                        INSTR=$(echo "$CMD_OUTPUT" | grep -E 'cpu_core/instructions/|,instructions' | awk -F';' '{print $1}' | sed 's/<not supported>/0/g' | tr -d ',' | tr -d ' ' | tail -n1)
                        LLC=$(echo "$CMD_OUTPUT" | grep -E 'cpu_core/LLC-load-misses/|,LLC-load-misses' | awk -F';' '{print $1}' | sed 's/<not supported>/0/g' | tr -d ',' | tr -d ' ' | tail -n1)
                        DRAM_READ=$(echo "$CMD_OUTPUT" | grep -E 'uncore_imc_free_running/data_read' | awk -F';' '{print $1}' | sed 's/<not supported>/0/g' | tr -d ',' | tr -d ' ' | tail -n1)
                        DRAM_WRITE=$(echo "$CMD_OUTPUT" | grep -E 'uncore_imc_free_running/data_write' | awk -F';' '{print $1}' | sed 's/<not supported>/0/g' | tr -d ',' | tr -d ' ' | tail -n1)
                        ENERGY_CORES=0
                        ENERGY_PKG=$(echo "$CMD_OUTPUT" | grep -E 'power/energy-pkg' | awk -F';' '{print $1}' | sed 's/<not supported>/0/g' | tr -d ',' | tr -d ' ' | tail -n1)
                    else
                        CYCLES=0
                        INSTR=0
                        LLC=0
                        DRAM_READ=0
                        DRAM_WRITE=0
                        ENERGY_CORES=0
                        ENERGY_PKG=0
                    fi

                    # Extract latency percentiles (assuming histogram output)
                    P50=$(echo "$CMD_OUTPUT" | grep "50.00000%" | awk '{print $3}' | sed 's/us//')
                    P99=$(echo "$CMD_OUTPUT" | grep "99.00000%" | awk '{print $3}' | sed 's/us//')
                    P999=$(echo "$CMD_OUTPUT" | grep "99.90000%" | awk '{print $3}' | sed 's/us//')

                    # Extract PCIe transport stats (Category C/D)
                    PCIE_STATS_LINE=$(echo "$CMD_OUTPUT" | grep "pcie_stats:" | tail -n1)
                    if [ -n "$PCIE_STATS_LINE" ]; then
                        POLLS=$(echo "$PCIE_STATS_LINE" | sed -n 's/.*polls=\([0-9]*\).*/\1/p')
                        COMPLETIONS=$(echo "$PCIE_STATS_LINE" | sed -n 's/.*completions=\([0-9]*\).*/\1/p')
                        SQ_MMIO=$(echo "$PCIE_STATS_LINE" | sed -n 's/.*sq_mmio=\([0-9]*\).*/\1/p')
                        CQ_MMIO=$(echo "$PCIE_STATS_LINE" | sed -n 's/.*cq_mmio=\([0-9]*\).*/\1/p')
                    else
                        POLLS=0
                        COMPLETIONS=0
                        SQ_MMIO=0
                        CQ_MMIO=0
                    fi

                    COMPLETION_CALLS=$(echo "$CMD_OUTPUT" | grep -m1 "completion_calls:" | awk '{print $2}' | tr -d ',')
                    COMPLETION_CALLS=${COMPLETION_CALLS:-$POLLS}

                    # Extract completions_per_poll_hist as a quoted CSV string
                    CPPHIST=$(echo "$CMD_OUTPUT" | grep "completions_per_poll_hist:" | sed 's/^[^:]*://;s/^ *//;s/ *$//')
                    CPPHIST="\"$CPPHIST\""

                    # Derived polling stats (Category C)
                    SCANS_PER=$(python3 -c "print(float($COMPLETION_CALLS) / $COMPLETIONS if $COMPLETIONS > 0 else 0)")
                    COMPLETIONS_PER=$(python3 -c "print(float($COMPLETIONS) / $COMPLETION_CALLS if $COMPLETION_CALLS > 0 else 0)")

                    # Defaults
                    IOPS=${IOPS:-0}
                    CYCLES=${CYCLES:-0}
                    INSTR=${INSTR:-0}
                    LLC=${LLC:-0}
                    DRAM_READ=${DRAM_READ:-0}
                    DRAM_WRITE=${DRAM_WRITE:-0}
                    ENERGY_CORES=${ENERGY_CORES:-0}
                    ENERGY_PKG=${ENERGY_PKG:-0}
                    P50=${P50:-0}
                    P99=${P99:-0}
                    P999=${P999:-0}
                    POLLS=${POLLS:-0}
                    COMPLETIONS=${COMPLETIONS:-0}
                    SCANS_PER=${SCANS_PER:-0}
                    COMPLETIONS_PER=${COMPLETIONS_PER:-0}
                    MMIO_PER=${MMIO_PER:-0}

                    # Calculate per IO metrics
                    TOTAL_IOS=$(python3 -c "print(float($IOPS) * $STEADY_TIME)")
                    CYC_PER_IO=$(python3 -c "print(float($CYCLES) / $TOTAL_IOS if $TOTAL_IOS > 0 else 0)")
                    INSTR_PER_IO=$(python3 -c "print(float($INSTR) / $TOTAL_IOS if $TOTAL_IOS > 0 else 0)")
                    LLC_PER_IO=$(python3 -c "print(float($LLC) / $TOTAL_IOS if $TOTAL_IOS > 0 else 0)")
                    DRAM_READ_PER_IO=$(python3 -c "print(float($DRAM_READ) * 1048576 / $TOTAL_IOS if $TOTAL_IOS > 0 else 0)")
                    DRAM_WRITE_PER_IO=$(python3 -c "print(float($DRAM_WRITE) * 1048576 / $TOTAL_IOS if $TOTAL_IOS > 0 else 0)")
                    ENERGY_PER_IO=$(python3 -c "print(float($ENERGY_PKG) / $TOTAL_IOS if $TOTAL_IOS > 0 else 0)")
                    MMIO_PER=$(python3 -c "print((float($SQ_MMIO) + float($CQ_MMIO)) / $TOTAL_IOS if $TOTAL_IOS > 0 else 0)")

                    # Aggregate cycle breakdown (ns) from cycle_breakdown.csv
                    if [ -f "$CYCLE_OUT" ]; then
                        read SUBMIT_NS COMPLETE_NS PREAMBLE_NS TR_ALLOC_NS XLATE_NS CMD_NS FENCE_NS DB_NS CQE_NS TR_LOOKUP_NS FREE_NS <<EOF
$(python3 - <<PY
import csv
import math

path = "$CYCLE_OUT"
cols = [
    "submit_ns",
    "completion_ns",
    "submit_preamble_ns",
    "tracker_alloc_ns",
    "addr_xlate_ns",
    "cmd_construct_ns",
    "fence_ns",
    "doorbell_ns",
    "cqe_detect_ns",
    "tracker_lookup_ns",
    "state_dealloc_ns",
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
    print("0 0 0 0 0 0 0 0 0 0 0")
else:
    print(
        f"{sums['submit_ns']/count} {sums['completion_ns']/count} "
        f"{sums['submit_preamble_ns']/count} {sums['tracker_alloc_ns']/count} {sums['addr_xlate_ns']/count} "
        f"{sums['cmd_construct_ns']/count} {sums['fence_ns']/count} {sums['doorbell_ns']/count} "
        f"{sums['cqe_detect_ns']/count} {sums['tracker_lookup_ns']/count} {sums['state_dealloc_ns']/count}"
    )
PY
)
EOF
                    else
                        SUBMIT_NS=0
                        COMPLETE_NS=0
                        PREAMBLE_NS=0
                        TR_ALLOC_NS=0
                        XLATE_NS=0
                        CMD_NS=0
                        FENCE_NS=0
                        DB_NS=0
                        CQE_NS=0
                        TR_LOOKUP_NS=0
                        FREE_NS=0
                    fi

                    echo "Done. ($IOPS IOPS)"
                    CSV_LINE="$QD,$QPAIRS,$IO_SIZE,$RUN_ID,$IOPS,$CYCLES,$INSTR,$LLC,$DRAM_READ,$DRAM_WRITE,$ENERGY_PKG,$CYC_PER_IO,$INSTR_PER_IO,$LLC_PER_IO,$DRAM_READ_PER_IO,$DRAM_WRITE_PER_IO,$ENERGY_PER_IO,$P50,$P99,$P999,$POLLS,$COMPLETIONS,$SCANS_PER,$COMPLETIONS_PER,$MMIO_PER,$CPPHIST,$SUBMIT_NS,$COMPLETE_NS,$PREAMBLE_NS,$TR_ALLOC_NS,$XLATE_NS,$CMD_NS,$FENCE_NS,$DB_NS,$CQE_NS,$TR_LOOKUP_NS,$FREE_NS"
                    echo "$CSV_LINE" >> "$OUTPUT_FILE"
                done
            done
        done
    done
done

echo "========================================================"
echo "Phase 1 Complete. Results saved under: $OUTPUT_BASE"
echo "========================================================"

