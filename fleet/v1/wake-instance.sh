#!/bin/bash
# DEPLOY: instance-util

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: wake-instance.sh
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
#     | MODULE: WAKE            | SUBSYSTEM: FLEET / IPC          |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Sends a wake signal to a fleet instance.                 |
#     |  v2: single-distro multi-user — tmux pane lookup.         |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     DEPLOY: instance-util
#
#           ______________________________________________________
#          /          LCARS FLEET - FEDERATION DATABASE           \
#         |   ________   __________________________________________\
#         |  |  2026  |  | SOURCE: wake-instance.sh
#         |  |________|  | AUTHOR: LORDZURP
#
#     [EN]
#     wake-instance.sh — Sends a wake signal to a fleet instance.
#     v2: single-distro multi-user — tmux pane lookup.
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

INSTANCE="${1:?usage: wake-instance.sh <instance> <subject>}"
# SEC-10: validate instance name (prevent yq injection)
[[ "$INSTANCE" =~ ^[a-z0-9_-]+$ ]] || { echo "ERROR: invalid instance name '$INSTANCE'" >&2; exit 1; }
# SEC-09: strip control chars + limit length to prevent prompt injection
SUBJECT=$(printf '%s' "${2:-wake}" | tr -cd '[:print:]' | head -c 200)

readonly INSTANCE SUBJECT
WAKE_NOTIFY="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/fleet-wake-notify.sh"
ALERT_SCRIPT="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/fleet-alert.sh"
readonly WAKE_NOTIFY ALERT_SCRIPT

# --- Non-wakeable agents → visual alert only (gyrophare) ---
_WAKEABLE=$(yq ".instances[] | select(.role == \"$INSTANCE\") | .wakeable" "$FLEET_YAML" 2>/dev/null)
[[ "$_WAKEABLE" == "null" || -z "$_WAKEABLE" ]] && _WAKEABLE="true"
if [[ "$_WAKEABLE" == "false" ]]; then
    if [ -x "$ALERT_SCRIPT" ]; then
        "$ALERT_SCRIPT" "$INSTANCE" &
    fi
    echo "OK: $INSTANCE — non-wakeable, gyrophare started" >&2
    exit 0
fi

# --- Headless agents → no pane, no wake, dispatched on-demand ---
_HAS_HEADLESS=$(yq ".instances[] | select(.role == \"$INSTANCE\") | .headless" "$FLEET_YAML" 2>/dev/null)
# A-007 fix: headless: false is string "false", not null/empty
if [[ "$_HAS_HEADLESS" != "null" && "$_HAS_HEADLESS" != "false" && -n "$_HAS_HEADLESS" ]]; then
    exit 0
fi

# tmux socket access: tmux 3.4 enforces UID == socket owner.
# Agents running as non-owner must sudo to the owner.
_TMUX_OWNER=$(stat -c '%U' "$FLEET_TMUX_SOCK" 2>/dev/null || echo "$FLEET_USER")
if [[ "$(whoami)" != "$_TMUX_OWNER" ]]; then
    _tmux() { sudo -u "$_TMUX_OWNER" tmux "$@"; }
else
    _tmux() { tmux "$@"; }
fi

# --- Resolve pane: fleet mode (@fleet-role) then standalone (session name) ---
PANE_ID="$(fleet_find_pane "$INSTANCE")"
PANE_MODE="fleet"

if [ -z "$PANE_ID" ]; then
    # Fallback: standalone session named after the agent
    if _tmux has-session -t "$INSTANCE" 2>/dev/null; then
        PANE_ID=$(_tmux list-panes -t "$INSTANCE" \
            -F '#{pane_id}' 2>/dev/null | head -1)
        PANE_MODE="standalone"
    fi
fi

if [ -z "$PANE_ID" ]; then
    echo "INFO: $INSTANCE — no tmux pane, message in spool" >&2
    if [ -x "$WAKE_NOTIFY" ]; then
        "$WAKE_NOTIFY" "$INSTANCE" "$SUBJECT" < /dev/null || true
    fi
    exit 0
