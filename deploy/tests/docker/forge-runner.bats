#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/docker/forge-runner.bats
# AUTHOR: bob
# STARDATE: 2026-09-14
# STATUS: témoins de forge-runner.sh au-delà des labels — jetons par fichier, forge HTTP locale, environnement de compose, compose relu, semis du daemon embarqué, verdicts

load ../refute
load ../support/decor
load ../support/compose

# un PATH qui porte tout celui de la machine sauf python3 : forge-runner lit la forge par jq
setup_file() {
  local d="$BATS_FILE_TMPDIR/sans-python3" dir f n
  local -A vu=()
  local -a dirs liens=()
  mkdir -p "$d"
  IFS=: read -ra dirs <<<"$PATH"
  for dir in "${dirs[@]}"; do
    for f in "$dir"/*; do
      n="${f##*/}"
      [[ -f "$f" && -x "$f" && -z "${vu[$n]:-}" ]] || continue
      case "$n" in python3|python3.*) continue ;; esac
      vu[$n]=1; liens+=("$f")
    done
  done
  ln -s -t "$d" "${liens[@]}"
  export SANS_PYTHON3="$d"
}

setup() {
  decor_pose
  # un arbre dont les constantes portent des valeurs que rien d'autre n'écrit
  local vrai="$BATS_TEST_DIRNAME/../.."
  ARBRE="$BATS_TEST_TMPDIR/arbre"
  mkdir -p "$ARBRE/deploy/docker" "$ARBRE/deploy/lib"
  cp "$vrai/docker/forge-runner.sh" "$vrai/docker/runner-compose.yml" "$vrai/docker/runner-compose.bench.yml" "$vrai/docker/runner-network.yml" "$ARBRE/deploy/docker/"
  cp "$vrai/lib/provision-lib.sh" "$vrai/lib/docker-endpoint.sh" "$ARBRE/deploy/lib/"
  CONSTANTES="$ARBRE/deploy/installer-constants.env"
  { grep -vE '^(PROV_FORGE_INTERNAL_URL|PROV_RUNNER_LABELS)=' "$vrai/installer-constants.env"
    printf '%s\n' PROV_FORGE_INTERNAL_URL=http://forge-temoin:3000 PROV_RUNNER_LABELS=shell:docker://alpine:temoin
  } > "$CONSTANTES"
  SRC="$ARBRE/deploy/docker/forge-runner.sh"

  forge_double_start
  FORGE_API="$FORGE_DOUBLE_URL/api/v1"

  BINDIR="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BINDIR"
  export CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  export UP_RC="$BATS_TEST_TMPDIR/up_rc";   echo 0 > "$UP_RC"
  export DIND_OUT="$BATS_TEST_TMPDIR/dind"; echo "27.0.0" > "$DIND_OUT"
  export DIND_CHARGE="$BATS_TEST_TMPDIR/dind-charge"
  # le compose de la pose est relu par compose lui-même, sans daemon, et son rendu JSON gardé ;
  # l'environnement qu'il reçoit est noté, et l'arbre de TMPDIR listé au même instant
  export RENDU="$BATS_TEST_TMPDIR/rendu.json" NO_DAEMON="unix://$BATS_TEST_TMPDIR/aucun-daemon.sock"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
  REAL_DOCKER="$(command -v docker)"; REAL_CURL="$(command -v curl)"
  export REAL_DOCKER REAL_CURL

  cat > "$BINDIR/dockerstub" <<'EOF'
#!/usr/bin/env bash
echo "DOCKER:$*" >> "$CALLS"
case "$*" in
  "image inspect "*)                    exit 0 ;;
  "compose "*" up -d")
    env | grep -E '^LCARS_(FORGE_URL|RUNNER_[A-Z]+)=' | sort | sed 's/^/ENV:/' >> "$CALLS"
    grep -rl 'REG-' "$TMPDIR" 2>/dev/null | sed 's/^/FICHIER-A-JETON:/' >> "$CALLS"
    DOCKER_HOST="$NO_DAEMON" "$REAL_DOCKER" "${@:1:$#-2}" config --format json > "$RENDU" 2>&1
    exit "$(cat "$UP_RC")" ;;
  "exec "*" docker version "*)          cat "$DIND_OUT"; exit 0 ;;
  "exec -i "*" docker load")            : > "$DIND_CHARGE"; exit 0 ;;
  # outil-local:9 n'est dans le daemon du runner qu'une fois chargée depuis la machine
  "exec "*" docker image inspect "*)    [[ " $* " != *" outil-local:9 "* || -e "$DIND_CHARGE" ]] || exit 0; echo sha256:abc; exit 0 ;;
esac
exit 0
EOF
  cat > "$BINDIR/curl" <<'EOF'
