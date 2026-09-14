#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/docker/bench/bench-down.bats
# AUTHOR: DrDree
# STARDATE: 2026-09-13
# STATUS: témoins de bench-down.sh — ce dont un banc est fait, l'ordre de sa destruction, et ce qui n'est pas un banc

load ../../refute

setup() {
  SRC="$BATS_TEST_DIRNAME/../../../docker/bench/bench-down.sh"
  BINDIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BINDIR"
  CALLS="$BATS_TEST_TMPDIR/docker.calls"
  : > "$CALLS"
  export CALLS

  # PRESENT : les conteneurs du daemon ; VOLUMES : ses volumes ; FLEET_FILES : les fichiers compose
  # inscrits sur le conteneur du projet <base>-fleet
  export PRESENT="" VOLUMES="" FLEET_FILES="/r/deploy/docker/docker-compose.yml,/r/deploy/docker/docker-compose.bench.yml"
  # un down émis est relu par compose lui-même, sans daemon : ses fichiers, ses constantes et son environnement suffisent-ils ?
  REAL_DOCKER="$(command -v docker)"
  export REAL_DOCKER NO_DAEMON="unix://$BATS_TEST_TMPDIR/aucun-daemon.sock"

  cat > "$BINDIR/dockerstub" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
if [[ "$1" == compose && "$*" == *" down -v --remove-orphans" ]]; then
  if err="$(DOCKER_HOST="$NO_DAEMON" "$REAL_DOCKER" "${@:1:$#-3}" config -q 2>&1)"; then echo "LU:${*: -4:1}" >> "$CALLS"
  else echo "ILLISIBLE:${*: -4:1}: $err" >> "$CALLS"
  fi
fi
case "$*" in
  "ps -aq --filter label=com.docker.compose.project=bt-fleet")
    for n in $PRESENT; do [[ "$n" == bt-fleet-* ]] && echo "id-$n"; done; exit 0 ;;
  "ps -a"*)     printf '%s\n' $PRESENT ;;
  "volume ls"*) printf '%s\n' $VOLUMES ;;
  "inspect "*)  echo "$FLEET_FILES" ;;
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

# l'index du premier appel qui porte un motif, ou "" : cette suite lit l'ordre
idx_of() {
  grep -n -- "$1" "$CALLS" | head -1 | cut -d: -f1
}

@test "un banc complet : les trois projets compose sont descendus, aucun oublié" {
  PRESENT="bt-fleet-lcars-1 bt-runner-act-1 bt-forge-gitea-1" run_down

  [ "$status" -eq 0 ]
  grep -q -- "-p bt-runner down -v" "$CALLS"
  grep -q -- "-p bt-fleet down -v" "$CALLS"
  grep -q -- "-p bt-forge down -v" "$CALLS"
}

@test "le runner part en premier : il tient le réseau de la forge" {
  PRESENT="bt-fleet-lcars-1 bt-runner-act-1 bt-forge-gitea-1" run_down

  runner="$(idx_of '\-p bt-runner down')"
  forge="$(idx_of '\-p bt-forge down')"
  [ -n "$runner" ]
  [ -n "$forge" ]
  [ "$runner" -lt "$forge" ]
}

@test "le magasin du banc est détruit, volume par volume" {
  PRESENT="bt-fleet-lcars-1 bt-forge-gitea-1" run_down

  [ "$status" -eq 0 ]
  local v
  for v in bt-fleet-cache bt-fleet-toolchains bt-fleet-sysroots bt-fleet-state; do
    grep -qx "volume rm -f $v" "$CALLS" || { echo "non détruit : $v"; return 1; }
  done
}

@test "un banc à moitié détruit (conteneur parti, runner debout) se termine" {
  PRESENT="bt-runner-act-1" run_down

  [ "$status" -eq 0 ]
  grep -q -- "-p bt-runner down -v" "$CALLS"
}

