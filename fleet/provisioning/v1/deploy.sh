#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: deploy.sh
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
#     | MODULE: DEPLOY          | SUBSYSTEM: FLEET / INSTALL      |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Syncs fleet/, .claude/, memory/ to each instance.        |
#     |                                                           |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#           ______________________________________________________
#          /          LCARS FLEET - FEDERATION DATABASE           \
#         |   ________   __________________________________________\
#         |  |  2026  |  | SOURCE: deploy.sh
#         |  |________|  | AUTHOR: LORDZURP
#         |   ________   | SYSTEM: LCARS-FLEET v5.4
#
#     [EN]
#     deploy.sh — Syncs fleet/, .claude/, memory/ to each instance.
#
#
# --- END HEADER ---


set -euo pipefail

# --- Resolve paths ---
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
DEPLOY_DIR="$(dirname "${BASH_SOURCE[0]}")/deploy.d"
SOURCE_DIR="$SCRIPT_DIR/.claude"
PATCH_JSON="$SCRIPT_DIR/fleet/toolbox/patch-json.py"
FLEET_SRC="$SCRIPT_DIR/fleet"

# --- Load shared library ---
source "$(dirname "${BASH_SOURCE[0]}")/deploy-lib.sh"

# --- Load fleet environment ---
source "$SCRIPT_DIR/fleet/fleet-env.sh"
FLEET_USER=$(_yq '.fleet.identity.fleet_user')
FLEET_USER_HOME=$(getent passwd "${FLEET_USER:-$USER}" 2>/dev/null | cut -d: -f6)
: "${FLEET_USER_HOME:=$HOME}"

# --- Build targets from blueprint (linux_user if set, else role) ---
# ROLE_FOR_USER maps linux_user -> role (for when linux_user != role)
declare -A ROLE_FOR_USER
TARGETS=()
while IFS= read -r role; do
    _lu="$(fleet_role_field "$role" "linux_user")"
    [[ "$_lu" == "null" || -z "$_lu" ]] && _lu="$role"
    TARGETS+=("$HOMES_ROOT/$_lu/.claude")
    ROLE_FOR_USER["$_lu"]="$role"
done < <(fleet_roles)

# resolve_role: get role from target path (supports linux_user != role)
resolve_role() {
    local _user
    _user="$(basename "$(dirname "$1")")"
    echo "${ROLE_FOR_USER[$_user]:-$_user}"
}

DIRS_TO_SYNC=("commands" "hooks" "skills" "agents")

# Pre-filter: skip non-provisioned homes
EFFECTIVE_TARGETS=()
for _T in "${TARGETS[@]}"; do
    if [ ! -d "$_T" ]; then
        : # Home not provisioned — expected for optional roles (e.g. consultant)
    elif [ ! -w "$_T" ]; then
        echo "  $_FAIL — not writable] $_T (run provision-user.sh first)"
    else
        EFFECTIVE_TARGETS+=("$_T")
    fi
done
TARGETS=("${EFFECTIVE_TARGETS[@]}")

# --- Parse args ---
DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=1
    echo "$_dryrun Aucune copie effectuée."
fi

# --- --update-models (early exit) ---
if [ "${1:-}" = "--update-models" ]; then
    echo "=== --update-models : patching settings.local.json per instance (from blueprint) ==="
    while IFS= read -r instance; do
        model=$(fleet_role_field "$instance" "model")
        [[ "$model" == "null" || -z "$model" ]] && continue
        _lu="$(fleet_role_field "$instance" "linux_user")"
        [[ "$_lu" == "null" || -z "$_lu" ]] && _lu="$instance"
        settings="$HOMES_ROOT/$_lu/.claude/settings.local.json"
        if [ -f "$settings" ]; then
            python3 "$PATCH_JSON" set-field "$settings" "model" "$model"
        else
            echo "  $instance: settings.local.json not found — skip"
        fi
    done < <(fleet_roles)
    exit 0
fi

# --- Deploy sequence ---
TOTAL_COPIED=0

source "$DEPLOY_DIR/deploy-claude.sh"
source "$DEPLOY_DIR/deploy-fleet.sh"
source "$DEPLOY_DIR/deploy-bashrc.sh"
source "$DEPLOY_DIR/deploy-hooks.sh"
source "$DEPLOY_DIR/deploy-infra.sh"

# --- Config lockdown (MUST run AFTER all deploy sub-scripts) ---
# Pattern from codex integration: agents cannot modify their own SP, hooks,
# skills, settings, or commands. Prevents self-modification via /tmp tricks.
# Runs last because deploy-hooks.sh writes settings.local.json as root.
echo ""
echo "=== config lockdown → all instances ==="
while IFS= read -r _role; do
    # F-C1 FIX: resolve linux_user for home path (role != linux_user possible)
    _lu="$(fleet_resolve_user "$_role")"
    _claude_dir="$HOMES_ROOT/$_lu/.claude"
    [ -d "$_claude_dir" ] || continue
    if [ "$DRY_RUN" -eq 0 ]; then
        for _cf in system-prompt.md CLAUDE.md settings.json settings.local.json instance-name; do
            [ -f "$_claude_dir/$_cf" ] && chown "$FLEET_USER:fleet" "$_claude_dir/$_cf" && chmod 644 "$_claude_dir/$_cf"
        done 2>/dev/null
        for _cd in hooks commands skills agents; do
            [ -d "$_claude_dir/$_cd" ] && chown -R "$FLEET_USER:fleet" "$_claude_dir/$_cd" && chmod -R u=rwX,g=rX,o= "$_claude_dir/$_cd"
        done 2>/dev/null
        chown "$FLEET_USER:fleet" "$_claude_dir" && chmod 1770 "$_claude_dir"
    fi
done < <(fleet_roles)
if [ "$DRY_RUN" -eq 0 ]; then
    echo "  $_ok config lockdown — SP/hooks/skills/settings owned by $FLEET_USER (sticky)"
fi

# --- Summary ---
echo ""
if [ "$DRY_RUN" -eq 0 ]; then
    echo "Déploiement terminé. $TOTAL_COPIED fichier(s) copié(s)."
else
    echo "Dry-run terminé. Aucune modification effectuée."
fi
