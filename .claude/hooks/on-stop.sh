#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: on-stop.sh
#     |  |________|  | AUTHOR: LORDZURP
#     |   ________   | SYSTEM: LCARS-FLEET v5.4
#     |  |  v5.4  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS-FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: ON-STOP         | SUBSYSTEM: HOOKS / LIFECYCLE    |
#     | LICENSE: AGPL-3         | STARDATE: 2026.090              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Writes action=shutdown status=done on clean exit.        |
#     |  Fires on Stop event — NOT on crash or WSL reboot.        |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     Écrit action=shutdown status=done à l'arrêt propre. Log la durée de session.
#     Nettoyage sentinels.
#
#     [EN]
#     NAME
#         on-stop.sh — clean shutdown: update handoff state and log session duration
#
#     INTERFACE
#         Ring:    CC Runtime (hook — Stop)
#         Input:   stdin JSON (drained), CLAUDE_AGENT_NAME, handoff
#         Output:  fleet-state.sh shutdown, session-log
#
#     EXIT CODES
#         0    Always
#
# --- END HEADER ---

set -euo pipefail

# Drain stdin (Stop hook sends JSON payload)
cat > /dev/null

INSTANCE_NAME="${CLAUDE_AGENT_NAME:-$(cat "$HOME/.claude/instance-name" 2>/dev/null)}"
[ -z "$INSTANCE_NAME" ] && exit 0

if [ -x "${HOME}/.local/bin/fleet-state.sh" ]; then
    "${HOME}/.local/bin/fleet-state.sh" phase=shutdown activity=—
fi

# Source fleet-env for paths (fleet-state.sh may not be in PATH yet on first run)
_FLEET_ENV=""
[ -x "$HOME/.local/bin/fleet-env.sh" ] && _FLEET_ENV="$HOME/.local/bin/fleet-env.sh"
[ -z "$_FLEET_ENV" ] && [ -f "$HOME/fleet/fleet-env.sh" ] && _FLEET_ENV="$HOME/fleet/fleet-env.sh"
if [ -n "$_FLEET_ENV" ]; then
    # shellcheck source=/dev/null
    source "$_FLEET_ENV" 2>/dev/null || true

    # v7 Phase 4d — commit + push worktree on stop
    for _wt in /home/projects.work/*/; do
        [ -d "$_wt/.git" ] || [ -f "$_wt/.git" ] || continue
        (
            flock -n 200 || exit 0  # skip if another agent is committing
            cd "$_wt" || exit 0
            git add -A 2>/dev/null || true
            if ! git diff --cached --quiet 2>/dev/null; then
                git commit -m "${INSTANCE_NAME:-unknown} | session-end | $(date '+%Y-%m-%d %H:%M')" 2>/dev/null || true
            fi
            git pull --rebase origin work/ops 2>/dev/null || true
            git push origin work/ops 2>/dev/null || true
        ) 200>"$_wt/fleet-commit.lock"
    done
fi

exit 0
