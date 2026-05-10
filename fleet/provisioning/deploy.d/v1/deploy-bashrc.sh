#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: deploy-bashrc.sh
#     |  |________|  | AUTHOR: LORDZURP
#     |   ________   | SYSTEM: LCARS-FLEET v5.4
#     |  |  v5.4  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS-FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: DEPLOY-BASHRC   | SUBSYSTEM: PROVISIONING / DEPLOY|
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Patch .bashrc for all agents (AUTOCOMPACT, SESSION, AUTO_LAUNCH).|
#     |  Sourced by deploy.sh. Includes v5.3 migrations.          |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     Patche les .bashrc de tous les agents (AUTOCOMPACT_PCT_OVERRIDE, SESSION vars,
#     AUTO_LAUNCH, aliases fleet). Inclut les migrations v5.3.
#
#     [EN]
#     NAME
#         deploy-bashrc.sh — patch .bashrc for all agents with fleet env vars
#
#     INTERFACE
#         Ring:    0 (setup)
#         Input:   fleet.yaml (instance configs), $HOMES_ROOT/<role>/.bashrc
#         Output:  patched .bashrc files with fleet-specific env vars and aliases
#
#     EXIT CODES
#         N/A (sourced by deploy.sh)
#
# --- END HEADER ---

INSTANCE_HOMES=()
while IFS= read -r _role; do
    INSTANCE_HOMES+=("$HOMES_ROOT/$_role")
done < <(fleet_roles)

# --- AUTOCOMPACT per role from blueprint ---
AUTOCOMPACT_SENTINEL="CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"
declare -A AUTOCOMPACT_VALUES=()
while IFS= read -r _role; do
    _thresh=$(fleet_role_field "$_role" "context_threshold")
    [[ "$_thresh" == "null" || -z "$_thresh" ]] && _thresh=60
    AUTOCOMPACT_VALUES["$_role"]="$_thresh"
done < <(fleet_roles)
AUTOCOMPACT_DEFAULT="60"
echo ""
echo "=== AUTOCOMPACT → .bashrc (per role) ==="
for IHOME in "${INSTANCE_HOMES[@]}"; do
    BASHRC="$IHOME/.bashrc"
    [[ -f "$BASHRC" ]] || continue
    ROLE=$(basename "$IHOME")
    PCT="${AUTOCOMPACT_VALUES[$ROLE]:-$AUTOCOMPACT_DEFAULT}"
    AUTOCOMPACT_LINE="export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=$PCT"
    if grep -q "$AUTOCOMPACT_SENTINEL" "$BASHRC" 2>/dev/null; then
        CURRENT=$(grep "$AUTOCOMPACT_SENTINEL" "$BASHRC" | grep -Eo '[0-9]+' | tail -1)
        if [[ "$CURRENT" == "$PCT" ]]; then
            echo "  $_ok $(basename "$IHOME")/.bashrc — already $PCT%"
        else
            if [ "$DRY_RUN" -eq 0 ]; then
                sed "s/export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=.*/export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=$PCT/" "$BASHRC" > "${BASHRC}.tmp" && mv -f "${BASHRC}.tmp" "$BASHRC"
                echo "  $_C[mis à jour]$_N $(basename "$IHOME")/.bashrc — $CURRENT% → $PCT%"
                TOTAL_COPIED=$((TOTAL_COPIED + 1))
            else
                echo "  $_dryrun mettrait à jour $(basename "$IHOME")/.bashrc — $CURRENT% → $PCT%"
            fi
        fi
    else
        if [ "$DRY_RUN" -eq 0 ]; then
            printf '\n# Compact anticipé — évite la dérive à haute occupation contexte\n%s\n' "$AUTOCOMPACT_LINE" >> "$BASHRC"
            echo "  $_patched $(basename "$IHOME")/.bashrc — $PCT%"
            TOTAL_COPIED=$((TOTAL_COPIED + 1))
        else
            echo "  $_dryrun patcherait $(basename "$IHOME")/.bashrc — $PCT%"
        fi
    fi
done

