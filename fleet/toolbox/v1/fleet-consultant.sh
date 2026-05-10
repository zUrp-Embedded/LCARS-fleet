#!/usr/bin/env bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-consultant.sh
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
#     | MODULE: FLEET-CONSULTANT  | SUBSYSTEM: FLEET / CLI        |
#     | LICENSE: AGPL-3           | STARDATE: 2026.091            |
#     +---------------------------+-------------------------------+
#     |                                                           |
#     |  Launch consultant agent under its own Linux user.        |
#     |  Stateless: home purged each launch, SP+skills rebuilt.   |
#     |  Standalone (tmux session) or headless (claude -p).       |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     fleet-consultant.sh — lance le consultant sous son user Linux dédié.
#     Stateless : home purgé à chaque lancement, SP+skills reconstruits.
#     Mode standalone (tmux) ou headless (claude -p).
#
#     [EN]
#     NAME
#         fleet-consultant.sh — launch consultant agent (stateless, own user)
#
#     SYNOPSIS
#         fleet-consultant [--profile BLOCKS] [--headless] [--model MODEL] [prompt]
#
#     DESCRIPTION
#         Purges the consultant home (preserving credentials), rebuilds SP
#         and skills, refreshes OAuth credentials, then launches claude
#         as the consultant Linux user. Standalone creates/attaches a tmux
#         session on the fleet socket.
#
#     INTERFACE
#         Ring:    4 (support)
#         Input:   fleet.yaml (tmux socket), build-sp.sh, skills/
#         Output:  tmux session "consultant" or headless stdout
#         JSON:    non
#
#     EXIT CODES
#         0    Session completed
#         1    Missing prompt in headless mode, or fleet not deployed
#
#     SEE ALSO
#         fleet-arch.sh, fleet-dispatch.sh, build-sp.sh
#
# --- END HEADER ---

set -euo pipefail

[ -f /home/fleet-state/.deploy_ok ] || { echo "Fleet pas déployée. Ouvre un terminal pour lancer le bootstrap."; exit 1; }

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
readonly SCRIPT_DIR
SP_DIR="$(readlink -f "$SCRIPT_DIR/../system-prompt")"
readonly SP_DIR
readonly BUILD="$SP_DIR/build-sp.sh"
readonly CONSULTANT_HOME="/home/consultant"
readonly SP_FILE="$CONSULTANT_HOME/.claude/system-prompt.md"

usage() {
    cat <<USAGE
Usage: fleet-consultant [OPTIONS] [prompt]

Launch a stateless consultant agent under its own Linux user.
Zero memory, zero handoff, clean context every launch.
Full fleet IPC (spool inbox, wake).

Options:
  --profile "BLOCKS"  SP blocks space-separated (default: full fleet profile)
  --headless         Run in headless mode (claude -p), requires prompt
  --model MODEL      Model override (default: system default)
  -h, --help         Show this help

Examples:
  fleet-consultant                                    # interactive, standalone tmux
  fleet-consultant --headless "Review this file..."   # headless one-shot
  fleet-consultant --model sonnet                     # force sonnet
USAGE
    exit 0
}

# --- Parse args ---
HEADLESS=false
MODEL=""
PROMPT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --headless) HEADLESS=true; shift ;;
        --model)    MODEL="$2"; shift 2 ;;
        -h|--help)  usage ;;
        *)          PROMPT="$1"; shift ;;
    esac
done

# Read SP blocks from blueprint (fleet.yaml)
FLEET_YAML="$LCARS_ROOT/fleet/fleet.yaml"
PROFILE="$(yq '.instances[] | select(.role == "consultant") | .system_prompt | join(" ")' "$FLEET_YAML" 2>/dev/null)"
[[ -z "$PROFILE" ]] && { echo "ERROR: consultant system_prompt not found in fleet.yaml" >&2; exit 1; }

