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
  SRC="$BATS_TEST_DIRNAME/../../services/console.sh"
  LANDING="$BATS_TEST_DIRNAME/../../services/console-landing.sh"
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
  # BIND *ET* LISTEN, comme le vrai ttyd. Un `bind` seul cree bien un fichier de socket, mais toute
  # connexion dessus est REFUSEE — et c'est exactement ce que la sonde d'idempotence mesure. Une
  # doublure qui ne fait que binder rendrait « morte » une console que le vrai ttyd sert.
  # BIND *ET* LISTEN, comme le vrai ttyd. Un `bind` seul cree bien un fichier de socket, mais toute
  # connexion dessus est REFUSEE — et c'est exactement ce que la sonde d'idempotence mesure. Une
  # doublure qui ne fait que binder rendrait « morte » une console que le vrai ttyd sert. Le
  # `setsid` + les redirections detachent l'ecouteur du tuyau de bats, qui attendrait sinon sa fin.
  if [[ -n "\$sock" ]]; then
    setsid python3 -c 'import socket,sys,time
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(8); time.sleep(6)' "\$sock" \
      </dev/null >/dev/null 2>&1 &
    for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -S "\$sock" ]] && break; sleep 0.1; done
  fi
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

  grep -q -- "setpriv --reuid bt --regid 1000" "$CALLS"
  ! grep -qE "^setpriv .*--reuid (root|0)( |$)" "$CALLS"
}

# ─── LE GID EST UN NOMBRE QU'ON LIT, PAS UN NOM QU'ON SUPPOSE ───────────────────────────────────
#
# Cette ligne a porte `--regid bt` pendant sa vie entiere, et le test l'epinglait — les deux
# supposaient qu'un groupe porte le nom de l'humain. C'est vrai sous `USERGROUPS_ENAB yes` (le
# defaut Debian, donc l'image) et FAUX des qu'un compte nait avec un groupe primaire nomme :
# `useradd -g fleet lcars` ne cree AUCUN groupe `lcars`.
#
# Mesure du 2026-08-21, poste natif : « setpriv: failed to parse regid: 'lcars' » — la console de
# l'humain de fleet mourait au demarrage, et le message affiche ensuite accusait la socket. Le gid
# est le champ 4 de la ligne passwd d'ou le script tire deja le home (6) et le shell (7).
@test "le gid primaire vient de passwd, pas du login — un groupe eponyme n'est pas supposé" {
  # bt a le gid 1000 et AUCUN groupe `bt` : la doublure `getent` refuse `group bt` (exit 2), comme
  # une vraie base ou le groupe n'existe pas.
  run_console
  [ "$status" -eq 0 ]

  ! grep -qE "^setpriv .*--regid bt( |$)" "$CALLS"
  # les DEUX consoles (humain et pod) passent par la meme identite — le second site avait ete
  # oublie une fois deja, il est nomme ici.
  [ "$(grep -c -- "setpriv --reuid bt --regid 1000" "$CALLS")" -ge 2 ]
}

