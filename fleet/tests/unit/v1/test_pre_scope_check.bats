#!/usr/bin/env bats
# test_post_scope_check.bats — Unit tests for .claude/hooks/pre-scope-check.sh
#
# Tests per-instance scope enforcement. Each test feeds stdin JSON with a
# tool_input.file_path and verifies the hook allows or blocks based on
# CLAUDE_AGENT_NAME. Contract: hook always exits 0 (never blocks tool),
# stdout contains violation warning iff scope breached.

setup() {
    source "$BATS_TEST_DIRNAME/../helpers/test_helpers.bash"
    _setup

    SUT="$REPO_ROOT/.claude/hooks/pre-scope-check.sh"

    # Ensure jq is available
    command -v jq &>/dev/null || skip "jq not installed"

    # Create instance-name fallback file
    mkdir -p "$BATS_TEST_TMPDIR/.claude"
    echo "test-agent" > "$BATS_TEST_TMPDIR/.claude/instance-name"

    # Override HOME for log isolation
    export HOME="$BATS_TEST_TMPDIR"
    mkdir -p "$BATS_TEST_TMPDIR/.local/log"
}

teardown() {
    _teardown
}

# ── Helper ──────────────────────────────────────────────────────────────────────

# Run the hook with a given instance name and file path
run_scope_check() {
    local instance="$1" path="$2"
    local json
    json=$(printf '{"tool_input":{"file_path":"%s"}}' "$path")
    CLAUDE_AGENT_NAME="$instance" run bash "$SUT" <<< "$json"
}

# ── Empty / missing input ───────────────────────────────────────────────────────

@test "pre-scope-check: empty stdin exits 0 silently" {
    CLAUDE_AGENT_NAME="dev" run bash "$SUT" <<< ""
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

@test "pre-scope-check: JSON without file_path exits 0 silently" {
    CLAUDE_AGENT_NAME="dev" run bash "$SUT" <<< '{"tool_input":{}}'
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

@test "pre-scope-check: JSON with empty file_path exits 0 silently" {
    CLAUDE_AGENT_NAME="dev" run bash "$SUT" <<< '{"tool_input":{"file_path":""}}'
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

# ── Universal rule: triangle strict ─────────────────────────────────────────────

@test "pre-scope-check: any agent writing to /local/LCARS/ is violation" {
    run_scope_check "dev" "/local/LCARS/fleet/fleet-env.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"SCOPE-CHECK"* ]]
    [[ "$output" == *"triangle strict"* ]]
}

@test "pre-scope-check: starfleet writing to /local/LCARS/ is violation" {
    run_scope_check "starfleet" "/local/LCARS/fleet/deploy.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"triangle strict"* ]]
}

@test "pre-scope-check: engineer writing to /local/LCARS/ is violation" {
    run_scope_check "engineer" "/local/LCARS/anything"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"triangle strict"* ]]
}

# ── dev scope ───────────────────────────────────────────────────────────────────

@test "pre-scope-check: dev writing to LCARS working copy is violation" {
    run_scope_check "dev" "/home/projects/LCARS/fleet/fleet-env.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"SCOPE-CHECK"* ]]
    [[ "$output" == *"starfleet-owned"* ]]
}

@test "pre-scope-check: dev writing to own project is OK" {
    run_scope_check "dev" "/home/projects/my-app/src/main.py"
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

@test "pre-scope-check: dev writing to home is OK" {
    run_scope_check "dev" "/home/dev/.claude/CLAUDE.md"
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

# ── starfleet scope ─────────────────────────────────────────────────────────────

@test "pre-scope-check: starfleet writing to project code is violation" {
    run_scope_check "starfleet" "/home/projects/my-app/src/main.py"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"SCOPE-CHECK"* ]]
    [[ "$output" == *"project code L1"* ]]
}

@test "pre-scope-check: starfleet writing to LCARS working copy is OK" {
    run_scope_check "starfleet" "/home/projects/LCARS/fleet/fleet-env.sh"
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

@test "pre-scope-check: starfleet writing to own home is OK" {
    run_scope_check "starfleet" "/home/starfleet/.local/log/test.log"
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

# ── qualifier scope ─────────────────────────────────────────────────────────────

@test "pre-scope-check: qualifier writing to LCARS is violation" {
    run_scope_check "qualifier" "/home/projects/LCARS/fleet/fleet-send.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"SCOPE-CHECK"* ]]
    [[ "$output" == *"qualifier"* ]]
}

@test "pre-scope-check: qualifier writing to own home is OK" {
    run_scope_check "qualifier" "/home/qualifier/reports/test-report.md"
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

# ── architect scope ─────────────────────────────────────────────────────────────

@test "pre-scope-check: architect writing .sh is violation" {
    run_scope_check "architect" "/home/projects/app/deploy.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"SCOPE-CHECK"* ]]
    [[ "$output" == *"architect FORBIDDEN"* ]]
}

@test "pre-scope-check: architect writing .py is violation" {
    run_scope_check "architect" "/home/projects/app/main.py"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"architect FORBIDDEN"* ]]
}

@test "pre-scope-check: architect writing .c is violation" {
    run_scope_check "architect" "/home/projects/firmware/main.c"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"architect FORBIDDEN"* ]]
}

