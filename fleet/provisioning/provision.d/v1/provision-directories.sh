#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: provision-directories.sh
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
#     | MODULE: PROVISION-DIRS  | SUBSYSTEM: PROVISIONING / SYSTEM|
#     | LICENSE: AGPL-3         | STARDATE: 2026.090              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Create system directories + IPC spool structure.         |
#     |  Sourced by provision-system.sh. Sets ownership + permissions.|
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     provision.d/provision-directories.sh — system dirs + spool IPC
#     Sourced by provision-system.sh — uses globals: CHECK, FLEET_USER, FLEET_GROUP,
#       COMMONS, HANDOFFS, FLEET_STATE_DIR, SPOOL_ROOT
#
#     [EN]
#     provision-directories.sh — Create system directories + IPC spool structure.
#     Sourced by provision-system.sh. Sets ownership + permissions.
#
#
# --- END HEADER ---

echo ""
echo "=== Directories ==="
for dir in "$COMMONS" \
           "$HANDOFFS" "$FLEET_STATE_DIR" \
           /home/projects /home/tmp /home/private; do
    check_or_do "dir:$dir" "[ -d $dir ]" "mkdir -p $dir"
done

if [[ $CHECK -eq 0 ]]; then
    for dir in "$COMMONS" \
               "$HANDOFFS" "$FLEET_STATE_DIR" \
               /home/projects /home/tmp; do
        chown "$FLEET_USER:$FLEET_GROUP" "$dir" 2>/dev/null || true
        chmod 2770 "$dir" 2>/dev/null || true
    done
    chown "$FLEET_USER:$FLEET_USER" /home/private 2>/dev/null || true
    chmod 700 /home/private 2>/dev/null || true
    # ~/.local/bin for Claude Code — handled by provision-users.sh per agent
fi

# --- Spool IPC ---
echo ""
echo "=== Spool IPC ==="
SPOOL_INBOX="$SPOOL_ROOT/inbox"
SPOOL_OUTBOX="$SPOOL_ROOT/outbox"
SPOOL_PENDING_WAKES="$SPOOL_ROOT/pending-wakes"

for dir in "$SPOOL_ROOT" "$SPOOL_INBOX" "$SPOOL_OUTBOX" "$SPOOL_PENDING_WAKES"; do
    check_or_do "spool:$dir" "[ -d $dir ]" \
        "mkdir -p $dir && chown root:$FLEET_GROUP $dir && chmod 770 $dir"
done

while IFS= read -r role; do
    check_or_do "spool:inbox/$role" \
        "[ -d $SPOOL_INBOX/$role ]" \
        "mkdir -p $SPOOL_INBOX/$role $SPOOL_INBOX/$role/.consumed $SPOOL_INBOX/$role/.processing && chown root:$FLEET_GROUP $SPOOL_INBOX/$role $SPOOL_INBOX/$role/.consumed $SPOOL_INBOX/$role/.processing && chmod 770 $SPOOL_INBOX/$role $SPOOL_INBOX/$role/.consumed $SPOOL_INBOX/$role/.processing"
done < <(fleet_roles)
