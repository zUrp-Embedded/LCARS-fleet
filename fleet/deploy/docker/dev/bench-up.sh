#!/usr/bin/env bash
# SOURCE: fleet/deploy/docker/dev/bench-up.sh
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
# 3bis. LE BINAIRE CLAUDE N'EST PAS DANS L'IMAGE. Il est installe dans le stage `build` (pour le
#    gate) et ce stage est JETE : l'image finale n'en a pas. Le module `40-claude-bin` le telecharge
#    au boot depuis claude.ai — donc une boite NEUVE sans reseau n'obtient aucun binaire, aucun pod
#    ne demarre, et la fleet a l'air saine en ne produisant rien. On seme donc le binaire de l'hote
#    AVANT le premier boot, a `$PROV_CLAUDE_SEED` (chemin lu dans provision-lib, pas recopie ici).
#    DEUX raisons pour la fenetre create→start, et pas plus tard : l'humain du runtime n'existe pas
#    encore (l'entrypoint le cree au boot, donc son home n'est pas un endroit ou deposer quoi que ce
#    soit), et une graine posee APRES le boot laisserait le module en drift permanent apres avoir
#    brule un telechargement rate. La source est resolue par `readlink -f` : l'installeur vendor
#    pose un SYMLINK, et copier le lien donne une cible morte dans la boite.
# 4. UN BANC NE DOIT JAMAIS COGNER LE BANC D'A COTE. Projet compose, port de forge et adresse de
#    bind sont TOUS parametres et defaultent sur des valeurs libres. `--bind` couvre la boite ET la
#    forge depuis le 2026-08-07 : jusque-la il n'etait passe qu'a la boite, la forge retombait sur
#    le defaut `127.0.0.1` du compose, et cet en-tete l'affirmait deja couverte. La separation
#    tenait quand meme — par unicite du PORT — mais un `--bind 127.0.0.7` rendait une forge sur .1. Le geste destructeur (`down -v`)
#    n'est pas ici : il est dans `bench-down.sh`, separement, pour qu'aucune faute de frappe sur ce
#    script-ci ne detruise un banc qui travaille.
#
# USAGE : bench-up.sh [--project lcars-nuit] [--forge-port 3700] [--bind 127.0.0.5]
#                     [--image lcars-fleet:2] [--creds-from ~/.claude/.credentials.json] [--no-creds]
#                     [--claude-from ~/.local/bin/claude] [--no-claude-bin] [--no-human-admin]
# EXIT  : 0 banc pret (verdict `banc PRET`, ou `banc PRET_SANS_CI` sous --no-runner) · 1
#         arguments/dependance · 2 la forge ne monte pas · 3 la boite ne monte pas · 4 amorcage
#         forge · 5 creds · 6 le verdict final ne passe pas — Y COMPRIS un runner DEMANDE qui ne
#         sert pas (image, token, enregistrement ou visibilite). `--no-runner` est le seul mode
#         degrade qui rende 0, et il porte son propre verdict.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(cd "$HERE/.." && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"

