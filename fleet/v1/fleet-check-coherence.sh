#!/bin/bash
# DEPLOY: instance-util

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-check-coherence.sh
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
#     | MODULE: CHECK-COHERENCE | SUBSYSTEM: FLEET / INTEGRITY    |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  deployed copies in each instance home.                   |
#     |  Reports drift via spool IPC — never auto-fixes.          |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     DEPLOY: instance-util
#
#           ______________________________________________________
#          /          LCARS FLEET - FEDERATION DATABASE           \
#         |   ________   __________________________________________\
#         |  |  2026  |  | SOURCE: fleet-check-coherence.sh
#         |  |________|  | AUTHOR: LORDZURP
#
#     [EN]
#     fleet-check-coherence.sh — deployed copies in each instance home.
#     Reports drift via spool IPC — never auto-fixes.
#
#
# --- END HEADER ---


# --help: extract [EN] section from this header
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && {
    sed -n '/^#     \[EN\]/,/^# --- END HEADER ---/{/\[EN\]/d; /END HEADER/d; s/^#     //; s/^#[[:space:]]*$//; p}' "$0"
    exit 0
}

set -euo pipefail

# Source fleet-env for blueprint functions
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/fleet-env.sh"

SENTINEL="${FLEET_STATE_DIR:-/home/fleet-state}/run/coherence-check-$(date +%Y-%m-%d)"
readonly SENTINEL
LOG="$FLEET_LOGS/fleet-state.log"
readonly LOG
# Drift alerts sent via fleet-send.sh (spool IPC)

# Sentinel: once per day
if [[ -f "$SENTINEL" ]]; then
    exit 0
fi

# Build source → deployed mapping dynamically from blueprint
declare -a PAIRS=()
while IFS= read -r role; do
    PAIRS+=(".claude/CLAUDE.md|$role|$HOMES_ROOT/$role/.claude/CLAUDE.md")
done < <(fleet_roles)

alerts=()

for PAIR in "${PAIRS[@]}"; do
    IFS='|' read -r SRC_REL LABEL DEPLOYED <<< "$PAIR"
    SRC="$LCARS_ROOT/$SRC_REL"

    if [[ ! -f "$DEPLOYED" ]]; then
        alerts+=("  - $LABEL : $SRC_REL → missing")
        continue
    fi

    # AUDIT-021/022: deploy-claude.sh intentionally mutates CLAUDE.md after copy
    # (conversation language injection at line 3). Skip first 3 lines for comparison.
    # If file is ≤3 lines, compare the whole thing (no injection possible on tiny files).
    _src_lc=$(wc -l < "$SRC" 2>/dev/null || echo 0)
    if [[ $_src_lc -gt 3 ]]; then
        src_body=$(tail -n +4 "$SRC" 2>/dev/null | md5sum | awk '{print $1}')
        dep_body=$(tail -n +4 "$DEPLOYED" 2>/dev/null | md5sum | awk '{print $1}')
    else
        src_body=$(md5sum "$SRC" 2>/dev/null | awk '{print $1}')
        dep_body=$(md5sum "$DEPLOYED" 2>/dev/null | awk '{print $1}')
    fi
    if [[ "$src_body" != "$dep_body" ]]; then
        alerts+=("  - $LABEL : $SRC_REL → drift")
    fi
done

touch "$SENTINEL"

if (( ${#alerts[@]} == 0 )); then
    echo "[check-coherence] OK — all CLAUDE.md in sync"
    exit 0
fi

# Build alert report
TIMESTAMP=$(date '+%Y-%m-%d %H:%M')
ALERT_HEADER="### $TIMESTAMP — [auto] CLAUDE.md drift detected"
ALERT_BODY=$(printf '%s\n' "${alerts[@]}")

echo "[check-coherence] drift detected (${#alerts[@]} instance(s)) — reporting via fleet-send.sh"

# Send drift alert to engineer via spool
FLEET_SEND="$(fleet_bin fleet-send.sh)"

if [[ -n "$FLEET_SEND" ]]; then
    printf '%s\n%s\n' "$ALERT_HEADER" "$ALERT_BODY" | "$FLEET_SEND" engineer "claude-md-drift"
else
    echo "[check-coherence] WARN: fleet-send.sh not found — drift alert not delivered" >&2
fi

echo "[$TIMESTAMP] [check-coherence] drift: ${alerts[*]}" >> "$LOG"

exit 0
