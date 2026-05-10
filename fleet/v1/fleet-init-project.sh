#!/bin/bash
# DEPLOY: instance-util

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-init-project.sh
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
#     | MODULE: INIT-PROJECT    | SUBSYSTEM: FLEET / MEMORY       |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Bootstraps agent context for a project.                  |
#     |  Injects filtered L2 domain memory + session-context.     |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     DEPLOY: instance-util
#
#           ______________________________________________________
#          /          LCARS FLEET - FEDERATION DATABASE           \
#         |   ________   __________________________________________\
#         |  |  2026  |  | SOURCE: fleet-init-project.sh
#         |  |________|  | AUTHOR: LORDZURP
#
#     [EN]
#     fleet-init-project.sh — Bootstraps agent context for a project.
#     Injects filtered L2 domain memory + session-context.
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

PROJECT=""
DOMAIN=""
AGENT_TYPE="${FLEET_INSTANCE:-unknown}"
L2_BASE="${L2_BASE:-$HOME/.claude/memory/L2}"
ACTIVE_DIR="$HOME/.claude/memory/L2-active"
CTX_FILE="$HOME/.claude/memory/session-context.md"

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --project) PROJECT="$2"; shift 2 ;;
        --domain)  DOMAIN="$2";  shift 2 ;;
        --agent)   AGENT_TYPE="$2"; shift 2 ;;
        --l2-dir)  L2_BASE="$2"; shift 2 ;;
        *) echo "ERROR: argument inconnu: $1" >&2
           echo "Usage: fleet-init-project.sh --project <nom> --domain <domaine>" >&2
           exit 1 ;;
    esac
done

[[ -z "$PROJECT" ]] && { echo "ERROR: --project requis" >&2; exit 1; }
[[ -z "$DOMAIN"  ]] && { echo "ERROR: --domain requis"  >&2; exit 1; }

L2_DOMAIN_DIR="$L2_BASE/domains/$DOMAIN"
NOW=$(date +%s)

echo "=== fleet-init-project: $PROJECT ($DOMAIN) ==="
echo "Agent : $AGENT_TYPE"
echo "L2    : $L2_DOMAIN_DIR"

# ── Rebuild L2-active atomically (AUDIT-035) ──────────────────────────────────
# Build new set in temp dir, then replace. Old L2-active survives on failure.
_ACTIVE_TMP="${ACTIVE_DIR}.tmp.$$"
rm -rf "$_ACTIVE_TMP"
mkdir -p "$_ACTIVE_TMP"
# Rename at the end after successful population — see below

# ── Filter + copy L2 entries ──────────────────────────────────────────────────
KEPT=0

if [[ ! -d "$L2_DOMAIN_DIR" ]]; then
    echo "INFO: L2 domain '$DOMAIN' vide — L2-active vide, cold start."
else
    python3 - "$L2_DOMAIN_DIR" "$_ACTIVE_TMP" "$NOW" <<'PYEOF'
import sys, os, re, shutil
from datetime import datetime, timezone

domain_dir, active_dir, now_ts = sys.argv[1], sys.argv[2], int(sys.argv[3])
now = datetime.fromtimestamp(now_ts, tz=timezone.utc)

KEEP_RECENT_DAYS   = 7    # always keep if younger than this
KEEP_HITS_MAX_DAYS = 180  # keep if hits>0 and younger than this
DROP_NO_HITS_DAYS  = 30   # drop if hits==0 and older than this
DROP_STALE_DAYS    = 180  # drop if older than this regardless of hits

def parse_frontmatter(text):
    m = re.match(r'^---\n(.*?)\n---\n', text, re.DOTALL)
    if not m:
        return {}
    meta = {}
    for line in m.group(1).splitlines():
        if ':' in line:
            k, _, v = line.partition(':')
            meta[k.strip()] = v.strip()
    return meta

