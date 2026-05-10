#!/usr/bin/env bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-sp-dump.sh
#     |  |________|  | AUTHOR: STARFLEET
#     |   ________   | SYSTEM: LCARS-FLEET v6.0
#     |  |  v5.4  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS-FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: FLEET-SP-DUMP     | SUBSYSTEM: TOOLBOX / SP       |
#     | LICENSE: AGPL-3           | STARDATE: 2026.087            |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Dump Anthropic system prompt from tweakcc GitHub repo.   |
#     |  Outputs a clean markdown file (origin, untouched).       |
#     |                                                           |
#     +-----------------------------------------------------------+
#
# --- END HEADER ---

set -euo pipefail

TWEAKCC_REPO="Piebald-AI/tweakcc"
TWEAKCC_PATH="data/prompts"
OUTPUT_DIR="${FLEET_SP_DIR:-$(dirname "$(readlink -f "$0")")/../system-prompt}"

usage() {
    cat <<USAGE
Usage: fleet-sp-dump.sh [OPTIONS]

Dump Anthropic Claude Code system prompt from tweakcc GitHub repo.
Outputs a markdown file with all system-prompt-* pieces, untouched.

Options:
  --version X.Y.Z    Target a specific CC version (default: latest available)
  --input FILE.json  Use a local JSON file instead of fetching from GitHub
  --output DIR       Output directory (default: $OUTPUT_DIR)
  --list             List available versions on tweakcc and exit
  --diff             Compare fetched version with existing origin in output dir
  -h, --help         Show this help

Examples:
  fleet-sp-dump.sh                          # fetch latest
  fleet-sp-dump.sh --version 2.1.80         # specific version
  fleet-sp-dump.sh --input /tmp/dump.json   # offline fallback
  fleet-sp-dump.sh --list                   # list versions
  fleet-sp-dump.sh --diff                   # fetch latest + diff with current
USAGE
    exit 0
}

# --- Parse args ---
VERSION=""
INPUT_FILE=""
LIST_ONLY=false
DIFF_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)  VERSION="$2"; shift 2 ;;
        --input)    INPUT_FILE="$2"; shift 2 ;;
        --output)   OUTPUT_DIR="$2"; shift 2 ;;
        --list)     LIST_ONLY=true; shift ;;
        --diff)     DIFF_MODE=true; shift ;;
        -h|--help)  usage ;;
        *)          echo "Unknown option: $1" >&2; usage ;;
    esac
done

# --- List mode ---
if $LIST_ONLY; then
    echo "Available versions on $TWEAKCC_REPO:"
    gh api "repos/${TWEAKCC_REPO}/contents/${TWEAKCC_PATH}" --jq '.[].name' 2>/dev/null \
        | sed 's/prompts-//;s/\.json//' \
        | sort -V
    exit 0
fi

# --- Resolve version + fetch JSON ---
if [[ -n "$INPUT_FILE" ]]; then
    # Offline fallback
    if [[ ! -f "$INPUT_FILE" ]]; then
        echo "ERROR: file not found: $INPUT_FILE" >&2
        exit 1
    fi
    VERSION=$(python3 -c "import json; print(json.load(open('$INPUT_FILE')).get('version','unknown'))")
    JSON_FILE="$INPUT_FILE"
    echo "[fleet-sp-dump] source: local file $INPUT_FILE (version $VERSION)"
