#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/20-groups.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — groupe fleet + membership de l'humain (AUCUN user créé : le modèle v2 est per-humain)
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root
#
# Toute la strate « users » de la v1 meurt ici par soustraction : les rôles v2 ne sont PAS des
# users Linux (un pod = un process bwrap sous l'UID de l'humain qui lance sa fleet ; les rôles
# sont des cap-profiles DANS le runtime + des comptes sur la FORGE, cf. 50-forge). Il ne reste
# que : le groupe `fleet` (lecture de l'install RO + des role-tokens 0640) et l'appartenance de
# l'humain-lanceur à ce groupe.
#
# ⚠ LE SECOND GROUPE N'A AUCUN MEMBRE ICI, ET C'EST LE POINT. `$PROV_ADMIN_GROUP` projette
# `is_admin` de la forge (⚖ user 2026-08-17) : qui l'administre est une decision prise SUR LA
# FORGE, convergee par `human-converger.sh`. Y ajouter l'humain-lanceur d'office ferait de « qui a
# lance la fleet » un droit d'administration — ce que ce lot existe pour retirer.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

check() {
  if getent group "$PROV_FLEET_GROUP" >/dev/null; then
    p_ok "groupe $PROV_FLEET_GROUP"
  else
    p_drift "groupe $PROV_FLEET_GROUP absent"
  fi
  if id "$PROV_HUMAN" >/dev/null 2>&1; then
    if id -nG "$PROV_HUMAN" | tr ' ' '\n' | grep -qx "$PROV_FLEET_GROUP"; then
      p_ok "$PROV_HUMAN ∈ $PROV_FLEET_GROUP"
    else
      p_drift "$PROV_HUMAN ∉ $PROV_FLEET_GROUP"
    fi
  else
    p_drift "humain cible inconnu du système : $PROV_HUMAN (--human pour désigner le bon)"
  fi
  if getent group "$PROV_ADMIN_GROUP" >/dev/null; then
    p_ok "groupe $PROV_ADMIN_GROUP (membres : $(members_of "$PROV_ADMIN_GROUP"))"
  else
    p_drift "groupe $PROV_ADMIN_GROUP absent — aucun humain ne pourra administrer le runtime"
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
  # Le groupe d'administration existe TOUJOURS, meme vide : les fichiers d'autorite lui sont
  # attribues (`0640 root:$PROV_ADMIN_GROUP`), et un groupe absent ferait echouer ce chown sur une
  # boite dont personne n'est encore admin.
  ensure_group "$PROV_ADMIN_GROUP" || verdict_apply
  # ⚠ SANS LUI, LA LANDING NE DEMARRE MEME PAS. `console-landing.sh` se depose par
  # `setpriv --reuid nobody --regid nogroup --groups lcars-console` : un groupe absent n'est pas une
  # degradation, c'est un `setpriv: unknown group` et un service qui meurt au demarrage. L'image le
  # cree dans son Dockerfile (gid 2001) ; le rail poste ne le creait nulle part, et je l'avais posé
  # a la main sur la premiere machine — donc le rail ne l'avait jamais fait une seule fois.
  ensure_group "$PROV_CONSOLE_GROUP" || verdict_apply
  verdict_apply
}

case "${1:?usage: 20-groups.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
