#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: post-install-builder.sh
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
#     | MODULE: POST-BUILDER    | SUBSYSTEM: PROV / WSL2          |
#     | LICENSE: AGPL-3         | STARDATE: 2026.063              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Post-install config for builder instances.               |
#     |  Build tools, cmake, cross-compilation toolchain.         |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     post-install-builder.sh — Module post-install pour instances de type 'builder'
#
#     Appelé par post-install.sh sur les instances builder.
#     Configure l'environnement cross-compilation ARM64 (RPi Zero 2).
#
#     Prérequis système installés par wsl-setup.sh (type 'builder') :
#       gcc-aarch64-linux-gnu, binutils-aarch64-linux-gnu, cmake, ninja-build,
#       pkg-config, file, ssh
#
#     [EN]
#     post-install-builder.sh — Post-install config for builder instances.
#     Build tools, cmake, cross-compilation toolchain.
#

set -euo pipefail

# --- Fleet env ---
source "$(dirname "${BASH_SOURCE[0]}")/../../fleet-env.sh"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[post-install-builder]${NC}  $*"; }
warn() { echo -e "${YELLOW}[post-install-builder]${NC}  $*"; }

# ─── 1. Vérification toolchain ────────────────────────────────────────────────
info "Checking cross-compilation toolchain"

TOOLCHAIN_OK=true
for bin in aarch64-linux-gnu-gcc aarch64-linux-gnu-g++ aarch64-linux-gnu-ld cmake ninja; do
    if command -v "$bin" &>/dev/null; then
        info "  $bin — OK ($(command -v $bin))"
    else
        warn "  $bin — NOT FOUND"
        TOOLCHAIN_OK=false
    fi
done

if $TOOLCHAIN_OK; then
    info "Toolchain ready"
else
    warn "Some toolchain components missing — check apt packages in wsl-setup.sh"
fi

# ─── 2. Cible RPi ─────────────────────────────────────────────────────────────
# Écrit seulement si absent — modifiable via rpi-target-set après provisioning.
RPI_TARGET_FILE="$HOME/.rpi-target"
if [ -f "$RPI_TARGET_FILE" ]; then
    warn ".rpi-target already exists ($(cat "$RPI_TARGET_FILE")) — skipping"
else
    echo "zero2" > "$RPI_TARGET_FILE"
    info "RPi target set to 'zero2' — change with: rpi-target-set <zero2|pi4|pi5>"
fi

# rpi-target-set → ~/.local/bin/ (dans le PATH Ubuntu)
mkdir -p "$HOME/.local/bin"
if [ -f "$HOME/.lcars/fleet/provisioning/wsl2/rpi-target-set.sh" ]; then
    cp "$HOME/.lcars/fleet/provisioning/wsl2/rpi-target-set.sh" "$HOME/.local/bin/rpi-target-set"
    chmod +x "$HOME/.local/bin/rpi-target-set"
    info "rpi-target-set installed in ~/.local/bin/"
else
    warn "rpi-target-set.sh not found in ~/.lcars/provisioning/wsl2 — skipping"
fi

# ─── 3. Template .env.cross ───────────────────────────────────────────────────
# Créé seulement si absent — l'utilisateur doit ajuster SYSROOT.
ENV_CROSS="$HOME/.env.cross"
if [ -f "$ENV_CROSS" ]; then
    warn ".env.cross already exists — skipping template creation"
else
    cat > "$ENV_CROSS" <<'EOF'
# Cross-compilation environment — aarch64 (RPi)
# Source this file before building: source ~/.env.cross
# Change target : echo zero2|pi4|pi5 > ~/.rpi-target  (then re-source)

export CROSS_COMPILE=aarch64-linux-gnu-
export SYSROOT=/opt/rpi-sysroot
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
export PKG_CONFIG_PATH="$SYSROOT/usr/lib/aarch64-linux-gnu/pkgconfig"
export CC=aarch64-linux-gnu-gcc
export CXX=aarch64-linux-gnu-g++

# Build workspace — ext4 natif (performances natives, pas 9P/drvfs)
# Cloner les sources ici, jamais dans ~/  (9P = lent)
export BUILD_WORK_DIR=/home/builder

