#!/usr/bin/env bash
# SOURCE: runtime/priv/spawner/watch.sh
# AUTHOR: starfleet
# STARDATE: 2026-06-06
# STATUS: monitor in-pod canonique (pattern #548 / PoC mcp-debate). Provisionné par
#         Fleet.Spawner.Pod dans le pod-dir (HOME bwrap). Armé par l'agent via l'outil
#         natif Monitor : Monitor(command="bash ~/watch.sh ~/turn.flag", …) — permanent si le
#         harnais le propose, sinon plafonné (30 min) et RÉARMÉ par l'agent à chaque expiration.
#
# Émet UNE ligne stdout par token frais dans le flag (wake-par-flag, zéro send-keys de
# contenu — ADR-G : send-keys = kick + slash seulement). Canal TYPÉ : flag = "<token>"
# seul → "ton tour" (un mandat attend, l'agent fait get_work_item) ; flag =
# "<token> <message>" → le MESSAGE verbatim (information pure — progression fleet —
# l'agent ne PULL PAS). L'outil Monitor transforme chaque ligne en réveil de l'agent.
set -uo pipefail          # PAS -e : moniteur in-pod, il tourne en boucle et doit survivre a
                          # chaque tour qui echoue — sinon la surveillance s'arrete au premier hoquet.
FLAG="${1:?usage: watch.sh <flagfile>}"
# Baseline = le DERNIER jeton LIVRÉ (".seen"), pas le contenu courant du flag. Le Monitor du harnais
# expire (30 min, sans mode permanent depuis Claude Code 2.1.x) et l'agent le réarme : un réveil écrit
# PENDANT l'intervalle est donc différent de ".seen", et il est émis dès le réarmement. Prendre le flag
# courant comme baseline l'avalait, et recopier le flag dans ".seen" le marquait LIVRÉ — le serveur
# (`TurnFlag.delivered?`) arrêtait alors ses relances send-keys sur un réveil jamais vu.
# Premier armement de la vie du pod (pas de ".seen" : le lancement l'efface) : baseline = le flag
# courant, pour que le token résiduel du kick de boot ne rejoue pas comme un faux réveil.
# La ligne « watch arme » ci-dessous reste LA confirmation d'armement.
if [[ -f "$FLAG.seen" ]]; then
  last="$(cat "$FLAG.seen" 2>/dev/null || true)"
else
  last="$([[ -f "$FLAG" ]] && cat "$FLAG" 2>/dev/null || true)"
  # Marqueur d'ARMEMENT : ".seen" existe dès le premier armement, AVANT tout wake. Le serveur lit son
  # existence pour arrêter l'engage de bootstrap. Il n'est écrit ici qu'une fois : ensuite, seule une
  # LIVRAISON l'écrit.
  printf '%s\n' "$last" > "$FLAG.seen" 2>/dev/null || true
fi
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
      # Trace de LIVRAISON : on écrit le token qu'on vient d'émettre dans "<flag>.seen". Le serveur
      # compare turn.flag à turn.flag.seen pour distinguer « Monitor a livré, l'agent est occupé » de
      # « Monitor planté » — au lieu de keyer le wake sur get_work_item, que l'agent peut légitimement
      # ne pas appeler (tour d'info, ou son propre jugement « rien à tirer »). Non-fatal.
      printf '%s\n' "$cur" > "$FLAG.seen" 2>/dev/null || true
    fi
  fi
  sleep 1
done
