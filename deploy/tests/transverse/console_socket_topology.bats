#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/transverse/console_socket_topology.bats
# AUTHOR: drdree
# STARDATE: 2026-08-14
# STATUS: bats tests for console.sh + console-landing.sh — JG-072/JG-098, le terminal n'a plus de port

# shellcheck disable=SC2016

load ../refute

setup() {
  SRC="$BATS_TEST_DIRNAME/../../../runtime/services/console.sh"
  LANDING="$BATS_TEST_DIRNAME/../../../runtime/services/console-landing.sh"
  DOCKERFILE="$BATS_TEST_DIRNAME/../../docker/Dockerfile"
  BINDIR="$BATS_TEST_TMPDIR/bin"
  CALLS="$BATS_TEST_TMPDIR/calls"

  ROOT="$(mktemp -d /tmp/lct.XXXXXX)"

  mkdir -p "$BINDIR"
  : > "$CALLS"

  # ttyd creates its socket only when asked to -- the two cases are the two things this suite must
  # tell apart: a launcher that works, and a launcher whose process lives while nothing listens.
  TTYD_MAKES_SOCK="$BATS_TEST_TMPDIR/ttyd.makesock"
  echo 1 > "$TTYD_MAKES_SOCK"

  cat > "$BINDIR/ttyd" <<EOF
#!/usr/bin/env bash
echo "ttyd \$*" >> "$CALLS"
if [[ "\$(cat "$TTYD_MAKES_SOCK")" == "1" ]]; then
  # The real ttyd binds an AF_UNIX socket at the path given to \`-i\`; a plain file would make the
  # script's \`-S\` guard pass on something that is not a socket, i.e. test the wrong property.
  sock=""; prev=""
  for a in "\$@"; do [[ "\$prev" == "-i" ]] && sock="\$a"; prev="\$a"; done
  # BIND *ET* LISTEN, comme le vrai ttyd. Un \`bind\` seul cree bien un fichier de socket, mais toute
  # connexion dessus est REFUSEE — et c'est exactement ce que la sonde d'idempotence mesure. Une
  # doublure qui ne fait que binder rendrait « morte » une console que le vrai ttyd sert.
  # BIND *ET* LISTEN, comme le vrai ttyd. Un \`bind\` seul cree bien un fichier de socket, mais toute
  # connexion dessus est REFUSEE — et c'est exactement ce que la sonde d'idempotence mesure. Une
  # doublure qui ne fait que binder rendrait « morte » une console que le vrai ttyd sert. Le
  # \`setsid\` + les redirections detachent l'ecouteur du tuyau de bats, qui attendrait sinon sa fin.
  if [[ -n "\$sock" ]]; then
    setsid python3 -c 'import socket,sys,time
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(8); time.sleep(6)' "\$sock" \
      </dev/null >/dev/null 2>&1 &
    for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -S "\$sock" ]] && break; sleep 0.1; done
  fi
fi
sleep 5
EOF

  cat > "$BINDIR/setpriv" <<EOF
#!/usr/bin/env bash
echo "setpriv \$*" >> "$CALLS"
while [[ \$# -gt 0 && "\$1" != "--" ]]; do shift; done
shift || true
exec "\$@"
EOF

  cat > "$BINDIR/install" <<EOF
#!/usr/bin/env bash
echo "install \$*" >> "$CALLS"
d=""; for a in "\$@"; do d="\$a"; done
mkdir -p "\$d"
EOF

  for c in chmod chown; do
    cat > "$BINDIR/$c" <<EOF
#!/usr/bin/env bash
echo "$c \$*" >> "$CALLS"
exit 0
EOF
  done

  cat > "$BINDIR/getent" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "passwd bt")            echo "bt:x:1000:1000::/tmp/bt-home:/bin/bash" ;;
  "group lcars-console")  echo "lcars-console:x:2001:" ;;
  "group fleet")          echo "fleet:x:2000:" ;;
  *) exit 2 ;;
