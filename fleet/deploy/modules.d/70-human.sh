#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/70-human.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — enrôlement per-humain : ~/.lcars, ~/pods, env seed-once, sondes creds (instruct-only)
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: human
#
# Chaque humain lance SA fleet (modèle ADR-E) : ce module pose SON état et sonde SES accès.
#   - ~/.lcars (0700) : l'état runtime per-humain (state, socks, logs — fleet_v2 y défaute tout) ;
#   - ~/pods (0700) : les pod_dirs (isolés par l'ownership OS, jamais sous /tmp que le tmpfs
#     bwrap orphelinerait) ;
#   - ~/.lcars/fleet_v2.env : SEED-ONCE depuis le template du prefix, FORGE_BASE_URL injecté si
#     connu — puis PLUS JAMAIS touché (c'est le fichier de l'humain, pas le nôtre : un re-run qui
#     l'écraserait détruirait ses réglages — la leçon anti-« ALL OR NOTHING » de mail-in-a-box) ;
#   - le credential CLAUDE est sondé, JAMAIS posé : le wizard (`claude` puis /login) est un geste
#     d'IDENTITÉ de la personne, et lui seul. La v1 enchâssait le wizard interactif DANS le
#     provisioning (read /dev/tty, sudo -iu … claude) : non-automatisable et faux-idempotent.
#     Ici : un verdict + la consigne exacte.
#   - le credential FORGE, lui, n'est PAS un geste de la personne : la fleet signe avec le jeton
#     SYSTÈME, câblé plus bas (cas D4). Ce module réclamait en plus un `~/.gitea_token` minté à la
#     main — un fichier que le runtime n'ouvre qu'à défaut de ce câblage, donc jamais. La sonde
#     porte désormais sur ce qui est réellement lu, et ne demande plus rien à personne.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

HOME_DIR="$(human_home)"
ENV_FILE="$HOME_DIR/.lcars/fleet_v2.env"
TEMPLATE="$PROV_PREFIX/etc/fleet_v2.env.template"

# Sondes d'identité — verdicts + consignes, AUCUNE mutation, TOUJOURS en warn : les credentials
# sont des gestes de l'humain, un apply ne peut ni les converger ni échouer dessus.
probe_identity() {
  # « PRÉSENTES » ET NON « VALIDES », ET LA NUANCE N'EST PAS DE LA PRUDENCE. Mesuré le 2026-08-09 :
  # un fichier complet de forme (scopes, subscriptionType, refreshTokenExpiresAt dans le futur) dont
  # les DEUX jetons faisaient zéro octet. Cette ligne annonçait « wizard fait », la fleet montait, et
  # chaque spawn mourait en `credentials_invalid`.
  #
  # ON NE PARSE PAS LE FICHIER ICI, DÉLIBÉRÉMENT. Sa forme appartient au vendor ; la relire en shell
  # revient à recopier son format dans notre provisioning et à le patcher à chaque fois qu'il bouge.
  # L'autorité existe et c'est `Fleet.Credentials.Gate.status/1`, qui tranche au spawn. Cette sonde
  # dit donc ce qu'elle SAIT — le fichier est là — et nomme qui tranche.
  #
  # ⚠ Le refresh est porté par un agent VIVANT. Une fleet restée sans aucun pod au-delà de la
  # fenêtre ne se rafraîchit pas toute seule : `starfleet` est toujours-up, et c'est ce qui garde
  # les credentials en vie autant que c'est un choix d'ergonomie.
  if [[ -f "$HOME_DIR/.claude/.credentials.json" ]]; then
    p_ok "fichier de credentials claude présent — sa VALIDITÉ est tranchée au spawn par le runtime (Credentials.Gate), pas ici"
  else
    p_warn "credentials claude absentes — l'humain lance « claude », /login, bonjour, /exit (geste d'identité, jamais automatisé)"
  fi
  # ON NE DEMANDE PLUS DE JETON FORGE À LA PERSONNE, PARCE QUE RIEN NE LE LISAIT. Cette sonde
  # l'envoyait dans Settings→Applications minter un `~/.gitea_token` — alors que ce module CÂBLE
  # `FORGE_TOKEN_FILE` sur le jeton système dans son propre `fleet_v2.env` (cas D4 plus bas), et que
  # le runtime ne descend sur `~/.gitea_token` qu'en dernier recours, faute de ce câblage. Une
  # consigne pour un fichier que la fleet n'ouvre jamais : le geste demandé était du travail mort.
  #
  # La question qui compte, et qui n'était posée nulle part, est celle-ci : la fleet de cette
  # personne a-t-elle un credential forge CÂBLÉ et VIVANT ? On la pose donc sur ce qui est
  # réellement lu.
  local tokfile tok code
  tokfile="$(sed -n 's/^FORGE_TOKEN_FILE=//p' "$ENV_FILE" 2>/dev/null | tail -n1)"
  if [[ -z "$tokfile" ]]; then
    p_warn "aucun FORGE_TOKEN_FILE dans $ENV_FILE — la fleet retomberait sur ~/.gitea_token ; c'est le token système qui doit être câblé (50-forge puis re-apply)"
  elif [[ ! -r "$tokfile" ]]; then
    p_warn "FORGE_TOKEN_FILE=$tokfile illisible par $PROV_HUMAN — la fleet ne pourra pas parler à la forge (groupe $PROV_FLEET_GROUP ?)"
  elif [[ -z "$PROV_FORGE_URL" ]]; then
    p_ok "credential forge de la fleet câblé et lisible ($tokfile ; forge non sondable : URL absente)"
  else
    tok="$(tr -d '[:space:]' < "$tokfile")"
    code="$(curl -s -o /dev/null -w '%{http_code}' -m 10 -H "Authorization: token $tok" "$PROV_FORGE_URL/api/v1/user" 2>/dev/null || echo 000)"
    if [[ "$code" == "200" ]]; then
      p_ok "credential forge de la fleet valide ($tokfile)"
    else
      p_warn "$tokfile présent mais la forge répond $code — token mort ; re-mint par 50-forge (jamais un geste de $PROV_HUMAN)"
    fi
  fi
}

