#!/usr/bin/env bats
# test_fleet_update.bats — Unit tests for fleet/fleet-update.sh
#
# fleet-update.sh runs with sudo + git pull — can't test the full path
# in unit tests. We test: --help, --dry-run, --json, error paths.
# Integration tests (actual pull+deploy) are separate.

# ============================================================
# Setup / Teardown
# ============================================================

setup() {
    HELPERS_DIR="$(cd "$(dirname "$(dirname "$BATS_TEST_DIRNAME")")/helpers/v1" && pwd)"
    REPO_ROOT="$(cd "$HELPERS_DIR/../.." && pwd)"
    load "$REPO_ROOT/tests/.bats/bats-support/load.bash"
    load "$REPO_ROOT/tests/.bats/bats-assert/load.bash"

    SUT="$REPO_ROOT/fleet/v1/fleet-update.sh"
    command -v yq &>/dev/null || skip "yq not installed"
    # fleet-update needs full fleet environment (fleet.yaml, /local/LCARS, homes)
    # Skip in CI where fleet is not deployed
    [[ -f "/local/LCARS/fleet/fleet.yaml" ]] || [[ -f "$HOME/.lcars/fleet/fleet.yaml" ]] || skip "fleet environment not deployed (CI)"
}

# ============================================================
# --help
# ============================================================

@test "fleet-update --help: exits 0 with description" {
    run bash "$SUT" --help
    assert_success
    assert_output --partial "pull LCARS runtime"
}

# ============================================================
# --dry-run (safe — no sudo, no git pull)
# ============================================================

@test "fleet-update --dry-run: exits 0 without pulling" {
    run bash "$SUT" --dry-run
    assert_success
    assert_output --partial "dry-run"
}

# ============================================================
# --json (implies --dry-run — safe)
# ============================================================

@test "fleet-update --json: outputs valid JSON" {
    run bash "$SUT" --json
    assert_success
    echo "$output" | python3 -m json.tool > /dev/null
}

@test "fleet-update --json: contains required keys" {
    run bash "$SUT" --json
    assert_success
    local missing
    missing=$(echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
required = ['runtime','branch','commit','fleet_user','deploy',
    'provision_system','provision_users','deploy_exists','is_git_repo']
missing = [k for k in required if k not in d]
if missing: print(' '.join(missing))
")
    [[ -z "$missing" ]] || fail "Missing keys: $missing"
}

@test "fleet-update --json: commit is a short hash" {
    run bash "$SUT" --json
    assert_success
    local commit
    commit=$(echo "$output" | python3 -c "import sys,json; print(json.load(sys.stdin)['commit'])")
    # Short hash: 7-12 hex chars
    [[ "$commit" =~ ^[0-9a-f]{7,12}$ ]] || fail "Bad commit hash: $commit"
}

@test "fleet-update --json: is_git_repo is true" {
    run bash "$SUT" --json
    assert_success
    echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['is_git_repo'] == True, 'expected is_git_repo=true'
"
}

# ============================================================
# Error paths
# ============================================================

@test "fleet-update: unknown flag exits with error" {
    run bash "$SUT" --bogus-flag
    assert_failure
    assert_output --partial "Unknown arg"
}

@test "fleet-update: not a git repo exits with error" {
    # fleet-env.sh resolves LCARS_ROOT from fleet.yaml/cache, overriding env.
    # To test the "not a git repo" path, we need a controlled fleet-env that
    # points LCARS_ROOT to a non-git dir. Skip if we can't isolate.
    # This path is verified manually during install testing.
    skip "requires isolated fleet-env mock (integration test)"
}

# ============================================================
# Regression guard
# ============================================================

@test "fleet-update: shellcheck clean" {
    run shellcheck --exclude=SC1091 "$SUT"
    assert_success
}
