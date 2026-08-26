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
TOKEN_FILE="$PROV_SYSTEM_TOKEN_FILE"
# `nobody` runs the deck (it reads and pilots nothing), and it reads this file. Group `nogroup` is
# what `setpriv --regid nogroup` gives it, so 0640 root:nogroup is the narrowest mode that works:
# the client_secret stays unreadable to every human on the box.
OIDC_GROUP="nogroup"

# The entrances, as full callback URIs. Loopback always: it is how the box's own operator reaches
# the deck, and it is the one address that is true everywhere.
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

  # ─── ET L'ADRESSE QU'UN TIERS COMPOSE, PARCE QUE LE DECK N'ÉCOUTE PAS QUE SUR LA LOOPBACK ──────
  #
  # MÊME LEÇON QUE LA FORGE, UN CRAN PLUS LOIN. `48-forge-host` l'a apprise avec `PROV_FORGE_ADVERTISE`
  # et `bench-up.sh` l'avait écrite avant lui : « LE RECAP DIT L'ADRESSE QU'ON COMPOSE, PAS CELLE SUR
  # LAQUELLE ON ECOUTE. » Ici c'est pire qu'un lien faux : OAuth2 compare le `redirect_uri` en CHAÎNE
  # EXACTE, donc une entrée non déclarée n'est pas une dégradation, c'est un refus.
  #
  # MESURÉ LE 2026-08-21, poste natif installé à froid, opérateur venant d'une autre machine :
  #   « CETTE ENTREE N'EST PAS DECLAREE — tu es arrive par http://10.42.0.63:20999/auth/callback.
  #     Entrees declarees : http://127.0.0.1:20999/…, http://localhost:20999/… »
  # Le deck s'arrête proprement et nomme le levier — c'est le comportement voulu, et il ne devrait
  # pas avoir à servir. Le levier existait (`PROV_DECK_ORIGINS`) ; c'est le DÉFAUT qui était faux.
  #
  # ⚠ ON N'ANNONCE QUE CE QUI VAUT QUELQUE CHOSE. `advertise_addr` rend l'adresse ET ce qu'elle vaut :
  # sous WSL en NAT, elle rend `localhost` avec un motif, parce que la VM n'est routée depuis aucune
  # autre machine. Déclarer une entrée dans ce cas ajouterait une chaîne que personne ne peut taper.
  # Un appelant qui ignore `PROV_ADVERTISE_WHY` annonce sans savoir ce qu'il annonce — la lib le dit.
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

forge_tok() { tr -d '[:space:]' < "$TOKEN_FILE" 2>/dev/null || true; }

# LES DEUX ADRESSES DU FICHIER, COMPARÉES À CE QU'ON POSERAIT — une seule fonction pour le check et
# pour l'apply, sinon les deux se répondraient différemment le jour où l'une dérive.
addrs_converged() { # 0 si le fichier porte déjà les deux adresses voulues
  local cur_pub cur_int
  cur_pub="$(jq -r '.public_url // ""' "$PROV_DECK_OIDC_FILE" 2>/dev/null || true)"
  cur_int="$(jq -r '.internal_url // ""' "$PROV_DECK_OIDC_FILE" 2>/dev/null || true)"
  [[ "$cur_pub" == "${PROV_FORGE_PUBLIC_URL%/}" && "$cur_int" == "${PROV_FORGE_URL%/}" ]]
}

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

# Les retours REELLEMENT enregistres chez la forge pour notre client, tries et joints par espace.
registered_uris() {
  local cid; cid="$(our_client_id)"
  [[ -n "$cid" ]] || return 0
  forge_api GET "/user/applications/oauth2" \
    | jq -r --arg c "$cid" \
        'if type=="array" then (.[] | select(.client_id==$c) | .redirect_uris | sort | join(" "))
         else empty end' 2>/dev/null | head -n1
}

