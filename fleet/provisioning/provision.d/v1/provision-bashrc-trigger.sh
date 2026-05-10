#!/usr/bin/env bash
# DEPLOY: none (called by provision-fleet.sh)

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: provision-bashrc-trigger.sh
#     |  |________|  | AUTHOR: STARFLEET
#     |   ________   | SYSTEM: LCARS-FLEET v6.0
#     |  |  v6.0  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS-FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: BASHRC-TRIGGER  | SUBSYSTEM: PROVISIONING         |
#     | LICENSE: AGPL-3         | STARDATE: 2026.088              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Installs post-reboot trigger in user's .bashrc.          |
#     |  One-shot: gated by sentinels, runs post-reboot.sh once.  |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     Installe le trigger post-reboot dans le .bashrc de l'utilisateur.
#     One-shot : gardé par sentinels (.install_ok + .fleet_ready).
#
#     [EN]
#     NAME
#         provision-bashrc-trigger.sh — install post-reboot trigger in .bashrc
#
#     SYNOPSIS
#         provision-bashrc-trigger.sh <user_home>
#
#     EXIT CODES
#         0    Trigger installed or already present
#
# --- END HEADER ---

set -euo pipefail

USER_HOME="${1:?usage: provision-bashrc-trigger.sh <user_home>}"
BASHRC="$USER_HOME/.bashrc"

info() { echo -e "\033[0;32m[bashrc-trigger]\033[0m  $*"; }

[ -f "$BASHRC" ] || { info ".bashrc not found — skipping"; exit 0; }

if grep -q 'post-reboot' "$BASHRC"; then
    info "post-reboot trigger already present"
    exit 0
fi

printf '\n# LCARS post-reboot bootstrap (one-shot, gated by sentinels)\nif [ -f /home/private/.install_ok ] && [ ! -f /home/private/.fleet_ready ]; then\n    bash /local/LCARS/fleet/provisioning/post-reboot.sh\nfi\n' >> "$BASHRC"
info "post-reboot trigger → $BASHRC"
