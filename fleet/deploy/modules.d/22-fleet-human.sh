#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/22-fleet-human.sh
# AUTHOR: DrDree
# STARDATE: (posée par /push-github)
# STATUS: PROTO-V2 — l'humain de fleet du POSTE : la forge le sème, le convergeur le pose, CE MODULE ATTESTE
# APPLY-ON: wsl linux
# CHECK-ON: wsl linux
# NEEDS: root
#
# ⚠ IL DÉRIVE, IL N'ÉCHOUE PAS. Un compte absent n'est pas une machine cassée : c'est un geste qui
# manque, et tout le reste du provisionnement est déjà posé quand on arrive ici. Un échec ferait
# rendre 1 à l'apply entier — la faute exacte que `52-ops-branch` portait le même jour.
#
# Données : PROV_FLEET_GROUP · le nom de l'humain intégré, LU chez son autorité

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

FLEET_HUMAN="$(bash "$(repo_root)/fleet/services/forge-gestures.sh" builtin-human 2>/dev/null || true)"

# ─── OBSERVER N'EST PAS JUGER ───────────────────────────────────────────────────────────────────
#
# Ce qui suit n'a donc pas de verdict : il DÉCRIT, chaque verbe conclut.
observe() {
  local uid
  if [[ -z "$FLEET_HUMAN" ]]; then
    p_drift "le nom de l'humain intégré est indéterminable — « fleet/services/forge-gestures.sh builtin-human » ne répond pas.
     Ce n'est pas un constat sur cette machine : c'est l'arbre du provisionnement qui est incomplet,
     et RIEN ici ne peut être mesuré tant qu'il l'est."
    return 0
  fi
  if ! uid="$(id -u -- "$FLEET_HUMAN" 2>/dev/null)"; then
    p_drift "humain de fleet « $FLEET_HUMAN » absent — la forge pose son compte (48) et le convergeur le matérialise (64) ; « 64-services » vérifie avant de rendre la main.
     Si le rail n'a pas abouti, le geste à la main : « useradd -m -G $PROV_FLEET_GROUP $FLEET_HUMAN »"
    return 0
  fi
  if is_fleet_human "$FLEET_HUMAN"; then
    p_ok "humain de fleet « $FLEET_HUMAN » (uid $uid) — il peut lancer la fleet"
  else
    # Le cas se produit si quelqu'un a créé le compte à la main sur l'uid du siège. On le DIT plutôt
    # que de le déplacer : changer l'uid d'un compte existant orphelinerait tout ce qu'il possède.
    p_drift "« $FLEET_HUMAN » existe en uid $uid, que GUARD B refuse (siège ou compte système) — la fleet ne démarrera pas sous lui"
  fi
  if id -nG "$FLEET_HUMAN" 2>/dev/null | tr ' ' '\n' | grep -qx "$PROV_FLEET_GROUP"; then
    p_ok "« $FLEET_HUMAN » ∈ $PROV_FLEET_GROUP"
  else
    p_drift "« $FLEET_HUMAN » hors du groupe $PROV_FLEET_GROUP — il ne lira ni /opt/lcars/var/tokens ni les zones de face"
  fi
}

check() { observe; verdict_check; }

apply() {
  # `p_fail` ferait rendre 1 à l'apply ENTIER au rang 22 — pour un arbre incomplet que `48-forge-host`
  # rencontrera de toute façon, en appelant le même script, avec un verdict qui porte la conséquence
  # réelle (structure non posée). Refuser tôt sur une cause qu'un autre module nomme mieux fait
  # chercher au mauvais rang.
  if [[ -z "$FLEET_HUMAN" ]]; then
    observe
    verdict_apply
  fi
  if ! id -u -- "$FLEET_HUMAN" >/dev/null 2>&1; then
    p_ok "« $FLEET_HUMAN » sera posé par la forge (48) puis matérialisé par le convergeur (64) : le même chemin qu'en production"
    verdict_apply
  fi

  if ! id -nG "$FLEET_HUMAN" 2>/dev/null | tr ' ' '\n' | grep -qx "$PROV_FLEET_GROUP"; then
    if usermod -aG "$PROV_FLEET_GROUP" -- "$FLEET_HUMAN" 2>/dev/null; then
      PROV_CHANGED=$((PROV_CHANGED + 1))
      p_chg "« $FLEET_HUMAN » ajouté au groupe $PROV_FLEET_GROUP"
    else
      p_drift "« $FLEET_HUMAN » n'a pas pu rejoindre $PROV_FLEET_GROUP"
    fi
  fi

  observe
  verdict_apply
}

case "${1:?usage: 22-fleet-human.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
