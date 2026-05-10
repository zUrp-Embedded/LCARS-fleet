#!/bin/bash
# DEPLOY: instance-util

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: drift-check.sh
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
#     | MODULE: DRIFT-CHECK     | SUBSYSTEM: HOOKS / LIFECYCLE    |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Alerte si >= 10 commits depuis dernier audit.            |
#     |                                                           |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     DEPLOY: instance-util
#
#           ______________________________________________________
#          /          LCARS FLEET - FEDERATION DATABASE           \
#         |   ________   __________________________________________\
#         |  |  2026  |  | SOURCE: drift-check.sh
#         |  |________|  | AUTHOR: LORDZURP
#
#     [EN]
#     drift-check.sh — Alerte si >= 10 commits depuis dernier audit.
#
#
# --- END HEADER ---


# --help: extract [EN] section from this header
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && {
    sed -n '/^#     \[EN\]/,/^# --- END HEADER ---/{/\[EN\]/d; /END HEADER/d; s/^#     //; s/^#[[:space:]]*$//; p}' "$0"
    exit 0
}

set -euo pipefail

# Source fleet-env for FLEET_STATE_DIR (caller may not have exported it)
FLEET_ENV="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/fleet-env.sh"
[ -f "$FLEET_ENV" ] && source "$FLEET_ENV"

readonly FLEET_STATE="${FLEET_STATE_DIR:-/home/fleet-state}"
CURRENT=$(cat "$FLEET_STATE/lcars-commit-count" 2>/dev/null || echo 0)
LAST=$(cat "$FLEET_STATE/lcars-commit-count-at-audit" 2>/dev/null || echo 0)
DIFF=$(( CURRENT - LAST ))

if (( DIFF >= 10 )); then
    echo ""
    echo "=== DRIFT AUDIT DUE ==="
    echo "${DIFF} commits on LCARS since last audit (threshold: 10)."
    echo "Run /drift-audit to start."
    echo "========================"
    echo ""
fi
