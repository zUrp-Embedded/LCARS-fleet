#!/usr/bin/env bats
# SOURCE: deploy/tests/lib/deploy_release.bats
# AUTHOR: consultant (remediation agent, off-fleet session)
# STARDATE: 2026.255
# STATUS: bats tests for deploy/lib/deploy-release.sh atomic-swap helpers (crash-safe deploy)
#

load ../refute

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../lib/deploy-release.sh"
  # shellcheck source=../../lib/deploy-release.sh
  source "$SCRIPT"
  TMP="$(mktemp -d)"
}

teardown() { rm -rf "$TMP"; }

@test "atomic_swap_dir: replaces the live tree and keeps the previous as .prev" {
  mkdir -p "$TMP/src/bin"; printf '#!/bin/sh\nnew\n' > "$TMP/src/bin/lcars_fleet"; chmod +x "$TMP/src/bin/lcars_fleet"
  mkdir -p "$TMP/dst/bin"; printf '#!/bin/sh\nold\n' > "$TMP/dst/bin/lcars_fleet"; chmod +x "$TMP/dst/bin/lcars_fleet"

  run atomic_swap_dir "$TMP/src" "$TMP/dst" "bin/lcars_fleet"
  [ "$status" -eq 0 ]
  grep -q new "$TMP/dst/bin/lcars_fleet"
  grep -q old "$TMP/dst.prev/bin/lcars_fleet"
}

@test "atomic_swap_dir: a build missing its probe FAILS and leaves the live tree untouched" {
  mkdir -p "$TMP/src/bin"    # no lcars_fleet probe inside
  mkdir -p "$TMP/dst/bin"; printf '#!/bin/sh\nold\n' > "$TMP/dst/bin/lcars_fleet"; chmod +x "$TMP/dst/bin/lcars_fleet"

  run atomic_swap_dir "$TMP/src" "$TMP/dst" "bin/lcars_fleet"
  [ "$status" -ne 0 ]
  [[ "$output" == *"build stage invalide"* ]]
  grep -q old "$TMP/dst/bin/lcars_fleet"
  [ ! -e "$TMP/dst.staging.$$" ]
}

@test "atomic_swap_file: renames the new file over the old (atomic, never truncated)" {
  printf 'NEW\n' > "$TMP/src"
  printf 'OLD\n' > "$TMP/dst"

  run atomic_swap_file "$TMP/src" "$TMP/dst"
  [ "$status" -eq 0 ]
  grep -q NEW "$TMP/dst"
  [ ! -e "$TMP/dst.new.$$" ]
}

@test "build_release runs the GATE before the release (gate->build continuation)" {
  mkdir -p "$TMP/binstub"
  cat > "$TMP/binstub/mix" << 'MIX'
#!/usr/bin/env bash
echo "$@" >> "$MIX_CALL_LOG"
exit 0
MIX
  chmod +x "$TMP/binstub/mix"

  export MIX_CALL_LOG="$TMP/mix-calls.log"
  PATH="$TMP/binstub:$PATH" run build_release "$TMP"
  [ "$status" -eq 0 ]

  grep -n gate "$MIX_CALL_LOG"
  gate_line="$(grep -n 'gate' "$MIX_CALL_LOG" | head -1 | cut -d: -f1)"
  rel_line="$(grep -n 'release' "$MIX_CALL_LOG" | head -1 | cut -d: -f1)"
  [ -n "$gate_line" ]
  [ -n "$rel_line" ]
  [ "$gate_line" -lt "$rel_line" ]
}

@test "build_release: LCARS_INSTALL_SKIP_GATE=1 skips the gate (explicit escape, stated)" {
  mkdir -p "$TMP/binstub"
  cat > "$TMP/binstub/mix" << 'MIX'
#!/usr/bin/env bash
echo "$@" >> "$MIX_CALL_LOG"
exit 0
MIX
  chmod +x "$TMP/binstub/mix"

  export MIX_CALL_LOG="$TMP/mix-calls.log"
  LCARS_INSTALL_SKIP_GATE=1 PATH="$TMP/binstub:$PATH" run build_release "$TMP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"gate sauté"* ]]
  refute grep -q ' gate$' "$MIX_CALL_LOG"
  grep -q release "$MIX_CALL_LOG"
}

