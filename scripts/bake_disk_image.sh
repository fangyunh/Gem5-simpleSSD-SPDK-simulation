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
COPY_OPENSSL3=${COPY_OPENSSL3:-1}
COPY_OPENSSL11=${COPY_OPENSSL11:-1}
DOCKER_OUT_DIR=${DOCKER_OUT_DIR:-"$ROOT_DIR/docker_artifacts"}
OPENSSL11_DIR=${OPENSSL11_DIR:-"$DOCKER_OUT_DIR/guest_openssl11"}
COPY_FUSE3=${COPY_FUSE3:-1}
COPY_LIBAIO=${COPY_LIBAIO:-1}
COPY_SPDK_BIN=${COPY_SPDK_BIN:-1}
SPDK_BIN_SRC=${SPDK_BIN_SRC:-"$DOCKER_OUT_DIR/guest_spdk_nvme_perf"}
KERNEL_MODULES_DIR=${KERNEL_MODULES_DIR:-""}
KERNEL_VERSION=${KERNEL_VERSION:-""}
LOOP_DEV=""
EXCLUDES=(
  ".git"
  "logs"
  "results"
  "SimpleSSD-FullSystem/tests"
  "SimpleSSD-FullSystem/util"
  "assets/x86-ubuntu.img"
)

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --disk-image PATH   Disk image path (default: $DISK_IMAGE)
  --src-repo PATH     Source repo path (default: $SRC_REPO)
  --dst-path PATH     Destination path inside image (default: $DST_PATH)
  --mount-dir PATH    Temporary mount point (default: $MOUNT_DIR)
  --copy-openssl3 0|1 Copy host OpenSSL 3 libs into image (default: $COPY_OPENSSL3)
  --copy-openssl11 DIR Copy OpenSSL 1.1.1 libs from DIR into image (default: $OPENSSL11_DIR)
  --enable-openssl11 0|1 Enable OpenSSL 1.1.1 copy (default: $COPY_OPENSSL11)
  --copy-fuse3 0|1    Copy host FUSE3 libs into image (default: $COPY_FUSE3)
  --copy-libaio 0|1   Copy host libaio libs into image (default: $COPY_LIBAIO)
  --copy-spdk-bin P   Copy guest-compatible spdk_nvme_perf into image (default: $SPDK_BIN_SRC)
  --enable-spdk-bin 0|1 Enable spdk_nvme_perf copy (default: $COPY_SPDK_BIN)
  --copy-kernel-modules DIR Copy kernel modules staging dir into image (default: $KERNEL_MODULES_DIR)
  --kernel-version VER Kernel version for modules path (default: $KERNEL_VERSION)
  --exclude PATTERN   Exclude path (can be repeated)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --disk-image) DISK_IMAGE="$2"; shift 2 ;;
    --src-repo) SRC_REPO="$2"; shift 2 ;;
    --dst-path) DST_PATH="$2"; shift 2 ;;
    --mount-dir) MOUNT_DIR="$2"; shift 2 ;;
    --copy-openssl3) COPY_OPENSSL3="$2"; shift 2 ;;
    --copy-openssl11) OPENSSL11_DIR="$2"; shift 2 ;;
    --enable-openssl11) COPY_OPENSSL11="$2"; shift 2 ;;
    --copy-fuse3) COPY_FUSE3="$2"; shift 2 ;;
    --copy-libaio) COPY_LIBAIO="$2"; shift 2 ;;
    --copy-spdk-bin) SPDK_BIN_SRC="$2"; shift 2 ;;
    --enable-spdk-bin) COPY_SPDK_BIN="$2"; shift 2 ;;
    --copy-kernel-modules) KERNEL_MODULES_DIR="$2"; shift 2 ;;
    --kernel-version) KERNEL_VERSION="$2"; shift 2 ;;
    --exclude) EXCLUDES+=("$2"); shift 2 ;;
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
$SUDO mkdir -p "$MOUNT_DIR/$(dirname "$DST_PATH")"
$SUDO rm -rf "$MOUNT_DIR/$DST_PATH"
$SUDO mkdir -p "$MOUNT_DIR/$DST_PATH"

# Copy repo contents into the image (preserve permissions).
if ! command -v rsync >/dev/null 2>&1; then
  echo "rsync not found. Install rsync to use exclude patterns." >&2
  exit 1
