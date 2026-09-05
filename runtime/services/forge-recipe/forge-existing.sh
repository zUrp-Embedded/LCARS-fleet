#!/usr/bin/env bash
# SOURCE: runtime/services/forge-recipe/forge-existing.sh
# AUTHOR: drdree
# STARDATE: 2026-08-16
# STATUS: existence source feeding the `import` blocks of both recipe modules
#
# WHY THIS EXISTS, AND WHY IT CANNOT BE A DATA SOURCE. The gitea provider does not enumerate
# accounts, and its per-object data sources FAIL on a missing object instead of returning nothing --
# which is precisely the case this has to describe. Same shell seam as the role tokens and the
# charte, for the same reason: the provider does not expose the call.
#
# AND THE SET MUST BE EXACT. An `import` block naming an absent object is a hard error
# (`user not found with id 9999`, measured 2026-08-16), not a no-op. So the import set cannot be
# "everything the recipe declares" -- it has to be the intersection with what the forge carries.
#
# CONTRACT -- the `external` data source protocol. A JSON object arrives on stdin; a FLAT JSON
# object of string->string must leave on stdout, and NOTHING else may reach stdout. Anything else,
# on either stream, is reported by tofu as a failure of the whole plan.
#
#   in : {"gitea_url":…, "org":…, "users":"a,b,c", "teams":"x,y"}
#   out: {"user:a":"13", "org:fleet":"10", "team:x":"4"}    -- only what EXISTS
#
# THE IDS ARE NUMERIC BECAUSE THE PROVIDER MAKES THEM SO: it converts an import id to an integer,
# so importing by login fails with `user not found with id 0` (measured 2026-08-16). A login is a
# name, not an address.

set -euo pipefail

command -v curl >/dev/null || { echo "forge-existing: curl requis" >&2; exit 1; }
command -v jq   >/dev/null || { echo "forge-existing: jq requis" >&2; exit 1; }

QUERY="$(cat)"
q() { printf '%s' "$QUERY" | jq -r --arg k "$1" '.[$k] // ""'; }

FORGE="$(q gitea_url)"; FORGE="${FORGE%/}"
ORG="$(q org)"
USERS="$(q users)"
TEAMS="$(q teams)"

[[ -n "$FORGE" ]] || { echo "forge-existing: gitea_url manquant dans la requete" >&2; exit 1; }

# THE TOKEN NEVER TRAVELS IN THE QUERY, and that is not a style choice: `data.external` prints its
# query in the plan output, so a token placed there would be shown to whoever runs `tofu plan` and
# kept in the plan file. It travels by ENVIRONMENT instead -- `TF_VAR_gitea_token` is already the
# channel every caller of this recipe uses to hand tofu the same secret, so reading it here adds no
# new requirement on the caller. `FORGE_ADMIN_TOKEN` comes first: it is the name the charte seam
# already uses, and an explicit export must win over the ambient one.
#
# NO FILE PATH HERE, deliberately. The durable home of the master token is `container config`'s
# business, and whoever launches the apply reads it from there and exports it -- one channel, taken
# by every caller. A second one, taken by none, is a branch nobody exercises and nobody tests.
TOKEN="${FORGE_ADMIN_TOKEN:-${TF_VAR_gitea_token:-}}"

# argv is world-readable through /proc while the request runs; `curl -K -` reads its configuration
# from stdin instead. Same gesture as `provision-forge-charte.sh` (6-141bis), and the value is
# ESCAPED rather than hoped clean -- curl's config is a quoted format.
curl_cfg_escape() { local v="$1"; v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; printf '%s' "$v"; }
AUTH_CFG=""
[[ -n "$TOKEN" ]] && AUTH_CFG="header = \"Authorization: token $(curl_cfg_escape "$TOKEN")\""

# One single door to curl. `-K -` with an empty config is a valid anonymous call, so the
# authenticated and anonymous paths are the same code -- no second call site to keep in sync.
forge_curl() { printf '%s\n' "$AUTH_CFG" | curl -sS -K - -m 15 "$@"; }

# Reads one object and prints its numeric id, or nothing when the forge says 404. Any OTHER status
# is fatal: a 500 or a connection reset silently read as "absent" would make tofu try to create what
# already exists, and the 409 would land far from its cause.
probe_id() { # $1=api path  $2=label for the error message
  local body code
  body="$(forge_curl -w '\n%{http_code}' "$FORGE/api/v1/$1")" || {
    echo "forge-existing: la forge ne repond pas ($2)" >&2; exit 1; }
  code="${body##*$'\n'}"
  body="${body%$'\n'*}"
  case "$code" in
    200) printf '%s' "$body" | jq -r '.id' ;;
    404) : ;;
    *)   echo "forge-existing: HTTP $code sur $2 -- ni present ni absent, on refuse de conclure" >&2
         exit 1 ;;
  esac
}

