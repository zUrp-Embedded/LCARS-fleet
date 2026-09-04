#!/usr/bin/env bash
# SOURCE: deploy/modules.d/22-fleet-human.sh
# AUTHOR: DrDree
# STARDATE: (posée par /push-github)
# STATUS: PROTO-V2 — l'humain de fleet du POSTE : la forge le sème, le convergeur le pose, CE MODULE ATTESTE
# APPLY-ON: wsl linux
# CHECK-ON: wsl linux
# NEEDS: root
# AFTER: 20-groups

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

# ⚠ CE MODULE N'ATTEND PLUS UN COMPTE NOMME, ET C'EST LE CANON QUI A CHANGE (⚖ user 2026-08-30).
# Il interrogeait `forge-gestures.sh builtin-human` et derivait si CE compte-la manquait. Or aucun
# deploiement de travail ne fabrique d'humain : le rail pose les AUTORITES (le siege, l'admin de
# forge, le master token), et les personnes s'enrolent par la page d'inscription de la forge, sous
# LEUR nom. Attendre « lcars » sur un poste de travail, c'etait attendre quelqu'un que plus rien ne
# cree — une derive permanente des que le premier inscrit s'appelle autrement.
#
# ⚠ ET IL NE POSE PLUS RIEN : le convergeur cree le compte (`useradd -m`) ET l'ajoute au groupe
# (`usermod -aG "$GROUP"`, deux sites dans human-converger.sh). Le `usermod` qui vivait ici doublait ce geste.
#
# CE QUI LUI RESTE EN PROPRE, et que personne d'autre ne verifie : L'APPARTENANCE AU GROUPE.
# `is_fleet_human` ne juge que l'uid (>= UID_MIN, pas le siege) ; un humain hors de `fleet` passe
# donc cette borne et ne lira pourtant ni les jetons ni les zones de face. `64-services` compte les
# humains, celui-ci regarde s'ils peuvent travailler.
observe() {
  local h found=0
  while read -r h; do
    [[ -n "$h" ]] || continue
    found=1
    if prov_in_group "$h" "$PROV_FLEET_GROUP"; then
      p_ok "« $h » (uid $(id -u -- "$h")) ∈ $PROV_FLEET_GROUP — il peut lancer la fleet"
    else
      p_drift "« $h » hors du groupe $PROV_FLEET_GROUP — il ne lira ni $PROV_TOKENS_DIR ni les zones de face"
    fi
  done < <(fleet_humans)

  # ⚠ ZERO HUMAIN N'EST PAS UNE DERIVE, c'est l'etat nominal d'une machine neuve — meme raison et
  # meme forme que dans `64-services`, qui pose la question du COMPTE. Ici il n'y a simplement
  # personne dont verifier le groupe.
  #
  # ⚠ ET LE GESTE RESTE PROPOSE (P-40) : le rail est le chemin, mais celui pour qui il n'a pas
  # abouti doit avoir quelque chose a taper. Ce n'est PAS un `useradd` (⚖ user 2026-09-04, DI-02 :
  # UN SEUL createur d'humains, le convergeur) — un compte fait a la main n'a ni son uid derive de
  # la forge, ni ses modules per-humain, et le convergeur le verra comme un inconnu. Ce qu'on
  # regarde quand le rail n'aboutit pas, c'est le convergeur lui-meme.
  [[ "$found" -eq 1 ]] || p_warn "aucun humain de fleet sur cette machine — rien a vérifier ici tant que personne ne s'est enrolé.
     Le chemin : la page d'inscription de la forge, puis la team « $PROV_HUMANS_TEAM » — le convergeur matérialise au tour suivant.
     S'il ne matérialise pas : « journalctl -u lcars-converger » dit pourquoi (forge, jeton, team)."
}

check() { observe; verdict_check; }

apply() {
  # LE RATTRAPAGE, PAS LE GESTE NOMINAL : le convergeur pose le groupe en creant le compte. Ce qui
  # arrive ici, c'est un compte cree A LA MAIN, ou un groupe perdu — l'apply le repose plutot que de
  # renvoyer l'operateur a un `usermod` qu'il devra ecrire lui-meme.
  local h
  while read -r h; do
    [[ -n "$h" ]] || continue
    prov_in_group "$h" "$PROV_FLEET_GROUP" && continue
    if usermod -aG "$PROV_FLEET_GROUP" -- "$h" 2>/dev/null; then
      PROV_CHANGED=$((PROV_CHANGED + 1))
      p_chg "« $h » ajouté au groupe $PROV_FLEET_GROUP"
    fi
  done < <(fleet_humans)

  observe
  verdict_apply
}

case "${1:?usage: 22-fleet-human.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
