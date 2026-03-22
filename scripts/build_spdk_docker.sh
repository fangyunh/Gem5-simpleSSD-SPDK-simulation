#!/usr/bin/env bash
set -euo pipefail

# Build spdk_nvme_perf inside Ubuntu 18.04 (glibc 2.27) using Docker.
# Output: docker_artifacts/guest_spdk_nvme_perf (or --output path).

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

DOCKER_IMAGE=${DOCKER_IMAGE:-"ubuntu:18.04"}
SPDK_DIR_IN_CONTAINER=${SPDK_DIR_IN_CONTAINER:-"/work/spdk"}
DOCKER_OUT_DIR=${DOCKER_OUT_DIR:-"$ROOT_DIR/docker_artifacts"}
SPDK_TARGET_ARCH=${SPDK_TARGET_ARCH:-"x86-64"}
DPDK_PLATFORM=${DPDK_PLATFORM:-"generic"}
DPDK_EXTRA_CFLAGS=${DPDK_EXTRA_CFLAGS:-"-mno-ssse3 -mno-sse4.1 -mno-sse4.2 -mno-avx -mno-avx2 -mno-avx512f"}
SPDK_CONFIGURE_FLAGS=${SPDK_CONFIGURE_FLAGS:-"--disable-tests --disable-unit-tests --disable-examples"}
DPDK_ENABLE_LIBS_DEFAULT="eal,hash,log,mbuf,mempool,pci,ring,argparse,cmdline,ethdev,kvargs,meter,net,rcu,stack,telemetry,power,timer,vhost,cryptodev,dmadev"
DPDK_ENABLE_LIBS=${DPDK_ENABLE_LIBS:-"$DPDK_ENABLE_LIBS_DEFAULT"}
DPDK_DISABLE_LIBS=${DPDK_DISABLE_LIBS:-""}
OUTPUT_BIN_DEFAULT="$DOCKER_OUT_DIR/guest_spdk_nvme_perf"
OPENSSL11_OUT_DEFAULT="$DOCKER_OUT_DIR/guest_openssl11"
OUTPUT_BIN=${OUTPUT_BIN:-"$OUTPUT_BIN_DEFAULT"}
OPENSSL11_OUT=${OPENSSL11_OUT:-"$OPENSSL11_OUT_DEFAULT"}
OUTPUT_BIN_SET=0
OPENSSL11_OUT_SET=0

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --image NAME      Docker image to use (default: $DOCKER_IMAGE)
  --output PATH     Output binary path on host (default: $OUTPUT_BIN)
  --openssl11-out PATH  Output dir for libssl.so.1.1/libcrypto.so.1.1 (default: $OPENSSL11_OUT)
  --artifacts-dir PATH  Output dir for docker artifacts (default: $DOCKER_OUT_DIR)
  --spdk-arch ARCH  SPDK target arch (default: $SPDK_TARGET_ARCH)
  --dpdk-platform P DPDK platform (default: $DPDK_PLATFORM)
  --dpdk-extra-cflags "CFLAGS" Extra DPDK CFLAGS (default: $DPDK_EXTRA_CFLAGS)
  --configure-flags "FLAGS" Extra SPDK configure flags (default: $SPDK_CONFIGURE_FLAGS)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) DOCKER_IMAGE="$2"; shift 2 ;;
    --output) OUTPUT_BIN="$2"; OUTPUT_BIN_SET=1; shift 2 ;;
    --openssl11-out) OPENSSL11_OUT="$2"; OPENSSL11_OUT_SET=1; shift 2 ;;
    --artifacts-dir) DOCKER_OUT_DIR="$2"; shift 2 ;;
    --spdk-arch) SPDK_TARGET_ARCH="$2"; shift 2 ;;
    --dpdk-platform) DPDK_PLATFORM="$2"; shift 2 ;;
    --dpdk-extra-cflags) DPDK_EXTRA_CFLAGS="$2"; shift 2 ;;
    --configure-flags) SPDK_CONFIGURE_FLAGS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

if [ "$OUTPUT_BIN_SET" -eq 0 ]; then
  OUTPUT_BIN="$DOCKER_OUT_DIR/guest_spdk_nvme_perf"
fi
if [ "$OPENSSL11_OUT_SET" -eq 0 ]; then
  OPENSSL11_OUT="$DOCKER_OUT_DIR/guest_openssl11"
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found. Install Docker or use a compatible container runtime." >&2
  exit 1
fi

if [ ! -d "$ROOT_DIR/spdk" ]; then
  echo "SPDK repo not found at $ROOT_DIR/spdk" >&2
  exit 1
fi

