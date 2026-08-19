#!/usr/bin/env bash
# SOURCE: fleet/deploy/docker/bench/bench-up.sh
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
#    au boot depuis claude.ai — donc UN BANC EXIGE DU RESEAU, et c'est voulu (⚖ user 2026-08-17 :
#    « il DOIT derouler le compose entierement, et re-dl a chaque tour »). Un semis a existe ici et
#    a ete retire : il rendait vert un chemin que le banc n'avait pas parcouru. Sans reseau, le boot
#    ne pose aucun binaire, aucun pod ne demarre — et c'est au VERDICT de provisioning de le dire
#    fort, pas a une copie cachee de le masquer.
# 4. UN BANC NE DOIT JAMAIS COGNER LE BANC D'A COTE. Projet compose, port de forge et adresse de
#    bind sont TOUS parametres et defaultent sur des valeurs libres. `--bind` couvre la boite ET la
#    forge depuis le 2026-08-07 : jusque-la il n'etait passe qu'a la boite, la forge retombait sur
#    le defaut `127.0.0.1` du compose, et cet en-tete l'affirmait deja couverte. La separation
#    tenait quand meme — par unicite du PORT — mais un `--bind 127.0.0.7` rendait une forge sur .1. Le geste destructeur (`down -v`)
#    n'est pas ici : il est dans `bench-down.sh`, separement, pour qu'aucune faute de frappe sur ce
#    script-ci ne detruise un banc qui travaille.
#
# USAGE : bench-up.sh [--project lcars-nuit] [--forge-port 21000] [--deck-port 20999] [--ssh-port 2222]
#                     [--bind 0.0.0.0] [--advertise <ip-ou-nom>]
#                     [--image lcars-fleet:2] [--creds-from ~/.claude/.credentials.json] [--no-creds]
#                     [--no-human-admin]
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
# ⚖ ARBITRAGE USER 2026-08-18 — LE BANC S'OUVRE SUR LE LAN, ET DEUX PORTS SONT FIXES : 20999 pour
# le deck, 21000 pour la forge. La beta se pretе a des amis : ils arrivent d'une AUTRE machine, donc
# un bind sur une loopback (`127.0.0.5`) leur ferme la porte sans un mot — le port repond, mais
# seulement a la machine qui l'heberge.
#
# ⚠ CE QUE CA COUTE, ET IL FAUT LE LIRE AVANT DE LANCER : ce banc porte des mots de passe de TEST
# ecrits en clair dans le README (`toto32toto32`, `toto1234`). Ouvert sur 0.0.0.0, il est joignable
# par tout ce qui atteint cette machine. C'est un choix pour un LAN de confiance, pas un defaut a
# emporter ailleurs — `--bind 127.0.0.1` le referme.
FORGE_PORT="21000"
DECK_PORT="20999"
SSH_PORT="2222"
BIND="0.0.0.0"
# L'ADRESSE ANNONCEE N'EST PAS L'ADRESSE D'ECOUTE, et les confondre casse deux choses precises.
# `0.0.0.0` est un joker d'ecoute : ce n'est l'adresse de personne. Mise dans le `ROOT_URL` de Gitea
# elle part dans chaque lien qu'il fabrique, et le navigateur d'un ami suit un lien vers nulle part ;
# mise dans le `redirect_uri` OAuth2, le retour de login tombe dans le vide. On DERIVE donc l'adresse
# que les autres composent — l'IP de cette machine sur son reseau — et `--advertise` la remplace
# quand la derivation se trompe (plusieurs interfaces, un nom DNS, un reverse-proxy).
ADVERTISE=""
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
    --deck-port)  DECK_PORT="${2:?}"; shift 2 ;;
    # ⚠ LE PORT SSH ETAIT LE SEUL DES TROIS A NE PAS AVOIR SON OPTION, et c'est le pre-vol des
    # ports qui l'a rendu visible : deux bancs sur une meme machine se refusaient sur 2222 alors
    # que la forge et le deck, eux, se deplacaient. Un banc de plus par machine est le cas
    # ordinaire ici (un jetable qu'on casse, un complet ou on travaille), pas une exception.
    --ssh-port)   SSH_PORT="${2:?}"; shift 2 ;;
    --bind)       BIND="${2:?}"; shift 2 ;;
    --advertise)  ADVERTISE="${2:?}"; shift 2 ;;
    --image)      IMAGE="${2:?}"; shift 2 ;;
    --runner-labels) RUNNER_LABELS="${2:?}"; shift 2 ;;
    --no-runner)  WITH_RUNNER=0; shift ;;
    --creds-from) CREDS_FROM="${2:?}"; shift 2 ;;
    --no-creds)   WITH_CREDS=0; shift ;;
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
# ─── LES DEUX ADRESSES, ET ELLES NE SE CONFONDENT PAS ────────────────────────────────────────────
#
#   FORGE_LOCAL_URL  celle que CE script compose pour parler a la forge (sondes, amorcage, API).
#                    Elle doit etre joignable depuis ici, tout de suite. Un bind joker (`0.0.0.0`)
#                    n'est pas une adresse : on passe par la loopback, qui atteint le port publie
#                    quel que soit le bind.
#   FORGE_URL        celle qu'on ANNONCE — le `ROOT_URL` de Gitea, le `FORGE_PUBLIC_URL` de la
#                    boite, la ligne du recap. C'est celle qu'un ami compose depuis sa machine.
#
# Un bind precis (`--bind 127.0.0.5`) rend les deux egales et l'ancien comportement revient.
# LA DERIVATION DE L'ADRESSE ANNONCEE VIT DANS `provision-lib.sh`, PAS ICI — et elle depend du
# SUBSTRAT. `ip route get`, qui tenait ce role, repond « par ou je pars » ; on le lisait « par ou on
# m'atteint ». Sous WSL2 en mode NAT les deux different, et la reponse etait fausse : cf. le pave
# `advertise_addr` dans la lib, qui porte la mesure. Ce script ne re-implemente rien — deux copies
# d'une meme derivation divergent, et celle qu'on lit n'est jamais celle qu'on a corrigee.
# shellcheck source=../../lib/provision-lib.sh
source "$DOCKER_DIR/../lib/provision-lib.sh"
# Les noms des volumes du magasin. Le banc monte LA MEME boite que l'install nominale
# (`docker-compose.install.yml`), donc il porte les memes volumes externes — et il doit les poser
# avant son `create`, pour la meme raison : compose REFUSE de demarrer sur un `external` absent.
# shellcheck source=../../lib/store.sh
source "$DOCKER_DIR/../lib/store.sh"

