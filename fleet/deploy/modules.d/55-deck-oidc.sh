#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/55-deck-oidc.sh
# AUTHOR: DrDree
# STARDATE: (posée par /push-github)
# STATUS: PROTO-V2 — pose le client OAuth2 du deck de la boîte + son fichier de config
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root
# AFTER: 21-service-accounts 50-forge

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

APP_NAME="lcars-deck"
TOKEN_FILE="$PROV_SYSTEM_TOKEN_FILE"
OIDC_GROUP="${PROV_SYSTEM_GROUP:-${PROV_SYSTEM_USER:-lcars-system}}"

# ⚠ DEDUPLIQUE. La loopback est posee ici d'office ET nommee par l'appelant depuis que le banc
# annonce deux entrees : sans ce filtre, elle est enregistree DEUX FOIS chez la forge (mesure du
# 2026-08-18). Gitea l'accepte, donc rien ne casse — mais une liste qui se repete est une liste dont
# personne ne tient l'inventaire, et c'est la sonde de derive juste en dessous qui compare des
# listes triees qui en paierait le prix.
callback_uris() {
  # DEUX ECRITURES DE LA LOOPBACK, PARCE QU'OAUTH2 COMPARE DES CHAINES. `localhost` et `127.0.0.1`
  # designent le meme point d'ecoute et sont deux ORIGINES DIFFERENTES pour la comparaison exacte du
  # `redirect_uri` — or `localhost` est ce qu'un humain tape, et sous WSL c'est la seule adresse qui
  # marche depuis le navigateur de l'hote. N'en declarer qu'une, c'est fermer la porte a celui qui
  # entre par l'autre, APRES son identification (mesure du 2026-08-18).
  local out="http://127.0.0.1:$PROV_DECK_PORT/auth/callback http://localhost:$PROV_DECK_PORT/auth/callback" o u

  advertise_addr "${PROV_DECK_BIND:-0.0.0.0}"
  if [[ -z "$PROV_ADVERTISE_WHY" && -n "$PROV_ADVERTISE" ]]; then
    u="http://$PROV_ADVERTISE:$PROV_DECK_PORT/auth/callback"
    case " $out " in *" $u "*) ;; *) out="$out $u" ;; esac
  fi

  IFS=',' read -ra _origins <<<"${PROV_DECK_ORIGINS:-}"
  for o in "${_origins[@]:-}"; do
    o="$(echo "$o" | tr -d '[:space:]')"; [[ -n "$o" ]] || continue
    u="${o%/}/auth/callback"
    case " $out " in *" $u "*) continue ;; esac
    out="$out $u"
  done
  echo "$out"
}

# Le resolveur du visiteur n'est pas mesurable d'ici : on nomme ce qui est local au daemon docker —
# le domaine `.internal`, et les noms de service (sans point). `localhost` n'a pas de point non plus
# et se resout : c'est l'adresse juste d'un operateur sur sa machine, donc jamais un drift.
browser_unreachable() {   # 0 si l'hôte de $1 ne peut pas être résolu par un navigateur
  local host="${1#*://}"; host="${host%%/*}"; host="${host%%:*}"
  [[ -z "$host" || "$host" == localhost ]] && return 1
  [[ "$host" == *.internal ]] && return 0
  [[ "$host" != *.* ]] && return 0
  return 1
}

# LES DEUX ADRESSES DU FICHIER, COMPARÉES À CE QU'ON POSERAIT — une seule fonction pour le check et
# pour l'apply, sinon les deux se répondraient différemment le jour où l'une dérive.
addrs_converged() { # 0 si le fichier porte déjà les deux adresses voulues
  local cur_pub cur_int
  cur_pub="$(jq -r '.public_url // ""' "$PROV_DECK_OIDC_FILE" 2>/dev/null || true)"
  cur_int="$(jq -r '.internal_url // ""' "$PROV_DECK_OIDC_FILE" 2>/dev/null || true)"
  [[ "$cur_pub" == "${PROV_FORGE_PUBLIC_URL%/}" && "$cur_int" == "${PROV_FORGE_URL%/}" ]]
}

