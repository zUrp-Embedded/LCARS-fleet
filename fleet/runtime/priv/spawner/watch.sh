#!/usr/bin/env bash
# SOURCE: apps/fleet_spawner/priv/watch.sh
# AUTHOR: starfleet
# STARDATE: 2026-06-06
# STATUS: monitor in-pod canonique (pattern #548 / PoC mcp-debate). Provisionné par
#         Fleet.Spawner.Pod dans le pod-dir (HOME bwrap). Armé par l'agent via l'outil
#         natif Monitor : Monitor(command="bash ~/watch.sh ~/turn.flag", persistent=true).
#
# Émet UNE ligne stdout ("ton tour") chaque fois que la fleet écrit un token frais dans
# le flag (wake-par-flag, zéro send-keys de contenu — ADR-G : send-keys = kick + slash
# seulement). L'outil Monitor transforme chaque ligne en réveil de l'agent → get_work_item (MCP).
set -uo pipefail
FLAG="${1:?usage: watch.sh <flagfile>}"
last=""
echo "watch arme sur $FLAG"
while :; do
  if [[ -f "$FLAG" ]]; then
    cur="$(cat "$FLAG" 2>/dev/null || true)"
    if [[ -n "$cur" && "$cur" != "$last" ]]; then
      last="$cur"
      echo "ton tour"
    fi
  fi
  sleep 1
done
