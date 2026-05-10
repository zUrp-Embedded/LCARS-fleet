#!/bin/bash
# DEPLOY: instance-util

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-send.sh
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
#     | MODULE: FLEET-SEND      | SUBSYSTEM: IPC / SPOOL          |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Spool-based IPC — replaces broker, inject, notify.       |
#     |  Drops a message file into inbox/<dest>/, then wakes      |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     DEPLOY: instance-util
#
#           ______________________________________________________
#          /          LCARS FLEET - FEDERATION DATABASE           \
#         |   ________   __________________________________________\
#         |  |  2026  |  | SOURCE: fleet-send.sh
#         |  |________|  | AUTHOR: LORDZURP
#
#     [EN]
#     fleet-send.sh — Spool-based IPC — replaces broker, inject, notify.
#     Drops a message file into inbox/<dest>/, then wakes
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

# --- Parse optional flags ---
MSG_TYPE="task"
MSG_PRIORITY="normal"
MSG_REF=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --type)      MSG_TYPE="${2:?--type requires a value}";     shift 2 ;;
        --priority)  MSG_PRIORITY="${2:?--priority requires a value}"; shift 2 ;;
        --ref)       MSG_REF="${2:?--ref requires a value}";       shift 2 ;;
        --)          shift; break ;;
        -*)          echo "ERROR: unknown flag '$1'" >&2; exit 1 ;;
        *)           break ;;
    esac
done

# B001-FIX: validate type/priority against whitelist (prevents YAML injection)
case "$MSG_TYPE" in
    task|ack|ping|escalation|result|notification) ;;
    *) echo "ERROR: invalid --type '$MSG_TYPE'. Must be: task|ack|ping|escalation|result|notification" >&2; exit 1 ;;
esac
case "$MSG_PRIORITY" in
    normal|high|critical) ;;
    *) echo "ERROR: invalid --priority '$MSG_PRIORITY'. Must be: normal|high|critical" >&2; exit 1 ;;
esac
# Sanitize --ref (strip newlines, control chars — same as SUBJECT)
MSG_REF="$(printf '%s' "$MSG_REF" | tr -d '\n\r' | tr -cd '[:print:]')"

DEST="${1:?usage: fleet-send.sh [--type T] [--priority P] [--ref R] <dest> <subject> [content-file]}"
SUBJECT="${2:?usage: fleet-send.sh [--type T] [--priority P] [--ref R] <dest> <subject> [content-file]}"
# LLB-003 fix: sanitize SUBJECT — strip newlines and control characters
# Prevents YAML frontmatter injection via multi-line subjects
SUBJECT="$(printf '%s' "$SUBJECT" | tr -d '\n\r' | tr -cd '[:print:]')"
CONTENT_FILE="${3:-}"

# F-C1 FIX: resolve linux_user → role via blueprint (whoami alone breaks if linux_user != role)
SOURCE="$(fleet_resolve_role)" || { echo "ERROR: caller '$(whoami)' not in blueprint — IPC denied" >&2; exit 1; }
TIMESTAMP="$(date +%Y%m%d-%H%M%S)-$$"
INBOX_DIR="$FLEET_SPOOL_INBOX/$DEST"
readonly DEST SUBJECT SOURCE TIMESTAMP INBOX_DIR

# --- Validate destination inbox exists ---
if [ ! -d "$INBOX_DIR" ]; then
    echo "ERROR: inbox dir '$INBOX_DIR' does not exist — run deploy.sh first" >&2
    exit 1
fi

# --- Validate IPC authorization (derived from blueprint tiers) ---
# v7 #03: routing matrix from fleet.yaml, not hardcoded.
# Rule: Tier 0 → anyone. Tier 1 → Tier 0 + Tier 2. Tier 2 → Tier 1 + Tier 0 only.
_FLEET_YAML="${FLEET_YAML:-/local/LCARS/fleet/fleet.yaml}"
_src_tier=$(yq ".instances[] | select(.role == \"$SOURCE\") | .tier" "$_FLEET_YAML" 2>/dev/null)
_dst_tier=$(yq ".instances[] | select(.role == \"$DEST\") | .tier" "$_FLEET_YAML" 2>/dev/null)
_dst_exists=$(yq ".instances[] | select(.role == \"$DEST\") | .role" "$_FLEET_YAML" 2>/dev/null)

