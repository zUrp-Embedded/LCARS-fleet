#!/usr/bin/env bash
# SOURCE: docker.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — entrée Docker user-facing : wrapper mince sur compose (le compose est un détail d'implémentation)
#
# LCARS fleet v2 en conteneur. Modèle : l'image embarque le runtime déployé (release RO) + sshd
# comme login-manager ; l'humain SSH dans le conteneur EN TANT QUE LUI puis `fleet_v2 start`.
# Le fichier compose vit dans fleet/provisioning_v2/docker/ — l'humain ne le touche pas.
#
# USAGE : ./docker.sh <commande>
#   build          construit l'image (labels OCI : sha git + date stampés ici)
#   up             démarre le conteneur fleet (détaché) — `--forge` ajoute le sidecar Gitea
#   doctor         sonde l'état DANS le conteneur (le même doctor que le chemin WSL)
#   shell          shell dans le conteneur, en tant que l'humain (LCARS_HUMAN)
#   logs           logs du conteneur (suivi)
#   down           arrête et retire les conteneurs (les volumes restent)
#   reset          down + image + VOLUMES (destructif — l'état /home du conteneur disparaît)
#   help           cette aide
#
# ENV (tous optionnels) :
#   LCARS_HUMAN                login de l'humain dans le conteneur (défaut lcars)
#   LCARS_UID                  uid de l'humain (défaut 1000)
#   LCARS_SSH_AUTHORIZED_KEYS  clés publiques SSH (contenu authorized_keys)
#   LCARS_SSH_PORT             bind du port SSH (défaut 127.0.0.1:2222)
#   FORGE_BASE_URL             forge cible (défaut http://forge:3000 avec --forge)
#
# EXIT : 0 succès · 1 erreur/commande inconnue

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/fleet/provisioning_v2/docker/docker-compose.yml"
PROJECT=lcars

# ─── Préflight ────────────────────────────────────────────────────────────────────────────────────
command -v docker >/dev/null || { echo "docker.sh: docker introuvable — installe Docker d'abord" >&2; exit 1; }
if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null; then
  COMPOSE=(docker-compose)
else
  echo "docker.sh: docker compose introuvable (plugin ou standalone)" >&2; exit 1
fi
[[ -f "$COMPOSE_FILE" ]] || { echo "docker.sh: compose introuvable: $COMPOSE_FILE (checkout incomplet ?)" >&2; exit 1; }

compose() { "${COMPOSE[@]}" -f "$COMPOSE_FILE" -p "$PROJECT" "$@"; }

# La vérité de révision : stampée au build dans les labels OCI (le worktree/clone HÔTE a git ;
# le contexte, lui, n'embarque pas .git — cf. Dockerfile).
build_env() {
  LCARS_GIT_SHA="$(git -C "$SCRIPT_DIR" rev-parse --short=8 HEAD 2>/dev/null || echo unknown)"
  LCARS_BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  export LCARS_GIT_SHA LCARS_BUILD_DATE
}

cmd_build() { build_env; compose build "$@"; }

cmd_up() {
  local profiles=()
  if [[ "${1:-}" == "--forge" ]]; then profiles=(--profile forge); shift; fi
  build_env
  compose "${profiles[@]}" up -d "$@"
  echo ""
  echo "LCARS fleet up. Accès :"
  echo "  ssh ${LCARS_HUMAN:-lcars}@127.0.0.1 -p ${LCARS_SSH_PORT##*:}    # puis : fleet_v2 start"
  echo "  ./docker.sh doctor                                   # état provisionné ?"
}

cmd_doctor() {
  compose exec lcars /opt/lcars/fleet/provisioning_v2/provision doctor --substrate docker \
    --human "${LCARS_HUMAN:-lcars}" "$@"
}

cmd_shell() { compose exec -it -u "${LCARS_HUMAN:-lcars}" lcars bash; }
cmd_logs()  { compose logs -f "$@"; }
cmd_down()  { compose --profile forge down "$@"; }

cmd_reset() {
  echo "docker.sh: RESET — conteneurs + image + VOLUMES (l'état /home du conteneur sera détruit)."
  read -r -p "Confirmer (yes/N) ? " a < /dev/tty || a=""
  [[ "$a" == "yes" ]] || { echo "docker.sh: annulé."; exit 1; }
  compose --profile forge down --rmi local -v
  echo "docker.sh: reset fait. « ./docker.sh up » pour repartir de zéro."
}

usage() { sed -n '6,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# LCARS_SSH_PORT par défaut, visible dans le message d'accès.
: "${LCARS_SSH_PORT:=127.0.0.1:2222}"

case "${1:-help}" in
  build)  shift; cmd_build "$@" ;;
  up)     shift; cmd_up "$@" ;;
  doctor) shift; cmd_doctor "$@" ;;
  shell)  cmd_shell ;;
  logs)   shift; cmd_logs "$@" ;;
  down)   shift; cmd_down "$@" ;;
  reset)  cmd_reset ;;
  help|-h|--help) usage ;;
  *) echo "docker.sh: commande inconnue: $1 (./docker.sh help)" >&2; exit 1 ;;
esac
