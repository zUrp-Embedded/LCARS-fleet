#!/usr/bin/env bash
# SOURCE: deploy/modules.d/48-forge-host.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-12
# STATUS: la forge du poste — un conteneur Gitea monté (ou une forge fournie jointe), son administrateur, son jeton master, son seed
# APPLY-ON: wsl linux
# CHECK-ON: wsl linux
# NEEDS: root
# AFTER: 44-media
#
# FORGE_BASE_URL posée : la forge est fournie, rien n'est monté, docker n'est pas requis ; sinon
# (ou PROV_FORGE_MONTEE=1, ce que --bench pose) le conteneur est monté ici. Amorçage, jeton master,
# promotion de l'administrateur et seed sont les mêmes dans les deux cas.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — ce module se joue par ./provision, pas nu}"
# shellcheck source=../lib/forge-bootstrap.sh
. "$(dirname "$PROVISION_LIB")/forge-bootstrap.sh"

: "${PROV_FORGE_ADMIN:=$(prov_seat_from_map)}"
: "${PROV_FORGE_ADMIN:=$PROV_HUMAN}"
: "${PROV_DOCKER_BIN:=docker}"
: "${PROV_FORGE_BIND:=0.0.0.0}"
: "${PROV_FORGE_ADVERTISE:=}"
advertise_addr "${PROV_FORGE_ADVERTISE:-$PROV_FORGE_BIND}"
PROV_FORGE_ADVERTISE="$PROV_ADVERTISE"
PROV_FORGE_ADVERTISE_WHY="$PROV_ADVERTISE_WHY"

COMPOSE_FILE="$(repo_root)/deploy/docker/forge-compose.yml"
FORGE_SERVICE="$(sed -nE '/^services:/,/^[a-z]/{ s/^  ([a-z][a-z0-9_-]*):[[:space:]]*$/\1/p }' "$COMPOSE_FILE" 2>/dev/null | head -n1 || true)"
FORGE_CONTAINER="${PROV_FORGE_PROJECT}-${FORGE_SERVICE}-1"

# les adresses viennent de la lib ; l'adresse publique de la forge du poste s'écrit ici, d'où la lib la relit
if [[ "$PROV_FORGE_DU_POSTE" -eq 1 ]]; then
  PUBLIC_URL="http://${PROV_FORGE_ADVERTISE}:${PROV_FORGE_HOST_PORT}"
else
  PUBLIC_URL="$PROV_FORGE_PUBLIC_URL"
fi

d() { "$PROV_DOCKER_BIN" "$@"; }
docker_answers() { d ps --format '{{.ID}}' >/dev/null 2>&1; }

forge_service_known() {
  [[ -n "$FORGE_SERVICE" ]] && return 0
  p_fail "aucun service lisible dans $COMPOSE_FILE — le nom du conteneur et le filtre docker en dérivent tous les deux"
  return 1
}

forge_running_port() {
  d ps --filter "label=com.docker.compose.project=$PROV_FORGE_PROJECT" \
       --filter "label=com.docker.compose.service=$FORGE_SERVICE" \
       --format '{{.Ports}}' 2>/dev/null \
    | sed -n 's/.*:\([0-9]\{1,5\}\)->3000\/tcp.*/\1/p' | head -n1
}
forge_is_ours() { [[ "$(forge_running_port)" == "$PROV_FORGE_HOST_PORT" ]]; }

foreign_forge_refusal() {
  p_fail "une forge répond sur $PROV_FORGE_URL, mais aucun conteneur du projet « $PROV_FORGE_PROJECT » ne publie $PROV_FORGE_HOST_PORT — ce n'est pas la forge de cette machine"
  p_fail "  en monter une autre : « --port-forge <autre port> » (et « --forge-project <nom> » si le nom est pris lui aussi)"
}

forge_reach_note() {
  case "$PROV_FORGE_BIND" in
    127.0.0.1|localhost|::1) printf ' — cette machine seule' ;;
    *) printf ' — ouverte sur %s, composable en %s' "$PROV_FORGE_BIND" "$PUBLIC_URL"
       [[ -n "${PROV_FORGE_ADVERTISE_WHY:-}" ]] && printf ' (%s)' "$PROV_FORGE_ADVERTISE_WHY"
       return 0 ;;
  esac
}

