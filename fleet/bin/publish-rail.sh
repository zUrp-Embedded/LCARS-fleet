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
# AUTH IS NOT OURS, and that is the whole point of V2. This rail NEVER reads, stores, or passes an
# external token — under ANY tier. Two tiers, one invariant:
#   TIER 1 (gh/glab, the 90% path, zero recurring friction) — `gh` (GitHub) / `glab` (GitLab), the
#     forges' OFFICIAL CLIs, are the wired git credential helpers AND open the change request
#     (`gh pr create` / `glab mr create`) under their own auth. The operator did `gh auth login` once.
#   TIER 2 (any wired helper — git-credential-oauth, GCM, .netrc, SSH) — the CLI is ABSENT or not
#     logged in. The push still works: `git push` takes its credential from whatever helper the
#     operator wired (his own creds, his call — the homelab-GitLab case). We just cannot open the PR
#     for him, so we PRINT a ready-to-open compare/new-MR URL: "one more click", never "unsupported".
# gh/glab are therefore OPTIONAL, not required. In BOTH tiers no token file, no `extraheader`, no curl,
# nothing token-shaped in an argv or a config we write. (V1 hand-rolled a token layer — extraheader +
# curl — and a security review had to close its leaks; V2 deletes the layer instead of guarding it.)
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
# DEPENDENCY: git (REQUIRED, universal) + publish-to-github.sh (co-located, needs git-filter-repo).
# The destination's CLI (`gh`/`glab`) is OPTIONAL — present+authed enables Tier 1 auto-PR/MR; absent
# degrades to Tier 2 (push via the wired helper + a printed compare/new-MR URL). All host-side.
#
# USAGE:
#   publish-rail.sh --project fleet/lcars-fleet --forge http://localhost:3000 \
#       --forge-token-file /home/private/system.gitea_token \
#       --host github --dest-repo lordzurp/LCARS-fleet --work /tmp/pub-lcars-fleet
#   Optional: --host gitlab (default github) · --dest-host HOST (default github.com / gitlab.com;
#             set it for Enterprise / self-hosted) · --branch lcars/publish · --base main ·
#             publish-to-github passthroughs (--vendor-identity, --filter-repo-bin,
#             --system-email, --linearize BRANCH)
#
# EXIT CODES:
#   0   PR/MR open/updated (Tier 1) OR branch pushed + a ready-to-open URL printed (Tier 2)
#         OR nothing to publish (fresh head == destination base head)
#   1   usage / missing dependency (git / publish-to-github.sh) / unknown --host
#   2   propagated from publish-to-github.sh (no human-derivable commit)
#   3   propagated from publish-to-github.sh (internal attribution survived — never pushed)
#   4   destination base branch has no head yet — run phase 1 (`lcars approve`) first; this rail only PRs
#   5   git push or the CLI change-request call failed
#   6   destination base is NOT an ancestor of the fresh clone — determinism broke; nothing pushed

set -euo pipefail
export GIT_TERMINAL_PROMPT=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBLISH_TRANSFORM="$SCRIPT_DIR/publish-to-github.sh"
# EVERY WORD SPOKEN TO THE EXTERNAL FORGE GOES THROUGH HERE, AND NOWHERE ELSE. This rail carried
# four `gh`/`glab` invocations of its own, none of which qualified the destination host: it pushed
# to the Enterprise instance and talked to github.com.
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
    # `--linearize` WAS MISSING FROM THIS LIST, and that made a documented, tested function
    # (`linearize_first_parent`, publish-to-github.sh:118) reachable by NOBODY: the transform is
    # only ever invoked from here, and this rail dropped the flag on the floor. A capability the
    # script advertises and no path can exercise is a promise the code does not keep.
    --vendor-identity|--filter-repo-bin|--system-email|--linearize) PASSTHROUGH+=("$1" "$2"); shift 2 ;;
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
[[ -x "$FORGE_CLI" ]] || { echo "publish-rail: forge-cli.sh introuvable a cote: $FORGE_CLI" >&2; exit 1; }
# git is the ONLY hard dependency: the push is universal (any wired helper). The CLI is optional.
command -v git >/dev/null 2>&1 || { echo "publish-rail: dependance absente: git" >&2; exit 1; }

# Tier detection (NOT a gate): the CLI enables auto-PR/MR only if it is present AND logged in. Absent
# or logged-out => Tier 2: we push via the wired helper and print a ready-to-open URL instead.
HAS_CLI=0
if "$FORGE_CLI" auth-ok --host "$HOST" --dest-host "$DEST_HOST" --repo "$DEST_REPO"; then
  HAS_CLI=1
else
  echo "publish-rail: $CLI absent/non authentifie ($DEST_HOST) — mode Tier 2 : push via le helper git" >&2
  echo "  cable, puis URL de PR/MR a ouvrir a la main (pour l'auto : '$CLI auth login')." >&2
fi
[[ -e "$WORK" ]] && { echo "publish-rail: --work ($WORK) doit etre un chemin neuf (le transform exige un clone frais)" >&2; exit 1; }

DEST_URL="https://${DEST_HOST}/${DEST_REPO}.git"

# --- Change-request adapter: ONE call surface, host-qualified ------------------------------------
# THIS BLOCK CARRIED FOUR `gh`/`glab` INVOCATIONS OF ITS OWN, and not one of them passed
# `$DEST_HOST` — the rail pushed to the requested host and searched/opened the PR on github.com.
# The qualification now lives in `forge-cli.sh`, the ONLY place in the repository where a forge CLI
# is invoked. What the rail gains on top: `request_find` distinguishes "answered empty" (0) from
# "failed" (3), two states the `|| true` here used to flatten into one.
fc() { "$FORGE_CLI" "$1" --host "$HOST" --dest-host "$DEST_HOST" --repo "$DEST_REPO" "${@:2}"; }
request_find()       { fc request-find --head "$BRANCH" --base "$BASE"; }
request_open()       { fc request-open --head "$BRANCH" --base "$BASE" --title "$1" --body "$2"; }
request_manual_url() { fc request-url  --head "$BRANCH" --base "$BASE"; }

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

# --- Force-push the rolling branch (credential from the wired helper — Tier 1 CLI or Tier 2 own) ----
if ! git push -q -f dest "HEAD:refs/heads/$BRANCH"; then
  echo "publish-rail: echec du push de $BRANCH vers $DEST_HOST/$DEST_REPO" >&2
  exit 5
fi

# --- Tier 2: no CLI to open the request — the push is done, hand back a ready-to-open URL ------------
if [[ "$HAS_CLI" == 0 ]]; then
  echo "publish-rail: branche $BRANCH poussee — ouvre la PR/MR ici -> $(request_manual_url)"
  exit 0
fi

# --- Tier 1: open (or leave-updated) exactly one PR/MR under the CLI's own auth ---------------------
# THE TWO STATES, KEPT APART. `|| true` swallowed a failing `list`: an auth expiring mid-run
# answered empty, we moved on to the creation, that failed, and the message blamed `create` while
# `list` was what gave way. Exit 3 = the helper could not answer; we stop, and we SAY so.
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
