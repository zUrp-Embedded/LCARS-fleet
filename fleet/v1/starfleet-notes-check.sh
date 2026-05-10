#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: starfleet-notes-check.sh
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
#     | MODULE: NOTES-CHECK     | SUBSYSTEM: FLEET / IPC          |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Checks starfleet-notes.md for pending items.             |
#     |  Alerts if unread notes remain after session end.         |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#           ______________________________________________________
#          /          LCARS FLEET - FEDERATION DATABASE           \
#         |   ________   __________________________________________\
#         |  |  2026  |  | SOURCE: starfleet-notes-check.sh
#         |  |________|  | AUTHOR: LORDZURP
#         |   ________   | SYSTEM: LCARS-FLEET v6.0
#
#     [EN]
#     starfleet-notes-check.sh — Checks starfleet-notes.md for pending items.
#     Alerts if unread notes remain after session end.
#
#
# --- END HEADER ---


# --help: extract [EN] section from this header
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && {
    sed -n '/^#     \[EN\]/,/^# --- END HEADER ---/{/\[EN\]/d; /END HEADER/d; s/^#     //; s/^#[[:space:]]*$//; p}' "$0"
    exit 0
}

set -euo pipefail

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/fleet-env.sh"

INDEX="$FLEET_HANDOFFS/starfleet-notes-index.md"
NOTES="$FLEET_HANDOFFS/starfleet-notes.md"
CLEAN=0
[[ "${1:-}" == "--clean" ]] && CLEAN=1

[[ -f "$INDEX" ]] || { echo "[notes-check] index not found — skipping"; exit 0; }
[[ -f "$NOTES" ]] || { echo "[notes-check] notes not found — skipping"; exit 0; }

# Parse index: collect id → status mapping
declare -A id_status
current_id=""
while IFS= read -r line; do
    if [[ "$line" =~ ^id:[[:space:]]+(.+)$ ]]; then
        current_id="${BASH_REMATCH[1]}"
        current_id="${current_id%"${current_id##*[![:space:]]}"}"  # rtrim
    elif [[ "$line" =~ ^status:[[:space:]]+(.+)$ ]] && [[ -n "$current_id" ]]; then
        status="${BASH_REMATCH[1]}"
        status="${status%"${status##*[![:space:]]}"}"
        id_status["$current_id"]="$status"
        current_id=""
    fi
done < "$INDEX"

# Collect stale entries that still exist in notes
stale_in_notes=()
for id in "${!id_status[@]}"; do
    [[ "${id_status[$id]}" == "stale" ]] || continue
    grep -q "<!-- id: ${id} -->" "$NOTES" && stale_in_notes+=("$id")
done

# Collect orphaned sections (anchor in notes, id not in index)
orphaned=()
while IFS= read -r line; do
    if [[ "$line" =~ \<\!--[[:space:]]id:[[:space:]]([^[:space:]]+)[[:space:]]--\> ]]; then
        anchor_id="${BASH_REMATCH[1]}"
        [[ -v "id_status[$anchor_id]" ]] || orphaned+=("$anchor_id")
    fi
done < "$NOTES"

# Report
issues=0
if (( ${#stale_in_notes[@]} > 0 )); then
    echo "[notes-check] stale sections in notes (${#stale_in_notes[@]}): ${stale_in_notes[*]}"
    issues=$(( issues + ${#stale_in_notes[@]} ))
fi
if (( ${#orphaned[@]} > 0 )); then
    echo "[notes-check] orphaned in notes (not in index): ${orphaned[*]}"
    issues=$(( issues + ${#orphaned[@]} ))
fi
if (( issues == 0 )); then
    active=$(grep -c "^status: active" "$INDEX" 2>/dev/null || echo 0)
    echo "[notes-check] OK — ${active} active entries"
fi

# Clean mode: remove stale sections from notes
if (( CLEAN == 1 )) && (( ${#stale_in_notes[@]} > 0 )); then
    python3 - "$NOTES" "${stale_in_notes[@]}" <<'PYEOF'
import sys, re

notes_file = sys.argv[1]
target_ids = sys.argv[2:]

with open(notes_file) as f:
    content = f.read()

for target_id in target_ids:
    # Each section: ---\n<!-- id: xxx -->\n...content...
    # Remove from the --- before <!-- id: target --> through the content,
    # stopping just before the next --- or end of file.
    pattern = (
        r'\n---\n<!-- id: ' + re.escape(target_id) + r' -->\n'
        r'.*?'
        r'(?=\n---\n<!-- id: |\Z)'
    )
    new_content = re.sub(pattern, '', content, flags=re.DOTALL)
    if new_content != content:
        print(f"[notes-check] removed stale: {target_id}")
        content = new_content
    else:
        print(f"[notes-check] warning: pattern not matched for: {target_id}")

# Clean up excess blank lines
content = re.sub(r'\n{3,}', '\n\n', content)

with open(notes_file, 'w') as f:
    f.write(content)
PYEOF
fi

exit 0
