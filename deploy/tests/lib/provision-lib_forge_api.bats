#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/lib/provision-lib_forge_api.bats
# AUTHOR: bob
# STARDATE: 2026-09-14
# STATUS: témoins de forge_api (lib/provision-lib.sh) contre une forge HTTP locale — authentification, corps JSON, codes rendus, secrets hors argv

# shellcheck disable=SC2016

load ../refute
load ../support/decor

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_)' || true)
  LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export LIB
  [ -f "$LIB" ]
  decor_pose
  forge_double_start
}

teardown() {
  forge_double_stop
  [[ -z "${MUET_PID:-}" ]] || { kill "$MUET_PID" 2>/dev/null || true; wait "$MUET_PID" 2>/dev/null || true; }
}

api() { run bash -c '. "$LIB" >/dev/null 2>&1; "$@"' _ "$@"; }

@test "forge_api : le jeton lu dans le fichier arrive entier dans l'en-tête, guillemet et barre oblique inverse compris" {
  printf ' jeton"avec\\oblique \n' > "$BATS_TEST_TMPDIR/jeton"
  forge_route GET /api/v1/user 200 {}
  api forge_api GET "$FORGE_DOUBLE_URL/api/v1/user" /dev/null --token-file "$BATS_TEST_TMPDIR/jeton"
  [ "$status" -eq 0 ]
  [ "$(forge_requests '.auth' | jq -r .)" = 'token jeton"avec\oblique' ]
}

@test "forge_api : ni le jeton, ni le mot de passe, ni leur encodage n'apparaissent dans l'argv ou l'environnement d'un enfant" {
  printf 'jeton-secret-42\n' > "$BATS_TEST_TMPDIR/jeton"
  espion_enfants curl base64 jq tr
  forge_route PATCH /api/v1/x 200 {}
  forge_route GET /api/v1/user 200 {}
  run bash -c '. "$LIB" >/dev/null 2>&1; pw=mdp-secret-17
    forge_api PATCH "$FORGE_DOUBLE_URL/api/v1/x" /dev/null --token-file "$BATS_TEST_TMPDIR/jeton" --json "{password: \$pw}" --rawfile pw <(printf "%s" "$pw") || exit 1
    forge_api GET "$FORGE_DOUBLE_URL/api/v1/user" /dev/null --basic amiral <(printf "%s" "$pw")'
  [ "$status" -eq 0 ]
  # chaque enfant a joué : un espion muet ne garderait rien
  [ "$(grep -c '^ARGV curl ' "$DECOR_ENFANTS")" -eq 2 ]
  [ "$(grep -c '^ARGV base64 ' "$DECOR_ENFANTS")" -eq 1 ]
  [ "$(grep -c '^ARGV jq ' "$DECOR_ENFANTS")" -eq 1 ]
  grep -q '^ARGV tr -d ' "$DECOR_ENFANTS"
  [ "$(forge_requests '.body | fromjson | .password' | jq -r .)" = mdp-secret-17 ]
  [ "$(forge_requests 'select(.method == "GET") | .auth' | jq -r .)" = "basic amiral:mdp-secret-17" ]
  refute grep -qF jeton-secret-42 "$DECOR_ENFANTS"
  refute grep -qF mdp-secret-17 "$DECOR_ENFANTS"
  refute grep -qF "$(printf 'amiral:mdp-secret-17' | base64 -w0)" "$DECOR_ENFANTS"
}

@test "forge_api --basic : le login donné et le mot de passe lu dans le fichier, guillemets et espaces compris" {
  printf 'mot "de" passe' > "$BATS_TEST_TMPDIR/pw"
  forge_route GET /api/v1/user 200 {}
  api forge_api GET "$FORGE_DOUBLE_URL/api/v1/user" /dev/null --basic amiral "$BATS_TEST_TMPDIR/pw"
  [ "$status" -eq 0 ]
  [ "$(forge_requests '.auth' | jq -r .)" = 'basic amiral:mot "de" passe' ]
}

@test "forge_api --json : le corps est bâti par jq, un secret lu par --rawfile, une valeur par --arg, en application/json" {
  printf '%s' 'p"w\d' > "$BATS_TEST_TMPDIR/pw"
  forge_route POST /api/v1/x 201 {}
  api forge_api POST "$FORGE_DOUBLE_URL/api/v1/x" /dev/null --json '{login: $l, password: $pw, admin: true}' --arg l 'a"b\c' --rawfile pw "$BATS_TEST_TMPDIR/pw"
  [ "$status" -eq 0 ]
  [ "$(forge_requests '.method' | jq -r .)" = POST ]
  [ "$(forge_requests '.ctype' | jq -r .)" = application/json ]
  [ "$(forge_requests '.body | fromjson')" = "$(jq -cn --arg l 'a"b\c' --arg p 'p"w\d' '{login: $l, password: $p, admin: true}')" ]
}

