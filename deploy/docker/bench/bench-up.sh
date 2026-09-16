#!/usr/bin/env bash
# SOURCE: deploy/docker/bench/bench-up.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-12
# STATUS: le banc — forge jetable, conteneur, structure, humain de démonstration, runner, fleet
#
# USAGE : bench-up.sh [--forge-project <base>] [--port-forge N] [--port-deck N] [--port-ssh N]
#                     [--bind 0.0.0.0] [--advertise <ip-ou-nom>] [--image lcars-fleet:local]
#                     [--creds-from ~/.claude/.credentials.json] [--no-creds]
#                     [--runner-labels <liste>] [--no-runner] [--human lcars]
#
#   Sans --forge-project ni option de port, la base et les ports sont les défauts de
#   deploy/installer-constants.env. Le banc monte une forge Gitea jetable (projet <base>-forge),
#   crée le conteneur (<base>-fleet) attaché à son réseau, y pose la structure de la forge,
#   l'humain de démonstration et ses jetons, sème le dépôt de la source à la révision de l'image,
#   enrôle un runner CI (<base>-runner) et démarre la fleet. Les mots de passe sont ceux du contrat
#   de banc : admiral / toto123456, lcars / toto32toto32 — publics, jetables. L'humain de
#   démonstration est site-admin de la forge : ce banc ne mesure pas ce que la team humans autorise
#   à un compte ordinaire. Un projet de ce nom qui ne porte pas le marqueur du banc
#   (label lcars.bench=<base>) est refusé avant tout.
#
# EXIT  : 0 banc prêt (« banc PRÊT », ou « banc PRÊT sans CI » sous --no-runner) · 1 arguments,
#         outil ou image absents, docker muet, port tenu, banc déjà monté, ou projet qui n'est pas
#         ce banc · 2 la forge ne monte pas · 3 le conteneur ne
#         monte pas · 4 amorçage de la forge · 5 humain ou credentials · 6 le banc n'est pas prêt
#         (jeton système absent après la relance, conteneur en échec de convergence, fleet qui ne
#         démarre pas, runner demandé qui ne sert pas) · 7 la source ne se sème pas (révision de
#         l'image, push, alignement du clone du conteneur)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(cd "$HERE/.." && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
BENCH_NOM=bench-up
# shellcheck source=../../lib/bench.sh
. "$DOCKER_DIR/../lib/bench.sh"

IMAGE="lcars-fleet:local"
RUNNER_LABELS="$PROV_RUNNER_LABELS"
WITH_RUNNER=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runner-labels) RUNNER_LABELS="${2:?--runner-labels attend une liste}"; shift 2 ;;
    --no-runner)     WITH_RUNNER=0; shift ;;
    -h|--help)       sed -n '/^# USAGE/,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)               bench_option "$@"; shift "$BENCH_LU" ;;
  esac
done
bench_projets
bench_adresses

FORGE_CONTAINER="${FORGE_PROJECT}-gitea-1"
RACINE_CONTENEUR="$(prov_canon "$PROV_ROOT")"
GESTES="$RACINE_CONTENEUR/forge-gestures.sh"
ADMIRAL="$BENCH_ADMIRAL"

case "$BIND" in
  0.0.0.0|::|"*") PROBE_HOST="127.0.0.1" ;;
  *)              PROBE_HOST="$BIND" ;;
esac
FORGE_LOCAL_URL="http://${PROBE_HOST}:${FORGE_PORT}"
ADMIRAL_PW="$(bench_admiral_password)"
HUMAN_PW="$(bench_human_password)"

d()   { "$DOCKER_BIN" "$@"; }
in_container() { d exec -i -u root "$CONTAINER" "$@"; }
as_human()     { d exec -i -u "$HUMAN" "$CONTAINER" "$@"; }

# ─── Le terrain ─────────────────────────────────────────────────────────────────────────────────
for _outil in curl jq git; do
  command -v "$_outil" >/dev/null 2>&1 || die "$_outil requis sur ce poste (le banc lit la forge par son API et sème sa source)" 1
done
PROV_DOCKER_BIN="$DOCKER_BIN"
docker_endpoint || die "$PROV_DOCKER_WHY" 1
# la CLI qui a répondu à la sonde sert aussi aux enfants : enroll-catalogue et forge-runner la lisent
export DOCKER_BIN="$PROV_DOCKER_BIN"
d image inspect "$IMAGE" >/dev/null 2>&1 \
  || die "image absente localement : $IMAGE — la tirer (deploy/container pull) ou la bâtir (deploy/pack.sh)" 1
