#!/usr/bin/env bash
# DEPLOY: none (called by post-reboot.sh)

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: provision-credentials.sh
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
#     | MODULE: CREDENTIALS     | SUBSYSTEM: PROVISIONING         |
#     | LICENSE: AGPL-3         | STARDATE: 2026.088              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Imports Anthropic credentials + GitHub auth to /private. |
#     |  Single owner of credential files in /home/private/.      |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     Importe les credentials Anthropic et l'auth GitHub dans /home/private/.
#     Owner unique des fichiers credentials dans /home/private/.
#
#     [EN]
#     NAME
#         provision-credentials.sh — import credentials to /home/private/
#
#     SYNOPSIS
#         provision-credentials.sh <source_credentials> [gh_hosts]
#
#     EXIT CODES
#         0    Credentials imported
#         1    Source credentials file missing
#
# --- END HEADER ---

set -euo pipefail

CREDS_SRC="${1:?usage: provision-credentials.sh <credentials.json> [gh-hosts.yml]}"
GH_HOSTS="${2:-}"
PRIVATE="/home/private"

G=$'\033[1;32m'; R=$'\033[1;31m'; Y=$'\033[1;33m'; N=$'\033[0m'

# Anthropic credentials
if [ ! -f "$CREDS_SRC" ]; then
    echo "${R}[credentials]${N} Source credentials not found: $CREDS_SRC" >&2
    exit 1
fi

sudo cp "$CREDS_SRC" "$PRIVATE/.credentials.json" \
    || { echo "${R}[credentials]${N} Copy failed — check permissions on $PRIVATE/" >&2; exit 1; }
sudo chmod 640 "$PRIVATE/.credentials.json"
# Verify copy succeeded
if [ ! -f "$PRIVATE/.credentials.json" ]; then
    echo "${R}[credentials]${N} Copy reported success but file missing" >&2
    exit 1
fi
echo "${G}[credentials]${N} Anthropic credentials → $PRIVATE/"

# GitHub auth (optional)
if [ -n "$GH_HOSTS" ] && [ -f "$GH_HOSTS" ]; then
    sudo cp "$GH_HOSTS" "$PRIVATE/gh-hosts.yml"
    sudo chmod 640 "$PRIVATE/gh-hosts.yml"
    echo "${G}[credentials]${N} GitHub auth → $PRIVATE/"
elif [ -n "$GH_HOSTS" ]; then
    echo "${Y}[credentials]${N} GitHub auth file not found: $GH_HOSTS — skipping"
else
    echo "${Y}[credentials]${N} No GitHub auth provided — will be configured via onboarding"
fi
