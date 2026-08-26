#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/console_creds_drift.bats
# AUTHOR: consultant
# STARDATE: 2026-08-21
# STATUS: bats tests for console.sh — a live console whose credentials the DB has outgrown
#
# WHY THIS EXISTS. `usermod -aG` writes /etc/group and touches no running process. The console's
# ttyd froze its supplementary groups at launch (`setpriv --init-groups`), and the only idempotence
# predicate used to be "does the socket answer" -- so a promotion NEVER reached the one surface
# where a human types commands. Measured 2026-08-20/21 on the live box: the operator was promoted
# on the forge, the converger projected the group, and `lcars catalogue install` kept refusing.
#
# WHAT IS PINNED HERE is the pair that makes the repair honest: the DB/process COMPARISON, and the
# fact that the repair TYPES rather than kills. Killing ttyd would also work and was the first
# draft; it destroys a carrier to refresh a shell, and it takes the human's console with it.
#
# ⚠ THE ASSERTIONS READ THE tmux COMMAND LINE THE SCRIPT ACTUALLY ISSUES, never its source. A grep
# over the source would pass on a script that computes the right group and then sends nothing.
#
# WHAT A STUB CANNOT PROVE, and it must be said: that `newgrp` really re-reads the group database
# and hands back a shell carrying it. That is the tool's behaviour, measured by the operator on the
# live box on 2026-08-20 -- it is what unblocked `catalogue install` when nothing else did.

setup() {
  SRC="$BATS_TEST_DIRNAME/../../services/console.sh"
  BINDIR="$BATS_TEST_TMPDIR/bin"
  CALLS="$BATS_TEST_TMPDIR/calls"

  # ⚠ NOT UNDER $BATS_TEST_TMPDIR: `sun_path` is 108 bytes including the NUL, and bats' temporary
  # directory is already deep -- the bind() fails with "path too long" and the console reads as
  # dead. Same trap as the neighbouring topology suite, which documents the measurement.
  ROOT="$(mktemp -d /tmp/lcd.XXXXXX)"
  PROC="$ROOT/proc"
  SOCKD="$ROOT/console/bt"
  mkdir -p "$BINDIR" "$PROC/4242" "$SOCKD"
  : > "$CALLS"

  # THE CONSOLE IS ALIVE. Everything this suite is about happens on the branch where the socket
  # ANSWERS -- a dead console is relaunched from scratch and carries fresh groups by construction.
  # `bind` alone is not enough: the probe connects, and a bound-but-not-listening socket refuses.
  setsid python3 -c 'import socket,sys,time
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(8); time.sleep(30)' \
    "$SOCKD/console.sock" </dev/null >/dev/null 2>&1 &
  LISTENER=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -S "$SOCKD/console.sock" ]] && break; sleep 0.1; done

  # THE PROCESS SIDE OF THE COMPARISON. `Groups:` carries ONLY the supplementary set; the primary
  # gid lives on `Gid:`. A reader that forgets `Gid:` calls every console stale, because `id -G`
  # always reports the primary group.
  printf 'Name:\tttyd\nGid:\t1000\t1000\t1000\t1000\nGroups:\t2000 2001 \n' > "$PROC/4242/status"

  # THE DATABASE SIDE. 2003 is the promotion the running ttyd never heard about.
  DB_GIDS="$BATS_TEST_TMPDIR/db_gids"
  echo "1000 2000 2001 2003" > "$DB_GIDS"

  TTYD_PID="$BATS_TEST_TMPDIR/ttyd_pid"
  echo "4242" > "$TTYD_PID"

  PANES="$BATS_TEST_TMPDIR/panes"
  printf '%%0\tbash\n' > "$PANES"

  cat > "$BINDIR/pgrep" <<EOF
#!/usr/bin/env bash
echo "pgrep \$*" >> "$CALLS"
cat "$TTYD_PID"
EOF

  cat > "$BINDIR/id" <<EOF
#!/usr/bin/env bash
[[ "\$1" == "-G" ]] && { cat "$DB_GIDS"; exit 0; }
exit 0
EOF

  cat > "$BINDIR/getent" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "passwd bt")            echo "bt:x:1000:1000::/tmp/bt-home:/bin/bash" ;;
  "group 2003")           echo "lcars-spare:x:2003:" ;;
  "group 2001")           echo "fleet:x:2001:" ;;
  "group lcars-console")  echo "lcars-console:x:2002:" ;;
  *) exit 2 ;;
esac
EOF

  # runuser is the identity boundary of the repair, and the stub must not swallow it: it LOGS what
  # it was asked to become, then runs the tail after `--`. A stub that just exec'd would let a
  # regression that types into the WRONG user's console through unseen.
  cat > "$BINDIR/runuser" <<EOF
