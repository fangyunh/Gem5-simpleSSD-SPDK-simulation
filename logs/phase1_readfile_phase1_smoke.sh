#!/bin/sh
LOG_FILE="/tmp/phase1_readfile.log"
REPO_HINT="/root/SimpleSSD_Gem5_simulation"
REPO_CANDIDATES="/root/SimpleSSD_Gem5_simulation /home/root/SimpleSSD_Gem5_simulation /home/ubuntu/SimpleSSD_Gem5_simulation /mnt/host/SimpleSSD_Gem5_simulation /mnt/9p/SimpleSSD_Gem5_simulation"
{
  echo "PHASE1_RUNSCRIPT_START"
  echo "PHASE1_RUNSCRIPT_INFO: uname=$(uname -a)"
  echo "PHASE1_RUNSCRIPT_INFO: pwd=$(pwd)"
  echo "PHASE1_RUNSCRIPT_INFO: mounts:"
  mount | sed 's/^/  /'
  echo "PHASE1_RUNSCRIPT_INFO: ls /"
  ls -la / | sed 's/^/  /'
  echo "PHASE1_RUNSCRIPT_INFO: ls /mnt"
  ls -la /mnt 2>/dev/null | sed 's/^/  /'

  if [ -d /mnt/9p ] && ! mountpoint -q /mnt/9p 2>/dev/null; then
    mount -t 9p -o trans=virtio,version=9p2000.L host /mnt/9p 2>/dev/null || true
  fi
  if [ -d /mnt/host ] && ! mountpoint -q /mnt/host 2>/dev/null; then
    mount -t 9p -o trans=virtio,version=9p2000.L host /mnt/host 2>/dev/null || true
  fi

  find_repo() {
    for p in "$REPO_HINT" $REPO_CANDIDATES; do
      if [ -d "$p" ] && [ -f "$p/scripts/phase1_run.sh" ]; then
        echo "$p"
        return 0
      fi
    done
    # Fallback: scan for the script within a shallow depth
    found=$(find / -maxdepth 6 -path "*/scripts/phase1_run.sh" 2>/dev/null | head -n1)
    if [ -n "$found" ]; then
      echo "$(dirname "$(dirname "$found")")"
      return 0
    fi
    return 1
  }

  REPO_PATH="$(find_repo)"
  if [ -z "$REPO_PATH" ]; then
    echo "PHASE1_RUNSCRIPT_ERROR: repo not found"
    echo "Checked: $REPO_HINT $REPO_CANDIDATES"
    exit 1
  fi

  echo "PHASE1_RUNSCRIPT_REPO: $REPO_PATH"
  cd "$REPO_PATH" || exit 1
export CORE_IDS="1"
export CORE_MASKS=""
export QPAIRS_LIST="1"
export QUEUE_DEPTHS_LIST="16"
export IO_SIZES_LIST="4096"
export REPEATS=1
export STEADY_TIME=10
export RUN_TAG="phase1_smoke"
export OUTPUT_ROOT="results/phase1_runs"
export PCI_ADDR="0000:02:00.0"
export PCI_CHECK=0
export PERF_ENABLE=1
export SKIP_SETUP=1
export HUGEMEM_MB=2048
  ./scripts/phase1_run.sh
  echo "PHASE1_RUNSCRIPT_DONE"
} 2>&1 | tee "$LOG_FILE"

echo "PHASE1_RUNSCRIPT_LOG_BEGIN"
cat "$LOG_FILE"
echo "PHASE1_RUNSCRIPT_LOG_END"

if command -v m5 >/dev/null 2>&1; then
  m5 exit
fi