@test "build_release: a RED gate stops the build (no release built)" {
  mkdir -p "$TMP/binstub"
  cat > "$TMP/binstub/mix" << 'MIX'
#!/usr/bin/env bash
echo "$@" >> "$MIX_CALL_LOG"
case "$*" in
  *gate*)    exit 1 ;;   # red gate
  *release*) echo "RELEASE-RAN" >> "$MIX_CALL_LOG"; exit 0 ;;
  *)         exit 0 ;;
esac
MIX
  chmod +x "$TMP/binstub/mix"

  export MIX_CALL_LOG="$TMP/mix-calls.log"
  PATH="$TMP/binstub:$PATH" run build_release "$TMP"
  [ "$status" -ne 0 ]
  refute grep -q RELEASE-RAN "$MIX_CALL_LOG"
}

@test "sourcing deploy-release.sh never runs the deploy (source guard)" {
  run bash -c "source '$SCRIPT'; echo sourced-ok"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sourced-ok"* ]]
}

@test "refuse_root : root est refusé, avec la conséquence et le compte attendu" {
  run refuse_root 0
  [ "$status" -ne 0 ]
  [[ "$output" == *"lancé en root — le build laisserait des artefacts root dans l'arbre source"*"compte propriétaire"* ]]
}

@test "refuse_root: an ordinary uid passes" {
  run refuse_root 1000
  [ "$status" -eq 0 ]
}

@test "refuse_root: called with NO argument, the default IS the effective uid" {
  run refuse_root
  local bare_status="$status"
  run refuse_root "$EUID"
  [ "$bare_status" -eq "$status" ]
}

@test "require_prefix_writable: a writable prefix passes" {
  run require_prefix_writable "$TMP/prefix"
  [ "$status" -eq 0 ]
}

@test "require_prefix_writable: walks UP to the first existing parent" {
  run require_prefix_writable "$TMP/a/b/c/d"
  [ "$status" -eq 0 ]
}

@test "require_prefix_writable: a non-writable destination FAILS before the build" {
  mkdir -p "$TMP/ro"
  chmod 500 "$TMP/ro"
  run require_prefix_writable "$TMP/ro/prefix"
  chmod 700 "$TMP/ro"
  [ "$status" -ne 0 ]
  [[ "$output" == *"non inscriptible"* ]]
  [[ "$output" == *"sudo"* ]]
}

@test "6-110: un lien requis qui echoue rend NON-ZERO — le compteur est enfin lu" {
  PREFIX="$TMP/prefix"
  LINK_DIR="$TMP/ro"
  MF_FILES=(fleet)
  MF_LINKS=(1)
  mkdir -p "$PREFIX/bin" "$LINK_DIR"
  chmod 500 "$LINK_DIR"

  run wire_path_links
  chmod 700 "$LINK_DIR"

  [ "$status" -ne 0 ]
  [[ "$output" == *"lien $LINK_DIR/fleet non posé"* ]]
}

@test "6-110: TEMOIN — un lien qui passe rend ZERO et annonce les liens poses" {
  PREFIX="$TMP/prefix"
  LINK_DIR="$TMP/bin"
  MF_FILES=(fleet)
  MF_LINKS=(1)
  mkdir -p "$PREFIX/bin" "$LINK_DIR"

  run wire_path_links
  [ "$status" -eq 0 ]
  [[ "$output" == *"liens $LINK_DIR/{fleet}"* ]]
  [ -L "$LINK_DIR/fleet" ]
}

@test "6-110: une entree NON-link ne compte pas — seul le cablage requis decide" {
  PREFIX="$TMP/prefix"
  LINK_DIR="$TMP/ro"
  MF_FILES=(fleet pas_un_lien)
  MF_LINKS=(0 0)
  mkdir -p "$PREFIX/bin" "$LINK_DIR"
  chmod 500 "$LINK_DIR"

  run wire_path_links
  chmod 700 "$LINK_DIR"

  [ "$status" -eq 0 ]
}

