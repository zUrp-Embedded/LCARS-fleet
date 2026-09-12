#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/49-forge-runner.bats
# AUTHOR: alice
# STARDATE: 2026-09-12
# STATUS: témoins de 49-forge-runner — l'enrôlement du runner CI, reporté, sauté, refusé ou posé

load ../refute

setup() {
  MODULE="$BATS_TEST_DIRNAME/../../modules.d/49-forge-runner.sh"; [ -f "$MODULE" ]
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN" "$BATS_TEST_TMPDIR/tokens"
  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export PROVISION_MODULE=49-forge-runner PROV_SUBSTRATE=wsl PROV_HUMAN=zoe
  export PROV_FORGE_URL="http://forge.test"
  export PROV_TOKENS_DIR="$BATS_TEST_TMPDIR/tokens"
  export PROV_MASTER_TOKEN_FILE="$BATS_TEST_TMPDIR/tokens/master"
  printf 'MASTERTOK' > "$PROV_MASTER_TOKEN_FILE"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
  export PATH="$BIN:$PATH"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/docker"; chmod +x "$BIN/docker"
  export PROV_DOCKER_BIN="$BIN/docker"
}

stub_curl() { # stub_curl <corps runners | MUET> [ETEINTE]
  cat > "$BIN/curl" <<EOF
#!/usr/bin/env bash
url=""
for a in "\$@"; do case "\$a" in http*) url="\$a" ;; esac; done
case "\$url" in
  */api/v1/version)               [ '${2:-}' = ETEINTE ] && exit 22; printf '{"version":"1.26.1"}' ;;
  */api/v1/admin/actions/runners) [ '$1' = MUET ] && exit 22; printf '%s' '$1' ;;
  *)                              exit 22 ;;
esac
exit 0
EOF
  chmod +x "$BIN/curl"
}

stub_delegue() { # stub_delegue <rc> [ligne écrite sur stdout]
  local d="$BATS_TEST_TMPDIR/repo/deploy/docker"
  mkdir -p "$d" "$BATS_TEST_TMPDIR/repo/deploy/lib"
  CALLS="$BATS_TEST_TMPDIR/runner.calls"; : > "$CALLS"
  cat > "$d/forge-runner.sh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
[ -n '${2:-}' ] && echo '${2:-}'
exit $1
EOF
  chmod +x "$d/forge-runner.sh"
  local cible="$BATS_TEST_TMPDIR/repo/deploy/lib/provision-lib.sh"
  [ "$PROVISION_LIB" = "$cible" ] || cp "$(dirname "$PROVISION_LIB")"/*.sh "$BATS_TEST_TMPDIR/repo/deploy/lib/"
  export PROVISION_LIB="$cible"
}

mod() { run bash "$MODULE" "$1"; }

@test "forge éteinte : l'enrôlement est reporté, ce n'est pas un échec ; le check n'y voit pas de dérive" {
  stub_curl '{"runners":[],"total_count":0}' ETEINTE
  mod apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN  49-forge-runner: forge du poste éteinte — enrôlement du runner reporté (48 la monte)"* ]]
  mod check
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK    49-forge-runner: forge du poste éteinte — le runner n'est pas mesurable"* ]]
}

@test "un runner existe déjà : le délégué n'est pas rejoué, le check est vert" {
  stub_curl '{"runners":[{"name":"r1"}],"total_count":1}'
  stub_delegue 0
  mod apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 runner(s) CI déjà enregistré(s)"* ]]
  [ ! -s "$CALLS" ]
  mod check
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 runner(s) CI enregistré(s)"* ]]
}

@test "jeton master absent : dit, et ce n'est pas un échec d'apply" {
  stub_curl '{"runners":[],"total_count":0}'
  stub_delegue 0
  rm -f "$PROV_MASTER_TOKEN_FILE"
  mod apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN  49-forge-runner: runner CI non enrôlable : aucun jeton master lisible ($PROV_MASTER_TOKEN_FILE)"* ]]
  [ ! -s "$CALLS" ]
}

@test "le délégué refuse : drift, sa sortie remonte, le temporaire est retiré" {
  stub_curl '{"runners":[],"total_count":0}'
  stub_delegue 1 "REFUS : image(s) introuvable(s)"
  mod apply
  [ "$status" -eq 2 ]
  [[ "$output" == *"     REFUS : image(s) introuvable(s)"*"DRIFT 49-forge-runner: runner CI NON enrôlé (rc=1"* ]]
  [ -s "$CALLS" ]
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "le délégué réussit : posé, il reçoit la forge, le jeton, le réseau, le projet et les labels ; le temporaire est retiré" {
  stub_curl '{"runners":[],"total_count":0}'
  stub_delegue 0
  PROV_FORGE_NET=bob_9-net PROV_RUNNER_PROJECT=bob_9-runner mod apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"POSÉ  49-forge-runner: runner CI enrôlé"* ]]
  grep -q -- "--forge-api http://forge.test/api/v1 --admin-token-file $PROV_MASTER_TOKEN_FILE --network bob_9-net --project bob_9-runner --labels shell:docker://alpine:3.20," "$CALLS"
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "API muette : rien n'est conclu au check, et l'apply tente l'enrôlement" {
  stub_curl MUET
  stub_delegue 0
  mod check
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN  49-forge-runner: runner CI non mesurable"* ]]
  mod apply
  [ "$status" -eq 0 ]
  [ -s "$CALLS" ]
}

@test "aucun runner et forge vivante : le check le dit en drift" {
  stub_curl '{"runners":[],"total_count":0}'
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 49-forge-runner: aucun runner CI — la CI acceptera des jobs que rien ne servira"* ]]
}
