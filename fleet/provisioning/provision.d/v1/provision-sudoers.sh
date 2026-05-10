#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: provision-sudoers.sh
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
#     | MODULE: PROVISION-SUDOERS| SUBSYSTEM: PROVISIONING / SYSTEM|
#     | LICENSE: AGPL-3         | STARDATE: 2026.090              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Write all /etc/sudoers.d/ files for fleet.               |
#     |  Sourced by provision-system.sh. Per-role from blueprint scope.|
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     provision.d/provision-sudoers.sh — all sudoers.d files
#     Sourced by provision-system.sh — uses globals: CHECK, FLEET_USER, FLEET_GROUP
#
#     [EN]
#     provision-sudoers.sh — Write all /etc/sudoers.d/ files for fleet.
#     Sourced by provision-system.sh. Per-role from blueprint scope.
#
#
# --- END HEADER ---

echo ""
echo "=== Sudoers ==="

# fleet_user → all agents (redundant if fleet_user has sudo:full in blueprint,
# but kept as explicit declaration for audit traceability)
AGENTS=$(printf '%s, ' $(fleet_roles))
AGENTS="${AGENTS%, }"

# Per-role sudoers
while IFS= read -r role; do
    sudo_level="$(fleet_role_field "$role" "sudo")"
    SUDOERS_ROLE="/etc/sudoers.d/fleet-agent-$role"

    case "$sudo_level" in
        full)
            check_or_do "sudoers:$role — full" \
                "grep -qF '$role ALL=(ALL) NOPASSWD: ALL' $SUDOERS_ROLE 2>/dev/null" \
                "echo '$role ALL=(ALL) NOPASSWD: ALL' > $SUDOERS_ROLE && chmod 440 $SUDOERS_ROLE"
            ;;
        read-only)
            CMDS="/usr/bin/cat,/usr/bin/ls,/usr/bin/find,/usr/bin/journalctl,/usr/bin/systemctl status *,/usr/bin/mount,/usr/bin/df,/usr/bin/du,/usr/bin/ps,/usr/bin/ss,/usr/bin/id,/usr/bin/stat,/usr/bin/head,/usr/bin/tail,/usr/bin/grep,/usr/bin/wc"
            check_or_do "sudoers:$role — read-only" \
                "grep -qF 'read-only' $SUDOERS_ROLE 2>/dev/null || ! [ -f $SUDOERS_ROLE ]" \
                "echo '$role ALL=(ALL) NOPASSWD: $CMDS' > $SUDOERS_ROLE && chmod 440 $SUDOERS_ROLE"
            ;;
        *)
            pass "sudoers:$role — none"
            ;;
    esac
done < <(fleet_roles)

# Fleet group → tmux
SUDOERS_TMUX="/etc/sudoers.d/fleet-tmux"
check_or_do "sudoers:%fleet → tmux as $FLEET_USER" \
    "grep -qF '/usr/bin/tmux' $SUDOERS_TMUX 2>/dev/null" \
    "echo '%fleet ALL=($FLEET_USER) NOPASSWD: /usr/bin/tmux' > $SUDOERS_TMUX && chmod 440 $SUDOERS_TMUX"

# Fleet group → dispatch (JUPITER-003: minimal commands for headless dispatch)
# fleet-dispatch.sh uses: sudo -u <target> -i env ... timeout ... claude -p ...
# -i runs login shell (/bin/bash), then env/timeout/claude as sub-commands.
# sudo sees the first command after -i, which is env (or bash with -i flag).
# C2-FIX: /bin/bash removed — fleet-dispatch.sh uses env HOME= instead of sudo -i
DISPATCH_CMDS="/usr/bin/env, /usr/bin/timeout, /usr/local/bin/claude"
SUDOERS_DISPATCH="/etc/sudoers.d/fleet-dispatch"
check_or_do "sudoers:%fleet → dispatch as ($AGENTS)" \
    "grep -qF 'NOPASSWD' $SUDOERS_DISPATCH 2>/dev/null && grep -qF '/usr/bin/env' $SUDOERS_DISPATCH 2>/dev/null" \
    "echo '%fleet ALL=($AGENTS) NOPASSWD: $DISPATCH_CMDS' > $SUDOERS_DISPATCH && chmod 440 $SUDOERS_DISPATCH"

# Fleet user → all agents (interactive launchers: fleet-arch, fleet-consultant, etc.)
SUDOERS_FU="/etc/sudoers.d/fleet-$FLEET_USER"
check_or_do "sudoers:$FLEET_USER → all agents" \
    "grep -qF '$FLEET_USER ALL=($AGENTS) NOPASSWD: ALL' $SUDOERS_FU 2>/dev/null" \
    "echo '$FLEET_USER ALL=($AGENTS) NOPASSWD: ALL' > $SUDOERS_FU && chmod 440 $SUDOERS_FU"

# No PTY
SUDOERS_NOPTY="/etc/sudoers.d/fleet-nopty"
check_or_do "sudoers:%fleet !use_pty" \
    "[ -f $SUDOERS_NOPTY ]" \
    "echo 'Defaults:%fleet !use_pty' > $SUDOERS_NOPTY && chmod 440 $SUDOERS_NOPTY"
