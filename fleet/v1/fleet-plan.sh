#!/bin/bash
# DEPLOY: instance-util
#
#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-plan.sh
#     |  |________|  | AUTHOR: LORDZURP
#     |   ________   | SYSTEM: LCARS-FLEET v5.4
#     |  |  v5.4  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: FLEET-PLAN      | SUBSYSTEM: WORK LIFECYCLE       |
#     | LICENSE: AGPL-3         | STARDATE: 2026.090              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Kanban-style plan lifecycle manager.                     |
#     |  Manages TODO → doing → done transitions with            |
#     |  reviewer headless validation gate on done.               |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     Gestionnaire de cycle de vie des plans. Kanban fichier avec gate de validation.
#
#     [EN]
#     NAME
#         fleet-plan.sh — gestion du cycle de vie des plans
#
#     SYNOPSIS
#         fleet-plan.sh <command> [args]
#
#     DESCRIPTION
#         Pipeline Kanban pour work/ : TODO → doing → done.
#         Validation gate via reviewer headless pour les transitions done.
#         Invoqué par le skill /plan ou directement en shell.
#
#     INTERFACE
#         Ring:    3 (kernel)
#         Input:   command + slug, work/ directory (TODO/, doing/, done/)
#         Output:  plan files moved/created in work/, reviewer dispatch for gate
#         JSON:    non
#
#     COMMANDS
#         new <slug>              Créer un plan dans TODO/
#         start <slug>            Déplacer TODO/ → doing/ (WIP limit: 2, warning)
#         done <slug> [--step N] [--force]  Valider + déplacer doing/ → done/ (gate reviewer, --force skip)
#         check <slug> [--step N] Dry-run validation (pas de déplacement)
#         list [TODO|doing|done]  Lister les plans (tous ou filtrés)
#         append <slug>           Ajouter du contenu (stdin) à un plan existant
#         audit                   Vérifier conformité de tous les plans
#
#     EXAMPLES
#         fleet-plan.sh new auth-refactor
#         fleet-plan.sh start auth-refactor
#         fleet-plan.sh done auth-refactor
#         fleet-plan.sh done auth-refactor --step 3
#         fleet-plan.sh list doing
#         echo "Ajout spec API" | fleet-plan.sh append auth-refactor
#
#     OPTIONS
#         --step N    Valider l'étape N uniquement (done/check). Plan reste en doing/.
#
#     EXIT CODES
#         0    Succès
#         1    Plan introuvable, validation FAIL, ou erreur
#
#     SEE ALSO
#         fleet-scrub.sh, fleet-dispatch.sh, conventions.md § Structure work/
#
# --- END HEADER ---

# --help: extract [EN] section from this header
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && {
    sed -n '/^#     \[EN\]/,/^# --- END HEADER ---/{/\[EN\]/d; /END HEADER/d; s/^#     //; s/^#[[:space:]]*$//; p}' "$0"
    exit 0
}

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve project root: walk up from $PWD looking for .git (work/ may not exist — worktree only)
# ---------------------------------------------------------------------------
_resolve_project() {
    local dir="$PWD"
    while [[ "$dir" != "/" ]]; do
        if [[ -d "$dir/.git" || -f "$dir/.git" ]]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    echo "ERROR: no project root found (no .git above $PWD)" >&2
    return 1
}

PROJECT_ROOT="$(_resolve_project)"
# v7 Phase 3: prefer worktree, fallback to in-repo work/
_proj_name="$(basename "$PROJECT_ROOT")"
if [ -d "${HOMES_ROOT:-/home}/projects.work/${_proj_name}/work" ]; then
    WORK_DIR="${HOMES_ROOT:-/home}/projects.work/${_proj_name}/work"
else
    WORK_DIR="$PROJECT_ROOT/work"
fi
TODO_DIR="$WORK_DIR/TODO"
DOING_DIR="$WORK_DIR/doing"
DONE_DIR="$WORK_DIR/done"
INDEX_FILE="$WORK_DIR/index.md"
_AGENT="${CLAUDE_AGENT_NAME:-$(cat "$HOME/.claude/instance-name" 2>/dev/null || echo "unknown")}"