#!/usr/bin/env bash
echo "CURL-ARGV:$*" >> "$CALLS"
exec "$REAL_CURL" "$@"
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BINDIR/sleep"
  chmod 0755 "$BINDIR/dockerstub" "$BINDIR/curl" "$BINDIR/sleep"
  export PATH="$BINDIR:$DECOR_BIN:$SANS_PYTHON3" DOCKER_BIN=dockerstub
  unset LCARS_RUNNER_LABELS

  ADMIN="$BATS_TEST_TMPDIR/admin.token"; printf 'ADMIN-TOK\n' > "$ADMIN"
  REGF="$BATS_TEST_TMPDIR/reg.token"; printf 'REG-FILE\n' > "$REGF"
}

teardown() { forge_double_stop; }

# une route posée par un cas passe devant : la première qui répond sert
routes_nominales() {
  forge_route POST /api/v1/admin/actions/runners/registration-token 200 '{"token":"REG-API"}'
  forge_route GET /api/v1/admin/actions/runners 200 '{"runners":[{"id":1}]}'
}

run_runner() {
  run bash "$SRC" --forge-api "$FORGE_API" --admin-token-file "$ADMIN" \
      --network bt-forge_default --project bt-runner --labels "shell:docker://alpine:3.20" "$@"
}

@test "un jeton en argv n'est plus accepté : --admin-token et --reg-token sont des options inconnues" {
  run bash "$SRC" --forge-api "$FORGE_API" --admin-token ADMIN-TOK --network n --project p
  [ "$status" -eq 1 ]
  [[ "$output" == *"option inconnue : --admin-token"* ]]
  run_runner --reg-token REG
  [ "$status" -eq 1 ]
  [[ "$output" == *"option inconnue : --reg-token"* ]]
  refute grep -q '^DOCKER:.* up ' "$CALLS"
}

@test "un fichier de jeton admin vide est un refus d'arguments" {
  : > "$ADMIN"
  run_runner
  [ "$status" -eq 1 ]
  [[ "$output" == *"--admin-token-file (non vide) requis"* ]]
}

@test "--reg-token-file : aucun appel à l'API d'enregistrement, le jeton arrive à compose par son environnement et aucun fichier ne le porte" {
  routes_nominales
  run_runner --reg-token-file "$REGF"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"jeton d'enregistrement fourni (--reg-token-file)"* ]]
  forge_requests '.path' | refute_out 'registration-token'
  grep -qx 'ENV:LCARS_RUNNER_TOKEN=REG-FILE' "$CALLS"
  refute grep -q '^FICHIER-A-JETON:' "$CALLS"
  refute grep -qE '^DOCKER:.*(REG-FILE|ADMIN-TOK)' "$CALLS"
}

@test "sans fichier de jeton d'enregistrement : la forge le mint sur le jeton admin reçu en en-tête, et jq le lit" {
  routes_nominales
  run_runner
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(forge_requests 'select(.path == "/api/v1/admin/actions/runners/registration-token") | [.method, .auth]')" = '["POST","token ADMIN-TOK"]' ]
  grep -qx 'ENV:LCARS_RUNNER_TOKEN=REG-API' "$CALLS"
  grep '^CURL-ARGV:' "$CALLS" | refute_out 'ADMIN-TOK'
}

@test "sans --instance-url, le runner vise l'adresse interne de la forge écrite dans les constantes" {
  routes_nominales
  run_runner
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx 'ENV:LCARS_FORGE_URL=http://forge-temoin:3000' "$CALLS"
}

@test "le runner se retire puis se pose, chaque fois par un compose qui lit les constantes de l'installeur" {
  routes_nominales
  run_runner
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(grep -c '^DOCKER:compose ' "$CALLS")" -eq 2 ]
  grep -q '^DOCKER:compose .* -p bt-runner down -v$' "$CALLS"
  grep -q '^DOCKER:compose .* -p bt-runner up -d$' "$CALLS"
  local f
  for f in $(grep -oE '^DOCKER:compose --env-file [^ ]+' "$CALLS" | cut -d' ' -f3); do
    [ "$(readlink -f "$f")" = "$CONSTANTES" ]
  done
}

@test "la pose se relit par compose : adresse de --instance-url, réseau externe de la forge, aucune config copiée" {
  compose_requis
  routes_nominales
  run_runner --instance-url http://host.docker.internal:21000
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(jq -r '.services.act.environment.GITEA_INSTANCE_URL' "$RENDU")" = http://host.docker.internal:21000 ] || { cat "$RENDU"; return 1; }
  [ "$(jq -c '.networks.default | [.name, .external]' "$RENDU")" = '["bt-forge_default",true]' ]
  [ "$(jq -r '.services.act.environment.CONFIG_FILE // "absent"' "$RENDU")" = absent ]
  refute grep -q '^DOCKER:cp ' "$CALLS"
}

