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

check() {
  if getent group "$PROV_FLEET_GROUP" >/dev/null; then
    p_ok "groupe $PROV_FLEET_GROUP"
  else
    p_drift "groupe $PROV_FLEET_GROUP absent"
  fi
  if id "$PROV_HUMAN" >/dev/null 2>&1; then
    if prov_in_group "$PROV_HUMAN" "$PROV_FLEET_GROUP"; then
      p_ok "$PROV_HUMAN ∈ $PROV_FLEET_GROUP"
    else
      p_drift "$PROV_HUMAN ∉ $PROV_FLEET_GROUP"
    fi
  else
    p_drift "humain cible inconnu du système : $PROV_HUMAN (--human pour désigner le bon)"
  fi
  if getent group "$PROV_CONSOLE_GROUP" >/dev/null; then
    p_ok "groupe $PROV_CONSOLE_GROUP"
  else
    p_drift "groupe $PROV_CONSOLE_GROUP absent — la landing ne démarrera pas (setpriv: unknown group), et aucune socket de console ne serait traversable"
  fi

  verdict_check
}

apply() {
  ensure_group "$PROV_FLEET_GROUP" || verdict_apply
  ensure_member "$PROV_HUMAN" "$PROV_FLEET_GROUP" || verdict_apply
  ensure_group "$PROV_CONSOLE_GROUP" || verdict_apply
  verdict_apply
}

case "${1:?usage: 20-groups.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
