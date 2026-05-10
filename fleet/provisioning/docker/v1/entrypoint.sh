#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: entrypoint.sh
#     |  |________|  | AUTHOR: LORDZURP
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
#     | MODULE: DOCKER-ENTRY    | SUBSYSTEM: DOCKER / RUNTIME     |
#     | LICENSE: AGPL-3         | STARDATE: 2026.090              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Docker entrypoint — bootstraps fleet inside container.   |
#     |  RUN-TIME only — user CLI is docker.sh at repo root.     |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     entrypoint.sh — bootstrap fleet dans le conteneur Docker.
#     Run-time : user, runtime, clone dev, credentials, deploy, shell.
#     L'user n'appelle jamais ce fichier — il utilise docker.sh.
#
#     [EN]
#     entrypoint.sh — Docker container runtime entrypoint.
#     User-facing CLI is docker.sh at repo root.

# --- END HEADER ---

set -euo pipefail

export LCARS_DOCKER=1

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
info()  { echo -e "${GREEN}[lcars]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[lcars]${NC}  $*"; }
error() { echo -e "${RED}[lcars]${NC} $*" >&2; }

# ─── Create fleet user ────────────────────────────────────────────────────────
REAL_USER="${LCARS_USER:-lcars}"
if ! id "$REAL_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$REAL_USER"
fi
echo "$REAL_USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/lcars-user
chmod 440 /etc/sudoers.d/lcars-user
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

# ─── Runtime — copy from build context ───────────────────────────────────────
LCARS_RUNTIME="/local/LCARS"
if [ ! -d "$LCARS_RUNTIME/fleet" ]; then
    mkdir -p "$LCARS_RUNTIME"
    cp -a /tmp/lcars-install/. "$LCARS_RUNTIME/"
fi

# ─── Fix fleet_user in fleet.yaml ────────────────────────────────────────────
FLEET_YAML="$LCARS_RUNTIME/fleet/fleet.yaml"
if [ -f "$FLEET_YAML" ] && grep -q "fleet_user:" "$FLEET_YAML"; then
    sed "s/fleet_user:.*/fleet_user: $REAL_USER/" "$FLEET_YAML" > "${FLEET_YAML}.tmp" && mv -f "${FLEET_YAML}.tmp" "$FLEET_YAML"
    sed "s/windows_user:.*/windows_user: $REAL_USER/" "$FLEET_YAML" > "${FLEET_YAML}.tmp" && mv -f "${FLEET_YAML}.tmp" "$FLEET_YAML"
fi

# ─── Git clone — dev copy with .git (triangle source→GitHub→runtime) ─────────
LCARS_DEV="/home/projects/LCARS"
LCARS_REPO="${LCARS_REPO:-lordzurp/LCARS-fleet}"
if [ ! -d "$LCARS_DEV/.git" ]; then
    info "Cloning $LCARS_REPO → $LCARS_DEV..."
    mkdir -p /home/projects
    git clone "https://github.com/${LCARS_REPO}.git" "$LCARS_DEV" 2>&1 || \
        warn "git clone failed — git push will not work (read-only mode)"
fi

# ─── Git identity from env vars ──────────────────────────────────────────────
GIT_USER_NAME="${GIT_USER_NAME:-Docker User}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-docker@lcars-fleet}"
mkdir -p /home/private
cat > /home/private/git-identity.conf <<GITEOF
GIT_USER_NAME=$GIT_USER_NAME
GIT_USER_EMAIL=$GIT_USER_EMAIL
GITEOF
chmod 640 /home/private/git-identity.conf

# ─── Install ─────────────────────────────────────────────────────────────────
info "Running install..."
INSTALL_FAILED=0
if ! SUDO_USER="$REAL_USER" bash "$LCARS_RUNTIME/fleet/provisioning/provision-fleet.sh" < /dev/null 2>&1; then
    error "install.sh FAILED — fleet may not work correctly"
    INSTALL_FAILED=1
fi

# ─── Credentials — OAuth or API key ──────────────────────────────────────────
CREDS_FILE="$REAL_HOME/.claude/.credentials.json"

if [ -f "$CREDS_FILE" ]; then
    info "Credentials found (mounted volume) — reusing"
    cp "$CREDS_FILE" /home/private/.credentials.json
    chmod 640 /home/private/.credentials.json
elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    info "API key detected — creating credentials..."
    mkdir -p "$REAL_HOME/.claude"
    python3 -c "import json,sys; print(json.dumps({'claudeAiApiKey': sys.argv[1]}))" "$ANTHROPIC_API_KEY" > /home/private/.credentials.json
    chmod 640 /home/private/.credentials.json
    cp /home/private/.credentials.json "$CREDS_FILE"
    chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.claude"
