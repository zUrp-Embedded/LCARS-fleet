#!/usr/bin/env bash
# SOURCE: bin/publish-rail.sh
# AUTHOR: consultant
# STARDATE: 2026-08-14
# STATUS: PROTO-V2 — phase-2 publish rail: certified forge clone -> external rolling PR/MR, auth by gh/glab
#
# AUTH IS NOT OURS, and it is the whole point of V2: this rail NEVER reads, stores or passes an
# external token, under ANY tier — no token file, no `extraheader`, no curl, nothing token-shaped in
# an argv or in a config we write. The push takes its credential from whatever helper the operator
# wired; when the CLI cannot open the request for him we print a ready-to-open URL instead.
#
# GIT_TERMINAL_PROMPT=0 so a MISSING/expired credential fails LOUD instead of hanging on a prompt —
# a headless BEAM has nobody to answer. `gh auth status` / `glab auth status` diagnose it.
#
# WHY A ROLLING BRANCH + ONE PR/MR: the diff base is the destination base's real head, so the request
# always carries everything pending. A new publish force-updates the same branch, and merging empties it.
#
# ⚠ THE DETERMINISM INVARIANT: this rail is only coherent if the filter-repo rewrite is
# DETERMINISTIC, so that commits already on the destination base reappear with the SAME SHAs. It
# does not trust that, it verifies it — and an exit 6 does NOT get "fixed" by dropping the check.
#
# USAGE:
#   publish-rail.sh --project fleet/lcars-fleet --forge http://localhost:3000 \
#       --forge-token-file /opt/lcars/var/tokens/system.gitea_token \
#       --host github --dest-repo lordzurp/LCARS-fleet --work /tmp/pub-lcars-fleet
#
# EXIT CODES — 2 and 3 are RAISED BY publish-transform.sh and travel through:
#   0   PR/MR open/updated (Tier 1) OR branch pushed + a ready-to-open URL printed (Tier 2)
#         OR nothing to publish (fresh head == destination base head)
#   1   usage / missing dependency (git / publish-transform.sh) / unknown --host
#   2   propagated from publish-transform.sh (no human-derivable commit)
#   3   propagated from publish-transform.sh (internal attribution survived — never pushed)
#   4   destination base branch has no head yet — run phase 1 (`lcars approve`) first; this rail only PRs
#   5   git push or the CLI change-request call failed
#   6   destination base is NOT an ancestor of the fresh clone — determinism broke; nothing pushed

set -euo pipefail
export GIT_TERMINAL_PROMPT=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBLISH_TRANSFORM="$SCRIPT_DIR/publish-transform.sh"
FORGE_CLI="$SCRIPT_DIR/forge-cli.sh"

HOST="github"
DEST_HOST=""
BRANCH="lcars/publish"
BASE="main"
PROJECT="" ; FORGE="" ; FORGE_TOKEN_FILE="" ; DEST_REPO="" ; WORK=""
PASSTHROUGH=()

usage() {
  echo "Usage: $0 --project OWNER/NAME --forge URL --forge-token-file FILE \\" >&2
  echo "          --host github|gitlab --dest-repo OWNER/NAME --work DIR \\" >&2
  echo "          [--dest-host HOST] [--branch lcars/publish] [--base main] [publish-transform passthroughs]" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --forge) FORGE="$2"; shift 2 ;;
    --forge-token-file) FORGE_TOKEN_FILE="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --dest-repo) DEST_REPO="$2"; shift 2 ;;
    --dest-host) DEST_HOST="$2"; shift 2 ;;
    --work) WORK="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --vendor-identity|--filter-repo-bin|--system-email|--linearize) PASSTHROUGH+=("$1" "$2"); shift 2 ;;
    *) echo "publish-rail: option inconnue: $1" >&2; usage ;;
  esac
done

[[ -n "$PROJECT" && -n "$FORGE" && -n "$FORGE_TOKEN_FILE" && -n "$DEST_REPO" && -n "$WORK" ]] || usage

case "$HOST" in
  github) CLI="gh";   [[ -n "$DEST_HOST" ]] || DEST_HOST="github.com" ;;
  gitlab) CLI="glab"; [[ -n "$DEST_HOST" ]] || DEST_HOST="gitlab.com" ;;
  *) echo "publish-rail: --host inconnu: '$HOST' (attendu: github|gitlab)" >&2; exit 1 ;;
esac
[[ -x "$PUBLISH_TRANSFORM" ]] || { echo "publish-rail: publish-transform.sh introuvable a cote: $PUBLISH_TRANSFORM" >&2; exit 1; }
[[ -x "$FORGE_CLI" ]] || { echo "publish-rail: forge-cli.sh introuvable a cote: $FORGE_CLI" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "publish-rail: dependance absente: git" >&2; exit 1; }