@test "seule la forge survit (bench-up mort avant le conteneur) : détruite quand même" {
  PRESENT="bt-forge-gitea-1" run_down

  [ "$status" -eq 0 ]
  grep -q -- "-p bt-forge down -v" "$CALLS"
}

@test "plus aucun conteneur, mais les volumes de la forge restent : détruits quand même" {
  PRESENT="someone-elses-container" VOLUMES="bt-forge_data bt-forge_config" run_down

  [ "$status" -eq 0 ]
  grep -q -- "-p bt-forge down -v" "$CALLS"
}

@test "un magasin resté à côté de sa forge compte comme résidu, et il est détruit" {
  VOLUMES="bt-forge_data bt-fleet-cache bt-fleet-toolchains" run_down

  [ "$status" -eq 0 ]
  grep -qx "volume rm -f bt-fleet-cache" "$CALLS"
}

@test "un magasin resté seul n'est pas « rien à détruire » : il est vu, et refusé faute de banc qui le porte" {
  VOLUMES="bt-fleet-cache bt-fleet-toolchains bt-fleet-sysroots bt-fleet-state" run_down

  [ "$status" -eq 1 ]
  [[ "$output" != *"rien à détruire"* ]]
  [[ "$output" == *"aucune forge ni runner de banc"* ]]
  refute grep -q -- "volume rm" "$CALLS"
}

@test "rien de ce banc n'existe : sortie 2, et pas un appel destructeur" {
  PRESENT="someone-elses-container" VOLUMES="someoneelses_data" run_down

  [ "$status" -eq 2 ]
  refute grep -q -- "down -v" "$CALLS"
  refute grep -q -- "volume rm" "$CALLS"
}

@test "un conteneur <base>-fleet créé sans l'override de banc est refusé : c'est une instance posée" {
  FLEET_FILES="/r/deploy/docker/docker-compose.yml,/r/deploy/docker/docker-compose.secrets.yml" \
    PRESENT="bt-fleet-lcars-1" run_down

  [ "$status" -eq 1 ]
  [[ "$output" == *"n'est pas un banc"*"sans docker-compose.bench.yml"*"deploy/container -p bt-fleet reset"* ]]
  refute grep -q -- "down -v" "$CALLS"
  refute grep -q -- "volume rm" "$CALLS"
}

@test "des volumes <base>-fleet sans forge ni runner de banc sont refusés, magasin compris" {
  VOLUMES="bt-fleet_lcars-home bt-fleet-cache bt-fleet-state" run_down

  [ "$status" -eq 1 ]
  [[ "$output" == *"aucune forge ni runner de banc"* ]]
  refute grep -q -- "down -v" "$CALLS"
  refute grep -q -- "volume rm" "$CALLS"
}

@test "--yes reste exigé, et son absence ne détruit rien" {
  PRESENT="bt-fleet-lcars-1 bt-runner-act-1"
  run bash "$SRC" --project bt

  [ "$status" -eq 1 ]
  refute grep -q -- "down -v" "$CALLS"
}

@test "les trois down se lisent par compose : les constantes de l'installeur, et une adresse factice pour le runner" {
  PRESENT="bt-fleet-lcars-1 bt-runner-act-1 bt-forge-gitea-1" run_down

  [ "$status" -eq 0 ]
  refute grep -q '^ILLISIBLE:' "$CALLS"
  grep -qx 'LU:bt-runner' "$CALLS"
  grep -qx 'LU:bt-fleet' "$CALLS"
  grep -qx 'LU:bt-forge' "$CALLS"
  local constantes f; constantes="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/installer-constants.env"
  [ "$(grep -c -- '^compose --env-file ' "$CALLS")" -eq 3 ]
  for f in $(grep -oE -- '^compose --env-file [^ ]+' "$CALLS" | cut -d' ' -f3); do
    [ "$(readlink -f "$f")" = "$constantes" ]
  done
}
