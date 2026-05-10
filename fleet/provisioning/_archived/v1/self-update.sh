#!/bin/bash
#
#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: self-update.sh
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
#     | MODULE: SELF-UPDATE     | SUBSYSTEM: FLEET / LIFECYCLE    |
#     | LICENSE: AGPL-3         | STARDATE: 2026.070              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Pull latest LCARS into runtime + deploy to all agents.   |
#     |  Called by starfleet after architect pushes changes.       |
#     |                                                           |
#     +-----------------------------------------------------------+
#
# Usage: bash self-update.sh [--dry-run] [--force] [--source <path>]
#
#   --dry-run        Show what would be done, don't execute
#   --force          Run deploy even if already up to date
#   --source <path>  Pull from local clone instead of origin
#                    (default: git pull from origin)
#
# Normal flow:
#   1. engineer commits + pushes to GitHub from /home/projects/LCARS
#   2. starfleet detects or is notified via to-starfleet.md
#   3. starfleet runs: bash self-update.sh (pulls from origin/GitHub)
#   4. starfleet confirms in handoff
#   --source is for offline/emergency use only — GitHub is the sole channel

set -euo pipefail

# --- Fleet env ---
source "$(dirname "${BASH_SOURCE[0]}")/fleet-env.sh"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[self-update]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[self-update]${NC}  $*"; }
error() { echo -e "${RED}[self-update]${NC} $*" >&2; exit 1; }

DRY=0
SOURCE=""
FORCE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY=1; shift ;;
        --force)    FORCE=1; shift ;;
        --source)   SOURCE="${2:-}"; [ -z "$SOURCE" ] && error "--source requires a path"; shift 2 ;;
        *)          error "Unknown arg: $1" ;;
    esac
done

RUNTIME="$LCARS_ROOT"
DEPLOY="$RUNTIME/fleet/provisioning/deploy.sh"

[ -d "$RUNTIME/.git" ] || error "$RUNTIME is not a git repository"

# --- Current state ---
cd "$RUNTIME"
BEFORE=$(git rev-parse --short HEAD)
BRANCH=$(git branch --show-current)
info "runtime: $RUNTIME (branch: $BRANCH, at: $BEFORE)"

# --- Pull ---
if [[ $DRY -eq 1 ]]; then
    if [ -n "$SOURCE" ]; then
        info "[dry-run] would pull from local: $SOURCE ($BRANCH)"
    else
        info "[dry-run] would pull from origin ($BRANCH)"
    fi
    info "[dry-run] would run deploy.sh"
    exit 0
fi

if [ -n "$SOURCE" ]; then
    [ -d "$SOURCE/.git" ] || error "$SOURCE is not a git repository"
    info "pulling from local: $SOURCE"
    git pull "$SOURCE" "$BRANCH" --ff-only
else
    info "pulling from origin"
    git pull --ff-only
fi

AFTER=$(git rev-parse --short HEAD)
if [ "$BEFORE" = "$AFTER" ] && [ "$FORCE" -eq 0 ]; then
    info "already up to date ($AFTER) — skipping deploy (use --force to deploy anyway)"
    exit 0
fi

info "updated: $BEFORE → $AFTER"
git --no-pager log --oneline "$BEFORE".."$AFTER"

# --- Deploy ---
if [ -x "$DEPLOY" ]; then
    info "running deploy.sh..."
    bash "$DEPLOY"
    info "deploy complete"
else
    error "deploy.sh not found at $DEPLOY"
fi

info "self-update done: $BEFORE → $AFTER"