IMAGE_REV="$(bench_revision "$IMAGE")"
[[ -n "$IMAGE_REV" && "$IMAGE_REV" != "unknown" ]] \
  || die "l'image $IMAGE ne porte pas de révision (label OCI) — le banc ne sème pas un code qu'il ne peut pas nommer" 7
OBJETS="$(bench_objets)" \
  || die "docker ne rend pas les objets des projets $CONTAINER_PROJECT, $FORGE_PROJECT, $RUNNER_PROJECT — rien n'est monté sur un état non lu" 1
ETRANGERS="$(bench_etrangers "$OBJETS")"
[[ -z "$ETRANGERS" ]] || bench_refus_etrangers "$ETRANGERS" "Un banc prend une base à lui : --forge-project <base>."
[[ "$OBJETS" != *"$CONTAINER_PROJECT conteneur "* ]] \
  || die "le banc $PROJECT existe déjà ($CONTAINER_PROJECT) — le détruire d'abord (bench-down.sh --project $PROJECT --yes) ou changer --forge-project" 1
BUSY=()
for _p in "$SSH_PORT" "$DECK_PORT" "$FORGE_PORT"; do
  _h="$(port_state "$_p" "$CONTAINER_PROJECT" "$FORGE_PROJECT" "$RUNNER_PROJECT")"
  [[ "$_h" != pris* ]] || BUSY+=("$_p -> ${_h#pris}")
done
if [[ ${#BUSY[@]} -gt 0 ]]; then
  say "refus : un autre conteneur ou un processus tient déjà un des ports de ce banc."
  for _b in "${BUSY[@]}"; do say "  $_b"; done
  say "  Un bind « $BIND » prend le port sur toutes les adresses : il n'y a qu'un banc par port."
  say "  Sorties : détruire l'autre banc (bench-down.sh --project <son-projet> --yes),"
  say "            ou déplacer celui-ci (--port-forge / --port-deck / --port-ssh, et --bind pour une loopback)."
  exit 1
fi

# ─── La forge ───────────────────────────────────────────────────────────────────────────────────
say "forge jetable : projet $FORGE_PROJECT sur $FORGE_URL"
quiet forge_mount "$DOCKER_BIN" "$DOCKER_DIR/forge-compose.yml" "$FORGE_PROJECT" "$FORGE_PORT" "$BIND" "$FORGE_URL" "$PROJECT" \
  || die "la forge ne monte pas" 2
forge_wait "$FORGE_LOCAL_URL" || die "la forge ne répond pas sur $FORGE_LOCAL_URL" 2
say "forge up"

# ─── Le conteneur ───────────────────────────────────────────────────────────────────────────────
store_ensure_volumes "$DOCKER_BIN" || die "magasin non posé — le conteneur ne peut pas se créer" 3
say "conteneur : projet $CONTAINER_PROJECT, image $IMAGE, bind $BIND"
# le conteneur matérialise admiral (uid 1000) ; l'humain vient de la forge, par le convergeur
quiet bench_conteneur_monte \
  || die "le conteneur ne se crée pas (le réseau $FORGE_NET existe-t-il ? les volumes du magasin ?)" 3
bench_attendre_healthy || die "le conteneur ne devient pas healthy (docker logs $CONTAINER)" 3
say "conteneur healthy"
bench_mot_de_passe "$ADMIRAL" "$ADMIRAL_PW"

# ─── L'amorçage : admin, jeton, seed, structure, humain ─────────────────────────────────────────
say "amorçage de la forge : compte $ADMIRAL, jeton master, seed"
case "$(forge_admin_ensure "$DOCKER_BIN" "$FORGE_CONTAINER" "$ADMIRAL")" in
  cree)    say "compte $ADMIRAL créé (site-admin de la forge)" ;;
  present) say "compte $ADMIRAL déjà présent" ;;
  *)       die "création du compte $ADMIRAL impossible" 4 ;;
esac
MASTER_TOKEN="$(forge_master_token "$DOCKER_BIN" "$FORGE_CONTAINER" "$ADMIRAL" "bench-$(date +%s)")" \
  || die "la forge n'a pas rendu de jeton master" 4
