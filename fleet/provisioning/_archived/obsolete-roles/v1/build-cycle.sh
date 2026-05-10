#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: build-cycle.sh
#     |  |________|  | AUTHOR: LORDZURP
#     |   ________   | SYSTEM: LCARS-FLEET v2.0
#     |  |  v2.0  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS-FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: BUILD-CYCLE     | SUBSYSTEM: FLEET / BUILD        |
#     | LICENSE: AGPL-3         | STARDATE: 2026.063              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Orchestrates the full build cycle for a project.         |
#     |  Pull → cmake → build → report → handoff.                 |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     build-cycle.sh — Cycle de build incrémental OST+INDI
#
#     Usage:
#       build-cycle.sh [--arch arm64|x86-64] [options]
#       build-cycle.sh                   # défaut : arm64, ostmodules + inject seulement
#       build-cycle.sh --rebuild-ost     # ostserver + ostmodules + inject
#       build-cycle.sh --rebuild-full    # tout sauf INDI
#
#     [EN]
#     build-cycle.sh — Orchestrates the full build cycle for a project.
#     Pull → cmake → build → report → handoff.
#

set -eo pipefail

# --- Fleet env ---
source "$(dirname "${BASH_SOURCE[0]}")/fleet-env.sh"
WORKDIR="/home/builder"
LOGFILE="$WORKDIR/build-cycle-$(date +%Y%m%d-%H%M%S).log"
CURRENT_STEP="init"

exec > >(tee -a "$LOGFILE") 2>&1

trap 'echo "@@@ EXIT: $? — ÉTAPE: $CURRENT_STEP — $(date)"' EXIT

echo "=== build-cycle.sh START — $(date) ==="

# ============================================================================
# OPTIONS PARSING
# ============================================================================

ARCH="arm64"
REBUILD_INDI=0
REBUILD_OST=0
REBUILD_FULL=0
IMAGE_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      shift
      case "${1:-}" in
        arm64|x86-64) ARCH="$1" ;;
        *) echo "Unknown --arch value: '${1:-}' (arm64|x86-64)"; exit 1 ;;
      esac
      ;;
    --rebuild-indi)
      REBUILD_INDI=1
      REBUILD_OST=1
      REBUILD_FULL=1
      ;;
    --rebuild-full)
      REBUILD_FULL=1
      REBUILD_OST=1
      ;;
    --rebuild-ost)
      REBUILD_OST=1
      ;;
    --image-only)
      IMAGE_ONLY=1
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
  shift
done

echo "=== OPTIONS ==="
echo "ARCH=$ARCH, REBUILD_INDI=$REBUILD_INDI, REBUILD_OST=$REBUILD_OST, REBUILD_FULL=$REBUILD_FULL, IMAGE_ONLY=$IMAGE_ONLY"

# ============================================================================
# STEP 0: Source environment
# ============================================================================

CURRENT_STEP="0-env"
echo "=== ÉTAPE 0: sourcing environment — $(date) ==="
if [[ "$ARCH" == "arm64" ]]; then
  # shellcheck source=/dev/null
  source ~/.env.cross
else
  # shellcheck source=/dev/null
  source ~/.env.x86
fi

# ============================================================================
# STEP 1: Git pull (fast reference update)
# ============================================================================

if [[ $IMAGE_ONLY -eq 0 ]]; then
  CURRENT_STEP="1-git-pull"
  echo "=== ÉTAPE 1: git pull sources — $(date) ==="
  # Only pull if on a branch (not detached HEAD)
  if git -C /home/builder/ostmodules rev-parse --abbrev-ref HEAD | grep -q detached; then
    echo ">>> ostmodules: detached HEAD, skipping pull (using current ref)"
  else
    git -C /home/builder/ostmodules pull --ff-only --quiet || echo ">>> ostmodules: pull skipped (non-fast-forward or no remote)"
  fi

  if git -C /home/builder/ostserver rev-parse --abbrev-ref HEAD | grep -q detached; then
    echo ">>> ostserver: detached HEAD, skipping pull (using current ref)"
  else
    git -C /home/builder/ostserver pull --ff-only --quiet || echo ">>> ostserver: pull skipped (non-fast-forward or no remote)"
  fi
  echo ">>> Sources checked"
