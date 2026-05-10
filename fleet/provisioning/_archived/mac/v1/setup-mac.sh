#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: setup-mac.sh
#     |  |________|  | AUTHOR: LORDZURP
#     |   ________   | SYSTEM: LCARS-FLEET v2.0
#     |  |  v2.0  |  | STATUS: WIP — M1 support planned
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS-FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: SETUP-MAC       | SUBSYSTEM: PROV / MAC           |
#     | LICENSE: AGPL-3         | STARDATE: 2026.063              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Initial macOS environment setup for fleet agents.        |
#     |  Installs brew deps, configures tmux and shell.           |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     setup-mac.sh — One-time setup for Claude multi-agent on macOS
#
#     Creates the shared directory structure, installs Claude Code, applies
#     Claude directives. Run once per machine.
#
#     Requires Homebrew — https://brew.sh
#
#     After this, use new-agent.sh to create named agent sessions.
#
#     Usage: bash setup-mac.sh [--shared-dir <path>] [--directives-repo <url>]
#
#     [EN]
#     setup-mac.sh — Initial macOS environment setup for fleet agents.
#     Installs brew deps, configures tmux and shell.
#

set -euo pipefail

SHARED_DIR="${CLAUDE_SHARED_DIR:-$HOME/claude-shared}"
DIRECTIVES_REPO_DEFAULT="git@github.com:${LCARS_REPO:-$ARCHITECT_USER/LCARS-fleet}.git"
DIRECTIVES_REPO="$DIRECTIVES_REPO_DEFAULT"
DIRECTIVES_DIR="$HOME/.lcars"
CUSTOM_DIRECTIVES_REPO=false
SHELL_RC="$HOME/.zshrc"   # default since macOS Catalina

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[setup]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[setup]${NC}  $*"; }
error() { echo -e "${RED}[setup]${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] && error "Ne pas lancer en root — doit tourner en tant que user normal"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --shared-dir)       SHARED_DIR="$2"; shift 2 ;;
        --directives-repo)  DIRECTIVES_REPO="$2"; CUSTOM_DIRECTIVES_REPO=true; shift 2 ;;
        -h|--help) echo "Usage: $0 [--shared-dir <path>] [--directives-repo <url>]"; exit 0 ;;
        *) error "Unknown argument: $1" ;;
    esac
done

# ─── 0. Homebrew ──────────────────────────────────────────────────────────────
if ! command -v brew &>/dev/null; then
    error "Homebrew not found — install it first: https://brew.sh"
fi
eval "$(brew shellenv)"   # ensure /opt/homebrew/bin (Apple Silicon) or /usr/local/bin (Intel) is in PATH

# ─── 1. Shared directories ────────────────────────────────────────────────────
info "Creating shared directories at $SHARED_DIR"
mkdir -p "$SHARED_DIR/handoff"
mkdir -p "$SHARED_DIR/artifacts"
mkdir -p "$SHARED_DIR/private"

# ─── 2. tmux ──────────────────────────────────────────────────────────────────
if command -v tmux &>/dev/null; then
    warn "tmux already installed — skipping"
else
    info "Installing tmux"
    brew install tmux
fi

# ─── 3. Claude Code ───────────────────────────────────────────────────────────
if command -v claude &>/dev/null; then
    warn "Claude Code already installed — skipping"
else
    info "Installing Claude Code"
    curl -fsSL https://claude.ai/install.sh | bash
    export PATH="$HOME/.local/bin:$HOME/.claude/bin:$PATH"
    if ! grep -q '\.local/bin' "$SHELL_RC"; then
        echo 'export PATH="$HOME/.local/bin:$HOME/.claude/bin:$PATH"' >> "$SHELL_RC"
        info "PATH updated in $SHELL_RC"
    fi
    info "Claude Code installed"
fi

# ─── 4. Claude directives ─────────────────────────────────────────────────────
# Claude directives evolve with usage — consider forking the upstream repo:
#   bash setup-mac.sh --directives-repo git@github.com:<you>/LCARS-fleet.git
if [ -d "$DIRECTIVES_DIR/.git" ]; then
    info "Claude directives: pulling"
    git -C "$DIRECTIVES_DIR" pull --ff-only
