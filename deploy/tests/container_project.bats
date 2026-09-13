#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/container_project.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-07
# STATUS: bats tests for deploy/container — a project NAME is not proof you are talking about the same container

load refute

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SRC="$REPO/deploy/container"
  CF="$REPO/deploy/docker/docker-compose.yml"

  BINDIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BINDIR"
  CALLS="$BATS_TEST_TMPDIR/docker.calls"
  : > "$CALLS"

  cat > "$BINDIR/docker" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
if [[ "\$*" == *"config --format json"* ]]; then printf '{"volumes":{"lcars-home":{"name":"%s"}}}\n' "\${STUB_COMPOSE_HOME:-}"; exit 0; fi
if [[ "\$*" == *".Mounts"* ]]; then echo "\${STUB_HOME_VOLUME:-}"; exit 0; fi
if [[ "\$1 \$2" == "image inspect" && -n "\${STUB_NO_IMAGE:-}" ]]; then exit 1; fi
case "\$1 \$2" in
  "compose version") exit 0 ;;
  "ps -aq")          printf '%s' "\${STUB_IDS:-}"; [[ -n "\${STUB_IDS:-}" ]] && echo; exit 0 ;;
  "volume ls")       printf '%s' "\${STUB_VOLUMES:-}"; [[ -n "\${STUB_VOLUMES:-}" ]] && echo; exit 0 ;;
  "inspect \${STUB_IDS:-__none__}") echo "\${STUB_CONFIG_FILES:-}"; exit 0 ;;
esac
# Le verdict des gestes de forge, lu par 'up' DANS le conteneur ; STUB_PROV_RC vide = pas encore ecrit.
# Pas d'accents graves ici : ce heredoc n'est pas quote, un mot entre accents graves y serait execute.
if [[ "\$*" == *"cat /run/lcars-forge.rc"* ]]; then
  [[ -n "\${STUB_PROV_RC:-}" ]] || exit 1
  printf '%s\n' "\${STUB_PROV_RC}"
  exit 0
fi
exit 0
EOF
  chmod 0755 "$BINDIR/docker"

  export PATH="$BINDIR:$PATH"
  unset LCARS_PROJECT STUB_IDS STUB_CONFIG_FILES STUB_PROV_RC STUB_VOLUMES STUB_HOME_VOLUME STUB_COMPOSE_HOME

  export DOCKER_HOST="unix:///dev/null"
  export PROV_DOCKER_BIN="$BINDIR/docker"
  # la conf par projet vit sous $HOME : un temoin ne touche pas le vrai
  export LCARS_CONTAINER_CONF_DIR="$BATS_TEST_TMPDIR/conf"
}

# A project holding one container, created from the files given as arguments.
seed_project() {
  export STUB_IDS="c0ffee"
  export STUB_CONFIG_FILES="$1"
}

@test "an EMPTY project is not refused — up is entitled to create it" {
  # STUB_IDS unset: `ps -aq` returns nothing, so there is no container whose provenance to read.
  run bash "$SRC" -p lcars-jamais-cree down

  [ "$status" -eq 0 ]
  [[ "$output" != *"refus"* ]]
  # It really went through to compose rather than short-circuiting.
  grep -q -- "-p lcars-jamais-cree down" "$CALLS"
}

@test "a project created by THIS compose file passes the guard" {
  seed_project "$CF"

  run bash "$SRC" down

  [ "$status" -eq 0 ]
  [[ "$output" != *"refus"* ]]
  grep -q -- "-p lcars-fleet down" "$CALLS"
}

@test "a project created by ANOTHER compose file is refused, and the refusal names both" {
  # The real case: the container predating the move, whose creating file no longer exists on disk.
  seed_project "/home/projects/LCARS/fleet/provisioning_v2/docker/docker-compose.install.yml"

  run bash "$SRC" down

  [ "$status" -eq 1 ]
  [[ "$output" == *"refus"* ]]
  # A refusal that does not say WHAT it saw cannot be acted on.
  [[ "$output" == *"provisioning_v2"* ]]
  [[ "$output" == *"$CF"* ]]
  [[ "$output" == *"docker compose ls"* ]]
  # Nothing reached compose: the guard is upstream, not a post-mortem.
  refute grep -q "down" "$CALLS"
}

