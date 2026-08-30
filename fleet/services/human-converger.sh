#!/usr/bin/env bash
# SOURCE: fleet/services/human-converger.sh
# AUTHOR: DrDree
# STARDATE: (posee par /push-github)
# STATUS: PROTO-V2 — boucle root : la team `humans` de la forge -> les users Linux de la boite
# Un serveur tmux distribue son jeu de groupes a TOUS les shells qu'il fork ensuite, et il ne meurt
# jamais tout seul : il survit a ttyd, au navigateur ferme, a tout sauf un kill. Retirer du groupe
# sans tuer, c'est fermer la porte d'entree en laissant la maison allumee a l'interieur.
#
# D'ou les trois gestes, dans CET ordre :
#   1. `gpasswd -d` — le groupe redevient exact ;
#   2. `pkill -u`   — les process de la personne meurent. Il n'existe pas de version douce :
#      revoquer INTERROMPT. C'est le prix, il est assume, il n'est pas contournable ;
#   3. `usermod -s nologin` — la porte ne se rouvre pas. Sans ce troisieme geste, le prochain
#      `console.sh --all` relance la console : elle ne lit que /etc/passwd, et `console-humans.sh`
#      (source UNIQUE de l'eligibilite, lue aussi par la landing) ecarte deja `shell nologin`.
# `usermod` APRES le kill : il refuse de toucher un compte dont des process tournent encore.
# RIEN N'EST SUPPRIME : ni compte, ni home, ni donnees, ni uid. La revocation ferme des acces, elle
# n'efface pas une personne — et re-entrer dans la team RESTAURE l'entree (cf. `restore_human`),
# sans quoi la revocation serait un piege a sens unique.
#
# LE GARDE QUI COMPTE : on ne revoque JAMAIS sur une liste non prouvee. Forge injoignable, team
# introuvable ou liste vide -> `converge_once` sort AVANT la passe de revocation. Un hoquet reseau
# lu comme « plus personne dans la team » revoquerait toute la boite d'un coup.
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
# `system_starfleet` a cote de l'humain. Le compte systeme et les comptes de role sont donc exclus
# nommement, depuis la meme source que le provisioning.
#
# USAGE : human-converger.sh [--once]      (--once : une passe, pour sonder ou tester)
# EXIT  : 0 · 1 dependance absente · 2 configuration absente (fail-closed, jamais une boucle muette)

set -euo pipefail

ONCE=0
[[ "${1:-}" == "--once" ]] && ONCE=1

FORGE="${FORGE_BASE_URL:-}"
# Le defaut litteral, lui, reste ecrit deux fois — ce script ne source pas `provision-lib.sh` (il
# tourne en boucle, pas dans un cycle de provisionnement). C'est l'egalite de ces deux litteraux
# qu'un temoin bats epingle, faute de pouvoir la deriver.
ORG="${PROV_FORGE_ORG:-fleet}"
TEAM="${PROV_HUMANS_TEAM:-humans}"
SYSTEM_ACCOUNT="${LCARS_SYSTEM_ACCOUNT:-system_starfleet}"
TOKEN_FILE="${FORGE_TOKEN_FILE:-/opt/lcars/var/tokens/$SYSTEM_ACCOUNT.gitea_token}"
ROLES="${LCARS_ROLES:-system_architect system_chief system_gatekeeper fleet_engineer fleet_scribe fleet_qualifier fleet_reviewer fleet_scoper fleet_vulcan}"
INTERVAL="${LCARS_CONVERGER_INTERVAL:-30}"
RECONCILE_EVERY="${LCARS_CONVERGER_RECONCILE:-3600}"
PROVISION="${LCARS_PROVISION:-/opt/lcars/fleet/deploy/provision}"
CONSOLE="${LCARS_CONSOLE_SH:-/opt/lcars/console.sh}"
SHELL_="${LCARS_HUMAN_SHELL:-/bin/bash}"
# Le shell d'un revoque. `console-humans.sh` ecarte `*/nologin` et `*/false` : poser celui-la ferme
# la console a la source, pour ses deux consommateurs a la fois.
NOLOGIN="${LCARS_NOLOGIN_SHELL:-/usr/sbin/nologin}"
GROUP="${PROV_FLEET_GROUP:-fleet}"
HOME_ROOT="${LCARS_HOME_ROOT:-/home}"
# GUARD A — L'UID DU SIEGE N'EST JAMAIS CONVERGE NI REVOQUE. Garde keye sur l'UID, PAS sur un login :
# le login du siege est celui de l'installeur, donc variable, et keyer sur l'uid survit a un rename.
# Le revoquer poserait `nologin` sur le sysadmin et fermerait la machine sur lui — l'enfermement
# dehors.
SEAT_UID_FILE="${LCARS_SEAT_UID_FILE:-/etc/lcars/seat.uid}"
SYSADMIN_UID="$(head -n1 -- "$SEAT_UID_FILE" 2>/dev/null | tr -d '[:space:]' || true)"
[[ "$SYSADMIN_UID" =~ ^[0-9]+$ ]] || SYSADMIN_UID="${LCARS_SYSADMIN_UID:-}"
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
# publish-transform.sh).

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
  [[ "$login" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]] || return 1
  [[ "$login" != *".."* ]] || return 1
  return 0
}

