#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: provision-system.sh
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
#     | MODULE: PROVISION-SYSTEM | SUBSYSTEM: PROV / WSL2         |
#     | LICENSE: AGPL-3          | STARDATE: 2026.068             |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  System-level provisioning for a fleet user.              |
#     |  Called by install.sh (standalone) and post-install.sh.   |
#     |  Must run as root. User passed as $1.                     |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     provision-system.sh — configuration système d'un user fleet (root).
#     Gère : CLAUDE.md, assets, utils, .bashrc injections, /home/commons.
#     Appelé par install.sh et post-install.sh (chemin standalone).
#     Ne clone pas le repo — le repo est supposé déjà présent via ~/.lcars.
#
#     [EN]
#     provision-system.sh — system-level fleet user setup (root).
#     Handles: CLAUDE.md, assets, utils, .bashrc injections, /home/commons.
#     Called by install.sh and post-install.sh (standalone path).
#     Does not clone the repo — ~/.lcars is assumed already in place.
#

set -euo pipefail

# --- Fleet env ---
source "$(dirname "${BASH_SOURCE[0]}")/../../fleet-env.sh"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[provision-system]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[provision-system]${NC}  $*"; }
error() { echo -e "${RED}[provision-system]${NC} $*" >&2; exit 1; }

[ "$EUID" -ne 0 ] && error "Must run as root"
[ -z "${1:-}" ] && error "Usage: provision-system.sh <username>"

REAL_USER="$1"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
LCARS_DIR="$REAL_HOME/.lcars"

[ -d "$LCARS_DIR" ] || error "$LCARS_DIR not found — run install.sh first"

# ─── System packages ─────────────────────────────────────────────────────────
PACKAGES=(btop expect python3-venv python3.12-venv gh)
MISSING=()
for pkg in "${PACKAGES[@]}"; do
    dpkg -s "$pkg" &>/dev/null || MISSING+=("$pkg")
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
    apt-get update -qq
    apt-get install -y "${MISSING[@]}" || warn "some packages failed — check apt manually"
    info "packages installed: ${MISSING[*]}"
else
    info "packages already installed: ${PACKAGES[*]}"
fi

# ─── Claude Code — system-wide install ────────────────────────────────────
if [ -x /usr/local/bin/claude ] && ! [ -L /usr/local/bin/claude ]; then
    info "Claude Code already installed: /usr/local/bin/claude"
else
    # Clean up any broken symlink from previous install
    rm -f /usr/local/bin/claude 2>/dev/null || true
    info "installing Claude Code system-wide"
    curl -fsSL https://claude.ai/install.sh | bash
    # The Anthropic installer may create a symlink (e.g. ~/.local/bin/claude → ~/.local/share/claude/versions/X.Y.Z)
    # We need the real binary in /usr/local/bin, not a symlink into /root/
    CLAUDE_BIN=""
    for candidate in /root/.local/bin/claude /root/.claude/local/claude "$HOME/.local/bin/claude"; do
        [ -e "$candidate" ] && CLAUDE_BIN="$candidate" && break
    done
    if [ -n "$CLAUDE_BIN" ]; then
        # Resolve symlink to get the real binary, then copy it
        CLAUDE_REAL="$(readlink -f "$CLAUDE_BIN")"
        cp "$CLAUDE_REAL" /usr/local/bin/claude
        chmod 755 /usr/local/bin/claude
        info "Claude Code installed: /usr/local/bin/claude (from $CLAUDE_REAL)"
    elif command -v claude &>/dev/null; then
        CLAUDE_REAL="$(readlink -f "$(command -v claude)")"
        cp "$CLAUDE_REAL" /usr/local/bin/claude
        chmod 755 /usr/local/bin/claude
        info "Claude Code installed: /usr/local/bin/claude (from $CLAUDE_REAL)"
    else
        warn "Claude Code install succeeded but binary not found — check manually"
    fi
fi

# ─── Fleet group + sudoers ────────────────────────────────────────────────
if ! getent group fleet >/dev/null 2>&1; then
    groupadd fleet
    info "fleet group created"
fi
if ! id -nG "$REAL_USER" | grep -qw fleet; then
    usermod -aG fleet "$REAL_USER"
    info "$REAL_USER added to fleet group"
fi
SUDOERS_FILE="/etc/sudoers.d/fleet-$REAL_USER"
if [ ! -f "$SUDOERS_FILE" ]; then
    FLEET_AGENTS="dev, builder, starfleet, engineer, qualifier, steward, architect"
    echo "$REAL_USER ALL=($FLEET_AGENTS) NOPASSWD: ALL" > "$SUDOERS_FILE"
    chmod 440 "$SUDOERS_FILE"
    info "sudoers: $REAL_USER can sudo -u to all fleet agents"
