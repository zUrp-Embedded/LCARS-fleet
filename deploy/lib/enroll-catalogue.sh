#!/usr/bin/env bash
# SOURCE: deploy/lib/enroll-catalogue.sh
# AUTHOR: DrDree
# STARDATE: 2026-08-10
# STATUS: dérive le roster (roles.auto.tfvars.json) de la recette forge depuis un catalogue
#
# USAGE  enroll-catalogue.sh --tofu-dir <dir> [--catalogue <racine>] [--image <img> | --release <bin> | --repo <runtime>]
#   --tofu-dir    la recette qui reçoit roles.auto.tfvars.json
#   --catalogue   la racine du catalogue lu ; sans elle, l'image ou la release lit le sien
#   --image       le roster est demandé à l'image (docker run … roles-tfvars) : rien à compiler sur l'hôte
#   --release     le roster est demandé à la release posée (eval Fleet.Roster)
#   --repo        le roster est compilé depuis les sources (mix) ; défaut quand ni image ni release
#   ENV   DOCKER_BIN  la CLI docker de --image (défaut : docker)
#   SORTIE  le catalogue lu, le fichier écrit, les rôles et l'org, une ligne chacun
#   EXIT  0 · 1 arguments, jq absent ou source illisible · 2 roster non rendu ou vide · 3 tofu-dir absent ou non inscriptible
#
# Il n'écrit aucune recette : un catalogue est la pièce qu'un opérateur remplace, et générer la
# recette depuis lui donnerait à un fichier remplaçable l'autorité d'élargir ses propres droits.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATALOGUE=""
TOFU_DIR=""
IMAGE=""
REPO=""
RELEASE=""
DOCKER_BIN="${DOCKER_BIN:-docker}"

say() { echo "[enroll-catalogue] $*"; }
die() { echo "[enroll-catalogue] ERREUR: $1" >&2; exit "${2:-1}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --catalogue) CATALOGUE="${2:?}"; shift 2 ;;
    --tofu-dir)  TOFU_DIR="${2:?}";  shift 2 ;;
    --image)     IMAGE="${2:?}";     shift 2 ;;
    --repo)      REPO="${2:?}";      shift 2 ;;
    --release)   RELEASE="${2:?}";   shift 2 ;;
    -h|--help)   sed -n '2,/^[^#]/{/^[^#]/!s/^# \{0,1\}//p;}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)           die "argument inconnu: $1" ;;
  esac
done

[[ -n "$CATALOGUE" || -n "$IMAGE" || -n "$RELEASE" ]] || die "--catalogue <root> requis (ou --image / --release, qui portent le sien)"
[[ -n "$TOFU_DIR"  ]] || die "--tofu-dir <dir> requis"
[[ -d "$TOFU_DIR"  ]] || die "tofu-dir introuvable: $TOFU_DIR" 3
command -v jq >/dev/null 2>&1 || die "jq requis sur cette machine : le roster se valide et se lit par lui (apt install jq)"

[[ -n "$CATALOGUE" && -d "$CATALOGUE" ]] && CATALOGUE="$(cd "$CATALOGUE" && pwd)"
LU="${CATALOGUE:-son catalogue livré}"

[[ -n "$REPO" || -n "$IMAGE" || -n "$RELEASE" ]] || REPO="$(cd "$HERE/../../runtime" && pwd)"

if [[ -n "$IMAGE" ]]; then
  SRC="image $IMAGE"
  MOUNT=()
  [[ -n "$CATALOGUE" && -d "$CATALOGUE" ]] && MOUNT=(-v "$CATALOGUE:$CATALOGUE:ro")
  TFVARS="$("$DOCKER_BIN" run --rm ${MOUNT[@]+"${MOUNT[@]}"} "$IMAGE" roles-tfvars ${CATALOGUE:+"$CATALOGUE"} 2>/dev/null)" \
    || die "l'image ne rend pas le roster de $LU" 2
elif [[ -n "$RELEASE" ]]; then
  SRC="release $RELEASE"
  [[ -x "$RELEASE" ]] || die "release non exécutable : $RELEASE" 1
  _arg="Fleet.Catalogue.root()"
  [[ -n "$CATALOGUE" ]] && _arg="\"$CATALOGUE\""
  TFVARS="$(env HOME="${TMPDIR:-/tmp}" RELEASE_TMP="${TMPDIR:-/tmp}" LCARS_TOOL_EVAL=1 \
              "$RELEASE" eval "Fleet.Roster.eval_tfvars(${_arg})" 2>/dev/null)" \
    || die "la release ne rend pas le roster de $LU" 2
else
  SRC="depot $REPO"
  [[ -f "$REPO/mix.exs" ]] || die "pas de mix.exs dans $REPO (--image pour une installation livrée)" 1
  ( cd "$REPO" && mix compile ) >/dev/null 2>&1 || die "le dépôt $REPO ne compile pas" 2
  TFVARS="$(cd "$REPO" && mix lcars.catalogue.roles "$CATALOGUE" --tfvars 2>/dev/null)" \
    || die "mix ne rend pas le roster de $LU" 2
fi

[[ -n "$TFVARS" ]] || die "roster vide pour $LU" 2
# une lecture : la validation, les rôles système devant les rôles métier sans doublon, puis l'org
LECTURE="$(jq -r 'if ((.roles // []) | length) == 0 then error("roster sans rôle") else
                    ((.system_roles // []) + .roles | reduce .[] as $r ([]; if index([$r]) then . else . + [$r] end) | join(" ")),
                    (.org // "")
                  end' <<<"$TFVARS" 2>/dev/null)" \
  || die "roster illisible ou sans rôle pour $LU" 2
{ read -r ROLES_LINE; read -r ORG_LINE || true; } <<<"$LECTURE"

DEST="$TOFU_DIR/roles.auto.tfvars.json"
TMP="$DEST.tmp.$$"
printf '%s\n' "$TFVARS" > "$TMP" || die "écriture impossible dans $TOFU_DIR" 3
mv -f "$TMP" "$DEST" || die "écriture impossible dans $TOFU_DIR" 3

say "catalogue : $LU (lu via $SRC)"
say "écrit     : $DEST"
say "rôles     : $ROLES_LINE"
say "org       : ${ORG_LINE:-<non déclarée>}"
