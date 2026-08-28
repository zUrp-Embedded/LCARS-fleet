#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/49-forge-runner.sh
# AUTHOR: DrDree
# STARDATE: (posée par /push-github)
# STATUS: PROTO-V2 — le runner CI de la forge du POSTE : une forge que rien ne peut servir n'en est pas une
# APPLY-ON: wsl linux
# CHECK-ON: wsl linux
# NEEDS: root
#
# ─── POURQUOI CE MODULE EXISTE SÉPARÉMENT ───────────────────────────────────────────────────────
#
# Il vivait dans `48-forge-host`, qui portait six métiers en 1029 lignes : le port, l'adminité, les
# deux adresses, le runner, les mots de passe, le siège. Le runner n'en partageait que deux valeurs
# — le réseau de la forge et son adresse — et les deux sont désormais DÉRIVÉES dans `provision-lib`
# (`PROV_FORGE_NET`) ou POSÉES sur disque par 48 (`forge.url` → `PROV_FORGE_URL`). Aucune recopie.
#
# Le sortir rend son état OBSERVABLE SEUL : son `check` était noyé dans celui de la forge, et un
# opérateur qui voulait savoir « ma CI a-t-elle une machine ? » lisait un verdict qui parlait d'autre
# chose. Le numéro `49` porte l'ordre : après la forge, dont il consomme le réseau et l'adresse.
#
# ⚠ LE RUNNER EST UN ÉTAT-CIBLE DE CE RAIL, PAS UN SUPPLÉMENT. Une forge sans lui accepte un ticket,
# dépense un producteur, ouvre une PR — et la CI attend une machine qui n'existe pas.
#
# ⚠ UN SEUL MÉCANISME D'ENRÔLEMENT. `docker/forge-runner.sh` le porte en entier — jeton
# d'enregistrement par l'API admin, config des jobs, montage du compose — avec ses cicatrices
# (portée du jeton, réseau des jobs, `docker cp` plutôt que bind). Il est entièrement paramétré : on
# l'APPELLE. Un second exemplaire divergerait du premier sur la première cicatrice qu'on ne
# recopierait pas.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/provision-lib.sh
source "$HERE/../lib/provision-lib.sh"

# L'adresse LOCALE de la forge, posée par 48 dans `forge.url` et relue par la lib. On ne la
# recompose pas : deux dérivations du même fait divergent le jour où le port bouge.
LOCAL_URL="$PROV_FORGE_URL"

# ⚠ TROIS LABELS, TOUS PUBLICS, ET C'EST CE QUI REND CE RAIL AUTONOME. Ils couvrent les `runs-on`
# des workflows livrés — `shell` (deps-upstream, template projet), `dood` (publish, qui fait du
# docker), `ubuntu-latest` (le gate, et le `runs-on` que tout workflow importé écrit). Le runner
# tire chaque image lui-même : rien à bâtir, rien à semer.
#
# ⚠ PAS DE LABEL `elixir`, ET C'EST DÉLIBÉRÉ. Le servir honnêtement exigerait `lcars-build`, une
# image LOCALE que ce rail ne construit pas ; le servir avec l'image Elixir de base donnerait un
# runner qui prend le job du gate et meurt sur `git` introuvable — vert à l'écran, faux au fond.
# Le gate n'en a plus besoin : il s'installe son BEAM dans le job (`erlef/setup-beam`).
# Annoncer un label qu'on ne sait pas servir est pire que ne pas l'annoncer.
: "${PROV_RUNNER_LABELS:=shell:docker://alpine:3.20,dood:docker://docker:cli,ubuntu-latest:docker://catthehacker/ubuntu:act-latest}"

