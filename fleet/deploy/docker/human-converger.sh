#!/usr/bin/env bash
# SOURCE: fleet/deploy/docker/human-converger.sh
# AUTHOR: DrDree
# STARDATE: (posee par /push-github)
# STATUS: PROTO-V2 — boucle root : la team `humans` de la forge -> les users Linux de la boite
#
# ─── CE QUE CE FICHIER REMPLACE ─────────────────────────────────────────────────────────────────
# Enroler quelqu'un demandait de REDEMARRER la boite : l'entrypoint creait les users au boot, donc
# ajouter une personne coutait un arret. Deux mesures suffisent a enterrer ca. Un contexte root
# tourne EN PERMANENCE (tini est PID 1, l'entrypoint finit sur `exec sshd -D -e`), donc le boot
# n'etait jamais la contrainte ; et `sudo` n'est pas installe, donc deleguer le `useradd` a un
# humain aurait coute une surface pour accorder ce que personne n'a besoin d'accorder.
#
# ─── LE MODELE : GITEA EST MAITRE DES HUMAINS ───────────────────────────────────────────────────
# On ne DECIDE rien ici. L'inscription est libre et un compte seul est inerte ; l'unique acte
# d'enrollment est l'ajout a la team `humans`, cote forge, par un proprietaire de l'org. Cette
# boucle ne fait que CONVERGER cette decision vers la boite. Elle n'ajoute personne a la team, elle
# n'en retire personne, et elle ne supprime JAMAIS un user Linux.
#
# ─── LA REVOCATION, ET POURQUOI ELLE TUE DES PROCESS ────────────────────────────────────────────
# Sortir de la team retire l'identite PROPRE de la personne. Ca ne suffisait pas : mesure du
# 2026-08-12, compte forge PURGE (204, re-lu 404), user Linux intact, elle gardait le groupe
# `fleet` — donc /home/private/system.gitea_token, donc un jeton qui REPOND `lcars-system` sur
# /api/v1/user, c'est-a-dire PROPRIETAIRE D'ORG — plus une console ttyd ECRIVABLE que
# `console.sh --all` lui relance (elle ne lit que /etc/passwd, jamais la forge) et qui repond 200
# sans aucune authentification.
#
# ⚠ RETIRER DU GROUPE NE MORD PAS SUR CE QUI TOURNE DEJA. Un process porte ses groupes
# supplementaires depuis son login ; `/etc/group` ne le rattrape jamais. Mesure du 2026-08-12 :
#   gpasswd -d theo fleet      -> `id theo` : groups=theo          (retire, cote base)
#   shell ouvert AVANT         -> groups=theo,fleet + jeton LU     (apres la revocation)
#   serveur tmux ne AVANT, nouvelle fenetre APRES -> groups=theo,fleet + jeton LU
# Un serveur tmux distribue son jeu de groupes a TOUS les shells qu'il fork ensuite, et il ne meurt
# jamais tout seul : il survit a ttyd, au navigateur ferme, a tout sauf un kill. Retirer du groupe
# sans tuer, c'est fermer la porte d'entree en laissant la maison allumee a l'interieur.
#
# D'ou les trois gestes, dans CET ordre :
#   1. `gpasswd -d` — plus de credentials partages pour tout NOUVEAU process ;
#   2. `pkill -u`   — les process qui portent encore l'ancien jeu de groupes meurent. Il n'existe
#      pas de version douce : c'est le meme process qui porte le travail et les credentials, donc
#      revoquer INTERROMPT. C'est le prix, il est assume, il n'est pas contournable ;
#   3. `usermod -s nologin` — la porte ne se rouvre pas. Sans ce troisieme geste, le prochain
#      `console.sh --all` relance la console : elle ne lit que /etc/passwd, et `console-humans.sh`
#      (source UNIQUE de l'eligibilite, lue aussi par la landing) ecarte deja `shell nologin`.
# `usermod` APRES le kill : il refuse de toucher un compte dont des process tournent encore.
#
# RIEN N'EST SUPPRIME : ni compte, ni home, ni donnees, ni uid. La revocation ferme des acces, elle
# n'efface pas une personne — et re-entrer dans la team RESTAURE l'entree (cf. `restore_human`),
# sans quoi la revocation serait un piege a sens unique.
#
# LE GARDE QUI COMPTE : on ne revoque JAMAIS sur une liste non prouvee. Forge injoignable, team
# introuvable ou liste vide -> `converge_once` sort AVANT la passe de revocation. Un hoquet reseau
# lu comme « plus personne dans la team » revoquerait toute la boite d'un coup.
#
# ─── FAIL-CLOSED SUR LE LOGIN, ET CE N'EST PAS DE LA PRUDENCE ───────────────────────────────────
# Les deux alphabets ne coincident pas, MESURE le 2026-08-12 sur cette image et cette forge :
#   · `useradd` accepte bien plus large qu'on ne croit — `Bob`, `1bob`, `bob@x`, `bob.`, `bob$`
#     passent. Il ne refuse que : plus de 32 caracteres, un espace, et un `-` initial (qui part en
#     PARSING D'OPTION, pas en refus de nom : c'est une injection d'argument, pas une coquille).
#   · Gitea refuse `_bob`, `bob$`, `bob@x`, `-bob`, `bob.`, `bob..x` — mais ACCEPTE `admin`, `b`,
#     `1bob`, et un nom de 33 caracteres que `useradd` refusera.
# Donc le danger n'est pas que Linux soit etroit : c'est que la forge laisse passer des noms qui
# collisionnent avec des comptes SYSTEME, et des noms trop longs pour aboutir. La validation est
# ici, avant le `useradd`, et elle REFUSE par defaut.
#
# La denylist se CALCULE (tout nom deja pris sous UID_MIN), elle ne se recopie pas : une liste en
# dur serait fausse le jour ou l'image ajoute un paquet qui cree son compte de service.
#
# ⚠ La team `humans` contient des comptes qui ne sont PAS des humains — mesure : elle porte
# `lcars-system` a cote de l'humain. Le compte systeme et les comptes de role sont donc exclus
# nommement, depuis la meme source que le provisioning.
#
# USAGE : human-converger.sh [--once]      (--once : une passe, pour sonder ou tester)
# EXIT  : 0 · 1 dependance absente · 2 configuration absente (fail-closed, jamais une boucle muette)