echo "Building spdk_nvme_perf in Docker image: $DOCKER_IMAGE"
echo "Output binary: $OUTPUT_BIN"
echo "OpenSSL 1.1.1 libs output dir: $OPENSSL11_OUT"
echo "Artifacts dir: $DOCKER_OUT_DIR"
echo "SPDK target arch: $SPDK_TARGET_ARCH"
echo "DPDK platform: $DPDK_PLATFORM"
echo "DPDK extra CFLAGS: $DPDK_EXTRA_CFLAGS"
echo "SPDK configure flags: $SPDK_CONFIGURE_FLAGS"

if [[ "$DPDK_EXTRA_CFLAGS" == *"-mno-sse4.1"* ]] || [[ "$DPDK_EXTRA_CFLAGS" == *"-mno-sse4.2"* ]]; then
  # Drop lib/net to avoid SSE4.1 intrinsics when SSE4 is explicitly disabled.
  DPDK_ENABLE_LIBS="${DPDK_ENABLE_LIBS//,net,/,}"
  DPDK_ENABLE_LIBS="${DPDK_ENABLE_LIBS//,net/}"
  DPDK_ENABLE_LIBS="${DPDK_ENABLE_LIBS#net,}"
  DPDK_ENABLE_LIBS="${DPDK_ENABLE_LIBS%,net}"
  if [ -n "$DPDK_DISABLE_LIBS" ]; then
    DPDK_DISABLE_LIBS="$DPDK_DISABLE_LIBS,net"
  else
    DPDK_DISABLE_LIBS="net"
  fi
fi
echo "DPDK enable libs: $DPDK_ENABLE_LIBS"
echo "DPDK disable libs: $DPDK_DISABLE_LIBS"

mkdir -p "$(dirname "$OUTPUT_BIN")"
mkdir -p "$OPENSSL11_OUT"

docker run --rm -t \
  -v "$ROOT_DIR":/work \
  -w "$SPDK_DIR_IN_CONTAINER" \
  -e SPDK_TARGET_ARCH="$SPDK_TARGET_ARCH" \
  -e DPDK_PLATFORM="$DPDK_PLATFORM" \
  -e DPDK_EXTRA_CFLAGS="$DPDK_EXTRA_CFLAGS" \
  -e SPDK_CONFIGURE_FLAGS="$SPDK_CONFIGURE_FLAGS" \
  -e DPDK_ENABLE_LIBS="$DPDK_ENABLE_LIBS" \
  -e DPDK_DISABLE_LIBS="$DPDK_DISABLE_LIBS" \
  "$DOCKER_IMAGE" \
  bash -lc '
    set -e
    apt-get update
    apt-get install -y \
      gcc g++ make build-essential pkg-config \
      python3 python3-pip python3-dev python3-venv python3-pyelftools \
      linux-libc-dev \
      libaio-dev libssl-dev libnuma-dev libjson-c-dev libcmocka-dev libcunit1-dev \
      uuid-dev libiscsi-dev libkeyutils-dev libncurses5-dev libncursesw5-dev \
      libfuse-dev unzip patchelf curl procps \
      ninja-build git ca-certificates \
      nasm autoconf automake libtool help2man systemtap-sdt-dev
    # Avoid scripts/pkgdep.sh on Ubuntu 18.04 since it requests libfuse3-dev.
    python3 -m pip install --no-cache-dir "meson>=0.57.2,<0.58"
# Work around older headers missing MAP_FIXED_NOREPLACE.
python3 - <<'PY'
from pathlib import Path
import re

path = Path("dpdk/lib/eal/unix/eal_unix_memory.c")
text = path.read_text()
lines = text.splitlines()

# Strip any stray '+' prefixes from prior patch attempts.
lines = [re.sub(r"^[ \t]*\+", "", line) for line in lines]

guard = [
  "#ifndef MAP_FIXED_NOREPLACE",
  "#define MAP_FIXED_NOREPLACE 0x100000",
  "#endif",
]

if not any(line.strip() == guard[0] for line in lines):
  out = []
  inserted = False
  for line in lines:
    out.append(line)
    if line.strip() == "#include <sys/mman.h>":
      out.extend(guard)
      inserted = True
  if inserted:
    lines = out

path.write_text("\n".join(lines) + "\n")
PY
# Patch rte_memcpy.h to use plain memcpy (avoid SSSE3 palignr)
python3 - <<'PY_MEMCPY'
from pathlib import Path
import re

path = Path("dpdk/lib/eal/x86/include/rte_memcpy.h")
text = path.read_text()

