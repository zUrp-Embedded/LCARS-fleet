#!/bin/bash
# DEPLOY: instance-util

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-lock-cleanup.sh
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
#     | MODULE: LOCK-CLEANUP    | SUBSYSTEM: FLEET / MAINT        |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Removes stale lock files left by crashed builds.         |
#     |  Safe to run when no active builds are running.           |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     DEPLOY: instance-util
#
#           ______________________________________________________
#          /          LCARS FLEET - FEDERATION DATABASE           \
#         |   ________   __________________________________________\
#         |  |  2026  |  | SOURCE: fleet-lock-cleanup.sh
#         |  |________|  | AUTHOR: LORDZURP
#
#     [EN]
#     fleet-lock-cleanup.sh — Removes stale lock files left by crashed builds.
#     Safe to run when no active builds are running.
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

readonly LOCK_BASE="/tmp/handoff-locks"
readonly MAX_AGE_SECS=3600

[ -d "$LOCK_BASE" ] || exit 0

NOW=$(date +%s)
CLEANED=0

for LOCK_DIR in "$LOCK_BASE"/*.lock.d; do
    [ -d "$LOCK_DIR" ] || continue

    if [ -f "$LOCK_DIR/owner" ]; then
        STORED=$(cat "$LOCK_DIR/owner")
        STORED_TS=$(echo "$STORED" | cut -d: -f3)
        if [ -n "$STORED_TS" ] && [ "$STORED_TS" -gt 0 ] 2>/dev/null; then
            AGE=$(( NOW - STORED_TS ))
            if [ "$AGE" -gt "$MAX_AGE_SECS" ]; then
                echo "[fleet-lock-cleanup] Removing stale lock: $(basename "$LOCK_DIR") (age: ${AGE}s, owner: $STORED)" >&2
                rm -rf "$LOCK_DIR"
                CLEANED=$(( CLEANED + 1 ))
            fi
        else
            echo "[fleet-lock-cleanup] Removing malformed lock: $(basename "$LOCK_DIR") (no valid timestamp)" >&2
            rm -rf "$LOCK_DIR"
            CLEANED=$(( CLEANED + 1 ))
        fi
    else
        echo "[fleet-lock-cleanup] Removing owner-less lock: $(basename "$LOCK_DIR")" >&2
        rm -rf "$LOCK_DIR"
        CLEANED=$(( CLEANED + 1 ))
    fi
done

[ "$CLEANED" -gt 0 ] && echo "[fleet-lock-cleanup] Removed $CLEANED stale lock(s)"
exit 0
