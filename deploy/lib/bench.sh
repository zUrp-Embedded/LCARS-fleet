#!/usr/bin/env bash
# les options et les noms du banc sortent par des globales que les scripts de banc lisent : shellcheck les voit inutilisées
# shellcheck disable=SC2034
# SOURCE: deploy/lib/bench.sh
# AUTHOR: bob
# STARDATE: 2026-09-14
# STATUS: la lib des scripts de banc — options et projets, marqueur, conteneur, attente, credentials, relance
#
# Sourcée par docker/bench/bench-up.sh, bench-swap-image.sh et bench-down.sh, qui posent BENCH_NOM
# avant. Un banc est une base : les projets compose <base>-fleet, <base>-forge et <base>-runner, et
# le magasin <base>-fleet-*. Chaque conteneur et volume de ces projets porte le label
# lcars.bench=<base> ; un script de banc ne réutilise ni ne détruit un objet qui ne le porte pas.

_BENCH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=provision-lib.sh
. "$_BENCH_LIB_DIR/provision-lib.sh"
# shellcheck source=store.sh
. "$_BENCH_LIB_DIR/store.sh"
# shellcheck source=forge-bootstrap.sh
. "$_BENCH_LIB_DIR/forge-bootstrap.sh"

BENCH_DOCKER_DIR="$(cd "$_BENCH_LIB_DIR/../docker" && pwd)"
BENCH_ADMIRAL=admiral

PROJECT="$PROV_FORGE_BASE_DEFAULT"
FORGE_PORT="$PROV_FORGE_HOST_PORT_DEFAULT"
DECK_PORT="$PROV_DECK_PORT_DEFAULT"
SSH_PORT="$PROV_SSH_PORT_DEFAULT"
BIND="0.0.0.0"
ADVERTISE=""
ADVERTISE_GUESSED=""
IMAGE=""
CREDS_FROM="$HOME/.claude/.credentials.json"
WITH_CREDS=1
HUMAN="lcars"
DOCKER_BIN="${DOCKER_BIN:-docker}"

say() { printf '[%s] %s\n' "$BENCH_NOM" "$*"; }
die() { printf '[%s] %s\n' "$BENCH_NOM" "$1" >&2; exit "${2:-1}"; }

bench_option() { # bench_option <arg…> — une option commune au banc et au swap ; BENCH_LU rend le nombre de mots lus
  case "$1" in
    --forge-project) PROJECT="${2:?--forge-project attend une base}"; BENCH_LU=2 ;;
    --port-forge)    FORGE_PORT="${2:?--port-forge attend un port}"; BENCH_LU=2 ;;
    --port-deck)     DECK_PORT="${2:?--port-deck attend un port}"; BENCH_LU=2 ;;
    --port-ssh)      SSH_PORT="${2:?--port-ssh attend un port}"; BENCH_LU=2 ;;
    --bind)          BIND="${2:?--bind attend une adresse}"; BENCH_LU=2 ;;
    --advertise)     ADVERTISE="${2:?--advertise attend une adresse}"; BENCH_LU=2 ;;
    --image)         IMAGE="${2:?--image attend une image}"; BENCH_LU=2 ;;
    --creds-from)    CREDS_FROM="${2:?--creds-from attend un fichier}"; BENCH_LU=2 ;;
    --no-creds)      WITH_CREDS=0; BENCH_LU=1 ;;
    --human)         HUMAN="${2:?--human attend un login}"; BENCH_LU=2 ;;
    *)               die "option inconnue : $1" 1 ;;
  esac
}

bench_projets() { # bench_projets — les projets et le conteneur dérivés de la base ; exporte ce que les compose lisent
  CONTAINER_PROJECT="${PROJECT}-fleet"
  FORGE_PROJECT="${PROJECT}-forge"
  RUNNER_PROJECT="${PROJECT}-runner"
  FORGE_NET="${FORGE_PROJECT}_default"
  CONTAINER="${CONTAINER_PROJECT}-lcars-1"
  export LCARS_STORE_PREFIX="$CONTAINER_PROJECT" LCARS_BENCH_BASE="$PROJECT"
}

bench_adresses() { # bench_adresses — l'adresse annoncée, et la forge vue d'un navigateur
  if [[ -z "$ADVERTISE" ]]; then
    advertise_addr "$BIND"
    ADVERTISE="$PROV_ADVERTISE"; ADVERTISE_GUESSED="${PROV_ADVERTISE_WHY:-}"
  fi
  FORGE_URL="http://${ADVERTISE}:${FORGE_PORT}"
}

bench_objets() { # bench_objets → « <projet> <conteneur|volume> <nom> <base marquée> » par objet des trois projets ; 1 si docker ne répond pas
  local p
  for p in "$CONTAINER_PROJECT" "$FORGE_PROJECT" "$RUNNER_PROJECT"; do
    "$DOCKER_BIN" ps -a --filter "label=com.docker.compose.project=$p" --format "$p conteneur {{.Names}} {{.Label \"lcars.bench\"}}" || return 1
    "$DOCKER_BIN" volume ls --filter "label=com.docker.compose.project=$p" --format "$p volume {{.Name}} {{.Label \"lcars.bench\"}}" || return 1
  done
}

