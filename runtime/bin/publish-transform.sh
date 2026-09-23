#!/usr/bin/env bash
# SOURCE: bin/publish-transform.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-07
# STATUS: PROTO-V1 — publish transform: rewrites a forge clone's history for an EXTERNAL mirror
#
# EXIT CODES ARE NOT NORMALISED: this runs under `set -euo pipefail` with NO trap, so a status other
# than the ones this script raises itself is the failing command's own — `git clone` returns git's
# (128 on the usual clone errors), the filter-repo subshell returns filter-repo's. Do not read an
# unknown failure as "not a clone/filter-repo problem": it is the opposite.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ⚖ Decision 3 : le compte systeme est un FAIT de la machine. Le voisin resout le checkout, la
# racine du produit resout la machine — voir `lcars-toolchain-converge` pour le pourquoi des deux.
FACTS_SH="${LCARS_FACTS_SH:-$SCRIPT_DIR/../services/lib/facts.sh}"
[[ -r "$FACTS_SH" ]] || FACTS_SH=/opt/lcars/services/lib/facts.sh
# shellcheck source=../services/lib/facts.sh
. "$FACTS_SH"
FORGE=""
REPO=""
TOKEN_FILE=""
OUT_DIR=""
VENDOR_IDENTITY="$SCRIPT_DIR/claude_launch.identity"
FILTER_REPO_BIN="${FILTER_REPO_BIN:-git-filter-repo}"
SYSTEM_EMAIL="$LCARS_SYSTEM_ACCOUNT@lcars.local"
# D2 — les bulles de merge sont NORMALES sur un main, des deux cotes : l'aplatissement ne sert que la
# branche d'une MR upstream, d'ou le defaut a vide.
LINEARIZE=""
PUBLISH_NAME=""
PUBLISH_EMAIL=""

usage() {
  echo "Usage: $0 --repo OWNER/NAME --forge URL --token-file FICHIER --out DIR [options]" >&2
  echo "  Options: --publish-name N --publish-email E (l'identite publique) · --vendor-identity F" >&2
  echo "           --filter-repo-bin B · --system-email E · --linearize BRANCHE" >&2
  exit 1
}

# The two patterns that decide what gets REWRITTEN (the boundary) are the ones that decide what gets
# REFUSED (the certification). A boundary drifted from the certification selects less than the
# certification refuses — a publish that dies at the last gate instead of one that never had the marker.
# ⚠ INTERNE = TOUTE ADRESSE QUI NE PEUT ÊTRE L'IDENTITÉ PUBLIQUE DE PERSONNE : le domaine de la forge
# locale, l'adresse système, et une adresse SANS DOMAINE ROUTABLE (pas de point après le `@`).
# `captain@Nico-SuperCharged` — l'identité de l'hôte, qui a signé tous les livrables d'un banc le
# 2026-09-23 — passait pour humaine et serait partie telle quelle vers la forge publique.
internal_ident_re() { # <system_email>
  printf '@lcars\.local|%s|@[^.@]+$' "$(printf '%s' "$1" | sed 's/[.[\*^$]/\\&/g')"
}
is_internal_email() { # <email> <system_email>
  printf '%s\n' "$1" | grep -qiE "$(internal_ident_re "$2")"
}
# ⚠ `\s` ET NON `[[:space:]]` : ce motif est lu par DEUX moteurs. La classe POSIX est valide en ERE
# (grep) et n'existe PAS en Python, qui la lit comme un ensemble imbrique et emet un `FutureWarning`
# sur stderr — melange a la sortie de la fonction. `\s` est compris des deux.
internal_msg_re() { printf 'Co-authored-by:\s*LCARS-|@lcars\.local'; }

scan_forbidden_markers() {
  local dir="$1" system_email="$2" hits=0

  local ident
  ident="$(cd "$dir" && git log --all --format='%ae%n%ce' | grep -iE "$(internal_ident_re "$system_email")" || true)"
  if [[ -n "$ident" ]]; then
    echo "publish-transform: CERTIFICATION KO — identite interne survivante dans author/committer :" >&2
    printf '  %s\n' "$ident" >&2
    hits=1
  fi

  local trailer
  trailer="$(cd "$dir" && git log --all --format='%B' | grep -iE "$(internal_msg_re)" || true)"
  if [[ -n "$trailer" ]]; then
    echo "publish-transform: CERTIFICATION KO — trailer interne survivant dans les messages :" >&2
    printf '  %s\n' "$trailer" >&2
    hits=1
  fi

  return "$hits"
}

oldest_internal_commit() { # <dir> <system_email> -> sha, or empty
  (cd "$1" && git log --topo-order --reverse --format='%H%x1f%ae%x1f%ce%x1f%B%x1e' HEAD) \
    | LCARS_IDENT_RE="$(internal_ident_re "$2")" LCARS_MSG_RE="$(internal_msg_re)" \
      python3 "$SCRIPT_DIR/publish-transform-boundary.py"
}

