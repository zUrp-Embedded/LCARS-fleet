#!/bin/bash
# DEPLOY: instance-util
#
#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-inbox-read.sh
#     |  |________|  | AUTHOR: LORDZURP
#     |   ________   | SYSTEM: LCARS-FLEET v5.4
#     |  |  v5.4  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: INBOX-READ      | SUBSYSTEM: IPC / SPOOL          |
#     | LICENSE: AGPL-3         | STARDATE: 2026.090.6             |
#     +-------------------------+---------------------------------+
#
# CALLED BY   : on-prompt.sh (sentinel), session-startup.sh
# WHY         : Drain du spool inbox vers le contexte agent
#
#
#     [FR]
#     Lecture et consommation des messages spool inbox. Auto-ACK PING.
#
#     [EN]
#     NAME
#         fleet-inbox-read.sh — read and consume spool inbox messages
#
#     SYNOPSIS
#         fleet-inbox-read.sh <instance-name>
#
#     DESCRIPTION
#         Drains /var/spool/fleet/inbox/<instance>/*.md chronologically.
#         Per message: outputs to stdout, moves to .consumed/ (flock atomic),
#         writes .ack for delivery verification. Auto-ACKs PING subjects.
#         Called by session-startup.sh (boot) and on-prompt.sh (sentinel).
#
#     INTERFACE
#         Ring:    1 (kernel)
#         Input:   $FLEET_SPOOL_INBOX/<instance>/*.md (YAML-enveloped messages)
#         Output:  stdout (message content), .consumed/ (moved files), .ack files
#         JSON:    non
#
#     OPTIONS
#         <instance-name>    Role name to drain inbox for
#
#     EXIT CODES
#         0    Inbox empty or drained successfully
#
#     EXAMPLES
#         fleet-inbox-read.sh starfleet
#         fleet-inbox-read.sh dev
#
#     SEE ALSO
#         fleet-send.sh, wake-instance.sh, on-prompt.sh, session-startup.sh
#
# --- END HEADER ---

# --help: extract [EN] section from this header
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && {
    sed -n '/^#     \[EN\]/,/^# --- END HEADER ---/{/\[EN\]/d; /END HEADER/d; s/^#     //; s/^#[[:space:]]*$//; p}' "$0"
    exit 0
}

set -euo pipefail

INSTANCE="${1:-}"
[[ -z "$INSTANCE" ]] && { echo "[fleet-inbox-read] no instance specified — skipping" >&2; exit 0; }

# Source fleet-env for FLEET_SPOOL_INBOX, fleet-send path
FLEET_ENV="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/fleet-env.sh"
# shellcheck source=/dev/null
[ -f "$FLEET_ENV" ] && source "$FLEET_ENV"

INBOX="${FLEET_SPOOL_INBOX:-/var/spool/fleet/inbox}/$INSTANCE"
readonly INSTANCE INBOX
[[ -d "$INBOX" ]] || exit 0

# Collect messages — sorted by name (timestamp prefix ensures chronological order)
# Note: messages arriving after this find are not seen until next drain (by design).
mapfile -t MSGS < <(find "$INBOX" -maxdepth 1 -name '*.md' -not -name '.*' 2>/dev/null | sort)
[[ ${#MSGS[@]} -eq 0 ]] && exit 0

mkdir -p "$INBOX/.processing"
mkdir -p "$INBOX/.consumed"

# Cleanup: move any orphaned .processing files back to inbox on startup
for _orphan in "$INBOX/.processing"/*.md; do
    [[ -f "$_orphan" ]] && mv "$_orphan" "$INBOX/" 2>/dev/null
done

MSG_COUNT=${#MSGS[@]}
echo "=== INBOX ($MSG_COUNT messages) ==="

for msg in "${MSGS[@]}"; do
    [ -f "$msg" ] || continue
    BASENAME="$(basename "$msg")"
    PROC_FILE="$INBOX/.processing/$BASENAME"

    # Move to .processing/ atomically — signals "being read"
    # Subshell: exit 1 = lock held by concurrent reader, skip this message
    (
        flock -n 200 || exit 1
        mv "$msg" "$PROC_FILE" 2>/dev/null || true
    ) 200>"$INBOX/.processing/.lock"

    [ -f "$PROC_FILE" ] || continue

    # Parse YAML envelope fields (between first --- pair only — not the body)
    # Guard: if file doesn't start with ---, treat as no envelope
    if head -1 "$PROC_FILE" 2>/dev/null | grep -q '^---$'; then
        _envelope="$(sed -n '2,/^---$/{ /^---$/d; p }' "$PROC_FILE" 2>/dev/null)"
    else
        _envelope=""
    fi
    SUBJECT_LINE="$(printf '%s\n' "$_envelope" | grep '^subject:' | head -1 | sed 's/^subject: *//')"
    FROM_LINE="$(printf '%s\n' "$_envelope" | grep '^from:' | head -1 | sed 's/^from: *//')"
    TYPE_LINE="$(printf '%s\n' "$_envelope" | grep '^type:' | head -1 | sed 's/^type: *//')"
    PRIORITY_LINE="$(printf '%s\n' "$_envelope" | grep '^priority:' | head -1 | sed 's/^priority: *//')"

    # Display header with envelope metadata
    echo "--- $BASENAME [type:${TYPE_LINE:-?} priority:${PRIORITY_LINE:-normal}] ---"
    LINE_COUNT=$(wc -l < "$PROC_FILE")
    if (( LINE_COUNT > 200 )); then
        head -200 "$PROC_FILE"
        echo "... (truncated — ${LINE_COUNT} lines total)"
    else
        cat "$PROC_FILE"
    fi
    echo ""

    # Move from .processing/ to .consumed/ — message fully read
    # ACK is conditional on successful move (A-002 fix: no faux ACK)
    (
        flock -n 201 || exit 1
        mv "$PROC_FILE" "$INBOX/.consumed/$BASENAME"
    ) 201>"$INBOX/.consumed/.lock"

    if [[ -f "$INBOX/.consumed/$BASENAME" ]]; then
        # Write .ack file only if message was actually consumed
        ACK_FILE="$INBOX/.consumed/${BASENAME%.md}.ack"
        printf 'acked: %s\nby: %s\nat: %s\n' \
            "$BASENAME" "$INSTANCE" "$(date '+%Y-%m-%d %H:%M:%S')" > "$ACK_FILE"
    else
        printf '[inbox-read] WARNING: failed to consume %s — no ACK written\n' "$BASENAME" >&2
    fi

    # Auto-ACK PING subject
    if [[ "$SUBJECT_LINE" == "PING" ]] && [[ -n "$FROM_LINE" ]]; then
        SEND="$(dirname "${BASH_SOURCE[0]}")/fleet-send.sh"
        if [ -x "$SEND" ]; then
            STATUS_MSG="${FLEET_INSTANCE:-$INSTANCE} online. idle"
            echo "$STATUS_MSG" | "$SEND" "$FROM_LINE" "ACK" > /dev/null 2>&1 || true
        fi
    fi
done

echo "=== END INBOX ==="

# Stop visual alert if running (gyrophare stops when inbox is emptied)
ALERT_SCRIPT="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/fleet-alert.sh"
if [ -x "$ALERT_SCRIPT" ]; then
    "$ALERT_SCRIPT" --stop 2>/dev/null || true
fi

exit 0
