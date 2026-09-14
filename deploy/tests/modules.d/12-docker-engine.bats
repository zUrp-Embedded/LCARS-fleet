#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/12-docker-engine.bats
# AUTHOR: DrDree
# STARDATE: 2026-09-12
# STATUS: témoins de 12-docker-engine — le module joué entier : docker-ce posé une fois sur linux dédié, le daemon constaté ensuite

load ../refute
load ../support/decor

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_|DOCKER_)' || true)
  SRC="$BATS_TEST_DIRNAME/../../modules.d/12-docker-engine.sh"; [ -f "$SRC" ]
  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export PROVISION_MODULE=12-docker-engine PROV_SUBSTRATE=linux PROVISION_RUN=1

  decor_pose
  export TRACE="$BATS_TEST_TMPDIR/trace" INSTALLES="$BATS_TEST_TMPDIR/installes" DAEMON="$BATS_TEST_TMPDIR/daemon"
  : > "$INSTALLES"
  KEY="$LCARS_DECOR_ROOT/etc/apt/keyrings/docker.asc"
  LIST="$LCARS_DECOR_ROOT/etc/apt/sources.list.d/docker.list"
  SOCK="$LCARS_DECOR_ROOT/var/run/docker.sock"
  mkdir -p "$(dirname "$LIST")" "$(dirname "$SOCK")"
  PIN="$(sed -n 's/^PROV_DOCKER_GPG_SHA256=//p' "$BATS_TEST_DIRNAME/../../installer-constants.env")"
  [ -n "$PIN" ]

  # la frontière : dpkg, apt, curl, docker et sleep. apt-get install note les paquets et « démarre » le daemon
  printf '#!/usr/bin/env bash\necho amd64\n' > "$DECOR_BIN/dpkg"
  printf '#!/usr/bin/env bash\ngrep -qx "${@: -1}" "$INSTALLES" && printf installed || printf not-installed\n' > "$DECOR_BIN/dpkg-query"
  cat > "$DECOR_BIN/apt-get" <<'EOS'
#!/usr/bin/env bash
echo "APT $*" >> "$TRACE"
case "$1" in
  update) exit "${STUB_APT_UPDATE_RC:-0}" ;;
  install) shift; for a in "$@"; do [[ "$a" == -* ]] || echo "$a" >> "$INSTALLES"; done
           [[ -n "${STUB_SANS_DAEMON:-}" ]] || : > "$DAEMON" ;;
esac
EOS
  cat > "$DECOR_BIN/curl" <<'EOS'
