#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/docker/forge-runner.bats
# AUTHOR: bob
# STARDATE: 2026-09-14
# STATUS: témoins de forge-runner.sh au-delà des labels — jetons par fichier, forge HTTP locale, env-file, compose relu, semis du daemon embarqué, verdicts

load ../refute
load ../support/decor

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
  cp "$vrai/docker/forge-runner.sh" "$vrai/docker/runner-compose.yml" "$ARBRE/deploy/docker/"
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
  # le compose de la pose est relu par compose lui-même, sans daemon, et son rendu JSON gardé
  export RENDU="$BATS_TEST_TMPDIR/rendu.json" NO_DAEMON="unix://$BATS_TEST_TMPDIR/aucun-daemon.sock"
  REAL_DOCKER="$(command -v docker)"; REAL_CURL="$(command -v curl)"
  export REAL_DOCKER REAL_CURL

  cat > "$BINDIR/dockerstub" <<'EOF'
#!/usr/bin/env bash
echo "DOCKER:$*" >> "$CALLS"
case "$*" in
  "image inspect "*)                    exit 0 ;;
  "compose "*" up --no-start")
    prev="" envfile=""
    for a in "$@"; do [[ "$prev" == --env-file ]] && envfile="$a"; prev="$a"; done
    echo "ENVFILE:mode=$(stat -c %a "$envfile")" >> "$CALLS"; sed 's/^/ENVFILE:/' "$envfile" >> "$CALLS"
    DOCKER_HOST="$NO_DAEMON" "$REAL_DOCKER" "${@:1:$#-2}" config --format json > "$RENDU" 2>&1
    exit "$(cat "$UP_RC")" ;;
  "exec "*" docker version "*)          cat "$DIND_OUT"; exit 0 ;;
  "exec "*" docker image inspect "*)    echo sha256:abc; exit 0 ;;
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
  unset LCARS_RUNNER_LABELS LCARS_RUNNER_NAME

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

@test "--reg-token-file : aucun appel à l'API d'enregistrement, et le jeton voyage par un env-file 0600" {
  routes_nominales
  run_runner --reg-token-file "$REGF"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"jeton d'enregistrement fourni (--reg-token-file)"* ]]
  forge_requests '.path' | refute_out 'registration-token'
  grep -qx 'ENVFILE:mode=600' "$CALLS"
  grep -qx 'ENVFILE:LCARS_RUNNER_TOKEN=REG-FILE' "$CALLS"
  refute grep -qE '^DOCKER:.*(REG-FILE|ADMIN-TOK)' "$CALLS"
}

@test "sans fichier de jeton d'enregistrement : la forge le mint sur le jeton admin reçu en en-tête, et jq le lit" {
  routes_nominales
  run_runner
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(forge_requests 'select(.path == "/api/v1/admin/actions/runners/registration-token") | [.method, .auth]')" = '["POST","token ADMIN-TOK"]' ]
  grep -qx 'ENVFILE:LCARS_RUNNER_TOKEN=REG-API' "$CALLS"
  grep '^CURL-ARGV:' "$CALLS" | refute_out 'ADMIN-TOK'
}

@test "sans --instance-url, le runner vise l'adresse interne de la forge écrite dans les constantes" {
  routes_nominales
  run_runner
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx 'ENVFILE:LCARS_FORGE_URL=http://forge-temoin:3000' "$CALLS"
}

@test "chaque compose du runner lit les constantes de l'installeur" {
  routes_nominales
  run_runner
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(grep -c '^DOCKER:compose ' "$CALLS")" -eq 3 ]
  local f
  for f in $(grep -oE '^DOCKER:compose --env-file [^ ]+' "$CALLS" | cut -d' ' -f3); do
    [ "$(readlink -f "$f")" = "$CONSTANTES" ]
  done
}

@test "la pose se relit par compose : adresse de --instance-url, réseau externe de la forge, config copiée" {
  routes_nominales
  run_runner --instance-url http://host.docker.internal:21000
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(jq -r '.services.act.environment.GITEA_INSTANCE_URL' "$RENDU")" = http://host.docker.internal:21000 ] || { cat "$RENDU"; return 1; }
  [ "$(jq -c '.networks.default | [.name, .external]' "$RENDU")" = '["bt-forge_default",true]' ]
  grep -q '^DOCKER:cp .*/config.yaml bt-runner-act-1:/data/bench-config.yaml' "$CALLS"
}

@test "--accept-generic : compose rend les labels des constantes" {
  routes_nominales
  run bash "$SRC" --forge-api "$FORGE_API" --admin-token-file "$ADMIN" --network bt-forge_default --project bt-runner --accept-generic
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(jq -r '.services.act.environment.GITEA_RUNNER_LABELS' "$RENDU")" = shell:docker://alpine:temoin ] || { cat "$RENDU"; return 1; }
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

@test "--verify-repo lit le statut du dernier run : success est la preuve, failure sort en 4" {
  forge_route GET /api/v1/repos/fleet/lcars/actions/tasks 200 x1 '{"workflow_runs":[{"status":"success"}]}'
  forge_route GET /api/v1/repos/fleet/lcars/actions/tasks 200 '{"workflow_runs":[{"status":"failure"}]}'
  routes_nominales
  run_runner --verify-repo fleet/lcars
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"PREUVE : un job a tourné et la forge rend un verdict vert"* ]]
  run_runner --verify-repo fleet/lcars
  [ "$status" -eq 4 ]
  [[ "$output" == *"le job de vérification finit en failure"* ]]
}
