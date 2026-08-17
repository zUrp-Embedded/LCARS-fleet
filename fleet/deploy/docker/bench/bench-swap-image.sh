#!/usr/bin/env bash
# SOURCE: fleet/deploy/docker/bench/bench-swap-image.sh
# AUTHOR: DrDree
# STARDATE: 2026-08-03
# STATUS: geste de BANC — remplace l'IMAGE de la boite d'un banc deja seme, forge intacte
#
# ─── POURQUOI CE FICHIER EXISTE ─────────────────────────────────────────────────────────────────
# Un banc coute deux choses tres inegales : une IMAGE (un build, reproductible a la commande) et une
# FORGE SEMEE (org, comptes, role-tokens, depots — deux passes d'amorcage et une relance de boite).
# Quand seul le code a bouge, `bench-down.sh` + `bench-up.sh` rejoue la partie chere pour rien.
#
# Le 2026-08-03, un banc rendait `poller_telemetry: true` sans le detail `tick` : son image etait
# anterieure au commit qui expose ce detail. Le code l'avait, ce qui TOURNAIT ne l'avait pas. Le
# geste manquant n'etait pas « refaire un banc », c'etait « remettre la boite a jour » — et il
# vivait dans la memoire de la session, ce que ce depot traite comme une absence.
#
# ─── CE QUE CE SCRIPT PRESERVE, ET CE QU'IL DETRUIT ─────────────────────────────────────────────
# PRESERVE : le projet compose de la forge, son volume, son semis, ses tokens ; le runner.
# DETRUIT  : le conteneur de la boite, et LUI SEUL. Tout ce qui vivait dans son systeme de fichiers
#            part avec — pods en vol, worktrees, logs BEAM. C'est un geste de banc, pas de prod.
#
# ─── LES TROIS PIEGES REPRIS DE bench-up.sh — ILS NE DISPARAISSENT PAS AVEC LE SWAP ─────────────
# 1. LA BOITE DOIT JOINDRE LE RESEAU DE LA FORGE AVANT SON PREMIER BOOT. `create` → `network
#    connect` → `start`, jamais un `up` : sinon `forge` ne resout pas au boot et le provisioning
#    part en drift. Le swap recree une boite NEUVE — le piege est donc entier, pas amorti.
# 2. LES CREDS ANTHROPIC PARTENT AVEC L'ANCIEN CONTENEUR. Sans `~/.claude/.credentials.json`,
#    `Credentials.Gate.validate` refuse au spawn-boundary : la fleet a l'air saine et ne produit
#    aucun pod. Elles sont reposees ici, sinon le banc est mort sans le dire.
# 3. `50-forge` MINTE LES ROLE-TOKENS AU BOOT, depuis le seed de la forge. Sur un banc deja seme le
#    seed EXISTE, donc une seule relance suffit — la seconde passe d'amorcage de `bench-up.sh` n'a
#    pas lieu d'etre. C'est toute la difference entre monter un banc et remettre sa boite a jour.
#
# ⚠ CE QUE CE SCRIPT NE FAIT PAS : demarrer la fleet. Comme apres un `bench-up.sh`, l'entrypoint
# s'arrete a « puis `fleet_v2 start` » — le daemon se lance a la main, et le verdict final ci-dessous
# le rappelle plutot que de laisser croire a un banc qui travaille.
#
# USAGE : bench-swap-image.sh --image lcars-fleet:xyz [--project lcars-nuit] [--bind 127.0.0.5]
#                             [--forge-port 3700] [--creds-from ~/.claude/.credentials.json]
#                             [--no-creds] [--human lcars]
# EXIT  : 0 boite remplacee · 1 arguments/dependance · 3 la boite ne monte pas · 5 creds
#         6 le verdict final ne passe pas

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(cd "$HERE/.." && pwd)"

PROJECT="lcars-nuit"
FORGE_PORT="3700"
BIND="127.0.0.5"
IMAGE=""
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
    *) echo "bench-swap-image: option inconnue: $1" >&2; exit 1 ;;
  esac
done

FORGE_PROJECT="${PROJECT}forge"
FORGE_NET="${FORGE_PROJECT}_default"
BOX="${PROJECT}-lcars-1"
FORGE_URL="http://127.0.0.1:${FORGE_PORT}"

say() { echo "bench-swap-image: $*"; }
die() { echo "bench-swap-image: $1" >&2; exit "${2:-1}"; }

[[ -n "$IMAGE" ]] || die "--image est obligatoire : ce script n'a pas de defaut, se tromper d'image est le seul degat qu'il puisse faire" 1

# Le banc doit exister : swapper la boite d'un banc absent monterait une boite orpheline, sans
# reseau de forge et sans seed — un objet qui a l'air d'un banc et n'en est pas.
"$DOCKER_BIN" network inspect "$FORGE_NET" >/dev/null 2>&1 \
  || die "reseau $FORGE_NET absent — il n'y a pas de banc '$PROJECT' a mettre a jour (bench-up.sh d'abord)" 1
"$DOCKER_BIN" image inspect "$IMAGE" >/dev/null 2>&1 \
  || die "image $IMAGE inconnue du daemon — elle doit exister AVANT qu'on detruise la boite" 1

if [[ "$WITH_CREDS" -eq 1 ]]; then
  [[ -r "$CREDS_FROM" ]] || die "creds illisibles: $CREDS_FROM (--no-creds pour un banc sans pods)" 5
fi

say "banc $PROJECT — la boite passe sur $IMAGE (forge, semis et tokens preserves)"

# ─── 1. la boite s'en va, et elle SEULE ──────────────────────────────────────────────────────────
"$DOCKER_BIN" rm -f "$BOX" >/dev/null 2>&1 || true

