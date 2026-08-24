#!/usr/bin/env bash
# SOURCE: docker.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: RENVOI TRANSITOIRE — tout vit dans `fleet/deploy/box` ; ce fichier part avec ses appelants
#

set -euo pipefail

# ⚠ CE FICHIER EST UN RENVOI, ET RIEN D'AUTRE. Le preflight, l'aide et les douze verbes vivent dans
# `fleet/deploy/box`, jumeau de `fleet/deploy/provision`. Il ne reste ici qu'un `exec` argv verbatim,
# le temps que les appelants soient bascules — puis ce fichier part.
#
# `exec` et pas un appel : le delegue HERITE du terminal, du code de sortie et des signaux. Un
# wrapper qui relaie a la main finit toujours par perdre l'un des trois — le plus souvent le code de
# sortie, celui qui compte.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOX="$SCRIPT_DIR/fleet/deploy/box"

[[ -x "$BOX" ]] || {
  echo "docker.sh: delegue introuvable : $BOX" >&2
  echo "   Checkout incomplet ou tronque — « git status » dans $SCRIPT_DIR" >&2
  exit 1
}

exec "$BOX" "$@"
