#!/usr/bin/env bash
# SOURCE: deploy/modules.d/21-service-accounts.sh
# AUTHOR: bob
# STARDATE: 2026-08-25
# STATUS: PROTO-V2 — les comptes SYSTEME des services de la machine (aucun humain ici)
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root
# AFTER: 20-groups
# ⚠ SANS SHELL ET SANS HOME. Un compte de service n'a personne a connecter : `nologin` ferme la
# porte, et l'absence de home evite un `/home/lcars-authority` que le convergeur d'humains devrait
# ensuite apprendre a ignorer.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

AUTHORITY_USER="$PROV_AUTHORITY_USER"
AUTHORITY_GROUP="${PROV_AUTHORITY_GROUP:-$AUTHORITY_USER}"
SYSTEM_USER="${PROV_SYSTEM_USER:-lcars-system}"
SYSTEM_GROUP="${PROV_SYSTEM_GROUP:-$SYSTEM_USER}"
NOLOGIN="${LCARS_NOLOGIN:-/usr/sbin/nologin}"

USERADD="${LCARS_USERADD:-useradd}"
USERMOD="${LCARS_USERMOD:-usermod}"
PASSWD_FILE="${LCARS_PASSWD_FILE:-/etc/passwd}"
GROUP_FILE="${LCARS_GROUP_FILE:-/etc/group}"

account_exists() { awk -F: -v n="$1" '$1==n {found=1} END {exit !found}' "$PASSWD_FILE"; }
shell_of()       { awk -F: -v n="$1" '$1==n {print $7; exit}' "$PASSWD_FILE"; }

# ⚠ LE GROUPE PRIMAIRE SE LIT, IL NE SE DEDUIT PAS DE `useradd -g`. Le `-g` de la creation ne vaut
# QU'A la creation : un compte qui existait deja, ou qu'un `usermod` a deplace, garde le groupe
# qu'il a. Sans cette sonde, `21-service-accounts` rendait vert un `lcars-system` retombe sur
# `nogroup` — c'est-a-dire l'etat exact que son propre message de drift decrit comme dangereux.
primary_group_of() { # primary_group_of <compte> -> le NOM de son groupe primaire, ou vide
  local gid; gid="$(awk -F: -v n="$1" '$1==n {print $4; exit}' "$PASSWD_FILE")"
  [[ -n "$gid" ]] || return 0
  awk -F: -v g="$gid" '$3==g {print $1; exit}' "$GROUP_FILE"
}

check() {
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

  if account_exists "$AUTHORITY_USER"; then
    local _pg; _pg="$(primary_group_of "$AUTHORITY_USER")"
    if [[ "$_pg" == "$AUTHORITY_GROUP" ]]; then
      p_ok "groupe primaire de $AUTHORITY_USER : $AUTHORITY_GROUP"
    else
      p_drift "groupe primaire de $AUTHORITY_USER : « ${_pg:-inconnu} » au lieu de $AUTHORITY_GROUP — tout ce qu'il écrit naît sur ce groupe-là, y compris les secrets de forge"
    fi
  fi

  if account_exists "$AUTHORITY_USER" \
     && id -nG "$AUTHORITY_USER" 2>/dev/null | tr ' ' '\n' | grep -qx "$PROV_FLEET_GROUP"; then
    p_ok "$AUTHORITY_USER ∈ $PROV_FLEET_GROUP (traversée de l'install RO)"
  elif account_exists "$AUTHORITY_USER"; then
    p_drift "$AUTHORITY_USER ∉ $PROV_FLEET_GROUP — il ne pourra pas traverser /opt/lcars/runtime, et « catalogue install » échouera sur un refus qui accuse le catalogue"
  fi

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

  if account_exists "$SYSTEM_USER"; then
    local _pgs; _pgs="$(primary_group_of "$SYSTEM_USER")"
    if [[ "$_pgs" == "$SYSTEM_GROUP" ]]; then
      p_ok "groupe primaire de $SYSTEM_USER : $SYSTEM_GROUP"
    else
      p_drift "groupe primaire de $SYSTEM_USER : « ${_pgs:-inconnu} » au lieu de $SYSTEM_GROUP — le secret OAuth2 du deck naîtrait sur ce groupe-là, lisible par tout ce qui le porte"
    fi
  fi

  verdict_check
}

apply() {
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

  if [[ "$(shell_of "$AUTHORITY_USER")" != "$NOLOGIN" ]]; then
    if run_quiet "$USERMOD" -s "$NOLOGIN" -- "$AUTHORITY_USER"; then
      PROV_CHANGED=$((PROV_CHANGED + 1))
      p_chg "$AUTHORITY_USER -> $NOLOGIN"
    else
      p_fail "$AUTHORITY_USER : shell non convergé vers $NOLOGIN"
    fi
  fi

  # ⚠ APRES la creation, et PAS a sa place : `useradd -g` ne pose le groupe primaire que la premiere
  # fois. Cette convergence est le seul geste qui rattrape un compte qui existait avant nous.
  if [[ "$(primary_group_of "$AUTHORITY_USER")" != "$AUTHORITY_GROUP" ]]; then
    if run_quiet "$USERMOD" -g "$AUTHORITY_GROUP" -- "$AUTHORITY_USER"; then
      PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "groupe primaire de $AUTHORITY_USER -> $AUTHORITY_GROUP"
    else
      p_fail "$AUTHORITY_USER : groupe primaire non convergé vers $AUTHORITY_GROUP"
      verdict_apply
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

  if [[ "$(primary_group_of "$SYSTEM_USER")" != "$SYSTEM_GROUP" ]]; then
    if run_quiet "$USERMOD" -g "$SYSTEM_GROUP" -- "$SYSTEM_USER"; then
      PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "groupe primaire de $SYSTEM_USER -> $SYSTEM_GROUP"
    else
      p_fail "$SYSTEM_USER : groupe primaire non convergé vers $SYSTEM_GROUP"
      verdict_apply
    fi
  fi

  verdict_apply
}

case "${1:?usage: 21-service-accounts.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
