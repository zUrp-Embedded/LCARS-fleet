#!/usr/bin/env bats
# bats file_tags=structure
# SOURCE: deploy/tests/racine_jetons.bats
# AUTHOR: alice
# STARDATE: (posee par /push-github)
# STATUS: bats tests — les HUIT defauts de la racine des jetons s'accordent, dans trois langages
#
# POURQUOI CE FICHIER EXISTE, ET POURQUOI IL EST ECRIT AVANT LE DEPLACEMENT.
#
# La racine des jetons de forge est nommee par HUIT defauts, en bash, en python et en Elixir. Ils
# doivent bouger ENSEMBLE : un seul oublie, et un service ouvre un jeton la ou personne ne l'ecrit —
# sans une ligne pour le dire, parce que chacun a son propre repli et qu'aucun ne compare.
#
# ⚠ LA LECON VIENT DU DEPLACEMENT PRECEDENT. `/usr/share/lcars` avait cinq defauts dans trois
# langages, et un temoin qui epinglait leur ACCORD (`media_tree.bats`) : il a rougi au deplacement,
# ce qui est exactement son metier, et c'est lui qui a rendu ce geste sur. Ici il n'y avait rien.
# Ecrire le mur AVANT de bouger est la seule facon de savoir qu'on n'a rien manque.
#
# ⚠ ET IL N'EPINGLE PAS `/opt/lcars/var/tokens`. Il epingle que les huit disent LA MEME CHOSE que la SSoT.
# Un temoin qui grave la valeur devrait etre reecrit a chaque deplacement — et un mur qu'on reecrit
# a chaque passage ne garde rien, il suit.

# shellcheck disable=SC2016

load refute

setup() {
  R="$BATS_TEST_DIRNAME/../.."          # la RACINE du depot — `deploy/` et `runtime/` y sont FRERES
  LIB="$R/deploy/lib/provision-lib.sh"
  [ -f "$LIB" ]
  # LA SOURCE : ce que la lib RESOUT, et rien d'autre ne decide.
  #
  # ⚠ ON SOURCE, ON N'EXTRAIT PAS LE TEXTE. Premiere version : un `sed` sur `${PROV_TOKENS_DIR:=…}`.
  # Elle a rendu les SIX temoins rouges le jour ou la lib s'est mise a DERIVER (`$PROV_ROOT/var/…`)
  # — l'extraction rendait le texte non developpe. Un instrument qui lit une valeur doit la faire
  # calculer par celui qui la definit, sinon il mesure une syntaxe et pas un chemin.
  # ⚠ `env -i` : on resout le DEFAUT, pas la surcharge de l'appelant. Un `setup()` qui exporte
  # cette variable — plusieurs le font — la rendrait telle quelle, et le mur mesurerait le
  # temoin au lieu de la SSoT. Le motif complet est dans `deploy_manifest.bats`.
  ATTENDU="$(env -i PATH="$PATH" bash -c ". '$LIB' >/dev/null 2>&1; printf '%s' \"\$PROV_TOKENS_DIR\"")"
}

# Rend la racine que porte un defaut, quel que soit le langage.
# ⚠ LE SLASH FINAL SE NORMALISE. `FORGE_TOKEN_FILE` vaut `<racine>/$SYSTEM_ACCOUNT.gitea_token` :
# l'extraction s'arrete au `$` et laisse `<racine>/`. Comparer sans normaliser accuserait un site
# parfaitement d'accord — un mur qui accuse a tort s'apprend a etre ignore aussi vite qu'un mur muet.
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
  # Lot 6 (2026-09-04) : l'entrypoint ne grave plus les deux chemins du conteneur — `container/init.sh`
  # les DERIVE de `PROV_TOKENS_DIR`, dont le defaut vit dans le protocole des modules du produit.
  # C'est ce defaut-la qui est tenu ici, a la place des deux litteraux.
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

@test "BASH : le verbe \`accept\` aussi — il lit les memes jetons" {
  local vu; vu="$(racine_de "$R/deploy/accept" 'LCARS_PRIVATE_DIR:-[^}]*')"
  [ "$vu" = "$ATTENDU" ]
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

@test "LA TABLE declare cette racine, et c'est la meme" {
  grep -qE "^dir[[:space:]]+${ATTENDU}[[:space:]]" "$R/deploy/system.manifest"
}
