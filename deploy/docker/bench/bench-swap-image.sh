#!/usr/bin/env bash
# SOURCE: deploy/docker/bench/bench-swap-image.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-13
# STATUS: remplace l'image du conteneur d'un banc déjà semé — la forge, son semis et ses jetons restent
#
# USAGE : bench-swap-image.sh --image lcars-fleet:xyz [--forge-project <base>] [--bind 0.0.0.0] [--advertise <ip-ou-nom>]
#                             [--port-forge N] [--port-deck N] [--port-ssh N]
#                             [--creds-from ~/.claude/.credentials.json] [--no-creds] [--human ensign]
# EXIT  : 0 conteneur remplacé · 1 arguments, image inconnue du daemon, docker muet, forge du banc absente,
#         ou projet qui n'est pas ce banc · 3 le conteneur ne monte pas · 5 credentials · 6 aucun jeton
#         de rôle après la relance
#
# Sans --forge-project ni option de port, la base et les ports sont les défauts de
# deploy/installer-constants.env, ceux de bench-up.sh. Détruit le conteneur LCARS et lui seul, après
# avoir vu la forge du banc et le marqueur de chaque objet de ses projets : ses volumes restent, ce
# qui vit hors d'eux (pods en vol, journaux BEAM) part avec. Ne démarre pas la fleet : le verdict
# final le rappelle.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(cd "$HERE/.." && pwd)"
BENCH_NOM=bench-swap-image
# shellcheck source=../../lib/bench.sh
. "$DOCKER_DIR/../lib/bench.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         bench_option "$@"; shift "$BENCH_LU" ;;
  esac
done
bench_projets
bench_adresses

[[ -n "$IMAGE" ]] || die "--image est obligatoire : ce script n'a pas de défaut, se tromper d'image est le seul dégât qu'il puisse faire" 1

OBJETS="$(bench_objets)" \
  || die "docker ne rend pas les objets des projets $CONTAINER_PROJECT, $FORGE_PROJECT, $RUNNER_PROJECT — rien n'est détruit sur un état non lu" 1
ETRANGERS="$(bench_etrangers "$OBJETS")"
[[ -z "$ETRANGERS" ]] || bench_refus_etrangers "$ETRANGERS" "Rien n'est détruit ; un banc se nomme par sa base : --forge-project <base>."
# sans la forge du banc, le swap monterait un conteneur orphelin, sans réseau de forge ni graine
[[ "$OBJETS" == *"$FORGE_PROJECT conteneur "* ]] \
  || die "aucune forge de banc $FORGE_PROJECT — il n'y a pas de banc « $PROJECT » à mettre à jour (bench-up.sh d'abord)" 1
"$DOCKER_BIN" image inspect "$IMAGE" >/dev/null 2>&1 \
  || die "image $IMAGE inconnue du daemon — elle doit exister avant que le conteneur soit détruit" 1

say "banc $PROJECT — le conteneur passe sur $IMAGE (forge, semis et jetons préservés)"

"$DOCKER_BIN" rm -f "$CONTAINER" >/dev/null 2>&1 || true
quiet bench_conteneur_monte \
  || die "le conteneur ne se crée pas (le réseau $FORGE_NET existe-t-il ? les volumes du magasin ?)" 3
bench_attendre_healthy || die "le conteneur ne devient pas healthy (docker logs $CONTAINER)" 3
say "conteneur healthy"
bench_mot_de_passe "$BENCH_ADMIRAL" "$(bench_admiral_password)"
bench_creds

# une relance suffit : la graine de la forge existe, le geste tokens minte les jetons de rôle au boot
say "relance pour que le geste tokens minte les jetons de rôle sur la graine existante"
bench_relance

ROLE_TOKENS="$(bench_jetons_de_role)"
[[ "${ROLE_TOKENS:-0}" -gt 0 ]] || die "aucun jeton de rôle après relance — le conteneur ne voit pas la graine de la forge" 6

REVISION="$(bench_revision "$IMAGE")"
say "─────────────────────────────────────────────────────────"
say "conteneur remplacé"
say "  image     : $IMAGE   (révision ${REVISION:-inconnue})"
say "  forge     : $FORGE_URL   (préservée — ni resemée ni redémarrée)"
say "  jetons    : $ROLE_TOKENS fichiers dans $(prov_canon "$PROV_TOKENS_DIR")"
say "  creds     : $([[ "$WITH_CREDS" -eq 1 ]] && echo oui || echo non)"
say "  la fleet n'est pas démarrée : docker exec -u $HUMAN $CONTAINER bash -lc 'fleet start'"
say "─────────────────────────────────────────────────────────"
