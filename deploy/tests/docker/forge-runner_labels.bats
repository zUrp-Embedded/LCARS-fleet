#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/docker/forge-runner_labels.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-05
# STATUS: bats tests for forge-runner.sh — a label is a promise, checked before it is made

# shellcheck disable=SC2016

load ../refute
load ../support/decor

setup() {
  decor_pose
  # les labels des constantes de cet arbre ne s'écrivent nulle part ailleurs
  local vrai="$BATS_TEST_DIRNAME/../.."
  mkdir -p "$BATS_TEST_TMPDIR/arbre/deploy/docker" "$BATS_TEST_TMPDIR/arbre/deploy/lib"
  cp "$vrai/docker/forge-runner.sh" "$vrai/docker/runner-compose.yml" "$vrai/docker/runner-network.yml" "$BATS_TEST_TMPDIR/arbre/deploy/docker/"
  cp "$vrai/lib/provision-lib.sh" "$vrai/lib/docker-endpoint.sh" "$BATS_TEST_TMPDIR/arbre/deploy/lib/"
  { grep -v '^PROV_RUNNER_LABELS=' "$vrai/installer-constants.env"; echo 'PROV_RUNNER_LABELS=shell:docker://alpine:temoin'; } \
    > "$BATS_TEST_TMPDIR/arbre/deploy/installer-constants.env"
  SRC="$BATS_TEST_TMPDIR/arbre/deploy/docker/forge-runner.sh"
  BINDIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BINDIR"
  CALLS="$BATS_TEST_TMPDIR/docker.calls"
  : > "$CALLS"

  KNOWN="$BATS_TEST_TMPDIR/known"
  printf 'alpine:3.20\noutil-local:9\n' > "$KNOWN"
  UNPULLABLE="$BATS_TEST_TMPDIR/unpullable"
  : > "$UNPULLABLE"
  cat > "$BINDIR/dockerstub" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
if [[ "\$1 \$2" == "image inspect" ]]; then
  grep -qxF "\$3" "$KNOWN" && exit 0 || exit 1
fi
if [[ "\$1" == "pull" ]]; then
  img="\${@: -1}"
  # Un tag LOCAL (\`outil-local:*\`) n'est sur aucun registre — le tir echoue, comme en vrai.
  case "\$img" in outil-local:*) exit 1 ;; esac
  grep -qxF "\$img" "$UNPULLABLE" && exit 1
  echo "\$img" >> "$KNOWN"
  exit 0
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
  printf "tok\n" > "$BATS_TEST_TMPDIR/admin.token"
  run bash "$SRC" --forge-api http://f/api/v1 --admin-token-file "$BATS_TEST_TMPDIR/admin.token" \
      --network t_default --project t-runner "$@"
}

@test "sans --labels, les images des labels des constantes sont vérifiées avant la forge" {
  printf 'alpine:temoin\n' > "$UNPULLABLE"
  run_runner
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUS : image(s) introuvable(s)"*"alpine:temoin"* ]]
  refute grep -q '^CURL' "$CALLS"
}

@test "an image no daemon can resolve is REFUSED — the runner would announce it anyway" {
  run_runner --labels "shell:docker://alpine:3.20,elixir:docker://outil-local:absente"

  [ "$status" -eq 1 ]
  [[ "$output" == *"outil-local:absente"* ]]
  [[ "$output" == *"rate chaque job"* ]]
  refute grep -q '^CURL' "$CALLS"
}

@test "labels whose images all resolve pass, and the check reaches the forge after" {
  run_runner --labels "shell:docker://alpine:3.20,elixir:docker://outil-local:9"

  [[ "$output" == *"labels : shell:docker://alpine:3.20 elixir:docker://outil-local:9"* ]]
  grep -q "image inspect alpine:3.20" "$CALLS"
  grep -q "image inspect outil-local:9" "$CALLS"
  grep -q '^CURL' "$CALLS"
}

@test "a label with no docker:// image is skipped, not reported missing" {
  # A host-runner label resolves to nothing to pull. Treating it as a missing image would refuse a
  # perfectly valid configuration — the check must answer the question it was asked.
  run_runner --labels "host,shell:docker://alpine:3.20"

  [[ "$output" != *"introuvable"* ]]
  refute grep -q "image inspect host" "$CALLS"
}


@test "une image de label absente est TIREE, et le banc continue" {
  run_runner --labels "shell:docker://alpine:3.20,dood:docker://docker:cli"

  # Ce qui est mesure est la GARDE, pas la fin du script : la forge est une doublure muette, donc
  # l'enregistrement echoue apres — comme dans le temoin « labels whose images all resolve ».
  [[ "$output" == *"tentative de tirage : docker:cli"* ]]
  [[ "$output" != *"REFUS"* ]]
  grep -q "^pull -q docker:cli" "$CALLS"
  # Une image DEJA la n'est pas re-tiree : la garde tire ce qui manque, pas ce qui est.
  refute grep -q "^pull -q alpine:3.20" "$CALLS"
  grep -q '^CURL' "$CALLS"
}

@test "une image que le tir ne ramene pas reste un REFUS, et il nomme le build" {
  run_runner --labels "shell:docker://alpine:3.20,elixir:docker://outil-local:absente"

  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUS"* ]]
  [[ "$output" == *"outil-local:absente"* ]]
  [[ "$output" == *"pack.sh"* ]]
  refute grep -q '^CURL' "$CALLS"
}
