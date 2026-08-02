#!/usr/bin/env bash
# SOURCE: fleet/provisioning/deps/provision-forge-avatars.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-06
# STATUS: PROTO-V2 — pose des avatars de charte sur les comptes + l'org forge (frère cosmétique de forge.tf)
#
# POURQUOI CE SCRIPT (et pas du .tf) : le provider go-gitea/gitea n'expose AUCUN attribut avatar
# settable (juste org.avatar_url en lecture). L'avatar n'est pas de l'état convergent qu'on déclare —
# c'est un geste one-shot d'upload d'image. Il vit donc dans le MÊME seam que provision-role-tokens.sh :
# forge.tf pose la structure déclarative, ce script pose l'impératif cosmétique. Les deux tournent au
# stand-up de la forge, tous deux avec le master-token — indépendants du token-seam runtime.
#
# PRIVILÈGE : poser l'avatar d'un compte tiers passe par le master/admin-token + header `Sudo: <compte>`
# (Gitea fait agir l'admin AU NOM du compte ; vérifié 2026-07-06 : POST /user/avatar Sudo:engineer -> 204).
# Contrairement au mint de token (que Gitea refuse par header token → basic-auth obligatoire), l'avatar
# ACCEPTE le token admin — donc UN seul token suffit pour tous les comptes, sans leurs passwords.
# L'org, elle, se pose en direct (l'admin édite l'org) sans Sudo.
#
# IDEMPOTENCE PAR RÉASSERTION : on re-POST l'image de charte à chaque run (l'effet visible est stable —
# même image = même rendu). C'est VOULU : un run RÉ-ASSERTE la charte (si quelqu'un a changé un avatar à
# la main, le prochain run le remet). `--check` = sonde seule : PASS si le compte porte un avatar custom
# (hash long), FAIL s'il est resté sur l'identicon par défaut.
#
# USAGE :
#   FORGE_BASE_URL=http://localhost:3000 FORGE_ADMIN_TOKEN=<tok> provision-forge-avatars.sh
#   provision-forge-avatars.sh --forge URL --admin-token-file /root/forge/test/admin.token
#   provision-forge-avatars.sh --forge URL --admin-token-file … --check      # sonde seule
# Options : --avatars-dir DIR (défaut : <dir du script>/avatars) · --org NAME (défaut fleet ; --org "" pour
#           sauter l'org). Le mapping compte→fichier est une DONNÉE (tableau ENTRIES ci-dessous).
# EXIT : 0 = tout posé/valide · 1 = usage/dépendance · 2 = au moins une entrée en échec.

set -euo pipefail

FORGE="${FORGE_BASE_URL:-}"
ADMIN_TOKEN="${FORGE_ADMIN_TOKEN:-}"
ADMIN_TOKEN_FILE=""
AVATARS_DIR=""
ORG="fleet"
CHECK_ONLY=0

# Mapping compte→fichier (DONNÉE, pas cas spécial) : les rôles + starfleet portent leur avatar de
# charte ; lcars-system porte le favicon LCARS (identité système = la marque, pas un rôle métier).
# L'org `fleet` porte AUSSI le favicon (posée à part, endpoint distinct). L'humain n'est PAS listé : il
# pose son propre avatar (compte daily), on ne le décide pas pour lui.
declare -a ENTRIES=(
  "architect:architect.png"
  "engineer:engineer.png"
  "gatekeeper:gatekeeper.png"
  "qualifier:qualifier.png"
  "reviewer:reviewer.png"
  "scoper:scoper.png"
  "scribe:scribe.png"
  "vulcan:vulcan.png"
  "starfleet:starfleet.png"
  "lcars-system:favicon.png"
)

usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --forge) FORGE="$2"; shift 2 ;;
    --admin-token-file) ADMIN_TOKEN_FILE="$2"; shift 2 ;;
    --avatars-dir) AVATARS_DIR="$2"; shift 2 ;;
    --org) ORG="$2"; shift 2 ;;
    --check) CHECK_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "provision-forge-avatars: option inconnue: $1" >&2; usage >&2; exit 1 ;;
  esac
done

command -v curl >/dev/null || { echo "provision-forge-avatars: curl requis" >&2; exit 1; }
command -v jq   >/dev/null || { echo "provision-forge-avatars: jq requis" >&2; exit 1; }
command -v base64 >/dev/null || { echo "provision-forge-avatars: base64 requis" >&2; exit 1; }
[[ -n "$FORGE" ]] || { echo "provision-forge-avatars: --forge URL (ou FORGE_BASE_URL) requis" >&2; exit 1; }
FORGE="${FORGE%/}"
[[ -n "$AVATARS_DIR" ]] || AVATARS_DIR="$(cd "$(dirname "$0")" && pwd)/avatars"
[[ -d "$AVATARS_DIR" ]] || { echo "provision-forge-avatars: dossier avatars introuvable: $AVATARS_DIR" >&2; exit 1; }

