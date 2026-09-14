#!/usr/bin/env bash
# SOURCE: deploy/docker/bench/bench-swap-image.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-13
# STATUS: remplace l'image du conteneur d'un banc déjà semé — la forge, son semis et ses jetons restent
#
# USAGE : bench-swap-image.sh --image lcars-fleet:xyz [--forge-project lcars] [--bind 0.0.0.0] [--advertise <ip-ou-nom>]
#                             [--port-forge 21000] [--port-deck 20999] [--port-ssh 2222]
#                             [--creds-from ~/.claude/.credentials.json] [--no-creds] [--human lcars]
# EXIT  : 0 conteneur remplacé · 1 arguments ou dépendance · 3 le conteneur ne monte pas · 5 credentials
#         6 aucun jeton de rôle après la relance
#
# Détruit le conteneur LCARS et lui seul : ses volumes restent, ce qui vit hors d'eux (pods en vol,
# journaux BEAM) part avec. Ne démarre pas la fleet : le verdict final le rappelle.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(cd "$HERE/.." && pwd)"

# shellcheck source=../../lib/provision-lib.sh
source "$DOCKER_DIR/../lib/provision-lib.sh"
# shellcheck source=../../lib/forge-bootstrap.sh
source "$DOCKER_DIR/../lib/forge-bootstrap.sh"

PROJECT="$PROV_FORGE_BASE_DEFAULT"
FORGE_PORT="$PROV_FORGE_HOST_PORT_DEFAULT"
DECK_PORT="$PROV_DECK_PORT_DEFAULT"
SSH_PORT="$PROV_SSH_PORT_DEFAULT"
BIND="0.0.0.0"
ADVERTISE=""
IMAGE=""
CREDS_FROM="$HOME/.claude/.credentials.json"
WITH_CREDS=1
HUMAN="lcars"
DOCKER_BIN="${DOCKER_BIN:-docker}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project|--forge-project)  PROJECT="${2:?}"; shift 2 ;;
    --forge-port|--port-forge)  FORGE_PORT="${2:?}"; shift 2 ;;
    --deck-port|--port-deck)    DECK_PORT="${2:?}"; shift 2 ;;
    --ssh-port|--port-ssh)      SSH_PORT="${2:?}"; shift 2 ;;
    --bind)       BIND="${2:?}"; shift 2 ;;
    --advertise)  ADVERTISE="${2:?}"; shift 2 ;;
    --image)      IMAGE="${2:?}"; shift 2 ;;
    --creds-from) CREDS_FROM="${2:?}"; shift 2 ;;
    --no-creds)   WITH_CREDS=0; shift ;;
    --human)      HUMAN="${2:?}"; shift 2 ;;
    -h|--help)    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "bench-swap-image : option inconnue : $1" >&2; exit 1 ;;
  esac
done

CONTAINER_PROJECT="${PROJECT}-fleet"
FORGE_PROJECT="${PROJECT}-forge"
FORGE_NET="${FORGE_PROJECT}_default"
CONTAINER="${CONTAINER_PROJECT}-lcars-1"
COMPOSE_ARGS=(--env-file "$PROV_CONSTANTS_FILE" -f "$DOCKER_DIR/docker-compose.yml" -f "$DOCKER_DIR/docker-compose.bench.yml" -p "$CONTAINER_PROJECT")

export LCARS_STORE_PREFIX="$CONTAINER_PROJECT"
if [[ -z "${ADVERTISE:-}" ]]; then advertise_addr "$BIND"; ADVERTISE="$PROV_ADVERTISE"; fi
FORGE_URL="http://${ADVERTISE}:${FORGE_PORT}"

say() { echo "bench-swap-image : $*"; }
die() { echo "bench-swap-image : $1" >&2; exit "${2:-1}"; }

[[ -n "$IMAGE" ]] || die "--image est obligatoire : ce script n'a pas de défaut, se tromper d'image est le seul dégât qu'il puisse faire" 1

# sans banc, le swap monterait un conteneur orphelin, sans réseau de forge ni graine
"$DOCKER_BIN" network inspect "$FORGE_NET" >/dev/null 2>&1 \
  || die "réseau $FORGE_NET absent — il n'y a pas de banc « $PROJECT » à mettre à jour (bench-up.sh d'abord)" 1
"$DOCKER_BIN" image inspect "$IMAGE" >/dev/null 2>&1 \
  || die "image $IMAGE inconnue du daemon — elle doit exister avant que le conteneur soit détruit" 1

if [[ "$WITH_CREDS" -eq 1 ]]; then
  [[ -r "$CREDS_FROM" ]] || die "credentials illisibles : $CREDS_FROM (--no-creds pour un banc sans pods)" 5
fi

say "banc $PROJECT — le conteneur passe sur $IMAGE (forge, semis et jetons préservés)"

