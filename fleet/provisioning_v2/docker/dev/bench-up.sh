#!/usr/bin/env bash
# SOURCE: fleet/provisioning_v2/docker/dev/bench-up.sh
# AUTHOR: DrDree
# STARDATE: 2026-08-03
# STATUS: geste de BANC — monte un banc COMPLET (forge jetable + boite + amorcage) en une commande
#
# ─── POURQUOI CE FICHIER EXISTE ─────────────────────────────────────────────────────────────────
# `bench-forge-bootstrap.sh` amene une forge NEUVE a l'etat "la fleet peut travailler dessus", et
# son en-tete dit pourquoi chacun de ses gestes existe. Mais il suppose la forge et la boite DEJA
# montees, connectees, et il faut le jouer DEUX FOIS (le semis des depots exige un token systeme
# que la boite ne minte qu'au boot SUIVANT le seed). Cette chorégraphie — quel projet compose, quel
# port, quel reseau brancher a quel moment, quand relancer la boite — vivait dans la memoire de la
# session qui l'avait faite. C'est exactement le defaut que bootstrap corrigeait pour la forge, un
# cran plus haut. Ici, la sequence complete.
#
# ─── LES QUATRE PIEGES QUE CE SCRIPT DESAMORCE, ET QU'UN LECTEUR NE DEVINE PAS ──────────────────
# 1. LA BOITE DOIT ETRE SUR LE RESEAU DE LA FORGE AVANT DE DEMARRER. `FORGE_BASE_URL=http://forge:3000`
#    ne resout que depuis le reseau du projet forge, et le compose de la boite ne connait pas ce
#    reseau. D'ou `create` → `network connect` → `start` plutot qu'un `up` : un `up` demarre la
#    boite sur un nom qui ne resout pas, et tout le provisioning forge part en drift au premier boot.
# 2. LE SEMIS EXIGE UN SECOND PASSAGE. `50-forge` minte les role-tokens au boot, a partir du seed
#    que bootstrap vient de poser — donc APRES ce boot-la. Le premier passage pose la structure et
#    saute le semis en le DISANT ; on relance la boite ; le second passage seme. Deux passages, pas
#    une boucle de retry : chacun est idempotent et le deuxieme dit la verite sur le premier.
# 3. LES CREDS ANTHROPIC SONT LA CONDITION DE VIE DES PODS. Sans `~/.claude/.credentials.json` chez
#    l'humain du runtime, `Credentials.Gate.validate` refuse au spawn-boundary et AUCUN pod ne
#    demarre — la fleet a l'air saine et ne produit rien. Elles sont copiees depuis l'humain de
#    l'HOTE ; c'est un geste de banc (le lien Anthropic est un compte, pas un artefact du projet).
# 4. UN BANC NE DOIT JAMAIS COGNER LE BANC D'A COTE. Projet compose, port de forge et adresse de
#    bind sont TOUS parametres et defaultent sur des valeurs libres. Le geste destructeur (`down -v`)
#    n'est pas ici : il est dans `bench-down.sh`, separement, pour qu'aucune faute de frappe sur ce
#    script-ci ne detruise un banc qui travaille.
#
# USAGE : bench-up.sh [--project lcars-nuit] [--forge-port 3700] [--bind 127.0.0.5]
#                     [--image lcars-fleet:2] [--creds-from ~/.claude/.credentials.json] [--no-creds]
# EXIT  : 0 banc pret · 1 arguments/dependance · 2 la forge ne monte pas · 3 la boite ne monte pas
#         4 amorcage forge · 5 creds · 6 le verdict final ne passe pas

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(cd "$HERE/.." && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"

PROJECT="lcars-nuit"
FORGE_PORT="3700"
BIND="127.0.0.5"
IMAGE="lcars-fleet:2"
CREDS_FROM="$HOME/.claude/.credentials.json"
WITH_CREDS=1
HUMAN="lcars"
DOCKER_BIN="${DOCKER_BIN:-docker}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)    PROJECT="${2:?}"; shift 2 ;;
    --forge-port) FORGE_PORT="${2:?}"; shift 2 ;;
    --bind)       BIND="${2:?}"; shift 2 ;;
    --image)      IMAGE="${2:?}"; shift 2 ;;
    --creds-from) CREDS_FROM="${2:?}"; shift 2 ;;
    --no-creds)   WITH_CREDS=0; shift ;;
    --human)      HUMAN="${2:?}"; shift 2 ;;
    -h|--help)    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "bench-up: option inconnue: $1" >&2; exit 1 ;;
  esac
