#!/bin/bash
#
#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: backup-wsl.sh
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
#     | MODULE: BACKUP-WSL      | SUBSYSTEM: BACKUP              |
#     | LICENSE: AGPL-3         | STARDATE: 2026.070              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Snapshot des fichiers non-versionnés WSL.             |
#     |  Rotation automatique, manifest MD5.                    |
#     |                                                           |
#     +-----------------------------------------------------------+
# backup-wsl.sh — snapshot des fichiers non-versionnés WSL
#
# Accessible uniquement depuis starfleet via /home/wsl-root/.
# Crée un snapshot horodaté dans #9_backup/, génère un manifest.txt.
# Rotation automatique : conserve les 5 derniers snapshots.
#
# Usage: ~/fleet/backup-wsl.sh [--dry-run]

set -euo pipefail

# --- Fleet env ---
source "$(dirname "${BASH_SOURCE[0]}")/fleet-env.sh"

WSL_ROOT="/home/wsl-root"
BACKUP_ROOT="$WSL_ROOT/#9_backup"
SNAPSHOT_NAME="$(date '+%Y-%m-%d_%H%M%S')"
SNAPSHOT_DIR="$BACKUP_ROOT/$SNAPSHOT_NAME"
KEEP_SNAPSHOTS=5

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

# ─── Helpers ─────────────────────────────────────────────────────────────────

copy_file() {
    local src="$1"
    local dst_dir="$2"

    [ -f "$src" ] || return 0

    if [ "$DRY_RUN" -eq 0 ]; then
        mkdir -p "$dst_dir"
        cp "$src" "$dst_dir/"
    fi
    echo "  + $(basename "$src")"
}

copy_dir() {
    local src="$1"
    local dst="$2"

    [ -d "$src" ] || return 0

    local count
    count=$(find "$src" -type f | wc -l | tr -d ' ')

    if [ "$DRY_RUN" -eq 0 ]; then
        mkdir -p "$dst"
        cp -r "$src/." "$dst/"
    fi
    echo "  + $(basename "$src")/ ($count fichiers)"
}

# ─── Init snapshot ───────────────────────────────────────────────────────────

if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] snapshot serait: $SNAPSHOT_NAME"
else
    mkdir -p "$SNAPSHOT_DIR"
    echo "Backup WSL — $SNAPSHOT_NAME"
fi

# ─── #4_Private ──────────────────────────────────────────────────────────────

echo ""
echo "--- #4_Private"
PRIV_SRC="$WSL_ROOT/#4_Private"
PRIV_DST="$SNAPSHOT_DIR/#4_Private"

copy_file "$PRIV_SRC/git-identity.conf" "$PRIV_DST"
copy_file "$PRIV_SRC/gh-token"          "$PRIV_DST"

# SSH keys : exclus par défaut (sensibles, stockés depuis Windows)
# copy_file "$PRIV_SRC/.ssh/id_ed25519"     "$PRIV_DST/.ssh"
# copy_file "$PRIV_SRC/.ssh/id_ed25519.pub" "$PRIV_DST/.ssh"

# ─── #2_Home — par instance ──────────────────────────────────────────────────

INSTANCES=("dev" "builder" "starfleet" "architect")
MISSING_CRITICAL=0

