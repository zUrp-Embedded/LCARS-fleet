#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/55-deck-oidc.sh
# AUTHOR: DrDree
# STARDATE: (posée par /push-github)
# STATUS: PROTO-V2 — pose le client OAuth2 du deck de la boîte + son fichier de config
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root
#
# THE BOX'S FRONT DOOR NEEDS A CLIENT, AND NOTHING WAS CREATING ONE. The deck (port 20999) now
# refuses to serve anything until it can ask the forge "who are you" — deliberately, because a deck
# that fell back to listing every human would make a missing configuration invisible, and nobody
# would ever fix it. This module is what makes that refusal go away.
#
# WHY THIS IS PROVISIONING AND NOT A HUMAN CLICKING A FORM: measured 2026-08-12,
# `POST /api/v1/user/applications/oauth2` refuses on SCOPE (`required=[write:user]`) and not on
# auth METHOD — unlike minting a token, which Gitea only accepts over basic auth. So a token is
# enough, and the system account has carried `write:user` since that measurement.
#
# ORDER: after 50-forge (which mints the system token this needs), before 70-human.
#
# Données : PROV_FORGE_URL (vide = instruct-only) · PROV_FORGE_PUBLIC_URL (adresse NAVIGATEUR) ·
#           PROV_DECK_ORIGINS · PROV_DECK_PORT · PROV_DECK_OIDC_FILE · PROV_TOKENS_DIR

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

APP_NAME="lcars-deck"
TOKEN_FILE="$PROV_TOKENS_DIR/system.gitea_token"
# `nobody` runs the deck (it reads and pilots nothing), and it reads this file. Group `nogroup` is
# what `setpriv --regid nogroup` gives it, so 0640 root:nogroup is the narrowest mode that works:
# the client_secret stays unreadable to every human on the box.
OIDC_GROUP="nogroup"

# The entrances, as full callback URIs. Loopback always: it is how the box's own operator reaches
# the deck, and it is the one address that is true everywhere.
callback_uris() {
  local out="http://127.0.0.1:$PROV_DECK_PORT/auth/callback" o
  IFS=',' read -ra _origins <<<"${PROV_DECK_ORIGINS:-}"
  for o in "${_origins[@]:-}"; do
    o="$(echo "$o" | tr -d '[:space:]')"; [[ -n "$o" ]] || continue
    out="$out ${o%/}/auth/callback"
  done
  echo "$out"
}

forge_tok() { tr -d '[:space:]' < "$TOKEN_FILE" 2>/dev/null || true; }

# Every call goes through here so the token is read once per call and never lands in a variable
# that could be echoed by `set -x`.
forge_api() { # forge_api <METHOD> <path> [json-body]
  local tok; tok="$(forge_tok)"
  curl -s -m 15 -H "Authorization: token $tok" \
       ${3:+-H "Content-Type: application/json" -d "$3"} \
       -X "$1" "$PROV_FORGE_URL/api/v1$2" 2>/dev/null || true
}

forge_up() { curl -fsS -m 10 -o /dev/null "$PROV_FORGE_URL/api/v1/version" 2>/dev/null; }

# The app id currently registered under our name, or empty.
# L'app QUI EST LA NOTRE — et le nom ne suffit pas a le prouver. Mesure du 2026-08-12 : Gitea
# accepte DEUX applications du meme nom sous le meme compte (201). Or le compte systeme est partage
# par toutes les boites qui parlent a une meme forge : chercher « lcars-deck » y rend une app
# arbitraire. Un `head -n1` sur ce nom, suivi du DELETE ci-dessous, ferait detruire a chaque boite la
# porte d'une autre — et comme chacune re-creerait la sienne au passage suivant, les deux se
# demoliraient en boucle sans qu'aucune ne le dise.
# Le discriminant est donc le RETOUR : nos `redirect_uris` sont, par construction, l'adresse de
# CETTE boite. On ne reconnait comme notre qu'une app qui porte exactement les notres.
app_id() { # app_id <uris-attendues, separees par espace>
  forge_api GET "/user/applications/oauth2" \
    | jq -r --arg n "$APP_NAME" --arg u "$1" \
        'if type=="array" then (.[]
           | select(.name==$n)
           | select((.redirect_uris|sort) == ($u|split(" ")|sort))
           | .id) else empty end' 2>/dev/null \
    | head -n1
}

