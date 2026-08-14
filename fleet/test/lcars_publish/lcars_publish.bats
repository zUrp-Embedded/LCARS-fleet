#!/usr/bin/env bats
# SOURCE: test/lcars_publish/lcars_publish.bats
# AUTHOR: consultant
# STARDATE: 2026-08-14
# STATUS: bats tests for `lcars target` (pool) + `lcars approve` (phase-1 gate) fail-closed paths
#
# V2: auth is the forge CLI (gh/glab), so a target carries NO token — the pool is host+owner+repo and
# the credential lives in the CLI's own store. Covered: the guards that fire BEFORE any clone/push —
# pool validation, target/binding resolution, CLI-auth precondition, and the forge-config precondition.
# HOME is redirected to a tmp so ~/.lcars/{targets,publish} is controlled; gh/glab are stubbed
# (authenticated) so approve reaches the checks past its CLI gate. The real link + push are
# operator-exercised.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../bin/lcars"
  TMP="$(mktemp -d)"
  export HOME="$TMP"                       # -> ~/.lcars resolves under TMP
  BIN="$TMP/bin"; mkdir -p "$BIN"

  # gh/glab stubs: `auth status` succeeds unless STUB_AUTHED=0 (the CLI-auth precondition probe).
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
  export PATH="$BIN:$PATH"
}

teardown() { rm -rf "$TMP"; }

@test "target add: missing flags -> exit 1 (usage)" {
  run "$SCRIPT" target add mine --host github
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage"* ]]
}

@test "target add: unknown host -> exit 1" {
  run "$SCRIPT" target add mine --host bitbucket --owner alice
  [ "$status" -eq 1 ]
  [[ "$output" == *"--host inconnu"* ]]
}

@test "target add: name with a slash -> exit 1 (no path traversal)" {
  run "$SCRIPT" target add "../evil" --host github --owner alice
  [ "$status" -eq 1 ]
  [[ "$output" == *"nom invalide"* ]]
}

@test "target add then list: round-trip (no token, auth is the CLI)" {
  run "$SCRIPT" target add mine --host gitlab --owner alice
  [ "$status" -eq 0 ]
  [[ "$output" == *"enregistree"* ]]
  [[ "$output" == *"glab auth login"* ]]
  run "$SCRIPT" target list
  [ "$status" -eq 0 ]
  [[ "$output" == *"mine"* ]]
  [[ "$output" == *"gitlab"* ]]
}

@test "approve: no repo -> exit 1 (usage)" {
  run "$SCRIPT" approve
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage"* ]]
}

@test "approve: repo without slash -> exit 1" {
  run "$SCRIPT" approve notaslug
  [ "$status" -eq 1 ]
  [[ "$output" == *"n'est pas un owner/nom"* ]]
}

@test "approve: project not linked and no --target -> exit 1" {
  run "$SCRIPT" approve fleet/demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"pas encore lie"* ]]
}

@test "approve: --target absent from pool -> exit 1" {
  run "$SCRIPT" approve fleet/demo --target ghost --as Demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"absente du pool"* ]]
}

@test "approve: --target without --as -> exit 1" {
  "$SCRIPT" target add mine --host github --owner alice >/dev/null
  run "$SCRIPT" approve fleet/demo --target mine
  [ "$status" -eq 1 ]
  [[ "$output" == *"exige --as"* ]]
}

@test "approve: resolved target but CLI not authenticated -> exit 1 (auth login)" {
  "$SCRIPT" target add mine --host github --owner alice >/dev/null
  STUB_AUTHED=0 run "$SCRIPT" approve fleet/demo --target mine --as Demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"auth login"* ]]
}

@test "approve: authed target but no forge config -> exit 1 (FORGE_BASE_URL absent), nothing pushed" {
  "$SCRIPT" target add mine --host github --owner alice >/dev/null
  # gh stub is authed; no ~/.lcars/fleet_v2.env -> the forge precondition refuses before any clone.
  run "$SCRIPT" approve fleet/demo --target mine --as Demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"FORGE_BASE_URL absent"* ]]
}
