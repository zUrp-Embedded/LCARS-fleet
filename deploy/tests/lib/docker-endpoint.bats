#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/lib/docker-endpoint.bats
# AUTHOR: bob
# STARDATE: 2026-09-14
# STATUS: témoins de lib/docker-endpoint.sh — le substrat, le choix de la CLI, la socket du décor et son verdict, le geste du refus, compose

load ../refute
load ../support/decor

setup() {
  unset LCARS_DOCKER PROV_DOCKER_BIN DOCKER_HOST
  LIB="$BATS_TEST_DIRNAME/../../lib/docker-endpoint.sh"; [ -f "$LIB" ]
  decor_pose
  mkdir -p "$LCARS_DECOR_ROOT/var/run" "$LCARS_DECOR_ROOT/proc/net"
  SOCK="$LCARS_DECOR_ROOT/var/run/docker.sock"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
}

lib() { run bash -c ". '$LIB' >/dev/null 2>&1; $1"; }

socket_posee() { # socket_posee <chemin> — le fichier d'une socket unix, sans processus derrière
  ( cd "$(dirname "$1")" && python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$(basename "$1")" )
  [[ -S "$1" ]]
}

table_unix() { # table_unix [<chemin> <drapeaux>]… — le /proc/net/unix du décor
  local f="$LCARS_DECOR_ROOT/proc/net/unix"
  printf 'Num       RefCount Protocol Flags    Type St Inode Path\n' > "$f"
  while [[ $# -ge 2 ]]; do
    printf '0000000000000000: 00000002 00000000 %s 0001 01 4242 %s\n' "$2" "$1" >> "$f"
    shift 2
  done
}

cli_muette() { printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/cli-muette"; chmod +x "$BIN/cli-muette"; }

sonde() { # sonde — docker_endpoint sous le décor avec une CLI muette
  run env -u DOCKER_HOST PROV_DOCKER_BIN="$BIN/cli-muette" \
    bash -c '. "$1"; docker_endpoint; echo "rc=$? denied=$PROV_DOCKER_DENIED"; echo "$PROV_DOCKER_WHY"' _ "$LIB"
}

@test "compose : le plugin porte le binaire qu'on lui donne" {
  printf '#!/usr/bin/env bash\n[[ "$1" == compose ]] && exit 0\nexit 1\n' > "$BIN/mydocker"; chmod +x "$BIN/mydocker"
  lib "docker_compose_cmd '$BIN/mydocker'; echo \"rc=\$? [\$PROV_COMPOSE_CMD]\""
  [ "$output" = "rc=0 [$BIN/mydocker compose]" ]
}

@test "compose : le plugin absent est dit, même avec un docker-compose autonome sur le PATH" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/nodocker"; chmod +x "$BIN/nodocker"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$DECOR_BIN/docker-compose"; chmod +x "$DECOR_BIN/docker-compose"
  lib "docker_compose_cmd '$BIN/nodocker'; echo \"rc=\$? [\$PROV_COMPOSE_CMD] \$PROV_COMPOSE_WHY\""
  [ "$output" = "rc=1 [] docker répond, mais le plugin « docker compose » est absent" ]
}

@test "CLI : PROV_DOCKER_BIN prime, sinon docker du PATH, jamais le montage Docker Desktop du décor" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/docker"; chmod +x "$BIN/docker"
  local montage="$LCARS_DECOR_ROOT/mnt/wsl/docker-desktop/cli-tools/usr/bin"
  mkdir -p "$montage" "$BATS_TEST_TMPDIR/vide"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$montage/docker"; chmod +x "$montage/docker"
  run env -u DOCKER_HOST PATH="$BIN:/usr/bin:/bin" bash -c '. "$1"; docker_endpoint; echo "rc=$? bin=$PROV_DOCKER_BIN"' _ "$LIB"
  [[ "$output" == *"rc=1 bin=docker"* ]]
  run env -u DOCKER_HOST PATH="$BATS_TEST_TMPDIR/vide" /bin/bash -c '. "$1"; docker_endpoint; echo "rc=$? bin=[$PROV_DOCKER_BIN]"; echo "$PROV_DOCKER_WHY"' _ "$LIB"
  [ "${lines[0]}" = "rc=1 bin=[]" ]
  [ "${lines[1]}" = "aucune CLI docker dans le PATH" ]
  run env -u DOCKER_HOST PROV_DOCKER_BIN="$BIN/docker" PATH="$BATS_TEST_TMPDIR/vide:/usr/bin:/bin" bash -c '. "$1"; docker_endpoint; echo "rc=$? bin=$PROV_DOCKER_BIN"' _ "$LIB"
  [[ "$output" == *"rc=1 bin=$BIN/docker"* ]]
}

@test "CLI : sous WSL, aucune CLI dans le PATH nomme le geste — l'intégration Docker Desktop de cette distribution" {
  mkdir -p "$BATS_TEST_TMPDIR/outils"
  ln -s "$(command -v grep)" "$BATS_TEST_TMPDIR/outils/grep"   # la sonde du substrat lit /proc/version par grep
  echo "Linux version 6.6.0-microsoft-standard-WSL2" > "$LCARS_DECOR_ROOT/proc/version"
  run env -u DOCKER_HOST PATH="$BATS_TEST_TMPDIR/outils" /bin/bash -c '. "$1"; docker_endpoint; echo "rc=$?"; echo "$PROV_DOCKER_WHY"' _ "$LIB"
  [ "${lines[0]}" = "rc=1" ]
  [[ "${lines[1]}" == "aucune CLI docker dans le PATH. Sur WSL"*"WSL integration"*"rouvrir la session" ]]
}

@test "socket : le daemon qui répond sur la socket du décor est retenu, PROV_DOCKER_HOST et DOCKER_HOST posés" {
  socket_posee "$SOCK"
  printf '#!/usr/bin/env bash\n[[ "$1" == version && "$DOCKER_HOST" == unix://%s ]]\n' "$SOCK" > "$BIN/docker"; chmod +x "$BIN/docker"
  run env -u DOCKER_HOST PATH="$BIN:/usr/bin:/bin" \
    bash -c '. "$1"; docker_endpoint; echo "rc=$? host=$DOCKER_HOST prov=$PROV_DOCKER_HOST"' _ "$LIB"
  [ "$output" = "rc=0 host=unix://$SOCK prov=unix://$SOCK" ]
}

@test "sans daemon : le refus nomme la CLI, la socket essayée, et sur WSL l'intégration de la distribution" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/docker"; chmod +x "$BIN/docker"
  echo "Linux version 5.15 microsoft-standard" > "$LCARS_DECOR_ROOT/proc/version"
  run env -u DOCKER_HOST PATH="$BIN:/usr/bin:/bin" bash -c '. "$1"; docker_endpoint; echo "rc=$?"; echo "$PROV_DOCKER_WHY"' _ "$LIB"
  [ "${lines[0]}" = "rc=1" ]
  [[ "${lines[1]}" == "aucun daemon docker joignable. CLI retenue : $BIN/docker · sockets essayées : ${SOCK}[absent]. "*"intégration WSL activée pour cette distribution"* ]]
  rm "$LCARS_DECOR_ROOT/proc/version"
  run env -u DOCKER_HOST PATH="$BIN:/usr/bin:/bin" bash -c '. "$1"; docker_endpoint; echo "$PROV_DOCKER_WHY"' _ "$LIB"
  [[ "$output" == *"Le service tourne-t-il, et ce compte est-il dans le groupe docker ?" ]]
  [[ "$output" != *"WSL"* ]]
}

@test "docker_denied_geste : dans le groupe pour la session — le bit d'écriture est la question" {
  : > "$SOCK"
  lib "docker_denied_geste '$SOCK'"
  [[ "$output" == "la session est dans « $(id -gn) » et l'accès est refusé quand même — la socket porte-t-elle le bit d'écriture"* ]]
}

@test "docker_denied_geste : dans /etc/group mais pas dans la session — rouvrir, ou sg" {
  : > "$SOCK"
  run bash -c '. "$1"
    id() { case "$1" in -nG) echo "sans-le-groupe" ;; *) command id "$@" ;; esac; }
    getent() { printf "%s:x:1:%s\n" "$2" "$(command id -un)"; }
    docker_denied_geste "$2"' _ "$LIB" "$SOCK"
  [[ "$output" == *"est dans « $(id -gn) » dans /etc/group mais pas dans cette session"*"sg $(id -gn) -c"* ]]
}

