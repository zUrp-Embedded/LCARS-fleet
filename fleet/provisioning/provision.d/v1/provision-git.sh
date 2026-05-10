#!/bin/bash
# DEPLOY: instance-util

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: provision-git.sh
#     |  |________|  | AUTHOR: STARFLEET
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
#     | MODULE: PROVISION-GIT   | SUBSYSTEM: PROVISIONING / SYSTEM |
#     | LICENSE: AGPL-3         | STARDATE: 2026.090            |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Configure git repos, auth (PAT + SSH), identity, remote. |
#     |  Sourced by provision-system.sh. PAT-first, SSH backup.   |
#     |                                                           |
#     +-----------------------------------------------------------+
#
# CALLED BY   : provision-system.sh
# WHY         : Git auth is required for fleet-update.sh pull + agent push
# CONSTRAINTS : PAT must be in /home/private/.github-token before this runs
#
#     [FR]
#     provision-git.sh — configure git auth (PAT + SSH), repos, identité.
#     PAT via gh credential helper = chemin principal. SSH = backup.
#
#     [EN]
#     provision-git.sh — Configure git repos, auth (PAT + SSH), identity, remote.
#     Sourced by provision-system.sh. PAT-first, SSH backup.
#
# --- END HEADER ---

echo ""
echo "=== Git ==="
RUNTIME_USER=$(while IFS= read -r r; do
    [[ "$(fleet_role_field "$r" "sudo")" == "full" ]] && echo "$r" && break
done < <(fleet_roles)) || true
: "${RUNTIME_USER:=starfleet}"
GH_BIN="$(command -v gh 2>/dev/null || true)"
PRIVATE="/home/private"
PAT_FILE="$PRIVATE/.github-token"

# --- safe.directory for all users that touch LCARS repos ---
# Must be BEFORE any git operation on these repos
for repo_dir in /home/projects/LCARS "$LCARS_ROOT"; do
    git config --global --add safe.directory "$repo_dir" 2>/dev/null || true  # root (this script)
    sudo -u "$FLEET_USER" git config --global --add safe.directory "$repo_dir" 2>/dev/null || true
    sudo -u "$RUNTIME_USER" git config --global --add safe.directory "$repo_dir" 2>/dev/null || true
done

# --- PAT authentication (primary path) ---
echo ""
echo "=== GitHub auth (PAT) ==="
if [ -f "$PAT_FILE" ] && [ -s "$PAT_FILE" ] && [ -n "$GH_BIN" ]; then
    # Authenticate gh for fleet_user + runtime_user + all pushing agents
    for _auth_user in "$FLEET_USER" "$RUNTIME_USER"; do
        if [[ $CHECK -eq 0 ]]; then
            sudo -u "$_auth_user" bash -c "cat '$PAT_FILE' | '$GH_BIN' auth login --with-token 2>/dev/null" \
                && pass "gh:auth — $_auth_user authenticated via PAT" \
                || warn "gh:auth — $_auth_user PAT login failed"
            sudo -u "$_auth_user" "$GH_BIN" auth setup-git 2>/dev/null || true
        else
            if sudo -u "$_auth_user" "$GH_BIN" auth status &>/dev/null; then
                pass "gh:auth — $_auth_user authenticated"
            else
                fail "gh:auth — $_auth_user not authenticated"
            fi
        fi
    done
    # Propagate to agents with code scope (they push project repos)
    while IFS= read -r _role; do
        _scope="$(fleet_role_field "$_role" "scope")"
        [[ "$_scope" == "code" ]] || continue
        [[ "$_role" == "$RUNTIME_USER" ]] && continue  # already done
        if [[ $CHECK -eq 0 ]]; then
            sudo -u "$_role" bash -c "cat '$PAT_FILE' | '$GH_BIN' auth login --with-token 2>/dev/null" \
                && pass "gh:auth — $_role authenticated via PAT" \
                || warn "gh:auth — $_role PAT login failed"
            sudo -u "$_role" "$GH_BIN" auth setup-git 2>/dev/null || true
        fi
    done < <(fleet_roles)
