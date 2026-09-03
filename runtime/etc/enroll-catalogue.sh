#!/usr/bin/env bash
# SOURCE: runtime/etc/enroll-catalogue.sh
# AUTHOR: DrDree
# STARDATE: 2026-08-10
# STATUS: actif — derive les entrees de la recette forge depuis un catalogue
#
# ENROLLER UN CATALOGUE : lit les roles qu'un catalogue declare, et ecrit ce que la recette forge
# attend en entree.
#
# CE QU'IL PRODUIT
#   1. <tofu-dir>/roles.auto.tfvars.json   les quatre listes (roles, writers, judges, externals).
#                                          tofu lit les *.auto.tfvars.json nativement.
#   2. sur stdout                          la ligne PROV_ROLES a exporter avant le mint des tokens.
#
# ⚠ CE QU'IL NE PRODUIT PAS, ET C'EST LA LIGNE QUI COMPTE
#   Il n'ecrit AUCUNE recette. Un catalogue est precisement la piece qu'un operateur remplace, et
#   generer la recette DEPUIS lui donnerait a un fichier remplacable l'autorite d'elargir ses
#   propres droits. Un catalogue nomme ses gens ; la recette dit ce qu'etre l'un d'eux permet.
#
# USAGE
#   enroll-catalogue.sh --tofu-dir <dir> [--catalogue <root>]
#                       [--image <img>] [--repo <fleet-dir>] [--release <bin>]
#                       [--served "<roles deja servis par cette boite>"]
#
#   TROIS chemins de lecture, selon ce qu'on a sous la main :
#     --image <img>    une image livree   -> docker run --rm IMG roles-tfvars [<root>]
#     --repo <dir>     un arbre avec mix  -> mix lcars.catalogue.roles <root>  (exige Elixir SUR L'HOTE)
#     --release <bin>  une release posee  -> <bin> eval Fleet.Roster.eval_tfvars(<root>)
#                                            (ni mix ni docker — le chemin du POSTE en livraison binaire)
#   Sans l'un ni l'autre : le depot de ce script, s'il porte un mix.exs.
# SORTIES : 0 ok · 1 usage/arguments · 2 lecture du catalogue impossible · 3 ecriture impossible
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
    # Les roles DEJA servis par cette boite (sortie d'un enrolement precedent, ou le defaut de
    # provision-lib). Sans eux, le PROV_ROLES rendu ici est complet pour CE catalogue et faux pour
    # la boite : le mint ne verrait plus les autres.
    --served)    SERVED="${2:?}";    shift 2 ;;
    # Borne RELATIVE, ligne terminale EXCLUE : une plage a numeros absolus fait glisser la fenetre
    # sur le code des qu'une ligne de l'en-tete bouge. `^[^#]` ne matche pas une ligne vide, donc la
    # plage court jusqu'au premier VRAI code, qu'on n'imprime pas.
    -h|--help)   sed -n '2,/^[^#]/{/^[^#]/!p;}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)           die "argument inconnu: $1" ;;
  esac
done

# ⚠ `--catalogue` EST FACULTATIF AVEC `--image`, ET SON ABSENCE VEUT DIRE « CELUI DE L'IMAGE ».
# Une image porte son catalogue ; lui en nommer un autre n'a de sens que pour en enroler un que
# l'operateur apporte. Avec `--repo` il reste obligatoire : un arbre source en porte plusieurs.
# ⚠ ET `--release` PORTE LE SIEN AUSSI, pour la meme raison qu'une image : c'est la MEME release
# a l'interieur. `Fleet.Catalogue.root()` rend le catalogue livre quand on ne nomme rien.
[[ -n "$CATALOGUE" || -n "$IMAGE" || -n "$RELEASE" ]] || die "--catalogue <root> requis (ou --image / --release, qui portent le sien)"
[[ -n "$TOFU_DIR"  ]] || die "--tofu-dir <dir> requis"
[[ -d "$TOFU_DIR"  ]] || die "tofu-dir introuvable: $TOFU_DIR" 3

# ⚠ ABSOLU DES QU'IL EXISTE, et le `-d` est la garde : un catalogue livre DANS l'image n'existe pas
# sur l'hote, c'est le seul cas ou ce chemin n'est pas un chemin d'hote.
[[ -n "$CATALOGUE" && -d "$CATALOGUE" ]] && CATALOGUE="$(cd "$CATALOGUE" && pwd)"

# Le depot par defaut : ce script vit dans runtime/etc/, donc runtime/ est un cran au-dessus.
[[ -n "$REPO" || -n "$IMAGE" || -n "$RELEASE" ]] || REPO="$(cd "$HERE/.." && pwd)"

# ─── 1. lire le catalogue ────────────────────────────────────────────────────────────────────────
# Une seule autorite de lecture des deux cotes : `Fleet.Roster.tfvars/1`. Le
# mix et l'eval de release appellent LA MEME fonction — la regle de placement (siege / juge /
# ecrivain) est en Elixir, testee, pas reecrite ici en jq.
if [[ -n "$IMAGE" ]]; then
  SRC="image $IMAGE"
  MOUNT=()
  [[ -n "$CATALOGUE" && -d "$CATALOGUE" ]] && MOUNT=(-v "$CATALOGUE:$CATALOGUE:ro")
  TFVARS="$("$DOCKER_BIN" run --rm ${MOUNT[@]+"${MOUNT[@]}"} "$IMAGE" roles-tfvars ${CATALOGUE:+"$CATALOGUE"} 2>/dev/null)" \
    || die "l'image ne rend pas le roster de ${CATALOGUE:-son catalogue livre}" 2
