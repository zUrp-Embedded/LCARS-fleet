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

@test "la BASELINE des pods (venv, pip, compilateur) est demandee sur TOUTE livraison — source comme binaire" {
  # Elle vivait dans BUILD_PACKAGES, « source seulement », et l'image la posait a la main pour ses
  # pods : deux rails, deux verites — un poste installe par kit n'avait pas de venv pour ses pods.
  # Depuis le 2026-09-11 (le jumeau Dockerfile est parti), une seule liste, sur chaque terrain.
  mod 'effective_packages'
  [[ "$output" == *"build-essential"* ]] && [[ "$output" == *"python3-venv"* ]] && [[ "$output" == *"tmux"* ]]
  printf 'abcd1234\n' > "$ROOT/.source-revision"
  mod 'effective_packages'
  [[ "$output" == *"build-essential"* ]] && [[ "$output" == *"python3-venv"* ]] && [[ "$output" == *"tmux"* ]]
  grep -vE '^\s*#' "$SRC" | refute_out 'BUILD_PACKAGES'
}

@test "canal kit/source : apply passe par apt (apt_ensure)" {
  printf 'kit\n' > "$LCARS_CHANNEL_FILE"
  run bash -c "set -uo pipefail; export PATH=\"$BIN:$PATH\"; bash '$SRC' apply"
  [ -e "$BATS_TEST_TMPDIR/apt.trace" ]
  grep -q 'APT .*install' "$BATS_TEST_TMPDIR/apt.trace"
}
