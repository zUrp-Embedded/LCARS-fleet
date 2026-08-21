#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/65-fleet-human.sh
# AUTHOR: DrDree
# STARDATE: (posée par /push-github)
# STATUS: PROTO-V2 — l'humain de fleet du POSTE : un compte unix qui n'est pas le siège
# APPLY-ON: wsl linux
# CHECK-ON: wsl linux
# NEEDS: root
#
# ⚖ ARBITRAGE USER 2026-08-21 : « pourquoi, tout en étant loggé sur mon compte lordzurp, je pourrais
# pas avoir une fleet qui tourne sous UID 1001 ? la porte d'entrée de la fleet c'est le deck, et la
# porte d'entrée du deck c'est le login sur la forge. on garde UID=1000 comme admin avec fleet
# bloqué. »
#
# ─── CE QUE CE MODULE FERME ────────────────────────────────────────────────────────────────────
# Le rail poste installait un runtime que personne ne pouvait lancer, et il se contredisait en le
# faisant. Mesure du 2026-08-21, install à froid sur machine dédiée, humain = l'opérateur (uid 1000) :
#
#     POSÉ  20-groups:   lordzurp ∈ fleet
#     POSÉ  70-human:    ~/.lcars, ~/pods, env  →  pour lordzurp
#     OK    75-projects: lordzurp n'est pas un humain de fleet (compte systeme ou sysadmin)
#
# Deux modules le traitaient comme l'humain, un troisième le récusait — et GUARD B, dans
# `bin/fleet_v2`, applique la même règle que `is_fleet_human` : `uid >= UID_MIN` ET
# `uid != LCARS_SYSADMIN_UID` (défaut 1000). Or le premier utilisateur d'une Linux ou d'une WSL
# standard EST uid 1000. La règle « uid >= 1001 » n'était écrite que pour la BOÎTE (entrypoint,
# bench-up) ; le rail poste n'en avait aucune.
#
# ─── POURQUOI UN COMPTE SÉPARÉ N'EST PAS UNE GÊNE ──────────────────────────────────────────────
# L'opérateur n'a pas à ÊTRE l'humain de fleet. Il lance (`sudo -u <humain> fleet_v2 start`) et il
# ATTEINT le deck par le groupe : la socket est `0660` et son dossier `2710 <humain>:fleet`, donc
# tout membre du groupe l'ouvre. `Fleet.EventRouter.UnixListener` le dit dans son propre contrat —
# « the landing — a DIFFERENT uid holding the console group — must open it ». Son identité, à lui,
# c'est son compte de FORGE : le deck s'ouvre sur un login forge, pas sur un uid.
#
# ─── CE MODULE N'EST PAS UN CONVERGEUR D'HUMAINS ───────────────────────────────────────────────
# Dans la boîte, `human-converger.sh` matérialise N humains inconnus depuis la team `humans` de la
# forge, et il continue de le faire. Ici il y a UN poste, UN humain de fleet, et la forge n'existe
# pas forcément encore quand ce module tourne (48-forge-host peut dériver). Ce module pose donc le
# compte, rien d'autre — pas de roster, pas de boucle, pas de révocation.
#
# ⚠ IL DÉRIVE, IL N'ÉCHOUE PAS. Un `useradd` refusé n'est pas une machine cassée : c'est un geste
# qui manque, et tout le reste du provisionnement est déjà posé quand on arrive ici. Un échec ferait
# rendre 1 à l'apply entier — la faute exacte que `52-ops-branch` portait le même jour.
#
# Données : PROV_FLEET_HUMAN (défaut `lcars`) · PROV_FLEET_GROUP · LCARS_SYSADMIN_UID

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

: "${PROV_FLEET_HUMAN:=lcars}"
FLEET_SHELL="${PROV_FLEET_HUMAN_SHELL:-/bin/bash}"

