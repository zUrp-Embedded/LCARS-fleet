#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/48-forge-host.sh
# AUTHOR: DrDree
# STARDATE: (posée par /push-github)
# STATUS: PROTO-V2 — la forge du POSTE DE TRAVAIL : un conteneur Gitea, amorcé et structuré
# APPLY-ON: wsl linux
# CHECK-ON: wsl linux
# NEEDS: root
#
# ⚖ ARBITRAGE USER 2026-08-18 : « soit on fait rien, l'user clone et monte des bancs docker ; soit
# on installe et on crée la forge dans le pack ». C'est la seconde.
#
# ⚠ `wsl linux` ET PAS `wsl` : le terrain de ce module est LE RAIL POSTE, pas un noyau. Il a porté
# `wsl` seul pendant deux jours, et rien dans son corps ne le justifiait — `docker_endpoint` est
# déjà substrat-conscient (il choisit son refus selon le terrain), l'adresse est `127.0.0.1`, le
# compose vient du dépôt. Le seul pré-requis réel est l'image `lcars-fleet:2`, qui porte tofu, la
# recette et les gestes, et son absence est déjà une dérive NOMMÉE plus bas.
#
# CE QUE LE GATE `wsl` A COÛTÉ, mesuré le 2026-08-20 : une install native s'est faite à la main —
# conteneur Gitea, compte d'administration, jeton master, amorçage en deux passes — c'est-à-dire
# que les gestes de ce fichier ont été rejoués un par un par un opérateur qui le croyait absent.
# Un module qui refuse un terrain où il fonctionne n'économise rien : il déplace le travail vers
# quelqu'un qui le fera moins bien, et sans convergence.
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
: "${PROV_FORGE_HOST_PORT:=3000}"               # le port qu'elle publie
: "${PROV_FORGE_ADMIN:=admiral}"                # le compte qui ADMINISTRE la forge
: "${PROV_FORGE_IMAGE:=lcars-fleet:2}"          # l'image qui porte tofu, la recette et les gestes
: "${PROV_DOCKER_BIN:=docker}"

# ─── DEUX ADRESSES, ET LES CONFONDRE CASSE LA MOITIÉ DES LIENS ─────────────────────────────────
# `bench-up.sh` a déjà payé cette leçon et l'a écrite : « LE RECAP DIT L'ADRESSE QU'ON COMPOSE, PAS
# CELLE SUR LAQUELLE ON ECOUTE. » Ce module n'avait ni l'une ni l'autre — il câblait `127.0.0.1`
# aux deux endroits.
#
#   PROV_FORGE_BIND       l'interface sur laquelle docker PUBLIE le port. C'est une décision de
#                         sécurité : `127.0.0.1` = cette machine seule, `0.0.0.0` = le réseau.
#   PROV_FORGE_ADVERTISE  l'adresse qu'on ÉCRIT dans `ROOT_URL`. Gitea s'en sert pour tous ses
#                         liens, ses URLs de clone et ses retours OAuth. Ouvrir le bind sans la
#                         bouger donne une UI joignable dont chaque lien pointe sur la loopback du
#                         visiteur — cassée depuis toute autre machine.
#
# ⚖ LE DÉFAUT EST OUVERT, ET LE CONTRAIRE ÉTAIT UN DÉFAUT CASSÉ (user 2026-08-21 : « un container
# docker inaccessible sur le réseau ET MÊME PAR SON RUNNER, ça sert à quoi ? »).
#
# Ce module a publié en loopback seul pendant trois jours, sous couvert de prudence. Or la carte
# canon déclare `ci: required` : sans runner, chaque PR attend un statut 45 min puis ESCALADE, et
# rien ne se livre. Et un runner n'atteint PAS une forge en loopback — ses conteneurs de job vivent
# sur un réseau par job, où `127.0.0.1` les désigne eux-mêmes ; un port publié sur la loopback de
# l'hôte n'est pas routable depuis la passerelle du bridge. Une forge fermée n'est donc pas une
# forge prudente : c'est une forge qui ne peut pas faire son travail.
#
# Fermer reste possible — `PROV_FORGE_BIND=127.0.0.1` — mais c'est le geste, pas le défaut, et il
# prive la machine de sa CI. `bench-up.sh` a tranché pareil et porte le coût écrit : les mots de
# passe d'un banc sont des défauts de test, publics dans le README, donc à n'ouvrir que sur un
# réseau de confiance. Ici les comptes sont ceux de l'opérateur : même prudence, même conclusion.
#
# ⚠ ET SOUS WSL L'OUVERTURE NE DONNE RIEN SUR LE LAN, ce qui compte pour ne pas la promettre : en
# NAT — le défaut de WSL et de Docker Desktop — publier sur `0.0.0.0` ouvre le port DANS la VM, pas
# sur la machine Windows. ⚖ user 2026-08-18, porté mot pour mot par `bench-up.sh` ; on ne le
# re-découvre pas ici. Le runner, lui, tourne dans cette même VM : il y atteint la forge.
: "${PROV_FORGE_BIND:=0.0.0.0}"
: "${PROV_FORGE_ADVERTISE:=$PROV_FORGE_BIND}"
# Un joker d'écoute n'est pas une adresse qu'on compose : si on annonce `0.0.0.0`, on retombe sur
# l'adresse de sortie de la machine, qui est ce qu'un tiers peut réellement taper.
case "$PROV_FORGE_ADVERTISE" in
  0.0.0.0|::|"") PROV_FORGE_ADVERTISE="$(lan_addr 2>/dev/null || true)"
                 [[ -n "$PROV_FORGE_ADVERTISE" ]] || PROV_FORGE_ADVERTISE=127.0.0.1 ;;
