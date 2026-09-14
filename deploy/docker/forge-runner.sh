#!/usr/bin/env bash
# SOURCE: deploy/docker/forge-runner.sh
# AUTHOR: consultant
# STARDATE: 2026-09-13
# STATUS: l'enrôlement d'un runner CI sur la forge jetable — jeton d'enregistrement, réseau des jobs, runner-compose.yml de l'opérateur, preuve par la forge
#
# USAGE : forge-runner.sh --forge-api <url-api avec /api/v1> --admin-token-file <chemin>
#                         --network <réseau compose de la forge> --project <projet compose du runner>
#                         [--instance-url http://gitea:3000] [--verify-repo fleet/lcars] [--reg-token-file <chemin>]
#                         [--labels "shell:docker://alpine:3.20,dood:docker://docker:cli,ubuntu-latest:docker://catthehacker/ubuntu:act-latest"]
#                         [--accept-generic]
# EXIT  : 0 runner enregistré (et job vérifié avec --verify-repo) · 1 arguments, ou label dont l'image
#         est introuvable · 2 la forge ne rend pas de jeton d'enregistrement · 3 le runner ne se monte
#         pas, son daemon embarqué ne répond pas, une image n'y est pas semée, ou la forge ne le liste
#         pas · 4 le job de vérification ne passe pas
#
# Rejouable après chaque destruction de la forge : l'identité d'un runner appairé à une forge morte
# survit dans le volume du projet, d'où le `down -v` avant chaque pose.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/provision-lib.sh
. "$HERE/../lib/provision-lib.sh"
# réseau et projet n'ont pas de défaut : un défaut qui viserait un autre déploiement enrôlerait le
# runner à côté de sa forge, et la CI resterait muette sans une ligne pour le dire
FORGE_API="" ; TOKEN_FILE="" ; INSTANCE_URL="$PROV_FORGE_INTERNAL_URL" ; NETWORK=""
PROJECT="" ; VERIFY_REPO="" ; DOCKER_BIN="${DOCKER_BIN:-docker}"
LABELS=""
ACCEPT_GENERIC=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --forge-api)    FORGE_API="${2:?}"; shift 2 ;;
    # les jetons arrivent par fichier : un argv se lit dans /proc par tout l'hôte
    --admin-token-file) TOKEN_FILE="${2:?}"; shift 2 ;;
    --reg-token-file)   REG_GIVEN="$(tr -d '[:space:]' < "${2:?}")"; shift 2 ;;
    --instance-url) INSTANCE_URL="${2:?}"; shift 2 ;;
    --network)      NETWORK="${2:?}"; shift 2 ;;
    --project)      PROJECT="${2:?}"; shift 2 ;;
    --verify-repo)  VERIFY_REPO="${2:?}"; shift 2 ;;
    --labels)       LABELS="${2:?}"; shift 2 ;;
    --accept-generic) ACCEPT_GENERIC=1; shift ;;
    *) echo "forge-runner : option inconnue : $1" >&2; exit 1 ;;
  esac
done
[[ -n "$FORGE_API" && -n "$(read_token "$TOKEN_FILE")" ]] || { echo "forge-runner : --forge-api et --admin-token-file (non vide) requis" >&2; exit 1; }
[[ -n "$NETWORK" && -n "$PROJECT" ]] || { echo "forge-runner : --network et --project requis (le réseau compose de la forge visée)" >&2; exit 1; }

say() { echo "[forge-runner] $*"; }