# LE PLANCHER D'UID SE DÉRIVE, IL NE S'ÉCRIT PAS. `is_fleet_human` exige `uid >= UID_MIN` ET
# `uid != LCARS_SYSADMIN_UID` : le premier uid acceptable est donc juste au-dessus du plus grand des
# deux. Recopier « 1001 » ici en ferait un troisième exemplaire d'un nombre que le système et la lib
# déclarent déjà — et il serait faux le jour où l'un des deux bouge.
fleet_uid_floor() {
  local uid_min sysadmin
  uid_min="$(awk '/^UID_MIN/ {print $2}' "${PASSWD_DEFS:-/etc/login.defs}" 2>/dev/null | head -n1 || true)"
  [[ "$uid_min" =~ ^[0-9]+$ ]] || uid_min=1000
  sysadmin="${LCARS_SYSADMIN_UID:-1000}"
  (( uid_min > sysadmin )) && { echo "$uid_min"; return 0; }
  echo "$(( sysadmin + 1 ))"
}

# Le premier uid LIBRE au-dessus du plancher. On ne le laisse pas à `useradd` : son propre choix
# part de UID_MIN, donc il rendrait l'uid du siège si celui-ci était libre — exactement le compte
# qu'on ne veut pas créer.
first_free_uid() {
  local uid; uid="$(fleet_uid_floor)"
  while getent passwd "$uid" >/dev/null 2>&1; do uid=$(( uid + 1 )); done
  echo "$uid"
}

check() {
  local uid
  if ! uid="$(id -u -- "$PROV_FLEET_HUMAN" 2>/dev/null)"; then
    p_drift "humain de fleet « $PROV_FLEET_HUMAN » absent — le poste n'a personne pour lancer la fleet (l'apply le crée)"
    verdict_check
  fi
  if is_fleet_human "$PROV_FLEET_HUMAN"; then
    p_ok "humain de fleet « $PROV_FLEET_HUMAN » (uid $uid) — il peut lancer la fleet"
  else
    # Le cas se produit si quelqu'un a créé le compte à la main sur l'uid du siège. On le DIT plutôt
    # que de le déplacer : changer l'uid d'un compte existant orphelinerait tout ce qu'il possède.
    p_drift "« $PROV_FLEET_HUMAN » existe en uid $uid, que GUARD B refuse (siège ou compte système) — la fleet ne démarrera pas sous lui"
  fi
  if id -nG "$PROV_FLEET_HUMAN" 2>/dev/null | tr ' ' '\n' | grep -qx "$PROV_FLEET_GROUP"; then
    p_ok "« $PROV_FLEET_HUMAN » ∈ $PROV_FLEET_GROUP"
  else
    p_drift "« $PROV_FLEET_HUMAN » hors du groupe $PROV_FLEET_GROUP — il ne lira ni /home/private ni les zones de face"
  fi
  verdict_check
}

apply() {
  if ! id -u -- "$PROV_FLEET_HUMAN" >/dev/null 2>&1; then
    local uid; uid="$(first_free_uid)"
    if useradd -u "$uid" -m -s "$FLEET_SHELL" -g "$PROV_FLEET_GROUP" -- "$PROV_FLEET_HUMAN" 2>/dev/null; then
      PROV_CHANGED=$((PROV_CHANGED + 1))
      p_chg "humain de fleet « $PROV_FLEET_HUMAN » créé (uid $uid, groupe $PROV_FLEET_GROUP)"
    else
      p_drift "useradd « $PROV_FLEET_HUMAN » (uid $uid) a échoué — le poste reste sans humain de fleet"
      verdict_apply
    fi
  fi

  # L'APPARTENANCE SE CONVERGE MÊME SUR UN COMPTE QUI EXISTAIT DÉJÀ : `useradd -g` ne vaut que pour
  # une création, et un compte posé à la main (ou par une version antérieure) peut être hors groupe.
  if ! id -nG "$PROV_FLEET_HUMAN" 2>/dev/null | tr ' ' '\n' | grep -qx "$PROV_FLEET_GROUP"; then
    if usermod -aG "$PROV_FLEET_GROUP" -- "$PROV_FLEET_HUMAN" 2>/dev/null; then
      PROV_CHANGED=$((PROV_CHANGED + 1))
      p_chg "« $PROV_FLEET_HUMAN » ajouté au groupe $PROV_FLEET_GROUP"
    else
      p_drift "« $PROV_FLEET_HUMAN » n'a pas pu rejoindre $PROV_FLEET_GROUP"
    fi
  fi

  check
}

case "${1:?usage: 65-fleet-human.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
