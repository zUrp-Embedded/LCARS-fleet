#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/21-service-accounts.sh
# AUTHOR: bob
# STARDATE: 2026-08-25
# STATUS: PROTO-V2 — les comptes SYSTEME des services de la machine (aucun humain ici)
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root
#
# ─── POURQUOI UN MODULE, ET PAS UNE LIGNE DANS `20-groups` ──────────────────────────────────────
#
# Ce module a failli ne pas exister. La question etait : elargir `20-groups` en « comptes ET groupes
# du systeme », ou en poser un dedie ? Le premier coute une ligne — et rend son nom FAUX.
#
# C'est le defaut que deux chantiers voisins viennent de reparer : `docker.sh` nommait le transport
# au lieu du rail, `deploy/docker/` nommait l'outil au lieu du metier. Elargir un module en gardant
# son nom, c'est le meme geste en miniature — et un lecteur qui cherche ou naissent les comptes de
# service ne regarde pas dans un module appele « groups ».
#
# ─── DEUX COMPTES, ET LEUR DIFFERENCE EST LE SUJET ──────────────────────────────────────────────
#
# `lcars-authority` DETIENT (les secrets de la forge) et n'escalade rien.
# `lcars-system`    N'EST QUE quelqu'un : il fait tourner la landing, qui ne detient rien de durable
#                   et n'a aucun privilege — elle a seulement besoin de ne PAS etre `nobody`.
#
# ⚠ POURQUOI `nobody` NE SUFFIT PAS, ET C'EST UNE MESURE, PAS UN PRINCIPE. `nobody` n'est pas une
# identite, c'est la convention de ceux qui n'en ont pas choisi. Le prix se lit sur son GROUPE :
# `deck-oidc.json` porte le `client_secret` OAuth2 de la boite et se posait `0640 root:nogroup` —
# « le mode le plus etroit qui marche », vrai si `nogroup` nommait une identite. Releve sur une
# Debian/Ubuntu ordinaire le 2026-08-27, `nogroup` (gid 65534) est le groupe PRIMAIRE de quatre
# comptes : `sync`, `_apt`, `nobody`, `dhcpcd`. Un demon reseau lisait donc le secret.
#
# ⚠ ET IL NE PREND PAS `fleet`, LUI. `lcars-authority` en est membre pour traverser
# `/local/LCARS_v2` ; la landing n'y lit RIEN — sa doc a ete deplacee hors du prefixe de release
# (`/usr/share/lcars/doc`) precisement parce que ce process ne pouvait pas l'y lire. Lui donner
# `fleet` « au cas ou » rendrait faux le motif qui a coute ce deplacement.
#
# ─── CE QUE CE COMPTE EST, ET CE QU'IL N'EST PAS ────────────────────────────────────────────────
#
# `lcars-authority` DETIENT des secrets de forge et n'a AUCUN privilege noyau. C'est l'inverse exact
# du convergeur d'humains, qui a le privilege (`useradd`) et ne detient rien. Les deux metiers ne se
# melangent pas : celui qui detient ne peut pas escalader, celui qui escalade n'a rien a voler.
#
# ⚠ SANS SHELL ET SANS HOME. Un compte de service n'a personne a connecter : `nologin` ferme la
# porte, et l'absence de home evite un `/home/lcars-authority` que le convergeur d'humains devrait
# ensuite apprendre a ignorer.
#
# ⚠ MEMBRE DU GROUPE `fleet`, ET CE N'EST PAS UNE AUTORITE — C'EST UNE TRAVERSEE. `/local/LCARS_v2`
# est `0750 root:fleet` (system.manifest), et `catalogue install` y execute le binaire de release par
# `entrypoint catalogue-source`. Sans le groupe, le geste echoue sur un repertoire qu'il ne peut pas
# ouvrir. Le groupe donne la LECTURE d'un arbre installe ; l'adminite, elle, se demande a la forge a
# l'instant du geste et ne se lit nulle part sur ce systeme.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