# --- Purge home (stateless) — preserve runtime state ---
_creds="$CONSULTANT_HOME/.claude/.credentials.json"
_creds_bak="/home/commons/consultant-creds-backup"
_claudejson="$CONSULTANT_HOME/.claude.json"
_claudejson_bak="/home/commons/consultant-claudejson-backup"
# Backup credentials + .claude.json (Claude Code runtime state: auth, onboarding, trust)
[ -f "$_creds" ] && sudo -u consultant cp "$_creds" "$_creds_bak"
[ -f "$_claudejson" ] && sudo -u consultant cp "$_claudejson" "$_claudejson_bak"

# Home must be 770 (consultant:fleet) so lordzurp (fleet group) can write config
sudo -u consultant chmod 770 "$CONSULTANT_HOME"
# Purge: mix of lordzurp-owned (config) and consultant-owned (runtime) files
# sudo -u consultant handles consultant files, lordzurp handles the rest
sudo -u consultant find "$CONSULTANT_HOME" -mindepth 1 -maxdepth 1 \
    -not -name '.bashrc' -not -name '.profile' -not -name '.hushlogin' \
    -exec rm -rf {} + 2>/dev/null || true
find "$CONSULTANT_HOME" -mindepth 1 -maxdepth 1 \
    -not -name '.bashrc' -not -name '.profile' -not -name '.hushlogin' \
    -user lordzurp -exec rm -rf {} + 2>/dev/null || true
# Recreate .claude/ — lordzurp-owned, sticky bit prevents agent from deleting config files
mkdir -p "$CONSULTANT_HOME/.claude"
chown lordzurp:fleet "$CONSULTANT_HOME/.claude"
chmod 1770 "$CONSULTANT_HOME/.claude"

# Restore credentials + .claude.json
[ -f "$_creds_bak" ] && sudo -u consultant cp "$_creds_bak" "$_creds" && sudo -u consultant chmod 640 "$_creds"
[ -f "$_claudejson_bak" ] && sudo -u consultant cp "$_claudejson_bak" "$_claudejson"

# --- Refresh OAuth credentials from starfleet (fallback only) ---
# Only if consultant has no credentials (first launch or backup failed).
# If consultant already has creds (from backup above), don't overwrite —
# starfleet's token may be older/expired.
if [ ! -f "$_creds" ]; then
    _sf_creds="/home/starfleet/.claude/.credentials.json"
    if [ -f "$_sf_creds" ]; then
        _tmp_creds="/home/commons/consultant-creds-seed"
        cp "$_sf_creds" "$_tmp_creds"
        chmod 644 "$_tmp_creds"
        sudo -u consultant cp "$_tmp_creds" "$_creds"
        sudo -u consultant chmod 640 "$_creds"
        rm -f "$_tmp_creds"
    fi
fi

# --- Settings: skip onboarding + trust + bypass prompts ---
# Settings — consultant-owned (Claude Code writes at runtime)
sudo -u consultant bash -c 'cat > /home/consultant/.claude/settings.json << EOF
{"hasCompletedOnboarding":true,"hasAcknowledgedCostThreshold":true,"skipDangerousModePermissionPrompt":true,"model":"opus[1m]"}
EOF'
# .claude.json — only create if not restored from backup
if [ ! -f "$_claudejson" ]; then
    sudo -u consultant bash -c 'cat > /home/consultant/.claude.json << EOF
{"projects":{"/home/consultant":{"allowedTools":[],"hasTrustDialogAccepted":true,"hasCompletedProjectOnboarding":true}}}
EOF'
fi

# --- Build SP (lordzurp writes, home is 770 fleet-writable) ---
bash "$BUILD" consultant "$PROFILE" "$CONSULTANT_HOME"

# --- Deploy skills from fleet deploy (consultant's skills from fleet.yaml) ---
_skills_src="$LCARS_ROOT/fleet/system-prompt/sources"
_skills_dst="$CONSULTANT_HOME/.claude/skills"
mkdir -p "$_skills_dst"
# Copy skills from repo (home purged above, deploy.sh won't run again)
_skills_repo="$LCARS_ROOT/.claude/skills"
if [ -d "$_skills_repo" ]; then
    for _skill_dir in sonde ponce reverse audit; do
        if [ -d "$_skills_repo/$_skill_dir" ]; then
            cp -r "$_skills_repo/$_skill_dir" "$_skills_dst/" 2>/dev/null || true
        fi
    done
