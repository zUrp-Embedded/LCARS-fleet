#!/bin/bash
# DEPLOY: instance-util

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-inbox-watch-daemon.sh
#     |  |________|  | AUTHOR: LORDZURP
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
#     | MODULE: INBOX-WATCH     | SUBSYSTEM: IPC / WAKE           |
#     | LICENSE: AGPL-3         | STARDATE: 2026.090              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Fallback wake daemon — inotifywait on inbox.             |
#     |  Used when systemd user units are unavailable.            |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     Daemon de surveillance inbox par inotifywait (fallback quand systemd absent).
#     Boucle infinie : détecte les nouveaux messages, appelle fleet-wake-notify.sh.
#     PID file dans /tmp, backoff 5s en cas d'erreur inotifywait.
#
#     [EN]
#     NAME
#         fleet-inbox-watch-daemon.sh — fallback inbox watch daemon via inotifywait
#
#     SYNOPSIS
#         fleet-inbox-watch-daemon.sh <agent> [stop]
#
#     DESCRIPTION
#         Watches an agent's inbox directory for new .md files using
#         inotifywait (close_write + moved_to events). On detection,
#         calls fleet-wake-notify.sh to alert the agent. Runs as a
#         background daemon with PID file in /tmp. Includes 200ms
#         debounce and 5s backoff on inotifywait failure. Used as
#         fallback when systemd user units are not available (WSL
#         without systemd=true, Docker, bare-metal).
#
#     INTERFACE
#         Ring:    3 (support — systemd)
#         Input:   $FLEET_SPOOL_INBOX/<agent>/*.md via inotifywait
#         Output:  fleet-wake-notify.sh calls, PID file in /tmp
#         JSON:    non
#
#     OPTIONS
#         agent    Agent name whose inbox to watch (required)
#         stop     Stop the running daemon for this agent
#
#     EXIT CODES
#         0    Daemon started (or stopped, or already running)
#         1    inotifywait missing or inbox dir absent
#
#     EXAMPLES
#         fleet-inbox-watch-daemon.sh engineer
#         fleet-inbox-watch-daemon.sh engineer stop
#
#     SEE ALSO
#         fleet-wake-notify.sh, fleet-send.sh, fleet-inbox-read.sh
#
# --- END HEADER ---

# --help: extract [EN] section from this header
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && {
    sed -n '/^#     \[EN\]/,/^# --- END HEADER ---/{/\[EN\]/d; /END HEADER/d; s/^#     //; s/^#[[:space:]]*$//; p}' "$0"
    exit 0
}

set -euo pipefail

AGENT="${1:?usage: fleet-inbox-watch-daemon.sh <agent> [stop]}"
ACTION="${2:-start}"

# Source fleet-env
FLEET_ENV="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/fleet-env.sh"
[ -f "$FLEET_ENV" ] && source "$FLEET_ENV"

INBOX_DIR="${FLEET_SPOOL_INBOX:-/var/spool/fleet/inbox}/$AGENT"
WAKE_NOTIFY="$(dirname "${BASH_SOURCE[0]}")/fleet-wake-notify.sh"
_RUN_DIR="${FLEET_STATE_DIR:-/home/fleet-state}/run"
mkdir -p "$_RUN_DIR" 2>/dev/null || true
PID_FILE="$_RUN_DIR/fleet-inbox-watch-${AGENT}.pid"

# --- Stop ---
if [[ "$ACTION" == "stop" ]]; then
    if [ -f "$PID_FILE" ]; then
        PID="$(cat "$PID_FILE")"
        if kill -0 "$PID" 2>/dev/null; then
            kill "$PID" && echo "[inbox-watch] stopped daemon for $AGENT (pid $PID)" >&2
        fi
        rm -f "$PID_FILE"
    else
        echo "[inbox-watch] no running daemon for $AGENT" >&2
    fi
    exit 0
fi

# --- Already running check ---
if [ -f "$PID_FILE" ]; then
    PID="$(cat "$PID_FILE")"
    if kill -0 "$PID" 2>/dev/null; then
        echo "[inbox-watch] daemon already running for $AGENT (pid $PID)" >&2
        exit 0
    fi
    rm -f "$PID_FILE"
fi

# --- Require inotifywait ---
if ! command -v inotifywait &>/dev/null; then
    echo "[inbox-watch] inotifywait not found — install inotify-tools for fallback daemon" >&2
    exit 1
fi

# --- Require inbox dir ---
if [ ! -d "$INBOX_DIR" ]; then
    echo "[inbox-watch] inbox dir $INBOX_DIR absent — run deploy.sh first" >&2
    exit 1
fi

# --- Watch loop (background) ---
_watch_loop() {
    while true; do
        # -e close_write: file fully written (mv from temp is close_write on dest)
        # -e moved_to: fleet-send.sh uses atomic write (temp + mv)
        if inotifywait -q -e close_write -e moved_to "$INBOX_DIR" 2>/dev/null; then
            # Small debounce — multiple files may land in the same second
            sleep 0.2
            # Check for actual .md files (not .lock or .consumed/)
            if find "$INBOX_DIR" -maxdepth 1 -name '*.md' -not -name '.*' 2>/dev/null | grep -q .; then
                "$WAKE_NOTIFY" "$AGENT" "spool-event" 2>/dev/null || true
            fi
        else
            # inotifywait exited unexpectedly — backoff before retry
            sleep 5
        fi
    done
}

_watch_loop &
DAEMON_PID=$!
echo "$DAEMON_PID" > "$PID_FILE"
echo "[inbox-watch] daemon started for $AGENT (pid $DAEMON_PID)" >&2