OUT=()
add() { OUT+=("$(jq -cn --arg k "$1" --arg v "$2" '{($k): $v}')"); }

# ─── users ───────────────────────────────────────────────────────────────────────────────────────
# `/users/<login>` is PUBLIC (measured: 200 anonymous, 404 on an absent login), so this half needs no
# authority at all. That matters for the bootstrap: the system token is minted DURING the apply, so
# it does not exist yet the first time this runs.
if [[ -n "$USERS" ]]; then
  IFS=',' read -r -a _users <<< "$USERS"
  for u in "${_users[@]}"; do
    [[ -n "$u" ]] || continue
    id="$(probe_id "users/$u" "user $u")"
    [[ -n "$id" ]] && add "user:$u" "$id"
  done
fi

# ─── org ─────────────────────────────────────────────────────────────────────────────────────────
# Also public. And an org IS a user to Gitea -- which is why an apply against an existing forge
# fails on the org with `user already exists [name: fleet]` and not with an org-specific message.
ORG_ID=""
if [[ -n "$ORG" ]]; then
  ORG_ID="$(probe_id "orgs/$ORG" "org $ORG")"
  [[ -n "$ORG_ID" ]] && add "org:$ORG" "$ORG_ID"
fi

# ─── teams ───────────────────────────────────────────────────────────────────────────────────────
# The ONLY call here that needs authority (401 anonymous, measured). And it is the one place where
# returning an empty set would be a lie with consequences: tofu would then try to create teams that
# exist and take a 409 at apply time, far from here. So a missing authority on an EXISTING org is
# fatal, loudly. On an absent org the question does not arise -- no org, no teams.
if [[ -n "$TEAMS" && -n "$ORG_ID" ]]; then
  # `limit=100` EST une borne, donc elle doit se DIRE quand on la touche. Une troncature muette
  # rendrait un ensemble d'existence incomplet, tofu tenterait de creer des teams qui existent, et
  # le 409 tomberait a l'apply — loin d'ici, sur un motif qui ne nomme pas la borne. Cinq teams
  # aujourd'hui ; ce refus est pour la forge de quelqu'un d'autre.
  body="$(forge_curl -w '\n%{http_code}' "$FORGE/api/v1/orgs/$ORG/teams?limit=100")" \
    || { echo "forge-existing: la forge ne repond pas (teams de $ORG)" >&2; exit 1; }
  code="${body##*$'\n'}"; body="${body%$'\n'*}"
  case "$code" in
    200) : ;;
    401|403) echo "forge-existing: l'org $ORG existe et ses teams ne sont pas lisibles (HTTP $code)." >&2
             echo "  Cette lecture EXIGE une autorite -- exporte TF_VAR_gitea_token (ou" >&2
             echo "  FORGE_ADMIN_TOKEN) avec le master token de la forge." >&2
             exit 1 ;;
    *)   echo "forge-existing: HTTP $code sur les teams de $ORG -- on refuse de conclure" >&2
         exit 1 ;;
  esac
  n_teams="$(printf '%s' "$body" | jq -r 'length' 2>/dev/null || echo 0)"
  if [[ "$n_teams" -ge 100 ]]; then
    echo "forge-existing: l'org $ORG porte >= 100 teams — la lecture est peut-etre TRONQUEE, et un" >&2
    echo "  ensemble d'existence incomplet ferait echouer l'apply en 409, loin d'ici." >&2
    exit 1
  fi
  IFS=',' read -r -a _teams <<< "$TEAMS"
  for t in "${_teams[@]}"; do
    [[ -n "$t" ]] || continue
    id="$(printf '%s' "$body" | jq -r --arg n "$t" 'map(select(.name == $n)) | .[0].id // empty')"
    [[ -n "$id" ]] && add "team:$t" "$id"
  done
fi

# `jq -s add` on an empty list yields `null`, which is not a map -- tofu would reject it. The empty
# case is the NOMINAL one on a virgin forge, so it gets its own literal rather than a guard nobody
# exercises.
if [[ ${#OUT[@]} -eq 0 ]]; then
  printf '{}\n'
else
  printf '%s\n' "${OUT[@]}" | jq -sc 'add'
fi
