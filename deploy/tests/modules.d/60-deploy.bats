#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/60-deploy.bats
# AUTHOR: bob
# STARDATE: 2026-09-12
# STATUS: témoins de 60-deploy — le raccourci « rien à bâtir », la pose par deploy-release.sh, le verrou, les intrus, le canal

load ../refute
load ../support/decor

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)
  MOD="$BATS_TEST_DIRNAME/../../modules.d/60-deploy.sh"; [ -f "$MOD" ]
  MANIFEST="$BATS_TEST_DIRNAME/../../../runtime/etc/release.manifest"; [ -f "$MANIFEST" ]
  export PROVISION_MODULE=60-deploy PROV_SUBSTRATE=linux PROV_HUMAN=root
  decor_pose
  PREFIX="$LCARS_DECOR_ROOT/opt/lcars/runtime"
  LINKS="$LCARS_DECOR_ROOT/usr/local/bin"
  CHANNEL="$LCARS_DECOR_ROOT/etc/lcars/channel"
  export MARQUEUR="$BATS_TEST_TMPDIR/pose-appelee"
  racine_pose "$BATS_TEST_TMPDIR/racine"
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"; mkdir -p "$XDG_RUNTIME_DIR"; chmod 0700 "$XDG_RUNTIME_DIR"
  BIN="$DECOR_BIN"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/mix"; chmod 0755 "$BIN/mix"
  mkdir -p "$PREFIX/bin"
}

