#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/console_socket_topology.bats
# AUTHOR: drdree
# STARDATE: 2026-08-14
# STATUS: bats tests for console.sh + console-landing.sh — JG-072/JG-098, le terminal n'a plus de port
#
# WHY THIS EXISTS. The invariant of this lot is not "the terminal is authenticated" -- it is "the
# terminal HAS NO PORT". A rule gets worked around and forgotten at the next route; a topology
# cannot be worked around, because there is no second path to discipline. So what is pinned here is
# the SHAPE of the thing: no `-p` on either ttyd, an AF_UNIX socket under a directory whose mode is
# the guard, and a deck that gains exactly one supplementary group.
#
# ⚠ THE ASSERTIONS READ THE COMMAND LINE ttyd ACTUALLY RECEIVES, not the source of the script. A
# grep over the source would pass on a script that builds the right array and then launches
# something else -- and the whole point of this lot is that the reachable surface is what counts,
# not what the code says about itself.
#
# WHAT IS NOT PROVEN HERE, and cannot be by a stub: that the kernel refuses a `connect(2)` to a
# directory the caller cannot traverse. That is the kernel's behaviour, measured on a live box on
# 2026-08-14 (`nobody` without the group -> connection refused; with `--groups` -> 200) and recorded
# in the chantier design. A stub can only prove we ASK for the right mode.

setup() {
  SRC="$BATS_TEST_DIRNAME/../docker/console.sh"
  LANDING="$BATS_TEST_DIRNAME/../docker/console-landing.sh"
  BINDIR="$BATS_TEST_TMPDIR/bin"
  CALLS="$BATS_TEST_TMPDIR/calls"

  # ⚠ LA RACINE DES SOCKETS NE PEUT PAS VIVRE DANS $BATS_TEST_TMPDIR, et le motif vaut d'etre su :
  # `sun_path` fait 108 octets NUL compris, et le repertoire temporaire de bats est deja profond --
  # le `bind()` echouait avec « AF_UNIX path too long » et ttyd mourait, ce qui se lisait comme une
  # console qui ne se leve pas. Le script porte desormais sa propre garde sur cette limite ; ce
  # harnais doit rester SOUS elle, sinon il mesure la garde au lieu de mesurer la topologie.
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
  [[ -n "\$sock" ]] && python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "\$sock"
fi
sleep 5
EOF

  # setpriv is the identity boundary, and the stub must not swallow it: it LOGS what it was asked to
  # become, then runs the tail after `--`. A stub that just exec'd the command would let a
  # regression on `--reuid` through unseen.
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

  # ⚠ TOUS LES STUBS SONT CREES ET RENDUS EXECUTABLES **AVANT** D'EXPORTER LE PATH, et ce n'est pas
  # cosmetique : `chmod` fait partie des stubs. Fait dans l'autre ordre, le `chmod` du harnais est le
  # STUB (exit 0, aucun effet), `podsh` reste non executable, `console.sh` declare les consoles de
  # pod indisponibles et sort proprement en 0 -- trois assertions echouaient en accusant le script
  # alors que l'outil s'etait mordu la queue. Mesure : hors bats, les deux ttyd se lancent.
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

  ! grep -qE "^ttyd .* -p( |$)" "$CALLS"
  ! grep -q -- "-i 0.0.0.0" "$CALLS"
}

@test "JG-072: each ttyd listens on an AF_UNIX socket under the console root" {
  run_console
  [ "$status" -eq 0 ]

  [[ "$(ttyd_line console.sock)" == *"-i $LCARS_CONSOLE_SOCK_ROOT/bt/console.sock"* ]]
  [[ "$(ttyd_line pod.sock)"     == *"-i $LCARS_CONSOLE_SOCK_ROOT/bt/pod.sock"* ]]
}

@test "JG-072: the per-human directory is asked for as 2710 <human>:lcars-console" {
  # The MODE is the guard -- `connect(2)` requires traversing every directory of the path. 0710
  # gives the owner everything and the group `--x` only (traverse, no listing); the setgid `2` is
  # what makes ttyd's socket inherit the group WITHOUT ttyd ever changing identity.
  run_console
  [ "$status" -eq 0 ]

  grep -q -- "install -d -m 2710 -o bt -g lcars-console $LCARS_CONSOLE_SOCK_ROOT/bt" "$CALLS"
  # Re-affirmed after the fact: `install -d` does NOT re-apply the mode to an existing directory,
  # so a directory inherited from an earlier version would silently keep the old one.
  grep -q -- "chmod 2710 $LCARS_CONSOLE_SOCK_ROOT/bt" "$CALLS"
  grep -q -- "chown bt:lcars-console $LCARS_CONSOLE_SOCK_ROOT/bt" "$CALLS"
}

