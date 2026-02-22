#!/bin/bash

# ==============================================================================
# SPDK Phase 1 Automation Script (bdev malloc mode)
# Focus: CPU-core max IOPS using an in-memory bdev
# ==============================================================================

# --- CONFIGURATION (Adjust these) ---
CORE_ID=${CORE_ID:-2}                 # CPU Core to pin the workload to
CORE_MASK=${CORE_MASK:-"0x4"}         # Hex mask for CORE_ID (used if CORE_IDS is unset)
CORE_IDS=(${CORE_IDS:-$CORE_ID})       # Space-separated list: "0 1 2"
CORE_MASKS=${CORE_MASKS:-""}          # Optional space-separated list: "0x1 0x2 0x4"

QPAIRS=${QPAIRS:-1}
QPAIRS_LIST=(${QPAIRS_LIST:-$QPAIRS})  # Space-separated list: "1 2 4"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=${ROOT_DIR:-"$(cd "$SCRIPT_DIR/.." && pwd)"}
OUTPUT_ROOT=${OUTPUT_ROOT:-"$ROOT_DIR/results/bdev_data"}
RUN_TAG=${RUN_TAG:-"run_$(date +%Y%m%d_%H%M%S)"}
OUTPUT_DIR=${OUTPUT_DIR:-"$OUTPUT_ROOT/$RUN_TAG"}
# Path to SPDK repo (for scripts/setup.sh and bdevperf.py)
SPDK_DIR=${SPDK_DIR:-"$ROOT_DIR/spdk"}
# Path to SPDK bdevperf binary (can be overridden via env var)
BDEVPERF_BIN=${BDEVPERF_BIN:-"$SPDK_DIR/build/examples/bdevperf"}
# RPC socket for bdevperf
RPC_SOCK=${RPC_SOCK:-/tmp/bdevperf.sock}

# Hugepage memory in MB for scripts/setup.sh (override via env HUGEMEM_MB)
HUGEMEM_MB=${HUGEMEM_MB:-2048}

# Optional toggles
SKIP_SETUP=${SKIP_SETUP:-0}   # Set to 1 to skip scripts/setup.sh
NO_HUGE=${NO_HUGE:-0}         # Set to 1 to use non-hugepage buffers (-H)
FORCE_KILL=${FORCE_KILL:-0}   # Set to 1 to kill stale bdevperf holding the RPC socket

# Malloc bdev configuration
BDEV_NAME=${BDEV_NAME:-Malloc0}
MALLOC_NUM_BLOCKS=${MALLOC_NUM_BLOCKS:-1048576}  # 1048576 * 512 = 512MiB
MALLOC_BLOCK_SIZE=${MALLOC_BLOCK_SIZE:-512}

# Latency histogram level: 0=off, 1=summary, 2=full histogram
HISTOGRAM_LEVEL=${HISTOGRAM_LEVEL:-2}

QUEUE_DEPTHS=(16 32 64 128)
IO_SIZES=(4096 16384)
REPEATS=3
STEADY_TIME=30

# Ensure root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# Basic dependency checks
for bin in python3; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "Missing dependency: $bin. Please install it and retry."
        exit 1
    fi
done

PERF_ENABLE=${PERF_ENABLE:-1}
if [ "$PERF_ENABLE" -eq 1 ] && ! command -v perf >/dev/null 2>&1; then
    echo "perf not found. Set PERF_ENABLE=0 to skip perf counters."
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

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

# Enable perf events
echo 0 > /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo "Warning: could not lower perf_event_paranoid"

# Run SPDK setup (hugepages only; skip PCI binding)
if [ "$SKIP_SETUP" -eq 0 ]; then
    if [ ! -x "$SPDK_DIR/scripts/setup.sh" ]; then
        echo "SPDK setup script not found at $SPDK_DIR/scripts/setup.sh"
        exit 1
    fi

    echo "Running SPDK setup with HUGEMEM=${HUGEMEM_MB}MB (PCI binding disabled)..."
    PCI_ALLOWED="none" HUGEMEM="$HUGEMEM_MB" "$SPDK_DIR/scripts/setup.sh" || {
        echo "SPDK setup failed."
        exit 1
    }

    _spdk_reset() {
        echo "Resetting SPDK setup (rebind devices back to kernel driver)..."
        PCI_ALLOWED="none" "$SPDK_DIR/scripts/setup.sh" reset || true
    }
    CLEANUP_RESET=1
