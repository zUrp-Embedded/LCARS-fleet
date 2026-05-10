#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: light_off.sh
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
#     | MODULE: LIGHT-OFF       | SUBSYSTEM: FLEET / DISPLAY      |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Turns off the status light indicator.                    |
#     |  Sends OFF signal to the physical or virtual LED.         |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#           ______________________________________________________
#          /          LCARS FLEET - FEDERATION DATABASE           \
#         |   ________   __________________________________________\
#         |  |  2026  |  | SOURCE: light_off.sh
#         |  |________|  | AUTHOR: LORDZURP
#         |   ________   | SYSTEM: LCARS-FLEET v5.4
#
#     [EN]
#     light_off.sh — Turns off the status light indicator.
#     Sends OFF signal to the physical or virtual LED.
#
#
# --- END HEADER ---



# --help: extract [EN] section from this header
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && {
    sed -n '/^#     \[EN\]/,/^# --- END HEADER ---/{/\[EN\]/d; /END HEADER/d; s/^#     //; s/^#[[:space:]]*$//; p}' "$0"
    exit 0
}

set -euo pipefail

# shellcheck source=fleet-env.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/fleet-env.sh"

SESSION="fleet"
HANDOFF="$FLEET_HANDOFFS"
HANDOFF_TIMEOUT=120  # secondes max pour attendre status: offline

mapfile -t WORKERS < <(fleet_roles)

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

# ─── Helpers ────────────────────────────────────────────────────────────────

get_status() {
    local file="$HANDOFF/${1}-handoff.md"
    [ -f "$file" ] || { echo "offline"; return; }
    grep -m1 "^status:" "$file" | awk '{print $2}'
}

get_action() {
    local file="$HANDOFF/${1}-handoff.md"
    [ -f "$file" ] || { echo "offline"; return; }
    grep -m1 "^action:" "$file" | awk '{print $2}'
}

# Écrit forced shutdown dans les handoffs des workers sans arrêt propre
stamp_forced_shutdown() {
    local date_str
    date_str=$(date '+%Y-%m-%d %H:%M')
    for w in "${WORKERS[@]}"; do
        local file="$HANDOFF/${w}-handoff.md"
        [ -f "$file" ] || continue
        local act
        act=$(get_action "$w")
        if [[ "$act" != "shutdown" && "$act" != "forced shutdown" && "$act" != "handoff" ]]; then
            # LLB-007 fix: scope sed to ## STATE block only
            local tmp="${file}.tmp"
            sed '/^## STATE$/,/^## [A-Z]/{s|^action:.*|action: forced shutdown|;s|^date:.*|date: '"${date_str}"'|}' "$file" > "$tmp" && mv -f "$tmp" "$file"
        fi
    done
}

# ─── Session ────────────────────────────────────────────────────────────────

if ! fleet_tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "Session '$SESSION' absente — rien à arrêter."
    exit 0
fi

# H7-FIX: find panes by @fleet-role property (set by fleet-launch.sh), not by index or window name
declare -A WORKER_PANE
while IFS=$'\t' read -r pane_id role_prop; do
    [[ -n "$role_prop" && "$role_prop" != "" ]] && WORKER_PANE["$role_prop"]="$pane_id"
done < <(fleet_tmux list-panes -a -t "$SESSION" -F "#{pane_id}	#{@fleet-role}" 2>/dev/null)

# ─── Vérification statuts ───────────────────────────────────────────────────

