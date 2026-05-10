#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: post-install-dev.sh
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
#     | MODULE: POST-DEV        | SUBSYSTEM: PROV / WSL2          |
#     | LICENSE: AGPL-3         | STARDATE: 2026.063              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Post-install config for dev instances.                   |
#     |  Code tools, git config, dev-specific shell setup.        |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     post-install-dev.sh — Module post-install pour instances de type 'dev'
#
#     Appelé par post-install.sh sur les instances de développement.
#
#     Prérequis système installés par wsl-setup.sh (type 'dev') :
#       build-essential, cmake, ninja-build, pkg-config, gdb,
#       clang, clang-format, clang-tidy, bear, ssh, python3, python3-pip, python3-venv
#
#     [EN]
#     post-install-dev.sh — Post-install config for dev instances.
#     Code tools, git config, dev-specific shell setup.
#

set -euo pipefail

# --- Fleet env ---
source "$(dirname "${BASH_SOURCE[0]}")/../../fleet-env.sh"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[post-install-dev]${NC}  $*"; }
warn() { echo -e "${YELLOW}[post-install-dev]${NC}  $*"; }

# ─── 1. Vérification outils dev ───────────────────────────────────────────────
info "Checking dev toolchain"

for bin in gcc g++ cmake ninja clang gdb python3; do
    if command -v "$bin" &>/dev/null; then
        info "  $bin — OK"
    else
        warn "  $bin — NOT FOUND"
    fi
done

# ─── 2. python3 venv de base ──────────────────────────────────────────────────
VENV_DIR="$HOME/.venv"
if [ ! -d "$VENV_DIR" ]; then
    info "Creating default python3 venv at $VENV_DIR"
    python3 -m venv "$VENV_DIR"
    if ! grep -q '\.venv/bin/activate' "$HOME/.bashrc"; then
        echo "source $VENV_DIR/bin/activate" >> "$HOME/.bashrc"
        info "venv activation added to .bashrc"
    fi
else
    warn "venv already exists at $VENV_DIR — skipping"
fi

# ─── 3. Claude Code model config ─────────────────────────────────────────────
CLAUDE_LOCAL_SETTINGS="$HOME/.claude/settings.local.json"
if [ -f "$CLAUDE_LOCAL_SETTINGS" ]; then
    python3 - <<'PYEOF'
import json, os
path = os.path.expanduser("~/.claude/settings.local.json")
with open(path) as f:
    s = json.load(f)
MODEL = "claude-sonnet-4-6"
if s.get("model") == MODEL:
    print(f"[post-install] dev model already set to {MODEL} — skip")
else:
    s["model"] = MODEL
    with open(path, "w") as f:
        json.dump(s, f, indent=2)
        f.write("\n")
    print(f"[post-install] dev model set to {MODEL}")
PYEOF
fi

info "Dev environment ready"

# Per-agent git identity — overrides global user.name from git-identity.conf
git config --global user.name "LCARS-dev"