@test "the file must match a WHOLE list element, never a prefix of one" {
  # `<file>` is a strict prefix of `<file>.bak`. Substring matching would call this project ours
  # and hand a live container to `down`.
  seed_project "$CF.bak"

  run bash "$SRC" down

  [ "$status" -eq 1 ]
  [[ "$output" == *"refus"* ]]
}

@test "one match inside a multi-file list is enough" {
  seed_project "/somewhere/base.yml,$CF,/somewhere/override.yml"

  run bash "$SRC" down

  [ "$status" -eq 0 ]
  [[ "$output" != *"refus"* ]]
}

@test "reset refuses BEFORE asking for confirmation" {
  # Order is the contract. A confirmation prompt shown first teaches the operator to type `yes` at
  # a question about the wrong container, and destruction follows their own answer.
  seed_project "/elsewhere/docker-compose.install.yml"

  run bash "$SRC" -p lcars-valid reset

  [ "$status" -eq 1 ]
  [[ "$output" == *"refus"* ]]
  [[ "$output" != *"reset du projet"* ]]
  refute grep -q "volume rm" "$CALLS"
}

@test "reset NAMES the project it is about to destroy" {
  command -v setsid >/dev/null || skip "setsid absent: cannot detach the tty without risking a hang"
  seed_project "$CF"

  # The empty answer takes the abort path. What is pinned is the QUESTION — a destruction prompt
  # that does not say which container is not a question, it is a reflex to type `yes` into.
  run setsid --wait bash "$SRC" -p lcars-a-moi reset

  [ "$status" -eq 1 ]
  [[ "$output" == *"lcars-a-moi"* ]]
  [[ "$output" == *"annulé"* ]]
}

# Le nom des volumes se dérive de docker (filtre par label de projet), il ne se recompose jamais
# depuis le compose : un nom recopié à la main a déjà fait retirer un fantôme en laissant le vrai.

@test "reset NOMME les volumes que docker declare, il ne les compose pas" {
  STUB_VOLUMES="$(printf 'lcars-a-moi_lcars-home\nlcars-a-moi_cache')" \
    run setsid --wait bash "$SRC" -p lcars-a-moi reset </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"lcars-a-moi_lcars-home"* ]]
  [[ "$output" == *"lcars-a-moi_cache"* ]]
}

@test "reset le DIT quand le projet ne porte aucun volume — jamais un nom invente" {
  run setsid --wait bash "$SRC" -p lcars-a-moi reset </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"<aucun>"* ]]
}

# shellcheck disable=SC2016 # motif `grep` : `${PROJECT}` doit atteindre grep tel quel
@test "up refuse une instance dont /home vit sur un autre volume que celui du compose — jamais un /home vide en silence" {
  seed_project "$CF"
  STUB_HOME_VOLUME=lcars-fleet_home STUB_COMPOSE_HOME=lcars-fleet_lcars-home run bash "$SRC" up
  [ "$status" -eq 1 ]
  [[ "$output" == *"lcars-fleet_home"*"lcars-fleet_lcars-home"*"volume vide"* ]]
  [[ "$output" == *"reset"* ]]
  refute grep -qE "compose .* up" "$CALLS"
  # même volume des deux côtés : la garde se tait et up va jusqu'au verdict
  STUB_HOME_VOLUME=lcars-fleet_lcars-home STUB_COMPOSE_HOME=lcars-fleet_lcars-home STUB_PROV_RC=0 \
    LCARS_UP_VERDICT_TIMEOUT=5 run bash "$SRC" up
  [ "$status" -eq 0 ]
  [[ "$output" != *"volume vide"* ]]
  grep -qE "compose .* up" "$CALLS"
}

