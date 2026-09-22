#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/modules.d/20-groups.bats
# AUTHOR: bob
# STARDATE: 2026-09-15
# STATUS: témoins de 20-groups joué entier — fleet et lcars-console au gid de la table, le siège dans fleet, aucun autre humain jugé

load ../refute
load ../support/decor

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)
  SRC="$BATS_TEST_DIRNAME/../../modules.d/20-groups.sh"; [ -f "$SRC" ]
  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  # le siège est bob (uid 1000), celui qui a lancé provision ; la passe le sert par défaut
  export PROVISION_MODULE=20-groups PROV_SUBSTRATE=linux PROVISION_RUN=1 PROV_HUMAN=bob LCARS_SYSADMIN_UID=1000

  decor_pose
  decor_comptes
  CALLS="$DECOR_COMPTES"
  GROUP="$LCARS_DECOR_ROOT/etc/group"
  printf '%s\n' 'root:x:0:0::/root:/bin/bash' 'bob:x:1000:1000::/home/bob:/bin/bash' 'zoe:x:1001:1001::/home/zoe:/bin/bash' \
    > "$LCARS_DECOR_ROOT/etc/passwd"
  printf '%s\n' 'root:x:0:' 'bob:x:1000:' 'zoe:x:1001:' 'fleet:x:2000:bob' 'lcars-console:x:2001:' > "$GROUP"
}

mod() { run bash "$SRC" "$1"; }

@test "check : les deux groupes au gid de la table et le siège dans fleet sont conformes" {
  mod check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"OK    20-groups: groupe fleet"* ]]
  [[ "$output" == *"OK    20-groups: groupe lcars-console"* ]]
  [[ "$output" == *"OK    20-groups: siège bob ∈ fleet"* ]]
}

@test "check : un gid qui s'écarte de la table est une dérive — le doctor ne peut pas être vert avant un apply en dérive" {
  printf '%s\n' 'root:x:0:' 'bob:x:1000:' 'fleet:x:4242:bob' 'lcars-console:x:2001:' > "$GROUP"
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 20-groups: groupe fleet : gid 4242, la table déclare 2000"* ]]
  mod apply
  [ "$status" -eq 2 ]
  [[ "$output" == *"DRIFT 20-groups: groupe fleet : gid 4242, la table déclare 2000"* ]]
}

@test "apply : les groupes absents sont créés au gid de la table, le siège rejoint fleet, puis check est conforme" {
  printf '%s\n' 'root:x:0:' 'bob:x:1000:' 'zoe:x:1001:' > "$GROUP"
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 20-groups: groupe fleet absent"* ]]
  [[ "$output" == *"DRIFT 20-groups: siège bob ∉ fleet"* ]]
  mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx 'groupadd -g 2000 fleet' "$CALLS"
  grep -qx 'groupadd -g 2001 lcars-console' "$CALLS"
  grep -qx 'usermod -aG fleet bob' "$CALLS"
  mod check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "apply : un état conforme ne produit aucun geste, et le dit" {
  mod apply
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
  [[ "$output" == *"OK    20-groups: groupes fleet et lcars-console en place, siège bob membre de fleet"* ]]
}

@test "--human qui n'est pas le siège : ni ajouté à fleet, ni mesuré en dérive — le convergeur en est seul juge ; le siège est servi quand même" {
  # la boucle du banc 63 : apply mettait zoe dans fleet, le convergeur la révoquait, le doctor redisait la dérive
  printf '%s\n' 'root:x:0:' 'bob:x:1000:' 'zoe:x:1001:' 'fleet:x:2000:' 'lcars-console:x:2001:' > "$GROUP"
  PROV_HUMAN=zoe mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 20-groups: siège bob ∉ fleet"* ]]
  [[ "$output" == *"OK    20-groups: zoe n'est pas le siège : son appartenance à fleet est l'affaire du convergeur d'humains (team « humans » de la forge)"* ]]
  refute_out 'zoe ∉' <<<"$output"
  PROV_HUMAN=zoe mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx 'usermod -aG fleet bob' "$CALLS"
  refute grep -q 'zoe' "$CALLS"
  PROV_HUMAN=zoe mod check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  # déjà dans fleet (le convergeur l'y a mise), elle n'est pas mesurée non plus
  printf '%s\n' 'root:x:0:' 'bob:x:1000:' 'zoe:x:1001:' 'fleet:x:2000:bob,zoe' 'lcars-console:x:2001:' > "$GROUP"
  PROV_HUMAN=zoe mod check
  [ "$status" -eq 0 ]
  refute_out 'zoe ∈' <<<"$output"
}

@test "siège root (doctor du conteneur par docker exec, sans --human) : ni dérive, ni ajout à fleet" {
  # mesuré dans l'image beta2 : root ∉ fleet, et « DRIFT 20-groups: root ∉ fleet » au doctor que le PRÊT désigne
  LCARS_SYSADMIN_UID=0 PROV_HUMAN=root mod check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"OK    20-groups: le siège est root (uid 0) : fleet ne lui donne rien"* ]]
  refute_out 'DRIFT|convergeur' <<<"$output"
  LCARS_SYSADMIN_UID=0 PROV_HUMAN=root mod apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  refute grep -q 'usermod' "$CALLS"
}

@test "un siège qu'aucun compte ne porte : check le nomme par son uid, apply échoue sans ajouter personne à fleet" {
  LCARS_SYSADMIN_UID=4242 mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT 20-groups: siège inconnu du système : aucun compte ne porte l'uid 4242 (LCARS_SYSADMIN_UID)"* ]]
  LCARS_SYSADMIN_UID=4242 mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  20-groups: siège inconnu du système : aucun compte ne porte l'uid 4242"*"personne n'est ajouté à fleet"* ]]
  refute grep -q 'usermod' "$CALLS"
}

@test "sans LCARS_SYSADMIN_UID : refus qui dit qui l'établit, aucun geste" {
  unset LCARS_SYSADMIN_UID
  mod apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"LCARS_SYSADMIN_UID absent ou non numérique"*"provision l'établit"* ]]
  [ ! -s "$CALLS" ]
}