forge_api() { # forge_api <METHOD> <path> [json-body]
  forge_curl "$TOKEN_FILE" -s -m 15 \
       ${3:+-H "Content-Type: application/json" -d "$3"} \
       -X "$1" "$PROV_FORGE_URL/api/v1$2" 2>/dev/null || true
}

forge_up() { curl -fsS -m 10 -o /dev/null "$PROV_FORGE_URL/api/v1/version" 2>/dev/null; }

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
  # ⚠ NOTRE PROPRE CLIENT EST EXCLU PAR SON client_id. Sans ce filtre, une boîte qui change ses
  # entrées voit son ANCIEN client (retours différents, même nom) comme celui d'une autre boîte :
  # elle le laisse en place en le dénonçant, et en crée un second. Deux clients homonymes vivants
  # sous le même compte, dont un mort — l'inventaire devient illisible en deux passages.
  local ours; ours="$(our_client_id)"
  forge_api GET "/user/applications/oauth2" \
    | jq -r --arg n "$APP_NAME" --arg u "$1" --arg c "$ours" \
        'if type=="array" then (.[]
           | select(.name==$n)
           | select(.client_id != $c)
           | select((.redirect_uris|sort) != ($u|split(" ")|sort))
           | "\(.id):\(.redirect_uris|join(","))") else empty end' 2>/dev/null
}

# The config file is USABLE when it names a client the forge still knows. Checking only that the
# file exists would keep a box happily pointing at an application someone deleted, and the failure
# would surface as an opaque OAuth2 error in a browser, half a rail away from its cause.
config_live() {
  local cid
  cid="$(our_client_id)"
  [[ -n "$cid" ]] || return 1
  forge_api GET "/user/applications/oauth2" \
    | jq -e --arg c "$cid" 'if type=="array" then any(.[]; .client_id==$c) else false end' \
      >/dev/null 2>&1
}

# Le client QUI EST LE NOTRE : celui que NOTRE fichier nomme. C'est le seul ancrage qui ne se
# devine pas — le nom est partage sur une forge commune, et les `redirect_uris` sont precisement ce
# qu'on veut pouvoir CHANGER (donc ils ne peuvent pas servir a s'identifier soi-meme).
our_client_id() { jq -r '.client_id // empty' "$PROV_DECK_OIDC_FILE" 2>/dev/null || true; }

registered_uris() {
  local cid; cid="$(our_client_id)"
  [[ -n "$cid" ]] || return 0
  forge_api GET "/user/applications/oauth2" \
    | jq -r --arg c "$cid" \
        'if type=="array" then (.[] | select(.client_id==$c) | .redirect_uris | sort | join(" "))
         else empty end' 2>/dev/null | head -n1
}

