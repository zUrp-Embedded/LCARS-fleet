#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: provision-users.sh
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
#     | MODULE: PROVISION-USERS | SUBSYSTEM: FLEET / INSTALL      |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Per-user provisioning. Blueprint-driven.                 |
#     |  Loops over fleet.yaml instances, sets up each home.      |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     Provisionne les homes agents. Boucle sur fleet.yaml, crée les utilisateurs,
#     configure .claude/, .bashrc, permissions 750, groupe fleet.
#
#     [EN]
#     NAME
#         provision-users.sh — per-user fleet provisioning from blueprint
#
#     INTERFACE
#         Ring:    0 (setup)
#         Input:   fleet.yaml (instances), fleet_user arg
#         Output:  created users, configured homes, .claude/ dirs
#
#     EXIT CODES
#         0    All users provisioned
#         1    Not root, or missing fleet_user
#
# --- END HEADER ---

set -euo pipefail

[ "$EUID" -ne 0 ] && { echo "[FAIL] must run as root"; exit 1; }

FLEET_USER="${1:?usage: provision-users.sh <fleet_user>}"

# ─── Fleet env ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
FLEET_ENV="$SCRIPT_DIR/../fleet-env.sh"
[ -f "$FLEET_ENV" ] && source "$FLEET_ENV"

FLEET_YAML="${FLEET_YAML:-$SCRIPT_DIR/../fleet.yaml}"

# Blueprint functions from fleet-env.sh: fleet_roles, fleet_role_field, _yq

LCARS_DIR="${LCARS_ROOT:-/local/LCARS}"
FLEET_GROUP="$(_yq '.fleet.group')"
[[ "$FLEET_GROUP" == "null" || -z "$FLEET_GROUP" ]] && FLEET_GROUP="fleet"

_G=$'\033[1;32m'; _Y=$'\033[1;33m'; _R=$'\033[1;31m'; _N=$'\033[0m'
info() { echo "  ${_G}[$1]${_N} $2"; }

# Shared PS1 definition (used by provision_user + fleet_user setup)
LCARS_PS1='\n\[\033[35m\]\u\[\033[30m\]@\[\033[32m\]\h\[\033[30m\]:\[\033[31m\]\w\[\033[0m\]\n[\t] ==> '

# ─── Provision one user ──────────────────────────────────────────────────────
provision_user() {
    local role="$1"
    local model="$(fleet_role_field "$role" "model")"
    local threshold="$(fleet_role_field "$role" "context_threshold")"
    local scope="$(fleet_role_field "$role" "scope")"
    local _linux_user="$(fleet_role_field "$role" "linux_user")"
    [[ "$_linux_user" == "null" || -z "$_linux_user" ]] && _linux_user="$role"
    local user="$_linux_user"
    local home

    home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6)"
    [ -z "$home" ] && { info "$role" "SKIP — user $user does not exist"; return; }
    [ -d "$home" ] || { info "$role" "SKIP — home $home does not exist"; return; }

    # Home traversable by fleet group (B1 — allows deploy/check without sudo)
    chgrp "$FLEET_GROUP" "$home" 2>/dev/null || true
    chmod g+rx "$home" 2>/dev/null || true

    echo ""
    echo "=== $role ($user) ==="

    # ── .claude/ directory structure ──────────────────────────────────────
    for dir in .claude .claude/skills .claude/commands .claude/memory .claude/hooks; do
        mkdir -p "$home/$dir"
    done
    mkdir -p "$home/.local/bin"
    touch "$home/.hushlogin"

    # ── ~/.claude.json — skip Claude Code first-run wizard ──────────────
    # All agents skip the wizard. The only wizard runs on lordzurp (vanilla).
    if [ ! -f "$home/.claude.json" ]; then
        cat > "$home/.claude.json" << CJEOF
{
  "hasCompletedOnboarding": true,
  "lastOnboardingVersion": "2.1.76",
  "numStartups": 1,
  "autoUpdates": false,
  "projects": {
    "$home": {
      "allowedTools": [],
      "hasTrustDialogAccepted": true
    }
  }
}
CJEOF
        chown "$user:$user" "$home/.claude.json"
        info "$role" ".claude.json created (wizard bypass)"
    fi

    # ── fleet-claude wrapper (~/.local/bin/fleet-claude) ─────────────────
    # Nommé fleet-claude pour survivre à l'auto-update Claude Code
    # qui écrase tout fichier nommé "claude" dans ~/.local/bin/
    cat > "$home/.local/bin/fleet-claude" << CWEOF
