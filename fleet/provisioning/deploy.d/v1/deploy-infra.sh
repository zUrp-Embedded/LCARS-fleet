#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: deploy-infra.sh
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
#     | MODULE: DEPLOY-INFRA    | SUBSYSTEM: PROVISIONING / DEPLOY|
#     | LICENSE: AGPL-3         | STARDATE: 2026.090              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Deploy spool dirs, systemd units, toolbox, symlinks, chown.|
#     |  Sourced by deploy.sh. Handles IPC infrastructure + git hooks.|
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     Déploie l'infrastructure : spool IPC (inbox/outbox/pending-wakes), units systemd,
#     toolbox, symlinks (L2, .lcars, fleet-sf/arch), git hooks, chown final.
#
#     [EN]
#     NAME
#         deploy-infra.sh — deploy IPC spool, systemd, toolbox, symlinks, final chown
#
#     INTERFACE
#         Ring:    0 (setup)
#         Input:   FLEET_SPOOL, FLEET_STATE_DIR, LCARS_ROOT, HOMES_ROOT, fleet.yaml
#         Output:  spool dirs, systemd units, toolbox scripts, symlinks, ownership fixes
#
#     EXIT CODES
#         N/A (sourced by deploy.sh)
#
# --- END HEADER ---

TOOLBOX_SRC="$FLEET_SRC/toolbox"
_BOUNDARY_OS=$(_yq '.fleet.instances[] | select(.scope == "boundary-os") | .role')
[[ "$_BOUNDARY_OS" == "null" || -z "$_BOUNDARY_OS" ]] && _BOUNDARY_OS="starfleet"
TOOLBOX_DST="$HOMES_ROOT/$_BOUNDARY_OS/toolbox"
if [ -d "$TOOLBOX_SRC" ]; then
    echo ""
    echo "=== toolbox/ → $_BOUNDARY_OS ==="
    sync_tree "$TOOLBOX_SRC" "$TOOLBOX_DST" "exec"
fi

# --- tmux.conf → fleet_user home ---
TMUX_SRC="$FLEET_SRC/tmux.conf"
TMUX_DST="$FLEET_USER_HOME/.tmux.conf"
if [ -f "$TMUX_SRC" ] && [ "$DRY_RUN" -eq 0 ]; then
    if ! cmp -s "$TMUX_SRC" "$TMUX_DST" 2>/dev/null; then
        fleet_cp "$TMUX_SRC" "$TMUX_DST"
        deployed
    fi
fi

# --- User symlinks (backup, deploy, knowledge) ---
declare -A FLEET_SYMLINKS=(
    ["$FLEET_USER_HOME/backup"]="$LCARS_ROOT/fleet/toolbox/backup-wsl.sh"
    ["$FLEET_USER_HOME/deploy"]="$LCARS_ROOT/fleet/provisioning/deploy.sh"
    ["$FLEET_USER_HOME/knowledge"]="$FLEET_KNOWLEDGE"
)
for link in "${!FLEET_SYMLINKS[@]}"; do
    target="${FLEET_SYMLINKS[$link]}"
    if [ "$DRY_RUN" -eq 0 ]; then
        ln -sfn "$target" "$link"
        echo "  $_symlink $link → $target"
    else
        echo "  $_dryrun créerait symlink $link → $target"
    fi
done

# --- CLI commands in /usr/local/bin/ ---
declare -A SYSTEM_SYMLINKS=(
    ["/usr/local/bin/start"]="$LCARS_ROOT/fleet/light_on.sh"
    ["/usr/local/bin/stop"]="$LCARS_ROOT/fleet/light_off.sh"
    ["/usr/local/bin/restart"]="$LCARS_ROOT/fleet/fleet-restart.sh"
    ["/usr/local/bin/fleet-sf"]="$LCARS_ROOT/fleet/fleet-sf.sh"
    ["/usr/local/bin/fleet-arch"]="$LCARS_ROOT/fleet/fleet-arch.sh"
    ["/usr/local/bin/fleet-update"]="$LCARS_ROOT/fleet/fleet-update.sh"
    ["/usr/local/bin/fleet-doctor"]="$LCARS_ROOT/fleet/fleet-doctor.sh"
    ["/usr/local/bin/fleet-consultant"]="$LCARS_ROOT/fleet/toolbox/fleet-consultant.sh"
)
for link in "${!SYSTEM_SYMLINKS[@]}"; do
    target="${SYSTEM_SYMLINKS[$link]}"
    if [ "$DRY_RUN" -eq 0 ]; then
        sudo ln -sfn "$target" "$link"
        echo "  $_symlink $link → $target"
    else
        echo "  $_dryrun créerait symlink $link → $target"
    fi
