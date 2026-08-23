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

# Pas de defaut : identite-v2 a retire « l'humain » unique (`LCARS_HUMAN`). Une console vise un login
# EXPLICITE (`--human`) ou toute la liste (`--all`) ; une invocation nue se refuse au lieu de deviner.
HUMAN=""
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

# ─── UNE CONSOLE VIVANTE SE MESURE EN S'Y CONNECTANT ────────────────────────────────────────────
#
# ⚠ CE SCRIPT ETAIT DECLARE IDEMPOTENT AILLEURS, ET IL NE L'ETAIT PAS. `human-converger.sh` porte
# depuis le 2026-08-17 un `ensure_console` PAR HUMAIN ET PAR TOUR (30 s), sous un commentaire qui
# affirmait « console.sh --human est IDEMPOTENT : il sonde la socket avant de lancer quoi que ce
# soit ». Il ne sondait rien : il faisait `rm -f` sur la socket puis relancait un ttyd.
#
# Mesure du 2026-08-18 sur un banc de 30 minutes : **64 ttyd par humain**, empiles sur la meme
# socket, celle-ci effacee et re-posee sous le navigateur a chaque tour. C'est le defaut que
# l'operateur voyait comme « la console du nouvel humain ne demarre pas » — elle demarrait, et la
# suivante la remplacait. Un redemarrage du conteneur « reparait » en vidant la pile, jusqu'au tour
# suivant.
#
# La sonde MESURE ce que le deck fera : elle ouvre la socket. Un fichier residuel sans serveur
# derriere refuse la connexion — c'est exactement la difference entre « injoignable » et
# « vivante », et `[[ -S ]]` ne la voit pas.
console_alive() { # <socket> — 0 si un serveur repond dessus
  local sock="$1"
  [[ -S "$sock" ]] || return 1
  python3 - "$sock" <<'PROBE' 2>/dev/null
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(2)
try:
    s.connect(sys.argv[1])
finally:
    s.close()
PROBE
}
# ─── « VIVANTE » NE DIT PAS « A JOUR ». LE CREDENTIAL DE LA CONSOLE PERIME, ET RIEN NE LE RATTRAPE ─
#
# MESURE DU 2026-08-21, ET C'EST LE DEFAUT QUI RENDAIT LA PROMOTION INOPERANTE. Une console est
# lancee par `setpriv --reuid <h> --regid <h> --init-groups`, et `--init-groups` lit la base des
# groupes UNE FOIS, a l'exec. Le set atterrit donc dans TTYD, et tout ce qu'il engendre en herite :
# le serveur tmux, le shell, ce que l'humain y tape. Un `usermod -aG` ecrit /etc/group et ne touche
# AUCUN process vivant — la regle Unix qui vaut deja pour la revocation, en tete de
# `human-converger.sh`.
#
# ⚠ CE GESTE NE NOMME AUCUN GROUPE, ET C'EST CE QUI LE FAIT SURVIVRE. Il est ne pour rattraper la
# projection de `is_admin` en groupe unix, qui n'existe plus — l'adminite se demande a la forge a
# l'instant du geste. Il mesure une derive GENERIQUE : le premier gid que la base accorde et que ce
# ttyd ne porte pas, quel qu'il soit. `fleet` en fait partie, donc il garde un objet.
#
# Jusqu'ici la sonde d'idempotence ci-dessus etait le SEUL predicat : socket qui repond -> on ne
# touche a rien. Pour la console du deck, la consequence n'etait pas « effectif a sa prochaine
# session », c'etait JAMAIS : l'onglet ne redemarre pas, `ensure_console` retourne tot a chaque
# tour, et ce ttyd garde les groupes de sa naissance pour la duree du conteneur. Or c'est la SEULE
# surface ou l'humain tape des commandes — donc la seule ou son adminite se depense.
#
# ⚠ `tmux kill-server` NE REPARE RIEN, et je l'ai prescrit pendant un jour dans le refus de
# `lcars catalogue install`. Le serveur tmux n'est pas le porteur du cache, il en est l'HERITIER :
# le suivant naitra sous le meme ttyd perime, avec exactement les memes groupes.
#
# ⚖ ARBITRAGE USER (2026-08-21) : ON NE TUE RIEN, ON TAPE `newgrp`.
# Premiere ecriture : tuer ttyd et le serveur tmux, laisser `ensure_console` relancer. Ca marche et
# c'est disproportionne — on detruit un porteur pour rafraichir un shell. `newgrp` fait exactement
# le meme travail (il est setuid-root, relit /etc/group, et demarre un shell avec le set a jour)
# sans rien detruire. Le pire risque devient : la ligne a moitie tapee est perdue, et l'humain perd
# cinq secondes. Le geste porte donc son propre commentaire, visible a l'ecran.
#
# CE QUE `newgrp` NE REPARE PAS, et il faut le savoir : il corrige LE SHELL DE CE PANE, pas ttyd ni
# le serveur tmux. Une fenetre tmux ouverte plus tard nait du serveur, donc perimee — et retombe
# sur le refus de `lcars`, qui nomme `newgrp`. On repare le cas courant automatiquement ; le cas
# rare garde un message juste. C'est strictement mieux que l'etat precedent, ou aucun des deux
# n'etait vrai.
#
# SOUS-ENSEMBLE, PAS EGALITE — DECISION EXPLICITE (⚖ user, 2026-08-21). On agit quand la base a un
# groupe que le process n'a PAS (promotion). Le cas inverse — le process porte un groupe que la
# base a retire (demotion) — ne declenche rien : `newgrp` ne peut de toute facon RIEN retirer, et
# la demotion est un probleme de fail-open qui se traite ailleurs.
PROC_ROOT="${LCARS_PROC_ROOT:-/proc}"

