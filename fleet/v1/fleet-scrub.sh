#!/bin/bash
# DEPLOY: instance-util
#
#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-scrub.sh
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
#     | MODULE: FLEET-SCRUB     | SUBSYSTEM: WORK MAINTENANCE     |
#     | LICENSE: AGPL-3         | STARDATE: 2026.090              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Periodic maintenance for work/ pipeline.                 |
#     |  Scrubs scratchpad and backlog via reviewer headless.     |
#     |  Bootstraps index.md from current state.                  |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     Maintenance périodique du pipeline work/.
#     Triage scratchpad/backlog par reviewer headless + bootstrap index.
#
#     [EN]
#     NAME
#         fleet-scrub.sh — triage scratchpad et backlog
#
#     SYNOPSIS
#         fleet-scrub.sh <command>
#
#     DESCRIPTION
#         Trie les captures brutes (scratchpad) et le backlog via un reviewer
#         headless. Route les items vers NOW / BACKLOG / PLAN / CADUC.
#         Vide la source après traitement.
#
#     INTERFACE
#         Ring:    3 (kernel)
#         Input:   work/scratchpad.md or work/backlog.md
#         Output:  routed items (backlog.md, plans via fleet-plan.sh), source cleared
#         JSON:    non
#
#     COMMANDS
#         scratchpad    Trier scratchpad.md → NOW | BACKLOG (→ backlog.md) | CADUC
#         backlog       Trier backlog.md → NOW | PLAN:new | PLAN:append | CADUC
#         init          Bootstrap index.md depuis l'état courant de work/
#
#     EXAMPLES
#         fleet-scrub.sh scratchpad    # trier le scratchpad
#         fleet-scrub.sh backlog       # trier le backlog en plans
#         fleet-scrub.sh init          # reconstruire l'index
#
#     EXIT CODES
#         0    Succès
#         1    Scrub échoué (dispatch indisponible, source vide)
#
#     SEE ALSO
#         fleet-plan.sh, fleet-dispatch.sh
#
# --- END HEADER ---

