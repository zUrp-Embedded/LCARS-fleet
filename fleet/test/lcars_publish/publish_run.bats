#!/usr/bin/env bats
# SOURCE: fleet/test/lcars_publish/publish_run.bats
# AUTHOR: bob
# STARDATE: 2026-08-20
# STATUS: bats tests for `lcars publish run` — phase 2's human door
#
# WHY THIS VERB EXISTS AT ALL. `publish-rail.sh` is a host-side, self-contained, executable script,
# and the BEAM was the ONLY thing able to trigger it (`project_publish.ex` was its single caller in
# the entire repository). Phase 1 IS a verb (`lcars approve`); phase 2 — the one that repeats — was
# not. An operator holding a `project_publish.failed` reason on the bus had no way to replay the
# gesture and look, and `publish status` diagnosed a publication it could not run.
#
# WHAT THESE PIN: that the verb reads the SAME binding the runtime reads, hands the rail the SAME
# arguments, refuses rather than guesses when the binding is incomplete, and honours the one exit
# code that must leave its clone behind. The rail is a stub here — what is under test is the door,
# not the rail (`test/publish_rail/` covers that one).

setup() {
  HOMEDIR="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOMEDIR/.lcars/publish"
  export HOME="$HOMEDIR"

  # The verb resolves its rail next to ITSELF, so the subject is a copy with a stub beside it.
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  cp "$BATS_TEST_DIRNAME/../../bin/lcars" "$BIN/lcars"
  SUT="$BIN/lcars"
  RAILLOG="$BATS_TEST_TMPDIR/raillog"

  cat > "$BIN/publish-rail.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$RAILLOG"
work=""
while [[ \$# -gt 0 ]]; do [[ "\$1" == "--work" ]] && work="\$2"; shift; done
mkdir -p "\$work"
exit \${LCARS_TEST_RAIL_EXIT:-0}
EOF
  chmod +x "$BIN/publish-rail.sh"

  # The box env the verb needs before it will call anything.
  printf 'FORGE_BASE_URL=http://forge.invalid\nFORGE_TOKEN_FILE=%s/tok\n' "$HOMEDIR" \
    > "$HOMEDIR/fleet_v2.env"
  echo t > "$HOMEDIR/tok"
  export LCARS_FLEET_V2_ENV="$HOMEDIR/fleet_v2.env"
}

_bind() { # _bind <json>
  printf '%s' "$1" > "$HOMEDIR/.lcars/publish/fleet__demo.json"
}

_full_binding='{"host":"github","dest_host":"ghe.example.com","dest_repo":"acme/widget","base":"master"}'

# ─── the door itself ───────────────────────────────────────────────────────────────────────────

@test "publish with no subcommand names BOTH of them" {
  run "$SUT" publish
  [ "$status" -eq 1 ]
  [[ "$output" == *"run"* ]]
  [[ "$output" == *"status"* ]]
}

@test "publish run without a repo -> usage" {
  run "$SUT" publish run
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage"* ]]
}

@test "publish run on an unlinked project names the gesture that links it" {
  run "$SUT" publish run fleet/demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"n'est pas lie"* ]]
  [[ "$output" == *"lcars approve"* ]]
}

# ─── an incomplete binding is REFUSED, never completed by a guess ──────────────────────────────

@test "a binding without 'base' is refused BY NAME — the runtime used to fall back to main" {
  # THE DEFECT THIS FORBIDS had two independent entry points: `approve` assumed `main` when writing,
  # and `rail_args/5` did `Map.get(b, "base") || "main"` when reading. Closing one alone left the
  # rail broken by the other. A binding that does not say WHERE it publishes is not a binding.
  _bind '{"host":"github","dest_host":"github.com","dest_repo":"acme/widget"}'
  run "$SUT" publish run fleet/demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"base"* ]]
  [ ! -f "$RAILLOG" ]   # and nothing was launched
}

@test "a binding without 'dest_repo' is refused BY NAME too" {
  _bind '{"host":"github","dest_host":"github.com","base":"main"}'
  run "$SUT" publish run fleet/demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"dest_repo"* ]]
}

# ─── the rail receives the binding's values, not defaults ──────────────────────────────────────

@test "the rail is handed the binding's host, dest-host, dest-repo and base" {
  # A second implementation of the argument list would drift from the runtime's. What is pinned is
  # that every value comes FROM the binding — in particular `base`, which used to be assumed `main`
  # on both sides while the destination's default branch was `master`.
  _bind "$_full_binding"
  run "$SUT" publish run fleet/demo
  [ "$status" -eq 0 ]
  grep -q -- "--host github" "$RAILLOG"
  grep -q -- "--dest-host ghe.example.com" "$RAILLOG"
  grep -q -- "--dest-repo acme/widget" "$RAILLOG"
  grep -q -- "--base master" "$RAILLOG"
  grep -q -- "--project fleet/demo" "$RAILLOG"
}

@test "the rail gets a FRESH --work path (it refuses one that already exists)" {
  _bind "$_full_binding"
  run "$SUT" publish run fleet/demo
  [ "$status" -eq 0 ]
  grep -q -- "--work " "$RAILLOG"
}

# ─── the work directory: swept, except for the one failure that must be inspected ──────────────

@test "a normal outcome leaves no clone behind" {
  _bind "$_full_binding"
  run "$SUT" publish run fleet/demo
  [ "$status" -eq 0 ]
  work="$(sed -n 's/.*--work \([^ ]*\).*/\1/p' "$RAILLOG")"
  [ -n "$work" ]
  [ ! -e "$work" ]
}

@test "exit 6 KEEPS the clone and prints where it is" {
  # Exit 6 means the rewrite lost its determinism — the one failure that cannot be reproduced from a
  # message. Sweeping it would erase the only evidence.
  _bind "$_full_binding"
  LCARS_TEST_RAIL_EXIT=6 run "$SUT" publish run fleet/demo
  [ "$status" -eq 6 ]
  work="$(sed -n 's/.*--work \([^ ]*\).*/\1/p' "$RAILLOG")"
  [ -d "$work" ]
  [[ "$output" == *"conserve pour inspection"* ]]
  rm -rf "$(dirname "$work")"
}

@test "any other non-zero exit propagates AND sweeps" {
  _bind "$_full_binding"
  LCARS_TEST_RAIL_EXIT=4 run "$SUT" publish run fleet/demo
  [ "$status" -eq 4 ]
  work="$(sed -n 's/.*--work \([^ ]*\).*/\1/p' "$RAILLOG")"
  [ ! -e "$work" ]
}
