#!/usr/bin/env bash
# SOURCE: bin/publish-to-github.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-07
# STATUS: PROTO-V1 — GitHub publish transform: rewrites a forge clone's history for a GitHub mirror
#
# WHY THIS SCRIPT (rather than a refinement of onboard): the work forge (Gitea) carries an INTERNAL
# truth — author=human, co-author=`LCARS-<role>` (Fleet.Credentials.ForgeIdentity, commit gate) — and
# some system commits (onboard/scaffold) are authored by `lcars-system`. That is HONEST for the work
# (the system really did generate the scaffold), but it is NOT what we want to publish: on a GitHub
# mirror the human must own their whole tree (human author everywhere) and the credit goes to the VENDOR
# that did the work — never an internal role, never a hardcoded "Claude", but derived from the active N1
# launcher. `Co-authored-by:` is NOT git-native: it is a message trailer, a GitHub convention, so it can
# be rewritten without lying about anything (a commit has exactly one author; the co-author is a layer
# on top).
#
# MECHANICS: a FRESH clone from the forge (never the work worktree — this is one-way, the SHAs change,
# it is NOT a bidirectional sync), then `git filter-repo`. THREE things happen, not two:
#   0. BEFORE the callback, host-side: scan the clone for the first commit whose committer is NOT the
#      system, and keep that identity (HUMAN_NAME/HUMAN_EMAIL). This pre-scan exists for the root commit
#      alone — see below — and it is the one thing here that can exit non-zero on its own.
#   1. In the callback, for a system-authored commit WITH a human committer: author := committer.
#   2. In the callback, for the Gitea `auto_init` root commit (author AND committer are the system, no
#      human trace at all): author AND committer are both set to the pre-scanned human. This is NOT
#      "author := committer" — the committer is precisely what cannot be trusted on that one commit.
#   3. In the callback, for every commit: rewrite the `Co-authored-by: LCARS-<role> <...@lcars.local>`
#      trailer into `Co-Authored-By: <vendor>`.
# This script NEVER PUSHES to GitHub (a hard project constraint: pushes go to local forges ONLY) — it
# prepares the rewritten clone and prints the publish gesture for the HUMAN to run.
#
# DEPENDENCY: `git-filter-repo` (a Python script, NOT packaged by default here). Install it in a
# dedicated venv or with pipx — NEVER `pip install --break-system-packages`, which defeats the PEP 668
# protection. The runtime error path below prints the exact venv recipe. Override the binary through
# --filter-repo-bin or $FILTER_REPO_BIN when it is off PATH (e.g. /path/to/venv/bin/git-filter-repo).
#
# USAGE:
#   publish-to-github.sh --repo fleet/mon-projet --forge http://localhost:3000 \
#       --token-file /home/private/test/system.gitea_token --out /tmp/mon-projet-gh
#   Options: --vendor-identity FILE (default: bin/claude_launch.identity, co-located with the active N1
#            launcher — NAME=/EMAIL=) · --filter-repo-bin BIN (default: git-filter-repo on PATH, or
#            $FILTER_REPO_BIN) · --system-email EMAIL (default: lcars-system@lcars.local — MUST match
#            Fleet.Credentials.ForgeIdentity.system_email/0, the single authority runtime-side).
#
# EXIT CODES, as they actually are — this runs under `set -euo pipefail` with no trap, so most failures
# propagate the exit status of the command that failed, they are NOT normalised:
#   0   the rewritten clone is ready in --out
#   4   --linearize failed its postconditions (final tree differs, or a merge survived) — do not push
#   1   usage, unreadable token/identity file, --out already exists, or git-filter-repo missing
#   2   ONE case only: no non-system commit in the clone, so the human cannot be derived (the pre-scan)
#   *   anything else is the failing command's own status — `git clone` returns git's (128 on the usual
#       clone errors), the filter-repo subshell returns filter-repo's. Do not read a non-2 failure as
#       "not a clone/filter-repo problem": it is the opposite.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORGE=""
REPO=""
TOKEN_FILE=""
OUT_DIR=""
VENDOR_IDENTITY="$SCRIPT_DIR/claude_launch.identity"
FILTER_REPO_BIN="${FILTER_REPO_BIN:-git-filter-repo}"
SYSTEM_EMAIL="lcars-system@lcars.local"
# D2 — branche à APLATIR en first-parent après la transformation (forme MR canonique, cf. la
# fonction). Vide = off : le miroir publie l'historique tel quel, bulles comprises — elles sont
# GitHub-normales sur un main ; l'aplatissement ne sert que la branche d'une MR upstream (D3).
LINEARIZE=""

usage() {
  echo "Usage: $0 --repo OWNER/NAME --forge URL --token-file FICHIER --out DIR [options]" >&2
  echo "  Options: --vendor-identity F · --filter-repo-bin B · --system-email E · --linearize BRANCHE" >&2
  exit 1
}

