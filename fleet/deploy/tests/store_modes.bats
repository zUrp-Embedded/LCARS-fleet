#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/store_modes.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-19
# STATUS: bats tests for 26-store.sh — the MODES of the store, and the guard that keeps the table honest
#
# WHAT IS UNDER TEST, AND WHY IT IS NOT "does chmod work". A fresh docker volume mounts
# `root:root 0755`. The pod runs under its human's uid and writes exactly ONE of the four store
# subtrees — `cache/`, which the launcher binds `rw` over the `ro` tree because pip, npm and cargo
# write there. Without `2775` and the fleet group, that `rw` bind hands the pod a directory it can
# see and cannot write: the same failure the `rw` bind exists to prevent, in EACCES instead of
# EROFS, and AFTER every precaution the bind ordering takes.
#
# So the contract is: the table carries a mode for EVERY volume the store declares, `cache` is the
# one that is group-writable and setgid, and a missing root is a WIRING FAULT that says so — never
# a store quietly treated as absent. A module that skipped on a missing root would report green on
# a box whose compose stopped setting `LCARS_STORE_ROOT`, which is the one case worth shouting for.
#
# WHAT IS NOT PROVEN HERE: that a pod of human A can replace a cache entry written by a pod of
# human B. That needs two humans, a mounted volume and a real spawn — it belongs to the box, not to
# a witness that must run in CI as an unprivileged user.

setup() {
  DEPLOY="$BATS_TEST_DIRNAME/.."
  MODULE="$DEPLOY/modules.d/26-store.sh"
  export PROVISION_LIB="$DEPLOY/lib/provision-lib.sh"
}

# Un arbre jetable : le module + une lib/store.sh dont ce test choisit les volumes declares.
# Le module resout `../lib/store.sh` depuis SA position, donc le copier suffit a detourner la
# declaration sans toucher au depot.
fake_tree() { # $1... = noms de volumes declares
  mkdir -p "$BATS_TEST_TMPDIR/modules.d" "$BATS_TEST_TMPDIR/lib"
  cp "$MODULE" "$BATS_TEST_TMPDIR/modules.d/"
  { echo 'LCARS_STORE_VOLUMES=('"$*"')'; } > "$BATS_TEST_TMPDIR/lib/store.sh"
  printf '%s' "$BATS_TEST_TMPDIR/modules.d/26-store.sh"
}

@test "racine absente : FAIL nomme et sonde en erreur, jamais un vert" {
  run env LCARS_STORE_ROOT= bash "$MODULE" check
  [ "$status" -eq 2 ]
  [[ "$output" == *"FAIL"* ]]
  [[ "$output" == *"LCARS_STORE_ROOT"* ]]
}

@test "completude : un volume declare sans mode dans la table est un FAIL, pas un defaut silencieux" {
  local mod; mod="$(fake_tree lcars-cache lcars-toolchains lcars-sysroots lcars-state lcars-wheels)"
  run env LCARS_STORE_ROOT=/nonexistent bash "$mod" check
  [ "$status" -eq 2 ]
  [[ "$output" == *"volume sans mode"* ]]
  [[ "$output" == *"wheels"* ]]
}

@test "completude : un mode sans volume est un FAIL — check ne reclamerait ce chemin a vie" {
  local mod; mod="$(fake_tree lcars-cache lcars-toolchains lcars-sysroots)"
  run env LCARS_STORE_ROOT=/nonexistent bash "$mod" check
  [ "$status" -eq 2 ]
  [[ "$output" == *"mode sans volume"* ]]
  [[ "$output" == *"state"* ]]
}

@test "completude : la table du depot recouvre EXACTEMENT lib/store.sh (temoin de presence)" {
  # Le jumeau des deux precedents : sans lui, un correctif qui retire la garde les rend verts.
  run env LCARS_STORE_ROOT=/nonexistent bash "$MODULE" check
  [[ "$output" != *"volume sans mode"* ]]
  [[ "$output" != *"mode sans volume"* ]]
}

@test "cache est le SEUL setgid et le seul au groupe fleet" {
  local table
  table="$(sed -n '/^prov_store_dirs()/,/^}/p' "$MODULE")"
  [[ "$(grep -c '2775' <<< "$table")" -eq 1 ]]
  grep -qE '"cache +2775 root:\$PROV_FLEET_GROUP"' <<< "$table"
  # Les trois autres sont lus en `ro` par le pod : root:root suffit, et c'est un choix, pas un oubli.
  [[ "$(grep -c 'root:root' <<< "$table")" -eq 3 ]]
}

@test "un mode faux se DIT en drift, chemin par chemin" {
  mkdir -p "$BATS_TEST_TMPDIR/store"/{cache,toolchains,sysroots,state}
  run env LCARS_STORE_ROOT="$BATS_TEST_TMPDIR/store" bash "$MODULE" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"cache"* ]]
  [[ "$output" == *"2775 root:fleet"* ]]
}

@test "un volume non monte se dit AVANT le premier pip install d'un pod" {
  mkdir -p "$BATS_TEST_TMPDIR/store/cache"
  run env LCARS_STORE_ROOT="$BATS_TEST_TMPDIR/store" bash "$MODULE" check
  [[ "$output" == *"toolchains absent"* ]]
  [[ "$output" == *"volume non monte"* ]]
}

@test "apply pose 2775 root:fleet sur cache" {
  [ "$(id -u)" -eq 0 ] || skip "apply chown root:fleet — exige root et le groupe fleet (mesure de boite)"
  getent group fleet >/dev/null || skip "groupe fleet absent sur cette machine"
  run env LCARS_STORE_ROOT="$BATS_TEST_TMPDIR/store" bash "$MODULE" apply
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a %U:%G' "$BATS_TEST_TMPDIR/store/cache")" = "2775 root:fleet" ]
}

@test "le module n'est retenu que sur le substrat docker" {
  run "$DEPLOY/provision" list --substrate docker
  [[ "$output" == *"26-store"* ]]
  run "$DEPLOY/provision" list --substrate wsl
  [[ "$output" != *"26-store"* ]]
  run "$DEPLOY/provision" list --substrate linux
  [[ "$output" != *"26-store"* ]]
}
