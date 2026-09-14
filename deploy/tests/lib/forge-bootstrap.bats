#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/lib/forge-bootstrap.bats
# AUTHOR: bob
# STARDATE: 2026-09-14
# STATUS: témoins de l'amorçage de forge — montage, admin, jeton master et seed avec docker doublé ; attente, jeton et humain de banc contre une forge HTTP locale

# shellcheck disable=SC2016

bats_require_minimum_version 1.5.0

load ../refute
load ../support/decor

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_)' || true)
  PROV_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  LIB="$BATS_TEST_DIRNAME/../../lib/forge-bootstrap.sh"
  export PROV_LIB LIB
  [ -f "$LIB" ]
  decor_pose
  CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  cat > "$DECOR_BIN/docker" <<EOF
#!/usr/bin/env bash
echo "DOCKER:\$*" >> "$CALLS"
env | grep '^LCARS_DEVFORGE_\|^LCARS_BENCH_BASE=\|^PW=' | sort >> "$CALLS"
case "\$*" in
  *"user create"*)  [[ -z "\${STUB_CREATE_ERR:-}" ]] || echo "\$STUB_CREATE_ERR" >&2; exit "\${STUB_CREATE_RC:-0}" ;;
  *"generate-access-token"*) printf '%s\n' "\${STUB_TOKEN-tok-123}"; exit 0 ;;
esac
exit "\${STUB_DOCKER_RC:-0}"
EOF
  chmod 0755 "$DECOR_BIN/docker"
  printf 'tok-master\n' > "$BATS_TEST_TMPDIR/master"
}

teardown() { forge_double_stop; }

lib() { run bash -c "set -euo pipefail; source '$PROV_LIB'; source '$LIB'; $1"; }

routes_du_banc() { # routes_du_banc [is_admin] [code du Basic] [réponse du jeton] — une forge qui accepte l'humain « lcars »
  local is_admin="${1:-true}" basic="${2:-200}" jeton='{"sha1":"op-abc"}'
  [[ -z "${3:-}" ]] || jeton="$3"
  forge_route PATCH /api/v1/admin/users/lcars 200 '{"login":"lcars"}'
  forge_route GET /api/v1/users/lcars 200 "{\"login\":\"lcars\",\"is_admin\":$is_admin}"
  forge_route GET /api/v1/user "$basic" '{"login":"lcars"}'
  forge_route POST /api/v1/users/lcars/tokens 201 "$jeton"
}

@test "forge_mount : compose up -d avec le projet, et port, bind, url racine dans l'environnement" {
  lib 'forge_mount docker /x/forge-compose.yml bob_9-forge 20090 0.0.0.0 http://localhost:20090'
  [ "$status" -eq 0 ]
  grep -qx 'DOCKER:compose -f /x/forge-compose.yml -p bob_9-forge up -d' "$CALLS"
  grep -qx 'LCARS_DEVFORGE_BIND=0.0.0.0' "$CALLS"
  grep -qx 'LCARS_DEVFORGE_PORT=20090' "$CALLS"
  grep -qx 'LCARS_DEVFORGE_ROOT_URL=http://localhost:20090/' "$CALLS"
  grep -qx 'LCARS_BENCH_BASE=' "$CALLS"
}

@test "forge_mount d'un banc : la surcouche marquée s'empile sur le compose, avec la base du banc" {
  lib 'forge_mount docker /x/forge-compose.yml bt-forge 20090 0.0.0.0 http://localhost:20090 bt'
  [ "$status" -eq 0 ]
  grep -qx 'DOCKER:compose -f /x/forge-compose.yml -f /x/forge-compose.bench.yml -p bt-forge up -d' "$CALLS"
  grep -qx 'LCARS_BENCH_BASE=bt' "$CALLS"
}

@test "forge_wait : réessaie jusqu'à ce que /api/v1/version réponde" {
  forge_double_start
  forge_route GET /api/v1/version 503 x1
  forge_route GET /api/v1/version 200 '{"version":"1.24"}'
  lib 'sleep() { :; }; forge_wait "$FORGE_DOUBLE_URL" 3'
  [ "$status" -eq 0 ]
  [ "$(forge_requests '.path' | wc -l)" -eq 2 ]
}

@test "forge_wait : une redirection sur /api/v1/version est une forge vivante, au premier essai" {
  forge_double_start
  forge_route GET /api/v1/version 302
  lib 'sleep() { :; }; forge_wait "$FORGE_DOUBLE_URL" 3'
  [ "$status" -eq 0 ]
  [ "$(forge_requests '.path' | wc -l)" -eq 1 ]
}

@test "forge_wait : rend 1 au bout des essais" {
  forge_double_start
  forge_route GET /api/v1/version 503
  lib 'sleep() { :; }; forge_wait "$FORGE_DOUBLE_URL" 2'
  [ "$status" -eq 1 ]
  [ "$(forge_requests '.path' | wc -l)" -eq 2 ]
}

