#!/usr/bin/env bash
# SOURCE: deploy/docker/bench/bench-down.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-13
# STATUS: détruit un banc complet, volumes compris — le runner, le conteneur, la forge, le magasin
#
# USAGE : bench-down.sh --project <base> --yes
# EXIT  : 0 détruit · 1 arguments, ou ce qui porte ce nom n'est pas un banc · 2 rien à détruire sous ce nom
#
# Un banc = trois projets compose dérivés de la base : <base>-fleet (le conteneur), <base>-forge,
# <base>-runner, plus le magasin <base>-fleet-*. Aucun défaut de projet : ce geste efface des
# volumes, le nom s'écrit. Une instance posée sans banc porte le même nom <base>-fleet : elle est
# refusée, parce que son conteneur n'a pas été créé avec docker-compose.bench.yml, ou, sans
# conteneur, parce qu'aucune forge de banc ne l'accompagne.

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

STORE_NAMES="$(store_volume_names)"
NOMS="$("$DOCKER_BIN" ps -a --format '{{.Names}}' || true)"
VOLUMES="$("$DOCKER_BIN" volume ls --format '{{.Name}}' || true)"
# les volumes comptent seuls : ils portent l'état, et down -v les emporte même sans conteneur
RESIDU_C="$(grep -cxE "$CONTAINER|$RUNNER|$FORGE" <<<"$NOMS" || true)"
RESIDU_V="$(grep -cE "^(${CONTAINER_PROJECT}|${FORGE_PROJECT}|${RUNNER_PROJECT})_" <<<"$VOLUMES" || true)"
RESIDU_S="$(grep -cxF -f <(printf '%s\n' "$STORE_NAMES") <<<"$VOLUMES" || true)"

[[ "$RESIDU_C" -gt 0 || "$RESIDU_V" -gt 0 || "$RESIDU_S" -gt 0 ]] \
  || { echo "bench-down : aucun conteneur ni volume de « $PROJECT » (ni $CONTAINER, $RUNNER, $FORGE, ni son magasin) — rien à détruire" >&2; exit 2; }

refus_provenance() {
  {
    echo "bench-down : refus — « $CONTAINER_PROJECT » n'est pas un banc : $1"
    echo "  Une instance posée par install.sh ou deploy/container porte ce nom sans banc ; ce geste effacerait son /home."
    echo "  La retirer : deploy/container -p $CONTAINER_PROJECT reset"
  } >&2
  exit 1
}
FLEET_IDS="$("$DOCKER_BIN" ps -aq --filter "label=com.docker.compose.project=$CONTAINER_PROJECT" || true)"
if [[ -n "$FLEET_IDS" ]]; then
  # shellcheck disable=SC2086 # les ids sont des mots
  FICHIERS="$("$DOCKER_BIN" inspect $FLEET_IDS --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' || true)"
  [[ "$FICHIERS" == *docker-compose.bench.yml* ]] \
    || refus_provenance "son conteneur a été créé sans docker-compose.bench.yml (${FICHIERS:-fichiers illisibles})"
elif [[ "$(grep -cxE "$FORGE|$RUNNER" <<<"$NOMS" || true)" -eq 0 \
        && "$(grep -cE "^(${FORGE_PROJECT}|${RUNNER_PROJECT})_" <<<"$VOLUMES" || true)" -eq 0 ]]; then
  refus_provenance "aucune forge ni runner de banc « $PROJECT » n'accompagne ses volumes"
fi

# le runner d'abord : il tient le réseau de la forge. runner-compose.yml exige LCARS_FORGE_URL même
# pour un down, d'où une valeur factice
echo "[bench-down] destruction du runner ($RUNNER_PROJECT)"
LCARS_FORGE_URL="http://gitea:3000" "$DOCKER_BIN" compose -f "$DOCKER_DIR/runner-compose.yml" -p "$RUNNER_PROJECT" \
  down -v --remove-orphans || true

echo "[bench-down] destruction du conteneur ($CONTAINER_PROJECT) — volumes compris"
"$DOCKER_BIN" compose -f "$DOCKER_DIR/docker-compose.yml" -p "$CONTAINER_PROJECT" down -v --remove-orphans || true

echo "[bench-down] destruction de la forge ($FORGE_PROJECT) — volumes compris"
"$DOCKER_BIN" compose -f "$DOCKER_DIR/forge-compose.yml" -p "$FORGE_PROJECT" down -v --remove-orphans || true

echo "[bench-down] destruction du magasin de « $PROJECT » ($(store_volume_names | tr '\n' ' ' | sed 's/ $//'))"
store_destroy_volumes "$DOCKER_BIN" || echo "[bench-down] au moins un volume du magasin n'a pas pu être détruit" >&2

echo "[bench-down] banc « $PROJECT » détruit"
