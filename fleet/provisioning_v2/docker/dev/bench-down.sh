#!/usr/bin/env bash
# SOURCE: fleet/provisioning_v2/docker/dev/bench-down.sh
# AUTHOR: DrDree
# STARDATE: 2026-08-03
# STATUS: geste de BANC — DETRUIT un banc complet, volumes compris
#
# ─── POURQUOI CE GESTE VIT DANS SON PROPRE FICHIER ──────────────────────────────────────────────
# `bench-up.sh` monte, celui-ci detruit. Les separer n'est pas de la coquetterie : le `-v` de
# `compose down` efface les volumes, donc la forge, ses comptes, ses tokens et le /home de la boite.
# Tant que le geste destructeur est une OPTION d'un script qu'on lance vingt fois par nuit, il finit
# par partir sur le mauvais projet. Ici il faut ecrire le nom du projet, et --yes.
#
# ⚠ LE NOM DU PROJET EST LA SEULE PROTECTION. Il n'y a aucun defaut : un defaut sur ce script serait
# un banc detruit par une commande sans argument. Un banc qui TRAVAILLE se detruit comme un autre —
# la machine ne sait pas lequel compte, c'est a toi de le savoir.
#
# USAGE : bench-down.sh --project lcars-nuit --yes
# EXIT  : 0 detruit · 1 arguments · 2 rien a detruire sous ce nom

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(cd "$HERE/.." && pwd)"

PROJECT=""
CONFIRM=0
DOCKER_BIN="${DOCKER_BIN:-docker}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="${2:?}"; shift 2 ;;
    --yes)     CONFIRM=1; shift ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "bench-down: option inconnue: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$PROJECT" ]] || { echo "bench-down: --project est OBLIGATOIRE (aucun defaut, par choix)" >&2; exit 1; }
[[ "$CONFIRM" -eq 1 ]] || { echo "bench-down: --yes requis — ceci efface les volumes de '$PROJECT'" >&2; exit 1; }

FORGE_PROJECT="${PROJECT}forge"
BOX="${PROJECT}-lcars-1"

"$DOCKER_BIN" ps -a --format '{{.Names}}' | grep -qx "$BOX" \
  || { echo "bench-down: aucun conteneur '$BOX' — rien a detruire" >&2; exit 2; }

echo "[bench-down] destruction de la boite ($PROJECT) — volumes compris"
"$DOCKER_BIN" compose -f "$DOCKER_DIR/docker-compose.install.yml" -p "$PROJECT" down -v --remove-orphans || true

echo "[bench-down] destruction de la forge ($FORGE_PROJECT) — volumes compris"
"$DOCKER_BIN" compose -f "$HERE/forge-compose.yml" -p "$FORGE_PROJECT" down -v --remove-orphans || true

echo "[bench-down] banc '$PROJECT' detruit"
