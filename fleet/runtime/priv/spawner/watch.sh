#!/usr/bin/env bash
# SOURCE: apps/fleet_spawner/priv/watch.sh
# AUTHOR: starfleet
# STARDATE: 2026-06-06
# STATUS: monitor in-pod canonique (pattern #548 / PoC mcp-debate). Provisionné par
#         Fleet.Spawner.Pod dans le pod-dir (HOME bwrap). Armé par l'agent via l'outil
#         natif Monitor : Monitor(command="bash ~/watch.sh ~/turn.flag", persistent=true).
#
# Émet UNE ligne stdout par token frais dans le flag (wake-par-flag, zéro send-keys de
# contenu — ADR-G : send-keys = kick + slash seulement). Canal TYPÉ : flag = "<token>"
# seul → "ton tour" (un mandat attend, l'agent fait get_work_item) ; flag =
# "<token> <message>" → le MESSAGE verbatim (information pure — progression fleet —
# l'agent ne PULL PAS). L'outil Monitor transforme chaque ligne en réveil de l'agent.
set -uo pipefail
FLAG="${1:?usage: watch.sh <flagfile>}"
last=""
echo "watch arme sur $FLAG"
while :; do
  if [[ -f "$FLAG" ]]; then
    cur="$(cat "$FLAG" 2>/dev/null || true)"
    if [[ -n "$cur" && "$cur" != "$last" ]]; then
      last="$cur"
      msg="${cur#* }"
      if [[ "$msg" == "$cur" ]]; then
        echo "ton tour"
      else
        echo "$msg"
      fi
    fi
  fi
  sleep 1
done