# les secrets de l'hôte vivent dans des fichiers 0600 d'un dossier 0700 : forge_api, git et forge-runner les lisent, jamais un argv
JETONS="$(mktemp -d "${TMPDIR:-/tmp}/bench-up-jetons.XXXXXX")"
trap 'rm -rf "$JETONS"' EXIT
( umask 077; printf '%s\n' "$MASTER_TOKEN" > "$JETONS/master" )
forge_token_ok "$FORGE_LOCAL_URL" "$JETONS/master" || die "le jeton master ne s'authentifie pas" 4
say "jeton master minté"
forge_admin_password "$FORGE_LOCAL_URL" "$JETONS/master" "$ADMIRAL" "$ADMIRAL_PW" \
  || die "mot de passe de banc de $ADMIRAL non posé" 4
say "mot de passe de banc posé sur $ADMIRAL"
SEED_PW="$(in_container cat "$(prov_canon "$PROV_FORGE_SEED_FILE")" 2>/dev/null | tr -d '\r\n' || true)"
if [[ -z "$SEED_PW" ]]; then
  SEED_PW="$(forge_seed_new)"; say "seed de banc généré"
else
  say "seed relu depuis $CONTAINER (celui des comptes existants)"
fi

# le roster des rôles vient du catalogue de l'image, jamais d'un clone de l'hôte
ROSTER_RC=0; ENROLL_OUT="$(prov_roster_conteneur "$IMAGE" in_container)" || ROSTER_RC=$?
[[ "$ROSTER_RC" -ne 1 ]] || die "dérivation du roster en échec (enroll-catalogue.sh, image $IMAGE)" 4
[[ "$ROSTER_RC" -eq 0 ]] || die "roster non déposé dans la recette de $CONTAINER" 4
# l'org du roster est celle du catalogue de l'image, où le banc sème la source ; l'org système
# (PROV_FORGE_ORG_DEFAULT) ne porte aucun projet, donc aucun repli sur elle : un roster muet est un refus
ORG="$(sed -n 's/^\[enroll-catalogue\] org *: \([A-Za-z0-9_.-]\{1,\}\)$/\1/p' <<<"$ENROLL_OUT")"
[[ -n "$ORG" ]] || die "le roster de l'image ne déclare pas d'org — le banc ne sait pas où semer la source (enroll-catalogue.sh, image $IMAGE)" 4
say "roster dérivé du catalogue de l'image ($(sed -n 's/^\[enroll-catalogue\] rôles *: //p' <<<"$ENROLL_OUT")) · org $ORG"

printf '%s' "$MASTER_TOKEN" | in_container "$GESTES" config-token || die "jeton master refusé par le conteneur" 4
printf '%s' "$SEED_PW"      | in_container "$GESTES" config-seed  || die "seed non posé dans le conteneur" 4
quiet d exec -i -u root -e LCARS_BUILTIN_HUMAN="$HUMAN" -e LCARS_BUILTIN_EMAIL="$HUMAN@lcars.local" \
    "$CONTAINER" "$GESTES" apply < /dev/null \
  || die "structure de la forge en échec dans $CONTAINER — rejouer :  $(bench_structure_geste "$HUMAN" "$CONTAINER")" 4
say "structure posée par le conteneur (org $ORG, teams, comptes, adhésions, dépôt modèle)"

HUMAN_TOKEN="$(bench_human_seed "$FORGE_LOCAL_URL" "$JETONS/master" "$HUMAN" "$HUMAN_PW" "" "$CONTAINER")" \
  || die "humain $HUMAN : mot de passe, adminité ou jeton opérateur refusés par la forge" 5
say "humain $HUMAN : mot de passe de banc posé, site-admin, jeton opérateur minté"

charte_out="$(d exec "$CONTAINER" bash -c \
    'cd "$1/services/forge-recipe" && ./provision-forge-charte.sh --forge "$FORGE_BASE_URL" --admiral "$2" --check' \
    _ "$RACINE_CONTENEUR" "$ADMIRAL" 2>&1)" || true
printf '%s\n' "$charte_out" | while IFS= read -r l; do [[ -z "$l" ]] || say "charte: $l"; done