@test "forge_api : 2xx, 3xx, 4xx, 5xx et l'absence de réponse rendent 0, 3, 4, 5, 1 et impriment le code" {
  forge_route GET /c/204 204
  forge_route GET /c/302 302
  forge_route GET /c/404 404
  forge_route GET /c/503 503
  api forge_api GET "$FORGE_DOUBLE_URL/c/204" /dev/null
  [ "$status" -eq 0 ]
  [ "$output" = 204 ]
  api forge_api GET "$FORGE_DOUBLE_URL/c/302" /dev/null
  [ "$status" -eq 3 ]
  [ "$output" = 302 ]
  api forge_api GET "$FORGE_DOUBLE_URL/c/404" /dev/null
  [ "$status" -eq 4 ]
  [ "$output" = 404 ]
  api forge_api GET "$FORGE_DOUBLE_URL/c/503" /dev/null
  [ "$status" -eq 5 ]
  [ "$output" = 503 ]
  api forge_api GET "http://127.0.0.1:1/api/v1/version" /dev/null
  [ "$status" -eq 1 ]
  [ "$output" = 000 ]
}

@test "forge_up : une forge qui redirige /api/v1/version (http vers https) est vivante, une 404 ne l'est pas" {
  forge_route GET /api/v1/version 301 x1
  forge_route GET /api/v1/version 404
  run bash -c '. "$LIB" >/dev/null 2>&1; PROV_FORGE_URL="$FORGE_DOUBLE_URL"; forge_up && echo vivante; forge_up || echo muette'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'vivante\nmuette')" ]
  [ "$(forge_requests '.path' | wc -l)" -eq 2 ]
}

@test "forge_api : le corps de la réponse va dans le fichier de sortie" {
  forge_route GET /api/v1/users/amiral 200 '{"login":"amiral","is_admin":true}'
  api forge_api GET "$FORGE_DOUBLE_URL/api/v1/users/amiral" "$BATS_TEST_TMPDIR/corps"
  [ "$status" -eq 0 ]
  [ "$(jq -r .is_admin "$BATS_TEST_TMPDIR/corps")" = true ]
}

@test "forge_api : une option curl passée après les arguments écrase le défaut, -m 1 coupe une forge muette" {
  python3 -c 'import os,socket,sys,time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(8)
open(sys.argv[1] + ".tmp", "w").write(str(s.getsockname()[1])); os.rename(sys.argv[1] + ".tmp", sys.argv[1])
time.sleep(60)' "$BATS_TEST_TMPDIR/muet.port" 3>&- &
  MUET_PID=$!
  local _
  for _ in $(seq 1 50); do [[ -s "$BATS_TEST_TMPDIR/muet.port" ]] && break; sleep 0.1; done
  local debut=$SECONDS
  api forge_api GET "http://127.0.0.1:$(cat "$BATS_TEST_TMPDIR/muet.port")/api/v1/version" /dev/null -m 1
  [ "$status" -eq 1 ]
  [ "$output" = 000 ]
  [ $((SECONDS - debut)) -lt 5 ]
}

@test "forge_api : un 200 dont le corps n'arrive pas entier avant le délai vaut « sans réponse », pas un succès" {
  python3 -c 'import os,socket,sys,time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(8)
open(sys.argv[1] + ".tmp", "w").write(str(s.getsockname()[1])); os.rename(sys.argv[1] + ".tmp", sys.argv[1])
c, _ = s.accept(); c.recv(4096)
c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\n{\"runners\":[")
time.sleep(60)' "$BATS_TEST_TMPDIR/muet.port" 3>&- &
  MUET_PID=$!
  local _
  for _ in $(seq 1 50); do [[ -s "$BATS_TEST_TMPDIR/muet.port" ]] && break; sleep 0.1; done
  api forge_api GET "http://127.0.0.1:$(cat "$BATS_TEST_TMPDIR/muet.port")/api/v1/admin/actions/runners" "$BATS_TEST_TMPDIR/corps" -m 1
  [ "$status" -eq 1 ]
  [ "$output" = 000 ]
}

@test "prov_seat_binding : la table muette, le siège est le compte d'id 1 que la forge nomme au jeton master" {
  printf 'jeton-master\n' > "$LCARS_DECOR_ROOT/opt/lcars/var/tokens/forge-master.token"
  forge_route GET '/api/v1/admin/users?limit=50' 200 '[{"id":2,"login":"autre"},{"id":1,"login":"amiral"}]'
  PROV_FORGE_HOST_PORT="${FORGE_DOUBLE_URL##*:}" \
    run bash -c '. "$LIB" >/dev/null 2>&1; prov_seat_binding amiral; echo "$PROV_SEAT_BINDING|$PROV_SEAT_LOGIN|$PROV_SEAT_SOURCE"'
  [ "$status" -eq 0 ]
  [ "$output" = "agree|amiral|forge" ]
  [ "$(forge_requests '.auth' | jq -r .)" = "token jeton-master" ]
}
