#!/usr/bin/env bash
# SOURCE: fleet/services/supervise.sh
# AUTHOR: bob
# STARDATE: (posee par /push-github)
# STATUS: PROTO-V2 — le superviseur de la BOITE : ce que `Restart=` fait sur le rail poste
#
# ─── POURQUOI CE FICHIER EXISTE ─────────────────────────────────────────────────────────────────
#
# ⚠ RIEN NE RELANCAIT UN SERVICE MORT DANS LA BOITE. Mesure du 2026-08-26, comparaison des deux
# rails :
#
#   rail poste   `64-services` pose des unites systemd : `Restart=always`, `RestartSec=10`,
#                `StartLimitBurst=5`, `StartLimitIntervalSec=60`. Un service qui tombe revient.
#   rail boite   `entrypoint.sh` lance `setsid <cmd> &` et passe a la suite. tini est PID 1 et
#                RECOLTE les orphelins — il n'en relance aucun.
#
# Un convergeur d'humains qui meurt dans la boite reste mort jusqu'au prochain `box restart`, et
# personne ne le sait : la boite reste *healthy* (son healthcheck ne sonde que des ports : ssh + le deck). Le rail poste
# testait donc des politiques de redemarrage que la PRODUCTION n'avait pas, et la production avait
# un mode de panne que rien ne testait — l'asymetrie exactement a l'envers de ce qu'on veut.
#
# ⚠ ET IL NE PEUT PAS VIVRE DANS L'ENTRYPOINT. Celui-ci finit sur `exec /usr/sbin/sshd -D -e` : le
# shell est REMPLACE, donc toute boucle qu'il porterait disparait a cet instant. Le superviseur est
# donc un processus a part, lance en `setsid`, qui survit a l'exec comme les services d'aujourd'hui.
#
# ─── CE QU'IL COPIE DE SYSTEMD, ET CE QU'IL N'ESSAIE PAS DE COPIER ──────────────────────────────
#
# Copie : la relance, le delai entre deux essais, et la BORNE — N relances dans une fenetre de S
# secondes, puis abandon bruyant. La borne n'est pas un detail : sans elle, un service qui echoue
# instantanement (fichier absent, port pris) tourne en boucle a 100 % d'un coeur et remplit un
# disque de journaux. C'est ce que `StartLimitBurst` existe pour empecher, et la raison pour
# laquelle `64-services` le pose deja sur ses unites.
#
# N'essaie pas de copier : les dependances entre unites, les sockets d'activation, les cgroups, le
# `Type=notify`. Ce fichier relance un processus, c'est tout — et l'ecrire ainsi est deliberer : un
# demi-systemd serait un objet dont personne ne connaitrait les limites.
#
# ⚠ IL N'EST PAS UTILISE SUR LE RAIL POSTE, ET IL Y EST POSE QUAND MEME. `62-runtime-helpers` pose
# tous les auxiliaires sur les deux rails — c'est la regle, et le mur de correspondance avec l'image
# l'exige. Sur un poste, systemd fait ce travail ; ce fichier y dort. Le poser des deux cotes coute
# un fichier ; ne le poser que d'un cote rouvrirait la divergence de mecanisme que ce lot ferme.

set -uo pipefail

NAME=""
LOG=""
BURST="${LCARS_SUPERVISE_BURST:-5}"
INTERVAL="${LCARS_SUPERVISE_INTERVAL:-60}"
DELAY="${LCARS_SUPERVISE_DELAY:-10}"
# ⚠ TOUS LES DEFAUTS SONT ICI, AVANT LE PARSEUR, ET `GRACE` NE L'ETAIT PAS. Il etait pose plus bas,
# a cote de la trap qui l'utilise — donc APRES la boucle qui lit `--grace`, qui l'ecrasait aussitot.
# Le drapeau existait, se parsait, et n'avait aucun effet. Un reglage inerte est pire qu'un reglage
# absent : on croit avoir regle quelque chose. Trouve en essayant de mesurer la garde qu'il commande.
GRACE="${LCARS_SUPERVISE_GRACE:-5}"

