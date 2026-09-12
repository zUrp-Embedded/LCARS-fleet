#!/usr/bin/env bash
# SOURCE: deploy/docker/bench/bench-swap-image.sh
# AUTHOR: DrDree
# STARDATE: 2026-08-03
# STATUS: geste de BANC — remplace l'IMAGE du conteneur d'un banc deja seme, forge intacte
#
# ─── POURQUOI CE FICHIER EXISTE ─────────────────────────────────────────────────────────────────
# Un banc coute deux choses tres inegales : une IMAGE (un build, reproductible a la commande) et une
# FORGE SEMEE (org, comptes, role-tokens, depots — deux passes d'amorcage et une relance de conteneur).
# Quand seul le code a bouge, `bench-down.sh` + `bench-up.sh` rejoue la partie chere pour rien.
#
# ─── CE QUE CE SCRIPT PRESERVE, ET CE QU'IL DETRUIT ─────────────────────────────────────────────
# PRESERVE : le projet compose de la forge, son volume, son semis, ses tokens ; le runner.
# DETRUIT  : le conteneur LCARS, et LUI SEUL. Tout ce qui vivait dans son systeme de fichiers
#            part avec — pods en vol, worktrees, logs BEAM. C'est un geste de banc, pas de prod.
#
# ─── LES TROIS PIEGES REPRIS DE bench-up.sh — ILS NE DISPARAISSENT PAS AVEC LE SWAP ─────────────
# 1. LE CONTENEUR DOIT JOINDRE LE RESEAU DE LA FORGE AVANT SON PREMIER BOOT. `create` → `network
#    connect` → `start`, jamais un `up` : sinon `gitea` ne resout pas au boot et le provisioning
#    part en drift. Le swap recree un conteneur NEUVE — le piege est donc entier, pas amorti.
# 2. LES CREDS ANTHROPIC PARTENT AVEC L'ANCIEN CONTENEUR. Sans `~/.claude/.credentials.json`,
#    `Credentials.Gate.validate` refuse au spawn-boundary : la fleet a l'air saine et ne produit
#    aucun pod. Elles sont reposees ici, sinon le banc est mort sans le dire.
# 3. `63-forge-tokens` MINTE LES ROLE-TOKENS AU BOOT, depuis le seed de la forge. Sur un banc deja seme le
#    seed EXISTE, donc une seule relance suffit — la seconde passe d'amorcage de `bench-up.sh` n'a
#    pas lieu d'etre. C'est toute la difference entre monter un banc et remettre son conteneur a jour.
#
# ⚠ CE QUE CE SCRIPT NE FAIT PAS : demarrer la fleet. Comme apres un `bench-up.sh`, l'entrypoint
# s'arrete a « puis `fleet start` » — le daemon se lance a la main, et le verdict final ci-dessous
# le rappelle plutot que de laisser croire a un banc qui travaille.
#
# USAGE : bench-swap-image.sh --image lcars-fleet:xyz [--project lcars-nuit] [--bind 0.0.0.0]
#                             [--forge-port 21000] [--deck-port 20999] [--ssh-port 2222]
#                             [--creds-from ~/.claude/.credentials.json] [--no-creds] [--human lcars]
# EXIT  : 0 conteneur remplace · 1 arguments/dependance · 3 le conteneur ne monte pas · 5 creds
#         6 le verdict final ne passe pas

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(cd "$HERE/.." && pwd)"

PROJECT="lcars-nuit"
# MEMES DEFAUTS QUE `bench-up.sh`, et ils doivent le rester : ce script RECREE le conteneur d'un banc
# existant. Des ports differents ici republieraient le conteneur ailleurs que sa forge ne l'annonce.
FORGE_PORT="21000"
DECK_PORT="20999"
SSH_PORT="2222"
BIND="0.0.0.0"
ADVERTISE=""
IMAGE=""
CREDS_FROM="$HOME/.claude/.credentials.json"
WITH_CREDS=1
HUMAN="lcars"
DOCKER_BIN="${DOCKER_BIN:-docker}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)    PROJECT="${2:?}"; shift 2 ;;
    --forge-port) FORGE_PORT="${2:?}"; shift 2 ;;
    --deck-port)  DECK_PORT="${2:?}"; shift 2 ;;
    --ssh-port)   SSH_PORT="${2:?}"; shift 2 ;;
    --bind)       BIND="${2:?}"; shift 2 ;;
    --advertise)  ADVERTISE="${2:?}"; shift 2 ;;
    --image)      IMAGE="${2:?}"; shift 2 ;;
    --creds-from) CREDS_FROM="${2:?}"; shift 2 ;;
    --no-creds)   WITH_CREDS=0; shift ;;
    --human)      HUMAN="${2:?}"; shift 2 ;;
    -h|--help)    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "bench-swap-image: option inconnue: $1" >&2; exit 1 ;;
  esac
