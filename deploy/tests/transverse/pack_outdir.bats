#!/usr/bin/env bats
# SOURCE: deploy/tests/transverse/pack_outdir.bats
# AUTHOR: DrDree
# STARDATE: (posee par /push-github)
# STATUS: bats tests for pack.sh — le paquet atterrit HORS de l'arbre, et le chemin est derive
#
# CE QUE CE CORPUS FERME, ET IL EST NE D'UNE PERTE FRÔLEE. Le tar allait dans `dist/`, a la racine
# du checkout : gitignore, donc invisible au `git status`, donc jamais range. Mesure du 2026-08-26,
# apres un arret froid — le paquet de la derniere revision viable, bati onze minutes avant la
# coupure, n'existait QUE dans le clone qui allait etre detruit. Un clone se jette ; un artefact que
# la forge doit porter ne peut pas vivre dedans.
#
# ⚠ ET LE TIROIR NE PEUT PAS ETRE UN CHEMIN DE LA MACHINE QUI L'A ECRIT. Le dossier evident sur le
# poste ou ce changement a ete fait etait `/home/commons` — un dossier de la v1, que
# `25-directories` a justement cesse de poser. Grave dans le produit, il aurait ete une panne pour
# tous les autres. Le defaut est donc DERIVE du checkout, et `LCARS_PACK_DIR` reste pour choisir.
#
# ⚠ ON EXECUTE LA RESOLUTION REELLE, EXTRAITE DU FICHIER. Un temoin qui `grep`-erait `dist/` ne
# mesurerait que l'orthographe d'une correction : la prochaine forme fautive s'ecrira autrement.
# On extrait les deux lignes qui calculent le chemin, on les evalue, et on regarde ou ca tombe.

# ⚠ SIGNALEMENTS VERIFIES UN PAR UN, AUCUN N'EST UN DEFAUT :
#   SC2013 — lecture mot a mot VOULUE : le champ mesure ne contient pas d'espace
#   SC2034 — variable posee pour un sous-processus ou lue par un helper, pas par ce fichier
# shellcheck disable=SC2013,SC2034

load ../refute

setup() {
  SUT="$BATS_TEST_DIRNAME/../../../pack.sh"
  [ -f "$SUT" ] || skip "pack.sh introuvable depuis $BATS_TEST_DIRNAME"
  # les deux lignes qui decident du chemin, telles qu'elles sont dans le fichier
  RESOLVE="$(grep -E '^(PACK_DIR|OUT)=' "$SUT")"
  [ -n "$RESOLVE" ] || skip "la resolution du chemin a change de forme"
}

# `pack.sh` fait `cd` a la racine du depot avant tout ; on rejoue ce contrat.
resolve_in() { # <racine simulee> [valeur de LCARS_PACK_DIR]
  local root="$1"
  mkdir -p "$root"
  ( cd "$root" \
    && NAME=paquet \
    && if [ -n "${2-}" ]; then export LCARS_PACK_DIR="$2"; else unset LCARS_PACK_DIR; fi \
    && eval "$RESOLVE" \
    && printf '%s\n' "$OUT" )
}

@test "sans reglage, le paquet tombe A COTE du checkout, jamais dedans" {
  local root="$BATS_TEST_TMPDIR/depot" out
  out="$(resolve_in "$root")"
  [ -n "$out" ]
  # la cicatrice : le chemin ne doit PAS etre sous la racine du depot
  case "$out" in
    "$root"/*) echo "le paquet retombe DANS l'arbre : $out" >&2; return 1 ;;
  esac
  # et il est bien voisin, pas perdu quelque part
  [ "$(dirname "$out")" = "$BATS_TEST_TMPDIR/lcars-packs" ]
}

@test "deux clones de la meme machine partagent UN tiroir — c'est le but" {
  local a b
  a="$(resolve_in "$BATS_TEST_TMPDIR/clone-a")"
  b="$(resolve_in "$BATS_TEST_TMPDIR/clone-b")"
  [ "$(dirname "$a")" = "$(dirname "$b")" ]
}

@test "LCARS_PACK_DIR est souverain — c'est la porte de sortie de qui a une autre topologie" {
  local out
  out="$(resolve_in "$BATS_TEST_TMPDIR/depot" "$BATS_TEST_TMPDIR/ailleurs")"
  [ "$(dirname "$out")" = "$BATS_TEST_TMPDIR/ailleurs" ]
}

@test "aucun chemin d'une machine particuliere n'est ecrit dans le packageur" {
  # `/home/commons` est le cas qui a failli arriver ; les autres sont des racines d'install que
  # seul le manifeste a le droit de nommer.
  grep -vE '^\s*#' "$SUT" | refute_out '/home/commons|/local/LCARS|/opt/lcars|/usr/share/lcars'
}

@test "PACK_DIR est POSE avant la ligne qui le nomme — sinon set -u tue le packageur" {
  # La cicatrice : le message « le tar est dans … » a ete ecrit APRES coup, et il a immediatement
  # casse `pack_secrets.bats`, qui execute ce bloc pour de vrai. Le temoin la-bas modelise le
  # contexte ; celui-ci tient l'ORDRE dans le fichier, qui est ce dont depend l'execution reelle.
  local pose l
  pose="$(grep -n '^PACK_DIR=' "$SUT" | head -1 | cut -d: -f1)"
  [ -n "$pose" ]
  # toute mention de PACK_DIR dans le code vient APRES son affectation
  for l in $(grep -nE 'PACK_DIR' "$SUT" | grep -vE ':\s*#' | cut -d: -f1); do
    [ "$l" -ge "$pose" ] || { echo "PACK_DIR employe l.$l, avant son affectation l.$pose" >&2; return 1; }
  done
}
