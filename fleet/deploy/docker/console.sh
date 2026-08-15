#!/usr/bin/env bash
# SOURCE: fleet/deploy/docker/console.sh
# AUTHOR: consultant
# STARDATE: 2026-07-31
# STATUS: la console web du conteneur — un shell dans le navigateur, SOUS L'IDENTITE de l'humain
#
# La porte d'entree que ni ssh ni Claude Desktop ne donnent : ssh demande un geste technique et une
# cle, Desktop exige un pod DEJA vivant. Ici : une page web, un shell, et `claude` lancable dedans.
# ssh reste la porte d'admin (chemin naturel d'une Debian headless) ; ceci ne la remplace pas.
#
# CE QUE CE SCRIPT FAIT, ET RIEN D'AUTRE : lancer ttyd sous l'humain, sur SA socket AF_UNIX.
# Il ne cree pas l'humain (entrypoint), ne provisionne rien (provision), et n'authentifie personne —
# l'authentification est celle du deck, une fois, via Gitea.
#
# ⚠ PLUS AUCUN PORT, ET C'EST L'INVARIANT DU SCRIPT. La console ecoutait sur `21000+(uid%500)*10+4`
# et la console de pod sur `+5`. Les deux slots sont MORTS : le terminal n'est plus joignable que
# par `/run/lcars/console/<human>/{console,pod}.sock`, dont la traversee est gardee par le mode du
# repertoire. Ne pas les re-attribuer sans lire pourquoi ils ont ete rendus (bloc « LE TERMINAL N'A
# PLUS DE PORT » plus bas) : republier un port ici, c'est recreer la seconde origine, et avec elle
# le shell inscriptible que personne ne garde.
#
# MULTI-HUMAIN (`--all`) : un repertoire de socket par humain, possede par lui. N humains = N
# consoles sans une ligne de coordination. L'isolation reste celle de l'OS (chacun son uid, son
# home, ses sockets tmux), pas une couche applicative — c'est la meme doctrine qu'avec les ports,
# le discriminant a seulement cesse d'etre un numero pour devenir un inode garde.
# L'eligibilite (et la garde anti-systeme qui empeche root de partager le bloc de l'uid 1000) vit
# dans `console-humans.sh` — source unique, cf. son en-tete.
#
# tmux derriere ttyd : `new-session -A` = attache si la session existe, la cree sinon. Le shell
# SURVIT donc au rechargement de l'onglet, et l'humain retrouve son `claude` en cours.
#
# USAGE : console.sh [--human USER | --all] [--foreground]
# EXIT  : 0 lance · 1 erreur d'usage/identite
#
# ⚠ `--port N` A ETE RETIRE, pas deprecie : il n'existe plus de port a choisir. Une option qui
# accepte encore une valeur qu'elle jette est pire qu'une option absente — l'appelant croit avoir
# regle quelque chose. Le chemin de socket, lui, se deplace par LCARS_CONSOLE_SOCK_ROOT.

set -euo pipefail

HUMAN="${LCARS_HUMAN:-lcars}"
FOREGROUND=0
ALL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --human) HUMAN="${2:?--human attend un login}"; shift 2 ;;
    --all)   ALL=1; shift ;;
    --port)  echo "console.sh: --port a ete retire — le terminal n'a plus de port (socket AF_UNIX)" >&2; exit 1 ;;
    --foreground) FOREGROUND=1; shift ;;
    -h|--help) sed -n '6,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "console.sh: option inconnue: $1 (--help)" >&2; exit 1 ;;
  esac
done

say() { echo "[lcars-console] $*"; }

command -v ttyd >/dev/null || { echo "console.sh: ttyd absent de l'image" >&2; exit 1; }