PROJECT="lcars-nuit"
FORGE_PORT="3700"
BIND="127.0.0.5"
IMAGE="lcars-fleet:2"
# Le runner du banc sert TROIS labels, et celui qui compte est `elixir` : il doit porter l'image du
# stage `build`, pas celle de BASE — sinon `mix gate` y meurt sur `git` introuvable et le runner a
# l'air vert. `bench-runner.sh` REFUSE de deviner et il a raison. On ne devine pas non plus : le
# defaut se DERIVE du tag de l'image de banc (`lcars-fleet:v4` -> `lcars-build:v4`, jumeaux du meme
# build) et n'est retenu QUE si cette image existe. Sinon on le dit et on saute — jamais un runner
# qui tourne sans pouvoir servir.
RUNNER_LABELS=""
WITH_RUNNER=1
CREDS_FROM="$HOME/.claude/.credentials.json"
WITH_CREDS=1
CLAUDE_FROM="$HOME/.local/bin/claude"
WITH_CLAUDE_BIN=1
HUMAN="lcars"
# LE BANC PROMEUT L'HUMAIN SITE-ADMIN, ET IL LE DEMANDE — il ne l'herite plus. Depuis le
# 2026-08-07 le bootstrap defaute au modele de prod (non-admin) : la propriete de banc est donc
# posee ICI, visible au point d'appel, et `--no-human-admin` la retire. Raison + cout : etape
# 6-bis du bootstrap.
BOOTSTRAP_EXTRA=(--human-admin)
DOCKER_BIN="${DOCKER_BIN:-docker}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)    PROJECT="${2:?}"; shift 2 ;;
    --forge-port) FORGE_PORT="${2:?}"; shift 2 ;;
    --bind)       BIND="${2:?}"; shift 2 ;;
    --image)      IMAGE="${2:?}"; shift 2 ;;
    --runner-labels) RUNNER_LABELS="${2:?}"; shift 2 ;;
    --no-runner)  WITH_RUNNER=0; shift ;;
    --creds-from) CREDS_FROM="${2:?}"; shift 2 ;;
    --no-creds)   WITH_CREDS=0; shift ;;
    --claude-from) CLAUDE_FROM="${2:?}"; shift 2 ;;
    --no-claude-bin) WITH_CLAUDE_BIN=0; shift ;;
    --no-human-admin) BOOTSTRAP_EXTRA=("${BOOTSTRAP_EXTRA[@]/--human-admin/}"); shift ;;
    --human)      HUMAN="${2:?}"; shift 2 ;;
    -h|--help)    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "bench-up: option inconnue: $1" >&2; exit 1 ;;
  esac
done

# TROIS CYCLES DE VIE, ET C'EST VOULU. La forge garde SON projet : elle coute deux passes
# d'amorcage quand la boite ne coute qu'un build, et `bench-swap-image.sh` existe pour exploiter
# cette asymetrie. Une fusion des projets rendait un `down -v` capable d'emporter la forge semee
# avec la boite — mesure et corrigee le 2026-08-07.
# Le piege 1 (resoudre `forge` AVANT le premier boot) ne se paie plus par un `network connect`
# manuel : la surcouche declare le reseau de la forge en `external` et compose branche la boite a la
# CREATION. Meme recette que `bench-runner.sh` pour le runner depuis le 2026-08-02.
FORGE_PROJECT="${PROJECT}forge"
FORGE_CONTAINER="${FORGE_PROJECT}-forge-1"
FORGE_NET="${FORGE_PROJECT}_default"
BOX="${PROJECT}-lcars-1"
COMPOSE_ARGS=(-f "$DOCKER_DIR/docker-compose.install.yml" -f "$DOCKER_DIR/docker-compose.bench.yml" -p "$PROJECT")
# L'URL suit le BIND, pas un 127.0.0.1 fige : sinon un banc bind sur .7 amorce une forge joignable
# a une autre adresse que celle qu'il annonce, et le premier lecteur du recap se trompe de fenetre.
FORGE_URL="http://${BIND}:${FORGE_PORT}"

say() { printf '[bench-up] %s\n' "$*"; }
die() { printf '[bench-up] %s\n' "$*" >&2; exit "${2:-1}"; }

command -v "$DOCKER_BIN" >/dev/null || die "docker introuvable (DOCKER_BIN=$DOCKER_BIN)"

# ─── 0. LE DAEMON, ET LA SONDE QUI ATTRAPE LE RELAIS MUET ───────────────────────────────────────
# Sur cette distro, le daemon est Docker Desktop cote Windows : il n'y a NI dockerd NI
# /var/run/docker.sock ici. Deux chemins d'acces existent, et ILS NE SE VALENT PAS :
#
#   a) la socket Docker Desktop elle-meme, /mnt/wsl/docker-desktop/.../docker.proxy.sock —
#      complete, mais root:root 0755 a la creation (donc inutilisable sans un chgrp fleet) ;
#   b) le relais systemd du groupe fleet, /run/docker-fleet.sock (systemd-socket-proxyd,
#      outillage/install-docker-relay.sh) — lisible par tout le groupe, et **AMPUTE**.
#
# CE QUE LE RELAIS FAIT DE PIRE (mesure du 2026-08-04) : il repond parfaitement aux commandes qui
# lisent (`version`, `ps`, `inspect`, `images`) et rend ZERO OCTET, EXIT 0, sur toute commande a
# flux attache — `exec`, `cp`, `run`, `attach`. Un `docker exec ... gitea --version` ne dit rien et
# reussit. Consequence pour ce script : chaque valeur capturee par un exec (master token, token
# systeme, verdict des creds) devient une chaine VIDE que le code prend pour un fait. L'amorçage
# est mort sur « la forge n'a pas rendu de master token » — un diagnostic qui accuse la forge, qui
# etait saine. Un instrument qui repond a moitie est pire qu'un instrument absent.
#
# D'ou : on prefere (a) quand elle est joignable, on retombe sur (b), et dans TOUS les cas on sonde
# le flux attache AVANT de commencer — la sonde est un aller-retour reel, pas une supposition.
if [[ -z "${DOCKER_HOST:-}" ]]; then
  DD_SOCK="/mnt/wsl/docker-desktop/shared-sockets/guest-services/docker.proxy.sock"
  if [[ -S "$DD_SOCK" && -w "$DD_SOCK" ]]; then
    export DOCKER_HOST="unix://$DD_SOCK"
    say "daemon : socket Docker Desktop directe"
  elif [[ -S /run/docker-fleet.sock ]]; then
    export DOCKER_HOST="unix:///run/docker-fleet.sock"
    say "daemon : relais fleet (la sonde de flux dira s'il est ampute)"
  fi
