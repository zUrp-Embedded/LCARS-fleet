#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/docker/bench_down_scope.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-09
# STATUS: bats tests for bench-down.sh — WHAT a bench is made of, and the order it comes apart in

load ../refute

setup() {
  SRC="$BATS_TEST_DIRNAME/../../docker/bench/bench-down.sh"
  BINDIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BINDIR"
  CALLS="$BATS_TEST_TMPDIR/docker.calls"
  : > "$CALLS"

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
  PRESENT="bt-fleet-lcars-1 bt-runner-runner-1" run_down

  grep -q -- "-p bt-runner down -v" "$CALLS"
  grep -q -- "-p bt-fleet down -v" "$CALLS"
  grep -q -- "-p bt-forge down -v" "$CALLS"
}

@test "the runner goes FIRST — it holds the forge network, so a later teardown leaves it standing" {
  PRESENT="bt-fleet-lcars-1 bt-runner-runner-1" run_down

  runner="$(idx_of '\-p bt-runner down')"
  forge="$(idx_of '\-p bt-forge down')"
  [ -n "$runner" ]
  [ -n "$forge" ]
  [ "$runner" -lt "$forge" ]
}

@test "a HALF-destroyed bench (container gone, runner up) can still be finished" {
  # The old discriminant was the container alone: this state exited 2 before reaching the runner, and
  # clearing it took a docker rm by hand. That is the state a first, incomplete teardown leaves.
  PRESENT="bt-runner-act-1" run_down

  [ "$status" -eq 0 ]
  grep -q -- "-p bt-runner down -v" "$CALLS"
}

@test "only the FORGE survives (bench-up died before creating the container) → still destroyed" {
  PRESENT="bt-forge-gitea-1" run_down

  [ "$status" -eq 0 ]
  grep -q -- "-p bt-forge down -v" "$CALLS"
}

@test "no container left but the volumes remain → still destroyed" {
  PRESENT="someone-elses-container" VOLUMES="bt-forge_data bt-forge_config" run_down

  [ "$status" -eq 0 ]
  grep -q -- "-p bt-forge down -v" "$CALLS"
}

@test "nothing of this bench exists → exit 2, and NOT one destructive call" {
  # TEMOIN of the two above: the residue test must still be able to say NO. A guard that answers
  # "there is something" on an empty daemon would make the two tests above pass vacuously.
  PRESENT="someone-elses-container" VOLUMES="someoneelses_data" run_down

  [ "$status" -eq 2 ]
  refute grep -q -- "down -v" "$CALLS"
}

@test "--yes is still required, and its absence destroys nothing" {
  PRESENT="bt-fleet-lcars-1 bt-runner-runner-1"
  run bash "$SRC" --project bt

  [ "$status" -eq 1 ]
  refute grep -q -- "down -v" "$CALLS"
}

@test "every compose file bench-down names EXISTS next to it — a phantom path fails silently under || true" {
  local here docker_dir f n=0
  here="$(cd "$(dirname "$SRC")" && pwd)"; docker_dir="$(cd "$here/.." && pwd)"
  while read -r f; do
    n=$((n + 1))
    f="${f//\$HERE/$here}"; f="${f//\$DOCKER_DIR/$docker_dir}"
    [ -f "$f" ] || { echo "compose file named but absent: $f"; return 1; }
  done < <(grep -oE -- '-f "\$(HERE|DOCKER_DIR)/[^"]+"' "$SRC" | sed -E 's/^-f "//; s/"$//')
  [ "$n" -eq 3 ]
}