# ─── LE TERMINAL N'A PLUS DE PORT ───────────────────────────────────────────────────────────────
# CE N'EST PAS UN DURCISSEMENT, C'EST UN CHANGEMENT DE TOPOLOGIE. Tant que ttyd ecoutait sur
# `-p <port> -i 0.0.0.0`, il existait une SECONDE ORIGINE : quiconque atteignait la loopback de
# l'hote obtenait un shell inscriptible sous l'identite de l'humain, dans un conteneur qui porte
# SYS_ADMIN, sans qu'on lui demande rien. Le landing avait beau verifier une session Gitea, il ne
# gardait qu'un annuaire — les portes, elles, ne demandaient rien.
#
# Une regle se contourne et s'oublie a la route suivante ; une topologie ne se contourne pas. Il n'y
# a plus de second chemin a discipliner parce qu'il n'y a plus de second chemin : le seul acces
# passe par le relais du deck, qui a deja verifie la session.
#
# LA GARDE EST LE REPERTOIRE, PAS LE FICHIER. `connect(2)` exige de traverser CHAQUE repertoire du
# chemin *et* d'ecrire sur la socket. On gate donc sur le repertoire, ce qui est plus fort et plus
# simple que de chercher le bon mode sur un fichier que ttyd recree a chaque demarrage :
#
#   /run/lcars/console/<human>/   <human>:lcars-console   2710
#
#   0710 : le proprietaire fait tout · le groupe TRAVERSE seulement (--x, pas de listage) · les
#          autres, rien ;
#   2    : le setgid fait heriter le groupe aux inodes crees dedans — donc la socket que ttyd cree
#          sort en `lcars-console` SANS que ttyd change d'identite (il reste sous l'humain).
#
# ⚠ MESURE DU 2026-08-14, ET ELLE CONTREDIT CE QU'ON CROIT : ttyd `chmod` sa socket LUI-MEME, en
# 0660, et IGNORE l'umask du processus — verifie sur umask 022, 077, 007 et 000, les quatre donnant
# `srw-rw----`. Ne PAS ajouter d'`umask` ici en croyant que c'est lui qui rend la socket
# groupe-inscriptible : ce serait un modele faux, et il enverrait chercher le prochain bug de
# permission du mauvais cote.
CONSOLE_SOCK_ROOT="${LCARS_CONSOLE_SOCK_ROOT:-/run/lcars/console}"
CONSOLE_GROUP="${LCARS_CONSOLE_GROUP:-lcars-console}"

# Rend le repertoire de socket de l'humain, cree et garde. Echoue FORT : une socket qui sort dans le
# mauvais groupe est injoignable par le deck, et la console serait morte sans que rien ne le dise.
sock_dir_for() {
  # DEUX `local`, ET CE N'EST PAS DU STYLE : dans `local a="$1" b="$a"`, les expansions sont faites
  # AVANT que le builtin n'affecte quoi que ce soit — `$a` y vaut donc l'ancien, pas le nouveau.
  # Ecrit en une ligne, `dir` lisait le `human` de l'appelant. Ca donnait la bonne valeur par
  # accident (l'appelant a le meme), et ca aurait casse au premier appel depuis ailleurs.
  local human="$1"
  local dir="$CONSOLE_SOCK_ROOT/$human"

  getent group "$CONSOLE_GROUP" >/dev/null 2>&1 || {
    echo "console.sh: groupe $CONSOLE_GROUP absent — l'image ne le cree pas (Dockerfile)" >&2
    return 1
  }

  # Le parent est traversable par tous (--x) et listable par personne d'autre que root : il ne porte
  # aucun secret, mais enumerer les humains de la boite n'a a servir personne.
  install -d -m 0711 -o root -g root "$CONSOLE_SOCK_ROOT" || return 1
  install -d -m 2710 -o "$human" -g "$CONSOLE_GROUP" "$dir" || return 1

  # `install -d` ne REPOSE pas le mode d'un repertoire qui existe deja — donc un repertoire herite
  # d'une version anterieure garderait son ancien mode en silence. On le reaffirme.
  chmod 2710 "$dir" && chown "$human:$CONSOLE_GROUP" "$dir" || return 1

  # ⚠ UN CHEMIN AF_UNIX EST PLAFONNE, ET LE DEPASSEMENT EST MUET LA OU IL COMPTE. Mesure du
  # 2026-08-14 DANS L'IMAGE, par `bind()` successifs : 106 OK, 107 OK, 108 « AF_UNIX path too long ».
  # Au-dela, ttyd meurt une demi-seconde apres son lancement — indiscernable, dans les logs du
  # conteneur, d'un ttyd qui n'a pas su demarrer. Trouve en ecrivant le test de ce script : le
  # harnais posait sa racine dans un repertoire temporaire profond et la console ne se levait jamais.
  #
  # En production le chemin est court (`/run/lcars/console/<login>/console.sock`), donc ce garde ne
  # se declenchera pour ainsi dire jamais — c'est exactement pourquoi il doit exister : le jour ou
  # un login long ou une racine deplacee le franchit, le motif doit etre ecrit, pas devine.
  local probe="$dir/console.sock"
  if [[ "${#probe}" -gt 107 ]]; then
    echo "console.sh: chemin de socket trop long (${#probe} > 107 octets, limite sun_path) : $probe" >&2
    echo "console.sh: rapprocher la racine via LCARS_CONSOLE_SOCK_ROOT" >&2
    return 1
  fi

  printf '%s\n' "$dir"
}

