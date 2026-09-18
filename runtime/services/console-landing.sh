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

PORT="${LCARS_LANDING_PORT:-20999}"
DECK_PY="${LCARS_CONSOLE_DECK:-/opt/lcars/console-deck.py}"

say() { echo "[lcars-landing] $*"; }

command -v python3 >/dev/null || { echo "console-landing.sh: python3 absent de l'image" >&2; exit 1; }
[[ -r "$DECK_PY" ]] || { echo "console-landing.sh: $DECK_PY introuvable" >&2; exit 1; }

# ⚠ ET SURTOUT PAS le groupe `fleet` : il porte deja la lecture de `/opt/lcars/runtime` et d'ailleurs.
# Le reutiliser aurait ete plus rapide, et aurait accorde tout le reste par la meme occasion.
CONSOLE_GROUP="${LCARS_CONSOLE_GROUP:-lcars-console}"
# ⚠ LE GROUPE DE LA PORTE DE DEPOT S'ACCORDE ICI, A L'EXEC, ET PAS PAR ADHESION. Le deck relaie un
# fichier a la porte que le service d'autorite ouvre (`/run/lcars/deposit/deposit.sock`, 0660 sur
# SON groupe) : sans ce groupe, la socket est parfaite et inatteignable. Le lui donner par
# `usermod -aG` serait l'inverse de la regle qui tient `lcars-console` (MUR 5 ter), et le mettre
# dans `fleet` lui donnerait les jetons de role. Ce groupe-ci ne porte que les portes de ce service.
DEPOSIT_GROUP="${LCARS_DEPOSIT_GROUP:-${LCARS_AUTHORITY_GROUP:-lcars-authority}}"
getent group "$CONSOLE_GROUP" >/dev/null 2>&1 || {
  echo "console-landing.sh: groupe $CONSOLE_GROUP absent — le deck ne pourrait joindre aucune console" >&2
  exit 1
}
# CELUI-LA NE TUE PAS LE DECK, ET C'EST LA DIFFERENCE : sans console, le deck n'a plus de metier ;
# sans porte de depot, il perd UN onglet et le dit lui-meme (« service de depot eteint »).
GROUPES="$CONSOLE_GROUP"
if getent group "$DEPOSIT_GROUP" >/dev/null 2>&1; then
  GROUPES="$CONSOLE_GROUP,$DEPOSIT_GROUP"
else
  echo "console-landing.sh: groupe $DEPOSIT_GROUP absent — l'onglet de dépôt refusera, le reste du deck sert" >&2
fi

DECK_USER="${LCARS_DECK_USER:-lcars-system}"
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
  exec setpriv --reuid "$DECK_USER" --regid "$DECK_GROUP" --groups "$GROUPES" -- "${SERVE[@]}"
fi
setpriv --reuid "$DECK_USER" --regid "$DECK_GROUP" --groups "$GROUPES" -- "${SERVE[@]}" &
say "deck lancé (pid $!)"
