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
#                       [--served "<roles deja servis par cette boite>"]
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
    # Les roles DEJA servis par cette boite (sortie d'un enrolement precedent, ou le defaut de
    # provision-lib). Sans eux, le PROV_ROLES rendu ici est complet pour CE catalogue et faux pour
    # la boite : le mint ne verrait plus les autres.
    --served)    SERVED="${2:?}";    shift 2 ;;
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
#
# ⚠ CETTE LIGNE ETAIT UN FRAGMENT PRESENTE COMME UN EXPORT COMPLET, et ca casse en silence dans les
# deux sens. Elle ne portait que les roles METIER du catalogue lu : la prendre verbatim retire du
# mint (1) les comptes `system_*`, qui sont une autorite d'INSTANCE presente dans toutes les orgs,
# et (2) les roles des autres catalogues deja servis par cette boite. Vecu le 2026-08-12 en enrolant
# `web` sur un banc qui servait deja `fleet` : le mint ne voyait plus que quatre comptes.
# Les `system_*` sont dans le tfvars, on les remet. Les autres catalogues, ce script ne les connait
# pas — d'ou `--served`, et l'avertissement quand il est absent : mieux vaut dire qu'on ne sait pas
# que rendre une ligne qui a l'air de tout savoir.
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

# L'ORG que ce catalogue porte — son nom. tofu la lit seul depuis roles.auto.tfvars.json (`var.org`) ;
# cette ligne-ci est pour le SHELL, qui n'a pas de mecanisme equivalent : `50-forge.sh` sonde les
# adhesions et publicise sur `$PROV_FORGE_ORG`, et pointer la mauvaise org rend des 404 muets.
ORG_LINE="$(printf '%s' "$TFVARS" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("org",""))')"

# L'AVERTISSEMENT QUAND ON NE SAIT PAS. Sans `--served`, la ligne rendue est complete pour CE
# catalogue et muette sur les autres — et c'est exactement la forme d'erreur qui ne se voit qu'au
# premier dispatch d'un role dont le token n'a pas ete minte.
if [[ -z "$SERVED" ]]; then
  say "⚠ --served absent : PROV_ROLES ci-dessous couvre CE catalogue et les comptes systeme, PAS"
  say "  les roles des autres catalogues deja servis par la boite. Si elle en sert d'autres, unir"
  say "  les listes avant le mint (un role sans token bloque au premier dispatch, pas a l'enrolement)."
fi

# ─── LES TROIS PIEGES, ET ILS NE VIVENT PLUS DANS UN TRANSCRIPT ─────────────────────────────────
# Enroler `web` sur un banc qui servait deja `fleet` (2026-08-12) a coute trois passes, et aucune
# des trois causes n'etait ecrite nulle part. Elles le sont ici, au moment ou l'operateur en a
# besoin, et pas dans un README qu'il lira apres.
if [[ -d "$TOFU_DIR/instance" ]]; then
  say "⚠ PIEGE 1 — le module instance/ est present dans $TOFU_DIR. Il cree les comptes system_* et il se"
  say "  joue UNE FOIS PAR FORGE. Sur une forge deja provisionnee (un banc bootstrappe, une"
  say "  instance existante), le rejouer rend « user already exists » et fait echouer l'apply."
  say "  Retire-le du dossier de travail si la forge porte deja ses comptes systeme."
fi
say '⚠ PIEGE 2 — le mot de passe. tofu cree les comptes avec UN seul seed_password ; la boite,' 
say "  elle, tient une carte PAR ROLE (/home/private/forge-role-passwords.json). Les deux ne se"
say "  parlent pas : passe a tofu le seed que la boite attend, sinon le mint des jetons rend"
say "  « invalid username, password or token » sur les comptes neufs, et seulement sur eux."
say ""

say "catalogue : $CATALOGUE (lu via $SRC)"
say "ecrit     : $DEST"
say "roles     : $ROLES_LINE"
say "org       : ${ORG_LINE:-<non declaree>}"
echo "PROV_ROLES=\"$ROLES_LINE\""
[[ -n "$ORG_LINE" ]] && echo "PROV_FORGE_ORG=\"$ORG_LINE\""
