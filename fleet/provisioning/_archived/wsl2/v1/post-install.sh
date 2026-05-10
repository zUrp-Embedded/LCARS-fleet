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
#     post-install.sh — Configuration premier boot d'une instance WSL
#
#     Lancé automatiquement au premier boot via autorun .bashrc (injecté par
#     wsl-setup.sh). Tourne en tant que l'user normal dans un vrai shell interactif
#     avec systemd actif et home drvfs monté.
#
#     Pour relancer manuellement :
#       bash ~/.lcars/provisioning/wsl2/post-install.sh
#
#     [EN]
#     post-install.sh — Main post-install dispatcher for WSL2 instances.
#     Detects role, calls appropriate post-install-*.sh.
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
INSTANCE_TYPE="base"
if [ -f "$HOME/.wsl-instance-type" ]; then
    RAW_TYPE=$(cat "$HOME/.wsl-instance-type")
    case "$RAW_TYPE" in
        base|dev|builder|starfleet|engineer|qualifier)
            INSTANCE_TYPE="$RAW_TYPE"
            ;;
        *)
            warn ".wsl-instance-type contient une valeur inconnue '${RAW_TYPE}' — fallback 'base'"
            ;;
    esac
    info "Instance type: $INSTANCE_TYPE"
else
    warn ".wsl-instance-type not found — defaulting to 'base'"
fi

# ─── 3. Permissions SSH ───────────────────────────────────────────────────────
# Fix défensif — les fichiers SSH copiés par PowerShell peuvent avoir des perms
# Windows résiduelles sur drvfs.
if [ -d "$HOME/.ssh" ]; then
    info "Fixing SSH permissions"
    chmod 700 "$HOME/.ssh"
    find "$HOME/.ssh" -type f -name "*.pub"                             -exec chmod 644 {} \;
    find "$HOME/.ssh" -type f ! -name "*.pub" ! -name "authorized_keys" -exec chmod 400 {} \;
fi

# ─── 4. Test SSH GitHub ───────────────────────────────────────────────────────
info "Testing SSH connection to GitHub"
GITHUB_SSH_OK=false
SSH_OUTPUT=$(ssh -T git@github.com 2>&1 || true)
if echo "$SSH_OUTPUT" | grep -q "successfully authenticated"; then
    info "GitHub SSH OK"
    GITHUB_SSH_OK=true
else
    warn "GitHub SSH not working — output: $SSH_OUTPUT"
    warn "Continuing anyway..."
fi

# ─── 5. Claude Code ───────────────────────────────────────────────────────────
if command -v claude &>/dev/null; then
    warn "Claude Code already installed — skipping"
else
    info "Installing Claude Code"
    # curl|bash sans vérification de hash : Anthropic ne publie pas de hash/signature
    # pour cet installer. Acceptable pour un binaire officiel distribué sur domaine
    # contrôlé (claude.ai). Risque théorique : MITM ou CDN compromis.
    if curl -fsSL https://claude.ai/install.sh | bash; then
        export PATH="$HOME/.claude/bin:$PATH"
        if ! grep -q '\.claude/bin' "$HOME/.bashrc"; then
            echo 'export PATH="$HOME/.claude/bin:$PATH"' >> "$HOME/.bashrc"
            info "PATH updated in .bashrc"
        fi
        info "Claude Code installed"
    else
        warn "Claude Code install failed — run manually: curl -fsSL https://claude.ai/install.sh | bash"
    fi
fi

# ─── 5b. Shell prompt (PS1) ──────────────────────────────────────────────────
if ! grep -q 'LCARS_PS1' "$HOME/.bashrc"; then
    cat >> "$HOME/.bashrc" << 'BASHRC_EOF'
# LCARS_PS1
PS1='\n\[\033[35m\]\u\[\033[30m\]@\[\033[32m\]\h\[\033[30m\]:\[\033[31m\]\w\[\033[0m\]\n[\t] ==> '
BASHRC_EOF
    info "PS1 prompt added to .bashrc"
fi

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

if [ -d "$DIRECTIVES_DIR" ] && [ -f "$DIRECTIVES_DIR/install.sh" ]; then
    if [ -d "$DIRECTIVES_DIR/.git" ]; then
        info "Claude directives: pulling"
        git -C "$DIRECTIVES_DIR" pull --ff-only || warn "git pull failed — continuing with current version"
    fi
    info "Claude directives: running install.sh"
    bash "$DIRECTIVES_DIR/install.sh"
    info "Claude directives installed"
else
    warn "Claude directives not mounted or install.sh missing at $DIRECTIVES_DIR"
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
        bash "$DIRECTIVES_DIR/install.sh"
        info "Claude directives installed"
    else
        warn "Clone failed — Claude directives NOT installed"
        warn "Clone manually:"
        warn "  git clone $DIRECTIVES_REPO_DEFAULT_SSH $DIRECTIVES_DIR"
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
if [ -f "$GIT_IDENTITY_FILE" ]; then
    # shellcheck source=/dev/null
    source "$GIT_IDENTITY_FILE"
    git config --global user.name  "${GIT_USER_NAME:?'GIT_USER_NAME not set in git-identity.conf'}"
    git config --global user.email "${GIT_USER_EMAIL:?'GIT_USER_EMAIL not set in git-identity.conf'}"
    info "Git identity configured from $GIT_IDENTITY_FILE"
else
    warn "git-identity.conf not found at $GIT_IDENTITY_FILE"
    warn "Create #4_Private/git-identity.conf with GIT_USER_NAME and GIT_USER_EMAIL"
    warn "Git user identity NOT configured — run 'git config --global user.email <email>' manually"
fi

# ─── 9. Module spécifique au type d'instance ─────────────────────────────────
MODULE="$HOME/.lcars/provisioning/wsl2/post-install-${INSTANCE_TYPE}.sh"
if [ -f "$MODULE" ]; then
    info "Running module: post-install-${INSTANCE_TYPE}.sh"
    bash "$MODULE"
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
echo "    claude auth login   ← authentification Claude Code"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
