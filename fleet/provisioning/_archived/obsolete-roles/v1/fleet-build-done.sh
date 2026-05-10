#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-build-done.sh
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
#     | MODULE: BUILD-DONE      | SUBSYSTEM: FLEET / BUILD        |
#     | LICENSE: AGPL-3         | STARDATE: 2026.063              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Atomizes the builder success handoff path.               |
#     |  Updates STATE, writes to-dev, notifies fleet.            |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     fleet-build-done.sh — séquence complète "build réussi" en un seul appel
#
#     Symétrique de fleet-blocker.sh (chemin échec).
#     Atomise STATE + own DONE + directional DONE → fleet-monitor auto-wake dev.
#     Aucun appel fleet-notify.sh requis : la surveillance de done_count dans
#     fleet-monitor.py détecte la nouvelle entrée et réveille le destinataire.
#
#     Usage:
#
#     [EN]
#     fleet-build-done.sh — Atomizes the builder success handoff path.
#     Updates STATE, writes to-dev, notifies fleet.
#

set -euo pipefail

# --- Fleet env ---
source "$(dirname "${BASH_SOURCE[0]}")/fleet-env.sh"

[[ -n "${FLEET_SESSION:-}" ]] || exit 0

REF="${1:?usage: fleet-build-done.sh <ref> <résumé> [corps]}"
SUMMARY="${2:?usage: fleet-build-done.sh <ref> <résumé> [corps]}"
BODY="${3:-}"

INSTANCE="${CLAUDE_AGENT_NAME:-$(cat "$HOME/.claude/instance-name" 2>/dev/null || hostname)}"
INSTANCE_LOWER="${INSTANCE,,}"

case "$INSTANCE_LOWER" in
    *builder*) ;;
    *) echo "ERROR: fleet-build-done.sh réservé au builder" >&2; exit 1 ;;
esac

DEV_FILE="$FLEET_HANDOFFS/to-dev.md"
QA_FILE="$FLEET_HANDOFFS/to-qualifier.md"

# 1 — STATE : succès
fleet-state.sh action=idle status=done ref="$REF"

# Log build completion
LOG_DIR="$FLEET_LOGS"
mkdir -p "$LOG_DIR"
echo "$(date '+%Y-%m-%d %H:%M') | ${INSTANCE} | build ${REF} — ${SUMMARY}" >> "${LOG_DIR}/fleet-build.log"

# 2 — Record in own handoff DONE section
fleet-done.sh "build ${REF} done" "${SUMMARY}${BODY:+ — $BODY}"

# 3 — Send to dev via spool
{
    echo "[${INSTANCE}] ${SUMMARY}"
    [[ -n "$BODY" ]] && echo "$BODY"
} | fleet-send.sh dev "build-done-${REF}"

# 4 — Send to qualifier via spool: build OK → tests ready
echo "[${INSTANCE}] build $REF done — run tests" | fleet-send.sh qualifier "build-ready-${REF}"

echo ">>> Build livré ($REF) — dev et qualifier notifiés via spool"