new_password() { head -c 200 /dev/urandom | tr -dc 'A-Za-z' | cut -c1-10; }
announce_password() { # announce_password <login> <mot de passe>
  prov_announce_credential "forge du poste — compte d'administration" "$1" "$2"
}

reset_admin_password_if_asked() { # reset_admin_password_if_asked <0 si le compte vient d'être créé>
  [[ -n "${PROV_FORGE_ADMIN_RESET:-}" ]] || return 0
  [[ "${1:-1}" -ne 0 ]] || return 0
  local npw; npw="$(new_password)"
  if forge_admin_password "$PROV_DOCKER_BIN" "$FORGE_CONTAINER" "$PROV_FORGE_ADMIN" "$npw"; then
    PROV_CHANGED=$((PROV_CHANGED + 1))
    announce_password "$PROV_FORGE_ADMIN" "$npw"
  else
    p_fail "repose du mot de passe de « $PROV_FORGE_ADMIN » en échec — le compte garde l'ancien"
  fi
}

forge_admin_state() { # forge_admin_state <login> → admin | plain | absent | unknown
  local body code
  [[ -n "$(read_token "$PROV_MASTER_TOKEN_FILE")" ]] || { echo unknown; return 0; }
  body="$(mktemp "${TMPDIR:-/tmp}/forge-admin.XXXXXX")"
  code="$(forge_api GET "$PROV_FORGE_URL/api/v1/users/$1" "$body" --token-file "$PROV_MASTER_TOKEN_FILE" -m 10)" || true
  case "$code" in
    200) if jq -e '.is_admin == true' "$body" >/dev/null 2>&1; then echo admin; else echo plain; fi ;;
    404) echo absent ;;
    *)   echo unknown ;;
  esac
  rm -f "$body"
}

# la CLI gitea sait créer un administrateur, pas en promouvoir un : la promotion passe par l'API ;
# login_name et source_id sont exigés par l'endpoint, sans eux il rend 422
forge_promote_admin() { # forge_promote_admin <login>
  forge_api PATCH "$PROV_FORGE_URL/api/v1/admin/users/$1" /dev/null --token-file "$PROV_MASTER_TOKEN_FILE" \
    --json '{admin: true, login_name: $l, source_id: 0}' --arg l "$1" >/dev/null
}

seat_binding_report() { # seat_binding_report <check|apply>
  local mode="$1"
  prov_seat_binding "$PROV_FORGE_ADMIN"
  if [[ "$PROV_SEAT_BINDING" == diverge ]]; then
    p_drift "siège : « $PROV_FORGE_ADMIN » côté unix, « $PROV_SEAT_LOGIN » côté $PROV_SEAT_SOURCE — deux acteurs pour un rôle, le lien n'est pas enregistré tant qu'ils ne s'accordent pas"
    return 0
  fi
  local _carte _uid; _carte="$(prov_file_state "$PROV_UID_MAP_FILE")"
  _uid="$(id -u -- "$PROV_SEAT_LOGIN" 2>/dev/null || true)"
  if [[ -n "$(prov_seat_from_map)" ]]; then
    p_ok "siège : « $PROV_SEAT_LOGIN » enregistré ($PROV_UID_MAP_FILE, forge_id 1)"
  elif [[ "$_carte" != "present" && "$_carte" != "absent" ]]; then
    p_warn "siège : carte des uid $(prov_state_why "$_carte" "$PROV_UID_MAP_FILE") — rien n'est conclu sur l'enregistrement de « $PROV_SEAT_LOGIN »"
  elif [[ ! "$_uid" =~ ^[0-9]+$ ]]; then
    p_drift "siège : « $PROV_SEAT_LOGIN » n'a pas de compte sur cette machine — la carte des uid ne l'enregistre pas sans uid ; créer ce compte, ou désigner un compte existant par PROV_FORGE_ADMIN"
  elif [[ "$mode" != "apply" ]]; then
    p_drift "siège : « $PROV_SEAT_LOGIN » connu ($PROV_SEAT_SOURCE) mais non enregistré — l'apply pose la ligne"
  elif prov_seat_record "$PROV_SEAT_LOGIN" "$_uid"; then
    PROV_CHANGED=$((PROV_CHANGED + 1))
    p_chg "siège : « $PROV_SEAT_LOGIN » enregistré ($PROV_UID_MAP_FILE, forge_id 1)"
  else
    p_drift "siège : « $PROV_SEAT_LOGIN » non enregistré dans $PROV_UID_MAP_FILE"
  fi
}

