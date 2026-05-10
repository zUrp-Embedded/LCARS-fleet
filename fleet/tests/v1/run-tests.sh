#!/bin/bash
#
#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: run-tests.sh
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
#     | MODULE: QUALITY-GATE    | SUBSYSTEM: TESTS / BATS        |
#     | LICENSE: AGPL-3         | STARDATE: 2026.084              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Single entry point for the full bats test suite.         |
#     |  Exit 0 if all pass, exit 1 if any fail.                  |
#     |                                                           |
#     +-----------------------------------------------------------+
#
# USAGE   : ./tests/run-tests.sh [unit|integration|system]
#           No argument = run all levels.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BATS="$SCRIPT_DIR/.bats/bats-core/bin/bats"

if [[ ! -x "$BATS" ]]; then
    echo "ERROR: bats not found at $BATS" >&2
    echo "  Run: git submodule update --init --recursive" >&2
    exit 1
fi

LEVEL="${1:-all}"
FAILED=0

run_level() {
    local dir="$SCRIPT_DIR/$1"
    if [[ -d "$dir" ]] && compgen -G "$dir/*.bats" > /dev/null; then
        echo "=== $1 ==="
        "$BATS" --tap "$dir" || FAILED=1
        echo ""
    else
        echo "=== $1 === (no tests)"
        echo ""
    fi
}

case "$LEVEL" in
    unit)        run_level "unit" ;;
    integration) run_level "integration" ;;
    system)      run_level "system" ;;
    all)
        run_level "unit"
        run_level "integration"
        run_level "system"
        ;;
    *)
        echo "Usage: $0 [unit|integration|system|all]" >&2
        exit 1
        ;;
esac

if [[ $FAILED -ne 0 ]]; then
    echo "RESULT: FAIL"
    exit 1
else
    echo "RESULT: PASS"
    exit 0
fi
