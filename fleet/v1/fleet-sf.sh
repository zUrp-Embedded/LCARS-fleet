#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-sf.sh
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
#     | MODULE: FLEET-SF        | SUBSYSTEM: FLEET / CLI          |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Launches starfleet standalone in a dedicated tmux        |
#     |  session (fleet socket). FLEET_CONTEXT=standalone.        |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     Lance StarFleet standalone dans une session tmux dédiée.
#     Contexte standalone : inbox IPC ignorée, sessions interactives longues.
#     Symlink /usr/local/bin/fleet-sf -> ce fichier (via deploy.sh).
#
#     [EN]
#     NAME
#         fleet-sf.sh — launch StarFleet standalone in a dedicated tmux session
#
#     SYNOPSIS
#         fleet-sf.sh
#
#     DESCRIPTION
#         Creates or attaches to a tmux session named "starfleet" on the
#         fleet socket. Sets FLEET_CONTEXT=standalone (disables IPC inbox
#         polling). If StarFleet is already running in a fleet monitor pane,
#         terminates it first (standalone takes precedence). No .deploy_ok
#         gate — StarFleet must be accessible to RUN the onboarding.
#
#     INTERFACE
#         Ring:    4 (support)
#         Input:   fleet.yaml (tmux socket path), tmux state
#         Output:  tmux session "starfleet" on fleet socket
#         JSON:    non
#
#     EXIT CODES
#         0    Session created/attached (exec replaces process)
#
#     EXAMPLES
#         fleet-sf
#         fleet-sf.sh
#
#     SEE ALSO
#         fleet-launch.sh, fleet-arch.sh, light_on.sh, fleet-env.sh
#
# --- END HEADER ---

set -euo pipefail

if tmux has-session -t starfleet 2>/dev/null; then
    exec tmux attach -t starfleet
fi

# --- Kill starfleet-fleet in monitor if running ---
FLEET_PANE=$(tmux list-panes -a \
    -F '#{@fleet-role} #{pane_id}' 2>/dev/null \
    | awk '$1 == "starfleet" { print $2; exit }')
if [ -n "$FLEET_PANE" ]; then
    # Send interrupt + exit to the fleet pane
    tmux send-keys -t "$FLEET_PANE" C-c 2>/dev/null || true
    sleep 0.5
    tmux send-keys -t "$FLEET_PANE" "exit" Enter 2>/dev/null || true
    echo "[fleet-sf] starfleet-fleet terminated — standalone takes over" >&2
fi

tmux new-session -d -s starfleet \
    "sudo -i -u starfleet bash -c 'export FLEET_CONTEXT=standalone CLAUDE_AGENT_NAME=starfleet FLEET_LAUNCHED=1; exec claude --dangerously-skip-permissions --system-prompt-file ~/.claude/system-prompt.md'"
tmux select-pane -T "starfleet" -t starfleet
tmux rename-window -t starfleet "starfleet"
exec tmux attach -t starfleet
