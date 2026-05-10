#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: provision-user.sh
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
#     | MODULE: PROVISION-USER  | SUBSYSTEM: PROV / LINUX        |
#     | LICENSE: AGPL-3         | STARDATE: 2026.064             |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Provisions a new fleet Linux user (v2 single-distro).   |
#     |  Run as architect (sudo required).                         |
#     |                                                           |
#     |  Creates user, adds to fleet group, deploys .claude       |
#     |  assets, creates initial handoff, runs post-install.      |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     provision-user.sh — Crée et initialise un user Linux fleet (v2)
#
#     À lancer en tant que architect (sudo disponible).
#     Crée le user, l'ajoute au groupe fleet, déploie les assets .claude,
#     crée le fichier handoff initial, lance post-install.sh comme le user.
#
#     Usage:
#       bash provision-user.sh <username> [<role>]
#       bash provision-user.sh dev
#       bash provision-user.sh qualifier qualifier
#
#     <role> défaut = <username>
#     Rôles valides : dev, qualifier, builder, starfleet, engineer, steward
#
#     [EN]
#     provision-user.sh — Creates and initialises a fleet Linux user (v2).
#     Run as architect (sudo required).
#
#     Usage:
#       bash provision-user.sh <username> [<role>]
#

set -euo pipefail

# --- Fleet env ---
source "$(dirname "${BASH_SOURCE[0]}")/../../fleet-env.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}[provision]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[provision]${NC}  $*"; }
error() { echo -e "${RED}[provision]${NC} $*" >&2; exit 1; }

# ─── Args ─────────────────────────────────────────────────────────────────────
USERNAME="${1:?usage: provision-user.sh <username> [<role>]}"
ROLE="${2:-$USERNAME}"

case "$ROLE" in
    dev|qualifier|builder|starfleet|engineer|steward) ;;
    architect) error "Role 'architect' is the interactive user ($USER) — no dedicated Linux user needed. Use provision-system.sh for initial setup." ;;
    *) error "Unknown role '$ROLE'. Valid: dev, qualifier, builder, starfleet, engineer, steward" ;;
esac

[[ $EUID -ne 0 ]] || error "Do not run as root — run as architect (sudo will be used)"

# ─── Paths ────────────────────────────────────────────────────────────────────
FLEET_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HANDOFF_DIR="$FLEET_HANDOFFS"
FLEET_GROUP="fleet"

# ─── FLEET_ROOT traversal — make accessible to fleet users ───────────────────
# If FLEET_ROOT is under a user home (e.g. $ARCHITECT_HOME/.lcars), fleet users
# can't traverse it (home dirs are 750). chmod o+x allows path traversal
# without exposing directory listing (711 semantic).
FLEET_ROOT_HOME="$(echo "$FLEET_ROOT" | grep -oP '^/home/[^/]+')"
if [[ -n "$FLEET_ROOT_HOME" ]] && [[ "$(stat -c %a "$FLEET_ROOT_HOME")" != *1 ]]; then
    sudo chmod o+x "$FLEET_ROOT_HOME"
    info "Made $FLEET_ROOT_HOME traversable for fleet users (o+x)"
fi

# ─── 1. Create fleet group if absent ──────────────────────────────────────────
if ! getent group "$FLEET_GROUP" > /dev/null 2>&1; then
    info "Creating group: $FLEET_GROUP"
    sudo groupadd "$FLEET_GROUP"
else
    info "Group '$FLEET_GROUP' already exists"
fi

# ─── 2. Create user ───────────────────────────────────────────────────────────
if id "$USERNAME" &>/dev/null; then
    warn "User '$USERNAME' already exists — skipping useradd"
else
    info "Creating user: $USERNAME"
    sudo useradd \
        --create-home \
        --shell /bin/bash \
        --groups "$FLEET_GROUP" \
        --comment "LCARS fleet agent — $ROLE" \
        "$USERNAME"
    info "User '$USERNAME' created"
fi

# ─── 2b. Sudoers — role-based least privilege ─────────────────────────────────
SUDOERS_FILE="/etc/sudoers.d/fleet-$USERNAME"
case "$USERNAME" in
    *steward)
        # Steward executes system fixes: packages, services, permissions, backups
        SUDOERS_RULE="$USERNAME ALL=(ALL) NOPASSWD:ALL"
        ;;
    *engineer)
        # Engineer: cross-user wake (tmux send-keys), deploy to other homes, provisioning
        SUDOERS_RULE="$USERNAME ALL=(ALL) NOPASSWD:ALL"
        ;;
    *starfleet)
        # StarFleet: read-only diagnostics — no writes, no installs, no modifications
        SUDOERS_RULE="$USERNAME ALL=(ALL) NOPASSWD: /usr/bin/cat, /usr/bin/ls, /usr/bin/find, /usr/bin/journalctl, /usr/bin/systemctl status *, /usr/bin/mount, /usr/bin/df, /usr/bin/du, /usr/bin/ps, /usr/bin/ss, /usr/bin/id, /usr/bin/stat, /usr/bin/head, /usr/bin/tail, /usr/bin/grep, /usr/bin/wc"
        ;;
    *dev|*qualifier|*builder)
        # Workers: no sudo — code, test, build only
        SUDOERS_RULE=""
        ;;
    *)
        SUDOERS_RULE="$USERNAME ALL=(ALL) NOPASSWD:ALL"
        ;;
