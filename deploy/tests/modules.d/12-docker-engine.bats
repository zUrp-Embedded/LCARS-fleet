#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/12-docker-engine.bats
# AUTHOR: DrDree
# STARDATE: 2026-09-12
# STATUS: témoins de 12-docker-engine — docker-ce posé une fois sur linux dédié, le daemon constaté ensuite

load ../refute

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_|DOCKER_)' || true)
  SRC="$BATS_TEST_DIRNAME/../../modules.d/12-docker-engine.sh"; [ -f "$SRC" ]
  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export PROVISION_MODULE=12-docker-engine PROV_SUBSTRATE=linux
  export PROV_TOKENS_DIR="$BATS_TEST_TMPDIR/private"
  MOD="$BATS_TEST_TMPDIR/mod.sh"; sed '/^case "${1:?usage/,$d' "$SRC" > "$MOD"
  TRACE="$BATS_TEST_TMPDIR/trace"
}

# mod <état du daemon : repond|refuse|arrete|absent> <corps> — source le module avec des doublures qui tracent
mod() {
  local endpoint denied=0 installed=1
  case "$1" in
    repond) endpoint="return 0" ;;
    refuse) endpoint="return 1"; denied=1; installed=1 ;;
    arrete) endpoint="return 1"; installed=0 ;;
    absent) endpoint="return 1"; installed=1 ;;
  esac
  run bash -c "set -uo pipefail; source '$MOD' >/dev/null 2>&1
    docker_endpoint() { PROV_DOCKER_DENIED=$denied; PROV_DOCKER_WHY='le daemon répond mais pas à testeur'; $endpoint; }
    engine_installed() { return $installed; }
    ensure_docker_repo() { echo REPO >> '$TRACE'; return 0; }
    apt_ensure() { echo \"APT \$*\" >> '$TRACE'; return 0; }
    sleep() { :; }
    $2"
}

@test "en-tête : linux seul, après 10-packages, sous root" {
  grep -q '^# APPLY-ON: linux$' "$SRC"
  grep -q '^# CHECK-ON: linux$' "$SRC"
  grep -q '^# AFTER: 10-packages$' "$SRC"
  grep -q '^# NEEDS: root$' "$SRC"
}

@test "check : un daemon qui répond est conforme" {
  mod repond check
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK    12-docker-engine: un daemon docker répond ("* ]]
}

@test "check : aucun daemon est une dérive qui annonce la pose" {
  mod absent check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT"*"docker-ce sera posé"* ]]
}

@test "check : un daemon qui refuse l'utilisateur est dit tel quel, pas « absent »" {
  mod refuse check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT"*"refuse cet utilisateur"*"pas à testeur"* ]]
  [[ "$output" != *"sera posé"* ]]
}

@test "check : docker-ce posé et service arrêté est dit tel quel, avec le geste" {
  mod arrete check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT"*"systemctl start docker"* ]]
  [[ "$output" != *"sera posé"* ]]
}

@test "apply : un daemon qui répond ne pose rien, ni dépôt ni paquet" {
  mod repond apply
  [ "$status" -eq 0 ]
  [ ! -e "$TRACE" ]
}

@test "apply : un daemon qui refuse l'utilisateur est un échec nommé, sans dépôt ni paquet" {
  mod refuse apply
  [ "$status" -eq 1 ]
  [ ! -e "$TRACE" ]
  [[ "$output" == *"FAIL"*"refuse cet utilisateur"* ]]
}

@test "apply : docker-ce posé et service arrêté est un échec nommé, rien n'est reposé" {
  mod arrete apply
  [ "$status" -eq 1 ]
  [ ! -e "$TRACE" ]
  [[ "$output" == *"FAIL"*"systemctl start docker"* ]]
}

@test "apply : sans daemon ni paquet, le dépôt est posé avant les paquets, puis l'absence de daemon est un échec nommé" {
  mod absent apply
  [ "$status" -eq 1 ]
  [ "$(sed -n 1p "$TRACE")" = "REPO" ]
  [[ "$(sed -n 2p "$TRACE")" == "APT docker-ce docker-ce-cli containerd.io"* ]]
  [[ "$output" == *"FAIL"*"aucun daemon"* ]]
}

@test "apply : le daemon qui apparaît après la pose rend un changement" {
  run bash -c "set -uo pipefail; source '$MOD' >/dev/null 2>&1
    n=0
    docker_endpoint() { n=\$((n+1)); [ \"\$n\" -ge 3 ]; }
    engine_installed() { return 1; }
    ensure_docker_repo() { return 0; }
    apt_ensure() { return 0; }
    sleep() { :; }
    apply"
  [ "$status" -eq 0 ]
  [[ "$output" == *"docker-ce posé, le daemon répond"* ]]
}

@test "apply : un dépôt qui refuse arrête avant tout paquet" {
  run bash -c "set -uo pipefail; source '$MOD' >/dev/null 2>&1
    docker_endpoint() { return 1; }
    engine_installed() { return 1; }
    ensure_docker_repo() { p_fail 'dépôt refusé'; return 1; }
    apt_ensure() { echo APT >> '$TRACE'; return 0; }
    apply"
  [ "$status" -eq 1 ]
  [ ! -e "$TRACE" ]
}

@test "le dépôt : distribution hors ubuntu et debian refusée, rien posé" {
  run env LCARS_DOCKER_KEYRING="$BATS_TEST_TMPDIR/keyrings/docker.asc" LCARS_DOCKER_LIST="$BATS_TEST_TMPDIR/docker.list" \
      bash -c "source '$MOD' >/dev/null 2>&1
    os_field() { case \"\$1\" in ID) echo arch ;; VERSION_CODENAME) echo rolling ;; esac; }
    ensure_docker_repo"
  [ "$status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/docker.list" ]
  [[ "$output" == *"ubuntu et debian"* ]]
}