#!/bin/bash
export CLAUDE_AGENT_NAME="$role"
exec /usr/local/bin/claude --dangerously-skip-permissions "\$@"
CWEOF
    chmod 755 "$home/.local/bin/fleet-claude"
    # Nettoyage : supprimer l'ancien wrapper ou binaire auto-installé
    rm -f "$home/.local/bin/claude" 2>/dev/null || true

    # ── instance-name ─────────────────────────────────────────────────────
    if [ ! -f "$home/.claude/instance-name" ]; then
        echo "$role" > "$home/.claude/instance-name"
        info "$role" "instance-name: $role"
    fi

    # ── CLAUDE.md — copied by deploy.sh, NOT symlinked ────────────────────
    # Symlink breaks @role.md resolution (resolves relative to target, not link)
    # deploy.sh handles the copy with fleet_cp — no action needed here

    # ── .lcars symlink → LCARS repo ──────────────────────────────────────
    if [ "$(readlink -f "$home/.lcars" 2>/dev/null)" != "$(readlink -f "$LCARS_DIR")" ]; then
        ln -sfn "$LCARS_DIR" "$home/.lcars"
        chown -h "$user:$user" "$home/.lcars"
    fi

    # ── .bashrc injections ────────────────────────────────────────────────
    local bashrc="$home/.bashrc"
    touch "$bashrc"

    # PATH
    if ! grep -q 'FLEET_LOCAL_BIN' "$bashrc"; then
        printf '\n# FLEET_LOCAL_BIN\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$bashrc"
    fi

    # Alias claude → fleet-claude (défense contre binaire fantôme auto-update)
    if ! grep -q 'FLEET_CLAUDE_ALIAS' "$bashrc"; then
        printf '\n# FLEET_CLAUDE_ALIAS\nalias claude="fleet-claude"\n' >> "$bashrc"
    fi

    # PS1
    if ! grep -q 'LCARS_PS1' "$bashrc"; then
        printf '\n# LCARS_PS1\nPS1=%s\n' "'$LCARS_PS1'" >> "$bashrc"
    fi

    # FLEET_SESSION
    if ! grep -q 'FLEET_SESSION=1' "$bashrc"; then
        printf '\n# Fleet session marker\n[[ "${TERM_PROGRAM:-}" != "vscode" ]] && export FLEET_SESSION=1\n' >> "$bashrc"
    fi

    # AUTOCOMPACT — from blueprint threshold
    : "${threshold:=60}"
    if ! grep -q 'AUTOCOMPACT_PCT' "$bashrc"; then
        echo "export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=$threshold" >> "$bashrc"
    fi

    # FLEET_AUTO_LAUNCH — all agents auto-launch fleet-claude on ssh
    if ! grep -q 'FLEET_LAUNCHED' "$bashrc"; then
        cat >> "$bashrc" << 'LAUNCH_EOF'

# Fleet auto-launch
if [[ "${FLEET_SESSION:-}" == "1" ]] && [[ -z "${FLEET_LAUNCHED:-}" ]]; then
    export FLEET_LAUNCHED=1
    exec "${HOME}/.local/bin/fleet-claude"