# Le home PORTE deja l'uid d'origine : c'est son proprietaire. On le relit au lieu de laisser l'OS
# redistribuer. Le chemin fait foi — `/home/<login>` est le home de <login>, quel que soit le nom
# auquel son uid numerique resout aujourd'hui.
uid_of_home() { # uid_of_home <login> -> uid proprietaire du home existant, ou vide
  local h="$HOME_ROOT/$1"
  [[ -d "$h" ]] || return 0
  stat -c %u "$h" 2>/dev/null || true
}

UID_MAP_FILE="${LCARS_UID_MAP_FILE:-/opt/lcars/var/tokens/forge-uid.map}"

uid_from_map() { # uid_from_map <forge_id> -> l'uid enregistre pour cet id, ou vide
  [[ -r "$UID_MAP_FILE" ]] || return 0
  awk -F'\t' -v id="$1" '$1 == id { print $2; exit }' "$UID_MAP_FILE" 2>/dev/null
}

# ENREGISTRE APRES LE `useradd`, JAMAIS AVANT : on note l'uid QUE LE SYSTEME A DONNE, pas celui
# qu'on esperait. Ecrire d'avance reconstruirait une formule, avec une etape de plus.
# Rejouable : un id deja present n'est pas re-ecrit (le premier enregistrement fait foi — c'est lui
# qui correspond au home sur le disque).
uid_map_record() { # uid_map_record <forge_id> <uid> <login>
  [[ "$1" =~ ^[0-9]+$ && "$2" =~ ^[0-9]+$ ]] || return 0
  [[ -n "$(uid_from_map "$1")" ]] && return 0
  local dir; dir="$(dirname "$UID_MAP_FILE")"
  mkdir -p "$dir" 2>/dev/null || true
  if printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$UID_MAP_FILE" 2>/dev/null; then
    chmod 0640 "$UID_MAP_FILE" 2>/dev/null || true
    chown "root:$GROUP" "$UID_MAP_FILE" 2>/dev/null || true
  else
    # Le compte EXISTE deja a ce stade : ne pas pouvoir noter son uid ne le defait pas, mais la
    # prochaine reconstruction ne le retrouvera que par son home. On le DIT.
    err "$3 : uid $2 NON enregistre dans $UID_MAP_FILE — une reconstruction ne le retrouvera que par son home"
  fi
}

# L'uid a demander pour <login>, et la REGLE DE PRIORITE tient en une phrase : un home existant
# gagne toujours.
# Le cas est etroit — sur une boite le siege existe deja quand ce service demarre, donc `useradd`
# passerait a l'uid suivant — mais `LCARS_SYSADMIN_UID` est REGLABLE : un siege a 1005 sur une
# machine ou 1005 est libre rentre exactement dans ce chemin.
# ⚠ LES DEUX BORNES SE VALIDENT, ET LA PREMIERE VERSION N'EN VALIDAIT QU'UNE. `m` passait par un
# `=~ ^[0-9]+$`, `s` non — asymetrie dans six lignes ecrites d'un coup. Ce que ca produit :
#
#   LCARS_SYSADMIN_UID="10 00"  (un espace au clavier)  →  `(( m > s ))` : syntax error
#   LCARS_SYSADMIN_UID="abc"                            →  `s` lu comme un NOM de variable en
#                                                          contexte arithmetique → unbound variable
#
# `:-` ne protege que du VIDE, pas du non-numerique. Sous le `set -e` du demarrage ca tue le service
# — bruyant, donc acceptable. Sous le `set +e` de la BOUCLE, `uid_wanted` rend vide, `uid_args`
# reste vide, `useradd` repart de `UID_MIN` : le plancher que ce fichier existe pour poser est
# contourne EN SILENCE. La garde ci-dessous est donc le plancher du plancher.
# ⚠ LE SIEGE EST UN TROU DANS LA PLAGE, PAS UN PLANCHER. Les deux gardes sont ORTHOGONAUX :
# « uid >= UID_MIN » est la frontiere systeme/humain, « uid != siege » est la reservation du siege.
# Partir de `siege + 1` les cumule, et declare inutilisables tous les uid entre UID_MIN et le siege —
# avec un siege a 1237, c'est 1000..1236 perdus alors que les deux gardes les acceptent. Le plancher
# est UID_MIN, et rien d'autre ; le siege s'evite en le sautant (`first_free_uid`).
uid_floor() {
  local m
  m="$(uid_min)"
  [[ "$m" =~ ^[0-9]+$ ]] || m=1000
  echo "$m"
}