case "$BIND" in
  0.0.0.0|::|"*") PROBE_HOST="127.0.0.1" ;;
  *)              PROBE_HOST="$BIND" ;;
esac
if [[ -z "$ADVERTISE" ]]; then
  advertise_addr "$BIND"; ADVERTISE="$PROV_ADVERTISE"
  # RIEN A ANNONCER N'EST PAS UNE PANNE, mais ca doit se DIRE. `PROV_ADVERTISE_WHY` est vide quand
  # l'adresse est une vraie adresse de reseau, et porte sinon la phrase qui dit ce qu'elle vaut.
  ADVERTISE_GUESSED="${PROV_ADVERTISE_WHY:-}"
fi

FORGE_LOCAL_URL="http://${PROBE_HOST}:${FORGE_PORT}"
# L'adresse par laquelle un CONTENEUR atteint cette machine — troisieme role, distinct des deux
# au-dessus. `lan_addr` repond « par ou je sors », ce qui est faux pour ANNONCER (cf. WSL en NAT)
# et juste pour ceci : c'est la meme interface que le NAT du daemon emprunte. Repli sur l'annoncee
# quand il n'y a pas d'adresse de sortie du tout (machine hors reseau).
# ⚠ LA TROISIEME ADRESSE DEPEND DU SUBSTRAT, ET CE SCRIPT N'EN CONNAISSAIT QU'UNE.
# Ce n'est ni le bind, ni l'adresse ANNONCEE : c'est celle par laquelle un CONTENEUR atteint cette
# machine. Sur linux natif, c'est l'adresse de sortie — le daemon tourne sur l'hote, ses conteneurs
# voient son IP (mesure du 2026-08-18 sur .63). Sous Docker Desktop, le daemon vit dans une AUTRE VM :
# l'IP de la distro WSL ne lui est pas routee, et c'est `host.docker.internal` qui designe l'hote.
#
# Mesure du 2026-08-19 sur une WSL vierge, depuis un conteneur de JOB (reseau isole DANS le dind) :
#   http://<lan_addr>:21199          -> download timed out
#   http://host.docker.internal:21199 -> {"version":"1.26.1"}
#
# Se tromper ici ne casse pas le banc, ce qui est pire : le runner demarre, seme son magasin
# d'images, et ne s'enregistre JAMAIS — « la forge ne liste aucun runner apres 60 s », un diagnostic
# qui accuse la forge alors qu'elle repondait a trois adresses sur quatre.
if [[ "$(detect_substrate)" == "wsl" ]]; then
  JOB_HOST="host.docker.internal"
