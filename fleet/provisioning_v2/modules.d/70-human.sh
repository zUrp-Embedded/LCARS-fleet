#!/usr/bin/env bash
# SOURCE: fleet/provisioning_v2/modules.d/70-human.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — enrôlement per-humain : ~/.lcars, ~/pods, env seed-once, sondes creds (instruct-only)
# SUBSTRATE: any
# NEEDS: human
#
# Chaque humain lance SA fleet (modèle ADR-E) : ce module pose SON état et sonde SES accès.
#   - ~/.lcars (0700) : l'état runtime per-humain (state, socks, logs — fleet_v2 y défaute tout) ;
#   - ~/pods (0700) : les pod_dirs (isolés par l'ownership OS, jamais sous /tmp que le tmpfs
#     bwrap orphelinerait) ;
#   - ~/.lcars/fleet_v2.env : SEED-ONCE depuis le template du prefix, FORGE_BASE_URL injecté si
#     connu — puis PLUS JAMAIS touché (c'est le fichier de l'humain, pas le nôtre : un re-run qui
#     l'écraserait détruirait ses réglages — la leçon anti-« ALL OR NOTHING » de mail-in-a-box) ;
#   - les CREDENTIALS sont sondés, JAMAIS posés : le wizard claude (`claude` puis /login) et le
#     token forge opérateur (~/.gitea_token) sont des gestes d'IDENTITÉ de l'humain. La v1
#     enchâssait le wizard interactif DANS le provisioning (read /dev/tty, sudo -iu … claude) :
#     non-automatisable et faux-idempotent. Ici : un verdict + la consigne exacte.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

HOME_DIR="$(human_home)"
ENV_FILE="$HOME_DIR/.lcars/fleet_v2.env"
TEMPLATE="$PROV_PREFIX/etc/fleet_v2.env.template"

# Sondes d'identité — verdicts + consignes, AUCUNE mutation, TOUJOURS en warn : les credentials
# sont des gestes de l'humain, un apply ne peut ni les converger ni échouer dessus.
probe_identity() {
  if [[ -f "$HOME_DIR/.claude/.credentials.json" ]]; then
    p_ok "credentials claude présentes (wizard fait)"
  else
    p_warn "credentials claude absentes — l'humain lance « claude », /login, bonjour, /exit (geste d'identité, jamais automatisé)"
  fi
  if [[ -r "$HOME_DIR/.gitea_token" ]]; then
    local tok code
    tok="$(tr -d '[:space:]' < "$HOME_DIR/.gitea_token")"
    if [[ -n "$PROV_FORGE_URL" && -n "$tok" ]]; then
      code="$(curl -s -o /dev/null -w '%{http_code}' -m 10 -H "Authorization: token $tok" "$PROV_FORGE_URL/api/v1/user" 2>/dev/null || echo 000)"
      if [[ "$code" == "200" ]]; then
        p_ok "token forge opérateur valide ($HOME_DIR/.gitea_token)"
      else
        p_warn "$HOME_DIR/.gitea_token présent mais la forge répond $code — token mort ? (mint : Settings→Applications sur $PROV_FORGE_URL)"
      fi
    else
      p_ok "$HOME_DIR/.gitea_token présent (forge non sondable : URL absente)"
    fi
  else
    p_warn "$HOME_DIR/.gitea_token absent — token du compte OPÉRATEUR de $PROV_HUMAN sur la forge (Settings→Applications), contrat FORGE_TOKEN_FILE"
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
        sed "s|^FORGE_BASE_URL=.*|FORGE_BASE_URL=$PROV_FORGE_URL|" "$TEMPLATE" > "$tmp"
      else
        cat "$TEMPLATE" > "$tmp"
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