check_labels() {
  if [[ -z "$LABELS" ]]; then
    [[ "$ACCEPT_GENERIC" -eq 1 ]] && { say "labels : défaut générique accepté (--accept-generic) — ce runner ne sait pas jouer mix gate"; return 0; }
    cat >&2 <<EOM
[forge-runner] REFUS : aucun --labels, donc le défaut de runner-compose.yml — un défaut subi, et un
[forge-runner]   runner qui sert un label non voulu a l'air vert. Sorties :
[forge-runner]     forge-runner.sh … --labels "$PROV_RUNNER_LABELS"
[forge-runner]     --accept-generic, pour un banc qui ne veut que la CI du modèle de projet (une décision).
EOM
    exit 1
  fi

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
if [[ -n "${REG_GIVEN:-}" ]]; then
  REG="$REG_GIVEN"
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

# ce répertoire n'est pas nettoyé : override.yml est un -f de compose, inscrit dans les labels du
# projet, et l'effacer casserait tout compose ultérieur sur ce projet ; il ne porte aucun secret
# hors le jeton d'enregistrement, à usage unique
GEN="$(mktemp -d)"
# aucun réseau forcé pour les jobs : ils vivent sur le bridge du daemon embarqué, qui ne connaît pas
# le réseau de la forge, et un réseau inconnu fait échouer leur création
cat > "$GEN/config.yaml" <<'EOF'
# Généré par forge-runner.sh.
container:
  privileged: false
EOF
# le nom du service se lit dans runner-compose.yml, borné au bloc services (le bloc volumes a le même indent)
SERVICE="$(sed -nE '/^services:/,/^[a-z]/{ s/^  ([a-z][a-z0-9_-]*):[[:space:]]*$/\1/p }' "$HERE/runner-compose.yml" | head -n1)"
[[ -n "$SERVICE" ]] || { echo "forge-runner : service introuvable dans runner-compose.yml — l'override ne peut pas le nommer" >&2; exit 1; }
cat > "$GEN/override.yml" <<EOF
# Généré par forge-runner.sh — additif au runner-compose de l'opérateur, jamais un remplacement.
services:
  $SERVICE:
    environment:
      CONFIG_FILE: /data/bench-config.yaml
networks:
  default:
    name: $NETWORK
    external: true
EOF

# le jeton d'enregistrement voyage par un env-file 0600 ; le down porte des valeurs factices parce
# que runner-compose.yml exige LCARS_FORGE_URL même pour un down
RUNNER_ENV="$GEN/runner.env"
umask 077
printf 'LCARS_FORGE_URL=%s\nLCARS_RUNNER_TOKEN=%s\nLCARS_RUNNER_NAME=%s\nLCARS_RUNNER_LABELS=%s\n' \
  "$INSTANCE_URL" "$REG" "${LCARS_RUNNER_NAME:-lcars-runner}" "$LABELS" > "$RUNNER_ENV"
RUNNER_ENV_DOWN="$GEN/runner-down.env"
printf 'LCARS_FORGE_URL=%s\nLCARS_RUNNER_TOKEN=%s\n' "$INSTANCE_URL" " " > "$RUNNER_ENV_DOWN"

"$DOCKER_BIN" compose --env-file "$PROV_CONSTANTS_FILE" --env-file "$RUNNER_ENV_DOWN" -f "$HERE/runner-compose.yml" -f "$GEN/override.yml" -p "$PROJECT" down -v >/dev/null 2>&1 || true
pose_runner() {
  "$DOCKER_BIN" compose --env-file "$PROV_CONSTANTS_FILE" --env-file "$RUNNER_ENV" -f "$HERE/runner-compose.yml" -f "$GEN/override.yml" -p "$PROJECT" up --no-start \
    && "$DOCKER_BIN" cp "$GEN/config.yaml" "$PROJECT-act-1:/data/bench-config.yaml" \
    && "$DOCKER_BIN" compose --env-file "$PROV_CONSTANTS_FILE" --env-file "$RUNNER_ENV" -f "$HERE/runner-compose.yml" -f "$GEN/override.yml" -p "$PROJECT" start
}
pose_runner || { say "ÉCHEC : le runner ne se monte pas (compose ou copie de sa config, sortie au-dessus)"; exit 3; }
say "runner lancé (projet $PROJECT, réseau $NETWORK, config copiée dans le volume)"

# le daemon embarqué du runner démarre vide : les images publiques, il les tire ; les images
# locales que pack.sh pose sans les publier, il ne peut pas les connaître — elles sont semées
seed_dind_images() {
  local c="$PROJECT-act-1" out entry image
  for _ in $(seq 1 30); do
    out="$("$DOCKER_BIN" exec "$c" docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
    [[ -n "$out" ]] && break
    sleep 2
  done
  [[ -n "$out" ]] || {
    say "REFUS : le daemon embarqué du runner ne rend rien après 60 s."
    say "  soit il n'a pas démarré (privileged ? apparmor=rootlesskit ?), soit le chemin vers le daemon"
    say "  (contexte, proxy) avale la sortie de « exec » — dans les deux cas rien ne peut être semé, et"
    say "  un runner sans ses images locales annonce des labels qu'il ne sait pas servir."
    exit 3
  }
  say "daemon embarqué du runner : docker $out"

  local IFS=,
  for entry in $LABELS; do
    image="${entry#*docker://}"
    [[ "$image" == "$entry" ]] && continue
    [[ -n "$("$DOCKER_BIN" exec "$c" docker image inspect -f '{{.Id}}' "$image" 2>/dev/null || true)" ]] && continue
    if "$DOCKER_BIN" exec "$c" docker pull -q "$image" >/dev/null 2>&1 &&
       [[ -n "$("$DOCKER_BIN" exec "$c" docker image inspect -f '{{.Id}}' "$image" 2>/dev/null || true)" ]]; then
      continue
    fi
    say "image locale semée dans le daemon du runner : $image"
    "$DOCKER_BIN" save "$image" 2>/dev/null | "$DOCKER_BIN" exec -i "$c" docker load >/dev/null 2>&1 || true
    [[ -n "$("$DOCKER_BIN" exec "$c" docker image inspect -f '{{.Id}}' "$image" 2>/dev/null || true)" ]] || {
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
for _ in $(seq 1 20); do
  sleep 3
  body="$(mktemp)"
  PROBE_HTTP="$(forge_api GET "$FORGE_API/admin/actions/runners" "$body" --token-file "$TOKEN_FILE" -m 5)" || true
  if [[ "$PROBE_HTTP" == "200" ]]; then
    n="$(jq '.runners // [] | length' "$body" 2>/dev/null || echo 0)"
    rm -f "$body"
    [[ "${n:-0}" -ge 1 ]] && { SEEN=1; say "enregistré : la forge liste $n runner(s)"; break; }
  else
    rm -f "$body"
    [[ "$PROBE_HTTP" =~ ^(401|403)$ ]] && break
  fi
done

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

# un runner enregistré qui rate ses jobs est pire qu'un runner absent : la preuve de bout en bout est un verdict de job
if [[ -n "$VERIFY_REPO" ]]; then
  say "vérification de bout en bout sur $VERIFY_REPO…"
  ok=""
  # 20 min : le premier job servi à un runner neuf peut être le gate complet du dépôt lcars
  for _ in $(seq 1 200); do
    sleep 6
    body="$(mktemp)"
    forge_api GET "$FORGE_API/repos/$VERIFY_REPO/actions/tasks" "$body" --token-file "$TOKEN_FILE" -m 6 >/dev/null || true
    st="$(jq -r '(.workflow_runs // [])[0].status // empty' "$body" 2>/dev/null || true)"
    rm -f "$body"
    case "$st" in
      success) ok=1; break ;;
      failure|cancelled) say "ÉCHEC : le job de vérification finit en $st"; exit 4 ;;
    esac
  done
  # un run encore en attente n'est pas un échec du runner : l'enregistrement est prouvé plus haut
  if [[ -n "$ok" ]]; then
    say "PREUVE : un job a tourné et la forge rend un verdict vert"
  else
    say "run toujours en attente après 20 min — le runner est enregistré et la forge le liste,"
    say "  mais aucun verdict n'a été rendu. Ses journaux (docker logs) le diront :"
    say "  une file occupée et un runner mort se ressemblent d'ici."
  fi
fi

say "runner opérationnel — labels servis : ${LABELS:-le défaut de runner-compose.yml}"
