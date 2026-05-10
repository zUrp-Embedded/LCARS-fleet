#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: configure-plan.sh
#     |  |________|  | AUTHOR: LORDZURP
#     |   ________   | SYSTEM: LCARS-FLEET v2.0
#     |  |  v2.0  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS-FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: CONFIGURE-PLAN  | SUBSYSTEM: PROV / WSL2          |
#     | LICENSE: AGPL-3         | STARDATE: 2026.063              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Configures Anthropic plan reset schedule in fleet.yaml.  |
#     |  Prompts for billing reset day/time, updates plan: section.|
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     configure-plan.sh — Configure Anthropic plan reset schedule in fleet.yaml
#
#     Prompts for the billing period reset day and time, then updates
#     the plan: section of fleet.yaml in the LCARS source repo.
#
#     Usage:
#       bash configure-plan.sh              # interactive
#       bash configure-plan.sh --force      # re-configure even if already set
#
#     [EN]
#     configure-plan.sh — Configures Anthropic plan reset schedule in fleet.yaml.
#     Prompts for billing reset day/time, updates plan: section.
#

set -euo pipefail

# --- Fleet env ---
source "$(dirname "${BASH_SOURCE[0]}")/../../fleet-env.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FLEET_YAML="$REPO_ROOT/fleet.yaml"
FORCE=0

for arg in "$@"; do
    [[ "$arg" == "--force" ]] && FORCE=1
done

if [[ ! -f "$FLEET_YAML" ]]; then
    echo "ERROR: fleet.yaml not found at $FLEET_YAML" >&2
    exit 1
fi

DAYS="monday tuesday wednesday thursday friday saturday sunday"

# ─── Check if already configured ─────────────────────────────────────────────

current_day=$(python3 -c "
import sys
try:
    import yaml
    d = yaml.safe_load(open('$FLEET_YAML'))
    print(d.get('plan', {}).get('reset_day', 'monday'))
except Exception:
    print('monday')
")
current_time=$(python3 -c "
import sys
try:
    import yaml
    d = yaml.safe_load(open('$FLEET_YAML'))
    print(d.get('plan', {}).get('reset_time', '00:00'))
except Exception:
    print('00:00')
")
current_plan_type=$(python3 -c "
import sys
try:
    import yaml
    d = yaml.safe_load(open('$FLEET_YAML'))
    print(d.get('plan', {}).get('plan_type', ''))
except Exception:
    print('')
")

if [[ "$FORCE" -eq 0 && "$current_day" != "monday" ]]; then
    echo "Plan already configured: $current_plan_type $current_day at $current_time — skipping (use --force to override)"
    exit 0
fi
if [[ "$FORCE" -eq 0 && "$current_day" == "monday" && "$current_time" != "00:00" ]]; then
    echo "Plan already configured: $current_plan_type $current_day at $current_time — skipping (use --force to override)"
    exit 0
fi

# ─── Interactive prompt ───────────────────────────────────────────────────────

echo ""
echo "=== Anthropic plan reset configuration ==="
echo "Check your plan reset schedule at: https://console.anthropic.com/settings/billing"
echo ""

# Plan type prompt
while true; do
    read -r -p "Plan type [PRO/MAX]: " plan_type
    plan_type="${plan_type^^}"  # uppercase
    if [[ "$plan_type" == "PRO" || "$plan_type" == "MAX" ]]; then
        break
    fi
    echo "  Invalid plan type. Enter PRO or MAX"
done

# Day prompt
while true; do
    read -r -p "Reset day of week [monday/tuesday/.../sunday]: " reset_day
    reset_day="${reset_day,,}"  # lowercase
    if echo "$DAYS" | grep -qw "$reset_day"; then
        break
    fi
    echo "  Invalid day. Enter one of: $DAYS"
done

# Time prompt
while true; do
    read -r -p "Reset time (HH:MM, 24h local time, e.g. 19:59): " reset_time
    if [[ "$reset_time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        break
    fi
    echo "  Invalid format. Use HH:MM (24h), e.g. 19:59 or 00:00"
done

# ─── Update fleet.yaml ────────────────────────────────────────────────────────

python3 - "$FLEET_YAML" "$reset_day" "$reset_time" "$plan_type" <<'PYEOF'
import sys, re

fleet_yaml, reset_day, reset_time, plan_type = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
text = open(fleet_yaml).read()

new_plan = f"""plan:
  provider: anthropic
  plan_type: {plan_type}        # PRO or MAX — configured by configure-plan.sh at first install
  reset_day: {reset_day}
  reset_time: "{reset_time}"  # local time HH:MM (24h) — check your plan page for exact time
"""

if re.search(r'^plan:', text, re.MULTILINE):
    # Replace existing plan: block (to end of file or next top-level key)
    text = re.sub(r'^plan:.*?(?=^\w|\Z)', new_plan, text, flags=re.MULTILINE | re.DOTALL)
else:
    text = text.rstrip('\n') + '\n\n' + new_plan

open(fleet_yaml, 'w').write(text)
print(f"  fleet.yaml updated: plan_type={plan_type}, reset_day={reset_day}, reset_time={reset_time}")
PYEOF

echo ""
echo "Done. Run 'bash deploy.sh' from LCARS to propagate to ~/fleet/fleet.yaml"
