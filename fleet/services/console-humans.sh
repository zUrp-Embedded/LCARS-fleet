#!/usr/bin/env bash
# SOURCE: fleet/services/console-humans.sh
# AUTHOR: consultant
# STARDATE: 2026-07-31
# STATUS: enumeration des humains eligibles a une console — source UNIQUE de la regle
#
# La forge decide QUI est un humain (team `humans`), `human-converger.sh` en derive les comptes
# Unix, et ce script repond a la seule question restante : lesquels recoivent une console ICI.
#
# EXIT 0 TOUJOURS : une liste vide est un resultat, pas une erreur.

set -uo pipefail          # PAS -e : ce script rend TOUJOURS 0 (cf. en-tete) — une liste vide est
                          # un resultat, et `-e` la transformerait en panne.

VERBOSE=0
[[ "${1:-}" == "--verbose" ]] && VERBOSE=1

# ⚠ AUCUN DEFAUT SUR CES BORNES, PARCE QU'IL SERAIT FAIL-OPEN : elles decident qui RECOIT une
# console, et un UID_MIN reel a 2000 devine a 1000 ouvre un shell web a tout ce qui vit entre les
# deux. Illisibles, on ne rend aucune liste et on le dit.
DEFS="${PASSWD_DEFS:-/etc/login.defs}"
UID_MIN="$(awk '/^UID_MIN/ {print $2}' "$DEFS" 2>/dev/null | head -n1 || true)"
UID_MAX="$(awk '/^UID_MAX/ {print $2}' "$DEFS" 2>/dev/null | head -n1 || true)"
if ! [[ "$UID_MIN" =~ ^[0-9]+$ && "$UID_MAX" =~ ^[0-9]+$ ]]; then
  echo "[humans] bornes d'uid illisibles ($DEFS) — la frontiere systeme/humain n'est pas etablie, aucune liste rendue" >&2
  exit 0
fi

# Hors plage est attendu a chaque boot, donc compte ; inapte DANS la plage est surprenant, donc nomme.
system_n=0
reject_system() { system_n=$(( system_n + 1 )); }
reject_odd()    { [[ "$VERBOSE" -eq 1 ]] && echo "[humans] rejete $1 : $2" >&2; return 0; }

# ⚠ AUCUN FILTRE DE GROUPE : `/etc/group` ne liste pas les membres par groupe PRIMAIRE, donc un tel
# filtre manquerait EN SILENCE les comptes crees `useradd -g <groupe>`.
while IFS=: read -r login _ uid _ _ home shell; do
  [[ -n "$login" ]] || continue

  if [[ "$uid" -lt "$UID_MIN" ]]; then reject_system; continue; fi
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

  printf '%s %s %s\n' "$login" "$uid" "$home"
  # `LCARS_CONSOLE_PASSWD` est la couture des temoins ; `getent` est le defaut et couvre NSS.
done < <(if [[ -n "${LCARS_CONSOLE_PASSWD:-}" ]]; then cat "$LCARS_CONSOLE_PASSWD"; else getent passwd; fi)

[[ "$VERBOSE" -eq 1 && "$system_n" -gt 0 ]] && \
  echo "[humans] $system_n comptes systeme ecartes (uid hors [$UID_MIN..$UID_MAX] — dont root, qui n'a pas de console)" >&2

exit 0
