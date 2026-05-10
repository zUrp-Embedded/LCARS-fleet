#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: onboard-preflight.sh
#     |  |________|  | AUTHOR: LORDZURP
#     |   ________   | SYSTEM: LCARS-FLEET v5.4
#     |  |  v5.4  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS-FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: ONBOARD-PREFLIGHT| SUBSYSTEM: FLEET / INSTALL      |
#     | LICENSE: AGPL-3         | STARDATE: 2026.090              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Pre-flight checks for onboarding.                        |
#     |  Output: structured KEY=VALUE, one per line.              |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     Vérifications pré-vol pour l'onboarding. Détecte l'état du système
#     (sudo, git, deploy, GitHub, WSL) et produit un rapport KEY=VALUE structuré.
#
#     [EN]
#     NAME
#         onboard-preflight.sh — pre-flight checks for fleet onboarding
#
#     INTERFACE
#         Ring:    0 (setup)
#         Input:   system state (sudo, git, deploy markers, GitHub auth)
#         Output:  KEY=VALUE pairs to stdout (HAS_SUDO, HAS_GIT, DEPLOY_OK, etc.)
#
#     EXIT CODES
#         0    Always (report only)
#
# --- END HEADER ---

set -euo pipefail

# --- Fleet env ---
SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
FLEET_ENV="$SCRIPT_DIR/../fleet-env.sh"
[ -f "$FLEET_ENV" ] && source "$FLEET_ENV"

# --- Status ---
[ -f /home/fleet-state/.deploy_ok ] && echo "DEPLOY_OK=true" || echo "DEPLOY_OK=false"
[ -f /home/private/.offline-bootstrap ] && echo "OFFLINE_BOOTSTRAP=true" || echo "OFFLINE_BOOTSTRAP=false"

# --- Barrier 1: C:\ isolation ---
if touch /mnt/c/.fleet-sec-check 2>/dev/null; then
    rm -f /mnt/c/.fleet-sec-check 2>/dev/null
    if grep -qE '(enabled\s*=\s*false|options.*metadata)' /etc/wsl.conf 2>/dev/null; then
        echo "BARRIER1=PEND"
    else
        echo "BARRIER1=FAIL"
    fi
else
    echo "BARRIER1=OK"
fi

# --- Ready room ---
mountpoint -q /home/ready-room 2>/dev/null && echo "READY_ROOM=MOUNTED" || echo "READY_ROOM=NOT_MOUNTED"

# --- Git identity ---
if [ -f /home/private/git-identity.conf ] && grep -q "GIT_USER_NAME=" /home/private/git-identity.conf 2>/dev/null; then
    echo "GIT_ID=OK"
else
    echo "GIT_ID=MISSING"
fi

# --- GitHub auth ---
if gh auth status 2>&1 | grep -q "Logged in"; then
    GH_LOGIN=$(gh api user --jq '.login' 2>/dev/null || echo "")
    echo "GH_AUTH=OK"
    echo "GH_LOGIN=$GH_LOGIN"
else
    echo "GH_AUTH=MISSING"
    echo "GH_LOGIN="
fi

# --- Barrier 2: branch protection ---
REPO="${LCARS_REPO:-}"
[ -z "$REPO" ] && REPO="${GH_LOGIN:-}/LCARS-fleet"

_b2_result="CONFIGURABLE"
if [ -n "${GH_LOGIN:-}" ]; then
    _b2_prot=$(gh api "repos/${REPO}/branches/main/protection" 2>&1 || true)
    if echo "$_b2_prot" | jq -e '.required_pull_request_reviews' > /dev/null 2>&1; then
        _b2_result="OK"
    elif echo "$_b2_prot" | grep -q "Upgrade"; then
        _b2_result="NA_FREE_PRIVATE"
    else
        _b2_rules=$(gh api "repos/${REPO}/rulesets" 2>&1 || true)
        if echo "$_b2_rules" | grep -q "Upgrade"; then
            _b2_result="NA_FREE_PRIVATE"
        fi
    fi
fi
echo "BARRIER2=$_b2_result"

# --- Deploy check ---
DEPLOY_ALL=true
if ! command -v fleet_roles &>/dev/null && [ -f "$FLEET_YAML" ]; then
    fleet_roles() { yq '.instances[].role' "$FLEET_YAML"; }
fi
while IFS= read -r role; do
    h="$HOMES_ROOT/$role"
    if [ -f "$h/.claude/CLAUDE.md" ] && [ -L "$h/directives" ] && [ -L "$h/.claude/role.md" ]; then
        echo "DEPLOY_${role}=OK"
    else
        echo "DEPLOY_${role}=FAIL"
        DEPLOY_ALL=false
    fi
done < <(fleet_roles)
echo "DEPLOY_ALL=$DEPLOY_ALL"
