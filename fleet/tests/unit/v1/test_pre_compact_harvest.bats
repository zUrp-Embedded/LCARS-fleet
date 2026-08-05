#!/usr/bin/env bats
# test_pre_compact_harvest.bats — Unit tests for .claude/hooks/pre-compact-harvest.sh
#
# Tests the mechanical harvest hook that captures git state before
# auto-compact. Contract: always exits 0, produces a snapshot file,
# appends to handoff via fleet-done.sh, copies to ready-room.

setup() {
    source "$BATS_TEST_DIRNAME/../../helpers/v1/test_helpers.bash"
    _setup

    SUT="$REPO_ROOT/.claude/hooks/pre-compact-harvest.sh"

    # Override HOME for isolation
    export HOME="$BATS_TEST_TMPDIR"
    mkdir -p "$BATS_TEST_TMPDIR/.claude"
    echo "test-agent" > "$BATS_TEST_TMPDIR/.claude/instance-name"
    mkdir -p "$BATS_TEST_TMPDIR/.local/log"

    # Create fake projects dir with a git repo
    export FLEET_PROJECTS_DIR="$BATS_TEST_TMPDIR/projects"
    mkdir -p "$BATS_TEST_TMPDIR/projects/test-project"
    git -C "$BATS_TEST_TMPDIR/projects/test-project" init -q
    git -C "$BATS_TEST_TMPDIR/projects/test-project" config user.email "test@test.com"
    git -C "$BATS_TEST_TMPDIR/projects/test-project" config user.name "Test"
    touch "$BATS_TEST_TMPDIR/projects/test-project/file.txt"
    git -C "$BATS_TEST_TMPDIR/projects/test-project" add .
    git -C "$BATS_TEST_TMPDIR/projects/test-project" commit -q -m "initial commit"

    # Mock fleet-done.sh
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat > "$BATS_TEST_TMPDIR/bin/fleet-done.sh" << 'MOCK'
#!/bin/bash
echo "$1" > "$HOME/.local/log/fleet-done-called.txt"
echo "$2" >> "$HOME/.local/log/fleet-done-called.txt"
MOCK
    chmod +x "$BATS_TEST_TMPDIR/bin/fleet-done.sh"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

    # Create handoff and ready-room dirs
    mkdir -p "/tmp/bats-handoffs-$$"
    mkdir -p "/tmp/bats-readyroom-$$/handoffs"
    export HANDOFF_DIR="/tmp/bats-handoffs-$$"
    export READYROOM_DIR="/tmp/bats-readyroom-$$"
}

teardown() {
    rm -rf "/tmp/bats-handoffs-$$" "/tmp/bats-readyroom-$$"
    rm -f "/tmp/fleet-harvest-test-agent.md"
    rm -f "/tmp/fleet-harvest-unknown.md"
    _teardown
}

# ── Basic operation ─────────────────────────────────────────────────────────────

@test "pre-compact-harvest: exits 0" {
    CLAUDE_AGENT_NAME="test-agent" run bash "$SUT"
    [[ "$status" -eq 0 ]]
}

@test "pre-compact-harvest: calls fleet-done.sh with harvest title" {
    CLAUDE_AGENT_NAME="test-agent" run bash "$SUT"
    [[ "$status" -eq 0 ]]
    [[ -f "$BATS_TEST_TMPDIR/.local/log/fleet-done-called.txt" ]]
    grep -q "Auto-harvest" "$BATS_TEST_TMPDIR/.local/log/fleet-done-called.txt"
}

@test "pre-compact-harvest: captures git branch name" {
    CLAUDE_AGENT_NAME="test-agent" run bash "$SUT"
    [[ "$status" -eq 0 ]]
    grep -q "test-project" "$BATS_TEST_TMPDIR/.local/log/fleet-done-called.txt"
}

@test "pre-compact-harvest: captures commit log" {
    CLAUDE_AGENT_NAME="test-agent" run bash "$SUT"
    [[ "$status" -eq 0 ]]
    grep -q "initial commit" "$BATS_TEST_TMPDIR/.local/log/fleet-done-called.txt"
}

