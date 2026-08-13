#!/usr/bin/env bash
# SOURCE: etc/publish-rail.sh
# AUTHOR: consultant
# STARDATE: 2026-08-14
# STATUS: PROTO-V1 — phase-2 publish rail: certified forge clone -> external rolling PR/MR
#
# WHAT: takes a certified-clean clone produced by publish-to-github.sh, force-pushes it to a FIXED
# rolling branch (`lcars/publish`) on the EXTERNAL destination, and opens (or leaves updated) exactly
# ONE change request (GitHub PR / GitLab MR) against the base branch. Prints its URL. It NEVER pushes
# the destination base branch directly — that is phase 1 (`lcars approve`, host-side, human gate).
#
# NOT GITHUB-ONLY, despite the sibling's name. Everything here is generic git EXCEPT the "open/find
# the change request" call, which is behind a per-host adapter (`--host github|gitlab`). GitLab is a
# first-class target; a self-hosted GitHub/GitLab is reached via `--dest-host`. The clone+rewrite step
# (publish-to-github.sh) is host-agnostic — it only reads the INTERNAL forge and rewrites authorship.
#
# WHY A ROLLING BRANCH + ONE PR/MR: the diff base is the destination base branch's real head, so the
# request always carries "internal main - external main" = everything pending. A new publish
# force-updates the same branch; the single open request stays current; merging it empties it.
# Ref: work/beyond_#6/chantier-publication-github-2026-08-14.
#
# THE DETERMINISM INVARIANT, load-bearing: publish-to-github.sh rewrites EVERY SHA (one-way filter-repo
# pass). This rail is only coherent if that rewrite is DETERMINISTIC — same source commit => same
# rewritten SHA each pass (fixed author/committer mapping + preserved dates + identical
# trees/parents/messages => identical hash). Then commits already on the destination base reappear
# with the SAME SHAs in the fresh clone, so the base IS an ancestor of it and the diff is only the new
# commits. The rail does NOT trust that: it VERIFIES the base is an ancestor of the fresh clone and
# REFUSES (exit 6) otherwise, rather than force-pushing an unrelated history into a baseless request.
# If exit 6 fires, the rewrite is not deterministic; do not "fix" it by dropping the check.
#
# THE GATE IS NOT HERE: this rail is the mechanism. Phase-2 authorization is the human MERGING the
# PR/MR on the destination's web UI. The destination token is read from a file, host-side, and NEVER
# enters a pod.
#
# DEPENDENCY: git, curl, python3 (JSON + urlencode), and publish-to-github.sh (co-located, needs
# git-filter-repo). All host-side.
#
# USAGE:
#   publish-rail.sh --project fleet/lcars-fleet --forge http://localhost:3000 \
#       --forge-token-file /home/private/system.gitea_token \
#       --host github --dest-repo lordzurp/LCARS-fleet \
#       --dest-token-file /home/private/github.token --work /tmp/pub-lcars-fleet
#   Optional: --host gitlab (default github) · --dest-host HOST (default per --host:
#             github.com / gitlab.com; set it for GitHub Enterprise or self-hosted GitLab) ·
#             --branch lcars/publish · --base main · publish-to-github passthroughs
#             (--vendor-identity, --filter-repo-bin, --system-email)
#
# EXIT CODES:
#   0   PR/MR open/updated (URL printed) OR nothing to publish (fresh head == destination base head)
#   1   usage / unreadable token / missing dependency / unknown --host
#   2   propagated from publish-to-github.sh (no human-derivable commit)
#   3   propagated from publish-to-github.sh (internal attribution survived — never pushed)
#   4   destination base branch has no head yet — run phase 1 (`lcars approve`) first; this rail only PRs
#   5   git push or destination API call failed
#   6   destination base is NOT an ancestor of the fresh clone — determinism broke; nothing pushed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBLISH_TRANSFORM="$SCRIPT_DIR/publish-to-github.sh"

