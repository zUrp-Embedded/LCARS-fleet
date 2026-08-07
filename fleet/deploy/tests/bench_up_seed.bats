#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/bench_up_seed.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-05
# STATUS: bats tests for bench-up.sh — the claude seeding, and the WINDOW it must land in
#
# WHY THIS EXISTS. `bench-up.sh` had no coverage at all, and its own header says its whole value is
# a CHOREOGRAPHY that used to live in the memory of the session that performed it: which project
# composes, which network attaches when, when to restart. The seeding added on 2026-08-05 is one
# more step in that order, and an order is exactly the kind of thing a syntax check cannot see.
#
# The window is the contract, not a preference. The seed must land AFTER `create` (the container
# must exist for `docker cp`) and BEFORE `start` (the entrypoint creates the runtime human at boot
# and the provisioning reads the seed on that same boot). A seed one step later is a seed the box
# has already decided to live without.
#
# WHAT IS PROVEN HERE: the order, the symlink resolution, and the two degradation branches. WHAT IS
# NOT: that `docker cp` accepts a created-but-unstarted container, that it preserves the source
# mode, and that `/local` exists in the runtime image. Those three are `docker`'s behaviour and an
# image's content — a stub cannot answer for either, and no daemon was reachable when this was
# written. They are named here rather than left for a reader to assume this suite covers them.
#
# The script is driven far enough to cross the window and then allowed to die in the forge
# bootstrap, which the stubs do not fake. Assertions read the CALL LOG, never the exit status.

setup() {
  SRC="$BATS_TEST_DIRNAME/../docker/dev/bench-up.sh"
  BINDIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BINDIR"
  CALLS="$BATS_TEST_TMPDIR/docker.calls"
  : > "$CALLS"

  # A real symlink chain, because the host binary IS one: the vendor installer leaves
  # ~/.local/bin/claude pointing at a versioned file, and copying the LINK gives the box a dead
  # target. The suite would pass on a plain file and miss the whole point.
  mkdir -p "$BATS_TEST_TMPDIR/claude/versions"
  REAL_CLAUDE="$BATS_TEST_TMPDIR/claude/versions/9.9.9"
  printf '#!/usr/bin/env bash\necho 9.9.9\n' > "$REAL_CLAUDE"
  chmod 0755 "$REAL_CLAUDE"
  LINK_CLAUDE="$BATS_TEST_TMPDIR/claude/claude"
  ln -sf "$REAL_CLAUDE" "$LINK_CLAUDE"

  cat > "$BINDIR/dockerstub" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
case "\$1 \$2" in
  "run --rm")   echo flux-ok ;;      # the attached-stream probe the script dies on if empty
  "ps -a")      : ;;                 # no box of this name yet
  "inspect -f") echo healthy ;;      # skip the health wait loop on the first turn
esac
exit 0
EOF
  chmod 0755 "$BINDIR/dockerstub"

  # The forge readiness probe. Nothing else in the crossed window shells out to curl.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BINDIR/curl"
  chmod 0755 "$BINDIR/curl"

  export PATH="$BINDIR:$PATH"
  export DOCKER_BIN=dockerstub
  # Set so the script skips its socket selection: neither Docker Desktop's shared socket nor the
  # fleet relay is a thing a test may depend on.
  export DOCKER_HOST=unix:///dev/null
}

run_bench() {
  run bash "$SRC" --project bt --no-creds --no-human-admin "$@"
}

# The index of the first logged call matching a pattern, or "" — order is what this suite reads.
idx_of() {
  grep -n -- "$1" "$CALLS" | head -1 | cut -d: -f1
}

refute_line_matches() {
  ! grep -q -- "$1" "$CALLS"
}

@test "the seed lands AFTER create and BEFORE start — the window is the contract" {
  run_bench --claude-from "$LINK_CLAUDE"

  local create cp_ start
  create="$(idx_of 'compose .* create')"
  cp_="$(idx_of '^cp ')"
  # Le motif suit la COMMANDE, pas sa forme d'appel : depuis le projet unique (2026-08-07) le
  # `start` porte le service (`start lcars`) et les `-f`/`-p` vivent dans un tableau. Epingler
  # `compose -p bt start` epinglait la syntaxe d'un jour, pas le contrat — et c'est le contrat que
  # ce test existe pour tenir : la graine tombe APRES create et AVANT start.
  start="$(idx_of 'compose .* start')"

  [ -n "$create" ] && [ -n "$cp_" ] && [ -n "$start" ]
  [ "$create" -lt "$cp_" ]
  # A seed dropped after `start` is a seed the box has already decided to live without: the
  # provisioning read (and failed) its claude module on that very boot.
  [ "$cp_" -lt "$start" ]
}

@test "the SYMLINK is resolved — copying the link gives the box a dead target" {
  run_bench --claude-from "$LINK_CLAUDE"

  grep -q -- "cp $REAL_CLAUDE " "$CALLS"
  refute_line_matches "cp $LINK_CLAUDE "
}

@test "the destination is the path provision-lib declares, never a literal retyped here" {
  run_bench --claude-from "$LINK_CLAUDE"

  local declared
  declared="$(bash -c '. "$1" >/dev/null 2>&1; echo "$PROV_CLAUDE_SEED"' _ \
                "$BATS_TEST_DIRNAME/../lib/provision-lib.sh")"
  [ -n "$declared" ]
  # The module that CONSUMES the path owns it. A copy here drifts the day it moves, and the failure
  # is a box that silently downloads instead of a build that breaks.
  grep -q -- "bt-lcars-1:$declared" "$CALLS"
}

@test "an absent source DEGRADES and says so — a networked bench never needed the seed" {
  run_bench --claude-from "$BATS_TEST_TMPDIR/nope"

  refute_line_matches '^cp '
  [[ "$output" == *"graine claude SAUTEE"* ]]
  # It must not die: the seeding is an offline convenience, not a precondition of the bench.
  [[ "$output" == *"boite healthy"* ]]
}

@test "--no-claude-bin skips it and NAMES the consequence" {
  run_bench --no-claude-bin

  refute_line_matches '^cp '
  [[ "$output" == *"NON posee (--no-claude-bin)"* ]]
  [[ "$output" == *"telechargera au boot"* ]]
}
