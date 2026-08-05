#!/usr/bin/env bats
# test_build_sp.bats — Unit tests for fleet/system-prompt/build-sp.sh
#
# Ring 0 kernel. Tests validate the INTERFACE contract:
#   Input:  fleet.yaml + sources/ directory
#   Output: <home>/.claude/system-prompt.md per agent

# ============================================================
# Setup / Teardown
# ============================================================

setup() {
    source "$BATS_TEST_DIRNAME/../../helpers/v1/test_helpers.bash"
    _setup

    SUT="$REPO_ROOT/fleet/system-prompt/build-sp.sh"

    # --- Build minimal source tree ---
    SP_DIR="$BATS_TEST_TMPDIR/sp"
    mkdir -p "$SP_DIR/sources/core"
    mkdir -p "$SP_DIR/sources/organisation"
    mkdir -p "$SP_DIR/sources/roles"

    # Anthropic base SP
    echo "# Anthropic SP base" > "$SP_DIR/anthropic-lcars.md"

    # Core sources (numbered for ordering)
    echo "# Axiomes" > "$SP_DIR/sources/core/#0_axiomes.md"
    echo "# General Orders" > "$SP_DIR/sources/core/#1_general-orders.md"

    # Organisation
    echo "# Topologie" > "$SP_DIR/sources/organisation/topologie.md"
    echo "# Infrastructure" > "$SP_DIR/sources/organisation/infrastructure.md"

    # Roles
    echo "# Role: starfleet" > "$SP_DIR/sources/roles/starfleet.md"
    echo "# Role: dev" > "$SP_DIR/sources/roles/dev.md"

    # Protocole (now in user/)
    mkdir -p "$SP_DIR/sources/user"
    echo "# Protocole" > "$SP_DIR/sources/user/protocole.md"

    # Manifest — minimal for tests
    cat > "$SP_DIR/sources/manifest.yaml" <<'MANIFEST'
api_version: 2
blocks:
  anthropic-lcars:
    path: ../anthropic-lcars.md
    position: 1
    target: all
    cacheable: true
    required: true
    separator: "\n\n<!-- === LCARS FLEET — mandatory core rules === -->\n"
  core:
    path: core/#*.md
    type: glob
    sort: alpha
    position: 2
    target: all
    cacheable: true
    required: true
  organisation/topologie:
    path: organisation/topologie.md
    position: 3
    target: [starfleet]
    cacheable: true
    required: false
    separator: "\n<!-- === LCARS FLEET — organisation === -->\n"
  organisation/infrastructure:
    path: organisation/infrastructure.md
    position: 3
    target: [starfleet]
    cacheable: true
    required: false
  protocole:
    path: user/protocole.md
    position: 4
    target: [starfleet]
    cacheable: true
    required: false
  role:
    path: roles/{role}.md
    position: last
    target: self
    cacheable: false
    required: true
MANIFEST

    # --- Build minimal fleet.yaml ---
    cat > "$BATS_TEST_TMPDIR/fleet.yaml" <<'YAML'
fleet:
  version: "6.0.0-test"
instances:
  - role: starfleet
    tier: 0
    scope: boundary-os
    system_prompt:
      - anthropic-lcars
      - core
      - organisation/topologie
      - organisation/infrastructure
  - role: dev
    tier: 2
    scope: code
    system_prompt:
      - anthropic-lcars
      - core
YAML

    # --- Create target home dirs ---
    mkdir -p "$BATS_TEST_TMPDIR/homes/starfleet/.claude"
    mkdir -p "$BATS_TEST_TMPDIR/homes/dev/.claude"

    export FLEET_YAML="$BATS_TEST_TMPDIR/fleet.yaml"
}

teardown() {
    _teardown
}

# ============================================================
# Helper — run build-sp.sh in single-agent mode with test sources
# ============================================================

_run_single() {
    local role="$1" keys="$2"
    mkdir -p "$BATS_TEST_TMPDIR/homes/$role/.claude"
    run env FLEET_YAML="$FLEET_YAML" \
        BUILD_SP_DIR="$SP_DIR" \
        BUILD_SP_SOURCES="$SP_DIR/sources" \
        BUILD_SP_MANIFEST="$SP_DIR/sources/manifest.yaml" \
        bash "$SUT" "$role" "$keys" "$BATS_TEST_TMPDIR/homes/$role"
}

# ============================================================
# Nominal — single-agent mode
# ============================================================

@test "build-sp: single-agent produces output file" {
    _run_single "starfleet" "core"
    assert_success
    assert [ -f "$BATS_TEST_TMPDIR/homes/starfleet/.claude/system-prompt.md" ]
}

