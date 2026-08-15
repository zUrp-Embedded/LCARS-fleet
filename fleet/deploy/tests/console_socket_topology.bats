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

# ─── L'ESPACE DES BLOCS N'EST PLUS PUBLIE DU TOUT ──────────────────────────────────────────────
# ⚠ CES TEMOINS ONT ETE REMPLACES, PAS RAPIECES. Ils epinglaient un contrat qui a tenu une demi-
# journee : « ce qui a un ecoutant est publie », avec une liste de six ports vivants. Ce contrat est
# mort quand la mesure a montre qu'AUCUN d'eux n'etait appele — la surface API a ete supprimee, le
# webhook aussi. Garder l'ancienne forme aurait epingle une liste que plus rien n'honore.
#
# LE NOUVEAU CONTRAT EST PLUS SIMPLE ET PLUS FORT : rien de l'espace des blocs (21000..25999) n'est
# publie. Il ne s'enumere pas, donc il ne perime pas a chaque service qui naît ou meurt — et il
# survit a l'UID tire de la forge, qui rend les blocs NON CONTIGUS (`lcars` = id 3 -> uid 1003 ->
# bloc 21030) et donc indevinables depuis un fichier qui ne connait pas les humains.
#
# Ce qui reste publie se dit en une ligne : ssh, et la porte de la boite.
# ⚠ ON LIT LE PORT DE FIN DE LIGNE, PAS UN MOTIF `hote:port:port`. La forme reelle du compose est
# `- "${VAR:-127.0.0.1:2222}:22"` : une accolade separe les deux nombres, donc tout motif
# `:[0-9]+:[0-9]+` rate TOUTES les publications a variable — c'est-a-dire toutes. Premiere version de
# cet extracteur, et il rendait une liste vide sur un compose qui publie deux ports.
ports_of() {
  grep -oE '^\s*- "[^"]+"' "$1" | grep -oE ':[0-9]+"$' | tr -d ':"' | sort -u
}

@test "6-072: neither compose publishes a RANGE of ports" {
  local dir="$BATS_TEST_DIRNAME/../docker"
  ! grep -qE '[0-9]+-[0-9]+:[0-9]+-[0-9]+' "$dir/docker-compose.yml"
  ! grep -qE '[0-9]+-[0-9]+:[0-9]+-[0-9]+' "$dir/docker-compose.install.yml"
}

@test "6-072: NOTHING of the per-human block space is published, by either compose" {
  # La propriete, pas la liste : un port publie sans ecoutant est une adresse libre dans un
  # conteneur qui porte SYS_ADMIN, et les listeners bindent 0.0.0.0 a l'interieur — donc CE BLOC EST
  # LA FRONTIERE. Enumerer les vivants obligerait a re-editer ce test a chaque service ; interdire
  # l'espace entier tient tout seul.
  local dir="$BATS_TEST_DIRNAME/../docker" p
  for f in docker-compose.yml docker-compose.install.yml; do
    for p in $(ports_of "$dir/$f"); do
      [ "$p" -lt 21000 ] || [ "$p" -gt 25999 ] \
        || { echo "$f publie $p, dans l'espace des blocs" >&2; return 1; }
    done
  done
}

@test "6-072: TEMOIN — l'instrument voit encore les publications qui restent" {
  # Sans lui, un `ports_of` casse rendrait une liste vide et le test ci-dessus passerait EN NE
  # MESURANT RIEN. C'est exactement le vert creux qu'une contre-epreuve avait deja trouve ici le
  # 2026-08-14, sur la forme en plage. Une liste vide n'est jamais une reponse.
  local dir="$BATS_TEST_DIRNAME/../docker" pub
  pub="$(ports_of "$dir/docker-compose.yml")"
  [ -n "$pub" ]
  grep -qx "20999" <<< "$pub"   # la porte de la boite
  grep -qx "22"    <<< "$pub"   # ssh, la porte d'admin
}

@test "6-072: the two composes publish the SAME list — a drift would be silent" {
  # One is the dev compose, the other the installed one. They already diverged once on a port
  # variable (measured 2026-08-03, and the divergence WAS the trap). Nothing but this test makes
  # the duplication safe.
  local dir="$BATS_TEST_DIRNAME/../docker" a b
  a="$(ports_of "$dir/docker-compose.yml")"
  b="$(ports_of "$dir/docker-compose.install.yml")"
  [ -n "$a" ] && [ -n "$b" ]
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

# ─── `console-humans.sh` EST LA REGLE, ET SA SORTIE EST UN CONTRAT ────────────────────────────────
#
# Ce script n'avait AUCUN test, et sa sortie vient de changer : la 3e colonne portait un bloc de
# ports (supprime avec la formule), elle porte maintenant le HOME. Le deck l'appelle desormais au
# lieu de refaire son propre filtre sur /etc/passwd — c'est ce qui met fin a la seconde autorite. Un
# contrat que deux programmes lisent et que rien n'epingle est un contrat en sursis.

humans_sh() { # humans_sh <passwd-file> <fleet-members-csv> [--verbose]
  # identite-v2 : l'eligibilite derive du groupe `fleet`. Le 2e arg = les membres (csv) que le test
  # declare dans le groupe ; un compte absent de cette liste est rejete meme s'il est valide par ailleurs.
  local pw="$1"; shift
  local members="${1:-}"; [[ $# -gt 0 ]] && shift
  local grp="$BATS_TEST_TMPDIR/group.humans_sh"
  printf 'fleet:x:2000:%s\n' "$members" > "$grp"
  LCARS_CONSOLE_PASSWD="$pw" LCARS_CONSOLE_GROUP_FILE="$grp" \
    run bash "$BATS_TEST_DIRNAME/../docker/console-humans.sh" "$@"
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

@test "identite-v2: un compte eligible HORS du groupe fleet est rejete (derive de l'autorite, pas de l'uid)" {
  local pw="$BATS_TEST_TMPDIR/passwd" home="$BATS_TEST_TMPDIR/h"
  mkdir -p "$home/zoe" "$home/ghost"
  # ghost : uid valide, home, /bin/bash -> eligible sur TOUS les criteres SAUF le groupe fleet.
  # (admiral, lui, EST dans le groupe fleet — c'est ainsi qu'il a sa console ; cf. entrypoint/20-groups.)
  printf 'ghost:x:1044:1044::%s/ghost:/bin/bash\n' "$home" > "$pw"
  printf 'zoe:x:1015:1015::%s/zoe:/bin/bash\n' "$home" >> "$pw"

  humans_sh "$pw" "zoe"   # seul zoe est membre du groupe fleet
  [ "$status" -eq 0 ]
  [[ "$output" == *"zoe"* ]]
  [[ "$output" != *"ghost"* ]]
}

@test "6-surface: un humain SANS home est refuse — une console sans home s'ouvre sur / et ment" {
  local pw="$BATS_TEST_TMPDIR/passwd" home="$BATS_TEST_TMPDIR/h"
  mkdir -p "$home/zoe"
  printf 'zoe:x:1015:1015::%s/zoe:/bin/bash\n' "$home" > "$pw"
  printf 'max:x:1016:1016::%s/absent:/bin/bash\n' "$home" >> "$pw"

  # ⚠ C'EST L'ECART QUI MORDAIT. Le deck acceptait `max` (il ne regardait pas le home) et affichait
  # son siege ; `console.sh --all` ne lui demarrait jamais de console. La page rendait donc « cette
  # console ne fonctionne pas » a quelqu'un dont le compte allait parfaitement bien.
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
