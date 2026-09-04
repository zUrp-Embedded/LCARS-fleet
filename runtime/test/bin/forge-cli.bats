#!/usr/bin/env bats
# SOURCE: runtime/test/bin/forge-cli.bats
# AUTHOR: bob
# STARDATE: 2026-08-20
# STATUS: bats tests for bin/forge-cli.sh — the single call surface for an external forge
#
# WHAT THESE PIN, AND WHY THEY EXIST. The dialogue with the external forge lived in ELEVEN places
# (seven `gh`/`glab` invocations, four `auth status` probes) and every one carried the same defect:
# the destination host was never passed. `--dest-host` was accepted, was used to build the push URL,
# and reached NO CLI call — the rail pushed to the Enterprise instance and talked to github.com,
# `approve` probed and CREATED the repository on github.com while pushing somewhere else.
#
# Eleven sites, one defect. These witnesses pin the property where it now lives: the helper. They
# TOUCH NO FORGE — `gh`/`glab` are doubled by stubs on the PATH which RECORD THEIR ARGUMENTS to a
# file. What is checked is therefore not "it works" but "the command was called with the host",
# which is the property at stake.

load ../support/refute

setup() {
  SUT="$BATS_TEST_DIRNAME/../../bin/forge-cli.sh"
  [ -x "$SUT" ]
  STUBS="$BATS_TEST_TMPDIR/stubs"; mkdir -p "$STUBS"
  ARGLOG="$BATS_TEST_TMPDIR/args"
  export PATH="$STUBS:$PATH"
}

# A double that logs its arguments and returns whatever we tell it to.
_stub() { # _stub <name> <exit> [stdout]
  cat > "$STUBS/$1" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$ARGLOG"
[[ -n "${3:-}" ]] && printf '%s\n' '${3:-}'
exit ${2}
EOF
  chmod +x "$STUBS/$1"
}

# ─── The host IS qualified: the property eleven sites did not hold ─────────────────────────────

@test "gh: the repository argument carries the HOST, not just OWNER/REPO" {
  _stub gh 0 'master'
  run "$SUT" default-branch --host github --dest-host ghe.example.com --repo acme/widget
  [ "$status" -eq 0 ]
  # THE FORBIDDEN LIE: talking to github.com while pushing to the enterprise instance.
  # `repo view` takes its repository POSITIONALLY, `pr list` via `--repo`: what is pinned is the
  # qualified string, not the flag shape — the host must travel, the syntax may vary.
  grep -q "ghe.example.com/acme/widget" "$ARGLOG"
  refute grep -qE "(^| )acme/widget( |$)" "$ARGLOG"
}

@test "gh: the host is qualified EVEN for github.com (no conditional branch)" {
  # An `if [[ $host != github.com ]]` would be one more path never taken, so one more never tested.
  _stub gh 0 'main'
  run "$SUT" default-branch --host github --dest-host github.com --repo acme/widget
  [ "$status" -eq 0 ]
  grep -q "github.com/acme/widget" "$ARGLOG"
}

@test "glab: the host travels through GITLAB_HOST, which covers EVERY verb" {
  # `--repo` also accepts a full URL on the GitLab side, but the variable covers `auth status` too,
  # where `--repo` does not exist. One mechanism for every verb.
  cat > "$STUBS/glab" <<'EOF'
#!/usr/bin/env bash
printf 'GITLAB_HOST=%s\n' "${GITLAB_HOST:-EMPTY}" >> "$ARGLOG_OUT"
exit 0
EOF
  chmod +x "$STUBS/glab"
  run env ARGLOG_OUT="$ARGLOG" "$SUT" auth-ok --host gitlab --dest-host gitlab.internal.lan --repo grp/proj
  grep -q "GITLAB_HOST=gitlab.internal.lan" "$ARGLOG"
}

# ─── auth-ok: on the target host, never on a global state ──────────────────────────────────────

@test "auth-ok: the probe carries --hostname of the DESTINATION" {
  # Bare, `auth status` exits 1 as soon as ANY host has an issue, and exits 0 as soon as ONE host is
  # fine. The two errors are symmetric and both wrong.
  _stub gh 0
  run "$SUT" auth-ok --host github --dest-host ghe.example.com --repo acme/widget
  [ "$status" -eq 0 ]
  grep -q -- "auth status --hostname ghe.example.com" "$ARGLOG"
}