@test "build-sp: single-agent core includes all core sources in order" {
    _run_single "starfleet" "core"
    assert_success
    local out="$BATS_TEST_TMPDIR/homes/starfleet/.claude/system-prompt.md"
    # Axiomes before General Orders (numeric sort)
    run grep -n "Axiomes\|General Orders" "$out"
    assert_success
    # Line of Axiomes < line of General Orders
    local line_ax line_go
    line_ax=$(grep -n "Axiomes" "$out" | head -1 | cut -d: -f1)
    line_go=$(grep -n "General Orders" "$out" | head -1 | cut -d: -f1)
    [[ "$line_ax" -lt "$line_go" ]]
}

@test "build-sp: anthropic-lcars key includes base SP" {
    _run_single "starfleet" "anthropic-lcars"
    assert_success
    local out="$BATS_TEST_TMPDIR/homes/starfleet/.claude/system-prompt.md"
    run grep "Anthropic SP base" "$out"
    assert_success
}

@test "build-sp: anthropic-lcars adds LCARS FLEET comment marker" {
    _run_single "starfleet" "anthropic-lcars"
    assert_success
    local out="$BATS_TEST_TMPDIR/homes/starfleet/.claude/system-prompt.md"
    run grep "LCARS FLEET" "$out"
    assert_success
}

@test "build-sp: organisation key includes specified org file" {
    _run_single "starfleet" "organisation/topologie"
    assert_success
    local out="$BATS_TEST_TMPDIR/homes/starfleet/.claude/system-prompt.md"
    run grep "Topologie" "$out"
    assert_success
}

@test "build-sp: organisation header added once for multiple org keys" {
    _run_single "starfleet" "organisation/topologie organisation/infrastructure"
    assert_success
    local out="$BATS_TEST_TMPDIR/homes/starfleet/.claude/system-prompt.md"
    local count
    count=$(grep -c "LCARS FLEET — organisation" "$out")
    [[ "$count" -eq 1 ]]
}

@test "build-sp: role file always appended last (implicit)" {
    _run_single "starfleet" "core"
    assert_success
    local out="$BATS_TEST_TMPDIR/homes/starfleet/.claude/system-prompt.md"
    run grep "Role: starfleet" "$out"
    assert_success
    # Role must be after core content
    local line_core line_role
    line_core=$(grep -n "Axiomes" "$out" | head -1 | cut -d: -f1)
    line_role=$(grep -n "Role: starfleet" "$out" | head -1 | cut -d: -f1)
    [[ "$line_role" -gt "$line_core" ]]
}

@test "build-sp: role file absent — no crash, no role section" {
    _run_single "nonexistent" "core"
    assert_success
    local out="$BATS_TEST_TMPDIR/homes/nonexistent/.claude/system-prompt.md"
    # Should NOT contain role marker
    run grep "LCARS FLEET — role:" "$out"
    assert_failure
}

@test "build-sp: protocole key includes protocole source" {
    _run_single "starfleet" "protocole"
    assert_success
    local out="$BATS_TEST_TMPDIR/homes/starfleet/.claude/system-prompt.md"
    run grep "Protocole" "$out"
    assert_success
}

@test "build-sp: output reports char count and token estimate" {
    _run_single "starfleet" "core"
    assert_success
    assert_output --partial "tokens"
    assert_output --partial "[build-sp] starfleet:"
}

# ============================================================
# Nominal — batch mode
# ============================================================

@test "build-sp: batch mode reads fleet.yaml and iterates instances" {
    # Batch mode hardcodes /home/$role — homes must exist.
    # Create fleet.yaml pointing to test homes that DO exist.
    cat > "$BATS_TEST_TMPDIR/batch-fleet.yaml" <<YAML
fleet:
  version: "6.0.0-test"
instances:
  - role: batchtest1
    tier: 0
    scope: boundary-os
    system_prompt:
      - core
  - role: batchtest2
    tier: 2
    scope: code
    system_prompt:
      - core
YAML
    # Create the homes at /home/ (real filesystem) — skip if no permission
    if [[ ! -w /home ]]; then
        skip "cannot create /home/batchtest* dirs (no write permission)"
    fi
    mkdir -p /home/batchtest1/.claude /home/batchtest2/.claude 2>/dev/null || skip "cannot create test homes"
    run env FLEET_YAML="$BATS_TEST_TMPDIR/batch-fleet.yaml" BUILD_SP_DIR="$SP_DIR" BUILD_SP_SOURCES="$SP_DIR/sources" BUILD_SP_MANIFEST="$SP_DIR/sources/manifest.yaml" bash "$SUT"
    # Cleanup
    rm -rf /home/batchtest1 /home/batchtest2 2>/dev/null || true
    assert_success
    assert_output --partial "[build-sp] batchtest1:"
    assert_output --partial "[build-sp] batchtest2:"
    assert_output --partial "[build-sp] done."
}