# ─── Lancement d'UNE console ────────────────────────────────────────────────────────────────────
launch_one() {
  local human="$1" home_dir tmux_conf
  local -a tmux_args cmd

  id "$human" >/dev/null 2>&1 || { echo "console.sh: humain inconnu: $human" >&2; return 1; }

  # L'IDENTITE N'EST PAS QUE L'UID : `setpriv` change l'uid/gid et RIEN D'AUTRE — HOME, USER et
  # LOGNAME restent ceux de l'appelant (l'entrypoint tourne en root → HOME=/root). Mesure en direct :
  # `cd ~` dans la console repondait « /root: Permission denied ». Meme piege que `USER` dans un
  # Dockerfile, qui ne change pas HOME non plus. On pose donc l'environnement EXPLICITEMENT, et le
  # cwd de depart avec (sinon le shell s'ouvre sur `/`). Le `cd` vit dans un SOUS-SHELL : en mode
  # `--all`, un `cd` au niveau du script contaminerait l'humain suivant.
  home_dir="$(getent passwd "$human" | cut -d: -f6 || true)"
  [[ -n "$home_dir" && -d "$home_dir" ]] || { echo "console.sh: home introuvable pour $human" >&2; return 1; }

  # SHELL, LU DANS PASSWD COMME LE HOME (champ 7, meme source que le champ 6 juste au-dessus).
  # Un login-manager pose SHELL — sshd le fait. Sans lui ici, les deux portes de la boite (ssh,
  # console web) ne rendent pas le meme environnement.
  login_shell="$(getent passwd "$human" | cut -d: -f7 || true)"
  [[ -n "$login_shell" && -x "$login_shell" ]] || login_shell=/bin/bash

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
  local sock_dir sock
  sock_dir="$(sock_dir_for "$human")" || return 1
  sock="$sock_dir/console.sock"

  # UNE SOCKET RESIDUELLE EMPECHE LE BIND, et le mode d'echec est muet : ttyd meurt a peine lance,
  # exactement comme sur un port deja pris. La difference avec un port, c'est qu'un fichier SURVIT
  # au processus — donc ce nettoyage n'est pas une precaution, c'est la condition d'un redemarrage.
  rm -f "$sock"

  # `-H` : ttyd REFUSE (407) toute requete sans cet en-tete. C'est une garde en profondeur derriere
  # celle du repertoire, et elle est gratuite. ⚠ Elle ne vaut PAS authentification : ttyd verifie la
  # PRESENCE de l'en-tete, jamais sa valeur ni qui l'envoie. C'est le relais qui doit l'ECRASER pour
  # qu'un client ne puisse pas le forger — mesure du 2026-08-14 : sans en-tete 407, avec 200.
  cmd=(env "HOME=$home_dir" "USER=$human" "LOGNAME=$human" "SHELL=$login_shell"
       ttyd --writable -i "$sock" -H X-LCARS-Human -t titleFixed="LCARS console — $human"
       -t fontSize=15 -t 'theme={"background":"#000000","foreground":"#FF9900"}'
       tmux "${tmux_args[@]}" new-session -A -s console)

  say "console de $human sur $sock (plus aucun port publie)"

  if [[ "$FOREGROUND" -eq 1 ]]; then
    cd "$home_dir" && exec setpriv --reuid "$human" --regid "$human" --init-groups -- "${cmd[@]}"
  fi

  # Detache : l'entrypoint continue son travail (sshd doit demarrer quoi qu'il arrive). La sortie va
  # dans les logs du conteneur — une console qui meurt doit se voir, pas disparaitre en silence.
  ( cd "$home_dir" && setpriv --reuid "$human" --regid "$human" --init-groups -- "${cmd[@]}" ) &
  local pid=$!

  # « Lancee » n'est pas « vivante ». Un ttyd qui ne peut pas binder meurt dans la demi-seconde :
  # sans cette verification, `--all` compterait une console morte comme un succes et l'humain la
  # chercherait dans son navigateur. On mesure au lieu de declarer.
  #
  # ET ON MESURE LA SOCKET, PAS SEULEMENT LE PROCESSUS : un pid vivant dont la socket n'existe pas
  # est precisement l'etat qu'une console injoignable prend. Le processus n'est que le producteur ;
  # ce que le deck ira ouvrir, c'est le fichier.
  sleep 0.4
  if ! kill -0 "$pid" 2>/dev/null; then
    say "console de $human MORTE au demarrage — socket $sock impossible a poser ? (motif au-dessus)"
    return 1
  fi
  if [[ ! -S "$sock" ]]; then
    say "console de $human : processus vivant mais AUCUNE socket en $sock — injoignable"
    return 1
  fi
  say "console de $human vivante (pid $pid, $(stat -c '%A %U:%G' "$sock"))"

  launch_pod_console "$human" "$home_dir" "$login_shell" "$sock_dir"
}

