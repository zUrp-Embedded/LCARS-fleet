#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: rpi-img-mount.sh
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
#     | MODULE: RPI-MOUNT       | SUBSYSTEM: FLEET / BUILD        |
#     | LICENSE: AGPL-3         | STARDATE: 2026.090              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Mounts a Raspberry Pi image for inspection.              |
#     |  Handles loop device setup and partition offsets.         |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#           ______________________________________________________
#          /          LCARS FLEET - FEDERATION DATABASE           \
#         |   ________   __________________________________________\
#         |  |  2026  |  | SOURCE: rpi-img-mount.sh
#         |  |________|  | AUTHOR: LORDZURP
#         |   ________   | SYSTEM: LCARS-FLEET v5.4
#
#     [EN]
#     rpi-img-mount.sh — Mounts a Raspberry Pi image for inspection.
#     Handles loop device setup and partition offsets.
#
#
# --- END HEADER ---

set -euo pipefail

# --- Fleet env ---
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/fleet-env.sh"

ACTION="${1:?usage: rpi-img-mount.sh mount <image.img> <mountpoint> | umount <mountpoint>}"

case "$ACTION" in

  mount)
    IMAGE="${2:?usage: rpi-img-mount.sh mount <image.img> <mountpoint>}"
    MOUNTPOINT="${3:?usage: rpi-img-mount.sh mount <image.img> <mountpoint>}"

    [[ -f "$IMAGE" ]] || { echo "ERROR: '$IMAGE' introuvable" >&2; exit 1; }

    # IEC 61508: validate MOUNTPOINT is under a known safe prefix
    case "$MOUNTPOINT" in
        /mnt/*|/tmp/*|/home/*) ;;
        *) echo "ERROR: MOUNTPOINT '$MOUNTPOINT' must be under /mnt/, /tmp/, or /home/" >&2; exit 1 ;;
    esac

    # Lire la table de partitions directement sur le fichier image (sans sudo)
    SECTOR_SIZE=$(fdisk -l "$IMAGE" | awk '/^Sector size/ { print $4; exit }')
    SECTOR_SIZE=${SECTOR_SIZE:-512}

    # IEC 61508: validate SECTOR_SIZE is numeric
    [[ "$SECTOR_SIZE" =~ ^[0-9]+$ ]] || { echo "ERROR: SECTOR_SIZE '$SECTOR_SIZE' is not numeric" >&2; exit 1; }

    # Première partition de type Linux (ext4) = rootfs RPi
    P2_START=$(fdisk -l "$IMAGE" | awk '/Linux/ { print $2; exit }')
    [[ -n "$P2_START" ]] || { echo "ERROR: aucune partition Linux dans $IMAGE" >&2; exit 1; }

    # IEC 61508: validate P2_START is numeric
    [[ "$P2_START" =~ ^[0-9]+$ ]] || { echo "ERROR: P2_START '$P2_START' is not numeric" >&2; exit 1; }

    OFFSET=$(( P2_START * SECTOR_SIZE ))
    echo ">>> offset = ${OFFSET}B  (secteur ${P2_START} × ${SECTOR_SIZE}B)"

    mkdir -p "$MOUNTPOINT"
    sudo mount -o "loop,offset=${OFFSET}" "$IMAGE" "$MOUNTPOINT"
    df -h "$MOUNTPOINT"
    ;;

  umount)
    MOUNTPOINT="${2:?usage: rpi-img-mount.sh umount <mountpoint>}"
    sudo umount "$MOUNTPOINT"
    echo ">>> démonté : $MOUNTPOINT"
    ;;

  *)
    echo "ERROR: action '$ACTION' inconnue — utiliser mount ou umount" >&2
    exit 1
    ;;

esac
