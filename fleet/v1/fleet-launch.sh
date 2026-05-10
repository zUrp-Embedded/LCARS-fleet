#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-launch.sh
#     |  |________|  | AUTHOR: STARFLEET
#     |   ________   | SYSTEM: LCARS-FLEET v6.0
#     |  |  v6.0  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS-FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: LAUNCHER        | SUBSYSTEM: FLEET / LIFECYCLE    |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Launches the fleet tmux session.                         |
#     |  v2: single-distro multi-user — sudo -u <user> -i         |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#           ______________________________________________________
#          /          LCARS FLEET - FEDERATION DATABASE           \
#         |   ________   __________________________________________\
#         |  |  2026  |  | SOURCE: fleet-launch.sh
#         |  |________|  | AUTHOR: LORDZURP
#         |   ________   | SYSTEM: LCARS-FLEET v6.0
#
#     [EN]
#     fleet-launch.sh — Launches the fleet tmux session.
#     v2: single-distro multi-user — sudo -u <user> -i
#
#
# --- END HEADER ---



# --help: extract [EN] section from this header
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && {
    sed -n '/^#     \[EN\]/,/^# --- END HEADER ---/{/\[EN\]/d; /END HEADER/d; s/^#     //; s/^#[[:space:]]*$//; p}' "$0"
    exit 0
}

set -euo pipefail

# --- Fleet env ---
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/fleet-env.sh"
mkdir -p "$FLEET_STATE_DIR/run"

# tmux server owned by fleet_user (whoever launches the dashboard)
# Socket ownership = caller. fleet_tmux wrapper handles cross-UID access.
_tmux() { tmux "$@"; }

SESSION="fleet"
readonly SESSION
HANDOFF="$FLEET_HANDOFFS"

# --- Arguments ---
# ─── Security gate — C:\ must NOT be mounted ─────────────────────────────────
if grep -qi microsoft /proc/version 2>/dev/null; then
    SEC_TEST="/mnt/c/tmp/.fleet-security-check-$$"
    if touch "$SEC_TEST" 2>/dev/null; then
        rm -f "$SEC_TEST" 2>/dev/null
        echo ""
        echo "  ╔══════════════════════════════════════════════════════════════╗"
        echo "  ║  SECURITY GATE FAILED — C:\\ is still mounted read-write    ║"
        echo "  ║                                                              ║"
        echo "  ║  All agents can read and write your entire Windows drive.    ║"
        echo "  ║  This is a Microsoft default, not a LCARS issue.            ║"
        echo "  ║                                                              ║"
        echo "  ║  Fix: reboot WSL from PowerShell:                           ║"
        echo "  ║       wsl --shutdown                                         ║"
        echo "  ║  Then relaunch.                                              ║"
        echo "  ╚══════════════════════════════════════════════════════════════╝"
        echo ""
        exit 1
    fi
fi

ATTACH=1
TEMPLATE="executive"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-attach) ATTACH=0; shift ;;
        --template)
            TEMPLATE="${2:?--template requires a value: executive|demo|panoptique}"
            shift 2
            ;;
        *)
            echo "Usage: fleet-launch.sh [--no-attach] [--template executive|demo|panoptique]" >&2
            exit 1
            ;;
    esac
done

case "$TEMPLATE" in
    executive|demo|panoptique) ;;
    *) echo "ERROR: unknown template '$TEMPLATE' (expected: executive|demo|panoptique)" >&2; exit 1 ;;
esac

if _tmux has-session -t "$SESSION" 2>/dev/null; then
    if [[ $ATTACH -eq 1 ]]; then
        _tmux attach-session -t "$SESSION:monitor"
    fi
    exit 0
fi

if [ ! -d "$HANDOFF" ]; then
    echo "Erreur : $HANDOFF introuvable." >&2
    exit 1
fi

# Models already set by deploy.sh during fleet-update.sh — no reset needed at launch.

