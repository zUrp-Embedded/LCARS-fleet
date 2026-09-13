#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/docker/forge-runner.bats
# AUTHOR: bob
# STARDATE: 2026-09-13
# STATUS: témoins de forge-runner.sh au-delà des labels — jetons par fichier, env-file, override, semis du daemon embarqué, sorties 2 et 3

load ../refute

setup() {
  SRC="$BATS_TEST_DIRNAME/../../docker/forge-runner.sh"
  BINDIR="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BINDIR"
  export CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  # ce que les doublures rendent, un fichier par fait
  export REG_API_OUT="$BATS_TEST_TMPDIR/reg_api";   printf '{"token":"REG-API"}' > "$REG_API_OUT"
  export UP_RC="$BATS_TEST_TMPDIR/up_rc";           echo 0 > "$UP_RC"
  export DIND_OUT="$BATS_TEST_TMPDIR/dind";         echo "27.0.0" > "$DIND_OUT"
  export RUNNERS_CODE="$BATS_TEST_TMPDIR/code";     echo 200 > "$RUNNERS_CODE"
  export RUNNERS_BODY="$BATS_TEST_TMPDIR/body";     printf '{"runners":[{"id":1}]}' > "$RUNNERS_BODY"

  cat > "$BINDIR/dockerstub" <<'EOF'
#!/usr/bin/env bash
echo "DOCKER:$*" >> "$CALLS"
args=("$@")
for i in "${!args[@]}"; do
  if [[ "${args[$i]}" == --env-file && "$*" == *" up --no-start" ]]; then
    f="${args[$((i + 1))]}"
    echo "ENVFILE:mode=$(stat -c %a "$f")" >> "$CALLS"; sed 's/^/ENVFILE:/' "$f" >> "$CALLS"
  fi
  if [[ "${args[$i]}" == -f && "${args[$((i + 1))]}" == */override.yml && "$*" == *" up --no-start" ]]; then
    sed 's/^/OVERRIDE:/' "${args[$((i + 1))]}" >> "$CALLS"
  fi
done
case "$*" in
  "image inspect "*)                    exit 0 ;;
  *" up --no-start")                    exit "$(cat "$UP_RC")" ;;
  "exec "*" docker version "*)          cat "$DIND_OUT"; exit 0 ;;
  "exec "*" docker image inspect "*)    echo sha256:abc; exit 0 ;;
esac
exit 0
EOF
  cat > "$BINDIR/curl" <<'EOF'
#!/usr/bin/env bash
cfg=""; out=""; wfmt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -K) cfg="$(cat)"; shift ;;
    -o) out="$2"; shift 2 ;;
    -w) wfmt="$2"; shift 2 ;;
    *)  url="$1"; shift ;;
  esac
done
echo "CURL:$url | $(tr '\n' ' ' <<<"$cfg")" >> "$CALLS"
case "$url" in
  */registration-token) cat "$REG_API_OUT" ;;
  */admin/actions/runners) cat "$RUNNERS_BODY" > "${out:-/dev/stdout}"; [[ -z "$wfmt" ]] || cat "$RUNNERS_CODE" ;;
esac
exit 0
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BINDIR/sleep"
  chmod 0755 "$BINDIR/dockerstub" "$BINDIR/curl" "$BINDIR/sleep"
  export PATH="$BINDIR:$PATH" DOCKER_BIN=dockerstub
  unset LCARS_RUNNER_LABELS LCARS_RUNNER_NAME

  ADMIN="$BATS_TEST_TMPDIR/admin.token"; printf 'ADMIN-TOK\n' > "$ADMIN"
  REGF="$BATS_TEST_TMPDIR/reg.token"; printf 'REG-FILE\n' > "$REGF"
}

run_runner() {
  run bash "$SRC" --forge-api http://f/api/v1 --admin-token-file "$ADMIN" \
      --network bt-forge_default --project bt-runner --labels "shell:docker://alpine:3.20" "$@"
}

@test "un jeton en argv n'est plus accepté : --admin-token et --reg-token sont des options inconnues" {
  run bash "$SRC" --forge-api http://f/api/v1 --admin-token ADMIN-TOK --network n --project p
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
  run_runner --reg-token-file "$REGF"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"jeton d'enregistrement fourni (--reg-token-file)"* ]]
  refute grep -q 'CURL:.*registration-token' "$CALLS"
  grep -qx 'ENVFILE:mode=600' "$CALLS"
  grep -qx 'ENVFILE:LCARS_RUNNER_TOKEN=REG-FILE' "$CALLS"
  refute grep -qE '^DOCKER:.*(REG-FILE|ADMIN-TOK)' "$CALLS"
}

@test "sans fichier de jeton d'enregistrement : l'API le mint, le jeton admin ne passe que par la config de curl" {
  run_runner
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q 'CURL:http://f/api/v1/admin/actions/runners/registration-token | header = "Authorization: token ADMIN-TOK"' "$CALLS"
  grep -qx 'ENVFILE:LCARS_RUNNER_TOKEN=REG-API' "$CALLS"
  grep -qx 'ENVFILE:LCARS_FORGE_URL=http://gitea:3000' "$CALLS"
}

@test "--instance-url arrive dans l'env-file, et l'override rattache le runner au réseau externe de la forge" {
  run_runner --instance-url http://host.docker.internal:21000
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx 'ENVFILE:LCARS_FORGE_URL=http://host.docker.internal:21000' "$CALLS"
  grep -qx 'OVERRIDE:  act:' "$CALLS"
  grep -qx 'OVERRIDE:    name: bt-forge_default' "$CALLS"
  grep -qx 'OVERRIDE:    external: true' "$CALLS"
  grep -q '^DOCKER:cp .*/config.yaml bt-runner-act-1:/data/bench-config.yaml' "$CALLS"
}

@test "la forge ne rend pas de jeton d'enregistrement : sortie 2, et rien n'est monté" {
  printf '{"message":"forbidden"}' > "$REG_API_OUT"
  run_runner
  [ "$status" -eq 2 ]
  [[ "$output" == *"pas rendu de jeton d'enregistrement"* ]]
  refute grep -q '^DOCKER:compose' "$CALLS"
}

@test "compose ne monte pas le runner : sortie 3, dite" {
  echo 1 > "$UP_RC"
  run_runner
  [ "$status" -eq 3 ]
  [[ "$output" == *"le runner ne se monte pas"* ]]
}

@test "le daemon embarqué ne répond pas : sortie 3, et aucune image n'est semée" {
  : > "$DIND_OUT"
  run_runner
  [ "$status" -eq 3 ]
  [[ "$output" == *"le daemon embarqué du runner ne rend rien"* ]]
  refute grep -q '^DOCKER:save' "$CALLS"
}

@test "la forge ne liste aucun runner : sortie 3" {
  printf '{"runners":[]}' > "$RUNNERS_BODY"
  run_runner
  [ "$status" -eq 3 ]
  [[ "$output" == *"la forge ne liste aucun runner"* ]]
}

@test "la liste des runners refusée au jeton (403) : non vérifié, dit, sortie 0" {
  echo 403 > "$RUNNERS_CODE"
  run_runner
  [ "$status" -eq 0 ]
  [[ "$output" == *"NON VÉRIFIÉ (HTTP 403"* ]]
}
