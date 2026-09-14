#!/usr/bin/env bats
# bats file_tags=unit
# SOURCE: deploy/tests/lib/kit_verify.bats
# AUTHOR: bob
# STARDATE: 2026-09-08
# STATUS: bats tests for kit-verify.sh — le kit porte-t-il ce que les listes declarent ?
#

setup() {
  LIB="$BATS_TEST_DIRNAME/../../lib/kit-verify.sh"
  [ -f "$LIB" ]
  # la lib se joue en sous-shell après provision-lib, dans l'ordre où pack.sh les source
  LIBS=". '$BATS_TEST_DIRNAME/../../lib/provision-lib.sh'; . '$LIB'"
  local D="$BATS_TEST_DIRNAME/../.."
  STAMP="$(sed -n 's/^PROV_SOURCE_STAMP=//p' "$D/installer-constants.env")"
  [ -n "$STAMP" ]
  K="$BATS_TEST_TMPDIR/kit"
  mkdir -p "$K/deploy" "$K/runtime/etc" "$K/runtime/bin" "$K/runtime/services" \
           "$K/runtime/_build/prod/rel/lcars_fleet/bin" "$K/assets/github.io/dist" \
           "$K/assets/avatars" "$K/assets/favicon"
  cp "$D/system.manifest" "$D/installer-constants.env" "$K/deploy/"
  cp "$D/../runtime/etc/release.manifest" "$K/runtime/etc/release.manifest"
  cp "$D/../runtime/etc/fleet.env.template" "$K/runtime/etc/fleet.env.template"
  echo deadbeef > "$K/$STAMP"
  printf '#!/bin/sh\n' > "$K/runtime/_build/prod/rel/lcars_fleet/bin/lcars_fleet"
  chmod +x "$K/runtime/_build/prod/rel/lcars_fleet/bin/lcars_fleet"
  printf '<html></html>' > "$K/assets/github.io/dist/index.html"
  local n
  while read -r n; do [[ -n "$n" ]] && : > "$K/runtime/bin/$n"; done \
    < <(awk 'NF && $1 !~ /^#/ { print $1 }' "$K/runtime/etc/release.manifest")
  for n in $(constante PROV_HELPERS) $(constante PROV_HELPERS_DATA); do : > "$K/runtime/services/$n"; done
  : > "$K/runtime/bin/lcars-toolchain-converge"; : > "$K/runtime/bin/lcars-authority-ask"
  : > "$K/runtime/services/lcars.bashrc"
}

constante() { sed -n "s/^$1=//p" "$BATS_TEST_DIRNAME/../../installer-constants.env"; }

REL_KIT=runtime/_build/prod/rel/lcars_fleet/bin/lcars_fleet
verifie() { run bash -c "$LIBS; kit_verifie '$K' '$REL_KIT'"; }

@test "KIT COMPLET : il passe — sinon tous les temoins suivants ne mesurent rien" {
  verifie
  [ "$status" -eq 0 ] || { echo "un kit COMPLET est refuse :"; echo "$output"; return 1; }
}

@test "KIT : sans son tampon de révision, il est refusé en le nommant — l'install se croirait source" {
  rm -f "$K/$STAMP"
  verifie
  [ "$status" -ne 0 ]
  [[ "$output" == *"$STAMP absent"* ]]
}

@test "KIT : le nom du tampon se lit dans les constantes du kit — un kit qui en déclare un autre est refusé sur celui-là" {
  sed "s/^PROV_SOURCE_STAMP=.*/PROV_SOURCE_STAMP=.tampon-du-kit/" "$BATS_TEST_DIRNAME/../../installer-constants.env" > "$K/deploy/installer-constants.env"
  verifie
  [ "$status" -ne 0 ]
  [[ "$output" == *".tampon-du-kit absent"* ]]
}

@test "KIT : sans le fichier des constantes, ce n'est pas un kit, et le refus le nomme" {
  rm -f "$K/deploy/installer-constants.env"
  verifie
  [ "$status" -ne 0 ]
  [[ "$output" == *"le kit n'a pas deploy/installer-constants.env — ce n'est pas un kit"* ]]
}

@test "KIT : des constantes sans PROV_SOURCE_STAMP sont un refus nommé, jamais une vérification vide" {
  grep -v '^PROV_SOURCE_STAMP=' "$BATS_TEST_DIRNAME/../../installer-constants.env" > "$K/deploy/installer-constants.env"
  verifie
  [ "$status" -ne 0 ]
  [[ "$output" == *"ne déclare pas PROV_SOURCE_STAMP"* ]]
}