fi

RSYNC_EXCLUDES=()
for pattern in "${EXCLUDES[@]}"; do
  RSYNC_EXCLUDES+=("--exclude=$pattern")
done

$SUDO rsync -a --delete "${RSYNC_EXCLUDES[@]}" "$SRC_REPO/" "$MOUNT_DIR/$DST_PATH/"

# Ensure root owns the tree inside the image.
$SUDO chown -R root:root "$MOUNT_DIR/$DST_PATH"

copy_openssl3() {
  local ssl_src=""
  local crypto_src=""
  local candidates=(
    "/usr/lib/x86_64-linux-gnu/libssl.so.3"
    "/usr/local/lib/libssl.so.3"
  )
  local crypto_candidates=(
    "/usr/lib/x86_64-linux-gnu/libcrypto.so.3"
    "/usr/local/lib/libcrypto.so.3"
  )

  for path in "${candidates[@]}"; do
    if [ -f "$path" ]; then
      ssl_src="$path"
      break
    fi
  done

  for path in "${crypto_candidates[@]}"; do
    if [ -f "$path" ]; then
      crypto_src="$path"
      break
    fi
  done

  if [ -z "$ssl_src" ] || [ -z "$crypto_src" ]; then
    echo "OpenSSL 3 libs not found on host; skipping copy." >&2
    return 0
  fi

  echo "Copying OpenSSL3 libs into image from $ssl_src and $crypto_src"
  $SUDO mkdir -p "$MOUNT_DIR/usr/lib/x86_64-linux-gnu" "$MOUNT_DIR/usr/local/lib"
  $SUDO cp -a "$ssl_src" "$MOUNT_DIR/usr/lib/x86_64-linux-gnu/"
  $SUDO cp -a "$crypto_src" "$MOUNT_DIR/usr/lib/x86_64-linux-gnu/"
  $SUDO cp -a "$ssl_src" "$MOUNT_DIR/usr/local/lib/"
  $SUDO cp -a "$crypto_src" "$MOUNT_DIR/usr/local/lib/"
  $SUDO mkdir -p "$MOUNT_DIR/etc/ld.so.conf.d"
  echo "/usr/local/lib" | $SUDO tee "$MOUNT_DIR/etc/ld.so.conf.d/openssl3.conf" >/dev/null

  if [ -x "$MOUNT_DIR/sbin/ldconfig" ]; then
    $SUDO chroot "$MOUNT_DIR" /sbin/ldconfig || true
  fi

  if [ ! -f "$MOUNT_DIR/usr/lib/x86_64-linux-gnu/libssl.so.3" ]; then
    echo "Warning: libssl.so.3 not found in image after copy." >&2
  fi
  if [ ! -f "$MOUNT_DIR/usr/lib/x86_64-linux-gnu/libcrypto.so.3" ]; then
    echo "Warning: libcrypto.so.3 not found in image after copy." >&2
  fi
}

copy_openssl11_from_dir() {
  if [ -z "$OPENSSL11_DIR" ]; then
    return 0
  fi
  if [ ! -d "$OPENSSL11_DIR" ]; then
    echo "OpenSSL 1.1.1 dir not found: $OPENSSL11_DIR" >&2
    return 1
  fi

  local ssl_src="$OPENSSL11_DIR/libssl.so.1.1"
  local crypto_src="$OPENSSL11_DIR/libcrypto.so.1.1"

  if [ ! -f "$ssl_src" ] || [ ! -f "$crypto_src" ]; then
    echo "OpenSSL 1.1.1 libs not found in $OPENSSL11_DIR" >&2
    return 1
  fi

  echo "Copying OpenSSL 1.1.1 libs into image from $OPENSSL11_DIR"
  $SUDO mkdir -p "$MOUNT_DIR/usr/lib/x86_64-linux-gnu" "$MOUNT_DIR/usr/local/lib"
  $SUDO cp -a "$ssl_src" "$MOUNT_DIR/usr/lib/x86_64-linux-gnu/"
  $SUDO cp -a "$crypto_src" "$MOUNT_DIR/usr/lib/x86_64-linux-gnu/"
  $SUDO cp -a "$ssl_src" "$MOUNT_DIR/usr/local/lib/"
  $SUDO cp -a "$crypto_src" "$MOUNT_DIR/usr/local/lib/"
  $SUDO mkdir -p "$MOUNT_DIR/etc/ld.so.conf.d"
  echo "/usr/local/lib" | $SUDO tee "$MOUNT_DIR/etc/ld.so.conf.d/openssl11.conf" >/dev/null

  if [ -x "$MOUNT_DIR/sbin/ldconfig" ]; then
    $SUDO chroot "$MOUNT_DIR" /sbin/ldconfig || true
  fi

  if [ ! -f "$MOUNT_DIR/usr/lib/x86_64-linux-gnu/libssl.so.1.1" ]; then
    echo "Warning: libssl.so.1.1 not found in image after copy." >&2
  fi
  if [ ! -f "$MOUNT_DIR/usr/lib/x86_64-linux-gnu/libcrypto.so.1.1" ]; then
    echo "Warning: libcrypto.so.1.1 not found in image after copy." >&2
  fi
}