elif [ -f /run/secrets/api_key ]; then
    info "API key from Docker secret"
    mkdir -p "$REAL_HOME/.claude"
    python3 -c "import json,sys; print(json.dumps({'claudeAiApiKey': sys.stdin.read().strip()}))" < /run/secrets/api_key > /home/private/.credentials.json
    chmod 640 /home/private/.credentials.json
    cp /home/private/.credentials.json "$CREDS_FILE"
    chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.claude"
else
    info "No credentials found."
    info "Run 'claude' and complete the OAuth login (browser will open)."
fi

# ─── GitHub CLI auth (if GH_TOKEN provided) ──────────────────────────────────
if [ -n "${GH_TOKEN:-}" ]; then
    info "Configuring gh auth from GH_TOKEN..."
    sudo -u "$REAL_USER" gh auth login --with-token <<< "$GH_TOKEN" 2>/dev/null \
        && info "gh auth OK" \
        || warn "gh auth failed — PR operations will not work"
    sudo -u "$REAL_USER" gh auth setup-git 2>/dev/null || true
fi

# ─── Provision + deploy ──────────────────────────────────────────────────────
info "Provisioning agents..."
if ! SUDO_USER="$REAL_USER" bash "$LCARS_RUNTIME/fleet/provisioning/provision-users.sh" "$REAL_USER" 2>&1; then
    warn "provision-users.sh failed — some agents may not be configured"
fi

info "Deploying fleet..."
if ! bash "$LCARS_RUNTIME/fleet/provisioning/deploy.sh" 2>&1; then
    warn "deploy.sh failed — fleet config may be incomplete"
fi

# ─── Install git hooks on dev clone ──────────────────────────────────────────
if [ -d "$LCARS_DEV/.git" ] && [ -x "$LCARS_RUNTIME/fleet/git-hooks/install-hooks.sh" ]; then
    bash "$LCARS_RUNTIME/fleet/git-hooks/install-hooks.sh" --repo "$LCARS_DEV" 2>/dev/null || true
fi

# ─── Fleet commands ───────────────────────────────────────────────────────────
cat > /usr/local/bin/fleet-arch << 'ARCHEOF'
#!/bin/bash
[ -f /home/fleet-state/.deploy_ok ] || { echo "Fleet pas déployée. Lancez fleet-sf pour l'onboarding."; exit 1; }
exec sudo -u architect -i
ARCHEOF
chmod 755 /usr/local/bin/fleet-arch

cat > /usr/local/bin/fleet-sf << 'SFEOF'
#!/bin/bash
exec sudo -u starfleet -i
SFEOF
chmod 755 /usr/local/bin/fleet-sf

# ─── Sentinels ────────────────────────────────────────────────────────────────
mkdir -p /home/private
touch /home/private/.fleet_ready
if [ -f /home/private/.credentials.json ]; then
    touch /home/fleet-state/.deploy_ok
fi

# ─── Banner ───────────────────────────────────────────────────────────────────
CREDS_STATUS="${RED}NOT SET — run 'claude' to login${NC}"
[ -f /home/private/.credentials.json ] && CREDS_STATUS="${GREEN}OK${NC}"
GH_STATUS="${RED}NOT SET — pass GH_TOKEN for git push${NC}"
[ -n "${GH_TOKEN:-}" ] && GH_STATUS="${GREEN}OK${NC}"
GIT_STATUS="${RED}NO CLONE${NC}"
[ -d "$LCARS_DEV/.git" ] && GIT_STATUS="${GREEN}OK — $(git -C "$LCARS_DEV" remote get-url origin 2>/dev/null)${NC}"

echo ""
if [[ "${INSTALL_FAILED:-0}" -eq 1 ]]; then
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}  LCARS-FLEET — Docker — INSTALL FAILED${NC}"
    echo -e "${RED}  Check logs above for errors.${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
else
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  LCARS-FLEET — Docker${NC}"
    echo ""
    echo -e "  User:        $REAL_USER"
    echo -e "  Runtime:     /local/LCARS"
    echo -e "  Dev clone:   $GIT_STATUS"
    echo -e "  Credentials: $CREDS_STATUS"
    echo -e "  GitHub CLI:  $GH_STATUS"
    echo ""
    if [ ! -f /home/fleet-state/.deploy_ok ]; then
        echo "  First run — complete setup:"
        echo "    1. claude        — OAuth login (browser opens on host)"
        echo "    2. /exit"
        echo "    3. fleet-sf      — security onboarding"
        echo ""
    fi
    echo "  Commands:"
    echo "    fleet-sf     — StarFleet (system admin)"
    echo "    fleet-arch   — Architect (interactive session)"
    echo "    ~/start      — full fleet dashboard (tmux)"
    echo "    claude       — vanilla Claude (no fleet)"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
fi

# ─── Drop to interactive shell ────────────────────────────────────────────────
exec sudo -u "$REAL_USER" -i
