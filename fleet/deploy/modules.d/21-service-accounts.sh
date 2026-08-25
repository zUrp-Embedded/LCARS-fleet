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
NOLOGIN="${LCARS_NOLOGIN:-/usr/sbin/nologin}"

# ⚠ SEAM DE TEMOIN, MEME IDIOME QUE `05-host-consent` ET `62-runtime-helpers` : un temoin ne peut pas
# creer un compte systeme. Ce qui doit etre epingle est ce qui S'ECRIT, pas le pouvoir de l'ecrire.
USERADD="${LCARS_USERADD:-useradd}"
USERMOD="${LCARS_USERMOD:-usermod}"
PASSWD_FILE="${LCARS_PASSWD_FILE:-/etc/passwd}"

account_exists() { awk -F: -v n="$1" '$1==n {found=1} END {exit !found}' "$PASSWD_FILE"; }
shell_of()       { awk -F: -v n="$1" '$1==n {print $7; exit}' "$PASSWD_FILE"; }

check() {
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

  verdict_check
}

apply() {
  # `20-groups` a deja pose `$PROV_FLEET_GROUP` — ce module tourne apres lui, et son rang le dit.
  if ! account_exists "$AUTHORITY_USER"; then
    # `--system` : pas de home, uid sous UID_MIN, donc `bin/fleet_v2` refusera de lancer une fleet
    # sous ce compte — le garde qui protege les pods vaut aussi pour lui, et gratuitement.
    if run_quiet "$USERADD" --system --no-create-home --shell "$NOLOGIN" \
                 -g "$PROV_FLEET_GROUP" -- "$AUTHORITY_USER"; then
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
  verdict_apply
}

case "${1:?usage: 21-service-accounts.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