copy_fuse3() {
  local fuse_src=""
  local fuse_real=""
  local candidates=(
    "/usr/lib/x86_64-linux-gnu/libfuse3.so.3"
    "/usr/local/lib/libfuse3.so.3"
  )

  for path in "${candidates[@]}"; do
    if [ -f "$path" ]; then
      fuse_src="$path"
      break
    fi
  done

  if [ -z "$fuse_src" ]; then
    echo "FUSE3 libs not found on host; skipping copy." >&2
    return 0
  fi

  fuse_real=$(readlink -f "$fuse_src" 2>/dev/null || true)
  if [ -z "$fuse_real" ]; then
    fuse_real="$fuse_src"
  fi

  echo "Copying FUSE3 lib into image from $fuse_src"
  $SUDO mkdir -p "$MOUNT_DIR/usr/lib/x86_64-linux-gnu" "$MOUNT_DIR/usr/local/lib"
  $SUDO cp -a "$fuse_src" "$MOUNT_DIR/usr/lib/x86_64-linux-gnu/"
  $SUDO cp -a "$fuse_src" "$MOUNT_DIR/usr/local/lib/"
  if [ "$fuse_real" != "$fuse_src" ]; then
    $SUDO cp -a "$fuse_real" "$MOUNT_DIR/usr/lib/x86_64-linux-gnu/"
    $SUDO cp -a "$fuse_real" "$MOUNT_DIR/usr/local/lib/"
  fi
  $SUDO mkdir -p "$MOUNT_DIR/etc/ld.so.conf.d"
  echo "/usr/local/lib" | $SUDO tee "$MOUNT_DIR/etc/ld.so.conf.d/fuse3.conf" >/dev/null

  if [ -x "$MOUNT_DIR/sbin/ldconfig" ]; then
    $SUDO chroot "$MOUNT_DIR" /sbin/ldconfig || true
  fi

  if [ ! -f "$MOUNT_DIR/usr/lib/x86_64-linux-gnu/libfuse3.so.3" ]; then
    echo "Warning: libfuse3.so.3 not found in image after copy." >&2
  fi
  if [ -n "$fuse_real" ] && [ ! -f "$MOUNT_DIR/usr/lib/x86_64-linux-gnu/$(basename "$fuse_real")" ]; then
    echo "Warning: $(basename "$fuse_real") not found in image after copy." >&2
  fi
}

