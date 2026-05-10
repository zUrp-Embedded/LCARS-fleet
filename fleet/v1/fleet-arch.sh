#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-arch.sh
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
#     | MODULE: FLEET-ARCH      | SUBSYSTEM: FLEET / CLI          |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Launches architect standalone in a dedicated tmux        |
#     |  session (fleet socket). FLEET_CONTEXT=standalone.        |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     Lance Architect standalone dans une session tmux dédiée.
#     Contexte standalone : sessions interactives avec l'user.
#     Symlink /usr/local/bin/fleet-arch -> ce fichier (via deploy.sh).
#
#     [EN]
#     NAME
#         fleet-arch.sh — launch Architect standalone in a dedicated tmux session
#
#     SYNOPSIS
#         fleet-arch.sh
#
#     DESCRIPTION
#         Creates or attaches to a tmux session named "architect" on the
#         fleet socket. Sets FLEET_CONTEXT=standalone for interactive user
#         sessions. Requires .deploy_ok (fleet must be deployed first).
#
#     INTERFACE
#         Ring:    4 (support)
#         Input:   fleet.yaml (tmux socket path), /home/fleet-state/.deploy_ok
#         Output:  tmux session "architect" on fleet socket
#         JSON:    non
#
#     EXIT CODES
#         0    Session created/attached (exec replaces process)
#         1    Fleet not deployed (.deploy_ok missing)
#
#     EXAMPLES
#         fleet-arch
#         fleet-arch.sh
#
#     SEE ALSO
#         fleet-sf.sh, fleet-launch.sh, light_on.sh
#
# --- END HEADER ---

set -euo pipefail

[ -f /home/fleet-state/.deploy_ok ] || { echo "Fleet pas déployée. Ouvre un terminal pour lancer le bootstrap."; exit 1; }

if tmux has-session -t architect 2>/dev/null; then
    exec tmux attach -t architect
fi

tmux new-session -d -s architect \
    "sudo -i -u architect bash -c 'export FLEET_CONTEXT=standalone CLAUDE_AGENT_NAME=architect FLEET_LAUNCHED=1; exec claude --dangerously-skip-permissions --system-prompt-file ~/.claude/system-prompt.md'"
tmux select-pane -T "architect" -t architect
tmux rename-window -t architect "architect"
exec tmux attach -t architect
