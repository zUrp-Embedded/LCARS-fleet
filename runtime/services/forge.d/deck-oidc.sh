#!/usr/bin/env bash
# SOURCE: runtime/services/forge.d/deck-oidc.sh
# AUTHOR: DrDree
# STARDATE: (posée par /push-github)
# STATUS: PROTO-V2 — pose le client OAuth2 du deck du conteneur + son fichier de config
# JOUE PAR : le boot du conteneur (a chaque demarrage) et l'installeur d'un poste, par un
# appelant mince. Ni terrain ni ordre ne se declarent ici : ces en-tetes ne sont lus que dans
# `deploy/modules.d`, et les recopier ici promettait une mecanique que personne ne joue.

set -euo pipefail

# L'hote nomme le protocole (LCARS_MODULE_PROTOCOL) : le boot du conteneur, un module de
# l'installeur, ou un temoin. Le contrat de ce dialecte est dans le fichier source.
# shellcheck source=../lib/module-protocol.sh
. "${LCARS_MODULE_PROTOCOL:?LCARS_MODULE_PROTOCOL non pose — lance via un module de l installeur ou le boot du conteneur, pas le geste nu}"

APP_NAME="lcars-deck"
TOKEN_FILE="$LCARS_SYSTEM_TOKEN_FILE"
OIDC_GROUP="$LCARS_SYSTEM_GROUP"

callback_uris() {
  # DEUX ECRITURES DE LA LOOPBACK, PARCE QU'OAUTH2 COMPARE DES CHAINES. `localhost` et `127.0.0.1`
  # designent le meme point d'ecoute et sont deux ORIGINES DIFFERENTES pour la comparaison exacte du
  # `redirect_uri` — or `localhost` est ce qu'un humain tape, et sous WSL c'est la seule adresse qui
  # marche depuis le navigateur de l'hote. N'en declarer qu'une, c'est fermer la porte a celui qui
  # entre par l'autre, APRES son identification (mesure du 2026-08-18).
  local out="http://127.0.0.1:$LCARS_LANDING_PORT/auth/callback http://localhost:$LCARS_LANDING_PORT/auth/callback" o u

  advertise_addr "$LCARS_DECK_BIND"
  if [[ -z "$LCARS_ADVERTISE_WHY" && -n "$LCARS_ADVERTISE" ]]; then
    u="http://$LCARS_ADVERTISE:$LCARS_LANDING_PORT/auth/callback"
    case " $out " in *" $u "*) ;; *) out="$out $u" ;; esac
  fi

  IFS=',' read -ra _origins <<<"${LCARS_DECK_ORIGINS:-}"
  for o in "${_origins[@]:-}"; do
    o="$(echo "$o" | tr -d '[:space:]')"; [[ -n "$o" ]] || continue
    u="${o%/}/auth/callback"
    case " $out " in *" $u "*) continue ;; esac
    out="$out $u"
  done
  echo "$out"
}

browser_unreachable() {   # 0 si l'hôte de $1 ne peut pas être résolu par un navigateur
  local host="${1#*://}"; host="${host%%/*}"; host="${host%%:*}"
  [[ -z "$host" || "$host" == localhost ]] && return 1
  [[ "$host" == *.internal ]] && return 0
  [[ "$host" != *.* ]] && return 0
  return 1
}

addrs_converged() { # 0 si le fichier porte déjà les deux adresses voulues
  local cur_pub cur_int
  cur_pub="$(jq -r '.public_url // ""' "$LCARS_DECK_OIDC_FILE" 2>/dev/null || true)"
  cur_int="$(jq -r '.internal_url // ""' "$LCARS_DECK_OIDC_FILE" 2>/dev/null || true)"
  [[ "$cur_pub" == "${FORGE_PUBLIC_URL%/}" && "$cur_int" == "${FORGE_BASE_URL%/}" ]]
}

forge_api() { # forge_api <METHOD> <path> [json-body]
  forge_curl "$TOKEN_FILE" -s -m 15 \
       ${3:+-H "Content-Type: application/json" -d "$3"} \
       -X "$1" "$FORGE_BASE_URL/api/v1$2" 2>/dev/null || true
}

forge_up() { curl -fsS -m 10 -o /dev/null "$FORGE_BASE_URL/api/v1/version" 2>/dev/null; }

