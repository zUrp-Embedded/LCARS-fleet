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
#     | LICENSE: AGPL-3         | STARDATE: 2026.247               |
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
#         Usage:   ./update_vendor.sh --verify           le sous-arbre EST-IL le pin ?
#                  ./update_vendor.sh [ref]            inspection seule
#                  ./update_vendor.sh [ref] --apply    re-copie + gate
#         Output:  rapport amont, puis sous-arbre a jour si --apply
#
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")" || exit 1

UPSTREAM="https://github.com/ppgranger/token-saver.git"
APPLY=0
VERIFY=0
REF="main"
for a in "$@"; do
    case "$a" in
        --apply)  APPLY=1 ;;
        --verify) VERIFY=1 ;;
        *) REF="$a" ;;
    esac
done
PIN=$(grep -oP '@ `\K[0-9a-f]{40}' VENDOR.md | head -1)

echo "=== brique vendoree : token_saver ==="
echo "  amont   : $UPSTREAM"
echo "  pin     : ${PIN:-inconnu}"
[ $VERIFY -eq 1 ] || echo "  cible   : $REF"
if   [ $VERIFY -eq 1 ]; then echo "  mode    : VERIFY (le sous-arbre est-il le pin ?)"
elif [ $APPLY  -eq 1 ]; then echo "  mode    : APPLY (le sous-arbre sera remplace)"
else                         echo "  mode    : inspection (aucune ecriture)"
fi
echo

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

# ─── MODE --verify : le pin est-il un FAIT, ou seulement une phrase ? ───────────────────────────
# Comparer l'amont au pin DECLARE dans VENDOR.md ne dit pas que notre sous-arbre corresponde a ce
# pin : deux choses divergent alors en silence, le sha lui-meme (l'etape 5 dit a l'humain de le
# recopier a la main, et une main oublie) et l'ETIQUETTE posee a cote. Mesure du 2026-08-09 : sha
# juste, etiquette « v2.6.3 » alors que `git describe` rend `v1.3.1-84-g098873e` et que ce tag est
# 16 commits plus loin — meme date, donc invisible a l'oeil. Un update « vers v2.6.3 » embarquerait
# 16 commits en croyant n'en embarquer aucun.
#
# Ce mode rejoue la mesure : archive de l'amont AU PIN, diff contre notre sous-arbre. `.go7-exempt`
# est le seul ecart admis — c'est notre marqueur, pas du code amont.
if [ $VERIFY -eq 1 ]; then
    [ -n "$PIN" ] || { echo "  ECHEC : aucun pin lisible dans VENDOR.md"; exit 1; }
    TMPV=$(mktemp -d) || exit 1
    trap 'rm -rf "$TMPV"' EXIT
    git clone --quiet "$UPSTREAM" "$TMPV/up" || { echo "  ECHEC clone"; exit 1; }
    git -C "$TMPV/up" cat-file -e "$PIN^{commit}" 2>/dev/null \
        || { echo "  ECHEC : le pin $PIN n'existe pas en amont"; exit 1; }

    echo "  describe : $(git -C "$TMPV/up" describe --tags "$PIN" 2>/dev/null || echo '<sans tag ancetre>')"
    mkdir -p "$TMPV/pin"
    git -C "$TMPV/up" archive "$PIN" src scripts tests | tar -x -C "$TMPV/pin"
    rm -f "$TMPV/pin/tests/test_installers.py"

    RCV=0
    for d in src scripts tests; do
        out=$(diff -rq --exclude=__pycache__ --exclude=.go7-exempt "$TMPV/pin/$d" "./$d" 2>&1)
        if [ -z "$out" ]; then
            echo "  $d/ : identique au pin"
        else
            echo "  $d/ : DIVERGE du pin"
            echo "$out" | sed 's/^/      /' | head -20
            RCV=1
        fi
    done
    [ $RCV -eq 0 ] && echo "  VERIFIE : le sous-arbre EST le pin." \
                   || echo "  ECHEC : le sous-arbre n'est pas le pin declare dans VENDOR.md."
    exit $RCV
fi

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
