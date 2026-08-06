#!/usr/bin/env bash
# SOURCE: fleet/deploy/docker/console-landing.sh
# AUTHOR: consultant
# STARDATE: 2026-07-31
# STATUS: lance le DECK de la boite (page unique, onglets verticaux, etat sonde) — sans auth
#
# ─── POURQUOI PAS `ttyd -I` ─────────────────────────────────────────────────────────────────────
# La prospection proposait de servir cette page via le flag `-I/--index` de ttyd. C'est FAUX et je
# le corrige ici : `-I` REMPLACE l'index.html de ttyd — or cet index EST le client xterm.js. Poser
# notre page dessus ne l'ajouterait pas a la console, ca la DETRUIRAIT. Le deck vit donc dans son
# propre serveur, sur son propre port, et la console n'est pas touchee.
#
# ─── PORT : HORS DE L'ESPACE DES BLOCS ──────────────────────────────────────────────────────────
# Les blocs humains occupent 21000..25999 (`21000 + (uid%500)*10`, +0..9). Cette page n'appartient
# a AUCUN humain — c'est la porte de la BOITE. Elle prend donc 20999, juste sous l'espace des
# blocs : impossible de collisionner avec un humain present ou futur.
#
# ─── CE SCRIPT NE FABRIQUE PLUS DE PAGE ─────────────────────────────────────────────────────────
# Il lance `console-deck.py`, qui sert la coquille ET l'etat (`/api/state`). Une page ecrite au
# boot ne peut porter que des faits stables ; celle-ci doit montrer les agents VIVANTS, qui
# naissent et meurent pendant la vie du conteneur. Un contenu qui bouge n'est pas un fichier,
# c'est un service.
#
# ─── QUI SERT ───────────────────────────────────────────────────────────────────────────────────
# `nobody`. Le deck LIT (passwd, /proc, l'API du deck de chaque humain) et ne pilote rien — aucune
# raison de lui donner plus. La lecture des `cmdline` des pods reste possible sous `nobody` (elles
# sont world-readable) et ne porte aucun credential : uniquement des chemins de montage, qui sont
# precisement le rattachement projet que le deck affiche.
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

export LCARS_LANDING_PORT="$PORT"
SERVE=(python3 "$DECK_PY")
say "deck sur le port $PORT (http://127.0.0.1:$PORT une fois publié)"

if [[ "$FOREGROUND" -eq 1 ]]; then
  exec setpriv --reuid nobody --regid nogroup --init-groups -- "${SERVE[@]}"
fi
setpriv --reuid nobody --regid nogroup --init-groups -- "${SERVE[@]}" &
say "deck lancé (pid $!)"