linearize_first_parent() { # <dir> <branch>
  local dir="$1" branch="$2" prev="" new c old_tip
  old_tip="$(git -C "$dir" rev-parse "refs/heads/${branch}" 2>/dev/null)"     || { echo "publish-transform: --linearize: branche inconnue: $branch" >&2; return 1; }

  while IFS= read -r c; do
    new="$(
      GIT_AUTHOR_NAME="$(git -C "$dir" log -1 --format=%an "$c")"       GIT_AUTHOR_EMAIL="$(git -C "$dir" log -1 --format=%ae "$c")"       GIT_AUTHOR_DATE="$(git -C "$dir" log -1 --format=%aD "$c")"       GIT_COMMITTER_NAME="$(git -C "$dir" log -1 --format=%cn "$c")"       GIT_COMMITTER_EMAIL="$(git -C "$dir" log -1 --format=%ce "$c")"       GIT_COMMITTER_DATE="$(git -C "$dir" log -1 --format=%cD "$c")"       git -C "$dir" commit-tree "$c^{tree}" ${prev:+-p "$prev"}         < <(git -C "$dir" log -1 --format=%B "$c")
    )" || return 1
    prev="$new"
  done < <(git -C "$dir" rev-list --first-parent --reverse "$old_tip")

  [[ "$(git -C "$dir" rev-parse "$prev^{tree}")" == "$(git -C "$dir" rev-parse "$old_tip^{tree}")" ]]     || { echo "publish-transform: linearize: l arbre final DIFFERE de l original — refus" >&2; return 1; }

  git -C "$dir" update-ref "refs/heads/${branch}" "$prev"

  if [[ -n "$(git -C "$dir" rev-list --merges "refs/heads/${branch}")" ]]; then
    echo "publish-transform: linearize: un commit de merge survit — refus" >&2
    return 1
  fi
}

# Source guard: the bats suite sources this file to drive the functions above one by one, on fixture
# repos and without git-filter-repo. Anything defined BELOW is invisible to it.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then return 0; fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --forge) FORGE="$2"; shift 2 ;;
    --token-file) TOKEN_FILE="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --vendor-identity) VENDOR_IDENTITY="$2"; shift 2 ;;
    --filter-repo-bin) FILTER_REPO_BIN="$2"; shift 2 ;;
    --system-email) SYSTEM_EMAIL="$2"; shift 2 ;;
    --linearize) LINEARIZE="$2"; shift 2 ;;
    --publish-name) PUBLISH_NAME="$2"; shift 2 ;;
    --publish-email) PUBLISH_EMAIL="$2"; shift 2 ;;
    *) echo "publish-transform: option inconnue: $1" >&2; usage ;;
  esac
done

[[ -n "$REPO" && -n "$FORGE" && -n "$TOKEN_FILE" && -n "$OUT_DIR" ]] || usage
[[ -r "$TOKEN_FILE" ]] || { echo "publish-transform: token-file illisible: $TOKEN_FILE" >&2; exit 1; }
[[ -e "$OUT_DIR" ]] && { echo "publish-transform: --out ($OUT_DIR) n'est pas un chemin neuf — filter-repo exige un clone FRAIS" >&2; exit 1; }

command -v "$FILTER_REPO_BIN" >/dev/null 2>&1 || {
  echo "publish-transform: git-filter-repo introuvable ($FILTER_REPO_BIN)." >&2
  echo "  Installe-le dans un venv (PEP 668 bloque le pip global) :" >&2
  echo "    python3 -m venv ~/.venvs/git-filter-repo && ~/.venvs/git-filter-repo/bin/pip install git-filter-repo" >&2
  echo "  Puis relance avec --filter-repo-bin ~/.venvs/git-filter-repo/bin/git-filter-repo" >&2
  exit 1
}

[[ -r "$VENDOR_IDENTITY" ]] || { echo "publish-transform: fichier vendor illisible: $VENDOR_IDENTITY" >&2; exit 1; }
# shellcheck source=/dev/null
source "$VENDOR_IDENTITY"
[[ -n "${NAME:-}" && -n "${EMAIL:-}" ]] || { echo "publish-transform: $VENDOR_IDENTITY doit poser NAME= et EMAIL=" >&2; exit 1; }
VENDOR_NAME="$NAME"
VENDOR_EMAIL="$EMAIL"

TOKEN="$(<"$TOKEN_FILE")"

echo "publish-transform: clone frais $FORGE/$REPO.git → $OUT_DIR"
# Header auth, NEVER the token in the URL or argv: GIT_CONFIG_KEY/VALUE rather than
# https://<token>@host, so the token does not leak through /proc/<pid>/cmdline.
GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0="http.${FORGE}.extraheader" \
  GIT_CONFIG_VALUE_0="Authorization: token ${TOKEN}" \
  git clone "$FORGE/$REPO.git" "$OUT_DIR"

