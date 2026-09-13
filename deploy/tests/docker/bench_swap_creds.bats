#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/docker/bench_swap_creds.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-18
# STATUS: bats tests for bench-swap-image.sh — la sonde des credentials ne fait pas descendre le secret

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