fi

# ============================================================================
# STEP 2: INDI build (skip unless --rebuild-indi)
# ============================================================================

if [[ "$ARCH" == "x86-64" ]]; then
  echo "=== ÉTAPE 2: INDI — N/A (x86-64 : RPi-only step) ==="
elif [[ $REBUILD_INDI -eq 1 ]]; then
  CURRENT_STEP="2-indi"
  echo "=== ÉTAPE 2: INDI build (--rebuild-indi) — $(date) ==="
  echo "WARNING: INDI rebuild takes ~30 minutes. See $LOGFILE"
  # Placeholder: full INDI rebuild logic
  # In practice, reference phase2.sh lines for INDI cmake/make/install
  echo "INDI rebuild not yet implemented in build-cycle.sh — use phase2.sh for full rebuild"
  exit 1
else
  echo "=== ÉTAPE 2: INDI — skipped (use --rebuild-indi) ==="
fi

# ============================================================================
# STEP 3: ostserver build (skip unless --rebuild-ost/--rebuild-full)
# ============================================================================

if [[ $REBUILD_OST -eq 1 ]] && [[ $IMAGE_ONLY -eq 0 ]]; then
  CURRENT_STEP="3-ostserver"
  echo "=== ÉTAPE 3: ostserver build — $(date) ==="

  # Clean and reconfigure
  rm -rf "$WORKDIR/build-ostserver"
  mkdir -p "$WORKDIR/build-ostserver"

  if [[ "$ARCH" == "arm64" ]]; then
    cmake -S "$WORKDIR/ostserver" \
          -B "$WORKDIR/build-ostserver" \
          -DCMAKE_TOOLCHAIN_FILE="$WORKDIR/ostserver/toolchain-rpi-aarch64.cmake" \
          -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_SYSROOT=/opt/rpi-sysroot \
          -DCMAKE_C_FLAGS="$CFLAGS_CPU" \
          -DCMAKE_CXX_FLAGS="$CFLAGS_CPU"
  else
    cmake -S "$WORKDIR/ostserver" \
          -B "$WORKDIR/build-ostserver" \
          -DCMAKE_BUILD_TYPE=Release
  fi

  cmake --build "$WORKDIR/build-ostserver" -j2 2>&1 | filter-build-output.sh

  # Install to staging
  rm -rf "$WORKDIR/ost-staging"
  DESTDIR="$WORKDIR/ost-staging" cmake --install "$WORKDIR/build-ostserver"

  echo ">>> ostserver built and staged"
else
  echo "=== ÉTAPE 3: ostserver — $([ $IMAGE_ONLY -eq 1 ] && echo 'skipped (--image-only)' || echo 'skipped (reuse cached)') ==="
fi

# ============================================================================
# STEP 4: ostmodules build (always unless --image-only)
# ============================================================================

if [[ $IMAGE_ONLY -eq 0 ]]; then
  CURRENT_STEP="4-ostmodules"
  echo "=== ÉTAPE 4: ostmodules build — $(date) ==="

  # For incremental: keep build-ostmodules dir if it exists and CMakeCache is valid
  # Only rm -rf if --rebuild-full or CMakeCache is stale
  if [[ $REBUILD_FULL -eq 1 ]]; then
    rm -rf "$WORKDIR/build-ostmodules"
  fi

  mkdir -p "$WORKDIR/build-ostmodules"

  # CMake configure
  if [[ "$ARCH" == "arm64" ]]; then
    cmake -S "$WORKDIR/ostmodules" \
          -B "$WORKDIR/build-ostmodules" \
          -DCMAKE_TOOLCHAIN_FILE="$WORKDIR/ostserver/toolchain-rpi-aarch64.cmake" \
          -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_SYSROOT=/opt/rpi-sysroot \
          -DCMAKE_C_FLAGS="$CFLAGS_CPU" \
          -DCMAKE_CXX_FLAGS="$CFLAGS_CPU" \
          -DOST_INCLUDE_DIR:PATH="$WORKDIR/ost-staging/usr/include" \
          -DOST_LIBRARY_BASE:FILEPATH="$WORKDIR/ost-staging/usr/lib/libostbasemodule.so" \
          -DOST_LIBRARY_INDI:FILEPATH="$WORKDIR/ost-staging/usr/lib/libostindimodule.so"
  else
    cmake -S "$WORKDIR/ostmodules" \
          -B "$WORKDIR/build-ostmodules" \
          -DCMAKE_BUILD_TYPE=Release \
          -DOST_INCLUDE_DIR:PATH="$WORKDIR/ost-staging/usr/include" \
          -DOST_LIBRARY_BASE:FILEPATH="$WORKDIR/ost-staging/usr/lib/libostbasemodule.so" \
          -DOST_LIBRARY_INDI:FILEPATH="$WORKDIR/ost-staging/usr/lib/libostindimodule.so"
  fi

  cmake --build "$WORKDIR/build-ostmodules" -j2 2>&1 | filter-build-output.sh

  # Install to staging (append, don't reset)
  DESTDIR="$WORKDIR/ost-staging" cmake --install "$WORKDIR/build-ostmodules"

  echo ">>> ostmodules built and staged"
