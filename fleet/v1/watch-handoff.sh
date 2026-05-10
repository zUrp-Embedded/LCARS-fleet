#!/bin/bash
# DEPLOY: instance-util

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: watch-handoff.sh
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
#     | MODULE: WATCH-HANDOFF   | SUBSYSTEM: FLEET / DISPLAY      |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Watches a handoff file for real-time changes.            |
#     |  Uses inotifywait or polling with colorized output.       |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     DEPLOY: instance-util
#
#           ______________________________________________________
#          /          LCARS FLEET - FEDERATION DATABASE           \
#         |   ________   __________________________________________\
#         |  |  2026  |  | SOURCE: watch-handoff.sh
#         |  |________|  | AUTHOR: LORDZURP
#
#     [EN]
#     watch-handoff.sh — Watches a handoff file for real-time changes.
#     Uses inotifywait or polling with colorized output.
#
#
# --- END HEADER ---


# --help: extract [EN] section from this header
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && {
    sed -n '/^#     \[EN\]/,/^# --- END HEADER ---/{/\[EN\]/d; /END HEADER/d; s/^#     //; s/^#[[:space:]]*$//; p}' "$0"
    exit 0
}

set -euo pipefail

if [[ -z "${1:-}" ]]; then
    echo "usage: watch-handoff.sh <file> [interval]" >&2
    exit 1
fi

readonly FILE="$1"
readonly INTERVAL="${2:-2}"
FLEET_DIR="$(dirname "$(realpath "$0")")"
readonly FLEET_DIR

# IEC 61508: wait for handoff file to exist before entering watch loop
while [ ! -f "$FILE" ]; do
    sleep 2
done

while true; do
    clear
    python3 "$FLEET_DIR/colorize-handoff.py" "$FILE"
    sleep "$INTERVAL"
done
