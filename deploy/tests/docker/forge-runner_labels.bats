#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/docker/forge-runner_labels.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-05
# STATUS: bats tests for forge-runner.sh — a label is a promise, checked before it is made

# shellcheck disable=SC2016

load ../refute

setup() {
  SRC="$BATS_TEST_DIRNAME/../../docker/forge-runner.sh"
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

@test "no --labels at all is REFUSED, and the refusal carries the way out" {
  run_runner

  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUS"* ]]
  # A refusal that does not say how to proceed is an obstacle, not a wall.
  [[ "$output" == *"--labels"* ]]
  [[ "$output" == *"--accept-generic"* ]]
  # Upstream of the forge: nothing was minted, nothing registered.
  refute grep -q '^CURL' "$CALLS"
}

@test "--accept-generic proceeds, and SAYS what was accepted" {
  run_runner --accept-generic

  # The generic default is right for an operator who cannot resolve a local LCARS image. Choosing
  # it is a decision; inheriting it silently was the defect.
  [[ "$output" == *"défaut générique accepté (--accept-generic)"* ]]
  [[ "$output" == *"ne sait pas jouer mix gate"* ]]
  grep -q '^CURL' "$CALLS"
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


@test "le compose du runner ne monte PLUS le socket de l'hote" {
  C="$BATS_TEST_DIRNAME/../../docker/runner-compose.yml"
  [ -f "$C" ]
  # aucune ligne de MONTAGE du socket (les mentions en commentaire, elles, expliquent pourquoi)
  refute grep -qE '^\s*-\s*/var/run/docker\.sock' "$C"
  grep -qE 'gitea/runner:[a-z0-9.]+-dind-rootless' "$C"
  # Et le digest ne revient pas par la fenetre : un pin ici serait un choix a re-arbitrer.
  refute grep -qE 'gitea/runner:[^[:space:]]*@sha256:' "$C"
  grep -qE '^\s*privileged: true' "$C"
  grep -q 'apparmor=rootlesskit' "$C"
  grep -q 'DOCKER_HOST: "unix:///var/run/user/1000/docker.sock"' "$C"
}

@test "le magasin du daemon embarque est un volume NOMME — sinon le semis meurt au recreate" {
  C="$BATS_TEST_DIRNAME/../../docker/runner-compose.yml"
  grep -q 'dind:/home/rootless/.local/share/docker' "$C"
  grep -qE '^\s{2}dind:\s*$' "$C"
}

@test "le magasin du dind ROOTFUL n'est PAS un volume — il ne porte rien" {
  C="$BATS_TEST_DIRNAME/../../docker/runner-compose.yml"
  grep -qE '^\s{4}tmpfs:\s*$' "$C"
  grep -qE '^\s{6}- /var/lib/docker\s*$' "$C"
  # et il n'apparait dans AUCUNE table de volumes
  sed -n '/^volumes:/,$p' "$C" | refute_out 'var/lib/docker'
}

@test "le semeur EXIGE une sortie non vide — un exec qui avale ne doit pas passer pour un succes" {
  SUT="$BATS_TEST_DIRNAME/../../docker/forge-runner.sh"
  grep -q 'seed_dind_images' "$SUT"
  grep -q 'docker image inspect -f .{{.Id}}.' "$SUT"
  # le refus existe et il nomme les deux causes possibles
  grep -q "ne rend rien après 60 s" "$SUT"
}

@test "le semeur lit LES LABELS — aucune seconde liste d'images a tenir" {
  # Une quatrieme liste du meme fait est morte ailleurs dans ce depot (PROV_ROLES). On ne
  # recommence pas : les labels nomment deja les images, l'etape 0 a deja verifie qu'elles existent.
  SUT="$BATS_TEST_DIRNAME/../../docker/forge-runner.sh"
  awk '/^seed_dind_images\(\)/,/^}/' "$SUT" | grep -q 'for entry in \$LABELS'
  awk '/^seed_dind_images\(\)/,/^}/' "$SUT" | grep -q 'image="\${entry#\*docker://}"'
}
