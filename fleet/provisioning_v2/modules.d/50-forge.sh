#!/usr/bin/env bash
# SOURCE: fleet/provisioning_v2/modules.d/50-forge.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — forge : comptes de rôle + compte système CRÉÉS, puis tokens délégués au script A4
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root
#
# La forge n'est PAS installée ici (elle vit à côté — conteneur sidecar en Docker, service externe
# en WSL/natif) : ce module provisionne CE QUE le runtime attend D'ELLE, via son API :
#   1. les comptes : 7 rôles + le compte SYSTÈME (PROV_SYSTEM_ACCOUNT — ce qui est fait par le
#      système est signé du système) — créés par l'API admin si absents ;
#   2. leurs passwords : générés UNE fois (check-before-create, jamais régénérés — regénérer
#      invaliderait la basic-auth du mint), stockés dans le passwords-file opérateur-only 0600.
#      Ce fichier EST le livrable A4 durable : rejouable à l'infini sur une forge nuke.
#   3. les tokens : DÉLÉGUÉS à fleet/runtime/etc/provision-role-tokens.sh (l'autorité A4 —
#      une seule mécanique de mint, pas deux). Gitea n'accepte QUE la basic-auth pour minter
#      (même un token site-admin ne peut pas — vérifié 2026-07-05), d'où le passwords-file.
#
# Données : PROV_FORGE_URL (obligatoire pour ce module), PROV_FORGE_ADMIN_TOKEN_FILE (token
# site-admin, requis SEULEMENT si des comptes manquent), PROV_PASSWORDS_FILE (défaut
# <tokens-dir>/forge-role-passwords.json).

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

: "${PROV_PASSWORDS_FILE:=$PROV_TOKENS_DIR/forge-role-passwords.json}"
: "${PROV_FORGE_ADMIN_TOKEN_FILE:=}"
A4_SCRIPT="$(repo_root)/fleet/runtime/etc/provision-role-tokens.sh"
ACCOUNTS="$PROV_ROLES $PROV_SYSTEM_ACCOUNT"

forge_up() { curl -fsS -m 10 -o /dev/null "$PROV_FORGE_URL/api/v1/version" 2>/dev/null; }

admin_token() {
  [[ -n "$PROV_FORGE_ADMIN_TOKEN_FILE" && -r "$PROV_FORGE_ADMIN_TOKEN_FILE" ]] || return 1
  tr -d '[:space:]' < "$PROV_FORGE_ADMIN_TOKEN_FILE"
}

account_exists() { # $1=login — endpoint public en lecture (pas besoin d'admin pour SONDER)
  curl -fsS -m 10 -o /dev/null "$PROV_FORGE_URL/api/v1/users/$1" 2>/dev/null
}

check() {
  if [[ -z "$PROV_FORGE_URL" ]]; then
    p_drift "FORGE_BASE_URL/PROV_FORGE_URL non posé — l'état-cible inclut une forge (pose-le via --env ou l'environnement)"
    verdict_check
  fi
  if ! forge_up; then
    p_drift "forge injoignable : $PROV_FORGE_URL/api/v1/version"
    verdict_check
  fi
  p_ok "forge joignable ($PROV_FORGE_URL)"

  local acct
  for acct in $ACCOUNTS; do
    if account_exists "$acct"; then
      p_ok "compte $acct"
    else
      p_drift "compte $acct absent sur la forge"
    fi
  done

  # La sonde tokens EST le --check du script A4 (une seule vérité, pas une re-implémentation).
  if [[ -x "$A4_SCRIPT" ]]; then
    if "$A4_SCRIPT" --forge "$PROV_FORGE_URL" --tokens-dir "$PROV_TOKENS_DIR" \
        --roles "$PROV_ROLES" --extra-token "$PROV_SYSTEM_ACCOUNT:system.gitea_token" --check >/dev/null 2>&1; then
      p_ok "role-tokens valides (sonde A4 --check)"
    else
      p_drift "role-tokens absents/invalides (sonde A4 --check) — l'apply les re-mint"
    fi
  else
    p_fail "script A4 introuvable/inexécutable : $A4_SCRIPT (checkout incomplet ?)"
  fi
  verdict_check
}