@test "pre-scope-check: architect writing Makefile is violation" {
    run_scope_check "architect" "/home/projects/app/Makefile"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"architect FORBIDDEN"* ]]
}

@test "pre-scope-check: architect writing CMakeLists.txt is violation" {
    run_scope_check "architect" "/home/projects/app/CMakeLists.txt"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"architect FORBIDDEN"* ]]
}

@test "pre-scope-check: architect writing .md is OK" {
    run_scope_check "architect" "/home/projects/app/docs/architecture.md"
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

@test "pre-scope-check: architect writing .yaml is OK" {
    run_scope_check "architect" "/home/projects/app/config.yaml"
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

# ── engineer scope ──────────────────────────────────────────────────────────────

@test "pre-scope-check: engineer writing to any project is violation" {
    run_scope_check "engineer" "/home/projects/my-app/src/main.py"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"SCOPE-CHECK"* ]]
    [[ "$output" == *"engineer scope"* ]]
}

@test "pre-scope-check: engineer writing to LCARS is also violation" {
    run_scope_check "engineer" "/home/projects/LCARS/fleet/fleet-env.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"engineer scope"* ]]
}

@test "pre-scope-check: engineer writing to own home is OK" {
    run_scope_check "engineer" "/home/engineer/.local/log/dispatch.log"
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

# ── reviewer scope (H-06) ───────────────────────────────────────────────────────

@test "pre-scope-check: reviewer writing to project is violation" {
    run_scope_check "reviewer" "/home/projects/my-app/src/main.py"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"SCOPE-CHECK"* ]]
    [[ "$output" == *"analysis, read-only"* ]]
}

@test "pre-scope-check: reviewer writing to own home is OK" {
    run_scope_check "reviewer" "/home/reviewer/reports/review.md"
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"SCOPE-CHECK"*"Scope boundary violation"* ]]
}

# ── compliance scope (H-06) ─────────────────────────────────────────────────────

@test "pre-scope-check: compliance writing to project is violation" {
    run_scope_check "compliance" "/home/projects/LCARS/fleet/fleet-env.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"analysis, read-only"* ]]
}

# ── documenter scope (H-06) ─────────────────────────────────────────────────────

@test "pre-scope-check: documenter writing .sh is violation" {
    run_scope_check "documenter" "/home/projects/LCARS/fleet/fleet-env.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"SCOPE-CHECK"* ]]
    [[ "$output" == *"documenter scope"* ]]
}

@test "pre-scope-check: documenter writing docs/ is OK" {
    run_scope_check "documenter" "/home/projects/LCARS/docs/readme.md"
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"SCOPE-CHECK"*"Scope boundary violation"* ]]
}

@test "pre-scope-check: documenter writing LCARS non-docs is violation" {
    run_scope_check "documenter" "/home/projects/LCARS/fleet/fleet.yaml"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"LCARS non-docs"* ]]
}

# ── quality scope (H-06) ────────────────────────────────────────────────────────

@test "pre-scope-check: quality writing to non-LCARS project is violation" {
    run_scope_check "quality" "/home/projects/my-app/src/main.py"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"quality scope: LCARS only"* ]]
}

@test "pre-scope-check: quality writing to LCARS is OK" {
    run_scope_check "quality" "/home/projects/LCARS/docs/report.md"
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"SCOPE-CHECK"*"Scope boundary violation"* ]]
}

# ── researcher scope (H-06) ─────────────────────────────────────────────────────

@test "pre-scope-check: researcher writing to project is violation" {
    run_scope_check "researcher" "/home/projects/my-app/data.json"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"researcher scope"* ]]
}

@test "pre-scope-check: researcher writing to own home is OK" {
    run_scope_check "researcher" "/home/researcher/output/report.md"
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"SCOPE-CHECK"*"Scope boundary violation"* ]]
}

# ── consultant scope (H-06) ─────────────────────────────────────────────────────

