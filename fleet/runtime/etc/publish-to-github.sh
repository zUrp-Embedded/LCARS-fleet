#!/usr/bin/env bash
# SOURCE: etc/publish-to-github.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-07
# STATUS: PROTO-V1 — transform de publish GH : réécrit l'historique d'un clone forge pour un miroir GitHub
#
# POURQUOI CE SCRIPT (et pas un raffinement d'onboard) : la forge de travail (Gitea) porte une vérité
# INTERNE — author=humain, co-author=`LCARS-<role>` (Fleet.Credentials.ForgeIdentity, gate de commit),
# et certains commits système (onboard/scaffold) sont authored `lcars-system`. C'est HONNÊTE pour le
# travail (le système a vraiment généré le scaffold), mais ce n'est PAS ce qu'on veut publier : sur un
# miroir GitHub, l'humain doit posséder tout son arbre (author humain partout) + le crédit va au VENDOR
# qui a exécuté le travail (jamais un rôle interne, jamais hardcodé « Claude » — dérivé du launcher N1
# actif). `Co-authored-by:` n'est PAS git-natif : c'est un trailer de message, une convention GitHub —
# donc réécrivable, sans mentir sur rien (un commit n'a qu'un seul author ; le co-author est une surcouche).
#
# MÉCANIQUE : clone FRAIS depuis la forge (jamais le worktree de travail — one-way, les SHA changent, ce
# n'est PAS un sync bidir) → `git filter-repo` avec UN commit-callback qui (1) réécrit l'author des
# commits système (author_email == system_email) en author := committer (déjà l'humain qui a initié) et
# (2) réécrit le trailer `Co-authored-by: LCARS-<role> <...@lcars.local>` en `Co-Authored-By: <vendor>`.
# Ce script NE POUSSE JAMAIS sur GitHub (contrainte dure du projet : push forges locales UNIQUEMENT) —
# il prépare le clone réécrit et affiche le geste de publish pour l'HUMAIN.
#
# DÉPENDANCE : `git-filter-repo` (script Python, PAS empaqueté par défaut sur cette machine — noté au
# backlog provisioning : à installer par le provisioning, ex. via un venv dédié ou pipx, JAMAIS
# `pip install --break-system-packages` qui contourne la protection PEP 668). Override du binaire via
# --filter-repo-bin ou $FILTER_REPO_BIN si hors PATH (ex. un venv : /path/to/venv/bin/git-filter-repo).
#
# USAGE :
#   publish-to-github.sh --repo fleet/mon-projet --forge http://localhost:3000 \
#       --token-file /home/private/test/system.gitea_token --out /tmp/mon-projet-gh
#   Options : --vendor-identity FICHIER (défaut : bin/claude_launch.identity, co-localisé au launcher N1
#             actif — NAME=/EMAIL=) · --filter-repo-bin BIN (défaut : git-filter-repo sur PATH, ou
#             $FILTER_REPO_BIN) · --system-email EMAIL (défaut : lcars-system@lcars.local — DOIT matcher
#             Fleet.Credentials.ForgeIdentity.system_email/0, autorité unique côté runtime).
# EXIT : 0 = clone réécrit prêt dans --out · 1 = usage/dépendance manquante · 2 = échec clone/filter-repo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORGE=""
REPO=""
TOKEN_FILE=""
OUT_DIR=""
VENDOR_IDENTITY="$SCRIPT_DIR/../bin/claude_launch.identity"
FILTER_REPO_BIN="${FILTER_REPO_BIN:-git-filter-repo}"
SYSTEM_EMAIL="lcars-system@lcars.local"

usage() {
  echo "Usage: $0 --repo OWNER/NAME --forge URL --token-file FICHIER --out DIR [options]" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --forge) FORGE="$2"; shift 2 ;;
    --token-file) TOKEN_FILE="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --vendor-identity) VENDOR_IDENTITY="$2"; shift 2 ;;
    --filter-repo-bin) FILTER_REPO_BIN="$2"; shift 2 ;;
    --system-email) SYSTEM_EMAIL="$2"; shift 2 ;;
    *) echo "publish-to-github: option inconnue: $1" >&2; usage ;;
  esac
done

[[ -n "$REPO" && -n "$FORGE" && -n "$TOKEN_FILE" && -n "$OUT_DIR" ]] || usage
[[ -r "$TOKEN_FILE" ]] || { echo "publish-to-github: token-file illisible: $TOKEN_FILE" >&2; exit 1; }
[[ -e "$OUT_DIR" ]] && { echo "publish-to-github: --out existe déjà ($OUT_DIR) — filter-repo exige un clone FRAIS, choisis un chemin neuf" >&2; exit 1; }

command -v "$FILTER_REPO_BIN" >/dev/null 2>&1 || {
  echo "publish-to-github: git-filter-repo introuvable ($FILTER_REPO_BIN)." >&2
  echo "  Installe-le dans un venv dédié (PEP 668 bloque le pip système) :" >&2
  echo "    python3 -m venv ~/.venvs/git-filter-repo && ~/.venvs/git-filter-repo/bin/pip install git-filter-repo" >&2
  echo "  Puis relance avec --filter-repo-bin ~/.venvs/git-filter-repo/bin/git-filter-repo" >&2
  exit 1
}

