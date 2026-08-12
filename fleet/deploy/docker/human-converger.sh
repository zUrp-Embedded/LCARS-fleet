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
# ⚠ CE QUI RESTE APRES UNE REVOCATION N'EST PAS « DES DONNEES ». Cette ligne le disait, et c'etait
# faux — mesure du 2026-08-12, compte forge PURGE (204, re-lu 404), user Linux intact :
#   · il reste dans le groupe `fleet`, donc il LIT /home/private/system.gitea_token ;
#   · ce jeton REPOND `lcars-system` sur /api/v1/user, c'est-a-dire PROPRIETAIRE D'ORG ;
#   · les 10 jetons de role lui sont lisibles ;
#   · `console.sh --all` lui relance une console ttyd ECRIVABLE (elle ne lit que /etc/passwd, jamais
#     la forge), qui repond 200 depuis l'hote SANS aucune authentification ;
#   · ~/.lcars, ~/pods et `fleet_v2` sont la : il peut demarrer une fleet.
# Autrement dit une personne revoquee garde un SHELL sur la boite et de quoi agir comme le compte
# systeme. La revocation retire son identite PROPRE ; elle ne touche pas aux credentials PARTAGES,
# et la fleet ne signe jamais en son nom — elle signe `lcars-system`.
#
# CE QUI LA RENDRAIT VRAIE tient en trois lignes : le miroir exact de l'entree. Cette boucle AJOUTE
# au groupe `fleet` (c'est ce groupe qui ouvre /home/private/*) ; l'en retirer couperait l'acces aux
# credentials partages SANS rien supprimer — ni compte, ni home, ni donnees. Ce n'est pas pose ici
# parce que ca change le contrat de cette boucle (add-only -> add-and-revoke) et que ca peut frapper
# quelqu'un en plein travail : c'est un arbitrage, pas du travail derivable. En attendant, ce
# commentaire dit l'etat REEL plutot qu'une garantie qui n'existe pas.
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
PROVISION="${LCARS_PROVISION:-/opt/lcars/fleet/deploy/provision}"
SHELL_="${LCARS_HUMAN_SHELL:-/bin/bash}"
GROUP="${LCARS_FLEET_GROUP:-fleet}"
HOME_ROOT="${LCARS_HOME_ROOT:-/home}"
# Un refus se dit UNE FOIS. Sans cette trace, un login invalide reproche la meme chose toutes les
# 30 s et noie le journal, ce qui revient a ne rien dire du tout.
REFUSED_FILE="${LCARS_CONVERGER_REFUSED:-/run/lcars-converger.refused}"

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

# Sourcer ce fichier donne l'admission ci-dessus et RIEN d'autre : ni preflight, ni boucle.
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
    id "$login" >/dev/null 2>&1 && continue          # deja converge : rien a dire
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
        "$PROVISION" apply --substrate docker --human "$login" --only 70-human >/dev/null 2>&1 \
          || err "$login : user cree mais 70-human a echoue — diagnose : $PROVISION doctor --human $login"
      else
        err "$login : user cree mais $PROVISION introuvable — son ~/.lcars n'est PAS pose"
      fi
    else
      err "$login : useradd a echoue — AUCUN user cree (relance au prochain tour)"
    fi
  done <<< "$members"
  [[ "$created" -gt 0 ]] && say "$created humain(s) converge(s)"
  return 0
}

if [[ "$ONCE" -eq 1 ]]; then
  converge_once
  exit 0
fi

say "convergence des humains : $FORGE org=$ORG team=$TEAM toutes les ${INTERVAL}s"
while true; do
  converge_once || true
  sleep "$INTERVAL"
done
