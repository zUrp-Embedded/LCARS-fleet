#!/usr/bin/env bash
# SOURCE: fleet/deploy/docker/bench/bench-runner.sh
# AUTHOR: consultant
# STARDATE: 2026-08-02
# STATUS: geste de BANC — enregistre un runner CI de circonstance sur la forge jetable
#
# ─── CE QUE C'EST ───────────────────────────────────────────────────────────────────────────────
# Le pendant runner de `bench-degrade.sh` : sur un banc qu'on nuke plusieurs fois par jour,
# l'appairage runner<->forge meurt avec la forge, et le rail CI du template laisse des runs en
# Waiting pour toujours. Ce script rejoue l'appairage en un geste : il minte le token
# d'enregistrement (API admin), pose la config reseau des JOBS, et lance le compose de
# l'operateur — `runner-compose.yml`, INCHANGE. La recette qui marche reste celle de l'operateur ;
# ce fichier n'ajoute que ce que le banc exige.
#
# ─── LES DEUX PIEGES RESEAU, ET POURQUOI UN OVERRIDE ────────────────────────────────────────────
# 1. Le RUNNER doit joindre la forge pour s'enregistrer : sur le banc elle n'existe que dans le
#    reseau compose de la forge jetable (`http://forge:3000`). L'override branche donc le projet
#    runner sur CE reseau (network externe), au lieu d'un `docker network connect` a la main que
#    le prochain nuke oublierait.
# 2. Les JOBS ne heritent PAS du reseau du runner : act_runner cree les conteneurs de job sur son
#    propre reseau par defaut, d'ou un clone qui echoue sur `forge:3000` introuvable — un runner
#    vert qui rate tous ses jobs, le pire des etats. La config `container.network` force les jobs
#    sur le meme reseau que la forge. C'est la troisieme incarnation du meme piege : une URL n'est
#    jamais absolue, elle est relative au reseau d'ou on la joint — `http://forge:3000` resout
#    depuis un conteneur du reseau de la forge, jamais depuis un navigateur de l'hote.
#
# IDEMPOTENT : re-jouable apres chaque nuke. L'identite du runner vit dans le volume du projet
# compose ; un runner deja enregistre sur une forge MORTE est un zombie — d'ou le `down -v`
# d'office avant chaque pose : sur un banc, l'histoire du runner ne vaut rien, l'appairage si.
#
# USAGE : bench-runner.sh --forge-api <url-api AVEC /api/v1 — ex http://127.0.0.1:3600/api/v1>
#                         (--admin-token <tok> | --admin-token-file <chemin>)
#                         [--instance-url http://forge:3000] [--network lcars-ticketforge_default]
#                         [--project lcars-ticket-runner] [--verify-repo fleet/lcars]
#                         [--labels "shell:docker://alpine:3.20,elixir:docker://lcars-build:3,dood:docker://docker:cli,ubuntu-latest:docker://catthehacker/ubuntu:act-latest"]
#                         [--accept-generic]
# EXIT  : 0 runner enregistre (et job verifie si --verify-repo) · 1 arguments · 2 la forge refuse
#         3 le runner ne s'enregistre pas · 4 le job de verification ne passe pas

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORGE_API="" ; TOKEN="" ; INSTANCE_URL="http://forge:3000" ; NETWORK="lcars-ticketforge_default"
PROJECT="lcars-ticket-runner" ; VERIFY_REPO="" ; DOCKER_BIN="${DOCKER_BIN:-docker}"
# Vide = le defaut de runner-compose.yml (qui ne sait PAS jouer `mix gate`, cf. son commentaire).
LABELS="${LCARS_RUNNER_LABELS:-}"
ACCEPT_GENERIC=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --forge-api)    FORGE_API="${2:?}"; shift 2 ;;
    --admin-token)  TOKEN="${2:?}"; shift 2 ;;
    # ⚠ UN SECRET DANS `argv` EST LISIBLE PAR TOUT L'HOTE dans `/proc` pendant l'appel, et il ressort
    # dans la trace de tout appelant qui imprime la commande qu'il a jouee. Ce script protege deja
    # le jeton de `curl` (`-K -`, plus bas) : il doit pouvoir le recevoir sans l'exposer lui-meme.
    # Le CHEMIN n'est pas un secret ; le fichier porte ses propres droits.
    --admin-token-file) TOKEN="$(tr -d '[:space:]' < "${2:?}")"; shift 2 ;;
    --reg-token)    REG_GIVEN="${2:?}"; shift 2 ;;
    --instance-url) INSTANCE_URL="${2:?}"; shift 2 ;;
    --network)      NETWORK="${2:?}"; shift 2 ;;
    --project)      PROJECT="${2:?}"; shift 2 ;;
    --verify-repo)  VERIFY_REPO="${2:?}"; shift 2 ;;
    --labels)       LABELS="${2:?}"; shift 2 ;;
    --accept-generic) ACCEPT_GENERIC=1; shift ;;
    *) echo "bench-runner: option inconnue: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$FORGE_API" && -n "$TOKEN" ]] || { echo "bench-runner: --forge-api et --admin-token(-file) requis" >&2; exit 1; }

