#!/bin/bash
#
#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: check-backup.sh
#     |  |________|  | AUTHOR: LORDZURP
#     |   ________   | SYSTEM: LCARS-FLEET v2.0
#     |  |  v2.0  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: CHECK-BACKUP    | SUBSYSTEM: BACKUP              |
#     | LICENSE: AGPL-3         | STARDATE: 2026.070              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Vérifie l'intégrité du dernier snapshot WSL.        |
#     |  Compare manifest vs fichiers sources.                  |
#     |                                                           |
#     +-----------------------------------------------------------+
# check-backup.sh — vérifie l'intégrité du dernier snapshot WSL
#
# Lit le manifest.txt du snapshot le plus récent.
# Vérifie que chaque fichier source existe encore.
# Les fichiers handoff sont exclus (transients par nature).
#
# Usage: ~/fleet/check-backup.sh
# Exit 0 : OK — Exit 1 : fichiers manquants ou snapshot absent

set -euo pipefail

# --- Fleet env ---
source "$(dirname "${BASH_SOURCE[0]}")/fleet-env.sh"

WSL_ROOT="/home/wsl-root"
BACKUP_ROOT="$WSL_ROOT/#9_backup"

LATEST=$(find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d | sort | tail -n 1)

if [ -z "$LATEST" ]; then
    echo "ERREUR: aucun snapshot trouvé dans $BACKUP_ROOT"
    exit 1
fi

SNAPSHOT_NAME=$(basename "$LATEST")
MANIFEST="$LATEST/manifest.txt"

if [ ! -f "$MANIFEST" ]; then
    echo "ERREUR: manifest.txt absent dans $SNAPSHOT_NAME"
    exit 1
fi

echo "Snapshot: $SNAPSHOT_NAME"
echo ""

MISSING=0
CHECKED=0

while IFS= read -r LINE; do
    [[ "$LINE" =~ ^# ]] && continue
    [ -z "$LINE" ] && continue

    REL_PATH=$(echo "$LINE" | awk '{print $3}')

    # Handoff files : transients, pas de vérification d'existence
    [[ "$REL_PATH" == "#3_Commons/handoff/"* ]] && continue

    SOURCE="$WSL_ROOT/$REL_PATH"
    CHECKED=$((CHECKED + 1))

    if [ ! -f "$SOURCE" ]; then
        echo "  MANQUANT: $SOURCE"
        MISSING=$((MISSING + 1))
    fi
done < "$MANIFEST"

echo "Fichiers vérifiés: $CHECKED"

if [ "$MISSING" -eq 0 ]; then
    echo "État: OK — aucun fichier manquant"
    exit 0
else
    echo "État: ALERTE — $MISSING fichier(s) manquant(s)"
    exit 1
fi
