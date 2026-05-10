#!/usr/bin/env bats
# test_fleet_plan.bats — Unit tests for fleet/fleet-plan.sh
# Ring 3 kernel. Contract: kanban lifecycle for work/ plans.
# Tests: new, start, list, append (no dispatch dependency).
# done/check/audit require fleet-dispatch → tested separately.

setup() {
    source "$BATS_TEST_DIRNAME/../helpers/test_helpers.bash"
    _setup
    SUT="$REPO_ROOT/fleet/fleet-plan.sh"

    # Create a project root with work/
    PROJECT="$BATS_TEST_TMPDIR/project"
    mkdir -p "$PROJECT/work"/{TODO,doing,done}

    # fleet-plan resolves project by walking up from PWD
    cd "$PROJECT"
}

teardown() {
    cd /
    _teardown
}

# ============================================================
# new
# ============================================================

@test "fleet-plan new: creates plan in TODO/" {
    run bash "$SUT" new test-plan
    assert_success
    assert [ -f "$PROJECT/work/TODO/test-plan.md" ]
}

@test "fleet-plan new: plan has header with date and status TODO" {
    run bash "$SUT" new my-feature
    assert_success
    run grep "Statut.*TODO" "$PROJECT/work/TODO/my-feature.md"
    assert_success
}

@test "fleet-plan new: plan has standard sections" {
    run bash "$SUT" new sections-test
    assert_success
    local plan="$PROJECT/work/TODO/sections-test.md"
    run grep "## Objectif" "$plan"
    assert_success
    run grep "## Livrables" "$plan"
    assert_success
    run grep "## Critères d'acceptance" "$plan"
    assert_success
}

@test "fleet-plan new: duplicate slug — exits 1" {
    bash "$SUT" new dupe > /dev/null 2>&1
    run bash "$SUT" new dupe
    assert_failure
    assert_output --partial "already exists"
}

@test "fleet-plan new: no slug — exits 1" {
    run bash "$SUT" new
    assert_failure
}

# ============================================================
# start
# ============================================================

@test "fleet-plan start: moves plan from TODO to doing" {
    bash "$SUT" new move-me > /dev/null 2>&1
    run bash "$SUT" start move-me
    assert_success
    assert [ ! -f "$PROJECT/work/TODO/move-me.md" ]
    assert [ -f "$PROJECT/work/doing/move-me.md" ]
}

@test "fleet-plan start: updates Statut to doing" {
    bash "$SUT" new status-check > /dev/null 2>&1
    bash "$SUT" start status-check > /dev/null 2>&1
    run grep "Statut.*doing" "$PROJECT/work/doing/status-check.md"
    assert_success
}

@test "fleet-plan start: plan not in TODO — exits 1" {
    run bash "$SUT" start nonexistent
    assert_failure
    assert_output --partial "not found"
}

@test "fleet-plan start: plan already in doing — exits 1" {
    bash "$SUT" new already > /dev/null 2>&1
    bash "$SUT" start already > /dev/null 2>&1
    run bash "$SUT" start already
    assert_failure
    assert_output --partial "already in doing"
}

@test "fleet-plan start: WIP limit warns at 2" {
    bash "$SUT" new wip1 > /dev/null 2>&1
    bash "$SUT" new wip2 > /dev/null 2>&1
    bash "$SUT" new wip3 > /dev/null 2>&1
    bash "$SUT" start wip1 > /dev/null 2>&1
    bash "$SUT" start wip2 > /dev/null 2>&1
    run bash "$SUT" start wip3
    assert_success
    assert_output --partial "WIP limit"
}

# ============================================================
# list
# ============================================================

@test "fleet-plan list: shows all plans" {
    bash "$SUT" new plan-a > /dev/null 2>&1
    bash "$SUT" new plan-b > /dev/null 2>&1
    bash "$SUT" start plan-a > /dev/null 2>&1
    run bash "$SUT" list
    assert_success
    assert_output --partial "plan-a"
    assert_output --partial "plan-b"
    assert_output --partial "doing"
    assert_output --partial "TODO"
}

@test "fleet-plan list: filter by state" {
    bash "$SUT" new only-todo > /dev/null 2>&1
    bash "$SUT" new started > /dev/null 2>&1
    bash "$SUT" start started > /dev/null 2>&1
    run bash "$SUT" list TODO
    assert_success
    assert_output --partial "only-todo"
    refute_output --partial "started"
}

@test "fleet-plan list: empty — shows header only" {
    run bash "$SUT" list
    assert_success
    assert_output --partial "PLAN"
    assert_output --partial "STATE"
}

# ============================================================
# append
# ============================================================

@test "fleet-plan append: adds content to existing plan" {
    bash "$SUT" new appendable > /dev/null 2>&1
    echo "New section content" | bash "$SUT" append appendable > /dev/null 2>&1
    run grep "New section content" "$PROJECT/work/TODO/appendable.md"
    assert_success
}

@test "fleet-plan append: updates Dernière révision" {
    bash "$SUT" new dated > /dev/null 2>&1
    # Modify date to yesterday to detect update
    sed -i 's/Dernière révision.*/Dernière révision** : 2020-01-01/' "$PROJECT/work/TODO/dated.md"
    echo "fresh content" | bash "$SUT" append dated > /dev/null 2>&1
    run grep "Dernière révision.*$(date +%Y)" "$PROJECT/work/TODO/dated.md"
    assert_success
}

@test "fleet-plan append: plan not found — exits 1" {
    run bash -c 'echo "stuff" | bash '"'$SUT'"' append nope'
    assert_failure
    assert_output --partial "not found"
}

@test "fleet-plan append: empty stdin — exits 1" {
    bash "$SUT" new empty-append > /dev/null 2>&1
    run bash "$SUT" append empty-append < /dev/null
    assert_failure
    assert_output --partial "empty stdin"
}

# ============================================================
# --help
# ============================================================

@test "fleet-plan: --help exits 0" {
    run bash "$SUT" --help
    assert_success
    assert_output --partial "NAME"
    assert_output --partial "COMMANDS"
}

@test "fleet-plan: no command — exits 1" {
    run bash "$SUT"
    assert_failure
}

@test "fleet-plan: unknown command — exits 1" {
    run bash "$SUT" bogus
    assert_failure
}

# ============================================================
# Shellcheck
# ============================================================

@test "fleet-plan: shellcheck clean" {
    if ! command -v shellcheck &>/dev/null; then skip "shellcheck not installed"; fi
    run shellcheck -S warning "$SUT"
    assert_success
}