@test "pre-compact-harvest: detects uncommitted changes" {
    echo "new content" > "$BATS_TEST_TMPDIR/projects/test-project/uncommitted.txt"
    CLAUDE_AGENT_NAME="test-agent" run bash "$SUT"
    [[ "$status" -eq 0 ]]
    grep -q "uncommitted.txt" "$BATS_TEST_TMPDIR/.local/log/fleet-done-called.txt" || \
        grep -q "Uncommitted" "$BATS_TEST_TMPDIR/.local/log/fleet-done-called.txt"
}

# ── Cleanup ─────────────────────────────────────────────────────────────────────

@test "pre-compact-harvest: cleans up snippet file" {
    CLAUDE_AGENT_NAME="test-agent" run bash "$SUT"
    [[ "$status" -eq 0 ]]
    [[ ! -f "/tmp/fleet-harvest-test-agent.md" ]]
}

# ── Edge cases ──────────────────────────────────────────────────────────────────

@test "pre-compact-harvest: handles no projects gracefully" {
    rm -rf "$BATS_TEST_TMPDIR/projects/test-project"
    CLAUDE_AGENT_NAME="test-agent" run bash "$SUT"
    [[ "$status" -eq 0 ]]
}

@test "pre-compact-harvest: handles unknown instance" {
    unset CLAUDE_AGENT_NAME
    rm -f "$BATS_TEST_TMPDIR/.claude/instance-name"
    run bash "$SUT"
    [[ "$status" -eq 0 ]]
}

@test "pre-compact-harvest: handles missing fleet-done.sh gracefully" {
    rm -f "$BATS_TEST_TMPDIR/bin/fleet-done.sh"
    CLAUDE_AGENT_NAME="test-agent" run env PATH="/usr/bin:/bin" bash "$SUT"
    [[ "$status" -eq 0 ]]
}

# ── Multiple projects ──────────────────────────────────────────────────────────

@test "pre-compact-harvest: captures multiple projects" {
    # Add a second project
    mkdir -p "$BATS_TEST_TMPDIR/projects/second-project"
    git -C "$BATS_TEST_TMPDIR/projects/second-project" init -q
    git -C "$BATS_TEST_TMPDIR/projects/second-project" config user.email "t@t.com"
    git -C "$BATS_TEST_TMPDIR/projects/second-project" config user.name "T"
    touch "$BATS_TEST_TMPDIR/projects/second-project/x.txt"
    git -C "$BATS_TEST_TMPDIR/projects/second-project" add .
    git -C "$BATS_TEST_TMPDIR/projects/second-project" commit -q -m "second init"

    CLAUDE_AGENT_NAME="test-agent" run bash "$SUT"
    [[ "$status" -eq 0 ]]
    grep -q "test-project" "$BATS_TEST_TMPDIR/.local/log/fleet-done-called.txt"
    grep -q "second-project" "$BATS_TEST_TMPDIR/.local/log/fleet-done-called.txt"
}

# ── Detached HEAD (T-08) ────────────────────────────────────────────────────────

@test "pre-compact-harvest: handles detached HEAD" {
    # Detach HEAD in the test project
    local sha
    sha=$(git -C "$BATS_TEST_TMPDIR/projects/test-project" rev-parse HEAD)
    git -C "$BATS_TEST_TMPDIR/projects/test-project" checkout --detach "$sha" 2>/dev/null

    CLAUDE_AGENT_NAME="test-agent" run bash "$SUT"
    [[ "$status" -eq 0 ]]
    # branch --show-current returns empty on detached HEAD, fallback to "detached"
    grep -q "detached" "$BATS_TEST_TMPDIR/.local/log/fleet-done-called.txt"
}

# ── Handoff absent (PCH-04) ────────────────────────────────────────────────────

@test "pre-compact-harvest: handles missing handoff file gracefully" {
    # Ensure no handoff file exists — the copy to ready-room should just skip
    rm -f "$HANDOFF_DIR/test-agent-handoff.md" 2>/dev/null || true
    CLAUDE_AGENT_NAME="test-agent" run bash "$SUT"
    [[ "$status" -eq 0 ]]
}

# ── Shellcheck ──────────────────────────────────────────────────────────────────

@test "pre-compact-harvest: shellcheck clean" {
    run shellcheck -x "$SUT"
    [[ "$status" -eq 0 ]]
}