# Replace the inline rte_memcpy with plain memcpy
new_text = re.sub(
    r"static __rte_always_inline void \*[\n\r]*rte_memcpy.*?\{.*?\}",
    """static __rte_always_inline void *
rte_memcpy(void *dst, const void *src, size_t n)
{
\treturn memcpy(dst, src, n);
}""",
    text,
    count=1,
    flags=re.DOTALL,
)
path.write_text(new_text)
PY_MEMCPY

# Remove SSSE3 from DPDK base_flags so rte_cpu_is_supported() passes
python3 - <<'PY_MESON'
from pathlib import Path

path = Path("dpdk/config/x86/meson.build")
text = path.read_text()

# Remove the line containing \x27ssse3\x27 from base_flags array
lines = text.splitlines()
out = []
for line in lines:
    if "\x27ssse3\x27" in line.lower() or "'ssse3'" in line.lower():
        continue
    out.append(line)
path.write_text("\n".join(out) + "\n")
PY_MESON

    rm -rf build dpdk/build dpdk/build-tmp
    ./configure --without-nvme-cuse --target-arch="$SPDK_TARGET_ARCH" $SPDK_CONFIGURE_FLAGS
    if grep -q "^CONFIG_APPS=n" mk/config.mk; then
      echo "ERROR: SPDK apps are disabled (CONFIG_APPS=n)." >&2
      exit 1
    fi
    DPDK_OPTS="-Denable_docs=false -Dplatform=$DPDK_PLATFORM -Denable_libs=$DPDK_ENABLE_LIBS -Ddisable_libs=$DPDK_DISABLE_LIBS" \
      EXTRA_DPDK_CFLAGS="$DPDK_EXTRA_CFLAGS" \
      make -j"$(nproc)"
    DPDK_OPTS="-Denable_docs=false -Dplatform=$DPDK_PLATFORM -Denable_libs=$DPDK_ENABLE_LIBS -Ddisable_libs=$DPDK_DISABLE_LIBS" \
      EXTRA_DPDK_CFLAGS="$DPDK_EXTRA_CFLAGS" \
      make -j"$(nproc)" app/spdk_nvme_perf
    mkdir -p /work/docker_artifacts
    BIN_PATH=$(find build -type f -name spdk_nvme_perf -print -quit)
    if [ -z "$BIN_PATH" ]; then
      echo "ERROR: spdk_nvme_perf not found under build/." >&2
      ls -la build || true
      exit 1
    fi
    cp -v "$BIN_PATH" /work/docker_artifacts/guest_spdk_nvme_perf
    if [ -f /usr/lib/x86_64-linux-gnu/libssl.so.1.1 ] && [ -f /usr/lib/x86_64-linux-gnu/libcrypto.so.1.1 ]; then
      mkdir -p /work/docker_artifacts/guest_openssl11
      cp -v /usr/lib/x86_64-linux-gnu/libssl.so.1.1 /work/docker_artifacts/guest_openssl11/
      cp -v /usr/lib/x86_64-linux-gnu/libcrypto.so.1.1 /work/docker_artifacts/guest_openssl11/
    fi
  '

if [ -f "$ROOT_DIR/docker_artifacts/guest_spdk_nvme_perf" ]; then
  SRC_BIN="$ROOT_DIR/docker_artifacts/guest_spdk_nvme_perf"
  SRC_REAL=$(readlink -f "$SRC_BIN")
  DST_REAL=$(readlink -f "$OUTPUT_BIN" 2>/dev/null || true)
  if [ "$SRC_REAL" != "$DST_REAL" ]; then
    mv -f "$SRC_BIN" "$OUTPUT_BIN"
  fi
  chmod +x "$OUTPUT_BIN"
  echo "Built: $OUTPUT_BIN"
else
  echo "Build completed but output binary not found." >&2
  exit 1
fi

if [ -d "$ROOT_DIR/docker_artifacts/guest_openssl11" ] && [ -n "$(ls -A "$ROOT_DIR/docker_artifacts/guest_openssl11" 2>/dev/null)" ]; then
  SRC_SSL="$ROOT_DIR/docker_artifacts/guest_openssl11"
  SRC_SSL_REAL=$(readlink -f "$SRC_SSL")
  DST_SSL_REAL=$(readlink -f "$OPENSSL11_OUT" 2>/dev/null || true)
  if [ "$SRC_SSL_REAL" != "$DST_SSL_REAL" ]; then
    rm -rf "$OPENSSL11_OUT"
    mv "$SRC_SSL" "$OPENSSL11_OUT"
  fi
  echo "OpenSSL 1.1.1 libs copied to: $OPENSSL11_OUT"
else
  echo "OpenSSL 1.1.1 libs not found in container; skipping export." >&2
fi