usage() {
  echo "usage: supervise.sh --name <nom> [--log <fichier>] [--burst N] [--interval S] [--delay S] [--grace S] -- <cmd...>" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)     NAME="${2:?--name attend un nom}"; shift 2 ;;
    --log)      LOG="${2:?--log attend un chemin}"; shift 2 ;;
    --burst)    BURST="${2:?--burst attend un nombre}"; shift 2 ;;
    --interval) INTERVAL="${2:?--interval attend des secondes}"; shift 2 ;;
    --delay)    DELAY="${2:?--delay attend des secondes}"; shift 2 ;;
    --grace)    GRACE="${2:?--grace attend des secondes}"; shift 2 ;;
    --)         shift; break ;;
    *)          usage ;;
  esac
done

[[ -n "$NAME" ]] || usage
[[ $# -gt 0 ]] || usage

# ⚠ LES TROIS NOMBRES SE VALIDENT, ET L'UN D'EUX RENDAIT LA BORNE INOPERANTE. `--interval 0` :
# la fenetre glissante purge sur `(( now - t < INTERVAL ))`, donc `< 0`, donc TOUJOURS faux — le
# tableau `starts` restait vide, `${#starts[@]} >= BURST` n'etait jamais vrai, et la boucle tournait
# sans fin a 100 % d'un coeur. C'est-a-dire EXACTEMENT le mode de panne que ce fichier existe pour
# empecher, atteint par son propre reglage. Mesure du 2026-08-26 : 130 Ko de journal en cinq
# secondes avant que le timeout du temoin l'arrete.
#
# `--delay abc` avait la meme forme en plus doux : `sleep` refusait, la boucle continuait SANS
# delai — une borne desarmee par une faute de frappe.
#
# Un reglage qui desarme la garde est refuse a l'entree, bruyamment. `INTERVAL` exige au moins 1 :
# une fenetre de zero seconde n'est pas une fenetre.
for _n in BURST:1 INTERVAL:1 DELAY:0 GRACE:0; do
  _var="${_n%%:*}"; _min="${_n##*:}"; _val="${!_var}"
  [[ "$_val" =~ ^[0-9]+$ ]] \
    || { echo "supervise.sh: --${_var,,} attend un entier, reçu « $_val »" >&2; exit 2; }
  (( _val >= _min )) \
    || { echo "supervise.sh: --${_var,,} doit être >= $_min (reçu $_val) — en dessous, la borne ne peut plus mordre" >&2; exit 2; }
done
unset _n _var _min _val

# ⚠ LA TRACE VA SUR STDERR PAR DEFAUT, JAMAIS DANS LE VIDE. Un superviseur muet est pire qu'aucun
# superviseur : le service revient, la cause disparait, et l'operateur voit un processus sain qui
# est en fait relance vingt fois par minute. `--log` sert quand l'appelant a deja choisi un fichier.
say() {
  local line; line="[$(date -Is 2>/dev/null || echo '?')] supervise($NAME): $*"
  if [[ -n "$LOG" ]]; then printf '%s\n' "$line" >> "$LOG" 2>/dev/null || printf '%s\n' "$line" >&2
  else printf '%s\n' "$line" >&2
  fi
}

# ⚠ LE SIGNAL SE PROPAGE A L'ENFANT, SINON UN `box down` LAISSE UN ORPHELIN. Le superviseur est le
# parent : sans ce piege, il meurt et son enfant reste, rattache a PID 1, hors de portee de tout.
# ⚠ ET TERM NE SUFFIT PAS : UN ENFANT PEUT L'IGNORER. Mesure du 2026-08-26 avec
# `bash -c "trap '' TERM; sleep 60"` : le superviseur relayait TERM, l'enfant n'en faisait rien, le
# superviseur sortait 0 — et l'enfant restait, rattache a PID 1, hors de portee de tout. Un
# `box down` laissait donc un processus vivant dans le conteneur.
#
# TERM, un DELAI DE GRACE, puis KILL. C'est ce que fait tout gestionnaire de services, et c'est le
# minimum pour que « arreter » veuille dire arreter.
#
# ⚠ CE QUE CE FICHIER NE FERME PAS, ET NE PRETENDRA PAS FERMER : les PETITS-enfants. Un enfant qui
# forke avant de mourir laisse sa descendance ; l'attraper demande un groupe de processus ou un
# cgroup, et systemd ne le fait proprement que parce qu'il a les cgroups. Poser un `setsid` ici
# rendrait `wait` faux (setsid forke, donc `$!` cesse d'etre le vrai enfant) pour un resultat
# partiel. On ferme le cas mesure, on NOMME celui qu'on ne ferme pas — un demi-systemd dont
# personne ne connaitrait les limites serait pire que cette phrase.
child=0
stopping=0
relay() {
  stopping=1
  [[ "$child" -eq 0 ]] && return 0
  kill -TERM "$child" 2>/dev/null || true
  local i=0
  while (( i < GRACE )) && kill -0 "$child" 2>/dev/null; do sleep 1; i=$(( i + 1 )); done
  if kill -0 "$child" 2>/dev/null; then
    say "l'enfant ($child) a ignore TERM pendant ${GRACE}s — KILL"
    kill -KILL "$child" 2>/dev/null || true
  fi
}
trap relay TERM INT

# La fenetre glissante des demarrages, en horodatages. On ne garde que ce qui est DANS la fenetre :
# un compteur nu ne saurait pas oublier, et un service qui tombe une fois par jour finirait par
# atteindre la borne au bout d'une semaine — donc par abandonner sur une machine parfaitement saine.
starts=()

while true; do
  now="$SECONDS"
  # On purge d'abord : la fenetre est relative a MAINTENANT, pas au premier demarrage.
  kept=()
  for t in ${starts[@]+"${starts[@]}"}; do
    (( now - t < INTERVAL )) && kept+=("$t")
  done
  starts=(${kept[@]+"${kept[@]}"})

  if (( ${#starts[@]} >= BURST )); then
    say "ABANDON — ${#starts[@]} demarrages en moins de ${INTERVAL}s (borne : $BURST). Le service ne sera PAS relance : une boucle d'echec instantane brule un coeur et remplit le disque. Repare la cause, puis « box restart »."
    exit 1
  fi

  starts+=("$now")
  "$@" &
  child=$!
  rc=0
  wait "$child" || rc=$?
  child=0

  if [[ "$stopping" -eq 1 ]]; then
    say "arret demande — l'enfant a recu TERM, on ne relance pas"
    exit 0
  fi

  # ⚠ UN RC 0 EST UNE MORT COMME UNE AUTRE ICI, et c'est voulu : ces services sont des BOUCLES.
  # `Restart=always` de systemd dit la meme chose — un convergeur qui « se termine proprement » a
  # quand meme cesse de converger. Distinguer les deux ferait taire exactement le cas ou un service
  # sort en 0 sur une erreur qu'il a mal classee.
  say "sorti (rc=$rc) — relance dans ${DELAY}s"
  # ⚠ `sleep "$DELAY"` NU RETARDE LE SIGNAL DE TOUT SON DELAI. Bash n'execute une trap qu'entre deux
  # commandes : un TERM recu PENDANT un `sleep` externe attend que le `sleep` finisse de lui-meme.
  # Mesure du 2026-08-26 avec `--delay 5` : le superviseur mettait 4 s a mourir. Avec le defaut de
  # 10 s et trois services supervises, un `box down` payait ca a chaque fois.
  #
  # En arriere-plan + `wait`, la trap s'execute IMMEDIATEMENT — `wait` est interruptible, un `sleep`
  # au premier plan ne l'est pas. Le `kill` d'apres ramasse le dormeur si on sort par la trap.
  if (( DELAY > 0 )); then
    sleep "$DELAY" & _sleeper=$!
    wait "$_sleeper" 2>/dev/null || true
    kill "$_sleeper" 2>/dev/null || true
  fi
  # La trap a pu tomber pendant l'attente : on ne relance pas ce qu'on vient d'arreter.
  [[ "$stopping" -eq 1 ]] && { say "arret demande pendant l'attente — on ne relance pas"; exit 0; }
done
