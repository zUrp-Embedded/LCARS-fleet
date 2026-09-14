#!/usr/bin/env bash
# SOURCE: deploy/lib/forge-bootstrap.sh
# AUTHOR: bob
# STARDATE: 2026-09-12
# STATUS: l'amorçage d'une forge Gitea — montage, compte d'administration, jeton master, seed, humain de banc
#
# Sourcée après provision-lib.sh, par 48-forge-host et workstation (poste) et par le banc
# (conteneur) : une seule forme pour les deux. L'API passe par forge_api ; la CLI gitea reçoit le mot de passe par une
# variable transmise à docker exec (-e PW), gitea n'ayant pas d'entrée stdin pour un mot de passe.

: "${LCARS_BENCH_ADMIRAL_PW:=toto123456}"
: "${LCARS_BENCH_HUMAN_PW:=toto32toto32}"

bench_admiral_password() { printf '%s\n' "$LCARS_BENCH_ADMIRAL_PW"; }
bench_human_password()   { printf '%s\n' "$LCARS_BENCH_HUMAN_PW"; }

forge_mount() { # forge_mount <docker> <compose> <projet> <port> <bind> <url publique> [<base du banc>] — le banc empile sa surcouche marquée
  local docker="$1" compose="$2" projet="$3" port="$4" bind="$5" root="$6" banc="${7:-}"
  local -a fichiers=(-f "$compose")
  [[ -z "$banc" ]] || fichiers+=(-f "${compose%.yml}.bench.yml")
  LCARS_DEVFORGE_PORT="$port" LCARS_DEVFORGE_BIND="$bind" LCARS_DEVFORGE_ROOT_URL="${root%/}/" LCARS_BENCH_BASE="$banc" \
    "$docker" compose "${fichiers[@]}" -p "$projet" up -d
}

forge_wait() { # forge_wait <url> [essais] → 0 quand /api/v1/version répond
  local url="$1" essais="${2:-60}" i
  for ((i = 0; i < essais; i++)); do
    forge_repond "$url" 3 && return 0
    sleep 2
  done
  return 1
}

forge_admin_ensure() { # forge_admin_ensure <docker> <conteneur> <login> <mot de passe> → imprime « cree » ou « present »
  local docker="$1" conteneur="$2" login="$3" pw="$4" err rc=0
  err="$(mktemp "${TMPDIR:-/tmp}/forge-admin.XXXXXX")"
  PW="$pw" "$docker" exec -e PW -u git "$conteneur" sh -c \
      'gitea admin user create --username "$1" --password "$PW" --email "$1@lcars.local" --admin --must-change-password=false' \
      _ "$login" >/dev/null 2>"$err" || rc=$?
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

forge_admin_password() { # forge_admin_password <docker> <conteneur> <login> <mot de passe> — rotation
  local docker="$1" conteneur="$2" login="$3" pw="$4"
  PW="$pw" "$docker" exec -e PW -u git "$conteneur" sh -c \
      'gitea admin user change-password --username "$1" --password "$PW" --must-change-password=false' \
      _ "$login" >/dev/null 2>&1
}

forge_master_token() { # forge_master_token <docker> <conteneur> <login> [nom] → imprime le jeton
  local docker="$1" conteneur="$2" login="$3" nom="${4:-master-$(date +%s)}" tok
  tok="$("$docker" exec -u git "$conteneur" gitea admin user generate-access-token \
           --username "$login" --token-name "$nom" --scopes all --raw 2>/dev/null | tail -n1 | tr -d '[:space:]')"
  [[ -n "$tok" ]] || return 1
  printf '%s\n' "$tok"
}

forge_seed_new() { head -c 400 /dev/urandom | tr -dc 'A-Za-z0-9' | cut -c1-20; }

forge_token_ok() { # forge_token_ok <url> <fichier du jeton> → 0 si le jeton s'authentifie
  forge_api GET "$1/api/v1/user" /dev/null --token-file "$2" -m 5 >/dev/null
}

bench_human_seed() { # bench_human_seed <url> <fichier du jeton master> <humain> <mot de passe> [jeton posé] → mot de passe, site-admin, imprime un jeton opérateur
  # un jeton posé qui s'authentifie encore est rendu tel quel : chaque passe en minterait un de plus sur la forge
  local url="$1" tokfile="$2" humain="$3" pw="$4" pose="${5:-}" code is_admin body sha
  body="$(mktemp "${TMPDIR:-/tmp}/forge-bench.XXXXXX")"
  code="$(forge_api PATCH "$url/api/v1/admin/users/$humain" /dev/null --token-file "$tokfile" -m 10 \
            --json '{login_name: $l, source_id: 0, password: $pw, must_change_password: false, admin: true}' \
            --arg l "$humain" --rawfile pw <(printf '%s' "$pw"))" \
    || { echo "la forge refuse le compte « $humain » (HTTP $code)" >&2; rm -f "$body"; return 1; }
  forge_api GET "$url/api/v1/users/$humain" "$body" --token-file "$tokfile" -m 5 >/dev/null || true
  is_admin="$(jq -r '.is_admin' "$body" 2>/dev/null || echo "?")"
  [[ "$is_admin" == "true" ]] || { echo "« $humain » n'est pas site-admin après la promotion (is_admin=$is_admin)" >&2; rm -f "$body"; return 1; }
  forge_api GET "$url/api/v1/user" /dev/null --basic "$humain" <(printf '%s' "$pw") -m 5 >/dev/null \
    || { echo "« $humain » ne s'authentifie pas avec le mot de passe posé" >&2; rm -f "$body"; return 1; }
  if [[ -s "$pose" ]] && forge_token_ok "$url" "$pose"; then
    rm -f "$body"
    tr -d '[:space:]' < "$pose"; echo
    return 0
  fi
  : > "$body"   # sans réponse, curl laisse la sortie intacte : le corps lu serait celui de l'humain
  forge_api POST "$url/api/v1/users/$humain/tokens" "$body" --basic "$humain" <(printf '%s' "$pw") -m 10 \
    --json '{name: $n, scopes: ["write:repository", "write:issue", "read:organization", "read:user"]}' \
    --arg n "bench-operateur-$(date +%s)" >/dev/null || true
  sha="$(jq -r '.sha1 // empty' "$body" 2>/dev/null || true)"
  [[ -n "$sha" ]] || { echo "la forge n'a pas rendu de jeton opérateur pour « $humain » : $(head -c 300 "$body" 2>/dev/null || true)" >&2; rm -f "$body"; return 1; }
  rm -f "$body"
  printf '%s\n' "$sha"
}