# Tier detection, NOT a gate.
HAS_CLI=0
if "$FORGE_CLI" auth-ok --host "$HOST" --dest-host "$DEST_HOST" --repo "$DEST_REPO"; then
  HAS_CLI=1
else
  echo "publish-rail: $CLI absent/non authentifie ($DEST_HOST) — mode Tier 2 : push via le helper git" >&2
  echo "  cable, puis URL de PR/MR a ouvrir a la main (pour l'auto : '$CLI auth login')." >&2
fi
[[ -e "$WORK" ]] && { echo "publish-rail: --work ($WORK) doit etre un chemin neuf (le transform exige un clone frais)" >&2; exit 1; }

DEST_URL="https://${DEST_HOST}/${DEST_REPO}.git"

# ⚠ Chaque appel passe $DEST_HOST : sans lui le rail pousse sur l'hote demande et cherche la PR
# sur github.com.
fc() { "$FORGE_CLI" "$1" --host "$HOST" --dest-host "$DEST_HOST" --repo "$DEST_REPO" "${@:2}"; }
request_find()       { fc request-find --head "$BRANCH" --base "$BASE"; }
request_open()       { fc request-open --head "$BRANCH" --base "$BASE" --title "$1" --body "$2"; }
request_manual_url() { fc request-url  --head "$BRANCH" --base "$BASE"; }

if ! git ls-remote --exit-code "$DEST_URL" "refs/heads/$BASE" >/dev/null 2>&1; then
  echo "publish-rail: $DEST_HOST/$DEST_REPO n'a pas de branche '$BASE' — fais la phase 1 (lcars approve) d'abord." >&2
  echo "  Ce rail ne fait QUE des PR/MR ; il ne peuple jamais la base lui-meme." >&2
  exit 4
fi

"$PUBLISH_TRANSFORM" \
  --repo "$PROJECT" --forge "$FORGE" --token-file "$FORGE_TOKEN_FILE" --out "$WORK" \
  "${PASSTHROUGH[@]}"

cd "$WORK"

git remote add dest "$DEST_URL"
git fetch -q dest "$BASE"
FRESH_HEAD="$(git rev-parse HEAD)"
DEST_BASE_HEAD="$(git rev-parse "dest/$BASE")"

if [[ "$FRESH_HEAD" == "$DEST_BASE_HEAD" ]]; then
  echo "publish-rail: rien a publier — le clone reecrit == $DEST_HOST/$DEST_REPO $BASE (deja a jour)."
  exit 0
fi

if ! git merge-base --is-ancestor "dest/$BASE" HEAD; then
  echo "publish-rail: ARRET — $DEST_HOST/$DEST_REPO $BASE n'est PAS un ancetre du clone reecrit." >&2
  echo "  La reecriture filter-repo n'est pas deterministe (ou les histoires ont diverge) :" >&2
  echo "  pousser creerait une PR/MR sans base commune. Rien n'a ete pousse." >&2
  echo "  Le clone est laisse dans $WORK pour inspection." >&2
  exit 6
fi

# Le credential vient du helper git cable, jamais d'ici.
if ! git push -q -f dest "HEAD:refs/heads/$BRANCH"; then
  echo "publish-rail: echec du push de $BRANCH vers $DEST_HOST/$DEST_REPO" >&2
  exit 5
fi

if [[ "$HAS_CLI" == 0 ]]; then
  echo "publish-rail: branche $BRANCH poussee — ouvre la PR/MR ici -> $(request_manual_url)"
  exit 0
fi

# ⚠ LES DEUX ETATS RESTENT SEPARES, et surtout PAS derriere un `|| true` : « aucune PR ouverte » et
# « le helper n'a pas pu repondre » rendent tous deux du vide. Confondus, une auth qui expire en
# cours de route fait tenter la creation, qui echoue, et le message accuse la mauvaise etape.
if ! EXISTING="$(request_find)"; then
  echo "publish-rail: impossible de savoir si une PR/MR est deja ouverte sur $DEST_HOST/$DEST_REPO" >&2
  echo "  La branche $BRANCH EST poussee. Rien n'a ete cree — relance quand la forge repond." >&2
  exit 5
fi
if [[ -n "$EXISTING" ]]; then
  echo "publish-rail: PR/MR actualisee (force-push sur $BRANCH) -> $EXISTING"
  exit 0
fi

TITLE="LCARS publish -> $BASE"
BODY="Publication automatique depuis la forge interne (branche roulante $BRANCH). A relire et merger cote $HOST."
NEW_URL="$(request_open "$TITLE" "$BODY" || true)"  # the helper already said why it failed
if [[ -z "$NEW_URL" ]]; then
  echo "publish-rail: la PR/MR n'a pas pu etre ouverte ($CLI create sans URL)" >&2
  exit 5
fi
echo "publish-rail: PR/MR ouverte -> $NEW_URL"
