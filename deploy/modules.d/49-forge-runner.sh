#!/usr/bin/env bash
# SOURCE: deploy/modules.d/49-forge-runner.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-12
# STATUS: le runner CI de la forge du poste — enrôlé par deploy/docker/forge-runner.sh quand la forge n'en a aucun
# APPLY-ON: wsl linux
# CHECK-ON: wsl linux
# NEEDS: root
# AFTER: 10-packages 12-docker-engine 48-forge-host

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — ce module se joue par ./provision, pas nu}"

ci_runner_count() { # ci_runner_count → le nombre de runners enregistrés, ou 1 si la forge ne répond pas
  local body rc=0
  [[ -s "$PROV_MASTER_TOKEN_FILE" ]] || return 1
  body="$(mktemp "${TMPDIR:-/tmp}/forge-runners.XXXXXX")"
  if forge_api GET "$PROV_FORGE_URL/api/v1/admin/actions/runners" "$body" --token-file "$PROV_MASTER_TOKEN_FILE" -m 10 >/dev/null; then
    jq -er '.total_count' "$body" 2>/dev/null || rc=1
  else
    rc=1
  fi
  rm -f "$body"
  return "$rc"
}

forge_fournie() { p_ok "forge fournie ($PROV_FORGE_URL) — son runner CI est à qui la tient ; cette installation n'en enrôle aucun"; }

JOB_URL="$(job_forge_url "$PROV_FORGE_HOST_PORT")"

runner_vise() { # runner_vise → l'adresse de forge qu'a reçue le runner de ce poste ; vide sans conteneur lisible
  env_field <("${PROV_DOCKER_BIN:-docker}" inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$PROV_RUNNER_PROJECT-act-1" 2>/dev/null) \
    GITEA_INSTANCE_URL
}

converge_ci_runner() {
  local n vise
  [[ -s "$PROV_MASTER_TOKEN_FILE" ]] \
    || { p_warn "runner CI non enrôlable : aucun jeton master lisible ($PROV_MASTER_TOKEN_FILE)"; return 0; }
  # un compte illisible n'est pas zéro : forge-runner.sh remplacerait le runner existant
  n="$(ci_runner_count)" \
    || { p_warn "runner CI non mesurable (API muette ou réponse illisible) — rien n'est enrôlé sur un compte inconnu"; return 0; }
  if [[ "$n" -gt 0 ]]; then
    vise="$(runner_vise)"
    if [[ -z "$vise" || "$vise" == "$JOB_URL" ]]; then
      p_ok "$n runner(s) CI déjà enregistré(s) — la CI de cette forge a une machine"
      return 0
    fi
    p_step "le runner $PROV_RUNNER_PROJECT vise $vise, qu'un job n'atteint pas : réenrôlé sur $JOB_URL"
  fi
  if ! docker_endpoint; then
    p_warn "runner CI non enrôlable : $PROV_DOCKER_WHY"
    return 0
  fi
  p_step "forge du poste : enrôlement du runner CI (projet $PROV_RUNNER_PROJECT, réseau $PROV_FORGE_NET)"
  local rc=0
  DOCKER_BIN="$PROV_DOCKER_BIN" \
    run_capture bash "$(repo_root)/deploy/docker/forge-runner.sh" \
      --forge-api "$PROV_FORGE_URL/api/v1" --admin-token-file "$PROV_MASTER_TOKEN_FILE" --instance-url "$JOB_URL" \
      --network "$PROV_FORGE_NET" --project "$PROV_RUNNER_PROJECT" \
      --labels "$PROV_RUNNER_LABELS" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    PROV_CHANGED=$((PROV_CHANGED + 1))
    p_chg "runner CI enrôlé — la forge du poste peut faire tourner sa CI"
    return 0
  fi
  prov_dump_last
  p_drift "runner CI NON enrôlé (rc=$rc — le refus du délégué est au-dessus) — la CI restera en attente"
}

check() {
  [[ "$PROV_FORGE_DU_POSTE" -eq 1 ]] || { forge_fournie; verdict_check; }
  if ! forge_up; then
    p_ok "forge du poste éteinte — le runner n'est pas mesurable, et son absence n'est pas une dérive"
    verdict_check
  fi
  local n vise; n="$(ci_runner_count || true)"
  [[ -z "$n" || "$n" -eq 0 ]] || vise="$(runner_vise)"
  if [[ -z "$n" ]]; then
    p_warn "runner CI non mesurable (jeton master illisible ou API muette) — la CI peut être sans machine ; relancer sous sudo pour conclure"
  elif [[ -n "${vise:-}" && "$vise" != "$JOB_URL" ]]; then
    p_drift "le runner $PROV_RUNNER_PROJECT vise $vise, qu'un job n'atteint pas (attendu $JOB_URL) — l'apply le réenrôle"
  elif [[ "$n" -gt 0 ]]; then
    p_ok "$n runner(s) CI enregistré(s) — la CI de cette forge a une machine"
  else
    p_drift "aucun runner CI — la CI acceptera des jobs que rien ne servira"
  fi
  verdict_check
}

apply() {
  [[ "$PROV_FORGE_DU_POSTE" -eq 1 ]] || { forge_fournie; verdict_apply; }
  if ! forge_up; then
    p_warn "forge du poste éteinte — enrôlement du runner reporté (48 la monte)"
    verdict_apply
  fi
  converge_ci_runner
  verdict_apply
}

case "${1:?usage: 49-forge-runner.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
