#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/bench_down_scope.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-09
# STATUS: bats tests for bench-down.sh — WHAT a bench is made of, and the order it comes apart in
#
# WHY THIS EXISTS. A bench is THREE compose projects — the box (`<project>`), the forge
# (`<project>forge`) and the runner (`<project>-runner`, started by bench-up through
# forge-runner.sh) — and this script tore down two. Measured 2026-08-09 on a real teardown:
# `lcars-faces-runner-runner-1` was still running afterwards and the forge's `down` ended on
# "Network ... Resource is still in use". The runner sits on the forge's network, so while it
# lives that network stays; and it stays REGISTERED against a forge that no longer exists — the
# zombie forge-runner.sh describes in its own header, except nobody clears it until the NEXT
# bench-up happens to reuse the same project name.
#
# The ORDER is the contract, not a preference: the runner must go first, or the forge teardown
# cannot take its network with it. A test that only checked "the runner is torn down" would pass
# on a script that does it last and leaves the network behind.
#
# WHAT IS PROVEN HERE: the three projects are named, the order between them, and that a
# half-destroyed bench (box gone, runner up) can still be finished. WHAT IS NOT: that `compose
# down -v` actually removes a volume, or that the network is released — those are docker's
# behaviour, and a stub cannot answer for them. Assertions read the CALL LOG, never the exit
# status: the stub does not fake compose's output.

load ../refute

setup() {
  SRC="$BATS_TEST_DIRNAME/../../docker/bench/bench-down.sh"
  BINDIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BINDIR"
  CALLS="$BATS_TEST_TMPDIR/docker.calls"
  : > "$CALLS"

  # `PRESENT` is what `docker ps -a` answers and `VOLUMES` what `docker volume ls` answers — together
  # they are the RESIDUE this script looks for to decide there is something to destroy. Each test
  # sets the leftovers it wants to exist. Volumes answer separately because they outlive containers:
  # a bench whose containers are all gone still owns the forge's seeded state until `down -v` runs.
  export PRESENT="${PRESENT:-}"
  export VOLUMES="${VOLUMES:-}"

  cat > "$BINDIR/dockerstub" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
case "\$1 \$2" in
  "ps -a")     printf '%s\n' \$PRESENT ;;
  "volume ls") printf '%s\n' \$VOLUMES ;;
esac
exit 0
EOF
  chmod 0755 "$BINDIR/dockerstub"

  export PATH="$BINDIR:$PATH"
  export DOCKER_BIN=dockerstub
}

run_down() {
  run bash "$SRC" --project bt --yes
}

# The index of the first logged call matching a pattern, or "" — order is what this suite reads.
idx_of() {
  grep -n -- "$1" "$CALLS" | head -1 | cut -d: -f1
}

@test "a full bench: the three compose projects are torn down, none forgotten" {
  PRESENT="bt-lcars-1 bt-runner-runner-1" run_down

  grep -q -- "-p bt-runner down -v" "$CALLS"
  grep -q -- "-p bt down -v" "$CALLS"
  grep -q -- "-p btforge down -v" "$CALLS"
}

@test "the runner goes FIRST — it holds the forge network, so a later teardown leaves it standing" {
  PRESENT="bt-lcars-1 bt-runner-runner-1" run_down

  runner="$(idx_of '\-p bt-runner down')"
  forge="$(idx_of '\-p btforge down')"
  [ -n "$runner" ]
  [ -n "$forge" ]
  [ "$runner" -lt "$forge" ]
}

@test "a HALF-destroyed bench (box gone, runner up) can still be finished" {
  # The old discriminant was the box alone: this state exited 2 before reaching the runner, and
  # clearing it took a docker rm by hand. That is the state a first, incomplete teardown leaves.
  PRESENT="bt-runner-act-1" run_down

  [ "$status" -eq 0 ]
  grep -q -- "-p bt-runner down -v" "$CALLS"
}

# 2026-08-14 — THE DISCRIMINANT GREW ONE MEMBER AT A TIME AND NEVER CLOSED THE CLASS. First the box,
# then box-or-runner (the test above). The member it still missed showed up on a real teardown: when
# bench-up dies BEFORE creating the box — its forge never answered — the only leftovers are
# `<project>forge-gitea-1` and two volumes, and this script answered "rien a detruire" on a bench
# that still held the bind, the port and the project name. The next bench-up then mounted itself on
# the previous one's remains.
@test "only the FORGE survives (bench-up died before creating the box) → still destroyed" {
  PRESENT="btforge-gitea-1" run_down

  [ "$status" -eq 0 ]
  grep -q -- "-p btforge down -v" "$CALLS"
}

# Volumes alone are the harder half, and the one that matters most: they carry the STATE — the
# seeded forge, the box's /home. `compose down -v` removes them even when no container mounts them,
# so a guard that only reads `ps -a` refuses to clean exactly the residue that poisons the next run.
@test "no container left but the volumes remain → still destroyed" {
  PRESENT="someone-elses-box" VOLUMES="btforge_data btforge_config" run_down

  [ "$status" -eq 0 ]
  grep -q -- "-p btforge down -v" "$CALLS"
}

@test "nothing of this bench exists → exit 2, and NOT one destructive call" {
  # TEMOIN of the two above: the residue test must still be able to say NO. A guard that answers
  # "there is something" on an empty daemon would make the two tests above pass vacuously.
  PRESENT="someone-elses-box" VOLUMES="someoneelses_data" run_down

  [ "$status" -eq 2 ]
  refute grep -q -- "down -v" "$CALLS"
}

@test "--yes is still required, and its absence destroys nothing" {
  PRESENT="bt-lcars-1 bt-runner-runner-1"
  run bash "$SRC" --project bt

  [ "$status" -eq 1 ]
  refute grep -q -- "down -v" "$CALLS"
}
