#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/lib/docker-endpoint.bats
# AUTHOR: bob
# STARDATE: 2026-09-12
# STATUS: témoins de lib/docker-endpoint.sh — le substrat, le choix de la CLI, le verdict sur la socket, le geste du refus, compose
#
# Les sockets sont posées par python3 dans le décor, avec ou sans processus derrière ; la CLI est
# une doublure. Sous root, « refusé » n'existe pas : ces cas sautent.

load ../refute

setup() {
  LIB="$BATS_TEST_DIRNAME/../../lib/docker-endpoint.sh"; [ -f "$LIB" ]
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
}

lib() { run bash -c ". '$LIB' >/dev/null 2>&1; $1"; }

@test "compose : le plugin est préféré, et il porte le binaire qu'on lui donne" {
  printf '#!/usr/bin/env bash\n[[ "$1" == compose ]] && exit 0\nexit 1\n' > "$BIN/mydocker"; chmod +x "$BIN/mydocker"
  lib "docker_compose_cmd '$BIN/mydocker' && echo \"[\$PROV_COMPOSE_CMD]\""
  [[ "$output" == *"[$BIN/mydocker compose]"* ]]
}

@test "compose : sans plugin, l'autonome prend le relais" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/nodocker"; chmod +x "$BIN/nodocker"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/docker-compose"; chmod +x "$BIN/docker-compose"
  lib "PATH='$BIN:\$PATH'; docker_compose_cmd '$BIN/nodocker' && echo \"[\$PROV_COMPOSE_CMD]\""
  [[ "$output" == *"[docker-compose]"* ]]
}

@test "compose : aucune des deux formes — refus nommé, jamais une commande vide" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/nodocker2"; chmod +x "$BIN/nodocker2"
  lib "PATH='$BATS_TEST_TMPDIR/vide'; docker_compose_cmd '$BIN/nodocker2' && echo OUI || echo \"NON [\$PROV_COMPOSE_WHY]\""
  [[ "$output" == *"NON [docker répond, mais compose est absent"* ]]
}

@test "CLI : PROV_DOCKER_BIN prime, sinon docker du PATH, jamais le montage Docker Desktop" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/docker"; chmod +x "$BIN/docker"
  mkdir -p "$BATS_TEST_TMPDIR/montage"; printf '#!/usr/bin/env bash\nexit 0\n' > "$BATS_TEST_TMPDIR/montage/docker"; chmod +x "$BATS_TEST_TMPDIR/montage/docker"
  run env -u DOCKER_HOST LCARS_DOCKER_SOCKETS="$BATS_TEST_TMPDIR/aucune.sock" LCARS_DOCKER_MOUNT_CLI="$BATS_TEST_TMPDIR/montage/docker" PATH="$BIN:/usr/bin:/bin" \
    bash -c '. "$1"; docker_endpoint; echo "rc=$? bin=$PROV_DOCKER_BIN"' _ "$LIB"
  [[ "$output" == *"rc=1 bin=docker"* ]]
  mkdir -p "$BATS_TEST_TMPDIR/vide" "$BATS_TEST_TMPDIR/linux"
  run env -u DOCKER_HOST LCARS_SUBSTRATE_ROOT="$BATS_TEST_TMPDIR/linux" LCARS_DOCKER_SOCKETS="$BATS_TEST_TMPDIR/aucune.sock" LCARS_DOCKER_MOUNT_CLI="$BATS_TEST_TMPDIR/montage/docker" PATH="$BATS_TEST_TMPDIR/vide" \
    /bin/bash -c '. "$1"; docker_endpoint; echo "rc=$? bin=[$PROV_DOCKER_BIN]"; echo "$PROV_DOCKER_WHY"' _ "$LIB"
  [[ "$output" == *"rc=1 bin=[]"*"aucune CLI docker dans le PATH"* ]]
  refute_out "intégration" <<<"$output"
  run env -u DOCKER_HOST LCARS_DOCKER_SOCKETS="$BATS_TEST_TMPDIR/aucune.sock" PROV_DOCKER_BIN="$BIN/docker" PATH="$BATS_TEST_TMPDIR/vide:/usr/bin:/bin" \
    bash -c '. "$1"; docker_endpoint; echo "rc=$? bin=$PROV_DOCKER_BIN"' _ "$LIB"
  [[ "$output" == *"rc=1 bin=$BIN/docker"* ]]
}