fi
LAUNCH_EOF
    fi

    # ── settings.local.json ───────────────────────────────────────────────
    local settings="$home/.claude/settings.local.json"
    if [ ! -f "$settings" ]; then
        cat > "$settings" << SETTINGS_EOF
{
  "permissions": {
    "allow": [],
    "deny": []
  },
  "model": "${model:-claude-sonnet-4-6}",
  "hooks": {}

}
SETTINGS_EOF
        info "$role" "settings.local.json created (model: ${model:-claude-sonnet-4-6})"
    fi

    # ── settings.json — trust dirs ────────────────────────────────────────
    local global_settings="$home/.claude/settings.json"
    if [ ! -f "$global_settings" ]; then
        cat > "$global_settings" << GSETTINGS_EOF
{
  "projects": {
    "$home": {
      "hasTrustDialogAccepted": true
    },
    "~": {
      "hasTrustDialogAccepted": true
    },
    "/home/projects.work": {
      "hasTrustDialogAccepted": true
    },
    "/home/fleet-state": {
      "hasTrustDialogAccepted": true
    },
    "/home/projects": {
      "hasTrustDialogAccepted": true
    },
    "/local/LCARS": {
      "hasTrustDialogAccepted": true
    }
  },
  "skipDangerousModePermissionPrompt": true,
  "hasCompletedOnboarding": true,
  "hasAcknowledgedCostThreshold": true
}
GSETTINGS_EOF
        info "$role" "settings.json created (bypassPermissions)"
    fi

    # ── Git identity ──────────────────────────────────────────────────────
    # All agents: name = LCARS-<role>, email = user's real email (from onboarding)
    # This ensures commits are attributed to the user's GitHub account
    local git_name git_email
    git_name="LCARS-$role"
    git_email=""
    if [ -f /home/private/git-identity.conf ]; then
        git_email="$(grep -E '^(GIT_USER_EMAIL|email)=' /home/private/git-identity.conf 2>/dev/null | head -1 | cut -d= -f2 || true)"
    fi
    : "${git_email:=${role}@lcars-fleet.local}"
    if [ -n "${git_name:-}" ]; then
        sudo -u "$user" git config --global user.name "$git_name" 2>/dev/null || true
        sudo -u "$user" git config --global user.email "$git_email" 2>/dev/null || true
    fi

    # ── Ownership ─────────────────────────────────────────────────────────
    # JUPITER-003: .claude/ is owner-write, group-read only. deploy.sh runs as root,
    # so group-write is not needed. This prevents cross-agent prompt/hook tampering.
    chown -R "$user:$FLEET_GROUP" "$home/.claude" "$home/.local" 2>/dev/null || true
    chmod -R u=rwX,g=rX,o= "$home/.claude" 2>/dev/null || true

    info "$role" "done"
}

# ─── Main loop ────────────────────────────────────────────────────────────────
echo "=== Provisioning users from blueprint ==="

while IFS= read -r role; do
    provision_user "$role"
done < <(fleet_roles)

# ─── Fleet user (hub) — minimal setup ──────────────────────────────────
echo ""
echo "=== Fleet user ($FLEET_USER) — minimal ==="

FLEET_HOME="$(getent passwd "$FLEET_USER" 2>/dev/null | cut -d: -f6)"
if [ -n "$FLEET_HOME" ] && [ -d "$FLEET_HOME" ]; then
    # .lcars symlink
    if [ "$(readlink -f "$FLEET_HOME/.lcars" 2>/dev/null)" != "$(readlink -f "$LCARS_DIR")" ]; then
        ln -sfn "$LCARS_DIR" "$FLEET_HOME/.lcars"
        chown -h "$FLEET_USER:$FLEET_USER" "$FLEET_HOME/.lcars"
    fi

    # PS1 in .bashrc
    bashrc="$FLEET_HOME/.bashrc"
    touch "$bashrc"
    if ! grep -q 'LCARS_PS1' "$bashrc"; then
        printf '\n# LCARS_PS1\nPS1=%s\n' "'$LCARS_PS1'" >> "$bashrc"
    fi

    # Post-reboot bootstrap trigger
    if ! grep -q 'post-reboot' "$bashrc"; then
        printf '\n# LCARS post-reboot bootstrap (one-shot, gated by sentinels)\nif [ -f /home/private/.install_ok ] && [ ! -f /home/private/.fleet_ready ]; then\n    bash /local/LCARS/fleet/provisioning/post-reboot.sh\nfi\n' >> "$bashrc"
    fi

    # ~/.local/bin/ — laisser Claude Code gérer son propre binaire
    # (rm -f supprimé : lordzurp = vanilla, on ne touche pas à ses fichiers Claude Code)
    mkdir -p "$FLEET_HOME/.local/bin"
    chown -R "$FLEET_USER:$FLEET_USER" "$FLEET_HOME/.local" 2>/dev/null || true

    info "fleet_user" "done ($FLEET_HOME) — vanilla claude, no routing"
fi

echo ""
echo "All users provisioned."
