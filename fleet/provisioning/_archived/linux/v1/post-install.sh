#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: post-install.sh
#     |  |________|  | AUTHOR: LORDZURP
#     |   ________   | SYSTEM: LCARS-FLEET v2.0
#     |  |  v2.0  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS-FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: POST-INSTALL    | SUBSYSTEM: PROV / WSL2          |
#     | LICENSE: AGPL-3         | STARDATE: 2026.063              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Main post-install dispatcher for WSL2 instances.         |
#     |  Detects role, calls appropriate post-install-*.sh.       |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     post-install.sh — Configuration initiale d'un user fleet (v2 single-distro)
#
#     Lancé une fois par provision-user.sh via sudo -u <user> -i.
#     Tourne en tant que l'user normal dans son home Linux.
#
#     Pour relancer manuellement :
#       sudo -u <user> -i bash ~/.lcars/fleet/provisioning/linux/post-install.sh
#
#     [EN]
#     post-install.sh — Initial setup for a fleet Linux user (v2 single-distro).
#     Role derived from $USER. Calls appropriate post-install-*.sh.
#

set -euo pipefail

# --- Fleet env ---
source "$(dirname "${BASH_SOURCE[0]}")/../../fleet-env.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[post-install]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[post-install]${NC}  $*"; }
error()   { echo -e "${RED}[post-install]${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] && error "Ne pas lancer en root — doit tourner en tant que user normal"

# ─── 1. PATH ──────────────────────────────────────────────────────────────────
export PATH="$HOME/.local/bin:$HOME/.claude/bin:$PATH"

# ─── 2. Instance type ─────────────────────────────────────────────────────────
# v2 single-distro: role = Linux username
case "$USER" in
    dev|builder|starfleet|engineer|qualifier|steward)
        INSTANCE_TYPE="$USER"
        echo "$USER" > "$HOME/.claude/instance-name"
        ;;
    architect)
        INSTANCE_TYPE="architect"
        # architect is always architect regardless of hostname/distro
        echo "architect" > "$HOME/.claude/instance-name"
        info "Instance name set to architect"
        ;;
    *)
        # First user (the one who ran install.sh) = architect role.
        INSTANCE_TYPE="architect"
        echo "architect" > "$HOME/.claude/instance-name"
        info "Instance type: architect (first user — $USER)"
        ;;
esac
info "Instance type: $INSTANCE_TYPE (user: $USER)"

# ─── 3. SSH key — fleet shared key from /home/private, or generate ───────────
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
SSH_KEY="$HOME/.ssh/id_ed25519"
FLEET_KEY="/home/private/fleet-key"
if [ ! -f "$SSH_KEY" ]; then
    if [ -f "$FLEET_KEY" ]; then
        info "Copying fleet shared SSH key from $FLEET_KEY"
        cp "$FLEET_KEY" "$SSH_KEY"
        cp "${FLEET_KEY}.pub" "${SSH_KEY}.pub"
    else
        info "Generating SSH key (ed25519) — save to $FLEET_KEY for reuse"
        ssh-keygen -t ed25519 -C "fleet@$(hostname -s)" -f "$SSH_KEY" -N ""
        mkdir -p /home/private
        cp "$SSH_KEY" "$FLEET_KEY"
        cp "${SSH_KEY}.pub" "${FLEET_KEY}.pub"
        chmod 600 "$FLEET_KEY"
        chmod 644 "${FLEET_KEY}.pub"
        info "Fleet key saved: $FLEET_KEY"
    fi
else
    info "SSH key already exists: $SSH_KEY"
fi
chmod 600 "$SSH_KEY"
chmod 644 "${SSH_KEY}.pub"
info "SSH key ready: $SSH_KEY — GitHub auth will be configured by steward after PoC"

# ─── 4. SSH GitHub — deferred to steward post-PoC ─────────────────────────────
GITHUB_SSH_OK=false   # steward handles this after PoC validation

# ─── 5. Claude Code ───────────────────────────────────────────────────────────
# Claude Code — system-wide install is handled by provision-system.sh
# Create local symlink so claude is in user's PATH and Anthropic app config is satisfied
if [ -x /usr/local/bin/claude ]; then
    mkdir -p "$HOME/.local/bin"
    ln -sf /usr/local/bin/claude "$HOME/.local/bin/claude"
    info "Claude Code: ~/.local/bin/claude → /usr/local/bin/claude"
elif command -v claude &>/dev/null; then
    info "Claude Code available: $(command -v claude)"
else
    warn "Claude Code not found — provision-system.sh should have installed it"
    warn "Run manually: curl -fsSL https://claude.ai/install.sh | bash"
