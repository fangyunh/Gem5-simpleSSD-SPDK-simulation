#!/bin/bash

# ==============================================================================
# SPDK Phase 1 Automation Script (Multi-core: 2/4/8)
# ==============================================================================

# --- CONFIGURATION (Adjust these) ---
PCI_ADDR="0000:03:00.0"  # PCI Address of the TARGET (Secondary) Drive
OUTPUT_FILE="phase1_multicore_results.csv"  # Output Filename

BASE_DIR=$(cd "$(dirname "$0")" && pwd)
# Path to SPDK repo (for scripts/setup.sh)
SPDK_DIR=${SPDK_DIR:-"$BASE_DIR/spdk"}
# Path to SPDK perf binary (can be overridden via env var)
SPDK_PERF_BIN=${SPDK_PERF_BIN:-"$SPDK_DIR/build/bin/spdk_nvme_perf"}
# Hugepage memory in MB for scripts/setup.sh (override via env HUGEMEM_MB)
HUGEMEM_MB=${HUGEMEM_MB:-2048}

# Ensure root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# Enable perf events
echo 0 > /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo "Warning: could not lower perf_event_paranoid"

# Run SPDK setup (hugepages + unbind NVMe/I/OAT)
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

# Setup Result CSV Header
echo "QD,Qpairs,IO_Size,Run_ID,Core_Count,Core_List,IOPS,Cycles,Instructions,LLC_Misses,Dram_Read_Bytes,Dram_Write_Bytes,Energy_Joules,Cycles_Per_IO,Instr_Per_IO,LLC_Misses_Per_IO,Dram_Read_Bytes_Per_IO,Dram_Write_Bytes_Per_IO,Energy_Per_IO,p50_Latency,p99_Latency,p99.9_Latency,Polls,Completions,Scans_Per_Completion,Completions_Per_Call,MMIO_Writes_Per_IO,Completions_Per_Poll_Hist,Submit_Logic_ns,Completion_Logic_ns,Submit_Preamble_ns,Tracker_Alloc_ns,Addr_Xlate_ns,Cmd_Construct_ns,Fence_ns,Doorbell_ns,CQE_Detect_ns,Tracker_Lookup_ns,State_Dealloc_ns" > "$OUTPUT_FILE"

# Logging
LOG_DIR=${LOG_DIR:-logs}
mkdir -p "$LOG_DIR"
ERROR_LOG=${ERROR_LOG:-phase1_multicore_errors.log}
> "$ERROR_LOG"

if [ -z "$PCI_ADDR" ]; then
    echo "WARNING: No PCI Address set. Using RAM Disk (Malloc) for script testing."
    exit 1
fi

# Verify SPDK perf binary exists and is executable.
if [ ! -x "$SPDK_PERF_BIN" ]; then
    echo "SPDK perf binary not found or not executable at $SPDK_PERF_BIN"
    exit 1
fi

QUEUE_DEPTHS=(16 32 64 128)
IO_SIZES=(4096 16384)
CORE_COUNTS=(2 4 8)
REPEATS=1
QPAIRS=1
STEADY_TIME=30

# Build perf event list once (Category B + D + E)
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

get_53ghz_cores() {
    lscpu -e=CPU,MAXMHZ | awk 'NR>1 && $2==5300.0000 {print $1}'
}

select_cores() {
    local count=$1
    shift
    local cores=("$@")
    printf "%s " "${cores[@]:0:$count}"
}