fi

_cleanup() {
    if [ -n "${BDEVPERF_PID:-}" ]; then
        kill "$BDEVPERF_PID" 2>/dev/null || true
        wait "$BDEVPERF_PID" 2>/dev/null || true
    fi
    rm -f "$RPC_SOCK"
    if [ "${CLEANUP_RESET:-0}" -eq 1 ]; then
        _spdk_reset
    fi
}
trap _cleanup EXIT

# Create malloc bdev JSON config for bdevperf
BDEV_JSON="$OUTPUT_DIR/bdevperf.json"
cat > "$BDEV_JSON" <<EOF
{
  "subsystems": [
    {
      "subsystem": "bdev",
      "config": [
        {
          "method": "bdev_malloc_create",
          "params": {
            "name": "${BDEV_NAME}",
            "num_blocks": ${MALLOC_NUM_BLOCKS},
            "block_size": ${MALLOC_BLOCK_SIZE}
          }
        }
      ]
    }
  ]
}
EOF

# Verify bdevperf binary exists
if [ ! -x "$BDEVPERF_BIN" ]; then
    echo "bdevperf binary not found or not executable at $BDEVPERF_BIN"
    exit 1
fi

# Core mask helper
core_mask_from_id() {
    printf "0x%x" "$((1 << $1))"
}

read -a CORE_MASK_LIST <<< "$CORE_MASKS"

HIST_OPT=""
if [ "$HISTOGRAM_LEVEL" -eq 1 ]; then
    HIST_OPT="-l"
elif [ "$HISTOGRAM_LEVEL" -ge 2 ]; then
    HIST_OPT="-ll"
fi

HUGE_OPT=""
if [ "$NO_HUGE" -eq 1 ]; then
    HUGE_OPT="-H"
fi