bench_etrangers() { # bench_etrangers <objets> → ceux qui ne portent pas la base de ce banc, un par ligne
  local p t n m
  while read -r p t n m; do
    [[ -z "$n" || "$m" == "$PROJECT" ]] || printf '%s %s (projet %s)\n' "$t" "$n" "$p"
  done <<<"$1"
}

bench_refus_etrangers() { # bench_refus_etrangers <étrangers> <remède> — l'arrêt en 1 qui les nomme
  {
    say "refus : ces objets portent un nom du banc « $PROJECT » sans son marqueur (label lcars.bench=$PROJECT) :"
    sed "s/^/[$BENCH_NOM]   /" <<<"$1"
    say "  $2"
  } >&2
  exit 1
}

quiet() { # quiet <cmd…> — la sortie n'apparaît que si la commande échoue (40 dernières lignes)
  local out rc=0; out="$(mktemp "${TMPDIR:-/tmp}/$BENCH_NOM.XXXXXX")"
  "$@" > "$out" 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]] || tail -n 40 "$out" >&2
  rm -f "$out"
  return "$rc"
}

# le deck compare exactement l'entrée annoncée à son client OAuth2 : seule celle-là est nommée, le
# geste deck-oidc sème les deux écritures de la loopback
bench_conteneur_monte() { # bench_conteneur_monte — le conteneur créé sur le réseau de sa forge, marqué, et démarré
  env LCARS_IMAGE="$IMAGE" \
      LCARS_ADMIRAL="$BENCH_ADMIRAL" \
      LCARS_SSH_PORT="${BIND}:${SSH_PORT}" \
      LCARS_LANDING_PORT_BIND="${BIND}:${DECK_PORT}" \
      FORGE_PUBLIC_URL="$FORGE_URL" \
      LCARS_DECK_ORIGINS="http://${ADVERTISE}:${DECK_PORT}" \
      LCARS_DEVFORGE_NETWORK="$FORGE_NET" \
    "$DOCKER_BIN" compose --env-file "$PROV_CONSTANTS_FILE" -f "$BENCH_DOCKER_DIR/docker-compose.yml" \
      -f "$BENCH_DOCKER_DIR/docker-compose.bench.yml" -p "$CONTAINER_PROJECT" up -d --no-build lcars
}

bench_attendre_healthy() { # bench_attendre_healthy → 0 quand le conteneur est healthy, 1 après trois minutes
  for _ in $(seq 1 90); do
    [[ "$("$DOCKER_BIN" inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null)" == "healthy" ]] && return 0
    sleep 2
  done
  return 1
}

bench_relance() { # bench_relance — redémarre le conteneur et l'attend ; un échec arrête en 3
  "$DOCKER_BIN" restart "$CONTAINER" >/dev/null || die "relance du conteneur impossible" 3
  bench_attendre_healthy || die "le conteneur ne redevient pas healthy après relance (docker logs $CONTAINER)" 3
}

bench_mot_de_passe() { # bench_mot_de_passe <login> <mot de passe> — le mot de passe unix de banc, par stdin
  if printf '%s:%s\n' "$1" "$2" | "$DOCKER_BIN" exec -i -u root "$CONTAINER" chpasswd 2>/dev/null; then
    say "mot de passe de banc posé sur $1 (ssh)"
  else
    say "$1 : mot de passe unix non posé — ssh par clé, ou docker exec -u $1 $CONTAINER bash"
  fi
}

bench_creds() { # bench_creds — les credentials claude chez l'humain ; absentes, c'est dit et WITH_CREDS passe à 0 ; une pose refusée arrête en 5
  if [[ "$WITH_CREDS" -eq 0 ]]; then
    say "creds claude non posées (--no-creds) — aucun pod ne pourra penser, par choix"
    return 0
  fi
  if [[ ! -r "$CREDS_FROM" ]]; then
    say "creds claude absentes ($CREDS_FROM) — non posées chez $HUMAN, aucun pod ne pourra penser ; le banc continue"
    WITH_CREDS=0
    return 0
  fi
  "$DOCKER_BIN" exec -i -u "$HUMAN" "$CONTAINER" bash -c \
      'mkdir -p ~/.claude && cat > ~/.claude/.credentials.json && chmod 600 ~/.claude/.credentials.json' \
    < "$CREDS_FROM" || die "creds non posées dans le conteneur" 5
  say "creds claude posées chez $HUMAN"
}

bench_jetons_de_role() { # bench_jetons_de_role → le nombre de jetons de rôle posés dans le conteneur
  # shellcheck disable=SC2016 # $1 est l'argument du bash du conteneur
  "$DOCKER_BIN" exec -i -u root "$CONTAINER" bash -c 'ls "$1"/*.gitea_token 2>/dev/null | wc -l' _ "$(prov_canon "$PROV_TOKENS_DIR")" < /dev/null \
    || echo 0
}