else
  JOB_HOST="$(lan_addr)"; JOB_HOST="${JOB_HOST:-$ADVERTISE}"
fi
FORGE_URL="http://${ADVERTISE}:${FORGE_PORT}"

say() { printf '[bench-up] %s\n' "$*"; }
die() { printf '[bench-up] %s\n' "$*" >&2; exit "${2:-1}"; }

# ⚠ UN NOM NU ET UN CHEMIN NE SE TESTENT PAS PAREIL. `command -v` ne trouve un chemin absolu que
# s'il est executable, mais il rend VRAI pour un repertoire portant ce nom — et surtout, la porte
# peut nous passer un SHIM d'escalade (socket appartenant a root), qui est un chemin, pas un nom.
[[ "$DOCKER_BIN" == */* ]] && { [[ -f "$DOCKER_BIN" && -x "$DOCKER_BIN" ]] || die "docker introuvable (DOCKER_BIN=$DOCKER_BIN)"; } \
  || command -v "$DOCKER_BIN" >/dev/null || die "docker introuvable (DOCKER_BIN=$DOCKER_BIN)"

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
#
# ⚠ CE MESSAGE A TENDU UNE INCANTATION MANUELLE PENDANT TROIS JOURS, AU MOTIF QUE `./docker.sh
# build` « n'existait pas dans ce depot ». Il existe, a la racine, et son `build_env()` exporte
# exactement les DEUX estampilles que ce refus declare obligatoires (`LCARS_GIT_SHA`,
# `LCARS_BUILD_DATE`). Le geste juste etait donc a une ligne, et le message envoyait recopier
# quatre lignes ou l'une des deux s'oublie en silence — ce qui produit precisement l'image muette
# sur son origine que le bloc « revision » ci-dessous existe pour attraper.
#
# LA LECON N'EST PAS « verifier ses chemins » : un refus qui DICTE une commande a la place de
# l'outil du depot double le rail. Quand l'outil bouge, la dictee reste, et c'est elle qu'on suit.
"$DOCKER_BIN" image inspect "$IMAGE" >/dev/null 2>&1 \
  || die "image absente localement: $IMAGE
   Construire (depuis la racine du depot) :
     ./docker.sh build
   Il pose le sha et la date de build, tous deux OBLIGATOIRES (cf. le bloc revision plus bas)." 1

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

# ─── 0. LES PORTS SONT-ILS LIBRES ? ──────────────────────────────────────────────────────────────
#
# ⚠ UN BIND JOKER NE PARTAGE PAS UN PORT, ET L'ERREUR NE LE DIT PAS. Avec des binds de loopback
# distincts (`127.0.0.5`, `.6`, `.7`) plusieurs bancs cohabitaient sur les memes numeros. Sur
# `0.0.0.0`, il n'y en a plus qu'UN par port — et docker le refuse en nommant l'adresse de l'AUTRE :
# « Bind for 127.0.0.6:2222 failed: port is already allocated », sur un banc ou personne n'a jamais
# tape `127.0.0.6`. Mesure du 2026-08-18. Le script mourait la-dessus en « la boite ne demarre pas ».
#
# On demande donc AVANT, et on nomme le detenteur. Deux sorties, pas une : detruire l'autre banc, ou
# deplacer les ports de celui-ci.
port_holder() { # <port> -> "<nom> (projet <p>)" du conteneur qui le publie, hors de NOS projets
  local port="$1" name proj
  while read -r name; do
    [[ -n "$name" ]] || continue
    proj="$("$DOCKER_BIN" inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$name" 2>/dev/null || true)"
    [[ "$proj" == "$PROJECT" || "$proj" == "$FORGE_PROJECT" || "$proj" == "${PROJECT}-runner" ]] && continue
    printf '%s (projet %s)\n' "$name" "${proj:-<hors compose>}"
    return 0
  done < <("$DOCKER_BIN" ps --filter "publish=$port" --format '{{.Names}}' 2>/dev/null)
  return 1
}

BUSY=()
for _p in "$SSH_PORT" "$DECK_PORT" "$FORGE_PORT"; do
  _h="$(port_holder "$_p")" && BUSY+=("$_p -> $_h")
done
if [[ ${#BUSY[@]} -gt 0 ]]; then
  say "REFUS : un autre conteneur tient deja un des ports de ce banc."
  for _b in "${BUSY[@]}"; do say "  $_b"; done
  say "  Un bind « $BIND » prend le port sur TOUTES les adresses : il n'y a qu'un banc par port."
  say "  Sorties : detruire l'autre banc (bench-down.sh --project <son-projet>),"
  say "            ou deplacer celui-ci (--forge-port / --deck-port / --ssh-port, et --bind pour une loopback)."
  exit 1
fi

# ─── 1. la forge jetable ─────────────────────────────────────────────────────────────────────────
say "forge jetable : projet $FORGE_PROJECT sur $FORGE_URL"
LCARS_DEVFORGE_PORT="$FORGE_PORT" LCARS_DEVFORGE_BIND="$BIND" LCARS_DEVFORGE_ROOT_URL="${FORGE_URL}/" \
  "$DOCKER_BIN" compose -f "$HERE/forge-compose.yml" -p "$FORGE_PROJECT" up -d \
  || die "la forge ne monte pas" 2

for _ in $(seq 1 60); do
  curl -sf -m 3 "$FORGE_LOCAL_URL/api/v1/version" >/dev/null 2>&1 && break
  sleep 2
done
curl -sf -m 3 "$FORGE_LOCAL_URL/api/v1/version" >/dev/null 2>&1 || die "la forge ne repond pas sur $FORGE_LOCAL_URL" 2
say "forge up"

# ─── 2. la boite — create, brancher, PUIS demarrer (piege 1) ─────────────────────────────────────
# Les volumes du magasin AVANT le create : `external: true` veut dire que compose ne les fabrique
# pas et refuse de demarrer sans eux. Ils sont partages entre les bancs de la machine — un volume
# externe n'est pas prefixe par le projet — donc le second banc ne repaie pas ce que le premier a
# telecharge, et `bench-down` ne peut pas les emporter.
store_ensure_volumes "$DOCKER_BIN" || die "magasin non pose — la boite ne peut pas se creer" 3
say "boite : projet $PROJECT, image $IMAGE, bind $BIND"
env LCARS_IMAGE="$IMAGE" \
    `# identite-v2 : le box materialise admiral (master/sysadmin, uid 1000). Le worker "$HUMAN" (lcars)` \
    `# n'est PAS cree par le box — il vient de la forge (team fleet:humans) via le convergeur.` \
    LCARS_ADMIRAL="admiral" \
    FORGE_BASE_URL="http://forge:3000" \
    LCARS_SOURCE_REMOTE="http://forge:3000/fleet/lcars.git" \
    LCARS_BIND="$BIND" \
    LCARS_SSH_PORT="${BIND}:${SSH_PORT}" \
    LCARS_LANDING_PORT_BIND="${BIND}:${DECK_PORT}" \
    FORGE_PUBLIC_URL="$FORGE_URL" \
    `# L'ENTREE ANNONCEE. Le deck derive son redirect_uri du Host de la requete (console-deck.py) et` \
    `# OAuth2 compare EXACTEMENT : une entree non declaree finit sur un refus APRES identification.` \
    `# Les deux ecritures de la loopback (127.0.0.1 ET localhost — deux ORIGINES pour un meme point` \
    `# d'ecoute) sont semees par 55-deck-oidc ; ici on ne nomme que celle qu'on annonce.` \
    LCARS_DECK_ORIGINS="http://${ADVERTISE}:${DECK_PORT}" \
    LCARS_DEVFORGE_NETWORK="$FORGE_NET" \
    "$DOCKER_BIN" compose "${COMPOSE_ARGS[@]}" create lcars \
  || die "la boite ne se cree pas (le reseau $FORGE_NET existe-t-il ? les volumes du magasin ?)" 3

# ⚠ LE SEMIS DU BINAIRE VENDOR A VECU ICI ET N'EXISTE PLUS (2026-08-17). NE PAS LE REMETTRE.
#
# ⚖ ARBITRAGE USER : « le bench ne devrait PAS copier le binaire local, il DOIT derouler le compose
# entierement, et re-dl a chaque tour. C'est moi qui paye la BP, j'ai jamais demande a l'economiser
# pour 300 Mo — et en faisant ca on a un banc qui ne reflete pas la realite du deploy de prod, donc
# il est inutile. »
#
# C'est la meme faute que ce depot traque partout : un banc seme rend VERT un chemin qu'il n'a pas
# parcouru. Le telechargement du binaire EST une etape du deploiement reel ; la sauter fait mesurer
# autre chose que ce qu'on croit mesurer.
#
# La fenetre `create` -> `start` reste, elle, pour la raison qui la justifiait deja seule : la boite
# doit etre sur le reseau de la forge AVANT de demarrer (piege 1), sinon `forge` ne resout pas et
# tout le provisioning forge part en drift au premier boot.

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

# ─── 3. les creds anthropic : DEPLACEES APRES LA RELANCE (piege 3) ───────────────────────────────
# Elles vivaient ICI, et depuis identite-v2 c'etait trop tot. L'entrypoint ne fabrique plus le
# worker : il materialise `admiral` (uid 1000, sysadmin) et RIEN d'autre. `$HUMAN` (lcars) vient de
# la FORGE — seme par l'amorcage en 4, materialise par le convergeur au boot de la relance en 5.
# A cet endroit-ci il n'existe donc pas encore, et `docker exec -u lcars` meurt sur
# « unable to find user lcars: no matching entries in passwd file ».
# Mesure du 2026-08-15, premiere execution du chemin admiral : `/etc/passwd` de la boite healthy ne
# porte QUE `admiral`. Le geste est en 5bis, la ou l'utilisateur existe — meme instant que le bloc de
# verdict, qui lit deja les creds avec `-u "$HUMAN"` sans jamais avoir eu de probleme.
[[ "$WITH_CREDS" -eq 1 ]] || say "creds NON posees (--no-creds) — aucun pod ne pourra demarrer, par choix"

# ─── 4. amorcage de la forge, passe 1 : structure ────────────────────────────────────────────────
# ⚠ CE BLOC ORGANISAIT LA SURVIE D'UN TFSTATE ENTRE LES DEUX PASSES, et il n'existait que parce que
# la recette n'etait pas rejouable : etat vide sur forge peuplee -> 409, mesure du 2026-08-03. La
# recette IMPORTE desormais ce que la forge porte deja (2026-08-16), donc l'etat est jetable et il
# n'y a plus rien a faire survivre. Le dossier partage, la copie de la recette et le `--tofu-dir`
# sont partis avec le defaut qui les avait fait naitre.
say "amorcage passe 1 (structure — le semis sera saute, c'est attendu)"
# ⚠ LE CODE DU SOUS-SCRIPT EST RENDU, PAS REMPLACE PAR 4. `bench-forge-bootstrap.sh` distingue
# SEPT sorties (2 la forge muette · 3 admiral/token · 4 la structure · 5 le seed · 6 le verdict ·
# 7 le semis) et ce site les ecrasait toutes sous « amorcage passe 1 en echec 4 » — un chiffre qui
# nomme la passe et pas la cause. Mesure du 2026-08-18 : deux diagnostics a l'aveugle sur cette
# ligne exacte, sur une machine distante, ou relire le sous-script coute un aller-retour.
BOOT_RC=0
DOCKER_BIN="$DOCKER_BIN" "$HERE/bench-forge-bootstrap.sh" \
    --forge-url "$FORGE_LOCAL_URL" --container "$FORGE_CONTAINER" --box "$BOX" --human "$HUMAN" \
    ${BOOTSTRAP_EXTRA[@]+"${BOOTSTRAP_EXTRA[@]}"} || BOOT_RC=$?
[[ "$BOOT_RC" -eq 0 ]] || die "amorcage passe 1 en echec (bench-forge-bootstrap.sh rend $BOOT_RC — sa derniere ligne ci-dessus nomme l'etape)" 4

# ─── 5. relance de la boite : 50-forge minte les role-tokens sur le seed (piege 2) ───────────────
say "relance de la boite pour que 50-forge minte les role-tokens"
"$DOCKER_BIN" restart "$BOX" >/dev/null || die "relance de la boite impossible" 3
for _ in $(seq 1 90); do
  [[ "$("$DOCKER_BIN" inspect -f '{{.State.Health.Status}}' "$BOX" 2>/dev/null)" == "healthy" ]] && break
  sleep 2
done
[[ "$("$DOCKER_BIN" inspect -f '{{.State.Health.Status}}' "$BOX" 2>/dev/null)" == "healthy" ]] \
  || die "la boite ne redevient pas healthy apres relance" 3

# ─── 5bis. les creds anthropic (piege 3) — ICI, parce que le worker existe MAINTENANT ────────────
# Cette relance est le boot ou le convergeur lit le roster de la forge et materialise `$HUMAN` en
# utilisateur unix (uid >= 1001). Avant elle, la boite ne porte qu'`admiral` : cf. le bloc 3.
if [[ "$WITH_CREDS" -eq 1 ]]; then
  [[ -r "$CREDS_FROM" ]] || die "creds illisibles: $CREDS_FROM (--no-creds pour un banc sans pods)" 5
  # L'existence est VERIFIEE avant l'exec, sinon l'echec parle docker et pas fleet : « unable to find
  # user » n'apprend a personne que le worker vient de la forge et pas de la boite.
  "$DOCKER_BIN" exec "$BOX" id -u "$HUMAN" >/dev/null 2>&1 \
    || die "le worker '$HUMAN' n'existe pas dans la boite apres la relance — le convergeur ne l'a pas
   materialise. Il vient de la FORGE (team fleet:humans), pas de l'entrypoint : verifier que
   l'amorcage passe 1 l'a bien seme, et les logs du convergeur ('docker logs $BOX')" 5
  "$DOCKER_BIN" exec -i -u "$HUMAN" "$BOX" bash -c \
      'mkdir -p ~/.claude && cat > ~/.claude/.credentials.json && chmod 600 ~/.claude/.credentials.json' \
    < "$CREDS_FROM" || die "creds non posees dans la boite" 5
  say "creds anthropic posees chez $HUMAN (le spawn-boundary passera)"
fi

# ─── 6. amorcage passe 2 : le semis ──────────────────────────────────────────────────────────────
say "amorcage passe 2 (semis des depots — le token systeme existe maintenant)"
BOOT_RC=0
DOCKER_BIN="$DOCKER_BIN" "$HERE/bench-forge-bootstrap.sh" \
    --forge-url "$FORGE_LOCAL_URL" --container "$FORGE_CONTAINER" --box "$BOX" --human "$HUMAN" \
    ${BOOTSTRAP_EXTRA[@]+"${BOOTSTRAP_EXTRA[@]}"} || BOOT_RC=$?
[[ "$BOOT_RC" -eq 0 ]] || die "amorcage passe 2 en echec (bench-forge-bootstrap.sh rend $BOOT_RC — sa derniere ligne ci-dessus nomme l'etape)" 4

# ─── 7. verdict MESURE ───────────────────────────────────────────────────────────────────────────
SYS_TOKEN="$("$DOCKER_BIN" exec "$BOX" cat /home/private/system.gitea_token 2>/dev/null | tr -d '[:space:]' || true)"
[[ -n "$SYS_TOKEN" ]] || die "token systeme absent apres deux passes — le banc n'est PAS pret" 6

ROLE_TOKENS="$("$DOCKER_BIN" exec "$BOX" bash -c 'ls /home/private/*.gitea_token 2>/dev/null | wc -l' || echo 0)"
CREDS_OK="$("$DOCKER_BIN" exec -u "$HUMAN" "$BOX" bash -c '[ -s ~/.claude/.credentials.json ] && echo oui || echo non')"
# LE TOKEN OPERATEUR EST EXIGE ICI, ET C'EST CE QUI REND LE SAUT DE LA PASSE 1 SUR. `bench-forge-bootstrap`
# ne peut pas le poser a la passe 1 (le worker vient de la forge et n'existe qu'apres la relance), il le
# saute donc en le disant. Sans cette ligne, un banc dont les DEUX passes l'auraient saute monterait vert
# et muet — la boite ne parlerait pas a la forge, et rien ne l'aurait dit. Le message nomme la cause,
# pas le symptome : c'est l'existence du worker qui manque, pas le fichier.
OP_TOKEN_OK="$("$DOCKER_BIN" exec -u "$HUMAN" "$BOX" bash -c '[ -s ~/.gitea_token ] && echo oui || echo non' 2>/dev/null || echo non)"
[[ "$OP_TOKEN_OK" == "oui" ]] || die "token operateur absent chez $HUMAN apres DEUX passes — la boite ne
   pourra pas parler a la forge. Cause probable : le convergeur n'a jamais materialise '$HUMAN' (il vient
   de la team forge fleet:humans, pas de l'entrypoint) — 'docker exec $BOX id $HUMAN' et 'docker logs $BOX'" 6
# Le verdict RESONDE la promotion plutot que de repeter le flag : ce qui est affiche est ce que la
# forge repond, pas ce qu'on lui a demande.
HUMAN_ADMIN_STATE="$(curl -s -m 5 -u "$HUMAN:toto32toto32" "$FORGE_LOCAL_URL/api/v1/user" \
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
# L'AUTORITE SE LIT DANS LA BOITE, plus dans un fichier que ce banc aurait persiste. Elle y est
# posee par le geste generique (`forge-gestures.sh config-token`), 0600 root, et elle y RESTE —
# c'est l'arbitrage du 2026-08-16. Le banc n'a donc plus de credential a lui a faire survivre.
MASTER_TOKEN="$("$DOCKER_BIN" exec -u root "$BOX" cat /home/private/forge-master.token 2>/dev/null | tr -d '\r\n' || true)"

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
elif [[ -z "$MASTER_TOKEN" ]]; then
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
  RUNNER_LOG="$(mktemp "${TMPDIR:-/tmp}/bench-runner-${PROJECT}.XXXXXX")"
  # LE JETON D'ENREGISTREMENT VIENT DE LA PORTE GENERIQUE (`forge-gestures.sh runner-token`), pas
  # d'un appel API refait ici : c'est le meme geste que l'operateur jouera pour SON runner, par
  # `./docker.sh runner-token`. `bench-runner.sh` garde son `--reg-token`, qui existait deja pour
  # le cas ou l'appelant sait le produire mieux que lui — c'est desormais le cas nominal.
  REG_TOKEN="$("$DOCKER_BIN" exec -i -u root "$BOX" /opt/lcars/forge-gestures.sh runner-token < /dev/null 2>/dev/null | tail -1 || true)"
  if DOCKER_BIN="$DOCKER_BIN" "$HERE/bench-runner.sh" \
       --forge-api "$FORGE_LOCAL_URL/api/v1" \
       --admin-token "$MASTER_TOKEN" \
       ${REG_TOKEN:+--reg-token "$REG_TOKEN"} \
       `# ⚠ TROISIEME ADRESSE, ET LES DEUX AUTRES NE MARCHENT PAS ICI. Ce n'est ni le nom de service` \
       `# compose (le runner tourne en dind : ses conteneurs de JOB sont sur un reseau par job, ou` \
       `# "forge" n'existe pas — mesure du 2026-08-18, « Failed to connect to forge port 3000 »),` \
       `# ni l'adresse ANNONCEE (sous WSL c'est "localhost", qui dans un conteneur designe le` \
       `# conteneur). C'est celle par laquelle un CONTENEUR atteint cette machine : l'adresse de` \
       `# sortie, et le port publie. Mesure du meme jour, depuis un reseau isole dans le dind :` \
       `# http://<lan_addr>:21000/api/v1/version rend {"version":"1.26.1"}.` \
       `# Elle sert aux DEUX : le runner y sonde la forge, et le job y clone.` \
       --instance-url "http://${JOB_HOST}:${FORGE_PORT}" \
       --network "$FORGE_NET" \
       --project "${PROJECT}-runner" \
       --labels "$RUNNER_LABELS" >"$RUNNER_LOG" 2>&1; then
    # Le verdict RESONDE la forge : un runner qui tourne sans s'etre enregistre est exactement le
    # silence que ce banc doit refuser.
    RUNNERS="$(curl -s -m 5 -H "Authorization: token $MASTER_TOKEN" \
        "$FORGE_LOCAL_URL/api/v1/admin/actions/runners" 2>/dev/null \
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
say "  deck      : http://${ADVERTISE}:${DECK_PORT}"
say "  boite     : $BOX   ssh ${ADVERTISE}:${SSH_PORT}"
# LE RECAP DIT L'ADRESSE QU'ON COMPOSE, PAS CELLE SUR LAQUELLE ON ECOUTE. Il imprimait `$BIND`, ce
# qui donnait « deck 0.0.0.0:20999 » — une ligne qu'on ne peut pas taper. L'ecoute reste dite, a
# part, parce qu'elle porte la consequence : ouvert sur le reseau ou ferme sur la machine.
if [[ "$BIND" == "0.0.0.0" || "$BIND" == "::" ]]; then
  say "  ecoute    : $BIND — OUVERT SUR LE RESEAU. Les mots de passe de ce banc sont des defauts de"
  say "              test, publics dans le README : a n'ouvrir que sur un reseau de confiance."
  say "              « --bind 127.0.0.1 » le referme sur cette machine."
  if [[ -n "${ADVERTISE_GUESSED:-}" ]]; then
    say "  ⚠ adresse : les liens pointent sur $ADVERTISE. ${ADVERTISE_GUESSED}"
    say "              « --advertise <ip-ou-nom> » pour annoncer autre chose."
  fi
  # ⚖ ARBITRAGE USER 2026-08-18 — SOUS WSL, LE BANC EST HOST-ONLY, ET C'EST LA CIBLE.
  # Publier sur 0.0.0.0 ouvre le port DANS la VM, pas sur la machine : en NAT — le defaut de WSL et
  # de Docker Desktop, donc le cas de la quasi-totalite des postes Windows — rien ne route jusqu'a
  # elle depuis le LAN. L'ouvrir demanderait de toucher au reseau Hyper-V du poste, et ce n'est pas
  # une chose qu'un banc de test propose a qui que ce soit.
  #
  # ⚠ CE QUE CETTE LIGNE NE FAIT PLUS, DELIBEREMENT : elle imprimait deux commandes `netsh
  # portproxy` pretes a coller. Une recette est une invitation ; celle-ci invitait a reconfigurer la
  # pile reseau de la machine pour un banc de dev. On dit le FAIT et on s'arrete la.
  #
  # La cible LAN — un NAS, un rpi, un homelab dispo 24/7 — c'est le Linux natif, ou la derivation
  # nominale donne la vraie adresse et ou il n'y a rien a regler. Depuis l'exterieur, c'est un
  # tunnel monte par la personne : hors perimetre.
  if [[ "$(detect_substrate)" == "wsl" && "$(wsl_networking_mode)" == "nat" ]]; then
    say "  portee    : WSL en mode NAT (le defaut) — ce banc n'est joignable que depuis CETTE machine."
    say "              Un deploiement ouvert sur le LAN, c'est un Linux natif ; ici c'est test/dev."
  fi
else
  say "  ecoute    : $BIND (cette machine seulement)"
fi
say "  image     : $IMAGE"
say "  revision  : $IMAGE_REV_STATE"
say "  runner    : $RUNNER_STATE"
say "  tokens    : $ROLE_TOKENS fichiers dans /home/private"
say "  op-token  : $OP_TOKEN_OK (~/.gitea_token de $HUMAN — la voie de la boite vers la forge)"
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
