#!/usr/bin/env bats
# bats file_tags=unit
# SOURCE: deploy/tests/lib/forge-bootstrap.bats
# AUTHOR: bob
# STARDATE: 2026-09-12
# STATUS: témoins de l'amorçage de forge — montage, admin, jeton, seed, humain de banc, avec docker et curl doublés
#
# Les doublures notent chaque appel et sa configuration stdin dans CALLS : ce qui doit passer par
# stdin s'y lit, ce qui ne doit jamais être dans un argv s'y cherche.

load ../refute

setup() {
  LIB="$BATS_TEST_DIRNAME/../../lib/forge-bootstrap.sh"
  [ -f "$LIB" ]
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  cat > "$BIN/docker" <<EOF
#!/usr/bin/env bash
echo "DOCKER:\$*" >> "$CALLS"
env | grep '^LCARS_DEVFORGE_\|^PW=' | sort >> "$CALLS"
case "\$*" in
  *"user create"*)  [[ -z "\${STUB_CREATE_ERR:-}" ]] || echo "\$STUB_CREATE_ERR" >&2; exit "\${STUB_CREATE_RC:-0}" ;;
  *"generate-access-token"*) printf '%s\n' "\${STUB_TOKEN-tok-123}"; exit 0 ;;
esac
exit "\${STUB_DOCKER_RC:-0}"
EOF
  cat > "$BIN/curl" <<EOF
