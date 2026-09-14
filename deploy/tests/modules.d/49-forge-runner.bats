#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/49-forge-runner.bats
# AUTHOR: alice
# STARDATE: 2026-09-12
# STATUS: témoins de 49-forge-runner — l'enrôlement du runner CI, reporté, sauté, refusé ou posé

load ../refute
load ../support/decor

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_)' || true)
  MODULE="$BATS_TEST_DIRNAME/../../modules.d/49-forge-runner.sh"; [ -f "$MODULE" ]
  DEPLOY="$BATS_TEST_DIRNAME/../.."
  export PROVISION_LIB="$DEPLOY/lib/provision-lib.sh"
  export PROVISION_MODULE=49-forge-runner PROV_SUBSTRATE=wsl PROV_HUMAN=zoe
  decor_pose
  MASTER="$LCARS_DECOR_ROOT/opt/lcars/var/tokens/forge-master.token"
  printf 'MASTERTOK' > "$MASTER"
  forge_double_start
  # la forge du poste écoute sur la loopback au port choisi : celui de la forge locale
  export PROV_FORGE_HOST_PORT="${FORGE_DOUBLE_URL##*:}"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
  # un daemon répond par le DOCKER_HOST hérité : la doublure rend 0 à « version »
  printf '#!/usr/bin/env bash\nexit 0\n' > "$DECOR_BIN/docker"; chmod +x "$DECOR_BIN/docker"
  export PROV_DOCKER_BIN="$DECOR_BIN/docker" DOCKER_HOST=unix:///dev/null
}

teardown() { forge_double_stop; }

forge_runners() { # forge_runners <code> <corps> — la forge vivante, et sa liste de runners
  forge_route GET /api/v1/version 200 '{"version":"1.26.1"}'
  forge_route GET /api/v1/admin/actions/runners "$1" "$2"
}

stub_delegue() { # stub_delegue <rc> [ligne écrite sur stdout] — l'argv reçu, un argument par ligne
  local d="$BATS_TEST_TMPDIR/repo/deploy"
  mkdir -p "$d/docker" "$d/lib"
  ARGV="$BATS_TEST_TMPDIR/runner.argv"
  cat > "$d/docker/forge-runner.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$ARGV"
[ -n '${2:-}' ] && echo '${2:-}'
exit $1
EOF
  chmod +x "$d/docker/forge-runner.sh"
  cp "$DEPLOY"/lib/*.sh "$d/lib/"
  cp "$DEPLOY/installer-constants.env" "$DEPLOY/system.manifest" "$d/"
  export PROVISION_LIB="$d/lib/provision-lib.sh"
}

mod() { run bash "$MODULE" "$1"; }

@test "forge éteinte : l'enrôlement est reporté, ce n'est pas un échec ; le check n'y voit pas de dérive" {
  export PROV_FORGE_HOST_PORT=9
  mod apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN  49-forge-runner: forge du poste éteinte — enrôlement du runner reporté (48 la monte)"* ]]
  mod check
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK    49-forge-runner: forge du poste éteinte — le runner n'est pas mesurable"* ]]
}

@test "un runner existe déjà : compté par l'API avec le jeton master en en-tête, le délégué n'est pas rejoué, le check est vert" {
  forge_runners 200 '{"runners":[{"name":"r1"}],"total_count":1}'
  stub_delegue 0
  mod apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 runner(s) CI déjà enregistré(s)"* ]]
  [ ! -e "$ARGV" ]
  [ "$(forge_requests 'select(.path == "/api/v1/admin/actions/runners") | .auth' | sort -u)" = '"token MASTERTOK"' ]
  mod check
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 runner(s) CI enregistré(s)"* ]]
}

@test "jeton master absent : dit, et ce n'est pas un échec d'apply" {
  forge_runners 200 '{"runners":[],"total_count":0}'
  stub_delegue 0
  rm -f "$MASTER"
  mod apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN  49-forge-runner: runner CI non enrôlable : aucun jeton master lisible ($MASTER)"* ]]
  [ ! -e "$ARGV" ]
}

@test "le délégué refuse : drift, sa sortie remonte et reste lisible, sa ligne de commande n'est pas imprimée" {
  forge_runners 200 '{"runners":[],"total_count":0}'
  stub_delegue 1 "REFUS : image(s) introuvable(s)"
  mod apply
  [ "$status" -eq 2 ]
  [[ "$output" == *"REFUS : image(s) introuvable(s)"*"DRIFT 49-forge-runner: runner CI NON enrôlé (rc=1"* ]]
  [[ "$output" != *"FAIL"* ]]
  [[ "$output" != *"--forge-api"* ]]
  [ -s "$ARGV" ]
  f="$(printf '%s\n' "$output" | sed -n 's/.*conservée : \([^ ]*\).*/\1/p' | tail -n1)"
  [ -s "$f" ]
}