@test "6-110: l'ANCIEN lien survit a l'echec — c'est le pire cas, pas un cas theorique" {
  PREFIX="$TMP/prefix"
  LINK_DIR="$TMP/ro"
  # shellcheck disable=SC2034  # entrees de `wire_path_links`, la fonction sous test
  MF_FILES=(fleet)
  # shellcheck disable=SC2034
  MF_LINKS=(1)
  mkdir -p "$PREFIX/bin" "$LINK_DIR" "$TMP/ancienne/bin"
  ln -s "$TMP/ancienne/bin/fleet" "$LINK_DIR/fleet"
  chmod 500 "$LINK_DIR"

  run wire_path_links
  chmod 700 "$LINK_DIR"

  [ "$status" -ne 0 ]
  [ "$(readlink "$LINK_DIR/fleet")" = "$TMP/ancienne/bin/fleet" ]
}

@test "S4 : un intrus de \$PREFIX/bin est retire, ET son symlink du PATH, une ligne par retrait" {
  PREFIX="$TMP/prefix"
  LINK_DIR="$TMP/bin"
  MF_FILES=(fleet lcars)
  mkdir -p "$PREFIX/bin" "$LINK_DIR"
  : > "$PREFIX/bin/fleet"; : > "$PREFIX/bin/lcars"; : > "$PREFIX/bin/fleet_v2"
  ln -s "$PREFIX/bin/fleet_v2" "$LINK_DIR/fleet_v2"
  ln -s "$PREFIX/bin/fleet" "$LINK_DIR/fleet"

  run prune_bin_dir
  [ "$status" -eq 0 ]
  [ ! -e "$PREFIX/bin/fleet_v2" ]
  [ ! -L "$LINK_DIR/fleet_v2" ]
  [[ "$output" == *"retire $PREFIX/bin/fleet_v2 (absent du manifest)"* ]]
  [[ "$output" == *"retire le lien $LINK_DIR/fleet_v2"* ]]
  [ -e "$PREFIX/bin/fleet" ]
  [ -e "$PREFIX/bin/lcars" ]
  [ -L "$LINK_DIR/fleet" ]
}

@test "S4 : un lien du PATH qui vise AILLEURS n'est pas a nous — il reste, meme homonyme" {
  PREFIX="$TMP/prefix"
  LINK_DIR="$TMP/bin"
  MF_FILES=(fleet)
  mkdir -p "$PREFIX/bin" "$LINK_DIR" "$TMP/autre"
  : > "$PREFIX/bin/fleet"; : > "$PREFIX/bin/vieux"; : > "$TMP/autre/vieux"
  ln -s "$TMP/autre/vieux" "$LINK_DIR/vieux"

  run prune_bin_dir
  [ "$status" -eq 0 ]
  [ ! -e "$PREFIX/bin/vieux" ]
  [ -L "$LINK_DIR/vieux" ]
  [ "$(readlink "$LINK_DIR/vieux")" = "$TMP/autre/vieux" ]
  refute grep -q 'retire le lien' <<<"$output"
}

@test "S4 : un symlink que l'humain ne peut pas retirer se DIT et ne fait pas echouer la pose" {
  PREFIX="$TMP/prefix"
  LINK_DIR="$TMP/ro"
  MF_FILES=(fleet)
  mkdir -p "$PREFIX/bin" "$LINK_DIR"
  : > "$PREFIX/bin/fleet"; : > "$PREFIX/bin/fleet_v2"
  ln -s "$PREFIX/bin/fleet_v2" "$LINK_DIR/fleet_v2"
  chmod 500 "$LINK_DIR"

  run prune_bin_dir
  chmod 700 "$LINK_DIR"
  [ "$status" -eq 0 ]
  [ ! -e "$PREFIX/bin/fleet_v2" ]
  [[ "$output" == *"lien $LINK_DIR/fleet_v2 non retiré"* ]]
  [[ "$output" == *"60-deploy"* ]]
}
