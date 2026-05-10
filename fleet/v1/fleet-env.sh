#!/bin/bash
# DEPLOY: instance-util

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-env.sh
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
#     | MODULE: FLEET-ENV       | SUBSYSTEM: CORE                 |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Centralized fleet paths and variables.                   |
#     |  Single source of truth for all fleet scripts.            |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     DEPLOY: instance-util
#
#           ______________________________________________________
#          /          LCARS FLEET - FEDERATION DATABASE           \
#         |   ________   __________________________________________\
#         |  |  2026  |  | SOURCE: fleet-env.sh
#         |  |________|  | AUTHOR: LORDZURP
#
#     [EN]
#     fleet-env.sh — Centralized fleet paths and variables.
#     Single source of truth for all fleet scripts.
#
#
# --- END HEADER ---


set -euo pipefail

# --- Direct execution mode: --json dumps all exported vars as JSON ---
# fleet-env.sh is normally sourced. When executed directly with --json,
# it sources itself then outputs the Ring 0 interface as structured JSON.
if [[ "${1:-}" == "--json" && "${BASH_SOURCE[0]}" == "$0" && -z "${_FLEET_ENV_JSON:-}" ]]; then
    # shellcheck source=fleet-env.sh
    _FLEET_ENV_JSON=1 source "${BASH_SOURCE[0]}"
    # IEC 61508: use jq -n to prevent JSON injection from variable values
    jq -n \
      --arg lcars_root "$LCARS_ROOT" \
      --arg homes_root "$HOMES_ROOT" \
      --arg fleet_yaml "$FLEET_YAML" \
      --arg fleet_dir "$FLEET_DIR" \
      --arg fleet_directives "$FLEET_DIRECTIVES" \
      --arg fleet_docs "$FLEET_DOCS" \
      --arg fleet_knowledge "$FLEET_KNOWLEDGE" \
      --arg fleet_project "$FLEET_PROJECT" \
      --arg fleet_workdir "$FLEET_WORKDIR" \
      --arg fleet_handoffs "$FLEET_HANDOFFS" \
      --arg fleet_scratchpad "$FLEET_SCRATCHPAD" \
      --arg fleet_state_dir "$FLEET_STATE_DIR" \
      --arg fleet_logs "$FLEET_LOGS" \
      --arg fleet_ready_room "$FLEET_READY_ROOM" \
      --arg fleet_tmux_sock "$FLEET_TMUX_SOCK" \
      --arg fleet_hub_port "$FLEET_HUB_PORT" \
      --arg fleet_spool "$FLEET_SPOOL" \
      --arg fleet_spool_inbox "$FLEET_SPOOL_INBOX" \
      --arg fleet_spool_outbox "$FLEET_SPOOL_OUTBOX" \
      --arg fleet_pending_wakes "$FLEET_PENDING_WAKES" \
      --arg fleet_instance "$FLEET_INSTANCE" \
      --arg fleet_user "$FLEET_USER" \
      --arg fleet_user_home "$FLEET_USER_HOME" \
      --arg architect_user "$ARCHITECT_USER" \
      --arg architect_home "$ARCHITECT_HOME" \
      --arg lcars_repo "$LCARS_REPO" \
      '{
        lcars_root: $lcars_root, homes_root: $homes_root,
        fleet_yaml: $fleet_yaml, fleet_dir: $fleet_dir,
        fleet_directives: $fleet_directives, fleet_docs: $fleet_docs,
        fleet_knowledge: $fleet_knowledge, fleet_project: $fleet_project,
        fleet_workdir: $fleet_workdir, fleet_handoffs: $fleet_handoffs,
        fleet_scratchpad: $fleet_scratchpad, fleet_state_dir: $fleet_state_dir,
        fleet_logs: $fleet_logs, fleet_ready_room: $fleet_ready_room,
        fleet_tmux_sock: $fleet_tmux_sock, fleet_hub_port: $fleet_hub_port,
        fleet_spool: $fleet_spool, fleet_spool_inbox: $fleet_spool_inbox,
        fleet_spool_outbox: $fleet_spool_outbox, fleet_pending_wakes: $fleet_pending_wakes,
        fleet_instance: $fleet_instance, fleet_user: $fleet_user,
        fleet_user_home: $fleet_user_home, architect_user: $architect_user,
        architect_home: $architect_home, lcars_repo: $lcars_repo
      }'
    exit 0
