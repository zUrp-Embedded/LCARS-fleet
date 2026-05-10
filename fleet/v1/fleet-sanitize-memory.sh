#!/bin/bash
# DEPLOY: instance-util

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-sanitize-memory.sh
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
#     | MODULE: SANITIZE-MEMORY | SUBSYSTEM: FLEET / MEMORY       |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Sanitizes MEMORY.md across all instances.                |
#     |  Whitelist: Identity + Completed sections only.           |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     DEPLOY: instance-util
#
#           ______________________________________________________
#          /          LCARS FLEET - FEDERATION DATABASE           \
#         |   ________   __________________________________________\
#         |  |  2026  |  | SOURCE: fleet-sanitize-memory.sh
#         |  |________|  | AUTHOR: LORDZURP
#
#     [EN]
#     fleet-sanitize-memory.sh — Sanitizes MEMORY.md across all instances.
#     Whitelist: Identity + Completed sections only.
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

_RUN_DIR="${FLEET_STATE_DIR:-/home/fleet-state}/run"
mkdir -p "$_RUN_DIR" 2>/dev/null || true
SENTINEL="$_RUN_DIR/mem-sanitize-$(date +%Y-%m-%d)"
readonly SENTINEL
LOG="$FLEET_LOGS/fleet-state.log"
readonly LOG

# Sentinel: once per day
if [[ -f "$SENTINEL" ]]; then
    exit 0
fi

# Build MEMORY_PATHS dynamically from blueprint
MEMORY_PATHS=()
while IFS= read -r role; do
    MEMORY_PATHS+=("$HOMES_ROOT/$role/.claude/projects/-home-$role/memory/MEMORY.md")
done < <(fleet_roles)

sanitized=0

for MEM in "${MEMORY_PATHS[@]}"; do
    [[ -f "$MEM" ]] || continue

    # Skip if file is nearly empty (< 3 lines)
    line_count=$(wc -l < "$MEM")
    if (( line_count < 3 )); then
        continue
    fi

    TMP="/tmp/mem_sanitize_$$.tmp"

    # awk: keep content before first ## (h1 title, preamble)
    # then keep only ## Identity and ## Completed sections
    awk '
    BEGIN { in_keep = 1 }
    /^## / { in_keep = ($0 ~ /Identity|Completed/) }
    in_keep { print }
    ' "$MEM" > "$TMP"

    # Compare — only write back if changed
    if ! diff -q "$MEM" "$TMP" > /dev/null 2>&1; then
        # R2S-14 mitigation: log which sections were removed
        removed_sections=$(diff "$MEM" "$TMP" 2>/dev/null | grep '^< ## ' | sed 's/^< //' || true)
        mv "$TMP" "$MEM"
        sanitized=$(( sanitized + 1 ))
        TIMESTAMP=$(date '+%Y-%m-%d %H:%M')
        # A-008 fix: extract role from path .../projects/-home-<role>/memory/MEMORY.md
        # dirname x2 = -home-<role>, then strip prefix
        agent_name=$(basename "$(dirname "$(dirname "$MEM")")")
        agent_name="${agent_name#-home-}"
        echo "[$TIMESTAMP] [sanitize-memory] cleaned: $MEM" >> "$LOG"
        if [[ -n "$removed_sections" ]]; then
            echo "[$TIMESTAMP] [sanitize-memory] removed sections from $agent_name: $removed_sections" >> "$LOG"
        fi
        echo "[sanitize-memory] cleaned: ${agent_name}/MEMORY.md"
    else
        rm -f "$TMP"
    fi
done

touch "$SENTINEL"

if (( sanitized == 0 )); then
    echo "[sanitize-memory] OK — all MEMORY.md clean"
fi

exit 0