fi

# ─── 5b. Shell prompt (PS1) — backlog, not configured here ───────────────────

# ─── 6. Claude directives ─────────────────────────────────────────────────────
# Claude directives evolve with usage — consider forking the upstream repo
# and storing your fork URL in /home/private/directives-repo.conf :
#   DIRECTIVES_REPO=git@github.com:<you>/LCARS-fleet.git
DIRECTIVES_DIR="$HOME/.lcars"
DIRECTIVES_REPO_DEFAULT_SSH="git@github.com:${LCARS_REPO:-$ARCHITECT_USER/LCARS-fleet}.git"
DIRECTIVES_REPO_DEFAULT_HTTPS="https://github.com/${LCARS_REPO:-$ARCHITECT_USER/LCARS-fleet}.git"

DIRECTIVES_REPO_CONF="/home/private/directives-repo.conf"
if [ -f "$DIRECTIVES_REPO_CONF" ]; then
    # shellcheck source=/dev/null
    source "$DIRECTIVES_REPO_CONF"
    info "Claude directives: using custom repo from directives-repo.conf"
fi

if [ -L "$DIRECTIVES_DIR" ] && ! [ -e "$DIRECTIVES_DIR" ]; then
    # Dangling symlink — target not mounted or deleted. Don't clone over it.
    warn "Claude directives: symlink $DIRECTIVES_DIR exists but target is missing"
    warn "Mount the target or remove the symlink, then re-run post-install.sh"
elif [ -L "$DIRECTIVES_DIR" ] && [ -d "$DIRECTIVES_DIR/.git" ]; then
    # v2 fleet: .lcars is a symlink set up by provision-user.sh → repo already in place.
    # deploy.sh has already synced .claude assets. No need to run install.sh (requires root).
    git config --global --add safe.directory "$(readlink -f "$DIRECTIVES_DIR")"
    if [ "${LCARS_SYSTEM_PROVISIONED:-0}" = "1" ]; then
        info "Claude directives: symlink present, repo fresh from install.sh — skip pull"
    else
        info "Claude directives: symlink present, pulling latest"
        git -C "$DIRECTIVES_DIR" pull --ff-only || warn "git pull skipped — no upstream or already current"
    fi
    info "Claude directives: assets deployed by deploy.sh — install.sh not needed"
elif [ -d "$DIRECTIVES_DIR" ] && [ -f "$DIRECTIVES_DIR/install.sh" ]; then
    # Standalone install (not via provision-user.sh): call provision-system.sh with sudo
    # Skip if install.sh already called it this session (offline tarball path).
    if [ -d "$DIRECTIVES_DIR/.git" ]; then
        info "Claude directives: pulling"
        git -C "$DIRECTIVES_DIR" pull --ff-only || warn "git pull failed — continuing with current version"
    fi
    if [ "${LCARS_SYSTEM_PROVISIONED:-0}" = "1" ]; then
        info "Claude directives: provision-system.sh already done (install.sh path) — skipping"
    else
        info "Claude directives: running provision-system.sh (requires sudo)"
        sudo bash "$DIRECTIVES_DIR/fleet/provisioning/linux/provision-system.sh" "$USER"
        info "Claude directives installed"
    fi
else
    warn "Claude directives not found at $DIRECTIVES_DIR"
    warn "Attempting to clone from GitHub..."
    if [ -n "${DIRECTIVES_REPO:-}" ]; then
        CLONE_URL="$DIRECTIVES_REPO"
    elif [ "$GITHUB_SSH_OK" = true ]; then
        CLONE_URL="$DIRECTIVES_REPO_DEFAULT_SSH"
        warn "Tip: claude directives evolve — consider forking and owning your copy."
        warn "     Run: claude 'Set up my LCARS'"
    else
        CLONE_URL="$DIRECTIVES_REPO_DEFAULT_HTTPS"
        warn "SSH not available — using HTTPS (read-only, no push)"
        warn "Tip: run: claude 'Set up my LCARS'  once SSH is configured"
    fi
    if git clone "$CLONE_URL" "$DIRECTIVES_DIR"; then
        info "Claude directives cloned from $CLONE_URL"
        sudo bash "$DIRECTIVES_DIR/install.sh"
        info "Claude directives installed"
    else
        warn "Clone failed — Claude directives NOT installed"
        warn "Clone manually: git clone $DIRECTIVES_REPO_DEFAULT_SSH $DIRECTIVES_DIR"
        warn "Then run: sudo bash $DIRECTIVES_DIR/install.sh"
    fi
fi

