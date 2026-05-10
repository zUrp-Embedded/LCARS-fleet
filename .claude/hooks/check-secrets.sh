#!/usr/bin/env bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: check-secrets.sh
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
#     | MODULE: SECRET-GUARD    | SUBSYSTEM: HOOKS / SECURITY     |
#     | LICENSE: AGPL-3         | STARDATE: 2026.090              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Blocks file writes containing hardcoded secrets.             |
#     |  CC PreToolUse hook — scans Write targets for credentials.         |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     Bloque les commits contenant des secrets hardcodés (API keys, tokens, passwords).
#     Scanne les fichiers stagés avec des patterns regex.
#
#     [EN]
#     NAME
#         check-secrets.sh — block commits containing hardcoded secrets
#
#     INTERFACE
#         Ring:    CC Runtime (hook — PreToolUse, matcher: Bash)
#         Input:   git staged files (diff --cached)
#         Output:  block with list of findings, or pass if clean
#
#     EXIT CODES
#         0    Clean (no secrets found) or not a git commit
#         1    Secrets detected (commit blocked)
#
# --- END HEADER ---

set -euo pipefail

PAYLOAD=$(cat)
FILE=$(echo "$PAYLOAD" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('file_path',''))" 2>/dev/null)

if [ -z "$FILE" ]; then
  exit 0
fi

# Skip binary files
if ! file "$FILE" | grep -q "text"; then
  exit 0
fi

# Skip .env files (they're supposed to hold secrets, just not be versioned)
if [[ "$FILE" == *.env* ]]; then
  exit 0
fi

PATTERNS=(
  'sk-[a-zA-Z0-9]{20,}'          # OpenAI / Anthropic keys
  'ghp_[a-zA-Z0-9]{36}'          # GitHub personal tokens
  'AKIA[0-9A-Z]{16}'             # AWS access keys
  'password\s*=\s*["\x27][^"\x27]{4,}' # Hardcoded passwords
  'api_key\s*=\s*["\x27][^"\x27]{4,}'  # Generic API keys
  'token\s*=\s*["\x27][^"\x27]{8,}'    # Generic tokens
)

FOUND=0
for pattern in "${PATTERNS[@]}"; do
  if grep -qiP "$pattern" "$FILE" 2>/dev/null; then
    echo "⚠ SECRET PATTERN DETECTED in $FILE (pattern: $pattern)"
    FOUND=1
  fi
done

if [ "$FOUND" -eq 1 ]; then
  echo "→ Move secrets to .env and add to .gitignore"
  exit 1
fi

exit 0
