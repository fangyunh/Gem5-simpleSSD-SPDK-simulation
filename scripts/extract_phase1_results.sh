#!/usr/bin/env bash
set -euo pipefail

# Extract phase1 results from the gem5 disk image back to the host.
# Requires sudo/root to mount the image.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

DISK_IMAGE=${DISK_IMAGE:-"$ROOT_DIR/assets/x86-ubuntu.img"}
RUN_TAG=${RUN_TAG:-""}
MOUNT_DIR=${MOUNT_DIR:-"/mnt/gem5_img"}
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
}
trap cleanup EXIT

$SUDO mount -o loop "$DISK_IMAGE" "$MOUNT_DIR"

SRC="$MOUNT_DIR/$GUEST_BASE"
if [ -n "$RUN_TAG" ]; then
  SRC="$SRC/$RUN_TAG"
fi

if [ ! -d "$SRC" ]; then
  echo "No results found at $SRC" >&2
  exit 1
fi

$SUDO cp -a "$SRC/." "$HOST_OUT/"

echo "Extracted results to $HOST_OUT"
