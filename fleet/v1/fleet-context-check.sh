#!/bin/bash
# DEPLOY: instance-util

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-context-check.sh
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
#     | MODULE: CONTEXT-CHECK   | SUBSYSTEM: HOOKS / LIFECYCLE    |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Reads active JSONL to compute real context window %.     |
#     |  Emits warning when soft threshold is reached.            |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     DEPLOY: instance-util
#
#           ______________________________________________________
#          /          LCARS FLEET - FEDERATION DATABASE           \
#         |   ________   __________________________________________\
#         |  |  2026  |  | SOURCE: fleet-context-check.sh
#         |  |________|  | AUTHOR: LORDZURP
#
#     [EN]
#     fleet-context-check.sh — Reads active JSONL to compute real context window %.
#     Emits warning when soft threshold is reached.
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

SESSION_ID="${1:-}"

# Per-role soft threshold = AUTOCOMPACT_PCT_OVERRIDE - 5
# Threshold set per role from blueprint context_threshold
AUTOCOMPACT="${AUTOCOMPACT_PCT_OVERRIDE:-75}"
SOFT_DEFAULT=$(( AUTOCOMPACT - 5 ))
THRESHOLD="${2:-$SOFT_DEFAULT}"
WINDOW=200000

[[ -z "$SESSION_ID" ]] && exit 0

# Find JSONL — search all project dirs (cwd-agnostic)
JSONL=$(find "$HOME/.claude/projects" -name "${SESSION_ID}.jsonl" 2>/dev/null | head -1)
[[ -z "$JSONL" || ! -f "$JSONL" ]] && exit 0

python3 - "$JSONL" "$THRESHOLD" "$WINDOW" <<'PYEOF'
import sys, json

jsonl_path, threshold_str, window_str = sys.argv[1:4]
threshold = int(threshold_str)
window = int(window_str)

last_usage = None
with open(jsonl_path) as f:
    for line in f:
        try:
            d = json.loads(line)
            msg = d.get("message", {})
            if isinstance(msg, dict) and "usage" in msg:
                last_usage = msg["usage"]
        except Exception:
            pass

if last_usage is None:
    sys.exit(0)

total = (
    last_usage.get("input_tokens", 0)
    + last_usage.get("cache_creation_input_tokens", 0)
    + last_usage.get("cache_read_input_tokens", 0)
)

pct = round(total * 100 / window)
if pct >= threshold:
    print(
        f"[context-check] GO-8 ACTIVE — Fenêtre {pct}% ({total}/{window}) "
        f"— seuil {threshold}% atteint. "
        f"Exécuter /harvest-emergency maintenant. "
        f"Terminer proprement la tâche en cours puis /handoff."
    )
PYEOF
