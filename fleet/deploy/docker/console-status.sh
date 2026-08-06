#!/usr/bin/env bash
# SOURCE: fleet/deploy/docker/console-status.sh
# AUTHOR: consultant
# STARDATE: 2026-07-31
# STATUS: sonde une-ligne de l'etat fleet, pour la barre de statut tmux de la console
#
# POURQUOI PAS `fleet_v2 status` DIRECTEMENT : il commence par `cmd_version`, qui retombe sur
# `git -C "$RUNTIME_DIR" status --porcelain` quand build_info.txt manque (fleet_v2:344). Un
# `git status` toutes les 15 s sur le runtime, pour afficher deux mots, c'est non. On reprend donc
# la MEME detection que `cmd_status` (fleet_v2:305) — has-session sur le socket du daemon, puis
# comptage des pods par leurs socks — sans le bloc version. Meme verite, sans le cout.
#
# CONTRAT : sort TOUJOURS 0 et TOUJOURS une ligne. Une barre de statut qui echoue n'affiche pas
# une erreur, elle affiche du bruit ; l'humain croit alors que la fleet est dans un etat qu'elle
# n'est pas. En cas de doute, la sonde dit ce qu'elle SAIT, pas ce qu'elle suppose.
#
# USAGE : console-status.sh   (aucun argument — s'execute sous l'identite de l'humain)

set -uo pipefail          # PAS -e : aucune commande de cette sonde n'a le droit de la tuer

TMUX_BIN="${LCARS_TMUX_BIN:-tmux}"
SESSION="${LCARS_FLEET_V2_SESSION:-fleet_v2}"
DAEMON_SOCK="${LCARS_FLEET_V2_SOCK:-$HOME/.lcars/run/fleet_v2.sock}"
SOCK_BASE="${LCARS_TMUX_SOCK_BASE:-$HOME/.lcars/run/tmux-sock}"

# Le BEAM d'abord : sans lui, compter les pods n'a pas de sens (des socks peuvent trainer apres un
# crash — c'est exactement le cas « sock orphelin » que `lcars list` distingue).
if ! "$TMUX_BIN" -S "$DAEMON_SOCK" has-session -t "$SESSION" 2>/dev/null; then
  printf 'fleet morte'
  exit 0
fi

# Un sock n'est pas un pod : `lcars list` verifie la session tmux DERRIERE chaque sock avant de
# declarer « vivant ». On fait pareil — sinon un crash laisse la barre mentir a la hausse.
pods=0
if [[ -d "$SOCK_BASE" ]]; then
  shopt -s nullglob
  for sock in "$SOCK_BASE"/*/pod.sock; do
    pod_id="$(basename "$(dirname "$sock")")"
    if "$TMUX_BIN" -S "$sock" has-session -t "lcars-pod-$pod_id" 2>/dev/null; then
      pods=$(( pods + 1 ))
    fi
  done
fi

if [[ "$pods" -eq 0 ]]; then
  printf 'fleet vivante · aucun pod'
elif [[ "$pods" -eq 1 ]]; then
  printf 'fleet vivante · 1 pod'
else
  printf 'fleet vivante · %d pods' "$pods"
fi
exit 0