start_bdevperf() {
    local core_mask="$1"
    local log_dir="$2"

    rm -f "$RPC_SOCK"
    if [ -S "$RPC_SOCK" ]; then
        if pgrep -fa bdevperf | grep -q "${RPC_SOCK}"; then
            if [ "$FORCE_KILL" -eq 1 ]; then
                echo "Found stale bdevperf using $RPC_SOCK. Killing it..."
                pgrep -fa bdevperf | awk '{print $1}' | xargs -r kill
                sleep 1
            else
                echo "RPC socket $RPC_SOCK is already in use."
                echo "Set FORCE_KILL=1 to terminate the existing bdevperf process."
                exit 1
            fi
        else
            echo "RPC socket $RPC_SOCK exists but no bdevperf process found."
            echo "Please remove the socket file and retry: rm -f $RPC_SOCK"
            exit 1
        fi
    fi

    "$BDEVPERF_BIN" -m "$core_mask" -c "$BDEV_JSON" -r "$RPC_SOCK" -z -T "$BDEV_NAME" $HIST_OPT $HUGE_OPT \
        > "$log_dir/bdevperf_stdout.log" 2>&1 &
    BDEVPERF_PID=$!

    for _ in $(seq 1 50); do
        if [ -S "$RPC_SOCK" ]; then
            break
        fi
        sleep 0.1
    done

    if [ ! -S "$RPC_SOCK" ]; then
        echo "RPC socket not ready at $RPC_SOCK. Check $log_dir/bdevperf_stdout.log"
        kill "$BDEVPERF_PID" 2>/dev/null || true
        exit 1
    fi
}

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
        RUN_DIR="$OUTPUT_DIR/core${CORE_ID}_qp${QPAIRS}"
        OUTPUT_FILE="$RUN_DIR/phase1_bdev_results.csv"
        LOG_DIR="$RUN_DIR/logs"
        HIST_DIR="$RUN_DIR/histograms"
        ERROR_LOG="$RUN_DIR/phase1_bdev_errors.log"

        mkdir -p "$RUN_DIR" "$LOG_DIR" "$HIST_DIR"
        > "$ERROR_LOG"

        # Setup Result CSV Header (same schema as phase1_run.sh)
        echo "QD,Qpairs,IO_Size,Run_ID,IOPS,Cycles,Instructions,LLC_Misses,Dram_Read_Bytes,Dram_Write_Bytes,Energy_Joules,Cycles_Per_IO,Instr_Per_IO,LLC_Misses_Per_IO,Dram_Read_Bytes_Per_IO,Dram_Write_Bytes_Per_IO,Energy_Per_IO,p50_Latency,p99_Latency,p99.9_Latency,Polls,Completions,Scans_Per_Completion,Completions_Per_Call,MMIO_Writes_Per_IO,Completions_Per_Poll_Hist,Submit_Logic_ns,Completion_Logic_ns,Submit_Preamble_ns,Tracker_Alloc_ns,Addr_Xlate_ns,Cmd_Construct_ns,Fence_ns,Doorbell_ns,CQE_Detect_ns,Tracker_Lookup_ns,State_Dealloc_ns" > "$OUTPUT_FILE"

        echo "========================================================"
        echo "Starting Phase 1 Evaluation (bdev malloc)"
        echo "Bdev: $BDEV_NAME"
        echo "Core: $CORE_ID (Mask $CORE_MASK)"
        echo "Qpairs: $QPAIRS"
        echo "Saving to: $OUTPUT_FILE"
        echo "========================================================"

        if [ "$QPAIRS" -ne 1 ]; then
            echo "Note: bdevperf does not expose qpairs; QPAIRS is recorded in CSV only."
        fi

        start_bdevperf "$CORE_MASK" "$LOG_DIR"

        for IO_SIZE in "${IO_SIZES[@]}"; do
            for QD in "${QUEUE_DEPTHS[@]}"; do
                for RUN_ID in $(seq 1 $REPEATS); do
                    echo -n "Running IO_SIZE=$IO_SIZE QD=$QD Run=$RUN_ID ... "

                    RUN_LOG="$LOG_DIR/run_s${IO_SIZE}_q${QD}_r${RUN_ID}.log"
                    PERF_LOG="$LOG_DIR/perf_s${IO_SIZE}_q${QD}_r${RUN_ID}.log"

                    # Run perf stat attached to bdevperf process during the test window
                    if [ "$PERF_ENABLE" -eq 1 ]; then
                        perf stat --no-scale -p "$BDEVPERF_PID" -e "$PERF_EVENTS" -x ';' -o "$PERF_LOG" -- sleep "$STEADY_TIME" &
                        PERF_PID=$!
                    else
                        PERF_PID=""
                    fi

                    # Trigger test via RPC (JSON output)
                    PYTHONPATH="$SPDK_DIR/python" \
                        python3 "$SPDK_DIR/examples/bdev/bdevperf/bdevperf.py" \
                        -s "$RPC_SOCK" perform_tests -q "$QD" -o "$IO_SIZE" -t "$STEADY_TIME" -w randread \
                        > "$RUN_LOG" 2>&1
                    RPC_RC=$?

                    if [ -n "$PERF_PID" ]; then
                        wait "$PERF_PID" 2>/dev/null
                    fi

                    if [ $RPC_RC -ne 0 ]; then
                        echo "Error on IO_SIZE=$IO_SIZE QD=$QD Run=$RUN_ID (rpc rc=$RPC_RC). Saved output: $RUN_LOG" | tee -a "$ERROR_LOG"
                        echo "$RUN_LOG" >> "$ERROR_LOG"
                        continue
                    fi

            # Extract IOPS and latency from JSON output
            read IOPS AVG_LAT MIN_LAT MAX_LAT STATUS <<EOF