# POST-TRANSFORM CERTIFICATION: filter-repo's exit 0 means "the callback ran", NOT "no internal
# attribution survived". A new identity or trailer format the callback does not match would pass
# through silently and be announced as a clone ready to publish. So we SCAN the transformed history
# for any forbidden internal marker (an `@lcars.local` author/committer, a `Co-authored-by: LCARS-<role>`
# trailer, the system email) and REFUSE if one remains — the certification is a real postcondition, not
# a trust in the transform's silence. `system_email` is passed so it is checked even when it equals the
# default. Prints every offending line found; returns non-zero if any.
scan_forbidden_markers() {
  local dir="$1" system_email="$2" hits=0

  # Author/committer emails still internal (the transform should have rewritten every one).
  local ident
  ident="$(cd "$dir" && git log --all --format='%ae%n%ce' | grep -iE '@lcars\.local|'"$(printf '%s' "$system_email" | sed 's/[.[\*^$]/\\&/g')"'' || true)"
  if [[ -n "$ident" ]]; then
    echo "publish-to-github: CERTIFICATION KO — identite interne survivante dans author/committer :" >&2
    printf '  %s\n' "$ident" >&2
    hits=1
  fi

  # Internal co-author trailers still in the messages.
  local trailer
  trailer="$(cd "$dir" && git log --all --format='%B' | grep -iE 'Co-authored-by:\s*LCARS-|@lcars\.local' || true)"
  if [[ -n "$trailer" ]]; then
    echo "publish-to-github: CERTIFICATION KO — trailer interne survivant dans les messages :" >&2
    printf '  %s\n' "$trailer" >&2
    hits=1
  fi

  return "$hits"
}

# D2 (chantier rails, 2026-08-18) — FIRST-PARENT LINEARIZATION, the seam-side flattening.
# WHY: the work forge keeps the TRUE history — a resolved conflict is a merge commit (the bubble is
# the trace, chantier doc 08). GitHub's canonical MR form wants a LINEAR branch, and purists shred
# back-merges in a PR. The two requirements live on two remotes, so the flattening happens HERE, at
# publication, on a COPY — never on the internal record.
# HOW: NOT a rebase (replaying side-branches would resurface the very conflicts the merges
# resolved). Each first-parent commit is REBUILT with `git commit-tree` on its OWN TREE: identical
# content at every step, author/committer/dates/message preserved, and a merge point becomes one
# regular commit carrying its resolution (side-branch content squashed into it — the published FORM;
# the per-commit truth stays on the work forge). Deterministic, zero conflict by construction.
# POSTCONDITIONS, both fail-loud: the new tip's tree is BYTE-IDENTICAL to the old one, and no merge
# commit remains.
linearize_first_parent() { # <dir> <branch>
  local dir="$1" branch="$2" prev="" new c old_tip
  old_tip="$(git -C "$dir" rev-parse "refs/heads/${branch}" 2>/dev/null)"     || { echo "publish-to-github: --linearize: branche inconnue: $branch" >&2; return 1; }

  while IFS= read -r c; do
    new="$(
      GIT_AUTHOR_NAME="$(git -C "$dir" log -1 --format=%an "$c")"       GIT_AUTHOR_EMAIL="$(git -C "$dir" log -1 --format=%ae "$c")"       GIT_AUTHOR_DATE="$(git -C "$dir" log -1 --format=%aD "$c")"       GIT_COMMITTER_NAME="$(git -C "$dir" log -1 --format=%cn "$c")"       GIT_COMMITTER_EMAIL="$(git -C "$dir" log -1 --format=%ce "$c")"       GIT_COMMITTER_DATE="$(git -C "$dir" log -1 --format=%cD "$c")"       git -C "$dir" commit-tree "$c^{tree}" ${prev:+-p "$prev"}         < <(git -C "$dir" log -1 --format=%B "$c")
    )" || return 1
    prev="$new"
  done < <(git -C "$dir" rev-list --first-parent --reverse "$old_tip")

  [[ "$(git -C "$dir" rev-parse "$prev^{tree}")" == "$(git -C "$dir" rev-parse "$old_tip^{tree}")" ]]     || { echo "publish-to-github: linearize: l arbre final DIFFERE de l original — refus" >&2; return 1; }

  git -C "$dir" update-ref "refs/heads/${branch}" "$prev"

  if [[ -n "$(git -C "$dir" rev-list --merges "refs/heads/${branch}")" ]]; then
    echo "publish-to-github: linearize: un commit de merge survit — refus" >&2
    return 1
  fi
}

# Source guard (standard idiom): sourcing loads the functions WITHOUT running the transform — the bats
# suite drives scan_forbidden_markers AND linearize_first_parent directly on fixture repos, without
# git-filter-repo.
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
    *) echo "publish-to-github: option inconnue: $1" >&2; usage ;;
  esac
done

[[ -n "$REPO" && -n "$FORGE" && -n "$TOKEN_FILE" && -n "$OUT_DIR" ]] || usage
[[ -r "$TOKEN_FILE" ]] || { echo "publish-to-github: token-file illisible: $TOKEN_FILE" >&2; exit 1; }
[[ -e "$OUT_DIR" ]] && { echo "publish-to-github: --out ($OUT_DIR) n'est pas un chemin neuf — filter-repo exige un clone FRAIS" >&2; exit 1; }