ci_runner_count() { # rend le nombre de runners, ou vide si la forge ne repond pas
  local tok body
  tok="$( { tr -d '[:space:]' < "$PROV_MASTER_TOKEN_FILE" || true; } 2>/dev/null )"
  [[ -n "$tok" ]] || return 1
  body="$(printf 'header = "Authorization: token %s"\n' "$tok" \
          | curl -K - -s -m 10 "$LOCAL_URL/api/v1/admin/actions/runners" 2>/dev/null || true)"
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
  # On teste la LISIBILITÉ du fichier, on n'en lit pas le contenu : le délégué le lira lui-même.
  # Un secret qu'on ne met pas dans une variable ne peut être recopié nulle part par accident.
  [[ -s "$PROV_MASTER_TOKEN_FILE" && -r "$PROV_MASTER_TOKEN_FILE" ]] \
    || { p_warn "runner CI non enrôlable : aucun jeton master lisible ($PROV_MASTER_TOKEN_FILE)"; return 0; }

  p_step "forge du poste : enrôlement du runner CI (projet $PROV_RUNNER_PROJECT, réseau $PROV_FORGE_NET)"

  # ⚠ PAS `run_quiet` ICI, ET POUR DEUX RAISONS QUI SE CUMULENT. (1) Il imprime la COMMANDE quand
  # elle échoue — donc tout secret passé en argument ressort dans la trace et dans le fichier de
  # capture qu'il conserve. (2) Il émet déjà `p_fail`, ce qui ferait DEUX verdicts pour un seul
  # fait et rendrait l'apply en `1` (échec) là où le contrat veut `2` (appliqué, drift résiduel).
  #
  # Le jeton part par CHEMIN (`--admin-token-file`) : `/proc` de l'hôte ne le voit pas pendant
  # l'appel, et rien ne peut le recopier dans une trace.
  local out rc=0
  out="$(mktemp "${TMPDIR:-/tmp}/forge-runner.XXXXXX")"
  # `DOCKER_BIN` porte la CLI RÉSOLUE — sur ce substrat elle vit dans le montage Docker Desktop et
  # peut être un shim d'escalade. Laisser le délégué chercher « docker » dans le PATH le ferait
  # échouer sur une machine parfaitement saine : rien n'installe docker dans une VM WSL.
  DOCKER_BIN="$PROV_DOCKER_BIN" \
    bash "$(repo_root)/fleet/deploy/docker/forge-runner.sh" \
      --forge-api "$LOCAL_URL/api/v1" --admin-token-file "$PROV_MASTER_TOKEN_FILE" \
      --network "$PROV_FORGE_NET" --project "$PROV_RUNNER_PROJECT" \
      ${PROV_RUNNER_LABELS:+--labels "$PROV_RUNNER_LABELS"} \
      ${PROV_RUNNER_ACCEPT_GENERIC:+--accept-generic} \
      >"$out" 2>&1 || rc=$?

  if [[ "$rc" -eq 0 ]]; then
    rm -f "$out"
    PROV_CHANGED=$((PROV_CHANGED + 1))
    p_chg "runner CI enrôlé — la forge du poste peut faire tourner sa CI"
    # Meme raison qu'en 48 : le nom du projet se derive, l'uninstall le lit dans le journal.
    prov_journal_note posed_docker "$PROV_RUNNER_PROJECT"
    return 0
  fi

  # La sortie du délégué SANS la ligne de commande : c'est elle qui dit pourquoi, et elle seule.
  sed 's/^/     /' "$out" >&2
  rm -f "$out"
  # PAS un échec du module : la forge est debout et utilisable, et le verdict de `50-forge` dira
  # que la CI n'a pas de machine. Un apply qui MEURT ici rendrait une forge saine inatteignable.
  p_drift "runner CI NON enrôlé (rc=$rc — le refus du délégué est au-dessus) — la CI restera en attente"
}

# LE VERDICT DIT SUR QUOI ELLE ÉCOUTE, parce que c'est la seule chose qu'un opérateur ne peut pas
# deviner en la voyant répondre en local. Une forge ouverte au réseau et une forme fermée rendent
# le même `200` sur la loopback.

check() {
  # ⚠ LA FORGE D'ABORD : sans elle, l'absence de runner n'est pas une dérive de CE module. Un
  # verdict qui accuse le runner quand la forge est éteinte envoie chercher au mauvais endroit.
  if ! curl -fsS -m 5 -o /dev/null "$LOCAL_URL/api/v1/version" 2>/dev/null; then
    p_ok "forge du poste éteinte — le runner n'est pas mesurable, et son absence n'est pas une dérive"
    verdict_check
  fi
  local n; n="$(ci_runner_count || true)"
  if [[ -z "$n" ]]; then
    p_drift "runner CI non mesurable (jeton master illisible ou API muette) — la CI peut être sans machine"
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
