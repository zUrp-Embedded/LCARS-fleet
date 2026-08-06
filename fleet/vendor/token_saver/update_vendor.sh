#!/bin/bash
#
#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: update_vendor.sh
#     |  |________|  | AUTHOR: STARFLEET
#     |   ________   | SYSTEM: LCARS-FLEET
#     |  |  v1.0  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | MODULE: TOKEN-SAVER     | SUBSYSTEM: RUNTIME / VENDOR      |
#     | LICENSE: AGPL-3         | STARDATE: 2026.216               |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Suit l'amont ppgranger/token-saver.                      |
#     |  Re-copie src/ scripts/ tests/, puis passe le gate.       |
#     |  AUCUN patch a rejouer : la couche LCARS est hors sous-    |
#     |  arbre. Le gate dit si les ancrages tiennent encore.      |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     Met a jour la brique vendoree depuis l'amont.
#
#         Usage:   ./update_vendor.sh [ref]            inspection seule
#                  ./update_vendor.sh [ref] --apply    re-copie + gate
#         Output:  rapport amont, puis sous-arbre a jour si --apply
#
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")" || exit 1

UPSTREAM="https://github.com/ppgranger/token-saver.git"
APPLY=0
REF="main"
for a in "$@"; do
    case "$a" in
        --apply) APPLY=1 ;;
        *) REF="$a" ;;
    esac
done
PIN=$(grep -oP '@ `\K[0-9a-f]{40}' VENDOR.md | head -1)

echo "=== brique vendoree : token_saver ==="
echo "  amont   : $UPSTREAM"
echo "  pin     : ${PIN:-inconnu}"
echo "  cible   : $REF"
[ $APPLY -eq 1 ] && echo "  mode    : APPLY (le sous-arbre sera remplace)" \
                 || echo "  mode    : inspection (aucune ecriture)"
echo

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

echo "=== 1/5 · recuperation ==="
git clone --quiet "$UPSTREAM" "$TMP/up" || { echo "  ECHEC clone"; exit 1; }
git -C "$TMP/up" checkout --quiet "$REF" || { echo "  ECHEC checkout $REF"; exit 1; }
NEW=$(git -C "$TMP/up" rev-parse HEAD)
echo "  HEAD amont : $NEW"

if [ "$NEW" = "$PIN" ]; then
    echo "  deja a jour — rien a faire."
    exit 0
fi

echo
echo "=== 2/5 · ce qui change en amont ==="
if [ -n "$PIN" ] && git -C "$TMP/up" cat-file -e "$PIN^{commit}" 2>/dev/null; then
    git -C "$TMP/up" log --oneline "$PIN..$NEW" -- src scripts tests | head -30
    echo
    echo "  fichiers touches :"
    git -C "$TMP/up" diff --stat "$PIN..$NEW" -- src scripts tests | tail -15
else
    echo "  (pin absent de l'historique amont — diff impossible)"
fi

if [ $APPLY -eq 0 ]; then
    echo
    echo "=== inspection terminee — rien n'a ete ecrit ==="
    echo "  relancer avec --apply pour re-copier et passer le gate."
    exit 0
fi

echo
echo "=== 3/5 · re-copie du sous-arbre ==="
if ! git diff --quiet -- src scripts tests 2>/dev/null; then
    echo "  REFUS : src/ scripts/ ou tests/ portent des modifications non commitees."
    echo "  Le sous-arbre doit etre propre — la re-copie ecraserait ce travail."
    exit 1
fi
for d in src scripts tests; do
    [ -d "$TMP/up/$d" ] || { echo "  ECHEC : $d absent en amont"; exit 1; }
    rm -rf "./$d"
    cp -r "$TMP/up/$d" "./$d"
    echo "  $d/ remplace"
done
cp "$TMP/up/LICENSE" ./LICENSE.upstream
find . -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null

# Les suites amont dont la cible n'est pas reprise (voir VENDOR.md).
rm -f tests/test_installers.py
echo "  tests/test_installers.py retire (installers/ non repris)"

echo
echo "=== 4/5 · gate ==="
./run_tests.sh
RC=$?

echo
echo "=== 5/5 · suite ==="
if [ $RC -ne 0 ]; then
    cat <<EOF
  GATE ROUGE — sous-arbre mis a jour mais NON valide.

  Si l'echec vient de lcars_tests/test_contrat_amont.py, un point d'ancrage
  de l'adapter a disparu ou change en amont. Le message du test dit lequel et
  ce qui se rouvre. Corriger adapter.py / lcars_processors.py, PAS le
  sous-arbre.

  Pour revenir en arriere :  git checkout -- src scripts tests
EOF
    exit 1
fi

cat <<EOF
  GATE VERT. Reste a faire :

    1. mettre a jour le pin dans VENDOR.md :
         $PIN
       ->  $NEW
    2. git add -A . && git commit
EOF