# L'app QUI EST LA NOTRE — et le nom ne suffit pas a le prouver. Mesure du 2026-08-12 : Gitea
# accepte DEUX applications du meme nom sous le meme compte (201). Or le compte systeme est partage
# par tous les conteneurs qui parlent a une meme forge : chercher « lcars-deck » y rend une app
# Le discriminant est donc le RETOUR : nos `redirect_uris` sont, par construction, l'adresse de
# CE conteneur. On ne reconnait comme notre qu'une app qui porte exactement les notres.
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
  # ⚠ NOTRE PROPRE CLIENT EST EXCLU PAR SON client_id. Sans ce filtre, un conteneur qui change ses
  # entrées voit son ANCIEN client (retours différents, même nom) comme celui d'un autre conteneur :
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
our_client_id() { jq -r '.client_id // empty' "$LCARS_DECK_OIDC_FILE" 2>/dev/null || true; }

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
  if [[ -z "$FORGE_BASE_URL" ]]; then
    p_drift "FORGE_BASE_URL non posé — client OAuth2 du deck non convergé (le deck refusera de servir)"
    verdict_check
  fi
  # ⚠ TROIS ETATS, ET LA VERSION PRECEDENTE N'EN CONNAISSAIT QUE DEUX. `[[ ! -r ]]` puis « absent » :
  # mesure du 2026-09-01 sur le banc 2004, ce module annoncait absent un fichier de 336 octets
  # parfaitement present. Il est en `0640 root:lcars-system` — un doctor lance sans sudo ne peut pas
  # l'OUVRIR, il peut parfaitement CONSTATER qu'il est la. Le test de lisibilite tenait lieu de test
  # d'existence, et envoyait converger un objet deja pose.
  # le fichier porte un client_secret : 0640, groupe du deck — un mode plus large se dit (relecture
  # hostile 2026-09-04 : ni mesure ni converge)
  if [[ -e "$LCARS_DECK_OIDC_FILE" ]]; then
    local _mode _grp; _mode="$(stat -c '%a' "$LCARS_DECK_OIDC_FILE" 2>/dev/null || true)"; _grp="$(stat -c '%G' "$LCARS_DECK_OIDC_FILE" 2>/dev/null || true)"
    [[ "$_mode" == 640 ]] || p_drift "$LCARS_DECK_OIDC_FILE : mode $_mode ≠ 640 — le secret du client est plus large que le deck"
    if getent group "$OIDC_GROUP" >/dev/null 2>&1; then
      [[ "$_grp" == "$OIDC_GROUP" ]] || p_drift "$LCARS_DECK_OIDC_FILE : groupe $_grp ≠ $OIDC_GROUP — le deck ne le lira pas"
    fi
  fi
  local _st; _st="$(prov_file_state "$LCARS_DECK_OIDC_FILE")"
  if [[ "$_st" == "absent" ]]; then
    p_drift "$LCARS_DECK_OIDC_FILE absent — le deck (port $LCARS_LANDING_PORT) sert 503 tant qu'il n'est pas posé"
  elif [[ "$_st" != "present" ]]; then
    # PAS un drift : un drift promet qu'`apply` converge, et on ne sait meme pas s'il y a quelque
    # chose a converger. Ce qui manque est une MESURE, et le rapport doit dire laquelle.
    p_warn "$LCARS_DECK_OIDC_FILE $(prov_state_why "$_st" "$LCARS_DECK_OIDC_FILE")"
  elif ! forge_up; then
    p_ok "$LCARS_DECK_OIDC_FILE présent (forge injoignable : client non re-vérifié)"
  elif config_live; then
    local _want; _want="$(callback_uris)"
    if uris_converged "$_want"; then
      p_ok "client OAuth2 du deck posé et connu de la forge ($LCARS_DECK_OIDC_FILE)"
    else
      p_drift "entrées du deck non convergées — enregistrées : « $(registered_uris) » / voulues : « $_want » (apply les repose)"
    fi
  else
    p_drift "$LCARS_DECK_OIDC_FILE nomme un client que la forge ne connaît plus — à re-poser"
  fi
  if [[ -n "$FORGE_PUBLIC_URL" ]] && browser_unreachable "$FORGE_PUBLIC_URL"; then
    p_drift "FORGE_PUBLIC_URL=$FORGE_PUBLIC_URL — nom local au daemon docker : AUCUN navigateur ne le résout (pose FORGE_PUBLIC_URL)"
  fi
  if [[ -r "$LCARS_DECK_OIDC_FILE" ]] && ! addrs_converged; then
    p_drift "adresses du deck non convergées — fichier : navigateur « $(jq -r '.public_url // ""' "$LCARS_DECK_OIDC_FILE" 2>/dev/null)  » / serveur « $(jq -r '.internal_url // ""' "$LCARS_DECK_OIDC_FILE" 2>/dev/null) » ; voulues : « ${FORGE_PUBLIC_URL%/} » / « ${FORGE_BASE_URL%/} » (apply les repose)"
  fi
  verdict_check
}

