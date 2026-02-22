#!/usr/bin/env bash
set -euo pipefail

# Bake the host repo into the gem5 disk image.
# Requires sudo/root to mount the image.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

DISK_IMAGE=${DISK_IMAGE:-"$ROOT_DIR/assets/x86-ubuntu.img"}
SRC_REPO=${SRC_REPO:-"$ROOT_DIR"}
DST_PATH=${DST_PATH:-"/root/SimpleSSD_Gem5_simulation"}
MOUNT_DIR=${MOUNT_DIR:-"/mnt/gem5_img"}

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --disk-image PATH   Disk image path (default: $DISK_IMAGE)
  --src-repo PATH     Source repo path (default: $SRC_REPO)
  --dst-path PATH     Destination path inside image (default: $DST_PATH)
  --mount-dir PATH    Temporary mount point (default: $MOUNT_DIR)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --disk-image) DISK_IMAGE="$2"; shift 2 ;;
    --src-repo) SRC_REPO="$2"; shift 2 ;;
    --dst-path) DST_PATH="$2"; shift 2 ;;
    --mount-dir) MOUNT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

if [ ! -f "$DISK_IMAGE" ]; then
  echo "Disk image not found: $DISK_IMAGE" >&2
  exit 1
fi

if [ ! -d "$SRC_REPO" ]; then
  echo "Source repo not found: $SRC_REPO" >&2
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

cleanup() {
  set +e
  if mountpoint -q "$MOUNT_DIR"; then
    $SUDO umount "$MOUNT_DIR"
  fi
}
trap cleanup EXIT

$SUDO mount -o loop "$DISK_IMAGE" "$MOUNT_DIR"
$SUDO mkdir -p "$MOUNT_DIR/$(dirname "$DST_PATH")"
$SUDO rm -rf "$MOUNT_DIR/$DST_PATH"
$SUDO mkdir -p "$MOUNT_DIR/$DST_PATH"

# Copy repo contents into the image (preserve permissions).
$SUDO cp -a "$SRC_REPO/." "$MOUNT_DIR/$DST_PATH/"

# Ensure root owns the tree inside the image.
$SUDO chown -R root:root "$MOUNT_DIR/$DST_PATH"

echo "Baked repo into image at $DST_PATH"
