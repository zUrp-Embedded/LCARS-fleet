#!/usr/bin/env bash
# SOURCE: fleet/provisioning_v2/deps/provision-forge-avatars.sh
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
#
# ⚠ CETTE LISTE N'EST PAS UN ROSTER, et ne doit pas le devenir. Elle porte un mapping compte→IMAGE :
# chaque entrée existe parce qu'un PNG de charte existe pour elle. La dériver du catalogue produirait
# une boucle qui échoue sur chaque rôle tiers — un rôle qu'on n'a pas dessiné n'a pas d'avatar, et
# c'est normal. C'est l'inverse qui devait bouger : un compte de CETTE liste absent de la forge visée
# n'est plus un échec (mesuré sur le catalogue web — six 404 d'affilée, un provisionnement correct
# rendu rouge par des comptes qui n'avaient aucune raison d'exister).
declare -a ENTRIES=(
  "system_architect:architect.png"
  "fleet_engineer:engineer.png"
  "system_gatekeeper:gatekeeper.png"
  "fleet_qualifier:qualifier.png"
  "fleet_reviewer:reviewer.png"
  "fleet_scoper:scoper.png"
  "fleet_scribe:scribe.png"
  "fleet_vulcan:vulcan.png"
  # Cote COMPTE : le LOGIN (`<catalogue>_<role>`). Cote IMAGE : le ROLE — une charte pointe des
  # FICHIERS, et un PNG ne se derive pas d'un nom. C'est pourquoi cette table reste tenue a la main
  # la ou les trois autres listes de roles sont desormais derivees du catalogue.
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

# ⚠ LE JETON ADMIN NE PASSE PLUS PAR argv, ET C'EST UNE PROPRIETE QUE L'APPELANT PAYAIT DEJA.
# `avatars.tf` la declare noir sur blanc : « le master-token passe par l'ENVIRONNEMENT, jamais par la
# ligne de commande : un argument est visible dans la table des processus ». Ce script la defaisait a
# son premier `curl` — `AUTH=(-H "Authorization: token $ADMIN_TOKEN")` met le jeton dans
# `/proc/<pid>/cmdline`, lisible par tout le monde pendant la requete. Et ce jeton-la est un
# SITE-ADMIN : avec `Sudo:`, il agit au nom de n'importe quel compte.
#
# `curl -K -` lit sa configuration sur STDIN : ni argv, ni fichier a creer/chmoder/supprimer. Meme
# geste que `etc/provision-role-tokens.sh` (6-141), applique ici a un credential plus puissant.
# La valeur est ECHAPPEE, pas esperee propre : la config de curl est un format cite.
curl_cfg_escape() { # $1=valeur
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  printf '%s' "$v"
}

AUTH_CFG="header = \"Authorization: token $(curl_cfg_escape "$ADMIN_TOKEN")\""

# Un seul point de passage vers curl : l'auth arrive par stdin, les options par argv. Ecrire
# `printf … | curl -K -` a chaque site laisserait la porte ouverte au prochain qui ajoute un appel.
forge_curl() { printf '%s\n' "$AUTH_CFG" | curl -K - "$@"; }

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
  code="$(forge_curl -s -o /dev/null -w '%{http_code}' -m 20 -X POST "$@" \
    -H "Content-Type: application/json" --data-binary @"$tmp" "$url")"
  rm -f "$tmp"
  printf '%s' "$code"
}

fail=0
skipped=0

# Le compte existe-t-il sur CETTE forge ? Un catalogue metier different n'a pas les memes roles, et
# poser un avatar sur un compte absent n'est pas un echec de provisionnement : c'est une entree de
# charte sans destinataire. Le distinguer demande le code HTTP, pas le corps — un 404 rend du JSON
# parfaitement lisible, donc `jq` seul ne verrait aucune difference.
account_exists() { # $1=compte
  local code
  code="$(forge_curl -s -o /dev/null -w '%{http_code}' -m 10 "$FORGE/api/v1/users/$1")"
  [[ "$code" == "200" ]]
}

for entry in "${ENTRIES[@]}"; do
  account="${entry%%:*}"
  file="$AVATARS_DIR/${entry#*:}"

  if ! account_exists "$account"; then
    echo "IGNORE $account — compte absent de cette forge (autre catalogue metier) : rien a poser"
    skipped=$((skipped + 1))
    continue
  fi

  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    url="$(forge_curl -s -m 10 "$FORGE/api/v1/users/$account" | jq -r '.avatar_url // ""')"
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
    url="$(forge_curl -s -m 10 "$FORGE/api/v1/orgs/$ORG" | jq -r '.avatar_url // ""')"
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

# Le compte des ignores est DIT, jamais tu : un provisionnement qui couvre trois entrees sur dix doit
# le montrer, sinon « tous les avatars poses » ment par omission sur ce qu'il a couvert.
note=""
[[ "$skipped" -gt 0 ]] && note=" ($skipped entree(s) de charte sans compte sur cette forge — ignorees)"

# ⚠ « TOUS LES AVATARS POSES » ETAIT UNE PHRASE PLUS LARGE QUE CE QU'ELLE COUVRAIT (6-115). Elle est
# vraie de LA CHARTE — chaque entree de la table a ete posee — et un lecteur y entend « chaque compte
# de la forge a une tete ». Ce sont deux populations differentes : `chief` a un compte et un jeton,
# et aucune entree ici, donc aucun avatar, sous un verdict qui disait le contraire.
#
# La table N'EST PAS un roster et ne doit pas le devenir (voir son propre commentaire, plus haut :
# la deriver echouerait sur chaque role tiers qu'on n'a pas dessine). Ce qui se corrige n'est donc
# pas la table, c'est la PORTEE de la phrase : elle dit desormais SUR QUOI elle porte, et combien.
# Un compte sans entree de charte reste invisible d'ici — mais plus personne ne lit « tous ».
couvert="${#ENTRIES[@]}"

if [[ "$fail" -ne 0 ]]; then
  echo "provision-forge-avatars: AU MOINS UNE ENTRÉE EN ÉCHEC (forge $FORGE)$note" >&2
  exit 2
fi
echo "provision-forge-avatars: $couvert entrée(s) de charte posées/valides sur $FORGE$note (la charte est une table tenue à la main : un compte hors table n'a pas d'avatar et n'est pas compté ici)"
