#!/usr/bin/env bash
# SOURCE: runtime/services/console-status.sh
# AUTHOR: consultant
# STARDATE: 2026-07-31
# STATUS: sonde une-ligne de l'etat fleet, pour la barre de statut tmux de la console
#
# CONTRAT : sort TOUJOURS 0 et TOUJOURS une ligne. tmux n'affiche rien d'un hook en echec, et
# l'operateur lirait cette absence de barre comme une absence de probleme.
#
# ⚠ LA DETECTION EST DUPLIQUEE DEPUIS `fleet cmd_status`, ET C'EST DELIBERE : `cmd_status`
# commence par `cmd_version`, qui retombe sur `git status --porcelain` du runtime quand
# build_info.txt manque. Appeler la commande au lieu de refaire ses deux tests poserait un
# `git status` toutes les 15 s pour afficher deux mots.

set -uo pipefail          # PAS -e : aucune commande de cette sonde n'a le droit de la tuer

TMUX_BIN="${LCARS_TMUX_BIN:-tmux}"
SESSION="${LCARS_FLEET_SESSION:-fleet}"
DAEMON_SOCK="${LCARS_FLEET_SOCK:-$HOME/.lcars/run/fleet.sock}"
SOCK_BASE="${LCARS_TMUX_SOCK_BASE:-$HOME/.lcars/run/tmux-sock}"

if ! "$TMUX_BIN" -S "$DAEMON_SOCK" has-session -t "$SESSION" 2>/dev/null; then
  printf 'fleet morte'
  exit 0
fi

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