# Atomic commit in worktree after each write (push stays in on-stop)
_wt_commit() {
    local msg="${1:-update}"
    # Only commit if WORK_DIR is inside a git worktree
    local _git_dir
    _git_dir="$(git -C "$WORK_DIR" rev-parse --git-dir 2>/dev/null)" || return 0
    (
        cd "$WORK_DIR" || return 0
        git add -A 2>/dev/null || true
        git diff --cached --quiet 2>/dev/null && return 0
        git commit -m "$_AGENT | $msg | $(date '+%Y-%m-%d %H:%M')" --quiet 2>/dev/null || true
    )
}

# ---------------------------------------------------------------------------
# Source fleet-env if available (for FLEET_READY_ROOM, fleet-dispatch, etc.)
# ---------------------------------------------------------------------------
_FLEET_ENV=""
[[ -x "$HOME/.local/bin/fleet-env.sh" ]] && _FLEET_ENV="$HOME/.local/bin/fleet-env.sh"
[[ -z "$_FLEET_ENV" ]] && [[ -f "$HOME/fleet/fleet-env.sh" ]] && _FLEET_ENV="$HOME/fleet/fleet-env.sh"
if [[ -n "$_FLEET_ENV" ]]; then
    # shellcheck source=/dev/null
    source "$_FLEET_ENV" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
_today() { date '+%Y-%m-%d'; }
_now()   { date '+%Y-%m-%d %H:%M'; }

_project_slug() {
    basename "$PROJECT_ROOT"
}

_ensure_dirs() {
    mkdir -p "$TODO_DIR" "$DOING_DIR" "$DONE_DIR"
}

# Resolve validator role: always reviewer (unified after quality/compliance retirement)
_validator_role() {
    echo "reviewer"
}

# Find a plan file by slug across TODO/doing/done. Returns path or empty.
_find_plan() {
    local slug="$1"
    for dir in "$TODO_DIR" "$DOING_DIR" "$DONE_DIR"; do
        if [[ -f "$dir/${slug}.md" ]]; then
            echo "$dir/${slug}.md"
            return 0
        fi
    done
    return 1
}

# Which state is the plan in?
_plan_state() {
    local slug="$1"
    [[ -f "$TODO_DIR/${slug}.md" ]]  && echo "TODO"  && return
    [[ -f "$DOING_DIR/${slug}.md" ]] && echo "doing" && return
    [[ -f "$DONE_DIR/${slug}.md" ]]  && echo "done"  && return
    echo "unknown"
}

_sync_ready_room() {
    :
}

# Update index.md — recent actions table (append, keep last 10)
_index_log() {
    local action="$1" source="$2" destination="$3"
    if [[ ! -f "$INDEX_FILE" ]]; then
        _index_init_stub
    fi
    local entry
    entry="| $(_today) | $action | $source | $destination |"
    # Append to recent actions
    local tmp
    tmp=$(mktemp)
    awk -v entry="$entry" '
    /^## Actions/ && /centes/ { in_section=1; done_insert=0; print; next }
    in_section && /^## / { in_section=0 }
    in_section && /^\| Date / { print; next }
    in_section && /^\|---/ && !done_insert { print; print entry; count=1; done_insert=1; next }
    in_section && /^\|/ { count++; if (count <= 10) print; next }
    { print }
    ' "$INDEX_FILE" > "$tmp"
    mv "$tmp" "$INDEX_FILE"
    rm -f "$tmp" 2>/dev/null
}

_index_init_stub() {
    cat > "$INDEX_FILE" << 'HEREDOC'
# Work Index

**Dernière mise à jour** : —
**Dernier scrub scratchpad** : —
**Dernier scrub backlog** : —

## Actions récentes (10 dernières)

| Date | Action | Source | Destination |
|---|---|---|---|
HEREDOC
}