# Les homonymes qui ne sont PAS a nous — a NOMMER, jamais a toucher.
foreign_apps() { # foreign_apps <uris-attendues>
  forge_api GET "/user/applications/oauth2" \
    | jq -r --arg n "$APP_NAME" --arg u "$1" \
        'if type=="array" then (.[]
           | select(.name==$n)
           | select((.redirect_uris|sort) != ($u|split(" ")|sort))
           | "\(.id):\(.redirect_uris|join(","))") else empty end' 2>/dev/null
}

# The config file is USABLE when it names a client the forge still knows. Checking only that the
# file exists would keep a box happily pointing at an application someone deleted, and the failure
# would surface as an opaque OAuth2 error in a browser, half a rail away from its cause.
config_live() {
  local cid
  cid="$(jq -r '.client_id // empty' "$PROV_DECK_OIDC_FILE" 2>/dev/null || true)"
  [[ -n "$cid" ]] || return 1
  forge_api GET "/user/applications/oauth2" \
    | jq -e --arg c "$cid" 'if type=="array" then any(.[]; .client_id==$c) else false end' \
      >/dev/null 2>&1
}

check() {
  if [[ -z "$PROV_FORGE_URL" ]]; then
    p_drift "FORGE_BASE_URL/PROV_FORGE_URL non posé — client OAuth2 du deck non convergé (le deck refusera de servir)"
    verdict_check
  fi
  if [[ ! -r "$PROV_DECK_OIDC_FILE" ]]; then
    p_drift "$PROV_DECK_OIDC_FILE absent — le deck (port $PROV_DECK_PORT) sert 503 tant qu'il n'est pas posé"
  elif ! forge_up; then
    p_ok "$PROV_DECK_OIDC_FILE présent (forge injoignable : client non re-vérifié)"
  elif config_live; then
    p_ok "client OAuth2 du deck posé et connu de la forge ($PROV_DECK_OIDC_FILE)"
  else
    p_drift "$PROV_DECK_OIDC_FILE nomme un client que la forge ne connaît plus — à re-poser"
  fi
  # The browser-facing address is its own failure mode: it is only wrong once somebody tries from
  # another machine, and by then the error looks like a broken login rather than a config value.
  if [[ -n "$PROV_FORGE_PUBLIC_URL" && "$PROV_FORGE_PUBLIC_URL" == *"://forge:"* ]]; then
    p_drift "PROV_FORGE_PUBLIC_URL=$PROV_FORGE_PUBLIC_URL — nom de service docker : AUCUN navigateur ne le résout (pose FORGE_PUBLIC_URL)"
  fi
  verdict_check
}