fi

# --- Remove skills/commands irrelevant for stateless consultant ---
rm -rf "$CONSULTANT_HOME/.claude/skills/handoff" \
    "$CONSULTANT_HOME/.claude/commands/handoff.md" 2>/dev/null || true

# --- Deploy CLAUDE.md ---
_claude_md_src="$LCARS_ROOT/fleet/system-prompt/sources/user"
if [ -d "$_claude_md_src" ]; then
    # Consultant gets protocole-user for keyword customization
    mkdir -p "$CONSULTANT_HOME/sp-sources/user"
    cp "$_claude_md_src/protocole-user.md" "$CONSULTANT_HOME/sp-sources/user/" 2>/dev/null || true
    # CLAUDE.md with @import
    cat > /tmp/consultant-claude-md.$$ << 'CLAUDEMD'
Langue de conversation avec l'utilisateur : français.
@../sp-sources/user/protocole-user.md
CLAUDEMD
    cp /tmp/consultant-claude-md.$$ "$CONSULTANT_HOME/.claude/CLAUDE.md"
    chmod 644 "$CONSULTANT_HOME/.claude/CLAUDE.md"
    rm -f /tmp/consultant-claude-md.$$
fi

# --- Deploy hooks (same as all fleet agents) ---
_hooks_src="$LCARS_ROOT/.claude/hooks"
if [ -d "$_hooks_src" ]; then
    cp -r "$_hooks_src" "$CONSULTANT_HOME/.claude/"
fi

# --- Deploy settings.local.json (hooks wiring — same for all agents) ---
_slj_ref="/home/starfleet/.claude/settings.local.json"
if [ -f "$_slj_ref" ]; then
    cp "$_slj_ref" "$CONSULTANT_HOME/.claude/settings.local.json"
fi

# --- Patch .bashrc if missing fleet injections ---
_bashrc="$CONSULTANT_HOME/.bashrc"
if ! grep -q "fleet-env.sh" "$_bashrc" 2>/dev/null; then
    cp "/home/starfleet/.bashrc" "$_bashrc"
    chown consultant:fleet "$_bashrc"
fi

# --- Ensure TMPDIR isolation ---
_agent_tmp="/tmp/fleet-consultant"
sudo -u consultant mkdir -p "$_agent_tmp" 2>/dev/null || true
sudo -u consultant chmod 700 "$_agent_tmp" 2>/dev/null || true

# --- Launch ---
CLAUDE_CMD="export FLEET_CONTEXT=standalone CLAUDE_AGENT_NAME=consultant FLEET_LAUNCHED=1; exec claude --dangerously-skip-permissions --system-prompt-file ~/.claude/system-prompt.md"

if [ -n "$MODEL" ]; then
    CLAUDE_CMD="export FLEET_CONTEXT=standalone CLAUDE_AGENT_NAME=consultant FLEET_LAUNCHED=1; exec claude --dangerously-skip-permissions --system-prompt-file ~/.claude/system-prompt.md --model $MODEL"
fi

if $HEADLESS; then
    if [ -z "$PROMPT" ]; then
        echo "ERROR: --headless requires a prompt" >&2
        exit 1
    fi
    sudo -u consultant bash -c "cd ~ && $CLAUDE_CMD" -p "$PROMPT"
else
    # Standalone tmux session (same pattern as fleet-arch.sh)
    if tmux has-session -t consultant 2>/dev/null; then
        exec tmux attach -t consultant
    fi

    tmux new-session -d -s consultant \
        "sudo -i -u consultant bash -c '$CLAUDE_CMD'"
    tmux select-pane -T "consultant" -t consultant
    tmux rename-window -t consultant "consultant"
    tmux set-option -t consultant automatic-rename off
    exec tmux attach -t consultant
fi