fi

# ─── Instance type ─────────────────────────────────────────────────────────
# v3 single-distro: role = Linux username
case "$REAL_USER" in
    dev|builder|starfleet|engineer|qualifier|steward)
        INSTANCE_TYPE="$REAL_USER"
        ;;
    architect)
        INSTANCE_TYPE="architect"
        ;;
    *)
        # First user (the one who ran install.sh) = architect role.
        # v2 single-distro: non-fleet username is always the architect.
        INSTANCE_TYPE="architect"
        ;;
esac
info "user: $REAL_USER — instance type: ${INSTANCE_TYPE:-unknown}"

# ─── CLAUDE.md — single source for all roles ──────────────────────────────
mkdir -p "$REAL_HOME/.claude"
CLAUDE_SRC="$LCARS_DIR/.claude/CLAUDE.md"
ln -sf "$CLAUDE_SRC" "$REAL_HOME/.claude/CLAUDE.md"
info "CLAUDE.md → CLAUDE.md"

# ─── Skills ────────────────────────────────────────────────────────────────
mkdir -p "$REAL_HOME/.claude/skills"
if [ -d "$LCARS_DIR/.claude/skills" ]; then
    cp -r "$LCARS_DIR/.claude/skills/"* "$REAL_HOME/.claude/skills/"
    info "skills → ~/.claude/skills/"
fi

# ─── Commands ──────────────────────────────────────────────────────────────
mkdir -p "$REAL_HOME/.claude/commands"
if [ -d "$LCARS_DIR/.claude/commands" ]; then
    cp -r "$LCARS_DIR/.claude/commands/"* "$REAL_HOME/.claude/commands/"
    info "commands → ~/.claude/commands/"
fi

# ─── Memory context ────────────────────────────────────────────────────────
mkdir -p "$REAL_HOME/.claude/memory"
if [ -d "$LCARS_DIR/.claude/memory" ]; then
    cp -r "$LCARS_DIR/.claude/memory/"* "$REAL_HOME/.claude/memory/"
    info "memory → ~/.claude/memory/"
fi

# ─── Hooks ─────────────────────────────────────────────────────────────────
mkdir -p "$REAL_HOME/.claude/hooks"
if [ -d "$LCARS_DIR/.claude/hooks" ]; then
    cp -r "$LCARS_DIR/.claude/hooks/"* "$REAL_HOME/.claude/hooks/"
    chmod +x "$REAL_HOME/.claude/hooks/"*.sh 2>/dev/null || true
    info "hooks → ~/.claude/hooks/"
fi

# ─── Fleet utils → ~/.local/bin/ ───────────────────────────────────────────
FLEET_DIR="$LCARS_DIR/fleet"
if [ -d "$FLEET_DIR" ]; then
    mkdir -p "$REAL_HOME/.local/bin"
    # fleet-env.sh must be co-located — all utils source it via dirname
    cp "$FLEET_DIR/fleet-env.sh" "$REAL_HOME/.local/bin/fleet-env.sh"
    chmod +x "$REAL_HOME/.local/bin/fleet-env.sh"
    INSTANCE_UTILS=(
        "fleet-send.sh" "fleet-state.sh" "fleet-done.sh"
        "fleet-action-done.sh" "fleet-bug.sh"
        "handoff-trim.sh" "handoff-check-utf8.sh"
        "wake-instance.sh"
    )
    for UTIL in "${INSTANCE_UTILS[@]}"; do
        SRC="$FLEET_DIR/$UTIL"
        [ -f "$SRC" ] || continue
        cp "$SRC" "$REAL_HOME/.local/bin/$UTIL"
        chmod +x "$REAL_HOME/.local/bin/$UTIL"
    done
    info "fleet utils → ~/.local/bin/"

    case "$INSTANCE_TYPE" in
        builder)
            BUILDER_UTILS=("rpi-img-mount.sh" "fleet-blocker.sh" "fleet-build-done.sh" "build-cycle.sh")
            for UTIL in "${BUILDER_UTILS[@]}"; do
                SRC="$FLEET_DIR/$UTIL"
                [ -f "$SRC" ] || continue
                cp "$SRC" "$REAL_HOME/.local/bin/$UTIL"
                chmod +x "$REAL_HOME/.local/bin/$UTIL"
            done
            info "builder utils → ~/.local/bin/"
            ;;
    esac
fi

# ─── .bashrc — PATH ~/.local/bin ────────────────────────────────────────────
if [ -f "$REAL_HOME/.bashrc" ] && ! grep -q 'FLEET_LOCAL_BIN' "$REAL_HOME/.bashrc"; then
    printf '\n# FLEET_LOCAL_BIN — fleet utils path\nexport PATH="$HOME/.local/bin:$PATH"\n' \
        >> "$REAL_HOME/.bashrc"
    info "~/.local/bin → PATH in ~/.bashrc"
