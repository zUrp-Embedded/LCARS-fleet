#!/usr/bin/env bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: check-backup.sh
#     |  |________|  | AUTHOR: STARFLEET
#     |   ________   | SYSTEM: LCARS-FLEET v6.0
#     |  |  v6.0  |  | STATUS: DEPRECATED
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS-FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: BACKUP-CHECK    | SUBSYSTEM: TOOLBOX / MAINT      |
#     | LICENSE: AGPL-3         | STARDATE: 2026.087              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  DEPRECATED — targets old layout (#9_backup) which no     |
#     |  longer exists in v6. Companion to backup-wsl.sh.         |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     check-backup.sh — OBSOLETE. Verifie l'integrite des archives
#     backup WSL2. Cible l'ancien layout (#9_backup). A reecrire pour v7.
#
#     [EN]
#     NAME
#         check-backup.sh — WSL2 backup integrity check (DEPRECATED)
#
#     SYNOPSIS
#         check-backup.sh [backup-dir]
#
#     DESCRIPTION
#         DEPRECATED: targets old filesystem layout. See backup-wsl.sh.
#
#     SEE ALSO
#         backup-wsl.sh(1) — also deprecated
#
# --- END HEADER ---

set -euo pipefail

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
