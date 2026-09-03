#!/usr/bin/env bash
# SOURCE: runtime/services/console.sh
# AUTHOR: consultant
# STARDATE: 2026-07-31
# STATUS: la console web du conteneur — un shell dans le navigateur, SOUS L'IDENTITE de l'humain
#
# La porte d'entree que ni ssh ni Claude Desktop ne donnent : ssh demande une cle, Desktop exige un
# pod DEJA vivant. Ici, une page web, un shell, et `claude` lancable dedans. ssh reste la porte
# d'admin ; ceci ne la remplace pas.
#
# CE QUE CE SCRIPT FAIT, ET RIEN D'AUTRE : lancer ttyd sous l'humain, sur SA socket AF_UNIX.
# Il ne cree pas l'humain, ne provisionne rien, et n'authentifie personne — l'authentification est
# celle du deck, une fois, via Gitea.
#
# MULTI-HUMAIN (`--all`) : un repertoire de socket par humain, possede par lui, donc N consoles sans
# une ligne de coordination. L'isolation est celle de l'OS — chacun son uid, son home, ses sockets
# tmux — pas une couche applicative.
#
# tmux derriere ttyd : `new-session -A` attache si la session existe, la cree sinon. Le shell SURVIT
# donc au rechargement de l'onglet, et l'humain retrouve son `claude` en cours.
#
# USAGE : console.sh [--human USER | --all] [--foreground]
# EXIT  : 0 lance · 1 erreur d'usage/identite
#

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
    # Borne RELATIVE, et la ligne terminale est EXCLUE : une plage a numeros absolus fait glisser la
    # fenetre sur le code des qu'une ligne de l'en-tete bouge. `^[^#]` ne matche pas une ligne vide
    # (aucun caractere a comparer), donc la plage court jusqu'au premier VRAI code — qu'on n'imprime pas.
    -h|--help) sed -n '6,/^[^#]/{/^[^#]/!p;}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "console.sh: option inconnue: $1 (--help)" >&2; exit 1 ;;
  esac
done

say() { echo "[lcars-console] $*"; }

command -v ttyd >/dev/null || { echo "console.sh: ttyd absent de l'image" >&2; exit 1; }

# ⚠ PLUS AUCUN PORT, ET CE N'EST PAS UN DURCISSEMENT MAIS UN CHANGEMENT DE TOPOLOGIE. Tant que ttyd
# ecoutait sur `-p <port> -i 0.0.0.0`, il existait une SECONDE ORIGINE : quiconque atteignait la
# loopback de l'hote obtenait un shell inscriptible sous l'identite de l'humain, dans un conteneur
# qui porte SYS_ADMIN. Republier un port ici recreerait ce chemin, que personne ne garde.
#
# LA GARDE EST LE REPERTOIRE, PAS LE FICHIER : `connect(2)` exige de traverser CHAQUE repertoire du
# chemin, ce qui est plus sur que de courir apres le mode d'un fichier que ttyd recree a chaque
# demarrage. Le `2` du `2710` fait heriter le groupe aux inodes crees dedans — donc la socket sort
# en `lcars-console` SANS que ttyd change d'identite.
#
# ⚠ MESURE, ET ELLE CONTREDIT CE QU'ON CROIT : ttyd `chmod` sa socket LUI-MEME en 0660 et IGNORE
# l'umask du processus (verifie sur 022, 077, 007, 000). Ne PAS ajouter d'`umask` ici en croyant
# que c'est lui qui rend la socket groupe-inscriptible : le prochain bug de permission se
# chercherait du mauvais cote.
CONSOLE_SOCK_ROOT="${LCARS_CONSOLE_SOCK_ROOT:-/run/lcars/console}"
CONSOLE_GROUP="${LCARS_CONSOLE_GROUP:-lcars-console}"

# ─── UNE CONSOLE VIVANTE SE MESURE EN S'Y CONNECTANT ────────────────────────────────────────────
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
# ─── « VIVANTE » NE DIT PAS « A JOUR » : LE CREDENTIAL D'UNE CONSOLE PERIME ─────────────────────
#
# `newgrp` est le remede parce qu'il est setuid-root, relit /etc/group et demarre un shell avec le
# set a jour — sans detruire le porteur.
#
# ⚠ CE QU'IL NE REPARE PAS : le shell de CE pane, et lui seul. Ni ttyd, ni le serveur tmux — une
# fenetre ouverte plus tard nait du serveur, donc perimee, et retombe sur le refus de `lcars` qui
# nomme `newgrp`. Le cas courant se repare tout seul, le cas rare garde un message juste.
#
# ⚠ CE GESTE NE NOMME AUCUN GROUPE, et c'est ce qui le fait survivre a la projection qui l'a fait
# naitre : il mesure une derive GENERIQUE, le premier gid que la base accorde et que ce ttyd ne
# porte pas, quel qu'il soit.
PROC_ROOT="${LCARS_PROC_ROOT:-/proc}"

console_ttyd_pid() { # <repertoire de socket> <humain> — le pid du ttyd de la console, ou vide
  pgrep -u "$2" -f "$1/console.sock" 2>/dev/null | head -1
}

