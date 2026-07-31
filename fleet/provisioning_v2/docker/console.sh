#!/usr/bin/env bash
# SOURCE: fleet/provisioning_v2/docker/console.sh
# AUTHOR: consultant
# STARDATE: 2026-07-31
# STATUS: la console web du conteneur — un shell dans le navigateur, SOUS L'IDENTITE de l'humain
#
# La porte d'entree que ni ssh ni Claude Desktop ne donnent : ssh demande un geste technique et une
# cle, Desktop exige un pod DEJA vivant. Ici : une page web, un shell, et `claude` lancable dedans.
# ssh reste la porte d'admin (chemin naturel d'une Debian headless) ; ceci ne la remplace pas.
#
# CE QUE CE SCRIPT FAIT, ET RIEN D'AUTRE : lancer ttyd sous l'humain, sur SON port derive de son UID.
# Il ne cree pas l'humain (entrypoint), ne provisionne rien (provision), n'ouvre aucune auth (etape 2).
#
# PORT : le bloc de 10 ports par humain de bin/fleet_v2 (`21000 + (uid%500)*10`) — meme formule,
# recopiee ici A DESSEIN car ce script tourne AVANT/SANS la fleet (c'est tout l'interet : la console
# doit exister quand rien ne tourne). Slot `+4` : premier jamais attribue. Le `+2` reste le trou
# documente de l'ancien MCP HTTP, on ne le comble pas.
#   +0 API · +1 observation · +2 (libere, laisse vide) · +3 webhook · +4 CONSOLE · +5..9 libres
#
# tmux derriere ttyd : `new-session -A` = attache si la session existe, la cree sinon. Le shell
# SURVIT donc au rechargement de l'onglet, et l'humain retrouve son `claude` en cours.
#
# USAGE : console.sh [--human USER] [--port N] [--foreground]
# EXIT  : 0 lance · 1 erreur d'usage/identite

set -euo pipefail

HUMAN="${LCARS_HUMAN:-lcars}"
PORT=""
FOREGROUND=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --human) HUMAN="${2:?--human attend un login}"; shift 2 ;;
    --port)  PORT="${2:?--port attend un numero}"; shift 2 ;;
    --foreground) FOREGROUND=1; shift ;;
    -h|--help) sed -n '6,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "console.sh: option inconnue: $1 (--help)" >&2; exit 1 ;;
  esac
done

say() { echo "[lcars-console] $*"; }

id "$HUMAN" >/dev/null 2>&1 || { echo "console.sh: humain inconnu: $HUMAN" >&2; exit 1; }
command -v ttyd >/dev/null || { echo "console.sh: ttyd absent de l'image" >&2; exit 1; }

if [[ -z "$PORT" ]]; then
  uid="$(id -u "$HUMAN")"
  PORT=$(( 21000 + (uid % 500) * 10 + 4 ))
fi

# ttyd tourne SOUS l'humain : ce qui est tape dans le navigateur a exactement ses droits, ni plus
# (pas de drop d'UID a faire, pas de privilege a porter) ni moins (son ~/.lcars, ses sockets tmux).
# `-W` : ecriture autorisee — sans lui la console est un ecran mort (piege nomme dans #5.8).
# `-m 1` : une seule connexion tmux servie, sinon tmux clampe la taille au plus petit client.
# Le bind est 0.0.0.0 DANS le conteneur ; la frontiere reelle est la publication compose, qui
# n'expose que sur la loopback de l'hote (etape 1 : pas d'auth, donc pas d'exposition LAN).
# L'IDENTITE N'EST PAS QUE L'UID : `setpriv` change l'uid/gid et RIEN D'AUTRE — HOME, USER et
# LOGNAME restent ceux de l'appelant (l'entrypoint tourne en root → HOME=/root). Mesure en direct :
# `cd ~` dans la console repondait « /root: Permission denied ». Meme piege que `USER` dans un
# Dockerfile, qui ne change pas HOME non plus. On pose donc l'environnement EXPLICITEMENT, et le
# cwd de depart avec (sinon le shell s'ouvre sur `/`).
HOME_DIR="$(getent passwd "$HUMAN" | cut -d: -f6 || true)"
[[ -n "$HOME_DIR" && -d "$HOME_DIR" ]] || { echo "console.sh: home introuvable pour $HUMAN" >&2; exit 1; }
cd "$HOME_DIR"

# `-f` : la config tmux DE LA CONSOLE (molette + historique — sans elle on est cloue a un ecran,
# tmux possedant l'ecran, le scrollback du navigateur ne voit rien). Elle ne touche pas les pods :
# eux ont leurs propres sockets tmux (`-S` par pod).
TMUX_CONF="${LCARS_CONSOLE_TMUX_CONF:-/opt/lcars/console.tmux.conf}"
TMUX_ARGS=(-u)
[[ -r "$TMUX_CONF" ]] && TMUX_ARGS+=(-f "$TMUX_CONF")

CMD=(env "HOME=$HOME_DIR" "USER=$HUMAN" "LOGNAME=$HUMAN"
     ttyd --writable -p "$PORT" -i 0.0.0.0 -t titleFixed="LCARS console — $HUMAN"
     -t fontSize=15 -t 'theme={"background":"#000000","foreground":"#FF9900"}'
     tmux "${TMUX_ARGS[@]}" new-session -A -s console)

say "console de $HUMAN sur le port $PORT (http://127.0.0.1:$PORT une fois publie)"

if [[ "$FOREGROUND" -eq 1 ]]; then
  exec setpriv --reuid "$HUMAN" --regid "$HUMAN" --init-groups -- "${CMD[@]}"
fi

# Detache : l'entrypoint continue son travail (sshd doit demarrer quoi qu'il arrive). La sortie va
# dans les logs du conteneur — une console qui meurt doit se voir, pas disparaitre en silence.
setpriv --reuid "$HUMAN" --regid "$HUMAN" --init-groups -- "${CMD[@]}" &
say "console lancee (pid $!)"
