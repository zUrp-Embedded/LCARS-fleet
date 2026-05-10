#!/usr/bin/env python3
#
#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: filter-build-output.sh
#     |  |________|  | AUTHOR: LORDZURP
#     |   ________   | SYSTEM: LCARS-FLEET v2.0
#     |  |  v2.0  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: FILTER-BUILD    | SUBSYSTEM: BUILD               |
#     | LICENSE: AGPL-3         | STARDATE: 2026.070              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Filtre la sortie cmake/ninja verbose.                  |
#     |  Supprime les lignes de progression [N/M].              |
#     |                                                           |
#     +-----------------------------------------------------------+
# filter-build-output.sh — supprime les lignes de progression cmake/ninja
#
# Lit stdin, supprime les lignes de compilation per-fichier [N/M] Building/Compiling/Scanning.
# Conserve : erreurs, warnings, Linking, FAILED, et toute sortie hors progression.
# Sortie : résumé des lignes supprimées + lignes conservées.
#
# Usage : cmake --build <dir> -j2 2>&1 | filter-build-output.sh

import sys
import re

SUPPRESS_PAT = re.compile(r'^\[\s*\d+/\d+\]\s+(Building|Compiling|Scanning) ')

lines = sys.stdin.readlines()
suppressed = [l for l in lines if SUPPRESS_PAT.match(l)]
kept = [l for l in lines if not SUPPRESS_PAT.match(l)]

if suppressed:
    sys.stdout.write(f"... [{len(suppressed)} build progress lines suppressed] ...\n")
for l in kept:
    sys.stdout.write(l)
