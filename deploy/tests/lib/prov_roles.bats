#!/usr/bin/env bats
# bats file_tags=unit
# SOURCE: deploy/tests/lib/prov_roles.bats
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: bats tests for prov_roles (provision-lib) — le roster du mint suit les catalogues INSTALLES
#
# Ces trois temoins vivaient dans le fichier du module 50-catalogues, dont ils partageaient le decor.
# Le module est devenu un geste du PRODUIT (runtime/services/forge.d/catalogues.sh, lot 6) ; la
# fonction `prov_roles`, elle, est de la lib de l'INSTALLEUR — elle lit la release posee par la
# porte outil, pour le mint de 63. Deux sujets, deux corpus.

load ../refute

setup() {
  LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export PROV_CATALOGUES_DIR="$BATS_TEST_TMPDIR/catalogues"
  mkdir -p "$PROV_CATALOGUES_DIR" "$BATS_TEST_TMPDIR/bin"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

seed_local() {
  mkdir -p "$PROV_CATALOGUES_DIR/$1/.git"
  printf 'api_version: 1\nname: %s\n' "$1" > "$PROV_CATALOGUES_DIR/$1/catalogue.yaml"
}

@test "prov_roles sans release : le plancher tenu a la main, et rien de plus" {
  # Chemin WSL avant `60-deploy`, ou conteneur sans release pose. Un conteneur doit pouvoir minter de quoi
  # demarrer meme quand la derivation est impossible.
  run bash -c "set -euo pipefail; export PROVISION_LIB='$LIB' PROV_CATALOGUES_DIR='$PROV_CATALOGUES_DIR' PROV_LCARS_CLI=/inexistant; source '$LIB'; prov_roles"
  [ "$status" -eq 0 ]
  [[ "$output" == *"system_architect"* ]]
  [[ "$output" == *"fleet_engineer"* ]]
}

@test "prov_roles avec un catalogue installe : ses roles ENTRENT, dedupliques et tries" {
  # LA QUATRIEME LISTE TENUE A LA MAIN MEURT ICI. Un catalogue installe apporte ses comptes sans
  # qu'aucun fichier de deploiement ne le sache — c'est tout l'interet de la derivation.
  seed_local "web"
  cat > "$BATS_TEST_TMPDIR/bin/entrypoint" <<'SH'
#!/usr/bin/env bash
# ⚠ LA PORTE EST `roles-tfvars`, PAS `roles`. La premiere rend des COMPTES (`web_dev`), la seconde
# des noms de ROLE (`dev`) — et `PROV_ROLES` est une liste de comptes. La doublure REFUSE `roles`
# pour que le temoin tombe si la derivation y revenait : mesure sur banc du 2026-08-16, branchee sur
# `roles`, elle faisait entrer `dev` et `writer` dans le roster a minter.
[[ "$1" == tool ]] && shift   # la porte est « lcars tool roles-tfvars » (lot 6)
[[ "$1" == "roles-tfvars" ]] || exit 1
printf '{"roles":["web_dev","web_writer","fleet_engineer"],"system_roles":["system_architect"]}\n'
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/entrypoint"
  : > "$BATS_TEST_TMPDIR/bin/release"; chmod +x "$BATS_TEST_TMPDIR/bin/release"

  run bash -c "set -euo pipefail; export PROVISION_LIB='$LIB' PROV_CATALOGUES_DIR='$PROV_CATALOGUES_DIR' PROV_LCARS_CLI='$BATS_TEST_TMPDIR/bin/entrypoint' PROV_RELEASE_BIN='$BATS_TEST_TMPDIR/bin/release'; source '$LIB'; prov_roles"
  [ "$status" -eq 0 ]
  [[ "$output" == *"web_dev"* ]]
  [[ "$output" == *"web_writer"* ]]
  # `fleet_engineer` est dans le plancher ET dans la sortie du catalogue : il ne sort qu'une fois.
  [ "$(printf '%s\n' $output | grep -c '^fleet_engineer$')" -eq 1 ]
}

@test "prov_roles : un catalogue dont la porte REFUSE n'ajoute rien, et ne casse pas le mint" {
  # Un catalogue incoherent est un catalogue que le boot refusera. Ce n'est pas au mint de trancher,
  # et faire echouer la derivation entiere priverait de jetons les catalogues sains.
  seed_local "casse"
  printf '#!/usr/bin/env bash\nexit 3\n' > "$BATS_TEST_TMPDIR/bin/entrypoint"
  chmod +x "$BATS_TEST_TMPDIR/bin/entrypoint"
  : > "$BATS_TEST_TMPDIR/bin/release"; chmod +x "$BATS_TEST_TMPDIR/bin/release"

  run bash -c "set -euo pipefail; export PROVISION_LIB='$LIB' PROV_CATALOGUES_DIR='$PROV_CATALOGUES_DIR' PROV_LCARS_CLI='$BATS_TEST_TMPDIR/bin/entrypoint' PROV_RELEASE_BIN='$BATS_TEST_TMPDIR/bin/release'; source '$LIB'; prov_roles"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fleet_engineer"* ]]
}

# ─── FORGE INCONNUE : LE VERBE DEPEND DE CE QUE LA MACHINE PORTE — ET IL DISAIT TOUJOURS WARN ───
#
# ⚠ AUCUN TEMOIN NE COUVRAIT CETTE BRANCHE : le setup exporte `PROV_FORGE_URL` dans TOUS les tests.
# La cause du trou est une inversion de rang non declarable — l adresse se derive de
# `$PROV_TOKENS_DIR/forge.url`, dont le seul poseur est `48-forge-host`, TROIS RANGS PLUS LOIN, et
# `provision:327` refuse un `AFTER` qui ne precede pas.
#
# Le module rendait `p_warn` dans les deux cas. Or `p_warn` n incremente ni PROV_DRIFT ni
# PROV_FAILED : sur une re-provision dont les jetons ont disparu alors que le volume de la forge a
# survecu, la passe etait INERTE et le bilan restait vert.
