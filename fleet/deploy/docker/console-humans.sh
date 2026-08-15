#!/usr/bin/env bash
# SOURCE: fleet/deploy/docker/console-humans.sh
# AUTHOR: consultant
# STARDATE: 2026-07-31
# STATUS: enumeration des humains eligibles a une console — source UNIQUE de la regle
#
# POURQUOI UN FICHIER A LUI SEUL : la regle « qui est un humain de cette boite » sert a decider qui
# recoit une console. La recopier chez l'appelant, c'est garantir qu'une des deux copies derive le
# jour ou on la corrige — et une garde qui derive est pire qu'une garde absente, parce qu'on croit
# l'avoir.
#
# ─── LA GARDE ANTI-SYSTEME, ET SON MOTIF A CHANGE ───────────────────────────────────────────────
# Elle s'est longtemps justifiee par une COLLISION DE BLOCS : le bloc de ports valait
# `21000 + (uid % 500) * 10`, donc uid 0 et uid 1000 tombaient sur le meme 21000. Cette collision
# n'existe plus — il n'y a plus de bloc de ports du tout, les consoles vivent sur des sockets
# AF_UNIX par humain. Le motif est mort ; LA GARDE, ELLE, RESTE JUSTE, pour une raison qui ne
# dependait pas de lui : **un compte systeme n'a pas de console.** Ce n'est pas une question de
# numero, c'est ce qu'est un compte systeme.
#
# C'est donc un PLANCHER D'UID, et pas un test de modulo — lequel rejetterait uid 1000, l'humain
# nominal. Convention Debian : < 1000 = systeme. Et 65534 (`nobody`) est au-dessus mais n'est pas
# un humain non plus, d'ou le plafond.
#
# ─── ET CE FICHIER N'EST PAS LA SOURCE : IL EN EST LA DERIVATION ────────────────────────────────
# La liste des humains est portee par LA FORGE (la team `humans` de l'org), et `human-converger.sh`
# en derive les comptes Unix. Ce script ne decide donc pas QUI est un humain : il repond « lesquels
# de ces comptes peuvent recevoir une console sur CETTE boite », ce qui est une question de siege,
# pas d'identite. Un compte que la forge ne connait plus est deja revoque quand on arrive ici
# (retire du groupe, shell `nologin`), et le filtre ci-dessous le rejette pour cette raison-la.
#
# Il reste la source UNIQUE de cette regle-ci, et c'est ce que ses consommateurs doivent appeler
# plutot que de refaire un filtre sur `/etc/passwd`. Le deck en portait un second, avec des bornes
# differentes : il listait un humain SANS home, donc un siege dont aucune console n'avait jamais ete
# demarree — exactement la page « cette console ne fonctionne pas » que le convergeur documente.
#
# USAGE  : console-humans.sh            → une ligne par humain : « login uid home »
#          console-humans.sh --verbose  → + les rejets sur stderr, avec leur motif
# EXIT   : 0 toujours (une liste vide est un resultat, pas une erreur)

set -uo pipefail

VERBOSE=0
[[ "${1:-}" == "--verbose" ]] && VERBOSE=1

UID_MIN="${LCARS_CONSOLE_UID_MIN:-1000}"
UID_MAX="${LCARS_CONSOLE_UID_MAX:-59999}"

# Deux classes de rejet, et elles ne meritent PAS le meme bruit :
#   - hors plage d'uid (root, daemon, www-data, nobody…) : ATTENDU a chaque boot. Detailler 19
#     lignes de comptes systeme, c'est apprendre a l'humain a ne plus lire ses logs. → un compte.
#   - dans la plage mais inapte (pas de home, shell nologin) : SURPRENANT. C'est un humain qui
#     aurait du avoir une console et ne l'a pas. → detaille, nominativement.
system_n=0
reject_system() { system_n=$(( system_n + 1 )); }
reject_odd()    { [[ "$VERBOSE" -eq 1 ]] && echo "[humans] rejete $1 : $2" >&2; return 0; }

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