for INST in "${INSTANCES[@]}"; do
    INST_SRC="$WSL_ROOT/#2_Home/$INST"
    INST_DST="$SNAPSHOT_DIR/#2_Home/$INST"

    [ -d "$INST_SRC" ] || continue

    echo ""
    echo "--- #2_Home/$INST"

    copy_file "$INST_SRC/.claude/settings.json"        "$INST_DST/.claude"
    copy_file "$INST_SRC/.claude/settings.local.json"  "$INST_DST/.claude"
    copy_file "$INST_SRC/.claude/instance-name"         "$INST_DST/.claude"
    copy_file "$INST_SRC/.claude.json"                  "$INST_DST"
    copy_file "$INST_SRC/.gitconfig"                    "$INST_DST"
    copy_file "$INST_SRC/.bashrc"                       "$INST_DST"
    copy_file "$INST_SRC/.wsl-instance-type"            "$INST_DST"

    # Fichiers critiques — présents sur toute instance provisionnée
    for critical in ".claude/settings.local.json" ".claude/instance-name"; do
        if [ ! -f "$INST_SRC/$critical" ]; then
            echo "  WARN: fichier critique manquant — $INST/$critical" >&2
            MISSING_CRITICAL=$(( MISSING_CRITICAL + 1 ))
        fi
    done

    # Fichiers spécifiques par rôle (optionnels — présents uniquement sur l'instance concernée)
    copy_file "$INST_SRC/.env.cross"     "$INST_DST"
    copy_file "$INST_SRC/.rpi-target"   "$INST_DST"
    copy_file "$INST_SRC/.env.x86"      "$INST_DST"
    copy_file "$INST_SRC/.tmux.conf"    "$INST_DST"
    copy_file "$INST_SRC/.rpi-deploy.conf" "$INST_DST"

    # Auto-memory — MEMORY.md et fichiers de contexte persistant
    PROJ_BASE="$INST_SRC/.claude/projects"
    if [ -d "$PROJ_BASE" ]; then
        while IFS= read -r -d '' MEMORY_DIR; do
            REL="${MEMORY_DIR#"$INST_SRC"/}"
            copy_dir "$MEMORY_DIR" "$INST_DST/$REL"
        done < <(find "$PROJ_BASE" -maxdepth 2 -name "memory" -type d -print0)
    fi
done

# ─── #3_Commons ──────────────────────────────────────────────────────────────

echo ""
echo "--- #3_Commons"
COMMONS_SRC="$WSL_ROOT/#3_Commons"
COMMONS_DST="$SNAPSHOT_DIR/#3_Commons"

if [ -d "$COMMONS_SRC/handoff" ]; then
    HANDOFF_DST="$COMMONS_DST/handoff"
    if [ "$DRY_RUN" -eq 0 ]; then
        mkdir -p "$HANDOFF_DST"
        find "$COMMONS_SRC/handoff" -maxdepth 1 -name "*.md" -exec cp {} "$HANDOFF_DST/" \;
    fi
    count=$(find "$COMMONS_SRC/handoff" -maxdepth 1 -name "*.md" | wc -l | tr -d ' ')
    echo "  + handoff/ ($count fichiers .md)"
fi

copy_file "$COMMONS_SRC/project-refs.md" "$COMMONS_DST"
copy_dir  "$COMMONS_SRC/artifacts"       "$COMMONS_DST/artifacts"

# ─── Manifest ────────────────────────────────────────────────────────────────

if [ "$DRY_RUN" -eq 0 ]; then
    MANIFEST="$SNAPSHOT_DIR/manifest.txt"
    {
        echo "# backup-wsl manifest — $SNAPSHOT_NAME"
        echo "# format: md5  size_bytes  path_relative_to_WSL_ROOT"
        echo ""
    } > "$MANIFEST"

    while IFS= read -r -d '' FILE; do
        REL="${FILE#"$SNAPSHOT_DIR"/}"
        SIZE=$(stat -c '%s' "$FILE")
        MD5=$(md5sum "$FILE" | awk '{print $1}')
        echo "$MD5  $SIZE  $REL"
    done < <(find "$SNAPSHOT_DIR" -type f -not -name "manifest.txt" -print0 | sort -z) >> "$MANIFEST"

    FILE_COUNT=$(grep -c "^[0-9a-f]" "$MANIFEST" || true)
    echo ""
    echo "Manifest: $FILE_COUNT fichiers"
    [ "$MISSING_CRITICAL" -gt 0 ] && echo "WARN: $MISSING_CRITICAL fichier(s) critique(s) manquant(s) — snapshot potentiellement incomplet" >&2
fi

# ─── Rotation ────────────────────────────────────────────────────────────────

if [ "$DRY_RUN" -eq 0 ]; then
    mapfile -t SNAPSHOTS < <(find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d | sort)
    COUNT=${#SNAPSHOTS[@]}

    if [ "$COUNT" -gt "$KEEP_SNAPSHOTS" ]; then
        TO_DELETE=$((COUNT - KEEP_SNAPSHOTS))
        for DIR in "${SNAPSHOTS[@]:0:$TO_DELETE}"; do
            rm -rf "$DIR"
            echo "  [supprimé] $(basename "$DIR")"
        done
    fi

    echo "Snapshots: $(find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')/$KEEP_SNAPSHOTS conservés"
fi
