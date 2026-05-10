#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: post-install-architect.sh
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
#     | MODULE: POST-ARCH-LEAD  | SUBSYSTEM: PROV / LINUX         |
#     | LICENSE: AGPL-3         | STARDATE: 2026.068              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Post-install module for architect / architect.       |
#     |  Installs system packages needed for fleet dashboard.     |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     post-install-architect.sh — Configuration spécifique à $ARCHITECT_USER.
#     Paquets système pour le dashboard fleet (btop, etc.).
#     Silence MOTD Ubuntu (hushlogin).
#

set -euo pipefail

# --- Fleet env ---
source "$(dirname "${BASH_SOURCE[0]}")/../../fleet-env.sh"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[post-arch-lead]${NC}  $*"; }
warn() { echo -e "${YELLOW}[post-arch-lead]${NC}  $*"; }

# ─── Silence Ubuntu MOTD ──────────────────────────────────────────────────────
# System packages (btop, expect, python3.12-venv, gh) installed by provision-system.sh
if [[ ! -f "$HOME/.hushlogin" ]]; then
    touch "$HOME/.hushlogin"
    info ".hushlogin created (MOTD silenced)"
fi

# ─── Provision steward ────────────────────────────────────────────────────────
PROVISION_USER="$HOME/.lcars/fleet/provisioning/linux/provision-user.sh"
if [[ -x "$PROVISION_USER" ]]; then
    info "Provisioning steward..."
    bash "$PROVISION_USER" steward
else
    warn "provision-user.sh not found at $PROVISION_USER"
fi

# ─── Lancement steward (Phase 1 — onboarding config + provisioning) ──────────
cd ~
clear
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
info "Tout est installé. Bienvenue dans la fleet !"
info "Le steward va vous guider pour la configuration initiale."
info "  → Tapez votre mot-clé <session-open> pour démarrer."
info "  → Mot-clé standard : yop"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Appuyez sur Entrée pour lancer le steward..."
read -r _ < /dev/tty
sudo -u steward -i /usr/local/bin/claude

# ─── Post-steward : message de retour ───────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
info "Phase 1 terminée. Les agents sont provisionnés."
info ""
info "Pour lancer le dashboard et continuer la visite guidée :"
info ""
info "    ~/start"
info ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
