#!/usr/bin/env python3

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: colorize-handoff.py
#     |  |________|  | AUTHOR: STARFLEET
#     |   ________   | SYSTEM: LCARS-FLEET v6.0
#     |  |  v6.0  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS-FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: HANDOFF-COLOR   | SUBSYSTEM: FLEET / DISPLAY      |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Colorizes handoff file output for terminal display.      |
#     |  ANSI highlighting for STATE fields and roles.            |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     colorize-handoff.py — Colorizes handoff file output for terminal display.
#
#     [EN]
#     colorize-handoff.py — Colorizes handoff file output for terminal display.
#     ANSI highlighting for STATE fields and roles.
#
#
# --- END HEADER ---

import re
import sys

R = '\033[0m'       # reset
BOLD = '\033[1m'
DIM = '\033[2m'
RED = '\033[31m'
GREEN = '\033[32m'
YELLOW = '\033[33m'
BLUE = '\033[34m'
MAGENTA = '\033[35m'
CYAN = '\033[36m'

STATUS_COLOR = {
    "done":        GREEN,
    "pending":     YELLOW,
    "in-progress": BLUE,
    "blocked":     RED,
    "offline":     DIM,
    "decommissioned": RED,
}
STATUS_DOT = {
    "done":        "●",
    "pending":     "◐",
    "in-progress": "◉",
    "blocked":     "✖",
    "offline":     "—",
    "decommissioned": "✖",
}


def colorize_line(line: str) -> str:
    # Titres de section (## ACTIONS, ## STATE, ## DONE, ## Pour ..., etc.)
    if re.match(r'^## ', line):
        return f"{BOLD}{CYAN}{line}{R}"

    # Sous-titres (### date — titre)
    if re.match(r'^### ', line):
        return f"{BOLD}{line}{R}"

    # Titre principal (#)
    if re.match(r'^# ', line):
        return f"{BOLD}{CYAN}{line}{R}"

    # status:
    if re.match(r'^status: ', line):
        val = line[8:].strip()
        color = STATUS_COLOR.get(val, DIM)
        dot = STATUS_DOT.get(val, "?")
        return f"{DIM}status: {R}{color}{BOLD}{dot} {val}{R}"

    # blocker:
    if re.match(r'^blocker: ', line):
        val = line[9:].strip()
        if val and val.lower() != "none":
            return f"{DIM}blocker: {R}{RED}{val}{R}"
        return f"{DIM}{line}{R}"

    # waiting:
    if re.match(r'^waiting: ', line):
        val = line[9:].strip()
        if val and val.lower() != "none":
            return f"{DIM}waiting: {R}{MAGENTA}⏳ {val}{R}"
        return f"{DIM}{line}{R}"

    # notify:
    if re.match(r'^notify: ', line):
        val = line[8:].strip()
        if val and val.lower() != "none":
            return f"{DIM}notify: {R}{MAGENTA}{BOLD}⚡ {val}{R}"
        return f"{DIM}{line}{R}"

    # date: / ref: / action:
    if re.match(r'^(date|ref|action): ', line):
        key, _, val = line.partition(': ')
        return f"{DIM}{key}: {R}{val}"

    # Actions en attente [ ]
    if line.strip().startswith('[ ]'):
        indent = len(line) - len(line.lstrip())
        return f"{' ' * indent}{YELLOW}[ ]{R}{line.strip()[3:]}"

    # Actions terminées [x]
    if line.strip().startswith('[x]'):
        indent = len(line) - len(line.lstrip())
        return f"{DIM}{' ' * indent}[x]{line.strip()[3:]}{R}"

    # Séparateur ---
    if line.strip() == '---':
        return f"{DIM}{line}{R}"

    # Markdown bold **texte** (pour starfleet-notes)
    if '**' in line:
        line = re.sub(r'\*\*(.+?)\*\*', f'{BOLD}\\1{R}', line)

    # Lignes de liste markdown (- item)
    if re.match(r'^(\s*)-\s', line):
        return f"{CYAN}-{R}{line[line.index('-') + 1:]}"

    return line


def colorize(text: str) -> str:
    return '\n'.join(colorize_line(line) for line in text.splitlines())


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: colorize-handoff.py <fichier>", file=sys.stderr)
        sys.exit(1)
    try:
        with open(sys.argv[1], encoding='utf-8') as f:
            text = f.read()
        print(colorize(text))
    except FileNotFoundError:
        print(f"Fichier introuvable : {sys.argv[1]}", file=sys.stderr)
        sys.exit(1)