console_ttyd_pid() { # <repertoire de socket> <humain> — le pid du ttyd de la console, ou vide
  pgrep -u "$2" -f "$1/console.sock" 2>/dev/null | head -1
}

db_gids() { # <humain> — les gid de la BASE, tries, sur une ligne
  id -G "$1" 2>/dev/null | tr ' ' '\n' | sort -n | tr '\n' ' '
}

# LA MESURE, ET ELLE EST AUSSI L'ARGUMENT. Elle rend le premier groupe que la BASE accorde et que
# le ttyd de cette console ne porte pas ; vide = rien a faire. Un seul objet pour le predicat et
# pour le geste : deux fonctions se seraient repondu differemment le jour ou l'une aurait derive.
#
# ⚠ FAIL-OPEN DELIBERE SUR L'ABSENCE DE MESURE : sans pid, sans /proc lisible, sans `id -G`, elle
# rend vide et on n'agit pas. Un `newgrp` envoye sur une mesure ratee tombe dans un shell qui n'en
# avait pas besoin.
missing_group_of() { # <repertoire de socket> <humain> — nom du groupe manquant, ou vide
  local pid proc_gids g
  pid="$(console_ttyd_pid "$1" "$2")"
  [[ -n "$pid" && -r "$PROC_ROOT/$pid/status" ]] || return 0
  # `Groups:` ne porte QUE les groupes supplementaires — le gid primaire vit sur `Gid:`, et
  # l'oublier ferait declarer perime tout process dont le gid primaire est dans `id -G`,
  # c'est-a-dire TOUS. Les deux lignes, donc, et un tampon d'espaces pour que `2000` ne matche
  # pas `12000`.
  proc_gids=" $(awk '/^Groups:/{ $1=""; print } /^Gid:/{ print $2 }' "$PROC_ROOT/$pid/status" \
                 | tr '\n' ' ') "
  for g in $(db_gids "$2"); do
    [[ "$proc_gids" == *" $g "* ]] && continue
    getent group "$g" 2>/dev/null | cut -d: -f1
    return 0
  done
}

# LE TAMPON, ET IL EST NECESSAIRE PARCE QUE LA MESURE NE GUERIT PAS. `newgrp` cree un shell ENFANT :
# le `pane_pid` que tmux rapporte reste celui du shell d'origine, qui n'aura jamais le groupe. Un
# convergeur qui remesurerait sans se souvenir retaperait `newgrp` toutes les 30 s, indefiniment —
# le cousin exact du defaut des 64 ttyd empiles. On enregistre donc le set de groupes pour lequel on
# a deja tape : une frappe par changement de groupes, pas une par tour.
#
# ⚠ IL S'ECRIT APRES UNE FRAPPE REUSSIE, JAMAIS AVANT. Pose d'avance, il consommerait le droit
# d'agir sur une console ou aucun pane n'etait frappable — celle dont l'unique pane fait tourner un
# agent, precisement le cas courant ici. Ecrit apres, la reparation attend simplement que l'humain
# revienne a son shell.
creds_stamp_path() { printf '%s/.creds-generation' "$1"; }

