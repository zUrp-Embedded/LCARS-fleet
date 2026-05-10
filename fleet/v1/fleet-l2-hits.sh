#!/bin/bash
# DEPLOY: instance-util

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-l2-hits.sh
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
#     | MODULE: L2-HITS         | SUBSYSTEM: FLEET / MEMORY       |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Increments the hits counter in an L2 entry's frontmatter.|
#     |  Called by agents when an L2 entry proves useful.         |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     DEPLOY: instance-util
#
#           ______________________________________________________
#          /          LCARS FLEET - FEDERATION DATABASE           \
#         |   ________   __________________________________________\
#         |  |  2026  |  | SOURCE: fleet-l2-hits.sh
#         |  |________|  | AUTHOR: LORDZURP
#
#     [EN]
#     fleet-l2-hits.sh — Increments the hits counter in an L2 entry's frontmatter.
#     Called by agents when an L2 entry proves useful.
#
#
# --- END HEADER ---


# --help: extract [EN] section from this header
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && {
    sed -n '/^#     \[EN\]/,/^# --- END HEADER ---/{/\[EN\]/d; /END HEADER/d; s/^#     //; s/^#[[:space:]]*$//; p}' "$0"
    exit 0
}

set -euo pipefail

# --- Fleet env ---
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/fleet-env.sh"

FILE="${1:?Usage: fleet-l2-hits.sh <fichier-L2.md>}"

[[ -f "$FILE" ]] || { echo "ERROR: fichier introuvable: $FILE" >&2; exit 1; }

# Increment hits in frontmatter via python3 (atomic write)
python3 - "$FILE" <<'PYEOF'
import sys, re, tempfile, os

path = sys.argv[1]
with open(path) as f:
    content = f.read()

# Match frontmatter block
m = re.match(r'^(---\n)(.*?)(\n---\n)(.*)', content, re.DOTALL)
if not m:
    print(f"WARN: no frontmatter in {path} — hits not updated", file=sys.stderr)
    sys.exit(0)

pre, fm_body, sep, body = m.groups()

# Increment hits field
def inc_hits(text):
    def repl(m):
        return f"hits: {int(m.group(1)) + 1}"
    new_text, n = re.subn(r'^hits:\s*(\d+)', repl, text, flags=re.MULTILINE)
    if n == 0:
        new_text = text.rstrip('\n') + '\nhits: 1'
    return new_text

new_fm = inc_hits(fm_body)
new_content = pre + new_fm + sep + body

# Atomic write
tmp_fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(path), prefix='.tmp-hits-')
try:
    with os.fdopen(tmp_fd, 'w') as f:
        f.write(new_content)
    os.replace(tmp_path, path)
except Exception:
    os.unlink(tmp_path)
    raise

# Extract new hits value for confirmation
new_hits = re.search(r'^hits:\s*(\d+)', new_fm, re.MULTILINE)
hits_val = new_hits.group(1) if new_hits else '?'
print(f"  hits: {hits_val}  ← {os.path.basename(path)}")
PYEOF

# Also sync to L2 canonical (domains/) if this file is in L2-active/
ACTIVE_DIR="$HOME/.claude/memory/L2-active"
L2_BASE="${L2_BASE:-$HOME/.claude/memory/L2}"
FNAME=$(basename "$FILE")

if [[ "$FILE" == "$ACTIVE_DIR"/* ]]; then
    # Find canonical file in domains/
    CANONICAL=$(find "$L2_BASE/domains" -name "$FNAME" 2>/dev/null | head -1)
    if [[ -n "$CANONICAL" ]]; then
        cp "$FILE" "$CANONICAL"
        echo "  synced → $(realpath --relative-to="$HOME" "$CANONICAL")"
    fi
fi
