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

# Le siege se lit dans son fichier (`LCARS_SEAT_UID_FILE`), sinon dans `LCARS_SYSADMIN_UID` — la
# meme lecture, dans le meme ordre, que l'installeur : un seul siege sur la machine, quel que soit
# celui qui le lit.
seat_uid() { # rend l'uid du siege, ou rien
  local f v
  f="${LCARS_SEAT_UID_FILE:-/etc/lcars/seat.uid}"
  if [[ -r "$f" ]]; then
    v="$(head -n1 -- "$f" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$v" =~ ^[0-9]+$ ]] && { printf '%s' "$v"; return 0; }
  fi
  v="${LCARS_SYSADMIN_UID:-}"
  [[ "$v" =~ ^[0-9]+$ ]] && { printf '%s' "$v"; return 0; }
  return 0
}

# ─── La frontiere systeme/humain ───────────────────────────────────────────────────────────────
# Les bornes se LISENT dans `login.defs` (`PASSWD_DEFS`, le meme nom que `console-humans.sh`,
# `bin/fleet` et le BEAM) ; elles ne s'ecrivent pas ici, et elles n'ont PAS de defaut.
#
# ⚠ AUCUN REPLI SUR 1000, et c'est delibere — la politique que le BEAM applique a son boot
# (`config/runtime.exs`, R-no-uid-min) et que `console-humans.sh` applique a sa liste. Un
# `login.defs` illisible n'est pas « la frontiere est a 1000 », c'est « la frontiere n'est pas
# etablie » : un UID_MIN reel a 2000 devine a 1000 ferait humain tout ce qui vit entre les deux, et
# un UID_MAX devine ferait humain `nobody` (65534, sur toute machine). Une garde qui ne peut pas
# mesurer refuse — et dit UNE FOIS le remede, qui n'est pas dans ce processus : c'est le fichier.
# CE FICHIER EST LA SEULE ECRITURE DE LA REGLE COTE SHELL (2026-09-05) : le convergeur, `boot.sh`
# et `75-projects` l'appellent ; `bin/fleet` et la lib de l'installeur en portent une copie de
# trois lignes, sous un temoin d'egalite (leur hote ne peut pas sourcer un protocole de module).
#
# La borne ne se lit PAS dans l'environnement du processus garde (`UID_MIN=0 …`) : « la frontiere
# obeirait a qui la franchit » (runtime.exs). `UID_MIN`/`UID_MAX` sont RE-ECRITS a chaque lecture
# depuis le fichier — une valeur heritee de l'environnement n'y survit pas.
#
# `uid_bounds` est un PREDICAT (`uid_bounds || …`) : le remede se dit une fois par processus
# (`_UID_BOUNDS_SAID`), et un `$( )` — un sous-shell — perd cette trace. Qui enumere lit les deux
# variables apres l'appel ; qui refuse trouve la raison dans `UID_BOUNDS_WHY`.
UID_MIN="" UID_MAX="" UID_BOUNDS_WHY=""
_UID_BOUNDS_SAID=""
uid_bounds() { # pose UID_MIN et UID_MAX depuis login.defs — 0 si les deux se lisent ; 1 sinon, remede dans UID_BOUNDS_WHY, dit une fois
  local defs="${PASSWD_DEFS:-/etc/login.defs}" missing=""
  UID_MIN="$(awk '$1 == "UID_MIN" {print $2; exit}' "$defs" 2>/dev/null || true)"
  UID_MAX="$(awk '$1 == "UID_MAX" {print $2; exit}' "$defs" 2>/dev/null || true)"
  [[ "$UID_MIN" =~ ^[0-9]+$ ]] || missing=UID_MIN
  [[ -n "$missing" || "$UID_MAX" =~ ^[0-9]+$ ]] || missing=UID_MAX
  if [[ -z "$missing" ]]; then UID_BOUNDS_WHY=""; return 0; fi
  UID_MIN="" UID_MAX=""
  UID_BOUNDS_WHY="la frontiere systeme/humain n'est pas etablie ($missing illisible dans $defs) — la borne est declaree par le systeme, pas par ce processus : repare $defs"
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
