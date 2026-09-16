#!/usr/bin/env bash
# SOURCE: runtime/services/human-converger.sh
# AUTHOR: DrDree
# STARDATE: (posee par /push-github)
# STATUS: PROTO-V2 — boucle root : la team `humans` de la forge -> les users Linux du conteneur
#
# ⚠ POURQUOI LA REVOCATION TUE, ET NE PEUT PAS FAIRE AUTREMENT : un serveur tmux distribue son jeu
# de groupes a TOUS les shells qu'il fork ensuite, et il survit a ttyd comme au navigateur ferme —
# a tout sauf un kill. Retirer du groupe sans tuer ferme la porte d'entree en laissant la maison
# allumee dedans. D'ou l'ordre `gpasswd -d`, `pkill -u`, `usermod -s nologin`, et il n'existe pas
# de version douce : revoquer INTERROMPT.
#
# ⚠ `usermod` APRES le kill : il refuse de toucher un compte dont des process tournent encore.
#
# RIEN N'EST SUPPRIME : ni compte, ni home, ni donnees, ni uid. Re-entrer dans la team restaure
# l'entree, sans quoi la revocation serait un piege a sens unique.

set -euo pipefail

ONCE=0
[[ "${1:-}" == "--once" ]] && ONCE=1

FORGE="${FORGE_BASE_URL:-}"
# Litteraux DUPLIQUES de `provision-lib.sh`, que ce script ne source pas : il tourne en boucle, hors
# d'un cycle de provisionnement. C'est un temoin qui epingle leur egalite, faute de pouvoir la deriver.
ORG="${LCARS_FORGE_ORG:-lcars}"
TEAM="${LCARS_HUMANS_TEAM:-humans}"
SYSTEM_ACCOUNT="${LCARS_SYSTEM_ACCOUNT:-system_starfleet}"
TOKEN_FILE="${FORGE_TOKEN_FILE:-/opt/lcars/var/tokens/$SYSTEM_ACCOUNT.gitea_token}"
ROLES="${LCARS_ROLES:-system_architect system_chief system_gatekeeper fleet_engineer fleet_scribe fleet_qualifier fleet_reviewer fleet_scoper fleet_vulcan}"
INTERVAL="${LCARS_CONVERGER_INTERVAL:-30}"
RECONCILE_EVERY="${LCARS_CONVERGER_RECONCILE:-3600}"
CONSOLE="${LCARS_CONSOLE_SH:-/opt/lcars/console.sh}"
SHELL_="${LCARS_HUMAN_SHELL:-/bin/bash}"
# Le shell d'un revoque. `console-humans.sh` ecarte `*/nologin` et `*/false` : poser celui-la ferme
# la console a la source, pour ses deux consommateurs a la fois.
NOLOGIN="${LCARS_NOLOGIN_SHELL:-/usr/sbin/nologin}"
GROUP="${LCARS_FLEET_GROUP:-fleet}"
HOME_ROOT="${LCARS_HOME_ROOT:-/home}"
# GUARD A — L'UID DU SIEGE N'EST JAMAIS CONVERGE NI REVOQUE. Garde keye sur l'UID, PAS sur un login :
# le login du siege est celui de l'installeur, donc variable, et keyer sur l'uid survit a un rename.
# Le revoquer poserait `nologin` sur le sysadmin et fermerait la machine sur lui — l'enfermement
# dehors.
SEAT_UID_FILE="${LCARS_SEAT_UID_FILE:-/etc/lcars/seat.uid}"
# L'uid se lit par `seat_uid` du protocole, source plus bas : ce daemon n'en tient pas une copie.
SYSADMIN_UID=""
# Un refus se dit UNE FOIS. Sans cette trace, un login invalide reproche la meme chose toutes les
# 30 s et noie le journal, ce qui revient a ne rien dire du tout.
REFUSED_FILE="${LCARS_CONVERGER_REFUSED:-/run/lcars-converger.refused}"
# 0 = la PREMIERE passe reconcilie tout le monde. C'est deliberé : la reconciliation au demarrage
# est la fonctionnalite (meme choix que le poller), pas une rafale a raboter.
LAST_RECONCILE=0