copy_libaio() {
  local aio_src=""
  local aio_real=""
  local candidates=(
    "/usr/lib/x86_64-linux-gnu/libaio.so.1t64"
    "/usr/lib/x86_64-linux-gnu/libaio.so.1"
    "/usr/local/lib/libaio.so.1t64"
    "/usr/local/lib/libaio.so.1"
  )

  for path in "${candidates[@]}"; do
    if [ -f "$path" ]; then
      aio_src="$path"
      break
    fi
  done

  if [ -z "$aio_src" ]; then
    echo "libaio not found on host; skipping copy." >&2
    return 0
  fi

  aio_real=$(readlink -f "$aio_src" 2>/dev/null || true)
  if [ -z "$aio_real" ]; then
    aio_real="$aio_src"
  fi

  echo "Copying libaio into image from $aio_src"
  $SUDO mkdir -p "$MOUNT_DIR/usr/lib/x86_64-linux-gnu" "$MOUNT_DIR/usr/local/lib"
  $SUDO cp -a "$aio_src" "$MOUNT_DIR/usr/lib/x86_64-linux-gnu/"
  $SUDO cp -a "$aio_src" "$MOUNT_DIR/usr/local/lib/"
  if [ "$aio_real" != "$aio_src" ]; then
    $SUDO cp -a "$aio_real" "$MOUNT_DIR/usr/lib/x86_64-linux-gnu/"
    $SUDO cp -a "$aio_real" "$MOUNT_DIR/usr/local/lib/"
  fi

  # If the host only has libaio.so.1t64, add a compatibility symlink.
  if [ ! -f "$MOUNT_DIR/usr/lib/x86_64-linux-gnu/libaio.so.1" ] && \
     [ -f "$MOUNT_DIR/usr/lib/x86_64-linux-gnu/libaio.so.1t64" ]; then
    $SUDO ln -sf libaio.so.1t64 "$MOUNT_DIR/usr/lib/x86_64-linux-gnu/libaio.so.1"
  fi
  if [ ! -f "$MOUNT_DIR/usr/local/lib/libaio.so.1" ] && \
     [ -f "$MOUNT_DIR/usr/local/lib/libaio.so.1t64" ]; then
    $SUDO ln -sf libaio.so.1t64 "$MOUNT_DIR/usr/local/lib/libaio.so.1"
  fi

  if [ -x "$MOUNT_DIR/sbin/ldconfig" ]; then
    $SUDO chroot "$MOUNT_DIR" /sbin/ldconfig || true
  fi

  if [ ! -f "$MOUNT_DIR/usr/lib/x86_64-linux-gnu/$(basename "$aio_src")" ]; then
    echo "Warning: $(basename "$aio_src") not found in image after copy." >&2
  fi
  if [ -n "$aio_real" ] && [ ! -f "$MOUNT_DIR/usr/lib/x86_64-linux-gnu/$(basename "$aio_real")" ]; then
    echo "Warning: $(basename "$aio_real") not found in image after copy." >&2
  fi
}

copy_kernel_modules() {
  if [ -z "$KERNEL_MODULES_DIR" ] || [ -z "$KERNEL_VERSION" ]; then
    return 0
  fi

  local src="$KERNEL_MODULES_DIR/lib/modules/$KERNEL_VERSION"
  if [ ! -d "$src" ]; then
    echo "Kernel modules not found: $src" >&2
    return 1
  fi

  echo "Copying kernel modules for $KERNEL_VERSION into image from $KERNEL_MODULES_DIR"
  $SUDO rm -rf "$MOUNT_DIR/lib/modules/$KERNEL_VERSION"
  $SUDO mkdir -p "$MOUNT_DIR/lib/modules"
  $SUDO cp -a "$src" "$MOUNT_DIR/lib/modules/"

  if [ -x "$MOUNT_DIR/sbin/depmod" ]; then
    $SUDO chroot "$MOUNT_DIR" /sbin/depmod "$KERNEL_VERSION" || true
  fi
}

if [ "$COPY_OPENSSL3" -eq 1 ]; then
  copy_openssl3
fi

if [ "$COPY_OPENSSL11" -eq 1 ] && [ -n "$OPENSSL11_DIR" ]; then
  copy_openssl11_from_dir
fi

if [ "$COPY_FUSE3" -eq 1 ]; then
  copy_fuse3
fi

if [ "$COPY_LIBAIO" -eq 1 ]; then
  copy_libaio
fi

copy_kernel_modules

if [ "$COPY_SPDK_BIN" -eq 1 ] && [ -n "$SPDK_BIN_SRC" ]; then
  if [ ! -f "$SPDK_BIN_SRC" ]; then
    echo "SPDK binary not found: $SPDK_BIN_SRC" >&2
  else
    echo "Copying spdk_nvme_perf into image from $SPDK_BIN_SRC"
    $SUDO mkdir -p "$MOUNT_DIR/$DST_PATH/spdk/build/bin"
    $SUDO cp -a "$SPDK_BIN_SRC" "$MOUNT_DIR/$DST_PATH/spdk/build/bin/spdk_nvme_perf"
    $SUDO chmod +x "$MOUNT_DIR/$DST_PATH/spdk/build/bin/spdk_nvme_perf"
  fi
fi

echo "Baked repo into image at $DST_PATH"
