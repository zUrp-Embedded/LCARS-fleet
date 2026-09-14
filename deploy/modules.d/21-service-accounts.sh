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

NOLOGIN=/usr/sbin/nologin

PASSWD_FILE="$(prov_decor /etc/passwd)"
GROUP_FILE="$(prov_decor /etc/group)"

account_exists() { awk -F: -v n="$1" '$1==n {found=1} END {exit !found}' "$PASSWD_FILE"; }
shell_of()       { awk -F: -v n="$1" '$1==n {print $7; exit}' "$PASSWD_FILE"; }

primary_group_of() { # primary_group_of <compte> -> le NOM de son groupe primaire, ou vide
  local gid; gid="$(awk -F: -v n="$1" '$1==n {print $4; exit}' "$PASSWD_FILE")"
  [[ -n "$gid" ]] || return 0
  awk -F: -v g="$gid" '$3==g {print $1; exit}' "$GROUP_FILE"
}

# compte_de_service <p_drift|p_fail> <compte> <ce qu'il détient> — le compte existe, sur son groupe
# éponyme, avec nologin ; le verdict qualifie l'écart. Un compte qui s'en écarte n'est jamais corrigé.
compte_de_service() {
  local verdict="$1" compte="$2" detient="$3" ecart="" shell pg
  if ! getent group "$compte" >/dev/null 2>&1; then
    "$verdict" "groupe $compte absent — le compte qui détient $detient n'a pas de groupe à lui"
    return 1
  fi
  if ! account_exists "$compte"; then
    "$verdict" "compte de service $compte absent — personne ne détient $detient"
    return 1
  fi
  shell="$(shell_of "$compte")"
  pg="$(primary_group_of "$compte")"
  [[ "$shell" == "$NOLOGIN" ]] || ecart="shell « ${shell:-vide} » au lieu de $NOLOGIN"
  [[ "$pg" == "$compte" ]] || ecart="${ecart:+$ecart, }groupe primaire « ${pg:-inconnu} » au lieu de $compte"
  if [[ -n "$ecart" ]]; then
    "$verdict" "compte $compte : $ecart — il détient $detient ; un compte qui existe déjà n'est pas corrigé : le retirer (userdel $compte), puis relancer"
    return 1
  fi
  p_ok "compte de service $compte (groupe $compte, $NOLOGIN)"
}

creer_compte() { # creer_compte <compte> <ce qu'il détient> — groupe éponyme et compte, s'ils manquent
  ensure_group "$1" || return 1
  account_exists "$1" && return 0
  # --system : uid sous UID_MIN, donc bin/fleet refuse une fleet sous ce compte
  if ! run_capture useradd --system --no-create-home --shell "$NOLOGIN" -g "$1" -- "$1"; then
    p_fail "création de $1 en échec — personne ne détient $2"
    prov_dump_last
    return 1
  fi
  PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "compte de service $1"
}

AUTHORITY_DETIENT="les secrets de forge"
SYSTEM_DETIENT="le secret OAuth2 du deck"

check() {
  if compte_de_service p_drift "$PROV_AUTHORITY_USER" "$AUTHORITY_DETIENT"; then
    if prov_in_group "$PROV_AUTHORITY_USER" "$PROV_FLEET_GROUP"; then
      p_ok "$PROV_AUTHORITY_USER ∈ $PROV_FLEET_GROUP (traversée de l'install RO)"
    else
      p_drift "$PROV_AUTHORITY_USER ∉ $PROV_FLEET_GROUP — il ne pourra pas traverser $PROV_PREFIX, et « catalogue install » échouera sur un refus qui accuse le catalogue"
    fi
  fi
  compte_de_service p_drift "$PROV_SYSTEM_USER" "$SYSTEM_DETIENT" || true
  verdict_check
}

apply() {
  if creer_compte "$PROV_AUTHORITY_USER" "$AUTHORITY_DETIENT" \
     && compte_de_service p_fail "$PROV_AUTHORITY_USER" "$AUTHORITY_DETIENT"; then
    ensure_member "$PROV_AUTHORITY_USER" "$PROV_FLEET_GROUP" || true
  fi
  # pas d'adhésion à fleet pour lcars-system : ce qu'il traverse lui est accordé par processus (setpriv --groups)
  if creer_compte "$PROV_SYSTEM_USER" "$SYSTEM_DETIENT"; then
    compte_de_service p_fail "$PROV_SYSTEM_USER" "$SYSTEM_DETIENT" || true
  fi
  verdict_apply
}

"$1"