HOST="github"
DEST_HOST=""
BRANCH="lcars/publish"
BASE="main"
PROJECT="" ; FORGE="" ; FORGE_TOKEN_FILE="" ; DEST_REPO="" ; DEST_TOKEN_FILE="" ; WORK=""
PASSTHROUGH=()

usage() {
  echo "Usage: $0 --project OWNER/NAME --forge URL --forge-token-file FILE \\" >&2
  echo "          --host github|gitlab --dest-repo OWNER/NAME --dest-token-file FILE --work DIR \\" >&2
  echo "          [--dest-host HOST] [--branch lcars/publish] [--base main] [publish-to-github passthroughs]" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --forge) FORGE="$2"; shift 2 ;;
    --forge-token-file) FORGE_TOKEN_FILE="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --dest-repo) DEST_REPO="$2"; shift 2 ;;
    --dest-token-file) DEST_TOKEN_FILE="$2"; shift 2 ;;
    --dest-host) DEST_HOST="$2"; shift 2 ;;
    --work) WORK="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --vendor-identity|--filter-repo-bin|--system-email) PASSTHROUGH+=("$1" "$2"); shift 2 ;;
    *) echo "publish-rail: option inconnue: $1" >&2; usage ;;
  esac
done

[[ -n "$PROJECT" && -n "$FORGE" && -n "$FORGE_TOKEN_FILE" && -n "$DEST_REPO" && -n "$DEST_TOKEN_FILE" && -n "$WORK" ]] || usage
case "$HOST" in
  github) [[ -n "$DEST_HOST" ]] || DEST_HOST="github.com" ;;
  gitlab) [[ -n "$DEST_HOST" ]] || DEST_HOST="gitlab.com" ;;
  *) echo "publish-rail: --host inconnu: '$HOST' (attendu: github|gitlab)" >&2; exit 1 ;;
esac
[[ -r "$DEST_TOKEN_FILE" ]] || { echo "publish-rail: dest-token-file illisible: $DEST_TOKEN_FILE" >&2; exit 1; }
[[ -x "$PUBLISH_TRANSFORM" ]] || { echo "publish-rail: publish-to-github.sh introuvable a cote: $PUBLISH_TRANSFORM" >&2; exit 1; }
for dep in git curl python3; do
  command -v "$dep" >/dev/null 2>&1 || { echo "publish-rail: dependance absente: $dep" >&2; exit 1; }
done
[[ -e "$WORK" ]] && { echo "publish-rail: --work ($WORK) doit etre un chemin neuf (le transform exige un clone frais)" >&2; exit 1; }

DEST_TOKEN="$(cat "$DEST_TOKEN_FILE")"
[[ -n "$DEST_TOKEN" ]] || { echo "publish-rail: dest-token vide ($DEST_TOKEN_FILE)" >&2; exit 1; }
DEST_OWNER="${DEST_REPO%%/*}"

# Token-carrying push URL — per-host username convention over https.
case "$HOST" in
  github) PUSH_URL="https://x-access-token:${DEST_TOKEN}@${DEST_HOST}/${DEST_REPO}.git" ;;
  gitlab) PUSH_URL="https://oauth2:${DEST_TOKEN}@${DEST_HOST}/${DEST_REPO}.git" ;;
esac

urlenc() { python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }
json_get() { python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get(sys.argv[1],"") if isinstance(d,dict) else "")' "$1"; }
json_first() { python3 -c 'import sys,json;a=json.load(sys.stdin);print(a[0].get(sys.argv[1],"") if isinstance(a,list) and a else "")' "$1"; }

