#!/usr/bin/env bats
# SOURCE: deploy/tests/lib/kit_verify.bats
# AUTHOR: bob
# STARDATE: 2026-09-08
# STATUS: bats tests for kit-verify.sh — le kit porte-t-il ce que les listes declarent ?
#

setup() {
  LIB="$BATS_TEST_DIRNAME/../../lib/kit-verify.sh"
  [ -f "$LIB" ]
  K="$BATS_TEST_TMPDIR/kit"
  local D="$BATS_TEST_DIRNAME/../.."
  mkdir -p "$K/deploy/modules.d" "$K/runtime/etc" "$K/runtime/bin" "$K/runtime/services" \
           "$K/runtime/_build/prod/rel/lcars_fleet/bin" "$K/assets/github.io/dist" \
           "$K/assets/avatars" "$K/assets/favicon"
  cp "$D/system.manifest" "$K/deploy/system.manifest"
  cp "$D/modules.d/62-runtime-helpers.sh" "$K/deploy/modules.d/"
  cp "$D/../runtime/etc/release.manifest" "$K/runtime/etc/release.manifest"
  cp "$D/../runtime/etc/fleet.env.template" "$K/runtime/etc/fleet.env.template"
  echo deadbeef > "$K/.source-revision"
  printf '#!/bin/sh\n' > "$K/runtime/_build/prod/rel/lcars_fleet/bin/lcars_fleet"
  chmod +x "$K/runtime/_build/prod/rel/lcars_fleet/bin/lcars_fleet"
  printf '<html></html>' > "$K/assets/github.io/dist/index.html"
  local n
  while read -r n; do [[ -n "$n" ]] && : > "$K/runtime/bin/$n"; done \
    < <(awk 'NF && $1 !~ /^#/ { print $1 }' "$K/runtime/etc/release.manifest")
  # la lib se joue en sous-shell : un « . "$LIB" » à chemin calculé serait un SC1090 que le plancher du gate refuse
  while read -r n; do [[ -n "$n" ]] && : > "$K/runtime/services/$n"; done \
    < <(bash -c ". '$LIB'; kv_tableau '$K/deploy/modules.d/62-runtime-helpers.sh' HELPERS" || true)
  while read -r n _; do [[ -n "$n" ]] && : > "$K/runtime/services/$n"; done \
    < <(bash -c ". '$LIB'; kv_tableau '$K/deploy/modules.d/62-runtime-helpers.sh' DATA" || true)
  : > "$K/runtime/bin/lcars-toolchain-converge"; : > "$K/runtime/bin/lcars-authority-ask"
  : > "$K/runtime/services/lcars.bashrc"
}

REL_KIT=runtime/_build/prod/rel/lcars_fleet/bin/lcars_fleet
verifie() { run bash -c ". '$LIB'; kit_verifie '$K' '$REL_KIT'"; }

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

@test "KIT : sans .source-revision, il est REFUSE — l'install se croirait SOURCE" {
  rm -f "$K/.source-revision"
  verifie
  [ "$status" -ne 0 ] || { echo "un kit sans .source-revision est accepte"; return 1; }
  [[ "$output" == *"source-revision"* ]] || { echo "le manque n'est pas nomme : $output"; return 1; }
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
  [ -n "$premier" ] || skip "release.manifest est vide"
  rm -f "$K/runtime/bin/$premier"
  verifie
  [ "$status" -ne 0 ] || { echo "un bin declare et absent est accepte"; return 1; }
  [[ "$output" == *"$premier"* ]] || { echo "le fichier manquant n'est pas nomme : $output"; return 1; }
}

@test "KIT : un auxiliaire que 62-runtime-helpers EMBARQUE et qui manque est vu, et NOMME" {
  local premier
  premier="$(bash -c ". '$LIB'; kv_tableau '$K/deploy/modules.d/62-runtime-helpers.sh' HELPERS" | head -1)"
  [ -n "$premier" ] || skip "HELPERS est vide"
  rm -f "$K/runtime/services/$premier"
  verifie
  [ "$status" -ne 0 ] || { echo "un auxiliaire declare et absent est accepte"; return 1; }
  [[ "$output" == *"$premier"* ]] || { echo "l'auxiliaire manquant n'est pas nomme : $output"; return 1; }
}

@test "KIT : une ancre de la table dont la source manque est vue" {
  rm -f "$K/runtime/services/lcars.bashrc"
  verifie
  [ "$status" -ne 0 ] || { echo "une ancre sans source est acceptee"; return 1; }
  [[ "$output" == *"lcars.bashrc"* ]] || { echo "l'ancre n'est pas nommee : $output"; return 1; }
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
  rm -f "$K/.source-revision"
  verifie
  [[ "$output" == *"tar"* ]] || { echo "le refus ne dit pas ce qui n'a pas eu lieu : $output"; return 1; }
  [[ "$output" == *"listes"* ]] || { echo "le refus ne dit pas ou chercher : $output"; return 1; }
}
