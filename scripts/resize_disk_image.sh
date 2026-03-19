#!/usr/bin/env bash
set -euo pipefail

# Resize the gem5 disk image and expand its filesystem.
# Requires qemu-img and root/sudo for partition/filesystem resizing.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

DISK_IMAGE=${DISK_IMAGE:-"$ROOT_DIR/assets/x86-ubuntu.img"}
NEW_SIZE=${NEW_SIZE:-"8G"}
LOOP_DEV=""

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --disk-image PATH   Disk image path (default: $DISK_IMAGE)
  --size SIZE         New size (qemu-img format, e.g. 8G or +4G) (default: $NEW_SIZE)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --disk-image) DISK_IMAGE="$2"; shift 2 ;;
    --size) NEW_SIZE="$2"; shift 2 ;;
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

if ! command -v qemu-img >/dev/null 2>&1; then
  echo "qemu-img not found. Install qemu-utils." >&2
  exit 1
fi

cleanup() {
  set +e
  if [ -n "$LOOP_DEV" ]; then
    $SUDO losetup -d "$LOOP_DEV" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "Resizing image to $NEW_SIZE: $DISK_IMAGE"
qemu-img resize "$DISK_IMAGE" "$NEW_SIZE"

LOOP_DEV=$($SUDO losetup --find --show --partscan "$DISK_IMAGE")
PART_DEV="${LOOP_DEV}p1"
if [ ! -b "$PART_DEV" ]; then
  echo "Partition device not found: $PART_DEV" >&2
  exit 1
fi

# Grow partition to fill the image.
if command -v growpart >/dev/null 2>&1; then
  $SUDO growpart "$LOOP_DEV" 1
elif command -v parted >/dev/null 2>&1; then
  $SUDO parted -s "$LOOP_DEV" resizepart 1 100%
  $SUDO partprobe "$LOOP_DEV" || true
else
  echo "Neither growpart nor parted is available to resize the partition." >&2
  echo "Install cloud-guest-utils (growpart) or parted and retry." >&2
  exit 1
fi

# Check and expand filesystem.
$SUDO e2fsck -f "$PART_DEV"
$SUDO resize2fs "$PART_DEV"

echo "Resize complete: $DISK_IMAGE"