# --- Per-host adapter: the ONLY host-specific surface -------------------------------------------
# request_find  -> prints the URL of the existing open PR/MR for BRANCH->BASE, or empty
# request_open  -> creates the PR/MR, prints its URL (or empty on failure)
case "$HOST" in
  github)
    API="https://api.github.com/repos/${DEST_REPO}"
    AUTH_HEADER="Authorization: Bearer ${DEST_TOKEN}"
    request_find() {
      curl -sS -H "$AUTH_HEADER" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
        "${API}/pulls?state=open&base=${BASE}&head=${DEST_OWNER}:${BRANCH}" | json_first html_url
    }
    request_open() {
      local body; body="$(python3 -c 'import json,sys;print(json.dumps({"title":sys.argv[1],"head":sys.argv[2],"base":sys.argv[3],"body":sys.argv[4]}))' \
        "$1" "$BRANCH" "$BASE" "$2")"
      curl -sS -X POST -H "$AUTH_HEADER" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
        -d "$body" "${API}/pulls" | json_get html_url
    }
    ;;
  gitlab)
    # GitLab addresses a project by URL-encoded path; MRs use source_branch/target_branch; PAT auth
    # is the PRIVATE-TOKEN header; the web URL field is web_url.
    PROJ_ENC="$(urlenc "$DEST_REPO")"
    API="https://${DEST_HOST}/api/v4/projects/${PROJ_ENC}"
    AUTH_HEADER="PRIVATE-TOKEN: ${DEST_TOKEN}"
    request_find() {
      curl -sS -H "$AUTH_HEADER" \
        "${API}/merge_requests?state=opened&source_branch=${BRANCH}&target_branch=${BASE}" | json_first web_url
    }
    request_open() {
      local body; body="$(python3 -c 'import json,sys;print(json.dumps({"title":sys.argv[1],"source_branch":sys.argv[2],"target_branch":sys.argv[3],"description":sys.argv[4]}))' \
        "$1" "$BRANCH" "$BASE" "$2")"
      curl -sS -X POST -H "$AUTH_HEADER" -H "Content-Type: application/json" \
        -d "$body" "${API}/merge_requests" | json_get web_url
    }
    ;;
esac

# --- Phase-2 precondition: the destination base must already exist (phase 1 populated it) ----------
if ! git ls-remote --exit-code "$PUSH_URL" "refs/heads/$BASE" >/dev/null 2>&1; then
  echo "publish-rail: $DEST_HOST/$DEST_REPO n'a pas de branche '$BASE' — fais la phase 1 (lcars approve) d'abord." >&2
  echo "  Ce rail ne fait QUE des PR/MR ; il ne peuple jamais la base lui-meme." >&2
  exit 4
fi

# --- Produce the certified-clean clone (author rewrite + internal-attribution scan) ---------------
"$PUBLISH_TRANSFORM" \
  --repo "$PROJECT" --forge "$FORGE" --token-file "$FORGE_TOKEN_FILE" --out "$WORK" \
  "${PASSTHROUGH[@]}"

cd "$WORK"

# --- Determinism gate: the destination base must be an ancestor of the fresh clone's head ----------
git remote add dest "$PUSH_URL"
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

# --- Force-push the rolling branch, then open/leave-updated the single PR/MR -----------------------
if ! git push -q -f dest "HEAD:refs/heads/$BRANCH"; then
  echo "publish-rail: echec du push de $BRANCH vers $DEST_HOST/$DEST_REPO" >&2
  exit 5
fi

EXISTING="$(request_find || true)"
if [[ -n "$EXISTING" ]]; then
  echo "publish-rail: PR/MR actualisee (force-push sur $BRANCH) -> $EXISTING"
  exit 0
fi

TITLE="LCARS publish -> $BASE"
BODY="Publication automatique depuis la forge interne (branche roulante $BRANCH). A relire et merger cote $HOST."
NEW_URL="$(request_open "$TITLE" "$BODY" || true)"
if [[ -z "$NEW_URL" ]]; then
  echo "publish-rail: la PR/MR n'a pas pu etre ouverte (reponse $HOST sans URL)" >&2
  exit 5
fi
echo "publish-rail: PR/MR ouverte -> $NEW_URL"