done

# ⚖ user 2026-09-04 (DI-05, lot 9) : UN sens pour le nom — la BASE des projets compose. Le conteneur
# est <N>-fleet (le defaut de « deploy/container », LCARS_BASE=N), la forge <N>-forge, le runner <N>-runner :
# le poste (48/49) et le banc derivent les memes noms de la meme base.
CONTAINER_PROJECT="${PROJECT}-fleet"
FORGE_PROJECT="${PROJECT}-forge"
FORGE_NET="${FORGE_PROJECT}_default"
CONTAINER="${CONTAINER_PROJECT}-lcars-1"

export LCARS_STORE_PREFIX="$CONTAINER_PROJECT"
# MEME SEPARATION QUE `bench-up.sh` : `0.0.0.0` est un joker d'ecoute, pas une adresse. Ce qu'on
# ANNONCE (FORGE_PUBLIC_URL, les entrees du deck) doit etre composable depuis une autre machine — et
# la derivation depend du SUBSTRAT (WSL en NAT n'a pas d'adresse annoncable). Une seule definition,
# dans la lib : la copie qui vivait ici portait la meme erreur et il aurait fallu la corriger deux fois.
# shellcheck source=../../lib/provision-lib.sh
source "$DOCKER_DIR/../lib/provision-lib.sh"
# shellcheck source=../../lib/forge-bootstrap.sh
source "$DOCKER_DIR/../lib/forge-bootstrap.sh"
if [[ -z "${ADVERTISE:-}" ]]; then advertise_addr "$BIND"; ADVERTISE="$PROV_ADVERTISE"; fi
FORGE_URL="http://127.0.0.1:${FORGE_PORT}"

say() { echo "bench-swap-image: $*"; }
die() { echo "bench-swap-image: $1" >&2; exit "${2:-1}"; }

[[ -n "$IMAGE" ]] || die "--image est obligatoire : ce script n'a pas de defaut, se tromper d'image est le seul degat qu'il puisse faire" 1

# Le banc doit exister : swapper le conteneur d'un banc absent monterait un conteneur orphelin, sans
# reseau de forge et sans seed — un objet qui a l'air d'un banc et n'en est pas.
"$DOCKER_BIN" network inspect "$FORGE_NET" >/dev/null 2>&1 \
  || die "reseau $FORGE_NET absent — il n'y a pas de banc '$PROJECT' a mettre a jour (bench-up.sh d'abord)" 1
"$DOCKER_BIN" image inspect "$IMAGE" >/dev/null 2>&1 \
  || die "image $IMAGE inconnue du daemon — elle doit exister AVANT qu'on detruise le conteneur" 1

if [[ "$WITH_CREDS" -eq 1 ]]; then
  [[ -r "$CREDS_FROM" ]] || die "creds illisibles: $CREDS_FROM (--no-creds pour un banc sans pods)" 5
fi

say "banc $PROJECT — le conteneur passe sur $IMAGE (forge, semis et tokens preserves)"

# ─── 1. le conteneur s'en va, et lui SEUL ──────────────────────────────────────────────────────────
"$DOCKER_BIN" rm -f "$CONTAINER" >/dev/null 2>&1 || true