# Garantit une entrée password pour $1 dans le passwords-file (génère si absente — JAMAIS
# régénérée si présente). Écriture atomique, fichier né 0600 (umask), root-only.
ensure_password_entry() {
  local acct="$1" dir tmp
  if [[ -f "$PROV_PASSWORDS_FILE" ]] && jq -e --arg a "$acct" 'has($a)' "$PROV_PASSWORDS_FILE" >/dev/null 2>&1; then
    return 0
  fi
  local pwd
  pwd="$(head -c 24 /dev/urandom | base64 | tr -d '=+/' | head -c 24)"
  [[ -n "$pwd" ]] || { p_fail "génération de password vide ($acct)"; return 1; }
  dir="$(dirname "$PROV_PASSWORDS_FILE")"
  tmp="$(umask 077 && mktemp "$dir/.pwd.XXXXXX")" || { p_fail "tmp passwords-file"; return 1; }
  if [[ -f "$PROV_PASSWORDS_FILE" ]]; then
    jq --arg a "$acct" --arg p "$pwd" '. + {($a): $p}' "$PROV_PASSWORDS_FILE" > "$tmp" || { rm -f "$tmp"; p_fail "merge passwords-file"; return 1; }
  else
    jq -n --arg a "$acct" --arg p "$pwd" '{($a): $p}' > "$tmp" || { rm -f "$tmp"; p_fail "init passwords-file"; return 1; }
  fi
  if ! { chmod 0600 "$tmp" && mv -f "$tmp" "$PROV_PASSWORDS_FILE"; }; then
    rm -f "$tmp"; p_fail "pose passwords-file"; return 1
  fi
  PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "password généré pour $acct → $PROV_PASSWORDS_FILE (0600, opérateur-only)"
}

ensure_account() { # $1=login — crée via l'API admin si absent
  local acct="$1" tok resp
  account_exists "$acct" && return 0
  if ! tok="$(admin_token)"; then
    p_fail "compte $acct absent et pas d'admin : pose PROV_FORGE_ADMIN_TOKEN_FILE (token site-admin lisible) pour créer les comptes"
    return 1
  fi
  # Le password n'est généré QUE pour un compte qu'ON crée. Un compte préexistant garde le sien :
  # l'inventer ici polluerait le passwords-file opérateur avec une valeur fausse (et le mint A4
  # échouerait) — si son token est invalide, c'est à l'opérateur de poser le VRAI password.
  ensure_password_entry "$acct" || return 1
  local pwd
  pwd="$(jq -r --arg a "$acct" '.[$a] // empty' "$PROV_PASSWORDS_FILE")"
  [[ -n "$pwd" ]] || { p_fail "password absent du passwords-file pour $acct (incohérence interne)"; return 1; }
  resp="$(curl -fsS -m 15 -X POST \
    -H "Authorization: token $tok" -H "Content-Type: application/json" \
    -d "$(jq -n --arg u "$acct" --arg p "$pwd" \
          '{username:$u, email:($u+"@lcars-fleet.local"), password:$p, must_change_password:false}')" \
    "$PROV_FORGE_URL/api/v1/admin/users" 2>&1)" || {
    p_fail "création du compte $acct refusée par la forge : $(printf '%s' "$resp" | head -c 200)"
    return 1
  }
  account_exists "$acct" || { p_fail "compte $acct toujours absent après POST (vérité re-sondée)"; return 1; }
  PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "compte $acct créé"
}

apply() {
  [[ -n "$PROV_FORGE_URL" ]] || { p_fail "FORGE_BASE_URL/PROV_FORGE_URL non posé"; verdict_apply; }
  forge_up || { p_fail "forge injoignable : $PROV_FORGE_URL"; verdict_apply; }
  [[ -x "$A4_SCRIPT" ]] || { p_fail "script A4 introuvable : $A4_SCRIPT"; verdict_apply; }

  local acct rc=0
  for acct in $ACCOUNTS; do
    ensure_account "$acct" || rc=1
  done
  [[ "$rc" -eq 0 ]] || verdict_apply

  # Délégation A4. D'abord la SONDE (--check) : si tout est déjà valide, aucun passwords-file
  # n'est requis (une machine re-provisionnée sur une forge saine ne doit exiger AUCUN secret).
  if "$A4_SCRIPT" --forge "$PROV_FORGE_URL" --tokens-dir "$PROV_TOKENS_DIR" \
      --roles "$PROV_ROLES" --extra-token "$PROV_SYSTEM_ACCOUNT:system.gitea_token" --check >/dev/null 2>&1; then
    p_ok "role-tokens déjà valides ($PROV_TOKENS_DIR)"
    verdict_apply
  fi
  # Des tokens manquent/sont morts → mode pose (mint basic-auth, exige le passwords-file).
  if [[ ! -r "$PROV_PASSWORDS_FILE" ]]; then
    p_fail "tokens à re-minter mais passwords-file illisible : $PROV_PASSWORDS_FILE — pose-y les passwords des comptes ({\"compte\":\"pwd\"}, 0600) et relance"
    verdict_apply
  fi
  if "$A4_SCRIPT" --forge "$PROV_FORGE_URL" --tokens-dir "$PROV_TOKENS_DIR" \
      --passwords-file "$PROV_PASSWORDS_FILE" --group "$PROV_FLEET_GROUP" \
      --roles "$PROV_ROLES" --extra-token "$PROV_SYSTEM_ACCOUNT:system.gitea_token"; then
    PROV_CHANGED=$((PROV_CHANGED + 1))
    p_chg "tokens A4 posés ($PROV_TOKENS_DIR)"
  else
    p_fail "provision-role-tokens.sh en échec (son verdict est au-dessus)"
  fi
  verdict_apply
}

case "${1:?usage: 50-forge.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