done

FORGE_PROJECT="${PROJECT}forge"
FORGE_CONTAINER="${FORGE_PROJECT}-forge-1"
BOX="${PROJECT}-lcars-1"
FORGE_NET="${FORGE_PROJECT}_default"
FORGE_URL="http://127.0.0.1:${FORGE_PORT}"

say() { printf '[bench-up] %s\n' "$*"; }
die() { printf '[bench-up] %s\n' "$*" >&2; exit "${2:-1}"; }

command -v "$DOCKER_BIN" >/dev/null || die "docker introuvable (DOCKER_BIN=$DOCKER_BIN)"

# Refus net plutot qu'un ecrasement silencieux : ce script MONTE, il ne remplace pas.
if "$DOCKER_BIN" ps -a --format '{{.Names}}' | grep -qx "$BOX"; then
  die "le projet $PROJECT existe deja ($BOX) — detruis-le d'abord (bench-down.sh) ou change --project" 1
fi

# ─── 1. la forge jetable ─────────────────────────────────────────────────────────────────────────
say "forge jetable : projet $FORGE_PROJECT sur $FORGE_URL"
LCARS_DEVFORGE_PORT="$FORGE_PORT" LCARS_DEVFORGE_ROOT_URL="http://forge:3000/" \
  "$DOCKER_BIN" compose -f "$HERE/forge-compose.yml" -p "$FORGE_PROJECT" up -d \
  || die "la forge ne monte pas" 2

for _ in $(seq 1 60); do
  curl -sf -m 3 "$FORGE_URL/api/v1/version" >/dev/null 2>&1 && break
  sleep 2
done
curl -sf -m 3 "$FORGE_URL/api/v1/version" >/dev/null 2>&1 || die "la forge ne repond pas sur $FORGE_URL" 2
say "forge up"

# ─── 2. la boite — create, brancher, PUIS demarrer (piege 1) ─────────────────────────────────────
say "boite : projet $PROJECT, image $IMAGE, bind $BIND"
env LCARS_IMAGE="$IMAGE" \
    LCARS_HUMAN="$HUMAN" \
    LCARS_HUMAN_EMAIL="${HUMAN}@lcars.local" \
    FORGE_BASE_URL="http://forge:3000" \
    LCARS_FORGE_WEB_URL="$FORGE_URL" \
    LCARS_SOURCE_REMOTE="http://forge:3000/fleet/lcars.git" \
    LCARS_BIND="$BIND" \
    LCARS_SSH_PORT="${BIND}:2222" \
    LCARS_LANDING_PORT_BIND="${BIND}:20999" \
    "$DOCKER_BIN" compose -f "$DOCKER_DIR/docker-compose.install.yml" -p "$PROJECT" create \
  || die "la boite ne se cree pas" 3

"$DOCKER_BIN" network connect "$FORGE_NET" "$BOX" \
  || die "la boite ne se branche pas sur le reseau de la forge ($FORGE_NET)" 3
say "boite branchee sur $FORGE_NET — le nom 'forge' resout AVANT le premier boot"

"$DOCKER_BIN" compose -p "$PROJECT" start || die "la boite ne demarre pas" 3

for _ in $(seq 1 90); do
  [[ "$("$DOCKER_BIN" inspect -f '{{.State.Health.Status}}' "$BOX" 2>/dev/null)" == "healthy" ]] && break
  sleep 2
done
[[ "$("$DOCKER_BIN" inspect -f '{{.State.Health.Status}}' "$BOX" 2>/dev/null)" == "healthy" ]] \
  || die "la boite ne devient pas healthy (docker logs $BOX)" 3
say "boite healthy"