@test "un humain dont le groupe primaire est NOMMÉ démarre quand même — la faute d'origine" {
  # `lcars`, gid 1003 (fleet) : la forme exacte que 22-fleet-human pose sur le rail poste, et celle
  # sur laquelle setpriv refusait de parser.
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
  ! grep -q -- "--regid lcars" "$CALLS"
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

humans_sh() { # humans_sh <passwd-file> <ignore> [--verbose]
  # ⚠ LE 2e ARGUMENT NE SERT PLUS A RIEN, ET IL EST GARDE EXPRES. L'eligibilite ne lit plus AUCUN
  # groupe : elle derive de conditions de SIEGE (uid dans la plage, home, shell, et pas le siege).
  # Garder la position evite de reecrire vingt appels pour un parametre mort — et le nommer `ignore`
  # dit ce qu'il est. Le jour ou quelqu'un lui redonne un sens, il le fera en le renommant.
  local pw="$1"; shift
  [[ $# -gt 0 ]] && shift
  LCARS_CONSOLE_PASSWD="$pw" \
    run bash "$BATS_TEST_DIRNAME/../../services/console-humans.sh" "$@"
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

# ─── L'ELIGIBILITE NE DERIVE PLUS D'UN GROUPE, ELLE DERIVE DU SIEGE ─────────────────────────────
#
# ⚠ CE TEMOIN EPINGLAIT « hors du groupe `fleet` -> rejete », et il appelait ce groupe une AUTORITE.
# C'en etait une PROJECTION : le convergeur y ajoutait chaque membre de l'equipe `humans` de la
# forge, toutes les trente secondes. Filtrer dessus, c'etait lire un cache pour repondre a une
# question qui n'en a pas besoin — « cette personne a-t-elle un siege de travail sur cette machine ».
#
# Le groupe n'ouvre plus rien depuis ce chantier. Ce qui reste a garder est la seule exclusion qui
# ait jamais eu une raison — et elle etait un EFFET DE BORD, jamais une regle : le siege.
@test "le SIEGE n'a pas de console worker — condition ECRITE, plus un effet de bord du groupe" {
  local pw="$BATS_TEST_TMPDIR/passwd" home="$BATS_TEST_TMPDIR/h"
  mkdir -p "$home/zoe" "$home/admiral"
  # Le siege est eligible sur TOUS les autres criteres : uid dans la plage, home, /bin/bash. Seule
  # sa qualite de siege le sort — lui ouvrir une console worker mettrait un shell sudo-capable
  # derriere la porte WEB de la boite, l'exact inverse de ce que les pods confinent.
  printf 'admiral:x:1000:1000::%s/admiral:/bin/bash\n' "$home" > "$pw"
  printf 'zoe:x:1015:1015::%s/zoe:/bin/bash\n' "$home" >> "$pw"

  humans_sh "$pw" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"zoe"* ]]
  [[ "$output" != *"admiral"* ]]
}

@test "le siege se reconnait a son UID, jamais a son login — le login est VARIABLE" {
  # `00` §5 : `admiral` sur banc, le login que l'installeur a cree en prod. La cle est l'uid, la
  # meme que GUARD A/B et que le miroir BEAM de `runtime.exs`. Ici le siege s'appelle `patron` et il
  # est exclu quand meme ; un compte NOMME `admiral` a un uid ordinaire ne l'est PAS.
  local pw="$BATS_TEST_TMPDIR/passwd" home="$BATS_TEST_TMPDIR/h"
  mkdir -p "$home/patron" "$home/admiral"
  printf 'patron:x:1000:1000::%s/patron:/bin/bash\n' "$home" > "$pw"
  printf 'admiral:x:1042:1042::%s/admiral:/bin/bash\n' "$home" >> "$pw"

  humans_sh "$pw" ""
  [ "$status" -eq 0 ]
  [[ "$output" != *"patron"* ]]
  [[ "$output" == *"admiral"* ]]
}

@test "l'uid du siege est un REGLAGE, pas le chiffre 1000 code en dur" {
  local pw="$BATS_TEST_TMPDIR/passwd" home="$BATS_TEST_TMPDIR/h"
  mkdir -p "$home/zoe" "$home/chef"
  printf 'chef:x:1077:1077::%s/chef:/bin/bash\n' "$home" > "$pw"
  printf 'zoe:x:1015:1015::%s/zoe:/bin/bash\n' "$home" >> "$pw"

  LCARS_SYSADMIN_UID=1077 humans_sh "$pw" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"zoe"* ]]
  [[ "$output" != *"chef"* ]]
}

