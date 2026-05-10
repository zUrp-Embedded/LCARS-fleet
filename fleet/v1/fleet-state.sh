#!/bin/bash
# DEPLOY: instance-util

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-state.sh
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
#     | MODULE: STATE-MANAGER   | SUBSYSTEM: FLEET / HANDOFF      |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Updates STATE fields in the active handoff.              |
#     |  Handles: action, status, blocker, ref, waiting.          |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     DEPLOY: instance-util
#
#           ______________________________________________________
#          /          LCARS FLEET - FEDERATION DATABASE           \
#         |   ________   __________________________________________\
#         |  |  2026  |  | SOURCE: fleet-state.sh
#         |  |________|  | AUTHOR: LORDZURP
#
#     [EN]
#     fleet-state.sh — Updates STATE fields in the active handoff.
#     Handles: action, status, blocker, ref, waiting.
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

# Guard : ne publier sur le dashboard que depuis une session fleet.
# FLEET_SESSION=1 est exporté par .bashrc sur toutes les instances fleet,
# sauf les terminaux VS Code (TERM_PROGRAM=vscode).
# Évite qu'une session hors-flotte écrase l'état.
[[ -n "${FLEET_SESSION:-}" ]] || exit 0

[[ $# -eq 0 ]] && { echo "usage: fleet-state.sh key=value [key=value ...]" >&2; exit 1; }

INSTANCE="${FLEET_INSTANCE:-$(hostname)}"
FILE="$FLEET_HANDOFFS/${INSTANCE}-handoff.md"
readonly INSTANCE FILE

# Cleanup tmp file on interrupt (write-tmp-then-mv pattern)
trap 'rm -f "${FILE}.tmp" 2>/dev/null' INT TERM EXIT

if [[ ! -f "$FILE" ]]; then
    mkdir -p "$(dirname "$FILE")"
    printf '## STATE\ndate: %s\nref: none\naction: idle\nstatus: pending\nblocker: none\nwaiting: none\nnotify: none\n\n## ACTIONS\n\n## DONE\n### %s — auto-created\nHandoff auto-created by fleet-state.sh (first run).\n' \
        "$(date '+%Y-%m-%d %H:%M')" "$(date '+%Y-%m-%d')" > "$FILE"
    echo "[fleet-state] created $FILE" >&2
fi
grep -q "^## STATE" "$FILE" || { echo "WARNING: section '## STATE' absente dans $FILE — mise à jour ignorée" >&2; exit 0; }

DATE=$(date '+%Y-%m-%d %H:%M')

# LLB-001 fix: scope sed substitutions to ## STATE block only
# Prevents accidental rewrite of date:/action:/status: in DONE or body sections
readonly SED_SCOPE='/^## STATE$/,/^## [A-Z]/'
UPDATES=("${SED_SCOPE}s|^date:.*|date: ${DATE}|")
LOG_ACTION=""
LOG_STATUS=""

for ARG in "$@"; do
    KEY="${ARG%%=*}"
    VAL="${ARG#*=}"
    case "$KEY" in
        # v7 #02: phase/activity are the canonical fields. action/status kept as aliases.
        phase)
            VAL_ESC="${VAL//\\/\\\\}"; VAL_ESC="${VAL_ESC//&/\\&}"; VAL_ESC="${VAL_ESC//|/\\|}"
            UPDATES+=("${SED_SCOPE}s|^action:.*|action: ${VAL_ESC}|")
            LOG_ACTION="$VAL"
            ;;
        activity)
            VAL_ESC="${VAL//\\/\\\\}"; VAL_ESC="${VAL_ESC//&/\\&}"; VAL_ESC="${VAL_ESC//|/\\|}"
            UPDATES+=("${SED_SCOPE}s|^status:.*|status: ${VAL_ESC}|")
            LOG_STATUS="$VAL"
            ;;
        action|status|blocker|ref|waiting|notify|session)
            VAL_ESC="${VAL//\\/\\\\}"; VAL_ESC="${VAL_ESC//&/\\&}"; VAL_ESC="${VAL_ESC//|/\\|}"
            UPDATES+=("${SED_SCOPE}s|^${KEY}:.*|${KEY}: ${VAL_ESC}|")
            [[ "$KEY" == "action" ]] && LOG_ACTION="$VAL"
            [[ "$KEY" == "status" ]] && LOG_STATUS="$VAL"
            ;;
        *)
            echo "WARNING: champ '${KEY}' inconnu (ignoré)" >&2
            ;;
    esac
done

SED_ARGS=()
for U in "${UPDATES[@]}"; do
    SED_ARGS+=(-e "$U")
done

# JUPITER-008: flock on handoff file
(
    flock -w 10 200 || { echo "ERROR: lock on $FILE" >&2; exit 1; }
    sed "${SED_ARGS[@]}" "$FILE" > "${FILE}.tmp" && mv -f "${FILE}.tmp" "$FILE"
) 200>"${FILE}.lock"

# Log action/status transitions
if [[ -n "${LOG_ACTION:-}${LOG_STATUS:-}" ]]; then
    LOG_DIR="$FLEET_LOGS"
    mkdir -p "$LOG_DIR"
    LOG_MSG="${DATE} | ${INSTANCE} | ${LOG_ACTION:+action=${LOG_ACTION} }${LOG_STATUS:+status=${LOG_STATUS}}"
    LOG_FILE="${LOG_DIR}/fleet-state.log"
    echo "${LOG_MSG% }" >> "$LOG_FILE"
    chmod 664 "$LOG_FILE" 2>/dev/null || true
fi

# Session duration log (#18) — triggered on handoff or offline action
if [[ "${LOG_ACTION:-}" == "handoff" || "${LOG_STATUS:-}" == "offline" ]]; then
    SESSION_LOG_BIN="$(fleet_bin fleet-session-log.sh)"
    if [[ -n "$SESSION_LOG_BIN" ]]; then
        "$SESSION_LOG_BIN" "${LOG_ACTION:-offline}" 2>/dev/null || true
    fi
fi

echo ">>> ${INSTANCE} STATE: $*  date=${DATE}"
