#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: deploy-claude.sh
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
#     | MODULE: DEPLOY-CLAUDE   | SUBSYSTEM: PROVISIONING / DEPLOY|
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Deploy .claude/, credentials, CLAUDE.md, sp-sources, SP.    |
#     |  Sourced by deploy.sh. Injects conversation language from blueprint.|
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     Déploie .claude/ (skills, hooks, agents, commands), credentials, CLAUDE.md,
#     sp-sources, role.md, settings.json. Injecte la langue de conversation depuis le blueprint.
#
#     [EN]
#     NAME
#         deploy-claude.sh — deploy .claude/ content, credentials, CLAUDE.md, role configs
#
#     INTERFACE
#         Ring:    0 (setup)
#         Input:   SOURCE_DIR (.claude/), LCARS_ROOT (CLAUDE.md, sp-sources/, roles/)
#         Output:  synced .claude/ subdirs, CLAUDE.md, role.md, settings per agent
#
#     EXIT CODES
#         N/A (sourced by deploy.sh)
#
# --- END HEADER ---

for TARGET in "${TARGETS[@]}"; do
    echo ""
    echo "=== $TARGET ==="
    for DIR in "${DIRS_TO_SYNC[@]}"; do
        [ "$DIR" = "skills" ] && continue   # handled separately below
        SRC="$SOURCE_DIR/$DIR"
        [ -d "$SRC" ] || continue
        if [[ "$DIR" == "hooks" ]]; then
            sync_tree "$SRC" "$TARGET/$DIR" "exec"
        else
            sync_tree "$SRC" "$TARGET/$DIR"
        fi
    done
done

