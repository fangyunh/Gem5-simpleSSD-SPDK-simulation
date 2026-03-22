#!/bin/sh
LOG_FILE="/tmp/phase1_readfile.log"
REPO_HINT="/mnt/9p"
REPO_CANDIDATES="/mnt/9p /mnt/9p/SimpleSSD_Gem5_simulation /root/SimpleSSD_Gem5_simulation /home/root/SimpleSSD_Gem5_simulation /home/ubuntu/SimpleSSD_Gem5_simulation /mnt/host/SimpleSSD_Gem5_simulation /mnt/9p/SimpleSSD_Gem5_simulation"
HOST_SHARE="/home/fangy6/SimpleSSD_Gem5_simulation"
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

  if [ -n "$HOST_SHARE" ]; then
    mkdir -p /mnt/9p
    if mountpoint -q /mnt/9p 2>/dev/null; then
      echo "PHASE1_RUNSCRIPT_INFO: /mnt/9p already mounted"
    else
      mount_ok=0

      echo "PHASE1_RUNSCRIPT_INFO: trying 9p mount with aname=$HOST_SHARE"
      if mount -t 9p -o trans=virtio,version=9p2000.L,aname="$HOST_SHARE" gem5 /mnt/9p; then
        mount_ok=1
        echo "PHASE1_RUNSCRIPT_INFO: /mnt/9p mounted with aname=$HOST_SHARE"
      else
        echo "PHASE1_RUNSCRIPT_WARN: mount attempt failed (aname=$HOST_SHARE)"
      fi

      if [ "$mount_ok" -eq 0 ]; then
        echo "PHASE1_RUNSCRIPT_INFO: trying 9p mount with aname=/"
        if mount -t 9p -o trans=virtio,version=9p2000.L,aname=/ gem5 /mnt/9p; then
          mount_ok=1
          echo "PHASE1_RUNSCRIPT_INFO: /mnt/9p mounted with aname=/"
        else
          echo "PHASE1_RUNSCRIPT_WARN: mount attempt failed (aname=/)"
        fi
      fi

      if [ "$mount_ok" -eq 0 ]; then
        echo "PHASE1_RUNSCRIPT_INFO: trying 9p mount without aname"
        if mount -t 9p -o trans=virtio,version=9p2000.L gem5 /mnt/9p; then
          mount_ok=1
          echo "PHASE1_RUNSCRIPT_INFO: /mnt/9p mounted without aname"
        else
          echo "PHASE1_RUNSCRIPT_WARN: mount attempt failed (no aname)"
        fi
      fi

      if [ "$mount_ok" -eq 0 ]; then
        echo "PHASE1_RUNSCRIPT_WARN: failed to mount /mnt/9p from $HOST_SHARE"
      fi
    fi
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

  # Raise memlock limit so DPDK/VFIO can mmap hugepages and device BARs.
  # The guest Ubuntu 18.04 image ships a 16 MB default for root which is too low.
  # Write to limits.d/ (highest priority) so 'su root -c "ulimit -l"' also sees it.
  mkdir -p /etc/security/limits.d
  echo '* - memlock unlimited' > /etc/security/limits.d/99-dpdk-memlock.conf
  echo 'root - memlock unlimited' >> /etc/security/limits.d/99-dpdk-memlock.conf
  ulimit -l unlimited 2>/dev/null || true

export CORE_IDS="0"
export CORE_MASKS=""
export QPAIRS_LIST="1"
export QUEUE_DEPTHS_LIST="16 32 64 128"
export IO_SIZES_LIST="4096 16384"
export REPEATS=3
export STEADY_TIME=30
export RUN_TAG="phase1_realistic_mlc"
export OUTPUT_ROOT="/mnt/9p/results"
export PCI_ADDR="0000:00:05.0"
export PCI_CHECK=0
export PERF_ENABLE=1
export SKIP_SETUP=0
export HUGEMEM_MB=1024
  ./scripts/phase1_run.sh
  echo "PHASE1_RUNSCRIPT_INFO: output_root=$OUTPUT_ROOT"
  ls -la "$OUTPUT_ROOT" 2>/dev/null | sed 's/^/  /'
  ls -la "$OUTPUT_ROOT/$RUN_TAG" 2>/dev/null | sed 's/^/  /'
  sync
  sleep 2
  echo "PHASE1_RUNSCRIPT_DONE"
} 2>&1 | tee "$LOG_FILE"

echo "PHASE1_RUNSCRIPT_LOG_BEGIN"
cat "$LOG_FILE"
echo "PHASE1_RUNSCRIPT_LOG_END"

if command -v m5 >/dev/null 2>&1; then
  m5 exit
fi