# racine_pose <dossier> — un arbre de source : la lib et ses constantes, le runtime, et un deploy-release.sh
# qui note son environnement LCARS_*
racine_pose() {
  RACINE="$1"
  mkdir -p "$RACINE/deploy/lib" "$RACINE/runtime/etc"
  cp "$BATS_TEST_DIRNAME"/../../lib/*.sh "$RACINE/deploy/lib/"
  cp "$BATS_TEST_DIRNAME/../../installer-constants.env" "$BATS_TEST_DIRNAME/../../system.manifest" "$RACINE/deploy/"
  cp "$MANIFEST" "$RACINE/runtime/etc/release.manifest"
  printf 'defmodule X do end\n' > "$RACINE/runtime/mix.exs"
  printf '#!/usr/bin/env bash\n{ echo POSE; env | grep "^LCARS_" | grep -v "^LCARS_DECOR_ROOT=" | sort; } >> "%s"\nexit "${STUB_POSE_RC:-0}"\n' "$MARQUEUR" > "$RACINE/deploy/lib/deploy-release.sh"
  chmod 0755 "$RACINE/deploy/lib/deploy-release.sh"
  git -C "$RACINE" init -q; git -C "$RACINE" add -A; git -C "$RACINE" -c user.email=t@t -c user.name=t commit -qm décor
  HEAD_SHA="$(git -C "$RACINE" rev-parse --short HEAD)"
  export PROVISION_LIB="$RACINE/deploy/lib/provision-lib.sh"
}

release_posee() { # release_posee [sha du build] — la release et tout ce que le manifeste nomme
  local rel="$PREFIX/rel/lcars_fleet" n
  mkdir -p "$rel/bin" "$rel/lib/lcars_fleet-0.9.0/priv/api" "$rel/releases" "$PREFIX/bin"
  printf '#!/bin/sh\nexit 0\n' > "$rel/bin/lcars_fleet"; chmod 0755 "$rel/bin/lcars_fleet"
  printf 'sha=%s\n' "${1:-$HEAD_SHA}" > "$rel/lib/lcars_fleet-0.9.0/priv/api/build_info.txt"
  printf '15.2.7.4 0.9.0\n' > "$rel/releases/start_erl.data"
  while read -r n _; do
    [[ -n "$n" && "$n" != \#* ]] || continue
    printf '#!/bin/sh\n' > "$PREFIX/bin/$n"; chmod 0755 "$PREFIX/bin/$n"
  done < "$MANIFEST"
}
verrouille() { chmod 0750 "$PREFIX"; }
mod() { run unshare -Ur bash "$MOD" "$@"; }
fn() { run bash -c "set -uo pipefail; source <(sed '/^case \"\${1:?usage/,\$d' '$MOD') >/dev/null 2>&1; $1"; }

@test "check : release absente — drift, rien d'autre n'est sondé" {
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 60-deploy: release absente sous $PREFIX"* ]]
  [[ "$output" != *"verrou"* ]]
}

@test "check : un prefix non traversable ne rend pas « release absente » — rien n'est conclu, et le pourquoi est dit" {
  # joué hors de l'espace de noms, par un compte qui ne traverse pas un 0000
  [ "$(id -u)" -ne 0 ]
  release_posee; chmod 0000 "$PREFIX"
  fn check
  chmod 0750 "$PREFIX"
  [[ "$output" == *"WARN  60-deploy: release non mesurable — $PREFIX"* ]]
  [[ "$output" != *"release absente"* ]]
}

@test "check : release posée, prefix non verrouillé — drift qui dit le mode attendu" {
  release_posee; chmod 0755 "$PREFIX"
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"release posée ($PREFIX, build $HEAD_SHA)"* ]]
  [[ "$output" == *"DRIFT 60-deploy: prefix non verrouillé : root:root 755 ≠ root:root 750"* ]]
}

@test "check : release posée et verrouillée, symlinks du PATH absents — un drift par lien du manifeste" {
  release_posee; verrouille
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"verrou RO du prefix (root:root 750)"* ]]
  [[ "$output" == *"DRIFT 60-deploy: $LINKS/fleet ≠ symlink vers $PREFIX/bin/fleet"* ]]
}

@test "intrus : une entrée de bin/ hors manifeste et le symlink du PATH qui la vise sont des drifts ; un lien qui vise ailleurs n'est pas à nous" {
  release_posee; verrouille
  : > "$PREFIX/bin/fleet_v2"
  ln -s "$PREFIX/bin/fleet_v2" "$LINKS/fleet_v2"
  ln -s /bin/true "$LINKS/quelconque"
  mod check
  [[ "$output" == *"DRIFT 60-deploy: intrus $PREFIX/bin/fleet_v2 — absent de release.manifest"* ]]
  [[ "$output" == *"DRIFT 60-deploy: symlink intrus $LINKS/fleet_v2 → $PREFIX/bin/fleet_v2"* ]]
  [[ "$output" != *"quelconque"* ]]
}

@test "intrus : l'apply les retire des deux côtés, une ligne par retrait, et ne touche à rien d'autre" {
  release_posee
  : > "$PREFIX/bin/fleet_v2"
  ln -s "$PREFIX/bin/fleet_v2" "$LINKS/fleet_v2"
  ln -s "$PREFIX/bin/fleet" "$LINKS/fleet"
  ln -s /bin/true "$LINKS/quelconque"
  fn 'prune_intrus; echo "rc=$?"'
  [[ "$output" == *"retiré $PREFIX/bin/fleet_v2"*"retiré symlink $LINKS/fleet_v2"*"rc=0"* ]]
  [ ! -e "$PREFIX/bin/fleet_v2" ]
  [ ! -L "$LINKS/fleet_v2" ]
  [ -e "$PREFIX/bin/fleet" ]
  [ -L "$LINKS/fleet" ]
  [ -L "$LINKS/quelconque" ]
}

@test "apply : build déployé égal à HEAD et runtime propre — rien à bâtir, deploy-release.sh n'est pas appelé, les symlinks sont posés, le canal dit source" {
  release_posee; verrouille
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"OK    60-deploy: build déployé $HEAD_SHA, celui de la source — rien à bâtir"* ]]
  [ ! -e "$MARQUEUR" ]
  [ "$(readlink "$LINKS/fleet")" = "$PREFIX/bin/fleet" ]
  [ "$(cat "$CHANNEL")" = source ]
}

@test "canal : le check ne l'écrit pas ; l'apply l'écrit sans le lire — un autre canal ou une valeur illisible cède à celui de l'arbre" {
  release_posee; verrouille
  mod check
  [ ! -e "$CHANNEL" ]
  local ancien
  for ancien in kit 'hors vocabulaire'; do
    printf '%s\n' "$ancien" > "$CHANNEL"
    mod apply
    [ "$status" -eq 0 ] || { echo "canal « $ancien » : $output"; return 1; }
    [ "$(cat "$CHANNEL")" = source ]
  done
}

@test "apply : rien à bâtir sur un prefix resté ouvert après un apply avorté — il est reverrouillé, et le check qui suit est conforme" {
  release_posee; chmod -R 0777 "$PREFIX"
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e "$MARQUEUR" ]
  [[ "$output" == *"POSÉ  60-deploy: prefix verrouillé : $PREFIX (root:root 750)"* ]]
  mod check
  [[ "$output" != *"prefix non verrouillé"* ]]
}

@test "apply : kit détaré sans git, déjà posé à sa révision — rien à bâtir, deploy-release.sh n'est pas rejoué" {
  rm -rf "$RACINE/.git"
  printf '%s\n' "$HEAD_SHA" > "$RACINE/.source-revision"
  release_posee; verrouille
  rm -f "$BIN/mix"
  PATH="$BIN:/usr/bin:/bin" mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"rien à bâtir"* ]]
  [ ! -e "$MARQUEUR" ]
  [[ "$output" != *"runtime déployé"* ]]
}

@test "apply : runtime modifié — deploy-release.sh est joué sous l'humain avec la seule source du runtime, le prefix est reverrouillé 750, le canal s'écrit après" {
  release_posee; verrouille
  printf '# modif\n' >> "$RACINE/runtime/mix.exs"
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$MARQUEUR")" = "$(printf 'POSE\nLCARS_RUNTIME_DIR=%s' "$RACINE/runtime")" ]
  [ "$(stat -c '%U:%G %a' "$PREFIX")" = "$(id -un):$(id -gn) 750" ]
  [ "$(cat "$CHANNEL")" = source ]
  [ "$(readlink "$LINKS/fleet")" = "$PREFIX/bin/fleet" ]
  [[ "$output" == *"POSÉ  60-deploy: runtime déployé : $PREFIX (build $HEAD_SHA) + $LINKS câblé"* ]]
}

@test "check : la génération précédente gardée par deploy-release.sh est nommée avec sa taille et le geste qui la libère" {
  release_posee; verrouille
  mkdir -p "$PREFIX/rel/lcars_fleet.prev/bin"
  head -c 4096 /dev/zero > "$PREFIX/rel/lcars_fleet.prev/bin/lcars_fleet"
  mod check
  [[ "$output" == *"génération précédente gardée : $PREFIX/rel/lcars_fleet.prev ("*"sudo rm -rf $PREFIX/rel/lcars_fleet.prev"* ]]
}

@test "apply : deploy-release.sh en échec, rc 3 compris — échec nommé, le canal n'est pas écrit" {
  release_posee; verrouille
  printf '# modif\n' >> "$RACINE/runtime/mix.exs"
  STUB_POSE_RC=3 mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  60-deploy: "*"build de la release"* ]]
  [[ "$output" == *"WARN  60-deploy: $PREFIX reste déverrouillé pour inspection"* ]]
  [ "$(grep -c 'FAIL  60-deploy' <<< "$output")" -eq 1 ]
  refute_out 'runtime déployé' <<<"$output"
  [ ! -e "$CHANNEL" ]
}

@test "apply : livraison binaire — mix n'est pas requis, la release du kit est posée, le canal dit kit" {
  release_posee 0000000; verrouille
  rm -f "$BIN/mix"
  printf 'cafe1234\n' > "$RACINE/.source-revision"
  PATH="$BIN:/usr/bin:/bin" mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"outillage mix non posé — livraison binaire"* ]]
  [ -s "$MARQUEUR" ]
  [ "$(cat "$CHANNEL")" = kit ]
}

@test "apply : sans mix en livraison source — l'outillage mix échoue en le nommant, deploy-release.sh n'est pas joué" {
  release_posee 0000000; verrouille
  rm -f "$BIN/mix"
  PATH="$BIN:/usr/bin:/bin" mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  60-deploy: commande en échec (rc=127) : as_human env -C $RACINE/runtime mix local.hex --force"* ]]
  [ ! -e "$MARQUEUR" ]
}

@test "apply : rejeu depuis la copie posée, sans source — la release en place est l'état-cible, le canal est écrit" {
  racine_pose "$LCARS_DECOR_ROOT/opt/lcars"
  release_posee; verrouille
  rm -f "$RACINE/runtime/mix.exs"
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"rejeu depuis la copie posée : release en place, aucune source ici"* ]]
  [ ! -e "$MARQUEUR" ]
  [ "$(cat "$CHANNEL")" = source ]
}
