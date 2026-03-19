#!/usr/bin/env bash
# =============================================================================
# upload_large_files.sh
# Transfer all large/binary files that are NOT in git to the remote server.
# gem5 will be recompiled on the remote from source (via git).
# =============================================================================

# ── Hyperparameters ──────────────────────────────────────────────────────────
REMOTE_USER="fangy6"
REMOTE_HOST="tzhang1.ecse.rpi.edu"
REMOTE_PASS=""          # Set this, or leave empty to use SSH key / prompt
RPATH="~/SimpleSSD_Gem5_simulation"
LOCAL="$(cd "$(dirname "$0")" && pwd)"
# ─────────────────────────────────────────────────────────────────────────────

REMOTE="${REMOTE_USER}@${REMOTE_HOST}"

# Helper: prepend sshpass if password is set, otherwise run bare
ssh_cmd() {
  if [ -n "$REMOTE_PASS" ]; then
    sshpass -p "$REMOTE_PASS" ssh "$REMOTE" "$@"
  else
    ssh "$REMOTE" "$@"
  fi
}

rsync_cmd() {
  if [ -n "$REMOTE_PASS" ]; then
    sshpass -p "$REMOTE_PASS" rsync "$@"
  else
    rsync "$@"
  fi
}

set -euo pipefail

echo "=== Target: ${REMOTE}:${RPATH} ==="

# ── 1. Create remote directory structure ─────────────────────────────────────
echo "[1/4] Creating remote directories..."
ssh_cmd "mkdir -p \
  ${RPATH}/assets \
  ${RPATH}/docker_artifacts/guest_openssl11 \
  ${RPATH}/SimpleSSD-FullSystem/build/X86 \
  ${RPATH}/logs \
  ${RPATH}/results/checkpoints"
echo "    OK"

# ── 2. Disk image (16GB — rsync with resume) ─────────────────────────────────
echo "[2/4] Uploading x86-ubuntu.img (16GB)..."
rsync_cmd -avP --partial \
  "${LOCAL}/assets/x86-ubuntu.img" \
  "${REMOTE}:${RPATH}/assets/"

# ── 3. Guest kernel (24MB) ───────────────────────────────────────────────────
echo "[3/4] Uploading vmlinux-5.4.49 (24MB)..."
rsync_cmd -avP --partial \
  "${LOCAL}/assets/vmlinux-5.4.49" \
  "${REMOTE}:${RPATH}/assets/"

# ── 4. docker_artifacts (guest SPDK binary + openssl libs, ~11MB) ────────────
echo "[4/4] Uploading docker_artifacts/..."
rsync_cmd -avP --partial \
  "${LOCAL}/docker_artifacts/" \
  "${REMOTE}:${RPATH}/docker_artifacts/"

echo ""
echo "=== Upload complete ==="
echo ""
echo "Next steps on the remote server:"
echo ""
echo "  # 1. Clone repo (if not already done)"
echo "  git clone https://github.com/YOUR_USER/YOUR_REPO.git ~/SimpleSSD_Gem5_simulation"
echo "  cd ~/SimpleSSD_Gem5_simulation"
echo ""
echo "  # 2. Set up Python 2 conda env with SCons"
echo "  conda create -n simplessd_env python=2.7 -y"
echo "  conda run -n simplessd_env pip install scons==3.1.2 ply six"
echo ""
echo "  # 3. Compile gem5 (uses source from git, not transferred)"
echo "  cd SimpleSSD-FullSystem"
echo "  conda run -n simplessd_env \\"
echo "    env LD_LIBRARY_PATH=\$CONDA_PREFIX/lib:\${LD_LIBRARY_PATH:-} \\"
echo "    scons -j\$(nproc) build/X86/gem5.opt"
echo ""
echo "  # 4. Run simulation"
echo "  cd ~/SimpleSSD_Gem5_simulation"
echo "  nohup bash scripts/driver_phase1.sh \\"
echo "    --auto --use-readfile 1 --auto-9p 1 \\"
echo "    --host-share ~/SimpleSSD_Gem5_simulation \\"
echo "    --qd 16 --ios 4096 --repeats 1 --steady-time 2 \\"
echo "    --tag smoke_test_v1 \\"
echo "    > /tmp/driver_smoke.log 2>&1 &"
echo "  disown \$!"