# L'IDENTITÉ PUBLIQUE SE DÉCLARE, ELLE NE SE DÉDUIT PAS. Par ordre : celle de la liaison de publication
# (`--publish-email`, posée par `lcars approve`), puis l'identité git globale de celui qui publie
# (`--global`, pas le `[user]` local d'un dépôt). Une identité interne n'est jamais retenue. Aucune →
# arrêt : l'ancienne déduction prenait le committer externe le plus récent de l'historique, c'est-à-dire
# n'importe qui.
# ⚠ `--global`, ET PAS `--get` NU : sans lui git resout local > global, et lance depuis un depot qui
# porte un `[user]` local le script prendrait CETTE identite au lieu de celle du conteneur.
if [[ -n "${PUBLISH_EMAIL:-}" ]]; then
  HUMAN_NAME="${PUBLISH_NAME:-}"
  HUMAN_EMAIL="$PUBLISH_EMAIL"
  ORIGINE="de la liaison de publication"
else
  HUMAN_NAME="$(git config --global --get user.name 2>/dev/null || true)"
  HUMAN_EMAIL="$(git config --global --get user.email 2>/dev/null || true)"
  ORIGINE="git config --global"
fi

if [[ -z "$HUMAN_EMAIL" ]] || is_internal_email "$HUMAN_EMAIL" "$SYSTEM_EMAIL"; then
  echo "publish-transform: aucune identite PUBLIQUE declaree (${HUMAN_EMAIL:-rien} — interne ou absente)." >&2
  echo "  Declare celle sous laquelle ce depot sort :" >&2
  echo "    lcars approve $REPO --publish-name \"Ton Nom\" --publish-email ton@adresse.publique" >&2
  exit 2
fi
echo "publish-transform: identite publique $ORIGINE : $HUMAN_NAME <$HUMAN_EMAIL>"
[[ -n "$HUMAN_NAME" ]] || HUMAN_NAME="$HUMAN_EMAIL"

# A wrong boundary cannot leak, it can only stop the publish: the certification below rescans the
# WHOLE history, not the rewritten range.
FIRST_OURS="$(oldest_internal_commit "$OUT_DIR" "$SYSTEM_EMAIL")"
REFS_ARGS=()
if [[ -z "$FIRST_OURS" ]]; then
  echo "publish-transform: aucune attribution interne — rien a reecrire, tous les SHA conserves"
elif BOUND="$(git -C "$OUT_DIR" rev-parse -q --verify "${FIRST_OURS}^" 2>/dev/null)" && [[ -n "$BOUND" ]]; then
  REFS_ARGS=(--refs "${BOUND}..HEAD")
  echo "publish-transform: reecriture BORNEE a ${FIRST_OURS:0:8}..HEAD ($(git -C "$OUT_DIR" rev-list --count "${BOUND}..HEAD") commits) — l histoire importee garde ses SHA"
else
  echo "publish-transform: tout l historique est interne (projet ne dans la fleet) — reecriture complete"
fi

if [[ -n "$FIRST_OURS" ]]; then
echo "publish-transform: passe filter-repo — toute identite interne (@lcars.local) devient $HUMAN_NAME, co-author interne devient $VENDOR_NAME"
(cd "$OUT_DIR" && \
  LCARS_PUB_VENDOR_NAME="$VENDOR_NAME" \
  LCARS_PUB_VENDOR_EMAIL="$VENDOR_EMAIL" \
  LCARS_PUB_HUMAN_NAME="$HUMAN_NAME" \
  LCARS_PUB_HUMAN_EMAIL="$HUMAN_EMAIL" \
  "$FILTER_REPO_BIN" --commit-callback "$SCRIPT_DIR/publish-transform-attribution.py" \
  ${REFS_ARGS[@]+"${REFS_ARGS[@]}"})
fi

# ⚠ PAS COSMETIQUE : `--partial` laisse `refs/remotes/origin/*` sur l'histoire d'avant, et la
# certification lit `git log --all` — elle refuserait une passe propre sur des refs NON PUBLIEES.
git -C "$OUT_DIR" remote remove origin 2>/dev/null || true

if [[ -n "$LINEARIZE" ]]; then
  echo "publish-transform: linearisation first-parent de '$LINEARIZE' (forme MR — arbre final identique, merges aplatis)"
  linearize_first_parent "$OUT_DIR" "$LINEARIZE" || exit 4
fi

# The transform is CERTIFIED, not trusted on its exit code.
if ! scan_forbidden_markers "$OUT_DIR" "$SYSTEM_EMAIL"; then
  echo "publish-transform: ARRET — le clone transforme porte encore une attribution interne (voir ci-dessus)." >&2
  echo "  Le clone est laisse dans $OUT_DIR pour inspection ; NE PAS pousser en l'etat." >&2
  exit 3
fi

echo ""
echo "publish-transform: fin de la passe → $OUT_DIR (certifie : zero attribution interne survivante)"
echo "  Les SHA des commits REECRITS sont neufs (passe one-way : ce n'est PAS un sync avec la forge)."
echo "  Ceux de l'histoire importee sont CONSERVES — c'est ce qui rend une PR vers l'upstream lisible."
echo "  Geste de publish (ce script ne pousse JAMAIS — le push est ton geste) :"
echo "    cd $OUT_DIR"
echo "    git remote add <nom> <url-du-depot-de-destination>"
echo "    git push <nom> main"
echo "  Ou, si le projet est deja lie : « lcars publish run <owner/nom-interne> » — le rail"
echo "  pousse une branche roulante et ouvre UNE PR/MR, sans toucher la base." 
