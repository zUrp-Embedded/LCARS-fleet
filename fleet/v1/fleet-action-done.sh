#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-action-done.sh
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
#     | MODULE: ACTION-DONE     | SUBSYSTEM: FLEET / IPC          |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Signals action completion in the fleet state.            |
#     |  Updates action=done + notifies waiting instance.         |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#           ______________________________________________________
#          /          LCARS FLEET - FEDERATION DATABASE           \
#         |   ________   __________________________________________\
#         |  |  2026  |  | SOURCE: fleet-action-done.sh
#         |  |________|  | AUTHOR: LORDZURP
#         |   ________   | SYSTEM: LCARS-FLEET v5.4
#
#     [EN]
#     fleet-action-done.sh — Signals action completion in the fleet state.
#     Updates action=done + notifies waiting instance.
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

FRAGMENT="${1:-}"
readonly FRAGMENT

INSTANCE="${FLEET_INSTANCE:-$(hostname)}"
FILE="$FLEET_HANDOFFS/${INSTANCE}-handoff.md"

[[ -f "$FILE" ]] || { echo "ERROR: $FILE introuvable" >&2; exit 1; }

# LLB-002 fix: restrict checkbox operations to ## ACTIONS section only
# Prevents marking checkboxes in ## DONE or other sections
if ! sed -n '/^## ACTIONS$/,/^## [A-Z]/p' "$FILE" | grep -q "^\[ \]"; then
    echo "WARNING: aucune action [ ] dans la section ACTIONS de $FILE" >&2
    exit 0
fi

if [[ -n "$FRAGMENT" ]]; then
    if ! sed -n '/^## ACTIONS$/,/^## [A-Z]/p' "$FILE" | grep "^\[ \]" | grep -qF "$FRAGMENT"; then
        echo "WARNING: aucune action [ ] correspondant à '${FRAGMENT}' dans ACTIONS" >&2
        exit 1
    fi
    (
    flock -w 10 200 || { echo "ERROR: lock on $FILE" >&2; exit 1; }
    awk -v frag="$FRAGMENT" '
    /^## ACTIONS$/ { in_actions = 1 }
    /^## [A-Z]/ && !/^## ACTIONS$/ { in_actions = 0 }
    in_actions && !done && /^\[ \]/ && index($0, frag) {
        sub(/^\[ \]/, "[x]")
        done = 1
    }
    { print }
    ' "$FILE" > "${FILE}.tmp" && mv -f "${FILE}.tmp" "$FILE"
    ) 200>"${FILE}.lock"
else
    (
    flock -w 10 200 || { echo "ERROR: lock on $FILE" >&2; exit 1; }
    awk '
    /^## ACTIONS$/ { in_actions = 1 }
    /^## [A-Z]/ && !/^## ACTIONS$/ { in_actions = 0 }
    in_actions && !done && /^\[ \]/ {
        sub(/^\[ \]/, "[x]")
        done = 1
    }
    { print }
    ' "$FILE" > "${FILE}.tmp" && mv -f "${FILE}.tmp" "$FILE"
    ) 200>"${FILE}.lock"
fi

echo ">>> ${INSTANCE} ACTION [x]: ${FRAGMENT:-(première)}"
