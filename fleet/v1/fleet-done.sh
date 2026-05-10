#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-done.sh
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
#     | MODULE: TASK-DONE       | SUBSYSTEM: FLEET / STATE        |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Marks the current task as done in STATE.                 |
#     |  Sets action=done, status=idle, clears blocker.           |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#           ______________________________________________________
#          /          LCARS FLEET - FEDERATION DATABASE           \
#         |   ________   __________________________________________\
#         |  |  2026  |  | SOURCE: fleet-done.sh
#         |  |________|  | AUTHOR: LORDZURP
#         |   ________   | SYSTEM: LCARS-FLEET v5.4
#
#     [EN]
#     fleet-done.sh — Marks the current task as done in STATE.
#     Sets action=done, status=idle, clears blocker.
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

TITLE="${1:?usage: fleet-done.sh <titre> [corps]}"
shift
BODY="${*:-}"

INSTANCE="${FLEET_INSTANCE:-$(hostname)}"
FILE="$FLEET_HANDOFFS/${INSTANCE}-handoff.md"

[[ -f "$FILE" ]] || { echo "ERROR: $FILE introuvable" >&2; exit 1; }
grep -q "^## DONE" "$FILE" || { echo "ERROR: anchor '## DONE' absent dans $(basename "$FILE") — injection annulée" >&2; exit 1; }

DATE=$(date '+%Y-%m-%d %H:%M')

(
flock -w 10 200 || { echo "ERROR: lock on $FILE" >&2; exit 1; }
TITLE="$TITLE" BODY="$BODY" DATE="$DATE" awk '
/^## DONE/ {
    print
    print ""
    print "### " ENVIRON["DATE"] " — " ENVIRON["TITLE"]
    if (ENVIRON["BODY"] != "") print ENVIRON["BODY"]
    print ""
    next
}
{ print }
' "$FILE" > "${FILE}.tmp.$$" && mv -f "${FILE}.tmp.$$" "$FILE"
) 200>"${FILE}.lock"

echo ">>> ${INSTANCE} DONE: ${TITLE}"
