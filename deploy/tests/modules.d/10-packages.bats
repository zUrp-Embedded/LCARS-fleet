#!/usr/bin/env bats
# SOURCE: deploy/tests/modules.d/10-packages.bats
# AUTHOR: bob
# STARDATE: 2026-09-05
# STATUS: le socle de 10-packages — une liste (= le Depends du paquet lcars), la compilation en source
#         seulement, et JAMAIS apt sous canal deb (mesure 2004, 2026-09-05 : rc 100 sous le verrou)

load ../refute

setup() {
  SRC="$BATS_TEST_DIRNAME/../../modules.d/10-packages.sh"; [ -f "$SRC" ]
  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export PROVISION_MODULE=10-packages PROV_HUMAN=temoin PROV_SUBSTRATE=wsl
  export LCARS_CHANNEL_FILE="$BATS_TEST_TMPDIR/etc/lcars/channel"; mkdir -p "$(dirname "$LCARS_CHANNEL_FILE")"
  export PROV_TOKENS_DIR="$BATS_TEST_TMPDIR/private"
  MOD="$BATS_TEST_TMPDIR/mod.sh"; sed '/^case "${1:?usage/,$d' "$SRC" > "$MOD"
  # une racine de depot pour prov_delivery : source (pas de tampon) ou binaire (tampon a la racine)
  ROOT="$BATS_TEST_TMPDIR/repo"; mkdir -p "$ROOT/deploy"; cp -r "$BATS_TEST_DIRNAME/../../lib" "$ROOT/deploy/"   # la lib source ses voisines (docker-endpoint.sh)
  export PROVISION_LIB="$ROOT/deploy/lib/provision-lib.sh"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  printf '#!/usr/bin/env bash\necho "APT $*" >> "%s"\nexit 0\n' "$BATS_TEST_TMPDIR/apt.trace" > "$BIN/apt-get"
  printf '#!/usr/bin/env bash\n[[ "$*" == *-s* ]] && exit 1\nexit 0\n' > "$BIN/dpkg"   # rien n'est installe
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/bwrap"
  chmod 0755 "$BIN"/*
}
mod() { run bash -c "set -uo pipefail; export PATH=\"$BIN:$PATH\"; source '$MOD' >/dev/null 2>&1; $1"; }

@test "livraison SOURCE : le socle de compilation est demande" {
  mod 'effective_packages'
  [[ "$output" == *"build-essential"* ]]
  [[ "$output" == *"tmux"* ]]
}

@test "livraison BINAIRE (tampon a la racine) : le socle de compilation n'est PAS demande — un kit ou un paquet arrivent compiles" {
  printf 'abcd1234\n' > "$ROOT/.source-revision"
  mod 'effective_packages'
  refute_out 'build-essential|pkg-config|python3-dev' <<<"$output"
  [[ "$output" == *"tmux"* ]]
}

@test "canal kit/source : apply passe par apt (apt_ensure)" {
  printf 'kit\n' > "$LCARS_CHANNEL_FILE"
  run bash -c "set -uo pipefail; export PATH=\"$BIN:$PATH\"; bash '$SRC' apply"
  [ -e "$BATS_TEST_TMPDIR/apt.trace" ]
  grep -q 'APT .*install' "$BATS_TEST_TMPDIR/apt.trace"
}