apply() {
  if [[ -z "$FORGE_BASE_URL" ]]; then
    p_drift "FORGE_BASE_URL non posé — client OAuth2 du deck NON posé"
    verdict_apply
  fi
  if ! forge_up; then
    p_drift "forge injoignable : $FORGE_BASE_URL — client OAuth2 du deck NON posé (relance quand elle répond)"
    verdict_apply
  fi
  if [[ ! -r "$TOKEN_FILE" ]]; then
    p_drift "$TOKEN_FILE absent — le geste des jetons n'a pas encore minté le jeton système ; client OAuth2 NON posé, il se posera à la convergence suivante"
    verdict_apply
  fi

  local uris body resp cid csec
  uris="$(callback_uris)"

  if [[ -e "$LCARS_DECK_OIDC_FILE" ]]; then
    chmod 0640 "$LCARS_DECK_OIDC_FILE" 2>/dev/null || true
    chgrp "$OIDC_GROUP" "$LCARS_DECK_OIDC_FILE" 2>/dev/null || true
  fi
  if [[ -r "$LCARS_DECK_OIDC_FILE" ]] && config_live && uris_converged "$uris" && addrs_converged; then
    p_ok "client OAuth2 du deck déjà posé et vivant"
    verdict_apply
  fi

  if [[ -r "$LCARS_DECK_OIDC_FILE" ]] && config_live; then
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
    LCARS_CHANGED=$((LCARS_CHANGED + 1))
  fi
  local foreign
  foreign="$(foreign_apps "$uris")"
  if [[ -n "$foreign" ]]; then
    p_warn "app(s) OAuth2 homonyme(s) sur cette forge, visant d'autres retours — INTACTES (un autre conteneur les possède) : $(echo "$foreign" | tr '\n' ' ')"
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

  ensure_dir "$(dirname "$LCARS_DECK_OIDC_FILE")" 0755 \
    || { p_fail "répertoire de la config OIDC non convergé ($(dirname "$LCARS_DECK_OIDC_FILE"))"; verdict_apply; }
  local tmp; tmp="$(mktemp "${LCARS_DECK_OIDC_FILE}.XXXXXX")"
  jq -n --arg ci "$cid" --arg cs "$csec" \
        --arg pub "${FORGE_PUBLIC_URL%/}" --arg int "${FORGE_BASE_URL%/}" --arg uris "$uris" \
        '{client_id:$ci, client_secret:$cs, public_url:$pub, internal_url:$int,
          redirect_uris:($uris|split(" "))}' > "$tmp"
  chmod 0640 "$tmp"
  chgrp "$OIDC_GROUP" "$tmp" 2>/dev/null || p_warn "groupe $OIDC_GROUP inconnu — $LCARS_DECK_OIDC_FILE restera illisible par le deck (il tourne sous ce compte : sur un poste, « deploy/workstation up » le pose ; dans un conteneur, c'est l'image qui le porte)"
  mv -f "$tmp" "$LCARS_DECK_OIDC_FILE"
  LCARS_CHANGED=$((LCARS_CHANGED + 1))
  p_chg "client OAuth2 « $APP_NAME » posé → $LCARS_DECK_OIDC_FILE (retours : $uris)"

  if browser_unreachable "$FORGE_PUBLIC_URL"; then
    p_warn "public_url=$FORGE_PUBLIC_URL est local au daemon docker — le navigateur ne le résoudra pas ; pose FORGE_PUBLIC_URL sur l'adresse réelle de la forge"
  fi
  verdict_apply
}

case "${1:?usage: deck-oidc.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
