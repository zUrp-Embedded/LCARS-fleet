#!/usr/bin/env bash
# DEPLOY: none (called by provision-fleet.sh)

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: provision-project-seed.sh
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
#     | MODULE: PROJECT-SEED    | SUBSYSTEM: PROVISIONING         |
#     | LICENSE: AGPL-3         | STARDATE: 2026.088              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Seeds /home/projects/LCARS from runtime.                 |
#     |  Creates the dev working copy if absent.                  |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     Crée la copie de travail /home/projects/LCARS depuis le runtime.
#     Si elle existe avec .git, pull --ff-only. Sinon, skip.
#
#     [EN]
#     NAME
#         provision-project-seed.sh — seed /home/projects/LCARS from runtime
#
#     SYNOPSIS
#         provision-project-seed.sh <fleet_user>
#
#     EXIT CODES
#         0    Seed complete or skipped
#
# --- END HEADER ---

set -euo pipefail

FLEET_USER="${1:?usage: provision-project-seed.sh <fleet_user>}"
LCARS_RUNTIME="/local/LCARS"
LCARS_PROJECT="/home/projects/LCARS"

info() { echo -e "\033[0;32m[project-seed]\033[0m  $*"; }

if [ ! -d "$LCARS_PROJECT" ]; then
    info "seeding $LCARS_PROJECT from runtime"
    mkdir -p "$(dirname "$LCARS_PROJECT")"
    chown "$FLEET_USER:$FLEET_USER" "$(dirname "$LCARS_PROJECT")"
    sudo -u "$FLEET_USER" cp -a "$LCARS_RUNTIME" "$LCARS_PROJECT"
    info "seed done"
elif [ -d "$LCARS_PROJECT/.git" ]; then
    info "project exists with git — pulling"
    sudo -u "$FLEET_USER" git -C "$LCARS_PROJECT" pull --ff-only 2>/dev/null || true
else
    info "project exists — skipping"
fi
