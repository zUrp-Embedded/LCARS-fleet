#!/usr/bin/env bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: docker.sh
#     |  |________|  | AUTHOR: STARFLEET
#     |   ________   | SYSTEM: LCARS-FLEET v6.0
#     |  |  v6.0  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS-FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: DOCKER-ENTRY    | SUBSYSTEM: DOCKER / BOOTSTRAP   |
#     | LICENSE: AGPL-3         | STARDATE: 2026.088              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Docker user-facing entrypoint — wraps docker compose.    |
#     |  The user never touches docker-compose.yml directly.      |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     Point d'entree Docker. Encapsule docker compose pour que l'user
#     n'ait qu'une CLI simple. Le fichier compose est un detail
#     d'implementation dans fleet/provisioning/docker/.
#
#     [EN]
#     NAME
#         docker.sh — LCARS fleet Docker entrypoint
#
#     SYNOPSIS
#         ./docker.sh <command> [options]
#
#     COMMANDS
#         build       Build the Docker image
#         up          Build (if needed) and start the container
#         shell       Open a shell in a running container
#         down        Stop and remove the container
#         reset       Remove container, image, and local volumes
#         help        Show this help
#
#     ENVIRONMENT
#         ANTHROPIC_API_KEY   Claude API key (optional — can use OAuth instead)
#         GH_TOKEN            GitHub token for git push (optional)
#         GIT_USER_NAME       Git commit author name
#         GIT_USER_EMAIL      Git commit author email
#         LCARS_REPO          Fork repo (default: lordzurp/LCARS-fleet)
#
#     EXIT CODES
#         0    Success
#         1    Error or unknown command
#
# --- END HEADER ---

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/fleet/provisioning/docker/docker-compose.yml"
PROJECT_NAME="lcars"

# ─── Preflight ──────────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    echo "ERROR: docker not found — install Docker first" >&2
    exit 1
fi

# Check for compose (plugin or standalone)
if docker compose version &>/dev/null 2>&1; then
    COMPOSE="docker compose"
elif command -v docker-compose &>/dev/null; then
    COMPOSE="docker-compose"
else
    echo "ERROR: docker compose not found — install Docker Compose" >&2
    exit 1
fi

compose_cmd() {
    $COMPOSE -f "$COMPOSE_FILE" -p "$PROJECT_NAME" "$@"
}

# ─── Commands ───────────────────────────────────────────────────────────────
cmd_build() {
    echo "[lcars-docker] Building image..."
    compose_cmd build "$@"
}

cmd_up() {
    echo "[lcars-docker] Starting LCARS fleet container..."
    compose_cmd run --rm lcars "$@"
}

cmd_shell() {
    local container
    container=$(docker ps --filter "label=com.docker.compose.project=$PROJECT_NAME" --format '{{.ID}}' | head -1)
    if [[ -z "$container" ]]; then
        echo "No running LCARS container — use './docker.sh up' first" >&2
        exit 1
    fi
    docker exec -it "$container" bash
}

cmd_down() {
    echo "[lcars-docker] Stopping..."
    compose_cmd down "$@"
}

cmd_reset() {
    echo "[lcars-docker] Resetting — removing container, image, and volumes..."
    compose_cmd down --rmi local -v "$@"
    echo "[lcars-docker] Reset complete. Run './docker.sh up' to start fresh."
}

cmd_help() {
    cat <<'EOF'
LCARS Fleet — Docker

Usage: ./docker.sh <command>

Commands:
  build       Build the Docker image
  up          Build (if needed) and start interactive container
  shell       Open a shell in a running container
  down        Stop and remove the container
  reset       Full reset — remove container, image, volumes

Environment variables:
  ANTHROPIC_API_KEY   Claude API key (or use OAuth on first run)
  GH_TOKEN            GitHub token for git push
  GIT_USER_NAME       Git author name
  GIT_USER_EMAIL      Git author email
  LCARS_REPO          Fork repo (default: lordzurp/LCARS-fleet)

Quick start:
  ./docker.sh up                                    # OAuth login
  ANTHROPIC_API_KEY=sk-ant-... ./docker.sh up       # API key
  GH_TOKEN=ghp_... ./docker.sh up                   # with git push
EOF
}

# ─── Dispatch ───────────────────────────────────────────────────────────────
case "${1:-help}" in
    build) shift; cmd_build "$@" ;;
    up)    shift; cmd_up "$@" ;;
    shell) cmd_shell ;;
    down)  shift; cmd_down "$@" ;;
    reset) shift; cmd_reset "$@" ;;
    help|--help|-h) cmd_help ;;
    *)
        echo "Unknown command: $1 — use './docker.sh help'" >&2
        exit 1
        ;;
esac