fi

"$DOCKER_BIN" version --format '{{.Server.Version}}' >/dev/null 2>&1 \
  || die "aucun daemon docker joignable (DOCKER_HOST=${DOCKER_HOST:-<vide>}) — Docker Desktop lance ?" 1

# La sonde : un aller-retour attache sur l'image qu'on s'apprete a deployer (locale, aucun pull).
# ⚠ LE GESTE CITE ICI POINTAIT VERS `./docker.sh build` — UN SCRIPT QUI N'EXISTE PAS dans ce depot
# (verifie le 2026-08-14 : aucun fichier de ce nom, et personne n'exporte LCARS_GIT_SHA). Un
# operateur qui suit ce message ne construit rien ; un agent qui le suit invente sa propre commande,
# et c'est exactement comme cette boite a fini par tourner sans savoir dire quel code elle portait.
"$DOCKER_BIN" image inspect "$IMAGE" >/dev/null 2>&1 \
  || die "image absente localement: $IMAGE
   Construire (le sha est OBLIGATOIRE, cf. le bloc revision plus bas) :
     LCARS_IMAGE=$IMAGE LCARS_GIT_SHA=\$(git rev-parse --short HEAD) \\
     LCARS_BUILD_DATE=\$(date -u +%Y-%m-%dT%H:%M:%SZ) \\
     docker compose -f fleet/deploy/docker/docker-compose.yml build" 1

# LA BOITE DOIT POUVOIR DIRE QUEL CODE ELLE PORTE, ET LE BANC DOIT LE LIRE AVANT DE L'ANNONCER.
# Mesure du 2026-08-14 : une image batie a la main (docker build nu, sans --build-arg) deployait un
# banc entierement vert dont `/api/version` rendait `sha: "unknown"`. Rien ne l'avait remarque —
# donc aucun verdict rendu par ce banc n'etait attribuable a un commit, ce qui est la seule chose
# qu'on lui demande. Le tag de l'image ne prouve rien : c'est un nom, il s'ecrit a la main.
#
# Ce n'est PAS un refus : la boite fonctionne, elle est seulement muette sur son origine. On le dit
# dans le bloc de verdict, a cote de `creds` et `admin`, la ou l'operateur lit l'etat du banc.
IMAGE_REV="$("$DOCKER_BIN" image inspect \
  -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$IMAGE" 2>/dev/null || true)"
if [[ -z "$IMAGE_REV" || "$IMAGE_REV" == "unknown" ]]; then
  IMAGE_REV_STATE="INCONNUE — image batie sans GIT_SHA : ce banc ne pourra attribuer aucun verdict a un commit"
else
  IMAGE_REV_STATE="$IMAGE_REV"
