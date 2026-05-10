#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: new-agent.sh
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
#     | MODULE: NEW-AGENT       | SUBSYSTEM: PROV / SHARED        |
#     | LICENSE: AGPL-3         | STARDATE: 2026.063              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Creates a new fleet agent (Linux or macOS).              |
#     |  Sets up handoff, workspace, and tmux session.            |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     new-agent.sh — Créer ou attacher une session Claude agent nommée (tmux)
#
#     Chaque agent est une session tmux avec CLAUDE_AGENT_NAME dans l'environnement.
#     Le hook session-startup lit cette variable pour identifier l'instance.
#
#     Usage: bash new-agent.sh <agent-name>
#     Exemple: bash new-agent.sh dev
#
#     [EN]
#     new-agent.sh — Creates a new fleet agent (Linux or macOS).
#     Sets up handoff, workspace, and tmux session.
#

set -euo pipefail

# --- Fleet env ---
source "$(dirname "${BASH_SOURCE[0]}")/../fleet-env.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[new-agent]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[new-agent]${NC}  $*"; }
error() { echo -e "${RED}[new-agent]${NC} $*" >&2; exit 1; }

AGENT_NAME="${1:-}"
[ -z "$AGENT_NAME" ] && error "Usage: $0 <agent-name> [--instance-type <type>] [--no-attach]"
shift
INSTANCE_TYPE="base"
NO_ATTACH=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --instance-type) INSTANCE_TYPE="${2:-base}"; shift 2 ;;
        --no-attach)     NO_ATTACH=1; shift ;;
        *) error "Unknown argument: $1" ;;
    esac
done

if ! command -v tmux &>/dev/null; then
    case "$(uname -s)" in
        Darwin) error "tmux not found — install: brew install tmux" ;;
        *)      error "tmux not found — install: sudo apt install tmux" ;;
    esac
fi

SHARED_DIR=$(cat "$HOME/.claude/shared-dir" 2>/dev/null || echo "$HOME/claude-shared")
HANDOFF_DIR="$SHARED_DIR/handoff"
IDENTITY_FILE="$SHARED_DIR/private/git-identity.conf"
SESSION_NAME="claude-$AGENT_NAME"

# ─── 1. Workspace de l'agent ─────────────────────────────────────────────────
WORKSPACE="$HOME/claude-agents/$AGENT_NAME"
mkdir -p "$WORKSPACE"
echo "$INSTANCE_TYPE" > "$WORKSPACE/.instance-type"
info "Workspace: $WORKSPACE (type: $INSTANCE_TYPE)"

# ─── 2. Fichier handoff initial ───────────────────────────────────────────────
HANDOFF_FILE="$HANDOFF_DIR/${AGENT_NAME}-handoff.md"
if [ ! -f "$HANDOFF_FILE" ]; then
    mkdir -p "$HANDOFF_DIR"
    cat > "$HANDOFF_FILE" <<EOF
# ${AGENT_NAME} handoff

## STATE
date: $(date '+%Y-%m-%d %H:%M')
ref: none
action: idle
status: pending
blocker: none
waiting: none
notify: none

## ACTIONS

## DONE
### $(date '+%Y-%m-%d %H:%M') — Instance créée
Agent ${AGENT_NAME} initialisé via new-agent.sh sur $(hostname).
EOF
    info "Handoff file created: $HANDOFF_FILE"
fi

# ─── 3. Git identity ──────────────────────────────────────────────────────────
if [ -f "$IDENTITY_FILE" ]; then
    # shellcheck source=/dev/null
    source "$IDENTITY_FILE"
    git config --global user.name  "${GIT_USER_NAME:?'GIT_USER_NAME not set in git-identity.conf'}"
    git config --global user.email "${GIT_USER_EMAIL:?'GIT_USER_EMAIL not set in git-identity.conf'}"
    info "Git identity: ${GIT_USER_NAME} <${GIT_USER_EMAIL}>"
else
    warn "git-identity.conf not found at $IDENTITY_FILE — git identity not configured"
fi

# ─── 4. Session tmux ──────────────────────────────────────────────────────────
if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    warn "Session '$SESSION_NAME' already exists — skipping"
    [[ "$NO_ATTACH" -eq 0 ]] && exec tmux attach-session -t "$SESSION_NAME"
    exit 0
fi

info "Creating tmux session: $SESSION_NAME"
tmux new-session -d -s "$SESSION_NAME" \
    -e "CLAUDE_AGENT_NAME=$AGENT_NAME" \
    -e "CLAUDE_INSTANCE_TYPE=$INSTANCE_TYPE" \
    -e "CLAUDE_SHARED_DIR=$SHARED_DIR" \
    -e "FLEET_SESSION=1" \
    -c "$WORKSPACE"

tmux send-keys -t "$SESSION_NAME" "claude" Enter

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
info "Agent '$AGENT_NAME' prêt"
echo "  Session  : $SESSION_NAME"
echo "  Workspace: $WORKSPACE"
echo "  Handoff  : $HANDOFF_FILE"
echo "  Env vars : CLAUDE_AGENT_NAME=$AGENT_NAME"
echo "             CLAUDE_INSTANCE_TYPE=$INSTANCE_TYPE"
echo "             CLAUDE_SHARED_DIR=$SHARED_DIR"
echo ""
echo "  Attach   : tmux attach -t $SESSION_NAME"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

[[ "$NO_ATTACH" -eq 0 ]] && exec tmux attach-session -t "$SESSION_NAME"