elif [ -f "$PAT_FILE" ] && [ -z "$GH_BIN" ]; then
    warn "gh:auth — PAT exists but gh CLI not found"
else
    warn "gh:auth — no PAT at $PAT_FILE (will be created during onboarding)"
fi

# --- Repo ownership + shared config ---
REPO_URL=$(yq '.fleet.repo' "$FLEET_YAML" 2>/dev/null)
[[ "$REPO_URL" == "null" || -z "$REPO_URL" ]] && REPO_URL=""

for repo_dir in /home/projects/LCARS "$LCARS_ROOT"; do
    REPO_OWNER="$RUNTIME_USER"
    if [ -d "$repo_dir/.git" ]; then
        if [[ $CHECK -eq 0 ]]; then
            chown -R "$REPO_OWNER:$FLEET_GROUP" "$repo_dir" 2>/dev/null || true
            find "$repo_dir" -type d -exec chmod g+ws {} \; 2>/dev/null || true
            find "$repo_dir" -not -path "$repo_dir/.git/objects/*" -type f -exec chmod g+rw {} \; 2>/dev/null || true
            git -C "$repo_dir" config core.sharedRepository group 2>/dev/null || true
        fi
        pass "git:$repo_dir — shared repo ($REPO_OWNER)"
    else
        pass "git:$repo_dir — not yet cloned (OK at install time)"
    fi
done

# --- Remote URL: HTTPS (if gh authenticated) or SSH (fallback) ---
echo ""
echo "=== Git remote ==="
LCARS_DEV="/home/projects/LCARS"
if [ -d "$LCARS_DEV/.git" ] && [ -n "$REPO_URL" ]; then
    CURRENT_REMOTE=$(sudo -u "$RUNTIME_USER" git -C "$LCARS_DEV" remote get-url origin 2>/dev/null || true)
    HTTPS_REMOTE="https://github.com/${REPO_URL}.git"
    SSH_REMOTE="git@github.com:${REPO_URL}.git"

    # HTTPS always works for public repos (no auth needed for pull).
    # SSH only if gh authenticated AND key uploaded (both conditions met).
    TARGET_REMOTE="$HTTPS_REMOTE"
    REMOTE_LABEL="HTTPS"
    if [ -n "$GH_BIN" ] && sudo -u "$RUNTIME_USER" "$GH_BIN" auth status &>/dev/null 2>&1; then
        REMOTE_LABEL="HTTPS (gh credential helper)"
    fi

    if [[ "$CURRENT_REMOTE" == "$TARGET_REMOTE" ]]; then
        pass "git:remote — dev clone already $REMOTE_LABEL"
    else
        if [[ $CHECK -eq 0 ]]; then
            sudo -u "$RUNTIME_USER" git -C "$LCARS_DEV" remote set-url origin "$TARGET_REMOTE"
            pass "git:remote — dev clone → $REMOTE_LABEL"
        else
            fail "git:remote — dev clone is $CURRENT_REMOTE (expected $TARGET_REMOTE)"
        fi
    fi
    # Same for runtime
    if [ -d "$LCARS_ROOT/.git" ]; then
        CURRENT_RT=$(git -C "$LCARS_ROOT" remote get-url origin 2>/dev/null || true)
        if [[ "$CURRENT_RT" != "$TARGET_REMOTE" ]] && [[ $CHECK -eq 0 ]]; then
            git -C "$LCARS_ROOT" remote set-url origin "$TARGET_REMOTE"
            pass "git:remote — runtime → $REMOTE_LABEL"
        fi
    fi
fi

# --- SSH key (backup — always generated, uploaded if gh available) ---
echo ""
echo "=== StarFleet SSH key (backup) ==="
SF_HOME="$(eval echo ~"$RUNTIME_USER")"
SF_SSH_DIR="$SF_HOME/.ssh"
SF_SSH_KEY="$SF_SSH_DIR/github_starfleet"

if [ -f "$SF_SSH_KEY" ]; then
    pass "ssh:starfleet-key — exists"