# Update "Dernière mise à jour" in index
_index_touch() {
    if [[ -f "$INDEX_FILE" ]]; then
        sed "s/^\*\*Dernière mise à jour\*\* : .*/\*\*Dernière mise à jour\*\* : $(_today)/" "$INDEX_FILE" > "${INDEX_FILE}.tmp" && mv -f "${INDEX_FILE}.tmp" "$INDEX_FILE"
    fi
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_new() {
    local slug="${1:?usage: fleet-plan.sh new <slug>}"
    _ensure_dirs

    local target="$TODO_DIR/${slug}.md"
    if _find_plan "$slug" > /dev/null 2>&1; then
        local state
        state="$(_plan_state "$slug")"
        echo "ERROR: plan '$slug' already exists in $state/" >&2
        return 1
    fi

    cat > "$target" << HEREDOC
# ${slug}

**Date** : $(_today)
**Dernière révision** : $(_today)
**Statut** : TODO
**Priorité** : normale
**Milestone** : —
**Assigné** : —
**Référencé par** : —
**Dérivé de** : —

## Objectif

## Livrables

## Critères d'acceptance

## Notes
HEREDOC

    echo "OK: $target"
    _index_log "plan created" "new" "TODO/${slug}.md"
    _index_touch
    _wt_commit "new $slug"
    _sync_ready_room
}

cmd_start() {
    local slug="${1:?usage: fleet-plan.sh start <slug>}"
    _ensure_dirs

    local src="$TODO_DIR/${slug}.md"
    if [[ ! -f "$src" ]]; then
        local state
        state="$(_plan_state "$slug")"
        if [[ "$state" == "doing" ]]; then
            echo "ERROR: plan '$slug' is already in doing/" >&2
        elif [[ "$state" == "done" ]]; then
            echo "ERROR: plan '$slug' is already in done/" >&2
        else
            echo "ERROR: plan '$slug' not found in TODO/" >&2
        fi
        return 1
    fi

    # Check WIP limit
    local wip_count
    wip_count=$(find "$DOING_DIR" -maxdepth 1 -name "*.md" | wc -l)
    if [[ "$wip_count" -ge 2 ]]; then
        echo "WARN: doing/ already has $wip_count plans (WIP limit = 2)" >&2
        echo "Plans in doing/:" >&2
        find "$DOING_DIR" -maxdepth 1 -name "*.md" -printf "  - %f\n" >&2
        echo "Proceed anyway? This is a WIP limit warning, not a block." >&2
    fi

    # Update Statut field before moving to target directory
    sed "s/^\*\*Statut\*\* : .*/\*\*Statut\*\* : doing/" "$src" > "${src}.tmp" && mv -f "${src}.tmp" "$src"
    mv "$src" "$DOING_DIR/${slug}.md"

    echo "OK: TODO/${slug}.md → doing/${slug}.md"
    _index_log "plan started" "TODO/${slug}.md" "doing/${slug}.md"
    _index_touch
    _wt_commit "start $slug"
    _sync_ready_room
}

cmd_done() {
    local slug=""
    local step=""
    local force=false

    # Parse args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --step) step="$2"; shift 2 ;;
            --force) force=true; shift ;;
            *)      slug="$1"; shift ;;
        esac
    done

    [[ -z "$slug" ]] && echo "usage: fleet-plan.sh done <slug> [--step N] [--force]" >&2 && return 1

    local src="$DOING_DIR/${slug}.md"
    if [[ ! -f "$src" ]]; then
        local state
        state="$(_plan_state "$slug")"
        if [[ "$state" == "TODO" ]] && $force; then
            src="$TODO_DIR/${slug}.md"
            echo "INFO: --force — accepting TODO → done (skip doing)" >&2
        elif [[ "$state" == "TODO" ]]; then
            echo "ERROR: plan '$slug' is in TODO/ — must start first (use --force to override)" >&2
            return 1
        elif [[ "$state" == "done" ]]; then
            echo "ERROR: plan '$slug' is already in done/" >&2
            return 1
        else
            echo "ERROR: plan '$slug' not found in doing/" >&2
            return 1
        fi
    fi

    # --- Validation gate: dispatch validator headless ---
    if $force; then
        echo "WARN: --force — skipping validation gate" >&2
        _ensure_dirs
        if [[ -n "$step" ]]; then
            echo "PASS (forced): step $step. Plan stays in doing/."
            _index_log "step $step forced" "doing/${slug}.md" "doing/${slug}.md"
            _index_touch
            _wt_commit "done $slug step $step (forced)"
            _sync_ready_room
            return 0
        fi
        # Update fields before moving to target directory
        sed -e "s/^\*\*Statut\*\* : .*/\*\*Statut\*\* : done/" -e "s/^\*\*Dernière révision\*\* : .*/\*\*Dernière révision\*\* : $(_today)/" "$src" > "${src}.tmp" && mv -f "${src}.tmp" "$src"
        mv "$src" "$DONE_DIR/${slug}.md"
        echo "OK: doing/${slug}.md → done/${slug}.md (forced, no validation)"
        _index_log "plan completed (forced)" "doing/${slug}.md" "done/${slug}.md"
        _index_touch
        _wt_commit "done $slug (forced)"
        _sync_ready_room
        return 0
    fi

    local validator
    validator="$(_validator_role)"

    local step_instruction=""
    if [[ -n "$step" ]]; then
        step_instruction="IMPORTANT: Validate ONLY step/étape $step. Ignore all other steps."
    fi

    # Read plan content into variable safely (no command substitution expansion)
    local plan_content
    plan_content=$(<"$src")

    local prompt
    prompt="You are a plan validation reviewer. Read the plan below and verify each deliverable against the current state of the codebase.

