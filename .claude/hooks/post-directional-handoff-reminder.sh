#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: post-directional-handoff-reminder.sh
#     |  |________|  | AUTHOR: LORDZURP
#     |   ________   | SYSTEM: LCARS-FLEET v5.4
#     |  |  v5.4  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS-FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: HANDOFF-REMIND  | SUBSYSTEM: HOOKS / IPC          |
#     | LICENSE: AGPL-3         | STARDATE: 2026.090              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Reminds to update directional handoff files.             |
#     |  Triggered after Write/Edit tool operations.              |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     Rappelle de mettre à jour les fichiers handoff directionnels après Write/Edit.
#     Injecte un contexte additionnel si le fichier modifié impacte un handoff.
#
#     [EN]
#     NAME
#         post-directional-handoff-reminder.sh — remind to update handoff after file edits
#
#     INTERFACE
#         Ring:    CC Runtime (hook — PostToolUse, matcher: Write|Edit)
#         Input:   stdin JSON (tool_input with file_path)
#         Output:  additionalContext reminder if handoff update needed
#
#     EXIT CODES
#         0    Always
#
# --- END HEADER ---

set -uo pipefail          # PAS -e : un rappel qui echoue ne doit pas faire echouer ce qu'il rappelle.

PAYLOAD=$(cat)
FILE_PATH=$(echo "$PAYLOAD" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('file_path',''))" 2>/dev/null)

[[ -z "$FILE_PATH" ]] && exit 0

BASENAME=$(basename "$FILE_PATH")

case "$BASENAME" in
    *-handoff.md|starfleet-notes.md)
        INSTANCE=$(cat "$HOME/.claude/instance-name" 2>/dev/null || basename "$HOME")
        OWN_HANDOFF="${INSTANCE}-handoff.md"
        [[ "$BASENAME" == "$OWN_HANDOFF" ]] && exit 0
        echo "[handoff-sync] $BASENAME written — update $FLEET_HANDOFFS/$OWN_HANDOFF now (STATE: date, ref, action, status)." >&2
        ;;
esac

exit 0
