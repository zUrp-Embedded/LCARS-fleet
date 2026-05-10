#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-codex.sh
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
#     | MODULE: FLEET-CODEX       | SUBSYSTEM: TOOLBOX / EXTERNAL |
#     | LICENSE: AGPL-3           | STARDATE: 2026.090            |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Launches Codex (external agent) in its own user context. |
#     |  Deploys config before launch. Not a fleet agent.         |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     Lance Codex (agent externe) sous son user Linux dédié.
#     Déploie la config avant lancement. Pas un agent fleet.
#
#     [EN]
#     NAME
#         fleet-codex.sh — launch Codex external agent
#
#     SYNOPSIS
#         fleet-codex.sh
#
#     DESCRIPTION
#         Deploys Codex config from repo, then launches `codex` as the
#         codex Linux user. Codex reads /home/projects/ directly (ACL).
#
#     INTERFACE
#         Ring:    4 (support)
#         Input:   /home/codex/, fleet/external-agents/codex/ (config)
#         Output:  interactive codex session
#         JSON:    non
#
#     EXIT CODES
#         0    Normal exit
#         1    Codex user or binary not found
#
# --- END HEADER ---

set -uo pipefail

# --- Checks ---
if ! id codex &>/dev/null; then
    echo "ERROR: user 'codex' does not exist — run provision-system.sh first" >&2
    exit 1
fi

if ! command -v codex &>/dev/null; then
    echo "ERROR: codex CLI not found in PATH" >&2
    exit 1
fi

# --- Deploy config + instructions from repo ---
# Config files are lordzurp-owned (immutable for codex). Provisioning sets permissions.
CODEX_CONFIG_SRC="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../external-agents/codex"
if [ -d "$CODEX_CONFIG_SRC" ]; then
    for _f in config.toml AGENTS.md; do
        if [ -f "$CODEX_CONFIG_SRC/$_f" ] && ! cmp -s "$CODEX_CONFIG_SRC/$_f" "/home/codex/.codex/$_f" 2>/dev/null; then
            cp "$CODEX_CONFIG_SRC/$_f" "/home/codex/.codex/$_f"
            chmod 644 "/home/codex/.codex/$_f"
            echo "[fleet-codex] deployed $_f"
        fi
    done
fi

# --- Launch ---
echo "[fleet-codex] launching codex as user 'codex' in /home/codex/"
exec sudo -u codex -i codex