# ─── Le runner, avant la relance ────────────────────────────────────────────────────────────────
# Le geste tokens du boot sonde les runners de la forge : enrôlé après la relance, le runner laissait
# un « AUCUN runner CI » dans le verdict que le banc lit et que status garde jusqu'au boot suivant.
# Il ne demande que la forge, son réseau et le jeton master déjà posé dans le conteneur.
RUNNER_SERT=0
if [[ "$WITH_RUNNER" -eq 0 ]]; then
  RUNNER_STATE="non démarré (--no-runner) — aucun workflow CI ne tournera sur ce banc, par choix"
elif ! JOB_URL="$(job_forge_url "$FORGE_PORT" "$ADVERTISE")"; then
  RUNNER_STATE="absent — aucune adresse de cette machine ne joint la forge depuis un job CI (adresse annoncée : $ADVERTISE) ; --advertise <adresse de l'hôte> la donne"
else
  say "runner CI : enrôlement sur la forge du banc (projet $RUNNER_PROJECT)"
  RUNNER_LOG="$(mktemp "${TMPDIR:-/tmp}/forge-runner-${PROJECT}.XXXXXX")"
  ( umask 077; in_container "$GESTES" runner-token < /dev/null 2>/dev/null | tail -1 > "$JETONS/reg" ) || true
  if "$DOCKER_DIR/forge-runner.sh" \
       --forge-api "$FORGE_LOCAL_URL/api/v1" --admin-token-file "$JETONS/master" --reg-token-file "$JETONS/reg" \
       --instance-url "$JOB_URL" --network "$FORGE_NET" \
       --project "$RUNNER_PROJECT" --labels "$RUNNER_LABELS" --bench "$PROJECT" >"$RUNNER_LOG" 2>&1; then
    RUNNER_SERT=1
    RUNNER_STATE="enregistré — labels : $RUNNER_LABELS"
    rm -f "$RUNNER_LOG"
  else
    RUNNER_STATE="absent — forge-runner.sh en échec, son refus mot pour mot :
$(sed 's/^/              /' "$RUNNER_LOG" 2>/dev/null | tail -12)
              sortie complète conservée : $RUNNER_LOG"
  fi
fi

# ─── La relance : le geste tokens minte les jetons de rôle, le convergeur matérialise l'humain ──
say "relance du conteneur : les jetons de rôle se mintent au boot, sur le seed"
bench_relance
as_human id -u "$HUMAN" >/dev/null 2>&1 \
  || die "l'humain '$HUMAN' n'existe pas dans le conteneur après la relance — il vient de la forge (team $ORG:humans), matérialisé par le convergeur : docker logs $CONTAINER" 5
printf '%s\n' "$HUMAN_TOKEN" | as_human bash -c 'umask 077 && cat > ~/.gitea_token' \
  || die "jeton opérateur non posé chez $HUMAN dans $CONTAINER" 5
say "jeton opérateur posé (~$HUMAN/.gitea_token)"
bench_mot_de_passe "$HUMAN" "$HUMAN_PW"
bench_creds

# ─── Le semis des dépôts : la source que le conteneur clone, à la révision de l'image ──────────
( umask 077
  { printf '[http "%s/"]\n\textraHeader = Authorization: token ' "$FORGE_LOCAL_URL"
    in_container cat "$(prov_canon "$PROV_SYSTEM_TOKEN_FILE")" 2>/dev/null | tr -d '[:space:]'
    printf '\n'
  } > "$JETONS/git-forge" ) || true
grep -q 'token [^[:space:]]' "$JETONS/git-forge" \
  || die "jeton système absent après la relance — le banc n'est pas prêt (docker logs $CONTAINER)" 6