done

# --- Toolbox in PATH via /etc/profile.d/ ---
_PROFILE_D="/etc/profile.d/fleet-toolbox.sh"
_TOOLBOX_PATH="${LCARS_ROOT:-/local/LCARS}/fleet/toolbox"
if [ "$DRY_RUN" -eq 0 ]; then
    if ! grep -q "$_TOOLBOX_PATH" "$_PROFILE_D" 2>/dev/null; then
        echo "export PATH=\"${_TOOLBOX_PATH}:\$PATH\"" | sudo tee "$_PROFILE_D" > /dev/null
        sudo chmod 644 "$_PROFILE_D"
        echo "  ${_symlink} $_PROFILE_D → toolbox in PATH"
    else
        echo "  [ok] toolbox already in PATH ($_PROFILE_D)"
    fi
    # Clean up old individual toolbox symlinks
    for old_link in fleet-profile fleet-auth fleet-sp-test fleet-sp-dump claude-update claude-to-stable claude-to-latest; do
        [ -L "/usr/local/bin/$old_link" ] && sudo rm -f "/usr/local/bin/$old_link"
    done
else
    echo "  $_dryrun would add toolbox to PATH via $_PROFILE_D"
fi

# --- Spool IPC dirs ---
SPOOL_ROOT="$FLEET_SPOOL"
SPOOL_INBOX="$FLEET_SPOOL_INBOX"
SPOOL_OUTBOX="$FLEET_SPOOL_OUTBOX"
SPOOL_PENDING_WAKES="${FLEET_PENDING_WAKES:-$FLEET_SPOOL/pending-wakes}"
FLEET_GROUP="$(_yq '.fleet.group')"
[[ "$FLEET_GROUP" == "null" || -z "$FLEET_GROUP" ]] && FLEET_GROUP="fleet"
echo ""
echo "=== spool dirs → $SPOOL_ROOT ==="
if [ "$DRY_RUN" -eq 0 ]; then
    sudo mkdir -p "$SPOOL_ROOT" "$SPOOL_INBOX" "$SPOOL_OUTBOX" "$SPOOL_PENDING_WAKES"
    sudo chown "root:$FLEET_GROUP" "$SPOOL_ROOT" "$SPOOL_INBOX" "$SPOOL_OUTBOX" "$SPOOL_PENDING_WAKES"
    sudo chmod 770 "$SPOOL_ROOT" "$SPOOL_INBOX" "$SPOOL_OUTBOX" "$SPOOL_PENDING_WAKES"
    while IFS= read -r role; do
        sudo mkdir -p "$SPOOL_INBOX/$role" "$SPOOL_INBOX/$role/.consumed" "$SPOOL_INBOX/$role/.processing"
        sudo chown "root:$FLEET_GROUP" "$SPOOL_INBOX/$role" "$SPOOL_INBOX/$role/.consumed" "$SPOOL_INBOX/$role/.processing"
        sudo chmod 770 "$SPOOL_INBOX/$role" "$SPOOL_INBOX/$role/.consumed" "$SPOOL_INBOX/$role/.processing"
        echo "  $_ok inbox/$role/"
        sudo mkdir -p "$SPOOL_PENDING_WAKES/$role"
        sudo chown "root:$FLEET_GROUP" "$SPOOL_PENDING_WAKES/$role"
        sudo chmod 770 "$SPOOL_PENDING_WAKES/$role"
        echo "  $_ok pending-wakes/$role/"
    done < <(fleet_roles)
    echo "  $_ok outbox/"
else
    while IFS= read -r role; do
        echo "  $_dryrun créerait inbox/$role/ + .consumed/ + pending-wakes/$role/"
    done < <(fleet_roles)
    echo "  $_dryrun créerait outbox/"
fi

# --- Systemd user units per agent (IPC wake) ---
echo ""
echo "=== systemd user units (IPC wake) ==="
_FLEET_SCRIPTS_DIR="$SCRIPT_DIR/fleet"
while IFS= read -r role; do
    _linux_user="$(fleet_role_field "$role" "linux_user" 2>/dev/null)"
    [[ "$_linux_user" == "null" || -z "$_linux_user" ]] && _linux_user="$role"
    _home="$HOMES_ROOT/$_linux_user"
    [ -d "$_home" ] || continue
    _inbox_dir="$SPOOL_INBOX/$role"
    _systemd_dir="$_home/.config/systemd/user"
    _wake_notify="$_home/.local/bin/fleet-wake-notify.sh"

    if [ "$DRY_RUN" -eq 0 ]; then
        sudo -u "$_linux_user" mkdir -p "$_systemd_dir"

        sudo -u "$_linux_user" tee "$_systemd_dir/fleet-inbox-watch.path" > /dev/null <<UNIT_EOF