@test "CLI : sous WSL, aucune CLI dans le PATH nomme le geste — l'intégration Docker Desktop de cette distribution" {
  mkdir -p "$BATS_TEST_TMPDIR/outils" "$BATS_TEST_TMPDIR/wsl/proc"
  ln -s "$(command -v grep)" "$BATS_TEST_TMPDIR/outils/grep"   # grep seul : la sonde du substrat en a besoin, aucune CLI docker
  echo "Linux version 6.6.0-microsoft-standard-WSL2" > "$BATS_TEST_TMPDIR/wsl/proc/version"
  run env -u DOCKER_HOST LCARS_SUBSTRATE_ROOT="$BATS_TEST_TMPDIR/wsl" LCARS_DOCKER_SOCKETS="$BATS_TEST_TMPDIR/aucune.sock" PATH="$BATS_TEST_TMPDIR/outils" \
    /bin/bash -c '. "$1"; docker_endpoint; echo "rc=$?"; echo "$PROV_DOCKER_WHY"' _ "$LIB"
  [[ "$output" == *"rc=1"*"aucune CLI docker dans le PATH. Sur WSL"*"WSL integration"*"rouvrir la session"* ]]
}

@test "sockets : une seule, /var/run/docker.sock, quel que soit le substrat — le décor la remplace" {
  lib '_docker_sockets'
  [ "$output" = /var/run/docker.sock ]
  LCARS_SUBSTRATE_ROOT="$BATS_TEST_TMPDIR/wsl" lib '_docker_sockets'
  [ "$output" = /var/run/docker.sock ]
  LCARS_DOCKER_SOCKETS="$BATS_TEST_TMPDIR/x.sock" lib '_docker_sockets'
  [ "$output" = "$BATS_TEST_TMPDIR/x.sock" ]
}

@test "sans daemon : le refus nomme la CLI, chaque socket essayée, et sur WSL l'intégration de la distribution" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/docker"; chmod +x "$BIN/docker"
  mkdir -p "$BATS_TEST_TMPDIR/wsl/proc"; echo "Linux version 5.15 microsoft-standard" > "$BATS_TEST_TMPDIR/wsl/proc/version"
  run env -u DOCKER_HOST -u LCARS_DOCKER LCARS_DOCKER_SOCKETS="$BATS_TEST_TMPDIR/aucune.sock" LCARS_SUBSTRATE_ROOT="$BATS_TEST_TMPDIR/wsl" PATH="$BIN:/usr/bin:/bin" \
    bash -c '. "$1"; docker_endpoint; echo "rc=$?"; echo "$PROV_DOCKER_WHY"' _ "$LIB"
  [[ "$output" == *"rc=1"*"aucun daemon docker joignable. CLI retenue : $BIN/docker · sockets essayées : $BATS_TEST_TMPDIR/aucune.sock[absent]"*"intégration WSL activée pour cette distribution"* ]]
  run env -u DOCKER_HOST -u LCARS_DOCKER LCARS_DOCKER_SOCKETS="$BATS_TEST_TMPDIR/aucune.sock" LCARS_SUBSTRATE_ROOT="$BATS_TEST_TMPDIR/linux" PATH="$BIN:/usr/bin:/bin" \
    bash -c '. "$1"; docker_endpoint; echo "$PROV_DOCKER_WHY"' _ "$LIB"
  [[ "$output" == *"Le service tourne-t-il, et ce compte est-il dans le groupe docker ?"* ]]
  [[ "$output" != *"WSL"* ]]
}

@test "docker_denied_geste : dans le groupe pour la session — le bit d'écriture est la question" {
  local sock="$BATS_TEST_TMPDIR/s.sock"
  python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$sock"
  lib "docker_denied_geste '$sock'"
  [[ "$output" == *"la session est dans « $(id -gn) » et l'accès est refusé quand même — la socket porte-t-elle le bit d'écriture"* ]]
}

@test "docker_denied_geste : dans /etc/group mais pas dans la session — rouvrir, ou sg" {
  local sock="$BATS_TEST_TMPDIR/s.sock"
  python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$sock"
  run bash -c '. "$1"
    id() { case "$1" in -nG) echo "sans-le-groupe" ;; *) command id "$@" ;; esac; }
    getent() { printf "%s:x:1:%s\n" "$2" "$(command id -un)"; }
    docker_denied_geste "$2"' _ "$LIB" "$sock"
  [[ "$output" == *"est dans « $(id -gn) » dans /etc/group mais pas dans cette session"*"sg $(id -gn) -c"* ]]
}

@test "docker_denied_geste : hors du groupe — usermod, puis rouvrir la session" {
  local sock="$BATS_TEST_TMPDIR/d.sock"; : > "$sock"
  run bash -c '. "$1"
    id() { case "$1" in -nG) echo "sans-le-groupe" ;; *) command id "$@" ;; esac; }
    getent() { printf "%s:x:1:\n" "$2"; }
    docker_denied_geste "$2"' _ "$LIB" "$sock"
  [[ "$output" == *"sudo usermod -aG $(id -gn) $(id -un)"*"rouvrir la session"* ]]
}

