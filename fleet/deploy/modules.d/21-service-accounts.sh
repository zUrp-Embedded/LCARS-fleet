#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/21-service-accounts.sh
# AUTHOR: bob
# STARDATE: 2026-08-25
# STATUS: PROTO-V2 — les comptes SYSTEME des services de la machine (aucun humain ici)
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root
# AFTER: 20-groups
# ⚠ ET IL NE PREND PAS `fleet`, LUI. `lcars-authority` en est membre pour traverser
# `/opt/lcars/runtime` ; la landing n'y lit RIEN — sa doc a ete deplacee hors du prefixe de release
# (`/opt/lcars/share/doc`) precisement parce que ce process ne pouvait pas l'y lire. Lui donner
# `fleet` « au cas ou » rendrait faux le motif qui a coute ce deplacement.
# ⚠ SANS SHELL ET SANS HOME. Un compte de service n'a personne a connecter : `nologin` ferme la
# porte, et l'absence de home evite un `/home/lcars-authority` que le convergeur d'humains devrait
# ensuite apprendre a ignorer.
# ⚠ MEMBRE DU GROUPE `fleet`, ET CE N'EST PAS UNE AUTORITE — C'EST UNE TRAVERSEE. `/opt/lcars/runtime`
# est `0750 root:fleet` (system.manifest), et `catalogue install` y execute le binaire de release par
# `entrypoint catalogue-source`. Sans le groupe, le geste echoue sur un repertoire qu'il ne peut pas
# ouvrir. Le groupe donne la LECTURE d'un arbre installe ; l'adminite, elle, se demande a la forge a
# l'instant du geste et ne se lit nulle part sur ce systeme.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

AUTHORITY_USER="$PROV_AUTHORITY_USER"
AUTHORITY_GROUP="${PROV_AUTHORITY_GROUP:-$AUTHORITY_USER}"
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

  if account_exists "$AUTHORITY_USER" \
     && id -nG "$AUTHORITY_USER" 2>/dev/null | tr ' ' '\n' | grep -qx "$PROV_FLEET_GROUP"; then
    p_ok "$AUTHORITY_USER ∈ $PROV_FLEET_GROUP (traversée de l'install RO)"
  elif account_exists "$AUTHORITY_USER"; then
    p_drift "$AUTHORITY_USER ∉ $PROV_FLEET_GROUP — il ne pourra pas traverser /opt/lcars/runtime, et « catalogue install » échouera sur un refus qui accuse le catalogue"
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
    if run_quiet "$USERMOD" -s "$NOLOGIN" -- "$AUTHORITY_USER"; then
      PROV_CHANGED=$((PROV_CHANGED + 1))
      p_chg "$AUTHORITY_USER -> $NOLOGIN"
    else
      p_fail "$AUTHORITY_USER : shell non convergé vers $NOLOGIN"
    fi
  fi

  ensure_member "$AUTHORITY_USER" "$PROV_FLEET_GROUP" || verdict_apply

  # Meme forme que ci-dessus, et une difference DELIBEREE : pas de `ensure_member` vers
  # `$PROV_FLEET_GROUP`. Ce qu'il traverse — les repertoires de socket des consoles — lui est
  # accorde PAR PROCESSUS a l'exec (`setpriv --groups`), jamais par une adhesion persistante.
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
    if run_quiet "$USERMOD" -s "$NOLOGIN" -- "$SYSTEM_USER"; then
      PROV_CHANGED=$((PROV_CHANGED + 1))
      p_chg "$SYSTEM_USER -> $NOLOGIN"
    else
      p_fail "$SYSTEM_USER : shell non convergé vers $NOLOGIN"
    fi
  fi

  verdict_apply
}

case "${1:?usage: 21-service-accounts.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
