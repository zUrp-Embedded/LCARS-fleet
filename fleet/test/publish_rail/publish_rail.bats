#!/usr/bin/env bats
# SOURCE: test/publish_rail/publish_rail.bats
# AUTHOR: consultant
# STARDATE: 2026-08-14
# STATUS: bats tests for bin/publish-rail.sh — the fail-closed preconditions (gh/glab auth model)
#
# V2 hands auth to the forge CLIs (gh/glab) — so there is NO token for this rail to leak, and the old
# token-off-argv regression is MOOT (deleted with the token layer). V2.1 makes the CLI OPTIONAL: absent
# or logged-out, the rail degrades to Tier 2 (push via the wired helper + a printed PR/MR URL) instead
# of refusing. What remains to pin: the guards that refuse BEFORE the destructive work — usage, unknown
# --host, non-fresh --work, "base absent -> exit 4, nothing pushed" for both hosts — AND that a
# logged-out CLI is NO LONGER a gate (it falls through to the base check, not exit 1). The push + PR/MR
# and the Tier-2 URL print need a live helper + git-filter-repo and are operator-exercised.
#
# git + gh + glab are stubbed on PATH: `command -v` finds them, `auth status` is driven by
# STUB_AUTHED, and git ls-remote by STUB_BASE_PRESENT — the preconditions become checkable offline.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../bin/publish-rail.sh"
  TMP="$(mktemp -d)"
  BIN="$TMP/bin"; mkdir -p "$BIN"
  FORGE_TOKEN_FILE="$TMP/forge.token"; echo "forgetok" > "$FORGE_TOKEN_FILE"

  cat > "$BIN/git" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "ls-remote" ]]; then
  [[ "${STUB_BASE_PRESENT:-0}" == "1" ]] && exit 0 || exit 2
fi
exit 0
STUB
  # gh/glab: `auth status` succeeds unless STUB_AUTHED=0. Nothing else is reached in these tests.
  for cli in gh glab; do
    cat > "$BIN/$cli" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "auth" && "$2" == "status" ]]; then
  [[ "${STUB_AUTHED:-1}" == "1" ]] && exit 0 || exit 1
fi
exit 0
STUB
    chmod +x "$BIN/$cli"
  done
  chmod +x "$BIN/git"
  export PATH="$BIN:$PATH"
}

teardown() { rm -rf "$TMP"; }

run_rail() {  # run_rail HOST [extra args...]
  local host="$1"; shift
  run "$SCRIPT" \
    --project fleet/demo --forge http://forge --forge-token-file "$FORGE_TOKEN_FILE" \
    --host "$host" --dest-repo owner/Demo --work "$TMP/work" "$@"
}

@test "missing required arg -> usage (exit 1)" {
  run "$SCRIPT" --project fleet/demo --forge http://forge
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "unknown --host -> exit 1" {
  run "$SCRIPT" \
    --project fleet/demo --forge http://forge --forge-token-file "$FORGE_TOKEN_FILE" \
    --host bitbucket --dest-repo owner/Demo --work "$TMP/work"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--host inconnu"* ]]
}

@test "CLI not authenticated is NO LONGER a gate — degrades to Tier 2, reaches the base check" {
  # V2.1 loosening: a logged-out CLI must not short-circuit to exit 1. With the base also absent, the
  # rail lands on exit 4 (the phase-1 precondition) — proof it fell through the auth check, not stopped.
  STUB_AUTHED=0 STUB_BASE_PRESENT=0 run_rail github
  [ "$status" -eq 4 ]
  [[ "$output" == *"Tier 2"* ]]
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
