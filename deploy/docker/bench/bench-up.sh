#!/usr/bin/env bash
# SOURCE: deploy/docker/bench/bench-up.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-12
# STATUS: le banc — forge jetable, conteneur, structure, humain de démonstration, runner, fleet
#
# USAGE : bench-up.sh [--forge-project lcars-nuit] [--port-forge 21000] [--port-deck 20999] [--port-ssh 2222]
#                     [--bind 0.0.0.0] [--advertise <ip-ou-nom>] [--image lcars-fleet:local]
#                     [--creds-from ~/.claude/.credentials.json] [--no-creds]
#                     [--runner-labels <liste>] [--no-runner] [--human lcars]
#
#   Le banc monte une forge Gitea jetable (projet <base>-forge), crée le conteneur (<base>-fleet)
#   attaché à son réseau, y pose la structure de la forge, l'humain de démonstration et ses
#   jetons, enrôle un runner CI (<base>-runner) et démarre la fleet. Les mots de passe sont ceux
#   du contrat de banc : admiral / toto123456, lcars / toto32toto32 — publics, jetables. L'humain
#   de démonstration est site-admin de la forge : ce banc ne mesure pas ce que la team humans
#   autorise à un compte ordinaire.
#
# EXIT  : 0 banc prêt (« banc PRÊT », ou « banc PRÊT sans CI » sous --no-runner) · 1 arguments ou
#         dépendance · 2 la forge ne monte pas · 3 le conteneur ne monte pas · 4 amorçage de la forge ·
#         5 humain ou credentials · 6 le verdict final ne passe pas (runner demandé qui ne sert pas,
#         conteneur en échec de convergence) · 7 la source ne se sème pas (révision de l'image)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(cd "$HERE/.." && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"

PROJECT="lcars-nuit"
FORGE_PORT="21000"
DECK_PORT="20999"
SSH_PORT="2222"
BIND="0.0.0.0"
ADVERTISE=""
IMAGE="lcars-fleet:local"
RUNNER_LABELS=""
WITH_RUNNER=1
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
    --bench)      shift ;;
    --bind)       BIND="${2:?}"; shift 2 ;;
    --advertise)  ADVERTISE="${2:?}"; shift 2 ;;
    --image)      IMAGE="${2:?}"; shift 2 ;;
    --runner-labels) RUNNER_LABELS="${2:?}"; shift 2 ;;
    --no-runner)  WITH_RUNNER=0; shift ;;
    --creds-from) CREDS_FROM="${2:?}"; shift 2 ;;
    --no-creds)   WITH_CREDS=0; shift ;;
    --human)      HUMAN="${2:?}"; shift 2 ;;
    -h|--help)    sed -n '/^# USAGE/,/^#         conteneur en échec/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "bench-up: option inconnue: $1" >&2; exit 1 ;;
  esac
done

CONTAINER_PROJECT="${PROJECT}-fleet"
FORGE_PROJECT="${PROJECT}-forge"
RUNNER_PROJECT="${PROJECT}-runner"
FORGE_CONTAINER="${FORGE_PROJECT}-gitea-1"
FORGE_NET="${FORGE_PROJECT}_default"
CONTAINER="${CONTAINER_PROJECT}-lcars-1"
COMPOSE_ARGS=(-f "$DOCKER_DIR/docker-compose.yml" -f "$DOCKER_DIR/docker-compose.bench.yml" -p "$CONTAINER_PROJECT")
ADMIRAL="admiral"

# shellcheck source=../../lib/provision-lib.sh
source "$DOCKER_DIR/../lib/provision-lib.sh"
# shellcheck source=../../lib/store.sh
source "$DOCKER_DIR/../lib/store.sh"
# shellcheck source=../../lib/forge-bootstrap.sh
source "$DOCKER_DIR/../lib/forge-bootstrap.sh"

case "$BIND" in
  0.0.0.0|::|"*") PROBE_HOST="127.0.0.1" ;;
  *)              PROBE_HOST="$BIND" ;;
esac
if [[ -z "$ADVERTISE" ]]; then
  advertise_addr "$BIND"; ADVERTISE="$PROV_ADVERTISE"
  ADVERTISE_GUESSED="${PROV_ADVERTISE_WHY:-}"