fi

# ─── .bashrc — PS1 ─────────────────────────────────────────────────────────
if [ -f "$REAL_HOME/.bashrc" ] && ! grep -q 'LCARS_PS1' "$REAL_HOME/.bashrc"; then
    cat >> "$REAL_HOME/.bashrc" << 'BASHRC_EOF'
# LCARS_PS1
PS1='\n\[\033[35m\]\u\[\033[30m\]@\[\033[32m\]\h\[\033[30m\]:\[\033[31m\]\w\[\033[0m\]\n[\t] ==> '
BASHRC_EOF
    info "PS1 → ~/.bashrc"
fi

# ─── .bashrc — FLEET_SESSION ────────────────────────────────────────────────
if [ -f "$REAL_HOME/.bashrc" ] && ! grep -q 'FLEET_SESSION=1' "$REAL_HOME/.bashrc"; then
    printf '\n# Fleet session marker — exclut les terminaux VS Code\n%s\n' \
        '[[ "${TERM_PROGRAM:-}" != "vscode" ]] && export FLEET_SESSION=1' \
        >> "$REAL_HOME/.bashrc"
    info "FLEET_SESSION → ~/.bashrc"
fi

# ─── .bashrc — FLEET_AUTO_LAUNCH (skip engineer + architect) ────
if [ "$INSTANCE_TYPE" != "engineer" ] && [ "$INSTANCE_TYPE" != "architect" ]; then
    if [ -f "$REAL_HOME/.bashrc" ] && ! grep -q 'FLEET_LAUNCHED' "$REAL_HOME/.bashrc"; then
        printf '\n# Fleet auto-launch — triggered by FLEET_SESSION\nif [[ "${FLEET_SESSION:-}" == "1" ]] && [[ -z "${FLEET_LAUNCHED:-}" ]] && [[ -x "${HOME}/.local/bin/claude" ]]; then\n    export FLEET_LAUNCHED=1\n    export PATH="${HOME}/.local/bin:${PATH}"\n    "${HOME}/.local/bin/claude"\nfi\n' \
            >> "$REAL_HOME/.bashrc"
        info "FLEET_AUTO_LAUNCH → ~/.bashrc"
    fi
fi

# ─── .bashrc — AUTOCOMPACT_PCT ──────────────────────────────────────────────
if [ -f "$REAL_HOME/.bashrc" ] && ! grep -q 'AUTOCOMPACT_PCT' "$REAL_HOME/.bashrc"; then
    case "$INSTANCE_TYPE" in
        builder|dev|qualifier) PCT=60 ;;
        *)              PCT=75 ;;
    esac
    echo "export AUTOCOMPACT_PCT_OVERRIDE=$PCT" >> "$REAL_HOME/.bashrc"
    info "AUTOCOMPACT_PCT=$PCT → ~/.bashrc"
fi

# ─── Instance name ──────────────────────────────────────────────────────────
if [ ! -f "$REAL_HOME/.claude/instance-name" ]; then
    INSTANCE="${CLAUDE_AGENT_NAME:-${INSTANCE_TYPE:-$(hostname -s)}}"
    echo "$INSTANCE" > "$REAL_HOME/.claude/instance-name"
    info "instance-name: $INSTANCE"
else
    info "instance-name already set: $(cat "$REAL_HOME/.claude/instance-name")"
fi

# ─── /home/commons — ext4 local IPC (wipeable = fleet reset to vanilla) ───
# All instances share this. Not a drvfs mount — local ext4 for performance.
# Clean up any legacy drvfs mount (v1 used #3_Commons on Windows)
if grep -q "/home/commons" /etc/fstab 2>/dev/null; then
    sed -i '\|/home/commons|d' /etc/fstab
    info "removed legacy /home/commons fstab entry (v2 uses ext4 local)"
    mountpoint -q "$FLEET_COMMONS" && umount "$FLEET_COMMONS" 2>/dev/null || true
fi
if [ ! -d "$FLEET_COMMONS" ]; then
    mkdir -p "$FLEET_COMMONS"
    info "$FLEET_COMMONS created (ext4 local)"
fi
# Handoffs subdirectory + logs
mkdir -p "$FLEET_HANDOFFS/logs" "$FLEET_HANDOFFS/fleet-state"
# Fleet group write access (fleet group created earlier in this script)
chown "$REAL_USER:fleet" "$FLEET_COMMONS" "$FLEET_HANDOFFS" "$FLEET_HANDOFFS/logs" "$FLEET_HANDOFFS/fleet-state"
chmod 2775 "$FLEET_COMMONS" "$FLEET_HANDOFFS" "$FLEET_HANDOFFS/logs" "$FLEET_HANDOFFS/fleet-state"
find "$FLEET_HANDOFFS" -maxdepth 1 -type f -exec chown "$REAL_USER:fleet" {} \; -exec chmod g+rw {} \; 2>/dev/null || true
info "$FLEET_HANDOFFS — fleet group write access set"