# le jeton système atteint git par un fichier de configuration 0600 : ni argv, ni environnement
git_forge() { git -c "include.path=$JETONS/git-forge" "$@"; }
LCARS_REMOTE="$FORGE_LOCAL_URL/$ORG/lcars.git"
# le dépôt semé n'est plus le dépôt système (celui-là est <org système>/_ops, posé par la structure) :
# plus rien ne le crée, le banc le fait lui-même, vide (un push sur un dépôt vide passe, sur un dépôt
# absent la forge répond « Push to create is not enabled for organizations ») — jusqu'à ce que
# l'adoption de la source par le système remplace ce semis
code="$(forge_api GET "$FORGE_LOCAL_URL/api/v1/repos/$ORG/lcars" /dev/null --token-file "$JETONS/master" -m 10)" || {
  [[ "$code" == 404 ]] || die "$ORG/lcars : la forge ne dit pas si le dépôt existe (HTTP $code) — rien n'est semé à l'aveugle" 7
  forge_api POST "$FORGE_LOCAL_URL/api/v1/orgs/$ORG/repos" /dev/null --token-file "$JETONS/master" -m 20 \
      --json '{name: $n, private: false, auto_init: false, description: "La source de LCARS-fleet, semée par le banc à la révision de son image."}' \
      --arg n lcars >/dev/null || true
  # la relecture fait foi, pas le code du POST
  forge_api GET "$FORGE_LOCAL_URL/api/v1/repos/$ORG/lcars" /dev/null --token-file "$JETONS/master" -m 10 >/dev/null \
    || die "$ORG/lcars : dépôt non créé — le banc n'a nulle part où semer la source" 7
  say "$ORG/lcars : dépôt créé pour le semis"
}
if [[ -d "$REPO_ROOT/.git" ]]; then
  git -C "$REPO_ROOT" rev-parse -q --verify "${IMAGE_REV}^{commit}" >/dev/null 2>&1 \
    || die "$ORG/lcars : la révision de l'image ($IMAGE_REV) n'est pas dans ce clone ($REPO_ROOT) — le banc sème le code du conteneur ; rebâtir l'image depuis ce clone" 7
  SEED_DIR="$REPO_ROOT"; SEED_REF="$IMAGE_REV"; SEED_DIT="révision de l'image : $IMAGE_REV"
else
  # un kit n'a pas d'historique : sa révision est dans .source-revision, et le semis est un commit unique bâti de son arbre
  KIT_REV="$(tr -d '[:space:]' < "$REPO_ROOT/$PROV_SOURCE_STAMP" 2>/dev/null || true)"
  [[ -n "$KIT_REV" && ( "$IMAGE_REV" == "$KIT_REV"* || "$KIT_REV" == "$IMAGE_REV"* ) ]] \
    || die "$ORG/lcars : ce kit atteste « ${KIT_REV:-aucune révision} » et l'image $IMAGE porte $IMAGE_REV — le banc sème le code du conteneur ; prendre le kit de cette image" 7
  SEED_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lcars-seed.XXXXXX")"
  git -C "$SEED_DIR" init -q
  git --git-dir="$SEED_DIR/.git" --work-tree="$REPO_ROOT" add -A
  git --git-dir="$SEED_DIR/.git" -c user.name=lcars-bench -c user.email=bench@lcars.invalid commit -q -m "kit $KIT_REV" >/dev/null
  SEED_REF="$(git -C "$SEED_DIR" rev-parse HEAD)"; SEED_DIT="kit $KIT_REV, un commit sans historique"
fi
seed_hooks=(); seed_force=()
remote_main="$(git_forge ls-remote --heads "$LCARS_REMOTE" refs/heads/main 2>/dev/null | awk '{print $1}' || true)"
if [[ -n "$remote_main" ]] && ! git -C "$SEED_DIR" merge-base --is-ancestor "$remote_main" "$SEED_REF" 2>/dev/null; then
  # un main déjà là : un banc rejoué sur une forge qui garde le semis d'avant (le dépôt naît vide sinon)
  say "$ORG/lcars : le main déjà là (${remote_main:0:9}) est remplacé par le semis"
  seed_hooks=(-c core.hooksPath=/dev/null); seed_force=(--force)
fi
PUSH_ERR="$(git_forge -C "$SEED_DIR" ${seed_hooks[@]+"${seed_hooks[@]}"} push -q ${seed_force[@]+"${seed_force[@]}"} "$LCARS_REMOTE" "${SEED_REF}:refs/heads/main" 2>&1)" \
  || die "$ORG/lcars : main non poussé — c'est la source que le conteneur clone ; sans lui le banc n'a pas de code
  git a dit : $PUSH_ERR" 7
