#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-blocker.sh
#     |  |________|  | AUTHOR: LORDZURP
#     |   ________   | SYSTEM: LCARS-FLEET v2.0
#     |  |  v2.0  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS-FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: BLOCKER         | SUBSYSTEM: FLEET / STATE        |
#     | LICENSE: AGPL-3         | STARDATE: 2026.063              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Sets or clears the blocker field in STATE.               |
#     |  Records blocking issues with optional context.           |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     fleet-blocker.sh — séquence complète "builder bloqué" en un seul appel
#
#     Remplace la séquence manuelle 4 étapes (snippet + inject + state + notify)
#     par une commande atomique. Réduit les erreurs de protocole sur Haiku.
#
#     Usage:
#       fleet-blocker.sh "<titre-court>" "<description>"
#
#     Ex: fleet-blocker.sh "cmake-dep-missing" "dependency not found in sysroot"
#
#     [EN]
#     fleet-blocker.sh — Sets or clears the blocker field in STATE.
#     Records blocking issues with optional context.
#

set -euo pipefail

# --- Fleet env ---
source "$(dirname "${BASH_SOURCE[0]}")/fleet-env.sh"

[[ -n "${FLEET_SESSION:-}" ]] || exit 0

BLOCKER="${1:?usage: fleet-blocker.sh <titre-court> <description>}"
DESC="${2:-}"

INSTANCE="${CLAUDE_AGENT_NAME:-$(cat "$HOME/.claude/instance-name" 2>/dev/null || hostname)}"
INSTANCE_LOWER="${INSTANCE,,}"

case "$INSTANCE_LOWER" in
    *builder*) ;;
    *) echo "ERROR: fleet-blocker.sh réservé au builder" >&2; exit 1 ;;
esac

SUP_FILE="$FLEET_HANDOFFS/to-starfleet.md"

# 1 — STATE : bloqué, sans notify encore (notify posé par fleet-notify.sh ensuite)
fleet-state.sh action=handoff status=blocked blocker="$BLOCKER" waiting="$BLOCKER" notify=none

# 2 — Record in own handoff DONE section
fleet-done.sh "BLOCKER: $BLOCKER" "${DESC:-}"

# 3 — Send to starfleet via spool
{
    echo "[${INSTANCE}] ${BLOCKER}"
    [[ -n "$DESC" ]] && echo "$DESC"
} | fleet-send.sh starfleet "blocker-${INSTANCE}"

echo ">>> BLOCKER escaladé vers starfleet : $BLOCKER"