esac

FORGE_NET="${PROV_FORGE_PROJECT}_default"
FORGE_CONTAINER="${PROV_FORGE_PROJECT}-forge-1"
MASTER_TOKEN_FILE="$PROV_TOKENS_DIR/forge-master.token"
SEED_FILE="$PROV_TOKENS_DIR/forge-seed.pass"
COMPOSE_FILE="$(repo_root)/fleet/deploy/docker/bench/forge-compose.yml"
# ⚠ DEUX URLS, ET CHACUNE A UN SEUL LECTEUR LÉGITIME.
#   LOCAL_URL   par où CE module et ses voisins parlent à la forge — toujours la loopback, parce
#               qu'ils tournent sur la machine. C'est elle qui va dans `forge.url`, lue par
#               `50-forge` et `55-deck-oidc`, et c'est elle que sonde `forge_up`. Elle ne dépend pas
#               de ce qu'on publie : une forge ouverte au réseau reste joignable en local.
#   PUBLIC_URL  ce que Gitea écrit dans ses liens, ses URLs de clone et ses retours OAuth. C'est
#               l'adresse qu'un TIERS compose — un navigateur, un `git clone`, un conteneur de job.
LOCAL_URL="http://127.0.0.1:${PROV_FORGE_HOST_PORT}"
PUBLIC_URL="http://${PROV_FORGE_ADVERTISE}:${PROV_FORGE_HOST_PORT}"

d() { "$PROV_DOCKER_BIN" "$@"; }
forge_up() { curl -fsS -m 5 -o /dev/null "$LOCAL_URL/api/v1/version" 2>/dev/null; }

# LE VERDICT DIT SUR QUOI ELLE ÉCOUTE, parce que c'est la seule chose qu'un opérateur ne peut pas
# deviner en la voyant répondre en local. Une forge ouverte au réseau et une forme fermée rendent
# le même `200` sur la loopback.
forge_reach_note() {
  case "$PROV_FORGE_BIND" in
    127.0.0.1|localhost|::1) printf ' — cette machine SEULE' ;;
    *) printf ' — OUVERTE sur %s, composable en %s' "$PROV_FORGE_BIND" "$PUBLIC_URL" ;;
  esac
}

check() {
  if ! docker_endpoint; then
    # Même mot que 00-preflight, et pour la même raison : ce rail ne PEUT pas tenir son état-cible
    # sans docker, donc ce n'est pas une dérive. Le préflight refuse déjà en amont ; si on arrive
    # ici quand même, on ne se contredit pas.
    p_fail "$PROV_DOCKER_WHY — la forge du poste est un CONTENEUR, il n'en existe aucune autre forme"
    verdict_check
  fi
  if forge_up; then
    p_ok "forge du poste vivante ($LOCAL_URL)$(forge_reach_note)"
    [[ -s "$MASTER_TOKEN_FILE" ]] && p_ok "autorité de création présente ($MASTER_TOKEN_FILE)" \
      || p_drift "forge vivante mais AUCUNE autorité ($MASTER_TOKEN_FILE) — l'apply la minte"
  else
    p_drift "aucune forge sur $LOCAL_URL — l'apply monte le conteneur, l'amorce et pose sa structure"
  fi
  verdict_check
}