[[ -r "$VENDOR_IDENTITY" ]] || { echo "publish-to-github: fichier d'identité vendor illisible: $VENDOR_IDENTITY" >&2; exit 1; }
# shellcheck source=/dev/null
source "$VENDOR_IDENTITY"
[[ -n "${NAME:-}" && -n "${EMAIL:-}" ]] || { echo "publish-to-github: $VENDOR_IDENTITY doit poser NAME= et EMAIL=" >&2; exit 1; }
VENDOR_NAME="$NAME"
VENDOR_EMAIL="$EMAIL"

TOKEN="$(<"$TOKEN_FILE")"

echo "publish-to-github: clone frais $FORGE/$REPO.git → $OUT_DIR"
# Auth par header (JAMAIS le token dans l'URL/argv — même mécanisme que Fleet.Credentials.ForgeAuth.git_env,
# GIT_CONFIG_KEY/VALUE plutôt que https://<token>@host, pour ne pas fuiter le token via /proc/<pid>/cmdline).
GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0="http.${FORGE}.extraheader" \
  GIT_CONFIG_VALUE_0="Authorization: token ${TOKEN}" \
  git clone "$FORGE/$REPO.git" "$OUT_DIR"

# Le committer=humain existe sur TOUT commit routé par GitOps (onboard/scaffold/travail) — SAUF le tout
# premier : le `auto_init` de Gitea (POST /repos, "Initial commit") est author=committer=SYSTÈME, aucune
# trace humaine dans CE commit. On ne peut donc pas dériver l'humain de son propre committer → on scanne
# les AUTRES commits du repo pour trouver la première identité non-système (garantie d'exister : tout
# projet onboardé a au moins un commit scaffold/travail avec committer=humain).
HUMAN_LINE="$(cd "$OUT_DIR" && git log --all --format='%cn|%ce' | awk -F'|' -v se="$SYSTEM_EMAIL" '$2 != se {print; exit}')"
[[ -n "$HUMAN_LINE" ]] || { echo "publish-to-github: aucun commit non-système trouvé — humain indérivable" >&2; exit 2; }
HUMAN_NAME="${HUMAN_LINE%%|*}"
HUMAN_EMAIL="${HUMAN_LINE##*|}"

echo "publish-to-github: réécriture (git filter-repo) — author système→humain ($HUMAN_NAME), co-author rôle→vendor ($VENDOR_NAME)"
# Les 5 valeurs passent par l'ENVIRONNEMENT (os.environb côté callback), JAMAIS par interpolation bash
# dans le source Python : un nom d'auteur est une donnée NON CONTRÔLÉE (git log %cn) — l'ancien
# `${VAR@Q}` produisait, sur une apostrophe (O'Brien), un littéral bash `$'...'` INVALIDE en Python →
# SyntaxError git-filter-repo, exit 2 opaque. Le callback est un texte FIXE (quote simple bash, aucune
# apostrophe dedans) ; `os.environb` rend les bytes exacts (zéro décodage/réencodage, noms non-UTF-8 ok).
(cd "$OUT_DIR" && \
  LCARS_PUB_SYSTEM_EMAIL="$SYSTEM_EMAIL" \
  LCARS_PUB_VENDOR_NAME="$VENDOR_NAME" \
  LCARS_PUB_VENDOR_EMAIL="$VENDOR_EMAIL" \
  LCARS_PUB_HUMAN_NAME="$HUMAN_NAME" \
  LCARS_PUB_HUMAN_EMAIL="$HUMAN_EMAIL" \
  "$FILTER_REPO_BIN" --commit-callback '
import re, os
SYSTEM_EMAIL = os.environb[b"LCARS_PUB_SYSTEM_EMAIL"]
VENDOR_NAME = os.environb[b"LCARS_PUB_VENDOR_NAME"]
VENDOR_EMAIL = os.environb[b"LCARS_PUB_VENDOR_EMAIL"]
HUMAN_NAME = os.environb[b"LCARS_PUB_HUMAN_NAME"]
HUMAN_EMAIL = os.environb[b"LCARS_PUB_HUMAN_EMAIL"]

if commit.author_email == SYSTEM_EMAIL:
    if commit.committer_email != SYSTEM_EMAIL:
        commit.author_name = commit.committer_name
        commit.author_email = commit.committer_email
    else:
        # auto_init Gitea (Initial commit) : committer AUSSI systeme, aucune trace humaine sur CE
        # commit -> fallback sur HUMAN_NAME/EMAIL (identite humaine scannee en amont, hors callback).
        # NB : ce bloc est une chaine bash single-quotee -> AUCUNE apostrophe ASCII ici (sinon la
        # quote casse — la classe de bug exacte que le passage par env corrige).
        commit.author_name = HUMAN_NAME
        commit.author_email = HUMAN_EMAIL
        commit.committer_name = HUMAN_NAME
        commit.committer_email = HUMAN_EMAIL

commit.message = re.sub(
    rb"Co-authored-by:\s*LCARS-\S+\s*<[^>]+@lcars\.local>",
    b"Co-Authored-By: " + VENDOR_NAME + b" <" + VENDOR_EMAIL + b">",
    commit.message,
    flags=re.IGNORECASE,
)
')

echo ""
echo "publish-to-github: clone réécrit prêt → $OUT_DIR"
echo "  Les SHA ont changé (réécriture one-way — ce n'est PAS un sync avec la forge de travail)."
echo "  Geste de publish (JAMAIS exécuté par ce script — push GitHub = ton geste) :"
echo "    cd $OUT_DIR"
echo "    git remote add github git@github.com:<owner>/<repo>.git"
echo "    git push github main"