"$DOCKER_BIN" rm -f "$CONTAINER" >/dev/null 2>&1 || true

# create puis start, jamais un up : l'override de banc branche le réseau de la forge à la création,
# et « gitea » résout avant le premier boot
env LCARS_IMAGE="$IMAGE" \
    LCARS_ADMIRAL="admiral" \
    FORGE_BASE_URL="$PROV_FORGE_INTERNAL_URL" \
    LCARS_SOURCE_REMOTE="$PROV_FORGE_INTERNAL_URL/$PROV_FORGE_ORG_DEFAULT/lcars.git" \
    LCARS_SSH_PORT="${BIND}:${SSH_PORT}" \
    LCARS_LANDING_PORT_BIND="${BIND}:${DECK_PORT}" \
    FORGE_PUBLIC_URL="$FORGE_URL" \
    LCARS_DECK_ORIGINS="http://${ADVERTISE}:${DECK_PORT}" \
    LCARS_DEVFORGE_NETWORK="$FORGE_NET" \
    "$DOCKER_BIN" compose "${COMPOSE_ARGS[@]}" create lcars \
  || die "le conteneur ne se crée pas (le réseau $FORGE_NET existe-t-il ? les volumes du magasin ?)" 3
"$DOCKER_BIN" compose "${COMPOSE_ARGS[@]}" start lcars || die "le conteneur ne démarre pas" 3

wait_healthy() {
  for _ in $(seq 1 90); do
    [[ "$("$DOCKER_BIN" inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null)" == "healthy" ]] && return 0
    sleep 2
  done
  return 1
}
wait_healthy || die "le conteneur ne devient pas healthy (docker logs $CONTAINER)" 3
say "conteneur healthy"

if printf 'admiral:%s\n' "$(bench_admiral_password)" | "$DOCKER_BIN" exec -i -u root "$CONTAINER" chpasswd 2>/dev/null; then
  say "mot de passe de banc posé sur admiral (ssh, sudo)"
else
  say "admiral : mot de passe non posé — ssh par clé, ou « docker exec -u admiral $CONTAINER bash »"
fi

# les credentials partent avec l'ancien conteneur ; sans elles la fleet a l'air saine et ne produit aucun pod
if [[ "$WITH_CREDS" -eq 1 ]]; then
  "$DOCKER_BIN" exec -i -u "$HUMAN" "$CONTAINER" bash -c \
      'mkdir -p ~/.claude && cat > ~/.claude/.credentials.json && chmod 600 ~/.claude/.credentials.json' \
    < "$CREDS_FROM" || die "credentials non posées dans le conteneur" 5
  say "credentials anthropic reposées chez $HUMAN"
else
  say "credentials non posées (--no-creds) — aucun pod ne pourra démarrer, par choix"
fi

# une relance suffit : la graine de la forge existe, le geste tokens minte les jetons de rôle au boot
say "relance pour que le geste tokens minte les jetons de rôle sur la graine existante"
"$DOCKER_BIN" restart "$CONTAINER" >/dev/null || die "relance du conteneur impossible" 3
wait_healthy || die "le conteneur ne redevient pas healthy après relance" 3

TOKENS_IN="$(prov_canon "$PROV_TOKENS_DIR")"
ROLE_TOKENS="$("$DOCKER_BIN" cp "$CONTAINER:$TOKENS_IN" - 2>/dev/null | tar -t 2>/dev/null | grep -c '\.gitea_token$' || true)"
[[ "${ROLE_TOKENS:-0}" -gt 0 ]] || die "aucun jeton de rôle après relance — le conteneur ne voit pas la graine de la forge" 6

CREDS_SIZE="$("$DOCKER_BIN" cp "$CONTAINER:/home/$HUMAN/.claude/.credentials.json" - 2>/dev/null \
              | tar -tv 2>/dev/null | awk 'NR==1 {print $3}' || true)"
if [[ "${CREDS_SIZE:-}" =~ ^[0-9]+$ ]] && [[ "$CREDS_SIZE" -gt 0 ]]; then
  CREDS_OK=oui
else
  CREDS_OK=non
fi

REVISION="$("$DOCKER_BIN" inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER" 2>/dev/null \
            | sed -n 's/^LCARS_IMAGE_REVISION=//p' | head -1 || true)"
REVISION="${REVISION:-inconnue}"

say "─────────────────────────────────────────────────────────"
say "conteneur remplacé"
say "  image     : $IMAGE   (révision $REVISION)"
say "  forge     : $FORGE_URL   (préservée — ni resemée ni redémarrée)"
say "  jetons    : $ROLE_TOKENS fichiers dans $TOKENS_IN"
say "  creds     : $CREDS_OK"
say "  la fleet n'est pas démarrée : docker exec -u $HUMAN $CONTAINER bash -lc 'fleet start'"
say "─────────────────────────────────────────────────────────"
