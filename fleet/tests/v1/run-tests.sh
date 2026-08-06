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
# `..` : ce script vit dans tests/v1/, le sous-module bats vit dans tests/.bats/. Le chemin d'avant
# le rangement du 2026-07-31 (`chore: isolate v1 files into v1/ subdirectories at every level`)
# pointait un niveau trop bas et ce lanceur n'a plus jamais demarre — meme casse que celle qui a tue
# les 447 cas du corpus lui-meme, dans le meme commit et jamais vue parce que personne ne le lance.
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BATS="$TESTS_DIR/.bats/bats-core/bin/bats"

# Repli sur le bats du systeme : le sous-module est PINE (reproductibilite) mais il n'est pas
# toujours recupere, et refuser de tourner quand un bats parfaitement valide est dans le PATH est un
# refus qui ne protege rien. On DIT lequel on prend — deux bats de versions differentes ne rendent
# pas les memes verdicts, et un lanceur qui tait sa toolchain rend un resultat inattribuable.
if [[ -x "$BATS" ]]; then
    echo "bats: sous-module pine ($BATS)"
elif command -v bats >/dev/null 2>&1; then
    BATS="$(command -v bats)"
    echo "bats: SYSTEME ($BATS, $("$BATS" --version 2>/dev/null)) — sous-module absent" >&2
    echo "  pour le pin : git submodule update --init fleet/tests/.bats/bats-core" >&2
else
    echo "ERROR: aucun bats — ni $BATS ni dans le PATH" >&2
    echo "  Run: git submodule update --init --recursive" >&2
    exit 1
fi

LEVEL="${1:-all}"
FAILED=0

# Les suites vivent en tests/<niveau>/v1/, pas en tests/v1/<niveau>/ : le meme rangement a separe le
# LANCEUR (parti dans v1/) de ce qu'il lance (reste sous unit/, puis descendu d'un cran dans v1/).
run_level() {
    local dir="$TESTS_DIR/$1/v1"
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
