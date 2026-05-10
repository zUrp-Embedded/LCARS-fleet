#!/bin/bash
# DEPLOY: instance-util

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-session-log.sh
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
#     | MODULE: SESSION-LOG     | SUBSYSTEM: FLEET / METRICS      |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Logs session duration at handoff/offline.                |
#     |  Anti-corruption: long sessions = drift risk signal.      |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     DEPLOY: instance-util
#
#           ______________________________________________________
#          /          LCARS FLEET - FEDERATION DATABASE           \
#         |   ________   __________________________________________\
#         |  |  2026  |  | SOURCE: fleet-session-log.sh
#         |  |________|  | AUTHOR: LORDZURP
#
#     [EN]
#     fleet-session-log.sh — Logs session duration at handoff/offline.
#     Anti-corruption: long sessions = drift risk signal.
#
#
# --- END HEADER ---


# --help: extract [EN] section from this header
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && {
    sed -n '/^#     \[EN\]/,/^# --- END HEADER ---/{/\[EN\]/d; /END HEADER/d; s/^#     //; s/^#[[:space:]]*$//; p}' "$0"
    exit 0
}

set -euo pipefail

# --- Fleet env ---
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/fleet-env.sh"

readonly INSTANCE="${FLEET_INSTANCE:-unknown}"
readonly ACTION="${1:-handoff}"
readonly LOG="$FLEET_LOGS/session-durations.log"
readonly START_FILE="${FLEET_STATE_DIR:-/home/fleet-state}/run/session-start-${INSTANCE}"

mkdir -p "$(dirname "$LOG")"

NOW=$(date +%s)
readonly NOW
TIMESTAMP=$(date "+%Y-%m-%d %H:%M")
readonly TIMESTAMP

if [[ ! -f "$START_FILE" ]]; then
    echo "$TIMESTAMP,$INSTANCE,unknown,$ACTION" >> "$LOG"
    echo "[session-log] no start timestamp found for $INSTANCE — logged as unknown"
    exit 0
fi

START_TS=$(cat "$START_FILE" 2>/dev/null || echo 0)
[[ "$START_TS" =~ ^[0-9]+$ ]] || START_TS=0
if [[ "$START_TS" -eq 0 ]]; then
    echo "$TIMESTAMP,$INSTANCE,unknown,$ACTION" >> "$LOG"
    exit 0
fi

DURATION_SEC=$(( NOW - START_TS ))
DURATION_MIN=$(( DURATION_SEC / 60 ))

WARN=""
if [[ $DURATION_MIN -ge 180 ]]; then
    WARN=" WARNING:drift-risk"
elif [[ $DURATION_MIN -ge 120 ]]; then
    WARN=" NOTICE:long-session"
fi

echo "$TIMESTAMP,$INSTANCE,${DURATION_MIN}m,$ACTION$WARN" >> "$LOG"
echo "[session-log] $INSTANCE — session ${DURATION_MIN}min ($ACTION)$WARN"

# Cleanup start file
rm -f "$START_FILE"
