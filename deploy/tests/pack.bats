#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/pack.bats
# AUTHOR: bob
# STARDATE: 2026-09-12
# STATUS: témoins de deploy/pack.sh — le refus d'un arbre modifié, le kit et son nom, la porte de la version, le tiroir, ce que la publication dit du jeton

load refute

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)
  SRC="$BATS_TEST_DIRNAME/../pack.sh"; [ -f "$SRC" ]
  RACINE_REELLE="$BATS_TEST_DIRNAME/../.."
  R="$BATS_TEST_TMPDIR/depot"
  mkdir -p "$R/deploy/lib" "$R/deploy/modules.d" "$R/deploy/docker" "$R/runtime/etc" "$R/runtime/bin" "$R/runtime/services" \
           "$R/assets/avatars" "$R/assets/favicon" "$R/assets/github.io"
  cp "$SRC" "$R/deploy/pack.sh"
  cp "$RACINE_REELLE"/deploy/lib/*.sh "$R/deploy/lib/"
  cp "$RACINE_REELLE/deploy/system.manifest" "$R/deploy/system.manifest"
  cp "$RACINE_REELLE/deploy/modules.d/62-runtime-helpers.sh" "$R/deploy/modules.d/"
  cp "$RACINE_REELLE/install.sh" "$R/install.sh"
  cp "$RACINE_REELLE/runtime/etc/release.manifest" "$RACINE_REELLE/runtime/etc/fleet.env.template" "$R/runtime/etc/"
  local n
  while read -r n _; do [[ -n "$n" && "$n" != \#* ]] || continue; cp "$RACINE_REELLE/runtime/bin/$n" "$R/runtime/bin/"; done < "$R/runtime/etc/release.manifest"
  cp "$RACINE_REELLE"/runtime/bin/lcars-toolchain-converge "$RACINE_REELLE"/runtime/bin/lcars-authority-ask "$R/runtime/bin/"
  for n in $(sed -n '/^HELPERS=(/,/^)/p' "$R/deploy/modules.d/62-runtime-helpers.sh" | sed '1d;$d' | tr -d ' ') console.tmux.conf lcars.bashrc; do
    cp "$RACINE_REELLE/runtime/services/$n" "$R/runtime/services/"
  done
  printf 'png' > "$R/assets/avatars/a.png"; printf 'ico' > "$R/assets/favicon/f.ico"
  printf '{"name":"doc"}\n' > "$R/assets/github.io/package.json"
  printf 'services: {}\n' > "$R/deploy/docker/docker-compose.yml"; printf '{}\n' > "$R/deploy/docker/lcars-hardened-seccomp.json"
  printf 'dist\n_build\n' > "$R/.gitignore"
  export GATE_LOG="$BATS_TEST_TMPDIR/gate.log"
  printf '#!/usr/bin/env bash\necho gate >> "$GATE_LOG"\nexit "${STUB_GATE_RC:-0}"\n' > "$R/deploy/gate.sh"; chmod 0755 "$R/deploy/gate.sh"
  git -C "$R" init -q; git -C "$R" add -A; git -C "$R" -c user.email=t@t -c user.name=t commit -qm décor
  HEAD_SHA="$(git -C "$R" rev-parse --short HEAD)"; HEAD8="$(git -C "$R" rev-parse --short=8 HEAD)"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"; export PATH="$BIN:$PATH"
  export CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  printf '#!/usr/bin/env bash\nprintf 27\n' > "$BIN/erl"
  cat > "$BIN/mix" <<'EOF'
#!/usr/bin/env bash
echo "mix $*" >> "$CALLS"
if [[ "$1" == release ]]; then
  rel=_build/prod/rel/lcars_fleet
  mkdir -p "$rel/bin" "$rel/lib/lcars_fleet-0.9.0/priv/api"
  printf '#!/bin/sh\nexit 0\n' > "$rel/bin/lcars_fleet"; chmod 0755 "$rel/bin/lcars_fleet"
  printf 'sha=%s\n' "${STUB_MIX_SHA:-$(git rev-parse --short HEAD)}" > "$rel/lib/lcars_fleet-0.9.0/priv/api/build_info.txt"
  [[ -z "${STUB_MIX_TWO_LIBS:-}" ]] || mkdir -p "$rel/lib/lcars_fleet-0.1.0/priv/api"
fi
exit 0
EOF
  cat > "$BIN/npm" <<'EOF'
#!/usr/bin/env bash
echo "npm $*" >> "$CALLS"
[[ "$1 $2" == "run build" ]] && { mkdir -p dist; printf '<html>doc</html>' > dist/index.html; }
exit 0
EOF
  printf '#!/usr/bin/env bash\necho "CURL $*" >> "$CALLS"; cat >/dev/null; printf 000\n' > "$BIN/curl"
  chmod 0755 "$BIN"/*
  export LCARS_PACK_DIR="$BATS_TEST_TMPDIR/packs"
  export LCARS_PACK_TOKEN_FILE="$BATS_TEST_TMPDIR/aucun-jeton"
  ARCH="$(uname -m)"
}

pack() { run bash "$R/deploy/pack.sh" "$@"; }

@test "un arbre modifié est refusé avant tout — ni gate, ni release" {
  printf 'x\n' >> "$R/install.sh"
  pack --no-image
  [ "$status" -eq 1 ]
  [[ "$output" == *"pack: ERREUR — arbre modifié"* ]]
  [ ! -s "$GATE_LOG" ]
  [ ! -s "$CALLS" ]
}

@test "une option inconnue est refusée en se nommant" {
  pack --no-push
  [ "$status" -eq 1 ]
  [[ "$output" == *"option inconnue: --no-push"* ]]
}

@test "le kit porte le tag dans son nom, la révision à sa racine, la release et la doc bâties, et le tiroir de la version porte la porte qui le retrouve" {
  LCARS_PACK_TAG=v9.9 pack --no-image
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local tar="$LCARS_PACK_DIR/lcars-fleet-v9.9-otp27-$ARCH.tar.gz"
  [ -s "$tar" ]
  [ "$(cut -d' ' -f1 < "$tar.sha256")" = "$(sha256sum "$tar" | cut -d' ' -f1)" ]
  local x="$BATS_TEST_TMPDIR/x"; mkdir -p "$x"; tar -xzf "$tar" -C "$x"
  [ "$(cat "$x/lcars_install/.source-revision")" = "$HEAD8" ]
  [ -x "$x/lcars_install/runtime/_build/prod/rel/lcars_fleet/bin/lcars_fleet" ]
  [ -s "$x/lcars_install/assets/github.io/dist/index.html" ]
  [ -f "$x/lcars_install/deploy/pack.sh" ]
  [ ! -e "$x/lcars_install/runtime/_build/prod/rel/lcars_fleet/lib/lcars_fleet-0.1.0" ]
  local dist="$LCARS_PACK_DIR/dist/v9.9"
  [ "$(stat -c %i "$dist/lcars-fleet-v9.9-otp27-$ARCH.tar.gz")" = "$(stat -c %i "$tar")" ]
  [ -f "$dist/docker-compose.yml" ]
  [ -f "$dist/lcars-hardened-seccomp.json" ]
  [ "$(bash "$dist/install.sh" --version)" = v9.9 ]
  [ "$(cut -d' ' -f1 < "$dist/install.sh.sha256")" = "$(sha256sum "$dist/install.sh" | cut -d' ' -f1)" ]
  grep -q "  lcars-fleet-v9.9-otp27-$ARCH.tar.gz\$" "$dist/install.sh"
  grep -q "^DOOR_BASE=\"https://forge.invalid/lcars/lcars-fleet/releases/download/v9.9\"" "$dist/install.sh"
  grep -q '^mix deps.get$' "$CALLS"
  grep -q '^mix release --overwrite$' "$CALLS"
  [[ "$output" == *"pack: --no-image : pas d'image"*"pack: sans --publish : le tar et l'installeur restent dans $dist"* ]]
}

@test "sans tag, la version est <MM-DD_HH-MM>-<sha> et le kit se nomme d'elle" {
  pack --no-image
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local tars; tars="$(find "$LCARS_PACK_DIR" -maxdepth 1 -name "lcars-fleet-*-$HEAD_SHA-otp27-$ARCH.tar.gz")"
  [ -n "$tars" ]
  [[ "$(basename "$tars")" =~ ^lcars-fleet-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-$HEAD_SHA-otp27-$ARCH\.tar\.gz$ ]]
  [ -d "$LCARS_PACK_DIR/dist/$(basename "$tars" | sed "s/^lcars-fleet-//; s/-otp27-$ARCH.tar.gz$//")" ]
}

@test "le tiroir : à côté du checkout par défaut, LCARS_PACK_DIR sinon, normalisé et absolu" {
  unset LCARS_PACK_DIR
  LCARS_PACK_TAG=v1 pack --no-image
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -s "$BATS_TEST_TMPDIR/lcars-packs/lcars-fleet-v1-otp27-$ARCH.tar.gz" ]
  LCARS_PACK_DIR="$BATS_TEST_TMPDIR/depot/../ailleurs/./tiroir" LCARS_PACK_TAG=v2 pack --no-image
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -s "$BATS_TEST_TMPDIR/ailleurs/tiroir/lcars-fleet-v2-otp27-$ARCH.tar.gz" ]
  [[ "$output" == *"pack: paquet : $BATS_TEST_TMPDIR/ailleurs/tiroir/lcars-fleet-v2-otp27-$ARCH.tar.gz"* ]]
}

@test "gate de l'installeur rouge : rien n'est empaqueté, la release n'est pas bâtie" {
  STUB_GATE_RC=1 pack --no-image
  [ "$status" -eq 1 ]
  [[ "$output" == *"pack: ERREUR — gate de l'installeur rouge — rien n'est empaqueté"* ]]
  refute grep -q '^mix release' "$CALLS"
  [ ! -e "$LCARS_PACK_DIR" ]
}

@test "une release dont le tampon n'est pas HEAD, ou qui porte deux libs, n'est pas empaquetée" {
  STUB_MIX_SHA=deadbee pack --no-image
  [ "$status" -eq 1 ]
  [[ "$output" == *"le tampon de la release dit « deadbee », HEAD est $HEAD_SHA"* ]]
  [ ! -e "$LCARS_PACK_DIR" ]
  STUB_MIX_TWO_LIBS=1 pack --no-image
  [ "$status" -eq 1 ]
  [[ "$output" == *"la release porte 2 lib/lcars_fleet-*"*"une assemblée n'en a qu'une"* ]]
}

@test "--publish : sans jeton, refus qui nomme les deux sources ; avec un jeton, son état est dit et jamais sa valeur" {
  LCARS_PACK_TAG=v9.9 LCARS_PACK_FORGE=http://forge.decor LCARS_PACK_OWNER=fleet pack --no-image --publish
  [ "$status" -eq 1 ]
  [[ "$output" == *"jeton : absent"*"pack: ERREUR — --publish : aucun jeton — LCARS_PACK_TOKEN dans l'environnement, ou LCARS_PACK_TOKEN_FILE"* ]]
  local sentinelle="s3cr3t-de-forge-a-ne-jamais-imprimer"
  : > "$CALLS"
  LCARS_PACK_TAG=v9.9 LCARS_PACK_FORGE=http://forge.decor LCARS_PACK_OWNER=fleet LCARS_PACK_TOKEN="$sentinelle" pack --no-image --publish
  [ "$status" -eq 1 ]
  [[ "$output" == *"jeton : trouvé"*"publication → http://forge.decor/fleet/lcars-fleet, release v9.9"* ]]
  [[ "$output" != *"$sentinelle"* ]]
  refute grep -q "$sentinelle" "$CALLS"
}

@test "--publish : origin non http et rien de posé — refus qui nomme les variables" {
  LCARS_PACK_TAG=v9.9 pack --no-image --publish
  [ "$status" -eq 1 ]
  [[ "$output" == *"--publish : forge ou owner indéterminables"*"LCARS_PACK_FORGE et LCARS_PACK_OWNER"* ]]
}

@test "aucun secret ni chemin de machine n'est écrit dans le lanceur" {
  local code; code="$(grep -vE '^\s*#' "$SRC")"
  refute grep -qE '[0-9a-f]{40}' <<<"$code"
  refute grep -qE '/home/commons|/local/LCARS|/opt/lcars|/usr/share/lcars' <<<"$code"
}
