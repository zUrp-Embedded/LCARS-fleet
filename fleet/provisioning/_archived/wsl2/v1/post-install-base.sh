#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: post-install-base.sh
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
#     | MODULE: POST-BASE       | SUBSYSTEM: PROV / WSL2          |
#     | LICENSE: AGPL-3         | STARDATE: 2026.063              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Base post-install shared by all WSL2 instances.          |
#     |  Shell config, Claude install, handoff bootstrap.         |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     post-install-base.sh — Module post-install pour instances de type 'base'
#
#     Appelé par post-install.sh pour les instances sans rôle spécifique.
#     Aucune configuration additionnelle requise.
#
#     [EN]
#     post-install-base.sh — Base post-install shared by all WSL2 instances.
#     Shell config, Claude install, handoff bootstrap.
#

GREEN='\033[0;32m'; NC='\033[0m'
echo -e "${GREEN}[post-install-base]${NC}  No additional configuration for type 'base'."