apply() {
  if ! docker_endpoint; then
    p_fail "$PROV_DOCKER_WHY — forge NON montée, et elle ne peut pas l'être autrement"
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
    LCARS_DEVFORGE_PORT="$PROV_FORGE_HOST_PORT" LCARS_DEVFORGE_BIND="$PROV_FORGE_BIND" \
    LCARS_DEVFORGE_ROOT_URL="$PUBLIC_URL/" \
      run_quiet d compose -f "$COMPOSE_FILE" -p "$PROV_FORGE_PROJECT" up -d \
      || { p_fail "la forge ne monte pas (compose -p $PROV_FORGE_PROJECT)"; verdict_apply; }
    local i
    for i in $(seq 1 60); do forge_up && break; sleep 2; done
    forge_up || { p_fail "forge montée mais muette sur $LOCAL_URL après 120 s"; verdict_apply; }
    PROV_CHANGED=$((PROV_CHANGED + 1))
    p_chg "forge du poste montée ($LOCAL_URL)$(forge_reach_note)"
  else
    p_ok "forge du poste déjà vivante ($LOCAL_URL)$(forge_reach_note)"
  fi

  # 1-bis. ELLE ANNONCE SON ADRESSE, parce que personne d'autre ne peut le faire pour elle. Les
  #    modules sont des PROCESSUS : ce shell ne peut rien exporter vers `50-forge`. Sans ce fichier,
  #    une install qui vient de monter une forge vivante voit `50-forge` et `55-deck-oidc` dériver
  #    sur « FORGE_BASE_URL non posé » — mesuré le 2026-08-18. 0644 : c'est une ADRESSE, pas un
  #    secret, et le doctor d'un humain doit pouvoir la lire.
  write_atomic "$PROV_TOKENS_DIR/forge.url" 0644 "root:$PROV_FLEET_GROUP" <<<"$LOCAL_URL" \
    || { p_fail "adresse de la forge non posée ($PROV_TOKENS_DIR/forge.url)"; verdict_apply; }

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
    # ⚠ SONDER LE FLUX AVANT DE CAPTURER — sinon le diagnostic accuse la forge, qui est saine.
    # Un relais docker peut répondre parfaitement à `version`/`ps`/`inspect` et rendre ZÉRO OCTET,
    # EXIT 0, sur `exec`. La capture ci-dessous devient alors une chaîne vide, et le refus juste en
    # dessous dit « la forge n'a rendu aucun jeton master » — un diagnostic faux, sur un objet sain,
    # exactement celui que `bench-up.sh` a payé et documenté. La sonde est un aller-retour RÉEL.
    docker_stream_ok "$FORGE_CONTAINER" || {
      p_fail "le daemon docker répond aux lectures mais rend du VIDE sur « exec » (relais amputé) — rien ne peut être capturé depuis $FORGE_CONTAINER, et la forge n'y est pour rien. Vise la socket Docker Desktop directement : DOCKER_HOST=unix://$(_docker_mount_sock)"
      verdict_apply
    }
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

  # 5. LA STRUCTURE, par un conteneur TRANSITOIRE de l'image (porte `forge-apply` de l'entrypoint).
  #
  # ⚠ AUCUN BIND D'UN CHEMIN DE L'HÔTE, ET CE N'EST PAS UNE PRÉFÉRENCE. Le daemon peut vivre
  # ailleurs que sur cette machine — sous Docker Desktop il est dans une autre VM — et un chemin
  # d'hôte lui est alors INVISIBLE : il crée un répertoire vide à sa place, EN SILENCE. Mesuré ici
  # le 2026-08-18 : `-v /home/private:/home/private` donnait au conteneur un dossier vide, et le
  # geste répondait « la boîte ne détient pas ce qu'il faut » en nommant des fichiers qui existaient
  # à trente centimètres. `bench-runner.sh` porte déjà cet avertissement mot pour mot ; j'y suis
  # entré quand même.
  #
  # La forme qui traverse : `docker create` → `docker cp` → `docker start`. `cp` passe par l'API du
  # daemon, donc il atteint le conteneur où qu'il soit. Le volume nommé porte l'autorité (un objet
  # du daemon, pas un chemin), et il est monté HORS de `/home` — que l'image déclare déjà comme
  # volume. `LCARS_PRIVATE_DIR` dit au geste où regarder ; il l'accepte depuis toujours.
  p_step "forge du poste : pose de la structure (orgs, comptes de rôle, teams, dépôt modèle)"
  local vol="${PROV_FORGE_PROJECT}-authority" cid rc=0
  d volume create "$vol" >/dev/null 2>&1 || true
  cid="$(d create --network "$FORGE_NET" \
        -v "$vol:/authority" \
        -e LCARS_PRIVATE_DIR=/authority \
        -e FORGE_BASE_URL="http://forge:3000" \
        -e LCARS_BUILTIN_HUMAN="$PROV_HUMAN" \
        "$PROV_FORGE_IMAGE" forge-apply 2>/dev/null)"
  [[ -n "$cid" ]] || { p_fail "conteneur de pose non créable ($PROV_FORGE_IMAGE)"; rm -rf "$enroll"; verdict_apply; }
  {
    d cp "$MASTER_TOKEN_FILE" "$cid:/authority/forge-master.token" &&
    d cp "$SEED_FILE"         "$cid:/authority/forge-seed.pass" &&
    d cp "$enroll/roles.auto.tfvars.json" "$cid:/opt/lcars/fleet/deploy/deps/roles.auto.tfvars.json"
  } >/dev/null 2>&1 \
    || { p_fail "autorité/roster non déposés dans le conteneur de pose"; d rm -f "$cid" >/dev/null 2>&1; rm -rf "$enroll"; verdict_apply; }
  run_step "structure de la forge" -- d start -a "$cid" || rc=$?
  d rm -f "$cid" >/dev/null 2>&1 || true
  rm -rf "$enroll"
  [[ "$rc" -eq 0 ]] \
    || { p_fail "structure NON posée (rc=$rc) — relis la sortie, rien n'est supposé"; verdict_apply; }
  PROV_CHANGED=$((PROV_CHANGED + 1))
  p_chg "structure de la forge posée — 50-forge peut minter les jetons de rôle"
  verdict_apply
}

case "${1:?usage: 48-forge-host.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