# ─── Resolve interactive roles from blueprint (pattern #9 fix) ──────────────
# Templates define layout structure; blueprint defines which roles fill them.
ROLE_BOUNDARY_OS=$(yq '.instances[] | select(.scope == "boundary-os") | .role' "$FLEET_YAML" 2>/dev/null | head -1)
ROLE_TIER1=$(yq '.instances[] | select(.tier == 1) | .role' "$FLEET_YAML" 2>/dev/null | head -1)
ROLE_WORKER=$(yq '.instances[] | select(.scope == "code") | .role' "$FLEET_YAML" 2>/dev/null | head -1)
: "${ROLE_BOUNDARY_OS:=starfleet}"
: "${ROLE_TIER1:=engineer}"
: "${ROLE_WORKER:=dev}"

# ─── Monitor window (shared by all modes) ────────────────────────────────────
# Layout: fleet-monitor (haut, ~40%) | $ROLE_BOUNDARY_OS (bas, 60%)
_tmux new-session -d -s "$SESSION" -n "monitor"
_tmux source-file "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/tmux.conf" 2>/dev/null || true
# v7 Phase 3c: bind project to tmux session (all panes inherit via tmux environment)
_tmux set-environment -t "$SESSION" FLEET_PROJECT "${FLEET_PROJECT:-LCARS}"
_tmux set-environment -t "$SESSION" FLEET_WORKDIR "${FLEET_WORKDIR:-$HOMES_ROOT/projects.work/LCARS/work}"
# Default socket — cosmetic permissions for fleet group access
_DEFAULT_SOCK="/tmp/tmux-$(id -u)/default"
[ -S "$_DEFAULT_SOCK" ] && chmod 660 "$_DEFAULT_SOCK" && chgrp fleet "$_DEFAULT_SOCK" || true
PBASE=$(_tmux show -gv pane-base-index 2>/dev/null || echo 1)
[[ "$PBASE" =~ ^[0-9]+$ ]] || PBASE=0
# Lancer fleet-hub.py en background dans le pane monitor (pane haut)
FLEET_HUB_PORT="${FLEET_HUB_PORT:-8765}"
FLEET_DIR_RESOLVED="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
python3 "$FLEET_DIR_RESOLVED/fleet-hub.py" \
    --port "$FLEET_HUB_PORT" \
    --handoff-dir "$FLEET_HANDOFFS" \
    --spool-inbox "$FLEET_SPOOL_INBOX" \
    > "$FLEET_STATE_DIR/run/fleet-hub.log" 2>&1 &
echo $! > "$FLEET_STATE_DIR/run/fleet-hub.pid"
sleep 0.5
if ! kill -0 "$(cat "$FLEET_STATE_DIR/run/fleet-hub.pid" 2>/dev/null)" 2>/dev/null; then
    echo "WARN: fleet-hub.py failed to start — dashboard may not work" >&2
fi
# Split vertical : bas = 60% (starfleet-fleet)
# --dangerously-skip-permissions: intentional for Tier 0 (starfleet has sudo, full fleet access)
_tmux split-window -v -l 60% -t "$SESSION:monitor"
_tmux send-keys -t "$SESSION:monitor.$((PBASE+1))" "sudo -i -u $ROLE_BOUNDARY_OS bash -c 'cd ~ && export FLEET_CONTEXT=fleet CLAUDE_AGENT_NAME=$ROLE_BOUNDARY_OS; exec claude --dangerously-skip-permissions --system-prompt-file ~/.claude/system-prompt.md'" Enter
_tmux select-pane -T "${ROLE_BOUNDARY_OS}-fleet" -t "$SESSION:monitor.$((PBASE+1))"
_tmux set-option -p -t "$SESSION:monitor.$((PBASE+1))" @fleet-role "$ROLE_BOUNDARY_OS"
# Pane PBASE   = haut (fleet-monitor)
# Pane PBASE+1 = bas (starfleet)
_tmux send-keys -t "$SESSION:monitor.$PBASE" "python3 \"$FLEET_DIR_RESOLVED/fleet-monitor.py\" --hub \"http://127.0.0.1:$FLEET_HUB_PORT\"" Enter
_tmux select-pane -t "$SESSION:monitor.$PBASE"

