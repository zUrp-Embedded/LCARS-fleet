#!/usr/bin/env bats
# SOURCE: runtime/test/bin/host_launch.bats
# AUTHOR: bob
# STARDATE: 2026-09-15
# STATUS: témoins de bin/host_launch.sh — la racine des sockets tmux vient du spawner, jamais d'un défaut du lanceur
#
# Le lancement réel (tmux, holder, teardown) est prouvé par test/integration/host_launch_test.sh, une
# sonde manuelle. Ce fichier tient ce qui se joue sans tmux : le refus d'une racine absente (RT-C-15).
# Le lanceur portait `/run/lcars/tmux-sock` pour défaut, alors que PodTmux, `fleet`, `lcars` et les
# consoles cherchent les sockets sous `~/.lcars/run/tmux-sock` : un pod lancé sans la variable
# naissait là où rien ne le voit.

load ../support/refute

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../bin/host_launch.sh"
  POD_DIR="$BATS_TEST_TMPDIR/pod"; mkdir -p "$POD_DIR"
  export LCARS_POD_SESSION_ID="test-session-uuid"
  export LCARS_POD_SESSION_NAME_PREFIX="lordzurp_admiral"
  # un tmux qui note son appel : aucun témoin ci-dessous ne doit l'atteindre
  export CALLS="$BATS_TEST_TMPDIR/tmux.calls"
  export LCARS_TMUX_BIN="$BATS_TEST_TMPDIR/tmux"
  printf '#!/usr/bin/env bash\necho "TMUX $*" >> "$CALLS"\n' > "$LCARS_TMUX_BIN"; chmod +x "$LCARS_TMUX_BIN"
}

@test "sans LCARS_TMUX_SOCK_BASE : refus qui nomme la variable et sa source, aucun défaut recopié, tmux jamais appelé" {
  unset LCARS_TMUX_SOCK_BASE
  run "$SCRIPT" admiral pod-1 "$POD_DIR" /bin/true
  [ "$status" -eq 1 ]
  [[ "$output" == *"LCARS_TMUX_SOCK_BASE: non posé"*"Fleet.Spawner.PodTmux"* ]]
  [[ "$output" != *"/run/lcars/tmux-sock"* ]]
  refute test -s "$CALLS"
}

@test "racine posée mais absente du disque : refus qui la nomme, tmux jamais appelé" {
  export LCARS_TMUX_SOCK_BASE="$BATS_TEST_TMPDIR/jamais-cree"
  run "$SCRIPT" admiral pod-1 "$POD_DIR" /bin/true
  [ "$status" -eq 1 ]
  [[ "$output" == *"sock parent $LCARS_TMUX_SOCK_BASE missing"* ]]
  refute test -s "$CALLS"
}