# ─── 2. create → connect → start (piege 1) ───────────────────────────────────────────────────────
# ⚠ `LCARS_ADMIRAL_EMAIL` N'EST PAS ICI, ET SON ABSENCE EST LE CORRECTIF. L'identite git ne se
# seme plus sur `admiral` : c'est le siege machine, il ne commite jamais, et lui donner l'adresse
# faisait signer les commits des humains par un compte fantome que la forge ne relie a personne.
# L'adresse qui compte est celle du compte forge de l'humain, posee par le convergeur.
# ⚠ PAR --env-file, PLUS JAMAIS PAR L'ENVIRONNEMENT (trois morsures en un jour) : la substitution `${VAR}` d'un compose file se fait dans le PROCESS compose — et quand
# `DOCKER_BIN` est un wrapper qui s'escalade (sudo interne, env remis a zero), les variables
# prefixees ici n'existent plus de l'autre cote. Consequences mesurees : l'image DEFAUTAIT (le tag
# de la liste rouge a ete ecrase, puis un pull du registre NAS), le port ssh DEFAUTAIT (bind sur le
# 2222 d'un autre banc). Un fichier d'env est lu du DISQUE par compose, apres l'escalade — il ne
# peut pas etre strippe. `identite-v2` : le container materialise admiral (master/sysadmin, uid 1000) ;
# le worker "$HUMAN" (lcars) vient de la forge (fleet:humans) via le convergeur. Miroir bench-up.sh.
# ⚠ PAS DE FICHIER TEMPORAIRE ANONYME, ET PAS DANS `/tmp` — le temoin `bench_swap_creds.bats`
# l'interdit, pour une raison mesuree : sur un poste ou le daemon passe par sudo, `docker cp` ecrit
# en ROOT, `/tmp` est sticky, donc celui qui a cree le fichier ne peut plus l'effacer. Deux copies
# de credentials VIVANTS y sont restees, pendant que le script se croyait propre.
# Ce fichier-ci ne porte que de la CONFIGURATION (image, ports, URLs — le mot de passe admiral part
# par un tube vers `chpasswd`, jamais par ici), mais le piege de propriete est le meme.
#
# Donc : un chemin DETERMINISTE dans le repertoire d'execution de l'appelant, cree par lui, en 0600,
# efface par le trap. `compose` le lit du DISQUE apres l'escalade — root lit un 0600 qui ne lui
# appartient pas, c'est tout ce dont on a besoin.
SWAP_ENV="${XDG_RUNTIME_DIR:-$HOME/.cache}/lcars-bench-swap.$PROJECT.env"
mkdir -p "$(dirname "$SWAP_ENV")"
( umask 077; : > "$SWAP_ENV" )
cat > "$SWAP_ENV" <<ENVEOF
LCARS_IMAGE=$IMAGE
LCARS_ADMIRAL=admiral
FORGE_BASE_URL=http://gitea:3000
LCARS_SOURCE_REMOTE=http://gitea:3000/fleet/lcars.git
LCARS_BIND=$BIND
LCARS_SSH_PORT=${BIND}:${SSH_PORT}
LCARS_LANDING_PORT_BIND=${BIND}:${DECK_PORT}
FORGE_PUBLIC_URL=http://${ADVERTISE}:${FORGE_PORT}
LCARS_DECK_ORIGINS=http://${ADVERTISE}:${DECK_PORT}
ENVEOF
trap 'rm -f "$SWAP_ENV"' EXIT

"$DOCKER_BIN" compose --env-file "$SWAP_ENV" -f "$DOCKER_DIR/docker-compose.yml" -p "$CONTAINER_PROJECT" create \
  || die "le conteneur ne se cree pas" 3

"$DOCKER_BIN" network connect "$FORGE_NET" "$CONTAINER" \
  || die "le conteneur ne se branche pas sur $FORGE_NET" 3
say "conteneur branche sur $FORGE_NET — 'gitea' resout AVANT le premier boot"

"$DOCKER_BIN" compose -p "$CONTAINER_PROJECT" start || die "le conteneur ne demarre pas" 3

wait_healthy() {
  for _ in $(seq 1 90); do
    [[ "$("$DOCKER_BIN" inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null)" == "healthy" ]] && return 0
    sleep 2
  done
  return 1
}
wait_healthy || die "le conteneur ne devient pas healthy (docker logs $CONTAINER)" 3
say "conteneur healthy"

