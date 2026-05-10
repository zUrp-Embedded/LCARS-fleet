#!/bin/bash
#
#     +-----------------------------------------------------------+
#     | [ LCARS-FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: STEWARD-WATCHDOG | SUBSYSTEM: FLEET / MONITOR    |
#     | LICENSE: AGPL-3          | STARDATE: 2026.068            |
#     +---------------------------+---------------------------------+
#
#     [FR]
#     steward-watchdog.sh — Watchdog cron pour l'instance steward (30 min).
#
#     Vérifie si le pane steward est vivant dans la session tmux fleet.
#     N'effectue aucune action corrective : log uniquement.
#     Le redémarrage est de la responsabilité de fleet-launch.sh (~/start).
#
#     Cron configuré par post-install-steward.sh :
#       */30 * * * * bash ~/.local/bin/steward-watchdog.sh >> /tmp/steward-watchdog.log 2>&1
#
#     [EN]
#     steward-watchdog.sh — 30-min cron watchdog for the steward instance.
#     Checks if steward tmux pane is alive. Logs only — does not restart.
#

set -euo pipefail

# --- Fleet env ---
source "$(dirname "${BASH_SOURCE[0]}")/fleet-env.sh"

TIMESTAMP="$(date '+%Y-%m-%d %H:%M')"
FLEET_SESSION="fleet"
STEWARD_WINDOW="monitor"
STEWARD_PANE="monitor.2"  # bottom-left pane (see fleet-launch.sh)

# ─── Check if fleet session exists ───────────────────────────────────────────
if ! tmux has-session -t "$FLEET_SESSION" 2>/dev/null; then
    echo "[$TIMESTAMP] fleet session not running — steward offline (expected if ~/start not launched)"
    exit 0
fi

# ─── Check if steward pane is alive ──────────────────────────────────────────
PANE_PID=$(tmux display-message -t "${FLEET_SESSION}:${STEWARD_PANE}" -p "#{pane_pid}" 2>/dev/null || echo "")
if [[ -z "$PANE_PID" ]]; then
    echo "[$TIMESTAMP] WARN — steward pane ${STEWARD_PANE} not found in session ${FLEET_SESSION}"
    exit 0
fi

# Check the process tree under pane PID
if ps --ppid "$PANE_PID" 2>/dev/null | grep -q "claude"; then
    echo "[$TIMESTAMP] OK — steward alive (pane=${STEWARD_PANE} pid=${PANE_PID})"
else
    echo "[$TIMESTAMP] WARN — steward pane alive but claude not running (pid=${PANE_PID}) — run ~/start to restart"
fi
