#!/usr/bin/env bats
# SOURCE: test/lcars_publish/lcars_publish.bats
# AUTHOR: consultant
# STARDATE: 2026-08-14
# STATUS: bats tests for `lcars target` (pool) + `lcars approve` (phase-1 gate) fail-closed paths
#
# Covered: the guards that fire BEFORE any clone/push — target-pool validation, target/binding
# resolution, and the forge-config precondition. HOME is redirected to a tmp so ~/.lcars/{targets,
# publish} is controlled; every case dies before publish-to-github.sh (which needs git-filter-repo)
# is ever reached, so no git/forge/network. The real link + initial push + direct push are
# operator-exercised, same split as the rail's bats.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../bin/lcars"
  TMP="$(mktemp -d)"
  export HOME="$TMP"                       # -> ~/.lcars resolves under TMP
  DTOK="$TMP/dest.token"; echo "desttok" > "$DTOK"
}

teardown() { rm -rf "$TMP"; }

@test "target add: missing flags -> exit 1 (usage)" {
  run "$SCRIPT" target add mine --host github
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage"* ]]
}

@test "target add: unknown host -> exit 1" {
  run "$SCRIPT" target add mine --host bitbucket --owner alice --token-file "$DTOK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--host inconnu"* ]]
}

@test "target add: name with a slash -> exit 1 (no path traversal)" {
  run "$SCRIPT" target add "../evil" --host github --owner alice --token-file "$DTOK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"nom invalide"* ]]
}

@test "target add then list: round-trip" {
  run "$SCRIPT" target add mine --host gitlab --owner alice --token-file "$DTOK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"enregistree"* ]]
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
  "$SCRIPT" target add mine --host github --owner alice --token-file "$DTOK" >/dev/null
  run "$SCRIPT" approve fleet/demo --target mine
  [ "$status" -eq 1 ]
  [[ "$output" == *"exige --as"* ]]
}

@test "approve: resolved target but no forge config -> exit 1 (FORGE_BASE_URL absent), nothing pushed" {
  "$SCRIPT" target add mine --host github --owner alice --token-file "$DTOK" >/dev/null
  # No ~/.lcars/fleet_v2.env under this HOME -> the forge precondition refuses before any clone.
  run "$SCRIPT" approve fleet/demo --target mine --as Demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"FORGE_BASE_URL absent"* ]]
}
