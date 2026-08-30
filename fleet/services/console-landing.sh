#!/usr/bin/env bash
# SOURCE: fleet/services/console-landing.sh
# AUTHOR: consultant
# STARDATE: 2026-07-31
# STATUS: lance le DECK de la boite (page unique, onglets verticaux, etat sonde) — identifie par la forge
#
# USAGE : console-landing.sh [--foreground]
# EXIT  : 0 lance · 1 dependance absente

set -euo pipefail

FOREGROUND=0
[[ "${1:-}" == "--foreground" ]] && FOREGROUND=1

PORT="${LCARS_LANDING_PORT:-20999}"
DECK_PY="${LCARS_CONSOLE_DECK:-/opt/lcars/console-deck.py}"

say() { echo "[lcars-landing] $*"; }

command -v python3 >/dev/null || { echo "console-landing.sh: python3 absent de l'image" >&2; exit 1; }
[[ -r "$DECK_PY" ]] || { echo "console-landing.sh: $DECK_PY introuvable" >&2; exit 1; }

CONSOLE_GROUP="${LCARS_CONSOLE_GROUP:-lcars-console}"
getent group "$CONSOLE_GROUP" >/dev/null 2>&1 || {
  echo "console-landing.sh: groupe $CONSOLE_GROUP absent — le deck ne pourrait joindre aucune console" >&2
  exit 1
}

# ⚠ LE COMPTE SE SONDE ICI, PARCE QUE `setpriv` ECHOUE SUR UN NOM INCONNU AVEC UN MESSAGE QUI PARLE
# DE `setpriv`, PAS DE LCARS. Le refus doit nommer le geste qui pose le compte, sinon le diagnostic
# coute deux sauts — meme regle que la garde du groupe juste au-dessus.
DECK_USER="${LCARS_DECK_USER:-lcars-system}"
DECK_GROUP="${LCARS_DECK_GROUP:-$DECK_USER}"
getent passwd "$DECK_USER" >/dev/null 2>&1 || {
  echo "console-landing.sh: compte $DECK_USER absent — le deck n'a pas d'identite a lui (« provision apply --only 21-service-accounts » le pose ; dans la boite, c'est l'image qui le porte)" >&2
  exit 1
}
getent group "$DECK_GROUP" >/dev/null 2>&1 || {
  echo "console-landing.sh: groupe $DECK_GROUP absent — le fichier d'identification du deck (0640 root:$DECK_GROUP) serait illisible" >&2
  exit 1
}

export LCARS_LANDING_PORT="$PORT"
SERVE=(python3 "$DECK_PY")
say "deck sur le port $PORT (http://127.0.0.1:$PORT une fois publié)"

if [[ "$FOREGROUND" -eq 1 ]]; then
  exec setpriv --reuid "$DECK_USER" --regid "$DECK_GROUP" --groups "$CONSOLE_GROUP" -- "${SERVE[@]}"
fi
setpriv --reuid "$DECK_USER" --regid "$DECK_GROUP" --groups "$CONSOLE_GROUP" -- "${SERVE[@]}" &
say "deck lancé (pid $!)"