check() {
  if [[ "$PROV_FORGE_DU_POSTE" -eq 1 ]]; then
    if ! docker_endpoint; then
      p_fail "$PROV_DOCKER_WHY — la forge du poste est un conteneur, il n'en existe aucune autre forme"
      verdict_check
    fi
    forge_service_known || verdict_check
    if forge_up && docker_answers && ! forge_is_ours; then
      foreign_forge_refusal
      verdict_check
    fi
  elif ! forge_up; then
    p_drift "forge fournie muette ($PROV_FORGE_URL) — c'est l'adresse de FORGE_BASE_URL ; cette installation ne la monte pas, elle la consomme"
    verdict_check
  fi
  if forge_up; then
    if [[ "$PROV_FORGE_DU_POSTE" -eq 1 ]]; then
      p_ok "forge du poste vivante ($PROV_FORGE_URL)$(forge_reach_note)"
    else
      p_ok "forge fournie vivante ($PROV_FORGE_URL) — montée ailleurs, structurée par cette installation"
    fi
    if [[ -s "$PROV_MASTER_TOKEN_FILE" ]]; then
      p_ok "autorité de création présente ($PROV_MASTER_TOKEN_FILE)"
    else
      p_drift "forge vivante mais aucune autorité ($PROV_MASTER_TOKEN_FILE) — l'apply la minte"
    fi
    seat_binding_report check
    case "$(forge_admin_state "$PROV_FORGE_ADMIN")" in
      admin)   p_ok "« $PROV_FORGE_ADMIN » administre la forge" ;;
      plain)   p_drift "« $PROV_FORGE_ADMIN » n'est pas administrateur de sa propre forge — l'apply le promeut" ;;
      absent)  p_drift "« $PROV_FORGE_ADMIN » n'a pas de compte sur cette forge — l'inscription est libre, elle se fait une fois" ;;
      *)       p_warn "adminité de « $PROV_FORGE_ADMIN » non mesurable (jeton absent ou forge muette)" ;;
    esac
  else
    p_drift "aucune forge sur $PROV_FORGE_URL — l'apply monte le conteneur et l'amorce, 61-forge-structure pose la structure"
  fi
  verdict_check
}