fi

# --- Re-source guard (same shell, same PID → skip) ---
[[ -n "${_FLEET_ENV_LOADED:-}" ]] && return 0 2>/dev/null

# --- Resolve own location (works through symlinks) ---
FLEET_ENV_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

# --- Precondition: yq ---
if ! command -v yq &>/dev/null; then
    echo "ERROR: yq not found — fleet-env.sh requires yq for blueprint queries" >&2
    echo "  Install: sudo apt-get install -y yq  OR  snap install yq" >&2
    return 1 2>/dev/null || exit 1
fi

# --- fleet.yaml location ---
# When deployed to ~/.local/bin/, fleet.yaml is not co-located.
# Resolve via ~/.lcars symlink (deploy.sh creates ~/.lcars → /local/LCARS on every instance).
# JUPITER-002: fail-closed — fleet.yaml MUST exist in operational mode.
if [ -f "$FLEET_ENV_DIR/fleet.yaml" ]; then
    FLEET_YAML="$FLEET_ENV_DIR/fleet.yaml"
elif [ -f "$HOME/.lcars/fleet/fleet.yaml" ]; then
    FLEET_YAML="$HOME/.lcars/fleet/fleet.yaml"
else
    echo "ERROR: fleet.yaml not found — fleet-env.sh cannot proceed without blueprint" >&2
    echo "  Searched: $FLEET_ENV_DIR/fleet.yaml, $HOME/.lcars/fleet/fleet.yaml" >&2
    return 1 2>/dev/null || exit 1
fi

