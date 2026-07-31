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
# MULTI-HUMAIN (`--all`) : la formule donne DEJA un port distinct par uid, donc N humains = N
# consoles sans une ligne de coordination — pas de proxy, pas d'auth, pas de registre. L'isolation
# est celle de l'OS (chacun son uid, son home, ses sockets tmux), pas une couche applicative.
# L'eligibilite (et la garde anti-systeme qui empeche root de partager le bloc de l'uid 1000) vit
# dans `console-humans.sh` — source unique, cf. son en-tete.
#
# tmux derriere ttyd : `new-session -A` = attache si la session existe, la cree sinon. Le shell
# SURVIT donc au rechargement de l'onglet, et l'humain retrouve son `claude` en cours.
#
# USAGE : console.sh [--human USER | --all] [--port N] [--foreground]
# EXIT  : 0 lance · 1 erreur d'usage/identite

set -euo pipefail

HUMAN="${LCARS_HUMAN:-lcars}"
PORT=""
FOREGROUND=0
ALL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --human) HUMAN="${2:?--human attend un login}"; shift 2 ;;
    --all)   ALL=1; shift ;;
    --port)  PORT="${2:?--port attend un numero}"; shift 2 ;;
    --foreground) FOREGROUND=1; shift ;;
    -h|--help) sed -n '6,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "console.sh: option inconnue: $1 (--help)" >&2; exit 1 ;;
  esac
done

say() { echo "[lcars-console] $*"; }

command -v ttyd >/dev/null || { echo "console.sh: ttyd absent de l'image" >&2; exit 1; }

# ─── Lancement d'UNE console ────────────────────────────────────────────────────────────────────
launch_one() {
  local human="$1" port="${2:-}" uid home_dir tmux_conf
  local -a tmux_args cmd

  id "$human" >/dev/null 2>&1 || { echo "console.sh: humain inconnu: $human" >&2; return 1; }

  if [[ -z "$port" ]]; then
    uid="$(id -u "$human")"
    port=$(( 21000 + (uid % 500) * 10 + 4 ))
  fi

  # L'IDENTITE N'EST PAS QUE L'UID : `setpriv` change l'uid/gid et RIEN D'AUTRE — HOME, USER et
  # LOGNAME restent ceux de l'appelant (l'entrypoint tourne en root → HOME=/root). Mesure en direct :
  # `cd ~` dans la console repondait « /root: Permission denied ». Meme piege que `USER` dans un
  # Dockerfile, qui ne change pas HOME non plus. On pose donc l'environnement EXPLICITEMENT, et le
  # cwd de depart avec (sinon le shell s'ouvre sur `/`). Le `cd` vit dans un SOUS-SHELL : en mode
  # `--all`, un `cd` au niveau du script contaminerait l'humain suivant.
  home_dir="$(getent passwd "$human" | cut -d: -f6 || true)"
  [[ -n "$home_dir" && -d "$home_dir" ]] || { echo "console.sh: home introuvable pour $human" >&2; return 1; }

  # `-f` : la config tmux DE LA CONSOLE (molette, historique, barre de statut — sans elle on est
  # cloue a un ecran, tmux possedant l'ecran, le scrollback du navigateur ne voit rien). Elle ne
  # touche pas les pods : eux ont leurs propres sockets tmux (`-S` par pod).
  tmux_conf="${LCARS_CONSOLE_TMUX_CONF:-/opt/lcars/console.tmux.conf}"
  tmux_args=(-u)
  [[ -r "$tmux_conf" ]] && tmux_args+=(-f "$tmux_conf")

  # ttyd tourne SOUS l'humain : ce qui est tape dans le navigateur a exactement ses droits, ni plus
  # (pas de drop d'UID a faire, pas de privilege a porter) ni moins (son ~/.lcars, ses sockets tmux).
  # `-W` : ecriture autorisee — sans lui la console est un ecran mort (piege nomme dans #5.8).
  # NOTE (corrigee le 2026-07-31) : ce bloc annoncait un `-m 1` que la commande n'a JAMAIS passe —
  # un commentaire qui decrivait une protection absente. Le fait reel, non mitige : deux onglets
  # ouverts sur la meme console partagent la session tmux, et tmux clampe alors l'affichage a la
  # taille du plus PETIT client. Consequence connue, pas corrigee ici : ajouter `-m 1` refuserait
  # aussi le nouvel onglet tant que l'ancien traine au rechargement, et ce compromis n'a pas ete
  # mesure. On decrit ce qui est, pas ce qu'on aimerait.
  # Le bind est 0.0.0.0 DANS le conteneur ; la frontiere reelle est la publication compose, qui
  # n'expose que sur la loopback de l'hote (etape 1 : pas d'auth, donc pas d'exposition LAN).
  cmd=(env "HOME=$home_dir" "USER=$human" "LOGNAME=$human"
       ttyd --writable -p "$port" -i 0.0.0.0 -t titleFixed="LCARS console — $human"
       -t fontSize=15 -t 'theme={"background":"#000000","foreground":"#FF9900"}'
       tmux "${tmux_args[@]}" new-session -A -s console)

  say "console de $human sur le port $port (http://127.0.0.1:$port une fois publie)"

  if [[ "$FOREGROUND" -eq 1 ]]; then
    cd "$home_dir" && exec setpriv --reuid "$human" --regid "$human" --init-groups -- "${cmd[@]}"
  fi

  # Detache : l'entrypoint continue son travail (sshd doit demarrer quoi qu'il arrive). La sortie va
  # dans les logs du conteneur — une console qui meurt doit se voir, pas disparaitre en silence.
  ( cd "$home_dir" && setpriv --reuid "$human" --regid "$human" --init-groups -- "${cmd[@]}" ) &
  local pid=$!

  # « Lancee » n'est pas « vivante ». Un ttyd qui ne peut pas binder (port deja pris) meurt dans la
  # demi-seconde : sans cette verification, `--all` compterait une console morte comme un succes et
  # l'humain la chercherait dans son navigateur. On mesure au lieu de declarer.
  sleep 0.4
  if ! kill -0 "$pid" 2>/dev/null; then
    say "console de $human MORTE au demarrage — port $port deja pris ? (motif au-dessus)"
    return 1
  fi
  say "console de $human vivante (pid $pid)"
}

# ─── Mode ───────────────────────────────────────────────────────────────────────────────────────
if [[ "$ALL" -eq 1 ]]; then
  [[ "$FOREGROUND" -eq 0 ]] || { echo "console.sh: --all et --foreground sont exclusifs" >&2; exit 1; }
  [[ -z "$PORT" ]]          || { echo "console.sh: --all et --port sont exclusifs" >&2; exit 1; }

  HUMANS_SH="${LCARS_CONSOLE_HUMANS:-/opt/lcars/console-humans.sh}"
  [[ -x "$HUMANS_SH" ]] || { echo "console.sh: $HUMANS_SH introuvable" >&2; exit 1; }

  n=0
  # `--verbose` : les rejets partent sur stderr → visibles dans `docker logs`. Un humain qui n'a PAS
  # eu sa console doit laisser une trace avec son motif ; un silence ferait croire a un oubli.
  while read -r login _uid _base; do
    [[ -n "$login" ]] || continue
    launch_one "$login" && n=$(( n + 1 )) || say "console de $login NON lancee"
  done < <("$HUMANS_SH" --verbose)

  say "$n console(s) lancee(s)"
  [[ "$n" -gt 0 ]] || { echo "console.sh: aucun humain eligible" >&2; exit 1; }
  exit 0
fi

launch_one "$HUMAN" "$PORT"