# ─── L'AUTH DE LA FORGE PASSE PAR STDIN, JAMAIS PAR ARGV ────────────────────────────────────────
#
# ⚠ `-H "Authorization: token $TOKEN"` MET LE JETON MASTER DANS LA LIGNE DE COMMANDE, que
# `/proc/<pid>/cmdline` expose a tout l'hote pendant la requete — cicatrice 6-141, deja payee deux
# fois sur des credentials MOINS puissants que celui-ci. Trois appels de ce fichier le faisaient.
#
# Releve par une revue adverse le 2026-08-19, et le constat porte plus loin que les trois lignes :
# le commit qui a sorti `LCARS_RUNNER_TOKEN` de l'environnement affirmait « le jeton ne passe pas en
# argv pour autant » — vrai du jeton d'ENREGISTREMENT, faux du jeton MASTER, qui voyageait juste a
# cote. Une correction qui deplace une fuite sans le dire en fabrique une seconde, plus discrete.
#
# `-K -` : curl lit sa config sur stdin. Le jeton n'apparait ni dans argv ni dans l'environnement.
forge_curl() { printf 'header = "Authorization: token %s"\n' "$TOKEN" | curl -K - "$@"; }

say() { echo "[bench-runner] $*"; }

# ─── 0. LES LABELS SONT UNE PROMESSE, ET ELLE SE VERIFIE AVANT DE LA FAIRE ──────────────────────
# Un label est une CLE que le runner annonce a la forge : « envoie-moi les jobs qui demandent ca ».
# Le runner s'enregistre VERT quelle que soit l'image derriere, puis rate chaque job qu'on lui
# confie. C'est mot pour mot le piege n2 de l'en-tete a une autre couche — « un runner vert qui
# rate tous ses jobs, le pire des etats » — et ce fichier le decrivait en note depuis le 2026-08-02
# sans rien en faire. Une note qui decrit un silence reste un silence.
#
# Deux refus, tous deux avant le moindre appel a la forge :
#
#   a) LABELS vide → le defaut de runner-compose sert `elixir` avec l'image de BASE du stage build,
#      qui porte Elixir et RIEN d'autre (ni git, ni bats, ni bwrap, ni python3). Le gate y meurt.
#      Ce defaut est correct pour un operateur quelconque, qui ne peut pas resoudre une image
#      locale de LCARS ; il ne l'est pas pour un BANC, qui sait qu'il est LCARS. On le refuse donc
#      ici, en donnant la sortie, plutot que de poser un runner dont on a ecrit qu'il ne sait pas
#      travailler. `--accept-generic` reste la porte : un banc qui ne veut QUE le rail template n'a
#      rien a faire du gate, et le dire est une decision, pas un oubli.
#
#   b) une image nommee qui n'existe pas sur CE daemon. `docker image inspect` est une commande a
#      flux NON attache : elle traverse le relais systemd du groupe fleet, contrairement a `exec`,
#      `run` et `cp` qui y rendent zero octet et exit 0. Cette sonde-la marche donc partout.
check_labels() {
  if [[ -z "$LABELS" ]]; then
    [[ "$ACCEPT_GENERIC" -eq 1 ]] && { say "labels: defaut generique ACCEPTE (--accept-generic) — ce runner ne sait pas jouer mix gate"; return 0; }
    cat >&2 <<'EOM'
[bench-runner] REFUS : aucun --labels, donc le defaut de runner-compose.yml — dont l'image `elixir`
[bench-runner]   est celle de BASE du stage build : Elixir et rien d'autre. `mix gate` y meurt sur
[bench-runner]   `git` introuvable, et le runner aura l'air vert. Sortie :
[bench-runner]     docker build --target build -t lcars-build:<tag> -f fleet/deploy/docker/Dockerfile .
[bench-runner]     bench-runner.sh ... --labels "shell:docker://alpine:3.20,elixir:docker://lcars-build:<tag>,dood:docker://docker:cli,ubuntu-latest:docker://catthehacker/ubuntu:act-latest"
[bench-runner]   Un banc qui ne veut que le rail CI du template : --accept-generic (c'est une decision).
EOM
    exit 1
  fi

  # ⚠ UNE IMAGE ABSENTE SE TIRE AVANT DE SE REFUSER. La garde ci-dessous est juste — un runner qui
  # annonce un label qu'il ne sait pas servir rate chaque job qui le demande — mais elle refusait
  # AUSSI les images publiques que personne n'avait jamais demande a personne de tirer. Mesure du
  # 2026-08-18, machine Debian neuve, chemin de livraison : `REFUS : docker:cli`, banc exit 6. Sur
  # la machine de dev les memes images etaient la depuis des mois, donc invisible.
  #
  # ⚖ La bande passante est arbitree (user) : « le bench DOIT derouler le compose entierement, et
  # re-dl a chaque tour ». On tire donc, et le refus ne tombe que si le tir echoue ET que l'image
  # reste absente — ce qui garde le refus intact pour une image LOCALE (`lcars-build:<tag>`), qui
  # n'est sur aucun registre et dont le message nomme la commande de build.
  local missing=()
  local entry image
  local IFS=,
  for entry in $LABELS; do
    image="${entry#*docker://}"
    [[ "$image" == "$entry" ]] && continue   # label sans image (host runner) : rien a resoudre
    "$DOCKER_BIN" image inspect "$image" >/dev/null 2>&1 && continue
    say "image absente, tentative de tir : $image"
    "$DOCKER_BIN" pull -q "$image" >/dev/null 2>&1 || true
    "$DOCKER_BIN" image inspect "$image" >/dev/null 2>&1 || missing+=("$image")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    say "REFUS : image(s) introuvable(s) sur ce daemon, et non tirables : ${missing[*]}"
    say "  un runner annonce le label quand meme et rate chaque job qui le demande."
    say "  construis-la (docker build --target build -t <image> ...) ou corrige --labels."
    exit 1
  fi
  say "labels: ${LABELS//,/ }"
}

check_labels

# ─── 1. Token d'enregistrement, minte par la forge (site-admin, portee instance) ────────────────
# `--reg-token` court-circuite l'appel API, et ce n'est pas une commodite : le endpoint exige une
# PORTEE de token que le token operateur d'un banc n'a pas forcement (mesure du 2026-08-09 : 403
# « token does not have at least one of required scope » avec un token pourtant is_admin=True). La
# forge sait toujours en minter un elle-meme, depuis son propre conteneur :
#     docker exec <forge> gitea actions generate-runner-token
# Sans cette porte, un banc dont le token est trop etroit n'a AUCUNE sortie et le runner reste
# absent — donc la CI muette, donc des gates qui attendent leur borne puis escaladent.
if [[ -n "${REG_GIVEN:-}" ]]; then
  REG="$REG_GIVEN"
  say "token d'enregistrement FOURNI (--reg-token), pas d'appel API"
else
  REG=$(forge_curl -s -m 10 -X POST "$FORGE_API/admin/actions/runners/registration-token" \
        | python3 -c "import json,sys;print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)
fi
[[ -n "$REG" ]] || {
  say "la forge n'a pas rendu de token d'enregistrement (portee du token ? cf. --reg-token)"
  exit 2
}
say "token d'enregistrement minte (${#REG} car)"

# ─── 2. Config jobs + override reseau, generes a cote de rien (tmpdir) ──────────────────────────
# CE TMPDIR N'EST PAS NETTOYE, ET C'EST DELIBERE (revu le 2026-08-18, en fermant la fuite de
# credentials de `bench-swap-image`). Il ne porte AUCUN secret — un nom de reseau et un chemin de
# config — et `override.yml` est un `-f` de compose : compose l'inscrit dans le label
# `config_files` du projet, donc l'effacer casserait un `compose` ultérieur sur ce meme projet.
# Quelques ko qui restent valent mieux qu'un projet compose qui ne se relit plus.
GEN="$(mktemp -d)"
cat > "$GEN/config.yaml" <<EOF
# Genere par bench-runner.sh.
#
# ⚠ CE FICHIER FORÇAIT LES CONTENEURS DE JOB SUR LE RESEAU DE LA FORGE, et depuis que le runner
# tourne en dind ce reseau N'EXISTE PLUS DE LEUR POINT DE VUE. Il appartient au daemon de la
# MACHINE ; le daemon embarque du runner n'a que `bridge`, `host`, `none`. Un job nomme donc un
# reseau introuvable et son conteneur meurt a la creation, sans une ligne d'erreur exploitable —
# mesure du 2026-08-18 : « shim disconnected » deux dixiemes de seconde apres « Running job ».
#
# Et le forçage n'est plus necessaire, ce qui est le point : le runner, LUI, est sur le reseau de
# la forge, et ses conteneurs de job heritent de son resolveur. Mesure du meme jour, depuis le
# bridge interne : `getent hosts forge` -> 172.18.0.2, `wget http://forge:3000/api/v1/version` ->
# {"version":"1.26.1"}, et `git ls-remote http://forge:3000/fleet/lcars.git` rend le sha. Le clone
# — la seule chose que ce forçage protegeait — passe sans lui.
container:
  # Aucun reseau force : le bridge du daemon embarque suffit, et lui existe.
  privileged: false
EOF
# La config part par `docker cp`, JAMAIS par bind : le daemon vit dans la VM Docker Desktop, un
# bind d'un chemin de CETTE distro WSL lui est invisible — il cree un repertoire vide a la place,
# en silence (troisieme incarnation du piege des deux points de vue, apres l'URL navigateur et le
# reseau des jobs). Le fichier est copie dans le volume du runner (/data), qui appartient a la VM.
cat > "$GEN/override.yml" <<EOF
# Genere par bench-runner.sh — additif au runner-compose de l'operateur, jamais un remplacement.
services:
  runner:
    environment:
      CONFIG_FILE: /data/bench-config.yaml
networks:
  default:
    name: $NETWORK
    external: true
EOF

# ─── 3. Pose : down -v d'office (zombie d'une forge morte), puis up avec le token ───────────────
# Le down porte des valeurs factices : `runner-compose.yml` exige LCARS_FORGE_URL (`:?`) et
# l'interpolation refuse MEME un down. Sans elles, ce nettoyage echoue en silence sous le
# `|| true`, l'identite zombie survit dans le volume, et act_runner IGNORE le nouveau token
# (il ne s'enregistre pas si `.runner` existe) — un runner appaire a une forge morte.
# ⚠ LES VARIABLES D'INTERPOLATION VOYAGENT PAR UN ENV-FILE, PLUS PAR L'ENVIRONNEMENT — et c'est un
# appel qui traverse peut-etre une escalade. Sur WSL la socket docker appartient a root : le rail
# passe alors par un shim qui `sudo`, et `sudo` remet l'environnement a zero. Ces assignations en
# tete de commande mouraient donc en le traversant, compose retombait sur ses defauts, et le runner
# bouclait sur « token is empty » — un runner qui tourne, qui seme son magasin d'images, et qui ne
# s'enregistre jamais. Mesure sur instance vierge le 2026-08-19.
#
# ET LE JETON NE PASSE PAS EN ARGV POUR AUTANT. Le shim NE transmet PAS les noms qui portent la
# marque d'un secret, precisement pour ne pas les mettre dans une ligne de commande que /proc
# expose (cicatrice 6-141). L'env-file est la troisieme voie : le CHEMIN est dans argv, la VALEUR
# dans un fichier 0600.
#
# ⚠ CE FICHIER RESTE, il ne « meurt » avec rien : le tmpdir est deliberement NON nettoye (cf. plus
# haut — `override.yml` est un `-f` de compose, que l'effacer casserait). Le jeton d'enregistrement
# survit donc dans `/tmp` jusqu'au menage du systeme. Il est a usage unique et a courte portee, ce
# qui rend le cout acceptable ; l'ecrire comme s'il disparaissait, non.
RUNNER_ENV="$GEN/runner.env"
umask 077
printf 'LCARS_FORGE_URL=%s\nLCARS_RUNNER_TOKEN=%s\nLCARS_RUNNER_NAME=%s\nLCARS_RUNNER_LABELS=%s\n' \
  "$INSTANCE_URL" "$REG" "bench-runner" "$LABELS" > "$RUNNER_ENV"
# Le `down` d'office porte un token factice : `runner-compose.yml` exige LCARS_FORGE_URL (`:?`) et
# l'interpolation refuse MEME un down. Sans lui, ce nettoyage echoue en silence sous le `|| true`,
# l'identite zombie survit dans le volume, et act_runner IGNORE le nouveau token (il ne s'enregistre
# pas si `.runner` existe) — un runner appaire a une forge morte.
RUNNER_ENV_DOWN="$GEN/runner-down.env"
printf 'LCARS_FORGE_URL=%s\nLCARS_RUNNER_TOKEN=%s\n' "$INSTANCE_URL" " " > "$RUNNER_ENV_DOWN"

$DOCKER_BIN compose --env-file "$RUNNER_ENV_DOWN" -f "$HERE/runner-compose.yml" -f "$GEN/override.yml" -p "$PROJECT" down -v >/dev/null 2>&1 || true
$DOCKER_BIN compose --env-file "$RUNNER_ENV" -f "$HERE/runner-compose.yml" -f "$GEN/override.yml" -p "$PROJECT" up --no-start
$DOCKER_BIN cp "$GEN/config.yaml" "$PROJECT-runner-1:/data/bench-config.yaml"
$DOCKER_BIN compose --env-file "$RUNNER_ENV" -f "$HERE/runner-compose.yml" -f "$GEN/override.yml" -p "$PROJECT" start
say "runner lance (projet $PROJECT, reseau $NETWORK, config copiee dans le volume)"

# ─── 3-bis. LE MAGASIN DU DAEMON EMBARQUE — un daemon neuf n'a AUCUNE image ─────────────────────
#
# Depuis que le runner tourne en `dind-rootless`, ses jobs parlent a un daemon QUI LUI APPARTIENT,
# et non plus a celui de la machine. Ce daemon demarre vide : les images publiques, il les tire
# tout seul ; les images LOCALES — `lcars-build:<tag>` en tete, qu'aucun registre au monde ne porte
# — il ne peut pas les connaitre. Sans cette etape, le label `elixir` est annonce et chaque job qui
# le demande echoue sur une image introuvable : le « runner vert qui rate tous ses jobs » que
# l'etape 0 refuse deja, une couche plus bas.
#
# On ne parametre rien : LES LABELS NOMMENT DEJA CES IMAGES, et l'etape 0 a deja verifie qu'elles
# existent cote hote. On relit la meme liste.
#
# ⚠ `docker exec` PEUT RENDRE ZERO OCTET ET `exit 0` a travers un relais (c'est ecrit noir sur blanc
# a l'etape 0 de ce fichier, a propos du relais systemd du groupe fleet). Une sonde qui se
# contenterait du code de retour semerait donc dans le vide en se croyant verte. On EXIGE une sortie
# NON VIDE : si le relais avale, on refuse en le disant, on ne continue pas en silence.
seed_dind_images() {
  local c="$PROJECT-runner-1" i out entry image
  for i in $(seq 1 30); do
    out="$("$DOCKER_BIN" exec "$c" docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
    [[ -n "$out" ]] && break
    sleep 2
  done
  [[ -n "$out" ]] || {
    say "REFUS : le daemon embarque du runner ne rend rien apres 60 s."
    say "  soit il n'a pas demarre (privileged ? apparmor=rootlesskit ?), soit ce relais docker"
    say "  avale la sortie de \`exec\` — dans les deux cas on ne peut RIEN semer, et un runner"
    say "  sans ses images locales annonce des labels qu'il ne sait pas servir."
    exit 1
  }
  say "daemon embarque du runner : docker $out"

  local IFS=,
  for entry in $LABELS; do
    image="${entry#*docker://}"
    [[ "$image" == "$entry" ]] && continue
    [[ -n "$("$DOCKER_BIN" exec "$c" docker image inspect -f '{{.Id}}' "$image" 2>/dev/null || true)" ]] && continue
    # Publique : qu'il la tire lui-meme — c'est plus court qu'un transfert et ca suit l'amont.
    if "$DOCKER_BIN" exec "$c" docker pull -q "$image" >/dev/null 2>&1 &&
       [[ -n "$("$DOCKER_BIN" exec "$c" docker image inspect -f '{{.Id}}' "$image" 2>/dev/null || true)" ]]; then
      continue
    fi
    # Locale : elle n'est sur aucun registre. On la lui donne, depuis le daemon de la machine.
    say "image locale semee dans le daemon du runner : $image"
    "$DOCKER_BIN" save "$image" 2>/dev/null | "$DOCKER_BIN" exec -i "$c" docker load >/dev/null 2>&1 || true
    [[ -n "$("$DOCKER_BIN" exec "$c" docker image inspect -f '{{.Id}}' "$image" 2>/dev/null || true)" ]] || {
      say "REFUS : $image absente du daemon du runner apres semis — le label qui la nomme serait un mensonge"
      exit 1
    }
  done
  say "magasin du runner : toutes les images des labels sont resolubles"
}
seed_dind_images

# ─── 4. Preuve d'enregistrement : la forge le LISTE — pas le log du runner ──────────────────────
# LA SONDE DISTINGUE « pas enregistre » DE « je n'ai pas pu regarder », parce qu'elle a menti sur
# cette difference. Mesure du 2026-08-09 : le runner s'etait enregistre (« Runner registered
# successfully », et il tirait deja une tache) pendant que ce bloc annoncait ECHEC — le token du
# banc n'a pas la portee du endpoint admin, `curl` rendait un 403, le `|| echo 0` l'ecrasait en
# « zero runner ». Un banc sain declare en panne, et le geste suivant part reparer ce qui marche.
#
# Donc : le code HTTP est lu AVANT le corps. 403/401 → on ne SAIT pas, on le dit, et on ne prononce
# pas d'echec sur une mesure qu'on n'a pas pu prendre.
SEEN=0
PROBE_HTTP=""
for _ in $(seq 1 20); do
  sleep 3
  body="$(mktemp)"
  PROBE_HTTP=$(forge_curl -s -m 5 -o "$body" -w '%{http_code}' \
               "$FORGE_API/admin/actions/runners" 2>/dev/null || echo 000)
  if [[ "$PROBE_HTTP" == "200" ]]; then
    n=$(python3 -c "import json,sys;print(len(json.load(open('$body')).get('runners') or []))" 2>/dev/null || echo 0)
    rm -f "$body"
    [[ "${n:-0}" -ge 1 ]] && { SEEN=1; say "enregistre : la forge liste $n runner(s)"; break; }
  else
    rm -f "$body"
    [[ "$PROBE_HTTP" =~ ^(401|403)$ ]] && break
  fi
done

if [[ "$SEEN" -ne 1 ]]; then
  if [[ "$PROBE_HTTP" =~ ^(401|403)$ ]]; then
    say "NON VERIFIE (HTTP $PROBE_HTTP sur /admin/actions/runners — portee du token) : le runner est"
    say "  peut-etre enregistre, cette sonde ne peut pas le dire. Verifier a la main :"
    say "    $DOCKER_BIN logs ${PROJECT}-runner-1 | grep -i 'registered successfully'"
    exit 0
  fi
  say "ECHEC : la forge ne liste aucun runner apres 60 s (HTTP ${PROBE_HTTP:-?})"
  exit 3
fi

# ─── 5. Preuve de bout en bout (optionnelle) : un run du repo temoin passe VERT ─────────────────
# Un runner enregistre qui rate tous ses jobs est PIRE qu'un runner absent (il consomme les runs
# en les cassant). La preuve n est donc pas l'enregistrement : c'est un verdict de job.
if [[ -n "$VERIFY_REPO" ]]; then
  say "verification de bout en bout sur $VERIFY_REPO…"
  ok=""
  # 40 x 6 s = 4 min, et c'etait trop court : mesure du 2026-08-12, le runner venait d'etre
  # enregistre et la forge lui a d'abord servi le GATE COMPLET du depot lcars (plusieurs minutes).
  # La sonde a rendu 4 sur un runner qui allait tres bien. 20 min couvre un vrai gate.
  for _ in $(seq 1 200); do
    sleep 6
    st=$(forge_curl -s -m 6 "$FORGE_API/repos/$VERIFY_REPO/actions/tasks" \
         | python3 -c "
import json,sys
d=json.load(sys.stdin); runs=d.get('workflow_runs') or []
print(runs[0].get('status','') if runs else '')" 2>/dev/null || true)
    case "$st" in
      success) ok=1; break ;;
      failure|cancelled) say "ECHEC : le job de verification finit en $st"; exit 4 ;;
    esac
  done
  # UN RUN ENCORE EN ATTENTE N'EST PAS UN ECHEC DU RUNNER, et les confondre a coute une sonde
  # rouge sur un banc sain. L'enregistrement est deja PROUVE plus haut (la forge le liste) ; ce qui
  # reste ici est la preuve du verdict, et un job long ou une file occupee ne la contredisent pas.
  # Un `failure`/`cancelled`, lui, sort toujours en 4 : la, le runner casse ce qu'il prend.
  if [[ -n "$ok" ]]; then
    say "PREUVE : un job a tourne et la forge rend un verdict VERT"
  else
    say "run toujours EN ATTENTE apres 20 min — le runner est enregistre et la forge le liste,"
    say "  mais aucun verdict n'a ete rendu. Regarde ses logs (docker logs) avant de conclure :"
    say "  une file occupee et un runner mort se ressemblent d'ici."
  fi
fi

# ⚠ LES LABELS SE LISENT, ILS NE SE RECITENT PAS. Cette ligne en nommait trois en dur : un runner
# enrole avec un jeu different annoncait ceux d'un autre, et c'est justement ce message qu'un
# operateur relit pour savoir quel `runs-on` sa forge sait servir.
say "runner operationnel — labels servis : ${LABELS:-le defaut de runner-compose.yml}"
