#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: entrypoint.sh
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
#     | MODULE: ENTRYPOINT      | SUBSYSTEM: DOCKER / SANDBOX    |
#     | LICENSE: AGPL-3         | STARDATE: 2026.069              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Docker entrypoint — propagates API key, launches fleet.  |
#     |                                                           |
#     +-----------------------------------------------------------+

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[lcars-fleet]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[lcars-fleet]${NC}  $*"; }
error() { echo -e "${RED}[lcars-fleet]${NC} $*" >&2; }

# ─── API key check ───────────────────────────────────────────────────────────
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo ""
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    error "ANTHROPIC_API_KEY is required"
    echo ""
    echo "  Run with:"
    echo "    docker run -it -e ANTHROPIC_API_KEY=sk-ant-... lcars-fleet"
    echo ""
    echo "  Or mount a file:"
    echo "    docker run -it -v ~/.anthropic_key:/run/secrets/api_key lcars-fleet"
    echo ""
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    exit 1
fi

# Secret file fallback
if [ -f /run/secrets/api_key ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    ANTHROPIC_API_KEY="$(cat /run/secrets/api_key)"
fi

# ─── Propagate API key to all agent users ─────────────────────────────────────
info "Propagating API key to fleet agents..."
for user in lordzurp dev qualifier builder starfleet engineer steward; do
    home=$(getent passwd "$user" | cut -d: -f6)
    bashrc="$home/.bashrc"

    # Write to .bashrc (agents read it on sudo -u login)
    if ! grep -q 'ANTHROPIC_API_KEY' "$bashrc" 2>/dev/null; then
        echo "export ANTHROPIC_API_KEY=\"$ANTHROPIC_API_KEY\"" >> "$bashrc"
    fi
done
info "API key configured for all agents"

# ─── SSH setup — propagate keys to all agents ───────────────────────────────
if [ -d "$HOME/.ssh" ]; then
    ssh-keyscan -t ed25519 github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null
    # Share keys via /home/private/ (fleet-accessible)
    cp "$HOME/.ssh/id_"* /home/private/ 2>/dev/null || true
    cp "$HOME/.ssh/known_hosts" /home/private/known_hosts 2>/dev/null || true
    chmod 640 /home/private/id_* /home/private/known_hosts 2>/dev/null || true
    for user in dev qualifier builder starfleet engineer steward; do
        home=$(getent passwd "$user" | cut -d: -f6)
        sudo -u "$user" mkdir -p "$home/.ssh"
        sudo -u "$user" cp /home/private/known_hosts "$home/.ssh/known_hosts"
        for key in /home/private/id_*; do
            [ -f "$key" ] || continue
            sudo -u "$user" cp "$key" "$home/.ssh/$(basename "$key")"
            sudo -u "$user" chmod 600 "$home/.ssh/$(basename "$key")"
        done
        sudo -u "$user" chmod 700 "$home/.ssh"
    done
    info "SSH keys + known_hosts propagated to all agents"
fi

# ─── Git identity — override from env if provided ────────────────────────────
if [ -n "${GIT_USER_NAME:-}" ]; then
    git config --global user.name "$GIT_USER_NAME"
    git config --global user.email "${GIT_USER_EMAIL:-$GIT_USER_NAME@lcars-fleet.local}"
    info "Git identity override: $(git config --global user.name) <$(git config --global user.email)>"

    # Propagate override to agents
    for user in dev qualifier builder starfleet engineer steward; do
        sudo -u "$user" git config --global user.name "$(git config --global user.name)"
        sudo -u "$user" git config --global user.email "$(git config --global user.email)"
    done
fi

# ─── Fleet hub (websocket dashboard backend) ─────────────────────────────────
if [ -f "$HOME/fleet/fleet-hub.py" ]; then
    nohup python3 "$HOME/fleet/fleet-hub.py" >>/tmp/fleet-hub.log 2>&1 &
    info "Fleet hub started (pid $!)"
fi

# ─── Launch banner ────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  LCARS-FLEET — Docker Sandbox${NC}"
echo ""
echo "  Fleet agents: dev, qualifier, builder, starfleet, engineer, steward"
echo "  Commons:      /home/commons/"
echo "  Repo:         /local/LCARS"
echo ""
echo "  tmux controls:"
echo "    Ctrl+B then N/P  — next/previous tab"
echo "    Ctrl+B then D    — detach (container stays running)"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ─── Launch tmux fleet session ────────────────────────────────────────────────
# Can't use fleet-launch.sh directly because it may reference fleet-env.sh paths
# that assume WSL. Simplified version for Docker.

SESSION="fleet"

# Window 1: monitor — fleet-monitor TUI (top) | steward (bottom-left) | btop (bottom-right)
tmux new-session -d -s "$SESSION" -n "monitor"

# Fleet monitor (if available)
if [ -f "$HOME/fleet/fleet-monitor.py" ]; then
    tmux send-keys -t "$SESSION:monitor" "python3 $HOME/fleet/fleet-monitor.py" Enter
else
    tmux send-keys -t "$SESSION:monitor" "echo 'Fleet monitor — watching /home/commons/'; watch -n5 'ls -la /home/commons/*-handoff.md 2>/dev/null | tail -10'" Enter
fi

tmux split-window -v -l 17 -t "$SESSION:monitor"
tmux send-keys -t "$SESSION:monitor" "sudo -u steward -i" Enter
tmux split-window -h -t "$SESSION:monitor"
tmux send-keys -t "$SESSION:monitor" "btop" Enter
tmux select-pane -t "$SESSION:monitor" -U

# Agent windows
for agent in dev qualifier engineer; do
    win="$agent"
    [ "$agent" = "engineer" ] && win="architect"
    tmux new-window -t "$SESSION" -n "$win"
    tmux send-keys -t "$SESSION:$win" "sudo -u $agent -i" Enter
done

# Terminal window — lordzurp interactive (architect)
tmux new-window -t "$SESSION" -n "terminal"
tmux send-keys -t "$SESSION:terminal" "export FLEET_LAUNCHED=1 CLAUDE_AGENT_NAME=architect && clear" Enter

# Attach
exec tmux attach-session -t "$SESSION:monitor"
