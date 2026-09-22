#!/usr/bin/env bats
# SOURCE: runtime/test/services/console_locale.bats
# AUTHOR: bob
# STARDATE: 2026-09-16
# STATUS: témoin de runtime/services/console.sh — la console porte sa locale, quel que soit l'environnement qui la lance

load ../support/refute

setup() {
  SRC="$BATS_TEST_DIRNAME/../../services/console.sh"
  BINDIR="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BINDIR"
  CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  ROOT="$(mktemp -d /tmp/lcl.XXXXXX)"
  cat > "$BINDIR/getent" <<'SH'
case "$1 $2" in
  "passwd bt")           echo "bt:x:1000:1000::/tmp/lcl-home:/bin/bash" ;;
  "group lcars-console") echo "lcars-console:x:2002:" ;;
  *) exit 2 ;;
esac
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BINDIR/id"
  cat > "$BINDIR/install" <<'SH'
d=""; for a in "$@"; do d="$a"; done
mkdir -p "$d"
SH
  for c in chmod chown ttyd; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BINDIR/$c"; done
  # setpriv journalise la commande qu'il exécuterait sous l'humain : c'est elle qui porte (ou non) la locale
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s"\n' "$CALLS" > "$BINDIR/setpriv"
  chmod 0755 "$BINDIR"/*
  mkdir -p /tmp/lcl-home
  export PATH="$BINDIR:$PATH" LCARS_CONSOLE_SOCK_ROOT="$ROOT/console"
}

teardown() { rm -rf "$ROOT" /tmp/lcl-home; }

@test "lancée sans aucune locale (la passe env -i de l'installeur), la console pose LANG=C.UTF-8 à ttyd et à son tmux" {
  # banc LCARS-beta : les consoles nées de cette passe rendaient chaque accent en « _ » dans le rattachement d'un pod
  run env -i PATH="$PATH" HOME=/root LCARS_CONSOLE_SOCK_ROOT="$ROOT/console" bash "$SRC" --human bt --foreground
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx 'LANG=C.UTF-8' "$CALLS" || { cat "$CALLS"; return 1; }
  grep -qx 'ttyd' "$CALLS"
  # la locale précède ttyd dans la commande `env` : ttyd, et ce qu'il lance, en héritent
  [ "$(grep -nx 'LANG=C.UTF-8' "$CALLS" | cut -d: -f1)" -lt "$(grep -nx 'ttyd' "$CALLS" | cut -d: -f1)" ]
}