fi
PROBE="$("$DOCKER_BIN" run --rm --entrypoint sh "$IMAGE" -c 'echo flux-ok' 2>/dev/null | tr -d '[:space:]')"
[[ "$PROBE" == "flux-ok" ]] || die \
  "le daemon repond mais un flux attache revient VIDE (recu: '${PROBE:-<rien>}') — DOCKER_HOST=$DOCKER_HOST
   C'est le relais systemd : il ne supporte pas le hijack HTTP de docker exec/run/cp.
   Sortie connue (root, une fois par demarrage de Docker Desktop) :
     sudo chgrp fleet /mnt/wsl/docker-desktop/shared-sockets/guest-services/docker.proxy.sock
     sudo chmod 660  /mnt/wsl/docker-desktop/shared-sockets/guest-services/docker.proxy.sock" 1

# Refus net plutot qu'un ecrasement silencieux : ce script MONTE, il ne remplace pas.
if "$DOCKER_BIN" ps -a --format '{{.Names}}' | grep -qx "$BOX"; then
  die "le projet $PROJECT existe deja ($BOX) — detruis-le d'abord (bench-down.sh) ou change --project" 1
fi

# ─── 1. la forge jetable ─────────────────────────────────────────────────────────────────────────
say "forge jetable : projet $FORGE_PROJECT sur $FORGE_URL"
LCARS_DEVFORGE_PORT="$FORGE_PORT" LCARS_DEVFORGE_BIND="$BIND" LCARS_DEVFORGE_ROOT_URL="${FORGE_URL}/" \
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
    `# identite-v2 : le box materialise admiral (master/sysadmin, uid 1000). Le worker "$HUMAN" (lcars)` \
    `# n'est PAS cree par le box — il vient de la forge (team fleet:humans) via le convergeur.` \
    LCARS_ADMIRAL="admiral" \
    LCARS_ADMIRAL_EMAIL="admiral@lcars.local" \
    FORGE_BASE_URL="http://forge:3000" \
    LCARS_SOURCE_REMOTE="http://forge:3000/fleet/lcars.git" \
    LCARS_BIND="$BIND" \
    LCARS_SSH_PORT="${BIND}:2222" \
    LCARS_LANDING_PORT_BIND="${BIND}:20999" \
    FORGE_PUBLIC_URL="$FORGE_URL" \
    LCARS_DECK_ORIGINS="http://${BIND}:20999" \
    LCARS_DEVFORGE_NETWORK="$FORGE_NET" \
    "$DOCKER_BIN" compose "${COMPOSE_ARGS[@]}" create lcars \
  || die "la boite ne se cree pas (le reseau $FORGE_NET existe-t-il ?)" 3

# La graine du binaire vendor (piege 3bis) — dans la fenetre create→start, sur un conteneur qui
# existe et n'a pas demarre. Le chemin cible est lu dans provision-lib : le module qui le consomme
# en est l'autorite, et un chemin recopie ici derive le jour ou il bouge.
if [[ "$WITH_CLAUDE_BIN" -eq 1 ]]; then
  SEED_DEST="$(bash -c '. "$1" >/dev/null 2>&1; echo "$PROV_CLAUDE_SEED"' _ \
                 "$REPO_ROOT/fleet/deploy/lib/provision-lib.sh")"
  CLAUDE_REAL="$(readlink -f "$CLAUDE_FROM" 2>/dev/null || true)"
  if [[ -z "$SEED_DEST" ]]; then
    say "graine claude SAUTEE : provision-lib ne rend pas PROV_CLAUDE_SEED (la boite telechargera)"
  elif [[ ! -x "$CLAUDE_REAL" ]]; then
    # Degrade en le DISANT, jamais en mourant : un banc avec reseau marche tres bien sans graine.
    say "graine claude SAUTEE : $CLAUDE_FROM introuvable ou non executable — la boite telechargera au boot (il lui faut du reseau)"
  else
    "$DOCKER_BIN" cp "$CLAUDE_REAL" "$BOX:$SEED_DEST" \
      || die "graine claude non copiee vers $BOX:$SEED_DEST" 3
    say "graine claude posee ($CLAUDE_REAL -> $SEED_DEST) — 40-claude-bin ne touchera pas au reseau"
  fi
else
  say "graine claude NON posee (--no-claude-bin) — la boite telechargera au boot, par choix"
fi

# PAS DE `network connect` : la surcouche a declare le reseau de la forge en `external`, donc le
# `create` ci-dessus a DEJA branche la boite. `forge` resout avant le premier boot, ce qui etait
# toute la raison d'etre de la fenetre. Le `create` reste, lui, pour une AUTRE raison intacte : la
# graine du binaire vendor doit se poser sur un conteneur qui existe et n'a pas demarre (piege 3bis).
"$DOCKER_BIN" compose "${COMPOSE_ARGS[@]}" start lcars || die "la boite ne demarre pas" 3

