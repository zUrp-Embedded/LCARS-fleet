#!/usr/bin/env bash
# SOURCE: fleet/services/supervise.sh
# AUTHOR: bob
# STARDATE: (posee par /push-github)
# STATUS: PROTO-V2 — le superviseur de la BOITE : ce que `Restart=` fait sur le rail poste
# N'essaie pas de copier : les dependances entre unites, les sockets d'activation, les cgroups, le
# `Type=notify`. Ce fichier relance un processus, c'est tout — et l'ecrire ainsi est deliberer : un
# demi-systemd serait un objet dont personne ne connaitrait les limites.

set -uo pipefail

NAME=""
LOG=""
BURST="${LCARS_SUPERVISE_BURST:-5}"
INTERVAL="${LCARS_SUPERVISE_INTERVAL:-60}"
DELAY="${LCARS_SUPERVISE_DELAY:-10}"
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
# TERM, un DELAI DE GRACE, puis KILL. C'est ce que fait tout gestionnaire de services, et c'est le
# minimum pour que « arreter » veuille dire arreter.
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
