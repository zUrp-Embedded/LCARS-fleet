#!/usr/bin/env bash
# SOURCE: fleet/services/console-humans.sh
# AUTHOR: consultant
# STARDATE: 2026-07-31
# STATUS: enumeration des humains eligibles a une console — source UNIQUE de la regle
#
# La regle « qui recoit une console sur cette boite » vit ICI et nulle part ailleurs : une copie chez
# un appelant derive le jour ou on corrige l'original, et une garde qui derive est pire qu'absente.
#
# CE FICHIER NE DECIDE PAS QUI EST UN HUMAIN. La forge le decide (team `humans` de l'org),
# `human-converger.sh` en derive les comptes Unix, et ce script repond a la question suivante :
# lesquels de ces comptes peuvent recevoir une console ICI. Un compte que la forge ne connait plus
# arrive deja revoque — shell `nologin` — et le filtre le rejette pour cette raison-la.
#
# PLANCHER ET PLAFOND D'UID : un compte systeme n'a pas de console, et `nobody` (65534) n'est pas un
# humain. Convention Debian, < 1000 = systeme.
#
# USAGE  : console-humans.sh            → une ligne par humain : « login uid home »
#          console-humans.sh --verbose  → + les rejets sur stderr, avec leur motif
# EXIT   : 0 toujours (une liste vide est un resultat, pas une erreur)

set -uo pipefail

VERBOSE=0
[[ "${1:-}" == "--verbose" ]] && VERBOSE=1

UID_MIN="${LCARS_CONSOLE_UID_MIN:-1000}"
UID_MAX="${LCARS_CONSOLE_UID_MAX:-59999}"

# ─── L'ELIGIBILITE EST LOCALE, ET ELLE NE LIT AUCUN GROUPE ─────────────────────────────────────
#
# Trois faits, tous lisibles sur la ligne de `passwd` qu'on parcourt : un uid dans la plage humaine,
# un home qui existe, un shell qui n'est pas `nologin`. Rien d'autre — et surtout aucune adhesion de
# groupe : `/etc/group` ne liste pas les membres par groupe PRIMAIRE, donc filtrer dessus manque
# silencieusement les comptes crees `useradd -g fleet`.
#
# LE SIEGE EN FAIT PARTIE. Il tient la machine, il a un home et un shell : il a une console comme
# tout humain d'ici, servie sous SON uid — donc sudo-capable, exactement comme son terminal ssh, et
# derriere une porte qui exige une session de la forge. Ce qui lui reste ferme n'est pas le shell
# mais la FLEET : le BEAM herite de l'uid du lanceur et ses pods avec, donc GUARD B refuse
# `fleet_v2 start` sous le siege. Deux questions distinctes, deux gardes distinctes.


# Deux classes de rejet, et elles ne meritent PAS le meme bruit :
#   - hors plage d'uid (root, daemon, www-data, nobody…) : ATTENDU a chaque boot. Detailler 19
#     lignes de comptes systeme, c'est apprendre a l'humain a ne plus lire ses logs. → un compte.
#   - dans la plage mais inapte (pas de home, shell nologin) : SURPRENANT. C'est un humain qui
#     aurait du avoir une console et ne l'a pas. → detaille, nominativement.
system_n=0
reject_system() { system_n=$(( system_n + 1 )); }
reject_odd()    { [[ "$VERBOSE" -eq 1 ]] && echo "[humans] rejete $1 : $2" >&2; return 0; }

# Le gid n'est plus lu : l'eligibilite ne regarde plus aucun groupe. `_` a la place, pour que la
# forme de la ligne de passwd reste lisible telle qu'elle est.
while IFS=: read -r login _ uid _ _ home shell; do
  [[ -n "$login" ]] || continue

  if [[ "$uid" -lt "$UID_MIN" ]]; then
    # Le cas qui compte : root. Une console de root serait un shell root ouvert derriere la porte
    # web de la boite — c'est la raison, et elle ne depend d'aucune arithmetique de ports.
    reject_system
    continue
  fi
  if [[ "$uid" -gt "$UID_MAX" ]]; then
    reject_system
    continue
  fi
  if [[ ! -d "$home" ]]; then
    reject_odd "$login" "home absent ($home) — une console sans home s'ouvre sur / et ment"
    continue
  fi
  case "$shell" in
    */nologin|*/false|"")
      reject_odd "$login" "shell $shell — le compte n'est pas fait pour ouvrir un shell"
      continue ;;
  esac

  # LA TROISIEME COLONNE A CHANGE DE NATURE, elle n'a pas ete « remise ». Elle portait
  # `21000 + (uid % 500) * 10` — le bloc de ports de cet humain, dont le seul lecteur le jetait, et
  # dont la formule a quitte la boite le 2026-08-14. Elle porte maintenant le HOME, c'est-a-dire
  # exactement ce que la garde du dessus vient de verifier. Emettre un fait deja etabli evite au
  # consommateur de le re-deriver, et c'est cette re-derivation qui avait fabrique une seconde
  # regle dans le deck.
  printf '%s %s %s\n' "$login" "$uid" "$home"
  # MEME SEAM QUE `human-converger.sh` (`PASSWD_FILE`), ET POUR LA MEME RAISON : cette regle decide
  # qui recoit une console, donc elle doit etre epinglable sans fabriquer des comptes Unix sur la
  # machine qui fait tourner les tests. `getent` reste le defaut — il couvre NSS, la ou un `cat`
  # de /etc/passwd ne verrait que les comptes locaux.
done < <(if [[ -n "${LCARS_CONSOLE_PASSWD:-}" ]]; then cat "$LCARS_CONSOLE_PASSWD"; else getent passwd; fi)

# Une ligne, pas dix-neuf : le compte des rejets attendus prouve que la garde a tourne, sans
# noyer le seul rejet qui meriterait qu'on le lise.
[[ "$VERBOSE" -eq 1 && "$system_n" -gt 0 ]] && \
  echo "[humans] $system_n comptes systeme ecartes (uid hors [$UID_MIN..$UID_MAX] — dont root, qui n'a pas de console)" >&2

exit 0
