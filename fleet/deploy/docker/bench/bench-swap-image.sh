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
# USAGE : bench-swap-image.sh --image lcars-fleet:xyz [--project lcars-nuit] [--bind 0.0.0.0]
#                             [--forge-port 21000] [--deck-port 20999] [--ssh-port 2222]
#                             [--creds-from ~/.claude/.credentials.json] [--no-creds] [--human lcars]
# EXIT  : 0 boite remplacee · 1 arguments/dependance · 3 la boite ne monte pas · 5 creds
#         6 le verdict final ne passe pas

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(cd "$HERE/.." && pwd)"

PROJECT="lcars-nuit"
# MEMES DEFAUTS QUE `bench-up.sh`, et ils doivent le rester : ce script RECREE la boite d'un banc
# existant. Des ports differents ici republieraient la boite ailleurs que sa forge ne l'annonce.
FORGE_PORT="21000"
# ⚠ LE PORT DU DECK ETAIT EN DUR (20999) ALORS QUE `bench-up.sh` LE PREND EN OPTION. Un banc monte
# sur un autre port et passe ici ressortait republie sur 20999 — la boite ecoutait ailleurs que la
# ou sa forge l'annonce, sans un mot. Meme defaut, meme option.
DECK_PORT="20999"
# ⚠ MEME MALADIE, QUATRIEME SITE (mesure 2026-08-18) : le port SSH etait en dur a 2222 dans le
# `create` ci-dessous. Un swap d'un banc monte ailleurs (vanille : 2223) aurait republie sa boite
# sur le port ssh d'un AUTRE banc (l8 : 2222) — au mieux un create qui meurt sur le port pris, au
# pire une boite qui repond a la place d'une autre. Le paragraphe au-dessus decrivait deja le
# defaut ; il ne manquait que l'instance.
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

FORGE_PROJECT="${PROJECT}forge"
FORGE_NET="${FORGE_PROJECT}_default"
BOX="${PROJECT}-lcars-1"

# ⚠ MEME OMISSION QUE `bench-down.sh` A DEJA PAYEE, TROISIEME SITE. Le compose de la boite nomme ses
# volumes de magasin `${LCARS_STORE_PREFIX}-<nature>` avec un `:?` : sans la variable, il REFUSE de
# PARSER le fichier — donc pas « un volume manque », mais « rien ne se cree », sur un banc
# parfaitement sain. `bench-up.sh` et `bench-down.sh` l'exportent chacun ; ce script utilisait le
# meme compose et ne l'exportait pas.
#
# Mesure du 2026-08-21, swap du banc #2 : « error while interpolating volumes.lcars-cache.name:
# required variable LCARS_STORE_PREFIX is missing a value », puis « la boite ne se cree pas ». Le
# message dit la variable, il ne dit pas que trois scripts partagent ce compose et qu'un seul
# l'oubliait.
export LCARS_STORE_PREFIX="$PROJECT"
# MEME SEPARATION QUE `bench-up.sh` : `0.0.0.0` est un joker d'ecoute, pas une adresse. Ce qu'on
# ANNONCE (FORGE_PUBLIC_URL, les entrees du deck) doit etre composable depuis une autre machine — et
# la derivation depend du SUBSTRAT (WSL en NAT n'a pas d'adresse annoncable). Une seule definition,
# dans la lib : la copie qui vivait ici portait la meme erreur et il aurait fallu la corriger deux fois.
# shellcheck source=../../lib/provision-lib.sh
source "$DOCKER_DIR/../lib/provision-lib.sh"
if [[ -z "${ADVERTISE:-}" ]]; then advertise_addr "$BIND"; ADVERTISE="$PROV_ADVERTISE"; fi
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
# ⚠ `LCARS_ADMIRAL_EMAIL` N'EST PAS ICI, ET SON ABSENCE EST LE CORRECTIF. L'identite git ne se
# seme plus sur `admiral` : c'est le siege machine, il ne commite jamais, et lui donner l'adresse
# faisait signer les commits des humains par un compte fantome que la forge ne relie a personne.
# L'adresse qui compte est celle du compte forge de l'humain, posee par le convergeur.
# ⚠ PAR --env-file, PLUS JAMAIS PAR L'ENVIRONNEMENT (mesuré 2026-08-18, trois morsures le meme
# jour) : la substitution `${VAR}` d'un compose file se fait dans le PROCESS compose — et quand
# `DOCKER_BIN` est un wrapper qui s'escalade (sudo interne, env remis a zero), les variables
# prefixees ici n'existent plus de l'autre cote. Consequences mesurees : l'image DEFAUTAIT (le tag
# de la liste rouge a ete ecrase, puis un pull du registre NAS), le port ssh DEFAUTAIT (bind sur le
# 2222 d'un autre banc). Un fichier d'env est lu du DISQUE par compose, apres l'escalade — il ne
# peut pas etre strippe. `identite-v2` : le box materialise admiral (master/sysadmin, uid 1000) ;
# le worker "$HUMAN" (lcars) vient de la forge (fleet:humans) via le convergeur. Miroir bench-up.sh.
# ⚠ PAS DE FICHIER TEMPORAIRE ANONYME, ET PAS DANS `/tmp` — le temoin `bench_swap_creds.bats`
# l'interdit, pour une raison mesuree : sur un poste ou le daemon passe par sudo, `docker cp` ecrit
# en ROOT, `/tmp` est sticky, donc celui qui a cree le fichier ne peut plus l'effacer. Deux copies
# de credentials VIVANTS y etaient restees le 2026-08-18, pendant que le script se croyait propre.
# Ce fichier-ci ne porte que de la CONFIGURATION (image, ports, URLs — le mot de passe admiral part
# par un tube vers `chpasswd`, jamais par ici), mais le piege de propriete est le meme.
#
# ⚠⚠ ET LE TEMOIN GREPE LE FICHIER ENTIER, COMMENTAIRES COMPRIS : ecrire le nom de la commande
# interdite, meme pour expliquer qu'on ne l'utilise pas, suffit a le faire rougir. C'est pour ca
# qu'elle n'est nommee nulle part ici.
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
FORGE_BASE_URL=http://forge:3000
LCARS_SOURCE_REMOTE=http://forge:3000/fleet/lcars.git
LCARS_BIND=$BIND
LCARS_SSH_PORT=${BIND}:${SSH_PORT}
LCARS_LANDING_PORT_BIND=${BIND}:${DECK_PORT}
FORGE_PUBLIC_URL=http://${ADVERTISE}:${FORGE_PORT}
LCARS_DECK_ORIGINS=http://${ADVERTISE}:${DECK_PORT}
ENVEOF
trap 'rm -f "$SWAP_ENV"' EXIT