else
  echo "=== ÉTAPE 4: ostmodules — skipped (--image-only) ==="
fi

# ============================================================================
# STEP 5: Deliver artifacts to commons (unless --image-only)
# ============================================================================

if [[ $IMAGE_ONLY -eq 0 ]]; then
  CURRENT_STEP="5-deliver"
  echo "=== ÉTAPE 5: deliver artifacts — $(date) ==="

  if [[ "$ARCH" == "arm64" ]]; then
    ARTIFACT_DIR=/home/commons/artifacts/arm64
  else
    ARTIFACT_DIR=/home/commons/artifacts/x86-64
  fi
  mkdir -p "$ARTIFACT_DIR"
  cp "$WORKDIR/ost-staging/usr/lib/libost"*.so "$ARTIFACT_DIR/"
  cp "$WORKDIR/ost-staging/usr/bin/ostserver" "$ARTIFACT_DIR/" 2>/dev/null || true

  echo ">>> Artifacts delivered to $ARTIFACT_DIR/"
fi

# ============================================================================
# STEP 6: pi-gen image (if --rebuild-full or --image-only, reference existing script)
# ============================================================================

if [[ "$ARCH" == "x86-64" ]]; then
  echo "=== ÉTAPE 6: pi-gen — N/A (x86-64 : RPi-only step) ==="
elif [[ $REBUILD_FULL -eq 1 ]] || [[ $IMAGE_ONLY -eq 1 ]]; then
  CURRENT_STEP="6-pigen"
  echo "=== ÉTAPE 6: pi-gen image build — $(date) ==="
  echo "WARNING: pi-gen rebuild takes ~45 minutes. See $LOGFILE"

  # pi-gen is invoked via phase2.sh — for now, reference it
  # In a future iteration, extract the pi-gen CMake/make into this script
  echo "pi-gen rebuild not yet integrated — use phase2.sh for full image rebuild"
  exit 1
else
  echo "=== ÉTAPE 6: pi-gen — skipped (use --rebuild-full or --image-only) ==="
fi

# ============================================================================
# STEP 7: inject-image (always, unless --image-only without code rebuild)
# ============================================================================

if [[ "$ARCH" == "x86-64" ]]; then
  echo "=== ÉTAPE 7: inject-image — N/A (x86-64 : RPi-only step) ==="
elif [[ $IMAGE_ONLY -eq 0 ]]; then
  CURRENT_STEP="7-inject"
  echo "=== ÉTAPE 7: inject-image — $(date) ==="

  # Reference the inject-image.sh script or inline the logic
  # For now, invoke the existing script (from starfleet notes)
  bash "$WORKDIR/inject-image.sh" 2>&1 | tee -a "$LOGFILE"

  echo ">>> Image injection complete"
else
  echo "=== ÉTAPE 7: inject-image — skipped (--image-only, no code rebuild) ==="
fi

# ============================================================================
# FINAL
# ============================================================================

CURRENT_STEP="final"
echo "=== build-cycle.sh COMPLETE — $(date) ==="
echo ">>> Log: $LOGFILE"
echo ">>> Artifacts: /home/commons/artifacts/arm64/"
