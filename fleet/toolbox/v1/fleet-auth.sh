#!/usr/bin/env bash
# DEPLOY: instance-util

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-auth.sh
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
#     | MODULE: FLEET-AUTH      | SUBSYSTEM: TOOLBOX / MAINT      |
#     | LICENSE: AGPL-3         | STARDATE: 2026.087              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Authenticate fleet agents with Anthropic OAuth.          |
#     |  Skips agents that already have valid credentials.        |
#     |  Interactive — opens browser for each unauthenticated     |
#     |  agent. Idempotent: re-run safely.                        |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     fleet-auth.sh — authentifie tous les agents fleet aupres d'Anthropic.
#     Chaque agent a son propre token OAuth. Processus interactif (browser).
#     Idempotent : skip les agents deja authentifies.
#
#     [EN]
#     NAME
#         fleet-auth.sh — authenticate all fleet agents with Anthropic
#
#     SYNOPSIS
#         sudo fleet-auth.sh
#
#     DESCRIPTION
#         Iterates over all fleet agents and runs claude auth login for
#         each one that lacks valid credentials. Each login opens a browser
#         for OAuth. Tedious but required — one token per agent, no sharing.
#
#     INTERFACE
#         Ring:    Toolbox (maintenance, interactive)
#         Input:   none (interactive — browser OAuth)
#         Output:  stdout progress per agent
#         Env:     requires root (sudo)
#
#     DEPENDENCIES
#         jq (>= 1.6), claude CLI, fleet-env.sh (fleet_roles)
#
#     EXIT CODES
#         0    All agents authenticated (or skipped)
#         1    Must run as root
#
#     SEE ALSO
#         onboard_v2 skill (invokes fleet-auth.sh during setup)
#
# --- END HEADER ---

set -euo pipefail

[[ $EUID -eq 0 ]] || { printf 'ERROR: must run as root (sudo fleet-auth.sh)\n' >&2; exit 1; }
command -v jq &>/dev/null || { printf 'ERROR: jq required\n' >&2; exit 1; }

# Source fleet-env for fleet_roles
SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
readonly SCRIPT_DIR
FLEET_ENV="$SCRIPT_DIR/../fleet-env.sh"
readonly FLEET_ENV
# shellcheck source=../fleet-env.sh
[[ -f "$FLEET_ENV" ]] && source "$FLEET_ENV"

readonly G=$'\033[1;32m' Y=$'\033[1;33m' W=$'\033[1;37m' N=$'\033[0m'
readonly AMBER=$'\033[38;5;214m'

AUTH_COUNT=0
AUTH_TOTAL=0

# Collect roles into array FIRST — avoids stdin leak to claude
mapfile -t AGENTS < <(fleet_roles)

for agent in "${AGENTS[@]}"; do
    AUTH_TOTAL=$((AUTH_TOTAL + 1))
    cred="/home/$agent/.claude/.credentials.json"
    if [[ -f "$cred" ]] && token=$(jq -r '.claudeAiOauth.accessToken // empty' "$cred" 2>/dev/null) && [[ -n "$token" ]]; then
        printf '  %s[OK]%s %s — already authenticated\n' "$G" "$N" "$agent"
        AUTH_COUNT=$((AUTH_COUNT + 1))
        continue
    fi
    echo ""
    echo "  ${AMBER}╔═══════════════════════════════════════════════════╗${N}"
    echo "  ${AMBER}║${W}  Agent: $agent$(printf '%*s' $((43 - ${#agent})) '')${AMBER}║${N}"
    echo "  ${AMBER}║${N}                                                   ${AMBER}║${N}"
    echo "  ${AMBER}║${N}  Tapez ${W}/login${N} puis ${W}/exit${N} pour continuer.       ${AMBER}║${N}"
    echo "  ${AMBER}║${N}  (Si le wizard demande un lien, copiez-le         ${AMBER}║${N}"
    echo "  ${AMBER}║${N}  dans votre navigateur.)                           ${AMBER}║${N}"
    echo "  ${AMBER}╚═══════════════════════════════════════════════════╝${N}"
    echo ""
    sudo -i -u "$agent" claude --dangerously-skip-permissions || true
    # No post-wizard check — false negatives. Re-run fleet-auth to verify.
done

# Re-scan all agents for final count (pre-check may have caught some, wizard did others)
AUTH_COUNT=0
for agent in "${AGENTS[@]}"; do
    cred="/home/$agent/.claude/.credentials.json"
    if [[ -f "$cred" ]] && token=$(jq -r '.claudeAiOauth.accessToken // empty' "$cred" 2>/dev/null) && [[ -n "$token" ]]; then
        AUTH_COUNT=$((AUTH_COUNT + 1))
    fi
done
printf '\n  Authenticated: %d / %d agents\n' "$AUTH_COUNT" "$AUTH_TOTAL"
if [[ "$AUTH_COUNT" -lt "$AUTH_TOTAL" ]]; then
    printf '  %sRe-run sudo fleet-auth to authenticate remaining agents.%s\n' "$Y" "$N"
fi