For each item (or only step $step if specified):
- DONE: implemented and verifiable (cite file:line or evidence)
- DEFERRED: explicitly moved to backlog or side quest (cite the file)
- MISSING: not implemented, not deferred

$step_instruction

Verdict:
- If validating a single step: PASS if all items in that step are DONE or DEFERRED. FAIL if any MISSING.
- If validating the full plan: PASS if ALL steps are DONE or DEFERRED. FAIL if any MISSING.

Output format (strict):
## Plan validation: $slug
### Items
1. [DONE|DEFERRED|MISSING] description — evidence
...
### Verdict: PASS|FAIL
### Missing: N item(s)
### Summary: one-line summary

--- PLAN CONTENT ---
"
    # Append plan content safely (no variable expansion on content)
    prompt="${prompt}${plan_content}"

    # --- Scale turns/timeout to plan size ---
    local plan_items plan_sections
    plan_items=$(grep -c '^\- \[' "$src" 2>/dev/null) || plan_items=0
    plan_sections=$(grep -c '^### ' "$src" 2>/dev/null) || plan_sections=0
    # Heuristic: 2 turns per item or section (whichever is larger), min 30, max 100
    local _count=$(( plan_items > plan_sections ? plan_items : plan_sections ))
    local scaled_turns=$(( _count * 2 ))
    (( scaled_turns < 30 )) && scaled_turns=30
    (( scaled_turns > 100 )) && scaled_turns=100
    # Timeout: 30s per turn
    local scaled_timeout=$(( scaled_turns * 30 ))

    echo "Dispatching reviewer for validation (${plan_items} items, ${scaled_turns} turns, ${scaled_timeout}s timeout)..." >&2
    local result=""
    local exit_code=0

    # Resolve fleet-dispatch.sh via fleet_bin helper or PATH or relative
    local dispatch_bin=""
    if type -t fleet_bin &>/dev/null; then
        dispatch_bin="$(fleet_bin fleet-dispatch.sh)"
    fi
    [[ -z "$dispatch_bin" || ! -x "$dispatch_bin" ]] && dispatch_bin="$(command -v fleet-dispatch.sh 2>/dev/null || true)"
    [[ -z "$dispatch_bin" || ! -x "$dispatch_bin" ]] && dispatch_bin="$(dirname "${BASH_SOURCE[0]}")/fleet-dispatch.sh"

    if [[ -x "$dispatch_bin" ]]; then
        local tmp_prompt
        tmp_prompt=$(mktemp /tmp/fleet-plan-validate-XXXXXX)
        # cleanup explicit, no trap EXIT (would overwrite other traps)
        printf '%s' "$prompt" > "$tmp_prompt"
        result=$("$dispatch_bin" --max-turns "$scaled_turns" --timeout "$scaled_timeout" \
            "$validator" "plan-validate-${slug}" "$tmp_prompt" 2>/dev/null) || exit_code=$?
        rm -f "$tmp_prompt"
    else
        echo "ERROR: fleet-dispatch.sh not found — cannot validate without $validator" >&2
        echo "FAIL: validation gate requires $validator. Fix fleet-dispatch.sh availability." >&2
        return 1
    fi

    if [[ $exit_code -eq 124 ]]; then
        echo "ERROR: $validator timed out" >&2
        return 1
    fi
    if [[ $exit_code -ne 0 ]]; then
        echo "ERROR: $validator dispatch failed (exit $exit_code)" >&2
        return 1
    fi

    # --- Parse verdict ---
    local verdict
    verdict=$(echo "$result" | grep -i "^### Verdict:" | head -1 | sed 's/.*: *//')

    echo "$result"
    echo ""

    if [[ "${verdict^^}" == *"FAIL"* ]]; then
        echo "BLOCKED: plan '$slug' has MISSING items. Fix and retry." >&2
        return 1
    fi

    # --- Step mode: mark step done in plan, don't move file ---
    if [[ -n "$step" ]]; then
        echo "PASS: step $step validated. Plan stays in doing/."
        _index_log "step $step validated" "doing/${slug}.md" "doing/${slug}.md"
        _index_touch
        _wt_commit "done $slug step $step"
        _sync_ready_room
        return 0
    fi

    # --- Full plan: move to done/ ---
    _ensure_dirs
    # Update fields before moving to target directory
    sed -e "s/^\*\*Statut\*\* : .*/\*\*Statut\*\* : done/" -e "s/^\*\*Dernière révision\*\* : .*/\*\*Dernière révision\*\* : $(_today)/" "$src" > "${src}.tmp" && mv -f "${src}.tmp" "$src"
    mv "$src" "$DONE_DIR/${slug}.md"

    echo "OK: doing/${slug}.md → done/${slug}.md (PASS)"
    _index_log "plan completed" "doing/${slug}.md" "done/${slug}.md"
    _index_touch
    _wt_commit "done $slug"
    _sync_ready_room
}

