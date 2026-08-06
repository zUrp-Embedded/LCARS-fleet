#!/bin/bash
#
#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: run_tests.sh
#     |  |________|  | AUTHOR: STARFLEET
#     |   ________   | SYSTEM: LCARS-FLEET
#     |  |  v1.0  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | MODULE: TOKEN-SAVER     | SUBSYSTEM: RUNTIME / COMPRESSION |
#     | LICENSE: AGPL-3         | STARDATE: 2026.216               |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Gate de la brique vendoree token_saver.                  |
#     |  Deux suites, deux PROCESSUS : l'adapter modifie l'etat    |
#     |  global (config figee, vocabulaire, methode build).        |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     Lance la suite amont (lib non configuree) puis la suite LCARS
#     (lib sous adapter). Les deux DOIVENT tourner separement.
#
#         Input:   aucun
#         Output:  code retour 0 si les deux suites passent
#
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")" || exit 1

RC=0

echo "=== 1/3 · suite amont (lib non configuree) ==="
python3 -m pytest -p no:cacheprovider "$@" || RC=1

echo
echo "=== 2/3 · suite LCARS (lib sous adapter) ==="
python3 -m pytest lcars_tests -q -p no:cacheprovider -o addopts="" "$@" || RC=1

echo
echo "=== 3/3 · harnais de mesure de perte ==="
if [ -f tools/probe_loss.py ]; then
    python3 tools/probe_loss.py . 2>&1 | tail -5
else
    echo "  (harnais absent)"
fi

rm -rf .pytest_cache ./*/__pycache__ ./__pycache__ src/processors/__pycache__ 2>/dev/null

echo
[ $RC -eq 0 ] && echo "GATE VERT" || echo "GATE ROUGE"
exit $RC