# Source must exist in blueprint
if [[ -z "$_src_tier" || "$_src_tier" == "null" ]]; then
    echo "ERROR: source '$SOURCE' not in blueprint — IPC denied" >&2; exit 1
fi
# Destination must exist in blueprint
if [[ -z "$_dst_exists" || "$_dst_exists" == "null" ]]; then
    echo "ERROR: destination '$DEST' not in blueprint — IPC denied" >&2; exit 1
fi

# Tier-based routing
case "$_src_tier" in
    0) ;; # Tier 0 can send to anyone
    1)
        # Tier 1 can send to Tier 0 and Tier 2
        case "$_dst_tier" in 0|2) ;; *)
            echo "ERROR: Tier $_src_tier ($SOURCE) cannot send to Tier $_dst_tier ($DEST)" >&2; exit 1 ;;
        esac ;;
    2)
        # Tier 2 can send to Tier 0 and Tier 1 only (escalation)
        case "$_dst_tier" in 0|1) ;; *)
            echo "ERROR: Tier $_src_tier ($SOURCE) cannot send to Tier $_dst_tier ($DEST) — escalate via Tier 0 or 1" >&2; exit 1 ;;
        esac ;;
    *)
        echo "ERROR: unknown tier '$_src_tier' for $SOURCE" >&2; exit 1 ;;
esac

# --- Build message filename ---
# Format: <timestamp>-<source>-<subject>.md
# Subject sanitized: lowercase, spaces→dashes, strip non-alnum
SAFE_SUBJECT="$(printf '%s' "$SUBJECT" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd '[:alnum:]-')"
[[ -z "$SAFE_SUBJECT" ]] && SAFE_SUBJECT="msg"
MSG_FILE="$INBOX_DIR/${TIMESTAMP}-${SOURCE}-${SAFE_SUBJECT}.md"

# Cleanup tmp file on interrupt (write-tmp-then-mv pattern)
trap 'rm -f "${MSG_FILE}.tmp" 2>/dev/null' INT TERM

# --- Write message content ---
# YAML frontmatter envelope — parseable by fleet-inbox-read.sh
# Using heredoc instead of printf to avoid format string injection via % in SUBJECT
ENVELOPE="---
from: ${SOURCE}
to: ${DEST}
subject: ${SUBJECT}
type: ${MSG_TYPE}
priority: ${MSG_PRIORITY}
ref: ${MSG_REF}
date: $(date -Iseconds)
---"

# $3 can be: a file path, an inline string, or absent (empty message / stdin)
if [ -n "$CONTENT_FILE" ]; then
    if [ -f "$CONTENT_FILE" ] || [ "$CONTENT_FILE" = "/dev/stdin" ]; then
        { printf '%s\n' "$ENVELOPE"; cat "$CONTENT_FILE"; } > "${MSG_FILE}.tmp" && mv -f "${MSG_FILE}.tmp" "$MSG_FILE"
    else
        # Treat as inline string — warn if it looks like a path
        [[ "$CONTENT_FILE" == /* || "$CONTENT_FILE" == ./* ]] && \
            echo "WARN: '$CONTENT_FILE' looks like a path but file not found — treating as inline content" >&2
        { printf '%s\n' "$ENVELOPE"; printf '%s' "$CONTENT_FILE"; } > "${MSG_FILE}.tmp" && mv -f "${MSG_FILE}.tmp" "$MSG_FILE"
    fi
elif [ ! -t 0 ]; then
    { printf '%s\n' "$ENVELOPE"; cat; } > "${MSG_FILE}.tmp" && mv -f "${MSG_FILE}.tmp" "$MSG_FILE"
else
    printf '%s\n' "$ENVELOPE" > "${MSG_FILE}.tmp" && mv -f "${MSG_FILE}.tmp" "$MSG_FILE"
fi

chmod 660 "$MSG_FILE"
chgrp fleet "$MSG_FILE" 2>/dev/null || true
trap - INT TERM  # restore default traps
echo "OK: $MSG_FILE" >&2
basename "$MSG_FILE"

# v7 #05: wake removed from send — inotifywait daemon handles wake on inbox delivery.
# fleet-send.sh = delivery only. One task, one tool.