# --- FLEET_ENV source → .bashrc (variables + functions fleet disponibles dans chaque Bash tool call) ---
FLEET_ENV_SENTINEL="source.*fleet-env.sh"
FLEET_ENV_LINE='[ -f "$HOME/.local/bin/fleet-env.sh" ] && source "$HOME/.local/bin/fleet-env.sh"'
echo ""
echo "=== FLEET_ENV → .bashrc ==="
for IHOME in "${INSTANCE_HOMES[@]}"; do
    BASHRC="$IHOME/.bashrc"
    [[ -f "$BASHRC" ]] || continue
    if grep -qE "$FLEET_ENV_SENTINEL" "$BASHRC" 2>/dev/null; then
        echo "  $_present $(basename "$IHOME")/.bashrc"
    else
        if [ "$DRY_RUN" -eq 0 ]; then
            printf '\n# Fleet environment (paths, variables, functions)\n%s\n' "$FLEET_ENV_LINE" >> "$BASHRC"
            echo "  $_patched $(basename "$IHOME")/.bashrc"
            TOTAL_COPIED=$((TOTAL_COPIED + 1))
        else
            echo "  $_dryrun patcherait $(basename "$IHOME")/.bashrc"
        fi
    fi
done

# --- FLEET_SESSION → .bashrc ---
FLEET_SESSION_LINE='[[ "${TERM_PROGRAM:-}" != "vscode" ]] && export FLEET_SESSION=1'
FLEET_SESSION_SENTINEL="FLEET_SESSION=1"
echo ""
echo "=== FLEET_SESSION → .bashrc ==="
for IHOME in "${INSTANCE_HOMES[@]}"; do
    BASHRC="$IHOME/.bashrc"
    [[ -f "$BASHRC" ]] || continue
    if grep -q "$FLEET_SESSION_SENTINEL" "$BASHRC" 2>/dev/null; then
        echo "  $_present $(basename "$IHOME")/.bashrc"
    else
        if [ "$DRY_RUN" -eq 0 ]; then
            printf '\n# Fleet session marker — exclut les terminaux VS Code\n%s\n' "$FLEET_SESSION_LINE" >> "$BASHRC"
            echo "  $_patched $(basename "$IHOME")/.bashrc"
            TOTAL_COPIED=$((TOTAL_COPIED + 1))
        else
            echo "  $_dryrun patcherait $(basename "$IHOME")/.bashrc"
        fi
    fi
done

# --- TMPDIR isolation (threat model #10: cross-agent /tmp leak) ---
TMPDIR_SENTINEL="FLEET_TMPDIR"
echo ""
echo "=== FLEET_TMPDIR → .bashrc ==="
for IHOME in "${INSTANCE_HOMES[@]}"; do
    BASHRC="$IHOME/.bashrc"
    [[ -f "$BASHRC" ]] || continue
    _role=$(basename "$IHOME")
    _agent_tmp="/tmp/fleet-$_role"
    if grep -q "$TMPDIR_SENTINEL" "$BASHRC" 2>/dev/null; then
        echo "  $_present $_role/.bashrc"
    else
        if [ "$DRY_RUN" -eq 0 ]; then
            # Create isolated tmpdir
            mkdir -p "$_agent_tmp" 2>/dev/null || true
            chown "$_role:$_role" "$_agent_tmp" 2>/dev/null || true
            chmod 700 "$_agent_tmp" 2>/dev/null || true
            printf '\n# FLEET_TMPDIR — isolated /tmp per agent (cross-agent leak mitigation)\nexport TMPDIR="%s"\n' "$_agent_tmp" >> "$BASHRC"
            echo "  $_patched $_role/.bashrc — TMPDIR=$_agent_tmp"
            TOTAL_COPIED=$((TOTAL_COPIED + 1))
        else
            echo "  $_dryrun patcherait $_role/.bashrc — TMPDIR=$_agent_tmp"
        fi
    fi
done

