#!/bin/bash
# DEPLOY: instance-util

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-shutdown-clean.sh
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
#     | MODULE: SHUTDOWN-CLEAN  | SUBSYSTEM: FLEET / LIFECYCLE    |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Moves pending ACTIONS to DONE as [interrupted] on        |
#     |  fleet shutdown. Keeps context clean for next boot.       |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     DEPLOY: instance-util
#
#           ______________________________________________________
#          /          LCARS FLEET - FEDERATION DATABASE           \
#         |   ________   __________________________________________\
#         |  |  2026  |  | SOURCE: fleet-shutdown-clean.sh
#         |  |________|  | AUTHOR: LORDZURP
#
#     [EN]
#     fleet-shutdown-clean.sh — Moves pending ACTIONS to DONE as [interrupted] on
#     fleet shutdown. Keeps context clean for next boot.
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

readonly HANDOFF_DIR="$FLEET_HANDOFFS"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M')
readonly TIMESTAMP

mapfile -t ROLES < <(fleet_roles)

for role in "${ROLES[@]}"; do
    file="$HANDOFF_DIR/${role}-handoff.md"
    [[ -f "$file" ]] || continue

    # Extract ACTIONS content (non-blank lines between ## ACTIONS and ## DONE)
    actions=$(awk '/^## ACTIONS$/{p=1;next} /^## /{p=0} p' "$file" | grep -v '^[[:space:]]*$' || true)
    [[ -z "$actions" ]] && continue

    # Atomic rewrite: clear ACTIONS, inject [interrupted] entry at top of DONE
    # IEC 61508: flock covers the entire awk+mv block to prevent partial writes
    (
        flock 9
        # IEC 61508: use ENVIRON instead of -v to avoid backslash interpretation
        ts="$TIMESTAMP" body="$actions" awk '
            /^## ACTIONS$/ { print; in_actions=1; next }
            /^## DONE$/    {
                in_actions=0
                print ""
                print "## DONE"
                print ""
                print "### " ENVIRON["ts"] " — [interrupted] fleet shutdown"
                print ""
                print ENVIRON["body"]
                print ""
                next
            }
            in_actions     { next }
            { print }
        ' "$file" > "${file}.tmp" && mv -f "${file}.tmp" "$file"
    ) 9>"${file}.lock"

    echo "[shutdown-clean] ${role}-handoff.md — ACTIONS moved to DONE [interrupted]"
done
