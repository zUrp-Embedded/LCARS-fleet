#!/bin/bash
# DEPLOY: instance-util

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: lcars-test.sh
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
#     | MODULE: LCARS-TEST      | SUBSYSTEM: TMUX / UI            |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Layout réplique le monitor fleet.                        |
#     |                                                           |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     DEPLOY: instance-util
#
#           ______________________________________________________
#          /          LCARS FLEET - FEDERATION DATABASE           \
#         |   ________   __________________________________________\
#         |  |  2026  |  | SOURCE: lcars-test.sh
#         |  |________|  | AUTHOR: LORDZURP
#
#     [EN]
#     lcars-test.sh — Layout réplique le monitor fleet.
#
#
# --- END HEADER ---


set -euo pipefail

# --- Fleet env ---
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/fleet-env.sh"

CONF="$HOME/.tmux.lcars.conf"
SOCKET="lcars"
SESSION="lcars"
[[ -n "${FLEET_HANDOFFS:-}" ]] || { echo "FATAL: FLEET_HANDOFFS not set" >&2; exit 1; }
HANDOFF="${FLEET_HANDOFFS}"

if tmux -L "$SOCKET" has-session -t "$SESSION" 2>/dev/null; then
    echo "Session '$SESSION' déjà active — attach : tmux -L $SOCKET attach"
    tmux -L "$SOCKET" attach-session -t "$SESSION"
    exit 0
fi

# ── Window 1 : monitor — réplique layout fleet (3 panes) ─────────────────────
# Pane .1 (haut, pleine largeur) : fleet-monitor TUI
# Pane .2 (bas-gauche)           : watch-handoff architect
# Pane .3 (bas-droite)           : watch-handoff to-engineer
tmux -L "$SOCKET" -f "$CONF" new-session -d -s "$SESSION" -n "monitor"

# Découpe bas (17 lignes) → pane .2 devient actif
tmux -L "$SOCKET" split-window -v -l 17 -t "$SESSION:monitor"
tmux -L "$SOCKET" send-keys -t "$SESSION:monitor" \
    "$HOME/fleet/watch-handoff.sh $HANDOFF/architect-handoff.md" Enter

# Découpe bas-droite → pane .3
tmux -L "$SOCKET" split-window -h -t "$SESSION:monitor"
tmux -L "$SOCKET" send-keys -t "$SESSION:monitor" \
    "$HOME/fleet/watch-handoff.sh $HANDOFF/engineer-handoff.md" Enter

# Remonte sur le pane du haut → lance fleet-monitor
tmux -L "$SOCKET" select-pane -t "$SESSION:monitor" -U
tmux -L "$SOCKET" send-keys -t "$SESSION:monitor" \
    "htop" Enter

# ── Window 2 : terminal — shell nu ───────────────────────────────────────────
tmux -L "$SOCKET" new-window -t "$SESSION" -n "terminal"

# ── Window 3 : notes — 2 panes côte à côte ───────────────────────────────────
tmux -L "$SOCKET" new-window -t "$SESSION" -n "notes"
tmux -L "$SOCKET" send-keys -t "$SESSION:notes" \
    "$HOME/fleet/watch-handoff.sh $HANDOFF/starfleet-notes.md" Enter
tmux -L "$SOCKET" split-window -h -t "$SESSION:notes"
tmux -L "$SOCKET" send-keys -t "$SESSION:notes" \
    "$HOME/fleet/watch-handoff.sh $HANDOFF/project-refs.md" Enter
tmux -L "$SOCKET" select-layout -t "$SESSION:notes" even-horizontal

# ── Attach sur window 1 ───────────────────────────────────────────────────────
tmux -L "$SOCKET" select-window -t "$SESSION:monitor"
tmux -L "$SOCKET" attach-session -t "$SESSION:monitor"