@test "LCARS_PROJECT is read, and -p overrides it" {
  seed_project "$CF"

  LCARS_PROJECT=depuis-env run bash "$SRC" down
  [ "$status" -eq 0 ]
  grep -q -- "-p depuis-env down" "$CALLS"

  : > "$CALLS"
  LCARS_PROJECT=depuis-env run bash "$SRC" -p depuis-flag down
  [ "$status" -eq 0 ]
  grep -q -- "-p depuis-flag down" "$CALLS"
  refute grep -q -- "-p depuis-env " "$CALLS"
}

@test "-p without a value is refused rather than swallowing the command" {
  # `container -p down` must not silently target a project named "down" and run no command.
  run bash "$SRC" -p

  [ "$status" -eq 1 ]
  [[ "$output" == *"-p attend un nom de projet"* ]]
}

@test "help works with NO docker at all, and is not truncated" {
  # Help is the one command that must survive a machine without docker — it is what you read to
  # find out what is missing.
  run env PATH=/usr/bin:/bin timeout 15 bash "$SRC" help

  [ "$status" -eq 0 ]
  # First line of the block and last line of the block: the extraction is anchored on content, so
  # inserting a header line can no longer amputate the tail.
  [[ "$output" == *"USAGE : deploy/container"* ]]
  [[ "$output" == *"EXIT :"* ]]
  # And the -p contract is documented where an operator looks for it.
  [[ "$output" == *"LCARS_PROJECT"* ]]
}


@test "up: verdict 0 -> convergé, sortie 0, et compose n'a jamais bâti" {
  STUB_PROV_RC=0 run "$SRC" -p lcars up
  [ "$status" -eq 0 ]
  [[ "$output" == *"gestes de forge convergés"* ]]
  grep -q -- ' up -d --no-build' "$CALLS"
  refute grep -qE '(^| )build( |$)' "$CALLS"
}

@test "up: verdict 2 -> DRIFT nomme, mais PAS un echec (un geste manque, rien n'est casse)" {
  STUB_PROV_RC=2 run "$SRC" -p lcars up
  [ "$status" -eq 0 ]
  [[ "$output" == *"drift résiduel"* ]]
  [[ "$output" != *"en échec"* ]]
}

@test "up: verdict non nul -> ECHEC, sortie NON NULLE, et la consequence est nommee" {
  STUB_PROV_RC=1 run "$SRC" -p lcars up
  [ "$status" -eq 1 ]
  [[ "$output" == *"en échec"* ]]
  # « le conteneur tourne » ET « ne produira rien » : les deux moities, sinon le lecteur croit que
  # le conteneur est mort et va le relancer au lieu de diagnostiquer.
  [[ "$output" == *"le conteneur tourne"* ]]
  [[ "$output" == *"ne produira rien"* ]]
}

@test "up: verdict ILLISIBLE -> on le DIT et on sort 0 — une non-mesure n'est pas un echec" {
  LCARS_UP_VERDICT_TIMEOUT=1 run "$SRC" -p lcars up
  [ "$status" -eq 0 ]
  [[ "$output" == *"non lu"* ]]
  [[ "$output" == *"n'est pas mesuré"* ]]
  [[ "$output" != *"en échec"* ]]
}


@test "build DELEGUE a pack.sh — aucun docker build, aucun compose build ici" {
  local stub="$BATS_TEST_TMPDIR/pack-stub"
  printf '#!/usr/bin/env bash\necho "PACK:$*"\n' > "$stub"; chmod 0755 "$stub"
  LCARS_PACK_BIN="$stub" run bash "$SRC" build --no-image
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"PACK:--no-image"* ]]
  refute grep -qE -- "compose .*build|build --target" "$CALLS"
}


@test "logs suit le journal et transmet ses arguments à compose" {
  run bash "$SRC" -p lcars-fleet logs --tail 20 lcars
  [ "$status" -eq 0 ]
  grep -qF -- "-p lcars-fleet logs -f --tail 20 lcars" "$CALLS"
}