# JUPITER-001: shell cache removed — sourcing a writable cache file is a code
# execution primitive. All variables are now computed fresh from fleet.yaml on
# every source. The yq cost (~200ms) is acceptable for a sealed system.
{

# --- YAML query helper (cold start — also defined after cache block for external callers) ---
_yq() { timeout 5 yq "$@" "$FLEET_YAML" 2>/dev/null; }

# --- Base paths from fleet.yaml ---
LCARS_ROOT="$(_yq '.fleet.paths.lcars_root')"
HOMES_ROOT="$(_yq '.fleet.paths.homes_root')"

# Fallbacks if fleet.yaml missing or unreadable
[[ "$LCARS_ROOT" == "null" ]] && LCARS_ROOT=""
[[ "$HOMES_ROOT" == "null" ]] && HOMES_ROOT=""
: "${LCARS_ROOT:=/local/LCARS}"
: "${HOMES_ROOT:=/home}"

# --- Derived paths (single place to change if structure moves) ---
# Repo structure
FLEET_DIR="$LCARS_ROOT/fleet"
FLEET_DIRECTIVES="$LCARS_ROOT/directives"
FLEET_DOCS="$LCARS_ROOT/docs"
FLEET_KNOWLEDGE="$LCARS_ROOT/knowledge"

# Fleet state — persistent state dir
_FST="$(_yq '.fleet.paths.fleet_state')"
[[ "$_FST" == "null" || -z "$_FST" ]] && _FST=""
FLEET_STATE_DIR="${_FST:-/home/fleet-state}"

FLEET_LOGS="$FLEET_STATE_DIR"

# Ready Room = sole persistent user↔fleet gate (drvfs)
_RR="$(_yq '.fleet.paths.ready_room')"
[[ "$_RR" == "null" || -z "$_RR" ]] && _RR=""
FLEET_READY_ROOM="${_RR:-/home/ready-room}"

# --- Identity (from fleet.yaml) — must be before Runtime (FLEET_USER needed for tmux socket) ---
_FLEET_USER="$(_yq '.fleet.identity.fleet_user')"
[[ "$_FLEET_USER" == "null" ]] && _FLEET_USER=""
FLEET_USER="${_FLEET_USER:-$(whoami)}"

# Runtime — tmux default socket (no custom -S, server started by fleet_user)
_TMUX_UID="$(id -u "$FLEET_USER" 2>/dev/null || echo "$UID")"
FLEET_TMUX_SOCK="/tmp/tmux-${_TMUX_UID}/default"

_HUB_PORT="$(_yq '.fleet.runtime.hub_port')"
[[ "$_HUB_PORT" == "null" ]] && _HUB_PORT=""
FLEET_HUB_PORT="${FLEET_HUB_PORT:-${_HUB_PORT:-8765}}"

# Spool IPC — Linux-native message passing (v5)
_SPOOL="$(_yq '.spool.root')"
[[ "$_SPOOL" == "null" || -z "$_SPOOL" ]] && _SPOOL=""
FLEET_SPOOL="${_SPOOL:-/var/spool/fleet}"
FLEET_SPOOL_INBOX="$FLEET_SPOOL/inbox"
FLEET_SPOOL_OUTBOX="$FLEET_SPOOL/outbox"
FLEET_PENDING_WAKES="$FLEET_SPOOL/pending-wakes"

# Project binding (v7 Phase 3 — worktree)
# FLEET_PROJECT: active project name (from tmux env or default LCARS)
# FLEET_WORKDIR: path to worktree work/ (e.g. /home/projects.work/LCARS/work)
if [[ -n "${FLEET_PROJECT:-}" ]]; then
    : # already set (tmux env or explicit)
elif [[ -S "${FLEET_TMUX_SOCK}" ]] && command -v tmux >/dev/null 2>&1; then
    _tp="$(tmux show-environment FLEET_PROJECT 2>/dev/null | sed 's/^FLEET_PROJECT=//' || true)"
    [[ -n "$_tp" && "$_tp" != "-FLEET_PROJECT" ]] && FLEET_PROJECT="$_tp"
fi
: "${FLEET_PROJECT:=LCARS}"
FLEET_WORKDIR="${HOMES_ROOT}/projects.work/${FLEET_PROJECT}/work"

# Handoffs — versioned in worktree work/ops branch
FLEET_HANDOFFS="${FLEET_WORKDIR}/handoffs"

# Scratchpad — volatile, not versioned (outside worktree)
FLEET_SCRATCHPAD="/home/fleet-state/scratchpad-${FLEET_PROJECT}.md"

# --- Identity (continued — home, architect) ---
# FLEET_USER already set above (before Runtime block)
# Resolve home without eval (eval + user input = injection risk)
_passwd_entry="$(getent passwd "$FLEET_USER" 2>/dev/null || true)"
if [[ -n "$_passwd_entry" ]]; then
    FLEET_USER_HOME="$(printf '%s' "$_passwd_entry" | cut -d: -f6)"
else
    FLEET_USER_HOME="/home/$FLEET_USER"
fi
_ARCHITECT="$(_yq '.fleet.instances[] | select(.scope == "boundary-user") | .role' | head -1)"
[[ "$_ARCHITECT" == "null" || -z "$_ARCHITECT" ]] && _ARCHITECT="architect"
ARCHITECT_USER="$_ARCHITECT"
ARCHITECT_HOME="$HOMES_ROOT/$ARCHITECT_USER"

# --- GitHub repo (overridable for forks) ---
_REPO="$(_yq '.fleet.repo')"
[[ "$_REPO" == "null" ]] && _REPO=""
LCARS_REPO="${LCARS_REPO:-${_REPO:-lordzurp/LCARS-fleet}}"

}  # end computation block

# --- YAML query helper (always defined, cache or not — used by dispatch, wake, etc.) ---
_yq() { timeout 5 yq "$@" "$FLEET_YAML" 2>/dev/null; }

# --- Instance identity (always recalculated, not cached — hostname/agent can change) ---
FLEET_INSTANCE="${FLEET_INSTANCE:-${CLAUDE_AGENT_NAME:-$(cat "$HOME/.claude/instance-name" 2>/dev/null || hostname)}}"

# --- Blueprint query functions (always defined, cache or not) ---
fleet_roles() {
    yq '.instances[].role' "$FLEET_YAML"
}

fleet_roles_by_tier() {
    [[ "${1:-}" =~ ^[0-9]+$ ]] || { echo "ERROR: fleet_roles_by_tier: tier must be numeric, got '${1:-}'" >&2; return 1; }
    yq ".instances[] | select(.tier == ${1}) | .role" "$FLEET_YAML"
}

fleet_roles_stateless() {
    yq '.instances[] | select(.stateless == true) | .role' "$FLEET_YAML"
}

fleet_roles_stateful() {
    yq '.instances[] | select(.stateless != true) | .role' "$FLEET_YAML"
}

