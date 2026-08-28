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
# ─── PORT : D'OU VIENT LE NOMBRE, ET CE QUI LE TIENT AUJOURD'HUI ────────────────────────────────
# ⚠ CE PARAGRAPHE DECLARAIT AU PRESENT UN ESPACE DE PORTS QUI N'EXISTE PLUS. Il disait « les blocs
# humains occupent 21000..25999 (`21000 + (uid%500)*10`) », et `console.sh` declare ces slots MORTS
# depuis que le terminal n'est plus joignable que par sa socket : « PLUS AUCUN PORT, ET C'EST
# L'INVARIANT DU SCRIPT ». La formule ne vit plus que dans des commentaires. 20999 a bien ete choisi
# « juste sous » cet espace — c'est son HISTOIRE, plus sa garantie.
#
# ⚠ ET 21000 A CHANGE DE PROPRIETAIRE ENTRE-TEMPS : c'est `PROV_FORGE_HOST_PORT`, le port de la
# forge sur l'hote. Un lecteur qui prendrait « juste sous 21000 » pour une regle vivante lirait donc
# une contrainte vis-a-vis de la forge, qui n'a jamais existe.
#
# CE QUI TIENT LE NOMBRE AUJOURD'HUI : `PROV_DECK_PORT` de `provision-lib.sh` en est la seule
# declaration nommee — c'est elle que `--port-deck` deplace et dont les `redirect_uris` OIDC
# derivent — et `MUR 4` de `variable_walls.bats` exige que les huit copies la suivent.
#
# ─── CE SCRIPT NE FABRIQUE PLUS DE PAGE ─────────────────────────────────────────────────────────
# Il lance `console-deck.py`, qui sert la coquille ET l'etat (`/api/state`). Une page ecrite au
# boot ne peut porter que des faits stables ; celle-ci doit montrer les agents VIVANTS, qui
# naissent et meurent pendant la vie du conteneur. Un contenu qui bouge n'est pas un fichier,
# c'est un service.
#
# ─── QUI SERT ───────────────────────────────────────────────────────────────────────────────────
# `lcars-system` — un compte SYSTEME a lui, sans shell et sans home (`21-service-accounts` au poste,
# le Dockerfile dans l'image). Le deck LIT (passwd, /proc, l'API du deck de chaque humain) et ne
# pilote rien — aucune raison de lui donner plus.
#
# ⚠ IL A TOURNE EN `nobody`, ET LE PRIX SE LISAIT SUR LE GROUPE. `nobody` n'est pas une identite,
# c'est la convention de ceux qui n'en ont pas choisi ; son groupe `nogroup` (gid 65534) est le
# groupe PRIMAIRE de `sync`, `_apt`, `nobody` et `dhcpcd` sur une Debian/Ubuntu ordinaire (releve du
# 2026-08-27). Le fichier d'identification ci-dessous — qui porte le `client_secret` OAuth2 — s'y
# posait en `0640 root:nogroup` : un demon reseau le lisait. Un compte a lui, et le groupe du
# fichier nomme exactement un lecteur.
#
# ⚠ CE QUE CE COMPTE NE CHANGE PAS : ce que le deck PEUT faire. Il recoit toujours `lcars-console`
# a l'exec, et ce groupe est a un `connect()` d'un shell sous n'importe quel humain. On a range qui
# partage son identite, pas son pouvoir.
#
# La lecture des `cmdline` des pods reste possible sous ce compte (elles
# sont world-readable) et ne porte aucun credential : uniquement des chemins de montage, qui sont
# precisement le rattachement projet que le deck affiche.
#
# CONSEQUENCE POUR SON CLIENT OAUTH2 : le fichier que le deck lit pour s'identifier aupres de la
# forge doit etre lisible par lui — c'est `55-deck-oidc.sh` qui le pose, en 0640 root:lcars-system.
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
# Le deck N'EST AUCUN HUMAIN, et ne peut pas l'etre : il doit accepter et router TOUS les humains.
# C'est pourquoi son compte est un compte de SERVICE et pas un compte de personne. Ce qu'il gagne est exactement un groupe supplementaire, qui ne donne que le `--x` sur
# `/run/lcars/console/<human>/`. C'est STRICTEMENT MOINS que ce qu'il a deja — il lit
# `/etc/lcars/deck-oidc.json`, qui porte le secret OIDC.
#
# ⚠ SURTOUT PAS le groupe `fleet` (gid 2000) : il porte deja la lecture de `/opt/lcars/runtime` et
# d'ailleurs. Le reutiliser aurait ete plus rapide et aurait accorde tout le reste par la meme
# occasion.
#
# ⚠ C'EST UN REMPLACEMENT DE `--init-groups`, PAS UN AJOUT — mesure du 2026-08-14 DANS L'IMAGE
# (`lcars-fleet`, util-linux 2.38.1, pas celui du poste de dev) :
# `setpriv: mutually exclusive arguments: --clear-groups --keep-groups --init-groups --groups`.
# Et le remplacement ne retire rien : `lcars-system` est cree SANS aucune adhesion secondaire, donc
# `--init-groups` ne lui rendrait que son groupe primaire, que `--regid` pose deja.
#
# ⚠ ET C'EST DELIBERE QU'IL NE SOIT PAS MEMBRE DE `lcars-console`. Le groupe garde ainsi ZERO
# membre : entre deux lancements, l'ensemble de ceux qui traversent les sockets de console est
# VIDE, et root le rend a un processus nomme, a l'exec. Une adhesion persistante rendrait ce
# pouvoir disponible a tout ce qui prendrait cette identite ensuite.
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