[[ "$SEED_DIR" == "$REPO_ROOT" ]] || rm -rf "$SEED_DIR"
say "$ORG/lcars : main poussé ($SEED_DIT)"
# la relance a cloné le dépôt tel que la structure l'a créé, avant le semis : le clone du conteneur
# se réaligne sur le main poussé, sous le compte qui le possède
SOURCE_IN="/home/projects/LCARS"
SOURCE_OWNER="$(in_container stat -c %U "$SOURCE_IN" 2>/dev/null | tr -d '[:space:]' || true)"
SOURCE_REMOTE_IN="$PROV_FORGE_INTERNAL_URL/$ORG/lcars.git"
if [[ -n "$SOURCE_OWNER" && "$SOURCE_OWNER" != "UNKNOWN" ]]; then
  quiet d exec -i -u "$SOURCE_OWNER" "$CONTAINER" \
      git -C "$SOURCE_IN" fetch -q --depth 1 "$SOURCE_REMOTE_IN" main < /dev/null \
    && quiet d exec -i -u "$SOURCE_OWNER" "$CONTAINER" git -C "$SOURCE_IN" reset -q --hard FETCH_HEAD < /dev/null \
    || die "$ORG/lcars : le clone du conteneur ($SOURCE_IN) ne se réaligne pas sur main — rejouer : docker exec -u $SOURCE_OWNER $CONTAINER git -C $SOURCE_IN pull" 7
  say "source du conteneur alignée sur main ($SOURCE_IN)"
else
  quiet d exec -i -u "$ADMIRAL" "$CONTAINER" git clone -q --depth 1 "$SOURCE_REMOTE_IN" "$SOURCE_IN" < /dev/null \
    || die "$ORG/lcars : aucun clone dans le conteneur et « git clone » y échoue ($SOURCE_IN)" 7
  say "source du conteneur clonée depuis main ($SOURCE_IN)"
fi

# ─── L'état du conteneur, le runner, la fleet ───────────────────────────────────────────────────
ROLE_TOKENS="$(bench_jetons_de_role)"
verdict_conteneur() { # verdict_conteneur <fichier du conteneur> → le code publié, ou rien
  local v; v="$(in_container cat "$1" 2>/dev/null | tr -d '[:space:]' || true)"
  [[ ! "$v" =~ ^[0-9]+$ ]] || printf '%s\n' "$v"
}
# une image qui n'écrit que lcars-provision.rc y rend 0 sur un geste en drift : seul un échec s'y distingue
VERDICT_FICHIER=/run/lcars-forge.rc
CONTAINER_PROV_RC="$(verdict_conteneur "$VERDICT_FICHIER")"
if [[ -z "$CONTAINER_PROV_RC" ]]; then
  VERDICT_FICHIER=/run/lcars-provision.rc
  CONTAINER_PROV_RC="$(verdict_conteneur "$VERDICT_FICHIER")"
fi
CONTAINER_PROV_OK=1
gestes_dits() { # gestes_dits → « : » puis un geste en défaut par ligne, lus au journal du dernier démarrage ; sans eux, où les lire
  local defauts; defauts="$(gestes_en_defaut "$DOCKER_BIN" "$CONTAINER")"
  if [[ -n "$defauts" ]]; then
    printf ' :\n%s\n              (le détail et son remède : docker logs %s)' "$(sed 's/^/              /' <<<"$defauts")" "$CONTAINER"
  else
    printf ' (docker logs %s le nomme)' "$CONTAINER"
  fi
}
case "$VERDICT_FICHIER:$CONTAINER_PROV_RC" in
  */lcars-provision.rc:0) CONTAINER_PROV_STATE="aucun geste en échec — cette image publie son verdict sans distinguer un drift (docker logs $CONTAINER nomme les gestes en drift)" ;;
  *:0)  CONTAINER_PROV_STATE="convergé" ;;
  *:2)  CONTAINER_PROV_STATE="appliqué avec drift résiduel — un geste manque, rien n'est cassé$(gestes_dits)" ;;
  *:3)  CONTAINER_PROV_STATE="un geste est MORT avant de rendre son verdict — rien n'a été conclu$(gestes_dits)"
        CONTAINER_PROV_OK=0 ;;
  *:)   CONTAINER_PROV_STATE="non mesuré — ni /run/lcars-forge.rc ni /run/lcars-provision.rc ne se lisent dans le conteneur (il n'a peut-être pas fini de converger)" ;;
  *)    CONTAINER_PROV_STATE="en échec (rc=$CONTAINER_PROV_RC) — le conteneur tourne et ne produira rien$(gestes_dits)"
        CONTAINER_PROV_OK=0 ;;
esac

