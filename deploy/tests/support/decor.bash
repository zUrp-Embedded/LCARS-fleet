# SOURCE: deploy/tests/support/decor.bash
# AUTHOR: bob
# STARDATE: 2026-09-14
# STATUS: helper bats — le décor d'un témoin (une racine système sous le tmp du cas) et la forge HTTP locale
#
#   load ../support/decor
#   decor_pose                         LCARS_DECOR_ROOT, ses dossiers usuels, DECOR_BIN en tête du PATH
#   forge_double_start                 FORGE_DOUBLE_URL ; les routes s'ajoutent par forge_route
#   forge_route <MÉTHODE> <chemin> <code> [x<usages>] [corps]
#   forge_requests '<filtre jq>'       les requêtes reçues, filtrées ; forge_double_stop en teardown
#   espion_enfants <commande…>         chaque commande note « ARGV <nom> <argv> » et son environnement dans DECOR_ENFANTS
#
# La lib lit toute constante de chemin sous LCARS_DECOR_ROOT, et prov_owner y rend le compte qui
# joue le cas : un témoin pose des fichiers dans le décor, jamais une variable par fichier.

DECOR_SUPPORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

decor_pose() {
  export LCARS_DECOR_ROOT="$BATS_TEST_TMPDIR/decor"
  export DECOR_BIN="$BATS_TEST_TMPDIR/decor-bin"
  mkdir -p "$LCARS_DECOR_ROOT/opt/lcars/var/tokens" "$LCARS_DECOR_ROOT/etc/lcars" \
           "$LCARS_DECOR_ROOT/usr/local/bin" "$DECOR_BIN"
  export PATH="$DECOR_BIN:$PATH"
}

forge_double_start() {
  FORGE_DOUBLE_DIR="$BATS_TEST_TMPDIR/forge-double"
  mkdir -p "$FORGE_DOUBLE_DIR"
  : > "$FORGE_DOUBLE_DIR/routes"
  : > "$FORGE_DOUBLE_DIR/requests.jsonl"
  # fd 3 fermé : bats attend la fin de tout processus qui garde son descripteur
  python3 "$DECOR_SUPPORT_DIR/forge_double.py" "$FORGE_DOUBLE_DIR" 3>&- &
  FORGE_DOUBLE_PID=$!
  local _
  for _ in $(seq 1 50); do [[ -s "$FORGE_DOUBLE_DIR/port" ]] && break; sleep 0.1; done
  [[ -s "$FORGE_DOUBLE_DIR/port" ]] || { echo "forge_double : le serveur n'a pas écrit son port" >&2; return 1; }
  FORGE_DOUBLE_URL="http://127.0.0.1:$(cat "$FORGE_DOUBLE_DIR/port")"
  export FORGE_DOUBLE_URL
}

forge_route() { printf '%s\n' "$*" >> "$FORGE_DOUBLE_DIR/routes"; }

espion_enfants() {
  export DECOR_ENFANTS="$BATS_TEST_TMPDIR/enfants"
  : > "$DECOR_ENFANTS"
  local c vraie
  for c in "$@"; do
    vraie="$(PATH="${PATH//"$DECOR_BIN:"/}" command -v "$c")"
    printf '#!/usr/bin/env bash\n{ printf "ARGV %s %%s\\n" "$*"; env; } >> %q\nexec %q "$@"\n' "$c" "$DECOR_ENFANTS" "$vraie" > "$DECOR_BIN/$c"
    chmod +x "$DECOR_BIN/$c"
  done
}

forge_requests() { jq -c "${1:-.}" "$FORGE_DOUBLE_DIR/requests.jsonl"; }

forge_double_stop() {
  [[ -z "${FORGE_DOUBLE_PID:-}" ]] || { kill "$FORGE_DOUBLE_PID" 2>/dev/null || true; wait "$FORGE_DOUBLE_PID" 2>/dev/null || true; }
}
