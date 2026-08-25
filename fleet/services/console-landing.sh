#!/usr/bin/env bash
# SOURCE: fleet/services/console-landing.sh
# AUTHOR: consultant
# STARDATE: 2026-07-31
# STATUS: lance le DECK de la boite (page unique, onglets verticaux, etat sonde) — identifie par la forge
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
# CONSEQUENCE POUR SON CLIENT OAUTH2 : le fichier que le deck lit pour s'identifier aupres de la
# forge doit etre lisible par `nobody` — c'est `55-deck-oidc.sh` qui le pose, en 0640 root:nogroup.
# Sans lui le deck ne sert RIEN (503 qui nomme le fichier manquant), deliberement : un deck qui se
# rabattrait sur l'annuaire complet rendrait l'absence de configuration invisible.
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

# ─── LE SEUL POUVOIR AJOUTE AU DECK, ET IL SE DIT EN UNE PHRASE ─────────────────────────────────
# « Traverser les repertoires de socket des consoles. » Si on ne sait pas l'ecrire aussi court, c'est
# qu'on accorde trop.
#
# Le deck RESTE `nobody` : il doit accepter et router TOUS les humains, donc il ne peut etre aucun
# d'eux. Ce qu'il gagne est exactement un groupe supplementaire, qui ne donne que le `--x` sur
# `/run/lcars/console/<human>/`. C'est STRICTEMENT MOINS que ce qu'il a deja — il lit
# `/etc/lcars/deck-oidc.json`, qui porte le secret OIDC.
#
# ⚠ SURTOUT PAS le groupe `fleet` (gid 2000) : il porte deja la lecture de `/local/LCARS_v2` et
# d'ailleurs. Le reutiliser aurait ete plus rapide et aurait accorde tout le reste par la meme
# occasion.
#
# ⚠ C'EST UN REMPLACEMENT DE `--init-groups`, PAS UN AJOUT — mesure du 2026-08-14 DANS L'IMAGE
# (`lcars-fleet`, util-linux 2.38.1, pas celui du poste de dev) :
# `setpriv: mutually exclusive arguments: --clear-groups --keep-groups --init-groups --groups`.
# Et le remplacement ne retire rien : dans cette meme image, `id nobody` rend `groups=65534(nogroup)`
# et aucune ligne de `/etc/group` ne le cite en membre. `--init-groups` ne lui donnait donc rien.
#
# ⚠ LE LIEU D'UNE MESURE FAIT PARTIE DE LA MESURE. Cette ligne a d'abord ete verifiee sur le poste
# de dev (util-linux 2.39.3) et ecrite « mesuree » : elle parlait d'un systeme qui n'est pas celui
# qui execute ce script. Le verdict s'est trouve identique — c'est de la chance, pas de la methode.
# Une version d'outil, une distribution ou un noyau different, et un commentaire « mesure » aurait
# affirme un comportement que la boite n'a pas.
CONSOLE_GROUP="${LCARS_CONSOLE_GROUP:-lcars-console}"
getent group "$CONSOLE_GROUP" >/dev/null 2>&1 || {
  echo "console-landing.sh: groupe $CONSOLE_GROUP absent — le deck ne pourrait joindre aucune console" >&2
  exit 1
}

export LCARS_LANDING_PORT="$PORT"
SERVE=(python3 "$DECK_PY")
say "deck sur le port $PORT (http://127.0.0.1:$PORT une fois publié)"

if [[ "$FOREGROUND" -eq 1 ]]; then
  exec setpriv --reuid nobody --regid nogroup --groups "$CONSOLE_GROUP" -- "${SERVE[@]}"
fi
setpriv --reuid nobody --regid nogroup --groups "$CONSOLE_GROUP" -- "${SERVE[@]}" &
say "deck lancé (pid $!)"
