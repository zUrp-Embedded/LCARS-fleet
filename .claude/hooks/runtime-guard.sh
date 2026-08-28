#!/bin/bash
#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: runtime-guard.sh
#     |  |________|  | AUTHOR: LORDZURP
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
#     | MODULE: RUNTIME-GUARD   | SUBSYSTEM: HOOKS / PreToolUse   |
#     | LICENSE: AGPL-3         | GO-7: STANDARD                  |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  PreToolUse hook — blocks writes to runtime paths.        |
#     |  Protected: /opt/lcars/runtime/, ~/.claude/, ~/.local/bin  |
#     |  Bypass: FLEET_CONTEXT=deploy (deploy.sh is legitimate).  |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     Bloque les écritures dans les paths runtime (/opt/lcars/runtime, ~/.claude, ~/.local/bin).
#     ⚠ CETTE LISTE DISAIT `/local/LCARS` APRES LE DEMENAGEMENT SOUS `/opt/lcars`, ET LE CODE, LUI,
#     PROTEGEAIT LE BON CHEMIN. Un en-tete de GARDE qui nomme la mauvaise adresse est le pire endroit
#     du depot ou laisser un commentaire faux : il ne casse rien, il fait croire que le live runtime
#     est ouvert — et la prochaine session le lit comme vrai.
#     Triangle strict : source → GitHub → runtime. Bypass si FLEET_CONTEXT=deploy.
#
#     [EN]
#     NAME
#         runtime-guard.sh — block writes to runtime paths (triangle enforcement)
#
#     INTERFACE
#         Ring:    CC Runtime (hook — PreToolUse, matcher: Write|Edit|Bash)
#         Input:   stdin JSON (tool_name, tool_input with file_path/command)
#         Output:  JSON decision: block if path is protected, pass otherwise
#
#     EXIT CODES
#         0    Decision emitted or bypass (deploy context)
#
# --- END HEADER ---

set -euo pipefail

# Deploy context bypass — deploy.sh sets FLEET_CONTEXT=deploy
if [[ "${FLEET_CONTEXT:-}" == "deploy" ]]; then
    exit 0
fi

# Read stdin once
INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')

BLOCK_MSG='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Runtime path protected — edit the repo source, not the deployed artifact. Triangle: source → GitHub → runtime."}}'

# Resolve home for pattern matching
HOME_DIR="$HOME"

# check_path: returns 0 (true) if path is protected
check_path() {
    local path="$1"
    # /local/LCARS* — always protected. The glob covers BOTH generations: v1 (/local/LCARS) and the
    # v2 install (/opt/lcars/runtime), which is the one actually running today. Naming only v1 left the
    # LIVE runtime unguarded — the guard protected the retired artifact and not the deployed one.
    if [[ "$path" == /local/LCARS/* || "$path" == /local/LCARS || "$path" == /opt/lcars/runtime/* || "$path" == /opt/lcars/runtime ]]; then
        return 0
    fi
    # ~/.claude/ — protected
    if [[ "$path" == "$HOME_DIR"/.claude/* || "$path" == "$HOME_DIR"/.claude ]]; then
        return 0
    fi
    # ~/.local/bin/ — protected
    if [[ "$path" == "$HOME_DIR"/.local/bin/* || "$path" == "$HOME_DIR"/.local/bin ]]; then
        return 0
    fi
    return 1
}

case "$TOOL" in
    Edit|Write)
        FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')
        if [[ -n "$FILE_PATH" ]] && check_path "$FILE_PATH"; then
            printf '%s' "$BLOCK_MSG"
            exit 0
        fi
        ;;
    Bash)
        CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
        if [[ -n "$CMD" ]]; then
            # Match write operations targeting protected paths
            # Patterns: sed -i, tee, >, >>, cp, mv targeting protected dirs
            PROTECTED_PATTERNS=(
                "/local/LCARS/"
                "/opt/lcars/runtime/"
                "$HOME_DIR/.claude/"
                "$HOME_DIR/.local/bin/"
            )
            for ppath in "${PROTECTED_PATTERNS[@]}"; do
                # Escape path for regex
                escaped=$(printf '%s' "$ppath" | sed 's/[.[\*^$()+?{|]/\\&/g')
                # Check for write commands targeting this path
                if printf '%s' "$CMD" | grep -qE "(sed\s+-i|tee|>[>]?|cp\s|mv\s).*${escaped}"; then
                    printf '%s' "$BLOCK_MSG"
                    exit 0
                fi
                # Check for write commands where path is the destination (cp/mv dest)
                if printf '%s' "$CMD" | grep -qE "(cp|mv)\s+.*\s+${escaped}"; then
                    printf '%s' "$BLOCK_MSG"
                    exit 0
                fi
            done
        fi
        ;;
esac

# No violation — allow
exit 0
