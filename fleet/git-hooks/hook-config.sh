#!/bin/bash
#
#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: hook-config.sh
#     |  |________|  | AUTHOR: LORDZURP
#     |   ________   | SYSTEM: LCARS-FLEET v5.4
#     |  |  v5.4  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: HOOK-CONFIG       | SUBSYSTEM: GIT-HOOKS / CONFIG  |
#     | LICENSE: AGPL-3           | STARDATE: 2026.090             |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Context detection for git hooks. Sources by pre-commit   |
#     |  and pre-push to adapt behavior per repo type.            |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#
#     [FR]
#     Configuration partagée des git hooks. Détecte le type de repo.
#
#     [EN]
#     NAME
#         hook-config.sh — shared context detection for git hooks
#
#     INTERFACE
#         Ring:    0 (gate)
#         Input:   git repo root (presence of fleet/fleet-env.sh)
#         Output:  exported variables: HOOK_REPO_TYPE (lcars|project),
#                  HOOK_DATE_FORMAT (stardate|iso), HOOK_DATE_FIELD,
#                  HOOK_POST_PUSH (fleet-update|none)
#
#     EXIT CODES
#         N/A (sourced by pre-commit/pre-push hooks)
#
# --- END HEADER ---

HOOK_REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo ".")"

# v7 #06: repo identity by fleet-env.sh presence
if [ -f "$HOOK_REPO_ROOT/fleet/fleet-env.sh" ]; then
    HOOK_REPO_TYPE="lcars"
    HOOK_DATE_FORMAT="stardate"
    HOOK_DATE_FIELD="STARDATE"
    HOOK_POST_PUSH="fleet-update"
else
    HOOK_REPO_TYPE="project"
    HOOK_DATE_FORMAT="iso"
    HOOK_DATE_FIELD="Dernière révision"
    HOOK_POST_PUSH="none"
fi

export HOOK_REPO_TYPE HOOK_DATE_FORMAT HOOK_DATE_FIELD HOOK_POST_PUSH