cmd_check() {
    local slug=""
    local step=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --step) step="$2"; shift 2 ;;
            *)      slug="$1"; shift ;;
        esac
    done

    [[ -z "$slug" ]] && echo "usage: fleet-plan.sh check <slug> [--step N]" >&2 && return 1

    local plan_file
    plan_file="$(_find_plan "$slug")" || { echo "ERROR: plan '$slug' not found" >&2; return 1; }

    local step_instruction=""
    if [[ -n "$step" ]]; then
        step_instruction="IMPORTANT: Check ONLY step/étape $step. Ignore all other steps."
    fi

    local prompt
    prompt="You are a plan validation reviewer. Read the plan below and verify each deliverable against the current state of the codebase.

For each item (or only step $step if specified):
- DONE: implemented and verifiable (cite file:line or evidence)
- DEFERRED: explicitly moved to backlog or side quest (cite the file)
- MISSING: not implemented, not deferred

$step_instruction

Output format (strict):
## Plan check: $slug
### Items
1. [DONE|DEFERRED|MISSING] description — evidence
...
### Status: N/M items done
### Summary: one-line summary

--- PLAN CONTENT ---
$(cat "$plan_file")"

    # --- Scale turns/timeout to plan size ---
    local plan_items
    plan_items=$(grep -c '^\- \[' "$plan_file" 2>/dev/null || echo 0)
    local scaled_turns=$(( plan_items * 2 ))
    (( scaled_turns < 20 )) && scaled_turns=20
    (( scaled_turns > 100 )) && scaled_turns=100
    local scaled_timeout=$(( scaled_turns * 30 ))

    local validator
    validator="$(_validator_role)"
    echo "Dispatching $validator for check (${plan_items} items, ${scaled_turns} turns, ${scaled_timeout}s timeout)..." >&2

    local dispatch_bin=""
    if type -t fleet_bin &>/dev/null; then
        dispatch_bin="$(fleet_bin fleet-dispatch.sh)"
    fi
    [[ -z "$dispatch_bin" || ! -x "$dispatch_bin" ]] && dispatch_bin="$(command -v fleet-dispatch.sh 2>/dev/null || true)"
    [[ -z "$dispatch_bin" || ! -x "$dispatch_bin" ]] && dispatch_bin="$(dirname "${BASH_SOURCE[0]}")/fleet-dispatch.sh"

    if [[ ! -x "$dispatch_bin" ]]; then
        echo "ERROR: fleet-dispatch.sh not found — cannot check without $validator" >&2
        return 1
    fi

    local result=""
    local tmp_prompt
    tmp_prompt=$(mktemp /tmp/fleet-plan-check-XXXXXX)
    trap 'rm -f "$tmp_prompt"' EXIT
    printf '%s' "$prompt" > "$tmp_prompt"
    local dispatch_exit=0
    result=$("$dispatch_bin" --max-turns "$scaled_turns" --timeout "$scaled_timeout" \
        "$validator" "plan-check-${slug}" "$tmp_prompt" 2>/dev/null) || dispatch_exit=$?
    [[ $dispatch_exit -ne 0 ]] && echo "WARN: [fleet-plan] validator dispatch failed (exit $dispatch_exit)" >&2
    rm -f "$tmp_prompt"

    echo "$result"
}