for _ in $(seq 1 90); do
  [[ "$("$DOCKER_BIN" inspect -f '{{.State.Health.Status}}' "$BOX" 2>/dev/null)" == "healthy" ]] && break
  sleep 2
done
[[ "$("$DOCKER_BIN" inspect -f '{{.State.Health.Status}}' "$BOX" 2>/dev/null)" == "healthy" ]] \
  || die "la boite ne devient pas healthy (docker logs $BOX)" 3
say "boite healthy"

# ─── 2ter. mot de passe de banc d'admiral (ssh + sudo) ───────────────────────────────────────────
# admiral (uid 1000, sysadmin) est cree par l'entrypoint sans secret — l'entrypoint pose le siege,
# pas le mot de passe. On lui donne ici un secret de BANC CONNU (meme convention jetable que la forge,
# `LCARS_BENCH_ADMIRAL_PW`), pour pouvoir ssh/sudo sans aller le chercher. Jamais lu par la prod.
printf 'admiral:%s\n' "${LCARS_BENCH_ADMIRAL_PW:-toto1234}" | "$DOCKER_BIN" exec -i "$BOX" chpasswd 2>/dev/null \
  && say "mot de passe de banc pose sur admiral (ssh/sudo)" \
  || say "admiral : mot de passe non pose — ssh par cle, ou 'docker exec -u admiral $BOX bash'"

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
cp -r "$REPO_ROOT/fleet/deploy/deps/." "$TOFU_DIR/"
say "recette tofu dans $TOFU_DIR (etat PARTAGE par les deux passes)"

say "amorcage passe 1 (structure — le semis sera saute, c'est attendu)"
DOCKER_BIN="$DOCKER_BIN" "$HERE/bench-forge-bootstrap.sh" \
    --forge-url "$FORGE_URL" --container "$FORGE_CONTAINER" --box "$BOX" --human "$HUMAN" \
    --tofu-dir "$TOFU_DIR" ${BOOTSTRAP_EXTRA[@]+"${BOOTSTRAP_EXTRA[@]}"} \
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
    --tofu-dir "$TOFU_DIR" ${BOOTSTRAP_EXTRA[@]+"${BOOTSTRAP_EXTRA[@]}"} \
  || die "amorcage passe 2 en echec" 4

# ─── 7. verdict MESURE ───────────────────────────────────────────────────────────────────────────
SYS_TOKEN="$("$DOCKER_BIN" exec "$BOX" cat /home/private/system.gitea_token 2>/dev/null | tr -d '[:space:]' || true)"
[[ -n "$SYS_TOKEN" ]] || die "token systeme absent apres deux passes — le banc n'est PAS pret" 6

ROLE_TOKENS="$("$DOCKER_BIN" exec "$BOX" bash -c 'ls /home/private/*.gitea_token 2>/dev/null | wc -l' || echo 0)"
CREDS_OK="$("$DOCKER_BIN" exec -u "$HUMAN" "$BOX" bash -c '[ -s ~/.claude/.credentials.json ] && echo oui || echo non')"
# Le verdict RESONDE la promotion plutot que de repeter le flag : ce qui est affiche est ce que la
# forge repond, pas ce qu'on lui a demande.
HUMAN_ADMIN_STATE="$(curl -s -m 5 -u "$HUMAN:toto32toto32" "$FORGE_URL/api/v1/user" \
  | python3 -c 'import json,sys; print("site-admin" if json.load(sys.stdin).get("is_admin") else "non-admin")' 2>/dev/null || echo "?")"

# ─── 7. LE RUNNER — on APPELLE la recette, on ne la refait pas ───────────────────────────────────
# `bench-runner.sh` (2026-08-02) EST le geste, et il porte deux pieges reseau qu'un appel naif
# reprendrait de plein fouet. Le projet unique en desamorce UN : le runner joint la forge parce
# qu'ils partagent le reseau. Le SECOND reste entier et n'a rien a voir avec le notre — les
# conteneurs de JOB n'heritent pas du reseau du runner, act_runner les cree sur son reseau par
# defaut, et le clone echoue sur `forge:3000` introuvable. Son en-tete le nomme : « un runner vert
# qui rate tous ses jobs, le pire des etats ». Il pose la config `container.network` pour ca, et il
# la copie par `docker cp` parce qu'un bind depuis cette distro WSL est invisible au daemon.
# Reecrire tout ca ici aurait produit un runner qui s'enregistre et ne sert rien.
RUNNER_STATE="non demarre"
MASTER_TOKEN_FILE="$TOFU_DIR/.master-token"