db_gids() { # <humain> — les gid de la BASE, tries, sur une ligne
  id -G "$1" 2>/dev/null | tr ' ' '\n' | sort -n | tr '\n' ' '
}

# UN SEUL OBJET POUR LE PREDICAT ET POUR LE GESTE : deux fonctions se seraient repondu differemment
# le jour ou l'une aurait derive.
missing_group_of() { # <repertoire de socket> <humain> — nom du groupe manquant, ou vide
  local pid proc_gids g
  pid="$(console_ttyd_pid "$1" "$2")"
  [[ -n "$pid" && -r "$PROC_ROOT/$pid/status" ]] || return 0
  # Les DEUX lignes (`Groups:` ne porte que les supplementaires, le primaire vit sur `Gid:`), et un
  # tampon d'espaces pour que `2000` ne matche pas `12000`.
  proc_gids=" $(awk '/^Groups:/{ $1=""; print } /^Gid:/{ print $2 }' "$PROC_ROOT/$pid/status" \
                 | tr '\n' ' ') "
  for g in $(db_gids "$2"); do
    [[ "$proc_gids" == *" $g "* ]] && continue
    getent group "$g" 2>/dev/null | cut -d: -f1
    return 0
  done
}

# ⚠ LE TAMPON EST NECESSAIRE PARCE QUE LA MESURE NE GUERIT PAS : `newgrp` cree un shell ENFANT, et
# le `pane_pid` que tmux rapporte reste celui du shell d'origine, qui n'aura JAMAIS le groupe.
# Remesurer sans se souvenir retaperait `newgrp` a chaque tour, indefiniment.
creds_stamp_path() { printf '%s/.creds-generation' "$1"; }