@test "docker_denied_geste : hors du groupe — usermod, puis rouvrir la session" {
  : > "$SOCK"
  run bash -c '. "$1"
    id() { case "$1" in -nG) echo "sans-le-groupe" ;; *) command id "$@" ;; esac; }
    getent() { printf "%s:x:1:\n" "$2"; }
    docker_denied_geste "$2"' _ "$LIB" "$SOCK"
  [[ "$output" == *"sudo usermod -aG $(id -gn) $(id -un)"*"rouvrir la session"* ]]
}

@test "docker_denied_geste : socket illisible — rien n'est raconté qui ne soit su" {
  lib "docker_denied_geste '$LCARS_DECOR_ROOT/nexistepas/docker.sock'"
  [[ "$output" == *"socket illisible"* ]]
  [[ "$output" != *"usermod"* ]]
}

@test "socket refusée qu'un processus écoute : « répond, mais pas à » — le groupe est la question, et le geste est dit" {
  [ "$EUID" -ne 0 ] || { echo "root écrit sur toute socket : ce cas se joue sous un compte ordinaire" >&2; return 1; }
  socket_posee "$SOCK"
  chmod 000 "$SOCK"
  table_unix "$SOCK" 00010000
  cli_muette
  sonde
  [ "${lines[0]}" = "rc=1 denied=1" ]
  [[ "${lines[1]}" == "le daemon docker répond, mais pas à « $(id -un) » : la socket $SOCK est "*"bit d'écriture"* ]]
}