#!/usr/bin/env bash
echo "CURL ${@: -1}" >> "$TRACE"
out=""; prev=""; for a in "$@"; do [[ "$prev" == -o ]] && out="$a"; prev="$a"; done
[[ -z "$out" ]] || echo "CLE-TELECHARGEE" > "$out"
EOS
  printf '#!/usr/bin/env bash\n[[ "$1" == version && -e "$DAEMON" ]]\n' > "$DECOR_BIN/docker"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$DECOR_BIN/sleep"
  chmod 0755 "$DECOR_BIN"/*
}

mod() { run bash "$SRC" "$1"; }

socket_pose() { # socket_pose [mode] — une vraie socket unix à l'emplacement du daemon, sous le décor
  python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$SOCK"
  chmod "${1:-0660}" "$SOCK"
}

# os_release <ID> <VERSION_CODENAME> — la distribution du décor
os_release() { printf 'ID=%s\nVERSION_CODENAME=%s\n' "$1" "$2" > "$LCARS_DECOR_ROOT/etc/os-release"; }

# la clé téléchargée par la doublure de curl porte le sha du pin : c'est le téléchargement qui est doublé, pas la vérification
cle_du_pin() {
  printf '#!/usr/bin/env bash\n[[ -e "$1" ]] || exit 1\nprintf "%%s  %%s\\n" "%s" "$1"\n' "$PIN" > "$DECOR_BIN/sha256sum"
  chmod 0755 "$DECOR_BIN/sha256sum"
}

@test "check : un daemon qui répond est conforme" {
  socket_pose; : > "$DAEMON"
  mod check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"OK    12-docker-engine: un daemon docker répond (unix://$SOCK)"* ]]
}

@test "check : aucun daemon est une dérive qui annonce la pose" {
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT"*"docker-ce sera posé"* ]]
}

@test "check : un daemon qui refuse l'utilisateur est dit tel quel, pas « absent »" {
  socket_pose 0000
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT"*"refuse cet utilisateur"* ]]
  [[ "$output" != *"sera posé"* ]]
}

@test "check : un moteur posé dont le service est arrêté est nommé, docker-ce comme docker.io, avec le geste" {
  local p
  for p in docker-ce docker.io; do
    echo "$p" > "$INSTALLES"
    mod check
    [ "$status" -eq 1 ]
    [[ "$output" == *"DRIFT 12-docker-engine: $p est posé mais aucun daemon ne répond"*"systemctl start docker"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"sera posé"* ]]
  done
}

@test "apply : un daemon qui répond ne pose rien, ni dépôt ni paquet" {
  socket_pose; : > "$DAEMON"
  mod apply
  [ "$status" -eq 0 ]
  [ ! -e "$TRACE" ]
}

@test "apply : un daemon qui refuse l'utilisateur est un échec nommé, sans dépôt ni paquet" {
  socket_pose 0000
  mod apply
  [ "$status" -eq 1 ]
  [ ! -e "$TRACE" ]
  [[ "$output" == *"FAIL"*"refuse cet utilisateur"* ]]
}

@test "apply : docker.io posé et arrêté est un échec nommé — docker-ce n'est pas posé à côté" {
  echo docker.io > "$INSTALLES"
  os_release debian trixie
  mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  12-docker-engine: docker.io est posé mais aucun daemon ne répond"* ]]
  [ ! -e "$TRACE" ]
  [ ! -e "$LIST" ]
}

@test "apply : sans daemon ni moteur — clé vérifiée, source dérivée, update restreint, paquets, puis le daemon répond" {
  socket_pose
  os_release debian trixie
  cle_du_pin
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$LIST")" = "deb [arch=amd64 signed-by=$KEY] https://download.docker.com/linux/debian trixie stable" ]
  [ "$(cat "$KEY")" = CLE-TELECHARGEE ]
  [ "$(sed -n 1p "$TRACE")" = "CURL https://download.docker.com/linux/debian/gpg" ]
  [[ "$(sed -n 2p "$TRACE")" == "APT update -o Dir::Etc::sourcelist=$LIST "* ]]
  [[ "$(grep '^APT install' "$TRACE")" == *"docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"* ]]
  [[ "$output" == *"POSÉ  12-docker-engine: docker-ce posé, le daemon répond (unix://$SOCK)"* ]]
}

@test "apply : les paquets posés sans daemon qui réponde sont un échec nommé" {
  socket_pose
  os_release ubuntu resolute
  cle_du_pin
  STUB_SANS_DAEMON=1 mod apply
  [ "$status" -eq 1 ]
  grep -q '^APT install' "$TRACE"
  [[ "$output" == *"FAIL  12-docker-engine: docker-ce posé mais aucun daemon ne répond"* ]]
}

@test "dépôt docker : une distribution que l'upstream ne publie pas est refusée, rien n'est posé" {
  os_release arch rolling
  mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"« arch »"*"ubuntu et debian"* ]]
  [ ! -e "$TRACE" ]
  [ ! -e "$LIST" ]
  [ ! -e "$KEY" ]
}

@test "dépôt docker : sans VERSION_CODENAME la suite est indérivable, et le refus le dit" {
  os_release ubuntu ""
  mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"VERSION_CODENAME"* ]]
  [ ! -e "$LIST" ]
}

@test "dépôt docker : une clé qui n'est pas celle du pin est refusée — un sha exporté n'y change rien" {
  os_release ubuntu resolute
  PROV_DOCKER_GPG_SHA256="$(echo CLE-TELECHARGEE | sha256sum | awk '{print $1}')" mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"sha256 différent"* ]]
  [ ! -e "$KEY" ]
  [ ! -e "$LIST" ]
  refute grep -q '^APT' "$TRACE"
}

@test "dépôt docker : une clé déjà posée qui n'est pas celle du pin se retélécharge, et la clé du pin la remplace" {
  socket_pose
  os_release ubuntu resolute
  mkdir -p "$(dirname "$KEY")"; echo "VIEILLE-CLE" > "$KEY"
  # la clé téléchargée porte le sha du pin, la vieille garde le sien
  printf '#!/usr/bin/env bash\nif grep -qx CLE-TELECHARGEE "$1" 2>/dev/null; then printf "%%s  %%s\\n" "%s" "$1"; else exec /usr/bin/sha256sum "$@"; fi\n' "$PIN" > "$DECOR_BIN/sha256sum"
  chmod 0755 "$DECOR_BIN/sha256sum"
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q '^CURL .*/gpg$' "$TRACE"
  [ "$(cat "$KEY")" = CLE-TELECHARGEE ]
}

@test "dépôt docker : un « apt-get update » qui refuse la source la retire avec sa clé, sans paquet" {
  os_release debian suite-qui-nexiste-pas
  cle_du_pin
  STUB_APT_UPDATE_RC=100 mod apply
  [ "$status" -eq 1 ]
  grep -q '^CURL ' "$TRACE"
  [ ! -e "$LIST" ]
  [ ! -e "$KEY" ]
  refute grep -q '^APT install' "$TRACE"
  [[ "$output" == *"refuse la source « https://download.docker.com/linux/debian suite-qui-nexiste-pas » — retirée avec sa clé"* ]]
}