# --help: extract [EN] section from this header
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && {
    sed -n '/^#     \[EN\]/,/^# --- END HEADER ---/{/\[EN\]/d; /END HEADER/d; s/^#     //; s/^#[[:space:]]*$//; p}' "$0"
    exit 0
}

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve project root: walk up from $PWD looking for work/ directory
# ---------------------------------------------------------------------------
_resolve_project() {
    local dir="$PWD"
    while [[ "$dir" != "/" ]]; do
        if [[ -d "$dir/work" ]]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    echo "ERROR: no project root found (no work/ directory above $PWD)" >&2
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
BACKLOG="$WORK_DIR/backlog.md"

# ---------------------------------------------------------------------------
# Source fleet-env if available
# ---------------------------------------------------------------------------
_FLEET_ENV=""
[[ -x "$HOME/.local/bin/fleet-env.sh" ]] && _FLEET_ENV="$HOME/.local/bin/fleet-env.sh"
[[ -z "$_FLEET_ENV" ]] && [[ -f "$HOME/fleet/fleet-env.sh" ]] && _FLEET_ENV="$HOME/fleet/fleet-env.sh"
if [[ -n "$_FLEET_ENV" ]]; then
    # shellcheck source=/dev/null
    source "$_FLEET_ENV" 2>/dev/null || true
fi

# Scratchpad — volatile, outside worktree (fleet-state)
SCRATCHPAD="${FLEET_SCRATCHPAD:-/home/fleet-state/scratchpad-${FLEET_PROJECT:-LCARS}.md}"

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

_sync_ready_room() {
    :
}

# Resolve fleet-dispatch.sh
_resolve_dispatch() {
    local dispatch_bin=""
    if type -t fleet_bin &>/dev/null; then
        dispatch_bin="$(fleet_bin fleet-dispatch.sh)"
    fi
    [[ -z "$dispatch_bin" || ! -x "$dispatch_bin" ]] && dispatch_bin="$(command -v fleet-dispatch.sh 2>/dev/null || true)"
    [[ -z "$dispatch_bin" || ! -x "$dispatch_bin" ]] && dispatch_bin="$(dirname "${BASH_SOURCE[0]}")/fleet-dispatch.sh"

    if [[ -x "$dispatch_bin" ]]; then
        echo "$dispatch_bin"
        return 0
    fi
    echo "ERROR: fleet-dispatch.sh not found — cannot scrub without reviewer" >&2
    return 1
}

# Dispatch a prompt to reviewer headless, return result on stdout
_dispatch_reviewer() {
    local subject="$1"
    local prompt="$2"

    local dispatch_bin
    dispatch_bin="$(_resolve_dispatch)" || return 1

    local tmp_prompt
    tmp_prompt=$(mktemp "${FLEET_STATE_DIR:-/home/fleet-state}/run/fleet-scrub-XXXXXX")
    printf '%s' "$prompt" > "$tmp_prompt"

    local result=""
    local exit_code=0
    # Unified: always use reviewer (quality/compliance retired)
    result=$("$dispatch_bin" "reviewer" "$subject" "$tmp_prompt" 2>/dev/null) || exit_code=$?
    rm -f "$tmp_prompt"

    if [[ $exit_code -eq 124 ]]; then
        echo "ERROR: reviewer timed out" >&2
        return 1
    fi
    if [[ $exit_code -ne 0 ]]; then
        echo "ERROR: reviewer dispatch failed (exit $exit_code)" >&2
        return 1
    fi

    echo "$result"
}

# Update index.md — recent actions table (append, keep last 10)
_index_log() {
    local action="$1" source="$2" destination="$3"
    if [[ ! -f "$INDEX_FILE" ]]; then
        _index_init_stub
    fi
    local entry
    entry="| $(_today) | $action | $source | $destination |"
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

_index_touch() {
    if [[ -f "$INDEX_FILE" ]]; then
        sed "s/^\*\*Dernière mise à jour\*\* : .*/\*\*Dernière mise à jour\*\* : $(_today)/" "$INDEX_FILE" > "${INDEX_FILE}.tmp" && mv -f "${INDEX_FILE}.tmp" "$INDEX_FILE"
    fi
}

_index_scrub_stamp() {
    local source_type="$1"
    if [[ -f "$INDEX_FILE" ]]; then
        sed "s/^\*\*Dernier scrub $source_type\*\* : .*/\*\*Dernier scrub $source_type\*\* : $(_today)/" "$INDEX_FILE" > "${INDEX_FILE}.tmp" && mv -f "${INDEX_FILE}.tmp" "$INDEX_FILE"
    fi
}

# ---------------------------------------------------------------------------
# Parse structured triage output from reviewer
# Expected format per item:
#   N. [NOW|BACKLOG|PLAN:<slug>|PLAN:new:<slug>|CADUC] description — justification
# ---------------------------------------------------------------------------
_parse_triage_items() {
    local result="$1"
    local -n _now_items=$2
    local -n _backlog_items=$3
    local -n _plan_items=$4
    local -n _caduc_items=$5

    while IFS= read -r line; do
        case "$line" in
            *"[NOW]"*)
                _now_items+=("${line#*] }")
                ;;
            *"[BACKLOG]"*)
                _backlog_items+=("${line#*] }")
                ;;
            *"[PLAN:"*"]"*)
                _plan_items+=("$line")
                ;;
            *"[CADUC]"*)
                _caduc_items+=("${line#*] }")
                ;;
        esac
    done <<< "$result"
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_scratchpad() {
    if [[ ! -f "$SCRATCHPAD" ]]; then
        echo "No scratchpad.md found — nothing to scrub."
        return 0
    fi

    local content
    content=$(cat "$SCRATCHPAD")
    if [[ -z "$content" || "$content" =~ ^[[:space:]]*$ ]]; then
        echo "Scratchpad is empty — nothing to scrub."
        return 0
    fi

    # Build context: existing backlog + plan summaries for routing
    local backlog_content=""
    [[ -f "$BACKLOG" ]] && backlog_content=$(cat "$BACKLOG")

    local plan_summary=""
    for dir in "$TODO_DIR" "$DOING_DIR"; do
        for plan in "$dir"/*.md; do
            [[ -f "$plan" ]] || continue
            local name
            name=$(basename "$plan" .md)
            local state
            [[ "$dir" == "$TODO_DIR" ]] && state="TODO" || state="doing"
            plan_summary+="- $state/$name.md
"
        done
    done

    local prompt
    prompt=$(cat << SCRUB_PROMPT
You are a project manager triaging a scratchpad. Each entry is a raw note captured during an agent session.

For each entry, decide:
- NOW: actionable immediately, execute this session (urgent fix, blocker, quick task)
- BACKLOG: defer to backlog.md for later triage (not urgent, needs planning)
- CADUC: obsolete, already done, or no longer relevant (delete with trace)

Context — existing backlog:
${backlog_content:-"(empty)"}

Context — active plans:
${plan_summary:-"(none)"}

Output format (strict — one line per entry):
1. [NOW|BACKLOG|CADUC] entry summary — justification
2. [NOW|BACKLOG|CADUC] entry summary — justification
...

### Summary
- NOW: N items
- BACKLOG: N items
- CADUC: N items

--- SCRATCHPAD CONTENT ---
$content
SCRUB_PROMPT
)

    echo "Dispatching reviewer for scratchpad scrub..." >&2
    local result
    result="$(_dispatch_reviewer "scrub-scratchpad" "$prompt")" || return 1

    echo "$result"
    echo ""

    # Validate reviewer output contains at least one triage tag
    if ! echo "$result" | grep -qE '\[(NOW|BACKLOG|PLAN:|CADUC)\]'; then
        echo "WARN: reviewer output contains no triage tags ([NOW]/[BACKLOG]/[CADUC]) — scratchpad NOT cleared" >&2
        return 1
    fi

    # Parse results
    local now_items=() backlog_items=() plan_items=() caduc_items=()
    _parse_triage_items "$result" now_items backlog_items plan_items caduc_items

    # Apply: append backlog items to backlog.md
    if [[ ${#backlog_items[@]} -gt 0 ]]; then
        {
            echo ""
            echo "## Scrub $(_today)"
            for item in "${backlog_items[@]}"; do
                echo "- [ ] $item"
            done
        } >> "$BACKLOG"
        echo "Appended ${#backlog_items[@]} item(s) to backlog.md"
    fi

    # Log caduc items to index
    for item in "${caduc_items[@]}"; do
        _index_log "scrub: caduc" "scratchpad" "${item:0:60}"
    done

    # Log now items to index
    for item in "${now_items[@]}"; do
        _index_log "scrub: now" "scratchpad" "${item:0:60}"
    done

    # Clear scratchpad after scrub — only if routing succeeded
    local _routed_ok=true
    if [[ ${#backlog_items[@]} -gt 0 ]] && ! grep -q "Scrub $(_today)" "$BACKLOG" 2>/dev/null; then
        echo "WARN: backlog append may have failed — scratchpad NOT cleared" >&2
        _routed_ok=false
    fi
    if [[ "$_routed_ok" == true ]]; then
        : > "$SCRATCHPAD"
        echo "Scratchpad cleared."
    fi

    # Print NOW items for immediate action
    if [[ ${#now_items[@]} -gt 0 ]]; then
        echo ""
        echo "=== NOW — items to execute this session ==="
        local i=1
        for item in "${now_items[@]}"; do
            echo "$i. $item"
            ((i++))
        done
    fi

    _index_scrub_stamp "scratchpad"
    _index_touch
    _sync_ready_room
}

cmd_backlog() {
    if [[ ! -f "$BACKLOG" ]]; then
        echo "No backlog.md found — nothing to scrub."
        return 0
    fi

    local content
    content=$(cat "$BACKLOG")
    if [[ -z "$content" || "$content" =~ ^[[:space:]]*$ ]]; then
        echo "Backlog is empty — nothing to scrub."
        return 0
    fi

    # Build context: active plans for routing decisions
    local plan_summary=""
    for dir in "$TODO_DIR" "$DOING_DIR"; do
        for plan in "$dir"/*.md; do
            [[ -f "$plan" ]] || continue
            local name
            name=$(basename "$plan" .md)
            local state obj
            [[ "$dir" == "$TODO_DIR" ]] && state="TODO" || state="doing"
            obj=$(grep -A2 "^## Objectif" "$plan" 2>/dev/null | tail -1 || echo "—")
            plan_summary+="- $state/$name.md — $obj
"
        done
    done

    local prompt
    prompt=$(cat << SCRUB_PROMPT
You are a project manager triaging a backlog. Each item is a deferred task or idea.

For each item, decide:
- NOW: ready to execute, actionable this session
- PLAN:new:<slug>: item needs its own plan (complex, multi-step). Suggest a slug.
- PLAN:<existing-slug>: item belongs to an existing plan (append it)
- CADUC: obsolete, already done, or superseded by active work

Context — active plans:
${plan_summary:-"(none)"}

Output format (strict — one line per item):
1. [NOW|PLAN:new:<slug>|PLAN:<slug>|CADUC] item summary — justification
2. [NOW|PLAN:new:<slug>|PLAN:<slug>|CADUC] item summary — justification
...

### Summary
- NOW: N items
- PLAN (new): N items
- PLAN (append): N items
- CADUC: N items

--- BACKLOG CONTENT ---
$content
SCRUB_PROMPT
)

    echo "Dispatching reviewer for backlog scrub..." >&2
    local result
    result="$(_dispatch_reviewer "scrub-backlog" "$prompt")" || return 1

    echo "$result"
    echo ""

    # Validate reviewer output contains at least one triage tag
    if ! echo "$result" | grep -qE '\[(NOW|BACKLOG|PLAN:|CADUC)\]'; then
        echo "WARN: reviewer output contains no triage tags — backlog NOT cleared" >&2
        return 1
    fi

    # Parse results
    local now_items=() backlog_items=() plan_items=() caduc_items=()
    _parse_triage_items "$result" now_items backlog_items plan_items caduc_items

    # Process PLAN items
    local plan_new_count=0
    local plan_append_count=0
    local plan_fail_count=0
    for item in "${plan_items[@]}"; do
        if [[ "$item" =~ \[PLAN:new:([a-z0-9_-]+)\] ]]; then
            local slug="${BASH_REMATCH[1]}"
            echo "→ Creating plan TODO/$slug.md"
            local plan_bin=""
            if type -t fleet_bin &>/dev/null; then
                plan_bin="$(fleet_bin fleet-plan.sh)"
            fi
            [[ -z "$plan_bin" || ! -x "$plan_bin" ]] && plan_bin="$(command -v fleet-plan.sh 2>/dev/null || true)"
            [[ -z "$plan_bin" || ! -x "$plan_bin" ]] && plan_bin="$(dirname "${BASH_SOURCE[0]}")/fleet-plan.sh"

            if [[ -x "$plan_bin" ]]; then
                "$plan_bin" new "$slug" || { echo "WARN: failed to create plan $slug" >&2; ((plan_fail_count++)); }
            else
                echo "WARN: fleet-plan.sh not found, cannot create plan $slug" >&2
                ((plan_fail_count++))
            fi
            ((plan_new_count++))
        elif [[ "$item" =~ \[PLAN:([a-z0-9_-]+)\] ]]; then
            local slug="${BASH_REMATCH[1]}"
            local desc="${item#*] }"
            echo "→ Appending to plan $slug"
            local plan_bin=""
            if type -t fleet_bin &>/dev/null; then
                plan_bin="$(fleet_bin fleet-plan.sh)"
            fi
            [[ -z "$plan_bin" || ! -x "$plan_bin" ]] && plan_bin="$(command -v fleet-plan.sh 2>/dev/null || true)"
            [[ -z "$plan_bin" || ! -x "$plan_bin" ]] && plan_bin="$(dirname "${BASH_SOURCE[0]}")/fleet-plan.sh"

            if [[ -x "$plan_bin" ]]; then
                echo "$desc" | "$plan_bin" append "$slug" || { echo "WARN: failed to append to plan $slug" >&2; ((plan_fail_count++)); }
            else
                echo "WARN: fleet-plan.sh not found, cannot append to plan $slug" >&2
                ((plan_fail_count++))
            fi
            ((plan_append_count++))
        fi
    done

    # Log caduc items to index
    for item in "${caduc_items[@]}"; do
        _index_log "scrub: caduc" "backlog" "${item:0:60}"
    done

    # Log now items to index
    for item in "${now_items[@]}"; do
        _index_log "scrub: now" "backlog" "${item:0:60}"
    done

    # Clear backlog — only if all plan routing succeeded
    if [[ "$plan_fail_count" -gt 0 ]]; then
        echo "WARN: $plan_fail_count plan route(s) failed — backlog NOT cleared (items preserved)" >&2
    else
        : > "$BACKLOG"
        echo "Backlog cleared."
    fi

    # Print NOW items for immediate action
    if [[ ${#now_items[@]} -gt 0 ]]; then
        echo ""
        echo "=== NOW — items to execute this session ==="
        local i=1
        for item in "${now_items[@]}"; do
            echo "$i. $item"
            ((i++))
        done
    fi

    echo ""
    echo "Routed: ${#now_items[@]} now, $plan_new_count new plans, $plan_append_count plan appends, ${#caduc_items[@]} caduc"

    _index_scrub_stamp "backlog"
    _index_touch
    _sync_ready_room
}

cmd_init() {
    _ensure_dirs

    if [[ -f "$INDEX_FILE" ]]; then
        echo "WARN: index.md already exists — will be overwritten" >&2
    fi

    # Build index from current state
    local today
    today="$(_today)"

    # Collect plans
    local todo_plans=() doing_plans=() done_plans=()
    for plan in "$TODO_DIR"/*.md; do
        [[ -f "$plan" ]] || continue
        todo_plans+=("$(basename "$plan" .md)")
    done
    for plan in "$DOING_DIR"/*.md; do
        [[ -f "$plan" ]] || continue
        doing_plans+=("$(basename "$plan" .md)")
    done
    for plan in "$DONE_DIR"/*.md; do
        [[ -f "$plan" ]] || continue
        done_plans+=("$(basename "$plan" .md)")
    done

    # Detect thematic sections by scanning plan objectives
    declare -A themes
    for dir in "$TODO_DIR" "$DOING_DIR" "$DONE_DIR"; do
        for plan in "$dir"/*.md; do
            [[ -f "$plan" ]] || continue
            local name
            name=$(basename "$plan" .md)
            local state
            [[ "$dir" == "$TODO_DIR" ]] && state="TODO"
            [[ "$dir" == "$DOING_DIR" ]] && state="doing"
            [[ "$dir" == "$DONE_DIR" ]] && state="done"
            local obj
            obj=$(awk '/^## Objectif/{getline; if(NF>0) print; else {getline; print}}' "$plan" 2>/dev/null | head -1)
            [[ -z "$obj" ]] && obj="(pas d'objectif)"
            themes["$name"]="$state | $obj"
        done
    done

    # Write index
    {
        cat << HEADER
# Work Index

**Dernière mise à jour** : $today
**Dernier scrub scratchpad** : —
**Dernier scrub backlog** : —

## Actions récentes (10 dernières)

| Date | Action | Source | Destination |
|---|---|---|---|
| $today | index bootstrap | init | index.md |

## Plans actifs

| Plan | État | Objectif |
|---|---|---|
HEADER
        for name in "${doing_plans[@]}"; do
            local info="${themes[$name]}"
            echo "| $name | ${info} |"
        done

        cat << MID

## Plans en attente

| Plan | État | Objectif |
|---|---|---|
MID
        for name in "${todo_plans[@]}"; do
            local info="${themes[$name]}"
            echo "| $name | ${info} |"
        done

        cat << MID2

## Plans terminés

| Plan | État | Objectif |
|---|---|---|
MID2
        for name in "${done_plans[@]}"; do
            local info="${themes[$name]}"
            echo "| $name | ${info} |"
        done

        # Scratchpad and backlog status
        echo ""
        echo "## État pipeline"
        echo ""
        if [[ -f "$SCRATCHPAD" ]]; then
            local sp_lines
            sp_lines=$(wc -l < "$SCRATCHPAD")
            echo "- Scratchpad : $sp_lines lignes"
        else
            echo "- Scratchpad : absent"
        fi
        if [[ -f "$BACKLOG" ]]; then
            local bl_lines
            bl_lines=$(wc -l < "$BACKLOG")
            echo "- Backlog : $bl_lines lignes"
        else
            echo "- Backlog : absent"
        fi
    } > "$INDEX_FILE"

    echo "OK: index.md bootstrapped"
    echo "  - ${#todo_plans[@]} plans TODO"
    echo "  - ${#doing_plans[@]} plans doing"
    echo "  - ${#done_plans[@]} plans done"

    _sync_ready_room
}

# ---------------------------------------------------------------------------
# Main dispatcher
# ---------------------------------------------------------------------------
case "${1:-}" in
    scratchpad) shift; cmd_scratchpad "$@" ;;
    backlog)    shift; cmd_backlog "$@" ;;
    init)       shift; cmd_init "$@" ;;
    *)
        echo "fleet-scrub.sh — work/ maintenance"
        echo ""
        echo "Usage: fleet-scrub.sh <command>"
        echo ""
        echo "Commands:"
        echo "  scratchpad    Triage scratchpad → now | backlog | caduc"
        echo "  backlog       Triage backlog → now | plan (new/append) | caduc"
        echo "  init          Bootstrap index.md from current state"
        echo ""
        echo "Project root: $PROJECT_ROOT"
        exit 1
        ;;
esac
