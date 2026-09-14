#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/container_project.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-07
# STATUS: bats tests for deploy/container — a project NAME is not proof you are talking about the same container

load refute
load support/decor

# sans_outil <outil> : un dossier qui porte tout le PATH de la machine sauf <outil>
sans_outil() {
  local d="$BATS_FILE_TMPDIR/sans-$1" dir f n
  local -A vu=()
  local -a dirs liens=()
  mkdir -p "$d"
  IFS=: read -ra dirs <<<"$PATH"
  for dir in "${dirs[@]}"; do
    for f in "$dir"/*; do
      n="${f##*/}"
      [[ -f "$f" && -x "$f" && -z "${vu[$n]:-}" ]] || continue
      case "$n" in "$1"|"$1".*) continue ;; esac
      vu[$n]=1; liens+=("$f")
    done
  done
  ln -s -t "$d" "${liens[@]}"
  printf '%s\n' "$d"
}

setup_file() {
  SANS_DOCKER="$(sans_outil docker)"
  export SANS_DOCKER
}

setup() {
  decor_pose
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SRC="$REPO/deploy/container"
  CF="$REPO/deploy/docker/docker-compose.yml"

  BINDIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BINDIR"
  CALLS="$BATS_TEST_TMPDIR/docker.calls"
  : > "$CALLS"
  local real_docker; real_docker="$(command -v docker)"

  cat > "$BINDIR/docker" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
if [[ "\$*" == *" config --images" ]]; then DOCKER_HOST="unix://$BATS_TEST_TMPDIR/aucun-daemon.sock" exec "$real_docker" "\$@"; fi
if [[ "\$1 \$2" == "image inspect" && -n "\${STUB_NO_IMAGE:-}" ]]; then exit 1; fi
case "\$1 \$2" in
  "compose version") exit 0 ;;
  "ps -aq")          printf '%s' "\${STUB_IDS:-}"; [[ -n "\${STUB_IDS:-}" ]] && echo; exit 0 ;;
  "volume ls")       printf '%s' "\${STUB_VOLUMES:-}"; [[ -n "\${STUB_VOLUMES:-}" ]] && echo; exit 0 ;;
  "inspect \${STUB_IDS:-__none__}") echo "\${STUB_CONFIG_FILES:-}"; exit 0 ;;
esac
exit 0
EOF
  chmod 0755 "$BINDIR/docker"

  export PATH="$BINDIR:$PATH"
  unset LCARS_PROJECT STUB_IDS STUB_CONFIG_FILES STUB_VOLUMES

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

@test "reset sans terminal : dit que la confirmation manque, annule, et n'imprime aucune erreur de bash" {
  seed_project "$CF"
  run setsid --wait bash "$SRC" -p lcars-a-moi reset </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"la confirmation se tape dans un terminal, et il n'y en a pas ici."*"container: annulé."* ]]
  [[ "$output" != *"/dev/tty"* ]]
  refute grep -q -- "down -v" "$CALLS"
}

@test "reset confirmé : compose down -v retire le conteneur et les volumes du projet, aucun volume n'est retiré à la main" {
  seed_project "$CF"
  run script -qec "bash '$SRC' -p lcars-a-moi reset" /dev/null <<<yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"reset fait"* ]]
  grep -qE -- "-p lcars-a-moi down -v$" "$CALLS"
  refute grep -q 'volume rm' "$CALLS"
}

@test "reset : un volume que compose down -v laisse (monté ailleurs) est relu et nommé, jamais « reset fait »" {
  seed_project "$CF"
  # compose rend 0 et laisse le volume : la relecture après le down le voit encore
  export STUB_VOLUMES="lcars-a-moi_lcars-home"
  run script -qec "bash '$SRC' -p lcars-a-moi reset" /dev/null <<<yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"encore là après compose down -v : lcars-a-moi_lcars-home"*"docker volume rm"* ]]
  [[ "$output" != *"reset fait"* ]]
  [ "$(grep -c '^volume ls' "$CALLS")" -eq 2 ]
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

@test "help works with NO docker at all, is not truncated, and creates no secrets file" {
  # Help is the one command that must survive a machine without docker — it is what you read to
  # find out what is missing.
  run env PATH="$SANS_DOCKER" timeout 15 bash "$SRC" help

  [ "$status" -eq 0 ]
  # First line of the block and last line of the block: the extraction is anchored on content, so
  # inserting a header line can no longer amputate the tail.
  [[ "$output" == *"USAGE : deploy/container"* ]]
  [[ "$output" == *"EXIT :"* ]]
  # And the -p contract is documented where an operator looks for it.
  [[ "$output" == *"LCARS_PROJECT"* ]]
  [ ! -e "$LCARS_CONTAINER_CONF_DIR" ]
}


@test "up ne bâtit jamais : compose reçoit --no-build" {
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BINDIR/sleep"; chmod 0755 "$BINDIR/sleep"
  run "$SRC" -p lcars up
  grep -q -- ' up -d --no-build' "$CALLS"
  refute grep -qE '(^| )build( |$)' "$CALLS"
}