#!/usr/bin/env bash
echo "runuser \$*" >> "$CALLS"
while [[ \$# -gt 0 && "\$1" != "--" ]]; do shift; done
shift || true
exec "\$@"
EOF

  cat > "$BINDIR/tmux" <<EOF
#!/usr/bin/env bash
echo "tmux \$*" >> "$CALLS"
[[ "\$1" == "list-panes" ]] && { cat "$PANES"; exit 0; }
exit 0
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

  for c in chmod chown ttyd; do
    cat > "$BINDIR/$c" <<EOF
#!/usr/bin/env bash
echo "$c \$*" >> "$CALLS"
exit 0
EOF
  done

  # ⚠ CHMOD IS ITSELF ONE OF THE STUBS: made executable AFTER exporting PATH, the harness' own
  # chmod is the no-op stub and nothing is executable. Same trap the neighbouring suite records.
  chmod 0755 "$BINDIR"/*

  mkdir -p /tmp/bt-home
  export PATH="$BINDIR:$PATH"
  export LCARS_CONSOLE_SOCK_ROOT="$ROOT/console"
  export LCARS_PROC_ROOT="$PROC"
  # The pod console is out of scope here and its launcher only adds noise to $CALLS.
  export LCARS_CONSOLE_POD="$ROOT/absent-pod.sh"
}

teardown() {
  [[ -n "${LISTENER:-}" ]] && kill "$LISTENER" 2>/dev/null || true
  [[ -n "${ROOT:-}" && "$ROOT" == /tmp/lcd.* ]] && rm -rf "$ROOT"
}

run_console() { run bash "$SRC" --human bt; }

# The TEXT call, never the Enter one -- they are two now, and an assertion that grabbed whichever
# came first would drift the day the order changed.
sendkeys_line() { grep -- "tmux send-keys -t .* C-u " "$CALLS" | head -1; }

@test "promotion: the group the DB grants and the ttyd lacks is typed as newgrp" {
  run_console
  [ "$status" -eq 0 ]

  # The group NAME is resolved from the missing GID, never copied into the script -- the mode of
  # the token file is the source of truth elsewhere, and a second hard-coded name would drift.
  [[ "$(sendkeys_line)" == *"newgrp lcars-spare"* ]]
}

@test "promotion: C-u clears the half-typed line before the text is typed" {
  run_console
  [ "$status" -eq 0 ]

  # Without C-u the keystroke is CONCATENATED with whatever the human was typing, which turns a
  # lost line into a command nobody wrote.
  [[ "$(sendkeys_line)" == *" C-u "* ]]
}

@test "the text and its Enter are TWO send-keys, never one" {
  # Fused, the line arrives and the validation is lost: what stays on screen is a command TYPED BUT
  # NOT RUN -- which looks exactly like a successful repair until someone looks at the pane.
  # Operator measurement, twelve times over. Splitting also buys what fusing could not: if the text
  # does not go through, nothing is validated.
  run_console
  [ "$status" -eq 0 ]

  [ "$(grep -c -- "^runuser .* tmux send-keys" "$CALLS")" -eq 2 ]
  [[ "$(sendkeys_line)" != *"Enter"* ]]
  grep -q -- "tmux send-keys -t %0 Enter$" "$CALLS"
}

@test "promotion: the keystroke carries its own explanation on screen" {
  run_console
  [ "$status" -eq 0 ]

  # A line that appears by itself in someone's terminal must say why. It is a shell comment, so it
  # reaches the eye and never `newgrp`.
  [[ "$(sendkeys_line)" == *"###"* ]]
  [[ "$(sendkeys_line)" == *"newgrp recharge"* ]]
}

@test "the repair types, it does not kill: no console relaunch and no tmux kill-server" {
  run_console
  [ "$status" -eq 0 ]

  # ⚠ THE POINT OF THE WHOLE DESIGN. Killing ttyd refreshes the groups too -- and takes the
  # human's console, and whatever runs in it, with it.
  ! grep -q -- "kill-server" "$CALLS"
  ! grep -qE "^ttyd .*console\.sock" "$CALLS"
}

@test "a pane that is not at a shell is left alone" {
  # `send-keys` writes into whatever OWNS the pane. In front of an agent, a pager or a password
  # prompt, the announced cost ("the half-typed line is lost") is not what happens -- it is an
  # injection into a third-party program.
  printf '%%0\tclaude\n' > "$PANES"
  run_console
  [ "$status" -eq 0 ]

  [ -z "$(sendkeys_line)" ]
}

@test "only the pane at a shell is typed into, among several" {
  printf '%%0\tclaude\n%%1\tbash\n%%2\tvim\n' > "$PANES"
  run_console
  [ "$status" -eq 0 ]

  [ "$(grep -c -- "^tmux send-keys -t " "$CALLS")" -eq 2 ]
  [[ "$(sendkeys_line)" == *"-t %1"* ]]
}

@test "no drift: a console whose groups match the DB is not touched" {
  printf 'Name:\tttyd\nGid:\t1000\t1000\t1000\t1000\nGroups:\t2000 2001 2003 \n' > "$PROC/4242/status"
  run_console
  [ "$status" -eq 0 ]

  [ -z "$(sendkeys_line)" ]
}

@test "the primary gid counts as carried, or every console reads as stale" {
  # `id -G` always reports the primary group; `Groups:` never does. A comparison that only reads
  # `Groups:` finds 1000 missing on EVERY console and types into all of them, forever.
  echo "1000 2000 2001" > "$DB_GIDS"
  run_console
  [ "$status" -eq 0 ]

  [ -z "$(sendkeys_line)" ]
}

@test "demotion is not this gesture's business: a group the DB removed types nothing" {
  # `newgrp` cannot take a group away, so firing here would cost a keystroke and repair nothing.
  # Subset, not equality -- an explicit arbitration, not an oversight.
  echo "1000 2000" > "$DB_GIDS"
  run_console
  [ "$status" -eq 0 ]

  [ -z "$(sendkeys_line)" ]
}

@test "no measurement, no keystroke: an unreadable /proc types nothing" {
  # FAIL-OPEN ON A FAILED MEASUREMENT. A `newgrp` sent on a guess lands in a shell that never
  # needed it; a console left stale costs the `newgrp` the refusal already names.
  rm -f "$PROC/4242/status"
  run_console
  [ "$status" -eq 0 ]

  [ -z "$(sendkeys_line)" ]
}

@test "no pid for the console ttyd: nothing is typed" {
  : > "$TTYD_PID"
  run_console
  [ "$status" -eq 0 ]

  [ -z "$(sendkeys_line)" ]
}

@test "the stamp bounds the repair to one keystroke per group change" {
  # `newgrp` starts a CHILD shell: the pane pid tmux reports stays the original, which will never
  # carry the group. Without a memory, the converger retypes every 30 s forever -- the cousin of
  # the 64 stacked ttyd this file's neighbour records.
  run_console
  [ "$status" -eq 0 ]
  [ "$(grep -c -- "^tmux send-keys -t " "$CALLS")" -eq 2 ]

  run_console
  [ "$status" -eq 0 ]
  [ "$(grep -c -- "^tmux send-keys -t " "$CALLS")" -eq 2 ]
}

@test "the stamp is NOT spent when no pane could be typed into" {
  # The common case here: the only pane is running an agent. Written in advance, the stamp would
  # consume the right to act on a console where nothing was typed -- and the repair would never
  # happen, which is exactly the defect being fixed.
  printf '%%0\tclaude\n' > "$PANES"
  run_console
  [ "$status" -eq 0 ]
  [ -z "$(sendkeys_line)" ]

  printf '%%0\tbash\n' > "$PANES"
  run_console
  [ "$status" -eq 0 ]
  [[ "$(sendkeys_line)" == *"newgrp lcars-spare"* ]]
}

@test "a new group after the first repair spends the stamp again" {
  run_console
  [ "$status" -eq 0 ]
  [ "$(grep -c -- "^tmux send-keys -t " "$CALLS")" -eq 2 ]

  echo "1000 2000 2001 2003 2004" > "$DB_GIDS"
  cat > "$BINDIR/getent" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "passwd bt")  echo "bt:x:1000:1000::/tmp/bt-home:/bin/bash" ;;
  "group 2003") echo "lcars-spare:x:2003:" ;;
  "group 2004") echo "lcars-extra:x:2004:" ;;
  # ⚠ KEEP IT: `sock_dir_for` fails HARD without this group, and the run dies before ever
  # reaching the drift branch -- the assertion would then blame the stamp for the stub.
  "group lcars-console") echo "lcars-console:x:2002:" ;;
  *) exit 2 ;;
esac
EOF
  chmod 0755 "$BINDIR/getent"

  run_console
  [ "$status" -eq 0 ]
  [ "$(grep -c -- "^tmux send-keys -t " "$CALLS")" -eq 4 ]
}

@test "the keystroke is issued AS the human, never as root" {
  run_console
  [ "$status" -eq 0 ]

  # The tmux socket belongs to the human (0700). Typing as root would either fail or, worse,
  # reach a server that is not theirs.
  grep -q -- "^runuser -u bt -- " "$CALLS"
}

@test "the caller's own TMUX is dropped before tmux is asked anything" {
  # `runuser` passes the environment through. An operator running this script BY HAND runs it from
  # a tmux -- theirs. With $TMUX still set, `tmux` targets the CALLER's socket and `send-keys`
  # types into somebody else's console. The socket mode (0700) refuses that today by accident;
  # relying on the accident means waiting for the day the two uids coincide.
  run_console
  [ "$status" -eq 0 ]

  [ "$(grep -c -- "^runuser .* env -u TMUX -u TMUX_PANE tmux " "$CALLS")" -ge 2 ]
  ! grep -qE -- "^runuser -u bt -- tmux " "$CALLS"
}