# ⚠ LE DIAGNOSTIC ETAIT DEJA JUSTE, ET LE VERDICT DISAIT LE CONTRAIRE (6-133). Les branches
# ci-dessous ecrivent « ABSENT », « BLOCAGE, pas degradation », « enregistrement rate » — puis le
# script imprimait `banc PRET` et rendait 0. Un appelant automatique acceptait donc un banc qui ne
# peut jouer aucun workflow CI, et un test d'integration restait `pending` au lieu de reveler que
# son harnais etait incomplet. Le detail textuel signalait l'absence ; le code de retour et le
# verdict principal affirmaient l'inverse, et c'est le verdict qu'on lit.
#
# `RUNNER_SERT` porte la seule question qui compte : un runner sert-il le label demande, VU PAR LA
# FORGE ? Elle ne se deduit pas de `RUNNER_STATE`, qui est une PHRASE — la deriver d'un texte serait
# remettre le verdict a la merci d'une reformulation.
RUNNER_SERT=0

# Derivation MESUREE du label `elixir` : le stage `build` du meme tag, s'il existe sur ce daemon.
if [[ -z "$RUNNER_LABELS" ]]; then
  BUILD_IMG="lcars-build:${IMAGE##*:}"
  if "$DOCKER_BIN" image inspect "$BUILD_IMG" >/dev/null 2>&1; then
    RUNNER_LABELS="shell:docker://alpine:3.20,elixir:docker://$BUILD_IMG,dood:docker://docker:cli"
  fi
fi

if [[ "$WITH_RUNNER" -eq 0 ]]; then
  RUNNER_STATE="NON demarre (--no-runner) — aucun workflow CI ne tournera sur ce banc, par choix"
