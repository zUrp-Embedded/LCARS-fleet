#!/usr/bin/env bats
# SOURCE: test/install/install.bats
# AUTHOR: consultant (remediation agent, off-fleet session)
# STARDATE: 2026.202
# STATUS: bats tests for etc/install.sh atomic-swap helpers (crash-safe deploy)
#
# The old install did `rm -rf $PREFIX/rel` then a slow `cp -a`, and overwrote each launcher in place:
# a failure mid-copy lost the last good build, a reader mid-copy saw a mixed assembly. These drive the
# extracted atomic_swap_dir / atomic_swap_file directly (source guard = no mix build) and prove the
# live target is never destroyed before the new one is verified, and the previous is kept.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../etc/install.sh"
  source "$SCRIPT"
  TMP="$(mktemp -d)"
}

teardown() { rm -rf "$TMP"; }

@test "atomic_swap_dir: replaces the live tree and keeps the previous as .prev" {
  mkdir -p "$TMP/src/bin"; printf '#!/bin/sh\nnew\n' > "$TMP/src/bin/lcars_fleet"; chmod +x "$TMP/src/bin/lcars_fleet"
  mkdir -p "$TMP/dst/bin"; printf '#!/bin/sh\nold\n' > "$TMP/dst/bin/lcars_fleet"; chmod +x "$TMP/dst/bin/lcars_fleet"

  run atomic_swap_dir "$TMP/src" "$TMP/dst" "bin/lcars_fleet"
  [ "$status" -eq 0 ]
  grep -q new "$TMP/dst/bin/lcars_fleet"
  grep -q old "$TMP/dst.prev/bin/lcars_fleet"
}

@test "atomic_swap_dir: a build missing its probe FAILS and leaves the live tree untouched" {
  mkdir -p "$TMP/src/bin"    # no lcars_fleet probe inside
  mkdir -p "$TMP/dst/bin"; printf '#!/bin/sh\nold\n' > "$TMP/dst/bin/lcars_fleet"; chmod +x "$TMP/dst/bin/lcars_fleet"

  run atomic_swap_dir "$TMP/src" "$TMP/dst" "bin/lcars_fleet"
  [ "$status" -ne 0 ]
  [[ "$output" == *"build stage invalide"* ]]
  # The live install survived a bad build — the exact loss the old rm -rf caused.
  grep -q old "$TMP/dst/bin/lcars_fleet"
  [ ! -e "$TMP/dst.staging.$$" ]
}

@test "atomic_swap_file: renames the new file over the old (atomic, never truncated)" {
  printf 'NEW\n' > "$TMP/src"
  printf 'OLD\n' > "$TMP/dst"

  run atomic_swap_file "$TMP/src" "$TMP/dst"
  [ "$status" -eq 0 ]
  grep -q NEW "$TMP/dst"
  [ ! -e "$TMP/dst.new.$$" ]
}

@test "build_release runs the GATE before the release (gate->build continuation)" {
  # A fake mix on PATH records the order of subcommands. The release must be TIED to the gate:
  # `mix gate` before `mix release`, on the same tree — the SHA identifies the artifact, the gate
  # qualifies it.
  mkdir -p "$TMP/binstub"
  cat > "$TMP/binstub/mix" << 'MIX'
#!/usr/bin/env bash
echo "$@" >> "$MIX_CALL_LOG"
exit 0
MIX
  chmod +x "$TMP/binstub/mix"

  export MIX_CALL_LOG="$TMP/mix-calls.log"
  PATH="$TMP/binstub:$PATH" run build_release "$TMP"
  [ "$status" -eq 0 ]

  # Order: deps.get, then gate, then release.
  grep -n gate "$MIX_CALL_LOG"
  gate_line="$(grep -n 'gate' "$MIX_CALL_LOG" | head -1 | cut -d: -f1)"
  rel_line="$(grep -n 'release' "$MIX_CALL_LOG" | head -1 | cut -d: -f1)"
  [ -n "$gate_line" ]
  [ -n "$rel_line" ]
  [ "$gate_line" -lt "$rel_line" ]
}

@test "build_release: LCARS_INSTALL_SKIP_GATE=1 skips the gate (explicit escape, stated)" {
  mkdir -p "$TMP/binstub"
  cat > "$TMP/binstub/mix" << 'MIX'
#!/usr/bin/env bash
echo "$@" >> "$MIX_CALL_LOG"
exit 0
MIX
  chmod +x "$TMP/binstub/mix"

  export MIX_CALL_LOG="$TMP/mix-calls.log"
  LCARS_INSTALL_SKIP_GATE=1 PATH="$TMP/binstub:$PATH" run build_release "$TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"gate saute"* ]]
  ! grep -q ' gate$' "$MIX_CALL_LOG"
  grep -q release "$MIX_CALL_LOG"
}

@test "build_release: a RED gate stops the build (no release built)" {
  mkdir -p "$TMP/binstub"
  cat > "$TMP/binstub/mix" << 'MIX'
#!/usr/bin/env bash
echo "$@" >> "$MIX_CALL_LOG"
case "$*" in
  *gate*)    exit 1 ;;   # red gate
  *release*) echo "RELEASE-RAN" >> "$MIX_CALL_LOG"; exit 0 ;;
  *)         exit 0 ;;
esac
MIX
  chmod +x "$TMP/binstub/mix"

  export MIX_CALL_LOG="$TMP/mix-calls.log"
  PATH="$TMP/binstub:$PATH" run build_release "$TMP"
  [ "$status" -ne 0 ]
  ! grep -q RELEASE-RAN "$MIX_CALL_LOG"
}

@test "sourcing install.sh never runs the deploy (source guard)" {
  run bash -c "source '$SCRIPT'; echo sourced-ok"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sourced-ok"* ]]
}

# --- guards: the deploy refuses the two ways it silently produced a wrong result -------------------

@test "refuse_root: root is refused (the gate is not valid under root)" {
  run refuse_root 0
  [ "$status" -ne 0 ]
  [[ "$output" == *"root"* ]]
  # The message must carry the REASON, not just the refusal: a reader who only sees "refused"
  # reaches for sudo again.
  [[ "$output" == *"gate"* ]]
}

@test "refuse_root: an ordinary uid passes" {
  run refuse_root 1000
  [ "$status" -eq 0 ]
}

@test "require_prefix_writable: a writable prefix passes" {
  run require_prefix_writable "$TMP/prefix"
  [ "$status" -eq 0 ]
}

@test "require_prefix_writable: walks UP to the first existing parent" {
  # The prefix usually does not exist yet; what matters is whether we may create it. Checking the
  # leaf alone would pass on any path at all.
  run require_prefix_writable "$TMP/a/b/c/d"
  [ "$status" -eq 0 ]
}

@test "require_prefix_writable: a non-writable destination FAILS before the build" {
  # The probe must land on the first EXISTING ancestor and test THAT one. A sibling that happens to
  # be writable inside a read-only parent is not the question: creating `$TMP/ro/prefix` needs write
  # on `$TMP/ro` itself.
  mkdir -p "$TMP/ro"
  chmod 500 "$TMP/ro"
  run require_prefix_writable "$TMP/ro/prefix"
  chmod 700 "$TMP/ro"
  [ "$status" -ne 0 ]
  [[ "$output" == *"non inscriptible"* ]]
  # And it must NOT send the reader back to sudo — that is the loop this pair exists to break.
  [[ "$output" == *"sudo"* ]]
}