# ─── 7. Claude Code settings.local.json ──────────────────────────────────────
CLAUDE_SETTINGS="$HOME/.claude/settings.local.json"
if [ -f "$CLAUDE_SETTINGS" ]; then
    warn "Claude settings.local.json already exists — skipping"
else
    mkdir -p "$HOME/.claude"
    cat > "$CLAUDE_SETTINGS" <<'EOF'
{
  "permissions": {
    "defaultMode": "bypassPermissions",
    "additionalDirectories": [
      "/home/commons"
    ]
  },
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash $HOME/.claude/hooks/session-startup.sh"
          }
        ]
      },
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash $HOME/.claude/hooks/on-prompt.sh"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "bash $HOME/.claude/hooks/post-directional-handoff-reminder.sh"
          },
          {
            "type": "command",
            "command": "bash $HOME/.claude/hooks/check-secrets.sh"
          },
          {
            "type": "command",
            "command": "bash $HOME/.claude/hooks/post-scope-check.sh"
          }
        ]
      }
    ]
  }
}
EOF
    info "Claude settings.local.json created (bypassPermissions + hooks)"
fi

# ─── 7b. Claude Code settings.json — trust dialog pre-accepted ───────────────
CLAUDE_SETTINGS_GLOBAL="$HOME/.claude/settings.json"
if [ -f "$CLAUDE_SETTINGS_GLOBAL" ]; then
    warn "Claude settings.json already exists — skipping"
else
    mkdir -p "$HOME/.claude"
    cat > "$CLAUDE_SETTINGS_GLOBAL" << EOF
{
  "projects": {
    "$HOME": {
      "hasTrustDialogAccepted": true
    },
    "~": {
      "hasTrustDialogAccepted": true
    },
    "/home/commons": {
      "hasTrustDialogAccepted": true
    }
  }
}
EOF
    info "Claude settings.json created (hasTrustDialogAccepted for $HOME + ~ + /home/commons)"
fi

# ─── 8. Mask gpg-agent-ssh.socket ────────────────────────────────────────────
# WSL2 shutdown race: gpg-agent-ssh.socket fails to thaw app.slice (cgroup already
# removed), leaving an error status that triggers "Failed to start systemd user
# session" on next login. None of the fleet instances use GPG-backed SSH auth.
mkdir -p "$HOME/.config/systemd/user"
ln -sf /dev/null "$HOME/.config/systemd/user/gpg-agent-ssh.socket"
info "gpg-agent-ssh.socket masked (WSL2 cgroup workaround)"

# ─── 8b. Config git globale ───────────────────────────────────────────────────
info "Configuring git"
GIT_IDENTITY_FILE="/home/private/git-identity.conf"
if [ -n "$(git config --global user.name 2>/dev/null)" ]; then
    info "Git identity already configured: $(git config --global user.name) <$(git config --global user.email)>"
elif [ -f "$GIT_IDENTITY_FILE" ]; then
    # shellcheck source=/dev/null
    source "$GIT_IDENTITY_FILE"
    git config --global user.name  "${GIT_USER_NAME:?'GIT_USER_NAME not set in git-identity.conf'}"
    git config --global user.email "${GIT_USER_EMAIL:?'GIT_USER_EMAIL not set in git-identity.conf'}"
    info "Git identity configured: $GIT_USER_NAME <$GIT_USER_EMAIL>"
else
    info "Git identity — will be configured during steward onboarding"
fi

# ─── 9. Anthropic plan reset schedule — déplacé dans l'onboarding steward ───
# (configure-plan.sh disponible manuellement : bash ~/.lcars/fleet/provisioning/linux/configure-plan.sh)

# ─── 9b. Module spécifique au type d'instance ───────────────────────────────
MODULE="$HOME/.lcars/fleet/provisioning/linux/post-install-${INSTANCE_TYPE}.sh"
if [ -f "$MODULE" ]; then
    info "Running module: post-install-${INSTANCE_TYPE}.sh"
    bash "$MODULE"
elif [ "$INSTANCE_TYPE" = "base" ]; then
    info "Instance type 'base' — no additional configuration"
else
    warn "No module found for instance type '$INSTANCE_TYPE' ($MODULE)"
fi

# ─── 10. Summary ──────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
info "Post-install complete"
echo "  Instance type    : $INSTANCE_TYPE"
echo "  Claude Code      : $(command -v claude 2>/dev/null || echo 'not found — check PATH')"
echo "  Claude directives: $DIRECTIVES_DIR"
echo ""
echo "  Next steps:"
echo "    provision-user.sh steward   ← provision the steward (if not done)"
echo "    ~/start                     ← launch fleet tmux session"
echo "    steward will handle agent provisioning + PoC interactively"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
