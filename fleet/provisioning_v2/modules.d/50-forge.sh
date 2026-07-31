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

# Le handoff tofu→A4, convergent PAR ENTRÉE : chaque compte de $ACCOUNTS a son entrée dans le
# passwords-file. Fichier absent → dérivé entier depuis le seed ; rôle AJOUTÉ après bootstrap →
# entrée manquante complétée depuis le seed (l'ajout de rôle converge dans le cycle — la
# dérivation fichier-entier ratait ce cas, attrapé au premier ajout réel : scoper). Les entrées
# existantes ne sont JAMAIS réécrites (un password tourné à la main reste sien).
ensure_passwords_entries() {
  local acct absents=()
  for acct in $ACCOUNTS; do
    if ! { [[ -r "$PROV_PASSWORDS_FILE" ]] && jq -e --arg a "$acct" 'has($a)' "$PROV_PASSWORDS_FILE" >/dev/null 2>&1; }; then
      absents+=("$acct")
    fi
  done
  [[ "${#absents[@]}" -eq 0 ]] && return 0
  if [[ ! -r "$PROV_FORGE_SEED_FILE" ]]; then
    p_drift "entrées passwords manquantes (${absents[*]}) et pas de seed ($PROV_FORGE_SEED_FILE) — pose le seed (geste 2 de « forge-bootstrap ») ou complète $PROV_PASSWORDS_FILE, puis relance"
    return 1
  fi
  local seed tmp rc=0
  seed="$(tr -d '[:space:]' < "$PROV_FORGE_SEED_FILE")"
  [[ -n "$seed" ]] || { p_fail "seed vide : $PROV_FORGE_SEED_FILE"; return 1; }
  tmp="$(mktemp "${TMPDIR:-/tmp}/prov-pwd.XXXXXX")" || { p_fail "tmp passwords-file"; return 1; }
  if ! { [[ -r "$PROV_PASSWORDS_FILE" ]] && cat "$PROV_PASSWORDS_FILE" || printf '{}'; } \
      | jq --arg s "$seed" '. + ($ARGS.positional | map({(.): $s}) | add)' --args "${absents[@]}" > "$tmp"; then
    rm -f "$tmp"; p_fail "complétion jq du passwords-file"; return 1
  fi
  write_atomic "$PROV_PASSWORDS_FILE" 0600 root:root < "$tmp" || rc=1
  rm -f "$tmp"
  [[ "$rc" -eq 0 ]] || return 1
  p_ok "passwords-file complété depuis le seed (entrées : ${absents[*]})"
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

  check_human_onboardable
  verdict_check
}

# L'HUMAIN sur la forge — ce que le runtime exige à l'onboarding d'un projet, sondé ICI plutôt
# que découvert par un pod au milieu d'un create_project ({:human_not_provisioned, …} puis
# {:human_team_unverifiable, …}, vécus au premier E2E docker). L'appartenance se sonde au
# niveau ORG (204/404, lisible par le token système) et non au niveau TEAM : `GET
# /teams/<id>/members/<u>` est 403 pour lui — Gitea réserve la lecture d'une team à ses membres
# et aux owners, et le système n'est NI l'un NI l'autre (choix forge.tf, blast-radius borné).
check_human_onboardable() {
  local tokfile="$PROV_TOKENS_DIR/system.gitea_token" tok code
  if ! account_exists "$PROV_HUMAN"; then
    p_drift "compte forge absent pour l'humain « $PROV_HUMAN » — l'onboarding projet échouera (human_not_provisioned) : ajoute-le à TF_VAR_human_username et « tofu apply »"
    return 0
  fi
  p_ok "compte forge de l'humain ($PROV_HUMAN)"
  [[ -r "$tokfile" ]] || { p_drift "token système illisible ($tokfile) — appartenance de $PROV_HUMAN à l'org $PROV_FORGE_ORG non sondable"; return 0; }
  tok="$(tr -d '[:space:]' < "$tokfile")"
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 10 -H "Authorization: token $tok" \
          "$PROV_FORGE_URL/api/v1/orgs/$PROV_FORGE_ORG/members/$PROV_HUMAN" 2>/dev/null || true)"
  case "$code" in
    204) p_ok "$PROV_HUMAN membre de l'org $PROV_FORGE_ORG (sonde du token système)" ;;
    404) p_drift "$PROV_HUMAN N'EST PAS membre de l'org $PROV_FORGE_ORG — l'onboarding projet le refusera ; ajoute-le à la team humans (forge.tf) et « tofu apply »" ;;
    *)   p_drift "appartenance de $PROV_HUMAN à l'org $PROV_FORGE_ORG non vérifiable (HTTP $code) — scope du token système ?" ;;
  esac
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
  # Des tokens manquent/sont morts → mode pose (mint basic-auth). Le passwords-file converge
  # PAR ENTRÉE depuis le seed — fichier absent OU rôle ajouté après bootstrap, même chemin.
  ensure_passwords_entries || verdict_apply
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