@test "auth-ok: a missing CLI answers 4 — NOT INSTALLED, distinct from logged out" {
  # TWO REASONS TO ANSWER NO, AND THEY NEED DIFFERENT GESTURES. The box installs neither `gh` nor
  # `glab` (`10-packages.sh`), so "absent" is the majority case on a fresh machine — and telling
  # that operator to run `gh auth login` sends them looking for a setting on a binary they do not
  # have. `glab` is genuinely absent from this test's PATH, which is exactly the state under test.
  run "$SUT" auth-ok --host gitlab --dest-host gitlab.com --repo grp/proj
  [ "$status" -eq 4 ]
}

@test "auth-ok: a CLI present but logged out answers 1 — 'log in', not 'install'" {
  _stub gh 1
  run "$SUT" auth-ok --host github --dest-host github.com --repo acme/widget
  [ "$status" -eq 1 ]
}

@test "auth-ok: neither answer is a hard error — Tier 2 is a supported mode" {
  # A caller that only cares about the tier reads any non-zero as Tier 2 and degrades: the rail
  # still pushes and hands back a URL to open. Only the callers that ADVISE read the difference.
  _stub gh 1
  run "$SUT" auth-ok --host github --dest-host github.com --repo acme/widget
  [ "$status" -ne 0 ]
  [ "$status" -lt 10 ]
  [ -z "$output" ]   # and it stays quiet: degrading is not an incident
}

# ─── request-find: "answered empty" and "failed" are TWO states ────────────────────────────────

@test "request-find: an empty answer -> exit 0 (there is no open PR)" {
  _stub gh 0 ''
  run "$SUT" request-find --host github --dest-host github.com --repo acme/widget --head h --base b
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "request-find: the CLI fails -> exit 3, NEVER an empty answer" {
  # THE DEFECT THIS WITNESS FORBIDS: `EXISTING="$(request_find || true)"` read a failing `list` as
  # "no PR open", moved on to the creation, and the final message blamed `create` while `list` was
  # what gave way. An auth expiring mid-run produced exactly that.
  _stub gh 1 ''
  run "$SUT" request-find --host github --dest-host github.com --repo acme/widget --head h --base b
  [ "$status" -eq 3 ]
}

@test "request-find: an open PR -> its url, exit 0" {
  _stub gh 0 'https://github.com/acme/widget/pull/7'
  run "$SUT" request-find --host github --dest-host github.com --repo acme/widget --head h --base b
  [ "$status" -eq 0 ]
  [[ "$output" == "https://github.com/acme/widget/pull/7" ]]
}

# ─── repo-exists: THREE states, not two ────────────────────────────────────────────────────────

@test "repo-exists: a 404 -> 1 (absent)" {
  _stub gh 1 'GraphQL: Could not resolve to a Repository with the name'
  run "$SUT" repo-exists --host github --dest-host github.com --repo acme/absent
  [ "$status" -eq 1 ]
}

@test "repo-exists: any other error -> 2 (UNDECIDABLE), never 'absent'" {
  # `gh repo view` exits non-zero for "absent" AND for "private, not allowed to see it". Conflated,
  # somebody else's private repository made us proceed to a creation that failed with "name already
  # exists" — a message that teaches nobody anything.
  _stub gh 1 'HTTP 401: Bad credentials'
  run "$SUT" repo-exists --host github --dest-host github.com --repo acme/widget
  [ "$status" -eq 2 ]
}

@test "repo-exists: present -> 0" {
  _stub gh 0 '{"name":"widget"}'
  run "$SUT" repo-exists --host github --dest-host github.com --repo acme/widget
  [ "$status" -eq 0 ]
}

# ─── request-url: the Tier 2 path, with no CLI at all ──────────────────────────────────────────

@test "request-url: no CLI required, and the host is the destination's" {
  run "$SUT" request-url --host github --dest-host ghe.example.com --repo acme/widget --head lcars/publish --base master
  [ "$status" -eq 0 ]
  [[ "$output" == "https://ghe.example.com/acme/widget/compare/master...lcars/publish?expand=1" ]]
}

@test "request-url gitlab: the brackets of merge_request[...] are encoded" {
  run "$SUT" request-url --host gitlab --dest-host gitlab.internal.lan --repo grp/proj --head lcars/publish --base main
  [ "$status" -eq 0 ]
  [[ "$output" == *"merge_request%5Bsource_branch%5D=lcars/publish"* ]]
  [[ "$output" == *"merge_request%5Btarget_branch%5D=main"* ]]
}

# ─── request-open: the most complex verb, and it had NO test at all ────────────────────────────
# By the time the URL is resolved the request IS created; only its address is uncertain. Reporting a
# failure there makes the operator open a SECOND request, which is worse than saying nothing.

setup_open() { export FORGE_CLI_URL_RETRIES=2 FORGE_CLI_URL_DELAY=0; }

@test "request-open github: the url comes from what create printed" {
  setup_open
  _stub gh 0 'https://github.com/acme/widget/pull/9'
  run "$SUT" request-open --host github --dest-host github.com --repo acme/widget       --head h --base b --title T --body Y
  [ "$status" -eq 0 ]
  [[ "$output" == "https://github.com/acme/widget/pull/9" ]]
  grep -q -- "pr create --repo github.com/acme/widget" "$ARGLOG"
}

@test "request-open github: create FAILS -> exit 3, and no url is invented" {
  setup_open
  _stub gh 1 'HTTP 422: A pull request already exists'
  run "$SUT" request-open --host github --dest-host github.com --repo acme/widget       --head h --base b --title T --body Y
  [ "$status" -eq 3 ]
  [[ "$output" != *"http"* ]]
}

@test "request-open: create SUCCEEDS but prints no url -> the CONTRACT is asked, not exit 1" {
  # THE DEFECT THIS FORBIDS: `grep | tail` exits 1 when it matches nothing, and under `pipefail`
  # that became the verb's exit code — 1 means "usage error" in this file's contract, for a request
  # that WAS opened. The re-read is what turns "I did not see the url" into "here it is".
  setup_open
  cat > "$STUBS/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$ARGLOG"
case "\$*" in
  *"pr create"*) echo "Creating pull request..." ;;
  *"pr list"*)   echo "https://github.com/acme/widget/pull/11" ;;