# ============================================================
# Error handling
# ============================================================

@test "build-sp: --help exits 0 with man page" {
    run bash "$SUT" --help
    assert_success
    assert_output --partial "NAME"
    assert_output --partial "INTERFACE"
}

@test "build-sp: single-agent with empty role — exits 1" {
    run env FLEET_YAML="$FLEET_YAML" BUILD_SP_DIR="$SP_DIR" BUILD_SP_SOURCES="$SP_DIR/sources" BUILD_SP_MANIFEST="$SP_DIR/sources/manifest.yaml" \
        bash "$SUT" '' 'core' "$BATS_TEST_TMPDIR/homes/dev"
    assert_failure
}

@test "build-sp: single-agent with missing home arg — exits 1" {
    run env FLEET_YAML="$FLEET_YAML" BUILD_SP_DIR="$SP_DIR" bash "$SUT" "dev" "core"
    assert_failure
}

@test "build-sp: batch mode with missing fleet.yaml — exits 1" {
    run env FLEET_YAML="/nonexistent/fleet.yaml" BUILD_SP_DIR="$SP_DIR" bash "$SUT"
    assert_failure
    assert_output --partial "ERROR"
    assert_output --partial "fleet.yaml"
}

@test "build-sp: batch mode with empty fleet.yaml — exits 1" {
    echo "fleet: {}" > "$BATS_TEST_TMPDIR/empty-fleet.yaml"
    run env FLEET_YAML="$BATS_TEST_TMPDIR/empty-fleet.yaml" BUILD_SP_DIR="$SP_DIR" bash "$SUT"
    assert_failure
    assert_output --partial "no instances"
}

@test "build-sp: missing anthropic source — warns, continues" {
    rm -f "$SP_DIR/anthropic-lcars.md"
    _run_single "starfleet" "anthropic-lcars core"
    assert_success
    assert_output --partial "WARN"
    assert_output --partial "missing"
}

@test "build-sp: missing core sources dir — warns" {
    rm -rf "$SP_DIR/sources/core"
    mkdir -p "$SP_DIR/sources/core"  # empty dir
    _run_single "starfleet" "core"
    assert_success
    assert_output --partial "WARN"
    assert_output --partial "no files for glob"
}

@test "build-sp: missing organisation file — warns, continues" {
    _run_single "starfleet" "organisation/nonexistent"
    assert_success
    assert_output --partial "WARN"
    assert_output --partial "missing"
}

@test "build-sp: unknown key in sp_list — warns and continues" {
    _run_single "starfleet" "unknown_key core"
    assert_success
    # unknown_key emits WARN but build continues with remaining keys
    assert_output --partial "WARN"
    assert_output --partial "not found in manifest"
    local out="$BATS_TEST_TMPDIR/homes/starfleet/.claude/system-prompt.md"
    run grep "Axiomes" "$out"
    assert_success
}

# ============================================================
# Contract validation — INTERFACE section accuracy
# ============================================================

@test "build-sp: output file is at <home>/.claude/system-prompt.md" {
    _run_single "dev" "core"
    assert_success
    assert [ -f "$BATS_TEST_TMPDIR/homes/dev/.claude/system-prompt.md" ]
}

@test "build-sp: output is non-empty for valid input" {
    _run_single "starfleet" "anthropic-lcars core"
    assert_success
    local out="$BATS_TEST_TMPDIR/homes/starfleet/.claude/system-prompt.md"
    local size
    size=$(wc -c < "$out")
    [[ "$size" -gt 0 ]]
}

@test "build-sp: full SP chain order — anthropic > core > org > role" {
    _run_single "starfleet" "anthropic-lcars core organisation/topologie"
    assert_success
    local out="$BATS_TEST_TMPDIR/homes/starfleet/.claude/system-prompt.md"
    local l_anth l_core l_org l_role
    l_anth=$(grep -n "Anthropic SP base" "$out" | head -1 | cut -d: -f1)
    l_core=$(grep -n "Axiomes" "$out" | head -1 | cut -d: -f1)
    l_org=$(grep -n "Topologie" "$out" | head -1 | cut -d: -f1)
    l_role=$(grep -n "Role: starfleet" "$out" | head -1 | cut -d: -f1)
    [[ "$l_anth" -lt "$l_core" ]]
    [[ "$l_core" -lt "$l_org" ]]
    [[ "$l_org" -lt "$l_role" ]]
}

# ============================================================
# Shellcheck
# ============================================================

@test "build-sp: shellcheck clean (no warnings/errors)" {
    if ! command -v shellcheck &>/dev/null; then
        skip "shellcheck not installed"
    fi
    run shellcheck -S warning "$SUT"
    assert_success
}