#!/usr/bin/env bash
cfg=""; for a in "\$@"; do [[ "\$a" == "-K" ]] && cfg="\$(cat)"; done
url="\${@: -1}"
echo "CURL:\$* | \$(tr '\n' ' ' <<<"\$cfg")" >> "$CALLS"
n=\$(grep -c '^CURL:' "$CALLS")
[[ "\$n" -gt "\${STUB_CURL_FAIL_UNTIL:-0}" ]] || exit 22
case "\$url" in
  */api/v1/admin/users/*) [[ " \$* " == *" -w "* ]] && printf '%s' "\${STUB_PATCH_CODE:-200}"; exit 0 ;;
  */api/v1/users/*/tokens) printf '%s' "\${STUB_TOKEN_RESP:-{\"sha1\":\"op-abc\"}}"; exit 0 ;;
  */api/v1/users/*) printf '{"login":"x","is_admin":%s}' "\${STUB_IS_ADMIN:-true}"; exit 0 ;;
esac
exit "\${STUB_CURL_RC:-0}"
EOF
  chmod 0755 "$BIN/docker" "$BIN/curl"
  export PATH="$BIN:$PATH"
}

lib() { run bash -c "set -euo pipefail; source '$LIB'; $1"; }

@test "forge_mount : compose up -d avec le projet, et port, bind, url racine dans l'environnement" {
  lib 'forge_mount docker /x/forge-compose.yml bob_9-forge 20090 0.0.0.0 http://localhost:20090'
  [ "$status" -eq 0 ]
  grep -qx 'DOCKER:compose -f /x/forge-compose.yml -p bob_9-forge up -d' "$CALLS"
  grep -qx 'LCARS_DEVFORGE_BIND=0.0.0.0' "$CALLS"
  grep -qx 'LCARS_DEVFORGE_PORT=20090' "$CALLS"
  grep -qx 'LCARS_DEVFORGE_ROOT_URL=http://localhost:20090/' "$CALLS"
}

@test "forge_wait : réessaie jusqu'à ce que /api/v1/version réponde, et rend 1 au bout des essais" {
  STUB_CURL_FAIL_UNTIL=1 lib 'forge_wait http://f:1 3'
  [ "$status" -eq 0 ]
  [ "$(grep -c 'CURL:.*api/v1/version' "$CALLS")" -eq 2 ]
  : > "$CALLS"
  STUB_CURL_FAIL_UNTIL=99 lib 'forge_wait http://f:1 1'
  [ "$status" -ne 0 ]
}

@test "forge_admin_ensure : crée le compte admin, ou dit qu'il est présent, ou rend l'erreur de la forge ; le mot de passe voyage par l'environnement" {
  lib 'forge_admin_ensure docker gitea-1 bob s3cret'
  [ "$status" -eq 0 ] && [ "$output" = "cree" ]
  grep -q 'DOCKER:exec -e PW -u git gitea-1 sh -c gitea admin user create --username "$1" --password "$PW" --email "$1@lcars.local" --admin --must-change-password=false _ bob' "$CALLS"
  grep -qx 'PW=s3cret' "$CALLS"
  refute grep -q 'DOCKER:.*s3cret' "$CALLS"
  STUB_CREATE_RC=1 STUB_CREATE_ERR="user already exists [name: bob]" lib 'forge_admin_ensure docker gitea-1 bob s3cret'
  [ "$status" -eq 0 ] && [ "$output" = "present" ]
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
  [ "$status" -eq 0 ] && [ "$output" = "tok-123" ]
  grep -q 'generate-access-token --username bob --token-name poste-1 --scopes all --raw' "$CALLS"
  STUB_TOKEN="" lib 'forge_master_token docker gitea-1 bob'
  [ "$status" -eq 1 ] && [ -z "$output" ]
}

@test "forge_seed_new : vingt caractères alphanumériques, deux tirages différents" {
  lib 'forge_seed_new; forge_seed_new'
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ ^[A-Za-z0-9]{20}$ ]]
  [ "${lines[0]}" != "${lines[1]}" ]
}

@test "forge_token_ok : le jeton part par stdin, jamais dans l'argv" {
  lib 'forge_token_ok http://f:1/ tok-secret'
  [ "$status" -eq 0 ]
  grep -q 'CURL:-K - .*api/v1/user | header = "Authorization: token tok-secret"' "$CALLS"
  refute grep -q 'CURL:.*tok-secret |' "$CALLS"
  STUB_CURL_RC=22 lib 'forge_token_ok http://f:1 tok-secret'
  [ "$status" -ne 0 ]
}

@test "bench_human_seed : mot de passe et site-admin en une requête, vérifiés, puis un jeton opérateur rendu" {
  lib 'bench_human_seed http://f:1 tok-master lcars toto32toto32'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = "op-abc" ]
  grep -q 'request = "PATCH"' "$CALLS"
  grep -q 'admin/users/lcars | .*"password\\":\\"toto32toto32\\".*"admin\\":true' "$CALLS"
  grep -q 'CURL:.*api/v1/users/lcars | header = "Authorization: token tok-master"' "$CALLS"
  grep -q 'CURL:.*-f .*api/v1/user | user = "lcars:toto32toto32"' "$CALLS"
  grep -q 'users/lcars/tokens | user = "lcars:toto32toto32".*request = "POST"' "$CALLS"
  refute grep -qE 'CURL:[^|]*(tok-master|toto32toto32)' "$CALLS"
}

@test "bench_human_seed : un refus de la forge, une promotion qui ne prend pas, un jeton absent — chacun nommé, rien rendu" {
  STUB_PATCH_CODE=403 lib 'bench_human_seed http://f:1 tok lcars pw'
  [ "$status" -eq 1 ] && [[ "$output" == *"refuse le compte « lcars » (HTTP 403)"* ]]
  STUB_IS_ADMIN=false lib 'bench_human_seed http://f:1 tok lcars pw'
  [ "$status" -eq 1 ] && [[ "$output" == *"n'est pas site-admin"* ]]
  STUB_TOKEN_RESP='{"message":"nope"}' lib 'bench_human_seed http://f:1 tok lcars pw'
  [ "$status" -eq 1 ] && [[ "$output" == *"jeton opérateur"*"nope"* ]]
}

@test "les mots de passe du banc sont ceux du contrat, et une variable les remplace" {
  lib 'bench_admiral_password; bench_human_password'
  [ "${lines[0]}" = "toto123456" ] && [ "${lines[1]}" = "toto32toto32" ]
  LCARS_BENCH_ADMIRAL_PW=autre lib 'bench_admiral_password'
  [ "$output" = "autre" ]
}