elif [[ -z "$RUNNER_LABELS" ]]; then
  # ⚠ LES BACKTICKS SONT ECHAPPES, ET CE N'EST PAS DE LA COQUETTERIE. Dans une chaine a GUILLEMETS
  # DOUBLES, `ci: required` est une SUBSTITUTION DE COMMANDE : bash executait `ci:`, ne le trouvait
  # pas, et `set -euo pipefail` tuait le script — exit 127, pour seul message « ci:: command not
  # found ». Cette branche et la suivante ne « remplissaient » donc pas RUNNER_STATE : elles
  # mouraient AVANT de l'ecrire, sans diagnostic, ce que 6-133 ne voit pas. Mesure faite en
  # atteignant la branche depuis un test.
  RUNNER_STATE="ABSENT — pas d'image lcars-build:${IMAGE##*:} pour le label elixir (CI indisponible).
  ⚠ CE N'EST PAS UNE DEGRADATION, C'EST UN BLOCAGE : la carte canon declare \`ci: required\`, donc
  le gate attend un statut sur chaque PR, 45 min, puis ESCALADE. Aucun jury n'est convoque
  entre-temps — rien ne sera livre sur ce banc tant qu'aucun runner ne sert le label.
              Sortie : docker build --target build -t lcars-build:${IMAGE##*:} -f fleet/deploy/docker/Dockerfile .
              puis rejouer bench-runner.sh, ou --runner-labels pour choisir soi-meme"
elif [[ ! -s "$MASTER_TOKEN_FILE" ]]; then
  RUNNER_STATE="ABSENT — pas de master token persiste. ⚠ BLOCAGE, pas degradation : \`ci: required\` sur la carte canon, donc chaque PR attend 45 min puis escalade, sans jury"
else
  # ⚠ LA SORTIE DU SOUS-SCRIPT EST CAPTUREE, PLUS JETEE. Elle partait en `>/dev/null 2>&1`, donc le
  # SEUL mode d'echec que ce script ne savait pas expliquer etait celui qu'il faisait taire
  # lui-meme : le verdict se reduisait a « en echec (rejouable : bench-runner.sh --help) », et il
  # fallait rejouer le sous-script a la main — en reconstruisant ses six arguments, dont un token
  # qui vit dans un `mktemp` — pour lire une phrase que le banc avait deja eue sous les yeux.
  # Mesure du 2026-08-14 : le refus etait « image(s) introuvable(s) sur ce daemon : alpine:3.20,
  # docker:cli », diagnostic complet et actionnable, perdu par la redirection.
  #
  # Le silence reste la regle au SUCCES — un banc qui marche n'a pas a deverser le journal de ses
  # sous-scripts. C'est l'echec qui parle, et il parle avec les mots du sous-script, pas les notres.
  RUNNER_LOG="$TOFU_DIR/bench-runner.out"
  if DOCKER_BIN="$DOCKER_BIN" "$HERE/bench-runner.sh" \
       --forge-api "$FORGE_URL/api/v1" \
       --admin-token "$(cat "$MASTER_TOKEN_FILE")" \
       --instance-url "http://forge:3000" \
       --network "$FORGE_NET" \
       --project "${PROJECT}-runner" \
       --labels "$RUNNER_LABELS" >"$RUNNER_LOG" 2>&1; then
    # Le verdict RESONDE la forge : un runner qui tourne sans s'etre enregistre est exactement le
    # silence que ce banc doit refuser.
    RUNNERS="$(curl -s -m 5 -H "Authorization: token $(cat "$MASTER_TOKEN_FILE")" \
        "$FORGE_URL/api/v1/admin/actions/runners" 2>/dev/null \
      | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    rs = d.get("runners", d if isinstance(d, list) else [])
    print(len(rs))
except Exception: print(0)' 2>/dev/null || echo 0)"
    if [[ "${RUNNERS:-0}" -gt 0 ]]; then
      RUNNER_STATE="ENREGISTRE ($RUNNERS vu(s) par la forge)"
      RUNNER_SERT=1
    else
      RUNNER_STATE="demarre mais AUCUN runner vu par la forge — enregistrement rate"
    fi
  else
    RUNNER_STATE="ABSENT — bench-runner.sh en echec, son refus mot pour mot :
$(sed 's/^/              /' "$RUNNER_LOG" 2>/dev/null | tail -12)"
  fi
fi

# TROIS VERDICTS, ET `--no-runner` EN PORTE SON PROPRE — jamais l'equivalent du banc complet. Un
# mode degrade choisi et un mode degrade subi ne se disent pas du meme mot : celui qui lit un journal
# doit pouvoir distinguer « je n'ai pas voulu de CI » de « la CI n'a pas pu se poser ».
if [[ "$WITH_RUNNER" -eq 0 ]]; then
  VERDICT="banc PRET_SANS_CI"
elif [[ "$RUNNER_SERT" -eq 1 ]]; then
  VERDICT="banc PRET"
else
  VERDICT="banc PAS PRET — le runner etait DEMANDE et ne sert pas"
fi

say "─────────────────────────────────────────────────────────"
say "$VERDICT"
say "  forge     : $FORGE_URL   (humain $HUMAN / toto32toto32)"
say "  boite     : $BOX   ssh ${BIND}:2222   deck ${BIND}:20999"
say "  image     : $IMAGE"
say "  revision  : $IMAGE_REV_STATE"
say "  runner    : $RUNNER_STATE"
say "  tokens    : $ROLE_TOKENS fichiers dans /home/private"
say "  creds     : $CREDS_OK"
say "  admin     : $HUMAN_ADMIN_STATE"
say "  destruire : bench-down.sh --project $PROJECT"
say "─────────────────────────────────────────────────────────"

# LE BLOC EST IMPRIME AVANT LE REFUS, delibere : l'operateur a besoin des details POUR reparer, et
# un `die` en tete les lui prendrait. Le code 6 est celui que ce script reserve deja au « verdict
# final qui ne passe pas » — la nature est la meme, la cause est nouvelle.
if [[ "$WITH_RUNNER" -eq 1 && "$RUNNER_SERT" -ne 1 ]]; then
  die "runner DEMANDE et non servi ($RUNNER_STATE) — banc INCOMPLET. \`--no-runner\` pour un banc sans CI, assume et dit comme tel" 6
fi