# la fleet démarre sous l'humain ; sans credentials claude elle tourne sans penser, et c'est dit
FLEET_STATE="non démarrée"
FLEET_OK=0
if [[ "$CONTAINER_PROV_OK" -eq 1 ]]; then
  if [[ "$WITH_CREDS" -eq 1 ]]; then fleet_env=(); else fleet_env=(LCARS_START_WITHOUT_CLAUDE=1); fi
  if d exec -u "$HUMAN" "$CONTAINER" env ${fleet_env[@]+"${fleet_env[@]}"} fleet start >/dev/null 2>&1; then
    FLEET_OK=1
    FLEET_STATE="démarrée sous $HUMAN$([[ "$WITH_CREDS" -eq 1 ]] || printf ' (sans credentials claude : aucun pod ne pense)')"
  else
    FLEET_STATE="« fleet start » a échoué sous $HUMAN — docker exec -u $HUMAN $CONTAINER fleet start pour lire sa plainte"
  fi
fi

REFUS=""
if [[ "$CONTAINER_PROV_OK" -ne 1 ]]; then
  VERDICT="banc PAS PRÊT — le conteneur s'est déclaré en échec de convergence"
  REFUS="le conteneur a publié un échec de convergence — banc incomplet ; il tourne et reste joignable pour être réparé, et ne produira rien tant que la convergence n'est pas verte"
elif [[ "$FLEET_OK" -ne 1 ]]; then
  VERDICT="banc PAS PRÊT — la fleet ne démarre pas sous $HUMAN"
  REFUS="« fleet start » a échoué sous $HUMAN — banc incomplet ; le conteneur tourne et reste joignable pour lire la plainte"
elif [[ "$WITH_RUNNER" -eq 0 ]]; then
  VERDICT="banc PRÊT sans CI"
elif [[ "$RUNNER_SERT" -eq 1 ]]; then
  VERDICT="banc PRÊT"
else
  VERDICT="banc PAS PRÊT — le runner était demandé et ne sert pas"
  REFUS="runner demandé et non servi — banc incomplet ; « --no-runner » pour un banc sans CI, assumé et dit comme tel"
fi
say "───────────────────────────────────────────────────────"
say "$VERDICT"
say "  forge     : $FORGE_URL   ($ADMIRAL / $ADMIRAL_PW · $HUMAN / $HUMAN_PW)"
say "  deck      : http://${ADVERTISE}:${DECK_PORT}"
say "  conteneur : $CONTAINER   ssh $HUMAN@${ADVERTISE} -p ${SSH_PORT}"
if [[ "$BIND" == "0.0.0.0" || "$BIND" == "::" ]]; then
  say "  écoute    : $BIND — ouvert sur le réseau ; les mots de passe de ce banc sont des défauts de"
  say "              test, publics : à n'ouvrir que sur un réseau de confiance. « --bind 127.0.0.1 » le referme."
  if [[ -n "$ADVERTISE_GUESSED" ]]; then
    say "  adresse   : les liens pointent sur $ADVERTISE. ${ADVERTISE_GUESSED}"
    say "              « --advertise <ip-ou-nom> » pour annoncer autre chose."
  fi
  if [[ "$(detect_substrate)" == "wsl" && "$(wsl_networking_mode)" == "nat" ]]; then
    say "  portée    : WSL en mode NAT (le défaut) — ce banc n'est joignable que depuis cette machine."
  fi
else
  say "  écoute    : $BIND (cette machine seulement)"
fi
say "  image     : $IMAGE"
say "  révision  : $IMAGE_REV"
say "  runner    : $RUNNER_STATE"
say "  jetons    : $ROLE_TOKENS fichiers dans $(prov_canon "$PROV_TOKENS_DIR")"
say "  creds     : $([[ "$WITH_CREDS" -eq 1 ]] && echo oui || echo non)"
say "  fleet     : $FLEET_STATE"
say "  converge  : $CONTAINER_PROV_STATE"
say "  statut    : $(printf %q "$REPO_ROOT")/deploy/container -p $CONTAINER_PROJECT status"
say "  détruire  : $(printf %q "$REPO_ROOT")/deploy/docker/bench/bench-down.sh --project $PROJECT --yes"
say "───────────────────────────────────────────────────────"
[[ -z "$REFUS" ]] || die "$REFUS" 6
