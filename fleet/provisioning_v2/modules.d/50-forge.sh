#!/usr/bin/env bash
# SOURCE: fleet/provisioning_v2/modules.d/50-forge.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — forge : SONDE de la structure (territoire OpenTofu) + jambe tokens (A4)
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root
#
# La forge n'est PAS installée ici (sidecar compose en Docker, app TrueNAS, service externe —
# créée par LE SYSTÈME, jamais par LCARS), et sa STRUCTURE n'est plus créée ici non plus :
# comptes/org/teams/hardening sont le territoire EXCLUSIF d'OpenTofu (forge.tf, arbitrage WS1 :
# « TF fait toute la STRUCTURE, bash SEULEMENT les tokens »). Ce module :
#   1. SONDE la structure (comptes de rôle + compte système, endpoint public) — absente, il
#      INSTRUIT le geste bootstrap (« ./docker.sh forge-bootstrap ») et n'exécute RIEN : même
#      famille de gestes d'identité que « claude /login », sondés et instruits, jamais faits ;
#   2. converge les TOKENS — délégués à fleet/runtime/etc/provision-role-tokens.sh (A4, une
#      seule mécanique de mint). Gitea n'accepte QUE la basic-auth pour minter (anti-escalade,
#      vérifié 2026-07-05) → passwords-file requis. S'il est absent mais que le SEED du
#      bootstrap est posé (PROV_FORGE_SEED_FILE = le TF_VAR_seed_password de tofu — les bots
#      le GARDENT : must_change_password=false dans forge.tf), le module le DÉRIVE :
#      {compte: seed} pour tous. Après le bootstrap unique, chaque apply converge donc les
#      tokens dans le MÊME cycle — plus aucun geste.
#
# Données : PROV_FORGE_URL (vide = instruct-only) · PROV_FORGE_SEED_FILE (défaut
# <tokens-dir>/forge-seed.pass, 0600 root, posé par le geste bootstrap) · PROV_PASSWORDS_FILE
# (défaut <tokens-dir>/forge-role-passwords.json — l'A4 durable, rejouable sur forge nuke).

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

: "${PROV_PASSWORDS_FILE:=$PROV_TOKENS_DIR/forge-role-passwords.json}"
A4_SCRIPT="$(repo_root)/fleet/runtime/etc/provision-role-tokens.sh"
ACCOUNTS="$PROV_ROLES $PROV_SYSTEM_ACCOUNT"

forge_up() { curl -fsS -m 10 -o /dev/null "$PROV_FORGE_URL/api/v1/version" 2>/dev/null; }

account_exists() { # $1=login — endpoint public en lecture (pas besoin d'admin pour SONDER)
  curl -fsS -m 10 -o /dev/null "$PROV_FORGE_URL/api/v1/users/$1" 2>/dev/null
}

missing_accounts() { # → la liste des comptes absents (vide = structure complète)
  # (nommé absents, pas « missing » : la lib a un array `missing` dans apt_ensure et
  # l'analyse -x confond les deux scopes — SC2178 parasite.)
  local acct absents=""
  for acct in $ACCOUNTS; do
    account_exists "$acct" || absents="$absents $acct"
  done
  printf '%s' "${absents# }"
}

# La sonde tokens EST le --check du script A4 (une seule vérité, pas une re-implémentation).
a4_check() {
  "$A4_SCRIPT" --forge "$PROV_FORGE_URL" --tokens-dir "$PROV_TOKENS_DIR" \
    --roles "$PROV_ROLES" --extra-token "$PROV_SYSTEM_ACCOUNT:system.gitea_token" --check >/dev/null 2>&1
}

# Le handoff tofu→A4 : {compte: seed} pour tous — dérivé, jamais demandé deux fois.
derive_passwords_file() {
  local seed tmp acct rc=0
  seed="$(tr -d '[:space:]' < "$PROV_FORGE_SEED_FILE")"
  [[ -n "$seed" ]] || { p_fail "seed vide : $PROV_FORGE_SEED_FILE"; return 1; }
  tmp="$(mktemp "${TMPDIR:-/tmp}/prov-pwd.XXXXXX")" || { p_fail "tmp passwords-file"; return 1; }
  if ! for acct in $ACCOUNTS; do printf '%s\n' "$acct"; done \
      | jq -R -n --arg s "$seed" '[inputs] | map({(.): $s}) | add' > "$tmp"; then
    rm -f "$tmp"; p_fail "dérivation jq du passwords-file"; return 1
  fi
  write_atomic "$PROV_PASSWORDS_FILE" 0600 root:root < "$tmp" || rc=1
  rm -f "$tmp"
  [[ "$rc" -eq 0 ]] || return 1
  p_ok "passwords-file dérivé du seed de bootstrap ($PROV_PASSWORDS_FILE)"
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

  local miss acct
  miss="$(missing_accounts)"
  if [[ -n "$miss" ]]; then
    p_drift "structure absente (comptes : $miss) — territoire OpenTofu, bootstrap requis : « ./docker.sh forge-bootstrap »"
  else
    for acct in $ACCOUNTS; do p_ok "compte $acct"; done
  fi

  if [[ -x "$A4_SCRIPT" ]]; then
    if a4_check; then
      p_ok "role-tokens valides (sonde A4 --check)"
    else
      p_drift "role-tokens absents/invalides (sonde A4 --check) — l'apply les re-mint"
    fi
  else
    p_fail "script A4 introuvable/inexécutable : $A4_SCRIPT (checkout incomplet ?)"
  fi
  verdict_check
}

apply() {
  # B6 : aligné sur le check — URL vide ou forge injoignable est un DRIFT dit, pas un échec.
  # L'apply (dont le boot Docker) converge le reste et DIT ce qui manque.
  if [[ -z "$PROV_FORGE_URL" ]]; then
    p_drift "FORGE_BASE_URL/PROV_FORGE_URL non posé — comptes/tokens forge non convergés (pose-le et relance)"
    verdict_apply
  fi
  if ! forge_up; then
    p_drift "forge injoignable : $PROV_FORGE_URL — tokens non convergés (relance quand elle répond)"
    verdict_apply
  fi
  [[ -x "$A4_SCRIPT" ]] || { p_fail "script A4 introuvable : $A4_SCRIPT"; verdict_apply; }

  local miss
  miss="$(missing_accounts)"
  if [[ -n "$miss" ]]; then
    # Territoire tofu : rien n'est exécutable ICI (geste d'identité bootstrap — instruit).
    p_drift "structure absente (comptes : $miss) — bootstrap requis : « ./docker.sh forge-bootstrap » (admin + tofu apply + seed)"
    verdict_apply
  fi

  if a4_check; then
    p_ok "role-tokens déjà valides ($PROV_TOKENS_DIR)"
    verdict_apply
  fi
  # Des tokens manquent/sont morts → mode pose (mint basic-auth, exige le passwords-file —
  # dérivé du seed de bootstrap si absent : le handoff qui met les tokens DANS le cycle).
  if [[ ! -r "$PROV_PASSWORDS_FILE" ]]; then
    if [[ -r "$PROV_FORGE_SEED_FILE" ]]; then
      derive_passwords_file || verdict_apply
    else
      p_drift "tokens à minter mais ni passwords-file ($PROV_PASSWORDS_FILE) ni seed ($PROV_FORGE_SEED_FILE) — pose le seed (geste 2 de « forge-bootstrap ») et relance"
      verdict_apply
    fi
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
