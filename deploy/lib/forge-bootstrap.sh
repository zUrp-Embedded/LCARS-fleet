#!/usr/bin/env bash
# SOURCE: deploy/lib/forge-bootstrap.sh
# AUTHOR: bob
# STARDATE: 2026-09-12
# STATUS: l'amorçage d'une forge Gitea — montage, compte d'administration, jeton master, seed, humain de banc
#
# Sourcée par 48-forge-host (poste) et par le banc (conteneur) : une seule forme pour les deux.
# Les secrets passent par stdin (curl -K -) ou par l'environnement de docker exec, jamais par argv.
#
#   forge_mount <docker> <compose> <projet> <port> <bind> <url publique>   compose up -d
#   forge_wait <url> [essais]                                              0 quand /api/v1/version répond
#   forge_admin_ensure <docker> <conteneur> <login> <mot de passe>         imprime « cree » ou « present »
#   forge_admin_password <docker> <conteneur> <login> <mot de passe>       rotation
#   forge_master_token <docker> <conteneur> <login> [nom]                  imprime le jeton
#   forge_seed_new                                                         imprime un seed
#   forge_token_ok <url> <jeton>                                           0 si le jeton s'authentifie
#   bench_human_seed <url> <jeton> <humain> <mot de passe>                 mot de passe, site-admin, imprime un jeton opérateur
#   bench_admiral_password                                                 le mot de passe de l'amiral en banc
#   bench_human_password                                                   le mot de passe de l'humain en banc

: "${LCARS_BENCH_ADMIRAL_PW:=toto123456}"
: "${LCARS_BENCH_HUMAN_PW:=toto32toto32}"

bench_admiral_password() { printf '%s\n' "$LCARS_BENCH_ADMIRAL_PW"; }
bench_human_password()   { printf '%s\n' "$LCARS_BENCH_HUMAN_PW"; }

forge_mount() {
  local docker="$1" compose="$2" projet="$3" port="$4" bind="$5" root="$6"
  LCARS_DEVFORGE_PORT="$port" LCARS_DEVFORGE_BIND="$bind" LCARS_DEVFORGE_ROOT_URL="${root%/}/" \
    "$docker" compose -f "$compose" -p "$projet" up -d
}

forge_wait() {
  local url="${1%/}" essais="${2:-60}" i
  for ((i = 0; i < essais; i++)); do
    curl -fsS -m 3 -o /dev/null "$url/api/v1/version" 2>/dev/null && return 0
    sleep 2
  done
  curl -fsS -m 3 -o /dev/null "$url/api/v1/version" 2>/dev/null
}

forge_admin_ensure() {
  local docker="$1" conteneur="$2" login="$3" pw="$4" err rc=0
  err="$(mktemp "${TMPDIR:-/tmp}/forge-admin.XXXXXX")"
  "$docker" exec -u git "$conteneur" gitea admin user create \
      --username "$login" --password "$pw" --email "$login@lcars.local" \
      --admin --must-change-password=false >/dev/null 2>"$err" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    rm -f "$err"; echo cree; return 0
  fi
  if grep -qiE 'already exist|user already|login name.*taken' "$err" 2>/dev/null; then
    rm -f "$err"; echo present; return 0
  fi
  tr -d '\r' < "$err" | grep -v '^$' | tail -3 >&2
  rm -f "$err"
  return 1
}

forge_admin_password() {
  local docker="$1" conteneur="$2" login="$3" pw="$4"
  "$docker" exec -u git "$conteneur" gitea admin user change-password \
      --username "$login" --password "$pw" --must-change-password=false >/dev/null 2>&1
}

forge_master_token() {
  local docker="$1" conteneur="$2" login="$3" nom="${4:-master-$(date +%s)}" tok
  tok="$("$docker" exec -u git "$conteneur" gitea admin user generate-access-token \
           --username "$login" --token-name "$nom" --scopes all --raw 2>/dev/null | tail -n1 | tr -d '[:space:]')"
  [[ -n "$tok" ]] || return 1
  printf '%s\n' "$tok"
}

forge_seed_new() { head -c 18 /dev/urandom | base64 | tr -d '/+=' | cut -c1-20; }

forge_token_ok() {
  local url="${1%/}"
  printf 'header = "Authorization: token %s"\n' "$2" | curl -K - -fsS -m 5 -o /dev/null "$url/api/v1/user" 2>/dev/null
}

bench_human_seed() {
  local url="${1%/}" tok="$2" humain="$3" pw="$4" code is_admin resp sha
  code="$(printf 'header = "Authorization: token %s"\nheader = "Content-Type: application/json"\nrequest = "PATCH"\ndata = "{\\"login_name\\":\\"%s\\",\\"source_id\\":0,\\"password\\":\\"%s\\",\\"must_change_password\\":false,\\"admin\\":true}"\n' \
             "$tok" "$humain" "$pw" \
           | curl -K - -s -m 10 -o /dev/null -w '%{http_code}' "$url/api/v1/admin/users/$humain" 2>/dev/null || echo 000)"
  [[ "$code" == 200 ]] || { echo "la forge refuse le compte « $humain » (HTTP $code)" >&2; return 1; }
  is_admin="$(printf 'header = "Authorization: token %s"\n' "$tok" \
              | curl -K - -s -m 5 "$url/api/v1/users/$humain" 2>/dev/null \
              | python3 -c 'import json,sys; print(json.load(sys.stdin).get("is_admin"))' 2>/dev/null || echo "?")"
  [[ "$is_admin" == "True" ]] || { echo "« $humain » n'est pas site-admin après la promotion (is_admin=$is_admin)" >&2; return 1; }
  printf 'user = "%s:%s"\n' "$humain" "$pw" \
    | curl -K - -s -m 5 -o /dev/null -f "$url/api/v1/user" 2>/dev/null \
    || { echo "« $humain » ne s'authentifie pas avec le mot de passe posé" >&2; return 1; }
  resp="$(printf 'user = "%s:%s"\nheader = "Content-Type: application/json"\nrequest = "POST"\ndata = "{\\"name\\":\\"bench-operateur-%s\\",\\"scopes\\":[\\"write:repository\\",\\"write:issue\\",\\"read:organization\\",\\"read:user\\"]}"\n' \
            "$humain" "$pw" "$(date +%s)" \
          | curl -K - -s -m 10 "$url/api/v1/users/$humain/tokens" 2>/dev/null || true)"
  sha="$(printf '%s' "$resp" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("sha1",""))
except Exception: print("")' 2>/dev/null || true)"
  [[ -n "$sha" ]] || { echo "la forge n'a pas rendu de jeton opérateur pour « $humain » : ${resp:-<corps vide>}" >&2; return 1; }
  printf '%s\n' "$sha"
}