# ⚠ PAS DE `&& say … || say …` ICI : `say` rend le statut de son `printf`, donc un tube ferme
# ferait annoncer l'echec sur un mot de passe pose. Le statut de `chpasswd` se lit une fois.
if printf 'admiral:%s\n' "$(bench_admiral_password)" | "$DOCKER_BIN" exec -i "$CONTAINER" chpasswd 2>/dev/null; then
  say "mot de passe de banc pose sur admiral (ssh/sudo)"
else
  say "admiral : mot de passe non pose — ssh par cle, ou 'docker exec -u admiral $CONTAINER bash'"
fi

# ─── 3. les creds repartent avec l'ancien conteneur (piege 2) ────────────────────────────────────
if [[ "$WITH_CREDS" -eq 1 ]]; then
  "$DOCKER_BIN" exec -i -u "$HUMAN" "$CONTAINER" bash -c \
      'mkdir -p ~/.claude && cat > ~/.claude/.credentials.json && chmod 600 ~/.claude/.credentials.json' \
    < "$CREDS_FROM" || die "creds non posees dans le conteneur" 5
  say "creds anthropic reposees chez $HUMAN"
else
  say "creds NON posees (--no-creds) — aucun pod ne pourra demarrer, par choix"
fi

# ─── 4. une relance, pas deux passes : le seed existe deja (piege 3) ─────────────────────────────
say "relance pour que 63-forge-tokens minte les role-tokens sur le seed EXISTANT"
"$DOCKER_BIN" restart "$CONTAINER" >/dev/null || die "relance du conteneur impossible" 3
wait_healthy || die "le conteneur ne redevient pas healthy apres relance" 3

# ─── 5. verdict MESURE ───────────────────────────────────────────────────────────────────────────
# MESURE PAR `cp` ET `inspect`, JAMAIS PAR `exec`. Quand le daemon est joint a travers un proxy de
# socket, `exec` LANCE la commande — les effets de bord ont lieu — mais ne rend ni sa sortie ni son
# code : il rend 0 et zero octet. Une mesure batie sur `exec` y lit donc le vide et conclut
# l'absence. Vecu : ce script a tue un swap avec « le conteneur ne voit pas le seed » sur un conteneur dont
# les dix jetons etaient en place, et l'operateur a passe l'heure suivante a chercher une panne de
# forge. `cp`, `logs` et `inspect` traversent, eux — donc la mesure passe par eux.
ROLE_TOKENS="$("$DOCKER_BIN" cp "$CONTAINER:/opt/lcars/var/tokens" - 2>/dev/null | tar -t 2>/dev/null | grep -c '\.gitea_token$' || true)"
[[ "${ROLE_TOKENS:-0}" -gt 0 ]] || die "aucun role-token apres relance — le conteneur ne voit pas le seed de la forge" 6

# Or on ne veut pas le CONTENU, on veut « present et non vide ». Le flux tar de `docker cp … -` le
# dit dans son en-tete : rien ne touche le disque. (Et on ne repasse pas par `exec`, mute a travers
# ce relais — c'est la raison qui avait fait choisir `cp` au depart, elle tient toujours.)
CREDS_SIZE="$("$DOCKER_BIN" cp "$CONTAINER:/home/$HUMAN/.claude/.credentials.json" - 2>/dev/null \
              | tar -tv 2>/dev/null | awk 'NR==1 {print $3}' || true)"
if [[ "${CREDS_SIZE:-}" =~ ^[0-9]+$ ]] && [[ "$CREDS_SIZE" -gt 0 ]]; then
  CREDS_OK=oui
else
  CREDS_OK=non
fi

REVISION="$("$DOCKER_BIN" inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER" 2>/dev/null \
            | sed -n 's/^LCARS_IMAGE_REVISION=//p' | head -1)"
REVISION="${REVISION:-inconnue}"

say "─────────────────────────────────────────────────────────"
say "conteneur remplace"
say "  image     : $IMAGE   (revision $REVISION)"
say "  forge     : $FORGE_URL   (PRESERVEE — ni resemee ni redemarree)"
say "  tokens    : $ROLE_TOKENS fichiers dans /opt/lcars/var/tokens"
say "  creds     : $CREDS_OK"
say "  la fleet n'est PAS demarree : docker exec -u $HUMAN $CONTAINER bash -lc 'fleet start'"
say "─────────────────────────────────────────────────────────"
