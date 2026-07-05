#!/usr/bin/env bash
# SOURCE: etc/provision-role-tokens.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — pose idempotente des role-tokens forge (fix A4) : mint + écriture <dir>/<role>.gitea_token + vérification
#
# LE trou A4 (vécu live 2026-07-05) : les tokens des comptes de rôle (architect, engineer, qualifier,
# reviewer, gatekeeper, consultant, vulcan) n'avaient AUCUN script de pose. Conséquence : un humain
# NEUF ne peut pas faire tourner la chaîne (create_issue signe as-architect → 401), la « réinstall
# 10 min » est une prétention, et le jeu de tokens vivant n'existe que dans l'env privé du premier
# opérateur. Ce script EST le mécanisme : il mint les tokens sur UNE forge et les écrit dans UN
# dossier (un jeu par forge — cf. FORGE_ROLE_TOKENS_DIR côté runtime), rejouable à l'infini.
#
# PRIVILÈGE (doctrine POSIX minimum, rien de maison) : minter le token d'un compte exige la BASIC
# AUTH de ce compte (`--passwords-file`). ⚠ Gitea REFUSE la création de token par header token —
# même un token site-admin, même sur soi-même (`POST /users/{u}/tokens` → "auth required" ; vérifié
# starfleet 2026-07-05). Il n'existe donc PAS de voie « admin-token » équivalente : un opérateur qui
# n'a que le token admin doit d'abord poser un password (`PATCH /admin/users/{u}`) PUIS basic-auth —
# hors scope de ce script (surface + non-idempotent). Le password est un SCALPEL (fichier
# opérateur-only) : ce script se lance UNE fois par un privilégié ; le runtime, lui, ne lit que les
# fichiers posés (0640, groupe fleet). Le script n'invente aucun privilège : il échoue proprement
# s'il n'a pas le sien.
#
# IDEMPOTENCE (provisioning brutal) : un token local DÉJÀ VALIDE sur la forge → skip (aucune
# écriture). Invalide/absent → l'ancien token remote du même nom est supprimé puis re-minté, le
# fichier est réécrit. Appliquer N fois = appliquer 1 fois. `--check` = vérification seule
# (exit≠0 si un token est invalide) — c'est la sonde du futur nuke-drill.
#
# USAGE :
#   provision-role-tokens.sh --forge URL --passwords-file /root/roles.json \
#       --extra-token lcars-system:system.gitea_token        # les 7 rôles + le token système = A4 complet
#   provision-role-tokens.sh --forge URL --check             # sonde seule (nuke-drill)
# Options : --tokens-dir DIR (défaut /home/private) · --roles "a b c" (défaut : les 7) ·
#           --extra-token COMPTE:FICHIER (répétable — pour un token où le compte ≠ le nom de fichier,
#             ex. le système `lcars-system:system.gitea_token`) · --group GRP (défaut fleet) ·
#           --token-name NAME (défaut lcars-fleet)
# passwords-file : JSON {"engineer":"pwd",...} OU {"engineer":{"password":"pwd"},...} (le compte système
#   y a sa clé, ex. "lcars-system"). Clé insensible à la casse (Gitea résout les comptes
#   case-insensitive : `Architect` matche le rôle `architect`).
# EXIT : 0 = toutes entrées posées/valides · 1 = usage/dépendance · 2 = au moins une entrée en échec.

set -euo pipefail

FORGE="${FORGE_BASE_URL:-}"
TOKENS_DIR="/home/private"
ROLES="architect consultant engineer gatekeeper qualifier reviewer vulcan"
GROUP="fleet"
TOKEN_NAME="lcars-fleet"
SCOPES="write:repository,write:issue,write:user"
PASSWORDS_FILE=""
CHECK_ONLY=0
# Tokens hors-rôle où le compte ≠ le nom de fichier (le mapping est une DONNÉE, pas un cas spécial) :
# le token SYSTÈME est le compte `lcars-system` mais le runtime lit `system.gitea_token`. Rempli par
# `--extra-token <compte>:<fichier>` (répétable). Sans lui, A4 laisse le system token en geste manuel.
declare -a EXTRA_ENTRIES

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --forge) FORGE="$2"; shift 2 ;;
    --tokens-dir) TOKENS_DIR="$2"; shift 2 ;;
    --roles) ROLES="$2"; shift 2 ;;
    --group) GROUP="$2"; shift 2 ;;
    --token-name) TOKEN_NAME="$2"; shift 2 ;;
    --passwords-file) PASSWORDS_FILE="$2"; shift 2 ;;
    --extra-token)
      [[ "$2" == *:* ]] || { echo "provision-role-tokens: --extra-token attend <compte>:<fichier> (reçu: $2)" >&2; exit 1; }
      EXTRA_ENTRIES+=("$2"); shift 2 ;;
    --check) CHECK_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "provision-role-tokens: option inconnue: $1" >&2; usage >&2; exit 1 ;;
  esac
done

command -v curl >/dev/null || { echo "provision-role-tokens: curl requis" >&2; exit 1; }
command -v jq >/dev/null || { echo "provision-role-tokens: jq requis" >&2; exit 1; }
[[ -n "$FORGE" ]] || { echo "provision-role-tokens: --forge URL (ou FORGE_BASE_URL) requis" >&2; exit 1; }
FORGE="${FORGE%/}"