set -euo pipefail

ONCE=0
[[ "${1:-}" == "--once" ]] && ONCE=1

FORGE="${FORGE_BASE_URL:-}"
ORG="${LCARS_FORGE_ORG:-fleet}"
TEAM="${LCARS_HUMANS_TEAM:-humans}"
TOKEN_FILE="${FORGE_TOKEN_FILE:-/home/private/system.gitea_token}"
SYSTEM_ACCOUNT="${LCARS_SYSTEM_ACCOUNT:-lcars-system}"
ROLES="${LCARS_ROLES:-system_architect system_chief system_gatekeeper fleet_engineer fleet_scribe fleet_qualifier fleet_reviewer fleet_scoper fleet_vulcan}"
INTERVAL="${LCARS_CONVERGER_INTERVAL:-30}"
# CADENCE DE RECONCILIATION DE L'ETAT DES HUMAINS DEJA LA. La boucle rapide ci-dessus ne cree que
# les MANQUANTS ; sans cette seconde passe, tout ce qui est pose « a la creation » n'atteint jamais
# quelqu'un qui existe deja — c'est le piege que le Dockerfile nomme pour `/etc/skel` (« le squelette
# n'est copie qu'a la CREATION de l'humain, jamais ensuite : une boite deja installee ne le verrait
# jamais »), et le convergeur y etait tombe : un module per-humain ajoute apres coup, ou une graine
# `claude` mise a jour, n'auraient atteint personne.
# Meme forme que la passe desired-state du poller (`@protection_recheck_ms`) : cadence LENTE, et la
# PREMIERE passe apres le boot verifie tout le monde — la reconciliation au demarrage est la
# fonctionnalite, pas une rafale a raboter.
RECONCILE_EVERY="${LCARS_CONVERGER_RECONCILE:-3600}"
PROVISION="${LCARS_PROVISION:-/opt/lcars/fleet/deploy/provision}"
CONSOLE="${LCARS_CONSOLE_SH:-/opt/lcars/console.sh}"
SHELL_="${LCARS_HUMAN_SHELL:-/bin/bash}"
# Le shell d'un revoque. `console-humans.sh` ecarte `*/nologin` et `*/false` : poser celui-la ferme
# la console a la source, pour ses deux consommateurs a la fois.
NOLOGIN="${LCARS_NOLOGIN_SHELL:-/usr/sbin/nologin}"
GROUP="${LCARS_FLEET_GROUP:-fleet}"
HOME_ROOT="${LCARS_HOME_ROOT:-/home}"
# L'HUMAIN DE BOOTSTRAP N'EST PAS CONVERGE, ET NE SE REVOQUE DONC PAS. L'entrypoint le cree
# lui-meme (`LCARS_HUMAN`, defaut `lcars`) qu'il soit dans la team ou non : c'est le compte d'entree
# de la boite. Le passer a la revocation reviendrait a fermer la boite sur elle-meme au premier tour
# ou personne ne l'a ajoute a la team.
BOOTSTRAP="${LCARS_HUMAN:-lcars}"
# Un refus se dit UNE FOIS. Sans cette trace, un login invalide reproche la meme chose toutes les
# 30 s et noie le journal, ce qui revient a ne rien dire du tout.
REFUSED_FILE="${LCARS_CONVERGER_REFUSED:-/run/lcars-converger.refused}"
# 0 = la PREMIERE passe reconcilie tout le monde. C'est deliberé : la reconciliation au demarrage
# est la fonctionnalite (meme choix que le poller), pas une rafale a raboter.
LAST_RECONCILE=0