# ⚠ `getent`, PAS `PASSWD_FILE` — ET C'EST LE SEUL ENDROIT DU FICHIER QUI DIVERGE. Le reste du
# module lit `${PASSWD_FILE:-/etc/passwd}` pour rester mesurable ; ici la question n'est pas « qui
# est ecrit dans ce fichier » mais « cet uid est-il pris SUR CETTE MACHINE », et NSS (LDAP, sssd)
# repond ce que le fichier ignore. `getent` est un sur-ensemble : un uid qu'il declare libre l'est
# aussi pour `PASSWD_FILE`, donc `uid_taken_by` ne peut pas contredire ce choix a tort.
first_free_uid() {
  local uid seat; uid="$(uid_floor)"; seat="$SYSADMIN_UID"
  while getent passwd "$uid" >/dev/null 2>&1 || [[ "$uid" == "$seat" ]]; do uid=$(( uid + 1 )); done
  echo "$uid"
}

uid_wanted() { # uid_wanted <login> <forge_id> -> uid a poser, ou vide
  local from_home
  from_home="$(uid_of_home "$1")"
  if [[ -n "$from_home" ]]; then
    printf '%s\n' "$from_home"
    return 0
  fi
  if [[ "$2" =~ ^[0-9]+$ ]]; then
    local from_map; from_map="$(uid_from_map "$2")"
    [[ -n "$from_map" ]] && { printf '%s\n' "$from_map"; return 0; }
  fi
  first_free_uid
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
# 0644 delibere : le deck tourne sous son propre compte de service, pas sous root. Le fichier ne porte qu'un login public et une raison,
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

uid_of() { awk -F: -v n="$1" '$1==n {print $3; exit}' "${PASSWD_FILE:-/etc/passwd}"; }

login_shell_of() { # login_shell_of <login>
  awk -F: -v n="$1" '$1==n {print $7}' "${PASSWD_FILE:-/etc/passwd}"
}

# Les humains que CETTE boite a converges : membres du groupe fleet, uid >= UID_MIN. C'est la seule
# trace qu'un enrollment a eu lieu, et elle se CALCULE — aucune liste tenue a la main ne resterait
# vraie. L'humain de bootstrap en est ecarte : il n'est pas venu de la team.
converged_humans() {
  local min login; min="$(uid_min)"; min="${min:-1000}"
  while IFS= read -r login; do
    [[ -n "$login" ]] || continue
    # GUARD A : `$3 != s` exclut l'uid reserve du sysadmin (admiral) — jamais candidat a revocation,
    # meme s'il se retrouvait dans le groupe fleet local.
    awk -F: -v n="$login" -v m="$min" -v s="$SYSADMIN_UID" \
      '$1==n && $3>=m && $3!=s {print n}' "${PASSWD_FILE:-/etc/passwd}"
  done < <(group_members)
}

# LA DECISION, SEPAREE DU GESTE. Qui n'est plus dans la team ? C'est la seule partie qui, en se
# trompant, coupe quelqu'un — donc elle est pure, elle n'ecrit rien, et elle est epinglee par les
# tests comme `reserved` et `valid_login`.
#
# SANS ARGUMENT, ELLE NE DESIGNE PERSONNE. L'appelant garde deja contre une liste non prouvee ; ce
# second verrou est ici parce que les deux fautes qui menent au meme desastre — une team vide et une
# forge muette — se ressemblent trop pour ne compter que sur un seul garde.
# LA CHARGE DE LA FORGE PORTE DEUX CHAMPS, LES DEUX CONSOMMATEURS EN VEULENT UN SEUL. `/teams/<id>/
# members` est lu une fois en `id<TAB>login` — l'id sert a poser l'UID a la creation, et lui seul.
# Cette fonction existe pour que la conversion soit EPINGLABLE. Recopier `cut -f2` dans un test
# aurait valide une copie : ce qui doit rester vrai, c'est ce que l'appelant reel calcule.
roster_of() { # roster_of <charge id<TAB>login, une par ligne> -> les logins, un par ligne
  cut -f2
}

absent_humans() { # absent_humans <membres…> -> les logins a revoquer, un par ligne
  [[ "$#" -gt 0 ]] || return 0
  local login
  while IFS= read -r login; do
    printf '%s\n' "$@" | grep -qxF -- "$login" && continue
    printf '%s\n' "$login"
  done < <(converged_humans)
  return 0
}

ensure_console() { # ensure_console <login>
  [[ "${LCARS_CONSOLE:-1}" == "1" && -x "$CONSOLE" ]] || return 0
  "$CONSOLE" --human "$1" >/dev/null 2>&1 \
    || err "$1 : sa console n'a pas demarre — ssh reste la porte ($CONSOLE --human $1)"
  return 0
}

# Sourcer ce fichier donne l'ADMISSION, la SELECTION des revoques et la LECTURE de l'adminite
# ci-dessus, et RIEN d'autre : ni preflight, ni boucle, et surtout aucun geste. Ce sont les trois
# decisions qui, en se trompant, creent un compte que personne ne voulait, coupent quelqu'un qui
# travaille, ou accordent l'administration du runtime a qui ne l'a pas — elles sont donc lisibles et
# testables sans lancer la boucle.
# Ce qui doit etre epingle vit AVANT cette ligne ; ce qui AGIT vit apres.
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
# Le siege decide GUARD A (qui n'est jamais converge) et le trou de la plage d'uid. Ce process tourne
# en root et fait `useradd` : sans siege etabli, il creerait un compte sur l'uid de l'admin.
[[ "$SYSADMIN_UID" =~ ^[0-9]+$ ]] || { err "siege non etabli ($SEAT_UID_FILE absent ou illisible, LCARS_SYSADMIN_UID non pose) — aucun compte ne se cree sur un plancher devine"; exit 2; }

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
  # `provision` resout `--substrate auto` par `detect_substrate` (/.dockerenv, /proc/version), donc
  # il repond deja juste DANS le conteneur : le litteral n'achetait rien et coutait le rail poste.
  # ⚠ LES CODES DE `apply` NE SONT PAS CEUX DE `check`, ET LE 2 EST UN SUCCES ICI :
  #   0 convergé · 1 ÉCHEC · 2 APPLIQUÉ, drift résiduel.
  local rc=0 out
  out="$(mktemp "${TMPDIR:-/tmp}/lcars-converge.XXXXXX")" || out=""
  if [[ -n "$out" ]]; then
    "$PROVISION" apply --human "$login" "${only[@]}" >"$out" 2>&1 || rc=$?
    if [[ "$rc" -ne 0 && "$rc" -ne 2 ]]; then
      err "$login : provisioning per-humain rc=$rc — les 15 dernieres lignes :"
      tail -n 15 "$out" | while IFS= read -r l; do err "  | $l"; done
    fi
    rm -f "$out"
  else
    "$PROVISION" apply --human "$login" "${only[@]}" >/dev/null 2>&1 || rc=$?
  fi
  [[ "$rc" -eq 0 || "$rc" -eq 2 ]]
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
  ensure_console "$login"
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
  members="$(api "/teams/$tid/members" \
    | jq -r 'if type=="array" then .[] | "\(.id)\t\(.login)" else empty end' 2>/dev/null || true)"
  [[ -n "$members" ]] || return 0

  while IFS=$'\t' read -r forge_id login; do
    [[ -n "$login" ]] || continue
    if id "$login" >/dev/null 2>&1; then
      # GUARD A : jamais restaurer (ni toucher) l'uid reserve du sysadmin (admiral).
      if [[ "$(uid_of "$login")" != "$SYSADMIN_UID" ]] &&
           { ! in_group "$login" || [[ "$(login_shell_of "$login")" == "$NOLOGIN" ]]; }; then
        restore_human "$login"
      fi
      ensure_console "$login"
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
    local want_uid holder uid_args=() uid_src=""
    # ⚠ LA SOURCE SE CAPTURE ICI, PAS APRES : `useradd -m` cree le home, donc tester son existence
    # plus bas repondrait « il a un home » pour TOUT LE MONDE. Premiere version de cette trace, et
    # elle aurait dit « repris de son home » sur un uid pose par la forge — un mensonge qui n'aurait
    # coute que le jour ou un uid surprend quelqu'un.
    # TROIS SOURCES, TROIS PHRASES. La derniere est le cas NOMINAL sur une machine neuve.
    if [[ -d "$HOME_ROOT/$login" ]]; then
      uid_src="repris de son home"
    elif [[ -n "$(uid_from_map "$forge_id")" ]]; then
      uid_src="relu dans la table (id de forge $forge_id)"
    else
      uid_src="premier libre au-dessus du siege"
    fi
    want_uid="$(uid_wanted "$login" "$forge_id")"
    if [[ -n "$want_uid" ]]; then
      holder="$(uid_taken_by "$want_uid" "$login")"
      if [[ -n "$holder" ]]; then
        # Deux logins revendiquent le meme uid : c'est un croisement deja installe, et le reparer
        # a l'aveugle deplacerait des fichiers d'humain. On refuse, en nommant les deux cotes.
        already_refused "$login" || {
          err "REFUS $login — uid $want_uid ($uid_src), deja porte par '$holder' ; AUCUN user cree (croisement a demeler a la main)"
          mark_refused "$login" "l'uid $want_uid ($uid_src) est deja porte par un autre compte ($holder) — un humain doit demeler"; }
        continue
      fi
      uid_args=(-u "$want_uid")
    fi
    # `--` ferme la liste d'options : meme si un jour un login commencait par `-`, il arriverait
    # ici comme un NOM et pas comme un drapeau. La validation l'interdit deja ; ceci est la
    # ceinture qui ne coute rien.
    if useradd "${uid_args[@]}" -m -s "$SHELL_" -- "$login" 2>/dev/null; then
      if getent group "$GROUP" >/dev/null 2>&1; then
        usermod -aG "$GROUP" -- "$login" 2>/dev/null \
          || say "ATTENTION: « $login » n'a PAS ete ajoute au groupe $GROUP — il ne lira pas ce que ce groupe ouvre"
      fi
      # L'UID EFFECTIF SE RELIT, IL NE SE SUPPOSE PAS.
      local got_uid; got_uid="$(id -u -- "$login" 2>/dev/null || true)"
      uid_map_record "$forge_id" "$got_uid" "$login"
      # La TRACE DIT D'OU VIENT L'UID : « repris de son home », « relu dans la table » et « premier
      # libre au-dessus du siege » sont trois histoires differentes le jour ou un uid surprend.
      say "user $login cree (membre de $ORG/$TEAM${got_uid:+, uid $got_uid $uid_src})"
      created=$((created + 1))
      # Le substrat per-humain (~/.lcars, ~/pods, fleet_v2.env seede) appartient a 70-human : on ne
      # le recopie pas ici, on l'appelle. Une deuxieme implementation du meme etat-cible derive.
      if [[ -x "$PROVISION" ]]; then
        converge_human "$login" \
          || err "$login : user cree mais le provisioning per-humain a echoue — diagnose : $PROVISION doctor --human $login"
      else
        err "$login : user cree mais $PROVISION introuvable — son ~/.lcars n'est PAS pose"
      fi
      # Meme interrupteur que l'entrypoint : qui coupe les consoles les coupe pour tout le monde.
      ensure_console "$login"
    else
      err "$login : useradd a echoue — AUCUN user cree (relance au prochain tour)"
    fi
  done <<< "$members"
  [[ "$created" -gt 0 ]] && say "$created humain(s) converge(s)"

  # Un TABLEAU, pas un decoupage par espaces. Un login valide n'en contient pas — mais s'appuyer
  # sur la validation d'un autre bout du script pour se permettre un `$(...)` nu est exactement
  # le genre de dette qui survit a la regle qui la rendait sure.
  #
  # LES LOGINS SEULS — le pourquoi est sur `roster_of`, qui est aussi ce que les tests epinglent.
  local -a roster; mapfile -t roster < <(roster_of <<< "$members")

  revoke_absent "${roster[@]}"

  local now; now="$(date +%s)"
  if [[ $((now - LAST_RECONCILE)) -ge "$RECONCILE_EVERY" ]]; then
    LAST_RECONCILE="$now"
    reconcile_humans "${roster[@]}"
  fi

  ensure_all_consoles
  return 0
}

ensure_all_consoles() {
  [[ "${LCARS_CONSOLE:-1}" == "1" && -x "$CONSOLE" ]] || return 0
  "$CONSOLE" --all >/dev/null 2>&1 \
    || err "certaines consoles n'ont pas demarre — ssh reste la porte ($CONSOLE --all)"
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