cmd_list() {
    local filter="${1:-}"
    _ensure_dirs

    printf "%-35s %-8s %-12s %-10s %s\n" "PLAN" "STATE" "PRIORITY" "UPDATED" "MILESTONE"
    printf "%-35s %-8s %-12s %-10s %s\n" "---" "---" "---" "---" "---"

    for state_dir in "$TODO_DIR:TODO" "$DOING_DIR:doing" "$DONE_DIR:done"; do
        local dir="${state_dir%%:*}"
        local state="${state_dir##*:}"

        # Skip if filter is set and doesn't match
        [[ -n "$filter" ]] && [[ "$filter" != "$state" ]] && continue

        for plan in "$dir"/*.md; do
            [[ -f "$plan" ]] || continue
            local name
            name=$(basename "$plan" .md)
            local priority updated milestone
            priority=$(grep -m1 '^\*\*Priorité\*\*' "$plan" 2>/dev/null | sed 's/.*: *//' || echo "—")
            updated=$(grep -m1 '^\*\*Dernière révision\*\*' "$plan" 2>/dev/null | sed 's/.*: *//' || echo "—")
            milestone=$(grep -m1 '^\*\*Milestone\*\*' "$plan" 2>/dev/null | sed 's/.*: *//' || echo "—")
            printf "%-35s %-8s %-12s %-10s %s\n" "$name" "$state" "$priority" "$updated" "$milestone"
        done
    done
}