else
    # Fetch from GitHub
    if ! command -v gh &>/dev/null; then
        echo "ERROR: gh CLI required. Install or use --input for offline mode." >&2
        exit 1
    fi

    if [[ -z "$VERSION" ]]; then
        # Find latest version
        VERSION=$(gh api "repos/${TWEAKCC_REPO}/contents/${TWEAKCC_PATH}" --jq '.[].name' 2>/dev/null \
            | sed 's/prompts-//;s/\.json//' \
            | sort -V \
            | tail -1)
        if [[ -z "$VERSION" ]]; then
            echo "ERROR: could not determine latest version from tweakcc" >&2
            exit 1
        fi
        echo "[fleet-sp-dump] latest version: $VERSION"
    fi

    JSON_FILE=$(mktemp)
    trap 'rm -f "$JSON_FILE"' EXIT

    echo "[fleet-sp-dump] fetching prompts-${VERSION}.json from ${TWEAKCC_REPO}..."
    CONTENT=$(gh api "repos/${TWEAKCC_REPO}/contents/${TWEAKCC_PATH}/prompts-${VERSION}.json" --jq '.content' 2>/dev/null)
    if [[ -z "$CONTENT" || "$CONTENT" == "null" ]]; then
        echo "ERROR: version $VERSION not found on tweakcc" >&2
        exit 1
    fi
    echo "$CONTENT" | base64 -d > "$JSON_FILE"
    echo "[fleet-sp-dump] fetched $(wc -c < "$JSON_FILE") bytes"
fi

# --- Parse and dump to markdown ---
mkdir -p "$OUTPUT_DIR"
OUT_FILE="${OUTPUT_DIR}/anthropic-origin-${VERSION}.md"

python3 << PYEOF
import json, sys
from datetime import datetime

with open("$JSON_FILE") as f:
    data = json.load(f)

version = data.get("version", "$VERSION")
prompts = data.get("prompts", [])

# Filter system-prompt-* only, with content
sp = []
for p in prompts:
    pid = p.get("id", "")
    if not pid.startswith("system-prompt-"):
        continue
    pieces = p.get("pieces", [])
    content = "".join(s for s in pieces if isinstance(s, str))
    if not content.strip():
        continue
    name = pid.replace("system-prompt-", "")
    desc = p.get("description", "")
    sp.append((name, content, desc, len(content)))

# Write markdown
with open("$OUT_FILE", "w") as f:
    f.write(f"# Anthropic Claude Code System Prompt — v{version}\n\n")
    f.write(f"**Dumped** : {datetime.now().strftime('%Y-%m-%d %H:%M')}\n")
    f.write(f"**Source** : {('$TWEAKCC_REPO' if not '$INPUT_FILE' else '$INPUT_FILE')}\n")
    f.write(f"**Version CC** : {version}\n")
    f.write(f"**Prompts** : {len(sp)} system-prompt entries\n")
    f.write(f"**Total** : {sum(c for _,_,_,c in sp)} chars\n\n")
    f.write("---\n\n")

    for name, content, desc, chars in sp:
        f.write(f"## {name} ({chars}c)\n\n")
        if desc:
            f.write(f"> {desc}\n\n")
        f.write(content.rstrip() + "\n\n---\n\n")

print(f"[fleet-sp-dump] {len(sp)} prompts, {sum(c for _,_,_,c in sp)} chars")
print(f"[fleet-sp-dump] output: $OUT_FILE")
PYEOF

echo "[fleet-sp-dump] done: $OUT_FILE"

# --- Diff mode ---
if $DIFF_MODE; then
    EXISTING=$(find "$OUTPUT_DIR" -maxdepth 1 -name 'anthropic-origin-*.md' ! -name "*${VERSION}*" -print 2>/dev/null | sort -V | tail -1)
    if [ -z "$EXISTING" ]; then
        echo "[fleet-sp-dump] --diff: no previous origin to compare with"
    else
        echo ""
        echo "[fleet-sp-dump] diff: $(basename "$EXISTING") → $(basename "$OUT_FILE")"
        echo "=== Sections added ==="
        diff <(grep "^## " "$EXISTING") <(grep "^## " "$OUT_FILE") | grep "^>" | sed 's/^> /  + /'
        echo "=== Sections removed ==="
        diff <(grep "^## " "$EXISTING") <(grep "^## " "$OUT_FILE") | grep "^<" | sed 's/^< /  - /'
        echo "=== Size delta ==="
        OLD_SIZE=$(wc -c < "$EXISTING")
        NEW_SIZE=$(wc -c < "$OUT_FILE")
        echo "  $(basename "$EXISTING"): ${OLD_SIZE}c → $(basename "$OUT_FILE"): ${NEW_SIZE}c (delta: $((NEW_SIZE - OLD_SIZE))c)"
    fi
fi