@test "un banc ne se recrée pas par un up simple : il sortirait du réseau de sa forge" {
  seed_project "$CF,$REPO/deploy/docker/docker-compose.bench.yml"
  run bash "$SRC" -p lcars-fleet up
  [ "$status" -eq 1 ]
  [[ "$output" == *"est un banc"*"--forge-project lcars --bench up"* ]]
  refute grep -q -- ' up -d' "$CALLS"
}

@test "--bench avec un projet qui ne suit pas le nommage du banc est refusé avant tout" {
  run bash "$SRC" -p mon-instance --bench up
  [ "$status" -eq 1 ]
  [[ "$output" == *"« mon-instance » n'en est pas un"* ]]
}

@test "l'aide ne promet plus une forge que l'operateur devrait apporter" {
  run env PATH=/usr/bin:/bin timeout 15 bash "$SRC" help
  [[ "$output" == *"--bench"* ]]
  [[ "$output" != *"LCARS ne la"$'\n'*"fabrique pas"* ]]
  [[ "$output" != *"ne la fabrique pas"* ]]
}

@test "l'aide se rend sans docker ni sonde, et ne crée aucun fichier de secrets" {
  run env PATH=/usr/bin:/bin timeout 15 bash "$SRC" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"USAGE"*"--bench"*"EXIT"* ]]
  [ ! -e "$LCARS_CONTAINER_CONF_DIR" ]
}

@test "up --bench : exec du banc avec la base du projet, l'image et les ports traduits" {
  local bench="$BATS_TEST_TMPDIR/arbre/deploy/docker/bench"; mkdir -p "$bench" "$BATS_TEST_TMPDIR/arbre/deploy/lib" "$BATS_TEST_TMPDIR/arbre/deploy/docker"
  cp "$SRC" "$BATS_TEST_TMPDIR/arbre/deploy/container"; cp -a "$REPO/deploy/lib/." "$BATS_TEST_TMPDIR/arbre/deploy/lib/"
  cp "$CF" "$REPO/deploy/docker/docker-compose.secrets.yml" "$BATS_TEST_TMPDIR/arbre/deploy/docker/"
  printf '#!/usr/bin/env bash\necho "BENCH:$*"; echo "DOCKER_BIN=$DOCKER_BIN"\n' > "$bench/bench-up.sh"; chmod 0755 "$bench/bench-up.sh"
  LCARS_IMAGE=lcars-fleet:9 run bash "$BATS_TEST_TMPDIR/arbre/deploy/container" --forge-project bob_10 --port-forge 20100 --port-deck 20101 --port-ssh 20102 --bench up
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"BENCH:--forge-project bob_10 --image lcars-fleet:9 --port-forge 20100 --port-deck 20101 --port-ssh 20102"* ]]
  [[ "$output" == *"DOCKER_BIN=$BINDIR/docker"* ]]
  refute grep -qE "compose .* up" "$CALLS"
}

@test "--port-forge sans --bench est refusé : la forge est fournie" {
  run bash "$SRC" --port-forge 20100 up
  [ "$status" -eq 1 ]
  [[ "$output" == *"--port-forge n'a d'objet qu'avec --bench"* ]]
}

@test "la CLI docker est celle que la sonde rend, jamais le docker nu du PATH" {
  local nu="$BATS_TEST_TMPDIR/nu"; mkdir -p "$nu"
  printf '#!/usr/bin/env bash\necho "DOCKER-NU:$*" >> "%s"\nexit 1\n' "$CALLS" > "$nu/docker"; chmod 0755 "$nu/docker"
  PATH="$nu:$PATH" run bash "$SRC" status
  [ "$status" -eq 2 ]
  refute grep -q 'DOCKER-NU' "$CALLS"
  grep -q 'compose .* ps -q lcars' "$CALLS"
}

@test "up : image absente — un up ne la fabrique pas, il nomme pull et build, et sort 1" {
  seed_project "$CF"
  STUB_NO_IMAGE=1 run bash "$SRC" up
  [ "$status" -eq 1 ]
  [[ "$output" == *"image « ghcr.io/"*" » absente"*"deploy/container pull"*"deploy/container build"* ]]
  refute grep -qE "compose .* up|build" "$CALLS"
}