# ─── 2. create → connect → start (piege 1) ───────────────────────────────────────────────────────
env LCARS_IMAGE="$IMAGE" \
    `# identite-v2 : le box materialise admiral (master/sysadmin, uid 1000). Le worker "$HUMAN" (lcars)` \
    `# vient de la forge (fleet:humans) via le convergeur, pas du box. Miroir de bench-up.sh.` \
    LCARS_ADMIRAL="admiral" \
    LCARS_ADMIRAL_EMAIL="admiral@lcars.local" \
    FORGE_BASE_URL="http://forge:3000" \
    LCARS_SOURCE_REMOTE="http://forge:3000/fleet/lcars.git" \
    LCARS_BIND="$BIND" \
    LCARS_SSH_PORT="${BIND}:2222" \
    LCARS_LANDING_PORT_BIND="${BIND}:20999" \
    FORGE_PUBLIC_URL="http://${BIND}:${FORGE_PORT}" \
    LCARS_DECK_ORIGINS="http://${BIND}:20999" \
    "$DOCKER_BIN" compose -f "$DOCKER_DIR/docker-compose.install.yml" -p "$PROJECT" create \
  || die "la boite ne se cree pas" 3

"$DOCKER_BIN" network connect "$FORGE_NET" "$BOX" \
  || die "la boite ne se branche pas sur $FORGE_NET" 3
say "boite branchee sur $FORGE_NET — 'forge' resout AVANT le premier boot"

"$DOCKER_BIN" compose -p "$PROJECT" start || die "la boite ne demarre pas" 3

wait_healthy() {
  local i
  for i in $(seq 1 90); do
    [[ "$("$DOCKER_BIN" inspect -f '{{.State.Health.Status}}' "$BOX" 2>/dev/null)" == "healthy" ]] && return 0
    sleep 2
  done
  return 1
}
wait_healthy || die "la boite ne devient pas healthy (docker logs $BOX)" 3
say "boite healthy"

# Mot de passe de banc d'admiral (ssh + sudo) — miroir de bench-up.sh "2ter". L'entrypoint cree le
# siege (uid 1000) sans secret ; on le pose ici pour pouvoir ssh/sudo apres un swap. Jamais lu par la prod.
printf 'admiral:%s\n' "${LCARS_BENCH_ADMIRAL_PW:-toto1234}" | "$DOCKER_BIN" exec -i "$BOX" chpasswd 2>/dev/null \
  && say "mot de passe de banc pose sur admiral (ssh/sudo)" \
  || say "admiral : mot de passe non pose — ssh par cle, ou 'docker exec -u admiral $BOX bash'"

# ─── 3. les creds repartent avec l'ancien conteneur (piege 2) ────────────────────────────────────
if [[ "$WITH_CREDS" -eq 1 ]]; then
  "$DOCKER_BIN" exec -i -u "$HUMAN" "$BOX" bash -c \
      'mkdir -p ~/.claude && cat > ~/.claude/.credentials.json && chmod 600 ~/.claude/.credentials.json' \
    < "$CREDS_FROM" || die "creds non posees dans la boite" 5
  say "creds anthropic reposees chez $HUMAN"
else
  say "creds NON posees (--no-creds) — aucun pod ne pourra demarrer, par choix"
fi

# ─── 4. une relance, pas deux passes : le seed existe deja (piege 3) ─────────────────────────────
say "relance pour que 50-forge minte les role-tokens sur le seed EXISTANT"
"$DOCKER_BIN" restart "$BOX" >/dev/null || die "relance de la boite impossible" 3
wait_healthy || die "la boite ne redevient pas healthy apres relance" 3

# ─── 5. verdict MESURE ───────────────────────────────────────────────────────────────────────────
# MESURE PAR `cp` ET `inspect`, JAMAIS PAR `exec`. Quand le daemon est joint a travers un proxy de
# socket, `exec` LANCE la commande — les effets de bord ont lieu — mais ne rend ni sa sortie ni son
# code : il rend 0 et zero octet. Une mesure batie sur `exec` y lit donc le vide et conclut
# l'absence. Vecu : ce script a tue un swap avec « la boite ne voit pas le seed » sur une boite dont
# les dix jetons etaient en place, et l'operateur a passe l'heure suivante a chercher une panne de
# forge. `cp`, `logs` et `inspect` traversent, eux — donc la mesure passe par eux.
ROLE_TOKENS="$("$DOCKER_BIN" cp "$BOX:/home/private" - 2>/dev/null | tar -t 2>/dev/null | grep -c '\.gitea_token$' || true)"
[[ "${ROLE_TOKENS:-0}" -gt 0 ]] || die "aucun role-token apres relance — la boite ne voit pas le seed de la forge" 6

CREDS_TMP="$(mktemp)"
if "$DOCKER_BIN" cp "$BOX:/home/$HUMAN/.claude/.credentials.json" "$CREDS_TMP" >/dev/null 2>&1 && [[ -s "$CREDS_TMP" ]]; then
  CREDS_OK=oui
else
  CREDS_OK=non
fi
rm -f "$CREDS_TMP"

REVISION="$("$DOCKER_BIN" inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$BOX" 2>/dev/null \
            | sed -n 's/^LCARS_IMAGE_REVISION=//p' | head -1)"
REVISION="${REVISION:-inconnue}"

say "─────────────────────────────────────────────────────────"
say "boite remplacee"
say "  image     : $IMAGE   (revision $REVISION)"
say "  forge     : $FORGE_URL   (PRESERVEE — ni resemee ni redemarree)"
say "  tokens    : $ROLE_TOKENS fichiers dans /home/private"
say "  creds     : $CREDS_OK"
say "  la fleet n'est PAS demarree : docker exec -u $HUMAN $BOX bash -lc 'fleet_v2 start'"
say "─────────────────────────────────────────────────────────"