command -v "$FILTER_REPO_BIN" >/dev/null 2>&1 || {
  echo "publish-to-github: git-filter-repo introuvable ($FILTER_REPO_BIN)." >&2
  echo "  Installe-le dans un venv (PEP 668 bloque le pip global) :" >&2
  echo "    python3 -m venv ~/.venvs/git-filter-repo && ~/.venvs/git-filter-repo/bin/pip install git-filter-repo" >&2
  echo "  Puis relance avec --filter-repo-bin ~/.venvs/git-filter-repo/bin/git-filter-repo" >&2
  exit 1
}

[[ -r "$VENDOR_IDENTITY" ]] || { echo "publish-to-github: fichier vendor illisible: $VENDOR_IDENTITY" >&2; exit 1; }
# shellcheck source=/dev/null
source "$VENDOR_IDENTITY"
[[ -n "${NAME:-}" && -n "${EMAIL:-}" ]] || { echo "publish-to-github: $VENDOR_IDENTITY doit poser NAME= et EMAIL=" >&2; exit 1; }
VENDOR_NAME="$NAME"
VENDOR_EMAIL="$EMAIL"

TOKEN="$(<"$TOKEN_FILE")"

echo "publish-to-github: clone frais $FORGE/$REPO.git → $OUT_DIR"
# Header auth (NEVER the token in the URL or argv — the same mechanism as
# Fleet.Credentials.ForgeAuth.git_env: GIT_CONFIG_KEY/VALUE rather than https://<token>@host, so the
# token does not leak through /proc/<pid>/cmdline).
GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0="http.${FORGE}.extraheader" \
  GIT_CONFIG_VALUE_0="Authorization: token ${TOKEN}" \
  git clone "$FORGE/$REPO.git" "$OUT_DIR"

# A human committer exists on EVERY commit routed through GitOps (onboard/scaffold/work) — EXCEPT the
# very first: Gitea's `auto_init` (POST /repos, "Initial commit") is author=committer=SYSTEM, with no
# human trace in THAT commit at all. So the human cannot be derived from its own committer, and we scan
# the OTHER commits for the first non-system identity (guaranteed to exist: any onboarded project has at
# least one scaffold/work commit with a human committer). This is the pre-scan the header describes as
# step 0, and the only path in this script that exits 2.
HUMAN_LINE="$(cd "$OUT_DIR" && git log --all --format='%cn|%ce' | awk -F'|' -v se="$SYSTEM_EMAIL" '$2 != se {print; exit}')"
[[ -n "$HUMAN_LINE" ]] || { echo "publish-to-github: tous les commits sont au compte lcars-system — l'humain reste inconnu" >&2; exit 2; }
HUMAN_NAME="${HUMAN_LINE%%|*}"
HUMAN_EMAIL="${HUMAN_LINE##*|}"

echo "publish-to-github: passe filter-repo — author lcars-system devient $HUMAN_NAME, co-author role devient $VENDOR_NAME"
# The 5 values cross through the ENVIRONMENT (os.environb, callback side), NEVER through bash
# interpolation into the Python source: an author name is UNCONTROLLED data (git log %cn), and the old
# `${VAR@Q}` produced, on an apostrophe (O'Brien), a bash literal `$'...'` that is INVALID Python —
# a git-filter-repo SyntaxError and an opaque exit 2. The callback is FIXED text (bash single quotes, no
# apostrophe inside it); `os.environb` yields the exact bytes (no decode/re-encode, non-UTF-8 names ok).
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
        # auto_init Gitea (Initial commit): committer is ALSO the system account, no human trace on THIS
        # commit -> fall back to HUMAN_NAME/EMAIL (human identity scanned upstream, outside the callback).
        # NB: this block is a single-quoted bash string -> NO ASCII apostrophe here (one would close the
        # quote - the exact bug class the env-var passing fixes).
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

if [[ -n "$LINEARIZE" ]]; then
  echo "publish-to-github: linearisation first-parent de '$LINEARIZE' (forme MR — arbre final identique, merges aplatis)"
  linearize_first_parent "$OUT_DIR" "$LINEARIZE" || exit 4
fi

# CERTIFY the transform instead of trusting its exit code (see scan_forbidden_markers). A surviving
# internal marker = a broken publish that would leak the internal attribution to GitHub — refuse loud
# (exit 3), the clone is left in place for inspection.
if ! scan_forbidden_markers "$OUT_DIR" "$SYSTEM_EMAIL"; then
  echo "publish-to-github: ARRET — le clone transforme porte encore une attribution interne (voir ci-dessus)." >&2
  echo "  Le clone est laisse dans $OUT_DIR pour inspection ; NE PAS pousser en l'etat." >&2
  exit 3
fi

echo ""
echo "publish-to-github: fin de la passe filter-repo → $OUT_DIR (certifie : zero attribution interne survivante)"
echo "  Les SHA sont tous neufs (passe one-way : ce n'est PAS un sync avec la forge de travail)."
echo "  Geste de publish (ce script ne pousse JAMAIS — le push GitHub est ton geste) :"
echo "    cd $OUT_DIR"
echo "    git remote add github git@github.com:<owner>/<repo>.git"
echo "    git push github main"
