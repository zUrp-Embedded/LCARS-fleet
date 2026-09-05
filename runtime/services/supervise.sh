#!/usr/bin/env bash
# SOURCE: runtime/services/supervise.sh
# AUTHOR: bob
# STARDATE: (posee par /push-github)
# STATUS: PROTO-V2 — le superviseur de la BOITE : ce que `Restart=` fait sur le rail poste
# N'essaie PAS de copier les dependances entre unites, les sockets d'activation, les cgroups ni le
# `Type=notify` : ce fichier relance un processus, c'est tout. Un demi-systemd serait un objet dont
# personne ne connaitrait les limites.

set -uo pipefail          # PAS -e : ce script SURVIT a l'echec de ce qu'il supervise — c'est son
                          # travail. `-e` le tuerait au premier plantage du processus relance,
                          # c'est-a-dire exactement quand il sert.

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

for _n in BURST:1 INTERVAL:1 DELAY:0 GRACE:0; do
  _var="${_n%%:*}"; _min="${_n##*:}"; _val="${!_var}"
  [[ "$_val" =~ ^[0-9]+$ ]] \
    || { echo "supervise.sh: --${_var,,} attend un entier, reçu « $_val »" >&2; exit 2; }
  (( _val >= _min )) \
    || { echo "supervise.sh: --${_var,,} doit être >= $_min (reçu $_val) — en dessous, la borne ne peut plus mordre" >&2; exit 2; }
done
unset _n _var _min _val

# ⚠ JAMAIS DANS LE VIDE : un superviseur muet fait voir a l'operateur un processus sain, la ou le
# service revient vingt fois par minute et ou la cause disparait avec lui.
say() {
  local line; line="[$(date -Is 2>/dev/null || echo '?')] supervise($NAME): $*"
  if [[ -n "$LOG" ]]; then printf '%s\n' "$line" >> "$LOG" 2>/dev/null || printf '%s\n' "$line" >&2
  else printf '%s\n' "$line" >&2
  fi
}

# ⚠ CE QUE CE FICHIER NE FERME PAS : les PETITS-enfants. Un enfant qui forke avant de mourir laisse
# sa descendance, et l'attraper demanderait un groupe de processus ou un cgroup. Poser un `setsid`
# ici rendrait `wait` FAUX — setsid forke, donc `$!` cesse d'etre le vrai enfant — pour un resultat
# partiel. On ferme le cas mesure, on nomme celui qu'on ne ferme pas.
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

starts=()

while true; do
  now="$SECONDS"
  kept=()
  for t in ${starts[@]+"${starts[@]}"}; do
    (( now - t < INTERVAL )) && kept+=("$t")
  done
  starts=(${kept[@]+"${kept[@]}"})

  if (( ${#starts[@]} >= BURST )); then
    say "ABANDON — ${#starts[@]} demarrages en moins de ${INTERVAL}s (borne : $BURST). Le service ne sera PAS relance : une boucle d'echec instantane brule un coeur et remplit le disque. Repare la cause, puis « container restart »."
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

  say "sorti (rc=$rc) — relance dans ${DELAY}s"
  # ⚠ PAS DE `sleep "$DELAY"` NU : bash n'execute une trap qu'ENTRE deux commandes, donc un TERM
  # recu pendant un `sleep` externe attend que celui-ci finisse de lui-meme. En arriere-plan +
  # `wait`, la trap part immediatement. Le `kill` d'apres ramasse le dormeur si on sort par la trap.
  if (( DELAY > 0 )); then
    sleep "$DELAY" & _sleeper=$!
    wait "$_sleeper" 2>/dev/null || true
    kill "$_sleeper" 2>/dev/null || true
  fi
  [[ "$stopping" -eq 1 ]] && { say "arret demande pendant l'attente — on ne relance pas"; exit 0; }
done
