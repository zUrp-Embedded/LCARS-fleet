#!/usr/bin/env bats
# test_fleet_inject.bats — Unit tests for fleet/fleet-inject.sh
# Ring 2 kernel. Contract: injects snippet content after handoff anchor.

setup() {
    source "$BATS_TEST_DIRNAME/../helpers/test_helpers.bash"
    _setup

    SANDBOX="$BATS_TEST_TMPDIR/sandbox"
    mkdir -p "$SANDBOX"
    cp "$REPO_ROOT/fleet/fleet-inject.sh" "$SANDBOX/"
    SUT="$SANDBOX/fleet-inject.sh"

    cat > "$SANDBOX/fleet-env.sh" <<'ENVSHIM'
:
ENVSHIM

    HANDOFF="$FLEET_HANDOFFS/${FLEET_INSTANCE}-handoff.md"
    cat > "$HANDOFF" <<'HF'
## STATE
date: 2026-03-28 00:00

## ACTIONS
[ ] Existing task

## DONE
### 2026-03-27 — Old entry
Old work.
HF

    SNIPPET="$BATS_TEST_TMPDIR/snippet.md"
}

teardown() { _teardown; }

# ============================================================
# Nominal — done section
# ============================================================

@test "fleet-inject: done — injects after ## DONE" {
    printf 'Session summary\nDetails here.\n' > "$SNIPPET"
    run bash "$SUT" done "$SNIPPET"
    assert_success
    run grep "Session summary" "$HANDOFF"
    assert_success
}

@test "fleet-inject: done — wraps with timestamp header" {
    printf 'My title\nBody line.\n' > "$SNIPPET"
    run bash "$SUT" done "$SNIPPET"
    assert_success
    run grep -E "^### [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} — My title" "$HANDOFF"
    assert_success
}

@test "fleet-inject: done — body from line 2 onwards" {
    printf 'Title\nLine 2\nLine 3\n' > "$SNIPPET"
    run bash "$SUT" done "$SNIPPET"
    assert_success
    run grep "Line 2" "$HANDOFF"
    assert_success
}

@test "fleet-inject: done — inserted before existing DONE entries" {
    printf 'New entry\nDetails.\n' > "$SNIPPET"
    run bash "$SUT" done "$SNIPPET"
    assert_success
    local line_new line_old
    line_new=$(grep -n "New entry" "$HANDOFF" | head -1 | cut -d: -f1)
    line_old=$(grep -n "Old entry" "$HANDOFF" | head -1 | cut -d: -f1)
    [[ "$line_new" -lt "$line_old" ]]
}

# ============================================================
# Nominal — actions section
# ============================================================

@test "fleet-inject: actions — injects raw lines after ## ACTIONS" {
    printf '[ ] New task one\n[ ] New task two\n' > "$SNIPPET"
    run bash "$SUT" actions "$SNIPPET"
    assert_success
    run grep "New task one" "$HANDOFF"
    assert_success
}

@test "fleet-inject: actions — existing actions preserved" {
    printf '[ ] Added task\n' > "$SNIPPET"
    run bash "$SUT" actions "$SNIPPET"
    assert_success
    run grep "Existing task" "$HANDOFF"
    assert_success
}

# ============================================================
# --file override
# ============================================================

@test "fleet-inject: --file overrides default handoff" {
    local alt="$BATS_TEST_TMPDIR/alt-handoff.md"
    printf '## DONE\n### Old\n' > "$alt"
    printf 'Injected\nBody.\n' > "$SNIPPET"
    run bash "$SUT" done --file "$alt" "$SNIPPET"
    assert_success
    run grep "Injected" "$alt"
    assert_success
}

# ============================================================
# Error handling
# ============================================================

@test "fleet-inject: --help exits 0" {
    run bash "$SUT" --help
    assert_success
    assert_output --partial "NAME"
}

@test "fleet-inject: no section arg — exits 1" {
    run bash "$SUT"
    assert_failure
}

@test "fleet-inject: unknown section — exits 1" {
    printf 'content\n' > "$SNIPPET"
    run bash "$SUT" bogus "$SNIPPET"
    assert_failure
    assert_output --partial "inconnue"
}

@test "fleet-inject: handoff missing — exits 1" {
    rm -f "$HANDOFF"
    printf 'content\n' > "$SNIPPET"
    run bash "$SUT" done "$SNIPPET"
    assert_failure
    assert_output --partial "introuvable"
}

@test "fleet-inject: snippet missing — exits 1" {
    run bash "$SUT" done "/nonexistent/snippet.md"
    assert_failure
    assert_output --partial "introuvable"
}

@test "fleet-inject: snippet empty — exits 1" {
    : > "$SNIPPET"
    run bash "$SUT" done "$SNIPPET"
    assert_failure
    assert_output --partial "vide"
}

@test "fleet-inject: anchor missing in handoff — exits 1" {
    echo "## STATE" > "$HANDOFF"
    printf 'content\n' > "$SNIPPET"
    run bash "$SUT" done "$SNIPPET"
    assert_failure
    assert_output --partial "absent"
}

# ============================================================
# Preserves content
# ============================================================

@test "fleet-inject: preserves STATE section" {
    printf 'New done\nBody.\n' > "$SNIPPET"
    run bash "$SUT" done "$SNIPPET"
    assert_success
    run grep "^## STATE" "$HANDOFF"
    assert_success
}

# ============================================================
# Shellcheck
# ============================================================

@test "fleet-inject: shellcheck clean" {
    if ! command -v shellcheck &>/dev/null; then skip "shellcheck not installed"; fi
    run shellcheck -S warning "$REPO_ROOT/fleet/fleet-inject.sh"
    assert_success
}
