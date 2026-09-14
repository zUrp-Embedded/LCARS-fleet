#!/usr/bin/env bash
# SOURCE: deploy/modules.d/22-fleet-human.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-12
# STATUS: les humains de fleet du poste — la forge les sème, le convergeur les crée, ce module atteste leur groupe
# APPLY-ON: wsl linux
# CHECK-ON: wsl linux
# NEEDS: root
# AFTER: 20-groups
#
# Aucun compte nommé n'est attendu ni créé ici : les personnes s'inscrivent sur la forge sous leur
# nom, le convergeur (seul créateur d'humains) les matérialise. Ce qui reste à ce module, et que
# personne d'autre ne mesure : l'appartenance au groupe fleet, sans laquelle un humain ne lit ni
# les jetons ni les zones de face. Zéro humain est l'état nominal d'une machine neuve.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — ce module se joue par ./provision, pas nu}"

observe() {
  local h found=0
  prov_uid_bounds || {
    p_drift "$PROV_UID_BOUNDS_WHY — cette machine ne peut reconnaître aucun humain de fleet"
    return 0
  }
  while read -r h; do
    found=1
    if prov_in_group "$h" "$PROV_FLEET_GROUP"; then
      p_ok "« $h » (uid $(id -u -- "$h")) ∈ $PROV_FLEET_GROUP — il peut lancer la fleet"
    else
      p_drift "« $h » hors du groupe $PROV_FLEET_GROUP — il ne lira ni $PROV_TOKENS_DIR ni les zones de face"
    fi
  done < <(fleet_humans)
  [[ "$found" -eq 1 ]] || p_ok "aucun humain de fleet — chacun s'inscrit sur la forge (team « $PROV_HUMANS_TEAM »), le convergeur le crée ; « journalctl -u lcars-converger » dit pourquoi s'il ne le fait pas"
}

check() { observe; verdict_check; }

# le rattrapage d'un compte fait à la main ou d'un groupe perdu ; observe, qui suit, dit la cause d'une population illisible
apply() {
  local h
  while read -r h; do
    ensure_member "$h" "$PROV_FLEET_GROUP" || true
  done < <(fleet_humans 2>/dev/null)
  observe
  verdict_apply
}

case "${1:-}" in check|apply) "$1" ;; *) p_die "mode inconnu: ${1:-} (check|apply)" ;; esac
