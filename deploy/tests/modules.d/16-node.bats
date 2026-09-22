#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/16-node.bats
# AUTHOR: bob
# STARDATE: 2026-09-14
# STATUS: témoins de 16-node joué entier en livraison source — téléchargement vérifié, extraction, liens, rejeu

load ../refute
load ../support/decor

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)
  SRC="$BATS_TEST_DIRNAME/../../modules.d/16-node.sh"; [ -f "$SRC" ]
  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export PROVISION_MODULE=16-node PROV_SUBSTRATE=linux PROVISION_RUN=1
  VERSION="$(sed -n 's/^PROV_NODE_PIN=//p' "$BATS_TEST_DIRNAME/../../installer-constants.env")"
  PIN_X64="$(sed -n 's/^PROV_NODE_PIN_SHA256_X64=//p' "$BATS_TEST_DIRNAME/../../installer-constants.env")"
  [ -n "$VERSION" ]
  [ -n "$PIN_X64" ]

  decor_pose
  LINKS="$LCARS_DECOR_ROOT/usr/local/bin"
  NODE_HOME="$LCARS_DECOR_ROOT/opt/node-$VERSION"
  export CURL_LOG="$BATS_TEST_TMPDIR/curl.log" TARBALL="$BATS_TEST_TMPDIR/node.tar.xz"
  mkdir -p "$LCARS_DECOR_ROOT/opt"

  # le précompilé de décor : bin/node répond la version épinglée
  local d="$BATS_TEST_TMPDIR/tar/node-v$VERSION-linux-x64/bin"
  mkdir -p "$d"
  printf '#!/usr/bin/env bash\necho v%s\n' "$VERSION" > "$d/node"
  printf '#!/usr/bin/env bash\necho 11.0.0\n' > "$d/npm"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/npx"
  chmod 0755 "$d"/*
  tar -cJf "$TARBALL" -C "$BATS_TEST_TMPDIR/tar" "node-v$VERSION-linux-x64"

  printf '#!/usr/bin/env bash\necho amd64\n' > "$DECOR_BIN/dpkg"
  cat > "$DECOR_BIN/curl" <<'EOS'
#!/usr/bin/env bash
echo "${@: -1}" >> "$CURL_LOG"
out=""; prev=""; for a in "$@"; do [[ "$prev" == -o ]] && out="$a"; prev="$a"; done
cp "${STUB_TARBALL:-$TARBALL}" "$out"
EOS
  # la vérification reste réelle : seul le précompilé de décor reçoit le sha du pin, tout autre fichier garde le sien
  cat > "$DECOR_BIN/sha256sum" <<EOS
#!/usr/bin/env bash
vrai="\$(/usr/bin/sha256sum "\$1" | cut -c1-64)"
[[ "\$vrai" == "\$(/usr/bin/sha256sum "$TARBALL" | cut -c1-64)" ]] && vrai="$PIN_X64"
printf '%s  %s\n' "\$vrai" "\$1"
EOS
  chmod 0755 "$DECOR_BIN"/*
}

mod() { run bash "$SRC" "$1"; }

@test "apply : le précompilé épinglé est téléchargé, vérifié, détaré sous le décor et lié ; le check le voit" {
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$CURL_LOG")" = "https://nodejs.org/dist/v$VERSION/node-v$VERSION-linux-x64.tar.xz" ]
  [ -x "$NODE_HOME/bin/node" ]
  local b; for b in node npm npx; do
    [ "$(readlink "$LINKS/$b")" = "$NODE_HOME/bin/$b" ] || { echo "lien $b : $(readlink "$LINKS/$b")"; return 1; }
  done
  [ ! -e "$LCARS_DECOR_ROOT/opt/.node-$VERSION.tar.xz" ]
  [ ! -e "$NODE_HOME.partial" ]
  [[ "$output" == *"POSÉ  16-node: node $VERSION posé ($NODE_HOME)"* ]]
  mod check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"OK    16-node: node $VERSION posé"* ]]
}

@test "apply : rejoué, le pin posé n'est pas retéléchargé" {
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  : > "$CURL_LOG"
  mod apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"node $VERSION déjà posé"* ]]
  [ ! -s "$CURL_LOG" ]
}

@test "apply : une archive qui n'est pas celle du pin est refusée, rien n'est posé ni lié" {
  printf 'autre chose\n' > "$BATS_TEST_TMPDIR/autre"
  STUB_TARBALL="$BATS_TEST_TMPDIR/autre" mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"sha256 différent"* ]]
  [ ! -e "$NODE_HOME" ]
  [ ! -e "$LINKS/node" ]
}

@test "check : un node lié qui échoue est une dérive qui le dit posé, et l'absence se dit absence" {
  printf '#!/usr/bin/env bash\nexit 127\n' > "$LINKS/node"; chmod 0755 "$LINKS/node"
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 16-node: node posé ($LINKS/node) mais ne répond pas à --version"* ]]
  rm -f "$LINKS/node"
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 16-node: node absent ($LINKS/node)"* ]]
}