apply() {
  if [[ -z "$PROV_FORGE_URL" ]]; then
    p_drift "FORGE_BASE_URL/PROV_FORGE_URL non posé — client OAuth2 du deck NON posé"
    verdict_apply
  fi
  if ! forge_up; then
    p_drift "forge injoignable : $PROV_FORGE_URL — client OAuth2 du deck NON posé (relance quand elle répond)"
    verdict_apply
  fi
  if [[ ! -r "$TOKEN_FILE" ]]; then
    p_drift "$TOKEN_FILE absent — 50-forge n'a pas encore minté le token système ; client OAuth2 NON posé"
    verdict_apply
  fi

  if [[ -r "$PROV_DECK_OIDC_FILE" ]] && config_live; then
    p_ok "client OAuth2 du deck déjà posé et vivant"
    verdict_apply
  fi

  local uris body resp cid csec
  uris="$(callback_uris)"

  # THE SECRET IS RETURNED ONCE, AT CREATION. If an application carrying our name AND our exact
  # return addresses exists while the config file is missing or stale, its secret is unrecoverable —
  # so we drop it and register a new one. Leaving it would accumulate dead clients under the system
  # account, each looking like the live one.
  local id; id="$(app_id "$uris")"
  if [[ -n "$id" ]]; then
    forge_api DELETE "/user/applications/oauth2/$id" >/dev/null
    p_chg "ancien client OAuth2 « $APP_NAME » (id $id) retiré — son secret n'était plus récupérable"
    PROV_CHANGED=$((PROV_CHANGED + 1))
  fi
  # Une app homonyme qui vise d'AUTRES retours appartient a une autre boite sur la meme forge. On la
  # NOMME et on n'y touche pas : la supprimer casserait sa porte, et elle re-creerait la sienne au
  # passage suivant — deux boites a se demolir en boucle, en silence.
  local foreign
  foreign="$(foreign_apps "$uris")"
  if [[ -n "$foreign" ]]; then
    p_warn "app(s) OAuth2 homonyme(s) sur cette forge, visant d'autres retours — INTACTES (une autre boîte les possède) : $(echo "$foreign" | tr '\n' ' ')"
  fi
  body="$(jq -nc --arg n "$APP_NAME" --arg u "$uris" \
            '{name:$n, redirect_uris:($u|split(" ")), confidential_client:true}')"
  resp="$(forge_api POST "/user/applications/oauth2" "$body")"
  cid="$(echo "$resp"  | jq -r '.client_id // empty' 2>/dev/null || true)"
  csec="$(echo "$resp" | jq -r '.client_secret // empty' 2>/dev/null || true)"
  if [[ -z "$cid" || -z "$csec" ]]; then
    # `write:user` is the one scope this needs and the one the system token lacked before
    # 2026-08-12 — name it, because the API message alone sends the reader to the swagger page.
    p_fail "création du client OAuth2 refusée par la forge : $(echo "$resp" | head -c 200) (le token système a-t-il le scope write:user ?)"
    verdict_apply
  fi

  install -d -m 0755 "$(dirname "$PROV_DECK_OIDC_FILE")"
  local tmp; tmp="$(mktemp "${PROV_DECK_OIDC_FILE}.XXXXXX")"
  # LES URI ENREGISTREES VOYAGENT AVEC LA CONFIG, et ce n'est pas de la redondance. Le deck derive
  # son `redirect_uri` du `Host` de la requete ; si la personne arrive par une entree qui n'est PAS
  # dans cette liste, OAuth2 refuse — et ce refus est une page 400 de Gitea au titre generique, qui
  # ne mentionne meme pas `redirect_uri` (mesure du 2026-08-12). Cul-de-sac parfait : apres
  # l'identification, sur une page qui n'est pas la notre. En les lui donnant, le deck compare AVANT
  # d'envoyer quelqu'un et sert son propre refus, qui nomme l'entree manquante.
  jq -n --arg ci "$cid" --arg cs "$csec" \
        --arg pub "${PROV_FORGE_PUBLIC_URL%/}" --arg int "${PROV_FORGE_URL%/}" --arg uris "$uris" \
        '{client_id:$ci, client_secret:$cs, public_url:$pub, internal_url:$int,
          redirect_uris:($uris|split(" "))}' > "$tmp"
  chmod 0640 "$tmp"
  chgrp "$OIDC_GROUP" "$tmp" 2>/dev/null || p_warn "groupe $OIDC_GROUP inconnu — $PROV_DECK_OIDC_FILE restera illisible par le deck (il tourne en nobody)"
  mv -f "$tmp" "$PROV_DECK_OIDC_FILE"
  PROV_CHANGED=$((PROV_CHANGED + 1))
  p_chg "client OAuth2 « $APP_NAME » posé → $PROV_DECK_OIDC_FILE (retours : $uris)"

  if [[ "$PROV_FORGE_PUBLIC_URL" == *"://forge:"* ]]; then
    p_warn "public_url=$PROV_FORGE_PUBLIC_URL est un nom de service docker — le navigateur ne le résoudra pas ; pose FORGE_PUBLIC_URL sur l'adresse réelle de la forge"
  fi
  verdict_apply
}

case "${1:?usage: 55-deck-oidc.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
