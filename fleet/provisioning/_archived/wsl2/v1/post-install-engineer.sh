#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: post-install-engineer.sh
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
#     | MODULE: POST-ARCH-FLEET | SUBSYSTEM: PROV / WSL2          |
#     | LICENSE: AGPL-3         | STARDATE: 2026.063              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Post-install config for the engineer instance.    |
#     |  Sets identity, wake-instance, fleet-hub layout.          |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     post-install-engineer.sh — Module post-install pour instances de type 'engineer'
#
#     Rôle : dev du toolkit AI (LCARS).
#     Setup système identique à starfleet (gh, binfmt, wsl-root en écriture).
#     La différenciation de rôle est au niveau Claude Code (MEMORY.md + directives).
#
#     Montages disponibles après boot :
#       /home/commons    → #3_Commons  (handoff, artifacts, bare repos)
#
#     [EN]
#     post-install-engineer.sh — Post-install config for the architect instance.
#     Sets identity, wake-instance, fleet-hub layout.
#

set -euo pipefail

# --- Fleet env ---
source "$(dirname "${BASH_SOURCE[0]}")/../../fleet-env.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[post-install-engineer]${NC}  $*"; }
warn() { echo -e "${YELLOW}[post-install-engineer]${NC}  $*"; }

# Setup identique à starfleet : gh CLI, gh auth, WSL interop binfmt
bash "$SCRIPT_DIR/post-install-starfleet.sh"

# ─── /local/ : ext4 pour le repo LCARS (engineer uniquement) ───
# post-install.sh a déjà cloné ~/.lcars depuis GitHub.
# On le déplace sur ext4 et on crée un symlink backward-compatible.
info "Setting up $LCARS_ROOT (ext4)"
sudo mkdir -p /local
sudo chown $ARCHITECT_USER:$ARCHITECT_USER /local
if [ -d "$HOME/.lcars" ] && [ ! -L "$HOME/.lcars" ]; then
    mv "$HOME/.lcars" $LCARS_ROOT
    info "Moved ~/.lcars → $LCARS_ROOT"
elif [ ! -d "$LCARS_ROOT" ]; then
    git clone git@github.com:${LCARS_REPO:-$ARCHITECT_USER/LCARS-fleet}.git $LCARS_ROOT
    info "Cloned LCARS → $LCARS_ROOT"
else
    info "$LCARS_ROOT already present — skipping clone"
fi
ln -sf $LCARS_ROOT "$HOME/.lcars"
info "Symlink ~/.lcars → $LCARS_ROOT"

# Configure Anthropic plan reset schedule (skip if already set)
bash "$SCRIPT_DIR/configure-plan.sh"

# Per-agent git identity — overrides global user.name from git-identity.conf
git config --global user.name "LCARS-engineer"