say() { echo "[lcars-converger] $*"; }
err() { echo "[lcars-converger] $*" >&2; }

# ─── LA FRONTIERE SYSTEME/HUMAIN EST CELLE DU PROTOCOLE, ET CE DAEMON L'EMPRUNTE ────────────────
# Ce fichier portait sa propre copie de la regle (`uid_min`, trois replis sur 1000), a contre-sens
# du BEAM qui refuse de booter sur un login.defs illisible (runtime.exs, R-no-uid-min) et de
# `console-humans.sh` qui ne rend aucune liste. La regle vit dans `lib/human-protocol.sh`
# (`uid_bounds` : UID_MIN et UID_MAX, ou rien et le remede dit une fois) ; `reserved`, `uid_floor`
# et `converged_humans` l'appellent, ils ne la recopient plus. Bornes illisibles = ce daemon ne
# converge PERSONNE (cf. `converge_once`) et le dit une fois par tour.
#
# Le chemin est celui de boot.sh (`LCARS_HUMAN_PROTOCOL`) : sur une machine posee, le protocole est
# sous `/opt/lcars/services/lib/` et ce script a `/opt/lcars/` (l'image et 62-runtime-helpers
# posent le meme layout) ; dans un checkout, c'est le voisin `lib/` de ce fichier. Les modules
# per-humain le chargent EUX-MEMES par la variable que ce service leur donne (`converge_human`).
#
# Le protocole exige un sujet (`LCARS_LOGIN`) pour un MODULE, qui agit sur une personne. Ce daemon
# est l'HOTE : il n'en a pas, il en nomme un a chaque appel. Il le declare — et ne l'EXPORTE pas :
# les modules qu'il lance gardent leur garde. Il est source ICI, avant le garde de sourcing, pour
# que les predicats d'admission restent testables sans lancer ni preflight ni boucle.
HUMAN_PROTOCOL="${LCARS_HUMAN_PROTOCOL:-/opt/lcars/services/lib/human-protocol.sh}"
[[ -r "$HUMAN_PROTOCOL" ]] || HUMAN_PROTOCOL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/human-protocol.sh"
LCARS_HUMAN_PROTOCOL_HOST=1
LCARS_MODULE_TAG="lcars-converger"
# shellcheck source=lib/human-protocol.sh
. "$HUMAN_PROTOCOL"
unset LCARS_HUMAN_PROTOCOL_HOST
# GUARD A lit le siege par la politique du protocole (fichier, puis LCARS_SYSADMIN_UID).
SYSADMIN_UID="$(seat_uid)"

# ─── L'ADMISSION ────────────────────────────────────────────────────────────────────────────────
# Ces trois predicats decident si un login de la forge devient un user Linux. C'est la seule partie
# qui, en se trompant, cree un compte que personne ne voulait — donc elle est definie AVANT le
# garde de sourcing, pour etre testable sans lancer ni preflight ni boucle (meme idiome que
# publish-transform.sh).

