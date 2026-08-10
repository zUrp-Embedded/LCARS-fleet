#!/usr/bin/env bash
# SOURCE: fleet/etc/enroll-catalogue.sh
# AUTHOR: DrDree
# STARDATE: 2026-08-10
# STATUS: actif — derive les entrees de la recette forge depuis un catalogue
#
# ENROLLER UN CATALOGUE : lit les roles qu'un catalogue declare, et ecrit ce que la recette forge
# attend en entree. C'est la derivation que `provision-lib.sh` annonce depuis le debut —
# « d'ici sa derivation, cette ligne se tient a la main ».
#
# CE QU'IL PRODUIT
#   1. <tofu-dir>/roles.auto.tfvars.json   les quatre listes (roles, writers, judges, externals).
#                                          tofu lit les *.auto.tfvars.json nativement.
#   2. sur stdout                          la ligne PROV_ROLES a exporter avant le mint des tokens.
#
# CE QU'IL NE PRODUIT PAS, ET C'EST LA LIGNE QUI COMPTE
#   Il n'ecrit AUCUNE recette. `forge.tf` declare ce qu'un compte a le DROIT d'etre — pas de
#   creation d'org, pas de git-hook serveur, pas d'import local, l'org et les teams. Ce sont des
#   contraintes, et un catalogue est precisement la piece qu'un operateur remplace. Generer la
#   recette DEPUIS un catalogue donnerait a un fichier remplacable l'autorite d'elargir ses propres
#   droits. Un catalogue nomme ses gens ; la recette dit ce qu'etre l'un d'eux permet.
#
# USAGE
#   enroll-catalogue.sh --catalogue <root> --tofu-dir <dir> [--image <img>] [--repo <fleet-dir>]
#
#   Deux chemins de lecture, selon ce qu'on a sous la main :
#     --repo <dir>     un arbre avec mix     -> mix lcars.catalogue.roles (dev, banc)
#     --image <img>    une image livree      -> docker run --rm IMG roles-tfvars <root> (prod)
#   Sans l'un ni l'autre : le depot de ce script, s'il porte un mix.exs.
#
# SORTIES : 0 ok · 1 usage/arguments · 2 lecture du catalogue impossible · 3 ecriture impossible
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATALOGUE=""
TOFU_DIR=""
IMAGE=""
REPO=""
DOCKER_BIN="${DOCKER_BIN:-docker}"

say() { echo "[enroll-catalogue] $*"; }
die() { echo "[enroll-catalogue] ERREUR: $1" >&2; exit "${2:-1}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --catalogue) CATALOGUE="${2:?}"; shift 2 ;;
    --tofu-dir)  TOFU_DIR="${2:?}";  shift 2 ;;
    --image)     IMAGE="${2:?}";     shift 2 ;;
    --repo)      REPO="${2:?}";      shift 2 ;;
    -h|--help)   sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)           die "argument inconnu: $1" ;;
  esac
done

[[ -n "$CATALOGUE" ]] || die "--catalogue <root> requis"
[[ -n "$TOFU_DIR"  ]] || die "--tofu-dir <dir> requis"
[[ -d "$TOFU_DIR"  ]] || die "tofu-dir introuvable: $TOFU_DIR" 3

# Le depot par defaut : ce script vit dans fleet/etc/, donc fleet/ est un cran au-dessus.
[[ -n "$REPO" || -n "$IMAGE" ]] || REPO="$(cd "$HERE/.." && pwd)"

# ─── 1. lire le catalogue ────────────────────────────────────────────────────────────────────────
# Une seule autorite de lecture des deux cotes : `Fleet.Application.CatalogueRoles.tfvars/1`. Le
# mix et l'eval de release appellent LA MEME fonction — la regle de placement (siege / juge /
# ecrivain) est en Elixir, testee, pas reecrite ici en jq.
if [[ -n "$IMAGE" ]]; then
  SRC="image $IMAGE"
  TFVARS="$("$DOCKER_BIN" run --rm "$IMAGE" roles-tfvars "$CATALOGUE" 2>/dev/null)" \
    || die "l'image ne rend pas le roster de $CATALOGUE" 2
else
  SRC="depot $REPO"
  [[ -f "$REPO/mix.exs" ]] || die "pas de mix.exs dans $REPO (utiliser --image pour une install livree)" 1
  # COMPILER D'ABORD, et le silence n'est pas de la coquetterie : sur un arbre froid, mix ecrit
  # « Compiling N files » sur STDOUT — pas stderr — et ces lignes se melent au JSON de la tache.
  # Constate au premier run. Le controle de validite plus bas l'a attrape, mais compter dessus
  # reviendrait a laisser la premiere execution de la journee echouer par principe.
  ( cd "$REPO" && mix compile ) >/dev/null 2>&1 || die "le depot $REPO ne compile pas" 2
  TFVARS="$(cd "$REPO" && mix lcars.catalogue.roles "$CATALOGUE" --tfvars 2>/dev/null)" \
    || die "mix ne rend pas le roster de $CATALOGUE" 2
fi

# Vide ou non-JSON = lecture ratee. Le controle est ici parce que la suite ECRIT : un tfvars
# tronque ferait creer des comptes portant des morceaux de message d'erreur.
[[ -n "$TFVARS" ]] || die "roster vide pour $CATALOGUE" 2
printf '%s' "$TFVARS" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("roles")' 2>/dev/null \
  || die "roster illisible ou sans role pour $CATALOGUE" 2

# ─── 2. ecrire les entrees de la recette ─────────────────────────────────────────────────────────
DEST="$TOFU_DIR/roles.auto.tfvars.json"
TMP="$DEST.tmp.$$"
printf '%s\n' "$TFVARS" > "$TMP" || die "ecriture impossible dans $TOFU_DIR" 3
mv -f "$TMP" "$DEST" || die "ecriture impossible dans $TOFU_DIR" 3

# ─── 3. la ligne pour le mint des tokens ─────────────────────────────────────────────────────────
# PROV_ROLES est la liste qui GAGNE au mint (50-forge la passe en --roles). Elle doit etre le meme
# roster que les comptes, sinon un role a un compte sans token — l'exact symetrique du defaut
# d'origine.
ROLES_LINE="$(printf '%s' "$TFVARS" | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)["roles"]))')"

say "catalogue : $CATALOGUE (lu via $SRC)"
say "ecrit     : $DEST"
say "roles     : $ROLES_LINE"
echo "PROV_ROLES=\"$ROLES_LINE\""
