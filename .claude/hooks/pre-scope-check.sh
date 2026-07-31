#!/usr/bin/env bash
# DEPLOY: instance-util

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: pre-scope-check.sh
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
#     | MODULE: SCOPE-CHECK     | SUBSYSTEM: HOOKS / SECURITY     |
#     | LICENSE: AGPL-3         | STARDATE: 2026.093              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  PreToolUse scope enforcement.                            |
#     |  Detects cross-boundary file writes per instance scope.   |
#     |  Reads scope from fleet.yaml — no hardcoded role matrix.  |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#
#           ______________________________________________________
#          /          LCARS FLEET - FEDERATION DATABASE           \
#         |   ________   __________________________________________\
#         |  |  2026  |  | SOURCE: pre-scope-check.sh
#         |  |________|  | AUTHOR: STARFLEET
#
#     [EN]
#     pre-scope-check.sh — PreToolUse scope enforcement.
#     Reads instance scope from fleet.yaml, enforces write boundaries.
#
#
# --- END HEADER ---


set -euo pipefail

# ── Dependency check ──────────────────────────────────────────────────────────
command -v jq &>/dev/null || { printf '[SCOPE-CHECK] jq not found — hook disabled\n'; exit 0; }

# ── Constants ───────────────────────────────────────────────────────────────────
INSTANCE="${CLAUDE_AGENT_NAME:-$(cat "$HOME/.claude/instance-name" 2>/dev/null || echo "unknown")}"
readonly INSTANCE
# PSC-03 mitigation: warn when instance identity is unknown (provisioning issue)
if [[ "$INSTANCE" == "unknown" ]]; then
    printf '[SCOPE-CHECK] WARNING: instance identity unknown — scope enforcement degraded\n' >&2
fi
readonly LOG_DIR="$HOME/.local/log"
readonly LOG_FILE="$LOG_DIR/scope-violations.log"

# ── Read tool input from stdin ──────────────────────────────────────────────────
INPUT=$(cat)
readonly INPUT

if [[ -z "$INPUT" ]]; then
    exit 0
fi

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')

# ── Extract paths depending on tool type ─────────────────────────────────────
# Edit/Write: file_path from tool_input
# Bash: extract target paths from write commands (sed -i, tee, >, >>, cp, mv)
PATHS_TO_CHECK=()