else
    if [ "$CUSTOM_DIRECTIVES_REPO" = false ]; then
        warn "Cloning upstream LCARS — directives evolve with usage."
        warn "Tip: fork the repo, then rerun with:"
        warn "     --directives-repo git@github.com:<you>/LCARS-fleet.git"
        warn "  or run: claude 'Set up my LCARS'  (CLAUDE.md will guide Claude)"
    fi
    info "Claude directives: cloning from $DIRECTIVES_REPO"
    git clone "$DIRECTIVES_REPO" "$DIRECTIVES_DIR"
fi
bash "$DIRECTIVES_DIR/install.sh"
info "Claude directives installed"

# ─── 5. Shared dir path — agents read this to locate handoff/ ─────────────────
mkdir -p "$HOME/.claude"
echo "$SHARED_DIR" > "$HOME/.claude/shared-dir"
info "Shared dir path written to ~/.claude/shared-dir"

# ─── 6. Claude Code settings.local.json ──────────────────────────────────────
CLAUDE_SETTINGS="$HOME/.claude/settings.local.json"
if [ -f "$CLAUDE_SETTINGS" ]; then
    warn "Claude settings.local.json already exists — skipping"
else
    mkdir -p "$HOME/.claude"
    cat > "$CLAUDE_SETTINGS" <<EOF
{
  "permissions": {
    "defaultMode": "bypassPermissions",
    "additionalDirectories": [
      "$SHARED_DIR"
    ]
  },
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \$HOME/.claude/hooks/session-startup.sh"
          }
        ]
      },
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \$HOME/.claude/hooks/on-prompt.sh"
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
            "command": "bash \$HOME/.claude/hooks/post-directional-handoff-reminder.sh"
          }
        ]
      }
    ]
  }
}
EOF
    info "Claude settings.local.json created (bypassPermissions + hooks)"
fi

# ─── 7. Claude Code settings.json — trust dialog pre-accepted ────────────────
CLAUDE_SETTINGS_GLOBAL="$HOME/.claude/settings.json"
if [ -f "$CLAUDE_SETTINGS_GLOBAL" ]; then
    warn "Claude settings.json already exists — skipping"
else
    mkdir -p "$HOME/.claude"
    cat > "$CLAUDE_SETTINGS_GLOBAL" <<EOF
{
  "projects": {
    "$HOME": {
      "hasTrustDialogAccepted": true
    },
    "~": {
      "hasTrustDialogAccepted": true
    },
    "$SHARED_DIR": {
      "hasTrustDialogAccepted": true
    }
  }
}
EOF
    info "Claude settings.json created (hasTrustDialogAccepted for \$HOME + ~ + \$SHARED_DIR)"
fi

# ─── 8. FLEET_SESSION ─────────────────────────────────────────────────────────
if ! grep -q 'FLEET_SESSION' "$SHELL_RC"; then
    echo '[[ "${TERM_PROGRAM:-}" != "vscode" ]] && export FLEET_SESSION=1' >> "$SHELL_RC"
    info "FLEET_SESSION added to $SHELL_RC"
fi

# ─── 9. Git identity template ─────────────────────────────────────────────────
IDENTITY_FILE="$SHARED_DIR/private/git-identity.conf"
if [ ! -f "$IDENTITY_FILE" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "$(dirname "$SCRIPT_DIR")/git-identity.conf.example" ]; then
        cp "$(dirname "$SCRIPT_DIR")/git-identity.conf.example" "$IDENTITY_FILE"
        warn "git-identity.conf created from example — edit before using new-agent.sh:"
        warn "  $IDENTITY_FILE"
    fi
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
info "Setup complete"
echo "  Shared dir   : $SHARED_DIR"
echo "  Handoff      : $SHARED_DIR/handoff/"
echo "  Claude Code  : $(command -v claude 2>/dev/null || echo "not in PATH — source $SHELL_RC")"
echo ""
echo "  Next steps:"
echo "    1. Edit $IDENTITY_FILE"
echo "    2. bash new-agent.sh <name>   ← create a named agent session"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
