#!/usr/bin/env bash
# SOURCE: bin/publish-rail.sh
# AUTHOR: consultant
# STARDATE: 2026-08-14
# STATUS: PROTO-V2 — phase-2 publish rail: certified forge clone -> external rolling PR/MR, auth by gh/glab
#
# WHAT: takes a certified-clean clone produced by publish-to-github.sh, force-pushes it to a FIXED
# rolling branch (`lcars/publish`) on the EXTERNAL destination, and opens (or leaves updated) exactly
# ONE change request (GitHub PR / GitLab MR) against the base. Prints its URL. It NEVER pushes the
# destination base branch directly — that is phase 1 (`lcars approve`, host-side, human gate).
#
# AUTH IS NOT OURS, and that is the whole point of V2. `gh` (GitHub) and `glab` (GitLab) are the
# OFFICIAL CLIs of the two forges, already the wired git credential helpers on this box. This rail
# therefore NEVER reads, stores, or passes an external token: `git push`/`fetch`/`ls-remote` get their
# credential from the helper, and the change request is opened by `gh pr create` / `glab mr create`
# under the CLI's own auth. No token file, no `extraheader`, no curl. The operator authenticates once
# with `gh auth login` / `glab auth login`; rotating or revoking a token is a CLI gesture, not ours.
# (V1 hand-rolled a token layer — extraheader + curl — and a security review had to close its leaks;
# V2 deletes the layer instead of guarding it.)
#
# GIT_TERMINAL_PROMPT=0 so a MISSING/expired credential fails LOUD instead of hanging on a prompt
# (a headless BEAM has nobody to answer). `gh auth status` / `glab auth status` diagnose it.
#
# WHY A ROLLING BRANCH + ONE PR/MR: the diff base is the destination base's real head, so the request
# always carries "internal main - external main" = everything pending. A new publish force-updates the
# same branch; the single open request stays current; merging it empties it.
# Ref: work/beyond_#6/chantier-publication-github-2026-08-14.
#
# THE DETERMINISM INVARIANT, load-bearing: publish-to-github.sh rewrites EVERY SHA (one-way filter-repo
# pass). This rail is only coherent if that rewrite is DETERMINISTIC — same source commit => same
# rewritten SHA each pass. Then commits already on the destination base reappear with the SAME SHAs in
# the fresh clone, so the base IS an ancestor of it and the diff is only the new commits. The rail does
# NOT trust that: it VERIFIES the base is an ancestor of the fresh clone and REFUSES (exit 6) otherwise,
# rather than force-pushing an unrelated history into a baseless request. If exit 6 fires, the rewrite
# is not deterministic; do not "fix" it by dropping the check.
#
# DEPENDENCY: git, publish-to-github.sh (co-located, needs git-filter-repo), and the destination's CLI
# (`gh` for github, `glab` for gitlab) authenticated. All host-side.
#
# USAGE:
#   publish-rail.sh --project fleet/lcars-fleet --forge http://localhost:3000 \
#       --forge-token-file /home/private/system.gitea_token \
#       --host github --dest-repo lordzurp/LCARS-fleet --work /tmp/pub-lcars-fleet
#   Optional: --host gitlab (default github) · --dest-host HOST (default github.com / gitlab.com;
#             set it for Enterprise / self-hosted) · --branch lcars/publish · --base main ·
#             publish-to-github passthroughs (--vendor-identity, --filter-repo-bin, --system-email)
#
# EXIT CODES:
#   0   PR/MR open/updated (URL printed) OR nothing to publish (fresh head == destination base head)
#   1   usage / missing dependency / unknown --host / CLI not authenticated
#   2   propagated from publish-to-github.sh (no human-derivable commit)
#   3   propagated from publish-to-github.sh (internal attribution survived — never pushed)
#   4   destination base branch has no head yet — run phase 1 (`lcars approve`) first; this rail only PRs
#   5   git push or the CLI change-request call failed
#   6   destination base is NOT an ancestor of the fresh clone — determinism broke; nothing pushed

set -euo pipefail
export GIT_TERMINAL_PROMPT=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBLISH_TRANSFORM="$SCRIPT_DIR/publish-to-github.sh"