# Le master-token n'est requis qu'en mode POSE (le --check lit des champs publics).
if [[ -n "$ADMIN_TOKEN_FILE" ]]; then
  [[ -r "$ADMIN_TOKEN_FILE" ]] || { echo "provision-forge-avatars: admin-token-file illisible: $ADMIN_TOKEN_FILE" >&2; exit 1; }
  ADMIN_TOKEN="$(tr -d '[:space:]' < "$ADMIN_TOKEN_FILE")"
fi
if [[ "$CHECK_ONLY" -eq 0 && -z "$ADMIN_TOKEN" ]]; then
  echo "provision-forge-avatars: mode pose sans autorité — FORGE_ADMIN_TOKEN ou --admin-token-file requis" >&2
  exit 1
fi

AUTH=(-H "Authorization: token $ADMIN_TOKEN")

# Un avatar custom uploadé porte un hash long (SHA256, 64 hex) ; l'identicon par défaut porte un hash
# court (32 hex). Heuristique de sonde (dépend de l'interne Gitea, mais stable en 1.26) : basename ≥ 40 hex.
avatar_is_custom() { # $1=avatar_url
  local base="${1##*/}"
  [[ "${#base}" -ge 40 ]]
}

# POST une image (base64) sur un endpoint. Corps JSON écrit en fichier temp (base64 volumineux → pas de
# -d inline fragile). Rend le code HTTP.
post_image() { # $1=url  $2=fichier_png  $3...=headers extra
  local url="$1" png="$2"; shift 2
  local tmp; tmp="$(mktemp)"
  printf '{"image":"%s"}' "$(base64 -w0 "$png")" > "$tmp"
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 20 -X POST "${AUTH[@]}" "$@" \
    -H "Content-Type: application/json" --data-binary @"$tmp" "$url")"
  rm -f "$tmp"
  printf '%s' "$code"
}

fail=0

for entry in "${ENTRIES[@]}"; do
  account="${entry%%:*}"
  file="$AVATARS_DIR/${entry#*:}"

  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    url="$(curl -s -m 10 "${AUTH[@]}" "$FORGE/api/v1/users/$account" | jq -r '.avatar_url // ""')"
    if avatar_is_custom "$url"; then echo "OK    $account — avatar custom"; else
      echo "FAIL  $account — pas d'avatar custom (identicon/défaut)" >&2; fail=1; fi
    continue
  fi

  [[ -r "$file" ]] || { echo "FAIL  $account — asset introuvable: $file" >&2; fail=1; continue; }
  code="$(post_image "$FORGE/api/v1/user/avatar" "$file" -H "Sudo: $account")"
  if [[ "$code" == "204" || "$code" == "201" ]]; then
    echo "POSÉ  $account — avatar de charte ($(basename "$file"))"
  else
    echo "FAIL  $account — POST avatar -> HTTP $code" >&2; fail=1
  fi
done

# L'ORG (endpoint distinct, sans Sudo — l'admin édite l'org). --org "" pour sauter.
if [[ -n "$ORG" ]]; then
  org_file="$AVATARS_DIR/favicon.png"
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    url="$(curl -s -m 10 "${AUTH[@]}" "$FORGE/api/v1/orgs/$ORG" | jq -r '.avatar_url // ""')"
    if avatar_is_custom "$url"; then echo "OK    org:$ORG — avatar custom"; else
      echo "FAIL  org:$ORG — pas d'avatar custom" >&2; fail=1; fi
  elif [[ -r "$org_file" ]]; then
    code="$(post_image "$FORGE/api/v1/orgs/$ORG/avatar" "$org_file")"
    if [[ "$code" == "204" || "$code" == "201" ]]; then echo "POSÉ  org:$ORG — favicon LCARS"; else
      echo "FAIL  org:$ORG — POST avatar -> HTTP $code" >&2; fail=1; fi
  else
    echo "FAIL  org:$ORG — favicon introuvable: $org_file" >&2; fail=1
  fi
fi

if [[ "$fail" -ne 0 ]]; then
  echo "provision-forge-avatars: AU MOINS UNE ENTRÉE EN ÉCHEC (forge $FORGE)" >&2
  exit 2
fi
echo "provision-forge-avatars: tous les avatars posés/valides sur $FORGE"