# --- Skills per-agent (filtered by fleet.yaml skills: list) ---
echo ""
echo "=== skills/ → per-agent (filtered) ==="
SKILLS_SRC="$SOURCE_DIR/skills"
[ -d "$SKILLS_SRC" ] || { echo "  $_SKIP no skills/ source"; }
if [ -d "$SKILLS_SRC" ]; then
for TARGET in "${TARGETS[@]}"; do
    _role=$(resolve_role "$TARGET")
    # Read skills list for this role (space-separated)
    _skills_raw=$(yq ".instances[] | select(.role == \"$_role\") | .skills // [] | join(\" \")" "$FLEET_YAML" 2>/dev/null)
    if [ -z "$_skills_raw" ] || [ "$_skills_raw" = "null" ] || [ "$_skills_raw" = " " ]; then
        _skills_raw=""
    fi
    # Copy listed skills
    for _skill in $_skills_raw; do
        _skill_src="$SKILLS_SRC/$_skill"
        [ -d "$_skill_src" ] || { echo "  $_SKIP $_role/$_skill — source not found"; continue; }
        sync_tree "$_skill_src" "$TARGET/skills/$_skill"
        echo "  $_ok $_role — skill: $_skill"
    done
    # Remove unlisted skills (cleanup)
    _skills_dst="$TARGET/skills"
    if [ "$DRY_RUN" -eq 0 ] && [ -d "$_skills_dst" ]; then
        for _existing in "$_skills_dst"/*/; do
            [ -d "$_existing" ] || continue
            _existing_name=$(basename "$_existing")
            if ! echo " $_skills_raw " | grep -q " $_existing_name "; then
                rm -rf "$_existing"
                echo "  [removed] $_role — skill: $_existing_name"
            fi
        done
    fi
done
fi

# --- Memory files ---
MEMORY_SRC="$SCRIPT_DIR/.claude/memory"
if [ -d "$MEMORY_SRC" ]; then
    echo ""
    echo "=== memory/ → .claude/memory/ ==="
    for TARGET in "${TARGETS[@]}"; do
        sync_tree "$MEMORY_SRC" "$TARGET/memory"
    done
fi

# --- Credentials (Anthropic OAuth + GitHub auth) ---
CREDS_SRC="/home/private/.credentials.json"
GH_HOSTS_SRC="/home/private/gh-hosts.yml"
echo ""
echo "=== credentials ==="
for TARGET in "${TARGETS[@]}"; do
    _role="$(resolve_role "$TARGET")"
    # Anthropic OAuth → every agent (shared token, single login)
    # Credentials: seed once, never overwrite (agents auto-refresh tokens)
    if [ -f "$CREDS_SRC" ]; then
        DST="$TARGET/.credentials.json"
        if [ "$DRY_RUN" -eq 0 ]; then
            if [ -f "$DST" ]; then
                echo "  $_ok $_role — .credentials.json (preserved)"
            else
                cp "$CREDS_SRC" "$DST"
                chmod 600 "$DST"
                chown "$_role:$_role" "$DST" 2>/dev/null || true
                echo "  $_ok $_role — .credentials.json (seeded)"
                TOTAL_COPIED=$((TOTAL_COPIED + 1))
            fi
        fi
    fi
    # GitHub auth → agents that push (sudo:full or scope:code)
    if [ -f "$GH_HOSTS_SRC" ]; then
        _sudo="$(fleet_role_field "$_role" "sudo")"
        _scope="$(fleet_role_field "$_role" "scope")"
        if [[ "$_sudo" == "full" || "$_scope" == "code" ]]; then
            _gh_dir="$(readlink -f "$(dirname "$TARGET")")/.config/gh"
            if [ "$DRY_RUN" -eq 0 ]; then
                mkdir -p "$_gh_dir"
                cp "$GH_HOSTS_SRC" "$_gh_dir/hosts.yml"
                chmod 600 "$_gh_dir/hosts.yml"
                chown -R "$_role:$_role" "$_gh_dir" 2>/dev/null || true
                # Set credential.helper so git push uses gh auth
                sudo -u "$_role" git config --global credential.helper '/usr/bin/gh auth git-credential' 2>/dev/null || true
                echo "  $_ok $_role — gh-hosts.yml + credential.helper"
                TOTAL_COPIED=$((TOTAL_COPIED + 1))
            fi
        fi
    fi
done
# GitHub auth → fleet_user
if [ -f "$GH_HOSTS_SRC" ]; then
    _fu_gh="$FLEET_USER_HOME/.config/gh"
    mkdir -p "$_fu_gh"
    if ! cmp -s "$GH_HOSTS_SRC" "$_fu_gh/hosts.yml" 2>/dev/null; then
        cp "$GH_HOSTS_SRC" "$_fu_gh/hosts.yml"
        chmod 600 "$_fu_gh/hosts.yml"
        chown -R "$FLEET_USER:$FLEET_USER" "$_fu_gh" 2>/dev/null || true
        echo "  $_ok $FLEET_USER — gh-hosts.yml"
        TOTAL_COPIED=$((TOTAL_COPIED + 1))
    fi
fi

# --- CLAUDE.md → all instances ---
CLAUDE_SOURCE="$SOURCE_DIR/CLAUDE.md"
CLAUDE_HEADLESS=$(mktemp)
trap 'rm -f "$CLAUDE_HEADLESS"' EXIT
grep -v "@../sp-sources/user/profile.md" "$CLAUDE_SOURCE" > "$CLAUDE_HEADLESS"

# Conversation language from blueprint (injected at top of deployed CLAUDE.md)
_FLEET_LANG=$(_yq '.fleet.lang')
_FLEET_LANG="${_FLEET_LANG:-fr}"
case "$_FLEET_LANG" in
    fr) _LANG_LINE="Langue de conversation avec l'utilisateur : français." ;;
    en) _LANG_LINE="Conversation language with the user: English." ;;
    *)  _LANG_LINE="Conversation language with the user: $_FLEET_LANG." ;;
esac
echo ""
echo "=== CLAUDE.md → all instances ==="
if [ ! -f "$CLAUDE_SOURCE" ]; then
    echo "⚠ CLAUDE.md SOURCE NOT FOUND: $CLAUDE_SOURCE"
else
    for TARGET in "${TARGETS[@]}"; do
        _role=$(resolve_role "$TARGET")
        _stateless=$(fleet_role_field "$_role" "stateless" 2>/dev/null || echo "false")
        if [[ "$_stateless" == "true" ]]; then
            _src="$CLAUDE_HEADLESS"; _label="headless"
        else
            _src="$CLAUDE_SOURCE"; _label="full"
        fi
        if [ "$DRY_RUN" -eq 0 ]; then
            if ! cmp -s "$_src" "$TARGET/CLAUDE.md" 2>/dev/null; then
                fleet_cp "$_src" "$TARGET/CLAUDE.md"
                # Inject conversation language at top (after first comment block)
                sed "3i\\$_LANG_LINE" "$TARGET/CLAUDE.md" > "${TARGET}/CLAUDE.md.tmp" && mv -f "${TARGET}/CLAUDE.md.tmp" "$TARGET/CLAUDE.md"
                deployed
            else
                echo "  $_ok $_role — already up to date ($_label)"
            fi
        else
            echo "  $_dryrun copierait CLAUDE.md ($_label) → $TARGET"
        fi
    done
fi
rm -f "$CLAUDE_HEADLESS"

# --- SP sources symlink (replaces old ~/directives) ---
SP_SOURCES_SRC="$LCARS_ROOT/fleet/system-prompt/sources"
echo ""
echo "=== ~/sp-sources symlink → all instances ==="
while IFS= read -r _role; do
    _home="$HOMES_ROOT/$_role"
    [ -d "$_home" ] || continue
    if [ "$DRY_RUN" -eq 0 ]; then
        # Remove legacy directives symlink if present
        [ -L "$_home/directives" ] && rm -f "$_home/directives"
        ln -sfn "$SP_SOURCES_SRC" "$_home/sp-sources"
        echo "  $_symlink $_home/sp-sources → $SP_SOURCES_SRC"
    else
        echo "  $_dryrun $_home/sp-sources → $SP_SOURCES_SRC"
    fi
done < <(fleet_roles)

# role.md per-instance — removed in v6.0 (role injected via SP-custom by build-sp.sh)

# --- System prompt per-instance ---
echo ""
echo "=== system-prompt.md → all instances (build-sp.sh) ==="
_SP_BUILD="$LCARS_ROOT/fleet/system-prompt/build-sp.sh"
if [ -f "$_SP_BUILD" ]; then
    if [ "$DRY_RUN" -eq 0 ]; then
        bash "$_SP_BUILD"
        # Fix ownership: build-sp runs as root, agents need to read their own SP
        while IFS= read -r _sp_role; do
            _sp_home="$HOMES_ROOT/$_sp_role"
            [ -f "$_sp_home/.claude/system-prompt.md" ] && chown "$FLEET_USER:fleet" "$_sp_home/.claude/system-prompt.md" 2>/dev/null
        done < <(fleet_roles)
    else
        echo "  $_dryrun build-sp.sh (would generate ~/.claude/system-prompt.md per instance)"
    fi
else
    echo "  $_SKIP build-sp.sh not found at $_SP_BUILD"
fi

# --- settings.json per-instance (trust bypass + model from blueprint) ---
echo ""
echo "=== settings.json → all instances ==="
while IFS= read -r _role; do
    _claude_dir="$HOMES_ROOT/$_role/.claude"
    [ -d "$_claude_dir" ] || continue
    _settings="$_claude_dir/settings.json"
    # Read model from blueprint — pass through to Claude Code "model" field
    _bp_model=$(yq ".instances[] | select(.role == \"$_role\") | .model // \"\"" "$FLEET_YAML" 2>/dev/null)
    # Blueprint values (opus[1m], claude-sonnet-4-6) are valid Claude Code aliases
    _cc_model="${_bp_model:-sonnet}"
    _settings_json=$(cat <<EOJSON
{"hasCompletedOnboarding":true,"hasAcknowledgedCostThreshold":true,"skipDangerousModePermissionPrompt":true,"model":"$_cc_model"}
EOJSON
    )
    # Settings: always enforce from repo (convergent, model from blueprint)
    if [ "$DRY_RUN" -eq 0 ]; then
        echo "$_settings_json" > "$_settings"
        echo "  $_ok $_role — settings.json (model: $_cc_model)"
        TOTAL_COPIED=$((TOTAL_COPIED + 1))
    else
        echo "  $_dryrun $_role — would enforce settings.json (model: $_cc_model)"
    fi
done < <(fleet_roles)

# Config lockdown moved to deploy.sh (runs AFTER all sub-scripts including deploy-hooks.sh)
