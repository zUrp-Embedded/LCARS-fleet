#!/bin/bash
# DEPLOY: instance-util

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-bug.sh
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
#     | MODULE: BUG-REPORT      | SUBSYSTEM: FLEET / IPC          |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Sends a bug report to starfleet via spool IPC.           |
#     |  Used by dev/qualifier to surface issues.                 |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     DEPLOY: instance-util
#
#           ______________________________________________________
#          /          LCARS FLEET - FEDERATION DATABASE           \
#         |   ________   __________________________________________\
#         |  |  2026  |  | SOURCE: fleet-bug.sh
#         |  |________|  | AUTHOR: LORDZURP
#
#     [EN]
#     fleet-bug.sh — Sends a bug report to starfleet via spool IPC.
#     Used by dev/qualifier to surface issues.
#
#
# --- END HEADER ---


# --help: extract [EN] section from this header
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && {
    sed -n '/^#     \[EN\]/,/^# --- END HEADER ---/{/\[EN\]/d; /END HEADER/d; s/^#     //; s/^#[[:space:]]*$//; p}' "$0"
    exit 0
}

set -euo pipefail

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/fleet-env.sh"

readonly SOURCE="${1:?usage: fleet-bug.sh <source> <platform> <description>}"
readonly PLATFORM="${2:?usage: fleet-bug.sh <source> <platform> <description>}"
shift 2
readonly DESCRIPTION="${*:?usage: fleet-bug.sh <source> <platform> <description>}"

DATE=$(date '+%Y-%m-%d')
readonly DATE
readonly ENTRY="BUG ${DATE} | ${SOURCE} | ${PLATFORM} | ${DESCRIPTION}"

SEND="$(dirname "${BASH_SOURCE[0]}")/fleet-send.sh"
readonly SEND
if [ -x "$SEND" ]; then
    echo "$ENTRY" | "$SEND" starfleet "bug-report" 2>/dev/null
    echo ">>> bug report sent to starfleet: ${ENTRY}"
else
    echo "ERROR: fleet-send.sh not found" >&2
    exit 1
fi
