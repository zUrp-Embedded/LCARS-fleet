#!/usr/bin/env bash
# SOURCE: bin/forge-cli.sh
# AUTHOR: bob
# STARDATE: 2026-08-20
# STATUS: PROTO-V1 — the SINGLE call surface for talking to an external forge (GitHub / GitLab)
#
# THE AUTH IS NOT OURS. No token is read, stored, passed as an argument or written to a config: the
# auth is the official CLI's own store, outside our process. If something ever needs a token to
# work, that something does not happen here.
#
# No `git push`, no clone, no rewrite either — this file TALKS to the forge, the rails MOVE git
# objects. The first can be exercised read-only against a real forge, the second cannot.
#
# USAGE:
#   forge-cli.sh <verb> --host github|gitlab --dest-host HOST --repo OWNER/NAME [verb args]
#
# VERBS:
#   auth-ok                                   0 = present and authenticated ON THIS HOST
#                                             1 = present but not logged in - 4 = NOT INSTALLED
#   repo-exists                               0 = present · 1 = absent · 2 = undecidable (rights)
#   repo-create      --visibility public|private
#   default-branch                            prints the repository's default branch
#   request-find     --head H --base B        prints the open PR/MR url, or nothing
#   request-open     --head H --base B --title T --body Y     prints the created url
#   request-url      --head H --base B        prints the web "open a PR/MR" url (no CLI needed)
#
# EXIT CODES:
#   0   the verb answered
#   1   usage / unknown host / missing dependency
#   2   `repo-exists`: undecidable (the repo may be there, without the right to see it)
#   3   the CLI FAILED — to be distinguished from "answered empty"
#   4   `auth-ok`: the CLI is NOT INSTALLED — distinct from "installed but logged out", because the
#       two need different gestures ("install it" vs "log in")

set -euo pipefail

# A CLI that hangs on a prompt inside a tty-less BEAM never fails: it blocks. The two forges read
# the same intent through two different variables.
export GIT_TERMINAL_PROMPT=0
export GH_PROMPT_DISABLED=1
export GLAB_NO_PROMPT=1

VERB="${1:-}"; [[ -n "$VERB" ]] || { echo "forge-cli: verbe requis" >&2; exit 1; }
shift

HOST="" ; DEST_HOST="" ; REPO="" ; HEAD="" ; BASE="" ; TITLE="" ; BODY="" ; VISIBILITY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)       HOST="$2"; shift 2 ;;
    --dest-host)  DEST_HOST="$2"; shift 2 ;;
    --repo)       REPO="$2"; shift 2 ;;
    --head)       HEAD="$2"; shift 2 ;;
    --base)       BASE="$2"; shift 2 ;;
    --title)      TITLE="$2"; shift 2 ;;
    --body)       BODY="$2"; shift 2 ;;
    --visibility) VISIBILITY="$2"; shift 2 ;;
    *) echo "forge-cli: option inconnue: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$HOST" && -n "$REPO" ]] || { echo "forge-cli: --host et --repo sont requis" >&2; exit 1; }

case "$HOST" in
  github) CLI="gh";   [[ -n "$DEST_HOST" ]] || DEST_HOST="github.com" ;;
  gitlab) CLI="glab"; [[ -n "$DEST_HOST" ]] || DEST_HOST="gitlab.com" ;;
  *) echo "forge-cli: --host inconnu: '$HOST' (github|gitlab)" >&2; exit 1 ;;
esac

# HOST QUALIFICATION — the point of this whole file.
GH_REPO="$DEST_HOST/$REPO"
export GITLAB_HOST="$DEST_HOST"

need_cli() {
  command -v "$CLI" >/dev/null 2>&1 || {
    echo "forge-cli: $CLI absent — ce verbe l'exige (« $CLI auth login » apres installation)" >&2
    exit 1; }
}

cmd_auth_ok() {
  command -v "$CLI" >/dev/null 2>&1 || return 4
  "$CLI" auth status --hostname "$DEST_HOST" >/dev/null 2>&1
}

cmd_repo_exists() {
  need_cli
  # ⚠ `out="$(cmd)" ; rc=$?` EST FAUX SOUS `set -e` : l'affectation dont la substitution echoue
  # declenche errexit AVANT que `rc=$?` ne tourne. Le cas « absent » passait vert PAR ACCIDENT, en
  # recevant d'errexit le code que sa propre logique aurait rendu. `|| rc=$?` met la commande en
  # contexte de condition, ou errexit ne s'applique pas.
  local out rc=0
  case "$HOST" in
    github) out="$(gh repo view "$GH_REPO" --json name 2>&1)" || rc=$? ;;
    gitlab) out="$(glab repo view "$REPO" 2>&1)" || rc=$? ;;
  esac
  [[ "$rc" == 0 ]] && return 0
  # Both forges' vocabulary for "this repository does not exist".
  if grep -qiE "could not resolve|not found|404|does not exist" <<<"$out"; then
    return 1
  fi
  echo "forge-cli: existence de $DEST_HOST/$REPO INDECIDABLE — $(head -1 <<<"$out")" >&2
  return 2
}

