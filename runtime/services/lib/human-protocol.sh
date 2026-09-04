#!/usr/bin/env bash
# SOURCE: fleet/services/lib/human-protocol.sh
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: actif — le protocole des modules per-humain (`human.d`) : le protocole des modules du produit, plus la PERSONNE
#
# ⚖ user 2026-09-04 (Q3 du chantier deploy-independance) : « la frontiere, c'est : joue uniquement
# a l'install, ou utilise en prod ? ». Les modules `human.d` sont joues EN PROD, a chaque humain
# que la forge inscrit, par le convergeur — jamais par l'installeur. Ils sourcaient pourtant
# `deploy/lib/provision-lib.sh`, par une garde `${PROVISION_LIB:?}` que leur seul hote reel ne
# pose pas : mesure du 2026-09-04 sur les deux bancs, chaque humain cree mourait a la ligne 1 de
# ses trois modules, rc=1, et la boite annoncait « converge ». Un humain sans `~/.lcars`, sans
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
: "${LCARS_LOGIN:?LCARS_LOGIN non pose — le convergeur nomme le login converge}"
: "${LCARS_MODULE_TAG:=human}"

# shellcheck source=module-protocol.sh
. "${LCARS_MODULE_PROTOCOL:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/module-protocol.sh}"

# ─── Les lectures de la personne ───────────────────────────────────────────────────────────────
human_home() { getent passwd "$LCARS_LOGIN" | cut -d: -f6 || true; }

# Le plancher se lit dans `login.defs` (`PASSWD_DEFS`, le meme nom que le convergeur) ; le siege
# dans son fichier (`LCARS_SEAT_UID_FILE`), sinon dans `LCARS_SYSADMIN_UID` — la meme lecture, dans
# le meme ordre, que l'installeur : un seul siege sur la machine, quel que soit celui qui le lit.
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
# Un humain de fleet : un uid au-dessus du plancher des humains de la machine, et qui n'est pas le
# SIEGE — le siege est le sysadmin, converge par l'installeur, jamais par ces modules.
is_fleet_human() { # [login] (defaut : LCARS_LOGIN) — 0 si oui
  local login="${1:-$LCARS_LOGIN}" uid uid_min seat
  uid="$(id -u -- "$login" 2>/dev/null || true)"
  [[ "$uid" =~ ^[0-9]+$ ]] || return 1
  uid_min="$(awk '/^UID_MIN/{print $2}' "${PASSWD_DEFS:-/etc/login.defs}" 2>/dev/null | head -n1 || true)"
  [[ "$uid_min" =~ ^[0-9]+$ ]] || uid_min=1000
  seat="$(seat_uid)"
  (( uid >= uid_min )) && [[ "$uid" != "$seat" ]]
}