@test "KIT : sans la release batie, il est REFUSE — git archive ne l'emporte pas" {
  rm -rf "$K/runtime/_build"
  verifie
  [ "$status" -ne 0 ] || { echo "un kit sans release est accepte"; return 1; }
  [[ "$output" == *"release"* ]] || { echo "le manque n'est pas nomme : $output"; return 1; }
}

@test "KIT : sans la doc batie, il est REFUSE — une demi-livraison n'est pas une livraison" {
  rm -f "$K/assets/github.io/dist/index.html"
  verifie
  [ "$status" -ne 0 ] || { echo "un kit sans doc est accepte"; return 1; }
  [[ "$output" == *"doc"* ]] || { echo "le manque n'est pas nomme : $output"; return 1; }
}

@test "KIT : un bin que release.manifest NOMME et qui manque est vu, et NOMME" {
  local premier; premier="$(awk 'NF && $1 !~ /^#/ { print $1; exit }' "$K/runtime/etc/release.manifest")"
  [ -n "$premier" ]
  rm -f "$K/runtime/bin/$premier"
  verifie
  [ "$status" -ne 0 ] || { echo "un bin declare et absent est accepte"; return 1; }
  [[ "$output" == *"$premier"* ]] || { echo "le fichier manquant n'est pas nomme : $output"; return 1; }
}

@test "KIT : un auxiliaire que 62-runtime-helpers EMBARQUE et qui manque est vu, et NOMME" {
  local premier
  premier="$(constante PROV_HELPERS | cut -d' ' -f1)"
  [ -n "$premier" ]
  rm -f "$K/runtime/services/$premier"
  verifie
  [ "$status" -ne 0 ] || { echo "un auxiliaire declare et absent est accepte"; return 1; }
  [[ "$output" == *"$premier"* ]] || { echo "l'auxiliaire manquant n'est pas nomme : $output"; return 1; }
}

@test "KIT : une donnée que 62-runtime-helpers embarque et qui manque est vue, et nommée" {
  rm -f "$K/runtime/services/lcars.bashrc"
  verifie
  [ "$status" -ne 0 ] || { echo "une donnée sans source est acceptee"; return 1; }
  [[ "$output" == *"PROV_SHELL_RC nomme lcars.bashrc, absent du kit"* ]] || { echo "la donnée n'est pas nommée : $output"; return 1; }
}

@test "KIT : un binaire que 62 pose hors de ses listes et qui manque est vu" {
  rm -f "$K/runtime/bin/lcars-authority-ask"
  verifie
  [ "$status" -ne 0 ]
  [[ "$output" == *"lcars-authority-ask"* ]]
}

@test "KIT : des constantes sans la liste des auxiliaires sont un refus nommé, pas un kit accepté" {
  grep -v '^PROV_HELPERS=' "$BATS_TEST_DIRNAME/../../installer-constants.env" > "$K/deploy/installer-constants.env"
  verifie
  [ "$status" -ne 0 ]
  [[ "$output" == *"ne déclare pas PROV_HELPERS — ce que 62-runtime-helpers en pose n'est pas vérifié"* ]]
}

@test "KIT : une liste se lit comme une donnée — une substitution écrite dedans n'est pas exécutée, elle est un nom absent" {
  { grep -v '^PROV_HELPERS_DATA=' "$BATS_TEST_DIRNAME/../../installer-constants.env"
    printf 'PROV_HELPERS_DATA=$(touch %s/effet)\n' "$BATS_TEST_TMPDIR"; } > "$K/deploy/installer-constants.env"
  verifie
  [ "$status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/effet" ]
  [[ "$output" == *"PROV_HELPERS_DATA nomme "* ]]
}

@test "KIT : un arbre de 44-media absent est vu — il ne se batit nulle part" {
  rm -rf "$K/assets/avatars"
  verifie
  [ "$status" -ne 0 ] || { echo "un arbre de medias absent est accepte"; return 1; }
  [[ "$output" == *"avatars"* ]] || { echo "l'arbre n'est pas nomme : $output"; return 1; }
}

@test "KIT : sans table, le refus dit « ce n'est pas un kit » et s'ARRETE la" {
  rm -f "$K/deploy/system.manifest"
  verifie
  [ "$status" -ne 0 ]
  [[ "$output" == *"pas un kit"* ]] || { echo "le refus ne dit pas la cause : $output"; return 1; }
  [[ "$output" != *"avatars"* ]] || { echo "le refus enumere des consequences au lieu de la cause : $output"; return 1; }
}

@test "KIT : le refus DIT que le tar n'a pas ete scelle, et ou chercher" {
  rm -f "$K/$STAMP"
  verifie
  [[ "$output" == *"tar"* ]] || { echo "le refus ne dit pas ce qui n'a pas eu lieu : $output"; return 1; }
  [[ "$output" == *"listes"* ]] || { echo "le refus ne dit pas ou chercher : $output"; return 1; }
}