cmd_scratchpad() {
    local content
    if [[ $# -gt 0 ]]; then
        content="$*"
    else
        content=$(cat)
    fi
    [[ -z "$content" ]] && echo "ERROR: nothing to write (empty input)" >&2 && return 1

    local scratch="$WORK_DIR/scratchpad.md"
    local agent="${CLAUDE_AGENT_NAME:-$(cat "$HOME/.claude/instance-name" 2>/dev/null || echo "unknown")}"
    local ts
    ts=$(date "+%Y-%m-%d %H:%M")

    printf '\n### %s — %s\n%s\n' "$ts" "$agent" "$content" >> "$scratch"
    echo "OK: scratchpad entry added ($ts)"
    _index_log "scratchpad entry" "scratchpad.md" "scratchpad.md"
    _index_touch
    _wt_commit "scratchpad"
}

cmd_backlog() {
    local content
    if [[ $# -gt 0 ]]; then
        content="$*"
    else
        content=$(cat)
    fi
    [[ -z "$content" ]] && echo "ERROR: nothing to write (empty input)" >&2 && return 1

    local backlog="$WORK_DIR/backlog.md"
    local ts
    ts=$(date "+%Y-%m-%d %H:%M")

    printf '\n- [ ] %s (%s)\n' "$content" "$ts" >> "$backlog"
    echo "OK: backlog item added ($ts)"
    _index_log "backlog item added" "backlog.md" "backlog.md"
    _index_touch
    _wt_commit "backlog"
}

cmd_append() {
    local slug="${1:?usage: fleet-plan.sh append <slug> (reads stdin)}"

    local plan_file
    plan_file="$(_find_plan "$slug")" || { echo "ERROR: plan '$slug' not found" >&2; return 1; }

    local content
    content=$(cat)
    [[ -z "$content" ]] && echo "ERROR: nothing to append (empty stdin)" >&2 && return 1

    printf '\n%s\n' "$content" >> "$plan_file"
    sed "s/^\*\*Dernière révision\*\* : .*/\*\*Dernière révision\*\* : $(_today)/" "$plan_file" > "${plan_file}.tmp" && mv -f "${plan_file}.tmp" "$plan_file"

    local state
    state="$(_plan_state "$slug")"
    echo "OK: appended to $state/${slug}.md"
    _index_log "plan updated (append)" "$state/${slug}.md" "$state/${slug}.md"
    _index_touch
    _wt_commit "append $slug"
    _sync_ready_room
}

cmd_audit() {
    _ensure_dirs

    local all_plans=()
    for dir in "$TODO_DIR" "$DOING_DIR" "$DONE_DIR"; do
        for plan in "$dir"/*.md; do
            [[ -f "$plan" ]] || continue
            all_plans+=("$plan")
        done
    done

    if [[ ${#all_plans[@]} -eq 0 ]]; then
        echo "No plans found."
        return 0
    fi

    # Build plan summary for reviewer
    local summary=""
    for plan in "${all_plans[@]}"; do
        local name state
        name=$(basename "$plan" .md)
        state=$(_plan_state "$name")
        local header
        header=$(head -20 "$plan")
        summary+="--- $state/$name.md ---
$header
---

"
    done

    local prompt
    prompt=$(cat << AUDIT_PROMPT
You are a plan auditor. Review the following plans for conformity and health.

For each plan, check:
1. CONFORMITY: Has all required fields? (Date, Dernière révision, Statut, Priorité, Milestone, Assigné, Référencé par, Dérivé de, Objectif, Livrables, Critères d'acceptance)
2. STALENESS: Dernière révision > 30 days ago with no activity?
3. SUPERSEDED: Another plan covers the same scope? (check for overlapping objectives)
4. REFERENCES: Points to files or plans that might no longer exist?

Today's date: $(_today)

Output format (strict):
## Plan audit report

### <plan-name> (<state>)
- Conformity: OK | MISSING: <fields>
- Staleness: OK | STALE (last revised: <date>)
- Superseded: OK | POSSIBLY by <other-plan>
- References: OK | BROKEN: <details>

(repeat for each plan)

### Summary
- Total: N plans
- Conformity issues: N
- Stale: N
- Possibly superseded: N

--- PLANS ---
$summary
AUDIT_PROMPT
)

    local validator
    validator="$(_validator_role)"
    echo "Dispatching $validator for audit..." >&2

    local dispatch_bin=""
    if type -t fleet_bin &>/dev/null; then
        dispatch_bin="$(fleet_bin fleet-dispatch.sh)"
    fi
    [[ -z "$dispatch_bin" || ! -x "$dispatch_bin" ]] && dispatch_bin="$(command -v fleet-dispatch.sh 2>/dev/null || true)"
    [[ -z "$dispatch_bin" || ! -x "$dispatch_bin" ]] && dispatch_bin="$(dirname "${BASH_SOURCE[0]}")/fleet-dispatch.sh"

    if [[ ! -x "$dispatch_bin" ]]; then
        echo "ERROR: fleet-dispatch.sh not found — cannot audit without $validator" >&2
        return 1
    fi

    local tmp_prompt
    tmp_prompt=$(mktemp /tmp/fleet-plan-audit-XXXXXX)
    trap 'rm -f "$tmp_prompt"' EXIT
    printf '%s' "$prompt" > "$tmp_prompt"
    local result=""
    local dispatch_exit=0
    result=$("$dispatch_bin" "$validator" "plan-audit" "$tmp_prompt" 2>/dev/null) || dispatch_exit=$?
    [[ $dispatch_exit -ne 0 ]] && echo "WARN: [fleet-plan] audit dispatch failed (exit $dispatch_exit)" >&2
    rm -f "$tmp_prompt"

    echo "$result"
}

# ---------------------------------------------------------------------------
# Main dispatcher
# ---------------------------------------------------------------------------
case "${1:-}" in
    new)    shift; cmd_new "$@" ;;
    start)  shift; cmd_start "$@" ;;
    done)   shift; cmd_done "$@" ;;
    check)  shift; cmd_check "$@" ;;
    list)   shift; cmd_list "$@" ;;
    append)     shift; cmd_append "$@" ;;
    scratchpad) shift; cmd_scratchpad "$@" ;;
    backlog)    shift; cmd_backlog "$@" ;;
    audit)      shift; cmd_audit "$@" ;;
    *)
        echo "fleet-plan.sh — plan lifecycle manager"
        echo ""
        echo "Usage: fleet-plan.sh <command> [args]"
        echo ""
        echo "Commands:"
        echo "  new <slug>              Create plan in TODO/"
        echo "  start <slug>            Move TODO/ → doing/"
        echo "  done <slug> [--step N]  Validate + move doing/ → done/"
        echo "  check <slug> [--step N] Dry-run validation (no move)"
        echo "  list [TODO|doing|done]  Show all plans"
        echo "  append <slug>           Append stdin to existing plan"
        echo "  scratchpad <text>       Append entry to scratchpad.md"
        echo "  backlog <text>          Add item to backlog.md"
        echo "  audit                   Check all plans for conformity"
        echo ""
        echo "Project root: $PROJECT_ROOT"
        exit 1
        ;;
esac
