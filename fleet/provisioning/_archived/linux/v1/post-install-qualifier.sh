#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: post-install-qualifier.sh
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
#     | MODULE: POST-QA         | SUBSYSTEM: PROV / WSL2          |
#     | LICENSE: AGPL-3         | STARDATE: 2026.063              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Post-install config for QA instances.                    |
#     |  Test frameworks, pytest, ctest, qualifier-specific setup.       |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     post-install-qualifier.sh — Module post-install pour instances de type 'qualifier'
#
#     Appelé par post-install.sh sur les instances QA/test.
#     Configure l'environnement de test : pytest, ctest, accès SSH Pi optionnel.
#
#     Prérequis système installés par wsl-setup.sh (type 'qualifier') :
#       build-essential, cmake, ninja-build, pkg-config, python3, python3-pip,
#       python3-venv, ssh
#
#     [EN]
#     post-install-qualifier.sh — Post-install config for QA instances.
#     Test frameworks, pytest, ctest, qualifier-specific setup.
#

set -euo pipefail

# --- Fleet env ---
source "$(dirname "${BASH_SOURCE[0]}")/../../fleet-env.sh"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[post-install-qualifier]${NC}  $*"; }
warn() { echo -e "${YELLOW}[post-install-qualifier]${NC}  $*"; }

# ─── 1. Vérification outils de base ───────────────────────────────────────────
info "Checking QA toolchain"

for bin in python3 cmake ninja; do
    if command -v "$bin" &>/dev/null; then
        info "  $bin — OK"
    else
        warn "  $bin — NOT FOUND"
    fi
done

# ─── 2. Python venv + pytest ──────────────────────────────────────────────────
VENV_DIR="$HOME/.venv"
if [ ! -d "$VENV_DIR" ]; then
    info "Creating python3 venv at $VENV_DIR"
    python3 -m venv "$VENV_DIR"
    if ! grep -q '\.venv/bin/activate' "$HOME/.bashrc"; then
        echo "source $VENV_DIR/bin/activate" >> "$HOME/.bashrc"
        info "venv activation added to .bashrc"
    fi
else
    warn "venv already exists at $VENV_DIR — skipping"
fi

source "$VENV_DIR/bin/activate"

info "Installing pytest"
pip install --quiet pytest pytest-timeout

# ─── 3. Claude Code model config ─────────────────────────────────────────────
CLAUDE_LOCAL_SETTINGS="$HOME/.claude/settings.local.json"
if [ -f "$CLAUDE_LOCAL_SETTINGS" ]; then
    python3 - <<'PYEOF'
import json, os
path = os.path.expanduser("~/.claude/settings.local.json")
with open(path) as f:
    s = json.load(f)
MODEL = "claude-haiku-4-5-20251001"
if s.get("model") == MODEL:
    print(f"[post-install] qualifier model already set to {MODEL} — skip")
else:
    s["model"] = MODEL
    with open(path, "w") as f:
        json.dump(s, f, indent=2)
        f.write("\n")
    print(f"[post-install] qualifier model set to {MODEL}")
PYEOF
fi

info "QA environment ready"
echo ""
echo "  Installed: $(python3 -m pytest --version 2>&1)"
echo ""
echo "  Checklist:"
echo "  [ ] to-qualifier.md accessible ($FLEET_HANDOFFS/to-qualifier.md)"
echo "  [ ] test-queue.md accessible ($FLEET_HANDOFFS/test-queue.md)"
echo "  [ ] SSH access to test targets (Pi, x86 host) if hardware-in-the-loop"

# Per-agent git identity — overrides global user.name from git-identity.conf
git config --global user.name "LCARS-qualifier"
