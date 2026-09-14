#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/12-docker-engine.bats
# AUTHOR: DrDree
# STARDATE: 2026-09-12
# STATUS: témoins de 12-docker-engine — docker-ce posé une fois sur linux dédié, le daemon constaté ensuite, la source apt sous le décor

load ../refute
load ../support/decor

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_|DOCKER_)' || true)
  SRC="$BATS_TEST_DIRNAME/../../modules.d/12-docker-engine.sh"; [ -f "$SRC" ]
  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export PROVISION_MODULE=12-docker-engine PROV_SUBSTRATE=linux
  MOD="$BATS_TEST_TMPDIR/mod.sh"; sed '/^case "${1:?usage/,$d' "$SRC" > "$MOD"
  TRACE="$BATS_TEST_TMPDIR/trace"

  decor_pose
  KEY="$LCARS_DECOR_ROOT/etc/apt/keyrings/docker.asc"
  LIST="$LCARS_DECOR_ROOT/etc/apt/sources.list.d/docker.list"
  mkdir -p "$(dirname "$LIST")"
  printf '#!/usr/bin/env bash\nexit "${STUB_CURL_RC:-0}"\n' > "$DECOR_BIN/curl"
  printf '#!/usr/bin/env bash\necho amd64\n' > "$DECOR_BIN/dpkg"
  printf '#!/usr/bin/env bash\necho "APT $*" >> "%s"\nexit "${STUB_APT_RC:-0}"\n' "$TRACE" > "$DECOR_BIN/apt-get"
  chmod 0755 "$DECOR_BIN"/*
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

# os_release <ID> <VERSION_CODENAME> — la distribution du décor
os_release() { printf 'ID=%s\nVERSION_CODENAME=%s\n' "$1" "$2" > "$LCARS_DECOR_ROOT/etc/os-release"; }

# depot — joue ensure_docker_repo ; le téléchargement vérifié est la frontière, il pose une clé et se note
depot() {
  run bash -c "set -uo pipefail; source '$MOD' >/dev/null 2>&1
    fetch_verify() { echo FETCH >> '$TRACE'; mkdir -p \"\$(dirname \"\$3\")\"; echo CLE-LCARS > \"\$3\"; }
    ensure_docker_repo"
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

@test "dépôt docker : une distribution que l'upstream ne publie pas est refusée, rien n'est posé" {
  os_release arch rolling
  depot
  [ "$status" -ne 0 ]
  [[ "$output" == *"« arch »"*"ubuntu et debian"* ]]
  [ ! -e "$LIST" ]
  [ ! -e "$KEY" ]
}

@test "dépôt docker : sans VERSION_CODENAME la suite est indérivable, et le refus le dit" {
  os_release ubuntu ""
  depot
  [ "$status" -ne 0 ]
  [[ "$output" == *"VERSION_CODENAME"* ]]
  [ ! -e "$LIST" ]
}

@test "dépôt docker : une suite absente chez Docker refuse avant la clé et la source" {
  # la sonde réseau passe avant la pose : un refus qui laisserait la source armerait un apt-get update cassé
  os_release ubuntu suite-qui-nexiste-pas
  STUB_CURL_RC=22 depot
  [ "$status" -ne 0 ]
  [[ "$output" == *"suite-qui-nexiste-pas"* ]]
  [ ! -e "$TRACE" ]
  [ ! -e "$LIST" ]
  [ ! -e "$KEY" ]
}

@test "dépôt docker : la source est dérivée de l'id, du codename et de l'architecture, sous le décor" {
  os_release debian trixie
  depot
  [ "$status" -eq 0 ]
  run cat "$LIST"
  [ "$output" = "deb [arch=amd64 signed-by=$KEY] https://download.docker.com/linux/debian trixie stable" ]
}

@test "dépôt docker : un sha GPG exporté ne change pas le pin — une clé qui n'est pas celle du pin se retélécharge" {
  # la clé posée est vide et l'environnement annonce le sha du vide : seul le pin du module décide
  mkdir -p "$(dirname "$KEY")"; : > "$KEY"
  os_release ubuntu resolute
  LCARS_DOCKER_GPG_SHA256="$(printf '' | sha256sum | awk '{print $1}')" depot
  [ "$status" -eq 0 ]
  grep -qx FETCH "$TRACE"
}

@test "dépôt docker : sur refus d'apt-get update, la source et la clé qui étaient là sont restaurées telles quelles" {
  mkdir -p "$(dirname "$KEY")"
  echo "deb LE-DEPOT-DE-L-OPERATEUR" > "$LIST"
  echo "CLE-DE-L-OPERATEUR" > "$KEY"
  os_release debian trixie
  STUB_APT_RC=100 depot
  [ "$status" -ne 0 ]
  [ "$(cat "$LIST")" = "deb LE-DEPOT-DE-L-OPERATEUR" ]
  [ "$(cat "$KEY")" = "CLE-DE-L-OPERATEUR" ]
  [[ "$output" == *"restauré"* ]]
}

@test "dépôt docker : sur refus d'apt-get update, ce que la passe a posé est retiré, et le refus le dit" {
  # sans ce sens, un module qui ne toucherait plus à rien passerait le cas de la restauration
  os_release debian trixie
  STUB_APT_RC=100 depot
  [ "$status" -ne 0 ]
  grep -qx FETCH "$TRACE"
  [ ! -e "$LIST" ]
  [ ! -e "$KEY" ]
  [[ "$output" == *"n'était là avant"* ]]
}
