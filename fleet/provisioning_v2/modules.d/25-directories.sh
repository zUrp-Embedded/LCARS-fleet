#!/usr/bin/env bash
# SOURCE: fleet/provisioning_v2/modules.d/25-directories.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — arborescence système : /local (préfixes d'install) + /home/private (secrets)
# SUBSTRATE: any
# NEEDS: root
#
# DEUX dossiers. C'est tout. (La v1 en posait une dizaine — commons, handoffs, fleet-state,
# spool, projects, tmp — pour l'IPC de sa fleet bash ; le runtime v2 n'a besoin d'AUCUN d'eux :
# son état vit sous ~/.lcars per-humain, posé par `fleet_v2 start` lui-même.)
#
#   /local          0755 root:root — les préfixes d'install y sont créés par 60-deploy ;
#                   root-only en écriture = personne ne remplace un runtime déployé par surprise.
#   /home/private   0750 root:fleet — les role-tokens forge (contrat FORGE_ROLE_TOKENS_DIR,
#                   fichiers 0640 posés par etc/provision-role-tokens.sh). Lecture : groupe fleet
#                   (le BEAM per-humain lit via le groupe) ; traversée interdite au reste.
#
# CHAQUE dossier est posé création+mode+owner en un geste convergent (la v1 séparait mkdir des
# perms → un crash entre les deux laissait des dossiers ownés root par défaut, silencieusement).

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

check() {
  local spec path mode owner
  # La table est LA donnée ; le code ne fait que la dérouler (une entrée = "chemin mode owner:groupe").
  for spec in "/local 0755 root:root" "$PROV_TOKENS_DIR 0750 root:$PROV_FLEET_GROUP"; do
    read -r path mode owner <<< "$spec"
    if [[ ! -d "$path" ]]; then
      p_drift "$path absent"
      continue
    fi
    local cur
    cur="$(stat -c '%a %U:%G' "$path")"
    if [[ "$cur" == "${mode#0} $owner" ]]; then
      p_ok "$path ($cur)"
    else
      p_drift "$path : $cur ≠ ${mode#0} $owner"
    fi
  done
  verdict_check
}

apply() {
  ensure_dir /local 0755 root:root || verdict_apply
  ensure_dir "$PROV_TOKENS_DIR" 0750 "root:$PROV_FLEET_GROUP" || verdict_apply
  verdict_apply
}

case "${1:?usage: 25-directories.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
