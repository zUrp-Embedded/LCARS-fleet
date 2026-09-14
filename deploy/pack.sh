#!/usr/bin/env bash
# SOURCE: deploy/pack.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-12
# STATUS: le lanceur de la version — gate, release, doc, kit tar, installeur de la version, image docker, et leur publication depuis le poste
# USAGE : deploy/pack.sh            gate + release + doc + tar + installeur + image : dans le tiroir et le daemon, rien n'en sort
#         deploy/pack.sh --publish  … puis l'image au registre et la release de la forge (tout le tiroir)
#         deploy/pack.sh --no-image pas d'image (un poste sans docker produit quand même son kit)
#         deploy/pack.sh --help     cette aide
#         Se lance hors root, sur un arbre commité.
# ENV   : LCARS_PACK_DIR      le tiroir des paquets (défaut : lcars-packs à côté du checkout)
#         LCARS_PACK_TAG      le tag de la version (défaut : le tag git de HEAD, sinon <AAAA-MM-JJ>-<sha>)
#         LCARS_PACK_IMAGE    le nom local de l'image (défaut lcars-fleet : tags <tag> et local)
#         LCARS_PACK_REGISTRY le registre du --publish (défaut : ghcr.io chez GitHub, l'hôte de la forge sinon)
#         LCARS_PACK_FORGE, LCARS_PACK_OWNER, LCARS_PACK_REPO   la forge, le propriétaire et le dépôt de la
#                             version (défaut : ceux d'un origin en http ou https)
#         LCARS_PACK_TOKEN_FILE  le fichier du jeton du --publish (write:repository et write:package), lu par
#                             curl et par docker login sur leur entrée ; un jeton ne s'accepte pas par l'environnement,
#                             dont héritent le gate, npm et leurs scripts
#         LCARS_SITE_BASE     la base d'URL de la doc, la même que 44-media
#         LCARS_DOOR_BASE     la base d'URL inscrite dans l'installeur, pour un tiroir servi localement ; refusée avec --publish
#         LCARS_MINISIGN_PUBKEY, LCARS_MINISIGN_SECKEY   la clé publique inscrite dans l'installeur et le fichier de la clé
#                             secrète qui signe le kit : l'une ne va pas sans l'autre
#         Le gabarit de l'installeur est toujours install.sh de cet arbre.
# PRÉ-REQUIS : git, erl, mix, npm — un poste en livraison source les a tous ; claude dans ~/.local/bin, que
#         la suite ExUnit du runtime exige de qui la joue ; bats et shellcheck, que la porte
#         de l'installeur exige ; docker compose, sans lequel cette porte saute les témoins des composes et les
#         compte ; docker et son plugin buildx, sauf --no-image ; jq avec --publish ; minisign avec les clés
# EXIT  : 0 la version est dans le tiroir, et publiée avec --publish · 1 refus (root, arbre modifié, option
#         inconnue, jeton par l'environnement), gate rouge, build ou doc en échec, kit incomplet, docker injoignable
#         ou sans buildx, publication refusée (dont une image du tag déjà publiée à une autre révision)

set -euo pipefail
SELF="$(readlink -f "$0")"
cd "$(dirname "$SELF")/.."
# shellcheck source=lib/provision-lib.sh
. deploy/lib/provision-lib.sh

PUBLISH=0
IMAGE=1
for _arg in "$@"; do
  case "$_arg" in
    --publish)  PUBLISH=1 ;;
    --no-image) IMAGE=0 ;;
    -h|--help)  sed -n '/^# USAGE/,/^$/p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "pack: option inconnue: $_arg (--publish | --no-image | --help)" >&2; exit 1 ;;
  esac
done

say() { echo "pack: $*" >&2; }
die() { echo "pack: ERREUR — $*" >&2; exit 1; }

[[ "$EUID" -ne 0 ]] || die "pack.sh ne se lance pas en root : l'installeur généré refuse root, et le build se fait sous l'humain"
[[ -z "${LCARS_PACK_TOKEN+x}" ]] \
  || die "LCARS_PACK_TOKEN n'est pas lu : le gate, npm et leurs scripts en hériteraient — le jeton se donne par fichier, LCARS_PACK_TOKEN_FILE=<fichier>"

# le gate et la release lisent l'arbre, git archive lit HEAD : un fichier modifié ou non suivi donnerait deux codes dans un paquet
_etat="$(git status --porcelain 2>/dev/null)" || die "pas un dépôt git — le kit est un git archive de HEAD"
[[ -z "$_etat" ]] || die "arbre modifié ou fichiers non suivis — le gate lirait l'arbre et le tar contiendrait HEAD : deux codes différents dans un même paquet. À commiter (ou remiser) d'abord."

