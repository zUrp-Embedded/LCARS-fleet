#!/usr/bin/env bash
# DEPLOY: none (called by provision-fleet.sh)

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: provision-identity.sh
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
#     | MODULE: IDENTITY        | SUBSYSTEM: PROVISIONING         |
#     | LICENSE: AGPL-3         | STARDATE: 2026.088              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Patches fleet_user + windows_user into fleet.yaml.       |
#     |  Idempotent — skips if already present.                   |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     Injecte fleet_user et windows_user dans fleet.yaml.
#     Idempotent : skip si déjà présent.
#
#     [EN]
#     NAME
#         provision-identity.sh — patch fleet_user/windows_user into fleet.yaml
#
#     SYNOPSIS
#         provision-identity.sh <fleet_user> <fleet_yaml>
#
#     EXIT CODES
#         0    Identity patched or already present
#
# --- END HEADER ---

set -euo pipefail

FLEET_USER="${1:?usage: provision-identity.sh <fleet_user> <fleet_yaml>}"
FLEET_YAML="${2:?usage: provision-identity.sh <fleet_user> <fleet_yaml>}"

info() { echo -e "\033[0;32m[identity]\033[0m  $*"; }

[ -f "$FLEET_YAML" ] || { echo "WARN: fleet.yaml not found at $FLEET_YAML — skipping identity patch" >&2; exit 0; }

# Resolve windows user
if [ -z "${LCARS_DOCKER:-}" ]; then
    WIN_USER="$(wslvar USERNAME 2>/dev/null | tr -d '\r' || true)"
else
    WIN_USER=""
fi
[ -z "$WIN_USER" ] && WIN_USER="$FLEET_USER"

# Patch fleet_user
if ! grep -q "^  fleet_user:" "$FLEET_YAML"; then
    sed "/^  lang:/a\\  fleet_user: $FLEET_USER" "$FLEET_YAML" > "${FLEET_YAML}.tmp" && mv -f "${FLEET_YAML}.tmp" "$FLEET_YAML"
    info "fleet_user: $FLEET_USER → fleet.yaml"
else
    info "fleet_user already set"
fi

# Patch windows_user
if ! grep -q "^  windows_user:" "$FLEET_YAML"; then
    sed "/^  fleet_user:/a\\  windows_user: $WIN_USER" "$FLEET_YAML" > "${FLEET_YAML}.tmp" && mv -f "${FLEET_YAML}.tmp" "$FLEET_YAML"
    info "windows_user: $WIN_USER → fleet.yaml"
else
    info "windows_user already set"
fi