esac
exit 0
EOF
  chmod +x "$STUBS/gh"
  run "$SUT" request-open --host github --dest-host github.com --repo acme/widget       --head h --base b --title T --body Y
  [ "$status" -eq 0 ]
  [[ "$output" == "https://github.com/acme/widget/pull/11" ]]
}

@test "request-open: neither create nor the re-read gives a url -> exit 3, and it SAYS not to reopen" {
  setup_open
  _stub gh 0 ''
  run "$SUT" request-open --host github --dest-host github.com --repo acme/widget       --head h --base b --title T --body Y
  [ "$status" -eq 3 ]
  [[ "$output" == *"CREEE"* ]]
  [[ "$output" == *"NE PAS en rouvrir"* ]]
}

@test "request-open gitlab: create prints nothing usable, so the contract answers" {
  # `glab mr create` has NO json output — measured against the doc. The url can only come from
  # `mr list`, which indexes ASYNCHRONOUSLY: "not indexed yet" and "does not exist" look the same
  # for a second or two, which is why the re-read retries.
  setup_open
  cat > "$STUBS/glab" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$ARGLOG"
case "\$*" in
  *"mr create"*) echo "Creating merge request for h into b" ;;
  *"mr list"*)   echo '[{"web_url":"https://gitlab.com/grp/proj/-/merge_requests/4"}]' ;;
esac
exit 0
EOF
  chmod +x "$STUBS/glab"
  run "$SUT" request-open --host gitlab --dest-host gitlab.com --repo grp/proj       --head h --base b --title T --body Y
  [ "$status" -eq 0 ]
  [[ "$output" == "https://gitlab.com/grp/proj/-/merge_requests/4" ]]
}

# ─── usage refusals ────────────────────────────────────────────────────────────────────────────

@test "an unknown --host is refused, and both valid ones are named" {
  run "$SUT" auth-ok --host bitbucket --dest-host x --repo a/b
  [ "$status" -eq 1 ]
  [[ "$output" == *"github|gitlab"* ]]
}

@test "an unknown verb is refused, and the seven valid ones are named" {
  run "$SUT" fusionne --host github --repo a/b
  [ "$status" -eq 1 ]
  [[ "$output" == *"default-branch"* ]]
  [[ "$output" == *"request-open"* ]]
}