fi

# --- Standalone session → gyrophare instead of wake injection ---
if [[ "$PANE_MODE" == "standalone" ]]; then
    if [ -x "$ALERT_SCRIPT" ]; then
        "$ALERT_SCRIPT" "$INSTANCE" &
    fi
    echo "OK: $INSTANCE — standalone session, gyrophare started" >&2
    exit 0
fi

# --- Ensure claude is running in the pane ---
LINUX_USER=$(fleet_role_field "$INSTANCE" "linux_user" 2>/dev/null)
[[ -z "$LINUX_USER" || "$LINUX_USER" == "null" ]] && LINUX_USER="$INSTANCE"

CURRENT_CMD=$(_tmux display-message -t "$PANE_ID" -p "#{pane_current_command}" 2>/dev/null || echo "unknown")

# Poll-based wait for claude process (replaces hardcoded sleep)
_wait_for_claude() {
    local user="$1" max_wait="$2" elapsed=0
    while (( elapsed < max_wait )); do
        pgrep -u "$user" -f "^claude " > /dev/null 2>&1 && return 0
        sleep 1
        elapsed=$(( elapsed + 1 ))
    done
    return 1
}

if [[ "$CURRENT_CMD" == "sudo" ]] && ! pgrep -u "$LINUX_USER" -f "^claude " > /dev/null 2>&1; then
    echo "INFO: pane $PANE_ID — sudo initializing, polling..." >&2
    _wait_for_claude "$LINUX_USER" 10 || echo "WARN: claude not detected after 10s" >&2
fi

if ! pgrep -u "$LINUX_USER" -f "^claude " > /dev/null 2>&1; then
    # Only inject claude --resume if pane is running a shell (not vim, less, etc.)
    if [[ "$CURRENT_CMD" =~ ^(bash|zsh|sh|sudo)$ ]]; then
        echo "INFO: $INSTANCE — claude absent — resuming" >&2
        _tmux send-keys -t "$PANE_ID" "claude --resume" Enter
        _wait_for_claude "$LINUX_USER" 15 || echo "WARN: claude not detected after resume (15s timeout)" >&2
    else
        echo "WARN: $INSTANCE — claude absent, pane running '$CURRENT_CMD' (not a shell) — skipping resume" >&2
    fi
fi

# AUDIT-013: trust dialog should be pre-accepted via settings.json hasTrustDialogAccepted.
# If it appears at runtime, it means deploy missed the agent. Log as warning, still accept
# (blocking the wake would leave the agent stuck).
pane_content=$(_tmux capture-pane -t "$PANE_ID" -p 2>/dev/null || true)
if printf '%s' "$pane_content" | grep -q "trust this folder"; then
    echo "WARN: trust dialog detected on $PANE_ID — settings.json may be missing hasTrustDialogAccepted. Auto-accepting." >&2
    _tmux send-keys -t "$PANE_ID" Enter
    sleep 1
fi

# --- Inject [FLEET-INBOX] sentinel via fleet-wake-notify.sh ---
# Guard: only inject sentinel if claude is actually running in the pane
if pgrep -u "$LINUX_USER" -f "^claude " > /dev/null 2>&1; then
    CALLER=$(whoami)
    if [ -x "$WAKE_NOTIFY" ]; then
        "$WAKE_NOTIFY" "$INSTANCE" "$SUBJECT" < /dev/null || \
            _tmux send-keys -l -t "$PANE_ID" "FLEET::WAKE::${CALLER}::${SUBJECT}
"
    else
        _tmux send-keys -l -t "$PANE_ID" "FLEET::WAKE::${CALLER}::${SUBJECT}
"
    fi
    echo "OK: $INSTANCE — wake sent (pane $PANE_ID, from $CALLER)" >&2
else
    echo "WARN: $INSTANCE — claude not running, sentinel not injected" >&2
fi