CORE_POOL=($(get_53ghz_cores))
if [ ${#CORE_POOL[@]} -lt 8 ]; then
    echo "Not enough 5.3GHz cores available. Found ${#CORE_POOL[@]}."
    exit 1
fi

for IO_SIZE in "${IO_SIZES[@]}"; do
    for QD in "${QUEUE_DEPTHS[@]}"; do
        for CORE_COUNT in "${CORE_COUNTS[@]}"; do
            for RUN_ID in $(seq 1 $REPEATS); do
                CORE_LIST=$(select_cores "$CORE_COUNT" "${CORE_POOL[@]}")
                CORE_LIST=$(echo "$CORE_LIST" | xargs)
                CORE_CSV=$(echo "$CORE_LIST" | sed 's/ /,/g')

                mask=0
                for c in $CORE_LIST; do
                    mask=$((mask | (1 << c)))
                done
                CORE_MASK=$(printf "0x%x" "$mask")
                echo -n "Running IO_SIZE=$IO_SIZE QD=$QD Cores=$CORE_COUNT Run=$RUN_ID ... "

                RUN_LOG="$LOG_DIR/run_s${IO_SIZE}_q${QD}_c${CORE_COUNT}_r${RUN_ID}.log"
                SPDK_CMD_RUN=("$SPDK_PERF_BIN" -r "trtype:PCIe traddr:$PCI_ADDR" -w randread -o "$IO_SIZE" -q "$QD" -t "$STEADY_TIME" -c "$CORE_MASK" -P "$QPAIRS" -L --transport-stats)

                export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:"$SPDK_DIR/build/lib"

                CYCLE_OUT="$LOG_DIR/cycle_breakdown_s${IO_SIZE}_q${QD}_c${CORE_COUNT}_r${RUN_ID}.csv"
                CMD_OUTPUT=$(SPDK_IO_CYCLE_ENABLE=1 SPDK_IO_CYCLE_OUT="$CYCLE_OUT" perf stat --no-scale -C "$CORE_CSV" -e "$PERF_EVENTS" -x ';' "${SPDK_CMD_RUN[@]}" 2>&1)
                RC=$?
                echo "$CMD_OUTPUT" > "$RUN_LOG"

                if [ $RC -ne 0 ] || ! echo "$CMD_OUTPUT" | grep -q "^Total"; then
                    echo "Error on IO_SIZE=$IO_SIZE QD=$QD Run=$RUN_ID (rc=$RC). Saved output: $RUN_LOG" | tee -a "$ERROR_LOG"
                    echo "$RUN_LOG" >> "$ERROR_LOG"
                    continue
                fi

                IOPS=$(echo "$CMD_OUTPUT" | grep "^Total" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]/) {print $i; exit}}')

                CYCLES=$(echo "$CMD_OUTPUT" | grep -E 'cpu_core/cycles/|,cycles' | awk -F';' '{print $1}' | sed 's/<not supported>/0/g' | tr -d ',' | tr -d ' ' | tail -n1)
                INSTR=$(echo "$CMD_OUTPUT" | grep -E 'cpu_core/instructions/|,instructions' | awk -F';' '{print $1}' | sed 's/<not supported>/0/g' | tr -d ',' | tr -d ' ' | tail -n1)
                LLC=$(echo "$CMD_OUTPUT" | grep -E 'cpu_core/LLC-load-misses/|,LLC-load-misses' | awk -F';' '{print $1}' | sed 's/<not supported>/0/g' | tr -d ',' | tr -d ' ' | tail -n1)
                DRAM_READ=$(echo "$CMD_OUTPUT" | grep -E 'uncore_imc_free_running/data_read' | awk -F';' '{print $1}' | sed 's/<not supported>/0/g' | tr -d ',' | tr -d ' ' | tail -n1)
                DRAM_WRITE=$(echo "$CMD_OUTPUT" | grep -E 'uncore_imc_free_running/data_write' | awk -F';' '{print $1}' | sed 's/<not supported>/0/g' | tr -d ',' | tr -d ' ' | tail -n1)
                ENERGY_PKG=$(echo "$CMD_OUTPUT" | grep -E 'power/energy-pkg' | awk -F';' '{print $1}' | sed 's/<not supported>/0/g' | tr -d ',' | tr -d ' ' | tail -n1)

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
                    POLLS=0
                    COMPLETIONS=0
                    SQ_MMIO=0
                    CQ_MMIO=0
                fi

                COMPLETION_CALLS=$(echo "$CMD_OUTPUT" | grep -m1 "completion_calls:" | awk '{print $2}' | tr -d ',')
                COMPLETION_CALLS=${COMPLETION_CALLS:-$POLLS}

                CPPHIST=$(echo "$CMD_OUTPUT" | grep "completions_per_poll_hist:" | sed 's/^[^:]*://;s/^ *//;s/ *$//')
                CPPHIST="\"$CPPHIST\""

                SCANS_PER=$(awk -v calls="${COMPLETION_CALLS}" -v comps="${COMPLETIONS}" 'BEGIN{print (comps>0)?calls/comps:0}')
                COMPLETIONS_PER=$(awk -v calls="${COMPLETION_CALLS}" -v comps="${COMPLETIONS}" 'BEGIN{print (calls>0)?comps/calls:0}')

                TOTAL_IOS=$(awk -v iops="${IOPS}" -v t="${STEADY_TIME}" 'BEGIN{print iops*t}')
                CYC_PER_IO=$(awk -v a="${CYCLES}" -v total="${TOTAL_IOS}" 'BEGIN{print (total>0)?a/total:0}')
                INSTR_PER_IO=$(awk -v a="${INSTR}" -v total="${TOTAL_IOS}" 'BEGIN{print (total>0)?a/total:0}')
                LLC_PER_IO=$(awk -v a="${LLC}" -v total="${TOTAL_IOS}" 'BEGIN{print (total>0)?a/total:0}')
                DRAM_READ_PER_IO=$(awk -v a="${DRAM_READ}" -v total="${TOTAL_IOS}" 'BEGIN{print (total>0)?(a*1048576)/total:0}')
                DRAM_WRITE_PER_IO=$(awk -v a="${DRAM_WRITE}" -v total="${TOTAL_IOS}" 'BEGIN{print (total>0)?(a*1048576)/total:0}')
                ENERGY_PER_IO=$(awk -v a="${ENERGY_PKG}" -v total="${TOTAL_IOS}" 'BEGIN{print (total>0)?a/total:0}')
                MMIO_PER=$(awk -v a="${SQ_MMIO}" -v b="${CQ_MMIO}" -v total="${TOTAL_IOS}" 'BEGIN{print (total>0)?(a+b)/total:0}')

                if [ -f "$CYCLE_OUT" ]; then
                    read SUBMIT_NS COMPLETE_NS PREAMBLE_NS TR_ALLOC_NS XLATE_NS CMD_NS FENCE_NS DB_NS CQE_NS TR_LOOKUP_NS FREE_NS <<EOF
$(python3 - <<PY
import csv

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
                CSV_LINE="$QD,$QPAIRS,$IO_SIZE,$RUN_ID,$CORE_COUNT,\"$CORE_LIST\",$IOPS,$CYCLES,$INSTR,$LLC,$DRAM_READ,$DRAM_WRITE,$ENERGY_PKG,$CYC_PER_IO,$INSTR_PER_IO,$LLC_PER_IO,$DRAM_READ_PER_IO,$DRAM_WRITE_PER_IO,$ENERGY_PER_IO,$P50,$P99,$P999,$POLLS,$COMPLETIONS,$SCANS_PER,$COMPLETIONS_PER,$MMIO_PER,$CPPHIST,$SUBMIT_NS,$COMPLETE_NS,$PREAMBLE_NS,$TR_ALLOC_NS,$XLATE_NS,$CMD_NS,$FENCE_NS,$DB_NS,$CQE_NS,$TR_LOOKUP_NS,$FREE_NS"
                echo "$CSV_LINE" >> "$OUTPUT_FILE"
            done
        done
    done
done

