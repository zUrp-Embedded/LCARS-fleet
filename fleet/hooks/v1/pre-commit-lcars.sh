#!/bin/bash
#
#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: pre-commit-lcars.sh
#     |  |________|  | AUTHOR: LORDZURP
#     |   ________   | SYSTEM: LCARS-FLEET v1.0
#     |  |  v1.0  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS-FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: PRE-COMMIT-LCARS | SUBSYSTEM: FLEET / HOOKS      |
#     | LICENSE: AGPL-3          | STARDATE: 2026.090             |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  GO-7 header enforcement + date bookkeeping.              |
#     |  Adapts to repo type via hook-config.sh.                  |
#     |  Checks presence only — never auto-fixes missing headers. |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     pre-commit-lcars.sh — Hook git pre-commit GO-7.
#     Pass 1 : mise à jour automatique des dates (STARDATE ou ISO).
#     Pass 2 : vérification headers .md et sources — bloque sans corriger.
#
#     [EN]
#     NAME
#         pre-commit-lcars.sh — git pre-commit hook for GO-7 header compliance
#
#     INTERFACE
#         Ring:    0 (gate)
#         Input:   git staged files (ACM filter), hook-config.sh (repo type)
#         Output:  updated dates in staged files (pass 1), block on missing headers (pass 2)
#
#     EXIT CODES
#         0    All staged files compliant
#         1    Missing headers detected (commit blocked)
#
# --- END HEADER ---

set -euo pipefail

STAGED=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null)
[[ -z "$STAGED" ]] && exit 0

# --- Source hook-config.sh for repo type detection ---
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_CONFIG="$HOOK_DIR/hook-config.sh"
if [ -f "$HOOK_CONFIG" ]; then
    # shellcheck source=/dev/null  # path is dynamic, resolved at runtime
    source "$HOOK_CONFIG"
else
    # shellcheck disable=SC2034  # consumed by sourced config
    HOOK_REPO_TYPE="project"
    HOOK_DATE_FORMAT="iso"
fi

# --- Pass 1: Date bookkeeping (metadata update, not a fix) ---
# IEC 61508 exception: this sed+git-add is an auto-fix, which normally contradicts
# the "hook bloque uniquement" directive. However, date/stardate bookkeeping is
# purely mechanical metadata (not content) — the exception is accepted and documented.
if [[ "$HOOK_DATE_FORMAT" == "stardate" ]]; then
    STARDATE=$(date '+%Y.%j')
    STARDATE_PATTERN="STARDATE: [0-9][0-9][0-9][0-9]\.[0-9][0-9][0-9]"
    while IFS= read -r file; do
        [[ -z "$file" || ! -f "$file" ]] && continue
        if grep -q "$STARDATE_PATTERN" "$file"; then
            CURRENT=$(grep -oE "STARDATE: [0-9]{4}\.[0-9]{3}" "$file" | head -1 | cut -d' ' -f2)
            if [[ "$CURRENT" != "$STARDATE" ]]; then
                sed "s/$STARDATE_PATTERN/STARDATE: ${STARDATE}/" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
                git add "$file"
            fi
        fi
    done <<< "$STAGED"
else
    TODAY=$(date '+%Y-%m-%d')
    while IFS= read -r file; do
        [[ -z "$file" || ! -f "$file" ]] && continue
        ext="${file##*.}"
        [[ "$ext" != "md" ]] && continue
        if grep -q '^\*\*Dernière révision\*\*' "$file"; then
            CURRENT=$(grep '^\*\*Dernière révision\*\*' "$file" | sed 's/.*: //' | grep -Eo '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
            if [[ -n "$CURRENT" && "$CURRENT" != "$TODAY" ]]; then
                sed "s/^\(\*\*Dernière révision\*\* : \)[0-9-]*/\1${TODAY}/" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
                git add "$file"
            fi
        fi
    done <<< "$STAGED"
fi

# --- Pass 2: GO-7 header check (block only — never auto-fix) ---
FAILED=()

is_ipc_exception() {
    local base
    base=$(basename "$1")
    case "$base" in
        *-handoff.md|to-*.md|*-notes.md|*-queue.md|MEMORY.md|scratchpad.md) return 0 ;;
    esac
    [[ "$1" == *"#9_archives"* || "$1" == *"9_archives/"* ]] && return 0
    [[ "$1" == *"directives/roles/"* || "$1" == *"sources/roles/"* ]] && return 0
    [[ "$1" == *"/skills/"*"/SKILL.md" ]] && return 0
    [[ "$1" == *"tests/fixtures/"* ]] && return 0
    return 1
}

check_md_header() {
    local h
    h=$(head -15 "$1" 2>/dev/null)
    echo "$h" | grep -qF "**Date**" && return 0
    echo "$h" | grep -qE "^\s+date:" && return 0
    echo "$h" | grep -qE "<!--\s*Date\s*:" && return 0
    return 1
}

check_source_header() {
    head -20 "$1" 2>/dev/null | grep -qEi "SOURCE:|AUTHOR:|STARDATE:"
}

while IFS= read -r file; do
    [[ -z "$file" || ! -f "$file" ]] && continue

    ext="${file##*.}"
    [[ "$ext" == "$(basename "$file")" ]] && continue

    case "$ext" in
        md)
            is_ipc_exception "$file" && continue
            check_md_header "$file" || FAILED+=("$file  ← missing **Date** header")
            ;;
        sh|py|cpp|c|h|hpp)
            check_source_header "$file" || FAILED+=("$file  ← missing source header (SOURCE:/AUTHOR:/STARDATE:)")
            ;;
        *)
            ;;
    esac
done <<< "$STAGED"

if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo ""
    echo "  [pre-commit] GO-7 violation — missing declarative header in:"
    echo ""
    for f in "${FAILED[@]}"; do
        echo "  x  $f"
    done
    echo ""
    echo "  .md     → add after # Title:"
    echo "            **Date** : YYYY-MM-DD"
    echo "            **Dernière révision** : YYYY-MM-DD"
    echo "            **Statut** : <one-liner>"
    echo "            **Référencé par** : <files or —>"
    echo "  source  → add LCARS STARDATE/AUTHOR/STATUS block at file top"
    echo ""
    echo "  Bypass (not recommended): git commit --no-verify"
    echo ""
    exit 1
fi

exit 0
