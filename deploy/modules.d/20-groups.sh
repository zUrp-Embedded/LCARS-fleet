#!/usr/bin/env bash
# SOURCE: deploy/modules.d/20-groups.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: les groupes fleet et console, et l'humain de la passe dans fleet — aucun compte créé ici
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — ce module se joue par ./provision, pas nu}"

# root n'est l'humain d'aucune passe. Sans --human ni SUDO_USER (le doctor du conteneur par « docker exec »,
# une session root), la passe le prend pour humain ; il passe outre les permissions de groupe et fleet ne
# lui donne rien : son appartenance ne se mesure ni ne se pose.
humain_est_root() { [[ "$(id -u -- "$PROV_HUMAN" 2>/dev/null)" == 0 ]]; }

check() {
  local grp
  for grp in "$PROV_FLEET_GROUP" "$PROV_CONSOLE_GROUP"; do
    if ! getent group "$grp" >/dev/null; then
      p_drift "groupe $grp absent"
    elif prov_group_gid_ok "$grp"; then
      p_ok "groupe $grp"
    fi
  done
  if ! id "$PROV_HUMAN" >/dev/null 2>&1; then
    p_drift "humain cible inconnu du système : $PROV_HUMAN (--human pour désigner le bon)"
  elif humain_est_root; then
    p_ok "$PROV_HUMAN n'est pas un humain de fleet : l'appartenance d'un humain se mesure avec --human <login>"
  elif prov_in_group "$PROV_HUMAN" "$PROV_FLEET_GROUP"; then
    p_ok "$PROV_HUMAN ∈ $PROV_FLEET_GROUP"
  else
    p_drift "$PROV_HUMAN ∉ $PROV_FLEET_GROUP"
  fi
  verdict_check
}

apply() {
  ensure_group "$PROV_FLEET_GROUP" || verdict_apply
  if humain_est_root; then
    p_ok "$PROV_HUMAN n'est pas un humain de fleet : il n'y est pas ajouté (--human <login> désigne l'humain de la passe)"
  else
    ensure_member "$PROV_HUMAN" "$PROV_FLEET_GROUP" || verdict_apply
  fi
  ensure_group "$PROV_CONSOLE_GROUP" || verdict_apply
  [[ "$PROV_CHANGED" -gt 0 ]] || humain_est_root \
    || p_ok "groupes $PROV_FLEET_GROUP et $PROV_CONSOLE_GROUP en place, $PROV_HUMAN membre de $PROV_FLEET_GROUP"
  verdict_apply
}

case "${1:-}" in check|apply) "$1" ;; *) p_die "mode inconnu: ${1:-} (check|apply)" ;; esac
