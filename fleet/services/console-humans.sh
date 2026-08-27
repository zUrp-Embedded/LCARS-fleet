#!/usr/bin/env bash
# SOURCE: fleet/services/console-humans.sh
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

# ─── L'ELIGIBILITE EST UNE CONDITION DE SIEGE, ELLE N'EST PLUS UNE ADHESION DE GROUPE ───────────
#
# ⚠ CETTE REGLE DISAIT « L'ELIGIBILITE DERIVE DE L'AUTORITE : membre du groupe `fleet` », ET ELLE
# NOMMAIT AUTORITE UNE COMMODITE. Le groupe etait une PROJECTION : le convergeur y ajoutait chaque
# membre de l'equipe `humans` de la forge, toutes les trente secondes. Filtrer dessus, c'etait lire
# un cache — pratique, et sans rapport avec la question posee ici, qui est « cette personne a-t-elle
# un siege de travail sur cette machine ».
#
# Le groupe n'ouvre plus rien depuis ce chantier : ni les jetons de forge, ni root. En faire la
# derniere lecture survivante de `/etc/group` en aurait fait celle dont plus personne ne sait ce
# qu'elle decide.
#
# ⚠ ET L'EXCLUSION DU SIEGE ETAIT UN EFFET DE BORD, PAS UNE REGLE. Elle tenait parce que le sysadmin
# (uid 1000) est dans `sudo` et pas dans `fleet` — une console worker pour lui aurait ete un shell
# sudo-capable derriere la porte web de la boite. Elle devient une CONDITION ECRITE, keyee sur
# l'UID : la meme cle que GUARD A/B et que le miroir BEAM de `runtime.exs`, jamais un login (`00` §5
# — le login du siege est variable, l'uid est la reservation). Un effet de bord non nomme est
# exactement ce qui disparait sans que personne le voie.
#
# ⚠ DEUX PIEGES DISPARAISSENT AVEC LE FILTRE, ET ILS VALENT D'ETRE SUS. La liste de membres de
# `/etc/group` ne contient PAS les membres par groupe PRIMAIRE : un compte cree `useradd -g fleet`
# n'y figure nulle part, alors que `id -nG` le dit membre. Mesure du 2026-08-21 : `lcars`, l'humain
# qui FAIT TOURNER LE BEAM, etait absent de cette liste — le deck ne lisait jamais sa socket et la
# landing affichait « 0 pod » sur une fleet vivante. Aucune erreur nulle part : la seule surface ou
# ca se voyait etait un compteur a zero, qui est aussi ce qu'affiche une fleet reellement vide.
# Il fallait donc lire DEUX sources pour une seule question. Il n'y en a plus aucune.
#
# CE QUI DECIDE MAINTENANT, ET RIEN D'AUTRE : un uid dans la plage humaine, un home qui existe, un
# shell qui n'est pas `nologin`, et ce n'est pas le siege. Quatre faits LOCAUX, tous lisibles sur la
# ligne de passwd qu'on parcourt — et aucun n'a de peremption.
# ⚠ PAS DE `:-1000`. Le siege est l'uid de qui a installe LCARS, grave en `/etc/lcars/seat.uid` : un
# defaut ferait entrer le siege dans la liste des humains des qu'il est ailleurs, et le deck lui
# offrirait une console. Sans siege etabli, on ne rend AUCUNE liste — une liste fausse se lit comme
# une population.
SEAT_UID_FILE="${LCARS_SEAT_UID_FILE:-/etc/lcars/seat.uid}"
SYSADMIN_UID="$(head -n1 -- "$SEAT_UID_FILE" 2>/dev/null | tr -d '[:space:]' || true)"
[[ "$SYSADMIN_UID" =~ ^[0-9]+$ ]] || SYSADMIN_UID="${LCARS_SYSADMIN_UID:-}"


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
  # ⚠ LE SIEGE N'A PAS DE CONSOLE WORKER, ET C'EST UNE CONDITION, PLUS UN EFFET DE BORD. Le sysadmin
  # est sudo-capable : lui ouvrir une console worker mettrait un shell root-capable derriere la porte
  # WEB de la boite — l'exact inverse de ce que les pods confinent. Il passe par ssh.
  #
  # Keye sur l'UID (`00` §5) : le login du siege est VARIABLE — `admiral` sur banc, celui que
  # l'installeur a cree en prod — et l'uid est la reservation. La meme cle que GUARD A/B et que le
  # miroir BEAM ; un nom aurait fait une seconde verite sur une question qui n'en a qu'une.
  if [[ "$uid" == "$SYSADMIN_UID" ]]; then
    reject_odd "$login" "siege de la machine (uid $SYSADMIN_UID) — sudo-capable, il passe par ssh, jamais par une console worker"
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
