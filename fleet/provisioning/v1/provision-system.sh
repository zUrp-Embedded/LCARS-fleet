#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: provision-system.sh
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
#     | MODULE: PROVISION-SYSTEM| SUBSYSTEM: FLEET / INSTALL      |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  System-level provisioning. Blueprint-driven.             |
#     |  --check = doctor (read-only, structured output).         |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#           ______________________________________________________
#          /          LCARS FLEET - FEDERATION DATABASE           \
#         |   ________   __________________________________________\
#         |  |  2026  |  | SOURCE: provision-system.sh
#         |  |________|  | AUTHOR: LORDZURP
#         |   ________   | SYSTEM: LCARS-FLEET v5.4
#
#     [EN]
#     provision-system.sh — System-level provisioning. Blueprint-driven.
#     --check = doctor (read-only, structured output).
#
#
# --- END HEADER ---


set -euo pipefail

# --- Args ---
CHECK=0
FLEET_USER=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) CHECK=1; shift ;;
        *)       FLEET_USER="$1"; shift ;;
    esac
done

[ "$EUID" -ne 0 ] && { echo "[FAIL] must run as root"; exit 1; }
[ -z "$FLEET_USER" ] && { echo "[FAIL] usage: provision-system.sh [--check] <fleet_user>"; exit 1; }

# --- Paths ---
SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
PROVISION_DIR="$SCRIPT_DIR/provision.d"
FLEET_YAML="${FLEET_YAML:-$SCRIPT_DIR/../fleet.yaml}"
_SYSTEM_YAML="$SCRIPT_DIR/../fleet-system.yaml"

# --- Counters ---
FAIL_COUNT=0; WARN_COUNT=0; PASS_COUNT=0

# --- Helpers (shared by sub-scripts via source) ---
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'
pass() { echo -e "${GREEN}[OK]${NC}   $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo -e "${RED}[FAIL]${NC} $*"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; WARN_COUNT=$((WARN_COUNT + 1)); }

check_or_do() {
    # JUPITER-011: eval replaced with bash -c in restricted subshell.
    # Commands run in a child process — no variable injection into caller scope.
    local label="$1" test_cmd="$2" fix_cmd="$3"
    if bash -c "$test_cmd"; then
        pass "$label"
    elif [[ $CHECK -eq 1 ]]; then
        fail "$label"
    else
        bash -c "$fix_cmd"
        if bash -c "$test_cmd"; then
            pass "$label — fixed"
        else
            fail "$label — fix failed"
        fi
    fi
}

# --- 1. Packages + yq (must run before fleet-env.sh) ---
source "$PROVISION_DIR/provision-packages.sh"

# --- Fleet env (yq now available) ---
BUILD_YAML="$SCRIPT_DIR/../fleet-build-yaml.sh"
if [ ! -f "$FLEET_YAML" ]; then
    if [ -x "$BUILD_YAML" ] && command -v yq &>/dev/null; then
        echo ""
        echo "=== fleet.yaml — generating from profile ==="
        bash "$BUILD_YAML" 2>&1
        [ -f "$FLEET_YAML" ] && pass "fleet.yaml:generated" || fail "fleet.yaml:generation failed"
    else
        fail "fleet.yaml:not found at $FLEET_YAML (yq or fleet-build-yaml.sh missing)"
        exit 1
    fi
fi

FLEET_ENV="$SCRIPT_DIR/../fleet-env.sh"
if command -v yq &>/dev/null; then
    [ -f "$FLEET_ENV" ] && source "$FLEET_ENV"
else
    warn "yq not in PATH — using defaults (fleet-env.sh skipped)"
    _yq() { echo "null"; }
    fleet_roles() { echo ""; }
    fleet_role_field() { echo "null"; }
fi

# Blueprint variables
FLEET_GROUP="$(_yq '.fleet.group')"
[[ "$FLEET_GROUP" == "null" || -z "$FLEET_GROUP" ]] && FLEET_GROUP="fleet"
LCARS_ROOT="$(_yq '.fleet.paths.lcars_root')"
[[ "$LCARS_ROOT" == "null" || -z "$LCARS_ROOT" ]] && LCARS_ROOT="/local/LCARS"
COMMONS="$(_yq '.fleet.paths.commons')"
[[ "$COMMONS" == "null" || -z "$COMMONS" ]] && COMMONS="/home/commons"
HANDOFFS="${FLEET_HANDOFFS:-}"
[[ -z "$HANDOFFS" ]] && { echo "FATAL: FLEET_HANDOFFS not set" >&2; exit 1; }
FLEET_STATE_DIR="$(_yq '.fleet.paths.fleet_state')"
[[ "$FLEET_STATE_DIR" == "null" || -z "$FLEET_STATE_DIR" ]] && FLEET_STATE_DIR="/home/fleet-state"
HOMES_ROOT="$(_yq '.fleet.paths.homes_root')"
[[ "$HOMES_ROOT" == "null" || -z "$HOMES_ROOT" ]] && HOMES_ROOT="/home"
SPOOL_ROOT="$(_yq '.spool.root')"
[[ "$SPOOL_ROOT" == "null" || -z "$SPOOL_ROOT" ]] && SPOOL_ROOT="/var/spool/fleet"

# --- Dispatch sub-scripts ---
source "$PROVISION_DIR/provision-groups.sh"
source "$PROVISION_DIR/provision-sudoers.sh"
source "$PROVISION_DIR/provision-directories.sh"
source "$PROVISION_DIR/provision-claude-bin.sh"
source "$PROVISION_DIR/provision-codex.sh"
source "$PROVISION_DIR/provision-git.sh"
source "$PROVISION_DIR/provision-wsl.sh"
source "$PROVISION_DIR/provision-permissions.sh"

# --- Fleet user hushlogin (silence MOTD Ubuntu) ---
_FU_HOME="$(getent passwd "$FLEET_USER" 2>/dev/null | cut -d: -f6)"
: "${_FU_HOME:=$HOMES_ROOT/$FLEET_USER}"
check_or_do "hushlogin:$FLEET_USER" \
    "[ -f $_FU_HOME/.hushlogin ]" \
    "touch $_FU_HOME/.hushlogin && chown $FLEET_USER:$FLEET_USER $_FU_HOME/.hushlogin"

# --- Summary ---
echo ""
echo "=== Summary ==="
echo "  OK   : $PASS_COUNT"
echo "  WARN : $WARN_COUNT"
echo "  FAIL : $FAIL_COUNT"

if [[ $CHECK -eq 1 ]]; then
    [[ $FAIL_COUNT -gt 0 ]] && echo "  Run without --check to fix." && exit 1
    echo "  System healthy."
else
    [[ $FAIL_COUNT -gt 0 ]] && echo "  Some items could not be fixed." && exit 1
    echo "  System provisioned."
fi
