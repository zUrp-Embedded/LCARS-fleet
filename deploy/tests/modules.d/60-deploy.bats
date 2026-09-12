#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/60-deploy.bats
# AUTHOR: bob
# STARDATE: 2026-09-12
# STATUS: témoins de 60-deploy — le raccourci « rien à bâtir », la pose par deploy-release.sh, le verrou, les intrus, le canal

load ../refute

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)
  MOD="$BATS_TEST_DIRNAME/../../modules.d/60-deploy.sh"; [ -f "$MOD" ]
  MANIFEST="$BATS_TEST_DIRNAME/../../../runtime/etc/release.manifest"; [ -f "$MANIFEST" ]
  RACINE="$BATS_TEST_TMPDIR/racine"
  mkdir -p "$RACINE/deploy/lib" "$RACINE/runtime/etc"
  cp "$BATS_TEST_DIRNAME"/../../lib/*.sh "$RACINE/deploy/lib/"
  cp "$MANIFEST" "$RACINE/runtime/etc/release.manifest"
  printf 'defmodule X do end\n' > "$RACINE/runtime/mix.exs"
  export MARQUEUR="$BATS_TEST_TMPDIR/pose-appelee"
  printf '#!/usr/bin/env bash\necho "POSE $LCARS_INSTALL_PREFIX $LCARS_RUNTIME_DIR gate=$LCARS_INSTALL_SKIP_GATE" >> "%s"\nexit "${STUB_POSE_RC:-0}"\n' "$MARQUEUR" > "$RACINE/deploy/lib/deploy-release.sh"
  chmod 0755 "$RACINE/deploy/lib/deploy-release.sh"
  git -C "$RACINE" init -q; git -C "$RACINE" add -A; git -C "$RACINE" -c user.email=t@t -c user.name=t commit -qm décor
  HEAD_SHA="$(git -C "$RACINE" rev-parse --short HEAD)"
  export PROVISION_LIB="$RACINE/deploy/lib/provision-lib.sh"
  export PROVISION_MODULE=60-deploy PROV_SUBSTRATE=linux PROV_HUMAN=root PROV_FLEET_GROUP=root
  export PROV_PREFIX="$BATS_TEST_TMPDIR/prefix"
  export PROV_LINK_DIR="$BATS_TEST_TMPDIR/path"
  export LCARS_CHANNEL_FILE="$BATS_TEST_TMPDIR/etc/channel"; mkdir -p "$BATS_TEST_TMPDIR/etc"
  export LCARS_CHANNEL_OWNER=root:root
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"; mkdir -p "$XDG_RUNTIME_DIR"; chmod 0700 "$XDG_RUNTIME_DIR"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"; export PATH="$BIN:$PATH"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/mix"; chmod 0755 "$BIN/mix"
  mkdir -p "$PROV_PREFIX/bin" "$PROV_LINK_DIR"
}

release_posee() { # release_posee [sha du build] — la release et tout ce que le manifeste nomme
  local rel="$PROV_PREFIX/rel/lcars_fleet" n
  mkdir -p "$rel/bin" "$rel/lib/lcars_fleet-0.9.0/priv/api" "$rel/releases"
  printf '#!/bin/sh\nexit 0\n' > "$rel/bin/lcars_fleet"; chmod 0755 "$rel/bin/lcars_fleet"
  printf 'sha=%s\n' "${1:-$HEAD_SHA}" > "$rel/lib/lcars_fleet-0.9.0/priv/api/build_info.txt"
  printf '15.2.7.4 0.9.0\n' > "$rel/releases/start_erl.data"
  while read -r n _; do
    [[ -n "$n" && "$n" != \#* ]] || continue
    printf '#!/bin/sh\n' > "$PROV_PREFIX/bin/$n"; chmod 0755 "$PROV_PREFIX/bin/$n"
  done < "$MANIFEST"
}
verrouille() { chmod 0750 "$PROV_PREFIX"; }
mod() {
  unshare -Ur true 2>/dev/null || skip "user namespaces indisponibles : le module ne se joue pas ici"
  run unshare -Ur bash "$MOD" "$@"
}
fn() { run bash -c "set -uo pipefail; source <(sed '/^case \"\${1:?usage/,\$d' '$MOD') >/dev/null 2>&1; $1"; }

@test "check : release absente — drift, rien d'autre n'est sondé" {
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 60-deploy: release absente sous $PROV_PREFIX"* ]]
  [[ "$output" != *"verrou"* ]]
}

@test "check : un prefix non traversable ne rend pas « release absente » — rien n'est conclu, et le pourquoi est dit" {
  [ "$(id -u)" -ne 0 ] || skip "root traverse tout : le non-traversable ne se joue pas ici"
  release_posee; chmod 0000 "$PROV_PREFIX"
  fn check
  chmod 0750 "$PROV_PREFIX"
  [[ "$output" == *"WARN  60-deploy: release non mesurable — $PROV_PREFIX"* ]]
  [[ "$output" != *"release absente"* ]]
}

@test "check : release posée, prefix non verrouillé — drift qui dit le mode attendu" {
  release_posee; chmod 0755 "$PROV_PREFIX"
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"release posée ($PROV_PREFIX, build $HEAD_SHA)"* ]]
  [[ "$output" == *"DRIFT 60-deploy: prefix non verrouillé : root:root 755 ≠ root:root 750"* ]]
}

@test "check : release posée et verrouillée, symlinks du PATH absents — un drift par lien du manifeste" {
  release_posee; verrouille
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"verrou RO du prefix (root:root 750)"* ]]
  [[ "$output" == *"DRIFT 60-deploy: $PROV_LINK_DIR/fleet ≠ symlink vers $PROV_PREFIX/bin/fleet"* ]]
}

@test "intrus : une entrée de bin/ hors manifeste et le symlink du PATH qui la vise sont des drifts ; un lien qui vise ailleurs n'est pas à nous" {
  release_posee; verrouille
  : > "$PROV_PREFIX/bin/fleet_v2"
  ln -s "$PROV_PREFIX/bin/fleet_v2" "$PROV_LINK_DIR/fleet_v2"
  ln -s /bin/true "$PROV_LINK_DIR/quelconque"
  mod check
  [[ "$output" == *"DRIFT 60-deploy: intrus $PROV_PREFIX/bin/fleet_v2 — absent de release.manifest"* ]]
  [[ "$output" == *"DRIFT 60-deploy: symlink intrus $PROV_LINK_DIR/fleet_v2 → $PROV_PREFIX/bin/fleet_v2"* ]]
  [[ "$output" != *"quelconque"* ]]
}

@test "intrus : l'apply les retire des deux côtés, une ligne par retrait, et ne touche à rien d'autre" {
  release_posee
  : > "$PROV_PREFIX/bin/fleet_v2"
  ln -s "$PROV_PREFIX/bin/fleet_v2" "$PROV_LINK_DIR/fleet_v2"
  ln -s "$PROV_PREFIX/bin/fleet" "$PROV_LINK_DIR/fleet"
  ln -s /bin/true "$PROV_LINK_DIR/quelconque"
  fn 'prune_intrus; echo "rc=$?"'
  [[ "$output" == *"retiré $PROV_PREFIX/bin/fleet_v2"*"retiré symlink $PROV_LINK_DIR/fleet_v2"*"rc=0"* ]]
  [ ! -e "$PROV_PREFIX/bin/fleet_v2" ]
  [ ! -L "$PROV_LINK_DIR/fleet_v2" ]
  [ -e "$PROV_PREFIX/bin/fleet" ]
  [ -L "$PROV_LINK_DIR/fleet" ]
  [ -L "$PROV_LINK_DIR/quelconque" ]
}

@test "release à deux libs : le build annoncé est celui qui démarre, la lib morte est un drift nommé" {
  release_posee d4d23d792; verrouille
  local rel="$PROV_PREFIX/rel/lcars_fleet"
  mkdir -p "$rel/lib/lcars_fleet-0.1.0/priv/api"
  printf 'sha=9ee4a4bcd\n' > "$rel/lib/lcars_fleet-0.1.0/priv/api/build_info.txt"
  mod check
  [[ "$output" == *"release posée ($PROV_PREFIX, build d4d23d792)"* ]]
  [[ "$output" == *"DRIFT 60-deploy: la release posée porte 2 lib/lcars_fleet-*"*"celle qui démarre est lcars_fleet-0.9.0"* ]]
}

@test "apply : build déployé égal à HEAD et runtime propre — rien à bâtir, deploy-release.sh n'est pas appelé, les symlinks sont posés, le canal dit source" {
  release_posee; verrouille
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"OK    60-deploy: build déployé $HEAD_SHA == HEAD source (runtime/ propre) — rien à bâtir"* ]]
  [ ! -e "$MARQUEUR" ]
  [ "$(readlink "$PROV_LINK_DIR/fleet")" = "$PROV_PREFIX/bin/fleet" ]
  [ "$(cat "$LCARS_CHANNEL_FILE")" = source ]
}

@test "apply : runtime modifié — deploy-release.sh est joué sous l'humain sans le gate, le prefix est reverrouillé root:fleet 750, le canal s'écrit après" {
  release_posee; verrouille
  printf '# modif\n' >> "$RACINE/runtime/mix.exs"
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q "^POSE $PROV_PREFIX $RACINE/runtime gate=1$" "$MARQUEUR"
  [ "$(stat -c '%U:%G %a' "$PROV_PREFIX")" = "$(id -un):$(id -gn) 750" ]
  [ "$(cat "$LCARS_CHANNEL_FILE")" = source ]
  [[ "$output" == *"POSÉ  60-deploy: runtime déployé : $PROV_PREFIX (build $HEAD_SHA) + /usr/local/bin câblé"* ]]
}

@test "check : la génération précédente gardée par deploy-release.sh est nommée avec sa taille et le geste qui la libère" {
  release_posee; verrouille
  mkdir -p "$PROV_PREFIX/rel/lcars_fleet.prev/bin"
  head -c 4096 /dev/zero > "$PROV_PREFIX/rel/lcars_fleet.prev/bin/lcars_fleet"
  mod check
  [[ "$output" == *"génération précédente gardée : $PROV_PREFIX/rel/lcars_fleet.prev ("*"sudo rm -rf $PROV_PREFIX/rel/lcars_fleet.prev"* ]]
}

@test "apply : le code 3 de deploy-release.sh est toléré, la pose continue" {
  release_posee; verrouille
  printf '# modif\n' >> "$RACINE/runtime/mix.exs"
  STUB_POSE_RC=3 mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -s "$MARQUEUR" ]
  [[ "$output" == *"POSÉ  60-deploy: runtime déployé"* ]]
}

@test "apply : deploy-release.sh en échec — échec nommé, le canal n'est pas écrit" {
  release_posee; verrouille
  printf '# modif\n' >> "$RACINE/runtime/mix.exs"
  STUB_POSE_RC=1 mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  60-deploy: deploy-release.sh en échec (rc=1"* ]]
  [ ! -e "$LCARS_CHANNEL_FILE" ]
}

@test "apply : livraison binaire — mix n'est pas requis, la release du kit est posée, le canal dit kit" {
  release_posee 0000000; verrouille
  rm -f "$BIN/mix"
  printf 'cafe1234\n' > "$RACINE/.source-revision"
  PATH="$BIN:/usr/bin:/bin" mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"outillage mix non posé — livraison binaire"* ]]
  [ -s "$MARQUEUR" ]
  [ "$(cat "$LCARS_CHANNEL_FILE")" = kit ]
}

@test "apply : sans mix en livraison source — échec qui nomme 15-toolchain, rien n'est joué" {
  release_posee 0000000; verrouille
  rm -f "$BIN/mix"
  PATH="$BIN:/usr/bin:/bin" mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  60-deploy: mix absent — 15-toolchain le pose"* ]]
  [ ! -e "$MARQUEUR" ]
}

@test "apply : rejeu depuis la copie posée, sans source — la release en place est l'état-cible, le canal est écrit" {
  release_posee; verrouille
  rm -f "$RACINE/runtime/mix.exs"
  PROV_ROOT="$RACINE" mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"rejeu depuis la copie posée : release en place, aucune source ici"* ]]
  [ ! -e "$MARQUEUR" ]
  [ "$(cat "$LCARS_CHANNEL_FILE")" = source ]
}