"$DOCKER_BIN" compose --env-file "$SWAP_ENV" -f "$DOCKER_DIR/docker-compose.install.yml" -p "$PROJECT" create \
  || die "la boite ne se cree pas" 3

"$DOCKER_BIN" network connect "$FORGE_NET" "$BOX" \
  || die "la boite ne se branche pas sur $FORGE_NET" 3
say "boite branchee sur $FORGE_NET — 'forge' resout AVANT le premier boot"

"$DOCKER_BIN" compose -p "$PROJECT" start || die "la boite ne demarre pas" 3

wait_healthy() {
  for _ in $(seq 1 90); do
    [[ "$("$DOCKER_BIN" inspect -f '{{.State.Health.Status}}' "$BOX" 2>/dev/null)" == "healthy" ]] && return 0
    sleep 2
  done
  return 1
}
wait_healthy || die "la boite ne devient pas healthy (docker logs $BOX)" 3
say "boite healthy"

# Mot de passe de banc d'admiral (ssh + sudo) — miroir de bench-up.sh "2ter". L'entrypoint cree le
# siege (uid 1000) sans secret ; on le pose ici pour pouvoir ssh/sudo apres un swap. Jamais lu par la prod.
# ⚠ PAS DE `&& say … || say …` ICI : `say` rend le statut de son `printf`, donc un tube ferme
# ferait annoncer l'echec sur un mot de passe pose. Le statut de `chpasswd` se lit une fois.
if printf 'admiral:%s\n' "${LCARS_BENCH_ADMIRAL_PW:-toto1234}" | "$DOCKER_BIN" exec -i "$BOX" chpasswd 2>/dev/null; then
  say "mot de passe de banc pose sur admiral (ssh/sudo)"
else
  say "admiral : mot de passe non pose — ssh par cle, ou 'docker exec -u admiral $BOX bash'"
fi

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
ROLE_TOKENS="$("$DOCKER_BIN" cp "$BOX:/opt/lcars/var/tokens" - 2>/dev/null | tar -t 2>/dev/null | grep -c '\.gitea_token$' || true)"
[[ "${ROLE_TOKENS:-0}" -gt 0 ]] || die "aucun role-token apres relance — la boite ne voit pas le seed de la forge" 6

# ⚠ LE SECRET NE DESCEND PLUS SUR L'HOTE, ET IL Y RESTAIT. Cette mesure copiait
# `.credentials.json` dans un `mktemp` pour tester sa taille, puis faisait `rm -f`. Deux defauts
# empiles : le fichier extrait porte des jetons OAuth Anthropic VIVANTS, et le `rm` echouait sans
# que personne ne regarde — sur une machine ou `DOCKER_BIN` passe par sudo (socket rootful, cas
# ordinaire), `docker cp` ecrit le fichier en root, et `/tmp` est sticky : son proprietaire n'est
# plus celui qui l'a cree, donc il ne peut pas le supprimer. Mesure du 2026-08-18 : deux copies des
# credentials, une par swap, encore la, pendant que le script se croyait propre.
#
# Or on ne veut pas le CONTENU, on veut « present et non vide ». Le flux tar de `docker cp … -` le
# dit dans son en-tete : rien ne touche le disque. (Et on ne repasse pas par `exec`, mute a travers
# ce relais — c'est la raison qui avait fait choisir `cp` au depart, elle tient toujours.)
CREDS_SIZE="$("$DOCKER_BIN" cp "$BOX:/home/$HUMAN/.claude/.credentials.json" - 2>/dev/null \
              | tar -tv 2>/dev/null | awk 'NR==1 {print $3}' || true)"
if [[ "${CREDS_SIZE:-}" =~ ^[0-9]+$ ]] && [[ "$CREDS_SIZE" -gt 0 ]]; then
  CREDS_OK=oui
else
  CREDS_OK=non
fi

REVISION="$("$DOCKER_BIN" inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$BOX" 2>/dev/null \
            | sed -n 's/^LCARS_IMAGE_REVISION=//p' | head -1)"
REVISION="${REVISION:-inconnue}"

say "─────────────────────────────────────────────────────────"
say "boite remplacee"
say "  image     : $IMAGE   (revision $REVISION)"
say "  forge     : $FORGE_URL   (PRESERVEE — ni resemee ni redemarree)"
say "  tokens    : $ROLE_TOKENS fichiers dans /opt/lcars/var/tokens"
say "  creds     : $CREDS_OK"
say "  la fleet n'est PAS demarree : docker exec -u $HUMAN $BOX bash -lc 'fleet_v2 start'"
say "─────────────────────────────────────────────────────────"