if [ "$FORCE" -eq 0 ]; then
    NOT_OFFLINE=()
    for worker in "${WORKERS[@]}"; do
        status=$(get_status "$worker")
        [ "$status" != "offline" ] && NOT_OFFLINE+=("$worker  [status: $status]")
    done

    if [ "${#NOT_OFFLINE[@]}" -gt 0 ]; then
        echo "⚠  Workers non-offline :"
        for w in "${NOT_OFFLINE[@]}"; do echo "   $w"; done
        echo ""
        echo "  [h] Envoyer /handoff aux workers concernés (attente max ${HANDOFF_TIMEOUT}s)"
        echo "  [f] Forcer l'arrêt immédiat"
        echo "  [q] Annuler"
        read -r -p "Choix [h/f/q] : " choice

        case "$choice" in
            h|H)
                for worker in "${WORKERS[@]}"; do
                    status=$(get_status "$worker")
                    if [ "$status" != "offline" ]; then
                        pane="${WORKER_PANE[$worker]:-}"
                        if [ -z "$pane" ]; then
                            echo "⚠ $worker non-offline mais pas de pane tmux — skip"
                            continue
                        fi
                        echo "→ /handoff → $worker"
                        fleet_tmux send-keys -t "$pane" "/handoff" Enter
                    fi
                done

                echo -n "Attente"
                elapsed=0
                all_offline=1
                while [ "$elapsed" -lt "$HANDOFF_TIMEOUT" ]; do
                    sleep 5
                    elapsed=$((elapsed + 5))
                    echo -n "."
                    all_offline=1
                    for worker in "${WORKERS[@]}"; do
                        [ "$(get_status "$worker")" != "offline" ] && all_offline=0 && break
                    done
                    [ "$all_offline" -eq 1 ] && break
                done
                echo ""

                if [ "$all_offline" -eq 0 ]; then
                    echo "Timeout — workers toujours actifs :"
                    for worker in "${WORKERS[@]}"; do
                        status=$(get_status "$worker")
                        [ "$status" != "offline" ] && echo "  - $worker (status: $status)"
                    done
                    read -r -p "Forcer quand même ? [o/n] : " force_anyway
                    if [[ "$force_anyway" != "o" && "$force_anyway" != "O" ]]; then
                        echo "Arrêt annulé."
                        exit 1
                    fi
                    stamp_forced_shutdown
                fi
                ;;
            f|F)
                echo "Arrêt forcé."
                stamp_forced_shutdown
                ;;
            *)
                echo "Arrêt annulé."
                exit 1
                ;;
        esac
    fi
fi

# ─── Arrêt ──────────────────────────────────────────────────────────────────

# Forcer les handoffs sans arrêt propre (--force ou timeout)
[ "$FORCE" -eq 1 ] && stamp_forced_shutdown

# v7: commit + push all worktrees before killing the session
for _wt in /home/projects.work/*/; do
    [ -d "$_wt/.git" ] || [ -f "$_wt/.git" ] || continue
    (
        cd "$_wt" || continue
        git add -A 2>/dev/null || true
        if ! git diff --cached --quiet 2>/dev/null; then
            git commit -m "fleet-down | $(date '+%Y-%m-%d %H:%M')" --quiet 2>/dev/null || true
        fi
        git push origin work/ops --quiet 2>/dev/null && echo "  worktree $(basename "$_wt") pushed" || echo "  worktree $(basename "$_wt") push failed"
    )
done

fleet_tmux kill-session -t "$SESSION"
echo "Session '$SESSION' terminée."

# Arrêt propre de fleet-hub.py
_HUB_PID_FILE="${FLEET_STATE_DIR:-/home/fleet-state}/run/fleet-hub.pid"
if [ -f "$_HUB_PID_FILE" ]; then
    HUB_PID="$(cat "$_HUB_PID_FILE")"
    if kill -0 "$HUB_PID" 2>/dev/null; then
        kill "$HUB_PID" 2>/dev/null || true
        echo "fleet-hub (PID $HUB_PID) arrêté."
    fi
    rm -f "$_HUB_PID_FILE"
else
    pkill -f "fleet-hub.py" 2>/dev/null || true
fi

# Purge ACTIONS après kill — fleet-monitor déjà mort, aucun wake dispatché
if command -v fleet-shutdown-clean.sh > /dev/null 2>&1; then
    fleet-shutdown-clean.sh || true
elif [ -x "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/fleet-shutdown-clean.sh" ]; then
    bash "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/fleet-shutdown-clean.sh" || true
fi
