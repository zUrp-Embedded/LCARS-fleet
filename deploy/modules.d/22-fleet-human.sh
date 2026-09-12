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
    p_drift "la frontiere systeme/humain n'est pas etablie — cette machine ne peut reconnaitre aucun humain de fleet (le remede est ci-dessus)"
    return 0
  }
  while read -r h; do
    [[ -n "$h" ]] || continue
    found=1
    if prov_in_group "$h" "$PROV_FLEET_GROUP"; then
      p_ok "« $h » (uid $(id -u -- "$h")) ∈ $PROV_FLEET_GROUP — il peut lancer la fleet"
    else
      p_drift "« $h » hors du groupe $PROV_FLEET_GROUP — il ne lira ni $PROV_TOKENS_DIR ni les zones de face"
    fi
  done < <(fleet_humans)
  [[ "$found" -eq 1 ]] || p_warn "aucun humain de fleet sur cette machine — rien a vérifier ici tant que personne ne s'est enrolé.
     Le chemin : la page d'inscription de la forge, puis la team « $PROV_HUMANS_TEAM » — le convergeur matérialise au tour suivant.
     S'il ne matérialise pas : « journalctl -u lcars-converger » dit pourquoi (forge, jeton, team)."
}

check() { observe; verdict_check; }

# le rattrapage d'un compte fait à la main ou d'un groupe perdu ; la garde des bornes est ici et non
# dans la substitution, où elle dirait le remède une seconde fois
apply() {
  local h
  if prov_uid_bounds; then
    while read -r h; do
      [[ -n "$h" ]] || continue
      prov_in_group "$h" "$PROV_FLEET_GROUP" && continue
      if usermod -aG "$PROV_FLEET_GROUP" -- "$h" 2>/dev/null; then
        PROV_CHANGED=$((PROV_CHANGED + 1))
        p_chg "« $h » ajouté au groupe $PROV_FLEET_GROUP"
      fi
    done < <(fleet_humans)
  fi
  observe
  verdict_apply
}

case "${1:?usage: 22-fleet-human.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