# ⚠ LA LISTE DES ENTREES DOIT CONVERGER, ET ELLE NE CONVERGEAIT PAS. `apply` sortait des que le
# fichier nommait un client encore connu de la forge — sans jamais comparer les retours enregistres
# a ceux qu'on veut. Consequence mesuree le 2026-08-18 : ajouter une origine a `LCARS_DECK_ORIGINS`
# et rejouer le provisionnement ne changeait RIEN, en silence. Et c'est exactement le geste que la
# page de refus du deck prescrit — le runtime imprimait une instruction que le runtime n'honorait
# pas. Un mensonge operationnel, pas une lacune de confort.
uris_converged() { # uris_converged <uris-voulues, separees par espace>
  local want got
  # shellcheck disable=SC2086 -- $1 est une LISTE separee par des espaces, a eclater
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
      # NOMMER LES DEUX LISTES. Le symptome de cette derive est une page de refus dans un navigateur,
      # a l'autre bout du rail : sans les deux listes cote a cote, personne ne fait le lien.
      p_drift "entrées du deck non convergées — enregistrées : « $(registered_uris) » / voulues : « $_want » (apply les repose)"
    fi
  else
    p_drift "$PROV_DECK_OIDC_FILE nomme un client que la forge ne connaît plus — à re-poser"
  fi
  # The browser-facing address is its own failure mode: it is only wrong once somebody tries from
  # another machine, and by then the error looks like a broken login rather than a config value.
  if [[ -n "$PROV_FORGE_PUBLIC_URL" && "$PROV_FORGE_PUBLIC_URL" == *"://forge:"* ]]; then
    p_drift "PROV_FORGE_PUBLIC_URL=$PROV_FORGE_PUBLIC_URL — nom de service docker : AUCUN navigateur ne le résout (pose FORGE_PUBLIC_URL)"
  fi
  # ⚠ ET LE FICHIER QU'ON ÉCRIT SE SONDE AUSSI, PAS SEULEMENT CE QUE LA FORGE ENREGISTRE. Cette
  # sonde ne comparait que la liste des retours ; `public_url` et `internal_url`, qu'elle POSE dans
  # le même fichier, n'étaient regardés par personne. Une adresse publique qui change ne convergeait
  # donc jamais — le module répondait « déjà posé et vivant », en toute bonne foi, sur un fichier
  # devenu faux.
  #
  # MESURE DU 2026-08-21 : `forge.public.url` arrive, `PROV_FORGE_PUBLIC_URL` devient
  # `http://10.42.0.63:3000`, apply rejoué → « client OAuth2 du deck déjà posé et vivant », et
  # `deck-oidc.json` porte toujours `public_url: http://127.0.0.1:3000`. Le bouton d'identification
  # continuait d'envoyer le visiteur sur SA propre loopback.
  #
  # C'est la faute que ce dépôt nomme « la sonde répond à une question voisine » : elle mesurait
  # l'enregistrement chez Gitea — vrai — au lieu de l'état-cible complet, dont le fichier fait partie.
  if [[ -r "$PROV_DECK_OIDC_FILE" ]] && ! addrs_converged; then
    # NOMMER LES DEUX ÉTATS, comme pour les listes de retours juste au-dessus : le symptôme vit dans
    # un navigateur, à l'autre bout du rail, et sans les valeurs côte à côte personne ne fait le lien.
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

  # ⚠ « DÉJÀ POSÉ » DOIT COUVRIR TOUT L'ÉTAT-CIBLE, PAS SEULEMENT LA MOITIÉ ENREGISTRÉE CHEZ GITEA.
  # Ce raccourci ne regardait que le client et ses retours ; les deux adresses que ce module ÉCRIT
  # dans le même fichier n'entraient pas dans la comparaison, donc une adresse publique qui change
  # ne convergeait jamais — l'apply répondait « déjà posé et vivant » sur un fichier devenu faux
  # (mesuré le 2026-08-21 : `public_url` resté sur la loopback après l'arrivée de `forge.public.url`).
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
    # `write:user` is the one scope this needs and the one the system token lacked before
    # 2026-08-12 — name it, because the API message alone sends the reader to the swagger page.
    p_fail "création du client OAuth2 refusée par la forge : $(echo "$resp" | head -c 200) (le token système a-t-il le scope write:user ?)"
    verdict_apply
  fi

  # ⚠ `ensure_dir`, PAS `install -d` : ce dernier ne passe pas par `prov_refuse_symlink_path`, donc
  # un lien pose dans un composant du chemin faisait chmoder sa CIBLE en root (vecteur 6-131). Le
  # repertoire — `/etc/lcars` — appartient a `25-directories`, qui le declare `0755 root:root`. Ce
  # site ne PASSE DONC PAS d'owner : il garantit l'existence et le mode avant d'ecrire, rien de plus.
  # Le lui faire revendiquer `root:root` en ferait une seconde autorite sur le meme objet — et ca se
  # voit tout de suite hors production, ou le proprietaire n'est pas root et ou le chown est refuse.
  ensure_dir "$(dirname "$PROV_DECK_OIDC_FILE")" 0755 \
    || { p_fail "répertoire de la config OIDC non convergé ($(dirname "$PROV_DECK_OIDC_FILE"))"; verdict_apply; }
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