@test "pre-scope-check: consultant writing to project is violation" {
    run_scope_check "consultant" "/home/projects/LCARS/fleet/fleet-env.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"consultant scope"* ]]
}

@test "pre-scope-check: consultant writing to outbox is OK" {
    run_scope_check "consultant" "/home/ready-room/outbox/audits/report.md"
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"SCOPE-CHECK"*"Scope boundary violation"* ]]
}

# ── PSC-05: unknown instance warning (stderr, not false positive) ────────────────

@test "pre-scope-check: unknown instance emits warning on stderr" {
    run_scope_check "mystery-agent" "/home/projects/anything/file.sh"
    [[ "$status" -eq 0 ]]
    # bats captures both stdout+stderr in $output
    [[ "$output" == *"unrecognized instance"* ]]
}

@test "pre-scope-check: unknown instance no false violation" {
    run_scope_check "mystery-agent" "/home/projects/anything/file.sh"
    [[ "$status" -eq 0 ]]
    # PSC-05: warning goes to stderr, NOT captured by REASON, so no violation block
    [[ "$output" != *"Scope boundary violation"* ]]
}

@test "pre-scope-check: unknown instance still blocked on runtime" {
    run_scope_check "mystery-agent" "/local/LCARS/fleet/env.sh"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"triangle strict"* ]]
}

# ── Logging ─────────────────────────────────────────────────────────────────────

@test "pre-scope-check: violation is logged to scope-violations.log" {
    run_scope_check "dev" "/home/projects/LCARS/fleet/test.sh"
    [[ "$status" -eq 0 ]]
    [[ -f "$BATS_TEST_TMPDIR/.local/log/scope-violations.log" ]]
    grep -q "SCOPE VIOLATION" "$BATS_TEST_TMPDIR/.local/log/scope-violations.log"
    grep -q "dev" "$BATS_TEST_TMPDIR/.local/log/scope-violations.log"
}

@test "pre-scope-check: no log file created when no violation" {
    rm -f "$BATS_TEST_TMPDIR/.local/log/scope-violations.log"
    run_scope_check "dev" "/home/projects/my-app/ok.py"
    [[ "$status" -eq 0 ]]
    [[ ! -f "$BATS_TEST_TMPDIR/.local/log/scope-violations.log" ]] || \
        ! grep -q "my-app" "$BATS_TEST_TMPDIR/.local/log/scope-violations.log"
}

# ── jq dependency ──────────────────────────────────────────────────────────────

@test "pre-scope-check: graceful exit if jq missing" {
    # Create a fake PATH without jq
    local fakepath="$BATS_TEST_TMPDIR/nojq-bin"
    mkdir -p "$fakepath"
    # Copy bash only
    ln -sf "$(command -v bash)" "$fakepath/bash"
    ln -sf "$(command -v cat)" "$fakepath/cat"
    ln -sf "$(command -v printf)" "$fakepath/printf" 2>/dev/null || true

    CLAUDE_AGENT_NAME="dev" run env PATH="$fakepath" bash "$SUT" <<< '{"tool_input":{"file_path":"/local/LCARS/x"}}'
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"jq not found"* ]]
}

# ── Exit code ───────────────────────────────────────────────────────────────────

@test "pre-scope-check: always exits 0 even on violation" {
    run_scope_check "dev" "/local/LCARS/critical/file.sh"
    [[ "$status" -eq 0 ]]
}

# ── PSC-03: unknown instance warning ────────────────────────────────────────────

@test "pre-scope-check: warns on unknown instance identity" {
    unset CLAUDE_AGENT_NAME
    # Remove the fallback file so INSTANCE becomes "unknown"
    rm -f "$BATS_TEST_TMPDIR/.claude/instance-name"
    run bash "$SUT" <<< '{"tool_input":{"file_path":"/home/projects/test/file.py"}}'
    [[ "$status" -eq 0 ]]
    # Warning goes to stderr — bats captures both in $output
    [[ "$output" == *"instance identity unknown"* ]] || [[ "$output" == *"unrecognized instance"* ]]
}

# ── PSC-05: unrecognized instance warning ───────────────────────────────────────

@test "pre-scope-check: warns on unrecognized instance name (stdout)" {
    run_scope_check "new-fancy-agent" "/home/projects/test/file.py"
    [[ "$status" -eq 0 ]]
    # PSC-05 fix: warning now in stdout (visible to agent), not stderr
    [[ "$output" == *"unrecognized instance"* ]]
}

# ── Shellcheck ──────────────────────────────────────────────────────────────────

@test "pre-scope-check: shellcheck clean" {
    run shellcheck -x "$SUT"
    [[ "$status" -eq 0 ]]
}
