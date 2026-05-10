#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: light_on.sh
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
#     | MODULE: LIGHT-ON        | SUBSYSTEM: FLEET / DISPLAY      |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Turns on the status light indicator.                     |
#     |  Sends ON signal to the physical or virtual LED.          |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#           ______________________________________________________
#          /          LCARS FLEET - FEDERATION DATABASE           \
#         |   ________   __________________________________________\
#         |  |  2026  |  | SOURCE: light_on.sh
#         |  |________|  | AUTHOR: LORDZURP
#         |   ________   | SYSTEM: LCARS-FLEET v5.4
#
#     [EN]
#     light_on.sh — Turns on the status light indicator.
#     Sends ON signal to the physical or virtual LED.
#
#
# --- END HEADER ---



# --help: extract [EN] section from this header
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && {
    sed -n '/^#     \[EN\]/,/^# --- END HEADER ---/{/\[EN\]/d; /END HEADER/d; s/^#     //; s/^#[[:space:]]*$//; p}' "$0"
    exit 0
}

set -euo pipefail

# --- Fleet env (reads fleet.yaml — already built at deploy/update time) ---
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/fleet-env.sh"

# --- Deploy gate --- #
DEPLOY_OK="$HOMES_ROOT/fleet-state/.deploy_ok"
if [ ! -f "$DEPLOY_OK" ]; then
    echo ""
    echo "=== FLEET BLOCKED — ONBOARDING REQUIRED ==="
    echo ""
    echo "La fleet ne peut pas démarrer : l'onboarding n'est pas terminé."
    echo "Les 3 barrières de sécurité n'ont pas encore été validées."
    echo ""
    echo "Lance l'onboarding en ouvrant une session StarFleet :"
    echo "  claude"
    echo ""
    echo "StarFleet te guidera à travers la configuration (≈ 10 min)."
    echo "Une fois l'onboarding terminé, relance : ~/start"
    echo ""
    echo "=== FIN ==="
    exit 1
fi

# --- Repo catalog update (silent, non-blocking) ---
KNOWN_REPOS="/home/private/known-repos.txt"
touch "$KNOWN_REPOS"
# Timeout: avoid blocking boot if network is slow/absent (WSL offline, VPN down)
GH_LOGIN=$(timeout 5 gh api user --jq '.login' 2>/dev/null || true)
if [ -n "$GH_LOGIN" ]; then
    NEW_REPOS=""
    while IFS=' ' read -r name url; do
        if ! grep -qF "$name" "$KNOWN_REPOS"; then
            echo "$name" >> "$KNOWN_REPOS"
            NEW_REPOS="${NEW_REPOS}  - ${name} (${url})\n"
        fi
    done < <(gh repo list "$GH_LOGIN" --json name,url --limit 100 2>/dev/null \
        | jq -r '.[] | .name + " " + .url')
    if [ -n "$NEW_REPOS" ]; then
        # Signal new repos via notify — content in the handoff notify field
        fleet-state.sh notify="architect: new repos detected" 2>/dev/null || true
        echo "[light_on] new repos detected — architect notified"
    fi
fi

SESSION="fleet"

# Lance la session fleet (windows + panes + workers WSL)
# Claude est démarré automatiquement sur chaque instance WSL via FLEET_AUTO_LAUNCH (.bashrc).
bash "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/fleet-launch.sh" --no-attach

# Attache sur le dashboard
fleet_tmux select-window -t "$SESSION:monitor"
fleet_tmux attach-session -t "$SESSION"
