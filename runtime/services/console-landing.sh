#!/usr/bin/env bash
# SOURCE: runtime/services/console-landing.sh
# AUTHOR: consultant
# STARDATE: 2026-07-31
# STATUS: lance le DECK du conteneur (page unique, onglets verticaux, etat sonde) — identifie par la forge
#
# ⚠ SURTOUT PAS `ttyd -I` POUR SERVIR CETTE PAGE : `-I` REMPLACE l'index.html de ttyd, or cet index
# EST le client xterm.js. La page ne s'ajouterait pas a la console, elle la DETRUIRAIT. Le deck a
# donc son propre serveur sur son propre port, et la console n'est pas touchee.

set -euo pipefail

FOREGROUND=0
[[ "${1:-}" == "--foreground" ]] && FOREGROUND=1

# ⚖ Decision 3 : le port, le groupe de console et l'identite du deck sont des FAITS de la machine,
# pas des litteraux de ce script. Ils se lisent, ils ne se recopient pas.
FACTS_SH="${LCARS_FACTS_SH:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/facts.sh}"
[[ -r "$FACTS_SH" ]] || FACTS_SH=/opt/lcars/services/lib/facts.sh
# shellcheck source=lib/facts.sh
. "$FACTS_SH"
PORT="$LCARS_LANDING_PORT"
DECK_PY="${LCARS_CONSOLE_DECK:-/opt/lcars/console-deck.py}"

say() { echo "[lcars-landing] $*"; }

command -v python3 >/dev/null || { echo "console-landing.sh: python3 absent de l'image" >&2; exit 1; }
[[ -r "$DECK_PY" ]] || { echo "console-landing.sh: $DECK_PY introuvable" >&2; exit 1; }

# ⚠ ET SURTOUT PAS le groupe `fleet` : il porte deja la lecture de `/opt/lcars/runtime` et d'ailleurs.
# Le reutiliser aurait ete plus rapide, et aurait accorde tout le reste par la meme occasion.
CONSOLE_GROUP="$LCARS_CONSOLE_GROUP"
getent group "$CONSOLE_GROUP" >/dev/null 2>&1 || {
  echo "console-landing.sh: groupe $CONSOLE_GROUP absent — le deck ne pourrait joindre aucune console" >&2
  exit 1
}

DECK_USER="${LCARS_DECK_USER:-$LCARS_SYSTEM_USER}"
DECK_GROUP="${LCARS_DECK_GROUP:-$DECK_USER}"
getent passwd "$DECK_USER" >/dev/null 2>&1 || {
  echo "console-landing.sh: compte $DECK_USER absent — le deck n'a pas d'identite a lui (« provision apply --only 21-service-accounts » le pose ; dans le conteneur, c'est l'image qui le porte)" >&2
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
