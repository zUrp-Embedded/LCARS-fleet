#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/48-forge-host.sh
# AUTHOR: DrDree
# STARDATE: (posée par /push-github)
# STATUS: PROTO-V2 — la forge du POSTE DE TRAVAIL : un conteneur Gitea, amorcé et structuré
# APPLY-ON: wsl
# CHECK-ON: wsl
# NEEDS: root
#
# ⚖ ARBITRAGE USER 2026-08-18 : « soit on fait rien, l'user clone et monte des bancs docker ; soit
# on installe et on crée la forge dans le pack ». C'est la seconde.
#
# POURQUOI CE MODULE EXISTE. Le rail poste-de-travail installe un LCARS qui TOURNE — release posée,
# `fleet_v2` câblé. Un LCARS qui tourne a besoin d'une forge : c'est là que vivent les projets, les
# tickets, les PR et les comptes de rôle. Sans elle, `50-forge` et `55-deck-oidc` restent en dérive
# et leurs consignes nomment `./docker.sh`, c'est-à-dire la BOÎTE — reconstruire et relancer un
# LCARS en conteneur pour tester celui qu'on vient d'installer nativement. Absurde, et mesuré tel
# quel le 2026-08-18 : 11 modules sur 13 convergés, ces deux-là seuls, pour cette seule raison.
#
# CE QU'IL N'EST PAS : un second chemin de forge. Il n'y a QU'UNE forge dans ce dépôt, et c'est un
# conteneur — `bench-up.sh` monte exactement la même. Ce module joue les mêmes gestes, sans boîte.
#
# ⚠ LA STRUCTURE EST POSÉE PAR UN RUN TRANSITOIRE DE L'IMAGE, et c'est possible parce que l'état de
# tofu est JETABLE PAR CONSTRUCTION : la recette reconstruit ce qui existe par ses blocs `import`
# (cf. forge-gestures.sh, et c'est pourquoi `--tofu-dir` est devenu un argument ignoré). Un
# `docker run --rm` part donc d'un tfstate vide, ce qui est le cas nominal et non un pis-aller.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

: "${PROV_FORGE_PROJECT:=lcars-forge}"          # projet compose de la forge du poste
: "${PROV_FORGE_HOST_PORT:=3000}"               # le port qu'elle publie sur la loopback
: "${PROV_FORGE_ADMIN:=admiral}"                # le compte qui ADMINISTRE la forge
: "${PROV_FORGE_IMAGE:=lcars-fleet:2}"          # l'image qui porte tofu, la recette et les gestes
: "${PROV_DOCKER_BIN:=docker}"

FORGE_NET="${PROV_FORGE_PROJECT}_default"
FORGE_CONTAINER="${PROV_FORGE_PROJECT}-forge-1"
MASTER_TOKEN_FILE="$PROV_TOKENS_DIR/forge-master.token"
SEED_FILE="$PROV_TOKENS_DIR/forge-seed.pass"
COMPOSE_FILE="$(repo_root)/fleet/deploy/docker/bench/forge-compose.yml"
LOCAL_URL="http://127.0.0.1:${PROV_FORGE_HOST_PORT}"

d() { "$PROV_DOCKER_BIN" "$@"; }
forge_up() { curl -fsS -m 5 -o /dev/null "$LOCAL_URL/api/v1/version" 2>/dev/null; }

check() {
  if ! command -v "$PROV_DOCKER_BIN" >/dev/null 2>&1; then
    p_drift "docker absent — la forge du poste est un CONTENEUR : sans lui, pas de forge, donc 50-forge et 55-deck-oidc resteront en dérive (Docker Desktop, intégration WSL)"
    verdict_check
  fi
  if forge_up; then
    p_ok "forge du poste vivante ($LOCAL_URL)"
    [[ -s "$MASTER_TOKEN_FILE" ]] && p_ok "autorité de création présente ($MASTER_TOKEN_FILE)" \
      || p_drift "forge vivante mais AUCUNE autorité ($MASTER_TOKEN_FILE) — l'apply la minte"
  else
    p_drift "aucune forge sur $LOCAL_URL — l'apply monte le conteneur, l'amorce et pose sa structure"
  fi
  verdict_check
}