# ─── 3. les creds anthropic (piege 3) ────────────────────────────────────────────────────────────
if [[ "$WITH_CREDS" -eq 1 ]]; then
  [[ -r "$CREDS_FROM" ]] || die "creds illisibles: $CREDS_FROM (--no-creds pour un banc sans pods)" 5
  "$DOCKER_BIN" exec -i -u "$HUMAN" "$BOX" bash -c \
      'mkdir -p ~/.claude && cat > ~/.claude/.credentials.json && chmod 600 ~/.claude/.credentials.json' \
    < "$CREDS_FROM" || die "creds non posees dans la boite" 5
  say "creds anthropic posees chez $HUMAN (le spawn-boundary passera)"
else
  say "creds NON posees (--no-creds) — aucun pod ne pourra demarrer, par choix"
fi

# ─── 4. amorcage de la forge, passe 1 : structure ────────────────────────────────────────────────
# LE TFSTATE DOIT SURVIVRE ENTRE LES DEUX PASSES. Laisse a lui-meme, bootstrap se copie la recette
# dans un mktemp NEUF a chaque appel, donc avec un etat VIDE : la passe 2 croit devoir creer une org
# et dix comptes deja poses et meurt en 409. Un script idempotent compose deux fois ne l'est plus
# des que son etat vit dans un temporaire qu'il recree — mesure du 2026-08-03, premiere execution.
TOFU_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bench-tofu-${PROJECT}.XXXXXX")"
cp -r "$REPO_ROOT/fleet/provisioning/deps/." "$TOFU_DIR/"
say "recette tofu dans $TOFU_DIR (etat PARTAGE par les deux passes)"

say "amorcage passe 1 (structure — le semis sera saute, c'est attendu)"
DOCKER_BIN="$DOCKER_BIN" "$HERE/bench-forge-bootstrap.sh" \
    --forge-url "$FORGE_URL" --container "$FORGE_CONTAINER" --box "$BOX" --human "$HUMAN" \
    --tofu-dir "$TOFU_DIR" \
  || die "amorcage passe 1 en echec" 4

# ─── 5. relance de la boite : 50-forge minte les role-tokens sur le seed (piege 2) ───────────────
say "relance de la boite pour que 50-forge minte les role-tokens"
"$DOCKER_BIN" restart "$BOX" >/dev/null || die "relance de la boite impossible" 3
for _ in $(seq 1 90); do
  [[ "$("$DOCKER_BIN" inspect -f '{{.State.Health.Status}}' "$BOX" 2>/dev/null)" == "healthy" ]] && break
  sleep 2
done
[[ "$("$DOCKER_BIN" inspect -f '{{.State.Health.Status}}' "$BOX" 2>/dev/null)" == "healthy" ]] \
  || die "la boite ne redevient pas healthy apres relance" 3

# ─── 6. amorcage passe 2 : le semis ──────────────────────────────────────────────────────────────
say "amorcage passe 2 (semis des depots — le token systeme existe maintenant)"
DOCKER_BIN="$DOCKER_BIN" "$HERE/bench-forge-bootstrap.sh" \
    --forge-url "$FORGE_URL" --container "$FORGE_CONTAINER" --box "$BOX" --human "$HUMAN" \
    --tofu-dir "$TOFU_DIR" \
  || die "amorcage passe 2 en echec" 4

# ─── 7. verdict MESURE ───────────────────────────────────────────────────────────────────────────
SYS_TOKEN="$("$DOCKER_BIN" exec "$BOX" cat /home/private/system.gitea_token 2>/dev/null | tr -d '[:space:]' || true)"
[[ -n "$SYS_TOKEN" ]] || die "token systeme absent apres deux passes — le banc n'est PAS pret" 6

ROLE_TOKENS="$("$DOCKER_BIN" exec "$BOX" bash -c 'ls /home/private/*.gitea_token 2>/dev/null | wc -l' || echo 0)"
CREDS_OK="$("$DOCKER_BIN" exec -u "$HUMAN" "$BOX" bash -c '[ -s ~/.claude/.credentials.json ] && echo oui || echo non')"

say "─────────────────────────────────────────────────────────"
say "banc PRET"
say "  forge     : $FORGE_URL   (humain $HUMAN / toto32toto32)"
say "  boite     : $BOX   ssh ${BIND}:2222   deck ${BIND}:20999"
say "  tokens    : $ROLE_TOKENS fichiers dans /home/private"
say "  creds     : $CREDS_OK"
say "  destruire : bench-down.sh --project $PROJECT"
say "─────────────────────────────────────────────────────────"
