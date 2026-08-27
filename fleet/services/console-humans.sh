#!/usr/bin/env bash
# SOURCE: fleet/services/console-humans.sh
# AUTHOR: consultant
# STARDATE: 2026-07-31
# STATUS: enumeration des humains eligibles a une console — source UNIQUE de la regle
#
# La forge decide QUI est un humain (team `humans`), `human-converger.sh` en derive les comptes
# Unix, et ce script repond a la seule question restante : lesquels recoivent une console ICI.
# Ses consommateurs l'appellent au lieu de refiltrer `/etc/passwd`.
#
# LE SIEGE EN FAIT PARTIE : sa console tourne sous son uid, donc sudo-capable, comme son terminal
# ssh. Ce qui lui reste ferme est la FLEET — le BEAM herite de l'uid du lanceur et ses pods avec,
# et GUARD B l'y refuse. Deux questions, deux gardes.
#
# USAGE  : console-humans.sh            → une ligne par humain : « login uid home »
#          console-humans.sh --verbose  → + les rejets sur stderr, avec leur motif
# EXIT   : 0 toujours (une liste vide est un resultat, pas une erreur)

set -uo pipefail

VERBOSE=0
[[ "${1:-}" == "--verbose" ]] && VERBOSE=1

# LES BORNES SE LISENT, ELLES NE SE DEVINENT PAS. `/etc/login.defs` les DECLARE, `useradd` les lit,
# et trois autres lecteurs de ce depot les lisent la aussi (`fleet_v2`, `human-converger`,
# `provision-lib`). Un litteral ici en ferait une quatrieme copie, fausse sur toute machine dont
# l'administrateur a bouge la frontiere.
#
# ⚠ ET LE DEFAUT SERAIT FAIL-OPEN, contrairement a celui de `fleet_v2`. La-bas, retomber sur 1000
# REFUSE davantage : c'est conservateur. Ici, la borne decide qui RECOIT une console — un UID_MIN
# reel a 2000 devine a 1000 ouvre un shell web a tout ce qui vit entre les deux. Bornes illisibles :
# on ne rend aucune liste, et on le dit.
DEFS="${PASSWD_DEFS:-/etc/login.defs}"
UID_MIN="$(awk '/^UID_MIN/ {print $2}' "$DEFS" 2>/dev/null | head -n1 || true)"
UID_MAX="$(awk '/^UID_MAX/ {print $2}' "$DEFS" 2>/dev/null | head -n1 || true)"
if ! [[ "$UID_MIN" =~ ^[0-9]+$ && "$UID_MAX" =~ ^[0-9]+$ ]]; then
  echo "[humans] bornes d'uid illisibles ($DEFS) — la frontiere systeme/humain n'est pas etablie, aucune liste rendue" >&2
  exit 0
fi

# Deux classes de rejet, deux volumes de bruit : hors plage est attendu a chaque boot (un compte),
# inapte dans la plage est surprenant — un humain qui aurait du avoir une console (nominatif).
system_n=0
reject_system() { system_n=$(( system_n + 1 )); }
reject_odd()    { [[ "$VERBOSE" -eq 1 ]] && echo "[humans] rejete $1 : $2" >&2; return 0; }

# Le gid est ignore : `/etc/group` ne liste pas les membres par groupe PRIMAIRE, donc un filtre de
# groupe manque en silence les comptes crees `useradd -g <groupe>`.
while IFS=: read -r login _ uid _ _ home shell; do
  [[ -n "$login" ]] || continue

  # root n'a pas de console : ce serait un shell root derriere la porte web de la boite.
  if [[ "$uid" -lt "$UID_MIN" ]]; then reject_system; continue; fi
  # `nobody` (65534) est au-dessus de la plage humaine et n'est pas un humain.
  if [[ "$uid" -gt "$UID_MAX" ]]; then reject_system; continue; fi
  if [[ ! -d "$home" ]]; then
    reject_odd "$login" "home absent ($home) — une console sans home s'ouvre sur / et ment"
    continue
  fi
  case "$shell" in
    */nologin|*/false|"")
      reject_odd "$login" "shell $shell — le compte n'est pas fait pour ouvrir un shell"
      continue ;;
  esac

  # Le home est emis parce qu'il vient d'etre verifie : le consommateur n'a pas a le re-deriver.
  printf '%s %s %s\n' "$login" "$uid" "$home"
  # `LCARS_CONSOLE_PASSWD` est la couture des temoins ; `getent` est le defaut et couvre NSS.
done < <(if [[ -n "${LCARS_CONSOLE_PASSWD:-}" ]]; then cat "$LCARS_CONSOLE_PASSWD"; else getent passwd; fi)

# Un compte, pas dix-neuf lignes : la garde a tourne, sans noyer le rejet qui merite d'etre lu.
[[ "$VERBOSE" -eq 1 && "$system_n" -gt 0 ]] && \
  echo "[humans] $system_n comptes systeme ecartes (uid hors [$UID_MIN..$UID_MAX] — dont root, qui n'a pas de console)" >&2

exit 0
