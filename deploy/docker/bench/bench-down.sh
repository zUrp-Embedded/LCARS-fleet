#!/usr/bin/env bash
# SOURCE: deploy/docker/bench/bench-down.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-13
# STATUS: détruit un banc complet, volumes compris — le runner, le conteneur, la forge, le magasin
#
# USAGE : bench-down.sh --project <base> --yes
# EXIT  : 0 détruit · 1 arguments · 2 rien à détruire sous ce nom
#
# Un banc = trois projets compose dérivés de la base : <base>-fleet (le conteneur), <base>-forge,
# <base>-runner. Aucun défaut de projet : ce geste efface des volumes, le nom s'écrit.

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
    *) echo "bench-down : option inconnue : $1" >&2; exit 1 ;;
  esac
done

[[ -n "$PROJECT" ]] || { echo "bench-down : --project est obligatoire (aucun défaut, par choix)" >&2; exit 1; }
[[ "$CONFIRM" -eq 1 ]] || { echo "bench-down : --yes requis — ceci efface les volumes de « $PROJECT »" >&2; exit 1; }

# le compose du conteneur exige LCARS_STORE_PREFIX pour se lire, même pour un down
CONTAINER_PROJECT="${PROJECT}-fleet"
export LCARS_STORE_PREFIX="$CONTAINER_PROJECT"
# shellcheck source=../../lib/store.sh
source "$DOCKER_DIR/../lib/store.sh"

FORGE_PROJECT="${PROJECT}-forge"
RUNNER_PROJECT="${PROJECT}-runner"
CONTAINER="${CONTAINER_PROJECT}-lcars-1"
RUNNER="${RUNNER_PROJECT}-act-1"
FORGE="${FORGE_PROJECT}-gitea-1"

# les volumes comptent seuls : ils portent l'état, et down -v les emporte même sans conteneur
RESIDU_C="$("$DOCKER_BIN" ps -a --format '{{.Names}}' | grep -cxE "$CONTAINER|$RUNNER|$FORGE" || true)"
RESIDU_V="$("$DOCKER_BIN" volume ls --format '{{.Name}}' \
  | grep -cE "^(${CONTAINER_PROJECT}|${FORGE_PROJECT}|${RUNNER_PROJECT})_" || true)"

[[ "$RESIDU_C" -gt 0 || "$RESIDU_V" -gt 0 ]] \
  || { echo "bench-down : aucun conteneur ni volume de « $PROJECT » (ni $CONTAINER, $RUNNER, $FORGE) — rien à détruire" >&2; exit 2; }

# le runner d'abord : il tient le réseau de la forge. Les valeurs voyagent par un env-file parce que
# runner-compose.yml exige LCARS_FORGE_URL même pour un down, et qu'un shim sudo remet l'environnement à zéro
echo "[bench-down] destruction du runner ($RUNNER_PROJECT)"
RUNNER_ENV_DOWN="$(mktemp "${TMPDIR:-/tmp}/bench-down-runner.XXXXXX")"
chmod 0600 "$RUNNER_ENV_DOWN"
printf 'LCARS_FORGE_URL=%s\nLCARS_RUNNER_TOKEN=%s\n' "http://gitea:3000" " " > "$RUNNER_ENV_DOWN"
"$DOCKER_BIN" compose --env-file "$RUNNER_ENV_DOWN" -f "$DOCKER_DIR/runner-compose.yml" -p "$RUNNER_PROJECT" \
  down -v --remove-orphans || true
rm -f "$RUNNER_ENV_DOWN"

echo "[bench-down] destruction du conteneur ($CONTAINER_PROJECT) — volumes compris"
"$DOCKER_BIN" compose -f "$DOCKER_DIR/docker-compose.yml" -p "$CONTAINER_PROJECT" down -v --remove-orphans || true

echo "[bench-down] destruction de la forge ($FORGE_PROJECT) — volumes compris"
"$DOCKER_BIN" compose -f "$DOCKER_DIR/forge-compose.yml" -p "$FORGE_PROJECT" down -v --remove-orphans || true

echo "[bench-down] destruction du magasin de « $PROJECT » ($(store_volume_names | tr '\n' ' ' | sed 's/ $//'))"
store_destroy_volumes "$DOCKER_BIN" || echo "[bench-down] au moins un volume du magasin n'a pas pu être détruit" >&2

echo "[bench-down] banc « $PROJECT » détruit"
