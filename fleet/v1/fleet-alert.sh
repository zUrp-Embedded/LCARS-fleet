#!/bin/bash
# DEPLOY: instance-util

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-alert.sh
#     |  |________|  | AUTHOR: STARFLEET
#     |   ________   | SYSTEM: LCARS-FLEET v5.4
#     |  |  v5.4  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS-FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: FLEET-ALERT     | SUBSYSTEM: FLEET / IPC          |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Visual alert — LCARS gyrophare on tmux status bar.       |
#     |  Blinks until target agent's inbox is empty.              |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     fleet-alert.sh — gyrophare visuel LCARS sur le bandeau tmux.
#     Clignote bleu/orange tant que l'inbox de l'agent cible contient des messages.
#     Lancé en background par fleet-wake-notify.sh pour les agents non-wakeable.
#
#     [EN]
#     NAME
#         fleet-alert.sh — visual LCARS alert on tmux status bar
#
#     SYNOPSIS
#         fleet-alert.sh <agent> &
#         fleet-alert.sh --stop
#
#     DESCRIPTION
#         Blinks the tmux status bar (blue/orange LCARS palette) until
#         the target agent's inbox is empty. Runs as a background loop
#         (disowned). Only one alert can run at a time (PID file guard).
#         Targets the agent's standalone session if it exists, otherwise
#         the main "fleet" session. Self-stops when inbox empties.
#         EXIT trap restores the tmux status bar color.
#
#     INTERFACE
#         Ring:    1 (support)
#         Input:   agent name, tmux sessions, $FLEET_SPOOL_INBOX/<agent>/*.md
#         Output:  tmux status-bg color changes (visual), PID file /tmp/fleet-alert.pid
#         JSON:    non
#
#     OPTIONS
#         agent     Target agent name (starts blinking)
#         --stop    No-op (loop self-stops when inbox empties)
#
#     EXIT CODES
#         0    Alert started, already running, or stopped
#         1    Missing agent argument
#
#     EXAMPLES
#         fleet-alert.sh architect &
#         fleet-alert.sh --stop
#
#     SEE ALSO
#         fleet-wake-notify.sh, wake-instance.sh, fleet-send.sh
#
# --- END HEADER ---

# --help: extract [EN] section from this header
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && {
    sed -n '/^#     \[EN\]/,/^# --- END HEADER ---/{/\[EN\]/d; /END HEADER/d; s/^#     //; s/^#[[:space:]]*$//; p}' "$0"
    exit 0
}

set -uo pipefail

# Source fleet-env
FLEET_ENV="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/fleet-env.sh"
[ -f "$FLEET_ENV" ] && source "$FLEET_ENV"

SOCK="${FLEET_TMUX_SOCK:-/tmp/tmux-$(id -u)/default}"
_RUN_DIR="${FLEET_STATE_DIR:-/home/fleet-state}/run"
mkdir -p "$_RUN_DIR" 2>/dev/null || true
PIDFILE="$_RUN_DIR/fleet-alert.pid"
INBOX_ROOT="${FLEET_SPOOL_INBOX:-/var/spool/fleet/inbox}"

# --- Stop mode ---
if [[ "${1:-}" == "--stop" ]]; then
    # No explicit kill needed — the blink loop self-stops when inbox is empty.
    # If the loop is still running, it will detect the empty inbox within 0.5s.
    # The EXIT trap in _blink restores the tmux style automatically.
    exit 0
fi

AGENT="${1:?usage: fleet-alert.sh <agent> | fleet-alert.sh --stop}"

# --- Guard: one alert at a time ---
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "[fleet-alert] already running (pid $(cat "$PIDFILE"))" >&2
    exit 0
fi

# --- Background blink loop ---
_blink() {
    echo $$ > "$PIDFILE"

    # Determine target session
    if tmux has-session -t "$AGENT" 2>/dev/null; then
        TARGET_SESSION="$AGENT"
    else
        TARGET_SESSION="fleet"
    fi

    trap 'rm -f "$PIDFILE"; tmux set -t "$TARGET_SESSION" status-bg colour233 2>/dev/null; exit 0' EXIT TERM INT

    local inbox="$INBOX_ROOT/$AGENT"

    while true; do
        # Stop if inbox is empty
        if ! ls "$inbox"/*.md &>/dev/null; then
            echo "[fleet-alert] inbox empty — alert stopped" >&2
            break
        fi

        # LCARS gyrophare: blue ↔ orange (1Hz, no sudo, no refresh-client)
        tmux set -t "$TARGET_SESSION" status-bg colour69 2>/dev/null
        sleep 0.5

        tmux set -t "$TARGET_SESSION" status-bg colour208 2>/dev/null
        sleep 0.5
    done
}

_blink &
disown
echo "[fleet-alert] gyrophare started for $AGENT (pid $!)" >&2
