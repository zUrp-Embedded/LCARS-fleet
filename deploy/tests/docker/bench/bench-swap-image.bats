#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/docker/bench/bench-swap-image.bats
# AUTHOR: DrDree
# STARDATE: 2026-09-13
# STATUS: témoins de bench-swap-image.sh — joué contre une doublure docker : projet, marqueur, drapeaux, override de banc, verdicts

load ../../refute
load ../../support/decor

setup() {
  decor_pose
  # un arbre dont les constantes portent des défauts que rien d'autre n'écrit : le script qui les rend les a lus
  local vrai="$BATS_TEST_DIRNAME/../../.." cles='PROV_FORGE_BASE_DEFAULT|PROV_FORGE_ORG_DEFAULT|PROV_FORGE_HOST_PORT_DEFAULT|PROV_DECK_PORT_DEFAULT|PROV_SSH_PORT_DEFAULT|PROV_FORGE_INTERNAL_URL'
  ARBRE="$BATS_TEST_TMPDIR/arbre"
  mkdir -p "$ARBRE/deploy/docker/bench" "$ARBRE/deploy/lib"
  cp "$vrai/docker/bench/bench-swap-image.sh" "$ARBRE/deploy/docker/bench/"
  cp "$vrai/lib/provision-lib.sh" "$vrai/lib/docker-endpoint.sh" "$vrai/lib/forge-bootstrap.sh" "$vrai/lib/store.sh" "$vrai/lib/bench.sh" "$ARBRE/deploy/lib/"
  CONSTANTES="$ARBRE/deploy/installer-constants.env"
  { grep -vE "^($cles)=" "$vrai/installer-constants.env"
    printf '%s\n' PROV_FORGE_BASE_DEFAULT=banc-temoin PROV_FORGE_ORG_DEFAULT=flotte-temoin PROV_FORGE_HOST_PORT_DEFAULT=4100 \
      PROV_DECK_PORT_DEFAULT=4999 PROV_SSH_PORT_DEFAULT=4222 PROV_FORGE_INTERNAL_URL=http://forge-temoin:3000
  } > "$CONSTANTES"
  SUT="$ARBRE/deploy/docker/bench/bench-swap-image.sh"
  BINDIR="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BINDIR"
  export CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  # OBJETS : « <nom>:<c|v>:<marqueur> », rangés dans le projet que leur nom porte ; JETONS : le compte du conteneur
  export OBJETS="banc-temoin-forge-gitea-1:c:banc-temoin bt-forge-gitea-1:c:bt bt-fleet-lcars-1:c:bt" JETONS=1 DOCKER_KO=""

  cat > "$BINDIR/dockerstub" <<'EOF'
#!/usr/bin/env bash
[[ -p /dev/stdin || -f /dev/stdin ]] && cat > /dev/null
echo "DOCKER:$*" >> "$CALLS"
objets() {
  local o nom type marque ligne
  for o in $OBJETS; do
    IFS=: read -r nom type marque <<<"$o"
    [[ "$type" == "$2" && "$nom" == "$1"[-_]* ]] || continue
    ligne="${3//\{\{.Names\}\}/$nom}"; ligne="${ligne//\{\{.Name\}\}/$nom}"
    printf '%s\n' "${ligne//\{\{.Label \"lcars.bench\"\}\}/$marque}"
  done
}
case "$*" in
  "ps -a --filter label=com.docker.compose.project="*)
    [[ "$DOCKER_KO" != ps ]] || exit 1
    objets "${4#label=com.docker.compose.project=}" c "$6" ;;
  "volume ls --filter label=com.docker.compose.project="*)
    objets "${4#label=com.docker.compose.project=}" v "$6" ;;
  *" up -d --no-build lcars") env | grep '^LCARS_\|^FORGE_' | sort | sed 's/^/ENV:/' >> "$CALLS"; exit 0 ;;
  "inspect -f {{.State.Health.Status}}"*) echo healthy; exit 0 ;;
  *"*.gitea_token"*)                       echo "$JETONS"; exit 0 ;;
  "inspect -f {{range .Config.Env}}"*)     echo "LCARS_IMAGE_REVISION=cafe1234"; exit 0 ;;
esac
exit 0
EOF
  chmod 0755 "$BINDIR/dockerstub"
  export PATH="$BINDIR:$PATH" DOCKER_BIN=dockerstub
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME/.claude"; printf 'CREDS' > "$HOME/.claude/.credentials.json"
}

run_swap() { run bash "$SUT" --image lcars-fleet:neuve --advertise 10.0.0.9 "$@"; }

@test "sans --image : refus en 1, et le conteneur n'est pas touché" {
  run bash "$SUT" --advertise 10.0.0.9
  [ "$status" -eq 1 ]
  [[ "$output" == *"--image est obligatoire"* ]]
  refute grep -q '^DOCKER:rm' "$CALLS"
}

