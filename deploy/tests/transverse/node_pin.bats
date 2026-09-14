#!/usr/bin/env bats
# bats file_tags=structure
# SOURCE: deploy/tests/transverse/node_pin.bats
# AUTHOR: alice
# STARDATE: 2026-08-28
# STATUS: mur d'accord — la doc du deck est bâtie par le node épinglé du poste (16-node) et par le workflow du site, à la même majeure

setup() {
  CONSTANTES="$BATS_TEST_DIRNAME/../../installer-constants.env"
  SITE_WF="$BATS_TEST_DIRNAME/../../../.github/workflows/site.yml"
  [ -f "$CONSTANTES" ]
  [ -f "$SITE_WF" ]
}

@test "le poste et le site en ligne bâtissent la doc avec la même majeure de node" {
  local m w
  # une extraction ratée rendrait une chaîne vide, et deux vides sont égaux
  m="$(sed -n 's/^PROV_NODE_PIN=\([0-9]\+\)\..*/\1/p' "$CONSTANTES")"
  w="$(sed -n 's/^ *node-version: *\([0-9]\+\) *$/\1/p' "$SITE_WF")"
  [ -n "$m" ] || { echo "extraction ratée : PROV_NODE_PIN dans $CONSTANTES"; return 1; }
  [ -n "$w" ] || { echo "extraction ratée : node-version dans $SITE_WF"; return 1; }
  [ "$m" = "$w" ] || { echo "majeure node : poste $m, workflow du site $w — la doc en ligne ne serait pas celle du deck"; return 1; }
}