# Le nom vit ICI, une fois. Les unites systemd et l'entrypoint le copient — et un temoin compare les
# copies, parce qu'une copie que personne ne verifie n'est pas une source unique de verite.
AUTHORITY_USER="${PROV_AUTHORITY_USER:-lcars-authority}"
# ─── LE GROUPE DU SERVICE, ET POURQUOI IL DOIT EXISTER ──────────────────────────────────────────
#
# ⚠ CE MODULE FAISAIT `useradd -g "$PROV_FLEET_GROUP"`, ET C'ETAIT LA MOITIE D'UN PATRON. Donner un
# groupe primaire EXISTANT est legitime — `22-fleet-human:184` le fait deliberement pour l'humain de
# fleet, dont la possession s'ecrit alors `user:fleet`. Ce qui est faux, c'est de le faire PUIS
# d'ecrire `chown user:user` : `useradd -g <groupe existant>` ne cree AUCUN groupe du nom du compte.
#
# MESURE DU 2026-08-25, install reelle sur WSL : `uid=999(lcars-authority) gid=1001(fleet)`, et
# `getent group lcars-authority` ne rend RIEN. Six `chown user:user` et deux lignes de manifeste
# nommaient donc un groupe inexistant — `chown: invalid group` — et trois modules sont tombes.
#
# ⚠ ET LA CICATRICE ETAIT DEJA ECRITE, A DEUX PORTES D'ICI. `services/console.sh:328` porte, mesure
# et datee du 2026-08-21 : « `useradd -g fleet lcars` ne cree aucun groupe `lcars` » — avec son
# symptome, une console MORTE au demarrage. J'ai ecrit `-g` dans le fichier d'a cote deux jours
# apres, sans lire le voisin.
#
# ⚖ POURQUOI UN GROUPE A LUI, ET PAS `user:fleet` : ecrire `chown user:fleet` sur les secrets
# remettrait `fleet` en position d'AUTORITE sur eux — le nom du groupe redeviendrait une reponse a
# « qui a le droit de lire », l'inverse exact de ce que ce chantier retire. A 0600 le groupe ne donne
# rien AUJOURD'HUI ; il donnerait tout le jour ou quelqu'un relache un jeton en 0640.
AUTHORITY_GROUP="${PROV_AUTHORITY_GROUP:-$AUTHORITY_USER}"
# Le compte de la landing. Meme forme, meme regle de groupe a lui — et AUCUNE adhesion a `fleet`.
SYSTEM_USER="${PROV_SYSTEM_USER:-lcars-system}"
SYSTEM_GROUP="${PROV_SYSTEM_GROUP:-$SYSTEM_USER}"
NOLOGIN="${LCARS_NOLOGIN:-/usr/sbin/nologin}"

# ⚠ SEAM DE TEMOIN, MEME IDIOME QUE `05-host-consent` ET `62-runtime-helpers` : un temoin ne peut pas
# creer un compte systeme. Ce qui doit etre epingle est ce qui S'ECRIT, pas le pouvoir de l'ecrire.
USERADD="${LCARS_USERADD:-useradd}"
USERMOD="${LCARS_USERMOD:-usermod}"
PASSWD_FILE="${LCARS_PASSWD_FILE:-/etc/passwd}"

account_exists() { awk -F: -v n="$1" '$1==n {found=1} END {exit !found}' "$PASSWD_FILE"; }
shell_of()       { awk -F: -v n="$1" '$1==n {print $7; exit}' "$PASSWD_FILE"; }

check() {
  # ⚠ LE GROUPE EST SONDE AVANT LE COMPTE, ET SON ABSENCE ETAIT LE TROU DE CE `check`. Il verifiait
  # le compte et l'adhesion, jamais le groupe — donc il rendait CONFORME sur la machine exacte ou
  # `chown lcars-authority:lcars-authority` allait echouer trois modules plus loin. Un check qui ne
  # sonde pas ce que l'apply pose est un check qui certifie l'etat qu'il ne regarde pas.
  if getent group "$AUTHORITY_GROUP" >/dev/null 2>&1; then
    p_ok "groupe de service $AUTHORITY_GROUP"
  else
    p_drift "groupe $AUTHORITY_GROUP absent — tout « chown $AUTHORITY_USER:$AUTHORITY_GROUP » échouera sur « invalid group », et les secrets de forge ne seront posés nulle part"
  fi

  if account_exists "$AUTHORITY_USER"; then
    if [[ "$(shell_of "$AUTHORITY_USER")" == "$NOLOGIN" ]]; then
      p_ok "compte de service $AUTHORITY_USER ($NOLOGIN)"
    else
      p_drift "compte $AUTHORITY_USER présent mais son shell n'est pas $NOLOGIN — un compte de service ne se connecte pas"
    fi
  else
    p_drift "compte de service $AUTHORITY_USER absent — le service d'autorité n'a pas d'identité, et personne ne peut détenir les secrets de forge à sa place"
  fi

  # ⚠ L'ADHESION EST UNE PRECONDITION DU GESTE, PAS UN CONFORT. Sans elle, `catalogue install`
  # meurt sur `/local/LCARS_v2` (0750 root:fleet) — un refus de catalogue pour un probleme de
  # traversee, exactement la classe de diagnostic faux que ce rail a deja payee deux fois.
  if account_exists "$AUTHORITY_USER" \
     && id -nG "$AUTHORITY_USER" 2>/dev/null | tr ' ' '\n' | grep -qx "$PROV_FLEET_GROUP"; then
    p_ok "$AUTHORITY_USER ∈ $PROV_FLEET_GROUP (traversée de l'install RO)"
  elif account_exists "$AUTHORITY_USER"; then
    p_drift "$AUTHORITY_USER ∉ $PROV_FLEET_GROUP — il ne pourra pas traverser /local/LCARS_v2, et « catalogue install » échouera sur un refus qui accuse le catalogue"
  fi

  # ⚠ SA CONSEQUENCE EST A LUI, ET C'EST LA LECON DE `64-services`. Un message generique ferait dire
  # au compte de la landing ce qui arrive au service d'autorite — la mauvaise porte, au moment ou
  # l'operateur en cherche une.
  if getent group "$SYSTEM_GROUP" >/dev/null 2>&1; then
    p_ok "groupe de service $SYSTEM_GROUP"
  else
    p_drift "groupe $SYSTEM_GROUP absent — la landing ne pourra pas se déposer dessus, et le secret OAuth2 du deck resterait sur un groupe partagé"
  fi

  if account_exists "$SYSTEM_USER"; then
    if [[ "$(shell_of "$SYSTEM_USER")" == "$NOLOGIN" ]]; then
      p_ok "compte de service $SYSTEM_USER ($NOLOGIN)"
    else
      p_drift "compte $SYSTEM_USER présent mais son shell n'est pas $NOLOGIN — un compte de service ne se connecte pas"
    fi
  else
    p_drift "compte de service $SYSTEM_USER absent — la landing retomberait sur « nobody », dont le groupe « nogroup » est partagé par plusieurs comptes système (le secret OAuth2 du deck leur serait lisible)"
  fi

  verdict_check
}

