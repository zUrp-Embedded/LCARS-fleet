#!/usr/bin/env bash
# SOURCE: deploy/modules.d/21-service-accounts.sh
# AUTHOR: bob
# STARDATE: 2026-08-25
# STATUS: les comptes système des services de la machine — sans shell ni home, aucun humain ici
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root
# AFTER: 20-groups

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — ce module se joue par ./provision, pas nu}"

AUTHORITY_USER="$PROV_AUTHORITY_USER"
AUTHORITY_GROUP="$PROV_AUTHORITY_USER"
SYSTEM_USER="$PROV_SYSTEM_USER"
SYSTEM_GROUP="$PROV_SYSTEM_USER"
NOLOGIN=/usr/sbin/nologin

PASSWD_FILE="$(prov_decor /etc/passwd)"
GROUP_FILE="$(prov_decor /etc/group)"

account_exists() { awk -F: -v n="$1" '$1==n {found=1} END {exit !found}' "$PASSWD_FILE"; }
shell_of()       { awk -F: -v n="$1" '$1==n {print $7; exit}' "$PASSWD_FILE"; }

# le groupe primaire se lit : le -g de useradd ne vaut qu'à la création, un compte déjà là garde le sien
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
     && prov_in_group "$AUTHORITY_USER" "$PROV_FLEET_GROUP"; then
    p_ok "$AUTHORITY_USER ∈ $PROV_FLEET_GROUP (traversée de l'install RO)"
  elif account_exists "$AUTHORITY_USER"; then
    p_drift "$AUTHORITY_USER ∉ $PROV_FLEET_GROUP — il ne pourra pas traverser $PROV_PREFIX, et « catalogue install » échouera sur un refus qui accuse le catalogue"
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
  ensure_group "$AUTHORITY_GROUP" || verdict_apply

  if ! account_exists "$AUTHORITY_USER"; then
    # --system : uid sous UID_MIN, donc bin/fleet refuse une fleet sous ce compte, gratuitement
    if run_capture useradd --system --no-create-home --shell "$NOLOGIN" \
                 -g "$AUTHORITY_GROUP" -- "$AUTHORITY_USER"; then
      PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "compte de service $AUTHORITY_USER"
    else
      p_fail "création de $AUTHORITY_USER en échec — le service d'autorité restera sans identité"
      prov_dump_last
      verdict_apply
    fi
  fi

  if [[ "$(shell_of "$AUTHORITY_USER")" != "$NOLOGIN" ]]; then
    if run_capture usermod -s "$NOLOGIN" -- "$AUTHORITY_USER"; then
      PROV_CHANGED=$((PROV_CHANGED + 1))
      p_chg "$AUTHORITY_USER -> $NOLOGIN"
    else
      p_fail "$AUTHORITY_USER : shell non convergé vers $NOLOGIN"
      prov_dump_last
    fi
  fi

  if [[ "$(primary_group_of "$AUTHORITY_USER")" != "$AUTHORITY_GROUP" ]]; then
    if run_capture usermod -g "$AUTHORITY_GROUP" -- "$AUTHORITY_USER"; then
      PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "groupe primaire de $AUTHORITY_USER -> $AUTHORITY_GROUP"
    else
      p_fail "$AUTHORITY_USER : groupe primaire non convergé vers $AUTHORITY_GROUP"
      prov_dump_last
      verdict_apply
    fi
  fi

  ensure_member "$AUTHORITY_USER" "$PROV_FLEET_GROUP" || verdict_apply

  # pas d'adhésion à fleet pour lcars-system : ce qu'il traverse lui est accordé par processus (setpriv --groups)
  ensure_group "$SYSTEM_GROUP" || verdict_apply

  if ! account_exists "$SYSTEM_USER"; then
    if run_capture useradd --system --no-create-home --shell "$NOLOGIN" \
                 -g "$SYSTEM_GROUP" -- "$SYSTEM_USER"; then
      PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "compte de service $SYSTEM_USER"
    else
      p_fail "création de $SYSTEM_USER en échec — la landing retomberait sur « nobody »"
      prov_dump_last
      verdict_apply
    fi
  fi

  if [[ "$(shell_of "$SYSTEM_USER")" != "$NOLOGIN" ]]; then
    if run_capture usermod -s "$NOLOGIN" -- "$SYSTEM_USER"; then
      PROV_CHANGED=$((PROV_CHANGED + 1))
      p_chg "$SYSTEM_USER -> $NOLOGIN"
    else
      p_fail "$SYSTEM_USER : shell non convergé vers $NOLOGIN"
      prov_dump_last
    fi
  fi

  if [[ "$(primary_group_of "$SYSTEM_USER")" != "$SYSTEM_GROUP" ]]; then
    if run_capture usermod -g "$SYSTEM_GROUP" -- "$SYSTEM_USER"; then
      PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "groupe primaire de $SYSTEM_USER -> $SYSTEM_GROUP"
    else
      p_fail "$SYSTEM_USER : groupe primaire non convergé vers $SYSTEM_GROUP"
      prov_dump_last
      verdict_apply
    fi
  fi

  [[ "${PROV_CHANGED:-0}" -gt 0 ]] || p_ok "comptes de service en place : $AUTHORITY_USER (membre de $PROV_FLEET_GROUP), $SYSTEM_USER (groupe $SYSTEM_GROUP)"
  verdict_apply
}

case "${1:?usage: 21-service-accounts.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