@test "forge_admin_ensure : crée le compte admin, ou dit qu'il est présent, ou rend l'erreur de la forge ; le mot de passe voyage par l'environnement" {
  lib 'forge_admin_ensure docker gitea-1 bob s3cret'
  [ "$status" -eq 0 ]
  [ "$output" = "cree" ]
  grep -q 'DOCKER:exec -e PW -u git gitea-1 sh -c gitea admin user create --username "$1" --password "$PW" --email "$1@lcars.local" --admin --must-change-password=false _ bob' "$CALLS"
  grep -qx 'PW=s3cret' "$CALLS"
  refute grep -q 'DOCKER:.*s3cret' "$CALLS"
  STUB_CREATE_RC=1 STUB_CREATE_ERR="user already exists [name: bob]" lib 'forge_admin_ensure docker gitea-1 bob s3cret'
  [ "$status" -eq 0 ]
  [ "$output" = "present" ]
  STUB_CREATE_RC=1 STUB_CREATE_ERR="database is locked" lib 'forge_admin_ensure docker gitea-1 bob s3cret'
  [ "$status" -eq 1 ]
  [[ "$output" == *"database is locked"* ]]
}

@test "forge_admin_password : rotation par la CLI de la forge, sans changement forcé" {
  lib 'forge_admin_password docker gitea-1 admiral toto123456'
  [ "$status" -eq 0 ]
  grep -q 'DOCKER:exec -e PW -u git gitea-1 sh -c gitea admin user change-password --username "$1" --password "$PW" --must-change-password=false _ admiral' "$CALLS"
  grep -qx 'PW=toto123456' "$CALLS"
  refute grep -q 'DOCKER:.*toto123456' "$CALLS"
}

@test "forge_master_token : rend le jeton minté, et 1 quand la forge n'en rend aucun" {
  lib 'forge_master_token docker gitea-1 bob poste-1'
  [ "$status" -eq 0 ]
  [ "$output" = "tok-123" ]
  grep -q 'generate-access-token --username bob --token-name poste-1 --scopes all --raw' "$CALLS"
  STUB_TOKEN="" lib 'forge_master_token docker gitea-1 bob'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "forge_seed_new : vingt caractères alphanumériques, deux tirages différents" {
  lib 'forge_seed_new; forge_seed_new'
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ ^[A-Za-z0-9]{20}$ ]]
  [ "${lines[0]}" != "${lines[1]}" ]
}

@test "forge_token_ok : le jeton du fichier s'authentifie sur /api/v1/user, un refus rend non nul" {
  forge_double_start
  forge_route GET /api/v1/user 200 x1 '{"login":"amiral"}'
  forge_route GET /api/v1/user 401 '{"message":"token is required"}'
  lib 'forge_token_ok "$FORGE_DOUBLE_URL" "$BATS_TEST_TMPDIR/master"'
  [ "$status" -eq 0 ]
  [ "$(forge_requests '.auth' | jq -r .)" = "token tok-master" ]
  lib 'forge_token_ok "$FORGE_DOUBLE_URL" "$BATS_TEST_TMPDIR/master"'
  [ "$status" -ne 0 ]
}

@test "bench_human_seed : PATCH JSON au jeton master — mot de passe, admin, login_name, source_id" {
  forge_double_start
  routes_du_banc
  lib 'bench_human_seed "$FORGE_DOUBLE_URL" "$BATS_TEST_TMPDIR/master" lcars toto32toto32'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local patch='select(.method == "PATCH" and .path == "/api/v1/admin/users/lcars")'
  [ "$(forge_requests "$patch | .auth" | jq -r .)" = "token tok-master" ]
  [ "$(forge_requests "$patch | .ctype" | jq -r .)" = application/json ]
  [ "$(forge_requests "$patch | .body | fromjson")" = '{"login_name":"lcars","source_id":0,"password":"toto32toto32","must_change_password":false,"admin":true}' ]
}

@test "bench_human_seed : l'adminité lue au jeton master, le mot de passe éprouvé en Basic, le jeton opérateur minté en Basic et son sha1 rendu" {
  forge_double_start
  routes_du_banc
  lib 'bench_human_seed "$FORGE_DOUBLE_URL" "$BATS_TEST_TMPDIR/master" lcars toto32toto32'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = "op-abc" ]
  [ "$(forge_requests 'select(.path == "/api/v1/users/lcars") | .auth' | jq -r .)" = "token tok-master" ]
  [ "$(forge_requests 'select(.path == "/api/v1/user") | .auth' | jq -r .)" = "basic lcars:toto32toto32" ]
  [ "$(forge_requests 'select(.path == "/api/v1/users/lcars/tokens") | .auth' | jq -r .)" = "basic lcars:toto32toto32" ]
  [[ "$(forge_requests 'select(.path == "/api/v1/users/lcars/tokens") | .body | fromjson | .name' | jq -r .)" == bench-operateur-* ]]
  [ "$(forge_requests 'select(.path == "/api/v1/users/lcars/tokens") | .body | fromjson | .scopes')" = '["write:repository","write:issue","read:organization","read:user"]' ]
}