apply() {
  # `20-groups` a deja pose `$PROV_FLEET_GROUP` — ce module tourne apres lui, et son rang le dit.
  #
  # ⚠ LE GROUPE AVANT LE COMPTE, ET L'ORDRE EST UN CONTRAT : `useradd -g "$AUTHORITY_GROUP"` refuse
  # net si le groupe n'existe pas. `ensure_group` est idempotent et verifie son propre `groupadd`
  # (provision-lib) — un groupe qu'on croit pose et qui ne l'est pas est le defaut qu'on repare ici.
  ensure_group "$AUTHORITY_GROUP" || { p_fail "groupe $AUTHORITY_GROUP non posé — le compte de service n'aura pas de groupe à lui, et tout chown sur les secrets échouera"; verdict_apply; }

  if ! account_exists "$AUTHORITY_USER"; then
    # `--system` : pas de home, uid sous UID_MIN, donc `bin/fleet_v2` refusera de lancer une fleet
    # sous ce compte — le garde qui protege les pods vaut aussi pour lui, et gratuitement.
    if run_quiet "$USERADD" --system --no-create-home --shell "$NOLOGIN" \
                 -g "$AUTHORITY_GROUP" -- "$AUTHORITY_USER"; then
      PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "compte de service $AUTHORITY_USER"
    else
      p_fail "création de $AUTHORITY_USER en échec — le service d'autorité restera sans identité"
      verdict_apply
    fi
  fi

  # CONVERGE, ne se contente pas de creer : un compte pose a la main avec un shell valide est une
  # porte ouverte que ce module doit refermer, pas constater.
  if [[ "$(shell_of "$AUTHORITY_USER")" != "$NOLOGIN" ]]; then
    run_quiet "$USERMOD" -s "$NOLOGIN" -- "$AUTHORITY_USER" \
      && { PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "$AUTHORITY_USER -> $NOLOGIN"; } \
      || p_fail "$AUTHORITY_USER : shell non convergé vers $NOLOGIN"
  fi

  ensure_member "$AUTHORITY_USER" "$PROV_FLEET_GROUP" || verdict_apply

  # ─── LE COMPTE DE LA LANDING ────────────────────────────────────────────────────────────────
  # Meme forme que ci-dessus, et une difference DELIBEREE : pas de `ensure_member` vers
  # `$PROV_FLEET_GROUP`. Ce qu'il traverse — les repertoires de socket des consoles — lui est
  # accorde PAR PROCESSUS a l'exec (`setpriv --groups`), jamais par une adhesion persistante.
  # Le groupe `lcars-console` n'a ainsi toujours aucun membre, et c'est ce qui le garde etroit.
  ensure_group "$SYSTEM_GROUP" || { p_fail "groupe $SYSTEM_GROUP non posé — la landing n'aura pas de groupe à elle, et le secret OAuth2 du deck resterait sur un groupe partagé"; verdict_apply; }

  if ! account_exists "$SYSTEM_USER"; then
    if run_quiet "$USERADD" --system --no-create-home --shell "$NOLOGIN" \
                 -g "$SYSTEM_GROUP" -- "$SYSTEM_USER"; then
      PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "compte de service $SYSTEM_USER"
    else
      p_fail "création de $SYSTEM_USER en échec — la landing retomberait sur « nobody »"
      verdict_apply
    fi
  fi

  if [[ "$(shell_of "$SYSTEM_USER")" != "$NOLOGIN" ]]; then
    run_quiet "$USERMOD" -s "$NOLOGIN" -- "$SYSTEM_USER" \
      && { PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "$SYSTEM_USER -> $NOLOGIN"; } \
      || p_fail "$SYSTEM_USER : shell non convergé vers $NOLOGIN"
  fi

  verdict_apply
}

case "${1:?usage: 21-service-accounts.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