# En mode POSE, la basic auth (passwords-file) est requise — seule voie que Gitea accepte pour créer
# un token (cf. header : le token admin ne peut PAS minter).
if [[ "$CHECK_ONLY" -eq 0 && -z "$PASSWORDS_FILE" ]]; then
  echo "provision-role-tokens: mode pose sans autorité — --passwords-file requis (--check pour sonder seul)" >&2
  exit 1
fi
if [[ -n "$PASSWORDS_FILE" && ! -r "$PASSWORDS_FILE" ]]; then
  echo "provision-role-tokens: passwords-file illisible: $PASSWORDS_FILE (lance avec le privilège qui le lit)" >&2
  exit 1
fi

# Sonde de validité d'un token : GET /user AVEC ce token. 200 = valide. (Les tokens mintés ici
# portent write:user ⊃ read:user → /user répond ; un 401/403 = invalide/scopé-ailleurs → re-pose.)
token_valid() { # $1=token
  [[ "$(curl -s -o /dev/null -w '%{http_code}' -m 10 -H "Authorization: token $1" "$FORGE/api/v1/user")" == "200" ]]
}

# Auth d'ACTION sur le compte $1 : basic auth (password du rôle). Écrit les args curl dans le tableau
# global CURL_AUTH (pas d'échappement fragile en string). Lookup de clé INSENSIBLE À LA CASSE : Gitea
# résout les comptes case-insensitive → un password-file avec `Architect` matche le rôle `architect`
# (on s'aligne sur le système sous-jacent, on n'impose pas une contrainte plus stricte que lui). La
# valeur = string nue OU objet `{password: ...}`. `-u user:pass` en basic auth (le seul mint accepté).
declare -a CURL_AUTH
set_auth_for() { # $1=role
  local role="$1" pwd
  pwd="$(jq -r --arg r "$role" '
    to_entries[]
    | select((.key | ascii_downcase) == ($r | ascii_downcase))
    | .value | if type=="object" then .password else . end
    | select(. != null and . != "")
  ' "$PASSWORDS_FILE" | head -1)"
  [[ -n "$pwd" ]] || return 1
  CURL_AUTH=(-u "$role:$pwd")
}

# UNE entrée à provisionner = une paire `compte:fichier` (le mapping est une DONNÉE). Les rôles
# produisent `<role>:<role>.gitea_token` ; `--extra-token` ajoute les paires où compte ≠ fichier
# (le système : `lcars-system:system.gitea_token`). Une seule mécanique de mint pour tous.
declare -a ENTRIES
for role in $ROLES; do ENTRIES+=("$role:$role.gitea_token"); done
ENTRIES+=("${EXTRA_ENTRIES[@]}")

fail=0
for entry in "${ENTRIES[@]}"; do
  account="${entry%%:*}"
  filename="${entry#*:}"
  file="$TOKENS_DIR/$filename"

  # Idempotence : token local présent ET valide → rien à faire.
  if [[ -r "$file" ]]; then
    tok="$(tr -d '[:space:]' < "$file")"
    if [[ -n "$tok" ]] && token_valid "$tok"; then
      echo "OK    $account — token valide ($file)"
      continue
    fi
  fi

  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    echo "FAIL  $account — token absent/invalide ($file)" >&2
    fail=1
    continue
  fi

  if ! set_auth_for "$account"; then
    echo "FAIL  $account — pas d'autorité (password absent du passwords-file)" >&2
    fail=1
    continue
  fi

  # Re-pose : supprime l'éventuel token remote du même nom (le nom est unique par compte), puis mint.
  # Le DELETE 404/422 est normal (pas de token de ce nom) — seul le POST fait foi.
  curl -s -o /dev/null -m 15 "${CURL_AUTH[@]}" -X DELETE \
    "$FORGE/api/v1/users/$account/tokens/$TOKEN_NAME" || true

  resp="$(curl -s -m 15 "${CURL_AUTH[@]}" -X POST \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$TOKEN_NAME\",\"scopes\":[$(printf '"%s",' ${SCOPES//,/ } | sed 's/,$//')]}" \
    "$FORGE/api/v1/users/$account/tokens")"
  tok="$(printf '%s' "$resp" | jq -r '.sha1 // empty')"

  if [[ -z "$tok" ]]; then
    echo "FAIL  $account — mint refusé par la forge : $(printf '%s' "$resp" | head -c 160)" >&2
    fail=1
    continue
  fi

  if ! token_valid "$tok"; then
    echo "FAIL  $account — token minté mais sonde /user KO (scopes ?)" >&2
    fail=1
    continue
  fi

  # Écriture atomique (tmp+mv) + droits POSIX : 0640, groupe fleet (le BEAM per-humain lit via
  # le groupe ; personne d'autre). chgrp best-effort (exige le privilège du dossier).
  install -d -m 0750 "$TOKENS_DIR" 2>/dev/null || true
  tmp="$(mktemp "$TOKENS_DIR/.provision.XXXXXX")" || { echo "FAIL  $account — $TOKENS_DIR non writable" >&2; fail=1; continue; }
  printf '%s\n' "$tok" > "$tmp"
  chmod 0640 "$tmp"
  chgrp "$GROUP" "$tmp" 2>/dev/null || echo "WARN  $account — chgrp $GROUP refusé (à poser à la main)" >&2
  mv -f "$tmp" "$file"
  echo "POSÉ  $account — token minté + validé → $file"
done

if [[ "$fail" -ne 0 ]]; then
  echo "provision-role-tokens: AU MOINS UNE ENTRÉE EN ÉCHEC (forge $FORGE)" >&2
  exit 2
fi
echo "provision-role-tokens: toutes les entrées valides sur $FORGE"