esac
if [ -n "$SUDOERS_RULE" ]; then
    echo "$SUDOERS_RULE" | sudo tee "$SUDOERS_FILE" > /dev/null
    sudo chmod 440 "$SUDOERS_FILE"
    info "Sudoers: $SUDOERS_FILE"
elif [ -f "$SUDOERS_FILE" ]; then
    sudo rm -f "$SUDOERS_FILE"
    info "Sudoers removed for $USERNAME (no sudo needed)"
else
    info "Sudoers: none for $USERNAME (worker role)"
fi

USER_HOME="/home/$USERNAME"

# Make home traversable by fleet group so $ARCHITECT_USER/deploy.sh can reach ~/.claude
sudo chgrp "$FLEET_GROUP" "$USER_HOME"
sudo chmod g+x "$USER_HOME"
info "$USER_HOME traversable by fleet group"

# ─── 3. Add to fleet group (idempotent) ───────────────────────────────────────
sudo usermod -aG "$FLEET_GROUP" "$USERNAME"
info "User '$USERNAME' in group '$FLEET_GROUP'"

# ─── 4. Symlink ~/.lcars → LCARS repo ───────────────────────────────────
LCARS_LINK="$USER_HOME/.lcars"
if sudo test -L "$LCARS_LINK"; then
    info ".lcars symlink already present"
elif sudo test -d "$LCARS_LINK"; then
    warn ".lcars exists as directory — skipping symlink"
else
    sudo ln -s "$FLEET_ROOT" "$LCARS_LINK"
    sudo chown -h "$USERNAME:$USERNAME" "$LCARS_LINK"
    info ".lcars → $FLEET_ROOT"
fi

# ─── 4b. /home/private — fleet group access ───────────────────────────────────
# Created by provision-system.sh (root, owned architect). Open to fleet group so
# all instances can read the shared SSH key and git identity.
if [ -d /home/private ]; then
    sudo chown "$(stat -c %U /home/private):$FLEET_GROUP" /home/private
    sudo chmod 750 /home/private
    for f in fleet-key fleet-key.pub git-identity.conf; do
        [ -f "/home/private/$f" ] || continue
        sudo chgrp "$FLEET_GROUP" "/home/private/$f"
        sudo chmod 640 "/home/private/$f"
    done
    info "/home/private accessible to fleet group"
fi

# ─── 5. Pre-create .claude dir with fleet group write access ─────────────────
# Allows architect (deploy.sh) to sync assets into this user's .claude dir
CLAUDE_DIR="$USER_HOME/.claude"
if [ ! -d "$CLAUDE_DIR" ]; then
    sudo mkdir -p "$CLAUDE_DIR"
    sudo chown "$USERNAME:$FLEET_GROUP" "$CLAUDE_DIR"
    sudo chmod 775 "$CLAUDE_DIR"
    info "Created $CLAUDE_DIR (fleet group write access)"
else
    # Idempotent: ensure fleet group write even if dir was created by an older provision
    # Recursive: subdirs (commands/, hooks/, skills/) may also be restrictive
    sudo chgrp -R "$FLEET_GROUP" "$CLAUDE_DIR"
    sudo chmod -R g+rwX "$CLAUDE_DIR"
    info "$CLAUDE_DIR — fleet group write ensured (recursive)"
fi

# ─── 5a. Pre-create .local/bin with fleet group write access ─────────────────
# deploy.sh writes instance-utils there — needs group write on the dir
LOCAL_BIN="$USER_HOME/.local/bin"
if [ ! -d "$LOCAL_BIN" ]; then
    sudo mkdir -p "$LOCAL_BIN"
    sudo chown "$USERNAME:$FLEET_GROUP" "$USER_HOME/.local" "$LOCAL_BIN"
    sudo chmod 775 "$USER_HOME/.local" "$LOCAL_BIN"
    info "Created $LOCAL_BIN (fleet group write access)"
fi

# ─── 5b-settings. Ensure settings.local.json is fleet-group-writable ─────────
# deploy.sh (scope-check) modifies it — on re-provision, file may exist as 600
SETTINGS="$CLAUDE_DIR/settings.local.json"
if [ -f "$SETTINGS" ]; then
    sudo chgrp "$FLEET_GROUP" "$SETTINGS"
    sudo chmod g+w "$SETTINGS"
    info "$SETTINGS — fleet group write ensured"
fi

# ─── 5b-pre. Ensure .bashrc exists and is group-writable ─────────────────────
# deploy.sh appends AUTOCOMPACT + FLEET_SESSION markers to .bashrc
BASHRC="$USER_HOME/.bashrc"
if [ ! -f "$BASHRC" ]; then
    sudo touch "$BASHRC"
    sudo chown "$USERNAME:$FLEET_GROUP" "$BASHRC"
    sudo chmod 664 "$BASHRC"
    info "Created $BASHRC (fleet group write access)"