elif [[ -n "$RELEASE" ]]; then
  # ─── LA TROISIEME PORTE : LA RELEASE POSEE ────────────────────────────────────────────────────
  #
  # ⚠ CE N'EST PAS UN TROISIEME MECANISME, C'EST LE MEME. `--image` fait deja
  # `docker run IMG roles-tfvars`, et cette porte-la n'est qu'un enrobage : l'entrypoint execute
  # `"$RELEASE_BIN" eval "Fleet.Roster.eval_tfvars(...)"`. Docker n'y sert qu'a transporter la
  # release. Quand la release est DEJA POSEE sur la machine, le detour n'a plus d'objet.
  #
  # POURQUOI IL MANQUAIT : les deux portes existantes couvrent la boite (`--image`, docker) et le
  # poste en livraison SOURCE (`--repo`, mix). Un poste en livraison BINAIRE n'a ni l'un ni
  # l'autre — pas de mix, c'est le geste R5 qui le veut ; pas d'image, c'est un poste. Il a la
  # release, et personne ne savait la lire.
  #
  # Le mur etait connu et ecrit plus haut : « le banc est mort dessus sur la premiere machine
  # neuve (2026-08-18, `mix: ABSENT`) ». La reponse donnee alors etait « prefere --image » ; elle
  # ne vaut que pour qui a docker.
  #
  # ⚠ MEME FONCTION, MEME AUTORITE : `Fleet.Roster.eval_tfvars`. La regle de placement (siege /
  # juge / ecrivain) reste en Elixir, testee — elle n'est reecrite ni ici, ni en jq, ni ailleurs.
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
  # ⚠ COMPILER D'ABORD, ET EN SILENCE : sur un arbre froid, mix ecrit « Compiling N files » sur
  # STDOUT — pas stderr — et ces lignes se meleraient au JSON de la tache.
  ( cd "$REPO" && mix compile ) >/dev/null 2>&1 || die "le depot $REPO ne compile pas" 2
  TFVARS="$(cd "$REPO" && mix lcars.catalogue.roles "$CATALOGUE" --tfvars 2>/dev/null)" \
    || die "mix ne rend pas le roster de $CATALOGUE" 2
fi

# ⚠ LE CONTROLE EST ICI PARCE QUE LA SUITE ECRIT : un tfvars tronque ferait creer des comptes
# portant des morceaux de message d'erreur.
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

# tofu lit l'org SEUL depuis roles.auto.tfvars.json ; cette ligne-ci est pour le SHELL, qui n'a pas
# de mecanisme equivalent et rendrait des 404 muets en pointant la mauvaise org.
ORG_LINE="$(printf '%s' "$TFVARS" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("org",""))')"

if [[ -z "$SERVED" ]]; then
  say "⚠ --served absent : PROV_ROLES ci-dessous couvre CE catalogue et les comptes systeme, PAS"
  say "  les roles des autres catalogues deja servis par la boite. Si elle en sert d'autres, unir"
  say "  les listes avant le mint (un role sans token bloque au premier dispatch, pas a l'enrolement)."
fi

if [[ -d "$TOFU_DIR/instance" ]]; then
  say "⚠ PIEGE 1 — le module instance/ est present dans $TOFU_DIR. Il cree les comptes system_* et il se"
  say "  joue UNE FOIS PAR FORGE. Sur une forge deja provisionnee (un banc bootstrappe, une"
  say "  instance existante), le rejouer rend « user already exists » et fait echouer l'apply."
  say "  Retire-le du dossier de travail si la forge porte deja ses comptes systeme."
fi
say '⚠ PIEGE 2 — le mot de passe. tofu cree les comptes avec UN seul seed_password ; la boite,' 
say "  elle, tient une carte PAR ROLE (/opt/lcars/var/tokens/forge-role-passwords.json). Les deux ne se"
say "  parlent pas : passe a tofu le seed que la boite attend, sinon le mint des jetons rend"
say "  « invalid username, password or token » sur les comptes neufs, et seulement sur eux."
say ""

# ⚠ « celui de l image » ETAIT VRAI QUAND IL N'Y AVAIT QUE DEUX PORTES. Une release posee porte le
# sien tout autant, et nommer le mauvais porteur envoie chercher un objet qui n'existe pas ici.
say "catalogue : ${CATALOGUE:-<celui de la livraison>} (lu via $SRC)"
say "ecrit     : $DEST"
say "roles     : $ROLES_LINE"
say "org       : ${ORG_LINE:-<non declaree>}"
echo "PROV_ROLES=\"$ROLES_LINE\""
[[ -n "$ORG_LINE" ]] && echo "PROV_FORGE_ORG=\"$ORG_LINE\""