fi
FORGE_LOCAL_URL="http://${PROBE_HOST}:${FORGE_PORT}"
FORGE_URL="http://${ADVERTISE}:${FORGE_PORT}"
# l'adresse par laquelle un conteneur de job atteint cette machine : ni le nom de service compose
# (le runner est en dind, réseau par job), ni l'adresse annoncée (localhost sous WSL est le conteneur)
if [[ "$(detect_substrate)" == "wsl" ]]; then
  JOB_HOST="host.docker.internal"
else
  JOB_HOST="$(lan_addr)"; JOB_HOST="${JOB_HOST:-$ADVERTISE}"
fi
ADMIRAL_PW="$(bench_admiral_password)"
HUMAN_PW="$(bench_human_password)"

say() { printf '[bench-up] %s\n' "$*"; }
die() { printf '[bench-up] %s\n' "$*" >&2; exit "${2:-1}"; }
d()   { "$DOCKER_BIN" "$@"; }
in_container() { d exec -i -u root "$CONTAINER" "$@"; }
as_human()     { d exec -i -u "$HUMAN" "$CONTAINER" "$@"; }
attendre_healthy() {
  local i
  for i in $(seq 1 90); do
    [[ "$(d inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null)" == "healthy" ]] && return 0
    sleep 2
  done
  return 1
}

# ─── Le terrain ─────────────────────────────────────────────────────────────────────────────────
for _outil in curl python3 git; do
  command -v "$_outil" >/dev/null 2>&1 || die "$_outil requis sur ce poste (le banc lit la forge par son API et sème sa source)" 1