@test "le projet par défaut est la base des constantes, celle que « container --bench » et install.sh créent" {
  run_swap
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx 'DOCKER:ps -a --filter label=com.docker.compose.project=banc-temoin-forge --format banc-temoin-forge conteneur {{.Names}} {{.Label "lcars.bench"}}' "$CALLS"
  grep -qx 'DOCKER:rm -f banc-temoin-fleet-lcars-1' "$CALLS"
}

@test "sans drapeau, les ports viennent des constantes et arrivent dans l'environnement de compose" {
  run_swap
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx 'ENV:LCARS_SSH_PORT=0.0.0.0:4222' "$CALLS"
  grep -qx 'ENV:LCARS_LANDING_PORT_BIND=0.0.0.0:4999' "$CALLS"
  grep -qx 'ENV:FORGE_PUBLIC_URL=http://10.0.0.9:4100' "$CALLS"
  grep -qx 'ENV:LCARS_ADMIRAL=admiral' "$CALLS"
}

@test "les drapeaux de container et de bench-up sont acceptés, et arrivent dans l'environnement de compose" {
  run_swap --forge-project bt --port-forge 31000 --port-deck 30999 --port-ssh 3222 --bind 127.0.0.1
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx 'ENV:LCARS_SSH_PORT=127.0.0.1:3222' "$CALLS"
  grep -qx 'ENV:LCARS_LANDING_PORT_BIND=127.0.0.1:30999' "$CALLS"
  grep -qx 'ENV:FORGE_PUBLIC_URL=http://10.0.0.9:31000' "$CALLS"
  grep -qx 'ENV:LCARS_DECK_ORIGINS=http://10.0.0.9:30999' "$CALLS"
  grep -qx 'ENV:LCARS_DEVFORGE_NETWORK=bt-forge_default' "$CALLS"
  grep -qx 'ENV:LCARS_STORE_PREFIX=bt-fleet' "$CALLS"
  grep -qx 'ENV:LCARS_BENCH_BASE=bt' "$CALLS"
  refute grep -q '^ENV:LCARS_BIND=' "$CALLS"
}

@test "le conteneur est recréé par up avec les constantes et l'override de banc : bench-down et container le reconnaissent encore" {
  run_swap --forge-project bt
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qxE "DOCKER:compose --env-file [^ ]+ -f $ARBRE/deploy/docker/docker-compose.yml -f $ARBRE/deploy/docker/docker-compose.bench.yml -p bt-fleet up -d --no-build lcars" "$CALLS"
  local f
  for f in $(grep -oE '^DOCKER:compose --env-file [^ ]+' "$CALLS" | cut -d' ' -f3); do
    [ "$(readlink -f "$f")" = "$CONSTANTES" ]
  done
  refute grep -q '^DOCKER:network connect' "$CALLS"
}

@test "pas de forge de banc : pas de banc, refus en 1 avant de détruire le conteneur" {
  run_swap --forge-project absent
  [ "$status" -eq 1 ]
  [[ "$output" == *"aucune forge de banc absent-forge"* ]]
  refute grep -q '^DOCKER:rm' "$CALLS"
}

@test "la forge d'un poste homonyme (sans marqueur) : refus en 1, le conteneur du poste n'est pas détruit" {
  OBJETS="lcars-forge-gitea-1:c: lcars-forge_data:v: lcars-fleet-lcars-1:c:" run_swap --forge-project lcars
  [ "$status" -eq 1 ]
  [[ "$output" == *"sans son marqueur"*"conteneur lcars-forge-gitea-1 (projet lcars-forge)"* ]]
  refute grep -q '^DOCKER:rm' "$CALLS"
  refute grep -q '^DOCKER:compose' "$CALLS"
}

@test "une requête docker en échec : refus en 1, rien n'est détruit" {
  DOCKER_KO="ps" run_swap --forge-project bt
  [ "$status" -eq 1 ]
  [[ "$output" == *"docker ne rend pas les objets"* ]]
  refute grep -q '^DOCKER:rm' "$CALLS"
}

@test "aucun jeton de rôle après la relance : sortie 6" {
  JETONS=0 run_swap
  [ "$status" -eq 6 ]
  [[ "$output" == *"aucun jeton de rôle"* ]]
}

@test "le récapitulatif dit jetons, credentials et révision" {
  run_swap
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"image     : lcars-fleet:neuve   (révision cafe1234)"* ]]
  # sous un décor, le dossier des jetons lu dans le conteneur reste son chemin canonique
  [[ "$output" == *"jetons    : 1 fichiers dans /opt/lcars/var/tokens"$'\n'* ]]
  [[ "$output" == *"creds     : oui"* ]]
}

@test "--no-creds : rien n'est lu ni posé, et le récapitulatif dit non" {
  run_swap --no-creds --creds-from "$BATS_TEST_TMPDIR/absent.json"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"creds claude non posées (--no-creds)"*"creds     : non"* ]]
  refute grep -q 'mkdir -p ~/.claude' "$CALLS"
}

@test "credentials absentes : la même règle que le banc, dites, et le swap continue" {
  run_swap --creds-from "$BATS_TEST_TMPDIR/absent.json"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"creds claude absentes"*"creds     : non"* ]]
  refute grep -q 'mkdir -p ~/.claude' "$CALLS"
}
