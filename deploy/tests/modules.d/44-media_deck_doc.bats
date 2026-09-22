#!/usr/bin/env bats
# bats file_tags=structure
# SOURCE: deploy/tests/modules.d/44-media_deck_doc.bats
# AUTHOR: DrDree
# STARDATE: 2026-09-12
# STATUS: la doc du deck — posée là où le deck la lit, hors du préfixe de release que son compte de service ne peut pas traverser

setup() {
  MOD="$BATS_TEST_DIRNAME/../../modules.d/44-media.sh"
  LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  DECK="$BATS_TEST_DIRNAME/../../../runtime/services/console-deck.py"
  [ -f "$MOD" ]
  [ -f "$LIB" ]
  [ -f "$DECK" ]
  # là où 44-media pose la doc, avec les constantes de la lib : ses deux lignes de définition, jouées
  DOC_DEST="$(env -u LCARS_DECOR_ROOT bash -c 'export PROVISION_MODULE=t; source "$1"; eval "$(grep -E "^(MEDIA_ROOT=|DOC_DIR=)" "$2")"; printf "%s" "$DOC_DIR"' _ "$LIB" "$MOD")"
  # le défaut du serveur, celui qui vaut quand personne ne pose la variable
  DECK_DEFAULT="$(grep -oE 'LCARS_DECK_DOC", "[^"]+' "$DECK" | sed 's/.*, "//')"
}

@test "44-media pose la doc là où le deck la lit par défaut, et hors du préfixe de release" {
  [ -n "$DOC_DEST" ]
  [ -n "$DECK_DEFAULT" ]
  [ "$DOC_DEST" = "$DECK_DEFAULT" ]
  local prefixe; prefixe="$(sed -n 's/^PROV_PREFIX=//p' "$BATS_TEST_DIRNAME/../../installer-constants.env")"
  [ -n "$prefixe" ]
  [[ "$DOC_DEST" != "$prefixe"* ]]
}

@test "la source porte les deux formats d'avatar — le png n'est pas dérivé du svg" {
  # Gitea décode png/jpeg/gif et pas le svg, et aucun rastériseur n'existe dans le runtime
  local src="$BATS_TEST_DIRNAME/../../../assets/avatars"
  [ -d "$src" ]
  local r
  for r in architect starfleet vulcan; do
    [ -f "$src/$r.svg" ]
    [ -f "$src/$r.png" ]
  done
}

@test "la route /doc/ refuse de sortir de sa racine — le préfixe voisin porte les jetons du conteneur" {
  grep -q 'os.path.realpath(os.path.join(DECK_DOC, rel))' "$DECK"
  grep -q 'full == root or full.startswith(root + os.sep)' "$DECK"
}