say() { echo "[lcars-converger] $*"; }
err() { echo "[lcars-converger] $*" >&2; }

# ─── L'ADMISSION ────────────────────────────────────────────────────────────────────────────────
# Ces trois predicats decident si un login de la forge devient un user Linux. C'est la seule partie
# qui, en se trompant, cree un compte que personne ne voulait — donc elle est definie AVANT le
# garde de sourcing, pour etre testable sans lancer ni preflight ni boucle (meme idiome que
# publish-to-github.sh).

# Les noms qu'on ne creera JAMAIS : tout ce qui est deja pris sous UID_MIN, plus les comptes de
# service de la fleet (qui vivent dans l'org, et dont l'un est membre de la team).
uid_min() { awk '/^UID_MIN/ {print $2}' "${PASSWD_DEFS:-/etc/login.defs}" 2>/dev/null | head -n1 || echo 1000; }

reserved() { # reserved <login> -> 0 si le nom est interdit
  local login=$1 lo min
  min="$(uid_min)"; min="${min:-1000}"
  lo="${login,,}"
  [[ "$lo" == "${SYSTEM_ACCOUNT,,}" ]] && return 0
  local r
  for r in $ROLES; do [[ "$lo" == "${r,,}" ]] && return 0; done
  # Un nom deja porte par un compte SOUS UID_MIN est un compte systeme : le convergeur ne
  # l'adopte pas, il refuse. Adopter reviendrait a donner un home et un shell fleet a `sshd`.
  awk -F: -v n="$login" -v m="$min" '$1==n && $3<m {found=1} END {exit !found}' \
      "${PASSWD_FILE:-/etc/passwd}" && return 0
  return 1
}