# ─── LA CONSOLE D'UN POD : UN SEUL TTYD POUR TOUS LES AGENTS ────────────────────────────────────
# `--url-arg` laisse le client nommer le pod dans l'URL (`?arg=<pod_id>`), donc UNE instance sert
# N agents. Un ttyd par pod epuiserait le bloc de 10 ports de l'humain a la sixieme mission —
# c'est la seule forme qui tienne dans le bloc, et elle garde le deck (base+5) a un port fixe.
#
# L'ARGUMENT EST UNE ENTREE DU MONDE : il ne va JAMAIS directement a `lcars attach`. `console-pod.sh`
# le valide (forme, unicite, socket existant) et refuse a l'ecran. Sans cette garde, le client
# choisirait les arguments d'une commande locale.
#
# ⚠ `--url-arg` RESTE, ET SON DANGER CHANGE DE NATURE. Tant que ce ttyd avait un port, `?arg=<pod_id>`
# laissait quiconque atteignait la loopback piloter le terminal de N'IMPORTE QUEL pod vivant — la
# garde de `console-pod.sh` verifie la FORME de l'argument, jamais le DROIT de celui qui le passe,
# parce qu'elle n'a aucune identite a comparer. Cette socket est desormais celle d'UN humain, donc
# l'appelant est deja etabli quand l'argument arrive : le relais n'ouvre la socket de <human> que
# pour <human>. La garde de forme reste necessaire (elle protege une commande locale), elle n'est
# plus seule.
launch_pod_console() {
  local human="$1" home_dir="$2" login_shell="$3" sock_dir="$4"
  local pod_sh="${LCARS_CONSOLE_POD:-/opt/lcars/console-pod.sh}"
  local sock="$sock_dir/pod.sock"

  [[ -x "$pod_sh" ]] || { say "consoles de pod indisponibles pour $human ($pod_sh absent)"; return 0; }

  rm -f "$sock"

  local cmd=(env "HOME=$home_dir" "USER=$human" "LOGNAME=$human" "SHELL=$login_shell"
             ttyd --writable --url-arg -i "$sock" -H X-LCARS-Human
             -t titleFixed="LCARS pod — $human" -t fontSize=15
             -t 'theme={"background":"#000000","foreground":"#FF9900"}'
             "$pod_sh")

  ( cd "$home_dir" && setpriv --reuid "$human" --regid "$human" --init-groups -- "${cmd[@]}" ) &
  local pid=$!
  sleep 0.4
  if ! kill -0 "$pid" 2>/dev/null; then
    say "consoles de pod de $human MORTES au demarrage — socket $sock impossible a poser ? (motif au-dessus)"
    return 0
  fi
  if [[ ! -S "$sock" ]]; then
    say "consoles de pod de $human : processus vivant mais AUCUNE socket en $sock — injoignables"
    return 0
  fi
  say "consoles de pod de $human sur $sock (un onglet par agent, via le deck)"
}

# ─── Mode ───────────────────────────────────────────────────────────────────────────────────────
if [[ "$ALL" -eq 1 ]]; then
  [[ "$FOREGROUND" -eq 0 ]] || { echo "console.sh: --all et --foreground sont exclusifs" >&2; exit 1; }

  HUMANS_SH="${LCARS_CONSOLE_HUMANS:-/opt/lcars/console-humans.sh}"
  [[ -x "$HUMANS_SH" ]] || { echo "console.sh: $HUMANS_SH introuvable" >&2; exit 1; }

  n=0
  # `--verbose` : les rejets partent sur stderr → visibles dans `docker logs`. Un humain qui n'a PAS
  # eu sa console doit laisser une trace avec son motif ; un silence ferait croire a un oubli.
  while read -r login _uid _home; do
    [[ -n "$login" ]] || continue
    launch_one "$login" && n=$(( n + 1 )) || say "console de $login NON lancee"
  done < <("$HUMANS_SH" --verbose)

  say "$n console(s) lancee(s)"
  [[ "$n" -gt 0 ]] || { echo "console.sh: aucun humain eligible" >&2; exit 1; }
  exit 0
fi

launch_one "$HUMAN"