@test "bench_human_seed : un mot de passe avec guillemet et barre oblique inverse arrive tel quel" {
  forge_double_start
  routes_du_banc
  lib 'bench_human_seed "$FORGE_DOUBLE_URL" "$BATS_TEST_TMPDIR/master" lcars '"'"'mot"de\passe'"'"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(forge_requests 'select(.method == "PATCH") | .body | fromjson | .password' | jq -r .)" = 'mot"de\passe' ]
  [ "$(forge_requests 'select(.path == "/api/v1/user") | .auth' | jq -r .)" = 'basic lcars:mot"de\passe' ]
}

@test "bench_human_seed : ni le jeton master ni le mot de passe dans l'argv ou l'environnement d'un enfant" {
  forge_double_start
  routes_du_banc
  espion_enfants curl base64 jq tr
  lib 'bench_human_seed "$FORGE_DOUBLE_URL" "$BATS_TEST_TMPDIR/master" lcars toto32toto32'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  # le PATCH, la lecture de l'adminité, l'épreuve Basic et le jeton opérateur : quatre curl, et le jq du corps
  [ "$(grep -c '^ARGV curl ' "$DECOR_ENFANTS")" -eq 4 ]
  grep -q '^ARGV jq -cn ' "$DECOR_ENFANTS"
  grep -q '^ARGV base64 ' "$DECOR_ENFANTS"
  refute grep -qF tok-master "$DECOR_ENFANTS"
  refute grep -qF toto32toto32 "$DECOR_ENFANTS"
  refute grep -qF "$(printf 'lcars:toto32toto32' | base64 -w0)" "$DECOR_ENFANTS"
}

@test "bench_human_seed : un PATCH refusé est nommé avec son code HTTP, rien n'est rendu" {
  forge_double_start
  forge_route PATCH /api/v1/admin/users/lcars 403 '{"message":"forbidden"}'
  run --separate-stderr bash -c "source '$PROV_LIB'; source '$LIB'; bench_human_seed \"\$FORGE_DOUBLE_URL\" \"\$BATS_TEST_TMPDIR/master\" lcars pw"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "la forge refuse le compte « lcars » (HTTP 403)" ]
}

@test "bench_human_seed : une promotion qui ne prend pas est nommée avec is_admin, rien n'est rendu" {
  forge_double_start
  routes_du_banc false
  run --separate-stderr bash -c "source '$PROV_LIB'; source '$LIB'; bench_human_seed \"\$FORGE_DOUBLE_URL\" \"\$BATS_TEST_TMPDIR/master\" lcars pw"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "« lcars » n'est pas site-admin après la promotion (is_admin=false)" ]
}

@test "bench_human_seed : un mot de passe que la forge refuse en Basic est nommé, rien n'est rendu" {
  forge_double_start
  routes_du_banc true 401
  run --separate-stderr bash -c "source '$PROV_LIB'; source '$LIB'; bench_human_seed \"\$FORGE_DOUBLE_URL\" \"\$BATS_TEST_TMPDIR/master\" lcars pw"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "« lcars » ne s'authentifie pas avec le mot de passe posé" ]
}

@test "bench_human_seed : une réponse sans sha1 est nommée avec le corps de la forge, rien n'est rendu" {
  forge_double_start
  routes_du_banc true 200 '{"message":"nope"}'
  run --separate-stderr bash -c "source '$PROV_LIB'; source '$LIB'; bench_human_seed \"\$FORGE_DOUBLE_URL\" \"\$BATS_TEST_TMPDIR/master\" lcars pw"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "la forge n'a pas rendu de jeton opérateur pour « lcars » : {\"message\":\"nope\"}" ]
}

@test "bench_human_seed : une forge muette au jeton opérateur est nommée sans reprendre la réponse précédente" {
  forge_double_start
  routes_du_banc
  printf '#!/usr/bin/env bash\n[[ "$*" != */tokens* ]] || exit 7\nexec %q "$@"\n' "$(PATH="${PATH#"$DECOR_BIN:"}" command -v curl)" > "$DECOR_BIN/curl"
  chmod 0755 "$DECOR_BIN/curl"
  run --separate-stderr bash -c "source '$PROV_LIB'; source '$LIB'; bench_human_seed \"\$FORGE_DOUBLE_URL\" \"\$BATS_TEST_TMPDIR/master\" lcars pw"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "la forge n'a pas rendu de jeton opérateur pour « lcars » :" ]
}

@test "les mots de passe du banc sont ceux du contrat, et une variable les remplace" {
  lib 'bench_admiral_password; bench_human_password'
  [ "${lines[0]}" = "toto123456" ]
  [ "${lines[1]}" = "toto32toto32" ]
  LCARS_BENCH_ADMIRAL_PW=autre lib 'bench_admiral_password'
  [ "$output" = "autre" ]
}
