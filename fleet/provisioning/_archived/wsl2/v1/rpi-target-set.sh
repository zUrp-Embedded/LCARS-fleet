#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: rpi-target-set.sh
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
#     | MODULE: RPI-TARGET      | SUBSYSTEM: PROV / WSL2          |
#     | LICENSE: AGPL-3         | STARDATE: 2026.063              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Sets the active Raspberry Pi build target.               |
#     |  Writes arch/board config to builder environment.         |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     rpi-target-set — Change la cible RPi pour la cross-compilation
#     Usage: rpi-target-set <zero2|pi4|pi5>
#
#     Écrit ~/.rpi-target. Re-sourcer ~/.env.cross pour appliquer.
#
#     [EN]
#     rpi-target-set.sh — Sets the active Raspberry Pi build target.
#     Writes arch/board config to builder environment.
#

TARGET="${1:-}"

case "$TARGET" in
    zero2)
        echo "zero2" > ~/.rpi-target
        echo "Target : zero2 (RPi Zero 2)"
        echo "RAM    : 512 MB (contrainte stricte)"
        echo "CPU    : -mcpu=cortex-a53 (Cortex-A53)"
        ;;
    pi4)
        echo "pi4" > ~/.rpi-target
        echo "Target : pi4 (RPi 4)"
        echo "RAM    : 1-8 GB (relâché)"
        echo "CPU    : -mcpu=cortex-a72 (Cortex-A72)"
        ;;
    pi5)
        echo "pi5" > ~/.rpi-target
        echo "Target : pi5 (RPi 5)"
        echo "RAM    : 4-8 GB (relâché)"
        echo "CPU    : -mcpu=cortex-a76 (Cortex-A76)"
        ;;
    *)
        echo "Usage: rpi-target-set <zero2|pi4|pi5>"
        echo ""
        echo "  zero2  RPi Zero 2  — 512 MB RAM, Cortex-A53 (-mcpu=cortex-a53)"
        echo "  pi4    RPi 4       — 1-8 GB RAM, Cortex-A72 (-mcpu=cortex-a72)"
        echo "  pi5    RPi 5       — 4-8 GB RAM, Cortex-A76 (-mcpu=cortex-a76)"
        exit 1
        ;;
esac

echo ""
echo "Applique avec : source ~/.env.cross"
