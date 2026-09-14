#!/usr/bin/env bats
# bats file_tags=structure
# SOURCE: deploy/tests/modules.d/fleet_membership.bats
# AUTHOR: bob
# STARDATE: 2026-09-15
# STATUS: témoin de structure — aucun module de l'installeur ne juge qui, parmi les humains de la machine, est de fleet
#
# Le convergeur d'humains est seul juge de l'appartenance d'un humain à fleet : il crée, ajoute et
# révoque d'après la team de la forge. Un module qui ajouterait à fleet les comptes de la plage
# d'uid, sans lire la forge, y mettrait un compte que le convergeur révoque au tour suivant (shell
# nologin, processus tués). Les appartenances nommées restent aux modules qui les posent : l'humain
# de la passe (20-groups) et le compte d'autorité (21-service-accounts).

load ../support/decor

setup() {
  MODULES="$BATS_TEST_DIRNAME/../../modules.d"
  [ -d "$MODULES" ]
  # ce témoin ne joue aucun lecteur du siège ni des bornes, il les nomme : le décor tient le mur I19
  decor_pose
}

code_of() { sed 's/#.*//' "$1"; }

@test "aucun module ne lit la population des humains et n'écrit une appartenance de groupe" {
  local m bad=0 lecteurs=0
  for m in "$MODULES"/[0-9][0-9]-*.sh; do
    code_of "$m" | grep -qE 'fleet_humans|prov_uid_bounds' || continue
    lecteurs=$((lecteurs + 1))
    if code_of "$m" | grep -qE 'ensure_member|usermod|gpasswd|adduser'; then
      echo "${m##*/} lit la population des humains et écrit une appartenance de groupe : le convergeur est seul juge de fleet" >&2
      bad=1
    fi
  done
  # garde d'instrument : 64-services lit encore la population ; sans lecteur, le mur ne mesure rien
  [ "$lecteurs" -gt 0 ] || { echo "aucun module ne lit fleet_humans ni prov_uid_bounds : le mur ne lit plus le corpus" >&2; return 1; }
  [ "$bad" -eq 0 ]
}

@test "garde d'instrument : l'écriture d'une appartenance se reconnaît dans le corpus des modules" {
  local n
  n="$(cat "$MODULES"/[0-9][0-9]-*.sh | sed 's/#.*//' | grep -cE 'ensure_member' || true)"
  [ "$n" -gt 0 ]
}