# ─── Ready Room — sole persistent user↔fleet gate ────────────────────────
# WSL: drvfs mount to Windows. Linux natif: local directory.
if [ "$INSTANCE_TYPE" = "architect" ] || [ -z "$INSTANCE_TYPE" ]; then
    if grep -qi microsoft /proc/version 2>/dev/null; then
        WIN_USERNAME="$REAL_USER"
        READY_ROOM_WIN="C:\\Users\\${WIN_USERNAME}\\ready-room"
        READY_ROOM_WSL="/mnt/c/Users/${WIN_USERNAME}/ready-room"
        if [ ! -d "$READY_ROOM_WSL" ]; then
            mkdir -p "$READY_ROOM_WSL/inbox" "$READY_ROOM_WSL/outbox"
            info "ready-room created → $READY_ROOM_WSL"
        fi
        mkdir -p "$FLEET_READY_ROOM"
        if ! grep -q "$FLEET_READY_ROOM" /etc/fstab 2>/dev/null; then
            printf '%s\t%s\tdrvfs\tuid=1000,gid=1000,metadata,umask=22,fmask=11,noatime\t0\t0\n' \
                "$READY_ROOM_WIN" "$FLEET_READY_ROOM" >> /etc/fstab
            info "$FLEET_READY_ROOM fstab → $READY_ROOM_WIN"
        fi
        mountpoint -q "$FLEET_READY_ROOM" || mount "$FLEET_READY_ROOM" && info "$FLEET_READY_ROOM mounted"
        if [ ! -f /etc/wsl.conf ]; then
            cat > /etc/wsl.conf << 'EOF'
[boot]
systemd=true

[automount]
enabled=false
mountFsTab=true

[interop]
enabled=true
appendWindowsPath=false
EOF
            info "/etc/wsl.conf written"
        fi
    else
        mkdir -p "$FLEET_READY_ROOM/inbox" "$FLEET_READY_ROOM/outbox"
        info "$FLEET_READY_ROOM created (Linux natif)"
    fi
fi

# ─── Shared workspaces ───────────────────────────────────────────────────
mkdir -p /home/projects /home/tmp
chown "$REAL_USER:fleet" /home/projects /home/tmp
chmod 2775 /home/projects /home/tmp
info "/home/projects + /home/tmp ensured (fleet group write)"

# ─── setgid on LCARS .git/ — group inheritance for fleet members ─────────
# Without setgid, each user creates .git/ files with their primary group
# → Permission denied for others in the fleet group (FETCH_HEAD, index.lock…)
# Applied now if LCARS is already cloned; otherwise run manually after clone:
#   sudo find /home/projects/LCARS/.git -type d -exec chmod g+s {} \;
#   sudo chgrp -R fleet /home/projects/LCARS/.git
for _LCARS_DIR in /home/projects/LCARS /local/LCARS; do
    if [ -d "$_LCARS_DIR/.git" ]; then
        chgrp -R fleet "$_LCARS_DIR/.git"
        find "$_LCARS_DIR/.git" -type d -exec chmod g+s {} \;
        git -C "$_LCARS_DIR" config core.sharedRepository group
        info "$_LCARS_DIR/.git — setgid + fleet group + sharedRepository applied"
    fi
done

# ─── /home/private — fleet shared secrets (SSH key, git identity, etc.) ────
if [ ! -d /home/private ]; then
    mkdir -p /home/private
    chown "$REAL_USER:$REAL_USER" /home/private
    chmod 700 /home/private
    info "/home/private created"
fi

# ─── Fleet entry point — ~/start ──────────────────────────────────────────
# ~/fleet is reserved for deploy.sh (fleet scripts directory)
if [ "$INSTANCE_TYPE" = "architect" ]; then
    ln -sfn "$LCARS_DIR/start" "$REAL_HOME/start"
    chown -h "$REAL_USER:$REAL_USER" "$REAL_HOME/start"
    info "~/start → $LCARS_DIR/start"
fi

# ─── Ownership ──────────────────────────────────────────────────────────────
chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.claude" "$REAL_HOME/.local"
# .lcars: only if real dir (not symlink to repo)
[ -L "$LCARS_DIR" ] || chown -R "$REAL_USER:$REAL_USER" "$LCARS_DIR"
info "ownership fixed → $REAL_USER"

info "Done."
