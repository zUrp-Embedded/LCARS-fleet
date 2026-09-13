#!/usr/bin/env bash
# SOURCE: deploy/pack.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-12
# STATUS: le lanceur de la version — gate, release, doc, kit tar, installeur de la version, image docker, et leur publication depuis le poste
# USAGE : deploy/pack.sh            gate + release + doc + tar + installeur + image : dans le tiroir et le daemon, rien n'en sort
#         deploy/pack.sh --publish  … puis la release de la forge (tout le tiroir) et l'image au registre
#         deploy/pack.sh --no-image pas d'image (un poste sans docker produit quand même son kit)
# ENV   : LCARS_PACK_DIR      le tiroir des paquets (défaut : lcars-packs à côté du checkout)
#         LCARS_PACK_TAG      le tag de la version (défaut : le tag git de HEAD, sinon <AAAA-MM-JJ>-<sha>)
#         LCARS_PACK_IMAGE    le nom local de l'image (défaut lcars-fleet : tags <tag> et local)
#         LCARS_PACK_REGISTRY le registre du --publish (défaut : l'hôte de la forge, ou ghcr.io chez GitHub)
#         LCARS_PACK_FORGE, LCARS_PACK_OWNER, LCARS_PACK_REPO   la forge du --publish quand origin n'est pas http
#         LCARS_PACK_TOKEN, LCARS_PACK_TOKEN_FILE   le jeton du --publish (write:repository et write:package)
#         LCARS_SITE_SRC, LCARS_SITE_BASE   les sources de la doc et sa base d'URL, les mêmes que 44-media
#         LCARS_DOOR_BASE     la base d'URL inscrite dans l'installeur, pour un tiroir servi localement ; refusée avec --publish
#         LCARS_MINISIGN_PUBKEY   la clé publique inscrite dans l'installeur, si le tiroir porte la signature du kit
# PRÉ-REQUIS : erl, mix, npm — un poste en livraison source les a tous
# EXIT  : 0 la version est dans le tiroir · 1 gate rouge, build ou doc en échec, kit incomplet, publication refusée

set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."

PUBLISH=0
IMAGE=1
for _arg in "$@"; do
  case "$_arg" in
    --publish)  PUBLISH=1 ;;
    --no-image) IMAGE=0 ;;
    *) echo "pack: option inconnue: $_arg (--publish | --no-image)" >&2; exit 1 ;;
  esac
done
unset _arg

say() { echo "pack: $*" >&2; }
die() { echo "pack: ERREUR — $*" >&2; exit 1; }

[[ "$EUID" -ne 0 ]] || die "pack.sh ne se lance pas en root : l'installeur généré refuse root, et le build se fait sous l'humain"

# le gate et la release lisent l'arbre, git archive lit HEAD : un fichier modifié ou non suivi donnerait deux codes dans un paquet
_etat="$(git status --porcelain 2>/dev/null)" || die "pas un dépôt git — le kit est un git archive de HEAD"
[[ -z "$_etat" ]] || die "arbre modifié ou fichiers non suivis — le gate lirait l'arbre et le tar contiendrait HEAD : deux codes différents dans un même paquet. À commiter (ou remiser) d'abord."

