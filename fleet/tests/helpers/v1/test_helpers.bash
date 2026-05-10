#!/bin/bash
# test_helpers.bash — Shared setup/teardown for all bats tests
#
# PURPOSE : Create test filesystem, load mocks, provide utility functions.
# USAGE   : In each .bats file:
#             setup()    { source "$BATS_TEST_DIRNAME/../helpers/test_helpers.bash"; _setup; }
#             teardown() { _teardown; }

# Resolve helpers directory (works from any .bats location)
HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$HELPERS_DIR" rev-parse --show-toplevel)"

_setup() {
    # bats provides BATS_TEST_TMPDIR — unique per test, auto-cleaned

    # --- Load bats libs (order: support first, assert depends on it) ---
    load "$REPO_ROOT/fleet/tests/.bats/bats-support/load.bash"
    load "$REPO_ROOT/fleet/tests/.bats/bats-assert/load.bash"
    load "$REPO_ROOT/fleet/tests/.bats/bats-file/load.bash"

    # --- Create test filesystem ---
    mkdir -p "$BATS_TEST_TMPDIR"/{lcars/fleet,lcars/directives,lcars/docs,lcars/knowledge}
    mkdir -p "$BATS_TEST_TMPDIR"/homes/{starfleet,architect,engineer,dev,qualifier,reviewer}
    mkdir -p "$BATS_TEST_TMPDIR"/handoffs
    mkdir -p "$BATS_TEST_TMPDIR"/fleet-state
    mkdir -p "$BATS_TEST_TMPDIR"/ready-room/{inbox,outbox}
    mkdir -p "$BATS_TEST_TMPDIR"/spool/inbox/{starfleet,architect,engineer,dev,qualifier,reviewer}
    mkdir -p "$BATS_TEST_TMPDIR"/spool/inbox/{starfleet,engineer,dev}/{.processing,.consumed}
    mkdir -p "$BATS_TEST_TMPDIR"/spool/outbox
    mkdir -p "$BATS_TEST_TMPDIR"/spool/pending-wakes
    mkdir -p "$BATS_TEST_TMPDIR"/bin
    mkdir -p "$BATS_TEST_TMPDIR"/fixtures

    # --- Copy fixtures ---
    if [[ -d "$REPO_ROOT/fleet/tests/fixtures" ]]; then
        cp -r "$REPO_ROOT/fleet/tests/fixtures/"* "$BATS_TEST_TMPDIR/fixtures/" 2>/dev/null || true
    fi

    # --- Load mocks (order matters: fleet_env first, it sets paths) ---
    source "$HELPERS_DIR/mock_fleet_env.bash"
    source "$HELPERS_DIR/mock_tmux.bash"
    source "$HELPERS_DIR/mock_yq.bash"
    source "$HELPERS_DIR/mock_claude.bash"

    # --- Make fleet scripts accessible in PATH ---
    # Tests that need real scripts can source them directly.
    # This PATH addition lets scripts find each other via `command -v`.
    export PATH="$BATS_TEST_TMPDIR/bin:$REPO_ROOT/fleet:$PATH"
}

_teardown() {
    # bats auto-cleans BATS_TEST_TMPDIR — nothing to do.
    # This function exists for future cleanup if needed.
    :
}
