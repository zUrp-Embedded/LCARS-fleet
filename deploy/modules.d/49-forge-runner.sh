#!/usr/bin/env bash
# SOURCE: deploy/modules.d/49-forge-runner.sh
# AUTHOR: DrDree
# STARDATE: (posée par /push-github)
# STATUS: PROTO-V2 — le runner CI de la forge du POSTE : une forge que rien ne peut servir n'en est pas une
# APPLY-ON: wsl linux
# CHECK-ON: wsl linux
# NEEDS: root
# AFTER: 48-forge-host

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/provision-lib.sh
source "$HERE/../lib/provision-lib.sh"

LOCAL_URL="$PROV_FORGE_URL"

# ⚠ PAS DE LABEL `elixir`, ET C'EST DÉLIBÉRÉ. Le servir honnêtement exigerait `lcars-build`, une
# image LOCALE que ce rail ne construit pas ; le servir avec l'image Elixir de base donnerait un
# runner qui prend le job du gate et meurt sur `git` introuvable — vert à l'écran, faux au fond.
: "${PROV_RUNNER_LABELS:=shell:docker://alpine:3.20,dood:docker://docker:cli,ubuntu-latest:docker://catthehacker/ubuntu:act-latest}"

ci_runner_count() { # rend le nombre de runners, ou vide si la forge ne repond pas
  local body
  [[ -s "$PROV_MASTER_TOKEN_FILE" ]] || return 1
  body="$(forge_curl "$PROV_MASTER_TOKEN_FILE" -s -m 10 "$LOCAL_URL/api/v1/admin/actions/runners" 2>/dev/null || true)"
  [[ -n "$body" ]] || return 1
  printf '%s' "$body" | jq -r '.total_count // empty' 2>/dev/null
}

converge_ci_runner() {
  local n
  n="$(ci_runner_count || true)"
  if [[ "${n:-0}" -gt 0 ]]; then
    p_ok "$n runner(s) CI déjà enregistré(s) — la CI de cette forge a une machine"
    return 0
  fi
  [[ -s "$PROV_MASTER_TOKEN_FILE" && -r "$PROV_MASTER_TOKEN_FILE" ]] \
    || { p_warn "runner CI non enrôlable : aucun jeton master lisible ($PROV_MASTER_TOKEN_FILE)"; return 0; }

  # ⚠ LA SONDE SE JOUE ICI, ET SON ABSENCE PASSAIT UNE CLI VIDE. `PROV_DOCKER_BIN` naît vide et
  # chaque module est un processus a lui : celle de `48-forge-host` ne traverse pas. Sans cette
  # ligne, le delegue retombait sur un `docker` nu — introuvable dans une VM WSL — et refusait
  # trois images PRESENTES sur le daemon (banc WSL, 2026-08-30). Sur un Linux natif le PATH le
  # portait : le defaut n'y etait pas visible.
  if ! docker_endpoint; then
    p_warn "runner CI non enrolable : $PROV_DOCKER_WHY"
    return 0
  fi
  p_step "forge du poste : enrôlement du runner CI (projet $PROV_RUNNER_PROJECT, réseau $PROV_FORGE_NET)"

  # ⚠ PAS `run_quiet` ICI, ET POUR DEUX RAISONS QUI SE CUMULENT. (1) Il imprime la COMMANDE quand
  # elle échoue — donc tout secret passé en argument ressort dans la trace et dans le fichier de
  # capture qu'il conserve. (2) Il émet déjà `p_fail`, ce qui ferait DEUX verdicts pour un seul
  # fait et rendrait l'apply en `1` (échec) là où le contrat veut `2` (appliqué, drift résiduel).
  local out rc=0
  out="$(mktemp "${TMPDIR:-/tmp}/forge-runner.XXXXXX")"
  # `DOCKER_BIN` porte la CLI RÉSOLUE — sur ce substrat elle vit dans le montage Docker Desktop et
  # peut être un shim d'escalade. Laisser le délégué chercher « docker » dans le PATH le ferait
  # échouer sur une machine parfaitement saine : rien n'installe docker dans une VM WSL.
  DOCKER_BIN="$PROV_DOCKER_BIN" \
    bash "$(repo_root)/deploy/docker/forge-runner.sh" \
      --forge-api "$LOCAL_URL/api/v1" --admin-token-file "$PROV_MASTER_TOKEN_FILE" \
      --network "$PROV_FORGE_NET" --project "$PROV_RUNNER_PROJECT" \
      ${PROV_RUNNER_LABELS:+--labels "$PROV_RUNNER_LABELS"} \
      ${PROV_RUNNER_ACCEPT_GENERIC:+--accept-generic} \
      >"$out" 2>&1 || rc=$?

  if [[ "$rc" -eq 0 ]]; then
    rm -f "$out"
    PROV_CHANGED=$((PROV_CHANGED + 1))
    p_chg "runner CI enrôlé — la forge du poste peut faire tourner sa CI"
    prov_journal_note posed_docker "$PROV_RUNNER_PROJECT"
    return 0
  fi

  sed 's/^/     /' "$out" >&2
  rm -f "$out"
  # PAS un échec du module : la forge est debout et utilisable, et le verdict de `50-forge` dira
  # que la CI n'a pas de machine. Un apply qui MEURT ici rendrait une forge saine inatteignable.
  p_drift "runner CI NON enrôlé (rc=$rc — le refus du délégué est au-dessus) — la CI restera en attente"
}


check() {
  if ! curl -fsS -m 5 -o /dev/null "$LOCAL_URL/api/v1/version" 2>/dev/null; then
    p_ok "forge du poste éteinte — le runner n'est pas mesurable, et son absence n'est pas une dérive"
    verdict_check
  fi
  local n; n="$(ci_runner_count || true)"
  if [[ -z "$n" ]]; then
    # ⚠ CE VERDICT DISAIT LUI-MEME QU'IL NE SAVAIT PAS, ET IL ETAIT CLASSE DRIFT. Le bon motif est
    # dix lignes plus haut, dans ce meme fichier : « forge éteinte — le runner n'est pas mesurable,
    # et son absence n'est pas une dérive ». Un drift promet qu'`apply` converge ; ici on n'a MEME
    # PAS mesuré, donc il n'y a rien a converger — mesure du 2026-09-01 sur le banc 2001, ou ce
    # drift apparaissait sans sudo et disparaissait avec.
    p_warn "runner CI non mesurable (jeton master illisible ou API muette) — la CI peut être sans machine ; relance sous sudo pour conclure"
  elif [[ "$n" -gt 0 ]]; then
    p_ok "$n runner(s) CI enregistré(s) — la CI de cette forge a une machine"
  else
    p_drift "aucun runner CI — la CI acceptera des jobs que rien ne servira"
  fi
  verdict_check
}

apply() {
  if ! curl -fsS -m 5 -o /dev/null "$LOCAL_URL/api/v1/version" 2>/dev/null; then
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
