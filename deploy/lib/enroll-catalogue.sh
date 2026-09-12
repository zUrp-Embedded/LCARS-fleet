#!/usr/bin/env bash
# SOURCE: deploy/lib/enroll-catalogue.sh
# AUTHOR: DrDree
# STARDATE: 2026-08-10
# STATUS: actif — derive les entrees de la recette forge depuis un catalogue
# USAGE
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATALOGUE=""
TOFU_DIR=""
IMAGE=""
REPO=""
RELEASE=""
SERVED=""
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
    --served)    SERVED="${2:?}";    shift 2 ;;
    -h|--help)   sed -n '2,/^[^#]/{/^[^#]/!p;}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)           die "argument inconnu: $1" ;;
  esac
done

[[ -n "$CATALOGUE" || -n "$IMAGE" || -n "$RELEASE" ]] || die "--catalogue <root> requis (ou --image / --release, qui portent le sien)"
[[ -n "$TOFU_DIR"  ]] || die "--tofu-dir <dir> requis"
[[ -d "$TOFU_DIR"  ]] || die "tofu-dir introuvable: $TOFU_DIR" 3

[[ -n "$CATALOGUE" && -d "$CATALOGUE" ]] && CATALOGUE="$(cd "$CATALOGUE" && pwd)"

[[ -n "$REPO" || -n "$IMAGE" || -n "$RELEASE" ]] || REPO="$(cd "$HERE/../../runtime" && pwd)"

if [[ -n "$IMAGE" ]]; then
  SRC="image $IMAGE"
  MOUNT=()
  [[ -n "$CATALOGUE" && -d "$CATALOGUE" ]] && MOUNT=(-v "$CATALOGUE:$CATALOGUE:ro")
  TFVARS="$("$DOCKER_BIN" run --rm ${MOUNT[@]+"${MOUNT[@]}"} "$IMAGE" roles-tfvars ${CATALOGUE:+"$CATALOGUE"} 2>/dev/null)" \
    || die "l'image ne rend pas le roster de ${CATALOGUE:-son catalogue livre}" 2
elif [[ -n "$RELEASE" ]]; then
  SRC="release $RELEASE"
  [[ -x "$RELEASE" ]] || die "release non executable : $RELEASE" 1
  _arg="Fleet.Catalogue.root()"
  [[ -n "$CATALOGUE" ]] && _arg="\"$CATALOGUE\""
  TFVARS="$(env HOME="${TMPDIR:-/tmp}" RELEASE_TMP="${TMPDIR:-/tmp}" LCARS_TOOL_EVAL=1 \
              "$RELEASE" eval "Fleet.Roster.eval_tfvars(${_arg})" 2>/dev/null)" \
    || die "la release ne rend pas le roster de ${CATALOGUE:-son catalogue livre}" 2
else
  SRC="depot $REPO"
  [[ -f "$REPO/mix.exs" ]] || die "pas de mix.exs dans $REPO (utiliser --image pour une install livree)" 1
  ( cd "$REPO" && mix compile ) >/dev/null 2>&1 || die "le depot $REPO ne compile pas" 2
  TFVARS="$(cd "$REPO" && mix lcars.catalogue.roles "$CATALOGUE" --tfvars 2>/dev/null)" \
    || die "mix ne rend pas le roster de $CATALOGUE" 2
fi

[[ -n "$TFVARS" ]] || die "roster vide pour $CATALOGUE" 2
printf '%s' "$TFVARS" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("roles")' 2>/dev/null \
  || die "roster illisible ou sans role pour $CATALOGUE" 2

DEST="$TOFU_DIR/roles.auto.tfvars.json"
TMP="$DEST.tmp.$$"
printf '%s\n' "$TFVARS" > "$TMP" || die "ecriture impossible dans $TOFU_DIR" 3
mv -f "$TMP" "$DEST" || die "ecriture impossible dans $TOFU_DIR" 3

ROLES_LINE="$(printf '%s' "$TFVARS" | python3 -c '
import json, sys
d = json.load(sys.stdin)
seen, out = set(), []
for r in d.get("system_roles", []) + d.get("roles", []):
    if r not in seen:
        seen.add(r); out.append(r)
print(" ".join(out))')"

if [[ -n "$SERVED" ]]; then
  ROLES_LINE="$(ROLES_LINE="$ROLES_LINE" SERVED="$SERVED" python3 -c '
import os
seen, out = set(), []
for r in (os.environ["SERVED"] + " " + os.environ["ROLES_LINE"]).split():
    if r not in seen:
        seen.add(r); out.append(r)
print(" ".join(out))')"
fi

ORG_LINE="$(printf '%s' "$TFVARS" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("org",""))')"

if [[ -z "$SERVED" ]]; then
  say "sans --served, PROV_ROLES ci-dessous couvre ce catalogue et les comptes système, pas les rôles des autres catalogues déjà servis : unir les listes avant le mint (un rôle sans jeton bloque au premier dispatch)"
fi
if [[ -d "$TOFU_DIR/instance" ]]; then
  say "le module instance/ est présent dans $TOFU_DIR : il crée les comptes system_* et se joue une fois par forge — sur une forge qui les porte déjà, le rejouer rend « user already exists » ; à retirer du dossier de travail dans ce cas"
fi
say "tofu crée les comptes avec un seul seed_password ; le conteneur tient une carte par rôle (/opt/lcars/var/tokens/forge-role-passwords.json) — le seed passé à tofu doit être celui que le conteneur attend, sinon le mint des jetons rend « invalid username, password or token » sur les comptes neufs"
say ""

say "catalogue : ${CATALOGUE:-<celui de la livraison>} (lu via $SRC)"
say "ecrit     : $DEST"
say "roles     : $ROLES_LINE"
say "org       : ${ORG_LINE:-<non declaree>}"
echo "PROV_ROLES=\"$ROLES_LINE\""
[[ -n "$ORG_LINE" ]] && echo "PROV_FORGE_ORG=\"$ORG_LINE\""