$(python3 - <<PY
import json
import sys

path = "$RUN_LOG"
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("0 0 0 0 failed")
    sys.exit(0)

results = data.get("results", [])
if not results:
    print("0 0 0 0 failed")
    sys.exit(0)

# Use the first job (Malloc0)
job = results[0]
print(f"{job.get('iops', 0)} {job.get('avg_latency_us', 0)} {job.get('min_latency_us', 0)} {job.get('max_latency_us', 0)} {job.get('status', 'unknown')}")
PY
)
EOF

            if [ "$STATUS" != "finished" ]; then
                echo "Error on IO_SIZE=$IO_SIZE QD=$QD Run=$RUN_ID (status=$STATUS). Saved output: $RUN_LOG" | tee -a "$ERROR_LOG"
                echo "$RUN_LOG" >> "$ERROR_LOG"
                continue
            fi

            # Extract perf values
            if [ "$PERF_ENABLE" -eq 1 ]; then
                CYCLES=$(grep -E 'cpu_core/cycles/|;cycles' "$PERF_LOG" | awk -F';' '{print $1}' | sed 's/<not supported>/0/g' | tr -d ',' | tr -d ' ' | tail -n1)
                INSTR=$(grep -E 'cpu_core/instructions/|;instructions' "$PERF_LOG" | awk -F';' '{print $1}' | sed 's/<not supported>/0/g' | tr -d ',' | tr -d ' ' | tail -n1)
                LLC=$(grep -E 'cpu_core/LLC-load-misses/|;LLC-load-misses' "$PERF_LOG" | awk -F';' '{print $1}' | sed 's/<not supported>/0/g' | tr -d ',' | tr -d ' ' | tail -n1)
                DRAM_READ=$(grep -E 'uncore_imc_free_running/data_read' "$PERF_LOG" | awk -F';' '{print $1}' | sed 's/<not supported>/0/g' | tr -d ',' | tr -d ' ' | tail -n1)
                DRAM_WRITE=$(grep -E 'uncore_imc_free_running/data_write' "$PERF_LOG" | awk -F';' '{print $1}' | sed 's/<not supported>/0/g' | tr -d ',' | tr -d ' ' | tail -n1)
                ENERGY_PKG=$(grep -E 'power/energy-pkg' "$PERF_LOG" | awk -F';' '{print $1}' | sed 's/<not supported>/0/g' | tr -d ',' | tr -d ' ' | tail -n1)
            else
                CYCLES=0
                INSTR=0
                LLC=0
                DRAM_READ=0
                DRAM_WRITE=0
                ENERGY_PKG=0
            fi

            # Extract latency percentiles and histogram (from bdevperf stdout)
            HIST_CSV="$HIST_DIR/hist_s${IO_SIZE}_q${QD}_r${RUN_ID}.csv"
            PCT_OUT=$(LOG_PATH="$LOG_DIR/bdevperf_stdout.log" \
                      JOB_NAME="$BDEV_NAME" \
                      HIST_CSV="$HIST_CSV" \
                      python3 - <<'PY'
import csv
import re
import os

log_path = os.environ.get("LOG_PATH", "")
job_name = os.environ.get("JOB_NAME", "")
hist_csv = os.environ.get("HIST_CSV", "")

try:
    with open(log_path, "r", encoding="utf-8", errors="ignore") as f:
        lines = f.read().splitlines()
except FileNotFoundError:
    print("0 0 0")
    raise SystemExit

def find_last_index(token: str) -> int:
    idx = -1
    for i, line in enumerate(lines):
        if token in line:
            idx = i
    return idx

def extract_job_block(start_idx: int):
    if start_idx < 0:
        return []
    job_idx = -1
    for i in range(start_idx, len(lines)):
        if f"Job: {job_name}" in lines[i]:
            job_idx = i
            break
    if job_idx < 0:
        return []
    block = []
    for i in range(job_idx + 1, len(lines)):
        line = lines[i].strip()
        if not line:
            break
        if line.startswith("Job:") or "Latency histogram" in line or "Latency summary" in line:
            break
        block.append(line)
    return block

sum_idx = find_last_index("Latency summary")
summary_block = extract_job_block(sum_idx)

def parse_pct(block):
    pct_map = {}
    for line in block:
        m = re.match(r"^(\d+\.\d+)%\s*:\s*([0-9.]+)us$", line)
        if not m:
            continue
        pct = float(m.group(1))
        val = float(m.group(2))
        pct_map[pct] = val
    return pct_map

pcts = parse_pct(summary_block)
p50 = pcts.get(50.0, 0)
p99 = pcts.get(99.0, 0)
p999 = pcts.get(99.9, 0)

hist_idx = find_last_index("Latency histogram")
hist_block = extract_job_block(hist_idx)

if hist_block:
    with open(hist_csv, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["start_us", "end_us", "pct", "count"])
        for line in hist_block:
            m = re.match(r"^([0-9.]+)\s*-\s*([0-9.]+):\s*([0-9.]+)%\s*\((\d+)\)$", line)
            if not m:
                continue
            writer.writerow([m.group(1), m.group(2), m.group(3), m.group(4)])

print(f"{p50} {p99} {p999}")
PY
)

            read -r P50 P99 P999 <<< "$PCT_OUT"

            # Defaults
            IOPS=${IOPS:-0}
            CYCLES=${CYCLES:-0}
            INSTR=${INSTR:-0}
            LLC=${LLC:-0}
            DRAM_READ=${DRAM_READ:-0}
            DRAM_WRITE=${DRAM_WRITE:-0}
            ENERGY_PKG=${ENERGY_PKG:-0}

            # Not applicable for bdevperf malloc mode
            POLLS=0
            COMPLETIONS=0
            SCANS_PER=0
            COMPLETIONS_PER=0
            MMIO_PER=0
            CPPHIST="\"\""

            # Calculate per IO metrics
            TOTAL_IOS=$(python3 -c "print(float($IOPS) * $STEADY_TIME)")
            CYC_PER_IO=$(python3 -c "print(float($CYCLES) / $TOTAL_IOS if $TOTAL_IOS > 0 else 0)")
            INSTR_PER_IO=$(python3 -c "print(float($INSTR) / $TOTAL_IOS if $TOTAL_IOS > 0 else 0)")
            LLC_PER_IO=$(python3 -c "print(float($LLC) / $TOTAL_IOS if $TOTAL_IOS > 0 else 0)")
            DRAM_READ_PER_IO=$(python3 -c "print(float($DRAM_READ) * 1048576 / $TOTAL_IOS if $TOTAL_IOS > 0 else 0)")
            DRAM_WRITE_PER_IO=$(python3 -c "print(float($DRAM_WRITE) * 1048576 / $TOTAL_IOS if $TOTAL_IOS > 0 else 0)")
            ENERGY_PER_IO=$(python3 -c "print(float($ENERGY_PKG) / $TOTAL_IOS if $TOTAL_IOS > 0 else 0)")

            # Cycle breakdown not available for bdevperf malloc mode
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

            echo "Done. ($IOPS IOPS)"
            CSV_LINE="$QD,$QPAIRS,$IO_SIZE,$RUN_ID,$IOPS,$CYCLES,$INSTR,$LLC,$DRAM_READ,$DRAM_WRITE,$ENERGY_PKG,$CYC_PER_IO,$INSTR_PER_IO,$LLC_PER_IO,$DRAM_READ_PER_IO,$DRAM_WRITE_PER_IO,$ENERGY_PER_IO,$P50,$P99,$P999,$POLLS,$COMPLETIONS,$SCANS_PER,$COMPLETIONS_PER,$MMIO_PER,$CPPHIST,$SUBMIT_NS,$COMPLETE_NS,$PREAMBLE_NS,$TR_ALLOC_NS,$XLATE_NS,$CMD_NS,$FENCE_NS,$DB_NS,$CQE_NS,$TR_LOOKUP_NS,$FREE_NS"
                    echo "$CSV_LINE" >> "$OUTPUT_FILE"
                done
            done
        done

        # Cleanup bdevperf for this core
        kill "$BDEVPERF_PID" 2>/dev/null || true
        wait "$BDEVPERF_PID" 2>/dev/null || true
        rm -f "$RPC_SOCK"
    done
done

echo "========================================================"
echo "Phase 1 (bdev) Complete. Results saved under: $OUTPUT_DIR"
echo "========================================================"
