#!/usr/bin/env bats
# SOURCE: test/fleet_v2/fleet_v2.bats
# AUTHOR: consultant (remediation agent, off-fleet session)
# STARDATE: 2026.202
# STATUS: bats tests for bin/fleet_v2 env semantics (maintenance override)
#
# The launcher used to clobber LCARS_BOOT_PERMANENT_AT_START with an unconditional
# export: an operator booting in maintenance (=false) got the permanent pods anyway
# (real spend, forge effects). setup_env must PRESERVE the operator's intent; the
# asymmetry with LCARS_PILOT_STEP (already override-preserving) was the tell.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../bin/fleet_v2"
  TMP_BASE="$(mktemp -d)"
  export HOME="$TMP_BASE"
  mkdir -p "$HOME/.lcars"
  # setup_env fail-louds on a missing forge URL (legitimate guard) — satisfied here.
  export FORGE_BASE_URL="http://forge.test"
}

teardown() { rm -rf "$TMP_BASE"; }

@test "maintenance override SURVIVES setup_env (LCARS_BOOT_PERMANENT_AT_START=false)" {
  run bash -c "export LCARS_BOOT_PERMANENT_AT_START=false; source '$SCRIPT'; setup_env; echo \"flag=\$LCARS_BOOT_PERMANENT_AT_START\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"flag=false"* ]]
}

@test "nominal default stays ON (flag unset -> true)" {
  run bash -c "unset LCARS_BOOT_PERMANENT_AT_START; source '$SCRIPT'; setup_env; echo \"flag=\$LCARS_BOOT_PERMANENT_AT_START\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"flag=true"* ]]
}

@test "the env file's own false is honoured too (operator intent from fleet_v2.env)" {
  echo 'LCARS_BOOT_PERMANENT_AT_START=false' > "$HOME/.lcars/fleet_v2.env"
  run bash -c "source '$SCRIPT'; setup_env; echo \"flag=\$LCARS_BOOT_PERMANENT_AT_START\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"flag=false"* ]]
}

@test "sourcing the launcher never runs the dispatcher (source guard)" {
  run bash -c "source '$SCRIPT'; echo sourced-ok"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sourced-ok"* ]]
}

# --- cmd_start: the claude credentials preflight ---
# The one input no pod can think without. Without the door-side check, `start` looks green and
# every pod then dies in tmux logs nobody reads. These tests pin the refusal AND its escape: a
# guard whose override is untested is a guard that can silently become unbypassable.
# The launch itself is neutralised (dtmux/fleet_up_notice redefined after sourcing) — what is
# under test is the door, not the BEAM.
# ⚠ The stub must ANSWER `has-session` NEGATIVELY. A blanket `dtmux() { :; }` reports a live
# session, cmd_start takes its already-up early return, and every test below passes without ever
# reaching the guard — green, and measuring nothing.
NEUTRALISED_START='dtmux() { [[ "$1" != has-session ]]; }; fleet_up_notice() { echo reached-launch; }; cmd_start'

@test "start REFUSES without claude credentials, and names the identity gesture" {
  run bash -c "source '$SCRIPT'; $NEUTRALISED_START"
  # message first: a death for ANOTHER reason (missing tmux) would also be non-zero
  [[ "$output" == *"credentials claude absentes"* ]]
  [[ "$output" == *"/login"* ]]
  [[ "$output" != *"reached-launch"* ]]
  [ "$status" -ne 0 ]
}

@test "an EMPTY credentials file refuses too (presence is not validity)" {
  mkdir -p "$HOME/.claude"
  : > "$HOME/.claude/.credentials.json"
  run bash -c "source '$SCRIPT'; $NEUTRALISED_START"
  [[ "$output" == *"credentials claude absentes"* ]]
  [ "$status" -ne 0 ]
}

@test "LCARS_START_WITHOUT_CLAUDE=1 passes the door with no credentials (documented escape)" {
  run bash -c "export LCARS_START_WITHOUT_CLAUDE=1; source '$SCRIPT'; $NEUTRALISED_START"
  [[ "$output" != *"credentials claude absentes"* ]]
  [[ "$output" == *"reached-launch"* ]]
}

@test "real credentials pass the door untouched (no escape needed)" {
  mkdir -p "$HOME/.claude"
  echo '{"claudeAiOauth":{"accessToken":"t"}}' > "$HOME/.claude/.credentials.json"
  run bash -c "source '$SCRIPT'; $NEUTRALISED_START"
  [[ "$output" != *"credentials claude absentes"* ]]
  [[ "$output" == *"reached-launch"* ]]
}

# --- cmd_stop: the graceful door of the NOMINAL stop ---
# Real processes and real signals: a fake pane (bash) parenting a fake beam (sleep).
# The tmux stub equates "session alive" with "fake beam alive" — exactly the coupling
# the launcher relies on (the tmux session dies with the BEAM).

make_tmux_stub() {
  mkdir -p "$TMP_BASE/stubs"
  cat > "$TMP_BASE/stubs/tmux-stub" << 'STUB'
#!/usr/bin/env bash
# tmux stand-in for cmd_stop: -S <sock> <command> ...
shift 2
case "$1" in
  has-session)      kill -0 "$(cat "$STUB_STATE/beam.pid" 2>/dev/null)" 2>/dev/null ;;
  display-message)  cat "$STUB_STATE/pane.pid" ;;
  kill-server)      touch "$STUB_STATE/kill-server-called"
                    kill -9 "$(cat "$STUB_STATE/beam.pid" 2>/dev/null)" 2>/dev/null || true ;;
  *) true ;;
esac
STUB
  chmod +x "$TMP_BASE/stubs/tmux-stub"
}

@test "nominal stop is GRACEFUL: SIGTERM reaches the beam, kill-server never fires" {
  export STUB_STATE="$TMP_BASE/state"; mkdir -p "$STUB_STATE"
  make_tmux_stub

  bash -c "echo \$\$ > '$STUB_STATE/pane.pid'; sleep 300 & echo \$! > '$STUB_STATE/beam.pid'; wait" &
  sleep 0.3

  run bash -c "export LCARS_TMUX_BIN='$TMP_BASE/stubs/tmux-stub' STUB_STATE='$STUB_STATE' FLEET_V2_STOP_WAIT=5; source '$SCRIPT'; cmd_stop"
  [ "$status" -eq 0 ]
  [[ "$output" == *"proprement"* ]]
  [ ! -f "$STUB_STATE/kill-server-called" ]
}

@test "a beam that ignores SIGTERM falls back to kill-server after the bounded wait" {
  export STUB_STATE="$TMP_BASE/state"; mkdir -p "$STUB_STATE"
  make_tmux_stub

  bash -c "echo \$\$ > '$STUB_STATE/pane.pid'; bash -c 'trap \"\" TERM; sleep 300' & echo \$! > '$STUB_STATE/beam.pid'; wait" &
  sleep 0.3

  run bash -c "export LCARS_TMUX_BIN='$TMP_BASE/stubs/tmux-stub' STUB_STATE='$STUB_STATE' FLEET_V2_STOP_WAIT=1; source '$SCRIPT'; cmd_stop"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fallback kill"* ]]
  [ -f "$STUB_STATE/kill-server-called" ]
}