fleet_role_field() {
    [[ "${1:-}" =~ ^[a-z0-9_-]+$ ]] || { echo "ERROR: fleet_role_field: invalid role '${1:-}'" >&2; return 1; }
    [[ "${2:-}" =~ ^[a-z0-9_.]+$ ]] || { echo "ERROR: fleet_role_field: invalid field '${2:-}'" >&2; return 1; }
    yq ".instances[] | select(.role == \"${1}\") | .${2}" "$FLEET_YAML"
}

# F-C1 FIX: resolve linux_user → role (single source of truth for identity)
# Returns role for the given linux username (or the username itself if linux_user == role).
# Fails with exit 1 if the user is not in the blueprint.
fleet_resolve_role() {
    local _uid_user="${1:-$(whoami)}"
    local _r _lu
    while IFS= read -r _r; do
        _lu=$(fleet_role_field "$_r" "linux_user")
        [[ "$_lu" == "null" || -z "$_lu" ]] && _lu="$_r"
        if [[ "$_lu" == "$_uid_user" ]]; then
            echo "$_r"
            return 0
        fi
    done < <(fleet_roles)
    echo "ERROR: fleet_resolve_role: user '$_uid_user' not in blueprint" >&2
    return 1
}

# Resolve role → linux_user (inverse of fleet_resolve_role)
fleet_resolve_user() {
    local _role="${1:?usage: fleet_resolve_user <role>}"
    local _lu
    _lu=$(fleet_role_field "$_role" "linux_user")
    [[ "$_lu" == "null" || -z "$_lu" ]] && _lu="$_role"
    echo "$_lu"
}

# tmux access helper — sudo to socket owner when caller UID differs (tmux 3.4+)
fleet_tmux() {
    if [[ -S "$FLEET_TMUX_SOCK" ]] && [[ "$(id -u)" != "$(stat -c %u "$FLEET_TMUX_SOCK")" ]]; then
        sudo -u "$(stat -c %U "$FLEET_TMUX_SOCK")" tmux "$@"
    else
        tmux "$@"
    fi
}

# Resolve pane by @fleet-role user option — immune to CC title overwrites
fleet_find_pane() {
    local agent="$1"
    if [[ -S "$FLEET_TMUX_SOCK" ]]; then
        fleet_tmux list-panes -a \
            -F '#{@fleet-role} #{pane_id}' 2>/dev/null \
            | awk -v a="$agent" '$1 == a { print $2; exit }'
    else
        tmux list-panes -a \
            -F '#{@fleet-role} #{pane_id}' 2>/dev/null \
            | awk -v a="$agent" '$1 == a { print $2; exit }'
    fi
}

# Resolve fleet binary — handles PATH, ~/.local/bin/, ~/fleet/ fallbacks
fleet_bin() {
    local bin="$1"
    command -v "$bin" 2>/dev/null && return
    [[ -x "$HOME/.local/bin/$bin" ]] && { echo "$HOME/.local/bin/$bin"; return; }
    [[ -x "$HOME/fleet/$bin" ]] && { echo "$HOME/fleet/$bin"; return; }
    echo ""
}

# --- Security: scrub credentials from subprocesses (hooks, MCP, Bash tool) ---
export CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1

# --- Mark loaded (re-source guard + cache source both set this) ---
_FLEET_ENV_LOADED=1

# --- Export everything ---
export LCARS_ROOT HOMES_ROOT
export FLEET_YAML FLEET_DIR FLEET_DIRECTIVES FLEET_DOCS FLEET_KNOWLEDGE
export FLEET_PROJECT FLEET_WORKDIR FLEET_HANDOFFS FLEET_SCRATCHPAD
export FLEET_STATE_DIR FLEET_LOGS FLEET_READY_ROOM
export FLEET_TMUX_SOCK FLEET_HUB_PORT
export FLEET_SPOOL FLEET_SPOOL_INBOX FLEET_SPOOL_OUTBOX FLEET_PENDING_WAKES
export FLEET_INSTANCE
export FLEET_USER FLEET_USER_HOME ARCHITECT_USER ARCHITECT_HOME
export LCARS_REPO
export -f fleet_roles fleet_roles_by_tier fleet_roles_stateless fleet_roles_stateful fleet_role_field fleet_resolve_role fleet_resolve_user fleet_tmux fleet_find_pane fleet_bin
