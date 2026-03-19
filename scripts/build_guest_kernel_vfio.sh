#!/usr/bin/env bash
set -euo pipefail

# Build a guest kernel with VFIO/UIO and virtio-9p support.
# This enables no-bake/no-extract workflow (host 9p share + SPDK binding).

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

KERNEL_VERSION=${KERNEL_VERSION:-"5.4.49"}
KERNEL_URL=${KERNEL_URL:-"https://cdn.kernel.org/pub/linux/kernel/v5.x/linux-${KERNEL_VERSION}.tar.xz"}
KERNEL_SRC=${KERNEL_SRC:-"$ROOT_DIR/kernel/linux-${KERNEL_VERSION}"}
OUT_DIR=${OUT_DIR:-"$ROOT_DIR/kernel_build/${KERNEL_VERSION}"}
VMLINUX_IN=${VMLINUX_IN:-"$ROOT_DIR/assets/vmlinux-${KERNEL_VERSION}"}
KCONFIG_IN=${KCONFIG_IN:-""}
VMLINUX_OUT=${VMLINUX_OUT:-"$ROOT_DIR/assets/vmlinux-${KERNEL_VERSION}"}
MODULES_OUT=${MODULES_OUT:-"$ROOT_DIR/kernel_modules/${KERNEL_VERSION}"}
JOBS=${JOBS:-"$(nproc)"}
BUILTIN_ONLY=0

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --kernel-version VER   Kernel version (default: $KERNEL_VERSION)
  --kernel-url URL       Kernel tarball URL (default: $KERNEL_URL)
  --kernel-src PATH      Kernel source path (default: $KERNEL_SRC)
  --out-dir PATH         Build output dir (default: $OUT_DIR)
  --vmlinux-in PATH      Existing vmlinux to extract config from (default: $VMLINUX_IN)
  --config PATH          Kernel .config to use (default: empty)
  --vmlinux-out PATH     Output vmlinux path (default: $VMLINUX_OUT)
  --modules-out PATH     Output modules staging dir (default: $MODULES_OUT)
  --builtin              Build VFIO/UIO as built-ins and skip modules_install
  --jobs N               Build parallelism (default: $JOBS)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kernel-version) KERNEL_VERSION="$2"; shift 2 ;;
    --kernel-url) KERNEL_URL="$2"; shift 2 ;;
    --kernel-src) KERNEL_SRC="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --vmlinux-in) VMLINUX_IN="$2"; shift 2 ;;
    --config) KCONFIG_IN="$2"; shift 2 ;;
    --vmlinux-out) VMLINUX_OUT="$2"; shift 2 ;;
    --modules-out) MODULES_OUT="$2"; shift 2 ;;
    --builtin) BUILTIN_ONLY=1; shift 1 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

mkdir -p "$OUT_DIR"
if [ "$BUILTIN_ONLY" -eq 0 ]; then
  mkdir -p "$MODULES_OUT"
fi