@test "--bench : la surcouche de banc marque le runner et ses volumes ; sans lui, aucun label, même sous un LCARS_BENCH_BASE de l'environnement" {
  compose_requis
  routes_nominales
  run_runner --bench bt
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(jq -c '[.services.act.labels["lcars.bench"]] + [.volumes[].labels["lcars.bench"]]' "$RENDU")" = '["bt","bt","bt"]' ] || { cat "$RENDU"; return 1; }
  grep -q '^DOCKER:compose .* -f [^ ]*/runner-compose.bench.yml -p bt-runner down -v$' "$CALLS"
  : > "$CALLS"
  LCARS_BENCH_BASE=bt run_runner
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(jq -c '[.services.act.labels, (.volumes[] | .labels)] | map(select(. != null))' "$RENDU")" = '[]' ] || { cat "$RENDU"; return 1; }
  refute grep -q 'runner-compose.bench.yml' "$CALLS"
}

@test "sans --labels, compose rend les labels des constantes, et un LCARS_RUNNER_LABELS de l'environnement ne les remplace pas" {
  compose_requis
  routes_nominales
  LCARS_RUNNER_LABELS=shell:docker://alpine:environnement run bash "$SRC" --forge-api "$FORGE_API" --admin-token-file "$ADMIN" --network bt-forge_default --project bt-runner
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(jq -r '.services.act.environment.GITEA_RUNNER_LABELS' "$RENDU")" = shell:docker://alpine:temoin ] || { cat "$RENDU"; return 1; }
}

@test "--help rend l'usage et les codes de sortie, sans jeton ni appel à la forge ou au daemon" {
  run bash "$SRC" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"USAGE : forge-runner.sh --forge-api"*"--bench"*"EXIT"* ]]
  [ ! -s "$CALLS" ]
}

@test "--verify-repo et --accept-generic sont des options inconnues" {
  run_runner --verify-repo fleet/lcars
  [ "$status" -eq 1 ]
  [[ "$output" == *"option inconnue : --verify-repo"* ]]
  run_runner --accept-generic
  [ "$status" -eq 1 ]
  [[ "$output" == *"option inconnue : --accept-generic"* ]]
  refute grep -q '^DOCKER:compose' "$CALLS"
}

@test "la forge ne rend pas de jeton d'enregistrement : sortie 2, et rien n'est monté" {
  forge_route POST /api/v1/admin/actions/runners/registration-token 403 '{"message":"forbidden"}'
  run_runner
  [ "$status" -eq 2 ]
  [[ "$output" == *"pas rendu de jeton d'enregistrement"* ]]
  refute grep -q '^DOCKER:compose' "$CALLS"
}

@test "compose ne monte pas le runner : sortie 3, dite" {
  routes_nominales
  echo 1 > "$UP_RC"
  run_runner
  [ "$status" -eq 3 ]
  [[ "$output" == *"le runner ne se monte pas"* ]]
}

@test "le daemon embarqué ne répond pas : sortie 3, et aucune image n'est semée" {
  routes_nominales
  : > "$DIND_OUT"
  run_runner
  [ "$status" -eq 3 ]
  [[ "$output" == *"le daemon embarqué du runner ne rend rien"* ]]
  refute grep -q '^DOCKER:save' "$CALLS"
}

@test "le semis lit les images dans les labels reçus : chacune est demandée au daemon du runner, une absente y est chargée depuis la machine" {
  routes_nominales
  run bash "$SRC" --forge-api "$FORGE_API" --admin-token-file "$ADMIN" --network bt-forge_default --project bt-runner \
    --labels "shell:docker://alpine:3.20,outil:docker://outil-local:9,hote:host"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx 'DOCKER:exec bt-runner-act-1 docker image inspect -f {{.Id}} alpine:3.20' "$CALLS"
  grep -qx 'DOCKER:exec bt-runner-act-1 docker image inspect -f {{.Id}} outil-local:9' "$CALLS"
  grep -qx 'DOCKER:save outil-local:9' "$CALLS"
  refute grep -q '^DOCKER:save alpine' "$CALLS"
  [[ "$output" == *"image locale semée dans le daemon du runner : outil-local:9"* ]]
  # un label sans image docker:// n'est pas demandé
  refute grep -q 'inspect -f {{.Id}} hote' "$CALLS"
}

@test "la forge ne liste aucun runner : sortie 3, après une liste lue sur le jeton admin" {
  forge_route GET /api/v1/admin/actions/runners 200 '{"runners":[]}'
  routes_nominales
  run_runner
  [ "$status" -eq 3 ]
  [[ "$output" == *"la forge ne liste aucun runner"* ]]
  [ "$(forge_requests 'select(.path == "/api/v1/admin/actions/runners") | .auth' | sort -u)" = '"token ADMIN-TOK"' ]
}

@test "la liste des runners refusée au jeton (403) : non vérifié, dit, sortie 0" {
  forge_route GET /api/v1/admin/actions/runners 403 '{"message":"forbidden"}'
  routes_nominales
  run_runner
  [ "$status" -eq 0 ]
  [[ "$output" == *"NON VÉRIFIÉ (HTTP 403"* ]]
}
