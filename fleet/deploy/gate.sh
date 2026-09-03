#!/usr/bin/env bash
# SOURCE: fleet/deploy/gate.sh
# AUTHOR: bob
# STARDATE: (posee par /push-github)
# STATUS: la porte de L'INSTALLEUR — sa suite, jouee par lui, pas par le gate du runtime
#
# POURQUOI UNE SECONDE PORTE, et pourquoi elle n'est pas un doublon.
#
# ⚖ USER : « avoir 2 dossiers independant, avec 2 software independant : l'installeur et le
# runtime. chacun avec sa suite de tests. ya pas de "si on sort de mix on teste plus rien" : c'est
# quoi la logique de tester la chaine d'install en bash a partir du mix elixir du runtime ? »
#
# MESURE : 1294 des 1774 cas bats que `mix gate` joue sont sous `deploy/tests/` — 73 % de la suite
# bats du runtime est en realite la suite de l'installeur. Elle n'etait pas a ecrire : elle etait
# branchee du mauvais cote.
#
# ⚠ ET LE DEBRANCHEMENT PORTE UN RISQUE NOMME, celui-la meme que `@test_corpora` du contracts.check
# raconte : « `fleet/deploy/tests` had never been run by any gate […] A corpus nobody runs does not
# rot loudly — it rots while reporting a coverage it does not provide ». Ce corpus a ete accroche au
# gate du runtime en aout PARCE QUE personne ne le jouait. Le detacher sans plus referait ce
# defaut-la, en le declarant corrige.
#
# CE QUI REND LE DETACHEMENT SUR — trois points de passage, et aucun n'est declaratif :
#   1. `pack.sh` joue CETTE porte avant d'empaqueter, au meme titre que `mix gate`. Rien n'atteint
#      la production sans les deux vertes.
#   2. `tests.corpora_on_record` (contracts.check) declare ce corpus `{:gated_by, <ce fichier>}` et
#      VERIFIE que le fichier existe et decouvre bien le corpus — un chemin mort echoue.
#   3. `deploy/tests/installer_gate.bats` mesure cette porte : elle refuse un corpus vide, elle
#      refuse bats absent, et son verdict suit celui de bats.
#
# ⚠ LA NEUTRALISATION D'ENVIRONNEMENT CI-DESSOUS EST UNE SECONDE COPIE, ASSUMEE ET GARDEE. Le
# raisonnement complet vit dans `fleet/test/shell_gate.sh` (trois pannes datees : `FORGE_BASE_URL`
# exporte par `provision --env`, un `LCARS_SEAT_UID_FILE` pose a la main, `PROV_FLEET_GROUP` qui
# VOYAGE par `services.env`). Le recopier ici serait un mensonge par redondance ; l'omettre ferait
# de cette porte un instrument que l'environnement du lanceur peut retuner. Un temoin garde donc que
# les deux blocs disent la meme chose — meme motif que `tests.refute_copies_agree`, qui tient deja
# les deux copies de `refute.bash` dans ce depot.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$HERE/tests"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

# ⚠ `--list-corpora` IMPRIME LA VARIABLE QUE LA DECOUVERTE UTILISE, il ne redeclare rien. C'est ce
# que `tests.corpora_on_record` interroge : le registre des corpus ne CROIT plus un mot-cle
# (`:gated`), il DEMANDE a chaque porte ce qu'elle joue. Un chemin mort, ou une porte qui a cesse de
# decouvrir son corpus, deviennent un echec nomme au lieu d'un silence.
if [[ "${1:-}" == "--list-corpora" ]]; then
  [[ -d "$TESTS_DIR" ]] && printf '%s\n' "${TESTS_DIR#"$REPO_ROOT/"}"
  exit 0
fi

echo "=== gate de l'installeur : $HERE ==="

# ⚠ CORPUS VIDE = ECHEC, JAMAIS UN SAUT. C'est la forme exacte du defaut que cette porte existe
# pour fermer : zero test joue se lit comme zero test rouge.
mapfile -t BATS_FILES < <(find "$TESTS_DIR" -type f -name '*.bats' 2>/dev/null | sort)
if [[ "${#BATS_FILES[@]}" -eq 0 ]]; then
  echo "ECHEC: aucun .bats sous $TESTS_DIR — la porte de l'installeur ne mesure RIEN." >&2
  exit 1
fi
# ⚠ `|| true` LOAD-BEARING (mur I3). `grep -c` rend 1 quand il ne trouve RIEN, et sous
# `set -euo pipefail` ce 1 traverse le tube : l'affectation meurt, et le script avec — AVANT la
# garde `bats absent` juste en dessous. Un corpus de fichiers `.bats` dont aucun ne porte de `@test`
# (une suite videe par un refactor, exactement le cas qu'on veut voir) tuait donc cette porte sans
# un mot. Trouve par `installer_gate.bats`, qui fabriquait ce corpus-la pour mesurer autre chose.
BATS_TEST_COUNT="$( { grep -hcE '^@test' "${BATS_FILES[@]}" 2>/dev/null || true; } | awk '{s+=$1} END {print s+0}')"

if ! command -v bats >/dev/null 2>&1; then
  echo "ECHEC: bats absent — ${#BATS_FILES[@]} fichier(s), $BATS_TEST_COUNT cas NON joues." >&2
  echo "       Installer : apt install bats  (ce n'est pas une dependance optionnelle ici :" >&2
  echo "       cette porte EST la suite de l'installeur)." >&2
  exit 1
fi

# Voir l'avertissement en tete : seconde copie assumee du bloc de `fleet/test/shell_gate.sh`.
BATS_ENV=()
while read -r v; do [[ -n "$v" ]] && BATS_ENV+=(-u "$v"); done < <(
  compgen -v | grep -E '^(LCARS_|PROV_|FORGE_)' | sort
)
if [[ "${#BATS_ENV[@]}" -gt 0 ]]; then
  echo "--- ${#BATS_ENV[@]} variable(s) du lanceur NEUTRALISEE(S) : ${BATS_ENV[*]//-u/}"
fi

echo "--- bats : ${#BATS_FILES[@]} fichier(s), $BATS_TEST_COUNT cas ---"
set +e
env "${BATS_ENV[@]}" bats "${BATS_FILES[@]}"
RC=$?
set -e

if [[ "$RC" -ne 0 ]]; then
  echo "=== gate de l'installeur : ECHEC (bats exit=$RC) ===" >&2
  exit "$RC"
fi
echo "=== gate de l'installeur : OK ($BATS_TEST_COUNT cas) ==="