# ─── Template-specific layout ────────────────────────────────────────────────
case "$TEMPLATE" in

executive)
    # Window 2: agents — Tier 1 (left) | worker (right 50%)
    _tmux new-window -t "$SESSION:" -n "agents"
    _tmux send-keys -t "$SESSION:agents.$PBASE" "sudo -u $ROLE_TIER1 -i" Enter
    _tmux select-pane -T "$ROLE_TIER1" -t "$SESSION:agents.$PBASE"
    _tmux set-option -p -t "$SESSION:agents.$PBASE" @fleet-role "$ROLE_TIER1"
    _tmux split-window -h -l 50% -t "$SESSION:agents"
    _tmux send-keys -t "$SESSION:agents.$((PBASE+1))" "sudo -u $ROLE_WORKER -i" Enter
    _tmux select-pane -T "$ROLE_WORKER" -t "$SESSION:agents.$((PBASE+1))"
    _tmux set-option -p -t "$SESSION:agents.$((PBASE+1))" @fleet-role "$ROLE_WORKER"
    # Window 3: consultant (stateless, interactive)
    _tmux new-window -t "$SESSION:" -n "consultant"
    _tmux send-keys -t "$SESSION:consultant.$PBASE" \
        "sudo -i -u consultant bash -c 'export FLEET_CONTEXT=standalone CLAUDE_AGENT_NAME=consultant FLEET_LAUNCHED=1; exec claude --dangerously-skip-permissions --system-prompt-file ~/.claude/system-prompt.md'" Enter
    _tmux select-pane -T "consultant" -t "$SESSION:consultant.$PBASE"
    _tmux set-option -p -t "$SESSION:consultant.$PBASE" @fleet-role "consultant"
    # Window 4: terminal
    _tmux new-window -t "$SESSION:" -n "terminal"
    ;;

demo)
    # Minimal — monitor + terminal only. No agent panes for clean presentation.
    _tmux new-window -t "$SESSION:" -n "terminal"
    ;;

panoptique)
    # Single window — all agents tiled
    # Top row:    fleet-monitor (left) | engineer (right)
    # Bottom row: starfleet (left) | usage-monitor (mid) | worker (right-bottom)
    # Note: shared section already created PBASE (monitor), PBASE+1 (starfleet), PBASE+2 (usage-monitor)
    _tmux split-window -h -l 50% -t "$SESSION:monitor.$PBASE"
    _tmux send-keys -t "$SESSION:monitor.$((PBASE+3))" "sudo -u $ROLE_TIER1 -i" Enter
    _tmux select-pane -T "$ROLE_TIER1" -t "$SESSION:monitor.$((PBASE+3))"
    _tmux set-option -p -t "$SESSION:monitor.$((PBASE+3))" @fleet-role "$ROLE_TIER1"
    # Split engineer pane to get worker below
    _tmux split-window -v -l 50% -t "$SESSION:monitor.$((PBASE+3))"
    _tmux send-keys -t "$SESSION:monitor.$((PBASE+4))" "sudo -u $ROLE_WORKER -i" Enter
    _tmux select-pane -T "$ROLE_WORKER" -t "$SESSION:monitor.$((PBASE+4))"
    _tmux set-option -p -t "$SESSION:monitor.$((PBASE+4))" @fleet-role "$ROLE_WORKER"
    # terminal window still added for shell access
    _tmux new-window -t "$SESSION:" -n "terminal"
    ;;

esac

if [[ $ATTACH -eq 1 ]]; then
    _tmux attach-session -t "$SESSION:monitor"
fi
