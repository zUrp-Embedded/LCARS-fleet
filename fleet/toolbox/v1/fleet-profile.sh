#!/usr/bin/env bash
# DEPLOY: instance-util

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-profile.sh
#     |  |________|  | AUTHOR: STARFLEET
#     |   ________   | SYSTEM: LCARS-FLEET v6.0
#     |  |  v5.4  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS-FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: FLEET-PROFILE   | SUBSYSTEM: TOOLBOX / MAINT      |
#     | LICENSE: AGPL-3         | STARDATE: 2026.090.6            |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Switch fleet profile (fleet/projects/embedded).          |
#     |  Persists in fleet-system.yaml + rebuilds + deploys.      |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     fleet-profile.sh — change le profil fleet actif.
#     Persiste dans fleet-system.yaml, rebuild fleet.yaml, fleet-update.
#
#     [EN]
#     NAME
#         fleet-profile.sh — switch fleet profile
#
#     SYNOPSIS
#         sudo fleet-profile.sh <fleet|projects|embedded>
#         fleet-profile.sh                              (show current)
#
#     DESCRIPTION
#         Switches the active fleet profile. Persists the choice in
#         fleet-system.yaml so it survives reboots and fleet-update.sh.
#         Runs fleet-update.sh to provision new agents and deploy.
#
#     PROFILES
#         fleet      Minimal: starfleet + qualifier + reviewer (LCARS self-maintenance)
#         projects   Standard: + architect, engineer, dev, qualifier, reviewer, documenter, researcher
#         embedded   Hardware: + builder, deployer (RPi, firmware, flash)
#
#     EXIT CODES
#         0    Profile switched (or shown)
#         1    Invalid profile / not root
#
# --- END HEADER ---

set -euo pipefail

FLEET_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.."
SYSTEM_YAML="$FLEET_DIR/fleet-system.yaml"
CURRENT=$(yq '.fleet.profile' "$SYSTEM_YAML" 2>/dev/null)
[[ "$CURRENT" == "null" || -z "$CURRENT" ]] && CURRENT="projects"

# No arg = show current
if [[ $# -eq 0 ]]; then
    echo "Current profile: $CURRENT"
    echo "Available: fleet | projects | embedded"
    exit 0
fi

PROFILE="$1"

# Validate
case "$PROFILE" in
    fleet|projects|embedded) ;;
    *) echo "ERROR: unknown profile '$PROFILE' (fleet|projects|embedded)" >&2; exit 1 ;;
esac

if [[ "$PROFILE" == "$CURRENT" ]]; then
    echo "Already on profile: $PROFILE"
    exit 0
fi

[[ $EUID -eq 0 ]] || { echo "ERROR: must run as root (sudo fleet-profile.sh $PROFILE)" >&2; exit 1; }

# Persist in fleet-system.yaml
if yq -e '.fleet.profile' "$SYSTEM_YAML" &>/dev/null; then
    yq -i ".fleet.profile = \"$PROFILE\"" "$SYSTEM_YAML"
else
    yq -i ".fleet.profile = \"$PROFILE\"" "$SYSTEM_YAML"
fi

echo "Profile: $CURRENT → $PROFILE"
echo "Rebuilding fleet.yaml + provisioning + deploying..."

# Full chain
fleet-update.sh --force

echo ""
echo "Profile switched to: $PROFILE"