kept, dropped = 0, 0
for fname in sorted(os.listdir(domain_dir)):
    if not fname.endswith('.md') or fname == 'DOMAIN.md':
        continue
    fpath = os.path.join(domain_dir, fname)
    with open(fpath) as f:
        content = f.read()
    meta = parse_frontmatter(content)

    # Parse date (default: keep)
    raw_date = meta.get('date', '')
    try:
        entry_date = datetime.strptime(raw_date, '%Y-%m-%d').replace(tzinfo=timezone.utc)
        age_days = (now - entry_date).days
    except ValueError:
        age_days = 0  # unparseable date → treat as fresh

    # Parse hits (default: 0)
    try:
        hits = int(meta.get('hits', '0'))
    except ValueError:
        hits = 0

    # Apply filter rules
    reason = None
    if age_days < KEEP_RECENT_DAYS:
        reason = f"recent ({age_days}d)"
    elif age_days > DROP_STALE_DAYS:
        reason = None  # stale → drop
        print(f"  DROP  {fname} — stale ({age_days}d)", flush=True)
        dropped += 1
        continue
    elif hits == 0 and age_days > DROP_NO_HITS_DAYS:
        print(f"  DROP  {fname} — never used ({age_days}d, hits=0)", flush=True)
        dropped += 1
        continue
    elif hits > 0 and age_days <= KEEP_HITS_MAX_DAYS:
        reason = f"hits={hits} ({age_days}d)"
    elif hits == 0:
        print(f"  DROP  {fname} — hits=0 ({age_days}d)", flush=True)
        dropped += 1
        continue
    else:
        reason = f"hits={hits}"

    shutil.copy2(fpath, os.path.join(active_dir, fname))
    print(f"  KEEP  {fname} — {reason}", flush=True)
    kept += 1

print(f"Filter: {kept} kept, {dropped} dropped", flush=True)
sys.exit(0)
PYEOF
    KEPT=$(find "$_ACTIVE_TMP" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l)
fi

# Atomic promotion: rename old, move new, then delete old.
# If mv fails, old state is preserved under .bak.
if [[ -d "$ACTIVE_DIR" ]]; then
    mv "$ACTIVE_DIR" "${ACTIVE_DIR}.bak.$$"
fi
if mv "$_ACTIVE_TMP" "$ACTIVE_DIR"; then
    rm -rf "${ACTIVE_DIR}.bak.$$" 2>/dev/null || true
else
    echo "ERROR: mv failed — restoring previous L2-active" >&2
    if [[ -d "${ACTIVE_DIR}.bak.$$" ]]; then
        mv "${ACTIVE_DIR}.bak.$$" "$ACTIVE_DIR"
    fi
    exit 1
fi

# ── Write session-context.md ──────────────────────────────────────────────────
TIMESTAMP=$(date "+%Y-%m-%d %H:%M")
L2_LIST=""
if [[ "$KEPT" -gt 0 ]]; then
    L2_LIST=$(find "$ACTIVE_DIR" -maxdepth 1 -name '*.md' -printf '%f\n' 2>/dev/null | sed 's/\.md$//; s/^/- /')
else
    L2_LIST="(none — cold start)"
fi

cat > "$CTX_FILE" <<EOF
# Session context — $PROJECT

**Initialized** : $TIMESTAMP
**Agent**       : $AGENT_TYPE
**Project**     : $PROJECT
**Domain**      : $DOMAIN

## L2 memory loaded ($KEPT entries)

$L2_LIST

## Quick start

- L2-active: \`~/.claude/memory/L2-active/\` — domain memory for this session
- Increment hits when an L2 entry proves useful: \`fleet-l2-hits.sh ~/.claude/memory/L2-active/<file>\`
- Project handoff: \`$FLEET_HANDOFFS/\`

## Scope reminder

$AGENT_TYPE scope: refer to ~/.claude/CLAUDE.md
EOF

echo ""
echo "session-context.md written."
echo "L2-active: $KEPT entries from domain '$DOMAIN'."
echo "Project '$PROJECT' ready."