esac
EOF

  printf '#!/usr/bin/env bash\nexit 0\n' > "$BINDIR/id"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BINDIR/podsh"

  chmod 0755 "$BINDIR"/*

  mkdir -p /tmp/bt-home
  export PATH="$BINDIR:$PATH"
  export LCARS_CONSOLE_SOCK_ROOT="$ROOT/console"
  export LCARS_CONSOLE_POD="$BINDIR/podsh"
}

teardown() {
  pkill -f "$BINDIR/ttyd" 2>/dev/null || true
  [[ -n "${ROOT:-}" && "$ROOT" == /tmp/lct.* ]] && rm -rf "$ROOT"
}

run_console() {
  run bash "$SRC" --human bt
}

# The ttyd command line for a given socket name, or "" -- every assertion about the reachable
# surface reads THIS, never the script's source.
ttyd_line() {
  grep -- "^ttyd .*$1" "$CALLS" | head -1
}

@test "JG-072: NEITHER ttyd carries -p — the terminal has no port at all" {
  run_console
  [ "$status" -eq 0 ]

  # Both launches must appear, or the assertion below passes by measuring nothing.
  [ -n "$(ttyd_line console.sock)" ]
  [ -n "$(ttyd_line pod.sock)" ]

  refute grep -qE "^ttyd .* -p( |$)" "$CALLS"
  refute grep -q -- "-i 0.0.0.0" "$CALLS"
}

@test "JG-072: each ttyd listens on an AF_UNIX socket under the console root" {
  run_console
  [ "$status" -eq 0 ]

  [[ "$(ttyd_line console.sock)" == *"-i $LCARS_CONSOLE_SOCK_ROOT/bt/console.sock"* ]]
  [[ "$(ttyd_line pod.sock)"     == *"-i $LCARS_CONSOLE_SOCK_ROOT/bt/pod.sock"* ]]
}

@test "JG-072: the per-human directory is asked for as 2710 <human>:lcars-console" {
  run_console
  [ "$status" -eq 0 ]

  grep -q -- "install -d -m 2710 -o bt -g lcars-console $LCARS_CONSOLE_SOCK_ROOT/bt" "$CALLS"
  # Re-affirmed after the fact: `install -d` does NOT re-apply the mode to an existing directory,
  # so a directory inherited from an earlier version would silently keep the old one.
  grep -q -- "chmod 2710 $LCARS_CONSOLE_SOCK_ROOT/bt" "$CALLS"
  grep -q -- "chown bt:lcars-console $LCARS_CONSOLE_SOCK_ROOT/bt" "$CALLS"
}

@test "JG-072: ttyd is asked to refuse a request without the identity header" {
  run_console
  [ "$status" -eq 0 ]

  [[ "$(ttyd_line console.sock)" == *"-H X-LCARS-Human"* ]]
  [[ "$(ttyd_line pod.sock)"     == *"-H X-LCARS-Human"* ]]
}

@test "JG-098: ttyd still runs AS the human, never as root" {
  # The socket is the new boundary, and it would be worth nothing if the shell behind it ran with
  # more rights than its owner. What is typed in the browser has exactly the human's rights.
  run_console
  [ "$status" -eq 0 ]

  grep -q -- "setpriv --reuid bt --regid 1000" "$CALLS"
  refute grep -qE "^setpriv .*--reuid (root|0)( |$)" "$CALLS"
}

@test "le gid primaire vient de passwd, pas du login — un groupe eponyme n'est pas supposé" {
  # bt a le gid 1000 et AUCUN groupe `bt` : la doublure `getent` refuse `group bt` (exit 2), comme
  # une vraie base ou le groupe n'existe pas.
  run_console
  [ "$status" -eq 0 ]

  refute grep -qE "^setpriv .*--regid bt( |$)" "$CALLS"
  # les DEUX consoles (humain et pod) passent par la meme identite — le second site avait ete
  # oublie une fois deja, il est nomme ici.
  [ "$(grep -c -- "setpriv --reuid bt --regid 1000" "$CALLS")" -ge 2 ]
}

@test "un humain dont le groupe primaire est NOMMÉ démarre quand même — la faute d'origine" {
  cat > "$BINDIR/getent" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "passwd lcars")         echo "lcars:x:1001:1003::/tmp/bt-home:/bin/bash" ;;
  "group lcars-console")  echo "lcars-console:x:2001:" ;;
  "group fleet")          echo "fleet:x:1003:" ;;
  *) exit 2 ;;
esac
EOF
  chmod 0755 "$BINDIR/getent"

  run bash "$SRC" --human lcars
  [ "$status" -eq 0 ]

  grep -q -- "setpriv --reuid lcars --regid 1003" "$CALLS"
  refute grep -q -- "--regid lcars" "$CALLS"
}

@test "a live process with NO socket is a FAILURE, not a running console" {
  echo 0 > "$TTYD_MAKES_SOCK"
  run_console

  [ "$status" -ne 0 ]
  [[ "$output" == *"AUCUNE socket"* ]]
}

@test "--port is REFUSED, not ignored — an option that swallows a value it drops is worse than none" {
  run bash "$SRC" --human bt --port 21004
  [ "$status" -eq 1 ]
  [[ "$output" == *"n'a plus de port"* ]]
}

@test "console.sh refuses outright when the console group is missing" {
  # A socket landing in the wrong group is unreachable by the deck, and nothing downstream would say
  # so: the console would look launched and be dead. Fail here, loudly, or not at all.
  cat > "$BINDIR/getent" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "passwd bt") echo "bt:x:1000:1000::/tmp/bt-home:/bin/bash" ;;
  *) exit 2 ;;
esac
EOF
  chmod 0755 "$BINDIR/getent"

  run_console
  [ "$status" -ne 0 ]
  [[ "$output" == *"lcars-console"* ]]
  refute grep -q "^ttyd" "$CALLS"
}

ports_of() { # ports_of <compose> — les ports du conteneur publiés, le compose rendu avec les constantes de l'installeur, sans daemon
  env -i PATH="$PATH" HOME="$HOME" DOCKER_HOST="unix://$BATS_TEST_TMPDIR/aucun-daemon.sock" LCARS_STORE_PREFIX=temoin \
    docker compose --env-file "$BATS_TEST_DIRNAME/../../installer-constants.env" -f "$1" -p temoin config --format json \
    | jq -r '.services[].ports[]? | .target' | sort -u
}

@test "6-072: the compose publishes no RANGE of ports" {
  local dir="$BATS_TEST_DIRNAME/../../docker"
  refute grep -qE '[0-9]+-[0-9]+:[0-9]+-[0-9]+' "$dir/docker-compose.yml"
}

@test "6-072: NOTHING of the per-human block space is published" {
  local dir="$BATS_TEST_DIRNAME/../../docker" p
  for p in $(ports_of "$dir/docker-compose.yml"); do
    [ "$p" -lt 21000 ] || [ "$p" -gt 25999 ] \
      || { echo "docker-compose.yml publie $p, dans l'espace des blocs" >&2; return 1; }
  done
}

@test "6-072: TEMOIN — l'instrument voit encore les publications qui restent" {
  local dir="$BATS_TEST_DIRNAME/../../docker" pub
  pub="$(ports_of "$dir/docker-compose.yml")"
  [ -n "$pub" ]
  grep -qx "20999" <<< "$pub"   # la porte du conteneur
  grep -qx "22"    <<< "$pub"   # ssh, la porte d'admin
}

@test "the deck gains the console group and NOT fleet" {
  grep -q -- '--groups "$CONSOLE_GROUP"' "$LANDING"
  refute grep -qE -- '--groups .*fleet' "$LANDING"
  grep -E '^[^#]*setpriv' "$LANDING" | refute_out '--init-groups'
}


humans_sh() { # humans_sh <passwd-file> <ignore> [--verbose]
  # Le 2e argument est mort — l'eligibilite ne lit aucun groupe — et sa POSITION est gardee pour ne
  # pas reecrire vingt appels. Le nommer `ignore` dit ce qu'il est.
  local pw="$1"; shift
  [[ $# -gt 0 ]] && shift
  local defs="$BATS_TEST_TMPDIR/login.defs"
  printf 'UID_MIN 1000\nUID_MAX 60000\n' > "$defs"
  LCARS_CONSOLE_PASSWD="$pw" PASSWD_DEFS="$defs" \
    run bash "$BATS_TEST_DIRNAME/../../../runtime/services/console-humans.sh" "$@"
}

@test "bornes d'uid illisibles : AUCUNE liste, et le motif est dit" {
  # La borne decide qui recoit une console. La deviner ouvrirait un shell web a tout ce qui vit
  # sous un UID_MIN reel plus haut que le defaut — un fail-open silencieux.
  local pw="$BATS_TEST_TMPDIR/passwd" home="$BATS_TEST_TMPDIR/h"
  mkdir -p "$home/zoe"
  printf 'zoe:x:1015:1015::%s/zoe:/bin/bash\n' "$home" > "$pw"

  LCARS_CONSOLE_PASSWD="$pw" PASSWD_DEFS="$BATS_TEST_TMPDIR/nexistepas" \
    run bash "$BATS_TEST_DIRNAME/../../../runtime/services/console-humans.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *"zoe"* ]]
  [[ "$output" == *"bornes d'uid illisibles"* ]]
}

@test "6-surface: console-humans rend TROIS colonnes — login, uid, et le home qu'il vient de valider" {
  local pw="$BATS_TEST_TMPDIR/passwd" home="$BATS_TEST_TMPDIR/h"
  mkdir -p "$home/zoe"
  printf 'root:x:0:0::/root:/bin/bash\n' > "$pw"
  printf 'zoe:x:1015:1015::%s/zoe:/bin/bash\n' "$home" >> "$pw"

  humans_sh "$pw" "zoe"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "zoe 1015 $home/zoe" ]
}

@test "le SIEGE a une console, comme tout humain de la machine" {
  local pw="$BATS_TEST_TMPDIR/passwd" home="$BATS_TEST_TMPDIR/h"
  mkdir -p "$home/zoe" "$home/admiral"
  printf 'admiral:x:1000:1000::%s/admiral:/bin/bash\n' "$home" > "$pw"
  printf 'zoe:x:1015:1015::%s/zoe:/bin/bash\n' "$home" >> "$pw"

  humans_sh "$pw" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"zoe"* ]]
  [[ "$output" == *"admiral"* ]]
}

@test "l'eligibilite ne lit NI le siege NI un groupe — trois faits locaux, et c'est tout" {
  # Un uid de siege pose ne change rien a la liste : la regle ne le consulte plus. Ce qui sort un
  # compte, c'est son uid hors plage, son home absent ou son shell.
  local pw="$BATS_TEST_TMPDIR/passwd" home="$BATS_TEST_TMPDIR/h"
  mkdir -p "$home/patron" "$home/zoe"
  printf 'patron:x:1000:1000::%s/patron:/bin/bash\n' "$home" > "$pw"
  printf 'zoe:x:1015:1015::%s/zoe:/bin/bash\n' "$home" >> "$pw"
  printf 'nobody:x:65534:65534::/nonexistent:/usr/sbin/nologin\n' >> "$pw"

  LCARS_SYSADMIN_UID=1000 humans_sh "$pw" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"patron"* ]]
  [[ "$output" == *"zoe"* ]]
  [[ "$output" != *"nobody"* ]]
}


@test "l'humain de fleet du rail poste (useradd -g fleet) est servi — le cas qui affichait « 0 pod »" {
  local pw="$BATS_TEST_TMPDIR/passwd" home="$BATS_TEST_TMPDIR/h"
  mkdir -p "$home/lcars"
  printf 'lcars:x:1001:2000::%s/lcars:/bin/bash\n' "$home" > "$pw"

  humans_sh "$pw" ""
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "lcars 1001 $home/lcars" ]
}

@test "un humain ORDINAIRE est servi quels que soient ses groupes — le gid ne decide plus rien" {
  local pw="$BATS_TEST_TMPDIR/passwd" home="$BATS_TEST_TMPDIR/h"
  mkdir -p "$home/zoe" "$home/max"
  # Deux gids sans aucun rapport avec `fleet`, et aucun fichier de groupe n'est fourni : sous
  # l'ancienne regle, les deux etaient rejetes.
  printf 'zoe:x:1015:4242::%s/zoe:/bin/bash\n' "$home" > "$pw"
  printf 'max:x:1016:7777::%s/max:/bin/bash\n' "$home" >> "$pw"

  humans_sh "$pw" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"zoe"* ]]
  [[ "$output" == *"max"* ]]
}

@test "6-surface: un humain SANS home est refuse — une console sans home s'ouvre sur / et ment" {
  local pw="$BATS_TEST_TMPDIR/passwd" home="$BATS_TEST_TMPDIR/h"
  mkdir -p "$home/zoe"
  printf 'zoe:x:1015:1015::%s/zoe:/bin/bash\n' "$home" > "$pw"
  printf 'max:x:1016:1016::%s/absent:/bin/bash\n' "$home" >> "$pw"

  humans_sh "$pw" "zoe,max"
  [ "$status" -eq 0 ]
  [[ "$output" == *"zoe"* ]]
  [[ "$output" != *"max"* ]]
}

@test "6-surface: un revoque (nologin) et un compte systeme sont hors de la liste" {
  local pw="$BATS_TEST_TMPDIR/passwd" home="$BATS_TEST_TMPDIR/h"
  mkdir -p "$home/zoe" "$home/gone" "$home/svc"
  printf 'zoe:x:1015:1015::%s/zoe:/bin/bash\n' "$home" > "$pw"
  printf 'gone:x:1016:1016::%s/gone:/usr/sbin/nologin\n' "$home" >> "$pw"
  printf 'svc:x:120:120::%s/svc:/bin/bash\n' "$home" >> "$pw"

  humans_sh "$pw" "zoe,gone,svc"
  [ "$status" -eq 0 ]
  [[ "$output" == *"zoe"* ]]
  [[ "$output" != *"gone"* ]]
  [[ "$output" != *"svc"* ]]
}


@test "rejoue sur une console VIVANTE : aucun ttyd de plus, la socket n'est pas touchee" {
  run_console
  [ "$status" -eq 0 ]
  local avant; avant="$(grep -c '^ttyd ' "$CALLS")"
  local inode; inode="$(stat -c '%i' "$LCARS_CONSOLE_SOCK_ROOT/bt/console.sock")"

  run_console
  [ "$status" -eq 0 ]

  # Pas un ttyd de plus : ni pour la console, ni pour les pods.
  [ "$(grep -c '^ttyd ' "$CALLS")" -eq "$avant" ]
  # ET LA SOCKET EST LA MEME — un `rm -f` suivi d'un re-bind rendrait le meme CHEMIN avec un autre
  # inode, ce qui coupe tout navigateur deja connecte. Le compte de processus seul ne le verrait pas.
  [ "$(stat -c '%i' "$LCARS_CONSOLE_SOCK_ROOT/bt/console.sock")" = "$inode" ]
}

@test "une socket RESIDUELLE (fichier sans serveur) est bien remplacee" {
  mkdir -p "$LCARS_CONSOLE_SOCK_ROOT/bt"
  python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$LCARS_CONSOLE_SOCK_ROOT/bt/console.sock"
  [ -S "$LCARS_CONSOLE_SOCK_ROOT/bt/console.sock" ]

  run_console
  [ "$status" -eq 0 ]
  [ -n "$(ttyd_line console.sock)" ]
}


hc_cmd() { grep -A1 '^HEALTHCHECK ' "$DOCKERFILE" | tail -n1; }

@test "la sonde de l'image teste le DECK, pas seulement sshd" {
  # Sans cette moitie, le healthcheck mesure une porte d'admin et la presente comme la sante du
  # conteneur. Les deux ports sont testes : sshd reste la porte de secours, le deck est l'entree.
  hc_cmd | grep -q '/dev/tcp/127.0.0.1/22'
  hc_cmd | grep -q 'LCARS_LANDING_PORT'
}

@test "la sonde lit le PORT depuis l'environnement, jamais un littéral" {
  hc_cmd | grep -q '${LCARS_LANDING_PORT:-20999}'
}

@test "une landing DESACTIVEE ne rend pas le conteneur malade — c'est un reglage, pas une panne" {
  # `LCARS_LANDING=0` est supporte par l'entrypoint. Sonder son port quand meme transformerait un
  # reglage en panne definitive : le conteneur serait *unhealthy* a vie, sans que rien ne soit casse.
  hc_cmd | grep -q '${LCARS_LANDING:-1}'
}

@test "la sonde de l'image est du JSON valide — la forme exec, pas un shell devine" {
  # Un `CMD` en forme exec est un tableau JSON. Une guillemet mal echappee ne casse pas le build :
  # docker retombe sur la forme SHELL et execute la ligne autrement que ce qu'on a ecrit.
  run python3 -c 'import json,sys; a=json.loads(sys.stdin.read().strip().removeprefix("CMD ")); sys.exit(0 if len(a)==3 and a[0]=="bash" else 1)'  <<< "$(hc_cmd)"
  [ "$status" -eq 0 ]
}