# arbre_container — une copie de container avec ses libs, ses compose et ses constantes, où les délégués se doublent
arbre_container() {
  ARBRE="$BATS_TEST_TMPDIR/arbre"
  mkdir -p "$ARBRE/deploy/docker/bench" "$ARBRE/deploy/lib"
  cp "$SRC" "$REPO/deploy/installer-constants.env" "$ARBRE/deploy/"
  cp -a "$REPO/deploy/lib/." "$ARBRE/deploy/lib/"
  cp "$CF" "$REPO/deploy/docker/docker-compose.secrets.yml" "$ARBRE/deploy/docker/"
}

@test "build DELEGUE a pack.sh — aucun docker build, aucun compose build ici" {
  arbre_container
  printf '#!/usr/bin/env bash\necho "PACK:$*"\n' > "$ARBRE/deploy/pack.sh"; chmod 0755 "$ARBRE/deploy/pack.sh"
  run bash "$ARBRE/deploy/container" build --no-image
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"PACK:--no-image"* ]]
  refute grep -qE -- "compose .*build|build --target" "$CALLS"
}



@test "un banc ne se recrée pas par un up simple : le remède mène à bench-swap-image, ou à bench-down puis --bench up — jamais à un --bench up sur le banc qui existe" {
  seed_project "$CF,$REPO/deploy/docker/docker-compose.bench.yml"
  LCARS_IMAGE=lcars-fleet:9 run bash "$SRC" -p lcars-fleet up
  [ "$status" -eq 1 ]
  [[ "$output" == *"est un banc"*"remplacer son conteneur : deploy/docker/bench/bench-swap-image.sh --forge-project lcars --image lcars-fleet:9"* ]]
  [[ "$output" == *"le remonter en entier : deploy/docker/bench/bench-down.sh --project lcars --yes, puis deploy/container --forge-project lcars --bench up"* ]]
  refute grep -q -- ' up -d' "$CALLS"
}

@test "--bench avec un projet qui ne suit pas le nommage du banc est refusé avant tout" {
  run bash "$SRC" -p mon-instance --bench up
  [ "$status" -eq 1 ]
  [[ "$output" == *"« mon-instance » n'en est pas un"* ]]
}

@test "l'aide ne promet plus une forge que l'operateur devrait apporter" {
  run env PATH="$SANS_DOCKER" timeout 15 bash "$SRC" help
  [[ "$output" == *"--bench"* ]]
  [[ "$output" != *"LCARS ne la"$'\n'*"fabrique pas"* ]]
  [[ "$output" != *"ne la fabrique pas"* ]]
}

@test "up --bench : exec du banc avec la base du projet, l'image et les ports traduits" {
  arbre_container
  local bench="$ARBRE/deploy/docker/bench"
  printf '#!/usr/bin/env bash\necho "BENCH:$*"; echo "DOCKER_BIN=$DOCKER_BIN"\n' > "$bench/bench-up.sh"; chmod 0755 "$bench/bench-up.sh"
  LCARS_IMAGE=lcars-fleet:9 run bash "$ARBRE/deploy/container" --forge-project bob_10 --port-forge 20100 --port-deck 20101 --port-ssh 20102 --bench up
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

@test "up et pull sans image lisible (compose ne rend pas celle du compose) : refus qui nomme LCARS_IMAGE, jamais une image vide" {
  seed_project "$CF"
  printf '#!/usr/bin/env bash\necho "$*" >> %q\n[[ "$*" == *" config --images" ]] && exit 1\n[[ "$1 $2" == "image inspect" ]] && exit 1\nexit 0\n' "$CALLS" > "$BINDIR/docker"
  local verbe
  for verbe in up pull; do
    run bash "$SRC" "$verbe"
    [ "$status" -eq 1 ]
    [[ "$output" == *"$verbe: aucune image nommée"*"LCARS_IMAGE=<registre/image:tag> deploy/container $verbe"* ]]
    [[ "$output" != *"« »"* ]]
  done
  refute grep -qE "compose .* up|^pull" "$CALLS"
}

@test "une instance posée par le compose d'un autre arbre LCARS (le kit d'une version précédente) est la nôtre : la mise à jour passe" {
  local kit=/home/bob/.lcars/kits/v0.9-beta/lcars_install/deploy/docker
  seed_project "$kit/docker-compose.yml,$kit/docker-compose.secrets.yml"
  run bash "$SRC" -p f63c-fleet down
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" != *"refus"* ]]
  grep -q -- "-p f63c-fleet down" "$CALLS"
  # un fichier qui ne fait que finir pareil, hors d'un arbre deploy/docker, reste étranger
  seed_project "/ailleurs/docker-compose.yml"
  run bash "$SRC" -p f63c-fleet down
  [ "$status" -eq 1 ]
  [[ "$output" == *"aucun compose d'instance LCARS ne l'a créé"* ]]
}

@test "down et reset d'un banc sont refusés avant tout geste : un banc se retire en entier par bench-down" {
  seed_project "$CF,$REPO/deploy/docker/docker-compose.bench.yml"
  local geste
  for geste in down reset; do
    : > "$CALLS"
    run setsid --wait bash "$SRC" -p b63b-fleet "$geste" </dev/null
    [ "$status" -eq 1 ] || { echo "$geste : $output"; return 1; }
    [[ "$output" == *"$geste: le projet « b63b-fleet » est un banc"*"deploy/docker/bench/bench-down.sh --project b63b --yes"* ]]
    [[ "$output" != *"Confirmer"* ]]
    refute grep -q -- "down" "$CALLS"
  done
}
