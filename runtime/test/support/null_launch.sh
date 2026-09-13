#!/usr/bin/env bash
# SOURCE: runtime/test/support/null_launch.sh
# AUTHOR: DrDree
# STARDATE: 2026-08-11
# STATUS: TEST DOUBLE — honours the N1 launcher contract, launches NO vendor
#
# ─── POURQUOI CE FICHIER EXISTE ─────────────────────────────────────────────────────────────────
# « vendor-agnostique » est une propriete qu'on VERIFIE A LA LECTURE, et une propriete qu'on verifie
# a la lecture n'en est pas une. Ce launcher est la preuve executable de la frontiere N0/N1 : il
# honore EXACTEMENT le contrat qu'un launcher vendor recoit (argv + env), et ne lance aucun vendor.
# Si le contrat bouge et qu'un second launcher ne suit pas, le gate le dit — c'est tout l'interet.
#
# ─── POURQUOI PAS DANS bin/ ─────────────────────────────────────────────────────────────────────
# `bin/` EST la frontiere vendor N1 : un fichier qui y vit est un launcher de PRODUCTION, et le
# discriminant du depot est « un launcher par vendor, meme forme d'arguments ». Poser ici un
# launcher qui ne lance rien y ajouterait un vendor fantome, et la frontiere cesserait de se lire
# par son contenu. Il vit donc sous `test/support/`, avec les autres doubles.
#
# ─── LE CONTRAT, TEL QUE `bin/claude_launch.sh` LE PORTE ────────────────────────────────────────
#   argv : <role> <pod_id> <pod_dir>
#   env REQUIS (fail-loud, `${VAR:?}`) : LCARS_POD_SESSION_ID · LCARS_POD_SESSION_NAME_PREFIX
#   env optionnels lus ici parce qu'ils changent le COMPORTEMENT du vrai launcher :
#     LCARS_POD_HOME     remplace le 3e positionnel
#     LCARS_POD_RESUME   0 = creation (--session-id) / 1 = reprise (--resume)
#
# Le transcript est DETERMINISTE : meme entree, meme sortie, octet pour octet. Aucune horloge,
# aucun aleatoire, aucun chemin absolu de la machine — sinon la preuve ne serait pas rejouable.
set -euo pipefail

[[ $# -ge 3 ]] || { echo "ERR: usage: $0 <role> <pod_id> <pod_dir>" >&2; exit 64; }

ROLE="$1"
POD_ID="$2"
POD_DIR="${LCARS_POD_HOME:-$3}"

# MEME fail-loud que le vrai : une variable requise absente est une erreur de CABLAGE du spawner,
# jamais un defaut a combler ici. Un double qui tolere ce que la production refuse ne prouve rien.
SESSION_ID="${LCARS_POD_SESSION_ID:?session UUID required (pre-allocated by the spawner)}"
SESSION_NAME_PREFIX="${LCARS_POD_SESSION_NAME_PREFIX:?pod label required (Fleet.Layout.pod_label)}"
POD_RESUME="${LCARS_POD_RESUME:-0}"

case "$POD_RESUME" in
  0) MODE="create" ;;
  1) MODE="resume" ;;
  *) echo "ERR: LCARS_POD_RESUME must be 0 or 1, got '$POD_RESUME'" >&2; exit 64 ;;
esac

# Le pod_dir est rendu par son NOM DE BASE : le transcript doit etre identique d'une machine a
# l'autre, et un chemin absolu porte le home de qui l'a joue.
cat <<EOF
null_launch v1
role=$ROLE
pod_id=$POD_ID
pod_dir=$(basename -- "$POD_DIR")
session_id=$SESSION_ID
session_name_prefix=$SESSION_NAME_PREFIX
mode=$MODE
vendor=none
EOF