COMMIT="$(git rev-parse HEAD)"
REV="$(git rev-parse --short=8 HEAD)"
VERSION="$(date +%Y-%m-%d)"
TAG="${LCARS_PACK_TAG:-$(git describe --tags --exact-match 2>/dev/null || echo "${VERSION}-${REV}")}"
[[ "$TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "tag « $TAG » : lettres, chiffres, . _ - seulement (il nomme le kit, l'image et la release)"

# la forge de la version, tirée d'origin : l'installeur y prendra son kit, la publication y posera la release
_o="$(git remote get-url origin 2>/dev/null || true)"; _o="${_o%/}"; _o="${_o%.git}"; _f="" _ow="" _re=""
if [[ "$_o" =~ ^(https?)://([^/]+)/([^/]+)/([^/]+)$ ]]; then
  _f="${BASH_REMATCH[1]}://${BASH_REMATCH[2]##*@}"; _ow="${BASH_REMATCH[3]}"; _re="${BASH_REMATCH[4]}"
fi
FORGE="${LCARS_PACK_FORGE:-$_f}"; FORGE="${FORGE%/}"
OWNER="${LCARS_PACK_OWNER:-$_ow}"
REPO="${LCARS_PACK_REPO:-${_re:-lcars-fleet}}"
if [[ -n "${LCARS_DOOR_BASE:-}" ]]; then
  [[ "$PUBLISH" -eq 0 ]] || die "LCARS_DOOR_BASE est posée : l'installeur publié chercherait son kit ailleurs que sur la release — la retirer pour --publish"
  DOOR_BASE="$LCARS_DOOR_BASE"
else
  DOOR_BASE="${FORGE:-https://forge.invalid}/${OWNER:-lcars}/$REPO/releases/download/$TAG"
fi
if [[ "$DOOR_BASE" != https://* ]]; then
  [[ "$PUBLISH" -eq 0 ]] || die "la forge de publication « $FORGE » n'est pas en https : l'installeur publié refuserait de télécharger son kit — LCARS_PACK_FORGE=https://… la pose"
  say "base de l'installeur en clair ($DOOR_BASE) : il ne téléchargera que sous LCARS_DOOR_INSECURE_HTTP=1"
fi
# une clé publique inscrite fait exiger à l'installeur la signature que seule la clé secrète produit
MINISIGN_PUBKEY="${LCARS_MINISIGN_PUBKEY:-}"
MINISIGN_SECKEY="${LCARS_MINISIGN_SECKEY:-}"
if [[ -n "$MINISIGN_PUBKEY$MINISIGN_SECKEY" ]]; then
  [[ -n "$MINISIGN_PUBKEY" && -n "$MINISIGN_SECKEY" ]] \
    || die "LCARS_MINISIGN_PUBKEY et LCARS_MINISIGN_SECKEY vont ensemble : l'installeur vérifie avec la clé publique la signature que la clé secrète produit"
  [[ -r "$MINISIGN_SECKEY" ]] || die "clé secrète minisign illisible : $MINISIGN_SECKEY"
  command -v minisign >/dev/null 2>&1 || die "minisign absent — il signe le kit que la clé publique fait vérifier"
fi
# l'image se bâtit sans attestation (--provenance, --sbom), que seul le constructeur buildx accepte
if [[ "$IMAGE" -eq 1 ]]; then
  docker_endpoint || die "docker injoignable — $PROV_DOCKER_WHY ; « --no-image » pour le kit seul"
  "$PROV_DOCKER_BIN" buildx version >/dev/null 2>&1 \
    || die "docker buildx absent — l'image se bâtit par lui (Docker Desktop l'inclut ; sur linux : apt install docker-buildx-plugin) ; « --no-image » pour le kit seul"
fi
# le gate, la release et la doc les appellent : un absent se dit avant plusieurs minutes de gate
for _outil in erl mix npm; do
  command -v "$_outil" >/dev/null 2>&1 || die "$_outil absent — le gate, la release et la doc en ont besoin (pré-requis : deploy/pack.sh --help)"
done
ARCH="$(uname -m)"
OTP="$(erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().' 2>/dev/null || echo 0)"
# le nom du kit porte le tag : c'est par lui que l'installeur le retrouve dans sa table (lcars-fleet-<tag>-*-<arch>)
NAME="lcars-fleet-${TAG}-otp${OTP}-${ARCH}"
PACK_DIR="${LCARS_PACK_DIR:-$(dirname "$PWD")/lcars-packs}"
PACK_DIR="$(realpath -m "$PACK_DIR")"
OUT="$PACK_DIR/${NAME}.tar.gz"

say "gate du runtime (compile strict + suite + bats + contrats + topologie + dialyzer)…"
( cd runtime && MIX_ENV=prod mix deps.get >/dev/null && MIX_ENV="test" mix gate ) || die "gate rouge — rien n'est empaqueté"
say "gate de l'installeur…"
bash deploy/gate.sh || die "gate de l'installeur rouge — rien n'est empaqueté"

# une release assemblée par-dessus une ancienne garde sa lib/lcars_fleet-<ancienne> : elle repart d'un répertoire vide
say "release prod…"
rm -rf runtime/_build/prod/rel/lcars_fleet
( cd runtime && MIX_ENV=prod mix release >/dev/null ) || die "mix release en échec"
# le tampon de la release porte l'abréviation courte de git, le kit la sienne : l'une préfixe l'autre
_built="$(sed -n 's/^sha=//p' runtime/_build/prod/rel/lcars_fleet/lib/lcars_fleet-*/priv/api/build_info.txt 2>/dev/null | head -1 || true)"
[[ -n "$_built" && ( "$REV" == "$_built"* || "$_built" == "$REV"* ) ]] \
  || die "le tampon de la release dit « ${_built:-aucun} », HEAD est $REV — les bits assemblés ne sont pas ceux du commit ; rien n'est empaqueté"
say "release attestée : build $_built"

# une cible en livraison binaire ne pose pas node : la doc voyage bâtie, au chemin que 44-media et kit-verify lisent
SITE_SRC=assets/github.io
SITE_BASE="${LCARS_SITE_BASE:-/doc/}"
[[ -d "$SITE_SRC" ]] || die "sources du site absentes ($SITE_SRC) — le paquet serait une demi-livraison"
say "doc du deck (npm ci + build, base $SITE_BASE)…"
( cd "$SITE_SRC" && npm ci --no-audit --no-fund >/dev/null 2>&1 ) \
  || die "npm ci en échec ($SITE_SRC) — la doc ne peut pas être bâtie"
( cd "$SITE_SRC" && LCARS_SITE_BASE="$SITE_BASE" npm run build >/dev/null 2>&1 ) \
  || die "build du site en échec ($SITE_SRC)"
say "doc bâtie : $(find "$SITE_SRC/dist" -type f | wc -l) fichier(s)"

# shellcheck source=lib/forge-publish.sh
. deploy/lib/forge-publish.sh
# l'image de la version, telle que --publish la pousse : l'installeur la nomme pour la tirer ; sans image ni forge, il ne nomme rien
IMAGE_REMOTE=""
if [[ "$IMAGE" -eq 1 && -n "$FORGE" && -n "$OWNER" ]]; then
  _registry="${LCARS_PACK_REGISTRY:-}"
  if [[ -z "$_registry" ]]; then
    if [[ "$(fp_dialect "$FORGE")" == github ]]; then _registry=ghcr.io; else _registry="${FORGE#*://}"; _registry="${_registry%%/*}"; fi
  fi
  IMAGE_REMOTE="$_registry/$(tr '[:upper:]' '[:lower:]' <<<"$OWNER/$REPO"):$TAG"
fi
IMAGE_NAME="${LCARS_PACK_IMAGE:-lcars-fleet}"

# le kit : l'arbre suivi (git archive HEAD), la release et la doc bâties, sous une racine fixe, avec sa révision
ROOT="lcars_install"
say "tar → $OUT  (racine : $ROOT/)"
mkdir -p "$PACK_DIR" || die "tiroir à paquets inaccessible : $PACK_DIR (LCARS_PACK_DIR le pose ailleurs)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT INT TERM
mkdir -p "$STAGE/$ROOT"
git archive --format=tar HEAD | tar -x -C "$STAGE/$ROOT" || die "git archive en échec"
printf '%s\n' "$REV" > "$STAGE/$ROOT/$PROV_SOURCE_STAMP"
say "révision estampillée : $REV"
# le compose d'un checkout nomme l'image locale ; celui du kit nomme l'image de sa version, publiée ou bâtie ici
if [[ "$IMAGE" -eq 1 ]]; then
  _compose="$STAGE/$ROOT/deploy/docker/docker-compose.yml"
  _image_version="${IMAGE_REMOTE:-$IMAGE_NAME:$TAG}"
  grep -qF '${LCARS_IMAGE:-lcars-fleet:local}' "$_compose" \
    || die "deploy/docker/docker-compose.yml ne nomme plus l'image par « \${LCARS_IMAGE:-lcars-fleet:local} » : le kit ne saurait pas y inscrire $_image_version"
  sed -i "s|\${LCARS_IMAGE:-lcars-fleet:local}|\${LCARS_IMAGE:-$_image_version}|" "$_compose"
  say "compose du kit : image $_image_version"
fi
mkdir -p "$STAGE/$ROOT/runtime/_build/prod/rel"
cp -a runtime/_build/prod/rel/lcars_fleet "$STAGE/$ROOT/runtime/_build/prod/rel/" || die "release introuvable après le build"
mkdir -p "$STAGE/$ROOT/$SITE_SRC"
cp -a "$SITE_SRC/dist" "$STAGE/$ROOT/$SITE_SRC/" || die "doc introuvable après le build ($SITE_SRC/dist)"
# shellcheck source=lib/kit-verify.sh
. deploy/lib/kit-verify.sh
kit_verifie "$STAGE/$ROOT" "runtime/_build/prod/rel/lcars_fleet/bin/lcars_fleet" \
  || die "kit incomplet — rien n'a été scellé (les manques sont nommés ci-dessus)"
say "kit vérifié : ce que les listes déclarent est dans l'arbre"
tar -czf "$OUT" -C "$STAGE" "$ROOT" || die "tar en échec"
( cd "$PACK_DIR" && sha256sum "${NAME}.tar.gz" > "${NAME}.tar.gz.sha256" )
say "paquet : $OUT ($(du -h "$OUT" | cut -f1))"
say "sha256 : $(cut -d' ' -f1 < "${OUT}.sha256")"

# le tiroir de la version : les artefacts (liens durs) et l'installeur qui porte leurs sha256 et leur base d'URL
DIST="$PACK_DIR/dist/$TAG"
rm -rf "$DIST"
mkdir -p "$DIST"
ln -f "$OUT" "$OUT.sha256" "$DIST/"
# le compose lit les constantes de l'installeur : elles voyagent à côté de lui ; c'est la copie du kit, qui nomme l'image de la version
cp -f "$STAGE/$ROOT/deploy/docker/docker-compose.yml" deploy/docker/lcars-hardened-seccomp.json deploy/installer-constants.env "$DIST/"
if [[ -n "$MINISIGN_SECKEY" ]]; then
  minisign -S -s "$MINISIGN_SECKEY" -m "$DIST/${NAME}.tar.gz" || die "signature du kit refusée par minisign"
  say "kit signé : $DIST/${NAME}.tar.gz.minisig"
fi
say "installeur de la version → $DIST/install.sh (base $DOOR_BASE${IMAGE_REMOTE:+, image $IMAGE_REMOTE})…"
LCARS_DOOR_TEMPLATE="$PWD/install.sh" LCARS_MINISIGN_PUBKEY="$MINISIGN_PUBKEY" LCARS_DOOR_IMAGE="$IMAGE_REMOTE" \
  bash deploy/lib/door-gen.sh "$TAG" "$DOOR_BASE" "$DIST" >/dev/null \
  || die "installeur de la version non généré"
say "tiroir de la version : $DIST ($(find "$DIST" -maxdepth 1 -type f | wc -l) fichiers, installeur compris)"

# l'image : le kit posé par les mêmes modules dans un conteneur (provision apply puis doctor, stages du Dockerfile) ;
# sans attestation, le stockage containerd garde une image Docker v2 simple, et non un index OCI que des clients
# de registre (Portainer) ne savent pas demander
if [[ "$IMAGE" -eq 1 ]]; then
  say "image → $IMAGE_NAME:$TAG (le kit posé par les modules, puis leur doctor)…"
  "$PROV_DOCKER_BIN" build \
      -f "$STAGE/$ROOT/deploy/docker/Dockerfile" \
      --build-arg GIT_SHA="$REV" --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --build-arg VERSION="$TAG" \
      --provenance=false --sbom=false \
      -t "$IMAGE_NAME:$TAG" -t "$IMAGE_NAME:local" \
      "$STAGE/$ROOT" \
    || die "image non bâtie — les modules ont rougi dans le conteneur (le kit et l'installeur sont là, dans $DIST)"
  say "image : $IMAGE_NAME:$TAG (révision $REV), aussi $IMAGE_NAME:local"
else
  say "--no-image : pas d'image — le kit et l'installeur seulement"
fi

[[ "$PUBLISH" -eq 1 ]] || { say "sans --publish : le tar et l'installeur restent dans $DIST, l'image dans le daemon"; exit 0; }

# la release se mesure avant l'image : un refus de la forge ne doit pas laisser une image publiée sans sa release
[[ -n "$FORGE" && -n "$OWNER" ]] || die "--publish : forge ou owner indéterminables (origin n'est pas http) — LCARS_PACK_FORGE et LCARS_PACK_OWNER les posent"
FP_TOKEN_FILE="${LCARS_PACK_TOKEN_FILE:-}"
[[ -n "$(read_token "$FP_TOKEN_FILE")" ]] \
  || die "--publish : aucun jeton — LCARS_PACK_TOKEN_FILE=<fichier> (portées write:repository + write:package), lisible et non vide"
say "publication : forge $FORGE · jeton trouvé"
fp_precheck "$FORGE" "$OWNER" "$REPO" "$TAG" "$COMMIT" \
  || die "publication refusée avant tout envoi — voir ci-dessus"
if [[ "$IMAGE" -eq 1 ]]; then
  _registry="${IMAGE_REMOTE%%/*}"
  read_token "$FP_TOKEN_FILE" | "$PROV_DOCKER_BIN" login "$_registry" -u "$OWNER" --password-stdin >/dev/null 2>&1 \
    || die "--publish : le registre $_registry refuse le jeton de $OWNER (portée write:package ?)"
  trap 'rm -rf "$STAGE"; "$PROV_DOCKER_BIN" logout "$_registry" >/dev/null 2>&1 || true' EXIT
  _rc=0; _insp="$("$PROV_DOCKER_BIN" manifest inspect "$IMAGE_REMOTE" 2>&1 >/dev/null)" || _rc=$?
  if [[ "$_rc" -eq 0 ]]; then
    # un tag publié ne se réécrit pas ; à la révision du kit, c'est l'image d'une publication arrêtée après son push, qui se reprend
    "$PROV_DOCKER_BIN" pull -q "$IMAGE_REMOTE" >/dev/null 2>&1 \
      || die "--publish : $IMAGE_REMOTE existe déjà et ne se tire pas pour lire sa révision — rien n'est poussé"
    _rev_publiee="$("$PROV_DOCKER_BIN" image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$IMAGE_REMOTE" 2>/dev/null || true)"
    [[ "$_rev_publiee" == "$REV" ]] \
      || die "--publish : $IMAGE_REMOTE existe déjà, à la révision « ${_rev_publiee:-aucune} » et non $REV — un tag publié ne se réécrit jamais ; pour refaire, le supprimer sur la forge, ce script ne le fait pas"
    say "image déjà publiée à la révision $REV : $IMAGE_REMOTE est reprise, rien n'est poussé"
  else
    [[ "${_insp,,}" == *"no such manifest"* || "${_insp,,}" == *"manifest unknown"* || "${_insp,,}" == *"not found"* ]] \
      || die "--publish : le registre ne dit pas si $IMAGE_REMOTE existe (${_insp:0:200}) — rien n'est poussé"
    say "image → $IMAGE_REMOTE…"
    "$PROV_DOCKER_BIN" tag "$IMAGE_NAME:$TAG" "$IMAGE_REMOTE" && "$PROV_DOCKER_BIN" push "$IMAGE_REMOTE" >/dev/null \
      || die "--publish : push de $IMAGE_REMOTE refusé — la release n'est pas créée, rien à réparer sur la forge"
    say "image publiée : $IMAGE_REMOTE"
  fi
  # l'installeur de la release tire l'image sans identifiants : un magasin de configuration vide rejoue ce tirage
  mkdir -p "$STAGE/docker-anonyme"
  _anon="$(DOCKER_CONFIG="$STAGE/docker-anonyme" "$PROV_DOCKER_BIN" manifest inspect "$IMAGE_REMOTE" 2>&1 >/dev/null)" \
    || die "--publish : $IMAGE_REMOTE est au registre, mais un tirage anonyme est refusé (${_anon:0:200}) — l'installeur de la release ne la tirerait pas, la release n'est pas créée. Le paquet de l'image est privé : sur GHCR, un paquet est privé à sa première publication, il se passe public dans ses réglages (Package settings → Change visibility) ; relancer ensuite --publish, qui reprend l'image de cette révision"
  say "image tirable sans identifiants : $IMAGE_REMOTE"
fi
say "publication → $FORGE/$OWNER/$REPO, release $TAG…"
FP_IMAGE="$IMAGE_REMOTE" fp_publish_dist "$FORGE" "$OWNER" "$REPO" "$TAG" "$DIST" "$COMMIT" \
  || die "publication interrompue — voir ci-dessus"
say "→ ${FORGE%/}/${OWNER}/${REPO}/releases/tag/${TAG}"