cmd_repo_create() {
  need_cli
  [[ "$VISIBILITY" == public || "$VISIBILITY" == private ]] \
    || { echo "forge-cli: --visibility public|private requis" >&2; exit 1; }
  case "$HOST" in
    github) gh   repo create "$GH_REPO" "--$VISIBILITY" ;;
    gitlab) glab repo create "$REPO"    "--$VISIBILITY" ;;
  esac
}

cmd_default_branch() {
  need_cli
  case "$HOST" in
    github) gh repo view "$GH_REPO" --json defaultBranchRef --jq '.defaultBranchRef.name // empty' ;;
    gitlab) glab repo view "$REPO" -F json 2>/dev/null \
              | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("default_branch") or "")' ;;
  esac
}

# Here: exit 0 = I could answer (the output may be empty) · exit 3 = I could not.
cmd_request_find() {
  need_cli
  [[ -n "$HEAD" && -n "$BASE" ]] || { echo "forge-cli: --head et --base requis" >&2; exit 1; }
  local out
  case "$HOST" in
    github)
      out="$(gh pr list --repo "$GH_REPO" --head "$HEAD" --base "$BASE" --state open \
               --json url --jq '.[0].url // empty' 2>&1)" || { echo "forge-cli: pr list a ECHOUE — $(head -1 <<<"$out")" >&2; exit 3; }
      ;;
    gitlab)
      out="$(glab mr list --repo "$REPO" --source-branch "$HEAD" --target-branch "$BASE" -F json 2>&1)" \
        || { echo "forge-cli: mr list a ECHOUE — $(head -1 <<<"$out")" >&2; exit 3; }
      out="$(python3 -c 'import sys,json
try:
    a = json.loads(sys.stdin.read() or "[]")
except Exception:
    sys.exit(3)
print(a[0]["web_url"] if isinstance(a, list) and a else "")' <<<"$out")" || exit 3
      ;;
  esac
  printf '%s' "$out"
}

# BY THE TIME WE GET HERE THE REQUEST IS CREATED; only its URL is uncertain. Never report a failure
# for a request that exists — the operator would open a second one.
resolve_request_url() { # <create output> -> url on stdout, exit 3 if unresolvable
  local url
  url="$(grep -oE 'https?://[^[:space:]]+' <<<"${1:-}" | tail -1 || true)"
  [[ -n "$url" ]] && { printf '%s' "$url"; return 0; }

  for _ in $(seq 1 "${FORGE_CLI_URL_RETRIES:-3}"); do
    url="$(cmd_request_find || true)"
    [[ -n "$url" ]] && { printf '%s' "$url"; return 0; }
    sleep "${FORGE_CLI_URL_DELAY:-1}"
  done

  echo "forge-cli: la PR/MR a ete CREEE mais son URL reste introuvable — NE PAS en rouvrir une" >&2
  return 3
}

cmd_request_open() {
  need_cli
  [[ -n "$HEAD" && -n "$BASE" && -n "$TITLE" ]] || { echo "forge-cli: --head --base --title requis" >&2; exit 1; }
  local out
  case "$HOST" in
    github)
      out="$(gh pr create --repo "$GH_REPO" --head "$HEAD" --base "$BASE" \
               --title "$TITLE" --body "$BODY" 2>&1)" \
        || { echo "forge-cli: pr create a ECHOUE — $(head -1 <<<"$out")" >&2; exit 3; }
      ;;
    gitlab)
      out="$(glab mr create --repo "$REPO" --source-branch "$HEAD" --target-branch "$BASE" \
               --title "$TITLE" --description "$BODY" --yes 2>&1)" \
        || { echo "forge-cli: mr create a ECHOUE — $(head -1 <<<"$out")" >&2; exit 3; }
      ;;
  esac
  resolve_request_url "$out"
}

# THE PRE-FILLED WEB URL — Tier 2, no CLI and no network call: a stable url scheme.
cmd_request_url() {
  [[ -n "$HEAD" && -n "$BASE" ]] || { echo "forge-cli: --head et --base requis" >&2; exit 1; }
  case "$HOST" in
    github) printf 'https://%s/%s/compare/%s...%s?expand=1' "$DEST_HOST" "$REPO" "$BASE" "$HEAD" ;;
    # %5B/%5D = the [ ] of merge_request[source_branch], encoded so the query string is well-formed.
    gitlab) printf 'https://%s/%s/-/merge_requests/new?merge_request%%5Bsource_branch%%5D=%s&merge_request%%5Btarget_branch%%5D=%s' \
              "$DEST_HOST" "$REPO" "$HEAD" "$BASE" ;;
  esac
}

case "$VERB" in
  auth-ok)        cmd_auth_ok ;;
  repo-exists)    cmd_repo_exists ;;
  repo-create)    cmd_repo_create ;;
  default-branch) cmd_default_branch ;;
  request-find)   cmd_request_find ;;
  request-open)   cmd_request_open ;;
  request-url)    cmd_request_url ;;
  *) echo "forge-cli: verbe inconnu '$VERB' (auth-ok|repo-exists|repo-create|default-branch|request-find|request-open|request-url)" >&2; exit 1 ;;
esac
