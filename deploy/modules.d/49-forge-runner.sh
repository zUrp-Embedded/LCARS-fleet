#!/usr/bin/env bash
# SOURCE: deploy/modules.d/49-forge-runner.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-12
# STATUS: le runner CI de la forge du poste — enrôlé par deploy/docker/forge-runner.sh quand aucun runner n'est en ligne, ses enregistrements périmés retirés
# APPLY-ON: wsl linux
# CHECK-ON: wsl linux
# NEEDS: root
# AFTER: 10-packages 12-docker-engine 48-forge-host

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — ce module se joue par ./provision, pas nu}"

forge_fournie() { p_ok "forge fournie ($PROV_FORGE_URL) — son runner CI est à qui la tient ; cette installation n'en enrôle aucun"; }

advertise_addr
JOB_URL="$(job_forge_url "$PROV_FORGE_HOST_PORT" "$PROV_ADVERTISE")" || JOB_URL=""
SANS_ADRESSE="aucune adresse de cette machine ne joint la forge depuis un job CI (${PROV_ADVERTISE_WHY:-adresse annoncée : $PROV_ADVERTISE}) — le runner n'est pas enrôlé sur une adresse de loopback, qui désigne le conteneur du job lui-même"

RUNNERS=""
lire_runners() { # lire_runners → RUNNERS, la liste des runners de la forge en JSON ; rc 1 sans jeton lisible, sans réponse ou sans liste
  local body rc=0
  RUNNERS=""
  [[ -s "$PROV_MASTER_TOKEN_FILE" ]] || return 1
  body="$(mktemp "${TMPDIR:-/tmp}/forge-runners.XXXXXX")"
  if forge_api GET "$PROV_FORGE_URL/api/v1/admin/actions/runners" "$body" --token-file "$PROV_MASTER_TOKEN_FILE" -m 10 >/dev/null; then
    RUNNERS="$(jq -ce '.runners | arrays' "$body" 2>/dev/null)" || rc=1
  else
    rc=1
  fi
  rm -f "$body"
  return "$rc"
}
en_ligne() { jq '[.[] | select(.status != "offline")] | length' <<<"$RUNNERS"; }
# un réenrôlement enregistre un runner neuf sous le même nom : les enregistrements plus anciens, hors ligne, sont périmés
perimes() { jq -r 'group_by(.name)[] | (max_by(.id).id) as $neuf | .[] | select(.id != $neuf and .status == "offline") | .id' <<<"$RUNNERS"; }

runner_vise() { # runner_vise → l'adresse de forge qu'a reçue le runner de ce poste ; vide sans conteneur lisible
  env_field <("${PROV_DOCKER_BIN:-docker}" inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$PROV_RUNNER_PROJECT-act-1" 2>/dev/null) \
    GITEA_INSTANCE_URL
}

retirer_perimes() {
  local id
  while read -r id; do
    [[ -n "$id" ]] || continue
    if forge_api DELETE "$PROV_FORGE_URL/api/v1/admin/actions/runners/$id" /dev/null --token-file "$PROV_MASTER_TOKEN_FILE" -m 10 >/dev/null; then
      PROV_CHANGED=$((PROV_CHANGED + 1))
      p_chg "enregistrement périmé du runner retiré de la forge (id $id, hors ligne)"
    else
      p_warn "enregistrement périmé du runner non retiré (id $id, hors ligne) — la forge le liste encore"
    fi
  done < <(perimes)
}

converge_ci_runner() {
  [[ -n "$JOB_URL" ]] || { p_drift "$SANS_ADRESSE"; return 0; }
  [[ -s "$PROV_MASTER_TOKEN_FILE" ]] \
    || { p_warn "runner CI non enrôlable : aucun jeton master lisible ($PROV_MASTER_TOKEN_FILE)"; return 0; }
  # une liste illisible n'est pas une liste vide : forge-runner.sh remplacerait le runner existant
  lire_runners \
    || { p_warn "runner CI non mesurable (API muette ou réponse illisible) — rien n'est enrôlé sur une liste inconnue"; return 0; }
  local n vise
  n="$(en_ligne)"
  if [[ "$n" -gt 0 ]]; then
    vise="$(runner_vise)"
    if [[ -z "$vise" || "$vise" == "$JOB_URL" ]]; then
      p_ok "$n runner(s) CI en ligne — la CI de cette forge a une machine"
      retirer_perimes
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
  if [[ "$rc" -ne 0 ]]; then
    prov_dump_last
    p_drift "runner CI NON enrôlé (rc=$rc — le refus du délégué est au-dessus) — la CI restera en attente"
    return 0
  fi
  PROV_CHANGED=$((PROV_CHANGED + 1))
  p_chg "runner CI enrôlé — la forge du poste peut faire tourner sa CI"
  lire_runners && retirer_perimes
  return 0
}

check() {
  [[ "$PROV_FORGE_DU_POSTE" -eq 1 ]] || { forge_fournie; verdict_check; }
  if ! forge_up; then
    p_ok "forge du poste éteinte — le runner n'est pas mesurable, et son absence n'est pas une dérive"
    verdict_check
  fi
  [[ -n "$JOB_URL" ]] || { p_drift "$SANS_ADRESSE"; verdict_check; }
  if ! lire_runners; then
    p_warn "runner CI non mesurable (jeton master illisible ou API muette) — la CI peut être sans machine ; relancer sous sudo pour conclure"
    verdict_check
  fi
  local n vise perime
  n="$(en_ligne)"
  vise="$(runner_vise)"
  if [[ "$n" -eq 0 ]]; then
    p_drift "aucun runner CI en ligne — la CI acceptera des jobs que rien ne servira"
  elif [[ -n "$vise" && "$vise" != "$JOB_URL" ]]; then
    p_drift "le runner $PROV_RUNNER_PROJECT vise $vise, qu'un job n'atteint pas (attendu $JOB_URL) — l'apply le réenrôle"
  else
    p_ok "$n runner(s) CI en ligne — la CI de cette forge a une machine"
  fi
  perime="$(perimes | paste -sd' ' -)"
  [[ -z "$perime" ]] || p_drift "enregistrement(s) périmé(s) du runner sur la forge, hors ligne (id $perime) — l'apply les retire"
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

case "${1:-}" in check|apply) "$1" ;; *) p_die "mode inconnu: ${1:-} (check|apply)" ;; esac