@test "le délégué réussit : posé, il reçoit la forge de la lib, le jeton, le réseau, le projet et les labels des constantes ; le temporaire est retiré" {
  forge_runners 200 '{"runners":[],"total_count":0}'
  stub_delegue 0
  PROV_FORGE_BASE=bob_9 mod apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"POSÉ  49-forge-runner: runner CI enrôlé"* ]]
  local labels; labels="$(sed -n 's/^PROV_RUNNER_LABELS=//p' "$DEPLOY/installer-constants.env")"
  [ -n "$labels" ]
  [ "$(cat "$ARGV")" = "$(printf '%s\n' --forge-api "$FORGE_DOUBLE_URL/api/v1" --admin-token-file "$MASTER" \
                          --instance-url "http://host.docker.internal:$PROV_FORGE_HOST_PORT" \
                          --network bob_9-forge_default --project bob_9-runner --labels "$labels")" ]
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "un runner du poste qui vise une adresse qu'un job n'atteint pas : drift au check, réenrôlé sur le port publié à l'apply" {
  forge_runners 200 '{"runners":[{"name":"r1"}],"total_count":1}'
  stub_delegue 0
  printf '#!/usr/bin/env bash\n[[ "$*" == "inspect "*" %s-act-1" ]] || exit 0\nprintf "PATH=/bin\\nGITEA_INSTANCE_URL=%s\\n"\n' \
    lcars-runner "${VISE:-http://gitea:3000}" > "$DECOR_BIN/docker"
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 49-forge-runner: le runner lcars-runner vise http://gitea:3000, qu'un job n'atteint pas (attendu http://host.docker.internal:$PROV_FORGE_HOST_PORT)"* ]]
  mod apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"POSÉ  49-forge-runner: runner CI enrôlé"* ]]
  grep -qx "http://host.docker.internal:$PROV_FORGE_HOST_PORT" "$ARGV"
}

@test "un runner du poste qui vise le port publié est conforme, et un runner sans conteneur de ce projet n'est pas touché" {
  forge_runners 200 '{"runners":[{"name":"r1"}],"total_count":1}'
  stub_delegue 0
  printf '#!/usr/bin/env bash\n[[ "$*" == "inspect "*" lcars-runner-act-1" ]] || exit 0\nprintf "GITEA_INSTANCE_URL=http://host.docker.internal:%s\\n"\n' \
    "$PROV_FORGE_HOST_PORT" > "$DECOR_BIN/docker"
  mod check
  [ "$status" -eq 0 ]
  mod apply
  [ "$status" -eq 0 ]
  [ ! -e "$ARGV" ]
  printf '#!/usr/bin/env bash\nexit 0\n' > "$DECOR_BIN/docker"
  mod check
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 runner(s) CI enregistré(s)"* ]]
}

@test "l'argv émis vers forge-runner.sh passe son vrai parseur : les labels arrivent à la vérification des images" {
  forge_runners 200 '{"runners":[],"total_count":0}'
  stub_delegue 0
  mod apply
  [ "$status" -eq 0 ]
  local -a argv; mapfile -t argv < "$ARGV"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$DECOR_BIN/docker-sans-images"; chmod +x "$DECOR_BIN/docker-sans-images"
  run env DOCKER_BIN="$DECOR_BIN/docker-sans-images" bash "$DEPLOY/docker/forge-runner.sh" "${argv[@]}"
  [ "$status" -eq 1 ]
  refute_out 'option inconnue|requis' <<<"$output"
  [[ "$output" == *"REFUS : image(s) introuvable(s) sur ce daemon, et non tirables : alpine:3.20,docker:cli,catthehacker/ubuntu:act-latest"* ]]
}

@test "API muette : rien n'est conclu, ni au check ni à l'apply — un compte inconnu n'enrôle pas un runner qui remplacerait l'existant" {
  forge_runners 500 '{"message":"panne"}'
  stub_delegue 0
  mod check
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN  49-forge-runner: runner CI non mesurable"* ]]
  mod apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN  49-forge-runner: runner CI non mesurable (API muette ou réponse illisible) — rien n'est enrôlé"* ]]
  [ ! -e "$ARGV" ]
}

@test "forge fournie : son runner est à qui la tient — rien n'est compté ni enrôlé, au check comme à l'apply" {
  forge_runners 200 '{"runners":[],"total_count":0}'
  stub_delegue 0
  export FORGE_BASE_URL="$FORGE_DOUBLE_URL"
  mod apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK    49-forge-runner: forge fournie ($FORGE_DOUBLE_URL) — son runner CI est à qui la tient"* ]]
  [ ! -e "$ARGV" ]
  mod check
  [ "$status" -eq 0 ]
  [ -z "$(forge_requests 'select(.path == "/api/v1/admin/actions/runners")')" ]
}

@test "aucun runner et forge vivante : le check le dit en drift" {
  forge_runners 200 '{"runners":[],"total_count":0}'
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 49-forge-runner: aucun runner CI — la CI acceptera des jobs que rien ne servira"* ]]
}