# Resolve all paths to absolute.  The kernel top-level Makefile converts O=
# relative to its own source directory, not the caller's cwd.  Using absolute
# paths ensures that 'make O=...' and scripts/config --file operate on the
# exact same .config file.
_abs() { local p="$1"; [[ "$p" == /* ]] && echo "$p" || echo "$PWD/$p"; }
OUT_DIR=$(cd "$OUT_DIR" && pwd)
KERNEL_SRC=$(_abs "$KERNEL_SRC")
VMLINUX_OUT=$(_abs "$VMLINUX_OUT")
VMLINUX_IN=$(_abs "$VMLINUX_IN")
MODULES_OUT=$(_abs "$MODULES_OUT")
[ -n "$KCONFIG_IN" ] && KCONFIG_IN=$(_abs "$KCONFIG_IN")

if [ ! -d "$KERNEL_SRC" ]; then
  echo "Kernel source not found at $KERNEL_SRC; downloading $KERNEL_URL"
  mkdir -p "$(dirname "$KERNEL_SRC")"
  curl -L "$KERNEL_URL" | tar -xJ -C "$(dirname "$KERNEL_SRC")"
fi

if [ -n "$KCONFIG_IN" ]; then
  if [ ! -f "$KCONFIG_IN" ]; then
    echo "Kernel config not found: $KCONFIG_IN" >&2
    exit 1
  fi
  # Skip copy if source and destination are the same file (e.g. --config and
  # --out-dir both point to kernel_build/<ver>/).
  if [ "$(realpath "$KCONFIG_IN")" != "$(realpath "$OUT_DIR/.config" 2>/dev/null || echo "")" ]; then
    cp "$KCONFIG_IN" "$OUT_DIR/.config"
  fi
else
  if [ ! -f "$VMLINUX_IN" ]; then
    echo "VMLINUX not found for config extraction: $VMLINUX_IN" >&2
    echo "Provide --config PATH to a valid kernel .config." >&2
    exit 1
  fi
  if [ ! -x "$KERNEL_SRC/scripts/extract-ikconfig" ]; then
    echo "Missing extract-ikconfig at $KERNEL_SRC/scripts/extract-ikconfig" >&2
    exit 1
  fi
  "$KERNEL_SRC/scripts/extract-ikconfig" "$VMLINUX_IN" > "$OUT_DIR/.config" || true
  if [ ! -s "$OUT_DIR/.config" ]; then
    echo "Failed to extract kernel config from $VMLINUX_IN" >&2
    echo "Provide --config PATH to a valid kernel .config." >&2
    exit 1
  fi
fi

KCONFIG_NONINTERACTIVE=1 make -C "$KERNEL_SRC" O="$OUT_DIR" olddefconfig

# Enable required modules for SPDK setup.sh and avoid objtool stack validation.
if [ ! -x "$KERNEL_SRC/scripts/config" ]; then
  echo "Missing scripts/config at $KERNEL_SRC/scripts/config" >&2
  exit 1
fi

echo "Using kernel source: $KERNEL_SRC"
echo "Using kernel config: $OUT_DIR/.config"

"$KERNEL_SRC/scripts/config" --file "$OUT_DIR/.config" \
  -e IOMMU_API \
  -d STACK_VALIDATION \
  -d UNWINDER_ORC \
  -e UNWINDER_FRAME_POINTER

if [ "$BUILTIN_ONLY" -eq 1 ]; then
  "$KERNEL_SRC/scripts/config" --file "$OUT_DIR/.config" \
    -e PCI \
    -e VIRTIO \
    -e VIRTIO_PCI \
    -e NETWORK_FILESYSTEMS \
    -e NET_9P \
    -e NET_9P_VIRTIO \
    -e 9P_FS \
    -e 9P_FS_POSIX_ACL \
    -d 9P_FSCACHE \
    -e FUSE_FS \
    -e HUGETLBFS \
    -e HUGETLB_PAGE \
    -e INTEL_IOMMU \
    -e VFIO \
    -e VFIO_PCI \
    -e VFIO_IOMMU_TYPE1 \
    -e VFIO_NOIOMMU \
    -e UIO \
    -e UIO_PCI_GENERIC
else
  "$KERNEL_SRC/scripts/config" --file "$OUT_DIR/.config" \
    -e PCI \
    -e VIRTIO \
    -e NETWORK_FILESYSTEMS \
    -m VIRTIO_PCI \
    -m NET_9P \
    -m NET_9P_VIRTIO \
    -m 9P_FS \
    -m 9P_FS_POSIX_ACL \
    -d 9P_FSCACHE \
    -e FUSE_FS \
    -e HUGETLBFS \
    -e HUGETLB_PAGE \
    -m VFIO \
    -m VFIO_PCI \
    -m VFIO_IOMMU_TYPE1 \
    -e VFIO_NOIOMMU \
    -m UIO \
    -m UIO_PCI_GENERIC
fi

# Refresh config defaults non-interactively, then re-apply stack validation off.
set +o pipefail
yes "" | KCONFIG_NONINTERACTIVE=1 make -C "$KERNEL_SRC" O="$OUT_DIR" olddefconfig
set -o pipefail

"$KERNEL_SRC/scripts/config" --file "$OUT_DIR/.config" \
  -d STACK_VALIDATION \
  -d UNWINDER_ORC \
  -e UNWINDER_FRAME_POINTER \
  --set-str SYSTEM_TRUSTED_KEYS "" \
  --set-str SYSTEM_REVOCATION_KEYS ""

if [ "$BUILTIN_ONLY" -eq 1 ]; then
  KCONFIG_NONINTERACTIVE=1 make -C "$KERNEL_SRC" O="$OUT_DIR" -j"$JOBS" \
    WERROR=0 HOSTCFLAGS="-Wno-error=use-after-free" \
    SKIP_STACK_VALIDATION=1 \
    vmlinux
else
  # Build vmlinux and modules.
  KCONFIG_NONINTERACTIVE=1 make -C "$KERNEL_SRC" O="$OUT_DIR" -j"$JOBS" \
    WERROR=0 HOSTCFLAGS="-Wno-error=use-after-free" \
    SKIP_STACK_VALIDATION=1 \
    vmlinux modules

  # Install modules into staging dir.
  KCONFIG_NONINTERACTIVE=1 make -C "$KERNEL_SRC" O="$OUT_DIR" \
    WERROR=0 HOSTCFLAGS="-Wno-error=use-after-free" \
    modules_install INSTALL_MOD_PATH="$MODULES_OUT" LOCALVERSION=
fi

# Copy vmlinux for gem5.
rm -f "$VMLINUX_OUT" 2>/dev/null || true
cp "$OUT_DIR/vmlinux" "$VMLINUX_OUT"

echo "Built vmlinux: $VMLINUX_OUT"
if [ "$BUILTIN_ONLY" -eq 0 ]; then
  echo "Installed modules under: $MODULES_OUT/lib/modules"
else
  echo "Built-in drivers enabled; no modules_install performed."
fi