@test "socket refusée orpheline (personne n'écoute) : daemon vivant non établi, le groupe n'est pas accusé" {
  [ "$EUID" -ne 0 ] || { echo "root écrit sur toute socket : ce cas se joue sous un compte ordinaire" >&2; return 1; }
  socket_posee "$SOCK"
  chmod 000 "$SOCK"
  table_unix "$SOCK" 00000000 /run/autre.sock 00010000
  cli_muette
  sonde
  [ "${lines[0]}" = "rc=1 denied=0" ]
  [[ "${lines[1]}" == "aucun daemon docker joignable"*"aucun processus n'y écoute (/proc/net/unix)"*"non établi"* ]]
  [[ "$output" != *"répond, mais pas à"* ]]
  [[ "$output" != *"usermod"* ]]
}

@test "socket refusée et /proc/net/unix illisible : le refus est présumé, l'écoute dite non vérifiable" {
  [ "$EUID" -ne 0 ] || { echo "root écrit sur toute socket : ce cas se joue sous un compte ordinaire" >&2; return 1; }
  socket_posee "$SOCK"
  chmod 000 "$SOCK"
  cli_muette
  sonde
  [ "${lines[0]}" = "rc=1 denied=1" ]
  [[ "${lines[1]}" == "le daemon docker répond (écoute non vérifiable : /proc/net/unix illisible — daemon vivant présumé, pas établi), mais pas à"* ]]
}

@test "substrat : un décor nu reste linux, un noyau microsoft dit wsl, .dockerenv gagne" {
  lib 'detect_substrate'
  [ "$output" = linux ]
  echo "Linux version 5.15 microsoft-standard" > "$LCARS_DECOR_ROOT/proc/version"
  lib 'detect_substrate'
  [ "$output" = wsl ]
  touch "$LCARS_DECOR_ROOT/.dockerenv"
  lib 'detect_substrate'
  [ "$output" = docker ]
}

@test "DOCKER_HOST hérité qui répond : gardé tel quel, et PROV_DOCKER_HOST posé à sa valeur" {
  printf '#!/usr/bin/env bash\n[[ "$1" == version && "$DOCKER_HOST" == tcp://daemon:2375 ]]\n' > "$BIN/docker"; chmod +x "$BIN/docker"
  run env DOCKER_HOST=tcp://daemon:2375 PATH="$BIN:/usr/bin:/bin" \
    bash -c '. "$1"; docker_endpoint; echo "rc=$? host=$DOCKER_HOST prov=[$PROV_DOCKER_HOST] ecarte=[$PROV_DOCKER_ECARTE]"' _ "$LIB"
  [ "$output" = "rc=0 host=tcp://daemon:2375 prov=[tcp://daemon:2375] ecarte=[]" ]
}

@test "DOCKER_HOST mort : il est retiré, la socket du décor qui répond le remplace, et l'adresse écartée est rendue pour être dite" {
  socket_posee "$SOCK"
  printf '#!/usr/bin/env bash\n[[ "$1" == version && "$DOCKER_HOST" == unix://%s ]]\n' "$SOCK" > "$BIN/docker"; chmod +x "$BIN/docker"
  run env DOCKER_HOST=unix:///nulle/part.sock PATH="$BIN:/usr/bin:/bin" \
    bash -c '. "$1"; docker_endpoint; echo "rc=$? host=$DOCKER_HOST prov=$PROV_DOCKER_HOST ecarte=$PROV_DOCKER_ECARTE"' _ "$LIB"
  [ "$output" = "rc=0 host=unix://$SOCK prov=unix://$SOCK ecarte=unix:///nulle/part.sock" ]
}

@test "DOCKER_HOST mort et aucune socket : le refus nomme l'adresse de l'environnement, et DOCKER_HOST est retiré" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/docker"; chmod +x "$BIN/docker"
  run env DOCKER_HOST=unix:///nulle/part.sock PATH="$BIN:/usr/bin:/bin" \
    bash -c '. "$1"; docker_endpoint; echo "rc=$? host=[${DOCKER_HOST:-}]"; echo "$PROV_DOCKER_WHY"' _ "$LIB"
  [ "${lines[0]}" = "rc=1 host=[]" ]
  [[ "${lines[1]}" == *"sockets essayées : unix:///nulle/part.sock[env,rien à cette adresse] ${SOCK}[absent]"* ]]
}