# RPi target — zero2 | pi4 | pi5
RPI_TARGET=$(cat ~/.rpi-target 2>/dev/null || echo zero2)
export RPI_TARGET
case "$RPI_TARGET" in
    zero2) export CFLAGS_CPU="-mcpu=cortex-a53" ;;
    pi4)   export CFLAGS_CPU="-mcpu=cortex-a72" ;;
    pi5)   export CFLAGS_CPU="-mcpu=cortex-a76" ;;
    *)     export CFLAGS_CPU="" ;;
esac
EOF
    info ".env.cross template written to $ENV_CROSS"
    warn "Edit $ENV_CROSS to set the correct SYSROOT path"
fi

# ─── 4. Claude Code env tuning ────────────────────────────────────────────────
# Réduire budget thinking (16K→8K) et déclencher compact plus tôt (95%→50%)
CLAUDE_LOCAL_SETTINGS="$HOME/.claude/settings.local.json"
if [ -f "$CLAUDE_LOCAL_SETTINGS" ]; then
    python3 - <<'PYEOF'
import json, os, sys
path = os.path.expanduser("~/.claude/settings.local.json")
with open(path) as f:
    s = json.load(f)
if "env" not in s:
    s["env"] = {"MAX_THINKING_TOKENS": "8000", "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "50"}
    with open(path, "w") as f:
        json.dump(s, f, indent=2)
        f.write("\n")
    print("[post-install] builder env vars added to settings.local.json")
else:
    print("[post-install] env block already present — skip")
PYEOF
fi

# ─── 4b. Claude Code model config ─────────────────────────────────────────────
CLAUDE_LOCAL_SETTINGS="$HOME/.claude/settings.local.json"
if [ -f "$CLAUDE_LOCAL_SETTINGS" ]; then
    python3 - <<'PYEOF'
import json, os
path = os.path.expanduser("~/.claude/settings.local.json")
with open(path) as f:
    s = json.load(f)
MODEL = "claude-haiku-4-5-20251001"
if s.get("model") == MODEL:
    print(f"[post-install] builder model already set to {MODEL} — skip")
else:
    s["model"] = MODEL
    with open(path, "w") as f:
        json.dump(s, f, indent=2)
        f.write("\n")
    print(f"[post-install] builder model set to {MODEL}")
PYEOF
fi

# ─── 5. Checklist ─────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Build instance setup checklist:${NC}"
echo "  [$([ -f "$RPI_TARGET_FILE" ] && echo 'x' || echo ' ')] .rpi-target present ($(cat "$RPI_TARGET_FILE" 2>/dev/null || echo '?')) — rpi-target-set <zero2|pi4|pi5>"
echo "  [$([ -f "$ENV_CROSS" ] && echo 'x' || echo ' ')] .env.cross present"
echo "  [ ] SYSROOT configured in .env.cross (/opt/rpi-sysroot)"
echo "  [ ] Sysroot populated (setup-rpi-sysroot.sh)"
echo "  [ ] SSH access to RPi target"
echo "  [ ] /home/commons mounted and accessible"
echo ""
echo "  Build sequence (all paths on ext4 — never clone in ~/):"
echo "    source ~/.env.cross"
echo "    git clone /home/commons/<project>/<repo>.git \$BUILD_WORK_DIR/<repo>"
echo "    # add further project repos as needed"
echo "    cmake -S \$BUILD_WORK_DIR/ostmodules -B \$BUILD_WORK_DIR/build \\"
echo "      -DCMAKE_TOOLCHAIN_FILE=\$BUILD_WORK_DIR/ostserver/toolchain-rpi-aarch64.cmake \\"
echo "      -DCMAKE_BUILD_TYPE=Release -DCMAKE_SYSROOT=\$SYSROOT \\"
echo "      -DCMAKE_C_FLAGS=\"\$CFLAGS_CPU\" -DCMAKE_CXX_FLAGS=\"\$CFLAGS_CPU\""
echo "    cmake --build \$BUILD_WORK_DIR/build --target ostdriftva -j\$(nproc)"

# Per-agent git identity — overrides global user.name from git-identity.conf
git config --global user.name "LCARS-builder"
