#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/bench_runner_labels.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-05
# STATUS: bats tests for bench-runner.sh — a label is a promise, checked before it is made
#
# WHY THIS EXISTS. A runner label is a KEY the runner announces to the forge: "send me the jobs that
# ask for this". The runner registers GREEN whatever image sits behind the key, then fails every job
# handed to it. That is trap n°2 of the script's own header at another layer — "a green runner that
# fails all its jobs, the worst of states" — and the file carried it as a NOTE since 2026-08-02
# without acting on it. A note describing a silence is still a silence.
#
# Both refusals fire BEFORE the first call to the forge: registering and then discovering the
# runner is useless costs a forge round-trip and leaves a zombie identity in the volume.
#
# `docker image inspect` is deliberate: it is a NON-attached-stream command, so it crosses the
# fleet group's systemd relay, unlike `exec`/`run`/`cp` which return zero bytes and exit 0 there.
# The probe therefore works on both sockets — a probe that only works on the good one would be
# absent exactly when it is needed.

setup() {
  SRC="$BATS_TEST_DIRNAME/../docker/dev/bench-runner.sh"
  BINDIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BINDIR"
  CALLS="$BATS_TEST_TMPDIR/docker.calls"
  : > "$CALLS"

  # Knows two images and nothing else. `image inspect` on anything else fails, which is exactly
  # what a daemon does for an image nobody built.
  cat > "$BINDIR/dockerstub" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
if [[ "\$1 \$2" == "image inspect" ]]; then
  case "\$3" in
    alpine:3.20|lcars-build:9) exit 0 ;;
    *) exit 1 ;;
  esac
fi
exit 0
EOF
  chmod 0755 "$BINDIR/dockerstub"

  # The forge must never be reached in these tests: every refusal is upstream of it. A curl that
  # ran would prove the check fired too late.
  cat > "$BINDIR/curl" <<EOF
#!/usr/bin/env bash
echo "CURL \$*" >> "$CALLS"
exit 0
EOF
  chmod 0755 "$BINDIR/curl"

  export PATH="$BINDIR:$PATH"
  export DOCKER_BIN=dockerstub
  unset LCARS_RUNNER_LABELS
}

run_runner() {
  run bash "$SRC" --forge-api http://f/api/v1 --admin-token tok "$@"
}

@test "no --labels at all is REFUSED, and the refusal carries the way out" {
  run_runner

  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUS"* ]]
  # A refusal that does not say how to proceed is an obstacle, not a wall.
  [[ "$output" == *"--target build"* ]]
  [[ "$output" == *"--accept-generic"* ]]
  # Upstream of the forge: nothing was minted, nothing registered.
  ! grep -q '^CURL' "$CALLS"
}

@test "--accept-generic proceeds, and SAYS what was accepted" {
  run_runner --accept-generic

  # The generic default is right for an operator who cannot resolve a local LCARS image. Choosing
  # it is a decision; inheriting it silently was the defect.
  [[ "$output" == *"ACCEPTE"* ]]
  [[ "$output" == *"ne sait pas jouer mix gate"* ]]
  grep -q '^CURL' "$CALLS"
}

@test "an image no daemon can resolve is REFUSED — the runner would announce it anyway" {
  run_runner --labels "shell:docker://alpine:3.20,elixir:docker://lcars-build:absente"

  [ "$status" -eq 1 ]
  [[ "$output" == *"lcars-build:absente"* ]]
  [[ "$output" == *"rate chaque job"* ]]
  ! grep -q '^CURL' "$CALLS"
}

@test "labels whose images all resolve pass, and the check reaches the forge after" {
  run_runner --labels "shell:docker://alpine:3.20,elixir:docker://lcars-build:9"

  [[ "$output" == *"labels:"* ]]
  grep -q "image inspect alpine:3.20" "$CALLS"
  grep -q "image inspect lcars-build:9" "$CALLS"
  grep -q '^CURL' "$CALLS"
}

@test "a label with no docker:// image is skipped, not reported missing" {
  # A host-runner label resolves to nothing to pull. Treating it as a missing image would refuse a
  # perfectly valid configuration — the check must answer the question it was asked.
  run_runner --labels "host,shell:docker://alpine:3.20"

  [[ "$output" != *"introuvable"* ]]
  ! grep -q "image inspect host" "$CALLS"
}