SHA="$(git rev-parse --short HEAD)"
VERSION="$(date +%Y-%m-%d)"
TAG="${LCARS_PACK_TAG:-$(git describe --tags --exact-match 2>/dev/null || echo "${VERSION}-${SHA}")}"
[[ "$TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "tag « $TAG » : lettres, chiffres, . _ - seulement (il nomme le kit, l'image et la release)"

# la forge de la version, tirée d'origin : l'installeur y prendra son kit, la publication y posera la release
_ORIGIN="$(git remote get-url origin 2>/dev/null || true)"
_o="${_ORIGIN%/}"; _o="${_o%.git}"; _f="" _ow="" _re=""
if [[ "$_o" =~ ^(https?)://([^/]+)/([^/]+)/([^/]+)$ ]]; then
  _f="${BASH_REMATCH[1]}://${BASH_REMATCH[2]##*@}"; _ow="${BASH_REMATCH[3]}"; _re="${BASH_REMATCH[4]}"
fi
_FORGE="${LCARS_PACK_FORGE:-$_f}"; _FORGE="${_FORGE%/}"
_OWNER="${LCARS_PACK_OWNER:-$_ow}"
_REPO="${LCARS_PACK_REPO:-$_re}"
unset _o _f _ow _re
if [[ -n "${LCARS_DOOR_BASE:-}" ]]; then
  [[ "$PUBLISH" -eq 0 ]] || die "LCARS_DOOR_BASE est posée : l'installeur publié chercherait son kit ailleurs que sur la release — la retirer pour --publish"
  DOOR_BASE="$LCARS_DOOR_BASE"
else
  DOOR_BASE="${_FORGE:-https://forge.invalid}/${_OWNER:-lcars}/${_REPO:-lcars-fleet}/releases/download/$TAG"
fi
if [[ "$DOOR_BASE" != https://* ]]; then
  [[ "$PUBLISH" -eq 0 ]] || die "la forge de publication « ${_FORGE} » n'est pas en https : l'installeur publié refuserait de télécharger son kit — LCARS_PACK_FORGE=https://… la pose"
  say "base de l'installeur en clair ($DOOR_BASE) : il ne téléchargera que sous LCARS_DOOR_INSECURE_HTTP=1"
fi
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

# mix release --overwrite ne retire pas une lib/lcars_fleet-<ancienne> : on repart d'un répertoire vide et on vérifie le tampon
say "release prod…"
rm -rf runtime/_build/prod/rel/lcars_fleet
( cd runtime && MIX_ENV=prod mix release --overwrite >/dev/null ) || die "mix release en échec"
_libs=(runtime/_build/prod/rel/lcars_fleet/lib/lcars_fleet-*)
[[ "${#_libs[@]}" -eq 1 && -d "${_libs[0]}" ]] \
  || die "la release porte ${#_libs[@]} lib/lcars_fleet-* (${_libs[*]##*/}) — une assemblée n'en a qu'une ; rien n'est empaqueté"
_built="$(sed -n 's/^sha=//p' "${_libs[0]}/priv/api/build_info.txt" 2>/dev/null | head -1 || true)"
[[ "$_built" == "$SHA" ]] \
  || die "le tampon de la release dit « ${_built:-aucun} », HEAD est $SHA — les bits assemblés ne sont pas ceux du commit ; rien n'est empaqueté"
say "release attestée : ${_libs[0]##*/}, build $_built"

# une cible en livraison binaire ne pose pas node : la doc voyage bâtie, au chemin que 44-media lit
SITE_SRC="${LCARS_SITE_SRC:-assets/github.io}"
SITE_BASE="${LCARS_SITE_BASE:-/doc/}"
[[ -d "$SITE_SRC" ]] || die "sources du site absentes ($SITE_SRC) — le paquet serait une demi-livraison"
command -v npm >/dev/null 2>&1 \
  || die "npm absent — ce script bâtit aussi la doc depuis $SITE_SRC ; un poste en livraison source pose node"
say "doc du deck (npm ci + build, base $SITE_BASE)…"
( cd "$SITE_SRC" && npm ci --no-audit --no-fund >/dev/null 2>&1 ) \
  || die "npm ci en échec ($SITE_SRC) — la doc ne peut pas être bâtie"
( cd "$SITE_SRC" && LCARS_SITE_BASE="$SITE_BASE" npm run build >/dev/null 2>&1 ) \
  || die "build du site en échec ($SITE_SRC)"
[[ -s "$SITE_SRC/dist/index.html" ]] \
  || die "build terminé sans index.html ($SITE_SRC/dist) — rien à servir"
say "doc bâtie : $(find "$SITE_SRC/dist" -type f | wc -l) fichier(s)"

# le kit : l'arbre suivi (git archive HEAD), la release et la doc bâties, sous une racine fixe, avec sa révision
ROOT="lcars_install"
say "tar → $OUT  (racine : $ROOT/)"
mkdir -p "$PACK_DIR" || die "tiroir à paquets inaccessible : $PACK_DIR (LCARS_PACK_DIR le pose ailleurs)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT INT TERM
mkdir -p "$STAGE/$ROOT"
git archive --format=tar HEAD | tar -x -C "$STAGE/$ROOT" || die "git archive en échec"
_rev="$(git rev-parse --short=8 HEAD 2>/dev/null)" \
  || die "révision indéterminable — le paquet serait intraçable"
printf '%s\n' "$_rev" > "$STAGE/$ROOT/.source-revision"
say "révision estampillée : $_rev"
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
for _f in "$OUT" "${OUT}.sha256"; do
  [[ -f "$_f" ]] || continue
  ln -f "$_f" "$DIST/$(basename "$_f")"
done
for _f in deploy/docker/docker-compose.yml deploy/docker/lcars-hardened-seccomp.json; do
  [[ -f "$_f" ]] || die "artefact de la version introuvable : $_f"
  cp -f "$_f" "$DIST/$(basename "$_f")"
done
# shellcheck source=lib/forge-publish.sh
. deploy/lib/forge-publish.sh
# l'image de la version, telle que --publish la pousse : l'installeur la nomme pour la tirer ; sans image ni forge, il ne nomme rien
IMAGE_REMOTE=""
if [[ "$IMAGE" -eq 1 && -n "$_FORGE" && -n "$_OWNER" ]]; then
  _registry="${LCARS_PACK_REGISTRY:-}"
  if [[ -z "$_registry" ]]; then
    if [[ "$(fp_dialect "$_FORGE")" == github ]]; then _registry=ghcr.io; else _registry="${_FORGE#*://}"; _registry="${_registry%%/*}"; fi
  fi
  IMAGE_REMOTE="$_registry/$(tr '[:upper:]' '[:lower:]' <<<"$_OWNER/${_REPO:-lcars-fleet}"):$TAG"
fi
say "installeur de la version → $DIST/install.sh (base $DOOR_BASE${IMAGE_REMOTE:+, image $IMAGE_REMOTE})…"
LCARS_DOOR_IMAGE="$IMAGE_REMOTE" bash deploy/lib/door-gen.sh "$TAG" "$DOOR_BASE" "$DIST" >/dev/null || die "installeur de la version non généré"
say "tiroir de la version : $DIST ($(find "$DIST" -maxdepth 1 -type f | wc -l) fichiers, installeur compris)"

# l'image : le kit posé par les mêmes modules dans un conteneur (provision apply puis doctor, stages du Dockerfile)
IMAGE_NAME="${LCARS_PACK_IMAGE:-lcars-fleet}"
if [[ "$IMAGE" -eq 1 ]]; then
  # shellcheck source=lib/docker-endpoint.sh
  . deploy/lib/docker-endpoint.sh
  docker_endpoint || die "docker injoignable — $PROV_DOCKER_WHY ; « --no-image » pour le kit seul"
  say "image → $IMAGE_NAME:$TAG (le kit posé par les modules, puis leur doctor)…"
  "$PROV_DOCKER_BIN" build \
      -f "$STAGE/$ROOT/deploy/docker/Dockerfile" \
      --build-arg GIT_SHA="$_rev" --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --build-arg VERSION="$TAG" \
      -t "$IMAGE_NAME:$TAG" -t "$IMAGE_NAME:local" \
      "$STAGE/$ROOT" \
    || die "image non bâtie — les modules ont rougi dans le conteneur (le kit et l'installeur sont là, dans $DIST)"
  _img_rev="$("$PROV_DOCKER_BIN" image inspect "$IMAGE_NAME:$TAG" --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}')"
  [[ "$_img_rev" == "$_rev" ]] || die "l'image dit « $_img_rev », le kit $_rev — deux révisions dans une même version, rien ne sort"
  say "image : $IMAGE_NAME:$TAG (révision $_img_rev), aussi $IMAGE_NAME:local"
else
  say "--no-image : pas d'image — le kit et l'installeur seulement"
fi

[[ "$PUBLISH" -eq 1 ]] || { say "sans --publish : le tar et l'installeur restent dans $DIST, l'image dans le daemon"; exit 0; }

# la release se mesure avant l'image : un refus de la forge ne doit pas laisser une image publiée sans sa release
FORGE="$_FORGE"; OWNER="$_OWNER"; REPO="${_REPO:-lcars-fleet}"
[[ -n "$FORGE" && -n "$OWNER" ]] || die "--publish : forge ou owner indéterminables (origin n'est pas http) — LCARS_PACK_FORGE et LCARS_PACK_OWNER les posent"
TOKEN="${LCARS_PACK_TOKEN:-}"
[[ -n "$TOKEN" || -z "${LCARS_PACK_TOKEN_FILE:-}" ]] || TOKEN="$(cat "$LCARS_PACK_TOKEN_FILE" 2>/dev/null || true)"
_tok_state="absent"
[[ -n "$TOKEN" ]] && _tok_state="trouvé"
say "publication : forge ${FORGE:-<aucune>} · jeton : $_tok_state"
[[ -n "$TOKEN" ]] || die "--publish : aucun jeton — LCARS_PACK_TOKEN dans l'environnement, ou LCARS_PACK_TOKEN_FILE (portées write:repository + write:package)"
FP_TOKEN="$TOKEN" fp_precheck "$FORGE" "$OWNER" "$REPO" "$TAG" "$(git rev-parse HEAD)" \
  || die "publication refusée avant tout envoi — voir ci-dessus"
if [[ "$IMAGE" -eq 1 ]]; then
  [[ -n "$IMAGE_REMOTE" ]] || die "--publish : l'image n'a pas de nom de registre (forge ou owner indéterminés à la génération de l'installeur)"
  _registry="${IMAGE_REMOTE%%/*}"
  printf '%s' "$TOKEN" | "$PROV_DOCKER_BIN" login "$_registry" -u "$OWNER" --password-stdin >/dev/null 2>&1 \
    || die "--publish : le registre $_registry refuse le jeton de $OWNER (portée write:package ?)"
  trap 'rm -rf "$STAGE"; "$PROV_DOCKER_BIN" logout "$_registry" >/dev/null 2>&1 || true' EXIT
  _rc=0; _insp="$("$PROV_DOCKER_BIN" manifest inspect "$IMAGE_REMOTE" 2>&1 >/dev/null)" || _rc=$?
  if [[ "$_rc" -eq 0 ]]; then
    die "--publish : $IMAGE_REMOTE existe déjà — un tag publié ne se réécrit jamais ; pour refaire, le supprimer sur la forge, ce script ne le fait pas"
  fi
  [[ "${_insp,,}" == *"no such manifest"* || "${_insp,,}" == *"manifest unknown"* || "${_insp,,}" == *"not found"* ]] \
    || die "--publish : le registre ne dit pas si $IMAGE_REMOTE existe (${_insp:0:200}) — rien n'est poussé"
  say "image → $IMAGE_REMOTE…"
  "$PROV_DOCKER_BIN" tag "$IMAGE_NAME:$TAG" "$IMAGE_REMOTE" && "$PROV_DOCKER_BIN" push "$IMAGE_REMOTE" >/dev/null \
    || die "--publish : push de $IMAGE_REMOTE refusé — la release n'est pas créée, rien à réparer sur la forge"
  say "image publiée : $IMAGE_REMOTE"
fi
say "publication → $FORGE/$OWNER/$REPO, release $TAG…"
FP_TOKEN="$TOKEN" FP_IMAGE="$IMAGE_REMOTE" fp_publish_dist "$FORGE" "$OWNER" "$REPO" "$TAG" "$DIST" "$(git rev-parse HEAD)" \
  || die "publication interrompue — voir ci-dessus"
say "→ ${FORGE%/}/${OWNER}/${REPO}/releases/tag/${TAG}"
