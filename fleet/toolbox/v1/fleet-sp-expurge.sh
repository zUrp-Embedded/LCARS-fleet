#!/usr/bin/env bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-sp-expurge.sh
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
#     | MODULE: FLEET-SP-EXPURGE  | SUBSYSTEM: TOOLBOX / SP       |
#     | LICENSE: AGPL-3           | STARDATE: 2026.087            |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Apply LCARS expurgation rules to an Anthropic SP origin. |
#     |  Removes conflicting/duplicate prompts, modifies others.  |
#     |  Input: anthropic-origin-X.Y.Z.md  Output: stdout or file|
#     |                                                           |
#     +-----------------------------------------------------------+
#
# --- END HEADER ---

set -euo pipefail

usage() {
    cat <<USAGE
Usage: fleet-sp-expurge.sh <input.md> [output.md]

Apply LCARS expurgation rules to an Anthropic SP origin file.
If output is omitted, writes to stdout.

Rules applied:
  - 26 prompts removed (memory, multi-agent, analytics, learning, chrome, doublons)
  - 3 prompts modified (output-efficiency, doing-tasks-blocked, auto-mode)

Examples:
  fleet-sp-expurge.sh anthropic-origin-2.1.80.md                     # stdout
  fleet-sp-expurge.sh anthropic-origin-2.1.80.md anthropic-lcars.md  # file
  fleet-sp-dump.sh --version 2.1.70 && fleet-sp-expurge.sh /path/to/origin.md  # pipeline
USAGE
    exit 0
}

[ $# -lt 1 ] && usage
[ "$1" = "-h" ] || [ "$1" = "--help" ] && usage

INPUT="$1"
OUTPUT="${2:-/dev/stdout}"

if [ ! -f "$INPUT" ]; then
    echo "ERROR: file not found: $INPUT" >&2
    exit 1
fi

python3 << PYEOF
import re, sys

with open("$INPUT") as f:
    content = f.read()

# Split into sections by "## " headers
parts = re.split(r'(?=^## )', content, flags=re.MULTILINE)
header = parts[0]
sections = parts[1:] if len(parts) > 1 else []

# --- REMOVE list ---
REMOVE = {
    'agent-memory-instructions',
    'description-part-of-memory-instructions',
    'memory-description-of-user-feedback',
    'team-memory-content-display',
    'fork-usage-guidelines',
    'subagent-delegation-examples',
    'tool-usage-subagent-guidance',
    'writing-subagent-prompts',
    'worker-instructions',
    'agent-summary-generation',
    'agent-thread-notes',
    'teammate-communication',
    'scratchpad-directory',
    'skillify-current-session',
    'insights-at-a-glance-summary',
    'insights-friction-analysis',
    'insights-on-the-horizon',
    'insights-session-facets-extraction',
    'insights-suggestions',
    'learning-mode',
    'learning-mode-insights',
    'chrome-browser-mcp-tools',
    'claude-in-chrome-browser-automation',
    'tone-concise-output-short',
    'doing-tasks-over-engineering',
    'doing-tasks-read-first',
}

kept = []
removed = 0

for s in sections:
    first_line = s.split('\n')[0]
    name = re.sub(r'^## (\S+).*', r'\1', first_line).strip()
    if name in REMOVE:
        removed += 1
        continue
    kept.append(s)

# --- MODIFY ---
modified = []
for s in kept:
    first_line = s.split('\n')[0]
    name = re.sub(r'^## (\S+).*', r'\1', first_line).strip()

    if name == 'output-efficiency':
        s = s.replace(
            "IMPORTANT: Go straight to the point. Try the simplest approach first without going in circles. Do not overdo it. Be extra concise.",
            "IMPORTANT: Go straight to the point. Be extra concise."
        )

    elif name == 'doing-tasks-blocked':
        s = s.replace(
            "do not attempt to brute force your way to the outcome. For example, if an API call or test fails, do not wait and retry the same action repeatedly. Instead, consider alternative approaches or other ways you might unblock yourself",
            "do not attempt to brute force your way to the outcome. Instead, understand the root cause before retrying"
        )

    elif 'Auto Mode Active' in s or name == 'auto-mode':
        s = s.replace(
            "3. **Prefer action over planning** — Do not enter plan mode unless the user explicitly asks. When in doubt, start coding.",
            "3. **Prefer action over planning** — Do not enter plan mode unless the user explicitly asks or directives require a plan. When in doubt, start coding."
        )

    modified.append(s)

# --- Output ---
version = "unknown"
for line in header.split('\n'):
    if 'Version CC' in line or '— v' in line:
        m = re.search(r'[\d]+\.[\d]+\.[\d]+', line)
        if m:
            version = m.group()
            break

out_header = f"""# Anthropic Claude Code System Prompt — LCARS edition

**Base** : v{version}
**Expurgated** : {removed} prompts removed, 3 modified
**Rules** : LCARS fleet expurgation (fleet-sp-expurge.sh)

---

"""

result = out_header + '\n---\n\n'.join(modified)

with open("$OUTPUT", 'w') if "$OUTPUT" != "/dev/stdout" else sys.stdout as f:
    f.write(result)

print(f"[fleet-sp-expurge] {removed} removed, {len(modified)} kept, 3 modified", file=sys.stderr)
PYEOF