HOST="github"
DEST_HOST=""
BRANCH="lcars/publish"
BASE="main"
PROJECT="" ; FORGE="" ; FORGE_TOKEN_FILE="" ; DEST_REPO="" ; WORK=""
PASSTHROUGH=()

usage() {
  echo "Usage: $0 --project OWNER/NAME --forge URL --forge-token-file FILE \\" >&2
  echo "          --host github|gitlab --dest-repo OWNER/NAME --work DIR \\" >&2
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
    --dest-host) DEST_HOST="$2"; shift 2 ;;
    --work) WORK="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --vendor-identity|--filter-repo-bin|--system-email) PASSTHROUGH+=("$1" "$2"); shift 2 ;;
    *) echo "publish-rail: option inconnue: $1" >&2; usage ;;
  esac
done

[[ -n "$PROJECT" && -n "$FORGE" && -n "$FORGE_TOKEN_FILE" && -n "$DEST_REPO" && -n "$WORK" ]] || usage

# Per-host CLI: the ONLY host-specific surface. It is BOTH the git credential helper (for push/fetch)
# and the change-request opener. gh<->glab are 1:1: `pr`/`mr`, `--base`/`--target-branch`.
case "$HOST" in
  github) CLI="gh";   [[ -n "$DEST_HOST" ]] || DEST_HOST="github.com" ;;
  gitlab) CLI="glab"; [[ -n "$DEST_HOST" ]] || DEST_HOST="gitlab.com" ;;
  *) echo "publish-rail: --host inconnu: '$HOST' (attendu: github|gitlab)" >&2; exit 1 ;;
esac
[[ -x "$PUBLISH_TRANSFORM" ]] || { echo "publish-rail: publish-to-github.sh introuvable a cote: $PUBLISH_TRANSFORM" >&2; exit 1; }
for dep in git "$CLI"; do
  command -v "$dep" >/dev/null 2>&1 || { echo "publish-rail: dependance absente: $dep" >&2; exit 1; }
done
# Auth is a precondition, not a runtime surprise: refuse LOUD now rather than fail mid-push.
"$CLI" auth status >/dev/null 2>&1 || {
  echo "publish-rail: $CLI n'est pas authentifie ($DEST_HOST) — fais '$CLI auth login' d'abord." >&2
  exit 1
}
[[ -e "$WORK" ]] && { echo "publish-rail: --work ($WORK) doit etre un chemin neuf (le transform exige un clone frais)" >&2; exit 1; }

DEST_URL="https://${DEST_HOST}/${DEST_REPO}.git"

# --- Per-host change-request adapter (auth = the CLI's own; no token handled here) ----------------
# request_find -> URL of the existing open PR/MR for BRANCH->BASE, or empty. request_open -> creates it.
case "$HOST" in
  github)
    request_find() {
      gh pr list --repo "$DEST_REPO" --head "$BRANCH" --base "$BASE" --state open \
        --json url --jq '.[0].url // empty' 2>/dev/null
    }
    request_open() {  # title body -> url
      gh pr create --repo "$DEST_REPO" --head "$BRANCH" --base "$BASE" --title "$1" --body "$2"
    }
    ;;
  gitlab)
    request_find() {
      glab mr list --repo "$DEST_REPO" --source-branch "$BRANCH" --target-branch "$BASE" -F json 2>/dev/null \
        | python3 -c 'import sys,json;a=json.load(sys.stdin);print(a[0]["web_url"] if isinstance(a,list) and a else "")' 2>/dev/null
    }
    request_open() {  # title body -> url
      glab mr create --repo "$DEST_REPO" --source-branch "$BRANCH" --target-branch "$BASE" \
        --title "$1" --description "$2" --yes 2>&1 | grep -oE 'https?://\S+' | tail -1
    }
    ;;
esac

# --- Phase-2 precondition: the destination base must already exist (phase 1 populated it) ----------
if ! git ls-remote --exit-code "$DEST_URL" "refs/heads/$BASE" >/dev/null 2>&1; then
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

# --- Force-push the rolling branch (credential from the CLI helper), then open/leave-updated the PR/MR
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
  echo "publish-rail: la PR/MR n'a pas pu etre ouverte ($CLI create sans URL)" >&2
  exit 5
fi
echo "publish-rail: PR/MR ouverte -> $NEW_URL"