@test "JG-072: ttyd is asked to refuse a request without the identity header" {
  # Defence in depth behind the directory guard, and free: measured 2026-08-14 on the pinned binary,
  # `-H` makes ttyd answer 407 without the header and 200 with it. ⚠ It proves PRESENCE, never the
  # value nor the sender -- the relay must overwrite it. This test pins the flag, not a guarantee.
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

  grep -q -- "setpriv --reuid bt --regid bt" "$CALLS"
  ! grep -qE "^setpriv .*--reuid (root|0)( |$)" "$CALLS"
}

@test "a live process with NO socket is a FAILURE, not a running console" {
  # The process is only the producer; what the deck will open is the file. Before this guard, a ttyd
  # that started and failed to bind was reported as "vivante" and the human went looking in a
  # browser for something that never existed.
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
  ! grep -q "^ttyd" "$CALLS"
}

# ─── CE QUI EST PUBLIE EST CE QUI EST SERVI ────────────────────────────────────────────────────
# The two composes published `21000-21029` — 30 ports for six possible listeners. The three missing
# from the roll call are the ones this lot killed. A published port with no listener is a free
# address inside a container that carries SYS_ADMIN: the first process to take it inherits a door
# nobody guards. A RANGE makes that room available in silence; an enumeration makes opening it cost
# a line somebody has to write.
ports_of() {
  grep -oE '"\$\{LCARS_BIND[^"]*\}:[0-9]+:[0-9]+"' "$1" | grep -oE ':[0-9]+"' | tr -d ':"' | sort -u
}

# ⚠ GARDE ANTI-VERT-CREUX, ET ELLE A ETE TROUVEE PAR LA CONTRE-EPREUVE. `ports_of` n'extrait que des
# ports EXPLICITES : sur l'ancienne forme (`21000-21029:21000-21029`) elle rend une liste VIDE, donc
# « aucun port mort n'est publie » devenait vrai en ne mesurant rien, et « les deux listes sont
# identiques » aussi (vide == vide). Les deux assertions passaient sur le code qu'elles devaient
# refuser. Une liste vide n'est donc plus une reponse : c'est un instrument casse.
assert_measured() {
  [ -n "$1" ] || { echo "ports_of n'a rien extrait — instrument casse ou plage revenue" >&2; return 1; }
}

@test "6-072: neither compose publishes a RANGE of ports" {
  local dir="$BATS_TEST_DIRNAME/../docker"
  ! grep -qE '[0-9]+-[0-9]+:[0-9]+-[0-9]+' "$dir/docker-compose.yml"
  ! grep -qE '[0-9]+-[0-9]+:[0-9]+-[0-9]+' "$dir/docker-compose.install.yml"
}

@test "6-072: the ports the lot killed are published by NEITHER compose" {
  local dir="$BATS_TEST_DIRNAME/../docker" pub
  pub="$(ports_of "$dir/docker-compose.yml"; ports_of "$dir/docker-compose.install.yml")"
  assert_measured "$pub"

  # base+1 observation deck · base+4 console · base+5 pod console, for the three human blocks.
  for dead in 21001 21004 21005 21011 21014 21015 21021 21024 21025; do
    ! grep -qx "$dead" <<< "$pub"
  done
}

@test "6-072: TEMOIN — what still HAS a listener is still published" {
  # Without this, deleting every port would pass the test above. base+0 is the API (out of this
  # lot's scope, named) and base+3 the opt-in webhook.
  local dir="$BATS_TEST_DIRNAME/../docker" pub
  pub="$(ports_of "$dir/docker-compose.yml")"

  for live in 21000 21003 21010 21013 21020 21023; do
    grep -qx "$live" <<< "$pub"
  done
}

@test "6-072: the two composes publish the SAME list — a drift would be silent" {
  # One is the dev compose, the other the installed one. They already diverged once on a port
  # variable (measured 2026-08-03, and the divergence WAS the trap). Nothing but this test makes
  # the duplication safe.
  local dir="$BATS_TEST_DIRNAME/../docker" a b
  a="$(ports_of "$dir/docker-compose.yml")"
  b="$(ports_of "$dir/docker-compose.install.yml")"
  assert_measured "$a"
  assert_measured "$b"
  [ "$a" = "$b" ]
}

@test "the deck gains the console group and NOT fleet" {
  # `fleet` (gid 2000) already carries read access to /local/LCARS_v2 and elsewhere; reusing it would
  # have been shorter and would have granted all of that too. The power granted here has to be
  # sayable in one sentence: traverse the consoles' socket directories.
  grep -q -- '--groups "$CONSOLE_GROUP"' "$LANDING"
  ! grep -qE -- '--groups .*fleet' "$LANDING"
  # And it REPLACES --init-groups: setpriv refuses both together -- measured IN THE IMAGE
  # (util-linux 2.38.1), not on a dev box, because a tool's argument handling is a property of the
  # system that runs it. Scoped to the setpriv INVOCATIONS: the comment above them explains the swap
  # and names the flag, and a grep over the whole file would fail on the prose that documents it.
  ! grep -E '^[^#]*setpriv' "$LANDING" | grep -q -- '--init-groups'
}