[Unit]
Description=Fleet inbox watch for ${role}
After=default.target

[Path]
PathChanged=${_inbox_dir}
PathModified=${_inbox_dir}

[Install]
WantedBy=default.target
UNIT_EOF

        sudo -u "$_linux_user" tee "$_systemd_dir/fleet-inbox-wake.service" > /dev/null <<UNIT_EOF
[Unit]
Description=Fleet inbox wake trigger for ${role}

[Service]
Type=oneshot
ExecStart=${_wake_notify} ${role} spool-event
UNIT_EOF

        if systemctl --user -M "${_linux_user}@.host" is-system-running &>/dev/null 2>&1 || \
           sudo -u "$_linux_user" XDG_RUNTIME_DIR="/run/user/$(id -u "$_linux_user")" \
               systemctl --user is-system-running &>/dev/null 2>&1; then
            sudo -u "$_linux_user" \
                XDG_RUNTIME_DIR="/run/user/$(id -u "$_linux_user")" \
                DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$_linux_user")/bus" \
                systemctl --user daemon-reload 2>/dev/null || true
            sudo -u "$_linux_user" \
                XDG_RUNTIME_DIR="/run/user/$(id -u "$_linux_user")" \
                DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$_linux_user")/bus" \
                systemctl --user enable --now fleet-inbox-watch.path 2>/dev/null \
                && echo "  $_ok $role: systemd unit enabled" \
                || echo "  $_WARN $role: systemctl enable failed (systemd session may not be up yet)"
        else
            echo "  $_WARN $role: systemd user session unavailable — unit written, not enabled"
            echo "         fallback: fleet-inbox-watch-daemon.sh will be started by session-startup.sh"
        fi
    else
        echo "  $_dryrun $role: would write fleet-inbox-watch.path + fleet-inbox-wake.service → $_systemd_dir"
    fi
done < <(fleet_roles)

# --- Drift audit commit counter ---
if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$FLEET_STATE_DIR"
    git -C "$SCRIPT_DIR" rev-list --count HEAD 2>/dev/null \
        > "$FLEET_STATE_DIR/lcars-commit-count.tmp" \
        && mv "$FLEET_STATE_DIR/lcars-commit-count.tmp" \
              "$FLEET_STATE_DIR/lcars-commit-count"
fi

# --- Git hooks → all projects ---
HOOKS_SRC="$SCRIPT_DIR/../git-hooks/install-hooks.sh"
LCARS_PROJECT="/home/projects/LCARS"
if [ -f "$HOOKS_SRC" ]; then
    echo ""
    echo "=== git hooks → all projects ==="
    if [ "$DRY_RUN" -eq 0 ]; then
        bash "$HOOKS_SRC" --all-projects /home/projects/ || true
    else
        for _repo in /home/projects/*/; do
            [ -d "$_repo/.git" ] && echo "  $_dryrun installerait git hooks → $_repo"
        done
    fi
fi

git config --global --add safe.directory "$LCARS_PROJECT" 2>/dev/null || true

# --- Chown dev clone to runtime user (starfleet) ---
_RUNTIME_USER=$(while IFS= read -r r; do
    [[ "$(fleet_role_field "$r" "sudo")" == "full" ]] && echo "$r" && break
done < <(fleet_roles)) || true
: "${_RUNTIME_USER:=starfleet}"
echo ""
echo "=== dev clone ownership → $_RUNTIME_USER ==="
if [ -d "$LCARS_PROJECT/.git" ]; then
    if [ "$DRY_RUN" -eq 0 ]; then
        chown -R "$_RUNTIME_USER:$FLEET_GROUP" "$LCARS_PROJECT" 2>/dev/null || true
        find "$LCARS_PROJECT" -type d -exec chmod g+ws {} \; 2>/dev/null || true
        find "$LCARS_PROJECT" -not -path "$LCARS_PROJECT/.git/objects/*" -type f \
            -exec chmod g+rw {} \; 2>/dev/null || true
        echo "  $_ok $LCARS_PROJECT → $_RUNTIME_USER:$FLEET_GROUP"
    else
        echo "  $_dryrun chown $LCARS_PROJECT → $_RUNTIME_USER:$FLEET_GROUP"
    fi
fi
