#!/usr/bin/env bash
# SOURCE: fleet/deploy/docker/bench/bench-down.sh
# AUTHOR: DrDree
# STARDATE: 2026-08-03
# STATUS: geste de BANC — DETRUIT un banc complet, volumes compris
#
# ─── POURQUOI CE GESTE VIT DANS SON PROPRE FICHIER ──────────────────────────────────────────────
# `bench-up.sh` monte, celui-ci detruit. Les separer n'est pas de la coquetterie : le `-v` de
# `compose down` efface les volumes, donc la forge, ses comptes, ses tokens et le /home de la boite.
# Tant que le geste destructeur est une OPTION d'un script qu'on lance vingt fois par nuit, il finit
# par partir sur le mauvais projet. Ici il faut ecrire le nom du projet, et --yes.
#
# ⚠ LE NOM DU PROJET EST LA SEULE PROTECTION. Il n'y a aucun defaut : un defaut sur ce script serait
# un banc detruit par une commande sans argument. Un banc qui TRAVAILLE se detruit comme un autre —
# la machine ne sait pas lequel compte, c'est a toi de le savoir.
#
# UN BANC = TROIS PROJETS COMPOSE : la boite (`<projet>`), la forge (`<projet>forge`) et le
# runner (`<projet>-runner`). Les trois partent ici, le runner en premier parce qu'il tient le
# reseau de la forge.
#
# USAGE : bench-down.sh --project lcars-nuit --yes
# EXIT  : 0 detruit · 1 arguments · 2 rien a detruire sous ce nom

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(cd "$HERE/.." && pwd)"

PROJECT=""
CONFIRM=0
DOCKER_BIN="${DOCKER_BIN:-docker}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="${2:?}"; shift 2 ;;
    --yes)     CONFIRM=1; shift ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "bench-down: option inconnue: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$PROJECT" ]] || { echo "bench-down: --project est OBLIGATOIRE (aucun defaut, par choix)" >&2; exit 1; }
[[ "$CONFIRM" -eq 1 ]] || { echo "bench-down: --yes requis — ceci efface les volumes de '$PROJECT'" >&2; exit 1; }

FORGE_PROJECT="${PROJECT}forge"
RUNNER_PROJECT="${PROJECT}-runner"
BOX="${PROJECT}-lcars-1"
RUNNER="${RUNNER_PROJECT}-runner-1"
FORGE="${FORGE_PROJECT}-forge-1"

# UN BANC A TROIS PROJETS COMPOSE, ET CELUI-CI N'EN VOYAIT QUE DEUX. `bench-up.sh` lance aussi un
# runner (`bench-runner.sh --project "${PROJECT}-runner"`) ; il n'etait jamais detruit. Mesure du
# 2026-08-09 : apres un `bench-down` complet, `lcars-faces-runner-runner-1` tournait toujours, et
# le `down` de la forge finissait sur « Network ... Resource is still in use » — le runner est
# branche sur le reseau de la forge, donc tant qu'il vit ce reseau ne part pas. Il reste enregistre
# contre une forge qui n'existe plus : le zombie que bench-runner decrit dans son propre en-tete,
# sauf que la, personne ne le nettoie avant le banc SUIVANT.
#
# ⚠ LE DISCRIMINANT PORTE SUR LE RESIDU, PLUS SUR UNE LISTE DE CONTENEURS ATTENDUS. Il a d'abord
# regarde la boite seule, puis la boite OU le runner — a chaque fois un membre de plus, jamais la
# classe. Le membre manquant s'est presente : `bench-up` meurt AVANT de creer la boite (forge qui
# ne repond pas), il ne reste que `<projet>forge-forge-1` et ses deux volumes, et ce script
# repondait « rien a detruire » sur un banc qui occupait le bind, le port et le nom du projet. Le
# banc suivant se montait alors sur les restes du precedent.
#
# La question juste n'est pas « la boite est-elle la ? » mais « reste-t-il QUOI QUE CE SOIT de ce
# banc ? » — donc les trois conteneurs ET les volumes des trois projets. Les volumes comptent
# seuls : ce sont eux qui portent l'etat (la forge semee, le /home de la boite), et `down -v` les
# emporte meme quand plus aucun conteneur ne les monte.
RESIDU_C="$("$DOCKER_BIN" ps -a --format '{{.Names}}' | grep -cxE "$BOX|$RUNNER|$FORGE" || true)"
RESIDU_V="$("$DOCKER_BIN" volume ls --format '{{.Name}}' \
  | grep -cE "^(${PROJECT}|${FORGE_PROJECT}|${RUNNER_PROJECT})_" || true)"

[[ "$RESIDU_C" -gt 0 || "$RESIDU_V" -gt 0 ]] \
  || { echo "bench-down: aucun conteneur ni volume de '$PROJECT' (ni $BOX, $RUNNER, $FORGE) — rien a detruire" >&2; exit 2; }

# LE RUNNER D'ABORD, et l'ordre n'est pas cosmetique : il tient le reseau de la forge, donc le
# detruire apres laisserait ce reseau debout. Valeurs factices comme dans le nettoyage de
# bench-runner : `runner-compose.yml` exige LCARS_FORGE_URL (`:?`) et l'interpolation refuse MEME
# un down — sans elles ce nettoyage echoue en silence sous le `|| true`.
echo "[bench-down] destruction du runner ($RUNNER_PROJECT)"
LCARS_FORGE_URL="http://forge:3000" LCARS_RUNNER_TOKEN=" " \
  "$DOCKER_BIN" compose -f "$HERE/runner-compose.yml" -p "$RUNNER_PROJECT" \
  down -v --remove-orphans || true

echo "[bench-down] destruction de la boite ($PROJECT) — volumes compris"
"$DOCKER_BIN" compose -f "$DOCKER_DIR/docker-compose.install.yml" -p "$PROJECT" down -v --remove-orphans || true

echo "[bench-down] destruction de la forge ($FORGE_PROJECT) — volumes compris"
"$DOCKER_BIN" compose -f "$HERE/forge-compose.yml" -p "$FORGE_PROJECT" down -v --remove-orphans || true

echo "[bench-down] banc '$PROJECT' detruit"
