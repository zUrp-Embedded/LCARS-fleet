#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/20-groups.bats
# AUTHOR: bob
# STARDATE: 2026-09-14
# STATUS: témoins de 20-groups joué entier — fleet et lcars-console au gid de la table, l'humain de la passe dans fleet

load ../refute
load ../support/decor

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)
  SRC="$BATS_TEST_DIRNAME/../../modules.d/20-groups.sh"; [ -f "$SRC" ]
  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export PROVISION_MODULE=20-groups PROV_SUBSTRATE=linux PROVISION_RUN=1 PROV_HUMAN=zoe

  decor_pose
  decor_comptes
  CALLS="$DECOR_COMPTES"
  GROUP="$LCARS_DECOR_ROOT/etc/group"
  printf '%s\n' 'root:x:0:0::/root:/bin/bash' 'zoe:x:1000:1000::/home/zoe:/bin/bash' > "$LCARS_DECOR_ROOT/etc/passwd"
  printf '%s\n' 'root:x:0:' 'zoe:x:1000:' 'fleet:x:2000:zoe' 'lcars-console:x:2001:' > "$GROUP"
}

mod() { run bash "$SRC" "$1"; }

@test "check : les deux groupes au gid de la table et l'humain dans fleet sont conformes" {
  mod check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"OK    20-groups: groupe fleet"* ]]
  [[ "$output" == *"OK    20-groups: groupe lcars-console"* ]]
  [[ "$output" == *"OK    20-groups: zoe ∈ fleet"* ]]
}

@test "check : un gid qui s'écarte de la table est une dérive — le doctor ne peut pas être vert avant un apply en dérive" {
  printf '%s\n' 'root:x:0:' 'zoe:x:1000:' 'fleet:x:4242:zoe' 'lcars-console:x:2001:' > "$GROUP"
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 20-groups: groupe fleet : gid 4242, la table déclare 2000"* ]]
  mod apply
  [ "$status" -eq 2 ]
  [[ "$output" == *"DRIFT 20-groups: groupe fleet : gid 4242, la table déclare 2000"* ]]
}

@test "apply : les groupes absents sont créés au gid de la table, l'humain rejoint fleet, puis check est conforme" {
  printf '%s\n' 'root:x:0:' 'zoe:x:1000:' > "$GROUP"
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 20-groups: groupe fleet absent"* ]]
  [[ "$output" == *"DRIFT 20-groups: zoe ∉ fleet"* ]]
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx 'groupadd -g 2000 fleet' "$CALLS"
  grep -qx 'groupadd -g 2001 lcars-console' "$CALLS"
  grep -qx 'usermod -aG fleet zoe' "$CALLS"
  mod check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "apply : un état conforme ne produit aucun geste, et le dit" {
  mod apply
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
  [[ "$output" == *"OK    20-groups: groupes fleet et lcars-console en place, zoe membre de fleet"* ]]
}

@test "un humain inconnu du système : check le nomme, apply échoue sans créer de groupe à sa place" {
  PROV_HUMAN=personne mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 20-groups: humain cible inconnu du système : personne"* ]]
  PROV_HUMAN=personne mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  20-groups: ensure_member: user inconnu: personne"* ]]
}