check() {
  [[ -n "$HOME_DIR" && -d "$HOME_DIR" ]] || { p_fail "home de $PROV_HUMAN introuvable"; verdict_check; }

  local d
  for d in "$HOME_DIR/.lcars" "$HOME_DIR/pods"; do
    if [[ -d "$d" && "$(stat -c '%a %U' "$d")" == "700 $PROV_HUMAN" ]]; then
      p_ok "$d (0700 $PROV_HUMAN)"
    else
      p_drift "$d absent ou pas 0700 $PROV_HUMAN"
    fi
  done

  if [[ -f "$ENV_FILE" ]]; then
    if grep -q '^FORGE_BASE_URL=' "$ENV_FILE"; then
      p_ok "fleet_v2.env présent (FORGE_BASE_URL posé)"
    else
      # Drift au DOCTOR (fleet_v2 start refusera : c'est un état non-conforme VRAI), mais le
      # fichier est à l'humain : l'apply n'y touche pas, il n'y a que lui pour l'éditer.
      p_drift "fleet_v2.env présent mais FORGE_BASE_URL manquant — fleet_v2 start refusera ; édite $ENV_FILE"
    fi
    # D4, cas env-seedé-AVANT-bootstrap (l'ordre du cold boot docker : le premier boot seed
    # l'env, la forge n'est bootstrappée qu'après) : le fichier est à l'humain, on ne le
    # réécrit JAMAIS — on instruit les 2 lignes exactes. Révélé par le run de validation.
    if [[ -r "$PROV_TOKENS_DIR/system.gitea_token" ]] && ! grep -q '^FORGE_TOKEN_FILE=' "$ENV_FILE"; then
      p_warn "token système minté mais non câblé dans $ENV_FILE — ajoute : FORGE_TOKEN_FILE=$PROV_TOKENS_DIR/system.gitea_token et FORGE_BOT_LOGIN=$PROV_SYSTEM_ACCOUNT (puis fleet_v2 stop/start)"
    fi
  else
    p_drift "fleet_v2.env absent ($ENV_FILE)"
  fi

  probe_identity
  verdict_check
}

