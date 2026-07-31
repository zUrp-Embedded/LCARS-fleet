#!/bin/bash
#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: work-guard.sh
#     |  |________|  | AUTHOR: STARFLEET
#     |   ________   | SYSTEM: LCARS-FLEET v7.0
#     |  |  v7.0  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS-FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: WORK-GUARD        | SUBSYSTEM: HOOKS / PreToolUse |
#     | LICENSE: AGPL-3           | STARDATE: 2026.096            |
#     +---------------------------+-------------------------------+
#     |                                                           |
#     |  PreToolUse hook — blocks ALL direct access to work/      |
#     |  paths (plans, backlog, handoffs, scratchpad).            |
#     |  Agents MUST use fleet-plan.sh or worktree hooks.         |
#     |  Covers Write, Edit, AND Bash (rm, mv, cp, cat >>).      |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     Bloque toute ecriture directe dans work/ (checkout main ET worktree .work/).
#     Seule methode autorisee : fleet-plan.sh, fleet-scrub.sh, hooks worktree.
#     Couvre Write, Edit, et commandes Bash destructives (rm, mv, cp, cat >>).
#
#     [EN]
#     NAME
#         work-guard.sh — enforce work/ access exclusively through fleet tools
#
#     INTERFACE
#         Ring:    CC Runtime (hook — PreToolUse, matcher: Write|Edit|Bash)
#         Input:   stdin JSON (tool_name, tool_input with file_path/command)
#         Output:  JSON denial if path targets work/, pass otherwise
#
#     EXIT CODES
#         0    Always (decision emitted or pass)
#
# --- END HEADER ---

set -euo pipefail

INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')

BLOCK_MSG='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"[WORK-GUARD] work/ is protected — use fleet-plan.sh, fleet-scrub.sh, or worktree hooks. Direct writes are blocked."}}'

# Protected path patterns — both gitignored work/ and worktree projects.work/
is_work_path() {
    local path="$1"
    # <project>/work/ (gitignored in main checkout)
    [[ "$path" == /home/projects/*/work/* ]] && return 0
    # projects.work/<project>/ (worktree namespace — orphan branch)
    [[ "$path" == /home/projects.work/* ]] && return 0
    # $FLEET_HANDOFFS (worktree handoffs — fleet-send.sh only)
    # Not blocked here — separate GO-5 concern
    return 1
}

case "$TOOL" in
    Edit|Write)
        FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')
        # Exception: handoff files in work/handoffs/ are writable (managed by /handoff skill)
        if printf '%s' "$FILE_PATH" | grep -qE '/handoffs/[^/]+-handoff\.md$'; then
            exit 0
        fi
        # Exception: doing/ is the active workspace — plans in progress are editable.
        # RECURSIVE, and it was not: the old pattern matched `doing/<file>` only, while a chantier
        # IS a directory (`doing/chantier-x/00-NOTE.md`). An agent with nowhere legitimate to put a
        # chantier note puts it somewhere illegitimate — the guard was producing the mess it exists
        # to prevent.
        if printf '%s' "$FILE_PATH" | grep -qE '/work/doing/'; then
            exit 0
        fi
        # Exception: the CURRENT beyond dossier — where the live work is recorded (plans, journals,
        # chantier folders). The number is hardcoded ON PURPOSE: changing era must be a deliberate,
        # visible edit here, not a silent widening to every archived dossier. Bump it at #7.
        if printf '%s' "$FILE_PATH" | grep -qE '/work/beyond_#6/'; then
            exit 0
        fi
        # Exception: reference/ is append-only L2 corpus — versioned external sources
        if printf '%s' "$FILE_PATH" | grep -qE '/work/reference/'; then
            exit 0
        fi
        if [[ -n "$FILE_PATH" ]] && is_work_path "$FILE_PATH"; then
            printf '%s' "$BLOCK_MSG"
            exit 0
        fi
        ;;
    Bash)
        CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
        if [[ -n "$CMD" ]]; then
            # Strategy: check each semicolon/&&/||-separated segment independently.
            # Only match commands that are ALWAYS destructive when targeting a path.
            # Read-only commands (find, ls, cat, head, grep) are allowed.
            WORK_RE="(/home/projects/[^[:space:]]*/work/|/home/projects\.work/|[\"']?work/)"
            # Exception: reference/ is append-only L2 corpus — allow cp/mkdir
            REF_RE="/work/reference/"
            if printf '%s' "$CMD" | grep -qE "$REF_RE" && ! printf '%s' "$CMD" | grep -qE "(rm|sed\s+-i)\s.*${REF_RE}"; then
                exit 0
            fi
            # Same opening as Write/Edit above, for the same reason: an agent allowed to write a
            # file but not to `mkdir` its chantier folder cannot land anything. `rm` stays blocked —
            # creating and editing is the need, erasing is not.
            OPEN_RE="(/work/doing/|/work/beyond_#6/)"
            if printf '%s' "$CMD" | grep -qE "$OPEN_RE" && ! printf '%s' "$CMD" | grep -qE "(^|;|&&|\|\|)\s*rm\s.*${OPEN_RE}"; then
                exit 0
            fi
            # 1. Always-destructive commands with work path as argument
            if printf '%s' "$CMD" | grep -qE "^\s*(rm|mv|touch|mkdir|chmod|chown)\s.*${WORK_RE}"; then
                printf '%s' "$BLOCK_MSG"
                exit 0
            fi
            # 2. Destructive after && or ; or |
            if printf '%s' "$CMD" | grep -qE "(;|&&|\|\|)\s*(rm|mv|touch|mkdir|chmod|chown)\s.*${WORK_RE}"; then
                printf '%s' "$BLOCK_MSG"
                exit 0
            fi
            # 3. sed -i targeting work paths
            if printf '%s' "$CMD" | grep -qE "sed\s+-i.*${WORK_RE}"; then
                printf '%s' "$BLOCK_MSG"
                exit 0
            fi
            # 4. Redirect (> or >>) with work path as IMMEDIATE target (no .* gap)
            if printf '%s' "$CMD" | grep -qE ">+\s*${WORK_RE}"; then
                printf '%s' "$BLOCK_MSG"
                exit 0
            fi
            # 5. tee to work path
            if printf '%s' "$CMD" | grep -qE "tee\s+(-a\s+)?${WORK_RE}"; then
                printf '%s' "$BLOCK_MSG"
                exit 0
            fi
            # 6. cp with work path as destination (last arg)
            if printf '%s' "$CMD" | grep -qE "cp\s+.*\s+${WORK_RE}"; then
                printf '%s' "$BLOCK_MSG"
                exit 0
            fi
        fi
        ;;
esac

exit 0