done
[[ "$DOCKER_BIN" == */* ]] && { [[ -f "$DOCKER_BIN" && -x "$DOCKER_BIN" ]] || die "docker introuvable (DOCKER_BIN=$DOCKER_BIN)"; } \
  || command -v "$DOCKER_BIN" >/dev/null || die "docker introuvable (DOCKER_BIN=$DOCKER_BIN)"
if [[ -z "${DOCKER_HOST:-}" ]]; then
  DD_SOCK="/mnt/wsl/docker-desktop/shared-sockets/guest-services/docker.proxy.sock"
  if [[ -S "$DD_SOCK" && -w "$DD_SOCK" ]]; then
    export DOCKER_HOST="unix://$DD_SOCK"
    say "daemon : socket Docker Desktop directe"
  elif [[ -n "${LCARS_DOCKER_RELAY_SOCK:-}" && -S "$LCARS_DOCKER_RELAY_SOCK" ]]; then
    export DOCKER_HOST="unix://$LCARS_DOCKER_RELAY_SOCK"
    say "daemon : relais $LCARS_DOCKER_RELAY_SOCK (la sonde de flux dira s'il est amputé)"
  fi
fi
d version --format '{{.Server.Version}}' >/dev/null 2>&1 \
  || die "aucun daemon docker joignable (DOCKER_HOST=${DOCKER_HOST:-<vide>}) — Docker Desktop est-il lancé ?" 1
d image inspect "$IMAGE" >/dev/null 2>&1 \
  || die "image absente localement : $IMAGE — la tirer (deploy/container pull) ou la bâtir (deploy/pack.sh)" 1
IMAGE_REV="$(d image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$IMAGE" 2>/dev/null || true)"
if [[ -z "$IMAGE_REV" || "$IMAGE_REV" == "unknown" ]]; then
  IMAGE_REV_STATE="INCONNUE — image bâtie sans GIT_SHA : ce banc ne pourra attribuer aucun verdict à un commit"
else
  IMAGE_REV_STATE="$IMAGE_REV"
fi
PROBE="$(d run --rm --entrypoint sh "$IMAGE" -c 'echo flux-ok' 2>/dev/null | tr -d '[:space:]')"
[[ "$PROBE" == "flux-ok" ]] || die \
  "le daemon répond mais un flux attaché revient vide (reçu : '${PROBE:-<rien>}') — DOCKER_HOST=${DOCKER_HOST:-<vide>}
   C'est le relais systemd : il ne supporte pas le hijack HTTP de docker exec/run/cp.
   Sortie connue (root, une fois par démarrage de Docker Desktop) :
     sudo chgrp fleet /mnt/wsl/docker-desktop/shared-sockets/guest-services/docker.proxy.sock
     sudo chmod 660  /mnt/wsl/docker-desktop/shared-sockets/guest-services/docker.proxy.sock" 1
_noms="$(d ps -a --format '{{.Names}}')"
if grep -qx -- "$CONTAINER" <<<"$_noms"; then
  die "le projet $PROJECT existe déjà ($CONTAINER) — le détruire d'abord (bench-down.sh --project $PROJECT --yes) ou changer --forge-project" 1
fi
BUSY=()
for _p in "$SSH_PORT" "$DECK_PORT" "$FORGE_PORT"; do
  _h="$(port_state "$_p" "$CONTAINER_PROJECT" "$FORGE_PROJECT" "$RUNNER_PROJECT")"
  [[ "$_h" != pris* ]] || BUSY+=("$_p -> ${_h#pris}")
done
if [[ ${#BUSY[@]} -gt 0 ]]; then
  say "refus : un autre conteneur ou un processus tient déjà un des ports de ce banc."
  for _b in "${BUSY[@]}"; do say "  $_b"; done
  say "  Un bind « $BIND » prend le port sur toutes les adresses : il n'y a qu'un banc par port."
  say "  Sorties : détruire l'autre banc (bench-down.sh --project <son-projet> --yes),"
  say "            ou déplacer celui-ci (--port-forge / --port-deck / --port-ssh, et --bind pour une loopback)."
  exit 1
fi

# ─── La forge ───────────────────────────────────────────────────────────────────────────────────
# un succès est une ligne, un échec montre la sortie : compose et tofu parlent beaucoup quand tout va bien
quiet() { # quiet <cmd…> — la sortie n'apparaît que si la commande échoue (40 dernières lignes)
  local out rc=0; out="$(mktemp "${TMPDIR:-/tmp}/bench-up.XXXXXX")"
  "$@" > "$out" 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]] || tail -n 40 "$out" >&2
  rm -f "$out"
  return "$rc"
}
say "forge jetable : projet $FORGE_PROJECT sur $FORGE_URL"
quiet forge_mount "$DOCKER_BIN" "$DOCKER_DIR/forge-compose.yml" "$FORGE_PROJECT" "$FORGE_PORT" "$BIND" "$FORGE_URL" \
  || die "la forge ne monte pas" 2
forge_wait "$FORGE_LOCAL_URL" || die "la forge ne répond pas sur $FORGE_LOCAL_URL" 2
say "forge up"

# ─── Le conteneur ───────────────────────────────────────────────────────────────────────────────
export LCARS_STORE_PREFIX="$CONTAINER_PROJECT"
store_ensure_volumes "$DOCKER_BIN" || die "magasin non posé — le conteneur ne peut pas se créer" 3
say "conteneur : projet $CONTAINER_PROJECT, image $IMAGE, bind $BIND"
# le conteneur matérialise admiral (uid 1000) ; l'humain vient de la forge, par le convergeur.
# Le deck compare exactement l'entrée annoncée à son client OAuth2 : on ne nomme que celle-là, le
# module 66 sème les deux écritures de la loopback.
quiet env LCARS_IMAGE="$IMAGE" \
    LCARS_ADMIRAL="$ADMIRAL" \
    FORGE_BASE_URL="http://gitea:3000" \
    LCARS_SOURCE_REMOTE="http://gitea:3000/fleet/lcars.git" \
    LCARS_BIND="$BIND" \
    LCARS_SSH_PORT="${BIND}:${SSH_PORT}" \
    LCARS_LANDING_PORT_BIND="${BIND}:${DECK_PORT}" \
    FORGE_PUBLIC_URL="$FORGE_URL" \
    LCARS_DECK_ORIGINS="http://${ADVERTISE}:${DECK_PORT}" \
    LCARS_DEVFORGE_NETWORK="$FORGE_NET" \
    "$DOCKER_BIN" compose "${COMPOSE_ARGS[@]}" create lcars \
  || die "le conteneur ne se crée pas (le réseau $FORGE_NET existe-t-il ? les volumes du magasin ?)" 3
quiet d compose "${COMPOSE_ARGS[@]}" start lcars || die "le conteneur ne démarre pas" 3
attendre_healthy || die "le conteneur ne devient pas healthy (docker logs $CONTAINER)" 3
say "conteneur healthy"
if printf '%s:%s\n' "$ADMIRAL" "$ADMIRAL_PW" | in_container chpasswd 2>/dev/null; then
  say "mot de passe de banc posé sur $ADMIRAL (ssh, sudo)"
else
  say "$ADMIRAL : mot de passe unix non posé — ssh par clé, ou docker exec -u $ADMIRAL $CONTAINER bash"
fi

# ─── L'amorçage : admin, jeton, seed, structure, humain ─────────────────────────────────────────
say "amorçage de la forge : compte $ADMIRAL, jeton master, seed"
case "$(forge_admin_ensure "$DOCKER_BIN" "$FORGE_CONTAINER" "$ADMIRAL" "$ADMIRAL_PW")" in
  cree)    say "compte $ADMIRAL créé (site-admin de la forge)" ;;
  present) forge_admin_password "$DOCKER_BIN" "$FORGE_CONTAINER" "$ADMIRAL" "$ADMIRAL_PW" \
             || die "rotation du mot de passe de $ADMIRAL impossible" 4
           say "compte $ADMIRAL déjà présent — mot de passe de banc reposé" ;;
  *)       die "création du compte $ADMIRAL impossible" 4 ;;
esac
MASTER_TOKEN="$(forge_master_token "$DOCKER_BIN" "$FORGE_CONTAINER" "$ADMIRAL" "bench-$(date +%s)")" \
  || die "la forge n'a pas rendu de jeton master" 4
forge_token_ok "$FORGE_LOCAL_URL" "$MASTER_TOKEN" || die "le jeton master ne s'authentifie pas" 4
say "jeton master minté"
SEED_PW="$(in_container cat /opt/lcars/var/tokens/forge-seed.pass 2>/dev/null | tr -d '\r\n' || true)"
if [[ -z "$SEED_PW" ]]; then
  SEED_PW="$(forge_seed_new)"; say "seed de banc généré"
else
  say "seed relu depuis $CONTAINER (celui des comptes existants)"
fi

# le roster des rôles vient du catalogue de l'image, jamais d'un clone de l'hôte
ENROLL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bench-enroll.XXXXXX")"
ENROLL_OUT="$("$REPO_ROOT/deploy/lib/enroll-catalogue.sh" --tofu-dir "$ENROLL_DIR" --image "$IMAGE" 2>/dev/null)" \
  || die "dérivation du roster en échec (enroll-catalogue.sh, image $IMAGE)" 4
ORG="$(printf '%s\n' "$ENROLL_OUT" | sed -n 's/^PROV_FORGE_ORG="\(.*\)"$/\1/p')"; ORG="${ORG:-fleet}"
say "roster dérivé du catalogue $(printf '%s\n' "$ENROLL_OUT" | sed -n 's/^PROV_ROLES=//p') · org $ORG"
d cp "$ENROLL_DIR/roles.auto.tfvars.json" "$CONTAINER:/opt/lcars/services/forge-recipe/roles.auto.tfvars.json" \
  || die "roster non déposé dans la recette de $CONTAINER" 4
rm -rf "$ENROLL_DIR"

printf '%s' "$MASTER_TOKEN" | in_container /opt/lcars/forge-gestures.sh config-token || die "jeton master refusé par le conteneur" 4
printf '%s' "$SEED_PW"      | in_container /opt/lcars/forge-gestures.sh config-seed  || die "seed non posé dans le conteneur" 4
quiet d exec -i -u root -e LCARS_BUILTIN_HUMAN="$HUMAN" -e LCARS_BUILTIN_EMAIL="$HUMAN@lcars.local" \
    "$CONTAINER" /opt/lcars/forge-gestures.sh apply < /dev/null \
  || die "structure de la forge en échec dans $CONTAINER (rejouer : docker exec -u root $CONTAINER /opt/lcars/forge-gestures.sh apply)" 4
say "structure posée par le conteneur (org $ORG, teams, comptes, adhésions, dépôt modèle)"

HUMAN_TOKEN="$(bench_human_seed "$FORGE_LOCAL_URL" "$MASTER_TOKEN" "$HUMAN" "$HUMAN_PW")" \
  || die "humain $HUMAN : mot de passe, adminité ou jeton opérateur refusés par la forge" 5
say "humain $HUMAN : mot de passe de banc posé, site-admin, jeton opérateur minté"

charte_out="$(d exec "$CONTAINER" bash -c \
    'cd /opt/lcars/services/forge-recipe && ./provision-forge-charte.sh --forge "$FORGE_BASE_URL" --admiral "'"$ADMIRAL"'" --check' 2>&1)" || true
printf '%s\n' "$charte_out" | while IFS= read -r l; do [[ -z "$l" ]] || say "charte: $l"; done

# ─── La relance : 63 minte les jetons de rôle, le convergeur matérialise l'humain ──────────────
say "relance du conteneur : les jetons de rôle se mintent au boot, sur le seed"
d restart "$CONTAINER" >/dev/null || die "relance du conteneur impossible" 3
attendre_healthy || die "le conteneur ne redevient pas healthy après relance" 3
as_human id -u "$HUMAN" >/dev/null 2>&1 \
  || die "l'humain '$HUMAN' n'existe pas dans le conteneur après la relance — il vient de la forge (team $ORG:humans), matérialisé par le convergeur : docker logs $CONTAINER" 5
printf '%s\n' "$HUMAN_TOKEN" | as_human bash -c 'umask 077 && cat > ~/.gitea_token' \
  || die "jeton opérateur non posé chez $HUMAN dans $CONTAINER" 5
say "jeton opérateur posé (~$HUMAN/.gitea_token)"
printf '%s:%s\n' "$HUMAN" "$HUMAN_PW" | in_container chpasswd 2>/dev/null \
  && say "mot de passe de banc posé sur $HUMAN (ssh)" \
  || say "$HUMAN : mot de passe unix non posé — ssh par clé"

if [[ "$WITH_CREDS" -eq 0 ]]; then
  say "creds claude non posées (--no-creds) — aucun pod ne pourra penser, par choix"
elif [[ ! -r "$CREDS_FROM" ]]; then
  say "creds claude absentes ($CREDS_FROM) — non posées chez $HUMAN, aucun pod ne pourra penser ; le banc continue"
  WITH_CREDS=0
fi
if [[ "$WITH_CREDS" -eq 1 ]]; then
  as_human bash -c 'mkdir -p ~/.claude && cat > ~/.claude/.credentials.json && chmod 600 ~/.claude/.credentials.json' \
    < "$CREDS_FROM" || die "creds non posées dans le conteneur" 5
  say "creds claude posées chez $HUMAN"
fi

# ─── Le semis des dépôts : la source que le conteneur clone, à la révision de l'image ──────────
SYS_TOKEN="$(in_container cat "/opt/lcars/var/tokens/${LCARS_SYSTEM_ACCOUNT:-system_starfleet}.gitea_token" 2>/dev/null | tr -d '[:space:]' || true)"
[[ -n "$SYS_TOKEN" ]] || die "jeton système absent après la relance — le banc n'est pas prêt (docker logs $CONTAINER)" 6
git_forge() {
  GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0="http.${FORGE_LOCAL_URL%/}/.extraheader" \
  GIT_CONFIG_VALUE_0="Authorization: token ${SYS_TOKEN}" \
  git "$@"
}
printf 'header = "Authorization: token %s"\nheader = "Content-Type: application/json"\nrequest = "POST"\ndata = "{\\"name\\":\\"lcars\\",\\"description\\":\\"LCARS — la source du conteneur\\",\\"private\\":false,\\"auto_init\\":false}"\n' "$SYS_TOKEN" \
  | curl -K - -s -m 10 -o /dev/null "$FORGE_LOCAL_URL/api/v1/orgs/$ORG/repos" 2>/dev/null || true
LCARS_REMOTE="${FORGE_LOCAL_URL%/}/$ORG/lcars.git"
[[ -n "$IMAGE_REV" && "$IMAGE_REV" != "unknown" ]] \
  || die "$ORG/lcars : l'image $IMAGE ne porte pas de révision (label OCI) — le banc ne sème pas un code qu'il ne peut pas nommer" 7
if [[ -d "$REPO_ROOT/.git" ]]; then
  git -C "$REPO_ROOT" rev-parse -q --verify "${IMAGE_REV}^{commit}" >/dev/null 2>&1 \
    || die "$ORG/lcars : la révision de l'image ($IMAGE_REV) n'est pas dans ce clone ($REPO_ROOT) — le banc sème le code du conteneur ; rebâtir l'image depuis ce clone" 7
  SEED_DIR="$REPO_ROOT"; SEED_REF="$IMAGE_REV"; SEED_DIT="révision de l'image : $IMAGE_REV"
else
  # un kit n'a pas d'historique : sa révision est dans .source-revision, et le semis est un commit unique bâti de son arbre
  KIT_REV="$(tr -d '[:space:]' < "$REPO_ROOT/.source-revision" 2>/dev/null || true)"
  [[ -n "$KIT_REV" && ( "$IMAGE_REV" == "$KIT_REV"* || "$KIT_REV" == "$IMAGE_REV"* ) ]] \
    || die "$ORG/lcars : ce kit atteste « ${KIT_REV:-aucune révision} » et l'image $IMAGE porte $IMAGE_REV — le banc sème le code du conteneur ; prendre le kit de cette image" 7
  SEED_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lcars-seed.XXXXXX")"
  git -C "$SEED_DIR" init -q
  git --git-dir="$SEED_DIR/.git" --work-tree="$REPO_ROOT" add -A
  git --git-dir="$SEED_DIR/.git" -c user.name=lcars-bench -c user.email=bench@lcars.invalid commit -q -m "kit $KIT_REV" >/dev/null
  SEED_REF="$(git -C "$SEED_DIR" rev-parse HEAD)"; SEED_DIT="kit $KIT_REV, un commit sans historique"
fi
seed_hooks=(); seed_force=()
remote_main="$(git_forge ls-remote --heads "$LCARS_REMOTE" refs/heads/main 2>/dev/null | awk '{print $1}' || true)"
if [[ -n "$remote_main" ]] && ! git -C "$SEED_DIR" merge-base --is-ancestor "$remote_main" "$SEED_REF" 2>/dev/null; then
  say "$ORG/lcars : main existe déjà sur la forge de banc (${remote_main:0:9}) et n'est pas un ancêtre de $SEED_REF — rejeu sur une forge jetable, poussé de force"
  seed_hooks=(-c core.hooksPath=/dev/null); seed_force=(--force)
fi
PUSH_ERR="$(git_forge -C "$SEED_DIR" ${seed_hooks[@]+"${seed_hooks[@]}"} push -q ${seed_force[@]+"${seed_force[@]}"} "$LCARS_REMOTE" "${SEED_REF}:refs/heads/main" 2>&1)" \
  || die "$ORG/lcars : main non poussé — c'est le dépôt ops de la fleet ; sans lui le banc n'a pas de code
  git a dit : $PUSH_ERR" 7
[[ "$SEED_DIR" == "$REPO_ROOT" ]] || rm -rf "$SEED_DIR"
say "$ORG/lcars : main poussé ($SEED_DIT)"
WORK_TREE="${LCARS_WORK_TREE:-}"
if [[ -z "$WORK_TREE" ]]; then
  say "$ORG/lcars : ops non poussé (LCARS_WORK_TREE non posé — le clone qui porte la branche ops, si le banc doit l'avoir)"
elif [[ -d "$WORK_TREE/.git" ]]; then
  if git -C "$WORK_TREE" push -q "$LCARS_REMOTE" ops:ops 2>/dev/null; then say "$ORG/lcars : ops poussé"; else say "$ORG/lcars : ops non poussé (push refusé depuis $WORK_TREE)"; fi
else
  say "$ORG/lcars : ops non poussé (LCARS_WORK_TREE=$WORK_TREE n'est pas un clone)"
fi

# ─── L'état du conteneur, le runner, la fleet ───────────────────────────────────────────────────
ROLE_TOKENS="$(in_container bash -c 'ls /opt/lcars/var/tokens/*.gitea_token 2>/dev/null | wc -l' || echo 0)"
CREDS_OK="$(as_human bash -c '[ -s ~/.claude/.credentials.json ] && echo oui || echo non')"
CONTAINER_PROV_RC="$(in_container cat /run/lcars-forge.rc 2>/dev/null | tr -d '[:space:]' || true)"
[[ "$CONTAINER_PROV_RC" =~ ^[0-9]+$ ]] || CONTAINER_PROV_RC=""
CONTAINER_PROV_OK=1
case "$CONTAINER_PROV_RC" in
  0)  CONTAINER_PROV_STATE="convergé" ;;
  2)  CONTAINER_PROV_STATE="appliqué avec drift résiduel — un geste manque, rien n'est cassé (docker exec $CONTAINER /opt/lcars/deploy/provision doctor le nomme)" ;;
  "") CONTAINER_PROV_STATE="non mesuré — /run/lcars-forge.rc illisible dans le conteneur (il n'a peut-être pas fini de converger)" ;;
  *)  CONTAINER_PROV_STATE="en échec (rc=$CONTAINER_PROV_RC) — le conteneur tourne et ne produira rien (docker exec $CONTAINER /opt/lcars/deploy/provision doctor)"
      CONTAINER_PROV_OK=0 ;;
esac

RUNNER_STATE="non démarré"
RUNNER_SERT=0
[[ -n "$RUNNER_LABELS" ]] || RUNNER_LABELS="shell:docker://alpine:3.20,dood:docker://docker:cli,ubuntu-latest:docker://catthehacker/ubuntu:act-latest"
if [[ "$WITH_RUNNER" -eq 0 ]]; then
  RUNNER_STATE="non démarré (--no-runner) — aucun workflow CI ne tournera sur ce banc, par choix"
else
  RUNNER_LOG="$(mktemp "${TMPDIR:-/tmp}/forge-runner-${PROJECT}.XXXXXX")"
  REG_TOKEN="$(in_container /opt/lcars/forge-gestures.sh runner-token < /dev/null 2>/dev/null | tail -1 || true)"
  if DOCKER_BIN="$DOCKER_BIN" "$DOCKER_DIR/forge-runner.sh" \
       --forge-api "$FORGE_LOCAL_URL/api/v1" --admin-token "$MASTER_TOKEN" \
       ${REG_TOKEN:+--reg-token "$REG_TOKEN"} \
       --instance-url "http://${JOB_HOST}:${FORGE_PORT}" --network "$FORGE_NET" \
       --project "$RUNNER_PROJECT" --labels "$RUNNER_LABELS" >"$RUNNER_LOG" 2>&1; then
    RUNNERS="$(printf 'header = "Authorization: token %s"\n' "$MASTER_TOKEN" \
      | curl -K - -s -m 5 "$FORGE_LOCAL_URL/api/v1/admin/actions/runners" 2>/dev/null \
      | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    rs = d.get("runners", d if isinstance(d, list) else [])
    print(len(rs))
except Exception: print(0)' 2>/dev/null || echo 0)"
    if [[ "${RUNNERS:-0}" -gt 0 ]]; then
      RUNNER_VER="$(d exec "${RUNNER_PROJECT}-act-1" gitea-runner --version 2>/dev/null | head -1 || true)"
      RUNNER_IMG="$(d inspect "${RUNNER_PROJECT}-act-1" --format '{{.Config.Image}}' 2>/dev/null || true)"
      RUNNER_STATE="enregistré ($RUNNERS vu(s) par la forge)
              ${RUNNER_VER:-version illisible} · image ${RUNNER_IMG:-inconnue}
              labels : ${RUNNER_LABELS:-aucun}"
      RUNNER_SERT=1
    else
      RUNNER_STATE="démarré mais aucun runner vu par la forge — enregistrement raté"
    fi
  else
    RUNNER_STATE="absent — forge-runner.sh en échec, son refus mot pour mot :
$(sed 's/^/              /' "$RUNNER_LOG" 2>/dev/null | tail -12)
              sortie complète conservée : $RUNNER_LOG"
  fi
  [[ "$RUNNER_SERT" -eq 1 ]] && rm -f "$RUNNER_LOG"
fi

# la fleet démarre sous l'humain ; sans credentials claude elle tourne sans penser, et c'est dit
FLEET_STATE="non démarrée"
if [[ "$CONTAINER_PROV_OK" -eq 1 ]]; then
  if [[ "$CREDS_OK" == oui ]]; then fleet_env=(); else fleet_env=(LCARS_START_WITHOUT_CLAUDE=1); fi
  if d exec -u "$HUMAN" "$CONTAINER" env ${fleet_env[@]+"${fleet_env[@]}"} fleet start >/dev/null 2>&1; then
    FLEET_STATE="démarrée sous $HUMAN$([[ "$CREDS_OK" == oui ]] || printf ' (sans credentials claude : aucun pod ne pense)')"
  else
    FLEET_STATE="« fleet start » a échoué sous $HUMAN — docker exec -u $HUMAN $CONTAINER fleet start pour lire sa plainte"
  fi
fi

if [[ "$CONTAINER_PROV_OK" -ne 1 ]]; then
  VERDICT="banc PAS PRÊT — le conteneur s'est déclaré en échec de convergence"
elif [[ "$WITH_RUNNER" -eq 0 ]]; then
  VERDICT="banc PRÊT sans CI"
elif [[ "$RUNNER_SERT" -eq 1 ]]; then
  VERDICT="banc PRÊT"
else
  VERDICT="banc PAS PRÊT — le runner était demandé et ne sert pas"
fi
say "───────────────────────────────────────────────────────"
say "$VERDICT"
say "  forge     : $FORGE_URL   ($ADMIRAL / $ADMIRAL_PW · $HUMAN / $HUMAN_PW)"
say "  deck      : http://${ADVERTISE}:${DECK_PORT}"
say "  conteneur : $CONTAINER   ssh $HUMAN@${ADVERTISE} -p ${SSH_PORT}"
if [[ "$BIND" == "0.0.0.0" || "$BIND" == "::" ]]; then
  say "  écoute    : $BIND — ouvert sur le réseau ; les mots de passe de ce banc sont des défauts de"
  say "              test, publics : à n'ouvrir que sur un réseau de confiance. « --bind 127.0.0.1 » le referme."
  if [[ -n "${ADVERTISE_GUESSED:-}" ]]; then
    say "  adresse   : les liens pointent sur $ADVERTISE. ${ADVERTISE_GUESSED}"
    say "              « --advertise <ip-ou-nom> » pour annoncer autre chose."
  fi
  if [[ "$(detect_substrate)" == "wsl" && "$(wsl_networking_mode)" == "nat" ]]; then
    say "  portée    : WSL en mode NAT (le défaut) — ce banc n'est joignable que depuis cette machine."
  fi
else
  say "  écoute    : $BIND (cette machine seulement)"
fi
say "  image     : $IMAGE"
say "  révision  : $IMAGE_REV_STATE"
say "  runner    : $RUNNER_STATE"
say "  jetons    : $ROLE_TOKENS fichiers dans /opt/lcars/var/tokens"
say "  creds     : $CREDS_OK"
say "  fleet     : $FLEET_STATE"
say "  converge  : $CONTAINER_PROV_STATE"
say "  détruire  : bench-down.sh --project $PROJECT --yes"
say "───────────────────────────────────────────────────────"
if [[ "$CONTAINER_PROV_OK" -ne 1 ]]; then
  die "le conteneur a publié un échec de convergence ($CONTAINER_PROV_STATE) — banc incomplet ; il tourne et reste joignable pour être réparé, et ne produira rien tant que la convergence n'est pas verte" 6
fi
if [[ "$WITH_RUNNER" -eq 1 && "$RUNNER_SERT" -ne 1 ]]; then
  die "runner demandé et non servi ($RUNNER_STATE) — banc incomplet ; « --no-runner » pour un banc sans CI, assumé et dit comme tel" 6
fi
