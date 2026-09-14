#!/usr/bin/env bash
# SOURCE: deploy/docker/bench/bench-down.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-13
# STATUS: détruit un banc complet, volumes compris — le runner, le conteneur, la forge, le magasin
#
# USAGE : bench-down.sh --project <base> --yes
# EXIT  : 0 détruit · 1 arguments, docker muet, ou ce qui porte ce nom n'est pas un banc · 2 rien à détruire sous ce nom
#
# Un banc = trois projets compose dérivés de la base : <base>-fleet (le conteneur), <base>-forge,
# <base>-runner, plus le magasin <base>-fleet-*. Aucun défaut de projet : ce geste efface des
# volumes, le nom s'écrit.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(cd "$HERE/.." && pwd)"
BENCH_NOM=bench-down
# shellcheck source=../../lib/bench.sh
. "$DOCKER_DIR/../lib/bench.sh"

PROJECT=""
CONFIRM=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="${2:?--project attend une base}"; shift 2 ;;
    --yes)     CONFIRM=1; shift ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "option inconnue : $1" 1 ;;
  esac
done

[[ -n "$PROJECT" ]] || die "--project est obligatoire (aucun défaut, par choix)" 1
[[ "$CONFIRM" -eq 1 ]] || die "--yes requis — ceci efface les volumes de « $PROJECT »" 1
bench_projets

OBJETS="$(bench_objets)" \
  || die "docker ne rend pas les objets des projets $CONTAINER_PROJECT, $FORGE_PROJECT, $RUNNER_PROJECT — rien n'est détruit sur un état non lu" 1
VOLUMES="$("$DOCKER_BIN" volume ls --format '{{.Name}}')" \
  || die "docker ne rend pas la liste des volumes — rien n'est détruit sur un état non lu" 1
MAGASIN="$(grep -xF -f <(store_volume_names) <<<"$VOLUMES" || true)"

[[ -n "$OBJETS" || -n "$MAGASIN" ]] \
  || die "aucun conteneur ni volume du banc « $PROJECT » ($CONTAINER_PROJECT, $FORGE_PROJECT, $RUNNER_PROJECT, magasin) — rien à détruire" 2
ETRANGERS="$(bench_etrangers "$OBJETS")"
[[ -z "$ETRANGERS" ]] \
  || bench_refus_etrangers "$ETRANGERS" "Rien n'est détruit. Une instance posée par install.sh ou deploy/container se retire par : deploy/container -p $CONTAINER_PROJECT reset"
if [[ -z "$OBJETS" ]]; then
  {
    say "refus : le magasin de « $CONTAINER_PROJECT » est là sans aucun objet du banc « $PROJECT » — ce n'est pas un banc."
    say "  Le retirer : docker volume rm ${MAGASIN//$'\n'/ }"
  } >&2
  exit 1
fi

# le runner d'abord : il tient le réseau de la forge
say "destruction du runner ($RUNNER_PROJECT)"
"$DOCKER_BIN" compose --env-file "$PROV_CONSTANTS_FILE" -f "$DOCKER_DIR/runner-compose.yml" -p "$RUNNER_PROJECT" \
  down -v --remove-orphans || true

say "destruction du conteneur ($CONTAINER_PROJECT) — volumes compris"
"$DOCKER_BIN" compose --env-file "$PROV_CONSTANTS_FILE" -f "$DOCKER_DIR/docker-compose.yml" -p "$CONTAINER_PROJECT" down -v --remove-orphans || true

say "destruction de la forge ($FORGE_PROJECT) — volumes compris"
"$DOCKER_BIN" compose --env-file "$PROV_CONSTANTS_FILE" -f "$DOCKER_DIR/forge-compose.yml" -p "$FORGE_PROJECT" down -v --remove-orphans || true

say "destruction du magasin de « $PROJECT » ($(store_volume_names | tr '\n' ' ' | sed 's/ $//'))"
store_destroy_volumes "$DOCKER_BIN" || say "au moins un volume du magasin n'a pas pu être détruit" >&2

say "banc « $PROJECT » détruit"
