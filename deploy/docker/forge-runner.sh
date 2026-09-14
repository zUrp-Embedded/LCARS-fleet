#!/usr/bin/env bash
# SOURCE: deploy/docker/forge-runner.sh
# AUTHOR: consultant
# STARDATE: 2026-09-13
# STATUS: l'enrôlement d'un runner CI sur la forge jetable — jeton d'enregistrement, réseau de la forge, images des labels, preuve par la forge
#
# USAGE : forge-runner.sh --forge-api <url-api avec /api/v1> --admin-token-file <chemin>
#                         --network <réseau compose de la forge> --project <projet compose du runner>
#                         [--instance-url <adresse de la forge vue du runner>] [--reg-token-file <chemin>] [--labels <liste>]
#   --instance-url   défaut : l'adresse interne de la forge, PROV_FORGE_INTERNAL_URL
#   --labels         défaut : PROV_RUNNER_LABELS ; chaque image docker:// nommée est vérifiée, puis semée
# EXIT  : 0 runner enregistré · 1 arguments, ou label dont l'image est introuvable · 2 la forge ne rend pas
#         de jeton d'enregistrement · 3 le runner ne se monte pas, son daemon embarqué ne répond pas, une
#         image n'y est pas semée, ou la forge ne le liste pas
#
# Rejouable après chaque destruction de la forge : l'identité d'un runner appairé à une forge morte
# survit dans le volume du projet, d'où le `down -v` avant chaque pose.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/provision-lib.sh
. "$HERE/../lib/provision-lib.sh"
# réseau et projet n'ont pas de défaut : un défaut qui viserait un autre déploiement enrôlerait le
# runner à côté de sa forge, et la CI resterait muette sans une ligne pour le dire
FORGE_API="" ; TOKEN_FILE="" ; REG_FILE="" ; INSTANCE_URL="$PROV_FORGE_INTERNAL_URL" ; NETWORK=""
PROJECT="" ; LABELS="$PROV_RUNNER_LABELS" ; DOCKER_BIN="${DOCKER_BIN:-docker}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --forge-api)    FORGE_API="${2:?}"; shift 2 ;;
    # les jetons arrivent par fichier : un argv se lit dans /proc par tout l'hôte
    --admin-token-file) TOKEN_FILE="${2:?}"; shift 2 ;;
    --reg-token-file)   REG_FILE="${2:?}"; shift 2 ;;
    --instance-url) INSTANCE_URL="${2:?}"; shift 2 ;;
    --network)      NETWORK="${2:?}"; shift 2 ;;
    --project)      PROJECT="${2:?}"; shift 2 ;;
    --labels)       LABELS="${2:?}"; shift 2 ;;
    *) echo "forge-runner : option inconnue : $1" >&2; exit 1 ;;
  esac
done
[[ -n "$FORGE_API" && -n "$(read_token "$TOKEN_FILE")" ]] || { echo "forge-runner : --forge-api et --admin-token-file (non vide) requis" >&2; exit 1; }
[[ -n "$NETWORK" && -n "$PROJECT" ]] || { echo "forge-runner : --network et --project requis (le réseau compose de la forge visée)" >&2; exit 1; }

say() { echo "[forge-runner] $*"; }

check_labels() {
  # une image absente se tire avant d'être refusée : les images publiques n'ont jamais été tirées sur une machine neuve
  local missing=()
  local entry image
  local IFS=,
  for entry in $LABELS; do
    image="${entry#*docker://}"
    [[ "$image" == "$entry" ]] && continue
    "$DOCKER_BIN" image inspect "$image" >/dev/null 2>&1 && continue
    say "image absente, tentative de tirage : $image"
    "$DOCKER_BIN" pull -q "$image" >/dev/null 2>&1 || true
    "$DOCKER_BIN" image inspect "$image" >/dev/null 2>&1 || missing+=("$image")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    say "REFUS : image(s) introuvable(s) sur ce daemon, et non tirables : ${missing[*]}"
    say "  un runner annonce le label quand même et rate chaque job qui le demande."
    say "  la bâtir (deploy/pack.sh pose lcars-fleet:<tag>), la tirer d'un registre, ou corriger --labels."
    exit 1
  fi
  say "labels : ${LABELS//,/ }"
}

check_labels

# le jeton d'enregistrement se minte par l'API admin ; un jeton admin peut en être refusé (403), et
# --reg-token-file apporte alors celui que la forge mint depuis son conteneur
REG="$(read_token "$REG_FILE")"
if [[ -n "$REG" ]]; then
  say "jeton d'enregistrement fourni (--reg-token-file), pas d'appel API"