else
    if [[ $CHECK -eq 0 ]]; then
        sudo -u "$RUNTIME_USER" mkdir -p "$SF_SSH_DIR"
        sudo -u "$RUNTIME_USER" chmod 700 "$SF_SSH_DIR"
        sudo -u "$RUNTIME_USER" ssh-keygen -t ed25519 \
            -C "starfleet@lcars-fleet" \
            -f "$SF_SSH_KEY" -N ""
        pass "ssh:starfleet-key — generated"
    else
        fail "ssh:starfleet-key — absent"
    fi
fi

# Seed known_hosts (idempotent)
if [ -d "$SF_SSH_DIR" ] && ! grep -q "github.com" "$SF_SSH_DIR/known_hosts" 2>/dev/null; then
    if [[ $CHECK -eq 0 ]]; then
        ssh-keyscan github.com 2>/dev/null | sudo -u "$RUNTIME_USER" tee -a "$SF_SSH_DIR/known_hosts" > /dev/null
        pass "ssh:known_hosts — github.com added"
    fi
fi

# Upload SSH key to GitHub (if gh authenticated — idempotent)
if [ -f "$SF_SSH_KEY.pub" ] && [ -n "$GH_BIN" ] && "$GH_BIN" auth status &>/dev/null; then
    if [[ $CHECK -eq 0 ]]; then
        "$GH_BIN" ssh-key add "$SF_SSH_KEY.pub" --title "starfleet-lcars" 2>/dev/null \
            && pass "ssh:github — key uploaded" \
            || pass "ssh:github — key already registered"
    fi
fi

# SSH config (for fallback SSH access)
SF_SSH_CONFIG="$SF_SSH_DIR/config"
if [ -d "$SF_SSH_DIR" ] && ! grep -q "github_starfleet" "$SF_SSH_CONFIG" 2>/dev/null; then
    if [[ $CHECK -eq 0 ]]; then
        printf 'Host github.com\n    HostName github.com\n    User git\n    IdentityFile %s\n    IdentitiesOnly yes\n' \
            "$SF_SSH_KEY" | sudo -u "$RUNTIME_USER" tee -a "$SF_SSH_CONFIG" > /dev/null
        sudo -u "$RUNTIME_USER" chmod 600 "$SF_SSH_CONFIG"
        pass "ssh:config — github_starfleet entry added"
    fi
fi

# --- Git identity ---
echo ""
echo "=== StarFleet git identity ==="
SF_GIT_NAME=$(sudo -u "$RUNTIME_USER" git config --global user.name 2>/dev/null || true)
SF_GIT_EMAIL=$(sudo -u "$RUNTIME_USER" git config --global user.email 2>/dev/null || true)
if [[ -n "$SF_GIT_NAME" && -n "$SF_GIT_EMAIL" ]]; then
    pass "git:identity — $RUNTIME_USER: $SF_GIT_NAME <$SF_GIT_EMAIL>"
else
    if [[ $CHECK -eq 0 ]]; then
        sudo -u "$RUNTIME_USER" git config --global user.name "StarFleet"
        sudo -u "$RUNTIME_USER" git config --global user.email "starfleet@lcars-fleet"
        pass "git:identity — $RUNTIME_USER: StarFleet <starfleet@lcars-fleet>"
    else
        fail "git:identity — $RUNTIME_USER: not configured"
    fi
fi

# --- Verification gate ---
echo ""
echo "=== GitHub connectivity ==="
if [ -n "$GH_BIN" ] && [ -n "$REPO_URL" ]; then
    if sudo -u "$RUNTIME_USER" "$GH_BIN" repo view "$REPO_URL" &>/dev/null; then
        pass "github:access — can reach $REPO_URL"
    elif sudo -u "$RUNTIME_USER" ssh -T git@github.com 2>&1 | grep -qi "successfully"; then
        pass "github:access — SSH fallback works"
    else
        warn "github:access — cannot reach $REPO_URL (PAT or SSH may need setup via onboarding)"
    fi
fi
