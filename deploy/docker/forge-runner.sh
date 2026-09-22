#!/usr/bin/env bash
# SOURCE: deploy/docker/forge-runner.sh
# AUTHOR: consultant
# STARDATE: 2026-09-13
# STATUS: l'enrôlement d'un runner CI sur une forge montée par l'installeur (poste ou banc) — jeton d'enregistrement, réseau de la forge, images des labels, preuve par la forge
#
# USAGE : forge-runner.sh --forge-api <url-api avec /api/v1> --admin-token-file <chemin>
#                         --network <réseau compose de la forge> --project <projet compose du runner>
#                         [--instance-url <adresse de la forge vue du runner>] [--reg-token-file <chemin>] [--labels <liste>]
#                         [--bench <base>]
#         forge-runner.sh --help
#   --instance-url   défaut : l'adresse interne de la forge, PROV_FORGE_INTERNAL_URL
#   --labels         défaut : PROV_RUNNER_LABELS ; chaque image docker:// nommée est vérifiée, puis semée
#   --bench          le runner d'un banc : lui et ses volumes portent le marqueur lcars.bench=<base> (runner-compose.bench.yml)
# EXIT  : 0 runner enregistré, ou enregistrement que la portée du jeton ne permet pas de vérifier (dit) · 1 arguments, ou label dont l'image est introuvable · 2 la forge ne rend pas
#         de jeton d'enregistrement · 3 le runner ne se monte pas, son daemon embarqué ne répond pas, une
#         image n'y est pas semée, ou la forge ne liste pas ce runner (l'id que son enregistrement écrit)
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
PROJECT="" ; LABELS="$PROV_RUNNER_LABELS" ; DOCKER_BIN="${DOCKER_BIN:-docker}" ; BENCH=""

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
    --bench)        BENCH="${2:?}"; shift 2 ;;
    -h|--help)      sed -n '/^# USAGE/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

COMPOSE_FICHIERS=(-f "$HERE/runner-compose.yml" -f "$HERE/runner-network.yml")
[[ -z "$BENCH" ]] || COMPOSE_FICHIERS+=(-f "$HERE/runner-compose.bench.yml")
# le volume du runner : son état d'enregistrement, et le jeton d'enregistrement le temps qu'il le lise
ETAT_RUNNER=/data/.runner
JETON_RUNNER=/data/.jeton-enregistrement
compose_runner() {
  LCARS_BENCH_BASE="$BENCH" LCARS_RUNNER_NETWORK="$NETWORK" LCARS_FORGE_URL="$INSTANCE_URL" LCARS_RUNNER_LABELS="$LABELS" LCARS_RUNNER_TOKEN_FILE="$JETON_RUNNER" \
    "$DOCKER_BIN" compose --env-file "$PROV_CONSTANTS_FILE" "${COMPOSE_FICHIERS[@]}" -p "$PROJECT" "$@"
}

compose_runner down -v >/dev/null 2>&1 || true
compose_runner create || { say "ÉCHEC : le runner ne se crée pas (sortie de compose au-dessus)"; exit 3; }
C="$(compose_runner ps -aq act)"
[[ -n "$C" ]] || { say "ÉCHEC : compose a créé le runner du projet $PROJECT et ne le rend pas (compose ps -aq act)"; exit 3; }
# le jeton entre dans le volume avant le premier démarrage, au compte de l'image rootless (uid 1000) :
# ni argv, ni environnement du conteneur
PLI="$(mktemp -d)"
( umask 077; printf '%s' "$REG" > "$PLI/${JETON_RUNNER##*/}" )
RC_JETON=0
tar -C "$PLI" --owner=1000 --group=1000 -cf - "${JETON_RUNNER##*/}" | "$DOCKER_BIN" cp - "$C:${JETON_RUNNER%/*}" || RC_JETON=$?
rm -rf "$PLI"
[[ "$RC_JETON" -eq 0 ]] || { say "ÉCHEC : le jeton d'enregistrement n'entre pas dans le runner ($JETON_RUNNER)"; exit 3; }
compose_runner start || { say "ÉCHEC : le runner ne démarre pas (sortie de compose au-dessus)"; exit 3; }
say "runner lancé (projet $PROJECT, réseau $NETWORK)"

# le daemon embarqué du runner démarre vide : les images publiques, il les tire ; les images
# locales que pack.sh pose sans les publier, il ne peut pas les connaître — elles sont semées
seed_dind_images() {
  local c="$C" out="" entry image
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

# la preuve d'enregistrement : l'id que ce runner écrit en s'enregistrant, lu dans la liste de la forge ;
# une liste non vide ne prouve rien, un runner d'avant hors ligne y figure encore
SEEN=0
PROBE_HTTP=""
ID=""
BODY="$(mktemp)"
for _ in $(seq 1 20); do
  sleep 3
  if [[ -z "$ID" ]]; then
    ID="$("$DOCKER_BIN" exec "$C" cat "$ETAT_RUNNER" 2>/dev/null | jq -r '.id // empty' 2>/dev/null || true)"
    [[ "$ID" =~ ^[0-9]+$ ]] || { ID=""; continue; }
    "$DOCKER_BIN" exec "$C" rm -f "$JETON_RUNNER" || say "le jeton d'enregistrement reste dans le volume du runner ($JETON_RUNNER)"
  fi
  PROBE_HTTP="$(forge_api GET "$FORGE_API/admin/actions/runners" "$BODY" --token-file "$TOKEN_FILE" -m 5)" || true
  [[ ! "$PROBE_HTTP" =~ ^(401|403)$ ]] || break
  [[ "$PROBE_HTTP" == "200" ]] || continue
  if jq -e --argjson id "$ID" '.runners // [] | any(.id == $id)' "$BODY" >/dev/null 2>&1; then
    SEEN=1; say "enregistré : la forge liste ce runner (id $ID)"; break
  fi
done
rm -f "$BODY"

if [[ "$SEEN" -ne 1 ]]; then
  if [[ -z "$ID" ]]; then
    say "ÉCHEC : le runner ne s'est pas enregistré après 60 s ($ETAT_RUNNER absent) — $DOCKER_BIN logs $C dit pourquoi"
    exit 3
  fi
  if [[ "$PROBE_HTTP" =~ ^(401|403)$ ]]; then
    say "NON VÉRIFIÉ (HTTP $PROBE_HTTP sur /admin/actions/runners — portée du jeton) : le runner s'est enregistré"
    say "  (id $ID), cette sonde ne peut pas dire que la forge le liste."
    exit 0
  fi
  say "ÉCHEC : la forge ne liste pas ce runner (id $ID) après 60 s (HTTP ${PROBE_HTTP:-?})"
  exit 3
fi

say "runner opérationnel — labels servis : $LABELS"