@test "docker_denied_geste : socket illisible — rien n'est raconté qui ne soit su" {
  lib "docker_denied_geste /nexistepas/docker.sock"
  [[ "$output" == *"socket illisible"* ]]
  [[ "$output" != *"usermod"* ]]
}

ecouteur() { # ecouteur <socket> — un processus qui écoute, mode 000 ; pose ECOUTEUR_PID
  python3 - "$1" <<'PY' &
import os, socket, sys, time
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1); os.chmod(sys.argv[1], 0)
time.sleep(30)
PY
  ECOUTEUR_PID=$!
  local _i; for _i in 1 2 3 4 5 6 7 8 9 10; do [[ -S "$1" ]] && break; sleep 0.2; done
  [[ -S "$1" ]]
}
orpheline() { # orpheline <socket> — le fichier d'une socket dont le processus est mort, mode 000
  python3 - "$1" <<'PY'
import os, socket, sys
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1); os.chmod(sys.argv[1], 0); s.close()
PY
  [[ -S "$1" ]]
}
teardown() { [[ -n "${ECOUTEUR_PID:-}" ]] && kill "$ECOUTEUR_PID" 2>/dev/null; return 0; }
sonde() { # sonde <socket> — docker_endpoint avec une CLI muette
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/cli-muette"; chmod +x "$BIN/cli-muette"
  run env -u DOCKER_HOST LCARS_DOCKER_SOCKETS="$1" PROV_DOCKER_BIN="$BIN/cli-muette" \
    bash -c '. "$1"; docker_endpoint; echo "rc=$? denied=$PROV_DOCKER_DENIED"; echo "$PROV_DOCKER_WHY"' _ "$LIB"
}

@test "un processus écoute et la socket refuse : « répond, mais pas à » — le groupe est la question, et le geste est dit" {
  [ "$EUID" -ne 0 ] || skip "root écrit sur toute socket : le cas « refusé » n'existe pas ici"
  [ -r /proc/net/unix ] || skip "pas de /proc/net/unix : l'écoute n'est pas mesurable ici"
  local sock="$BATS_TEST_TMPDIR/vivante.sock"
  ecouteur "$sock"
  sonde "$sock"
  [[ "$output" == *"rc=1 denied=1"*"le daemon docker répond, mais pas à « $(id -un) » : la socket $sock est"*"bit d'écriture"* ]]
  [[ "$output" != *"non établi"* ]]
}

@test "socket orpheline (personne n'écoute) : daemon vivant non établi, le groupe n'est pas accusé" {
  [ "$EUID" -ne 0 ] || skip "root écrit sur toute socket : le cas « refusé » n'existe pas ici"
  [ -r /proc/net/unix ] || skip "pas de /proc/net/unix : l'écoute n'est pas mesurable ici"
  local sock="$BATS_TEST_TMPDIR/morte.sock"
  orpheline "$sock"
  sonde "$sock"
  [[ "$output" == *"rc=1 denied=0"*"aucun daemon docker joignable"*"aucun processus n'y écoute"*"non établi"* ]]
  [[ "$output" != *"répond, mais pas à"* ]]
  [[ "$output" != *"usermod"* ]]
}

@test "_docker_sock_listening distingue la socket écoutée de l'orpheline" {
  [ -r /proc/net/unix ] || skip "pas de /proc/net/unix"
  ecouteur "$BATS_TEST_TMPDIR/v.sock"; orpheline "$BATS_TEST_TMPDIR/m.sock"
  run bash -c '. "$1"; _docker_sock_listening "$2"; echo "v=$?"; _docker_sock_listening "$3"; echo "m=$?"' _ "$LIB" "$BATS_TEST_TMPDIR/v.sock" "$BATS_TEST_TMPDIR/m.sock"
  [[ "$output" == *"v=0"*"m=1"* ]]
}

@test "substrat : un décor nu reste linux, un noyau microsoft dit wsl, .dockerenv gagne" {
  local root="$BATS_TEST_TMPDIR/sub"; mkdir -p "$root/proc"
  LCARS_SUBSTRATE_ROOT="$root" run env -u LCARS_DOCKER bash -c ". '$LIB'; detect_substrate"
  [ "$output" = linux ]
  echo "Linux version 5.15 microsoft-standard" > "$root/proc/version"
  LCARS_SUBSTRATE_ROOT="$root" run env -u LCARS_DOCKER bash -c ". '$LIB'; detect_substrate"
  [ "$output" = wsl ]
  touch "$root/.dockerenv"
  LCARS_SUBSTRATE_ROOT="$root" run env -u LCARS_DOCKER bash -c ". '$LIB'; detect_substrate"
  [ "$output" = docker ]
}
