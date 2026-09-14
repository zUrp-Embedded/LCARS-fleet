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
  # la lib se joue en sous-shell, seule : pack.sh la source sans que rien ne garantisse provision-lib avant elle
  LIBS=". '$LIB'"
  local D="$BATS_TEST_DIRNAME/../.."
  STAMP="$(sed -n 's/^PROV_SOURCE_STAMP=//p' "$D/installer-constants.env")"
  [ -n "$STAMP" ]
  K="$BATS_TEST_TMPDIR/kit"
  mkdir -p "$K/deploy/modules.d" "$K/runtime/etc" "$K/runtime/bin" "$K/runtime/services" \
           "$K/runtime/_build/prod/rel/lcars_fleet/bin" "$K/assets/github.io/dist" \
           "$K/assets/avatars" "$K/assets/favicon"
  cp "$D/system.manifest" "$D/installer-constants.env" "$K/deploy/"
  cp "$D/modules.d/62-runtime-helpers.sh" "$K/deploy/modules.d/"
  cp "$D/../runtime/etc/release.manifest" "$K/runtime/etc/release.manifest"
  cp "$D/../runtime/etc/fleet.env.template" "$K/runtime/etc/fleet.env.template"
  echo deadbeef > "$K/$STAMP"
  printf '#!/bin/sh\n' > "$K/runtime/_build/prod/rel/lcars_fleet/bin/lcars_fleet"
  chmod +x "$K/runtime/_build/prod/rel/lcars_fleet/bin/lcars_fleet"
  printf '<html></html>' > "$K/assets/github.io/dist/index.html"
  local n
  while read -r n; do [[ -n "$n" ]] && : > "$K/runtime/bin/$n"; done \
    < <(awk 'NF && $1 !~ /^#/ { print $1 }' "$K/runtime/etc/release.manifest")
  while read -r n; do [[ -n "$n" ]] && : > "$K/runtime/services/$n"; done \
    < <(bash -c "$LIBS; kv_tableau '$K/deploy/modules.d/62-runtime-helpers.sh' HELPERS" || true)
  while read -r n _; do [[ -n "$n" ]] && : > "$K/runtime/services/$n"; done \
    < <(bash -c "$LIBS; kv_tableau '$K/deploy/modules.d/62-runtime-helpers.sh' DATA" || true)
  : > "$K/runtime/bin/lcars-toolchain-converge"; : > "$K/runtime/bin/lcars-authority-ask"
  : > "$K/runtime/services/lcars.bashrc"
}

REL_KIT=runtime/_build/prod/rel/lcars_fleet/bin/lcars_fleet
verifie() { run bash -c "$LIBS; kit_verifie '$K' '$REL_KIT'"; }

@test "LCARS header: SOURCE/AUTHOR/STARDATE/STATUS present" {
  head -6 "$LIB" | grep -q '^# SOURCE:'
  head -6 "$LIB" | grep -q '^# AUTHOR:'
  head -6 "$LIB" | grep -q '^# STARDATE:'
  head -6 "$LIB" | grep -q '^# STATUS:'
}

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
  premier="$(bash -c "$LIBS; kv_tableau '$K/deploy/modules.d/62-runtime-helpers.sh' HELPERS" | head -1)"
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
  [[ "$output" == *"la donnée lcars.bashrc"* ]] || { echo "la donnée n'est pas nommée : $output"; return 1; }
}

@test "KIT : un binaire que 62 pose hors de ses listes et qui manque est vu" {
  rm -f "$K/runtime/bin/lcars-authority-ask"
  verifie
  [ "$status" -ne 0 ]
  [[ "$output" == *"lcars-authority-ask"* ]]
}

@test "KIT : une liste de 62 renommée ne se lit plus, et c'est un refus nommé, pas un kit accepté" {
  sed -i 's/^HELPERS=(/AUXILIAIRES=(/' "$K/deploy/modules.d/62-runtime-helpers.sh"
  verifie
  [ "$status" -ne 0 ]
  [[ "$output" == *"la liste HELPERS ne se lit pas"* ]]
}

@test "KIT : une liste de 62 qui cite une variable que personne ne pose est un refus nommé" {
  sed -i 's/^DATA=(/DATA=(\n  "$VARIABLE_JAMAIS_POSEE"/' "$K/deploy/modules.d/62-runtime-helpers.sh"
  verifie
  [ "$status" -ne 0 ]
  [[ "$output" == *"la liste DATA ne se lit pas"* ]]
}

@test "kv_tableau : une liste sur une ligne se lit seule, le code qui la suit n'est pas exécuté" {
  printf 'HELPERS=(a b)\necho EFFET-DE-BORD\nDATA=(\n  "c d"\n)\n' > "$BATS_TEST_TMPDIR/mod.sh"
  run bash -c "$LIBS; kv_tableau '$BATS_TEST_TMPDIR/mod.sh' HELPERS"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'a\nb')" ]
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