# ⚠ `pane_current_command` EST LA GARDE : sans elle, `send-keys` ecrit dans ce qui tourne — un
# prompt d'agent, un `vim`, un `sudo` qui attend un mot de passe. Le cout annonce (« une ligne a
# moitie tapee est perdue ») n'est vrai QUE devant un shell ; ailleurs c'est une injection dans un
# programme tiers. On compare au shell de passwd, pas a une liste de noms a maintenir.
#
# S'il manque plusieurs groupes, le premier suffit : l'argument de `newgrp` ne choisit que le gid
# PRIMAIRE, et le shell qu'il ouvre porte de toute facon TOUS les groupes de la base.
nudge_console_creds() { # <humain> <shell de login> <groupe manquant> — 0 si au moins un pane frappe
  local human="$1" grp="$3" shell_base panes pane cmd hit=1
  shell_base="$(basename "$2")"

  # ⚠ `env -u TMUX` N'EST PAS DU STYLE : `runuser` transmet l'environnement, et un operateur qui
  # lance ce script a la main le lance depuis SON tmux. Sans ce retrait, `send-keys` taperait dans
  # la console de quelqu'un d'autre — le mode 0700 refuserait aujourd'hui par accident, et se
  # reposer sur l'accident c'est attendre le jour ou les deux uid coincident.
  panes="$(runuser -u "$human" -- env -u TMUX -u TMUX_PANE tmux list-panes -a \
             -F '#{pane_id}	#{pane_current_command}' 2>/dev/null || true)"
  [[ -n "$panes" ]] || return 1

  while IFS=$'\t' read -r pane cmd; do
    [[ -n "$pane" && "$cmd" == "$shell_base" ]] || continue
    # ⚠ DEUX APPELS, LE TEXTE PUIS `Enter` : fusionnes, la ligne arrive et la validation se perd —
    # une commande TAPEE MAIS PAS LANCEE, qui a l'air d'une reparation reussie tant qu'on ne regarde
    # pas le pane. Separes, un texte qui ne passe pas ne valide RIEN.
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

  # ⚠ UN CHEMIN AF_UNIX EST PLAFONNE (107 octets, `sun_path`) ET LE DEPASSEMENT EST MUET : au-dela,
  # ttyd meurt une demi-seconde apres son lancement, indiscernable dans les logs d'un ttyd qui n'a
  # pas su demarrer. En production le chemin est court, donc ce garde ne servira presque jamais —
  # et c'est pourquoi il doit exister : le jour ou il mord, le motif doit etre ecrit, pas devine.
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

  # ⚠ L'IDENTITE N'EST PAS QUE L'UID : `setpriv` change uid/gid et RIEN D'AUTRE — HOME, USER et
  # LOGNAME restent ceux de l'appelant, root ici, donc `cd ~` repond « /root: Permission denied ».
  # L'environnement se pose EXPLICITEMENT, et le cwd avec. Le `cd` vit dans un SOUS-SHELL : en
  # `--all`, un `cd` au niveau du script contaminerait l'humain suivant.
  home_dir="$(getent passwd "$human" | cut -d: -f6 || true)"
  [[ -n "$home_dir" && -d "$home_dir" ]] || { echo "console.sh: home introuvable pour $human" >&2; return 1; }

  # SHELL, LU DANS PASSWD COMME LE HOME (champ 7, meme source que le champ 6 juste au-dessus).
  # Un login-manager pose SHELL — sshd le fait. Sans lui ici, les deux portes de la boite (ssh,
  # console web) ne rendent pas le meme environnement.
  login_shell="$(getent passwd "$human" | cut -d: -f7 || true)"
  [[ -n "$login_shell" && -x "$login_shell" ]] || login_shell=/bin/bash

  primary_gid="$(getent passwd "$human" | cut -d: -f4 || true)"
  [[ "$primary_gid" =~ ^[0-9]+$ ]] || { echo "console.sh: gid primaire illisible pour $human" >&2; return 1; }

  # `-f` : sans cette config, tmux possede l'ecran et le scrollback du navigateur ne voit RIEN.
  tmux_conf="${LCARS_CONSOLE_TMUX_CONF:-/opt/lcars/console.tmux.conf}"
  tmux_args=(-u)
  [[ -r "$tmux_conf" ]] && tmux_args+=(-f "$tmux_conf")

  local sock_dir sock
  sock_dir="$(sock_dir_for "$human")" || return 1
  sock="$sock_dir/console.sock"

  # ⚠ VIVANTE, MAIS PAS FORCEMENT A JOUR : on ne sort pas sans regarder le credential, une console
  # vivante portant des groupes perimes etant le cas NORMAL apres une promotion.
  if console_alive "$sock"; then
    local grp want have
    grp="$(missing_group_of "$sock_dir" "$human")"
    if [[ -n "$grp" ]]; then
      want="$(db_gids "$human")"
      have="$(cat "$(creds_stamp_path "$sock_dir")" 2>/dev/null || true)"
      if [[ "$want" != "$have" ]]; then
        nudge_console_creds "$human" "$login_shell" "$grp" \
          && { printf '%s' "$want" > "$(creds_stamp_path "$sock_dir")" 2>/dev/null || true; }
      fi
    fi
    launch_pod_console "$human" "$home_dir" "$login_shell" "$sock_dir" "$primary_gid"
    return 0
  fi

  # ⚠ CE NETTOYAGE N'EST PAS UNE PRECAUTION, C'EST LA CONDITION D'UN REDEMARRAGE : un fichier de
  # socket SURVIT au processus, empeche le bind, et ttyd meurt alors a peine lance. On n'arrive ici
  # QUE si personne ne repond — le fichier est un residu, pas un service.
  rm -f "$sock"

  # ⚠ `-H` NE VAUT PAS AUTHENTIFICATION : ttyd refuse (407) une requete sans cet en-tete, mais il en
  # verifie la PRESENCE, jamais la valeur ni qui l'envoie. C'est au relais de l'ECRASER pour qu'un
  # client ne puisse pas le forger.
  #
  # `--writable` : sans lui la console est un ecran MORT, lancee mais sourde aux frappes.
  #
  # LIMITE CONNUE, NON MITIGEE : deux onglets sur la meme console partagent la session tmux, et tmux
  # clampe l'affichage a la taille du plus PETIT client. Le `-m 1` qui l'eviterait refuserait aussi
  # le nouvel onglet tant que l'ancien traine au rechargement.
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

  # « Lancee » n'est pas « vivante », et on mesure LA SOCKET autant que le processus : un pid vivant
  # dont la socket n'existe pas est exactement l'etat d'une console injoignable. Le processus n'est
  # que le producteur ; ce que le deck ira ouvrir, c'est le fichier.
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
#
# ⚠ CE QUI REND `--url-arg` SUR ICI EST LA SOCKET, PAS LA GARDE : `console-pod.sh` verifie la FORME
# de l'argument, jamais le DROIT de celui qui le passe — il n'a aucune identite a comparer. C'est
# parce que cette socket est celle d'UN humain que l'appelant est deja etabli quand l'argument
# arrive. La garde de forme protege une commande locale ; elle n'etablit personne.
launch_pod_console() {
  local human="$1" home_dir="$2" login_shell="$3" sock_dir="$4" primary_gid="$5"
  local pod_sh="${LCARS_CONSOLE_POD:-/opt/lcars/console-pod.sh}"
  local sock="$sock_dir/pod.sock"

  [[ -x "$pod_sh" ]] || { say "consoles de pod indisponibles pour $human ($pod_sh absent)"; return 0; }

  # Sa propre sonde : la console d'un humain peut vivre pendant que celle de ses pods est morte, et
  # une garde partagee avec l'appelant laisserait sans reparation le cas qui se voit le moins.
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
    # `n=$(( … ))` rend toujours 0, donc le `||` ne se declenche que sur `launch_one` — mais la
    # forme est celle qui a fait mentir `p_ok` et `say_ok` dans ce meme lot. On la retire partout.
    if launch_one "$login"; then n=$(( n + 1 )); else say "console de $login NON lancee"; fi
  done < <("$HUMANS_SH" --verbose)

  say "$n console(s) lancee(s)"
  [[ "$n" -gt 0 ]] || { echo "console.sh: aucun humain eligible" >&2; exit 1; }
  exit 0
fi

[[ -n "$HUMAN" ]] || { echo "console.sh: --human <login> ou --all requis" >&2; exit 1; }
launch_one "$HUMAN"