else
  REG_BODY="$(mktemp)"
  forge_api POST "$FORGE_API/admin/actions/runners/registration-token" "$REG_BODY" --token-file "$TOKEN_FILE" -m 10 >/dev/null || true
  REG="$(jq -r '.token // empty' "$REG_BODY" 2>/dev/null || true)"
  rm -f "$REG_BODY"
fi
[[ -n "$REG" ]] || {
  say "la forge n'a pas rendu de jeton d'enregistrement (portée du jeton ? --reg-token-file)"
  exit 2
}
say "jeton d'enregistrement prêt (${#REG} caractères)"

compose_runner() { "$DOCKER_BIN" compose --env-file "$PROV_CONSTANTS_FILE" -f "$HERE/runner-compose.yml" -f "$HERE/runner-network.yml" -p "$PROJECT" "$@"; }

LCARS_RUNNER_NETWORK="$NETWORK" compose_runner down -v >/dev/null 2>&1 || true
LCARS_RUNNER_NETWORK="$NETWORK" LCARS_FORGE_URL="$INSTANCE_URL" LCARS_RUNNER_TOKEN="$REG" LCARS_RUNNER_LABELS="$LABELS" \
  compose_runner up -d \
  || { say "ÉCHEC : le runner ne se monte pas (sortie de compose au-dessus)"; exit 3; }
say "runner lancé (projet $PROJECT, réseau $NETWORK)"

# le daemon embarqué du runner démarre vide : les images publiques, il les tire ; les images
# locales que pack.sh pose sans les publier, il ne peut pas les connaître — elles sont semées
seed_dind_images() {
  local c="$PROJECT-act-1" out="" entry image
  dind_a() { [[ -n "$("$DOCKER_BIN" exec "$c" docker image inspect -f '{{.Id}}' "$1" 2>/dev/null)" ]]; }
  for _ in $(seq 1 30); do
    out="$("$DOCKER_BIN" exec "$c" docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
    [[ -n "$out" ]] && break
    sleep 2
  done
  [[ -n "$out" ]] || {
    say "REFUS : le daemon embarqué du runner ne rend rien après 60 s — il n'a pas démarré (privileged ?"
    say "  apparmor=rootlesskit ?) ou le chemin vers le daemon avale la sortie de « exec » ; rien ne peut être semé."
    exit 3
  }
  say "daemon embarqué du runner : docker $out"

  local IFS=,
  for entry in $LABELS; do
    image="${entry#*docker://}"
    [[ "$image" == "$entry" ]] && continue
    dind_a "$image" && continue
    if "$DOCKER_BIN" exec "$c" docker pull -q "$image" >/dev/null 2>&1 && dind_a "$image"; then
      continue
    fi
    say "image locale semée dans le daemon du runner : $image"
    "$DOCKER_BIN" save "$image" 2>/dev/null | "$DOCKER_BIN" exec -i "$c" docker load >/dev/null 2>&1 || true
    dind_a "$image" || {
      say "REFUS : $image absente du daemon du runner après semis — le label qui la nomme serait un mensonge"
      exit 3
    }
  done
  say "magasin du runner : toutes les images des labels sont résolubles"
}
seed_dind_images

# la preuve d'enregistrement est la liste de la forge, pas le journal du runner
SEEN=0
PROBE_HTTP=""
BODY="$(mktemp)"
for _ in $(seq 1 20); do
  sleep 3
  PROBE_HTTP="$(forge_api GET "$FORGE_API/admin/actions/runners" "$BODY" --token-file "$TOKEN_FILE" -m 5)" || true
  [[ ! "$PROBE_HTTP" =~ ^(401|403)$ ]] || break
  [[ "$PROBE_HTTP" == "200" ]] || continue
  n="$(jq '.runners // [] | length' "$BODY" 2>/dev/null || echo 0)"
  [[ "${n:-0}" -ge 1 ]] && { SEEN=1; say "enregistré : la forge liste $n runner(s)"; break; }
done
rm -f "$BODY"

if [[ "$SEEN" -ne 1 ]]; then
  if [[ "$PROBE_HTTP" =~ ^(401|403)$ ]]; then
    say "NON VÉRIFIÉ (HTTP $PROBE_HTTP sur /admin/actions/runners — portée du jeton) : le runner est"
    say "  peut-être enregistré, cette sonde ne peut pas le dire. À vérifier :"
    say "    $DOCKER_BIN logs ${PROJECT}-act-1 | grep -i 'registered successfully'"
    exit 0
  fi
  say "ÉCHEC : la forge ne liste aucun runner après 60 s (HTTP ${PROBE_HTTP:-?})"
  exit 3
fi

say "runner opérationnel — labels servis : $LABELS"
