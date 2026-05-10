#!/bin/bash
# DEPLOY: instance-util

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-restart.sh
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
#     | MODULE: RESTART         | SUBSYSTEM: FLEET / LIFECYCLE    |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Restarts a fleet instance in its tmux pane.              |
#     |  Kills, re-sources, re-launches with clean state.         |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     DEPLOY: instance-util
#
#           ______________________________________________________
#          /          LCARS FLEET - FEDERATION DATABASE           \
#         |   ________   __________________________________________\
#         |  |  2026  |  | SOURCE: fleet-restart.sh
#         |  |________|  | AUTHOR: LORDZURP
#
#     [EN]
#     fleet-restart.sh — Restarts a fleet instance in its tmux pane.
#     Kills, re-sources, re-launches with clean state.
#
#
# --- END HEADER ---


set -euo pipefail

# --- Fleet env ---
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/fleet-env.sh"

# AUDIT-011: restart is fleet-wide by design — instance arg is NOT supported.
# light_off + light_on operate on the entire fleet session.
if [[ $# -gt 0 ]]; then
    echo "ERROR: fleet-restart does not support per-instance restart — it restarts the entire fleet" >&2
    echo "  To restart a single agent, use: fleet-dispatch.sh --headless <role> <prompt>" >&2
    exit 1
fi
bash "$HOME/fleet/light_off.sh" || exit 0
sleep 2
bash "$HOME/fleet/light_on.sh"