apply() {
  if [[ "$PROV_FORGE_DU_POSTE" -eq 1 ]]; then
    if ! docker_endpoint; then
      p_fail "$PROV_DOCKER_WHY — forge non montée, et elle ne peut pas l'être autrement"
      verdict_apply
    fi
    forge_service_known || verdict_apply
  elif ! forge_up; then
    p_fail "forge fournie muette ($PROV_FORGE_URL) — cette installation la consomme, elle ne la monte pas ; c'est à qui la tient de la relever"
    verdict_apply
  fi
  local was_up=0; forge_up && was_up=1

  if [[ "$PROV_FORGE_DU_POSTE" -eq 1 ]]; then
    if [[ "$was_up" -eq 1 ]] && docker_answers && ! forge_is_ours; then
      foreign_forge_refusal
      verdict_apply
    fi
    local _running; _running="$(forge_running_port)"
    if [[ -n "$_running" && "$_running" != "$PROV_FORGE_HOST_PORT" ]]; then
      p_fail "la forge du projet « $PROV_FORGE_PROJECT » tourne déjà sur le port $_running, et cette passe en demande $PROV_FORGE_HOST_PORT — elle n'est pas déplacée sans instruction"
      p_fail "  une seconde forge      : « --forge-project <nom> » (conteneur, réseau, volumes et runner à elle)"
      p_fail "  déplacer celle-ci      : « $PROV_DOCKER_BIN compose -p $PROV_FORGE_PROJECT down » d'abord, puis relancer"
      verdict_apply
    fi
    local etat; etat="$(port_state "$PROV_FORGE_HOST_PORT" "$PROV_FORGE_PROJECT")"
    if [[ "$was_up" -eq 0 && "$etat" == pris* ]]; then
      local holder; holder="${etat#pris}"; holder="${holder# par }"
      p_fail "port $PROV_FORGE_HOST_PORT déjà pris${holder:+ par $holder}, et ce n'est pas la forge de LCARS (elle ne répond pas sur $PROV_FORGE_URL)"
      p_fail "en choisir un autre : PROV_FORGE_HOST_PORT=<port> — ou libérer celui-ci"
      verdict_apply
    fi
    [[ "$was_up" -eq 1 ]] \
      || p_step "forge du poste : montage du conteneur Gitea (projet $PROV_FORGE_PROJECT, port $PROV_FORGE_HOST_PORT)"
    run_capture forge_mount "$PROV_DOCKER_BIN" "$COMPOSE_FILE" "$PROV_FORGE_PROJECT" "$PROV_FORGE_HOST_PORT" "$PROV_FORGE_BIND" "$PUBLIC_URL" \
      || { p_fail "la forge ne converge pas (compose -p $PROV_FORGE_PROJECT)"; prov_dump_last; verdict_apply; }
    forge_wait "$PROV_FORGE_URL" || { p_fail "forge montée mais muette sur $PROV_FORGE_URL après 120 s"; verdict_apply; }
  fi

  if [[ "$PROV_FORGE_DU_POSTE" -eq 0 ]]; then
    p_ok "forge fournie ($PROV_FORGE_URL) — rien à monter ; cette installation l'amorce, 61-forge-structure y pose la structure"
  elif [[ "$was_up" -eq 1 ]]; then
    p_ok "forge du poste vivante et convergée ($PROV_FORGE_URL)$(forge_reach_note)"
  else
    PROV_CHANGED=$((PROV_CHANGED + 1))
    p_chg "forge du poste montée ($PROV_FORGE_URL)$(forge_reach_note)"
  fi

  write_atomic "$PROV_FORGE_URL_FILE" 0644 "root:$PROV_FLEET_GROUP" <<<"$PROV_FORGE_URL" \
    || { p_fail "adresse de la forge non posée ($PROV_FORGE_URL_FILE)"; verdict_apply; }
  write_atomic "$PROV_FORGE_PUBLIC_URL_FILE" 0644 "root:$PROV_FLEET_GROUP" <<<"$PUBLIC_URL" \
    || { p_fail "adresse publique de la forge non posée ($PROV_FORGE_PUBLIC_URL_FILE)"; verdict_apply; }
  write_atomic "$PROV_FORGE_MODE_FILE" 0644 "root:$PROV_FLEET_GROUP" \
    <<<"$([[ "$PROV_FORGE_DU_POSTE" -eq 1 ]] && echo poste || echo fournie)" || verdict_apply

  [[ -s "$PROV_MASTER_TOKEN_FILE" ]] && reset_admin_password_if_asked 1
  # en banc, chaque passe repose le mot de passe du contrat
  if [[ "${LCARS_BENCH:-}" == "1" && "$PROV_FORGE_DU_POSTE" -eq 1 && -s "$PROV_MASTER_TOKEN_FILE" ]]; then
    if forge_admin_password "$PROV_DOCKER_BIN" "$FORGE_CONTAINER" "$PROV_FORGE_ADMIN" "$(bench_admiral_password)"; then
      announce_password "$PROV_FORGE_ADMIN" "$(bench_admiral_password)"
    else
      p_drift "banc : mot de passe de « $PROV_FORGE_ADMIN » non reposé (la forge a refusé) — le contrat du banc n'est pas tenu"
    fi
  fi

  if [[ "$PROV_FORGE_DU_POSTE" -eq 0 && ! -s "$PROV_MASTER_TOKEN_FILE" ]]; then
    p_drift "forge fournie sans autorité : y écrire un jeton master site-admin de cette forge dans $PROV_MASTER_TOKEN_FILE (0600, $PROV_AUTHORITY_USER), puis relancer"
    verdict_apply
  fi
  if [[ ! -s "$PROV_MASTER_TOKEN_FILE" ]]; then
    p_step "forge du poste : compte d'administration « $PROV_FORGE_ADMIN » et jeton master"
    local pw etat err preexistant=1
    if [[ "${LCARS_BENCH:-}" == "1" ]]; then pw="$(bench_admiral_password)"; else pw="$(new_password)"; fi
    err="$(mktemp "${TMPDIR:-/tmp}/forge-admin.XXXXXX")"
    etat="$(forge_admin_ensure "$PROV_DOCKER_BIN" "$FORGE_CONTAINER" "$PROV_FORGE_ADMIN" "$pw" 2>"$err")" || etat=refus
    case "$etat" in
      cree)
        preexistant=0; announce_password "$PROV_FORGE_ADMIN" "$pw" ;;
      present)
        if [[ "${LCARS_BENCH:-}" == "1" ]] && forge_admin_password "$PROV_DOCKER_BIN" "$FORGE_CONTAINER" "$PROV_FORGE_ADMIN" "$pw"; then
          preexistant=0; announce_password "$PROV_FORGE_ADMIN" "$pw"
        else
          p_ok "compte « $PROV_FORGE_ADMIN » déjà présent (son mot de passe est un hash, il n'est pas relisible)"
          p_warn "pour obtenir un mot de passe : « PROV_FORGE_ADMIN_RESET=1 » sur un apply en pose un neuf et l'affiche"
        fi ;;
      *)
        p_fail "création du compte « $PROV_FORGE_ADMIN » refusée par la forge : $(tr -d '\r' < "$err" | grep -v '^$' | tail -3 | tr '\n' ' ')"
        rm -f "$err"
        verdict_apply ;;
    esac
    rm -f "$err"
    reset_admin_password_if_asked "$preexistant"
    docker_stream_ok "$FORGE_CONTAINER" || {
      p_fail "le daemon docker répond aux lectures mais rend du vide sur « exec » — rien ne peut être capturé depuis $FORGE_CONTAINER ; un relais docker amputé (contexte, proxy) est en cause"
      verdict_apply
    }
    local tok
    tok="$(forge_master_token "$PROV_DOCKER_BIN" "$FORGE_CONTAINER" "$PROV_FORGE_ADMIN" "poste-$(date +%s)")" \
      || { p_fail "la forge n'a rendu aucun jeton master pour $PROV_FORGE_ADMIN"; verdict_apply; }
    write_atomic "$PROV_MASTER_TOKEN_FILE" 0600 "$PROV_AUTHORITY_USER:$PROV_AUTHORITY_USER" <<<"$tok" \
      || { p_fail "jeton master non posé ($PROV_MASTER_TOKEN_FILE)"; verdict_apply; }
    p_chg "autorité de création posée ($PROV_MASTER_TOKEN_FILE, $PROV_AUTHORITY_USER seul)"
  else
    p_ok "autorité de création déjà posée ($PROV_MASTER_TOKEN_FILE)"
  fi

  case "$(forge_admin_state "$PROV_FORGE_ADMIN")" in
    admin)
      p_ok "« $PROV_FORGE_ADMIN » administre la forge" ;;
    absent)
      p_warn "« $PROV_FORGE_ADMIN » n'a pas de compte sur cette forge — l'inscription est libre, elle se fait une fois puis ce module le promeut" ;;
    plain)
      if forge_promote_admin "$PROV_FORGE_ADMIN"; then
        PROV_CHANGED=$((PROV_CHANGED + 1))
        p_chg "« $PROV_FORGE_ADMIN » promu administrateur de la forge"
      else
        p_fail "« $PROV_FORGE_ADMIN » n'a pas pu être promu administrateur — le jeton master de $PROV_MASTER_TOKEN_FILE porte-t-il encore l'adminité ?"
      fi ;;
    *)
      p_warn "adminité de « $PROV_FORGE_ADMIN » non mesurable (forge muette ou jeton absent) — rien n'a été tenté" ;;
  esac

  # le seed ne se régénère pas : le provider n'écrit pas le mot de passe d'un compte existant, un seed neuf rendrait les jetons de rôle en 401
  if [[ ! -s "$PROV_FORGE_SEED_FILE" ]]; then
    local seed; seed="$(forge_seed_new)"
    [[ -n "$seed" ]] || { p_fail "seed non générable (/dev/urandom illisible ?)"; verdict_apply; }
    write_atomic "$PROV_FORGE_SEED_FILE" 0600 "$PROV_AUTHORITY_USER:$PROV_AUTHORITY_USER" <<<"$seed" \
      || { p_fail "seed non posé ($PROV_FORGE_SEED_FILE)"; verdict_apply; }
    p_chg "seed des comptes posé ($PROV_FORGE_SEED_FILE, $PROV_AUTHORITY_USER seul)"
  else
    p_ok "seed des comptes déjà posé ($PROV_FORGE_SEED_FILE)"
  fi

  seat_binding_report apply
  verdict_apply
}

case "${1:?usage: 48-forge-host.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
