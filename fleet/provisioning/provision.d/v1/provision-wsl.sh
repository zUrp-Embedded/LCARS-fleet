#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: provision-wsl.sh
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
#     | MODULE: PROVISION-WSL   | SUBSYSTEM: PROVISIONING / SYSTEM|
#     | LICENSE: AGPL-3         | STARDATE: 2026.090              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Configure /etc/wsl.conf + ready-room drvfs mount.        |
#     |  Sourced by provision-system.sh. WSL-only, skips on native Linux.|
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     provision.d/provision-wsl.sh — wsl.conf + ready-room mount
#     Sourced by provision-system.sh — uses globals: CHECK, FLEET_USER, FLEET_GROUP, FLEET_YAML
#
#     [EN]
#     provision-wsl.sh — Configure /etc/wsl.conf + ready-room drvfs mount.
#     Sourced by provision-system.sh. WSL-only, skips on native Linux.
#
#
# --- END HEADER ---

if ! grep -qi microsoft /proc/version 2>/dev/null; then
    return 0 2>/dev/null || exit 0
fi

echo ""
echo "=== WSL ==="
check_or_do "wsl:/etc/wsl.conf" \
    "grep -q '^\[automount\]' /etc/wsl.conf 2>/dev/null && sed -n '/\[automount\]/,/\[/p' /etc/wsl.conf | grep -q 'enabled=false' && sed -n '/\[interop\]/,/\[/p' /etc/wsl.conf | grep -q 'enabled=false'" \
    "cat > /etc/wsl.conf << 'WSLEOF'
[boot]
systemd=true

[automount]
enabled=false
mountFsTab=true

[interop]
enabled=false
appendWindowsPath=false
WSLEOF"

if mountpoint -q /mnt/c 2>/dev/null || ls /proc/sys/fs/binfmt_misc/WSLInterop* >/dev/null 2>&1; then
    warn "wsl:runtime — config written but C:\\ still mounted or interop active. Reboot WSL to activate."
fi

# --- Ready Room ---
WIN_USER="$(_yq '.fleet.identity.windows_user')"
[[ "$WIN_USER" == "null" ]] && WIN_USER=""
[ -z "$WIN_USER" ] && WIN_USER="$(wslvar USERNAME 2>/dev/null | tr -d '\r' || true)"
[ -z "$WIN_USER" ] && WIN_USER="$FLEET_USER"
RR_WSL="/mnt/c/Users/${WIN_USER}/ready-room"
FLEET_RR="${FLEET_READY_ROOM:-/home/ready-room}"

check_or_do "wsl:ready-room ($RR_WSL)" \
    "mountpoint -q $FLEET_RR || [ -d $RR_WSL ]" \
    "mkdir -p $RR_WSL/inbox $RR_WSL/outbox $RR_WSL/outbox/audits $RR_WSL/handoffs $RR_WSL/projects"

RR_FSTAB="C:/Users/${WIN_USER}/ready-room ${FLEET_RR} drvfs defaults,metadata 0 0"
check_or_do "wsl:fstab:ready-room" \
    "grep -qF '${FLEET_RR} drvfs' /etc/fstab 2>/dev/null" \
    "printf '%s\\n' '${RR_FSTAB}' >> /etc/fstab"

if mountpoint -q "$FLEET_RR" 2>/dev/null; then
    pass "wsl:ready-room mount ($FLEET_RR)"
else
    mkdir -p "$FLEET_RR/inbox" "$FLEET_RR/outbox" "$FLEET_RR/outbox/audits" "$FLEET_RR/handoffs" "$FLEET_RR/projects" 2>/dev/null || true
    chown "$FLEET_USER:$FLEET_GROUP" "$FLEET_RR" "$FLEET_RR/inbox" "$FLEET_RR/outbox" "$FLEET_RR/handoffs" 2>/dev/null || true
    chown "root:$FLEET_GROUP" "$FLEET_RR/projects" 2>/dev/null || true
    chmod 777 "$FLEET_RR" "$FLEET_RR/inbox" "$FLEET_RR/outbox" "$FLEET_RR/handoffs" 2>/dev/null || true
    chmod 2770 "$FLEET_RR/projects" 2>/dev/null || true
    if mountpoint -q "$FLEET_RR" 2>/dev/null; then
        pass "wsl:ready-room mount ($FLEET_RR) — fixed"
    else
        warn "wsl:ready-room mount ($FLEET_RR) — reboot WSL to activate (fstab + wsl.conf configured)"
    fi
fi