# ─── LE MEMBRE QUE `/etc/group` NE NOMMAIT PAS — LA CICATRICE, ET POURQUOI ELLE RESTE ───────────
#
# Un compte cree `useradd -g fleet` a le groupe pour gid PRIMAIRE, et /etc/group ne le liste PAS
# dans son champ 4 — ce champ ne porte que les ajouts secondaires. `id -nG` le disait membre, le
# fichier non : deux reponses vraies a deux questions differentes, et la regle lisait la mauvaise.
#
# Mesure du 2026-08-21, poste natif : `lcars`, l'humain de fleet pose par 22-fleet-human, tenait le
# BEAM et sa `deck.sock` — et etait absent de cette liste. Le deck ne lisait donc jamais sa socket
# et affichait « 0 pod » sur une fleet vivante. Le mode de defaillance est le pire qui soit : un
# compteur a zero, identique a celui d'une fleet reellement vide.
#
# ⚠ CE PIEGE N'EXISTE PLUS, ET LE TEMOIN RESTE PARCE QUE SON CAS EST REEL. `lcars` est le compte que
# `22-fleet-human` pose sur toute boite native, avec exactement cette forme de ligne de passwd — il
# DOIT etre servi. Il l'est maintenant pour une raison plus simple : plus rien ne regarde son gid.
# Garder le cas coute une ligne et attrape le jour ou quelqu'un rebranche une lecture de groupe ;
# le retirer parce que « sa cause a disparu » retirerait la preuve que la cause a disparu.
@test "l'humain de fleet du rail poste (useradd -g fleet) est servi — le cas qui affichait « 0 pod »" {
  local pw="$BATS_TEST_TMPDIR/passwd" home="$BATS_TEST_TMPDIR/h"
  mkdir -p "$home/lcars"
  # La forme EXACTE que `22-fleet-human` produit : gid primaire = celui de `fleet`, champ 4 vide.
  printf 'lcars:x:1001:2000::%s/lcars:/bin/bash\n' "$home" > "$pw"

  humans_sh "$pw" ""
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "lcars 1001 $home/lcars" ]
}

# ⚠ CE TEMOIN EPINGLAIT « un autre gid reste dehors », ET SON SUJET A DISPARU AVEC LE FILTRE. Il
# gardait une comparaison d'egalite sur un gid — utile tant que le gid decidait. Il ne decide plus
# rien : ce qui le remplace est sa CONTREPARTIE, et elle est la moitie qu'aucun temoin ne tenait.
#
# Sans elle, un `console-humans.sh` qui rejetterait TOUT passerait les trois temoins du siege
# ci-dessus — ils cherchent tous une ABSENCE — et la boite n'ouvrirait plus une seule console, en
# affichant « 0 pod », c'est-a-dire exactement ce qu'affiche une fleet vide.
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

# ─── l'idempotence, qui etait DECLAREE ailleurs et n'existait pas ─────────────────────────────────

@test "rejoue sur une console VIVANTE : aucun ttyd de plus, la socket n'est pas touchee" {
  # LE DEFAUT MESURE (2026-08-18). `human-converger.sh` appelle `console.sh --human` PAR HUMAIN ET
  # PAR TOUR (30 s), sous un commentaire qui affirmait que ce script « sonde la socket avant de
  # lancer quoi que ce soit ». Il ne sondait rien : `rm -f` puis relance. Resultat sur un banc de
  # trente minutes : **64 ttyd par humain**, empiles sur la meme socket, celle-ci effacee et
  # re-posee sous le navigateur a chaque tour. L'operateur voyait « la console du nouvel humain ne
  # demarre pas » — elle demarrait, et la suivante la remplacait.
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
  # L'autre moitie, et sans elle la garde ci-dessus serait un blocage permanent : un fichier de
  # socket survit a son processus. `[[ -S ]]` ne distingue pas les deux etats — seule une connexion
  # le fait, et c'est ce que le deck fera.
  mkdir -p "$LCARS_CONSOLE_SOCK_ROOT/bt"
  python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$LCARS_CONSOLE_SOCK_ROOT/bt/console.sock"
  [ -S "$LCARS_CONSOLE_SOCK_ROOT/bt/console.sock" ]

  run_console
  [ "$status" -eq 0 ]
  [ -n "$(ttyd_line console.sock)" ]
}
