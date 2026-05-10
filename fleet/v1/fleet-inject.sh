#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-inject.sh
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
#     | MODULE: MSG-INJECT      | SUBSYSTEM: FLEET / IPC          |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Injects a message into a running Claude session.         |
#     |  Uses tmux send-keys to deliver text to instance.         |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#           ______________________________________________________
#          /          LCARS FLEET - FEDERATION DATABASE           \
#         |   ________   __________________________________________\
#         |  |  2026  |  | SOURCE: fleet-inject.sh
#         |  |________|  | AUTHOR: LORDZURP
#         |   ________   | SYSTEM: LCARS-FLEET v5.4
#
#     [EN]
#     fleet-inject.sh — Injects a message into a running Claude session.
#     Uses tmux send-keys to deliver text to instance.
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

SECTION="${1:?usage: fleet-inject.sh <done|actions> [--file <handoff>] [snippet-file]}"
shift

HANDOFF_FILE=""
SNIPPET_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --file)
            HANDOFF_FILE="${2:?--file requiert un chemin}"
            shift 2
            ;;
        *)
            SNIPPET_FILE="$1"
            shift
            ;;
    esac
done

INSTANCE="${FLEET_INSTANCE:-$(hostname)}"
HANDOFF_FILE="${HANDOFF_FILE:-$FLEET_HANDOFFS/${INSTANCE}-handoff.md}"
SNIPPET_FILE="${SNIPPET_FILE:-${FLEET_STATE_DIR:-/home/fleet-state}/run/fleet-snippet-${INSTANCE}.md}"
readonly SECTION HANDOFF_FILE SNIPPET_FILE

[[ -f "$HANDOFF_FILE" ]] || { echo "ERROR: $HANDOFF_FILE introuvable" >&2; exit 1; }
[[ -f "$SNIPPET_FILE" ]] || { echo "ERROR: snippet $SNIPPET_FILE introuvable" >&2; exit 1; }
[[ -s "$SNIPPET_FILE" ]] || { echo "ERROR: snippet $SNIPPET_FILE vide" >&2; exit 1; }

DATE=$(date '+%Y-%m-%d %H:%M')
INSERT_TMP=$(mktemp)
trap 'rm -f "$INSERT_TMP" 2>/dev/null' EXIT

case "$SECTION" in
    done)
        TITLE=$(head -1 "$SNIPPET_FILE")
        # Bloc formaté : ligne vide + header daté + corps + ligne vide
        {
            echo ""
            echo "### ${DATE} — ${TITLE}"
            tail -n +2 "$SNIPPET_FILE"
            echo ""
        } > "$INSERT_TMP"
        ANCHOR="^## DONE"
        LABEL="DONE: ${TITLE}"
        ;;
    actions)
        # Contenu brut — lignes [ ] telles quelles
        cp "$SNIPPET_FILE" "$INSERT_TMP"
        ANCHOR="^## ACTIONS"
        LABEL="ACTIONS: $(wc -l < "$SNIPPET_FILE") ligne(s)"
        ;;
    *)
        echo "ERROR: section '${SECTION}' inconnue — utiliser: done | actions" >&2
        rm -f "$INSERT_TMP"
        exit 1
        ;;
esac

ANCHOR_PLAIN="${ANCHOR#^}"
grep -q "^${ANCHOR_PLAIN}" "$HANDOFF_FILE" || {
    echo "ERROR: anchor '${ANCHOR_PLAIN}' absent dans $(basename "$HANDOFF_FILE") — injection annulée" >&2
    rm -f "$INSERT_TMP"
    exit 1
}

# JUPITER-008: flock on handoff file to serialize concurrent writers
(
    flock -w 10 200 || { echo "ERROR: could not acquire lock on $HANDOFF_FILE" >&2; exit 1; }
    awk -v ins="$INSERT_TMP" -v anchor="$ANCHOR" '
$0 ~ anchor {
    print
    while ((getline line < ins) > 0) print line
    close(ins)
    next
}
{ print }
' "$HANDOFF_FILE" > "${HANDOFF_FILE}.tmp" && mv -f "${HANDOFF_FILE}.tmp" "$HANDOFF_FILE"
) 200>"${HANDOFF_FILE}.lock"

rm -f "$INSERT_TMP"
echo ">>> $(basename "$HANDOFF_FILE") ${LABEL}"
