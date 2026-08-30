#!/usr/bin/env bash
# SOURCE: fleet/deploy/docker/bench/bench-degrade.sh
# AUTHOR: consultant
# STARDATE: 2026-08-02
# STATUS: geste de BANC — ouvre l'UI de la forge jetable et declare le client OAuth du deck
#
# Ce script fait donc DEUX choses, et rien d'autre :
#   1. il DEGRADE le compte humain (mot de passe connu, drapeau retire) — la faille est le but ;
#   2. il declare le client OAuth2 du deck aupres de la forge, avec l'URL de redirection que le
#      NAVIGATEUR atteint (jamais le nom de service docker : deux mondes reseau distincts).
# IDEMPOTENT : rejouable apres chaque nuke ; le client OAuth existant est reutilise, pas duplique.
#
# USAGE : bench-degrade.sh --forge <url-api> --admin-token <tok> [--human lcars]
#                          [--password <mdp>] [--redirect <url-navigateur>] [--client-name lcars-deck]
# EXIT  : 0 degrade · 1 argument/dependance manquants · 2 la forge refuse

set -euo pipefail

FORGE="" ; TOKEN="" ; HUMAN="lcars" ; PASSWORD="" ; REDIRECT="" ; CLIENT_NAME="lcars-deck"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --forge)        FORGE="${2:?--forge attend une URL d API}"; shift 2 ;;
    --admin-token)  TOKEN="${2:?--admin-token attend un token}"; shift 2 ;;
    --human)        HUMAN="${2:?--human attend un login}"; shift 2 ;;
    --password)     PASSWORD="${2:?--password attend une valeur}"; shift 2 ;;
    --redirect)     REDIRECT="${2:?--redirect attend une URL}"; shift 2 ;;
    --client-name)  CLIENT_NAME="${2:?--client-name attend un nom}"; shift 2 ;;
    -h|--help)      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "bench-degrade: option inconnue: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$FORGE" && -n "$TOKEN" ]] || { echo "bench-degrade: --forge et --admin-token sont requis" >&2; exit 1; }
command -v curl >/dev/null || { echo "bench-degrade: curl absent" >&2; exit 1; }
command -v python3 >/dev/null || { echo "bench-degrade: python3 absent" >&2; exit 1; }

# Gitea REFUSE un mot de passe de moins de 8 caracteres (« password must be at least 8
# characters », mesure du 2026-08-02). Le defaut le respecte pour que le geste ne casse pas sur
# une regle de la forge plutot que sur une intention.
: "${PASSWORD:=toto32toto32}"

say() { echo "[bench-degrade] $*"; }
api() { curl -s -m 10 -H "Authorization: token $TOKEN" -H 'Content-Type: application/json' "$@"; }

code="$(api -o /tmp/bd.out -w '%{http_code}' -X PATCH \
  -d "{\"login_name\":\"$HUMAN\",\"source_id\":0,\"password\":\"$PASSWORD\",\"must_change_password\":false}" \
  "$FORGE/admin/users/$HUMAN")"
if [[ "$code" != 200 ]]; then
  say "REFUS de la forge sur le compte $HUMAN (code $code) : $(head -c 200 /tmp/bd.out)"
  exit 2
fi
say "compte $HUMAN DEGRADE — mot de passe « $PASSWORD », reset au premier login retire"

# La preuve est un login reel, pas le code de la modification : un PATCH accepte qui laisse le
# compte inutilisable serait un faux vert exactement la ou on teste une authentification.
if [[ "$(curl -s -o /dev/null -w '%{http_code}' -m 10 -u "$HUMAN:$PASSWORD" "$FORGE/user")" == 200 ]]; then
  say "verifie : $HUMAN s'authentifie vraiment sur la forge"
else
  say "ANOMALIE : mot de passe pose mais l'authentification echoue — la degradation n'a PAS pris"
  exit 2
fi

# Gitea est fournisseur OpenID Connect (mesure : `/.well-known/openid-configuration` rend ses
# quatre endpoints, scopes openid/profile/email/groups, PKCE S256). Le deck sera donc un CLIENT
# PUBLIC : il n'a pas de secret a garder, il vit dans un navigateur derriere une loopback.
if [[ -n "$REDIRECT" ]]; then
  existing="$(api "$FORGE/user/applications/oauth2" | python3 -c "
import json,sys
try: apps=json.load(sys.stdin)
except Exception: apps=[]
print(next((str(a['id']) for a in apps if a.get('name')=='$CLIENT_NAME'), ''))" 2>/dev/null || true)"

  if [[ -n "$existing" ]]; then
    body="$(api -X PATCH -d "{\"name\":\"$CLIENT_NAME\",\"redirect_uris\":[\"$REDIRECT\"],\"confidential_client\":false}" \
            "$FORGE/user/applications/oauth2/$existing")"
    say "client OAuth « $CLIENT_NAME » deja declare — redirection remise a jour"
  else
    body="$(api -X POST -d "{\"name\":\"$CLIENT_NAME\",\"redirect_uris\":[\"$REDIRECT\"],\"confidential_client\":false}" \
            "$FORGE/user/applications/oauth2")"
    say "client OAuth « $CLIENT_NAME » declare"
  fi
  cid="$(printf '%s' "$body" | python3 -c "import json,sys;print(json.load(sys.stdin).get('client_id',''))" 2>/dev/null || true)"
  # `A && say … || say …` : `say` rend le statut de son `echo`. Un tube ferme (un `| head`) le fait
  # echouer, et le banc annonce « illisible » sur un client_id parfaitement lu.
  if [[ -n "$cid" ]]; then say "client_id : $cid"
  else say "client_id illisible dans la reponse — a verifier a la main"; fi
  say "redirection declaree : $REDIRECT"
else
  say "pas de --redirect : client OAuth non declare (le deck ne pourra pas deleguer l'auth)"
fi

say "RAPPEL : cette forge a un mot de passe humain PUBLIC. Jetable uniquement."
