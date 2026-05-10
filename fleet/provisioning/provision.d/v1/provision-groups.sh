#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: provision-groups.sh
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
#     | MODULE: PROVISION-GROUPS| SUBSYSTEM: PROVISIONING / SYSTEM|
#     | LICENSE: AGPL-3         | STARDATE: 2026.087              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Create fleet group + agent Linux users.                  |
#     |  Sourced by provision-system.sh. Blueprint-driven.        |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     provision.d/provision-groups.sh — fleet group + agent users
#     Sourced by provision-system.sh — uses globals: CHECK, FLEET_USER, FLEET_GROUP
#
#     [EN]
#     provision-groups.sh — Create fleet group + agent Linux users.
#     Sourced by provision-system.sh. Blueprint-driven.
#
#
# --- END HEADER ---

echo ""
echo "=== Fleet group ==="
check_or_do "group:$FLEET_GROUP" \
    "getent group $FLEET_GROUP >/dev/null 2>&1" \
    "groupadd $FLEET_GROUP"

check_or_do "group:$FLEET_GROUP — $FLEET_USER member" \
    "id -nG $FLEET_USER 2>/dev/null | grep -qw $FLEET_GROUP" \
    "usermod -aG $FLEET_GROUP $FLEET_USER"

echo ""
echo "=== Users ==="
while IFS= read -r role; do
    check_or_do "user:$role" \
        "id $role >/dev/null 2>&1" \
        "useradd -m -s /bin/bash -G $FLEET_GROUP $role"

    if id "$role" >/dev/null 2>&1; then
        check_or_do "user:$role — $FLEET_GROUP member" \
            "id -nG $role 2>/dev/null | grep -qw $FLEET_GROUP" \
            "usermod -aG $FLEET_GROUP $role"
    fi
done < <(fleet_roles)
