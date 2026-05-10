#!/bin/bash
# DEPLOY: instance-util

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-wake-notify.sh
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
#     | MODULE: WAKE-NOTIFY     | SUBSYSTEM: IPC / WAKE           |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Unified wake primitive.                                  |
#     |  Looks up agent pane by tmux title (dynamic resolution).  |
#     |  If found: injects [FLEET-INBOX] sentinel into pane.      |
#     |  If absent: writes .wake file to pending-wakes spool.     |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     Primitive de réveil unifiée. Résolution dynamique par titre de pane tmux.
#     Si pane trouvé : injecte [FLEET-INBOX]. Si absent : écrit un .wake file.
#     Agents non-wakeable (architect) : alerte visuelle seulement.
#
#     [EN]
#     NAME
#         fleet-wake-notify.sh — unified wake primitive with dynamic pane resolution
#
#     SYNOPSIS
#         fleet-wake-notify.sh <agent> [subject]
#
#     DESCRIPTION
#         Resolves the agent's tmux pane by title (fleet_find_pane from
#         fleet-env.sh). If found, injects [FLEET-INBOX] sentinel into the
#         pane to trigger inbox processing. If not found, writes a .wake
#         file to pending-wakes spool for later pickup. Non-wakeable agents
#         (architect) receive a visual gyrophare alert only — no sentinel
#         injection. Pane title convention: each tmux pane is titled with
#         the agent name via `select-pane -T` at launch.
#
#     INTERFACE
#         Ring:    1 (support)
#         Input:   agent name, tmux pane titles, fleet.yaml (wakeable flag)
#         Output:  [FLEET-INBOX] sentinel to pane, or .wake file in pending-wakes
#         JSON:    non
#
#     OPTIONS
#         agent     Target agent name (required)
#         subject   Wake reason (default: "wake"). Sanitized for filename.
#
#     EXIT CODES
#         0    Wake sent (pane injection or pending write or non-wakeable alert)
#         1    Missing agent argument
#
#     EXAMPLES
#         fleet-wake-notify.sh engineer "new-message"
#         fleet-wake-notify.sh dev spool-event
#
#     SEE ALSO
#         wake-instance.sh, fleet-alert.sh, fleet-inbox-read.sh, fleet-env.sh
#
# --- END HEADER ---

# --help: extract [EN] section from this header
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && {
    sed -n '/^#     \[EN\]/,/^# --- END HEADER ---/{/\[EN\]/d; /END HEADER/d; s/^#     //; s/^#[[:space:]]*$//; p}' "$0"
    exit 0
}

set -uo pipefail

AGENT="${1:?usage: fleet-wake-notify.sh <agent> [subject]}"
SUBJECT="${2:-wake}"

# Source fleet-env for FLEET_PENDING_WAKES, FLEET_TMUX_SOCK
FLEET_ENV="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/fleet-env.sh"
[ -f "$FLEET_ENV" ] && source "$FLEET_ENV"

TMUX_SOCK="${FLEET_TMUX_SOCK:-/tmp/tmux-$(id -u)/default}"
PENDING_WAKES_DIR="${FLEET_PENDING_WAKES:-/var/spool/fleet/pending-wakes}/$AGENT"

# --- Resolve pane by title (fleet_find_pane from fleet-env.sh) ---
PANE_ID="$(fleet_find_pane "$AGENT")"

    # Non-wakeable agents (architect) — visual alert only, no prompt injection
    _WAKEABLE=$(yq ".instances[] | select(.role == \"$AGENT\") | .wakeable" "$FLEET_YAML" 2>/dev/null)
    [[ "$_WAKEABLE" == "null" || -z "$_WAKEABLE" ]] && _WAKEABLE="true"
    if [[ "$_WAKEABLE" == "false" ]]; then
        ALERT_SCRIPT="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/fleet-alert.sh"
        if [ -x "$ALERT_SCRIPT" ]; then
            "$ALERT_SCRIPT" "$AGENT" &
            echo "[wake-notify] $AGENT: non-wakeable — gyrophare started" >&2
        else
            echo "[wake-notify] $AGENT: non-wakeable — fleet-alert.sh not found" >&2
        fi
        exit 0
    fi

if [ -n "$PANE_ID" ]; then
    # Pane found — inject [FLEET-INBOX] sentinel
    if [ -S "$TMUX_SOCK" ]; then
        fleet_tmux send-keys -t "$PANE_ID" "[FLEET-INBOX]" Enter 2>/dev/null || true
    else
        tmux send-keys -t "$PANE_ID" "[FLEET-INBOX]" Enter 2>/dev/null || true
    fi
    echo "[wake-notify] $AGENT: [FLEET-INBOX] sent to pane $PANE_ID" >&2
else
    # Pane not found — write pending wake
    mkdir -p "$PENDING_WAKES_DIR"
    TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
    SAFE_SUBJECT="$(printf '%s' "$SUBJECT" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd '[:alnum:]-')"
    WAKE_FILE="$PENDING_WAKES_DIR/${TIMESTAMP}-${SAFE_SUBJECT}.wake"
    # AUDIT-020: atomic write via temp+rename
    _WAKE_TMP="${WAKE_FILE}.tmp.$$"
    printf 'Wake-at: %s\nAgent: %s\nSubject: %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$AGENT" "$SUBJECT" > "$_WAKE_TMP"
    mv -f "$_WAKE_TMP" "$WAKE_FILE"
    chmod 660 "$WAKE_FILE" 2>/dev/null || true
    chgrp fleet "$WAKE_FILE" 2>/dev/null || true
    echo "[wake-notify] $AGENT offline — pending wake written: $(basename "$WAKE_FILE")" >&2
fi
