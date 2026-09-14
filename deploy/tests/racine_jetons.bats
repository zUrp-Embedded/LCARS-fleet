#!/usr/bin/env bats
# bats file_tags=structure
# SOURCE: deploy/tests/racine_jetons.bats
# AUTHOR: alice
# STARDATE: 2026-08-28
# STATUS: bats tests — les defauts de la racine des jetons du runtime s'accordent avec la constante de l'installeur, dans trois langages

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

@test "GARDE D'INSTRUMENT : la SSoT rend une racine absolue" {
  # Sans ce garde, une extraction cassee rendrait vide et TOUS les temoins ci-dessous compareraient
  # du vide a du vide — verts sur rien, la forme d'echec la plus chere.
  [ -n "$ATTENDU" ]
  [[ "$ATTENDU" == /* ]]
}

@test "BASH : les defauts du rail et du produit disent ce que la lib declare" {
  local bad=0
  declare -A sites=(
    ["$R/runtime/services/lib/module-protocol.sh|LCARS_PRIVATE_DIR"]='LCARS_PRIVATE_DIR:=[^}]*'
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

@test "PYTHON : les deux defauts de l'executeur de catalogue s'accordent" {
  # Ce service DETIENT l'autorite de la forge. Un repli qui pointe ailleurs, et il demarre en
  # refusant chaque geste sur un fichier absent.
  local f="$R/runtime/services/catalogue-executor.py" vu
  vu="$(racine_de "$f" 'FORGE_ROLE_TOKENS_DIR", "[^"]*')"
  [ "$vu" = "$ATTENDU" ]
  vu="$(racine_de "$f" 'LCARS_MASTER_TOKEN_FILE", "[^"]*')"
  [ "$vu" = "$ATTENDU" ]
}

@test "ELIXIR : le defaut de \`RoleToken\` s'accorde avec le rail" {
  # Le runtime lit ces jetons par `Fleet.Credentials.RoleToken`. Son `@default_dir` est le huitieme
  # decideur, et le seul que ni bash ni python ne verraient diverger.
  local vu; vu="$(racine_de "$R/runtime/lib/fleet/credentials/role_token.ex" '@default_dir "[^"]*')"
  [ "$vu" = "$ATTENDU" ]
}