case "$TOOL_NAME" in
    Edit|Write)
        _fp=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')
        [[ -n "$_fp" ]] && PATHS_TO_CHECK+=("$_fp")
        ;;
    Bash)
        _cmd=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
        if [[ -n "$_cmd" ]]; then
            # PSC-04 fix (2026-04-20): extract ONLY write targets, not every
            # mentioned path. Previous version extracted any /home/projects/
            # path and then flagged them all if ANY write operator appeared
            # anywhere in the command. Consequence: `bash /home/projects/X > /tmp/Y`
            # was blocked because > triggered "write" but the real target was
            # /tmp/Y. A read-only agent (scope analysis/advisory) could not
            # pipe a read command's output anywhere.
            # Fix: extract write destinations only. A path not adjacent to a
            # write operator is considered a read argument and not flagged.
            _path_re='[^ "'\''><|;&]+'
            _PC=()

            # Redirections: > path  |  >> path
            while IFS= read -r _m; do
                [[ -n "$_m" ]] && _PC+=("$_m")
            done < <(printf '%s' "$_cmd" | grep -oE '>>?[[:space:]]*'"$_path_re" 2>/dev/null | sed -E 's/^>>?[[:space:]]*//' || true)

            # tee / tee -a path
            while IFS= read -r _m; do
                [[ -n "$_m" ]] && _PC+=("$_m")
            done < <(printf '%s' "$_cmd" | grep -oE 'tee[[:space:]]+(-a[[:space:]]+)?'"$_path_re" 2>/dev/null | sed -E 's/^tee[[:space:]]+(-a[[:space:]]+)?//' || true)

            # sed -i[opt] ... path : extract LAST arg of the sed invocation
            # (sed has one or more expressions, path is last). Approx : take
            # last /home/projects/ path within the segment.
            while IFS= read -r _seg; do
                _last=$(printf '%s' "$_seg" | grep -oE "$_path_re" | grep -v '^-' | tail -1)
                [[ -n "$_last" && "$_last" != "sed" ]] && _PC+=("$_last")
            done < <(printf '%s' "$_cmd" | grep -oE 'sed[[:space:]]+-i[^[:space:]]*([[:space:]]+[^;&|]+)+' 2>/dev/null || true)

            # Commands whose path args are write targets: rm, mkdir, chmod,
            # chown, install, patch, touch, dd. Multi-arg allowed, flags allowed.
            for _kw in rm mkdir chmod chown install patch touch dd; do
                while IFS= read -r _m; do
                    [[ -n "$_m" ]] && _PC+=("$_m")
                done < <(printf '%s' "$_cmd" | grep -oE "(^|[;&|[:space:]])${_kw}[[:space:]]+([^;&|]+)" 2>/dev/null \
                    | grep -oE "${_path_re}" 2>/dev/null \
                    | grep -v -E "^(-|\\$|${_kw}\$)" 2>/dev/null || true)
            done

            # cp / mv: destination is last positional. Approx: pick last path
            # in the matched cp/mv segment.
            while IFS= read -r _seg; do
                _last=$(printf '%s' "$_seg" | grep -oE "$_path_re" | tail -1)
                [[ -n "$_last" && "$_last" != "cp" && "$_last" != "mv" ]] && _PC+=("$_last")
            done < <(printf '%s' "$_cmd" | grep -oE '(^|[;&|[:space:]])(cp|mv)[[:space:]]+[^;&|]+' 2>/dev/null || true)

            # Filter : only check paths under /home/projects/ (other paths are
            # not in scope of this hook — handled by runtime-guard / work-guard).
            for _p in "${_PC[@]}"; do
                if [[ "$_p" == /home/projects/* ]]; then
                    PATHS_TO_CHECK+=("$_p")
                fi
            done
        fi
        ;;
esac

[[ ${#PATHS_TO_CHECK[@]} -eq 0 ]] && exit 0

# ── Resolve scope from blueprint ──────────────────────────────────────────────
# Read scope once from fleet.yaml — single source of truth.
_FLEET_YAML="${FLEET_YAML:-/local/LCARS/fleet/fleet.yaml}"
if [[ -f "$_FLEET_YAML" ]] && command -v yq &>/dev/null; then
    SCOPE="$(yq ".instances[] | select(.role == \"$INSTANCE\") | .scope" "$_FLEET_YAML" 2>/dev/null)" || SCOPE=""
    [[ "$SCOPE" == "null" ]] && SCOPE=""
else
    SCOPE=""
fi
readonly SCOPE

# ── Source file extensions (architect/documenter: no implementing) ────────────
readonly SOURCE_EXTS="py|sh|bash|js|ts|jsx|tsx|c|cpp|h|hpp|rs|go|java|rb"

# ── Forbidden path patterns per scope ─────────────────────────────────────────
# DESIGN DECISION: this hook is the canonical enforcement source for scope→path rules.
# Blueprint (fleet.yaml) owns role→scope assignment. This hook owns scope→path policy.
# Two distinct responsibilities, not duplication. Intentional — reviewed 2026-04-01.
#
# Returns non-empty reason string if path is forbidden, empty if ok.
# Rules from SP core/#3_perimetre + organisation/topologie scope matrix.
#
# /local/LCARS/ is the RUNTIME — deployed by fleet-update.sh via the triangle
# (source -> GitHub -> runtime). No agent writes to it directly.
#
# /home/projects/LCARS/ is the WORKING COPY — starfleet owns it exclusively.
# Other agents do not write to it (containment rule).
#
# /home/<agent>/ — each agent's home is bounded. Cross-agent writes are forbidden
# except via /home/commons/ (shared workspace) and $FLEET_HANDOFFS (worktree handoffs).
check_scope() {
    local scope="$1" path="$2"

    # Universal rule: nobody writes to runtime directly (triangle strict)
    if [[ "$path" == /local/LCARS/* ]]; then
        echo "runtime /local/LCARS/ (triangle strict: source -> GitHub -> runtime)"
        return 0
    fi

    # v7 Phase 4a: block direct writes to projects.work/ (defense in depth — ACLs are primary enforcement)
    # Exception: handoff files are writable (managed by /handoff skill)
    # Exception: doing/ is the active workspace — plans in progress are editable
    if [[ "$path" == /home/projects.work/* ]]; then
        if [[ "$path" == */handoffs/*-handoff.md ]]; then
            return 1  # allowed
        fi
        if [[ "$path" == */work/doing/* ]]; then
            return 1  # allowed — active workspace
        fi
        # Exception: the CURRENT beyond dossier — SYMETRIQUE de work-guard.sh, et c'est le point.
        # Ces deux gardes decrivent la MEME intention ; n'en ouvrir qu'un a produit exactement
        # l'incoherence qu'ils sont censes empecher — un agent voisin a pu poser son fichier par
        # Bash (work-guard ouvert) apres s'etre fait refuser par Write (celui-ci, ferme). Un outil
        # sur deux, c'est une regle qui ne veut plus rien dire. Le numero est code en dur ici aussi :
        # changer d'ere doit se voir aux DEUX endroits. Bump a #7.
        if [[ "$path" == */work/beyond_#6/* ]]; then
            return 1  # allowed — dossier courant
        fi
        echo "projects.work/ writes go through hooks only (v7 Phase 4a)"
        return 0
    fi

    # v7 Phase 4b: moved to work-guard.sh (dedicated hook, covers Bash too)

    case "$scope" in
        code)
            # L1 R/W — must not touch LCARS working copy (starfleet-owned)
            if [[ "$path" == /home/projects/LCARS/* ]]; then
                echo "LCARS working copy (starfleet-owned)"
                return 0
            fi
            ;;
        boundary-os)
            # starfleet owns LCARS, infra, provisioning. No L1 (project code).
            if [[ "$path" == /home/projects/* && "$path" != /home/projects/LCARS && "$path" != /home/projects/LCARS/* ]]; then
                echo "project code L1 (scope: boundary-os, infra only)"
                return 0
            fi
            ;;
        boundary-user)
            # Exception PoC_unitaire worktree : architect opère en PoC engineer
            # mode per .readmefirst §Rôle + §Production. Autorisé à écrire
            # sources (test.sh, code PoC) sous son worktree PoC dédié.
            if [[ "$path" == /home/architect/poc/*/PoC/* ]]; then
                return 1  # allowed
            fi
            # architect MUST NOT implement — block source files
            local ext="${path##*.}"
            if [[ "$ext" =~ ^($SOURCE_EXTS)$ ]]; then
                echo "source file (scope: boundary-user, implementing FORBIDDEN)"
                return 0
            fi
            if [[ "$(basename "$path")" == "Makefile" || "$(basename "$path")" == "CMakeLists.txt" ]]; then
                echo "build file (scope: boundary-user, implementing FORBIDDEN)"
                return 0
            fi
            ;;
        sas-user)
            # engineer dispatches — no project code, no LCARS
            if [[ "$path" == /home/projects/* ]]; then
                echo "project/LCARS code (scope: sas-user, dispatch only)"
                return 0
            fi
            ;;
        test)
            # read L1, write test reports only — no code writes
            if [[ "$path" == /home/projects/* ]]; then
                echo "project code (scope: test, write reports to home only)"
                return 0
            fi
            ;;
        analysis)
            # read-only — no writes to projects or LCARS
            if [[ "$path" == /home/projects/* ]]; then
                echo "project/LCARS code (scope: analysis, read-only)"
                return 0
            fi
            ;;
        documentation)
            # R/W docs/ only, no source code
            local doc_ext="${path##*.}"
            if [[ "$doc_ext" =~ ^($SOURCE_EXTS)$ ]]; then
                echo "source file (scope: documentation, docs only)"
                return 0
            fi
            if [[ "$path" == /home/projects/LCARS/* && "$path" != /home/projects/LCARS/docs/* ]]; then
                echo "LCARS non-docs (scope: documentation, docs/ only)"
                return 0
            fi
            ;;
        research)
            # no project writes, output to home only
            if [[ "$path" == /home/projects/* ]]; then
                echo "project code (scope: research, no project writes)"
                return 0
            fi
            ;;
        advisory)
            # write to ready-room/outbox/ and home only
            if [[ "$path" == /home/projects/* ]]; then
                echo "project code (scope: advisory, outbox only)"
                return 0
            fi
            ;;
        "")
            # No scope resolved — instance not in blueprint
            printf '[SCOPE-CHECK] WARNING: no scope for instance "%s" — no rules applied\n' "$INSTANCE" >&2
            ;;
        *)
            # Unknown scope — warn but do NOT block
            printf '[SCOPE-CHECK] WARNING: unknown scope "%s" for instance "%s" — no rules applied\n' "$scope" "$INSTANCE" >&2
            ;;
    esac
    return 0
}

# Check all extracted paths — first violation wins
REASON=""
VIOLATING_PATH=""
for _p in "${PATHS_TO_CHECK[@]}"; do
    REASON=$(check_scope "$SCOPE" "$_p")
    if [[ -n "$REASON" ]]; then
        VIOLATING_PATH="$_p"
        break
    fi
done
readonly REASON VIOLATING_PATH

[[ -z "$REASON" ]] && exit 0

# ── Violation detected — BLOCK the operation (JUPITER-004) ─────────────────────
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
readonly TIMESTAMP

mkdir -p "$LOG_DIR"
printf '%s [%s/%s] SCOPE VIOLATION: %s — %s\n' "$TIMESTAMP" "$INSTANCE" "$SCOPE" "$VIOLATING_PATH" "$REASON" >> "$LOG_FILE"

# JUPITER-004: output JSON denial to mechanically block the write.
# PreToolUse hooks use permissionDecision to allow/deny/ask.
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"[SCOPE-CHECK] %s (%s) — %s: %s"}}\n' \
    "$INSTANCE" "$SCOPE" "$VIOLATING_PATH" "$REASON"

exit 0
