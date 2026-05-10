#!/usr/bin/env python3

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: filter-build-output.py
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
#     | MODULE: BUILD-FILTER    | SUBSYSTEM: FLEET / BUILD        |
#     | LICENSE: AGPL-3         | STARDATE: 2026.080              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Filters compiler output for relevant messages.           |
#     |  Strips noise, keeps errors, warnings, progress.          |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     filter-build-output.py — Filters compiler output for relevant messages.
#
#     [EN]
#     filter-build-output.py — Filters compiler output for relevant messages.
#     Strips noise, keeps errors, warnings, progress.
#
#
# --- END HEADER ---

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