uris_converged() { # uris_converged <uris-voulues, separees par espace>
  local want got
  # shellcheck disable=SC2086 # $1 est une LISTE separee par des espaces, a eclater
  want="$(printf '%s\n' $1 | sort | tr '\n' ' ')"
  got="$(registered_uris) "
  [[ "$want" == "$got" ]]
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
    local _want; _want="$(callback_uris)"
    if uris_converged "$_want"; then
      p_ok "client OAuth2 du deck posé et connu de la forge ($PROV_DECK_OIDC_FILE)"
    else
      p_drift "entrées du deck non convergées — enregistrées : « $(registered_uris) » / voulues : « $_want » (apply les repose)"
    fi
  else
    p_drift "$PROV_DECK_OIDC_FILE nomme un client que la forge ne connaît plus — à re-poser"
  fi
  # The browser-facing address is its own failure mode: it is only wrong once somebody tries from
  # another machine, and by then the error looks like a broken login rather than a config value.
  if [[ -n "$PROV_FORGE_PUBLIC_URL" ]] && browser_unreachable "$PROV_FORGE_PUBLIC_URL"; then
    p_drift "PROV_FORGE_PUBLIC_URL=$PROV_FORGE_PUBLIC_URL — nom local au daemon docker : AUCUN navigateur ne le résout (pose FORGE_PUBLIC_URL)"
  fi
  if [[ -r "$PROV_DECK_OIDC_FILE" ]] && ! addrs_converged; then
    p_drift "adresses du deck non convergées — fichier : navigateur « $(jq -r '.public_url // ""' "$PROV_DECK_OIDC_FILE" 2>/dev/null)  » / serveur « $(jq -r '.internal_url // ""' "$PROV_DECK_OIDC_FILE" 2>/dev/null) » ; voulues : « ${PROV_FORGE_PUBLIC_URL%/} » / « ${PROV_FORGE_URL%/} » (apply les repose)"
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

  local uris body resp cid csec
  uris="$(callback_uris)"

  if [[ -r "$PROV_DECK_OIDC_FILE" ]] && config_live && uris_converged "$uris" && addrs_converged; then
    p_ok "client OAuth2 du deck déjà posé et vivant"
    verdict_apply
  fi

  # NOTRE client existe mais ne vise plus les bonnes entrées : c'est LUI qu'on retire, designe par
  # le client_id de notre fichier — pas par son nom (partagé sur une forge commune) ni par ses
  # retours (c'est justement ce qui a changé). Le secret n'étant rendu qu'à la création, remplacer
  # est le seul geste possible : on ne peut pas ré-écrire le fichier autour d'un secret perdu.
  if [[ -r "$PROV_DECK_OIDC_FILE" ]] && config_live; then
    local ours; ours="$(our_client_id)"
    local oid
    oid="$(forge_api GET "/user/applications/oauth2" \
            | jq -r --arg c "$ours" 'if type=="array" then (.[]|select(.client_id==$c)|.id) else empty end' \
              2>/dev/null | head -n1)"
    if [[ -n "$oid" ]]; then
      forge_api DELETE "/user/applications/oauth2/$oid" >/dev/null
      p_chg "entrées du deck changées — client OAuth2 (id $oid) retiré pour être reposé sur : $uris"
    fi
  fi

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
    p_fail "création du client OAuth2 refusée par la forge : $(echo "$resp" | head -c 200) (le token système a-t-il le scope write:user ?)"
    verdict_apply
  fi

  ensure_dir "$(dirname "$PROV_DECK_OIDC_FILE")" 0755 \
    || { p_fail "répertoire de la config OIDC non convergé ($(dirname "$PROV_DECK_OIDC_FILE"))"; verdict_apply; }
  local tmp; tmp="$(mktemp "${PROV_DECK_OIDC_FILE}.XXXXXX")"
  jq -n --arg ci "$cid" --arg cs "$csec" \
        --arg pub "${PROV_FORGE_PUBLIC_URL%/}" --arg int "${PROV_FORGE_URL%/}" --arg uris "$uris" \
        '{client_id:$ci, client_secret:$cs, public_url:$pub, internal_url:$int,
          redirect_uris:($uris|split(" "))}' > "$tmp"
  chmod 0640 "$tmp"
  chgrp "$OIDC_GROUP" "$tmp" 2>/dev/null || p_warn "groupe $OIDC_GROUP inconnu — $PROV_DECK_OIDC_FILE restera illisible par le deck (il tourne sous ce compte ; « provision apply --only 21-service-accounts » le pose)"
  mv -f "$tmp" "$PROV_DECK_OIDC_FILE"
  PROV_CHANGED=$((PROV_CHANGED + 1))
  p_chg "client OAuth2 « $APP_NAME » posé → $PROV_DECK_OIDC_FILE (retours : $uris)"

  if browser_unreachable "$PROV_FORGE_PUBLIC_URL"; then
    p_warn "public_url=$PROV_FORGE_PUBLIC_URL est local au daemon docker — le navigateur ne le résoudra pas ; pose FORGE_PUBLIC_URL sur l'adresse réelle de la forge"
  fi
  verdict_apply
}

case "${1:?usage: 55-deck-oidc.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
