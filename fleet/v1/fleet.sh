#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet.sh
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
#     | MODULE: FLEET             | SUBSYSTEM: CLI / ENTRYPOINT   |
#     | LICENSE: AGPL-3           | STARDATE: 2026.090            |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Unified fleet CLI. Entry point for all fleet operations. |
#     |  `fleet` = status. `fleet <cmd>` = dispatch.              |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     Point d'entrée unifié de la fleet. Sans argument : état + commandes.
#     Avec argument : dispatch vers la sous-commande.
#
#     [EN]
#     NAME
#         fleet — unified fleet CLI
#
#     SYNOPSIS
#         fleet              status + available commands
#         fleet up           launch fleet dashboard (tmux)
#         fleet down         stop fleet dashboard
#         fleet arch         launch architect standalone
#         fleet sf           launch starfleet standalone
#         fleet codex        launch codex (external agent)
#         fleet consultant   launch consultant (ephemeral)
#         fleet update       pull + provision + deploy
#         fleet doctor       diagnostics
#         fleet status       worker status only
#
#     INTERFACE
#         Ring:    4 (support)
#         Input:   fleet-env.sh, handoff files, tmux state
#         Output:  formatted status + command list
#         JSON:    non
#
# --- END HEADER ---

set -euo pipefail

FLEET_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

# --- Resolve fleet-env for status display ---
FLEET_ENV="$FLEET_DIR/fleet-env.sh"
if [ -f "$FLEET_ENV" ]; then
    # shellcheck source=/dev/null
    source "$FLEET_ENV"
fi

# --- Colors ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Status display ---
show_status() {
    local version
    version=$(yq '.fleet.version' "$FLEET_YAML" 2>/dev/null || echo "?")

    printf "\n${BOLD}  LCARS Fleet v%s${NC}\n" "$version"
    printf "  %-20s %s\n" "Runtime:" "$(git -C "${LCARS_ROOT:-/local/LCARS}" log --oneline -1 2>/dev/null || echo '?')"
    printf "  %-20s %s\n" "Socket:" "${FLEET_TMUX_SOCK:-?}"
    printf "\n"

    # Worker status from handoffs
    printf "  ${BOLD}%-14s %-10s %-8s %s${NC}\n" "AGENT" "STATUS" "ACTION" "LAST UPDATE"
    printf "  %-14s %-10s %-8s %s\n" "─────────────" "─────────" "───────" "───────────"

    if [ -d "${FLEET_HANDOFFS}" ]; then
        for hf in "${FLEET_HANDOFFS}"/*-handoff.md; do
            [ -f "$hf" ] || continue
            local agent status action date_line
            agent=$(basename "$hf" | sed 's/-handoff\.md//')
            status=$(grep '^status:' "$hf" 2>/dev/null | head -1 | sed 's/status: *//')
            action=$(grep '^action:' "$hf" 2>/dev/null | head -1 | sed 's/action: *//')
            date_line=$(grep '^date:' "$hf" 2>/dev/null | head -1 | sed 's/date: *//')

            # Color based on status
            local color="$NC"
            case "$status" in
                *online*|*in-progress*|*idle*|*done*) color="$GREEN" ;;
                *offline*)                             color="$RED" ;;
                *blocked*|*waiting*)                    color="$YELLOW" ;;
            esac

            printf "  %-14s ${color}%-10s${NC} %-8s %s\n" "$agent" "${status:-?}" "${action:-?}" "${date_line:-?}"
        done
    else
        printf "  ${RED}(no handoffs directory)${NC}\n"
    fi
    printf "\n"
}

# --- Commands display ---
show_commands() {
    printf "  ${BOLD}COMMANDS${NC}\n"
    printf "  %-22s %s\n" "fleet" "this screen"
    printf "  %-22s %s\n" "fleet up [--template T]" "launch dashboard (tmux)"
    printf "  %-22s %s\n" "fleet down" "stop dashboard"
    printf "  %-22s %s\n" "fleet arch" "architect standalone"
    printf "  %-22s %s\n" "fleet sf" "starfleet standalone"
    printf "  %-22s %s\n" "fleet codex" "codex (external agent)"
    printf "  %-22s %s\n" "fleet consultant" "consultant (ephemeral)"
    printf "  %-22s %s\n" "fleet update [--force]" "pull + provision + deploy"
    printf "  %-22s %s\n" "fleet doctor [--check]" "diagnostics"
    printf "  %-22s %s\n" "fleet status" "worker status only"
    printf "  %-22s %s\n" "fleet restart" "stop + start dashboard"
    printf "\n"
}

# --- Dispatch ---
case "${1:-}" in
    ""|help|-h|--help)
        show_status
        show_commands
        ;;
    status)
        show_status
        ;;
    up|start)
        shift
        exec bash "$FLEET_DIR/light_on.sh" "$@"
        ;;
    down|stop)
        shift
        exec bash "$FLEET_DIR/light_off.sh" "$@"
        ;;
    arch|architect)
        exec bash "$FLEET_DIR/fleet-arch.sh"
        ;;
    sf|starfleet)
        exec bash "$FLEET_DIR/fleet-sf.sh"
        ;;
    codex)
        exec bash "$FLEET_DIR/toolbox/fleet-codex.sh"
        ;;
    consultant)
        exec bash "$FLEET_DIR/toolbox/fleet-consultant.sh"
        ;;
    update)
        shift
        exec sudo bash "$FLEET_DIR/fleet-update.sh" "$@"
        ;;
    doctor)
        shift
        exec bash "$FLEET_DIR/fleet-doctor.sh" "$@"
        ;;
    restart)
        exec bash "$FLEET_DIR/fleet-restart.sh"
        ;;
    *)
        # Try fleet-<cmd>.sh
        CMD="$FLEET_DIR/fleet-${1}.sh"
        if [ -x "$CMD" ]; then
            shift
            exec bash "$CMD" "$@"
        fi
        # Try toolbox/fleet-<cmd>.sh
        CMD="$FLEET_DIR/toolbox/fleet-${1}.sh"
        if [ -x "$CMD" ]; then
            shift
            exec bash "$CMD" "$@"
        fi
        echo "ERROR: unknown command '$1'" >&2
        echo "  Run 'fleet' for available commands." >&2
        exit 1
        ;;
esac