else
    # Ensure fleet group can write (idempotent)
    sudo chgrp "$FLEET_GROUP" "$BASHRC"
    sudo chmod g+w "$BASHRC"
    info "$BASHRC — fleet group write ensured"
fi

# ─── 5b. Deploy .claude assets ────────────────────────────────────────────────
# Use sg to activate fleet group membership in same session (usermod -aG takes
# effect only on next login, but deploy.sh needs -w on fleet-group dirs now)
info "Deploying .claude assets via deploy.sh"
sg "$FLEET_GROUP" -c "bash '$FLEET_ROOT/fleet/provisioning/deploy.sh'"

# ─── 5c. Pre-configure git identity from /home/private if available ──────────
FLEET_GIT_ID="/home/private/git-identity.conf"
if [ -f "$FLEET_GIT_ID" ]; then
    # Support both bash format (GIT_USER_NAME=x) and git config format ([user] name = x)
    if grep -q '^\[user\]' "$FLEET_GIT_ID" 2>/dev/null; then
        # Git config INI format — parse with git config --file
        GIT_USER_NAME="$(git config --file "$FLEET_GIT_ID" user.name 2>/dev/null || true)"
        GIT_USER_EMAIL="$(git config --file "$FLEET_GIT_ID" user.email 2>/dev/null || true)"
    else
        # Bash format — source directly
        # shellcheck source=/dev/null
        source "$FLEET_GIT_ID"
    fi
    if [[ -n "${GIT_USER_NAME:-}" && -n "${GIT_USER_EMAIL:-}" ]]; then
        # Per-role identity: agents get LCARS-<role>, owner keeps their configured name
        if [ "$USERNAME" = "$(whoami)" ]; then
            _GIT_NAME="$GIT_USER_NAME"
            _GIT_EMAIL="$GIT_USER_EMAIL"
        else
            _GIT_NAME="LCARS-$USERNAME"
            _GIT_EMAIL="${USERNAME}@lcars-fleet.local"
        fi
        sudo -u "$USERNAME" git config --global user.name "$_GIT_NAME"
        sudo -u "$USERNAME" git config --global user.email "$_GIT_EMAIL"
        sudo -u "$USERNAME" git config --global --add safe.directory "$FLEET_ROOT"
        sudo -u "$USERNAME" git config --global --add safe.directory '*'
        info "Git identity ($_GIT_NAME) + safe.directory pre-configured for $USERNAME"
    else
        warn "git-identity.conf found but could not parse name/email — check format"
    fi
else
    warn "git-identity.conf not found at $FLEET_GIT_ID — will be configured during onboarding"
fi

# ─── 6. Initial handoff file ──────────────────────────────────────────────────
HANDOFF_FILE="$HANDOFF_DIR/${USERNAME}-handoff.md"
if [ ! -f "$HANDOFF_FILE" ]; then
    info "Creating initial handoff: $HANDOFF_FILE"
    cat > "$HANDOFF_FILE" <<EOF
# ${USERNAME} handoff

## STATE
date: $(date '+%Y-%m-%d %H:%M')
ref: none
action: idle
status: pending
blocker: none
waiting: none
notify: none

## ACTIONS
[ ] Onboarding — accueillir l'utilisateur, configurer git identity + plan Anthropic

## DONE
### $(date '+%Y-%m-%d %H:%M') — User provisioned + post-install complete
User ${USERNAME} (role: ${ROLE}) created and provisioned via provision-user.sh on $(hostname).
Claude Code installed, directives deployed, SSH key configured.
EOF
else
    warn "Handoff already exists: $HANDOFF_FILE — skipping"
fi

# ─── 7. Run post-install as the new user ─────────────────────────────────────
POST_INSTALL="$FLEET_ROOT/fleet/provisioning/linux/post-install.sh"
if [ -f "$POST_INSTALL" ]; then
    info "Running post-install as $USERNAME"
    sudo -u "$USERNAME" -i LCARS_SYSTEM_PROVISIONED=1 bash "$POST_INSTALL"
else
    warn "post-install.sh not found at $POST_INSTALL — skipping"
    warn "Run manually: sudo -u $USERNAME -i bash $POST_INSTALL"
fi

# ─── 8. Final permissions fixup ────────────────────────────────────────────────
# post-install.sh creates files (settings.local.json, etc.) owned by $USERNAME:$USERNAME.
# Re-apply fleet group so deploy.sh can patch them cross-instance.
sudo chgrp -R "$FLEET_GROUP" "$CLAUDE_DIR"
sudo chmod -R g+rwX "$CLAUDE_DIR"

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
info "Provisioning complete: $USERNAME ($ROLE)"
echo "  Home     : $USER_HOME"
echo "  Groups   : $(id -Gn "$USERNAME")"
echo "  Handoff  : $HANDOFF_FILE"
echo ""
echo "  Next: add $USERNAME to fleet-launch.sh tmux layout if not already present"
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