apply() {
  if ! command -v "$PROV_DOCKER_BIN" >/dev/null 2>&1; then
    p_drift "docker absent — forge NON montée (Docker Desktop côté Windows, intégration WSL activée)"
    verdict_apply
  fi
  # L'IMAGE PORTE tofu, LA RECETTE ET LES GESTES. Sans elle il n'y a pas de structure à poser, et
  # le dire ici évite un `docker run` qui échouerait sur un « image inconnue » sans nommer le geste.
  if ! d image inspect "$PROV_FORGE_IMAGE" >/dev/null 2>&1; then
    p_drift "image $PROV_FORGE_IMAGE absente — elle porte tofu, la recette et les gestes de forge : « ./docker.sh build » d'abord, puis relance"
    verdict_apply
  fi

  # 1. LE CONTENEUR. `compose up -d` est idempotent : il ne recrée que si la déclaration a bougé.
  if ! forge_up; then
    p_step "forge du poste : montage du conteneur Gitea (projet $PROV_FORGE_PROJECT, port $PROV_FORGE_HOST_PORT)"
    LCARS_DEVFORGE_PORT="$PROV_FORGE_HOST_PORT" LCARS_DEVFORGE_BIND="127.0.0.1" \
    LCARS_DEVFORGE_ROOT_URL="$LOCAL_URL/" \
      run_quiet d compose -f "$COMPOSE_FILE" -p "$PROV_FORGE_PROJECT" up -d \
      || { p_fail "la forge ne monte pas (compose -p $PROV_FORGE_PROJECT)"; verdict_apply; }
    local i
    for i in $(seq 1 60); do forge_up && break; sleep 2; done
    forge_up || { p_fail "forge montée mais muette sur $LOCAL_URL après 120 s"; verdict_apply; }
    PROV_CHANGED=$((PROV_CHANGED + 1))
    p_chg "forge du poste montée ($LOCAL_URL)"
  else
    p_ok "forge du poste déjà vivante ($LOCAL_URL)"
  fi

  # 2. L'AUTORITÉ. Le compte d'administration et son jeton, mintés DANS le conteneur (`gitea admin`
  #    n'a pas besoin d'un jeton pour créer le premier). Le fichier est le même que celui que la
  #    boîte garde : `50-forge` le lit sans savoir qui l'a posé.
  if [[ ! -s "$MASTER_TOKEN_FILE" ]]; then
    p_step "forge du poste : compte d'administration « $PROV_FORGE_ADMIN » et jeton master"
    local pw; pw="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | head -c 20)"
    if ! d exec -u git "$FORGE_CONTAINER" gitea admin user create \
           --username "$PROV_FORGE_ADMIN" --password "$pw" \
           --email "$PROV_FORGE_ADMIN@lcars.local" --admin --must-change-password=false \
           >/dev/null 2>&1; then
      # Déjà là : on ne casse pas un compte existant, on lui refait juste un jeton.
      p_ok "compte « $PROV_FORGE_ADMIN » déjà présent sur la forge"
    fi
    local tok
    tok="$(d exec -u git "$FORGE_CONTAINER" gitea admin user generate-access-token \
             --username "$PROV_FORGE_ADMIN" --token-name "poste-$(date +%s)" --scopes all --raw \
             2>/dev/null | tail -n1 | tr -d '[:space:]')"
    [[ -n "$tok" ]] || { p_fail "la forge n'a rendu aucun jeton master pour $PROV_FORGE_ADMIN"; verdict_apply; }
    write_atomic "$MASTER_TOKEN_FILE" 0640 "root:$PROV_FLEET_GROUP" <<<"$tok" \
      || { p_fail "jeton master non posé ($MASTER_TOKEN_FILE)"; verdict_apply; }
    p_chg "autorité de création posée ($MASTER_TOKEN_FILE)"
  else
    p_ok "autorité de création déjà posée ($MASTER_TOKEN_FILE)"
  fi

  # 3. LE SEED. Il ne se REGÉNÈRE pas : le provider n'écrit pas le password d'un compte existant
  #    (mesure 2026-08-16), donc un seed neuf donnerait un fichier qui ne correspond plus aux
  #    comptes et le mint des jetons de rôle partirait en 401.
  if [[ ! -s "$SEED_FILE" ]]; then
    local seed; seed="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | head -c 20)"
    write_atomic "$SEED_FILE" 0640 "root:$PROV_FLEET_GROUP" <<<"$seed" \
      || { p_fail "seed non posé ($SEED_FILE)"; verdict_apply; }
    p_chg "seed des comptes posé ($SEED_FILE)"
  else
    p_ok "seed des comptes déjà posé ($SEED_FILE)"
  fi

  # 4. LE ROSTER, dérivé du catalogue que l'IMAGE porte — jamais de l'arbre de l'hôte, qui peut
  #    avoir bougé depuis le build, et dont les droits ferment la porte au conteneur.
  local enroll; enroll="$(mktemp -d "${TMPDIR:-/tmp}/prov-enroll.XXXXXX")"
  run_quiet env DOCKER_BIN="$PROV_DOCKER_BIN" \
      "$(repo_root)/fleet/etc/enroll-catalogue.sh" --tofu-dir "$enroll" --image "$PROV_FORGE_IMAGE" \
    || { p_fail "roster non dérivable de $PROV_FORGE_IMAGE"; rm -rf "$enroll"; verdict_apply; }
  [[ -s "$enroll/roles.auto.tfvars.json" ]] \
    || { p_fail "roster vide — la recette serait appliquée sans comptes"; rm -rf "$enroll"; verdict_apply; }

  # 5. LA STRUCTURE, par un run TRANSITOIRE de l'image (porte `forge-apply` de l'entrypoint).
  #    Le conteneur rejoint le réseau de la forge : `forge` y résout, comme pour la boîte.
  p_step "forge du poste : pose de la structure (orgs, comptes de rôle, teams, dépôt modèle)"
  run_step "structure de la forge" -- \
    d run --rm --network "$FORGE_NET" \
      -v "$PROV_TOKENS_DIR:$PROV_TOKENS_DIR" \
      -v "$enroll/roles.auto.tfvars.json:/opt/lcars/fleet/deploy/deps/roles.auto.tfvars.json:ro" \
      -e FORGE_BASE_URL="http://forge:3000" \
      -e LCARS_BUILTIN_HUMAN="$PROV_HUMAN" \
      "$PROV_FORGE_IMAGE" forge-apply \
    || { p_fail "structure NON posée — relis la sortie, rien n'est supposé"; rm -rf "$enroll"; verdict_apply; }
  rm -rf "$enroll"
  PROV_CHANGED=$((PROV_CHANGED + 1))
  p_chg "structure de la forge posée — 50-forge peut minter les jetons de rôle"
  verdict_apply
}

case "${1:?usage: 48-forge-host.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