valid_login() { # valid_login <login> -> 0 si utilisable tel quel comme user Linux
  local login=$1
  [[ ${#login} -ge 1 && ${#login} -le 32 ]] || return 1
  # L'alphabet de Gitea, pas un plus large. Les DEUX bouts sont alphanumeriques : en tete parce
  # qu'un `-` initial serait lu comme une OPTION par useradd, en queue parce que Gitea refuse toute
  # ponctuation finale — mesure du 2026-08-12, `trail-`, `trail_` et `trail.` sont refuses tous les
  # trois a l'inscription. Exiger la meme chose ici ne rejette donc AUCUN login legitime.
  [[ "$login" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]] || return 1
  [[ "$login" != *".."* ]] || return 1
  return 0
}

# L'UID EST UNE PROPRIETE DURABLE, ET RIEN NE LE GARANTISSAIT. Mesure du 2026-08-12, au premier
# boot a froid : `/etc/passwd` meurt avec le conteneur, `/home` survit dans un volume. Le convergeur
# recreait donc les users dans l'ordre ou la team les rend — qui n'est PAS l'ordre de creation
# initial — et `useradd` distribuait les uid libres dans ce nouvel ordre. Resultat mesure : zoe est
# passee de 1001 a 1002, guest1 de 1002 a 1001, et chacune s'est retrouvee proprietaire du home de
# l'AUTRE : `mkdir /home/zoe/.lcars` en Permission denied, et surtout un `.claude/.credentials.json`
# et un `~/.lcars` 0700 lisibles par la mauvaise personne.
#
# Le home PORTE deja l'uid d'origine : c'est son proprietaire. On le relit au lieu de laisser l'OS
# redistribuer. Le chemin fait foi — `/home/<login>` est le home de <login>, quel que soit le nom
# auquel son uid numerique resout aujourd'hui.
uid_of_home() { # uid_of_home <login> -> uid proprietaire du home existant, ou vide
  local h="$HOME_ROOT/$1"
  [[ -d "$h" ]] || return 0
  stat -c %u "$h" 2>/dev/null || true
}

# Qui porte deja cet uid, s'il est pris par quelqu'un d'AUTRE que <login>.
uid_taken_by() { # uid_taken_by <uid> <login>
  awk -F: -v u="$1" -v me="$2" '$3==u && $1!=me {print $1; exit}' "${PASSWD_FILE:-/etc/passwd}"
}

already_refused() { grep -q "^$1	" "$REFUSED_FILE" 2>/dev/null; }

# LE REFUS EST PUBLIE, PAS SEULEMENT JOURNALISE, et c'est ce qui empeche un mensonge. Une personne
# dont le login est inutilisable EST membre de la team : le deck lui repondait « ca converge tout
# seul, rien a faire de ton cote » — pour une convergence qui n'arrivera JAMAIS. Le convergeur est
# le seul a savoir pourquoi ; il l'ecrit donc la ou le deck peut le lire.
# 0644 delibere : le deck tourne en `nobody`. Le fichier ne porte qu'un login public et une raison,
# aucun secret.
mark_refused() { # mark_refused <login> <raison lisible>
  mkdir -p "$(dirname "$REFUSED_FILE")"
  printf '%s\t%s\n' "$1" "$2" >> "$REFUSED_FILE"
  chmod 0644 "$REFUSED_FILE" 2>/dev/null || true
}

# Meme idiome de sonde que `PASSWD_FILE` plus haut : un fichier injectable pour les tests, la base
# reelle sinon. Sans ca, la selection des revoques ne serait epinglee par rien — et c'est la partie
# qui, en se trompant, ferme la porte a quelqu'un qui travaille.
group_members() { # group_members -> un login par ligne
  if [[ -n "${GROUP_FILE:-}" ]]; then
    awk -F: -v g="$GROUP" '$1==g {print $4}' "$GROUP_FILE"
  else
    getent group "$GROUP" 2>/dev/null | cut -d: -f4
  fi | tr ',' '\n' | grep -v '^$' || true
}

in_group() { group_members | grep -qxF -- "$1"; }

login_shell_of() { # login_shell_of <login>
  awk -F: -v n="$1" '$1==n {print $7}' "${PASSWD_FILE:-/etc/passwd}"
}

# Les humains que CETTE boite a converges : membres du groupe fleet, uid >= UID_MIN. C'est la seule
# trace qu'un enrollment a eu lieu, et elle se CALCULE — aucune liste tenue a la main ne resterait
# vraie. L'humain de bootstrap en est ecarte : il n'est pas venu de la team.
converged_humans() {
  local min login; min="$(uid_min)"; min="${min:-1000}"
  while IFS= read -r login; do
    [[ -n "$login" && "$login" != "$BOOTSTRAP" ]] || continue
    awk -F: -v n="$login" -v m="$min" '$1==n && $3>=m {print n}' "${PASSWD_FILE:-/etc/passwd}"
  done < <(group_members)
}

# LA DECISION, SEPAREE DU GESTE. Qui n'est plus dans la team ? C'est la seule partie qui, en se
# trompant, coupe quelqu'un — donc elle est pure, elle n'ecrit rien, et elle est epinglee par les
# tests comme `reserved` et `valid_login`.
#
# SANS ARGUMENT, ELLE NE DESIGNE PERSONNE. L'appelant garde deja contre une liste non prouvee ; ce
# second verrou est ici parce que les deux fautes qui menent au meme desastre — une team vide et une
# forge muette — se ressemblent trop pour ne compter que sur un seul garde.
absent_humans() { # absent_humans <membres…> -> les logins a revoquer, un par ligne
  [[ "$#" -gt 0 ]] || return 0
  local login
  while IFS= read -r login; do
    printf '%s\n' "$@" | grep -qxF -- "$login" && continue
    printf '%s\n' "$login"
  done < <(converged_humans)
  return 0
}

# Sourcer ce fichier donne l'ADMISSION et la SELECTION des revoques ci-dessus, et RIEN d'autre :
# ni preflight, ni boucle, et surtout aucun geste. Ce sont les deux decisions qui, en se trompant,
# creent un compte que personne ne voulait ou coupent quelqu'un qui travaille — elles sont donc
# lisibles et testables sans lancer la boucle.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then return 0; fi

command -v curl >/dev/null || { err "curl absent de l'image"; exit 1; }
command -v jq   >/dev/null || { err "jq absent de l'image"; exit 1; }

# FAIL-CLOSED, ET BRUYANT. Une boucle qui tourne sans savoir a quelle forge parler ne converge
# rien ; si elle se contentait de dormir, la boite aurait l'air d'attendre des humains alors
# qu'elle n'en verra jamais aucun.
# CES DEUX-LA AVANT LE CONTROLE DE ROOT, deliberement : la configuration est ce qu'un operateur se
# trompe, tandis qu'etre root est une propriete du LANCEMENT (l'entrypoint l'est toujours). Faire
# passer le refus de privilege en premier repondrait a cote de la question posee.
[[ -n "$FORGE" ]] || { err "FORGE_BASE_URL non pose — aucun enrollment ne peut converger"; exit 2; }
[[ -r "$TOKEN_FILE" ]] || { err "$TOKEN_FILE illisible — le token systeme est le seul droit de lecture de la team"; exit 2; }

[[ "$(id -u)" -eq 0 ]] || { err "doit tourner en root (c'est lui qui cree les users)"; exit 1; }

api() { # api <path>
  curl -s -m 15 -H "Authorization: token $(tr -d '[:space:]' < "$TOKEN_FILE")" \
       "$FORGE/api/v1$1" 2>/dev/null || true
}

team_id() {
  api "/orgs/$ORG/teams" \
    | jq -r --arg t "$TEAM" 'if type=="array" then (.[] | select(.name==$t) | .id) else empty end' 2>/dev/null \
    | head -n1
}

# L'ETAT PER-HUMAIN, convergé — appelé A LA CREATION *et* a chaque reconciliation.
# La liste des modules se CALCULE : le provisioning DECLARE lesquels sont per-humain
# (`# NEEDS: human`), on lit cette declaration au lieu de la recopier. Une liste en dur redevient
# fausse au prochain module ajoute — c'est arrive deux fois (la console, puis le binaire `claude`).
converge_human() { # converge_human <login>
  local login=$1
  [[ -x "$PROVISION" ]] || return 1
  local -a only=(); local m
  while IFS= read -r m; do only+=(--only "$(basename "$m" .sh)"); done < <(
    grep -l '^# NEEDS: human' "$(dirname "$PROVISION")/modules.d"/*.sh 2>/dev/null | sort)
  # Repli EXPLICITE : si la declaration est illisible, on converge au moins le substrat plutot que
  # de ne rien converger en silence.
  [[ "${#only[@]}" -gt 0 ]] || only=(--only 70-human)
  "$PROVISION" apply --substrate docker --human "$login" "${only[@]}" >/dev/null 2>&1
}

# LES TROIS GESTES DE LA REVOCATION, dans l'ordre qui les rend vrais (cf. l'en-tete). Chacun est
# tolerant a l'echec de l'etape precedente : une revocation partielle vaut mieux qu'une revocation
# abandonnee au milieu, et le tour suivant reprendra ce qui manque.
revoke_human() { # revoke_human <login>
  local login=$1
  gpasswd -d "$login" "$GROUP" >/dev/null 2>&1 || true
  # TERM puis KILL : le serveur tmux, ttyd, le BEAM et les pods vivent sur des sockets tmux
  # DIFFERENTS (`~/.lcars/run/fleet_v2.sock`, `~/.lcars/run/tmux-sock/<pod>/pod.sock`), donc aucun
  # `tmux kill-server` ne les atteint tous. Le seul predicat qui les couvre est l'uid.
  pkill -u "$login" 2>/dev/null || true
  sleep 1
  pkill -KILL -u "$login" 2>/dev/null || true
  usermod -s "$NOLOGIN" -- "$login" 2>/dev/null \
    || err "$login : revoque, mais son shell n'a pas pu passer a $NOLOGIN — sa console peut redemarrer"
  say "REVOQUE $login — retire de $GROUP, process tues, shell $NOLOGIN (compte, home et donnees intacts)"
}

# LE CHEMIN DE RETOUR. Sans lui, re-ajouter quelqu'un a la team ne le ferait PAS revenir : la boucle
# le verrait exister (`id` repond) et passerait son tour, en le laissant hors du groupe avec un shell
# nologin. Une revocation qu'on ne peut pas annuler n'est pas une revocation, c'est une suppression
# deguisee.
restore_human() { # restore_human <login>
  local login=$1
  usermod -aG "$GROUP" -- "$login" 2>/dev/null || true
  usermod -s "$SHELL_" -- "$login" 2>/dev/null || true
  say "REINTEGRE $login — remis dans $GROUP, shell $SHELL_"
  if [[ "${LCARS_CONSOLE:-1}" == "1" && -x "$CONSOLE" ]]; then
    "$CONSOLE" --human "$login" >/dev/null 2>&1 \
      || err "$login : reintegre mais sa console n'a pas redemarre ($CONSOLE --human $login)"
  fi
}

# LE GESTE, sur la decision ci-dessus. Appelee UNIQUEMENT avec une liste de membres prouvee non
# vide — le garde est chez l'appelant, et il y est parce qu'ici on ne saurait pas distinguer « la
# team est vide » de « la forge n'a pas repondu ».
revoke_absent() { # revoke_absent <membres…>
  local login
  while IFS= read -r login; do
    [[ -n "$login" ]] || continue
    revoke_human "$login"
  done < <(absent_humans "$@")
  return 0
}

# LA PASSE LENTE : l'etat des humains DEJA presents. Sans elle, tout ce qui est pose « a la
# creation » n'atteint jamais quelqu'un qui existe deja.
reconcile_humans() { # reconcile_humans <login…>
  local login n=0
  for login in "$@"; do
    id "$login" >/dev/null 2>&1 || continue
    converge_human "$login" || { err "$login : reconciliation per-humain en echec — diagnose : $PROVISION doctor --human $login"; continue; }
    n=$((n + 1))
  done
  [[ "$n" -gt 0 ]] && say "$n humain(s) reconcilie(s) (passe lente, toutes les ${RECONCILE_EVERY}s)"
  return 0
}

converge_once() {
  local tid members login created=0
  tid="$(team_id)"
  if [[ -z "$tid" ]]; then
    err "team $ORG/$TEAM introuvable (ou forge injoignable) — rien converge ce tour"
    return 0
  fi
  members="$(api "/teams/$tid/members" | jq -r 'if type=="array" then .[].login else empty end' 2>/dev/null || true)"
  [[ -n "$members" ]] || return 0

  while IFS= read -r login; do
    [[ -n "$login" ]] || continue
    if id "$login" >/dev/null 2>&1; then
      # « EXISTE » NE DIT PAS « A SES ACCES ». Quelqu'un revoque puis re-ajoute a la team arrive
      # exactement ici : `id` repond, et la boucle passait son tour en le laissant hors du groupe,
      # en nologin, sans console. C'est le seul endroit ou le chemin de retour peut etre pris.
      if [[ "$login" != "$BOOTSTRAP" ]] &&
           { ! in_group "$login" || [[ "$(login_shell_of "$login")" == "$NOLOGIN" ]]; }; then
        restore_human "$login"
      fi
      continue
    fi
    if reserved "$login"; then
      already_refused "$login" || {
        err "REFUS $login — nom reserve (compte systeme ou compte de service de la fleet) ; AUCUN user cree"
        mark_refused "$login" "ce login est reserve sur cette boite (compte systeme, ou compte de service de la fleet)"; }
      continue
    fi
    if ! valid_login "$login"; then
      already_refused "$login" || {
        err "REFUS $login — login inutilisable comme user Linux (1-32 car., alphanumerique en tete et en queue, [A-Za-z0-9._-], pas de '..') ; la personne doit changer de login sur la forge"
        mark_refused "$login" "ce login ne peut pas devenir un compte Unix : il faut 1 a 32 caracteres, commencant ET finissant par une lettre ou un chiffre, sans '..'"; }
      continue
    fi
    # Un home deja la impose SON uid : sinon la personne ne peut pas ecrire chez elle, et pire,
    # elle ecrit chez quelqu'un d'autre.
    local want_uid holder uid_args=()
    want_uid="$(uid_of_home "$login")"
    if [[ -n "$want_uid" ]]; then
      holder="$(uid_taken_by "$want_uid" "$login")"
      if [[ -n "$holder" ]]; then
        # Deux logins revendiquent le meme uid : c'est un croisement deja installe, et le reparer
        # a l'aveugle deplacerait des fichiers d'humain. On refuse, en nommant les deux cotes.
        already_refused "$login" || {
          err "REFUS $login — son home appartient a l'uid $want_uid, deja porte par '$holder' ; AUCUN user cree (croisement a demeler a la main)"
          mark_refused "$login" "le repertoire /home/$login appartient a un identifiant deja pris par un autre compte ($holder) — un humain doit demeler"; }
        continue
      fi
      uid_args=(-u "$want_uid")
    fi
    # `--` ferme la liste d'options : meme si un jour un login commencait par `-`, il arriverait
    # ici comme un NOM et pas comme un drapeau. La validation l'interdit deja ; ceci est la
    # ceinture qui ne coute rien.
    if useradd "${uid_args[@]}" -m -s "$SHELL_" -- "$login" 2>/dev/null; then
      getent group "$GROUP" >/dev/null 2>&1 && usermod -aG "$GROUP" -- "$login" 2>/dev/null || true
      say "user $login cree (membre de $ORG/$TEAM${want_uid:+, uid $want_uid repris de son home})"
      created=$((created + 1))
      # Le substrat per-humain (~/.lcars, ~/pods, fleet_v2.env seede) appartient a 70-human : on ne
      # le recopie pas ici, on l'appelle. Une deuxieme implementation du meme etat-cible derive.
      if [[ -x "$PROVISION" ]]; then
        # TOUS les modules per-humain, et la liste se CALCULE. Elle etait `--only 70-human`, en dur —
        # et c'est ce littéral qui a produit le defaut : `40-claude-bin` (qui pose ~/.local/bin/claude)
        # ne tournait jamais pour un humain converge, donc la personne recevait un home, un substrat,
        # et AUCUN binaire `claude`. Or `claude /login` est le seul geste qui lui reste a faire : sans
        # le binaire, le rail d'enrollment s'arrete a son dernier pas, et le message d'accueil lui
        # demande de lancer une commande qui n'existe pas.
        # Une liste en dur redevient fausse au prochain module per-humain ajoute. Le provisioning
        # DECLARE deja lesquels le sont (`# NEEDS: human`) : on lit cette declaration au lieu de la
        # recopier. Meme discipline que la denylist des noms reserves, qui se calcule depuis
        # /etc/passwd plutot que d'etre inscrite quelque part.
        converge_human "$login" \
          || err "$login : user cree mais le provisioning per-humain a echoue — diagnose : $PROVISION doctor --human $login"
      else
        err "$login : user cree mais $PROVISION introuvable — son ~/.lcars n'est PAS pose"
      fi
      # SA CONSOLE, MAINTENANT — parce que personne d'autre ne la lancera. `console.sh --all` n'est
      # appele QUE par l'entrypoint, au boot. Un humain converge APRES le boot recevait donc un user,
      # un home et un substrat, et le deck lui affichait fierement l'adresse d'une console que rien
      # n'avait demarree : « cette page ne fonctionne pas ». Le convergeur est le seul a savoir qu'un
      # humain vient d'apparaitre ; c'est donc a lui de completer le geste.
      # Meme interrupteur que l'entrypoint : qui coupe les consoles les coupe pour tout le monde.
      if [[ "${LCARS_CONSOLE:-1}" == "1" && -x "$CONSOLE" ]]; then
        "$CONSOLE" --human "$login" >/dev/null 2>&1 \
          || err "$login : user cree mais sa console n'a pas demarre — ssh reste la porte ($CONSOLE --human $login)"
      fi
    else
      err "$login : useradd a echoue — AUCUN user cree (relance au prochain tour)"
    fi
  done <<< "$members"
  [[ "$created" -gt 0 ]] && say "$created humain(s) converge(s)"

  # Un TABLEAU, pas un decoupage par espaces. Un login valide n'en contient pas — mais s'appuyer
  # sur la validation d'un autre bout du script pour se permettre un `$(...)` nu est exactement
  # le genre de dette qui survit a la regle qui la rendait sure.
  local -a roster; mapfile -t roster <<< "$members"

  # LA REVOCATION, a chaque tour. On n'arrive ici qu'avec une liste de membres PROUVEE (team
  # trouvee, reponse non vide) : les deux sorties precedentes de cette fonction sont ce qui empeche
  # un hoquet reseau de revoquer toute la boite.
  revoke_absent "${roster[@]}"

  # LA PASSE LENTE, sur les membres DEJA presents. `id <login>` plus haut dit que l'user EXISTE —
  # pas que son etat est converge, et le commentaire disait « deja converge : rien a dire ».
  # C'etait faux : tout ce qui est pose a la creation n'atteignait jamais un humain deja la.
  local now; now="$(date +%s)"
  if [[ $((now - LAST_RECONCILE)) -ge "$RECONCILE_EVERY" ]]; then
    LAST_RECONCILE="$now"
    reconcile_humans "${roster[@]}"
  fi
  return 0
}

if [[ "$ONCE" -eq 1 ]]; then
  converge_once
  exit 0
fi

say "convergence des humains : $FORGE org=$ORG team=$TEAM toutes les ${INTERVAL}s"

# `set -e` EST UN CONTRAT DE DEMARRAGE, PAS UN CONTRAT DE BOUCLE — et les confondre a fait mourir
# celle-ci. Mesure du 2026-08-12 : un signal TRAPPE delivre au groupe de process tue le `sleep`
# enfant sans tuer bash ; `sleep` rend alors non-zero, `errexit` s'applique, et la boucle eternelle
# s'arrete au premier tour. Corps du delit : un journal qui s'arrete a « tour 1 » et plus jamais un
# humain converge — sans une erreur, sans une trace.
# Un preflight DOIT mourir au premier imprevu : c'est ce que `set -euo pipefail` achete plus haut, et
# il le garde. Une boucle eternelle a le contrat INVERSE — ne jamais mourir — donc `errexit` est
# retire ICI et seulement ici. Ce n'est pas un relachement : chaque echec qui compte est deja
# explicitement gere (`converge_once || true`, et `err` pour ce qui merite d'etre dit).
set +e
while true; do
  converge_once
  sleep "$INTERVAL"
done