# Les noms qu'on ne creera JAMAIS : tout ce qui est deja pris HORS de la plage des humains, plus
# les comptes de service de la fleet (qui vivent dans l'org, et dont l'un est membre de la team).
reserved() { # reserved <login> -> 0 si le nom est interdit
  local login=$1 lo
  lo="${login,,}"
  [[ "$lo" == "${SYSTEM_ACCOUNT,,}" ]] && return 0
  local r
  for r in $ROLES; do [[ "$lo" == "${r,,}" ]] && return 0; done
  # Un nom deja porte par un compte HORS de la plage des humains — sous UID_MIN (`sshd`), au-dessus
  # de UID_MAX (`nobody`) — est un compte systeme : le convergeur ne l'adopte pas, il refuse.
  # Adopter reviendrait a donner un home et un shell fleet a `sshd`. Bornes illisibles : TOUT nom
  # est reserve — on ne cree personne sur une frontiere devinee.
  uid_bounds || return 0
  awk -F: -v n="$login" -v m="$UID_MIN" -v M="$UID_MAX" \
      '$1==n && ($3+0<m || $3+0>M) {found=1} END {exit !found}' "${PASSWD_FILE:-/etc/passwd}" && return 0
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

# Le plancher de creation : UID_MIN du protocole, et rien d'autre (le siege est un TROU dans la
# plage, pas un plancher). Bornes illisibles : RIEN, et 1 — jamais un defaut. Sous le `set +e` de
# la boucle, un defaut ferait repartir `useradd` de son propre plancher, contournant EN SILENCE
# celui que ce fichier existe pour poser ; l'appelant refuse (`first_free_uid`, puis `converge_once`).
uid_floor() {
  uid_bounds || return 1
  echo "$UID_MIN"
}

# ⚠ `getent`, PAS `PASSWD_FILE` — SEUL ENDROIT DU FICHIER QUI DIVERGE. La question n'est pas « qui
# est ecrit dans ce fichier » mais « cet uid est-il pris SUR CETTE MACHINE », et NSS (LDAP, sssd)
# repond ce que le fichier ignore. C'est un sur-ensemble : un uid libre pour lui l'est aussi pour
# `PASSWD_FILE`, donc `uid_taken_by` ne peut pas contredire ce choix a tort.
first_free_uid() {
  local uid seat; uid="$(uid_floor)" || return 1; seat="$SYSADMIN_UID"
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

# LE REFUS EST PUBLIE, PAS SEULEMENT JOURNALISE : une personne dont le login est inutilisable EST
# membre de la team, et le deck lui repondrait « ca converge tout seul » pour une convergence qui
# n'arrivera JAMAIS. Le convergeur est le seul a savoir pourquoi, il l'ecrit ou le deck peut le lire.
# 0644 delibere : le deck tourne sous son propre compte, et le fichier ne porte aucun secret.
mark_refused() { # mark_refused <login> <raison lisible>
  mkdir -p "$(dirname "$REFUSED_FILE")"
  printf '%s\t%s\n' "$1" "$2" >> "$REFUSED_FILE"
  chmod 0644 "$REFUSED_FILE" 2>/dev/null || true
}

# Meme idiome de sonde que `PASSWD_FILE` plus haut : un fichier injectable pour les tests, la base
# reelle sinon. Sans ca, la selection des revoques ne serait epinglee par rien — et c'est la partie
# qui, en se trompant, ferme la porte a quelqu'un qui travaille.
members_of() { # members_of <groupe> -> un login par ligne
  if [[ -n "${GROUP_FILE:-}" ]]; then
    awk -F: -v g="$1" '$1==g {print $4}' "$GROUP_FILE"
  else
    getent group "$1" 2>/dev/null | cut -d: -f4
  fi | tr ',' '\n' | grep -v '^$' || true
}

group_members() { members_of "$GROUP"; } # group_members -> les membres du groupe fleet, un par ligne

# ─── UN COMPTE D'ADMINISTRATION DE LA MACHINE NE SE REVOQUE PAS ────────────────────────────────
# L'adminite de la MACHINE, pas celle de la forge : ce convergeur ne lit rien de la seconde.
#
# La revocation vise tout membre de fleet, dans la plage des humains, absent de la team. GUARD A
# n'en retire que le siege DECLARE AUJOURD'HUI. Restent atteignables : le siege d'hier (un autre
# sudoer a rejoue l'installation, `seat.uid` a change), le compte qui a lance une installation, un
# sudoer mis dans fleet a la main. Sur eux, `nologin` et le kill fermeraient la machine sur son
# administrateur. Le convergeur refuse, le dit une fois par processus, et nomme le geste manuel.
#
# UNE QUESTION, UNE SEULE : ce compte peut-il ouvrir un shell root ? Root la pose a sudo sous la
# forme `sudo -n -l -U <login> /bin/sh`, et c'est le CODE qui porte le verdict (0 : permis). Elle
# couvre `%sudo`, `%admin`, `%wheel` et toute regle au nom du compte. Ni le nom d'un groupe (`wheel`
# ne donne rien sur Debian ni Ubuntu), ni `sudo -l -U <login>` sans commande, qui repond « may run »
# pour toute regle, meme etroite (`systemctl restart …`) ou vers un autre compte que root : une
# delegation etroite n'administre pas la machine, et ce compte se revoque comme les autres.
# Sans sudo sur la machine, aucun compte de la plage des humains n'ouvre de shell root par lui.
SUDO_BIN="${LCARS_SUDO_BIN:-sudo}"
declare -A MACHINE_ADMINS_SPARED=()

machine_admin_why() { # machine_admin_why <login> -> la raison s'il administre la machine, rien sinon
  command -v "$SUDO_BIN" >/dev/null 2>&1 || return 0
  if LC_ALL=C "$SUDO_BIN" -n -l -U "$1" /bin/sh >/dev/null 2>&1; then
    printf 'sudo lui ouvre un shell root\n'
  fi
  return 0
}

spare_machine_admin() { # spare_machine_admin <login> <raison> — le refus, dit une fois par processus
  [[ -z "${MACHINE_ADMINS_SPARED[$1]:-}" ]] || return 0
  MACHINE_ADMINS_SPARED[$1]=1
  err "REFUS de révoquer $1 — compte d'administration de la machine ($2) : absent de $ORG/$TEAM, il garde son groupe $GROUP, son shell et ses processus. Le retirer de $GROUP est un geste d'administrateur : « sudo gpasswd -d $1 $GROUP » (sur un poste ; dans un conteneur, depuis « deploy/container shell »)"
}

# `<<<` et non un tuyau : `grep -q` sort au premier match et fermerait le tuyau sur un producteur
# qui ecrit encore — sous `pipefail`, 141, c'est-a-dire « pas membre » sur un membre.
in_group() { grep -qxF -- "$1" <<<"$(group_members)"; }

uid_of() { awk -F: -v n="$1" '$1==n {print $3; exit}' "${PASSWD_FILE:-/etc/passwd}"; }

login_shell_of() { # login_shell_of <login>
  awk -F: -v n="$1" '$1==n {print $7}' "${PASSWD_FILE:-/etc/passwd}"
}

# Les humains que CE conteneur a converges : membres du groupe fleet, uid dans la plage des humains
# (UID_MIN <= uid <= UID_MAX). C'est la seule trace qu'un enrollment a eu lieu, et elle se CALCULE
# — aucune liste tenue a la main ne resterait vraie. L'humain de bootstrap en est ecarte : il
# n'est pas venu de la team. Bornes illisibles : PERSONNE n'est designe — une liste vide n'est
# pas une purge, et une liste devinee en serait une.
converged_humans() {
  local login
  uid_bounds || return 0
  while IFS= read -r login; do
    [[ -n "$login" ]] || continue
    # GUARD A : `$3 != s` exclut l'uid reserve du sysadmin (admiral) — jamais candidat a revocation,
    # meme s'il se retrouvait dans le groupe fleet local.
    awk -F: -v n="$login" -v m="$UID_MIN" -v M="$UID_MAX" -v s="$SYSADMIN_UID" \
      '$1==n && $3+0>=m && $3+0<=M && $3!=s {print n}' "${PASSWD_FILE:-/etc/passwd}"
  done < <(group_members)
}

# Une fonction pour un `cut`, et c'est le point : recopier la conversion dans un temoin validerait
# une COPIE. Ce qui doit rester vrai est ce que l'appelant reel calcule.
roster_of() { # roster_of <charge id<TAB>login, une par ligne> -> les logins, un par ligne
  cut -f2
}

absent_humans() { # absent_humans <membres…> -> les logins a revoquer, un par ligne
  [[ "$#" -gt 0 ]] || return 0
  local login
  while IFS= read -r login; do
    grep -qxF -- "$login" <<<"$(printf '%s\n' "$@")" && continue
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

# Ce qui doit etre epingle vit AVANT cette ligne ; ce qui AGIT vit apres.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then return 0; fi

command -v curl >/dev/null || { err "curl absent de l'image"; exit 1; }
command -v jq   >/dev/null || { err "jq absent de l'image"; exit 1; }

# ⚠ CES DEUX-LA AVANT LE CONTROLE DE ROOT, deliberement : la configuration est ce qu'un operateur
# se trompe, tandis qu'etre root est une propriete du LANCEMENT. Refuser le privilege d'abord
# repondrait a cote de la question posee.
[[ -n "$FORGE" ]] || { err "FORGE_BASE_URL non pose — aucun enrollment ne peut converger"; exit 2; }
[[ -r "$TOKEN_FILE" ]] || { err "$TOKEN_FILE illisible — le token systeme est le seul droit de lecture de la team"; exit 2; }
# Le siege decide GUARD A et le trou de la plage d'uid : sans lui, ce `useradd` root creerait un
# compte sur l'uid de l'admin.
[[ "$SYSADMIN_UID" =~ ^[0-9]+$ ]] || { err "siege non etabli ($SEAT_UID_FILE absent ou illisible, LCARS_SYSADMIN_UID non pose) — aucun compte ne se cree sur un plancher devine"; exit 2; }

[[ "$(id -u)" -eq 0 ]] || { err "doit tourner en root (c'est lui qui cree les users)"; exit 1; }

api() { # api <path> — le jeton passe par un fichier de config sur STDIN, jamais en argv :
  # `/proc/<pid>/cmdline` est lisible par tout compte du conteneur, toutes les 30 s, a vie.
  printf 'header = "Authorization: token %s"\n' "$(tr -d '[:space:]' < "$TOKEN_FILE")" \
    | curl -s -m 15 -K - "$FORGE/api/v1$1" 2>/dev/null || true
}

team_id() {
  api "/orgs/$ORG/teams" \
    | jq -r --arg t "$TEAM" 'if type=="array" then (.[] | select(.name==$t) | .id) else empty end' 2>/dev/null \
    | head -n1
}

# L'ETAT PER-HUMAIN, convergé — appelé A LA CREATION *et* a chaque reconciliation.
#
# ⚠ CE SERVICE NE PASSE PAS PAR L'INSTALLEUR, ET C'EST TOUT L'OBJET DE LA SEPARATION : ce daemon
# TOURNE, toutes les trente secondes, sur une machine installee, et le critere est ⚖ user : « une
# fois installe, si on supprime deploy/, il doit rien se passer ». Un convergeur qui crierait
# toutes les trente secondes apres `deploy/provision`, c'est le contraire de rien.
#
# ⚠ UN SEUL CHEMIN VERS L'ETAT PER-HUMAIN : celui-ci. L'installeur ne joue AUCUN module de
# `human.d` — deux chemins vers un etat (le premier humain a l'apply, les suivants ici), c'est
# celui qu'on ne relit pas qui derive. ⚖ user : « pas besoin d'avoir du code en + pour faire ce que
# le service qu'on pose fait a son premier tour ».
#
# LE PRIX ASSUME : a la seconde ou l'apply se termine, le siege n'a pas encore son `~/.lcars`. Il
# l'a au premier tour de ce service, trente secondes plus tard. Une install qui se dit finie avant
# que son convergeur ait tourne une fois n'a jamais decrit la machine reelle.
#
# LE VOCABULAIRE DES MODULES VIT DANS `lib/human-protocol.sh`, COTE PRODUIT, ET C'EST LE SEUL
# ENDROIT. Ce bloc le definissait inline, au motif qu'une lib runtime « ferait deux copies d'un
# meme contrat » avec celle de l'installeur — et pendant ce temps les modules, eux, sourcaient la
# lib de l'INSTALLEUR par une garde `${PROVISION_LIB:?}` que ce convergeur ne posait pas. Mesure
# du 2026-09-04 sur les deux bancs : chaque humain cree mourait a la ligne 1 de ses trois modules,
# rc=1, sans `~/.lcars`, sans `claude`, sans projets — et `--once` rendait 0. Les deux copies
# existaient bel et bien, et aucune des deux ne servait.
#
# ⚖ user 2026-09-04 (Q3) : ce qui est joue en prod est du produit. Le protocole est donc ICI, dans
# `services/lib/`, source par le module lui-meme (`LCARS_HUMAN_PROTOCOL`) et par ses
# temoins — une copie, un contrat, et l'installeur garde sa lib pour SES modules : deux contrats,
# chacun chez celui qui le joue. Les modules sont SOURCES dans un sous-shell : leur `case "$1"`
# final les dispatche, et le sous-shell garantit qu'aucun n'empoisonne le suivant. Le chemin du
# protocole (`HUMAN_PROTOCOL`) est resolu en tete de ce fichier, la ou ce daemon le source lui-meme.
HUMAN_MODULES="${LCARS_HUMAN_MODULES:-/opt/lcars/services/human.d}"

converge_human() { # converge_human <login>
  local login=$1
  [[ -d "$HUMAN_MODULES" ]] || { err "$login : modules per-humain introuvables ($HUMAN_MODULES)"; return 1; }

  local m rc_all=0 out
  out="$(mktemp "${TMPDIR:-/tmp}/lcars-converge.XXXXXX")" || out=""

  # ⚠ LES MODULES SE JOUENT SOUS L'IDENTITE DE L'HUMAIN, PAS SOUS CELLE DE CE SERVICE. Ils
  # agissent sur une PERSONNE, et l'installeur les jouait par `as_human` : `runuser -u <login>`, cwd
  # dans son home, HOME/USER/LOGNAME poses. Ce service les sourcait en ROOT — mesure du 2026-09-04,
  # banc bob_1, la premiere fois qu'ils ont tourne ici : `~/.lcars` de l'humain cree root:root,
  # son `fleet.env` illisible par lui, `git config` mort sur « $HOME not set », `lcars` sur
  # « HOME: unbound ». Un module per-humain joue en root ecrit chez l'humain ce que l'humain ne
  # peut pas lire.
  #
  # Hors root, le module joue sous l'identite courante : ce n'est un cas que pour un decor de
  # temoin — en prod ce service est root, sinon il n'aurait pas cree l'humain.
  local home="" tag
  if [[ "$EUID" -eq 0 && "$(id -un)" != "$login" ]]; then
    home="$(getent passwd "$login" | cut -d: -f6 || true)"
    [[ -n "$home" ]] || { err "$login : pas de home dans passwd — les modules per-humain ne se jouent pas"; return 1; }
  fi

  # L'ORDRE EST CELUI DU PREFIXE NUMERIQUE, lisible dans un `ls` — meme regle que `modules.d`.
  for m in "$HUMAN_MODULES"/[0-9][0-9]-*.sh; do
    [[ -f "$m" ]] || continue
    local rc=0
    tag="$(basename "$m" .sh)"
    # LE MODULE CHARGE LE PROTOCOLE LUI-MEME, par la variable que l'hote lui donne — la meme
    # forme que ses temoins. Ce service ne definit plus rien : il nomme l'humain, le module, et
    # le fichier. Vide si l'hote n'en a pas (un decor qui ne joue que cette fonction) : c'est
    # alors la garde du module qui parle, et elle nomme sa cause.
    # LCARS_MODULE_RUN arme la garde du protocole : un module qui meurt sous `set -e` sortait du
    # code de la commande qui a echoue, et un 2 passait ici pour un drift acceptable — toutes les
    # 30 s, en silence. Une mort rend 3, et 3 n'est le drift de personne.
    if [[ -n "$home" ]]; then
      ( cd "$home" && runuser -u "$login" -- \
          env HOME="$home" USER="$login" LOGNAME="$login" \
              LCARS_LOGIN="$login" LCARS_MODULE_TAG="$tag" LCARS_MODULE_RUN=1 \
              LCARS_HUMAN_PROTOCOL="${HUMAN_PROTOCOL:-${LCARS_HUMAN_PROTOCOL:-}}" \
              bash -c 'set -euo pipefail; . "$1" apply' _ "$m"
      ) >"${out:-/dev/null}" 2>&1 || rc=$?
    else
      (
        set -euo pipefail
        export LCARS_LOGIN="$login" LCARS_MODULE_TAG="$tag" LCARS_MODULE_RUN=1
        export LCARS_HUMAN_PROTOCOL="${HUMAN_PROTOCOL:-${LCARS_HUMAN_PROTOCOL:-}}"
        # shellcheck source=/dev/null  # le module est choisi a l execution — chemin non constant par nature
        . "$m" apply
      ) >"${out:-/dev/null}" 2>&1 || rc=$?
    fi
    if [[ "$rc" -ne 0 && "$rc" -ne 2 ]]; then
      rc_all=1
      if [[ "$rc" -eq 3 ]]; then
        err "$login : $(basename "$m" .sh) MORT avant de rendre son verdict — rien n'a ete conclu ; les 15 dernieres lignes :"
      else
        err "$login : $(basename "$m" .sh) rc=$rc — les 15 dernieres lignes :"
      fi
      [[ -n "$out" ]] && tail -n 15 "$out" | while IFS= read -r l; do err "  | $l"; done
    fi
  done
  [[ -n "$out" ]] && rm -f "$out"
  [[ "$rc_all" -eq 0 ]]
}

# LES TROIS GESTES DE LA REVOCATION, dans l'ordre qui les rend vrais (cf. l'en-tete). Chacun est
# tolerant a l'echec de l'etape precedente : une revocation partielle vaut mieux qu'une revocation
# abandonnee au milieu, et le tour suivant reprendra ce qui manque.
revoke_human() { # revoke_human <login>
  local login=$1
  gpasswd -d "$login" "$GROUP" >/dev/null 2>&1 || true
  # TERM puis KILL : le serveur tmux, ttyd, le BEAM et les pods vivent sur des sockets tmux
  # DIFFERENTS (`~/.lcars/run/fleet.sock`, `~/.lcars/run/tmux-sock/<pod>/pod.sock`), donc aucun
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
  local login why
  while IFS= read -r login; do
    [[ -n "$login" ]] || continue
    why="$(machine_admin_why "$login")"
    if [[ -n "$why" ]]; then
      spare_machine_admin "$login" "$why"
      continue
    fi
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
    converge_human "$login" || { err "$login : reconciliation per-humain en echec — les modules ont dit leur cause ci-dessus"; continue; }
    n=$((n + 1))
  done
  [[ "$n" -gt 0 ]] && say "$n humain(s) reconcilie(s) (passe lente, toutes les ${RECONCILE_EVERY}s)"
  return 0
}

converge_once() {
  local tid members login created=0
  # LA FRONTIERE D'ABORD, UNE FOIS PAR TOUR. Sans bornes lisibles, ce daemon ne sait ni qui est
  # reserve, ni ou creer, ni qui il a converge : il ne cree, ne restaure ni ne revoque PERSONNE ce
  # tour. Le protocole dit le remede une fois par processus ; ce daemon le redit une fois par
  # tour — pas une fois par membre, et pas trente fois par minute en silence.
  if ! uid_bounds; then
    err "$UID_BOUNDS_WHY — rien converge ce tour (aucun compte cree, restaure ni revoque)"
    return 0
  fi
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
      # UN COMPTE QUI EXISTE N'EST PAS UN HUMAIN POUR AUTANT. `sshd`, `nobody`, un compte de service
      # inscrit sur la forge par erreur passaient ici SANS `reserved` et se retrouvaient dans le
      # groupe fleet — le meme refus que pour un compte a creer, prononce une fois.
      if reserved "$login"; then
        already_refused "$login" || {
          err "REFUS $login — compte EXISTANT reserve (uid hors [UID_MIN..UID_MAX], compte systeme ou de service) ; ni reintegre, ni console"
          mark_refused "$login" "ce login existe deja sur ce conteneur comme compte systeme ou de service : il ne devient pas un humain de fleet"; }
        continue
      fi
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
        mark_refused "$login" "ce login est reserve sur ce conteneur (compte systeme, ou compte de service de la fleet)"; }
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
    # plus bas repondrait « il a un home » pour TOUT LE MONDE.
    if [[ -d "$HOME_ROOT/$login" ]]; then
      uid_src="repris de son home"
    elif [[ -n "$(uid_from_map "$forge_id")" ]]; then
      uid_src="relu dans la table (id de forge $forge_id)"
    else
      uid_src="premier libre au-dessus du siege"
    fi
    want_uid="$(uid_wanted "$login" "$forge_id")" || want_uid=""
    # Un uid VIDE n'est plus « useradd choisira » : `uid_wanted` rend toujours un uid quand le
    # plancher se lit (D8), donc vide = plancher illisible = on ne cree pas sur le defaut de useradd.
    if [[ -z "$want_uid" ]]; then
      err "$login : aucun uid a poser (plancher illisible) — AUCUN user cree ce tour"
      continue
    fi
    holder="$(uid_taken_by "$want_uid" "$login")"
    if [[ -n "$holder" ]]; then
      already_refused "$login" || {
        err "REFUS $login — uid $want_uid ($uid_src), deja porte par '$holder' ; AUCUN user cree (croisement a demeler a la main)"
        mark_refused "$login" "l'uid $want_uid ($uid_src) est deja porte par un autre compte ($holder) — un humain doit demeler"; }
      continue
    fi
    uid_args=(-u "$want_uid")
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
      # Le substrat per-humain (~/.lcars, ~/pods, fleet.env seede) appartient a 70-human : on ne
      # le recopie pas ici, on l'appelle. Une deuxieme implementation du meme etat-cible derive.
      converge_human "$login" \
        || err "$login : user cree mais le provisioning per-humain a echoue — les modules ont dit leur cause ci-dessus ($HUMAN_MODULES)"
      # Meme interrupteur que l'entrypoint : qui coupe les consoles les coupe pour tout le monde.
      ensure_console "$login"
    else
      err "$login : useradd a echoue — AUCUN user cree (relance au prochain tour)"
    fi
  done <<< "$members"
  [[ "$created" -gt 0 ]] && say "$created humain(s) converge(s)"

  # Un TABLEAU, pas un `$(...)` nu : s'appuyer sur la validation d'un autre bout du script pour se
  # permettre un decoupage par espaces est le genre de dette qui survit a la regle qui la rendait sure.
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

# ⚠ `set -e` EST UN CONTRAT DE DEMARRAGE, PAS UN CONTRAT DE BOUCLE, et ce `+e` n'est pas un
# relachement. Un signal TRAPPE delivre au groupe de process tue le `sleep` enfant sans tuer bash ;
# `sleep` rend non-zero, `errexit` s'applique, et la boucle eternelle s'arrete au premier tour —
# sans une erreur, sans une trace. Chaque echec qui compte est deja gere explicitement.
set +e
while true; do
  converge_once
  sleep "$INTERVAL"
done
