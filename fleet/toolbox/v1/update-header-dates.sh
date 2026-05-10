#!/usr/bin/env bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: update-header-dates.sh
#     |  |________|  | AUTHOR: STARFLEET
#     |   ________   | SYSTEM: LCARS-FLEET v6.0
#     |  |  v5.4  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS-FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: HEADER-DATES    | SUBSYSTEM: TOOLBOX / MAINT      |
#     | LICENSE: AGPL-3         | STARDATE: 2026.087              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Run before push to keep stardates current.               |
#     |                                                           |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#           ______________________________________________________
#          /          LCARS FLEET - FEDERATION DATABASE           \
#         |   ________   __________________________________________\
#         |  |  2026  |  | SOURCE: update-header-dates.sh
#         |  |________|  | AUTHOR: STARFLEET
#         |   ________   | SYSTEM: LCARS-FLEET v6.0
#
#     [EN]
#     update-header-dates.sh — Run before push to keep stardates current.
#
#
# --- END HEADER ---

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STARDATE=$(date '+%Y.%j')
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

COUNT=0
UPTODATE=0
TOTAL=0

while IFS= read -r -d '' FILE; do
    REL="${FILE#"$REPO_ROOT"/}"
    if grep -q "STARDATE: [0-9][0-9][0-9][0-9]\.[0-9][0-9][0-9]" "$FILE"; then
        CURRENT=$(grep -oE "STARDATE: [0-9]{4}\.[0-9]{3}" "$FILE" | head -1 | cut -d' ' -f2)
        TOTAL=$((TOTAL + 1))
        if [[ "$CURRENT" == "$STARDATE" ]]; then
            UPTODATE=$((UPTODATE + 1))
        elif [[ "$DRY_RUN" -eq 1 ]]; then
            echo "  WOULD UPDATE: $REL  ($CURRENT → $STARDATE)"
            COUNT=$((COUNT + 1))
        else
            sed "s/STARDATE: [0-9][0-9][0-9][0-9]\.[0-9][0-9][0-9]/STARDATE: ${STARDATE}/" "$FILE" > "${FILE}.tmp" && mv -f "${FILE}.tmp" "$FILE"
            echo "  updated: $REL"
            COUNT=$((COUNT + 1))
        fi
    fi
done < <(find "$REPO_ROOT" \
    -not -path '*/.git/*' \
    -not -path '*/docs/*' \
    -not -path '*/_archived/*' \
    \( -name "*.sh" -o -name "*.py" -o -name "*.yaml" -o -name "*.yml" -o -name "*.conf" \) \
    -print0)

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "→ ${COUNT} file(s) would update, ${UPTODATE} up-to-date, ${TOTAL} total  [ stardate: ${STARDATE} ]"
else
    echo "→ ${COUNT} file(s) updated, ${UPTODATE} already current  [ stardate: ${STARDATE} ]"
fi
