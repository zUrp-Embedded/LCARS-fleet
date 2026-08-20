#!/usr/bin/env bats
# SOURCE: test/publish_transform/publish_transform.bats
# AUTHOR: consultant (remediation agent, off-fleet session)
# STARDATE: 2026.232
# STATUS: bats tests for bin/publish-transform.sh post-transform certification
#
# filter-repo's exit 0 means "the callback ran", not "no internal attribution survived". These drive
# the extracted scan_forbidden_markers (source guard = no filter-repo needed) on a fixture git repo,
# proving a surviving @lcars.local identity or a LCARS- co-author trailer is REFUSED, and a clean tree
# passes — the certification the script announces is actually checked, not trusted.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../bin/publish-transform.sh"
  source "$SCRIPT"
  TMP="$(mktemp -d)"
  cd "$TMP"
  git init -q .
  git config user.name "Human Name"
  git config user.email "human@example.com"
}

teardown() { rm -rf "$TMP"; }

@test "clean tree (no internal marker) → certification PASSES" {
  git commit -q --allow-empty -m "a normal commit"
  run scan_forbidden_markers "$TMP" "system_starfleet@lcars.local"
  [ "$status" -eq 0 ]
}

@test "a surviving @lcars.local committer → certification FAILS" {
  GIT_COMMITTER_NAME="LCARS-engineer" GIT_COMMITTER_EMAIL="lcars-engineer@lcars.local" \
    git commit -q --allow-empty -m "leaked internal committer"
  run scan_forbidden_markers "$TMP" "system_starfleet@lcars.local"
  [ "$status" -ne 0 ]
  [[ "$output" == *"identite interne survivante"* ]]
}

@test "a surviving LCARS- co-author trailer → certification FAILS" {
  git commit -q --allow-empty -m "$(printf 'work\n\nCo-authored-by: LCARS-reviewer <lcars-reviewer@lcars.local>')"
  run scan_forbidden_markers "$TMP" "system_starfleet@lcars.local"
  [ "$status" -ne 0 ]
  [[ "$output" == *"trailer interne survivant"* ]]
}

@test "sourcing publish-transform.sh never runs the transform (source guard)" {
  run bash -c "source '$SCRIPT'; echo sourced-ok"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sourced-ok"* ]]
}
