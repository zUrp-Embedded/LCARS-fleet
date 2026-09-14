#!/usr/bin/env bats
# bats file_tags=structure
# SOURCE: deploy/tests/racine_jetons.bats
# AUTHOR: alice
# STARDATE: 2026-08-28
# STATUS: mur d'accord — les défauts de la racine des jetons que le convergeur, le geste de forge et l'exécuteur de catalogue gardent s'accordent avec la constante de l'installeur

# shellcheck disable=SC2016

load refute

setup() {
  R="$BATS_TEST_DIRNAME/../.."          # la RACINE du depot — `deploy/` et `runtime/` y sont FRERES
  LIB="$R/deploy/lib/provision-lib.sh"
  [ -f "$LIB" ]
  ATTENDU="$(env -i PATH="$PATH" bash -c ". '$LIB' >/dev/null 2>&1; printf '%s' \"\$PROV_TOKENS_DIR\"")"
}

racine_de() { # racine_de <fichier> <motif ERE capturant le chemin>
  grep -ohE "$2" "$1" 2>/dev/null | head -1 \
    | grep -oE '/[A-Za-z0-9_./-]+' | head -1 \
    | sed -E 's#/(forge-uid\.map|forge-master\.token|[^/]*\.gitea_token)$##' \
    | sed -E 's#/$##'
}

@test "GARDE D'INSTRUMENT : la constante rend une racine absolue" {
  # une extraction cassée rendrait vide, et les cas suivants compareraient du vide à du vide
  [ -n "$ATTENDU" ]
  [[ "$ATTENDU" == /* ]]
}

# le protocole des modules du produit et le RoleToken du BEAM : tenus par le contrat
# SingleSource.check_private_dir_single_source (runtime/lib/mix/tasks/lcars/contracts/check/single_source.ex)
@test "BASH : les défauts du convergeur et du geste de forge disent ce que la constante déclare" {
  local bad=0
  declare -A sites=(
    ["$R/runtime/services/human-converger.sh|FORGE_TOKEN_FILE"]='FORGE_TOKEN_FILE:-[^}]*'
    ["$R/runtime/services/human-converger.sh|LCARS_UID_MAP_FILE"]='LCARS_UID_MAP_FILE:-[^}]*'
    ["$R/runtime/services/forge-gestures.sh|LCARS_PRIVATE_DIR"]='LCARS_PRIVATE_DIR:-[^}]*'
  )
  local cle f vu
  for cle in "${!sites[@]}"; do
    f="${cle%%|*}"
    vu="$(racine_de "$f" "${sites[$cle]}")"
    [ "$vu" = "$ATTENDU" ] || { echo "${cle##*|} dans $(basename "$f") : « $vu » ≠ « $ATTENDU »"; bad=1; }
  done
  [ "$bad" -eq 0 ]
}

@test "PYTHON : les deux défauts de l'exécuteur de catalogue s'accordent" {
  # ce service détient l'autorité de la forge : un repli qui pointe ailleurs refuse chaque geste sur un fichier absent
  local f="$R/runtime/services/catalogue-executor.py" vu
  vu="$(racine_de "$f" 'FORGE_ROLE_TOKENS_DIR", "[^"]*')"
  [ "$vu" = "$ATTENDU" ]
  vu="$(racine_de "$f" 'LCARS_MASTER_TOKEN_FILE", "[^"]*')"
  [ "$vu" = "$ATTENDU" ]
}
