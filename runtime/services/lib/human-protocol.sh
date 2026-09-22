#!/usr/bin/env bash
# SOURCE: runtime/services/lib/human-protocol.sh
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: actif — le protocole des modules per-humain (`human.d`) : le protocole des modules du produit, plus la PERSONNE
#
# ⚖ user 2026-09-04 (Q3 du chantier deploy-independance) : « la frontiere, c'est : joue uniquement
# a l'install, ou utilise en prod ? ». Les modules `human.d` sont joues EN PROD, a chaque humain
# que la forge inscrit, par le convergeur — jamais par l'installeur. Ils sourcaient pourtant
# `deploy/lib/provision-lib.sh`, par une garde `${PROVISION_LIB:?}` que leur seul hote reel ne
# pose pas : mesure du 2026-09-04 sur les deux bancs, chaque humain cree mourait a la ligne 1 de
# ses trois modules, rc=1, et le conteneur annoncait « converge ». Un humain sans `~/.lcars`, sans
# `claude`, sans projets — qui ne peut pas lancer de fleet.
#
# Le vocabulaire commun vit dans `module-protocol.sh` (les gestes de forge le partagent). Ici, ce
# qui n'a de sens que pour une personne : QUI elle est, son home, et si elle est un humain de fleet.
# Source par le convergeur (l'hote) ET par les temoins — une copie, un contrat.
#
# ⚠ SOURCE, JAMAIS EXECUTE : aucun `set -e` ici, aucune sortie.

# ─── Le sujet ──────────────────────────────────────────────────────────────────────────────────
# `LCARS_LOGIN` est pose par l'hote (le convergeur : le login qu'il converge). Sans lui, un module
# agirait sur l'utilisateur courant — root, sous le convergeur. On ne devine pas : on refuse.
#
# L'HOTE, lui, source ce fichier pour la REGLE — `uid_bounds`, `is_fleet_human <login>` — pas pour
# agir sur une personne : il n'a pas UN sujet, il en nomme un a chaque appel. Il le declare par
# `LCARS_HUMAN_PROTOCOL_HOST=1` — LE CONTRAT DE LA VARIABLE : posee (jamais exportee) juste avant
# le `source`, retiree (`unset`) juste apres. Un module que l'hote lance ne l'herite donc pas et
# garde sa garde ; un hote qui l'exporterait, ou qui poserait un `LCARS_LOGIN` d'emprunt a la
# place, ferait de toute lecture « de la personne » (`human_home`) celle de ce login. Deux hotes
# (lot 15) : `human-converger.sh` (la boucle) et `container/boot.sh` (la mesure de population au boot) ;
# les temoins qui sourcent pour la regle la posent de la meme facon. Sans sujet nomme, les
# lectures de la personne rendent « rien » ou « non » — jamais l'utilisateur courant.
if [[ -z "${LCARS_HUMAN_PROTOCOL_HOST:-}" ]]; then
  : "${LCARS_LOGIN:?LCARS_LOGIN non pose — le convergeur nomme le login converge}"
fi
: "${LCARS_MODULE_TAG:=human}"

# shellcheck source=module-protocol.sh
. "${LCARS_MODULE_PROTOCOL:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/module-protocol.sh}"

# ─── Les lectures de la personne ───────────────────────────────────────────────────────────────
human_home() { [[ -n "${LCARS_LOGIN:-}" ]] || return 0; getent passwd "$LCARS_LOGIN" | cut -d: -f6 || true; }

# `seat_uid` vient du protocole des modules, source ci-dessus : un seul siege sur la machine, une
# seule lecture, quel que soit celui qui la fait.

# ─── La frontiere systeme/humain ───────────────────────────────────────────────────────────────
# ⚖ Phase 5 : LA LECTURE N'EST PLUS ECRITE ICI. Elle vit dans `lib/uid-bounds.sh`, avec toute la
# doctrine qui la tient (aucun repli, deux bornes, rien depuis l'environnement du garde). Ce
# fichier en etait « la seule ecriture cote shell » et trois autres en portaient une copie, parce
# que leurs hotes « ne peuvent pas sourcer un protocole de module » — vrai, il exige un sujet.
# Mais ils peuvent sourcer une LECTURE, qui n'impose rien et n'imprime rien.
#
# Ce qui reste ici est ce qui n'a de sens que pour un MODULE : le DIRE, une fois par processus.
# `uid_bounds` est un PREDICAT (`uid_bounds || …`) : la trace du « dit une fois » (`_UID_BOUNDS_SAID`)
# ne survivrait pas a un `$( )`, qui est un sous-shell. Qui enumere lit les deux variables apres
# l'appel ; qui refuse trouve la raison dans `UID_BOUNDS_WHY`.
# shellcheck source=uid-bounds.sh
. "${LCARS_UID_BOUNDS_SH:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/uid-bounds.sh}"
_UID_BOUNDS_SAID=""
uid_bounds() { # pose UID_MIN et UID_MAX — 0 si les deux se lisent ; 1 sinon, remede dans UID_BOUNDS_WHY, dit une fois
  uid_bounds_read && return 0
  if [[ -z "$_UID_BOUNDS_SAID" ]]; then
    _UID_BOUNDS_SAID=1
    p_warn "$UID_BOUNDS_WHY"
  fi
  return 1
}

# Un humain de fleet : un uid DANS la plage des humains de la machine (UID_MIN <= uid <= UID_MAX —
# les comptes systeme sont en dessous, `nobody` au-dessus), et qui n'est pas le SIEGE — le siege
# est le sysadmin, converge par l'installeur, jamais par ces modules. Bornes illisibles : personne
# n'est un humain, et `uid_bounds` a dit pourquoi.
# Le SIEGE fait partie de la frontiere : un siege inconnu ne peut pas etre exclu, donc il passerait
# pour un humain. Meme politique que les bornes (et que le BEAM, R-no-seat) : pas de siege, pas
# d'humain, dit une fois. Le remede nomme les deux lectures (fichier, puis LCARS_SYSADMIN_UID).
_SEAT_SAID=""
seat_established() { # pose SEAT_UID — 0 si le siege se lit ; 1 sinon, dit une fois
  SEAT_UID="$(seat_uid)"
  [[ -n "$SEAT_UID" ]] && return 0
  if [[ -z "$_SEAT_SAID" ]]; then
    _SEAT_SAID=1
    p_warn "le siège n'est pas déclaré (${LCARS_SEAT_UID_FILE:-/etc/lcars/seat.uid} illisible, LCARS_SYSADMIN_UID non posé) — sans lui la frontière n'est pas établie : cette machine n'est pas installée. Sur un poste, « deploy/workstation up » le pose ; dans un conteneur, l'init du démarrage le pose, et s'il ne peut pas le déterminer : « deploy/container config » depuis l'hôte, puis « deploy/container up »"
  fi
  return 1
}

is_fleet_human() { # [login] (defaut : LCARS_LOGIN) — 0 si oui
  local login="${1:-${LCARS_LOGIN:-}}" uid
  [[ -n "$login" ]] || return 1
  uid="$(id -u -- "$login" 2>/dev/null || true)"
  [[ "$uid" =~ ^[0-9]+$ ]] || return 1
  uid_bounds || return 1
  seat_established || return 1
  (( uid >= UID_MIN && uid <= UID_MAX )) && [[ "$uid" != "$SEAT_UID" ]]
}
