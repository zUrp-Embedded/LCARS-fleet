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

# L'ELIGIBILITE DERIVE DE L'AUTORITE : membre du groupe `fleet`. La liste des humains est portee par
# la forge (team `humans`) et materialisee par le convergeur, qui ajoute chaque worker au groupe
# `fleet` (`usermod -aG fleet`). Filtrer sur le groupe, c'est lire ce que le convergeur a converge,
# au lieu de re-deviner par uid+home+shell (identite-v2). Effet de bord voulu : le sysadmin `admiral`
# (uid 1000, groupe `sudo`, PAS `fleet`) est exclu des consoles worker — il passe par ssh. Seam de
# test `LCARS_CONSOLE_GROUP_FILE`, meme idiome que `LCARS_CONSOLE_PASSWD`.
CONSOLE_GROUP="${LCARS_CONSOLE_GROUP:-fleet}"
FLEET_MEMBERS=",$(if [[ -n "${LCARS_CONSOLE_GROUP_FILE:-}" ]]; then awk -F: -v g="$CONSOLE_GROUP" '$1==g {print $4}' "$LCARS_CONSOLE_GROUP_FILE"; else getent group "$CONSOLE_GROUP" 2>/dev/null | cut -d: -f4; fi),"

# ⚠ LA LISTE DE MEMBRES DE `/etc/group` NE CONTIENT PAS LES MEMBRES PAR GROUPE PRIMAIRE, et c'est
# le piege Unix le plus vieux de ce fichier. Un compte cree `useradd -g fleet` a `fleet` pour groupe
# primaire : `id -nG` le dit membre, le champ 4 de `/etc/group` ne le nomme nulle part. Filtrer sur
# le seul champ 4, c'est donc repondre a « qui a ete AJOUTE au groupe », pas a « qui en est ».
#
# MESURE DU 2026-08-21, poste natif .63 : `lcars` (uid 1001, gid 1003 = fleet) est l'humain de fleet
# — c'est LUI qui fait tourner le BEAM et qui possede `/run/lcars/console/lcars/deck.sock`. Il etait
# absent de cette liste, donc le deck ne lisait jamais sa socket : la landing affichait « 0 pod »
# sur une fleet vivante. Aucune erreur nulle part — la seule surface ou ca se voit est un compteur
# a zero, qui est aussi ce qu'affiche une fleet reellement vide.
#
# Le gid, lui, est DEJA dans la ligne de passwd qu'on lit plus bas ; il suffisait de ne pas le
# jeter. Meme seam pour les deux formes (`LCARS_CONSOLE_GROUP_FILE`), sinon la regle serait
# epinglable a moitie.
CONSOLE_GID="$(if [[ -n "${LCARS_CONSOLE_GROUP_FILE:-}" ]]; then awk -F: -v g="$CONSOLE_GROUP" '$1==g {print $3}' "$LCARS_CONSOLE_GROUP_FILE"; else getent group "$CONSOLE_GROUP" 2>/dev/null | cut -d: -f3; fi)"

# Deux classes de rejet, et elles ne meritent PAS le meme bruit :
#   - hors plage d'uid (root, daemon, www-data, nobody…) : ATTENDU a chaque boot. Detailler 19
#     lignes de comptes systeme, c'est apprendre a l'humain a ne plus lire ses logs. → un compte.
#   - dans la plage mais inapte (pas de home, shell nologin) : SURPRENANT. C'est un humain qui
#     aurait du avoir une console et ne l'a pas. → detaille, nominativement.
system_n=0
reject_system() { system_n=$(( system_n + 1 )); }
reject_odd()    { [[ "$VERBOSE" -eq 1 ]] && echo "[humans] rejete $1 : $2" >&2; return 0; }

while IFS=: read -r login _ uid gid _ home shell; do
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
  # Membre du groupe fleet ? Sinon ce n'est pas un humain de la fleet (sysadmin admiral, compte
  # hors-fleet) : pas de console worker. C'est la garde qui derive de l'autorite, pas de l'uid seul.
  # Les deux formes d'appartenance, chacune sur sa source : le champ 4 pour l'ajout explicite
  # (`usermod -aG`, ce que fait le convergeur), le gid de la ligne passwd pour le groupe primaire
  # (`useradd -g`, ce que fait 22-fleet-human sur le rail poste).
  if [[ "$FLEET_MEMBERS" != *",$login,"* && ( -z "$CONSOLE_GID" || "$gid" != "$CONSOLE_GID" ) ]]; then
    reject_odd "$login" "hors du groupe $CONSOLE_GROUP — pas un humain converge de la fleet"
    continue
  fi

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