# --- FLEET_AUTO_LAUNCH + migrations v5.3 ---
FLEET_AUTO_LAUNCH_SENTINEL="FLEET_LAUNCHED"
echo ""
echo "=== FLEET_AUTO_LAUNCH → .bashrc ==="
for IHOME in "${INSTANCE_HOMES[@]}"; do
    BASHRC="$IHOME/.bashrc"
    [[ -f "$BASHRC" ]] || continue
    # Migration v5.3 : fleet-claude rename
    if grep -q '\.local/bin/claude" --dangerously' "$BASHRC" 2>/dev/null; then
        if [ "$DRY_RUN" -eq 0 ]; then
            sed 's|exec "${HOME}/.local/bin/claude" --dangerously-skip-permissions|exec "${HOME}/.local/bin/fleet-claude"|' "$BASHRC" > "${BASHRC}.tmp" && mv -f "${BASHRC}.tmp" "$BASHRC"
            sed '/^    export PATH="\${HOME}\/.local\/bin:\${PATH}"$/d' "$BASHRC" > "${BASHRC}.tmp" && mv -f "${BASHRC}.tmp" "$BASHRC"
            echo "  $_migrated $(basename "$IHOME")/.bashrc — fleet-claude"
        else
            echo "  $_dryrun migrerait $(basename "$IHOME")/.bashrc — fleet-claude"
        fi
    fi
    # Migration variante provision-users.sh
    if grep -q 'command -v claude .* && exec claude' "$BASHRC" 2>/dev/null; then
        if [ "$DRY_RUN" -eq 0 ]; then
            sed 's|command -v claude .*/dev/null && exec claude|exec "${HOME}/.local/bin/fleet-claude"|' "$BASHRC" > "${BASHRC}.tmp" && mv -f "${BASHRC}.tmp" "$BASHRC"
            sed '/^    export PATH="\${HOME}\/.local\/bin:\${PATH}"$/d' "$BASHRC" > "${BASHRC}.tmp" && mv -f "${BASHRC}.tmp" "$BASHRC"
            echo "  $_migrated $(basename "$IHOME")/.bashrc — fleet-claude (variante provision)"
        fi
    fi
    if grep -q "$FLEET_AUTO_LAUNCH_SENTINEL" "$BASHRC" 2>/dev/null; then
        echo "  $_present $(basename "$IHOME")/.bashrc"
    else
        if [ "$DRY_RUN" -eq 0 ]; then
            printf '\n# Fleet auto-launch — triggered by FLEET_SESSION\nif [[ "${FLEET_SESSION:-}" == "1" ]] && [[ -z "${FLEET_LAUNCHED:-}" ]]; then\n    export FLEET_LAUNCHED=1\n    exec "${HOME}/.local/bin/fleet-claude"\nfi\n' >> "$BASHRC"
            echo "  $_patched $(basename "$IHOME")/.bashrc"
            TOTAL_COPIED=$((TOTAL_COPIED + 1))
        else
            echo "  $_dryrun patcherait $(basename "$IHOME")/.bashrc"
        fi
    fi
done

# --- Alias claude=fleet-claude ---
ALIAS_SENTINEL="FLEET_CLAUDE_ALIAS"
for IHOME in "${INSTANCE_HOMES[@]}"; do
    BASHRC="$IHOME/.bashrc"
    [[ -f "$BASHRC" ]] || continue
    if ! grep -q "$ALIAS_SENTINEL" "$BASHRC" 2>/dev/null; then
        if [ "$DRY_RUN" -eq 0 ]; then
            printf '\n# FLEET_CLAUDE_ALIAS\nalias claude="fleet-claude"\n' >> "$BASHRC"
            echo "  $_patched $(basename "$IHOME")/.bashrc — alias claude=fleet-claude"
        else
            echo "  $_dryrun patcherait $(basename "$IHOME")/.bashrc — alias"
        fi
    fi
done

# --- ftmux alias (starfleet only) ---
FTMUX_SENTINEL="FLEET_FTMUX_ALIAS"
SF_BASHRC="/home/starfleet/.bashrc"
if [[ -f "$SF_BASHRC" ]] && ! grep -q "$FTMUX_SENTINEL" "$SF_BASHRC" 2>/dev/null; then
    if [ "$DRY_RUN" -eq 0 ]; then
        printf '\n# FLEET_FTMUX_ALIAS\nalias ftmux="sudo tmux"\n' >> "$SF_BASHRC"
        echo "  $_patched starfleet/.bashrc — alias ftmux"
    else
        echo "  $_dryrun patcherait starfleet/.bashrc — alias ftmux"
    fi
fi

# --- Migration v5.3 : remove old claude routing from fleet_user ---
LORDZURP_BASHRC="$FLEET_USER_HOME/.bashrc"
if [[ -f "$LORDZURP_BASHRC" ]] && grep -q "fleet-claude-routing" "$LORDZURP_BASHRC" 2>/dev/null; then
    if [ "$DRY_RUN" -eq 0 ]; then
        sed '/^# fleet-claude-routing/,+3d' "$LORDZURP_BASHRC" > "${LORDZURP_BASHRC}.tmp" && mv -f "${LORDZURP_BASHRC}.tmp" "$LORDZURP_BASHRC"
        echo "  $_migrated $(basename "$FLEET_USER_HOME")/.bashrc — supprimé claude routing"
    else
        echo "  $_dryrun supprimerait claude routing de $(basename "$FLEET_USER_HOME")/.bashrc"
    fi
fi
