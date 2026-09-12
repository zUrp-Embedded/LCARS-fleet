#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/docker/bench_swap_creds.bats
# AUTHOR: DrDree
# STARDATE: (posee par /push-github)
# STATUS: bats tests for bench-swap-image.sh — la sonde des credentials ne fait pas descendre le secret
#
# CE QUE CE TEMOIN TIENT, ET CE QU'IL A COUTE. Pour dire « creds : oui/non » dans son recap, ce
# script copiait `.credentials.json` du conteneur dans un `mktemp` de l'hote, testait sa taille, puis
# faisait `rm -f`. Le fichier extrait porte des jetons OAuth Anthropic VIVANTS.
#
# Le `rm` echouait, et personne ne regardait son code de retour : sur une machine ou l'acces au
# daemon passe par sudo (socket rootful — cas ordinaire, et celui de ce poste), `docker cp` ecrit en
# root, `/tmp` est sticky, donc celui qui a cree le fichier n'en est plus proprietaire et ne peut
# pas l'effacer. Mesure du 2026-08-18 : DEUX copies des credentials dans /tmp, une par swap,
# toujours la, pendant que le script se croyait propre. Une seule ligne d'erreur `rm:` dans un flot
# de sortie, jamais lue.
#
# La question posee etait « present et non vide », jamais « quel contenu ». L'en-tete du flux tar de
# `docker cp … -` y repond sans qu'un octet touche le disque.

# ⚠ SC2016 : CE TEMOIN LIT DU CODE. Ses motifs `grep`/`sed` portent des `${VAR:-defaut}` qui
# doivent atteindre l'outil TELS QUELS — les developper chercherait la valeur dans CE shell au lieu
# du texte audite. Les quotes simples sont l'instrument, pas un oubli.
# shellcheck disable=SC2016

# ⚠ SIGNALEMENTS VERIFIES UN PAR UN, AUCUN N'EST UN DEFAUT :
#   SC2034 — variable posee pour un sous-processus ou lue par un helper, pas par ce fichier
# shellcheck disable=SC2034

load ../refute

setup() {
  SUT="$BATS_TEST_DIRNAME/../../docker/bench/bench-swap-image.sh"
  [ -f "$SUT" ]
}

@test "aucun secret n'est ecrit sur l'hote : pas de mktemp, et le cp des creds STREAME" {
  # ⚠ LE CODE, PAS LE FICHIER — ET LA CONVERSION EN `refute` L'A REVELE. Tant que cette ligne etait
  # `! grep …` non-derniere de son bloc, son statut etait jete : elle ne pouvait pas rougir. Rendue
  # mordante, elle a accuse la CICATRICE de `bench-swap-image.sh:227`, qui cite `mktemp` pour
  # expliquer le defaut qu'elle a ferme. Un temoin qui lit la prose accuse le commentaire qui
  # documente le correctif — et la seule reponse est de lire ce qui S'EXECUTE.
  grep -vE '^[[:space:]]*#' "$SUT" | refute_out 'mktemp'
  # tout `docker cp` des credentials doit finir par « - » (stdout), jamais par un chemin d'hote
  run bash -c "grep -n 'credentials.json' '$SUT' | grep -v '^\\s*#' | grep 'cp '"
  [ -n "$output" ]
  [[ "$output" == *'credentials.json" -'* ]]
}

@test "le recap dit toujours oui/non — la sonde n'a pas disparu avec le fichier temporaire" {
  grep -q 'CREDS_OK=oui' "$SUT"
  grep -q 'CREDS_OK=non' "$SUT"
  grep -q 'creds     : \$CREDS_OK' "$SUT"
}

@test "la TAILLE se lit bien au champ 3 du listing tar — l'hypothese de parsing, epinglee" {
  # C'est la seule partie fragile : `tar -tv` n'a pas le meme format partout. Si un jour il bouge,
  # la sonde repondrait « non » sur des credentials presentes et le banc s'accuserait a tort.
  printf '%0.s.' $(seq 1 509) > "$BATS_TEST_TMPDIR/.credentials.json"
  run bash -c "tar -C '$BATS_TEST_TMPDIR' -cf - .credentials.json | tar -tv | awk 'NR==1 {print \$3}'"
  [ "$status" -eq 0 ]
  [ "$output" = "509" ]
}

@test "un flux VIDE (fichier absent dans le conteneur) ne rend pas un faux « oui »" {
  run bash -c "printf '' | tar -tv 2>/dev/null | awk 'NR==1 {print \$3}'"
  [ -z "$output" ]
  # et la garde du script refuse tout ce qui n'est pas un entier strictement positif
  CREDS_SIZE=""
  run bash -c '[[ "${CREDS_SIZE:-}" =~ ^[0-9]+$ ]] && [[ "$CREDS_SIZE" -gt 0 ]]'
  [ "$status" -ne 0 ]
}

# ─── LE MAGASIN : TROIS SCRIPTS PARTAGENT UN COMPOSE, UN SEUL L'OUBLIAIT ────────────────────────
#
# Le compose du conteneur nomme ses volumes `${LCARS_STORE_PREFIX}-<nature>` avec un `:?`. Sans la
# variable, compose refuse de PARSER le fichier — donc pas « un volume manque » mais « rien ne se
# cree », sur un banc parfaitement sain.
#
# Mesure du 2026-08-21, swap du banc #2 : « required variable LCARS_STORE_PREFIX is missing a
# value », puis « le conteneur ne se cree pas ». `bench-up.sh` et `bench-down.sh` l'exportaient chacun ;
# ce script utilisait le meme compose et ne l'exportait pas.

@test "bench-swap-image EXPORTE LCARS_STORE_PREFIX — sinon compose ne parse meme pas" {
  # lot 9 (DI-05) : le prefixe est celui du CONTENEUR, <N>-fleet, derive de la base
  grep -qE '^export LCARS_STORE_PREFIX="\$CONTAINER_PROJECT"$' "$SUT"
  grep -qE '^CONTAINER_PROJECT="\$\{PROJECT\}-fleet"$' "$SUT"
}

@test "les TROIS scripts de banc derivent le prefixe du MEME endroit — le projet" {
  # Une derivation differente d'un script a l'autre pointerait sur d'autres volumes : un `down`
  # effacerait le magasin d'un voisin, un `swap` en fabriquerait un second sous le nez du premier.
  local d="$BATS_TEST_DIRNAME/../../docker/bench"
  local f
  for f in bench-up.sh bench-down.sh bench-swap-image.sh; do
    grep -qE '^export LCARS_STORE_PREFIX="\$CONTAINER_PROJECT"$' "$d/$f" \
      || { echo "$f ne derive pas le prefixe de \$CONTAINER_PROJECT" >&2; false; }
    grep -qE '^CONTAINER_PROJECT="\$\{PROJECT\}-fleet"$' "$d/$f" \
      || { echo "$f ne derive pas CONTAINER_PROJECT de la base \$PROJECT" >&2; false; }
  done
}
