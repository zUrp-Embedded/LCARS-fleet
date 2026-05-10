#!/bin/bash
#
#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: run-shellcheck.sh
#     |  |________|  | AUTHOR: LORDZURP
#     |   ________   | SYSTEM: LCARS-FLEET v1.0
#     |  |  v1.0  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS-FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: QUALITY-GATE    | SUBSYSTEM: TESTS / SHELLCHECK   |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Static analysis gate. Runs shellcheck on all .sh files.  |
#     |  Exit 0 if clean, exit 1 if any warning.                  |
#     |                                                           |
#     +-----------------------------------------------------------+
#
# USAGE   : ./tests/run-shellcheck.sh

set -uo pipefail
# Note: no set -e — we handle errors explicitly in the loop.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

if ! command -v shellcheck &>/dev/null; then
    echo "ERROR: shellcheck not installed" >&2
    exit 1
fi

# Collect all .sh files, excluding _archived and test submodules
SCRIPTS=()
while IFS= read -r -d '' file; do
    SCRIPTS+=("$file")
done < <(find "$REPO_ROOT/fleet" "$REPO_ROOT/.claude/hooks" \
    -name "*.sh" -not -path "*/_archived/*" -not -path "*/tests/*" \
    -print0 2>/dev/null | sort -z)

TOTAL=${#SCRIPTS[@]}
PASS=0
FAIL=0
FAILED_FILES=()

echo "shellcheck v$(shellcheck --version | grep "^version:" | cut -d' ' -f2)"
echo "Scanning $TOTAL scripts..."
echo ""

for script in "${SCRIPTS[@]}"; do
    rel="${script#"$REPO_ROOT/"}"
    script_dir="$(dirname "$script")"
    # --source-path: let shellcheck find sourced files relative to script location
    # -e SC1091: "not following" — dynamic source paths unresolvable in static analysis
    # -e SC2317: "unreachable" — false positive on functions called indirectly (trap, eval)
    output="$(shellcheck -x -S warning \
        --source-path="$script_dir" --source-path="$REPO_ROOT/fleet" \
        -e SC1091 -e SC2317 \
        "$script" 2>&1)" || true
    if [[ -z "$output" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED_FILES+=("$rel")
        echo "FAIL: $rel"
        echo "$output" | head -20
        echo "---"
    fi
done

echo ""
echo "RESULT: $PASS/$TOTAL pass, $FAIL fail"

if [[ $FAIL -gt 0 ]]; then
    echo ""
    echo "Failed files:"
    for f in "${FAILED_FILES[@]}"; do
        echo "  $f"
    done
    exit 1
fi

exit 0