# LA FRAPPE. Un seul geste, et il ne s'execute que dans un SHELL.
#
# ⚠ `pane_current_command` EST LA GARDE, ET ELLE N'EST PAS DECORATIVE. Sans elle, `send-keys` ecrit
# dans ce qui tourne dans le pane : un prompt d'agent, un `vim`, un `sudo` qui attend un mot de
# passe. Le cout annonce (« une ligne a moitie tapee est perdue ») n'est vrai QUE devant un shell ;
# devant autre chose, la meme frappe est une injection dans un programme tiers. On compare au shell
# de passwd — celui-la meme que ttyd a lance — plutot qu'a une liste de noms de shells a maintenir.
#
# `C-u` d'abord : il vide la ligne en cours. C'est ce qui rend le cout borne a « la commande en
# cours de frappe est perdue » au lieu de « elle est concatenee avec la notre ».
#
# LE GROUPE VISE EST CELUI QUI MANQUE, pas un nom recopie ici. S'il en manque plusieurs, le premier
# suffit : `newgrp` n'en prend qu'un, et le shell qu'il ouvre porte TOUS les groupes de la base de
# toute facon — l'argument ne choisit que le gid PRIMAIRE.
nudge_console_creds() { # <humain> <shell de login> <groupe manquant> — 0 si au moins un pane frappe
  local human="$1" grp="$3" shell_base panes pane cmd hit=1
  shell_base="$(basename "$2")"

  # ⚠ `env -u TMUX` N'EST PAS UNE PRECAUTION DE STYLE. `runuser` transmet l'environnement, et un
  # operateur qui lance ce script A LA MAIN le lance depuis un tmux — le sien. Sans ce retrait,
  # `tmux` viserait la socket de l'APPELANT au lieu de celle de l'humain, et `send-keys` taperait
  # dans la console de quelqu'un d'autre. Le mode 0700 de la socket refuserait aujourd'hui par
  # accident ; se reposer sur l'accident, c'est attendre le jour ou les deux uid coincident.
  panes="$(runuser -u "$human" -- env -u TMUX -u TMUX_PANE tmux list-panes -a \
             -F '#{pane_id}	#{pane_current_command}' 2>/dev/null || true)"
  [[ -n "$panes" ]] || return 1

  while IFS=$'\t' read -r pane cmd; do
    [[ -n "$pane" && "$cmd" == "$shell_base" ]] || continue
    # ⚠ DEUX APPELS, LE TEXTE PUIS `Enter` — ET CE N'EST PAS UN GOUT. Fusionner la frappe et sa
    # validation dans un seul `send-keys` ne tient pas : la ligne arrive, la validation se perd, et
    # ce qui reste a l'ecran est une commande TAPEE MAIS PAS LANCEE — un etat qui a exactement
    # l'air d'une reparation reussie tant qu'on ne regarde pas le pane. Mesure de l'operateur,
    # douze fois. La mienne, sur un bash nu hors console, ne l'a PAS reproduit : elle prouve donc
    # seulement que le bash nu n'est pas la console, pas que la fusion serait sure.
    #
    # Separer donne aussi ce qu'on ne pouvait pas avoir fusionne : si le texte ne passe pas, on ne
    # valide RIEN. Fusionne, un envoi partiel se serait fait executer.
    runuser -u "$human" -- env -u TMUX -u TMUX_PANE tmux send-keys -t "$pane" C-u \
      "newgrp $grp ### reset des perms de groupe : newgrp recharge les groupes de ce shell ###" \
      >/dev/null 2>&1 || continue
    runuser -u "$human" -- env -u TMUX -u TMUX_PANE tmux send-keys -t "$pane" Enter \
      >/dev/null 2>&1 || continue
    say "console de $human : « newgrp $grp » tape dans $pane (groupes acquis depuis son lancement)"
    hit=0
  done <<< "$panes"

  return "$hit"
}



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
  local human="$1" home_dir tmux_conf primary_gid
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

  # ─── LE GID PRIMAIRE SE LIT, IL NE SE DEVINE PAS DU NOM ────────────────────────────────────────
  # `setpriv --regid "$human"` supposait qu'un groupe porte le nom de l'humain — vrai sous
  # `USERGROUPS_ENAB yes` (le defaut Debian, donc l'image), FAUX des qu'un compte est cree avec un
  # groupe primaire nomme : `useradd -g fleet lcars` ne cree aucun groupe `lcars`.
  #
  # MESURE DU 2026-08-21, poste natif : « setpriv: failed to parse regid: 'lcars' », console MORTE
  # au demarrage, et le message pointait la socket — le motif reel etait deux lignes plus haut. Le
  # gid est le champ 4 de la MEME ligne de passwd d'ou sortent deja le home (6) et le shell (7) :
  # il n'y avait qu'a ne pas le deviner.
  primary_gid="$(getent passwd "$human" | cut -d: -f4 || true)"
  [[ "$primary_gid" =~ ^[0-9]+$ ]] || { echo "console.sh: gid primaire illisible pour $human" >&2; return 1; }

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

  # RIEN A FAIRE SI ELLE REPOND DEJA. C'est ce qui rend ce script rejouable a chaque tour du
  # convergeur sans empiler un ttyd de plus — cf. `console_alive` en tete pour la mesure de 64.
  #
  # ⚠ ON NE SORT PLUS SANS REGARDER LE CREDENTIAL. Une console vivante peut porter des groupes que
  # la base a depasses, et c'est le cas NORMAL apres une promotion (cf. `missing_group_of`). La
  # reparation ne relance rien : elle tape `newgrp` dans les panes qui sont a un shell.
  if console_alive "$sock"; then
    local grp want have
    grp="$(missing_group_of "$sock_dir" "$human")"
    if [[ -n "$grp" ]]; then
      want="$(db_gids "$human")"
      have="$(cat "$(creds_stamp_path "$sock_dir")" 2>/dev/null || true)"
      if [[ "$want" != "$have" ]]; then
        nudge_console_creds "$human" "$login_shell" "$grp" \
          && printf '%s' "$want" > "$(creds_stamp_path "$sock_dir")" 2>/dev/null || true
      fi
    fi
    launch_pod_console "$human" "$home_dir" "$login_shell" "$sock_dir" "$primary_gid"
    return 0
  fi

  # UNE SOCKET RESIDUELLE EMPECHE LE BIND, et le mode d'echec est muet : ttyd meurt a peine lance,
  # exactement comme sur un port deja pris. La difference avec un port, c'est qu'un fichier SURVIT
  # au processus — donc ce nettoyage n'est pas une precaution, c'est la condition d'un redemarrage.
  # On n'arrive ici QUE si personne ne repond : le fichier est un residu, pas un service.
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
    cd "$home_dir" && exec setpriv --reuid "$human" --regid "$primary_gid" --init-groups -- "${cmd[@]}"
  fi

  # Detache : l'entrypoint continue son travail (sshd doit demarrer quoi qu'il arrive). La sortie va
  # dans les logs du conteneur — une console qui meurt doit se voir, pas disparaitre en silence.
  ( cd "$home_dir" && setpriv --reuid "$human" --regid "$primary_gid" --init-groups -- "${cmd[@]}" ) &
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

  launch_pod_console "$human" "$home_dir" "$login_shell" "$sock_dir" "$primary_gid"
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
  local human="$1" home_dir="$2" login_shell="$3" sock_dir="$4" primary_gid="$5"
  local pod_sh="${LCARS_CONSOLE_POD:-/opt/lcars/console-pod.sh}"
  local sock="$sock_dir/pod.sock"

  [[ -x "$pod_sh" ]] || { say "consoles de pod indisponibles pour $human ($pod_sh absent)"; return 0; }

  # Sa propre sonde, parce que c'est sa propre socket : la console d'un humain peut vivre pendant
  # que celle de ses pods est morte. Une garde partagee avec l'appelant laisserait ce cas sans
  # reparation, et c'est le cas qui se voit le moins.
  console_alive "$sock" && return 0

  rm -f "$sock"

  local cmd=(env "HOME=$home_dir" "USER=$human" "LOGNAME=$human" "SHELL=$login_shell"
             ttyd --writable --url-arg -i "$sock" -H X-LCARS-Human
             -t titleFixed="LCARS pod — $human" -t fontSize=15
             -t 'theme={"background":"#000000","foreground":"#FF9900"}'
             "$pod_sh")

  ( cd "$home_dir" && setpriv --reuid "$human" --regid "$primary_gid" --init-groups -- "${cmd[@]}" ) &
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

[[ -n "$HUMAN" ]] || { echo "console.sh: --human <login> ou --all requis" >&2; exit 1; }
launch_one "$HUMAN"
