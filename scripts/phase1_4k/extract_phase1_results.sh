#!/usr/bin/env bash
set -euo pipefail

# Extract phase1 results from the gem5 disk image back to the host.
# Requires sudo/root to mount the image.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)

DISK_IMAGE=${DISK_IMAGE:-"$ROOT_DIR/assets/x86-ubuntu.img"}
RUN_TAG=${RUN_TAG:-""}
MOUNT_DIR=${MOUNT_DIR:-"/mnt/gem5_img"}
LOOP_DEV=""
GUEST_BASE=${GUEST_BASE:-"/root/SimpleSSD_Gem5_simulation/results/phase1_runs"}
HOST_OUT=${HOST_OUT:-"$ROOT_DIR/results/phase1_runs"}

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --disk-image PATH   Disk image path (default: $DISK_IMAGE)
  --run-tag NAME      Run tag to extract (default: all)
  --mount-dir PATH    Temporary mount point (default: $MOUNT_DIR)
  --guest-base PATH   Guest results base (default: $GUEST_BASE)
  --host-out PATH     Host output base (default: $HOST_OUT)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --disk-image) DISK_IMAGE="$2"; shift 2 ;;
    --run-tag) RUN_TAG="$2"; shift 2 ;;
    --mount-dir) MOUNT_DIR="$2"; shift 2 ;;
    --guest-base) GUEST_BASE="$2"; shift 2 ;;
    --host-out) HOST_OUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

if [ ! -f "$DISK_IMAGE" ]; then
  echo "Disk image not found: $DISK_IMAGE" >&2
  exit 1
fi

if ! command -v sudo >/dev/null 2>&1 && [ "$EUID" -ne 0 ]; then
  echo "sudo not found and not running as root." >&2
  exit 1
fi

SUDO=""
if [ "$EUID" -ne 0 ]; then
  SUDO="sudo"
fi

$SUDO mkdir -p "$MOUNT_DIR"
$SUDO mkdir -p "$HOST_OUT"

cleanup() {
  set +e
  if mountpoint -q "$MOUNT_DIR"; then
    $SUDO umount "$MOUNT_DIR"
  fi
  if [ -n "$LOOP_DEV" ]; then
    $SUDO losetup -d "$LOOP_DEV" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# Attach loop device with partition scan, then mount the first partition if present.
LOOP_DEV=$($SUDO losetup --find --show --partscan "$DISK_IMAGE")
MOUNT_SRC="$LOOP_DEV"
if [ -b "${LOOP_DEV}p1" ]; then
  MOUNT_SRC="${LOOP_DEV}p1"
fi

$SUDO mount "$MOUNT_SRC" "$MOUNT_DIR"

SRC="$MOUNT_DIR/$GUEST_BASE"
if [ -n "$RUN_TAG" ]; then
  SRC="$SRC/$RUN_TAG"
fi

if [ ! -d "$SRC" ]; then
  echo "No results found at $SRC" >&2
  echo "Debug: listing $MOUNT_DIR/root/SimpleSSD_Gem5_simulation/results" >&2
  $SUDO ls -la "$MOUNT_DIR/root/SimpleSSD_Gem5_simulation/results" 2>/dev/null || true
  echo "Debug: searching for phase1_runs in image..." >&2
  $SUDO find "$MOUNT_DIR" -maxdepth 6 -type d -path "*/results/phase1_runs" 2>/dev/null || true
  echo "Debug: searching for phase1_results.csv in image..." >&2
  $SUDO find "$MOUNT_DIR" -maxdepth 8 -type f -name "phase1_results.csv" 2>/dev/null || true
  exit 1
fi

if ! $SUDO find "$SRC" -type f -name "phase1_results.csv" -print -quit 2>/dev/null | grep -q .; then
  echo "Warning: no phase1_results.csv found under $SRC." >&2
  echo "Debug: files under $SRC:" >&2
  $SUDO find "$SRC" -maxdepth 4 -type f 2>/dev/null || true
fi

$SUDO cp -a "$SRC/." "$HOST_OUT/"

echo "Extracted results to $HOST_OUT"