apply() {
  [[ -n "$HOME_DIR" && -d "$HOME_DIR" ]] || { p_fail "home de $PROV_HUMAN introuvable"; verdict_apply; }

  as_human mkdir -p "$HOME_DIR/.lcars" "$HOME_DIR/.lcars/log" "$HOME_DIR/pods" || { p_fail "mkdir ~/.lcars ~/pods"; verdict_apply; }
  as_human chmod 0700 "$HOME_DIR/.lcars" "$HOME_DIR/pods" || { p_fail "chmod 0700"; verdict_apply; }

  # Seed-once de l'env : SI absent ET template déployé. On injecte FORGE_BASE_URL si connu
  # (le template le laisse en exemple NAS) — après ce seed, le fichier appartient à l'humain.
  if [[ ! -f "$ENV_FILE" ]]; then
    if [[ -r "$TEMPLATE" ]]; then
      local tmp
      tmp="$(as_human mktemp "$HOME_DIR/.lcars/.env.XXXXXX")" || { p_fail "tmp env"; verdict_apply; }
      if [[ -n "$PROV_FORGE_URL" ]]; then
        # Le template ne porte AUCUN FORGE_BASE_URL actif (une valeur en dur viserait une forge
        # réelle pour toute boîte seedée) : l'URL connue du provisioning s'APPEND. Un sed sur la
        # ligne du template réécrirait du commentaire et n'injecterait rien.
        { cat "$TEMPLATE"; echo ""; echo "FORGE_BASE_URL=$PROV_FORGE_URL"; } > "$tmp"
      else
        cat "$TEMPLATE" > "$tmp"
      fi
      # L'exposition des listeners est une propriété du DÉPLOIEMENT, pas de l'humain : le runtime
      # lie en loopback par défaut, ce qui dans un conteneur rend le deck injoignable depuis un
      # navigateur (la loopback est celle du conteneur). Elle voyage donc par l'environnement du
      # substrat — et doit atterrir ICI, parce que `fleet_v2` lit ce fichier et non l'environnement
      # du conteneur : un `su - <humain>` repart d'un environnement vierge.
      if [[ -n "${LCARS_BIND_HOST:-}" ]]; then
        { echo ""; echo "LCARS_BIND_HOST=$LCARS_BIND_HOST"; } >> "$tmp"
      fi
      # D4 (ADR install/compile/release) : ce que le système fait est signé du SYSTÈME. Si le
      # token lcars-system est déjà minté (bootstrap forge fait avant ce seed — l'ordre 50<70
      # du cycle), on câble sa lecture ICI ; sinon le token minté ne serait jamais lu (le
      # défaut runtime est ~/.gitea_token) — le travail mort que l'ADR pointait.
      if [[ -r "$PROV_TOKENS_DIR/system.gitea_token" ]]; then
        {
          echo ""
          echo "# — posé par le seed 70-human (D4) : les marqueurs système sont signés lcars-system —"
          echo "FORGE_TOKEN_FILE=$PROV_TOKENS_DIR/system.gitea_token"
          echo "FORGE_BOT_LOGIN=$PROV_SYSTEM_ACCOUNT"
        } >> "$tmp"
      fi
      as_human chmod 0600 "$tmp"
      as_human mv -f "$tmp" "$ENV_FILE"
      PROV_CHANGED=$((PROV_CHANGED + 1))
      p_chg "fleet_v2.env seedé depuis le template${PROV_FORGE_URL:+ (FORGE_BASE_URL=$PROV_FORGE_URL)} — désormais À L'HUMAIN, plus jamais réécrit ici"
    else
      p_fail "template absent ($TEMPLATE) — lance d'abord 60-deploy"
    fi
  elif ! grep -q '^FORGE_BASE_URL=' "$ENV_FILE"; then
    # L'apply ne réécrit JAMAIS le fichier de l'humain : il converge SA part et DIT le reste.
    p_warn "fleet_v2.env sans FORGE_BASE_URL — fleet_v2 start refusera ; édite $ENV_FILE (le doctor le comptera en drift tant que ce n'est pas fait)"
  fi

  probe_identity
  verdict_apply
}

case "${1:?usage: 70-human.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
