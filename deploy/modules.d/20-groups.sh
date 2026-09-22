#!/usr/bin/env bash
# SOURCE: deploy/modules.d/20-groups.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: les groupes fleet et console, et le siège dans fleet — aucun compte créé ici, aucune appartenance d'humain jugée
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — ce module se joue par ./provision, pas nu}"

# Le convergeur d'humains est seul juge de l'appartenance d'un humain à fleet : il ajoute et révoque d'après
# la team de la forge. Ce module n'y met que le siège, le compte de l'uid LCARS_SYSADMIN_UID que provision
# établit depuis le compte qui l'a lancé (jamais depuis --human), et que le convergeur ne touche jamais (GUARD A).
# Le siège en a besoin pour traverser le dossier des jetons : le skill system-issues y lit forge.url.
# lu après le mode : un mode inconnu se refuse avant toute lecture
lire_siege() {
  [[ "${LCARS_SYSADMIN_UID:-}" =~ ^[0-9]+$ ]] \
    || p_die "LCARS_SYSADMIN_UID absent ou non numérique (« ${LCARS_SYSADMIN_UID:-} ») : provision l'établit depuis le compte qui le lance — ce module se joue par ./provision"
  SEAT_LOGIN="$(getent passwd | awk -F: -v u="$LCARS_SYSADMIN_UID" '$3 == u {print $1; exit}' || true)"
  SIEGE_INCONNU="siège inconnu du système : aucun compte ne porte l'uid $LCARS_SYSADMIN_UID (LCARS_SYSADMIN_UID)"
}

# root n'est l'humain d'aucune passe : le siège root (le doctor du conteneur par « docker exec », une session
# root) passe outre les permissions de groupe, et fleet ne lui donne rien
siege_est_root() { [[ "$LCARS_SYSADMIN_UID" == 0 ]]; }
SIEGE_ROOT="le siège est root (uid 0) : fleet ne lui donne rien, son appartenance ne se mesure ni ne se pose"

# l'humain de la passe (--human) qui n'est pas le siège : son appartenance n'est pas l'affaire de ce module
humain_hors_siege() {
  [[ "$PROV_HUMAN" != "$SEAT_LOGIN" && "$(id -u -- "$PROV_HUMAN" 2>/dev/null)" != 0 ]] || return 0
  p_ok "$PROV_HUMAN n'est pas le siège : son appartenance à $PROV_FLEET_GROUP est l'affaire du convergeur d'humains (team « $PROV_HUMANS_TEAM » de la forge) — ce module ne la mesure ni ne la pose"
}

check() {
  local grp
  for grp in "$PROV_FLEET_GROUP" "$PROV_CONSOLE_GROUP"; do
    if ! getent group "$grp" >/dev/null; then
      p_drift "groupe $grp absent"
    elif prov_group_gid_ok "$grp"; then
      p_ok "groupe $grp"
    fi
  done
  if siege_est_root; then
    p_ok "$SIEGE_ROOT"
  elif [[ -z "$SEAT_LOGIN" ]]; then
    p_drift "$SIEGE_INCONNU"
  elif prov_in_group "$SEAT_LOGIN" "$PROV_FLEET_GROUP"; then
    p_ok "siège $SEAT_LOGIN ∈ $PROV_FLEET_GROUP"
  else
    p_drift "siège $SEAT_LOGIN ∉ $PROV_FLEET_GROUP — il ne traverse pas $PROV_TOKENS_DIR"
  fi
  humain_hors_siege
  verdict_check
}

apply() {
  ensure_group "$PROV_FLEET_GROUP" || verdict_apply
  if siege_est_root; then
    p_ok "$SIEGE_ROOT"
  elif [[ -z "$SEAT_LOGIN" ]]; then
    p_fail "$SIEGE_INCONNU — personne n'est ajouté à $PROV_FLEET_GROUP"
  else
    ensure_member "$SEAT_LOGIN" "$PROV_FLEET_GROUP" || verdict_apply
  fi
  humain_hors_siege
  ensure_group "$PROV_CONSOLE_GROUP" || verdict_apply
  [[ "$PROV_CHANGED" -gt 0 || "$PROV_FAILED" -gt 0 ]] || siege_est_root \
    || p_ok "groupes $PROV_FLEET_GROUP et $PROV_CONSOLE_GROUP en place, siège $SEAT_LOGIN membre de $PROV_FLEET_GROUP"
  verdict_apply
}

case "${1:-}" in check|apply) lire_siege; "$1" ;; *) p_die "mode inconnu: ${1:-} (check|apply)" ;; esac
