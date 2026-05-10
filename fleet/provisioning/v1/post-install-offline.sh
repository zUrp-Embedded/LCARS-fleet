#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: post-install-offline.sh
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
#     | MODULE: POST-INSTALL-OFF| SUBSYSTEM: FLEET / INSTALL      |
#     | LICENSE: AGPL-3         | STARDATE: 2026.087              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Post-install steps for offline/air-gapped setup.         |
#     |  Runs without network access.                             |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     Étapes post-install pour setup offline/air-gapped.
#     Fonctionne sans accès réseau. Initialise git local, build-yaml, deploy.
#
#     [EN]
#     NAME
#         post-install-offline.sh — post-install for offline/air-gapped setup
#
#     INTERFACE
#         Ring:    0 (setup)
#         Input:   offline bootstrap marker, local LCARS runtime
#         Output:  initialized git repo, fleet.yaml, deployed configs
#
#     EXIT CODES
#         0    Post-install completed
#         1    Not root
#
# --- END HEADER ---

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[post-install]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[post-install]${NC}  $*"; }
error() { echo -e "${RED}[post-install]${NC} $*" >&2; exit 1; }

SENTINEL="/home/private/.offline-bootstrap"
REAL_USER="$(id -un)"
LCARS_RUNTIME="/local/LCARS"
LCARS_PROJECT="/home/projects/LCARS"

[ -f "$SENTINEL" ] || error "No offline sentinel found — nothing to do."

# If gh auth not available for current user, try propagating from invoking user (sudo -u context)
if ! gh auth status > /dev/null 2>&1; then
    GH_CONFIG_SRC="${SUDO_USER:+/home/${SUDO_USER}/.config/gh}"
    if [ -n "$GH_CONFIG_SRC" ] && [ -d "$GH_CONFIG_SRC" ]; then
        mkdir -p "$HOME/.config/gh"
        cp "$GH_CONFIG_SRC/hosts.yml" "$HOME/.config/gh/hosts.yml" 2>/dev/null || true
        cp "$GH_CONFIG_SRC/config.yml" "$HOME/.config/gh/config.yml" 2>/dev/null || true
    fi
    gh auth status > /dev/null 2>&1 || error "GitHub not authenticated. Run: gh auth login"
fi

# Read repo+branch from fleet.yaml (source of truth — sentinel is a flag-only file)
_FLEET_YAML=""
[ -f "$LCARS_PROJECT/fleet/fleet.yaml" ] && _FLEET_YAML="$LCARS_PROJECT/fleet/fleet.yaml"
[ -z "$_FLEET_YAML" ] && [ -f "$LCARS_RUNTIME/fleet/fleet.yaml" ] && _FLEET_YAML="$LCARS_RUNTIME/fleet/fleet.yaml"
[ -z "$_FLEET_YAML" ] && error "fleet.yaml not found in project or runtime"
_repo="$(grep '^\s*repo:' "$_FLEET_YAML" | awk '{print $2}')"
_branch="$(grep '^\s*branch:' "$_FLEET_YAML" | awk '{print $2}')"
REPO_URL="${_repo:+https://github.com/${_repo}.git}"
BRANCH="$_branch"
: "${REPO_URL:=https://github.com/lordzurp/LCARS-fleet.git}"
: "${BRANCH:=v5.2}"

info "repo: $REPO_URL (branch: $BRANCH)"

# ─── 1. Git credential helper ────────────────────────────────────────────────
GH_BIN="$(command -v gh)"
sudo -u "$REAL_USER" git config --global credential.helper "$GH_BIN auth git-credential"
info "credential.helper configured"

# ─── 2. Git identity ─────────────────────────────────────────────────────────
if [ -f /home/private/git-identity.conf ]; then
    _name="$(grep -E '^GIT_USER_NAME=' /home/private/git-identity.conf | cut -d= -f2 || true)"
    _email="$(grep -E '^GIT_USER_EMAIL=' /home/private/git-identity.conf | cut -d= -f2 || true)"
    [ -n "${_name:-}" ] && sudo -u "$REAL_USER" git config --global user.name "$_name"
    [ -n "${_email:-}" ] && sudo -u "$REAL_USER" git config --global user.email "$_email"
    info "git identity: ${_name} <${_email}>"
fi

# ─── 3. Safe directories (must precede git operations) ─────────────────────
git config --global --add safe.directory "$LCARS_RUNTIME" 2>/dev/null || true
git config --global --add safe.directory "$LCARS_PROJECT" 2>/dev/null || true

# ─── 4. Connect runtime to GitHub ─── ────────────────────────────────────────────
# Runtime must be owned by fleet-update.sh runner (SUDO_USER = starfleet in onboard context)
RUNTIME_USER="${SUDO_USER:-starfleet}"
if ! git -C "$LCARS_RUNTIME" remote get-url origin &>/dev/null; then
    info "initializing runtime git → $BRANCH"
    [ -d "$LCARS_RUNTIME/.git" ] || git -C "$LCARS_RUNTIME" init -b "$BRANCH"
    git -C "$LCARS_RUNTIME" remote remove origin 2>/dev/null || true
    git -C "$LCARS_RUNTIME" remote add origin "$REPO_URL"
    git -C "$LCARS_RUNTIME" fetch origin "$BRANCH"
    git -C "$LCARS_RUNTIME" reset --hard "origin/$BRANCH"
    git -C "$LCARS_RUNTIME" branch --set-upstream-to="origin/$BRANCH" "$BRANCH"
    chown -R "$RUNTIME_USER:$RUNTIME_USER" "$LCARS_RUNTIME"
    sudo -u "$RUNTIME_USER" git config --global credential.helper \
        "$GH_BIN auth git-credential" 2>/dev/null || true
    info "runtime connected to origin/$BRANCH (owner: $RUNTIME_USER)"
else
    info "runtime already a git repo — skipping init"
fi

# ─── 4. Connect project to GitHub ────────────────────────────────────────────
if ! sudo -u "$REAL_USER" git -C "$LCARS_PROJECT" remote get-url origin &>/dev/null; then
    info "initializing project git → $BRANCH"
    [ -d "$LCARS_PROJECT/.git" ] || sudo -u "$REAL_USER" git -C "$LCARS_PROJECT" init -b "$BRANCH"
    sudo -u "$REAL_USER" git -C "$LCARS_PROJECT" remote remove origin 2>/dev/null || true
    sudo -u "$REAL_USER" git -C "$LCARS_PROJECT" remote add origin "$REPO_URL"
    sudo -u "$REAL_USER" git -C "$LCARS_PROJECT" fetch origin "$BRANCH"
    sudo -u "$REAL_USER" git -C "$LCARS_PROJECT" reset --hard "origin/$BRANCH"
    sudo -u "$REAL_USER" git -C "$LCARS_PROJECT" branch --set-upstream-to="origin/$BRANCH" "$BRANCH"
    info "project connected to origin/$BRANCH"
else
    info "project already a git repo — skipping init"
fi

# ─── 6. Remove sentinel ──────────────────────────────────────────────────────
rm -f "$SENTINEL"
info "sentinel removed — offline bootstrap complete"

info "→ fleet-update.sh can now run normally"
