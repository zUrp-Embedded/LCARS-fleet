#!/usr/bin/env bats
# SOURCE: test/publish_rail/publish_rail.bats
# AUTHOR: consultant
# STARDATE: 2026-08-14
# STATUS: bats tests for etc/publish-rail.sh — the fail-closed preconditions + host selection
#
# What is covered: the guards that run BEFORE the (destructive, remote-touching) work — argument
# validation, unknown --host, token readability/emptiness, fresh --work, and the phase-2 precondition
# "destination base must already exist" (exit 4), for BOTH github and gitlab. These are the safety
# net: every one refuses without pushing anything. The real push + PR/MR + the determinism gate
# (exit 6) need a live destination + git-filter-repo and are exercised by the operator, not here.
#
# `git` is stubbed on PATH so the ls-remote precondition is controllable without a network. The stub
# is found by `command -v` (deps check passes) and its ls-remote result is driven by STUB_BASE_PRESENT.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../etc/publish-rail.sh"
  TMP="$(mktemp -d)"
  BIN="$TMP/bin"; mkdir -p "$BIN"

  DEST_TOKEN_FILE="$TMP/dest.token"; echo "desttok" > "$DEST_TOKEN_FILE"
  FORGE_TOKEN_FILE="$TMP/forge.token"; echo "forgetok" > "$FORGE_TOKEN_FILE"

  # git stub: ls-remote --exit-code succeeds only when STUB_BASE_PRESENT=1. When STUB_REC is set it
  # records the ls-remote argv + the GIT_CONFIG auth env — the token-handling regression probe.
  cat > "$BIN/git" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "ls-remote" ]]; then
  if [[ -n "${STUB_REC:-}" ]]; then
    printf '%s\n' "$*" > "$STUB_REC/argv"
    printf '%s\n' "${GIT_CONFIG_VALUE_0:-}" > "$STUB_REC/cfgval"
  fi
  [[ "${STUB_BASE_PRESENT:-0}" == "1" ]] && exit 0 || exit 2
fi
exit 0
STUB
  chmod +x "$BIN/git"
  export PATH="$BIN:$PATH"
}

teardown() { rm -rf "$TMP"; }

run_rail() {  # run_rail HOST [extra args...]
  local host="$1"; shift
  run "$SCRIPT" \
    --project fleet/demo --forge http://forge --forge-token-file "$FORGE_TOKEN_FILE" \
    --host "$host" --dest-repo owner/Demo --dest-token-file "$DEST_TOKEN_FILE" --work "$TMP/work" "$@"
}

@test "missing required arg -> usage (exit 1)" {
  run "$SCRIPT" --project fleet/demo --forge http://forge
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "unknown --host -> exit 1" {
  run "$SCRIPT" \
    --project fleet/demo --forge http://forge --forge-token-file "$FORGE_TOKEN_FILE" \
    --host bitbucket --dest-repo owner/Demo --dest-token-file "$DEST_TOKEN_FILE" --work "$TMP/work"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--host inconnu"* ]]
}

@test "unreadable dest-token-file -> exit 1" {
  run "$SCRIPT" \
    --project fleet/demo --forge http://forge --forge-token-file "$FORGE_TOKEN_FILE" \
    --host github --dest-repo owner/Demo --dest-token-file "$TMP/nope.token" --work "$TMP/work"
  [ "$status" -eq 1 ]
  [[ "$output" == *"dest-token-file illisible"* ]]
}

@test "empty dest-token -> exit 1" {
  : > "$DEST_TOKEN_FILE"
  run_rail github
  [ "$status" -eq 1 ]
  [[ "$output" == *"dest-token vide"* ]]
}

@test "existing --work path -> exit 1 (transform needs a fresh clone)" {
  mkdir -p "$TMP/work"
  run_rail github
  [ "$status" -eq 1 ]
  [[ "$output" == *"chemin neuf"* ]]
}

@test "github: base branch absent -> exit 4 (phase 1 first), nothing pushed" {
  STUB_BASE_PRESENT=0 run_rail github
  [ "$status" -eq 4 ]
  [[ "$output" == *"phase 1"* ]]
}

@test "gitlab: base branch absent -> exit 4 (phase 1 first), nothing pushed" {
  STUB_BASE_PRESENT=0 run_rail gitlab
  [ "$status" -eq 4 ]
  [[ "$output" == *"phase 1"* ]]
}

@test "token rides in GIT_CONFIG env, never in the git argv (CRITIQUE regression)" {
  local rec="$TMP/rec"; mkdir -p "$rec"
  printf 'SECRETTOK' > "$DEST_TOKEN_FILE"          # a literal we can grep for
  STUB_REC="$rec" STUB_BASE_PRESENT=0 run_rail github
  [ "$status" -eq 4 ]                              # stopped at the precondition, before any transform
  run cat "$rec/argv"
  [[ "$output" != *"SECRETTOK"* ]]                 # the token is NOT in the git argv (no ps leak)
  [[ "$output" == *"https://github.com/owner/Demo.git"* ]]   # git saw the PLAIN url
  run cat "$rec/cfgval"
  [[ "$output" == "Authorization: Basic "* ]]      # auth is carried by the extraheader env, not the url
}
